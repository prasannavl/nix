use super::*;
use async_nats::jetstream::stream::Config as StreamConfig;
use std::collections::HashMap;
use std::net::{SocketAddr, TcpListener as StdTcpListener};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::process::{Child, Command};
use tokio::sync::mpsc;
use tokio::time::{sleep, timeout};

const TEST_TIMEOUT: Duration = Duration::from_secs(10);
static TEST_ID_COUNTER: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, PartialEq, Eq)]
struct ObservedHttpRequest {
    method: String,
    path: String,
    body: Vec<u8>,
}

#[derive(Debug, Clone)]
struct HttpResponseSpec {
    status_code: u16,
    body: Vec<u8>,
}

struct TestHttpServer {
    addr: SocketAddr,
    requests_rx: mpsc::UnboundedReceiver<ObservedHttpRequest>,
    shutdown_tx: watch::Sender<bool>,
    task: tokio::task::JoinHandle<Result<()>>,
}

struct TestNatsServer {
    server_url: String,
    store_dir: PathBuf,
    child: Child,
}

struct TestBridgeHarness {
    shutdown_tx: watch::Sender<bool>,
    tasks: JoinSet<Result<()>>,
}

#[test]
fn config_defaults_to_core_push_and_post() {
    let config: Config = serde_yaml::from_str(
        r#"
        routes:
          - subject: demo.subject
            http:
              url: http://127.0.0.1:8080/demo
        "#,
    )
    .expect("config should parse");

    assert_eq!(config.routes.len(), 1);
    assert!(matches!(config.routes[0].mode, BridgeMode::Push));
    assert!(matches!(config.routes[0].transport, TransportConfig::Core));
    assert!(matches!(config.routes[0].http.method, HttpMethod::Post));
}

#[test]
fn config_parses_jetstream_request_response_route() {
    let config: Config = serde_yaml::from_str(
        r#"
        routes:
          - name: orders
            subject: orders.lookup
            mode: request-response
            http:
              url: http://127.0.0.1:8080/orders/lookup
              method: post
            transport:
              kind: jetstream
              stream: orders
              consumer: orders-http-bridge
              ack_wait_secs: 45
              max_ack_pending: 2
              max_deliver: 5
              fetch_batch: 2
              nak_delay_secs: 20
        "#,
    )
    .expect("config should parse");

    let route = &config.routes[0];
    assert!(matches!(route.mode, BridgeMode::RequestResponse));
    match &route.transport {
        TransportConfig::Jetstream {
            stream,
            consumer,
            ack_wait_secs,
            max_ack_pending,
            max_deliver,
            fetch_batch,
            nak_delay_secs,
        } => {
            assert_eq!(stream, "orders");
            assert_eq!(consumer.as_deref(), Some("orders-http-bridge"));
            assert_eq!(*ack_wait_secs, Some(45));
            assert_eq!(*max_ack_pending, Some(2));
            assert_eq!(*max_deliver, Some(5));
            assert_eq!(*fetch_batch, Some(2));
            assert_eq!(*nak_delay_secs, Some(20));
        }
        TransportConfig::Core => panic!("expected JetStream transport"),
    }
}

#[test]
fn consumer_name_is_stable_and_sanitized() {
    let route = RouteConfig {
        name: Some("Orders Lookup / v1".to_owned()),
        subject: "orders.lookup".to_owned(),
        mode: BridgeMode::RequestResponse,
        transport: TransportConfig::Core,
        http: HttpConfig {
            url: "http://127.0.0.1:8080/orders/lookup".to_owned(),
            method: HttpMethod::Post,
        },
    };

    let first = default_consumer_name(&route, "orders");
    let second = default_consumer_name(&route, "orders");

    assert_eq!(first, second);
    assert!(first.starts_with("nats-http-bridge-orders-lookup-v1-"));
}

#[test]
fn network_errors_use_delayed_nak() {
    let retry_delay = Duration::from_secs(30);

    assert!(matches!(
        jetstream_failure_ack_kind(None, retry_delay),
        AckKind::Nak(Some(delay)) if delay == retry_delay
    ));
}

