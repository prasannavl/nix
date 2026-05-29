use anyhow::{anyhow, bail, Context, Result};
use async_nats::jetstream;
use async_nats::jetstream::consumer;
use async_nats::jetstream::AckKind;
use async_nats::{Client, Event, Subject};
use bytes::Bytes;
use clap::Parser;
use futures_util::StreamExt;
use serde::Deserialize;
use std::collections::hash_map::DefaultHasher;
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::watch;
use tokio::task::JoinSet;
use tracing::{info, warn};

const DEFAULT_SERVER: &str = "nats://127.0.0.1:4222";
const DEFAULT_HTTP_TIMEOUT_SECS: u64 = 30;
const RETRY_INITIAL_SECS: u64 = 1;
const RETRY_MAX_SECS: u64 = 60;
const DEFAULT_JETSTREAM_ACK_WAIT_SECS: u64 = 30;
// Keep the bridge single-flight by default. The current JetStream loop handles
// messages sequentially, so fetching or allowing more than one unacked message
// mostly increases buffering rather than throughput.
const DEFAULT_JETSTREAM_FETCH_BATCH: usize = 1;
const DEFAULT_JETSTREAM_MAX_ACK_PENDING: i64 = 1;
const DEFAULT_JETSTREAM_NAK_DELAY_SECS: u64 = 30;
const DEFAULT_FETCH_EXPIRES_MS: u64 = 250;
const JETSTREAM_REPLY_SUBJECT_HEADER: &str = "X-Nats-Http-Bridge-Reply-Subject";

#[derive(Debug, Parser)]
#[command(version, about = "Bridge NATS subscriptions into HTTP endpoints")]
struct Cli {
    #[arg(long)]
    config: PathBuf,
    #[arg(long, default_value = DEFAULT_SERVER)]
    server: String,
    #[arg(long)]
    tls: Option<bool>,
    #[arg(long)]
    ca_cert: Option<PathBuf>,
    #[arg(long)]
    client_cert: Option<PathBuf>,
    #[arg(long)]
    client_key: Option<PathBuf>,
    #[arg(long, default_value_t = DEFAULT_HTTP_TIMEOUT_SECS)]
    http_timeout_secs: u64,
    #[arg(long, default_value = "info")]
    log_filter: String,
    #[arg(long)]
    check_config: bool,
}

#[derive(Debug, Clone, Deserialize)]
struct Config {
    routes: Vec<RouteConfig>,
}

#[derive(Debug, Clone, Deserialize)]
struct RouteConfig {
    name: Option<String>,
    subject: String,
    #[serde(default)]
    mode: BridgeMode,
    #[serde(default)]
    transport: TransportConfig,
    http: HttpConfig,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum BridgeMode {
    #[default]
    Push,
    RequestResponse,
}

#[derive(Debug, Clone, Deserialize)]
struct HttpConfig {
    url: String,
    #[serde(default)]
    method: HttpMethod,
}

#[derive(Debug, Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "kebab-case")]
enum HttpMethod {
    Get,
    #[default]
    Post,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
#[derive(Default)]
enum TransportConfig {
    #[default]
    Core,
    Jetstream {
        stream: String,
        consumer: Option<String>,
        ack_wait_secs: Option<u64>,
        max_ack_pending: Option<i64>,
        max_deliver: Option<i64>,
        fetch_batch: Option<usize>,
        nak_delay_secs: Option<u64>,
    },
}

#[derive(Debug, Clone)]
struct HttpResponseData {
    status: reqwest::StatusCode,
    body: Bytes,
}

#[derive(Debug, Clone)]
struct InboundMessage {
    subject: String,
    reply: Option<Subject>,
    payload: Bytes,
}

#[derive(Debug, Clone)]
struct RetryBackoff {
    next: Duration,
    max: Duration,
}

impl RetryBackoff {
    fn new() -> Self {
        Self {
            next: Duration::from_secs(RETRY_INITIAL_SECS),
            max: Duration::from_secs(RETRY_MAX_SECS),
        }
    }

    fn next_delay(&mut self) -> Duration {
        let delay = self.next;
        self.next = std::cmp::min(self.next.saturating_mul(2), self.max);
        delay
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    init_tracing(&cli.log_filter);
    run(cli).await
}

async fn run(cli: Cli) -> Result<()> {
    let config = load_config(&cli.config)?;
    if cli.check_config {
        info!(routes = config.routes.len(), "config valid");
        return Ok(());
    }

    let client = connect_nats(&cli).await?;
    let http_client = reqwest::Client::builder()
        .timeout(Duration::from_secs(cli.http_timeout_secs))
        .build()
        .context("failed to build HTTP client")?;

    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let mut tasks = JoinSet::new();

    for route in config.routes {
        let client = client.clone();
        let http_client = http_client.clone();
        let shutdown_rx = shutdown_rx.clone();
        tasks.spawn(async move { run_route(route, client, http_client, shutdown_rx).await });
    }

    let mut shutting_down = false;

    loop {
        tokio::select! {
            signal = tokio::signal::ctrl_c(), if !shutting_down => {
                signal.context("failed to listen for Ctrl+C")?;
                shutting_down = true;
                info!("shutdown requested");
                let _ = shutdown_tx.send(true);
            }
            joined = tasks.join_next() => match joined {
                Some(Ok(Ok(()))) => {
                    if !shutting_down {
                        let _ = shutdown_tx.send(true);
                        bail!("bridge route exited unexpectedly");
                    }
                }
                Some(Ok(Err(error))) => {
                    if shutting_down {
                        warn!(error = %error, "route exited with error during shutdown");
                    } else {
                        let _ = shutdown_tx.send(true);
                        return Err(error);
                    }
                }
                Some(Err(error)) => {
                    let error = anyhow!("route task join failure: {error}");
                    if shutting_down {
                        warn!(error = %error, "route task failed during shutdown");
                    } else {
                        let _ = shutdown_tx.send(true);
                        return Err(error);
                    }
                }
                None => return Ok(()),
            }
        }
    }
}

fn init_tracing(log_filter: &str) {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_new(log_filter)
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_target(false)
        .try_init();
}

fn load_config(path: &Path) -> Result<Config> {
    let raw = fs::read_to_string(path)
        .with_context(|| format!("failed to read config file {}", path.display()))?;
    let config: Config = serde_yaml::from_str(&raw)
        .with_context(|| format!("failed to parse {}", path.display()))?;
    config.validate()?;
    Ok(config)
}

impl Config {
    fn validate(&self) -> Result<()> {
        if self.routes.is_empty() {
            bail!("config must include at least one routes entry");
        }

        for route in &self.routes {
            route.validate()?;
        }

        Ok(())
    }
}

impl RouteConfig {
    fn validate(&self) -> Result<()> {
        if self.subject.trim().is_empty() {
            bail!("route subject must not be empty");
        }

        if self.http.url.trim().is_empty() {
            bail!("route {} has an empty http.url", self.label());
        }
        let url = reqwest::Url::parse(&self.http.url)
            .with_context(|| format!("route {} has an invalid http.url", self.label()))?;
        if !matches!(url.scheme(), "http" | "https") {
            bail!(
                "route {} http.url must use http or https, got {}",
                self.label(),
                url.scheme()
            );
        }

        match &self.transport {
            TransportConfig::Core => {}
            TransportConfig::Jetstream {
                stream,
                consumer,
                ack_wait_secs,
                max_ack_pending,
                max_deliver,
                fetch_batch,
                nak_delay_secs,
            } => {
                if stream.trim().is_empty() {
                    bail!("JetStream route {} must set transport.stream", self.label());
                }
                if let Some(consumer) = consumer {
                    if consumer.trim().is_empty() {
                        bail!(
                            "JetStream route {} has an empty transport.consumer",
                            self.label()
                        );
                    }
                }
                if let Some(ack_wait_secs) = ack_wait_secs {
                    if *ack_wait_secs == 0 {
                        bail!(
                            "JetStream route {} transport.ack_wait_secs must be at least 1",
                            self.label()
                        );
                    }
                }
                if let Some(max_ack_pending) = max_ack_pending {
                    if *max_ack_pending < 1 {
                        bail!(
                            "JetStream route {} transport.max_ack_pending must be at least 1",
                            self.label()
                        );
                    }
                }
                if let Some(max_deliver) = max_deliver {
                    if *max_deliver < 1 {
                        bail!(
                            "JetStream route {} transport.max_deliver must be at least 1",
                            self.label()
                        );
                    }
                }
                if let Some(fetch_batch) = fetch_batch {
                    if *fetch_batch == 0 {
                        bail!(
                            "JetStream route {} transport.fetch_batch must be at least 1",
                            self.label()
                        );
                    }
                }
                if let Some(nak_delay_secs) = nak_delay_secs {
                    if *nak_delay_secs == 0 {
                        bail!(
                            "JetStream route {} transport.nak_delay_secs must be at least 1",
                            self.label()
                        );
                    }
                }
            }
        }

        Ok(())
    }