#[test]
fn config_rejects_invalid_http_url() {
    let config: Config = serde_yaml::from_str(
        r#"
        routes:
          - subject: demo.subject
            http:
              url: nats://127.0.0.1/demo
        "#,
    )
    .expect("config should parse");

    let error = config
        .validate()
        .expect_err("non-HTTP endpoint URL should be rejected");
    assert!(error
        .to_string()
        .contains("http.url must use http or https"));
}

#[test]
fn timeout_and_429_statuses_use_delayed_nak() {
    let retry_delay = Duration::from_secs(30);

    assert!(matches!(
        jetstream_failure_ack_kind(Some(reqwest::StatusCode::REQUEST_TIMEOUT), retry_delay),
        AckKind::Nak(Some(delay)) if delay == retry_delay
    ));
    assert!(matches!(
        jetstream_failure_ack_kind(Some(reqwest::StatusCode::TOO_MANY_REQUESTS), retry_delay),
        AckKind::Nak(Some(delay)) if delay == retry_delay
    ));
}

#[test]
fn server_errors_use_delayed_nak() {
    let retry_delay = Duration::from_secs(30);

    assert!(matches!(
        jetstream_failure_ack_kind(Some(reqwest::StatusCode::INTERNAL_SERVER_ERROR), retry_delay),
        AckKind::Nak(Some(delay)) if delay == retry_delay
    ));
    assert!(matches!(
        jetstream_failure_ack_kind(Some(reqwest::StatusCode::BAD_GATEWAY), retry_delay),
        AckKind::Nak(Some(delay)) if delay == retry_delay
    ));
}

#[test]
fn poison_400_404_and_422_statuses_terminate() {
    let retry_delay = Duration::from_secs(30);

    assert!(matches!(
        jetstream_failure_ack_kind(Some(reqwest::StatusCode::BAD_REQUEST), retry_delay),
        AckKind::Term
    ));
    assert!(matches!(
        jetstream_failure_ack_kind(Some(reqwest::StatusCode::NOT_FOUND), retry_delay),
        AckKind::Term
    ));
    assert!(matches!(
        jetstream_failure_ack_kind(Some(reqwest::StatusCode::UNPROCESSABLE_ENTITY), retry_delay),
        AckKind::Term
    ));
}

#[test]
fn pull_consumer_mismatch_details_include_changed_fields() {
    let mut existing = consumer::IntoConsumerConfig::into_consumer_config(
        desired_pull_consumer_config("bridge", "orders.old".to_owned(), 30, 8, Some(0)),
    );
    existing.ack_policy = consumer::AckPolicy::None;
    let desired = consumer::IntoConsumerConfig::into_consumer_config(desired_pull_consumer_config(
        "bridge",
        "orders.new".to_owned(),
        120,
        1,
        Some(5),
    ));

    let mismatches = pull_consumer_mismatches(&existing, &desired);

    assert!(mismatches
        .iter()
        .any(|mismatch| mismatch.contains("filter_subject")));
    assert!(mismatches
        .iter()
        .any(|mismatch| mismatch.contains("ack_policy")));
    assert!(mismatches
        .iter()
        .any(|mismatch| mismatch.contains("ack_wait")));
    assert!(mismatches
        .iter()
        .any(|mismatch| mismatch.contains("max_ack_pending")));
    assert!(mismatches
        .iter()
        .any(|mismatch| mismatch.contains("max_deliver")));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn five_distinct_routes_forward_to_the_correct_http_endpoints() -> Result<()> {
    let nats_server = TestNatsServer::start(true).await?;
    let mut http_server = TestHttpServer::start(HashMap::from([
        (
            "/route-one".to_owned(),
            HttpResponseSpec::ok("route-one-response"),
        ),
        (
            "/route-two".to_owned(),
            HttpResponseSpec::ok("route-two-response"),
        ),
        (
            "/route-three".to_owned(),
            HttpResponseSpec::ok("route-three-response"),
        ),
        (
            "/route-four".to_owned(),
            HttpResponseSpec::ok("route-four-response"),
        ),
        (
            "/route-five".to_owned(),
            HttpResponseSpec::ok("route-five-response"),
        ),
    ]))
    .await?;

    let routes = vec![
        core_route(
            "route-one",
            "tests.routes.one",
            BridgeMode::Push,
            HttpMethod::Post,
            http_server.url("/route-one"),
        ),
        core_route(
            "route-two",
            "tests.routes.two",
            BridgeMode::Push,
            HttpMethod::Get,
            http_server.url("/route-two"),
        ),
        core_route(
            "route-three",
            "tests.routes.three",
            BridgeMode::Push,
            HttpMethod::Post,
            http_server.url("/route-three"),
        ),
        core_route(
            "route-four",
            "tests.routes.four",
            BridgeMode::Push,
            HttpMethod::Post,
            http_server.url("/route-four"),
        ),
        core_route(
            "route-five",
            "tests.routes.five",
            BridgeMode::Push,
            HttpMethod::Get,
            http_server.url("/route-five"),
        ),
    ];

    let bridge = TestBridgeHarness::start(routes, &nats_server.server_url).await?;
    let publisher = async_nats::connect(&nats_server.server_url)
        .await
        .context("failed to connect test publisher")?;

    publisher
        .publish("tests.routes.one", Bytes::from_static(b"alpha"))
        .await
        .context("failed to publish route one")?;
    publisher
        .publish("tests.routes.two", Bytes::from_static(b"ignored get body"))
        .await
        .context("failed to publish route two")?;
    publisher
        .publish("tests.routes.three", Bytes::new())
        .await
        .context("failed to publish route three")?;
    publisher
        .publish(
            "tests.routes.four",
            Bytes::from_static(br#"{"kind":"json","count":4}"#),
        )
        .await
        .context("failed to publish route four")?;
    publisher
        .publish("tests.routes.five", Bytes::new())
        .await
        .context("failed to publish route five")?;
    publisher
        .flush()
        .await
        .context("failed to flush publisher")?;

    let requests = http_server
        .recv_requests(5)
        .await
        .context("failed to collect forwarded requests")?;
    let request_map = request_map_by_path(requests);

    assert_request(
        request_map.get("/route-one"),
        "POST",
        "/route-one",
        b"alpha",
    );
    assert_request(request_map.get("/route-two"), "GET", "/route-two", b"");
    assert_request(request_map.get("/route-three"), "POST", "/route-three", b"");
    assert_request(
        request_map.get("/route-four"),
        "POST",
        "/route-four",
        br#"{"kind":"json","count":4}"#,
    );
    assert_request(request_map.get("/route-five"), "GET", "/route-five", b"");

    bridge.shutdown().await?;
    http_server.shutdown().await?;
    nats_server.shutdown().await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn core_and_jetstream_modes_cover_push_and_request_response_for_get_and_post() -> Result<()> {
    let nats_server = TestNatsServer::start(true).await?;
    let mut http_server = TestHttpServer::start(HashMap::from([
        (
            "/core/push/get".to_owned(),
            HttpResponseSpec::ok("core-push-get"),
        ),
        (
            "/core/push/post".to_owned(),
            HttpResponseSpec::ok("core-push-post"),
        ),
        (
            "/core/request/get".to_owned(),
            HttpResponseSpec::ok("core-request-get-reply"),
        ),
        (
            "/core/request/post".to_owned(),
            HttpResponseSpec::ok("core-request-post-reply"),
        ),
        (
            "/js/push/get".to_owned(),
            HttpResponseSpec::ok("js-push-get"),
        ),
        (
            "/js/push/post".to_owned(),
            HttpResponseSpec::ok("js-push-post"),
        ),
        (
            "/js/request/get".to_owned(),
            HttpResponseSpec::ok("js-request-get-reply"),
        ),
        (
            "/js/request/post".to_owned(),
            HttpResponseSpec::ok("js-request-post-reply"),
        ),
    ]))
    .await?;

    let setup_client = async_nats::connect(&nats_server.server_url)
        .await
        .context("failed to connect setup client")?;
    let jetstream = jetstream::new(setup_client);
    let stream_name = unique_test_name("bridge-matrix-stream");
    jetstream
        .get_or_create_stream(StreamConfig {
            name: stream_name.clone(),
            subjects: vec!["tests.matrix.js.>".into()],
            ..Default::default()
        })
        .await
        .context("failed to create test JetStream stream")?;

    let routes = vec![
        core_route(
            "core-push-get",
            "tests.matrix.core.push.get",
            BridgeMode::Push,
            HttpMethod::Get,
            http_server.url("/core/push/get"),
        ),
        core_route(
            "core-push-post",
            "tests.matrix.core.push.post",
            BridgeMode::Push,
            HttpMethod::Post,
            http_server.url("/core/push/post"),
        ),
        core_route(
            "core-request-get",
            "tests.matrix.core.request.get",
            BridgeMode::RequestResponse,
            HttpMethod::Get,
            http_server.url("/core/request/get"),
        ),
        core_route(
            "core-request-post",
            "tests.matrix.core.request.post",
            BridgeMode::RequestResponse,
            HttpMethod::Post,
            http_server.url("/core/request/post"),
        ),
        jetstream_route(
            "js-push-get",
            "tests.matrix.js.push.get",
            BridgeMode::Push,
            HttpMethod::Get,
            http_server.url("/js/push/get"),
            &stream_name,
        ),
        jetstream_route(
            "js-push-post",
            "tests.matrix.js.push.post",
            BridgeMode::Push,
            HttpMethod::Post,
            http_server.url("/js/push/post"),
            &stream_name,
        ),
        jetstream_route(
            "js-request-get",
            "tests.matrix.js.request.get",
            BridgeMode::RequestResponse,
            HttpMethod::Get,
            http_server.url("/js/request/get"),
            &stream_name,
        ),
        jetstream_route(
            "js-request-post",
            "tests.matrix.js.request.post",
            BridgeMode::RequestResponse,
            HttpMethod::Post,
            http_server.url("/js/request/post"),
            &stream_name,
        ),
    ];

    let bridge = TestBridgeHarness::start(routes, &nats_server.server_url).await?;
    let client = async_nats::connect(&nats_server.server_url)
        .await
        .context("failed to connect publisher client")?;

    client
        .publish(
            "tests.matrix.core.push.get",
            Bytes::from_static(b"ignored core push get"),
        )
        .await
        .context("failed to publish core push get")?;
    client
        .publish(
            "tests.matrix.core.push.post",
            Bytes::from_static(b"core-push-post-body"),
        )
        .await
        .context("failed to publish core push post")?;
    client
        .publish(
            "tests.matrix.js.push.get",
            Bytes::from_static(b"ignored js push get"),
        )
        .await
        .context("failed to publish js push get")?;
    client
        .publish(
            "tests.matrix.js.push.post",
            Bytes::from_static(b"js-push-post-body"),
        )
        .await
        .context("failed to publish js push post")?;
    client
        .flush()
        .await
        .context("failed to flush push messages")?;

    let core_request_get = client
        .request(
            "tests.matrix.core.request.get",
            Bytes::from_static(b"core get ignored"),
        )
        .await
        .context("failed to request core get route")?;
    let core_request_post = client
        .request(
            "tests.matrix.core.request.post",
            Bytes::from_static(b"core-request-post-body"),
        )
        .await
        .context("failed to request core post route")?;
    let js_request_get = request_via_jetstream_reply_subject(
        &client,
        "tests.matrix.js.request.get",
        Bytes::from_static(b"js get ignored"),
    )
    .await
    .context("failed to request js get route")?;
    let js_request_post = request_via_jetstream_reply_subject(
        &client,
        "tests.matrix.js.request.post",
        Bytes::from_static(b"js-request-post-body"),
    )
    .await
    .context("failed to request js post route")?;

    assert_eq!(core_request_get.payload.as_ref(), b"core-request-get-reply");
    assert_eq!(
        core_request_post.payload.as_ref(),
        b"core-request-post-reply"
    );
    assert_eq!(js_request_get.payload.as_ref(), b"js-request-get-reply");
    assert_eq!(js_request_post.payload.as_ref(), b"js-request-post-reply");

    let requests = http_server
        .recv_requests(8)
        .await
        .context("failed to collect mode-matrix requests")?;
    let request_map = request_map_by_path(requests);

    assert_request(
        request_map.get("/core/push/get"),
        "GET",
        "/core/push/get",
        b"",
    );
    assert_request(
        request_map.get("/core/push/post"),
        "POST",
        "/core/push/post",
        b"core-push-post-body",
    );
    assert_request(
        request_map.get("/core/request/get"),
        "GET",
        "/core/request/get",
        b"",
    );
    assert_request(
        request_map.get("/core/request/post"),
        "POST",
        "/core/request/post",
        b"core-request-post-body",
    );
    assert_request(request_map.get("/js/push/get"), "GET", "/js/push/get", b"");
    assert_request(
        request_map.get("/js/push/post"),
        "POST",
        "/js/push/post",
        b"js-push-post-body",
    );
    assert_request(
        request_map.get("/js/request/get"),
        "GET",
        "/js/request/get",
        b"",
    );
    assert_request(
        request_map.get("/js/request/post"),
        "POST",
        "/js/request/post",
        b"js-request-post-body",
    );

    bridge.shutdown().await?;
    http_server.shutdown().await?;
    nats_server.shutdown().await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ensure_pull_consumer_reconciles_existing_consumer_config() -> Result<()> {
    let nats_server = TestNatsServer::start(true).await?;
    let setup_client = async_nats::connect(&nats_server.server_url)
        .await
        .context("failed to connect setup client")?;
    let jetstream = jetstream::new(setup_client);

    let stream_name = unique_test_name("consumer-reconcile-stream");
    let consumer_name = unique_test_name("consumer-reconcile");
    let subject = "tests.reconcile.consumer";
    let stream = jetstream
        .get_or_create_stream(StreamConfig {
            name: stream_name.clone(),
            subjects: vec![subject.into()],
            ..Default::default()
        })
        .await
        .context("failed to create reconcile test stream")?;

    stream
        .create_consumer(consumer::pull::Config {
            durable_name: Some(consumer_name.clone()),
            filter_subject: subject.to_owned(),
            ack_policy: consumer::AckPolicy::Explicit,
            ack_wait: Duration::from_secs(30),
            max_ack_pending: 8,
            max_deliver: 0,
            ..Default::default()
        })
        .await
        .context("failed to seed stale JetStream consumer")?;

    let route = RouteConfig {
        name: Some("consumer-reconcile".to_owned()),
        subject: subject.to_owned(),
        mode: BridgeMode::Push,
        transport: TransportConfig::Jetstream {
            stream: stream_name,
            consumer: Some(consumer_name.clone()),
            ack_wait_secs: Some(120),
            max_ack_pending: Some(1),
            max_deliver: Some(5),
            fetch_batch: Some(1),
            nak_delay_secs: Some(30),
        },
        http: HttpConfig {
            url: "http://127.0.0.1:1/unused".to_owned(),
            method: HttpMethod::Post,
        },
    };

    let consumer = ensure_pull_consumer(&stream, &route, &consumer_name, 120, 1, Some(5))
        .await
        .context("failed to reconcile existing JetStream consumer")?;
    let info = consumer
        .get_info()
        .await
        .context("failed to inspect reconciled JetStream consumer")?;

    assert_eq!(info.config.filter_subject, subject);
    assert_eq!(info.config.ack_policy, consumer::AckPolicy::Explicit);
    assert_eq!(info.config.ack_wait, Duration::from_secs(120));
    assert_eq!(info.config.max_ack_pending, 1);
    assert_eq!(info.config.max_deliver, 5);

    nats_server.shutdown().await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn connect_nats_retries_until_server_is_available() -> Result<()> {
    let port = reserve_port()?;
    let server = format!("nats://127.0.0.1:{port}");
    let cli = Cli {
        config: PathBuf::from("/tmp/unused-config.yaml"),
        server,
        tls: None,
        ca_cert: None,
        client_cert: None,
        client_key: None,
        http_timeout_secs: DEFAULT_HTTP_TIMEOUT_SECS,
        log_filter: "warn".to_owned(),
        check_config: false,
    };

    let connect_task = tokio::spawn(async move { connect_nats(&cli).await });

    sleep(Duration::from_millis(250)).await;
    assert!(!connect_task.is_finished());

    let nats_server = TestNatsServer::start_on_port(port, false).await?;

    let client = timeout(TEST_TIMEOUT, connect_task)
        .await
        .context("timed out waiting for connect_nats retry loop to succeed")?
        .map_err(|error| anyhow!("connect_nats task join failure: {error}"))??;
    client
        .flush()
        .await
        .context("connected client failed to flush after retry")?;

    nats_server.shutdown().await?;
    Ok(())
}

impl HttpResponseSpec {
    fn ok(body: &str) -> Self {
        Self {
            status_code: 200,
            body: body.as_bytes().to_vec(),
        }
    }
}

impl TestHttpServer {
    async fn start(responses: HashMap<String, HttpResponseSpec>) -> Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .context("failed to bind test HTTP listener")?;
        let addr = listener
            .local_addr()
            .context("failed to get test HTTP listener address")?;
        let responses = Arc::new(responses);
        let (requests_tx, requests_rx) = mpsc::unbounded_channel();
        let (shutdown_tx, mut shutdown_rx) = watch::channel(false);

        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = shutdown_rx.changed() => {
                        if *shutdown_rx.borrow() {
                            break;
                        }
                    }
                    accepted = listener.accept() => {
                        let (mut stream, _) = accepted.context("failed to accept test HTTP connection")?;
                        let request_tx = requests_tx.clone();
                        let response_map = responses.clone();
                        tokio::spawn(async move {
                            if let Err(error) =
                                handle_test_http_connection(&mut stream, request_tx, response_map).await
                            {
                                warn!(error = %error, "test HTTP connection failed");
                            }
                        });
                    }
                }
            }

            Ok(())
        });

        Ok(Self {
            addr,
            requests_rx,
            shutdown_tx,
            task,
        })
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{}", self.addr, path)
    }

    async fn recv_requests(&mut self, expected: usize) -> Result<Vec<ObservedHttpRequest>> {
        let mut requests = Vec::with_capacity(expected);
        while requests.len() < expected {
            let request = timeout(TEST_TIMEOUT, self.requests_rx.recv())
                .await
                .context("timed out waiting for HTTP request")?
                .context("test HTTP server closed before receiving enough requests")?;
            requests.push(request);
        }
        Ok(requests)
    }

    async fn shutdown(self) -> Result<()> {
        let _ = self.shutdown_tx.send(true);
        timeout(TEST_TIMEOUT, async {
            self.task
                .await
                .map_err(|error| anyhow!("test HTTP server task join failure: {error}"))?
        })
        .await
        .context("timed out shutting down test HTTP server")??;
        Ok(())
    }
}