    fn label(&self) -> &str {
        self.name.as_deref().unwrap_or(&self.subject)
    }
}

async fn connect_nats(cli: &Cli) -> Result<Client> {
    validate_nats_cli(cli)?;
    let mut backoff = RetryBackoff::new();

    loop {
        let options = build_connect_options(cli)?;
        match options.connect(&cli.server).await {
            Ok(client) => return Ok(client),
            Err(error) => {
                let delay = backoff.next_delay();
                warn!(
                    server = %cli.server,
                    retry_secs = delay.as_secs(),
                    error = %error,
                    "failed to connect to NATS server; retrying"
                );
                tokio::time::sleep(delay).await;
            }
        }
    }
}

fn validate_nats_cli(cli: &Cli) -> Result<()> {
    if cli.client_cert.is_some() != cli.client_key.is_some() {
        bail!("--client-cert and --client-key must be provided together");
    }

    if matches!(cli.tls, Some(false))
        && (cli.ca_cert.is_some() || cli.client_cert.is_some() || cli.client_key.is_some())
    {
        bail!("TLS files were provided but --tls=false was requested");
    }
    Ok(())
}

fn build_connect_options(cli: &Cli) -> Result<async_nats::ConnectOptions> {
    let mut options = build_default_connect_options().name("nats-http-bridge");
    let require_tls = cli
        .tls
        .unwrap_or(cli.ca_cert.is_some() || cli.client_cert.is_some() || cli.client_key.is_some());
    options = options.require_tls(require_tls);

    if let Some(ca_cert) = &cli.ca_cert {
        options = options.add_root_certificates(ca_cert.clone());
    }

    if let (Some(client_cert), Some(client_key)) = (&cli.client_cert, &cli.client_key) {
        options = options.add_client_certificate(client_cert.clone(), client_key.clone());
    }

    Ok(options)
}

fn build_default_connect_options() -> async_nats::ConnectOptions {
    let last_slow_consumer = Arc::new(Mutex::new(None::<std::time::Instant>));

    async_nats::ConnectOptions::new().event_callback(move |event| {
        let last_slow_consumer = last_slow_consumer.clone();
        async move {
            match event {
                Event::Connected => info!("nats connected"),
                Event::Disconnected => warn!("nats disconnected"),
                Event::LameDuckMode => warn!("nats server entered lame duck mode"),
                Event::Draining => info!("nats draining"),
                Event::Closed => warn!("nats connection closed"),
                Event::ServerError(error) => warn!(%error, "nats server error"),
                Event::ClientError(error) => warn!(%error, "nats client error"),
                Event::SlowConsumer(subscription_id) => {
                    let now = std::time::Instant::now();
                    let mut last_logged = last_slow_consumer
                        .lock()
                        .expect("slow consumer callback mutex poisoned");
                    let should_log = last_logged.is_none_or(|previous| {
                        now.duration_since(previous) >= Duration::from_secs(5)
                    });
                    if should_log {
                        *last_logged = Some(now);
                        warn!(subscription_id, "nats slow consumer backpressure detected");
                    }
                }
            }
        }
    })
}

async fn run_route(
    route: RouteConfig,
    client: Client,
    http_client: reqwest::Client,
    shutdown: watch::Receiver<bool>,
) -> Result<()> {
    match &route.transport {
        TransportConfig::Core => run_core_route(route, client, http_client, shutdown).await,
        TransportConfig::Jetstream { .. } => {
            run_jetstream_route(route, client, http_client, shutdown).await
        }
    }
}

async fn run_core_route(
    route: RouteConfig,
    client: Client,
    http_client: reqwest::Client,
    mut shutdown: watch::Receiver<bool>,
) -> Result<()> {
    let mut backoff = RetryBackoff::new();
    loop {
        if *shutdown.borrow() {
            return Ok(());
        }

        match run_core_route_once(&route, &client, &http_client, shutdown.clone()).await {
            Ok(()) => return Ok(()),
            Err(error) => {
                let delay = backoff.next_delay();
                warn!(
                    route = route.label(),
                    retry_secs = delay.as_secs(),
                    error = %error,
                    "core NATS route error; retrying"
                );
                tokio::select! {
                    _ = tokio::time::sleep(delay) => {}
                    _ = wait_for_shutdown(&mut shutdown) => {}
                }
            }
        }
    }
}

async fn run_core_route_once(
    route: &RouteConfig,
    client: &Client,
    http_client: &reqwest::Client,
    mut shutdown: watch::Receiver<bool>,
) -> Result<()> {
    let mut subscriber = client
        .subscribe(route.subject.clone())
        .await
        .with_context(|| format!("failed to subscribe to {}", route.subject))?;

    info!(
        route = route.label(),
        subject = route.subject.as_str(),
        mode = ?route.mode,
        "core route ready"
    );

    loop {
        tokio::select! {
            _ = wait_for_shutdown(&mut shutdown) => break,
            maybe_message = subscriber.next() => {
                let Some(message) = maybe_message else {
                    bail!("core subscription for {} closed", route.label());
                };
                if let Err(error) = handle_core_message(route, client, http_client, message).await {
                    warn!(route = route.label(), error = %error, "core message handling failed");
                }
            }
        }
    }

    Ok(())
}

async fn handle_core_message(
    route: &RouteConfig,
    client: &Client,
    http_client: &reqwest::Client,
    message: async_nats::Message,
) -> Result<()> {
    let inbound = InboundMessage::from_core(message);

    match route.mode {
        BridgeMode::Push => {
            let response = call_http(http_client, route, &inbound).await?;
            if !response.status.is_success() {
                warn!(
                    route = route.label(),
                    subject = inbound.subject,
                    status = %response.status,
                    "core push route got non-success HTTP response"
                );
            }
        }
        BridgeMode::RequestResponse => {
            let reply = inbound.reply.clone().context(format!(
                "core request-response route {} received a message without a reply subject",
                route.label()
            ))?;
            let response = call_http(http_client, route, &inbound).await?;
            publish_response(client, reply, response.body)
                .await
                .context("failed to publish core request-response reply")?;
        }
    }

    Ok(())
}

async fn run_jetstream_route(
    route: RouteConfig,
    client: Client,
    http_client: reqwest::Client,
    mut shutdown: watch::Receiver<bool>,
) -> Result<()> {
    let mut backoff = RetryBackoff::new();
    loop {
        if *shutdown.borrow() {
            return Ok(());
        }

        match run_jetstream_route_once(&route, &client, &http_client, shutdown.clone()).await {
            Ok(()) => return Ok(()),
            Err(error) => {
                let delay = backoff.next_delay();
                warn!(
                    route = route.label(),
                    retry_secs = delay.as_secs(),
                    error = %error,
                    "JetStream route error; retrying"
                );
                tokio::select! {
                    _ = tokio::time::sleep(delay) => {}
                    _ = wait_for_shutdown(&mut shutdown) => {}
                }
            }
        }
    }
}

async fn run_jetstream_route_once(
    route: &RouteConfig,
    client: &Client,
    http_client: &reqwest::Client,
    shutdown: watch::Receiver<bool>,
) -> Result<()> {
    let jetstream = jetstream::new(client.clone());
    let (
        stream_name,
        consumer_name,
        ack_wait_secs,
        max_ack_pending,
        max_deliver,
        fetch_batch,
        nak_delay,
    ) = match &route.transport {
        TransportConfig::Jetstream {
            stream,
            consumer,
            ack_wait_secs,
            max_ack_pending,
            max_deliver,
            fetch_batch,
            nak_delay_secs,
        } => (
            stream.clone(),
            consumer
                .clone()
                .unwrap_or_else(|| default_consumer_name(route, stream)),
            ack_wait_secs.unwrap_or(DEFAULT_JETSTREAM_ACK_WAIT_SECS),
            max_ack_pending.unwrap_or(DEFAULT_JETSTREAM_MAX_ACK_PENDING),
            *max_deliver,
            fetch_batch.unwrap_or(DEFAULT_JETSTREAM_FETCH_BATCH),
            Duration::from_secs(nak_delay_secs.unwrap_or(DEFAULT_JETSTREAM_NAK_DELAY_SECS)),
        ),
        TransportConfig::Core => unreachable!("JetStream route required"),
    };

    let stream = jetstream
        .get_stream(&stream_name)
        .await
        .with_context(|| format!("failed to open JetStream stream {stream_name}"))?;
    let consumer = ensure_pull_consumer(
        &stream,
        route,
        &consumer_name,
        ack_wait_secs,
        max_ack_pending,
        max_deliver,
    )
    .await?;

    info!(
        route = route.label(),
        subject = route.subject.as_str(),
        stream = stream_name,
        consumer = consumer_name,
        mode = ?route.mode,
        "jetstream route ready"
    );

    loop {
        if *shutdown.borrow() {
            break;
        }

        let mut batch = consumer
            .fetch()
            .max_messages(fetch_batch)
            .expires(Duration::from_millis(DEFAULT_FETCH_EXPIRES_MS))
            .messages()
            .await
            .with_context(|| format!("failed to fetch JetStream batch for {}", route.label()))?;

        while let Some(message) = batch.next().await {
            if *shutdown.borrow() {
                break;
            }

            let message = message.map_err(|error| anyhow!(error)).with_context(|| {
                format!("failed to receive JetStream message for {}", route.label())
            })?;

            if let Err(error) =
                handle_jetstream_message(route, client, http_client, message, nak_delay).await
            {
                warn!(
                    route = route.label(),
                    error = %error,
                    "jetstream message handling failed"
                );
            }
        }
    }

    Ok(())
}

async fn handle_jetstream_message(
    route: &RouteConfig,
    client: &Client,
    http_client: &reqwest::Client,
    message: async_nats::jetstream::Message,
    nak_delay: Duration,
) -> Result<()> {
    let response_reply = resolve_jetstream_response_subject(&message);
    let inbound = InboundMessage::from_jetstream(&message);
    let response = match call_http(http_client, route, &inbound).await {
        Ok(response) => response,
        Err(error) => {
            ack_jetstream_failure(&message, jetstream_failure_ack_kind(None, nak_delay))
                .await
                .map_err(|ack_error| {
                    anyhow!("failed to NAK JetStream message after HTTP error: {ack_error}")
                })?;
            return Err(error);
        }
    };

    if !response.status.is_success() {
        let ack_kind = jetstream_failure_ack_kind(Some(response.status), nak_delay);
        let action = match &ack_kind {
            AckKind::Term => "terminated",
            AckKind::Nak(Some(_)) | AckKind::Nak(None) => "scheduled for retry",
            _ => "handled",
        };
        ack_jetstream_failure(&message, ack_kind)
            .await
            .map_err(|error| {
                anyhow!(
                    "failed to ACK failure state for {} after HTTP status {}: {error}",
                    route.label(),
                    response.status
                )
            })?;
        warn!(
            route = route.label(),
            subject = inbound.subject,
            status = %response.status,
            action,
            "jetstream route got non-success HTTP response"
        );
        return Ok(());
    }

    message.ack().await.map_err(|error| {
        anyhow!(
            "failed to ACK JetStream message for {}: {error}",
            route.label()
        )
    })?;

    if route.mode == BridgeMode::RequestResponse {
        if let Some(reply) = response_reply {
            publish_response(client, reply, response.body)
                .await
                .context("failed to publish JetStream request-response reply")?;
        } else {
            warn!(
                route = route.label(),
                subject = inbound.subject,
                "jetstream request-response route received a message without a reply subject"
            );
        }
    }

    Ok(())
}

async fn call_http(
    http_client: &reqwest::Client,
    route: &RouteConfig,
    inbound: &InboundMessage,
) -> Result<HttpResponseData> {
    let request = match route.http.method {
        HttpMethod::Get => http_client.get(&route.http.url),
        HttpMethod::Post => http_client
            .post(&route.http.url)
            .body(inbound.payload.clone()),
    };

    let response = request.send().await.with_context(|| {
        format!(
            "failed to call HTTP endpoint {} for route {}",
            route.http.url,
            route.label()
        )
    })?;
    let status = response.status();
    let body = response.bytes().await.with_context(|| {
        format!(
            "failed to read HTTP response body from {} for route {}",
            route.http.url,
            route.label()
        )
    })?;

    Ok(HttpResponseData { status, body })
}

async fn publish_response(client: &Client, reply: Subject, body: Bytes) -> Result<()> {
    client
        .publish(reply, body)
        .await
        .map_err(|error| anyhow!("failed to publish NATS reply: {error}"))
}

async fn ack_jetstream_failure(
    message: &async_nats::jetstream::Message,
    ack_kind: AckKind,
) -> Result<(), async_nats::Error> {
    message.ack_with(ack_kind).await
}

fn jetstream_failure_ack_kind(status: Option<reqwest::StatusCode>, nak_delay: Duration) -> AckKind {
    match status {
        None => AckKind::Nak(Some(nak_delay)),
        Some(status) if should_retry_http_status(status) => AckKind::Nak(Some(nak_delay)),
        Some(status) if status.is_client_error() => AckKind::Term,
        Some(_) => AckKind::Nak(Some(nak_delay)),
    }
}

fn should_retry_http_status(status: reqwest::StatusCode) -> bool {
    status == reqwest::StatusCode::REQUEST_TIMEOUT
        || status == reqwest::StatusCode::TOO_MANY_REQUESTS
        || status.is_server_error()
}

async fn ensure_pull_consumer(
    stream: &jetstream::stream::Stream,
    route: &RouteConfig,
    consumer_name: &str,
    ack_wait_secs: u64,
    max_ack_pending: i64,
    max_deliver: Option<i64>,
) -> Result<consumer::PullConsumer> {
    let desired_config = desired_pull_consumer_config(
        consumer_name,
        route.subject.clone(),
        ack_wait_secs,
        max_ack_pending,
        max_deliver,
    );

    if let Ok(existing) = stream
        .get_consumer::<consumer::pull::Config>(consumer_name)
        .await
    {
        match existing.get_info().await {
            Ok(info) => {
                let desired_consumer_config =
                    consumer::IntoConsumerConfig::into_consumer_config(desired_config.clone());
                let mismatches = pull_consumer_mismatches(&info.config, &desired_consumer_config);
                if !mismatches.is_empty() {
                    warn!(
                        route = route.label(),
                        consumer = consumer_name,
                        mismatches = %mismatches.join(", "),
                        "existing JetStream consumer config differs; updating in place"
                    );
                }
            }
            Err(error) => {
                warn!(
                    route = route.label(),
                    consumer = consumer_name,
                    error = %error,
                    "failed to inspect existing JetStream consumer before reconcile"
                );
            }
        }
    }

    stream
        .create_consumer(desired_config)
        .await
        .with_context(|| {
            format!(
                "failed to create or update JetStream consumer {consumer_name} for route {}",
                route.label()
            )
        })
}

fn desired_pull_consumer_config(
    consumer_name: &str,
    subject: String,
    ack_wait_secs: u64,
    max_ack_pending: i64,
    max_deliver: Option<i64>,
) -> consumer::pull::Config {
    consumer::pull::Config {
        durable_name: Some(consumer_name.to_owned()),
        filter_subject: subject,
        ack_policy: consumer::AckPolicy::Explicit,
        ack_wait: Duration::from_secs(ack_wait_secs),
        max_ack_pending,
        max_deliver: max_deliver.unwrap_or_default(),
        ..Default::default()
    }
}

fn pull_consumer_mismatches(
    existing: &consumer::Config,
    desired: &consumer::Config,
) -> Vec<String> {
    let mut mismatches = Vec::new();

    if existing.filter_subject != desired.filter_subject {
        mismatches.push(format!(
            "filter_subject {:?} -> {:?}",
            existing.filter_subject, desired.filter_subject
        ));
    }
    if existing.ack_policy != desired.ack_policy {
        mismatches.push(format!(
            "ack_policy {:?} -> {:?}",
            existing.ack_policy, desired.ack_policy
        ));
    }
    if existing.ack_wait != desired.ack_wait {
        mismatches.push(format!(
            "ack_wait {:?} -> {:?}",
            existing.ack_wait, desired.ack_wait
        ));
    }
    if existing.max_ack_pending != desired.max_ack_pending {
        mismatches.push(format!(
            "max_ack_pending {} -> {}",
            existing.max_ack_pending, desired.max_ack_pending
        ));
    }
    if existing.max_deliver != desired.max_deliver {
        mismatches.push(format!(
            "max_deliver {} -> {}",
            existing.max_deliver, desired.max_deliver
        ));
    }

    mismatches
}

fn default_consumer_name(route: &RouteConfig, stream: &str) -> String {
    let base = sanitize_consumer_component(route.label(), 24);
    let fingerprint_source = format!("{stream}:{}:{:?}", route.subject, route.mode);
    let mut hasher = DefaultHasher::new();
    fingerprint_source.hash(&mut hasher);
    let fingerprint = hasher.finish();
    format!("nats-http-bridge-{base}-{fingerprint:016x}")
}

fn sanitize_consumer_component(value: &str, max_len: usize) -> String {
    let mut sanitized = String::with_capacity(value.len());
    let mut previous_dash = false;

    for ch in value.chars() {
        let mapped = if ch.is_ascii_alphanumeric() {
            previous_dash = false;
            ch.to_ascii_lowercase()
        } else if previous_dash {
            continue;
        } else {
            previous_dash = true;
            '-'
        };
        sanitized.push(mapped);
        if sanitized.len() >= max_len {
            break;
        }
    }

    let trimmed = sanitized.trim_matches('-');
    if trimmed.is_empty() {
        "route".to_owned()
    } else {
        trimmed.to_owned()
    }
}

fn resolve_jetstream_response_subject(message: &async_nats::jetstream::Message) -> Option<Subject> {
    if let Some(headers) = message.headers.as_ref() {
        if let Some(reply) = headers.get(JETSTREAM_REPLY_SUBJECT_HEADER) {
            return Some(reply.as_str().into());
        }
    }

    message
        .reply
        .clone()
        .filter(|reply| !reply.as_str().starts_with("$JS.ACK."))
}

async fn wait_for_shutdown(shutdown: &mut watch::Receiver<bool>) {
    if *shutdown.borrow() {
        return;
    }
    let _ = shutdown.changed().await;
}

impl InboundMessage {
    fn from_core(message: async_nats::Message) -> Self {
        Self {
            subject: message.subject.to_string(),
            reply: message.reply,
            payload: message.payload,
        }
    }

    fn from_jetstream(message: &async_nats::jetstream::Message) -> Self {
        Self {
            subject: message.subject.to_string(),
            reply: message.reply.clone(),
            payload: message.payload.clone(),
        }
    }
}

#[cfg(test)]
mod tests;