impl TestNatsServer {
    async fn start(enable_jetstream: bool) -> Result<Self> {
        let port = reserve_port()?;
        Self::start_on_port(port, enable_jetstream).await
    }

    async fn start_on_port(port: u16, enable_jetstream: bool) -> Result<Self> {
        let store_dir = std::env::temp_dir().join(unique_test_name("nats-http-bridge-js"));
        fs::create_dir_all(&store_dir).with_context(|| {
            format!(
                "failed to create temporary NATS store {}",
                store_dir.display()
            )
        })?;

        let mut command = Command::new(nats_server_bin());
        command
            .arg("-a")
            .arg("127.0.0.1")
            .arg("-p")
            .arg(port.to_string())
            .stdout(Stdio::null())
            .stderr(Stdio::null());

        if enable_jetstream {
            command.arg("-js").arg("-sd").arg(&store_dir);
        }

        let child = command.spawn().context("failed to start nats-server")?;
        let server_url = format!("nats://127.0.0.1:{port}");
        let mut server = Self {
            server_url,
            store_dir,
            child,
        };

        server.wait_until_ready().await?;
        Ok(server)
    }

    async fn wait_until_ready(&mut self) -> Result<()> {
        let deadline = tokio::time::Instant::now() + TEST_TIMEOUT;
        loop {
            if let Some(status) = self
                .child
                .try_wait()
                .context("failed to poll nats-server")?
            {
                bail!("nats-server exited early with status {status}");
            }

            match async_nats::connect(&self.server_url).await {
                Ok(client) => {
                    client
                        .flush()
                        .await
                        .context("failed to flush test NATS connection")?;
                    return Ok(());
                }
                Err(error) => {
                    if tokio::time::Instant::now() >= deadline {
                        return Err(error).context("timed out waiting for nats-server");
                    }
                }
            }

            sleep(Duration::from_millis(50)).await;
        }
    }

    async fn shutdown(mut self) -> Result<()> {
        let _ = self.child.start_kill();
        let _ = timeout(TEST_TIMEOUT, self.child.wait())
            .await
            .context("timed out waiting for nats-server shutdown")?;
        let _ = fs::remove_dir_all(&self.store_dir);
        Ok(())
    }
}

impl Drop for TestNatsServer {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
        let _ = fs::remove_dir_all(&self.store_dir);
    }
}

impl TestBridgeHarness {
    async fn start(routes: Vec<RouteConfig>, server: &str) -> Result<Self> {
        let client = async_nats::connect(server)
            .await
            .with_context(|| format!("failed to connect bridge client to {server}"))?;
        let http_client = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .context("failed to build test HTTP client")?;
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let mut tasks = JoinSet::new();

        for route in routes {
            let client = client.clone();
            let http_client = http_client.clone();
            let shutdown_rx = shutdown_rx.clone();
            tasks.spawn(async move { run_route(route, client, http_client, shutdown_rx).await });
        }

        sleep(Duration::from_millis(250)).await;

        Ok(Self { shutdown_tx, tasks })
    }

    async fn shutdown(mut self) -> Result<()> {
        let _ = self.shutdown_tx.send(true);

        while let Some(joined) = timeout(TEST_TIMEOUT, self.tasks.join_next())
            .await
            .context("timed out waiting for bridge tasks to stop")?
        {
            let task_result =
                joined.map_err(|error| anyhow!("bridge task join failure: {error}"))?;
            task_result?;
        }

        Ok(())
    }
}

async fn handle_test_http_connection(
    stream: &mut tokio::net::TcpStream,
    requests_tx: mpsc::UnboundedSender<ObservedHttpRequest>,
    responses: Arc<HashMap<String, HttpResponseSpec>>,
) -> Result<()> {
    let request = read_test_http_request(stream).await?;
    let response = responses
        .get(&request.path)
        .cloned()
        .unwrap_or(HttpResponseSpec {
            status_code: 404,
            body: b"missing".to_vec(),
        });

    requests_tx
        .send(request.clone())
        .map_err(|_| anyhow!("failed to queue observed HTTP request"))?;

    let status_text = reason_phrase(response.status_code);
    let mut response_bytes = format!(
        "HTTP/1.1 {} {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        response.status_code,
        status_text,
        response.body.len()
    )
    .into_bytes();
    response_bytes.extend_from_slice(&response.body);
    stream
        .write_all(&response_bytes)
        .await
        .context("failed to write test HTTP response")?;
    stream
        .shutdown()
        .await
        .context("failed to close HTTP stream")?;

    Ok(())
}

async fn read_test_http_request(stream: &mut tokio::net::TcpStream) -> Result<ObservedHttpRequest> {
    let mut buffer = Vec::new();
    let header_end = loop {
        if let Some(position) = find_header_end(&buffer) {
            break position;
        }

        let mut chunk = [0_u8; 1024];
        let read = stream
            .read(&mut chunk)
            .await
            .context("failed to read HTTP request bytes")?;
        if read == 0 {
            bail!("HTTP client closed before sending a full request");
        }
        buffer.extend_from_slice(&chunk[..read]);
    };

    let header_text = std::str::from_utf8(&buffer[..header_end])
        .context("failed to decode HTTP request headers")?;
    let mut lines = header_text.split("\r\n");
    let request_line = lines.next().context("missing HTTP request line")?;
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts
        .next()
        .context("missing HTTP method")?
        .to_owned();
    let path = request_parts
        .next()
        .context("missing HTTP path")?
        .to_owned();

    let mut content_length = 0_usize;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        if name.trim().eq_ignore_ascii_case("content-length") {
            content_length = value
                .trim()
                .parse::<usize>()
                .context("invalid content-length")?;
        }
    }

    let body_start = header_end + 4;
    let mut body = buffer[body_start..].to_vec();
    while body.len() < content_length {
        let mut chunk = vec![0_u8; content_length - body.len()];
        let read = stream
            .read(&mut chunk)
            .await
            .context("failed to read HTTP request body")?;
        if read == 0 {
            bail!("HTTP client closed before request body was complete");
        }
        body.extend_from_slice(&chunk[..read]);
    }
    body.truncate(content_length);

    Ok(ObservedHttpRequest { method, path, body })
}

fn find_header_end(buffer: &[u8]) -> Option<usize> {
    buffer.windows(4).position(|window| window == b"\r\n\r\n")
}

fn reason_phrase(status_code: u16) -> &'static str {
    match status_code {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        _ => "OK",
    }
}

fn request_map_by_path(requests: Vec<ObservedHttpRequest>) -> HashMap<String, ObservedHttpRequest> {
    requests
        .into_iter()
        .map(|request| (request.path.clone(), request))
        .collect()
}

fn assert_request(
    request: Option<&ObservedHttpRequest>,
    expected_method: &str,
    expected_path: &str,
    expected_body: &[u8],
) {
    let request = request.unwrap_or_else(|| panic!("missing request for {expected_path}"));
    assert_eq!(request.method, expected_method);
    assert_eq!(request.path, expected_path);
    assert_eq!(request.body, expected_body);
}

fn core_route(
    name: &str,
    subject: &str,
    mode: BridgeMode,
    method: HttpMethod,
    url: String,
) -> RouteConfig {
    RouteConfig {
        name: Some(name.to_owned()),
        subject: subject.to_owned(),
        mode,
        transport: TransportConfig::Core,
        http: HttpConfig { url, method },
    }
}

fn jetstream_route(
    name: &str,
    subject: &str,
    mode: BridgeMode,
    method: HttpMethod,
    url: String,
    stream: &str,
) -> RouteConfig {
    RouteConfig {
        name: Some(name.to_owned()),
        subject: subject.to_owned(),
        mode,
        transport: TransportConfig::Jetstream {
            stream: stream.to_owned(),
            consumer: Some(unique_test_name(&format!("{name}-consumer"))),
            ack_wait_secs: Some(5),
            max_ack_pending: Some(4),
            max_deliver: Some(3),
            fetch_batch: Some(1),
            nak_delay_secs: Some(2),
        },
        http: HttpConfig { url, method },
    }
}

fn unique_test_name(prefix: &str) -> String {
    let counter = TEST_ID_COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock must be after unix epoch")
        .as_nanos();
    format!("{prefix}-{}-{counter}", nanos)
}

fn reserve_port() -> Result<u16> {
    let listener =
        StdTcpListener::bind("127.0.0.1:0").context("failed to reserve local test TCP port")?;
    let port = listener
        .local_addr()
        .context("failed to inspect reserved local port")?
        .port();
    drop(listener);
    Ok(port)
}

fn nats_server_bin() -> String {
    std::env::var("NATS_SERVER_BIN").unwrap_or_else(|_| "nats-server".to_owned())
}

async fn request_via_jetstream_reply_subject(
    client: &Client,
    subject: &str,
    payload: Bytes,
) -> Result<async_nats::Message> {
    let reply_subject = unique_test_name("_INBOX.tests.nats-http-bridge");
    let mut headers = async_nats::HeaderMap::new();
    headers.insert(JETSTREAM_REPLY_SUBJECT_HEADER, reply_subject.as_str());
    let mut subscriber = client
        .subscribe(reply_subject.clone())
        .await
        .with_context(|| format!("failed to subscribe to test reply subject {reply_subject}"))?;

    client
        .publish_with_reply_and_headers(subject.to_owned(), reply_subject, headers, payload)
        .await
        .with_context(|| format!("failed to publish test message to {subject}"))?;
    client
        .flush()
        .await
        .context("failed to flush JetStream request message")?;

    loop {
        let message = timeout(TEST_TIMEOUT, subscriber.next())
            .await
            .context("timed out waiting for JetStream request reply")?
            .context("reply subscriber closed before receiving JetStream reply")?;

        if is_jetstream_publish_ack(&message.payload) {
            continue;
        }

        return Ok(message);
    }
}

fn is_jetstream_publish_ack(payload: &[u8]) -> bool {
    let Ok(text) = std::str::from_utf8(payload) else {
        return false;
    };

    text.starts_with('{') && text.contains("\"stream\"") && text.contains("\"seq\"")
}
