use anyhow::{bail, Context, Result};
use async_nats::header::{HeaderMap, NATS_MESSAGE_ID};
use async_nats::jetstream;
use async_nats::jetstream::consumer;
use async_nats::jetstream::stream::{Config as StreamConfig, RetentionPolicy, StorageType};
use async_nats::jetstream::AckKind;
use async_nats::{Client, Event, Subject, Subscriber};
use bytes::Bytes;
use clap::{ArgAction, Args, Parser, ValueEnum};
use futures_util::StreamExt;
use rand::rngs::StdRng;
use rand::{rng, Rng, SeedableRng};
use std::fs;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::time::{sleep, timeout};
use tracing::{info, warn};

const PAYLOAD_HEADER_BYTES: usize = 16;
const DEFAULT_SUBJECT: &str = "test.nats_wrecking_ball";
const DEFAULT_STREAM_NAME: &str = "wrecking_ball";
const DEFAULT_CONSUMER_NAME: &str = "wrecking_ball_workers";
const DEFAULT_QUEUE_GROUP: &str = "wrecking_ball";
const GAP3_PROFILE_CLIENT_CERT_PATH: &str =
    concat!("/run/agenix/nats-wrecking-ball.", "z.gap3.ai", ".crt");
const GAP3_PROFILE_CLIENT_KEY_PATH: &str =
    concat!("/run/agenix/nats-wrecking-ball.", "z.gap3.ai", ".key");
const SIZE_BUCKETS: [usize; 8] = [256, 1024, 4096, 16384, 65536, 262144, 1048576, usize::MAX];
const LATENCY_BUCKETS_NS: [u64; 8] = [
    1_000_000,
    5_000_000,
    10_000_000,
    50_000_000,
    100_000_000,
    500_000_000,
    1_000_000_000,
    u64::MAX,
];

static PROCESS_SHUTDOWN: OnceLock<ProcessShutdownSignal> = OnceLock::new();

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum TestMode {
    #[value(name = "fanout")]
    Fanout,
    #[value(name = "queue")]
    Queue,
    #[value(name = "req-reply")]
    ReqReply,
    #[value(name = "js-queue-strict")]
    JetstreamQueueStrict,
    #[value(name = "js-queue-concurrent")]
    JetstreamQueueConcurrent,
    #[value(name = "js-queue-strict-exactly-once")]
    JetstreamQueueStrictExactlyOnce,
    #[value(name = "js-queue-concurrent-exactly-once")]
    JetstreamQueueConcurrentExactlyOnce,
    #[value(name = "js-replay")]
    JetstreamReplay,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum ConnectProfile {
    Generic,
    Gap3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum JetstreamAckMode {
    Ack,
    Confirmed,
    None,
}

#[derive(Debug, Clone, Parser)]
pub struct ProducerCli {
    #[command(flatten)]
    pub common: CommonArgs,
    #[command(flatten)]
    pub test: ProducerArgs,
}

#[derive(Debug, Clone, Parser)]
pub struct ConsumerCli {
    #[command(flatten)]
    pub common: CommonArgs,
    #[command(flatten)]
    pub test: ConsumerArgs,
}

#[derive(Debug, Clone, Parser)]
pub struct OrchestratorCli {
    #[command(flatten)]
    pub common: CommonArgs,
    #[arg(long, value_enum, default_value = "generic")]
    pub profile: ConnectProfile,
    #[arg(long, value_enum, default_value = "fanout")]
    pub mode: TestMode,
    #[command(flatten)]
    pub connect: ConnectArgs,
    #[arg(long, default_value = DEFAULT_SUBJECT)]
    pub subject: String,
    #[arg(long, default_value = DEFAULT_STREAM_NAME)]
    pub stream: String,
    #[arg(long, default_value = DEFAULT_CONSUMER_NAME)]
    pub consumer: String,
    #[arg(long)]
    pub queue_group: Option<String>,
    #[arg(long, default_value_t = false, action = ArgAction::SetTrue)]
    pub recreate: bool,
    #[arg(long, default_value_t = 1)]
    pub producers: usize,
    #[arg(long, default_value_t = 1)]
    pub consumers: usize,
    #[arg(long, default_value_t = 2_000)]
    pub drain_ms: u64,
    #[arg(long)]
    pub producer_rate: Option<u64>,
    #[arg(long)]
    pub producer_count: Option<u64>,
    #[arg(long, value_parser = parse_duration)]
    pub producer_duration: Option<Duration>,
    #[arg(long, default_value_t = 1_024)]
    pub avg_payload_bytes: usize,
    #[arg(long, default_value_t = 1_000)]
    pub request_timeout_ms: u64,
    #[arg(long)]
    pub consumer_rate: Option<u64>,
    #[arg(long)]
    pub consumer_count: Option<u64>,
    #[arg(long, value_parser = parse_duration)]
    pub consumer_duration: Option<Duration>,
    #[arg(long, value_parser = parse_duration)]
    pub processing_delay: Option<Duration>,
    #[arg(
        long,
        visible_alias = "js-ack-mode",
        value_enum,
        default_value = "confirmed"
    )]
    pub jetstream_ack_mode: JetstreamAckMode,
    #[arg(
        long,
        visible_alias = "js-max-ack-pending",
        value_parser = clap::value_parser!(i64).range(1..)
    )]
    pub jetstream_max_ack_pending: Option<i64>,
    #[arg(long, visible_alias = "js-pull-batch")]
    pub jetstream_pull_batch: Option<usize>,
}

#[derive(Debug, Clone, Args)]
pub struct ProducerArgs {
    #[arg(long, value_enum, default_value = "generic")]
    pub profile: ConnectProfile,
    #[arg(long, value_enum, default_value = "fanout")]
    pub mode: TestMode,
    #[command(flatten)]
    pub connect: ConnectArgs,
    #[arg(long, default_value = DEFAULT_SUBJECT)]
    pub subject: String,
    #[arg(long)]
    pub rate: Option<u64>,
    #[arg(long)]
    pub count: Option<u64>,
    #[arg(long, value_parser = parse_duration)]
    pub duration: Option<Duration>,
    #[arg(long, default_value_t = 1_024)]
    pub avg_payload_bytes: usize,
    #[arg(long, default_value_t = 1_000)]
    pub request_timeout_ms: u64,
    #[arg(long, default_value_t = false, action = ArgAction::SetTrue)]
    pub recreate: bool,
    #[arg(long, default_value = DEFAULT_STREAM_NAME)]
    pub stream: String,
}

#[derive(Debug, Clone, Args)]
pub struct ConsumerArgs {
    #[arg(long, value_enum, default_value = "generic")]
    pub profile: ConnectProfile,
    #[arg(long, value_enum, default_value = "fanout")]
    pub mode: TestMode,
    #[command(flatten)]
    pub connect: ConnectArgs,
    #[arg(long, default_value = DEFAULT_SUBJECT)]
    pub subject: String,
    #[arg(long)]
    pub rate: Option<u64>,
    #[arg(long)]
    pub count: Option<u64>,
    #[arg(long, value_parser = parse_duration)]
    pub duration: Option<Duration>,
    #[arg(long, value_parser = parse_duration)]
    pub processing_delay: Option<Duration>,
    #[arg(
        long,
        visible_alias = "js-ack-mode",
        value_enum,
        default_value = "confirmed"
    )]
    pub jetstream_ack_mode: JetstreamAckMode,
    #[arg(
        long,
        visible_alias = "js-max-ack-pending",
        value_parser = clap::value_parser!(i64).range(1..)
    )]
    pub jetstream_max_ack_pending: Option<i64>,
    #[arg(long, visible_alias = "js-pull-batch")]
    pub jetstream_pull_batch: Option<usize>,
    #[arg(long)]
    pub queue_group: Option<String>,
    #[arg(long, default_value_t = false, action = ArgAction::SetTrue)]
    pub recreate: bool,
    #[arg(long, default_value = DEFAULT_STREAM_NAME)]
    pub stream: String,
    #[arg(long, default_value = DEFAULT_CONSUMER_NAME)]
    pub consumer: String,
}

#[derive(Debug, Clone, Args)]
pub struct CommonArgs {
    #[arg(long, default_value_t = 1)]
    pub report_every_secs: u64,
    #[arg(long, default_value = "info")]
    pub log_filter: String,
    #[arg(long)]
    pub nats_pid: Option<u32>,
    #[arg(long, default_value_t = true, action = ArgAction::Set)]
    pub auto_monitor_nats: bool,
    #[arg(long, default_value_t = 500)]
    pub resource_sample_ms: u64,
}

#[derive(Debug, Clone, Args, Default)]
pub struct ConnectArgs {
    #[arg(long)]
    pub server: Option<String>,
    #[arg(long)]
    pub tls: Option<bool>,
    #[arg(long)]
    pub ca_cert: Option<String>,
    #[arg(long)]
    pub client_cert: Option<String>,
    #[arg(long)]
    pub client_key: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ResolvedConnectArgs {
    pub profile: ConnectProfile,
    pub server: String,
    pub tls: bool,
    pub ca_cert: Option<String>,
    pub client_cert: Option<String>,
    pub client_key: Option<String>,
}

impl ConnectArgs {
    pub fn resolve(&self, profile: ConnectProfile) -> Result<ResolvedConnectArgs> {
        let mut resolved = match profile {
            ConnectProfile::Generic => ResolvedConnectArgs {
                profile,
                server: "nats://127.0.0.1:4222".to_owned(),
                tls: false,
                ca_cert: None,
                client_cert: None,
                client_key: None,
            },
            ConnectProfile::Gap3 => ResolvedConnectArgs {
                profile,
                server: "nats://127.0.0.1:4222".to_owned(),
                tls: true,
                ca_cert: Some("/run/agenix/nats-ca-cert".to_owned()),
                client_cert: Some(GAP3_PROFILE_CLIENT_CERT_PATH.to_owned()),
                client_key: Some(GAP3_PROFILE_CLIENT_KEY_PATH.to_owned()),
            },
        };

        if let Some(server) = &self.server {
            resolved.server = server.clone();
        }
        if let Some(tls) = self.tls {
            resolved.tls = tls;
        }
        if let Some(ca_cert) = &self.ca_cert {
            resolved.ca_cert = Some(ca_cert.clone());
        }
        if let Some(client_cert) = &self.client_cert {
            resolved.client_cert = Some(client_cert.clone());
        }
        if let Some(client_key) = &self.client_key {
            resolved.client_key = Some(client_key.clone());
        }

        if resolved.tls
            && (resolved.ca_cert.is_none()
                || resolved.client_cert.is_none()
                || resolved.client_key.is_none())
        {
            bail!("TLS is enabled but CA cert, client cert, or client key is missing");
        }

        Ok(resolved)
    }
}

impl CommonArgs {
    pub fn resolve_monitoring(&self) -> Result<ResolvedMonitoring> {
        let self_pid = std::process::id();
        let mut notes = Vec::new();
        let nats_pid = if let Some(pid) = self.nats_pid {
            if read_process_sample(pid).is_none() {
                bail!("--nats-pid {pid} does not refer to a readable live process");
            }
            notes.push(format!("monitoring nats-server pid {pid} from --nats-pid"));
            Some(pid)
        } else if self.auto_monitor_nats {
            let pids = detect_local_nats_server_pids()?;
            match pids.as_slice() {
                [] => {
                    notes.push("no local nats-server process detected for monitoring".to_owned());
                    None
                }
                [pid] => {
                    notes.push(format!("auto-detected local nats-server pid {pid}"));
                    Some(*pid)
                }
                pids => {
                    notes.push(format!(
                        "multiple local nats-server processes detected ({}); skipping auto monitor",
                        pids.iter()
                            .map(u32::to_string)
                            .collect::<Vec<_>>()
                            .join(", ")
                    ));
                    None
                }
            }
        } else {
            notes.push("local nats-server auto-monitoring disabled".to_owned());
            None
        };

        Ok(ResolvedMonitoring {
            self_pid,
            nats_pid,
            resource_sample_interval: Duration::from_millis(self.resource_sample_ms.max(100)),
            notes,
        })
    }
}

#[derive(Debug, Clone)]
pub struct Limits {
    pub count: Option<u64>,
    pub duration: Option<Duration>,
}

impl Limits {
    pub fn exhausted(&self, started_at: Instant, completed: u64) -> bool {
        if let Some(target) = self.count {
            if completed >= target {
                return true;
            }
        }

        if let Some(limit) = self.duration {
            if started_at.elapsed() >= limit {
                return true;
            }
        }

        false
    }
}

#[derive(Debug)]
pub struct RateController {
    rate: Option<u64>,
    started_at: Instant,
    ordinal: AtomicU64,
}

impl RateController {
    pub fn new(rate: Option<u64>) -> Result<Self> {
        if matches!(rate, Some(0)) {
            bail!("rate must be greater than zero");
        }

        Ok(Self {
            rate,
            started_at: Instant::now(),
            ordinal: AtomicU64::new(0),
        })
    }

    pub async fn wait_turn(&self) {
        let Some(rate) = self.rate else {
            return;
        };

        let slot = self.ordinal.fetch_add(1, Ordering::Relaxed);
        let nanos = ((slot as u128) * 1_000_000_000u128) / (rate as u128);
        let target = self.started_at + duration_from_nanos(nanos);
        if let Some(delay) = target.checked_duration_since(Instant::now()) {
            sleep(delay).await;
        }
    }
}

#[derive(Debug, Default, Clone)]
pub struct SummarySnapshot {
    pub messages: u64,
    pub bytes: u64,
    pub payload_min_bytes: Option<u64>,
    pub payload_max_bytes: Option<u64>,
    pub payload_histogram: [u64; SIZE_BUCKETS.len()],
    pub latency_samples: u64,
    pub latency_total: Duration,
    pub latency_min: Option<Duration>,
    pub latency_max: Option<Duration>,
    pub latency_histogram: [u64; LATENCY_BUCKETS_NS.len()],
}

#[derive(Debug, Default, Clone)]
pub struct ProcessUsageSummary {
    pub pid: u32,
    pub rss_samples: u64,
    pub cpu_samples: u64,
    pub avg_rss_bytes: u64,
    pub peak_rss_bytes: u64,
    pub avg_cpu_percent: f64,
    pub peak_cpu_percent: f64,
}

#[derive(Debug, Default, Clone)]
pub struct ResourceUsageSnapshot {
    pub self_process: Option<ProcessUsageSummary>,
    pub nats_process: Option<ProcessUsageSummary>,
}

impl SummarySnapshot {
    pub fn latency_avg(&self) -> Option<Duration> {
        if self.latency_samples == 0 {
            return None;
        }

        Some(duration_from_nanos(
            self.latency_total.as_nanos() / self.latency_samples as u128,
        ))
    }
}

#[derive(Debug)]
pub struct Metrics {
    messages: AtomicU64,
    bytes: AtomicU64,
    payload_min_bytes: AtomicU64,
    payload_max_bytes: AtomicU64,
    payload_histogram: [AtomicU64; SIZE_BUCKETS.len()],
    latency_total_nanos: AtomicU64,
    latency_samples: AtomicU64,
    latency_min_nanos: AtomicU64,
    latency_max_nanos: AtomicU64,
    latency_histogram: [AtomicU64; LATENCY_BUCKETS_NS.len()],
}

impl Default for Metrics {
    fn default() -> Self {
        Self {
            messages: AtomicU64::new(0),
            bytes: AtomicU64::new(0),
            payload_min_bytes: AtomicU64::new(0),
            payload_max_bytes: AtomicU64::new(0),
            payload_histogram: std::array::from_fn(|_| AtomicU64::new(0)),
            latency_total_nanos: AtomicU64::new(0),
            latency_samples: AtomicU64::new(0),
            latency_min_nanos: AtomicU64::new(0),
            latency_max_nanos: AtomicU64::new(0),
            latency_histogram: std::array::from_fn(|_| AtomicU64::new(0)),
        }
    }
}

impl Metrics {
    pub fn messages(&self) -> u64 {
        self.messages.load(Ordering::Relaxed)
    }

    pub fn record(&self, bytes: usize, latency: Option<Duration>) -> u64 {
        let bytes = bytes as u64;
        self.bytes.fetch_add(bytes, Ordering::Relaxed);
        update_atomic_min(&self.payload_min_bytes, bytes);
        update_atomic_max(&self.payload_max_bytes, bytes);
        self.payload_histogram[payload_bucket_index(bytes as usize)]
            .fetch_add(1, Ordering::Relaxed);

        if let Some(latency) = latency {
            let nanos = duration_to_nanos_u64(latency);
            self.latency_total_nanos.fetch_add(nanos, Ordering::Relaxed);
            self.latency_samples.fetch_add(1, Ordering::Relaxed);
            update_atomic_min(&self.latency_min_nanos, nanos);
            update_atomic_max(&self.latency_max_nanos, nanos);
            self.latency_histogram[latency_bucket_index(nanos)].fetch_add(1, Ordering::Relaxed);
        }

        self.messages.fetch_add(1, Ordering::Relaxed) + 1
    }

    pub fn snapshot(&self) -> SummarySnapshot {
        SummarySnapshot {
            messages: self.messages.load(Ordering::Relaxed),
            bytes: self.bytes.load(Ordering::Relaxed),
            payload_min_bytes: nonzero_atomic_value(&self.payload_min_bytes),
            payload_max_bytes: nonzero_atomic_value(&self.payload_max_bytes),
            payload_histogram: std::array::from_fn(|index| {
                self.payload_histogram[index].load(Ordering::Relaxed)
            }),
            latency_samples: self.latency_samples.load(Ordering::Relaxed),
            latency_total: Duration::from_nanos(self.latency_total_nanos.load(Ordering::Relaxed)),
            latency_min: nonzero_atomic_duration(&self.latency_min_nanos),
            latency_max: nonzero_atomic_duration(&self.latency_max_nanos),
            latency_histogram: std::array::from_fn(|index| {
                self.latency_histogram[index].load(Ordering::Relaxed)
            }),
        }
    }
}

#[derive(Debug, Clone)]
pub struct RunSummary {
    pub kind: String,
    pub mode: TestMode,
    pub elapsed: Duration,
    pub snapshot: SummarySnapshot,
    pub resources: ResourceUsageSnapshot,
    pub notes: Vec<String>,
}

pub struct Runtime {
    pub started_at: Instant,
    pub stop: Arc<AtomicBool>,
    pub external_stop: Option<Arc<AtomicBool>>,
    pub metrics: Arc<Metrics>,
    pub limits: Limits,
    pub limiter: Arc<RateController>,
}

#[derive(Debug, Clone)]
struct ProcessShutdownSignal {
    stop_requested: Arc<AtomicBool>,
    skip_drain_requested: Arc<AtomicBool>,
}

struct ConfirmedAcker {
    client: Client,
    inbox: Subject,
    subscription: Subscriber,
}

#[derive(Debug, Clone)]
pub struct ResolvedMonitoring {
    pub self_pid: u32,
    pub nats_pid: Option<u32>,
    pub resource_sample_interval: Duration,
    pub notes: Vec<String>,
}

#[derive(Debug, Clone, Copy)]
struct ProcessSample {
    cpu_ticks: u64,
    rss_bytes: u64,
}

#[derive(Debug)]
struct ProcessUsageAccumulator {
    pid: u32,
    rss_samples: u64,
    cpu_samples: u64,
    rss_total_bytes: u128,
    peak_rss_bytes: u64,
    cpu_total_percent: f64,
    peak_cpu_percent: f64,
}

impl ProcessUsageAccumulator {
    fn new(pid: u32) -> Self {
        Self {
            pid,
            rss_samples: 0,
            cpu_samples: 0,
            rss_total_bytes: 0,
            peak_rss_bytes: 0,
            cpu_total_percent: 0.0,
            peak_cpu_percent: 0.0,
        }
    }

    fn record_rss(&mut self, rss_bytes: u64) {
        self.rss_samples += 1;
        self.rss_total_bytes += rss_bytes as u128;
        self.peak_rss_bytes = self.peak_rss_bytes.max(rss_bytes);
    }

    fn record_cpu_percent(&mut self, cpu_percent: f64) {
        self.cpu_samples += 1;
        self.cpu_total_percent += cpu_percent;
        self.peak_cpu_percent = self.peak_cpu_percent.max(cpu_percent);
    }

    fn snapshot(&self) -> ProcessUsageSummary {
        ProcessUsageSummary {
            pid: self.pid,
            rss_samples: self.rss_samples,
            cpu_samples: self.cpu_samples,
            avg_rss_bytes: if self.rss_samples == 0 {
                0
            } else {
                (self.rss_total_bytes / self.rss_samples as u128) as u64
            },
            peak_rss_bytes: self.peak_rss_bytes,
            avg_cpu_percent: if self.cpu_samples == 0 {
                0.0
            } else {
                self.cpu_total_percent / self.cpu_samples as f64
            },
            peak_cpu_percent: self.peak_cpu_percent,
        }
    }
}

struct ResourceMonitorHandle {
    stop: Arc<AtomicBool>,
    join: tokio::task::JoinHandle<()>,
    self_accumulator: Arc<Mutex<ProcessUsageAccumulator>>,
    nats_accumulator: Option<Arc<Mutex<ProcessUsageAccumulator>>>,
}

impl ResourceMonitorHandle {
    fn start(config: &ResolvedMonitoring) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let self_accumulator = Arc::new(Mutex::new(ProcessUsageAccumulator::new(config.self_pid)));
        let nats_accumulator = config
            .nats_pid
            .map(|pid| Arc::new(Mutex::new(ProcessUsageAccumulator::new(pid))));
        let sample_interval = config.resource_sample_interval;
        let self_pid = config.self_pid;
        let nats_pid = config.nats_pid;
        let cpu_count = std::thread::available_parallelism()
            .map(|count| count.get() as f64)
            .unwrap_or(1.0);
        let stop_flag = stop.clone();
        let self_accumulator_task = self_accumulator.clone();
        let nats_accumulator_task = nats_accumulator.clone();

        let join = tokio::spawn(async move {
            let mut last_total_cpu_ticks = read_total_cpu_ticks().ok();
            let mut last_self_sample = read_process_sample(self_pid);
            let mut last_nats_sample = nats_pid.and_then(read_process_sample);

            if let Some(sample) = last_self_sample {
                self_accumulator_task
                    .lock()
                    .expect("self process accumulator poisoned")
                    .record_rss(sample.rss_bytes);
            }
            if let (Some(sample), Some(accumulator)) =
                (last_nats_sample, nats_accumulator_task.as_ref())
            {
                accumulator
                    .lock()
                    .expect("nats process accumulator poisoned")
                    .record_rss(sample.rss_bytes);
            }

            let mut ticker = tokio::time::interval(sample_interval);
            loop {
                ticker.tick().await;

                let current_total_cpu_ticks = read_total_cpu_ticks().ok();
                let current_self_sample = read_process_sample(self_pid);
                let current_nats_sample = nats_pid.and_then(read_process_sample);

                if let Some(sample) = current_self_sample {
                    self_accumulator_task
                        .lock()
                        .expect("self process accumulator poisoned")
                        .record_rss(sample.rss_bytes);
                }
                if let (Some(sample), Some(accumulator)) =
                    (current_nats_sample, nats_accumulator_task.as_ref())
                {
                    accumulator
                        .lock()
                        .expect("nats process accumulator poisoned")
                        .record_rss(sample.rss_bytes);
                }

                if let (Some(previous_total), Some(current_total)) =
                    (last_total_cpu_ticks, current_total_cpu_ticks)
                {
                    let total_delta = current_total.saturating_sub(previous_total);
                    if total_delta > 0 {
                        if let (Some(previous), Some(current)) =
                            (last_self_sample, current_self_sample)
                        {
                            let cpu_percent =
                                cpu_percent(previous, current, total_delta, cpu_count);
                            self_accumulator_task
                                .lock()
                                .expect("self process accumulator poisoned")
                                .record_cpu_percent(cpu_percent);
                        }

                        if let (Some(previous), Some(current), Some(accumulator)) = (
                            last_nats_sample,
                            current_nats_sample,
                            nats_accumulator_task.as_ref(),
                        ) {
                            let cpu_percent =
                                cpu_percent(previous, current, total_delta, cpu_count);
                            accumulator
                                .lock()
                                .expect("nats process accumulator poisoned")
                                .record_cpu_percent(cpu_percent);
                        }
                    }
                }

                last_total_cpu_ticks = current_total_cpu_ticks;
                last_self_sample = current_self_sample;
                last_nats_sample = current_nats_sample;

                if stop_flag.load(Ordering::Relaxed) {
                    break;
                }
            }
        });

        Self {
            stop,
            join,
            self_accumulator,
            nats_accumulator,
        }
    }

    async fn finish(self) -> ResourceUsageSnapshot {
        self.stop.store(true, Ordering::Relaxed);
        let _ = self.join.await;
        ResourceUsageSnapshot {
            self_process: Some(
                self.self_accumulator
                    .lock()
                    .expect("self process accumulator poisoned")
                    .snapshot(),
            ),
            nats_process: self.nats_accumulator.map(|accumulator| {
                accumulator
                    .lock()
                    .expect("nats process accumulator poisoned")
                    .snapshot()
            }),
        }
    }
}

impl Runtime {
    pub fn new(
        limits: Limits,
        limiter: Arc<RateController>,
        external_stop: Option<Arc<AtomicBool>>,
    ) -> Self {
        Self {
            started_at: Instant::now(),
            stop: Arc::new(AtomicBool::new(false)),
            external_stop,
            metrics: Arc::new(Metrics::default()),
            limits,
            limiter,
        }
    }

    pub fn should_stop(&self) -> bool {
        self.stop.load(Ordering::Relaxed)
            || self
                .external_stop
                .as_ref()
                .is_some_and(|stop| stop.load(Ordering::Relaxed))
            || self
                .limits
                .exhausted(self.started_at, self.metrics.messages())
    }

    pub fn request_stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }

    pub fn record_message(&self, bytes: usize, latency: Option<Duration>) {
        let completed = self.metrics.record(bytes, latency);
        if self.limits.exhausted(self.started_at, completed) {
            self.request_stop();
        }
    }

    pub fn summary(
        &self,
        kind: String,
        mode: TestMode,
        resources: ResourceUsageSnapshot,
        notes: Vec<String>,
    ) -> RunSummary {
        RunSummary {
            kind,
            mode,
            elapsed: self.started_at.elapsed(),
            snapshot: self.metrics.snapshot(),
            resources,
            notes,
        }
    }
}

impl ConfirmedAcker {
    async fn new(client: &Client) -> Result<Self> {
        let inbox = client.new_inbox();
        let subscription = client
            .subscribe(inbox.clone())
            .await
            .context("failed to subscribe confirmed ack inbox")?;
        Ok(Self {
            client: client.clone(),
            inbox: inbox.into(),
            subscription,
        })
    }

    async fn acknowledge(&mut self, message: &async_nats::jetstream::Message) -> Result<()> {
        let reply = message.reply.clone().ok_or_else(|| {
            anyhow::anyhow!("JetStream message did not include reply subject for confirmed ack")
        })?;

        self.client
            .publish_with_reply(reply, self.inbox.clone(), AckKind::Ack.into())
            .await
            .context("failed to publish confirmed JetStream ack")?;

        match timeout(Duration::from_secs(5), self.subscription.next())
            .await
            .context("confirmed JetStream ack response timed out")?
        {
            Some(_) => Ok(()),
            None => bail!("confirmed JetStream ack subscription closed"),
        }
    }
}

#[derive(Debug)]
pub struct PayloadFactory {
    average_bytes: usize,
    rng: Mutex<StdRng>,
}

impl PayloadFactory {
    pub fn new(average_bytes: usize) -> Result<Self> {
        if average_bytes < PAYLOAD_HEADER_BYTES {
            bail!("avg payload bytes must be at least {PAYLOAD_HEADER_BYTES}");
        }

        Ok(Self {
            average_bytes,
            rng: Mutex::new(StdRng::from_rng(&mut rng())),
        })
    }

    pub fn average_bytes(&self) -> usize {
        self.average_bytes
    }

    pub fn build_payload(&self, sequence: u64) -> Bytes {
        let mut rng = self.rng.lock().expect("payload RNG mutex poisoned");
        let min_bytes = (self.average_bytes / 2).max(PAYLOAD_HEADER_BYTES);
        let max_bytes = self.average_bytes.saturating_mul(3).div_ceil(2);
        let span = max_bytes.saturating_sub(min_bytes);
        let size = if span == 0 {
            min_bytes
        } else {
            min_bytes + (rng.next_u64() as usize % (span + 1))
        };

        let mut body = vec![0u8; size];
        body[..8].copy_from_slice(&sequence.to_le_bytes());
        body[8..16].copy_from_slice(&unix_time_nanos().to_le_bytes());
        if size > PAYLOAD_HEADER_BYTES {
            rng.fill_bytes(&mut body[PAYLOAD_HEADER_BYTES..]);
        }
        Bytes::from(body)
    }
}

#[derive(Debug, Clone, Copy)]
pub struct PayloadMeta {
    pub sequence: u64,
    pub sent_at_unix_nanos: u64,
}

impl PayloadMeta {
    pub fn decode(payload: &[u8]) -> Option<Self> {
        if payload.len() < PAYLOAD_HEADER_BYTES {
            return None;
        }

        let mut sequence = [0u8; 8];
        let mut sent_at = [0u8; 8];
        sequence.copy_from_slice(&payload[..8]);
        sent_at.copy_from_slice(&payload[8..16]);
        Some(Self {
            sequence: u64::from_le_bytes(sequence),
            sent_at_unix_nanos: u64::from_le_bytes(sent_at),
        })
    }

    pub fn age(&self) -> Option<Duration> {
        Some(Duration::from_nanos(
            unix_time_nanos().checked_sub(self.sent_at_unix_nanos)?,
        ))
    }
}

pub fn init_tracing(filter: &str) {
    let merged_filter = format!("{filter},async_nats=warn");
    let env_filter = tracing_subscriber::EnvFilter::try_new(&merged_filter)
        .or_else(|_| tracing_subscriber::EnvFilter::try_new("info,async_nats=warn"))
        .expect("valid fallback log filter");

    let _ = tracing_subscriber::fmt()
        .with_env_filter(env_filter)
        .with_target(false)
        .try_init();
}

fn process_shutdown_signal() -> ProcessShutdownSignal {
    PROCESS_SHUTDOWN
        .get_or_init(|| {
            let stop_requested = Arc::new(AtomicBool::new(false));
            let skip_drain_requested = Arc::new(AtomicBool::new(false));
            let signal_count = Arc::new(AtomicUsize::new(0));
            let stop_task = stop_requested.clone();
            let skip_task = skip_drain_requested.clone();
            let signal_count_task = signal_count.clone();

            tokio::spawn(async move {
                loop {
                    if tokio::signal::ctrl_c().await.is_err() {
                        break;
                    }

                    let press = signal_count_task.fetch_add(1, Ordering::Relaxed) + 1;
                    stop_task.store(true, Ordering::Relaxed);
                    if press >= 2 {
                        skip_task.store(true, Ordering::Relaxed);
                    }
                }
            });

            ProcessShutdownSignal {
                stop_requested,
                skip_drain_requested,
            }
        })
        .clone()
}

fn build_connect_options() -> async_nats::ConnectOptions {
    let last_slow_consumer = Arc::new(Mutex::new(None::<Instant>));

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
                    let now = Instant::now();
                    let mut last_logged = last_slow_consumer
                        .lock()
                        .expect("slow consumer callback mutex poisoned");
                    let should_log = last_logged
                        .is_none_or(|previous| now.duration_since(previous) >= Duration::from_secs(5));
                    if should_log {
                        *last_logged = Some(now);
                        warn!(
                            subscription_id,
                            "nats slow consumer backpressure detected; lower --js-pull-batch or raise consumer throughput"
                        );
                    }
                }
            }
        }
    })
}

pub async fn run_producer(args: ProducerCli) -> Result<RunSummary> {
    init_tracing(&args.common.log_filter);
    let shutdown = process_shutdown_signal();
    let monitoring = args.common.resolve_monitoring()?;
    run_producer_instance(
        args.test,
        args.common,
        monitoring,
        "producer".to_owned(),
        Some(shutdown.stop_requested),
    )
    .await
}

pub async fn run_consumer(args: ConsumerCli) -> Result<RunSummary> {
    init_tracing(&args.common.log_filter);
    let shutdown = process_shutdown_signal();
    if matches!(args.test.jetstream_pull_batch, Some(0)) {
        bail!("--jetstream-pull-batch must be at least 1");
    }
    let monitoring = args.common.resolve_monitoring()?;
    run_consumer_instance(
        args.test,
        args.common,
        monitoring,
        "consumer".to_owned(),
        Some(shutdown.stop_requested),
    )
    .await
}

pub async fn run_orchestrator(args: OrchestratorCli) -> Result<()> {
    init_tracing(&args.common.log_filter);
    let shutdown = process_shutdown_signal();

    if args.producers == 0 {
        bail!("--producers must be at least 1");
    }

    if args.consumers == 0 {
        bail!("--consumers must be at least 1");
    }

    if matches!(args.jetstream_pull_batch, Some(0)) {
        bail!("--jetstream-pull-batch must be at least 1");
    }

    let common = args.common.clone();
    let monitoring = common.resolve_monitoring()?;
    let queue_group = args.queue_group.clone();
    let producer_args = ProducerArgs {
        mode: args.mode,
        profile: args.profile,
        connect: args.connect.clone(),
        subject: args.subject.clone(),
        rate: args.producer_rate,
        count: args.producer_count,
        duration: args.producer_duration,
        avg_payload_bytes: args.avg_payload_bytes,
        request_timeout_ms: args.request_timeout_ms,
        recreate: false,
        stream: args.stream.clone(),
    };
    let consumer_args = ConsumerArgs {
        mode: args.mode,
        profile: args.profile,
        connect: args.connect.clone(),
        subject: args.subject.clone(),
        rate: args.consumer_rate,
        count: args.consumer_count,
        duration: args.consumer_duration,
        processing_delay: args.processing_delay,
        jetstream_ack_mode: args.jetstream_ack_mode,
        jetstream_max_ack_pending: args.jetstream_max_ack_pending,
        jetstream_pull_batch: args.jetstream_pull_batch,
        queue_group,
        recreate: false,
        stream: args.stream.clone(),
        consumer: args.consumer.clone(),
    };

    if args.recreate {
        let resolved_connect = args.connect.resolve(args.profile)?;
        let client = connect(&resolved_connect).await?;
        recreate_mode_state(
            &client,
            args.mode,
            &effective_subject_name(args.mode, &args.subject),
            &effective_stream_name(args.mode, &args.stream),
        )
        .await?;
    }

    log_orchestrator_start(&args, &monitoring);
    let orchestrator_monitor = ResourceMonitorHandle::start(&monitoring);

    let orchestrator_stop = shutdown.stop_requested.clone();
    let mut producer_handles = Vec::with_capacity(args.producers);
    for index in 0..args.producers {
        producer_handles.push(tokio::spawn(run_producer_instance(
            producer_args.clone(),
            common.clone(),
            monitoring.clone(),
            format!("producer-{}", index + 1),
            Some(orchestrator_stop.clone()),
        )));
    }

    let mut consumer_handles = Vec::with_capacity(args.consumers);
    for index in 0..args.consumers {
        consumer_handles.push(tokio::spawn(run_consumer_instance(
            consumer_args.clone(),
            common.clone(),
            monitoring.clone(),
            format!("consumer-{}", index + 1),
            Some(orchestrator_stop.clone()),
        )));
    }

    let mut producer_summaries = Vec::with_capacity(args.producers);
    for handle in producer_handles {
        producer_summaries.push(handle.await??);
    }
    for summary in &producer_summaries {
        log_summary(summary);
    }

    if should_drain_jetstream_queue(args.mode)
        && effective_jetstream_ack_mode(&args) != JetstreamAckMode::None
    {
        wait_for_jetstream_drain(&args, common.report_every_secs, orchestrator_stop.clone())
            .await?;
        orchestrator_stop.store(true, Ordering::Relaxed);
    } else if should_drain_jetstream_queue(args.mode)
        && effective_jetstream_ack_mode(&args) == JetstreamAckMode::None
    {
        println!(
            "\nJetStream Shutdown\n  ack mode is none; full queue drain is not possible, so consumers will stop immediately"
        );
        orchestrator_stop.store(true, Ordering::Relaxed);
    } else if args.drain_ms > 0 {
        println!(
            "\nDrain\n  waiting {} before stopping consumers",
            humantime::format_duration(Duration::from_millis(args.drain_ms))
        );
        sleep(Duration::from_millis(args.drain_ms)).await;
        orchestrator_stop.store(true, Ordering::Relaxed);
    } else {
        orchestrator_stop.store(true, Ordering::Relaxed);
    }

    let mut consumer_summaries = Vec::with_capacity(args.consumers);
    for handle in consumer_handles {
        consumer_summaries.push(handle.await??);
    }

    for summary in &consumer_summaries {
        log_summary(summary);
    }

    let resources = orchestrator_monitor.finish().await;
    log_combined_summary(
        &args,
        &producer_summaries,
        &consumer_summaries,
        resources,
        monitoring.notes.clone(),
    );
    Ok(())
}

async fn run_producer_instance(
    args: ProducerArgs,
    common: CommonArgs,
    monitoring: ResolvedMonitoring,
    kind: String,
    external_stop: Option<Arc<AtomicBool>>,
) -> Result<RunSummary> {
    let payloads = Arc::new(PayloadFactory::new(args.avg_payload_bytes)?);
    let resolved_connect = args.connect.resolve(args.profile)?;
    if args.recreate {
        let client = connect(&resolved_connect).await?;
        recreate_mode_state(
            &client,
            args.mode,
            &effective_subject_name(args.mode, &args.subject),
            &effective_stream_name(args.mode, &args.stream),
        )
        .await?;
    }
    let runtime = Runtime::new(
        Limits {
            count: args.count,
            duration: args.duration,
        },
        Arc::new(RateController::new(args.rate)?),
        external_stop,
    );

    log_producer_start(&kind, &args, &monitoring, payloads.average_bytes());
    let resource_monitor = ResourceMonitorHandle::start(&monitoring);
    let reporter = spawn_progress_reporter(
        Box::leak(kind.clone().into_boxed_str()),
        common.report_every_secs,
        runtime.metrics.clone(),
        runtime.stop.clone(),
        runtime.started_at,
    );
    let client = connect(&resolved_connect).await?;
    match args.mode {
        TestMode::Fanout => produce_core(client, &args, &runtime, payloads).await?,
        TestMode::Queue => produce_core(client, &args, &runtime, payloads).await?,
        TestMode::ReqReply => produce_request_reply(client, &args, &runtime, payloads).await?,
        TestMode::JetstreamQueueStrict
        | TestMode::JetstreamQueueConcurrent
        | TestMode::JetstreamQueueStrictExactlyOnce
        | TestMode::JetstreamQueueConcurrentExactlyOnce
        | TestMode::JetstreamReplay => {
            produce_jetstream(client, &args, &runtime, payloads, &kind).await?
        }
    }

    runtime.request_stop();
    reporter.abort();
    let resources = resource_monitor.finish().await;
    Ok(runtime.summary(kind, args.mode, resources, monitoring.notes.clone()))
}

async fn run_consumer_instance(
    args: ConsumerArgs,
    common: CommonArgs,
    monitoring: ResolvedMonitoring,
    kind: String,
    external_stop: Option<Arc<AtomicBool>>,
) -> Result<RunSummary> {
    let runtime = Arc::new(Runtime::new(
        Limits {
            count: args.count,
            duration: args.duration,
        },
        Arc::new(RateController::new(args.rate)?),
        external_stop,
    ));
    let resolved_connect = args.connect.resolve(args.profile)?;
    if args.recreate {
        let client = connect(&resolved_connect).await?;
        recreate_mode_state(
            &client,
            args.mode,
            &effective_subject_name(args.mode, &args.subject),
            &effective_stream_name(args.mode, &args.stream),
        )
        .await?;
    }

    log_consumer_start(&kind, &args, &monitoring);
    let resource_monitor = ResourceMonitorHandle::start(&monitoring);
    let reporter = spawn_progress_reporter(
        Box::leak(kind.clone().into_boxed_str()),
        common.report_every_secs,
        runtime.metrics.clone(),
        runtime.stop.clone(),
        runtime.started_at,
    );
    let client = connect(&resolved_connect).await?;
    match args.mode {
        TestMode::Fanout => consume_core(client, &args, runtime.clone()).await?,
        TestMode::Queue => consume_queue(client, &args, runtime.clone()).await?,
        TestMode::ReqReply => consume_request_reply(client, &args, runtime.clone()).await?,
        TestMode::JetstreamQueueStrict
        | TestMode::JetstreamQueueConcurrent
        | TestMode::JetstreamQueueStrictExactlyOnce
        | TestMode::JetstreamQueueConcurrentExactlyOnce
        | TestMode::JetstreamReplay => {
            consume_jetstream(client, &args, runtime.clone(), &kind).await?
        }
    }

    runtime.request_stop();
    reporter.abort();
    let resources = resource_monitor.finish().await;
    Ok(runtime.summary(kind, args.mode, resources, monitoring.notes.clone()))
}

async fn connect(connect: &ResolvedConnectArgs) -> Result<Client> {
    let mut options = build_connect_options();

    if connect.tls {
        options = options
            .require_tls(true)
            .add_root_certificates(
                connect
                    .ca_cert
                    .clone()
                    .expect("resolved TLS CA cert present")
                    .into(),
            )
            .add_client_certificate(
                connect
                    .client_cert
                    .clone()
                    .expect("resolved TLS client cert present")
                    .into(),
                connect
                    .client_key
                    .clone()
                    .expect("resolved TLS client key present")
                    .into(),
            );
    }

    options
        .connect(&connect.server)
        .await
        .with_context(|| format!("failed to connect to NATS at {}", connect.server))
}

async fn ensure_workqueue_stream(
    jetstream: &jetstream::Context,
    stream: &str,
    subject: &str,
) -> Result<jetstream::stream::Stream> {
    jetstream
        .get_or_create_stream(StreamConfig {
            name: stream.to_owned(),
            subjects: vec![subject.to_owned()],
            retention: RetentionPolicy::WorkQueue,
            storage: StorageType::File,
            ..Default::default()
        })
        .await
        .with_context(|| format!("failed to get or create JetStream stream {stream}"))
}

async fn ensure_replay_stream(
    jetstream: &jetstream::Context,
    stream: &str,
    subject: &str,
) -> Result<jetstream::stream::Stream> {
    jetstream
        .get_or_create_stream(StreamConfig {
            name: stream.to_owned(),
            subjects: vec![subject.to_owned()],
            retention: RetentionPolicy::Limits,
            storage: StorageType::File,
            ..Default::default()
        })
        .await
        .with_context(|| format!("failed to get or create JetStream replay stream {stream}"))
}

async fn recreate_mode_state(
    client: &Client,
    mode: TestMode,
    subject: &str,
    stream: &str,
) -> Result<()> {
    match mode {
        TestMode::Fanout | TestMode::Queue | TestMode::ReqReply => {
            info!(
                mode = format_mode(mode),
                subject,
                "recreate requested; core NATS mode has no server-side queue state to reset"
            );
            Ok(())
        }
        TestMode::JetstreamQueueStrict
        | TestMode::JetstreamQueueConcurrent
        | TestMode::JetstreamQueueStrictExactlyOnce
        | TestMode::JetstreamQueueConcurrentExactlyOnce
        | TestMode::JetstreamReplay => {
            let jetstream = jetstream::new(client.clone());
            match jetstream.get_stream(stream).await {
                Ok(_) => {
                    jetstream.delete_stream(stream).await.with_context(|| {
                        format!("failed to delete JetStream stream {stream} for --recreate")
                    })?;
                    info!(
                        mode = format_mode(mode),
                        stream, subject, "recreated JetStream state by deleting existing stream"
                    );
                }
                Err(_) => {
                    info!(
                        mode = format_mode(mode),
                        stream, subject, "recreate requested; no existing JetStream stream found"
                    );
                }
            }
            Ok(())
        }
    }
}

async fn ensure_pull_consumer(
    stream: &jetstream::stream::Stream,
    consumer_name: &str,
    subject: &str,
    mode: TestMode,
    max_ack_pending: Option<i64>,
) -> Result<consumer::PullConsumer> {
    let desired_max_ack_pending = effective_jetstream_max_ack_pending(mode, max_ack_pending);
    let desired_config = consumer::pull::Config {
        durable_name: Some(consumer_name.to_owned()),
        filter_subject: subject.to_owned(),
        ack_policy: consumer::AckPolicy::Explicit,
        max_ack_pending: desired_max_ack_pending,
        ..Default::default()
    };

    match stream
        .get_consumer::<consumer::pull::Config>(consumer_name)
        .await
    {
        Ok(existing) => {
            let existing_info = existing.get_info().await.with_context(|| {
                format!("failed to inspect existing pull consumer {consumer_name}")
            })?;
            let existing_config = &existing_info.config;

            if existing_config.filter_subject != desired_config.filter_subject
                || existing_config.ack_policy != desired_config.ack_policy
                || existing_config.max_ack_pending != desired_config.max_ack_pending
            {
                bail!(
                    "existing pull consumer {consumer_name} has incompatible config: \
filter_subject={} ack_policy={:?} max_ack_pending={}; wanted filter_subject={} ack_policy={:?} max_ack_pending={}. \
delete the durable or use a different --consumer name",
                    existing_config.filter_subject,
                    existing_config.ack_policy,
                    existing_config.max_ack_pending,
                    desired_config.filter_subject,
                    desired_config.ack_policy,
                    desired_config.max_ack_pending
                );
            }

            Ok(existing)
        }
        Err(_) => stream
            .create_consumer(desired_config)
            .await
            .with_context(|| format!("failed to create pull consumer {consumer_name}")),
    }
}

async fn acknowledge_jetstream_message(
    message: &async_nats::jetstream::Message,
    ack_mode: JetstreamAckMode,
    confirmed_acker: Option<&mut ConfirmedAcker>,
) -> Result<()> {
    match ack_mode {
        JetstreamAckMode::Ack => message
            .ack()
            .await
            .map_err(|error| anyhow::anyhow!("failed to ack JetStream message: {error}"))?,
        JetstreamAckMode::Confirmed => {
            confirmed_acker
                .context("confirmed ack mode requires a reusable ack inbox")?
                .acknowledge(message)
                .await?
        }
        JetstreamAckMode::None => {}
    }

    Ok(())
}

async fn jetstream_consumer_drained(
    stream: &jetstream::stream::Stream,
    consumer: &consumer::PullConsumer,
) -> Result<bool> {
    let stream_info = stream
        .get_info()
        .await
        .context("failed to fetch JetStream stream state during shutdown drain")?;
    let consumer_info = consumer
        .get_info()
        .await
        .context("failed to fetch JetStream consumer state during shutdown drain")?;

    Ok(stream_info.state.messages == 0
        || (consumer_info.num_pending == 0 && consumer_info.num_ack_pending == 0))
}

async fn wait_for_jetstream_drain(
    args: &OrchestratorCli,
    report_every_secs: u64,
    orchestrator_stop: Arc<AtomicBool>,
) -> Result<()> {
    let shutdown = process_shutdown_signal();
    println!(
        "\nJetStream Drain\n  draining queue before shutdown\n  press Ctrl+C again to skip drain"
    );

    let resolved_connect = args.connect.resolve(args.profile)?;
    let client = connect(&resolved_connect).await?;
    let jetstream = jetstream::new(client);
    let subject_name = effective_subject_name(args.mode, &args.subject);
    let stream_name = effective_stream_name(args.mode, &args.stream);
    let consumer_name = effective_consumer_name(args.mode, &args.consumer, "consumer");
    let stream = ensure_workqueue_stream(&jetstream, &stream_name, &subject_name).await?;
    let consumer = ensure_pull_consumer(
        &stream,
        &consumer_name,
        &subject_name,
        args.mode,
        args.jetstream_max_ack_pending,
    )
    .await?;

    let interval = Duration::from_secs(report_every_secs.max(1));
    let mut ticker = tokio::time::interval(interval);

    loop {
        tokio::select! {
            _ = ticker.tick() => {
                if shutdown.skip_drain_requested.load(Ordering::Relaxed) {
                    println!("Drain skipped  stopping consumers immediately");
                    orchestrator_stop.store(true, Ordering::Relaxed);
                    break;
                }

                let stream_info = stream
                    .get_info()
                    .await
                    .context("failed to fetch JetStream stream state while draining")?;
                let consumer_info = consumer
                    .get_info()
                    .await
                    .context("failed to fetch JetStream consumer state while draining")?;

                println!(
                    "Drain progress  remaining queue messages: {}  ack pending: {}",
                    stream_info.state.messages,
                    consumer_info.num_ack_pending
                );

                if stream_info.state.messages == 0
                    || (consumer_info.num_pending == 0 && consumer_info.num_ack_pending == 0)
                {
                    println!("Drain complete  remaining queue messages: 0  ack pending: 0");
                    break;
                }
            }
        }
    }

    Ok(())
}

fn spawn_progress_reporter(
    kind: &'static str,
    report_every_secs: u64,
    metrics: Arc<Metrics>,
    stop: Arc<AtomicBool>,
    started_at: Instant,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let interval = Duration::from_secs(report_every_secs.max(1));
        let mut last_messages = 0u64;
        let mut last_bytes = 0u64;
        let mut ticker = tokio::time::interval(interval);

        loop {
            ticker.tick().await;
            let snapshot = metrics.snapshot();
            let delta_messages = snapshot.messages.saturating_sub(last_messages);
            let delta_bytes = snapshot.bytes.saturating_sub(last_bytes);
            let elapsed = started_at.elapsed().as_secs_f64().max(0.001);
            let window = interval.as_secs_f64().max(0.001);

            info!(
                kind,
                total_messages = snapshot.messages,
                total_bytes = snapshot.bytes,
                elapsed_secs = elapsed,
                window_messages_per_sec = delta_messages as f64 / window,
                window_mib_per_sec = (delta_bytes as f64 / window) / (1024.0 * 1024.0),
                overall_messages_per_sec = snapshot.messages as f64 / elapsed,
                latency_avg_ms = snapshot
                    .latency_avg()
                    .map(duration_to_millis)
                    .unwrap_or_default(),
                latency_max_ms = snapshot
                    .latency_max
                    .map(duration_to_millis)
                    .unwrap_or_default(),
                "progress"
            );

            last_messages = snapshot.messages;
            last_bytes = snapshot.bytes;

            if stop.load(Ordering::Relaxed) {
                break;
            }
        }
    })
}

async fn produce_core(
    client: Client,
    args: &ProducerArgs,
    runtime: &Runtime,
    payloads: Arc<PayloadFactory>,
) -> Result<()> {
    let subject: Subject = effective_subject_name(args.mode, &args.subject).into();
    loop {
        if runtime.should_stop() {
            break;
        }

        runtime.limiter.wait_turn().await;
        let next = runtime.metrics.messages() + 1;
        let payload = payloads.build_payload(next);
        let started = Instant::now();
        client
            .publish(subject.clone(), payload.clone())
            .await
            .context("failed to publish core NATS message")?;
        runtime.record_message(payload.len(), Some(started.elapsed()));
    }
    client.flush().await.context("failed to flush producer")?;
    Ok(())
}

async fn produce_request_reply(
    client: Client,
    args: &ProducerArgs,
    runtime: &Runtime,
    payloads: Arc<PayloadFactory>,
) -> Result<()> {
    let subject: Subject = effective_subject_name(args.mode, &args.subject).into();
    let request_timeout = Duration::from_millis(args.request_timeout_ms);

    loop {
        if runtime.should_stop() {
            break;
        }

        runtime.limiter.wait_turn().await;
        let next = runtime.metrics.messages() + 1;
        let payload = payloads.build_payload(next);
        let started = Instant::now();
        let reply = timeout(
            request_timeout,
            client.request(subject.clone(), payload.clone()),
        )
        .await
        .context("request timed out")?
        .context("request failed")?;
        runtime.record_message(payload.len() + reply.payload.len(), Some(started.elapsed()));
    }
    Ok(())
}

async fn publish_jetstream_message(
    jetstream: &jetstream::Context,
    subject: Subject,
    payload: Bytes,
    mode: TestMode,
    producer_kind: &str,
    sequence: u64,
) -> Result<()> {
    if is_jetstream_exactly_once_mode(mode) {
        let mut headers = HeaderMap::new();
        headers.insert(
            NATS_MESSAGE_ID,
            format!("{}-{}-{}", std::process::id(), producer_kind, sequence).as_str(),
        );
        jetstream
            .publish_with_headers(subject, headers, payload)
            .await
            .context("failed to publish JetStream exactly-once message")?;
    } else {
        jetstream
            .publish(subject, payload)
            .await
            .context("failed to publish JetStream message")?;
    }
    Ok(())
}

async fn produce_jetstream(
    client: Client,
    args: &ProducerArgs,
    runtime: &Runtime,
    payloads: Arc<PayloadFactory>,
    kind: &str,
) -> Result<()> {
    let jetstream = jetstream::new(client.clone());
    let subject_name = effective_subject_name(args.mode, &args.subject);
    let stream_name = effective_stream_name(args.mode, &args.stream);
    ensure_jetstream_stream(&jetstream, args.mode, &stream_name, &subject_name).await?;
    let subject: Subject = subject_name.into();

    loop {
        if runtime.should_stop() {
            break;
        }

        runtime.limiter.wait_turn().await;
        let next = runtime.metrics.messages() + 1;
        let payload = payloads.build_payload(next);
        let started = Instant::now();
        publish_jetstream_message(
            &jetstream,
            subject.clone(),
            payload.clone(),
            args.mode,
            kind,
            next,
        )
        .await?;
        runtime.record_message(payload.len(), Some(started.elapsed()));
    }
    Ok(())
}

async fn consume_core(client: Client, args: &ConsumerArgs, runtime: Arc<Runtime>) -> Result<()> {
    let subject: Subject = effective_subject_name(args.mode, &args.subject).into();
    let mut subscription = client
        .subscribe(subject)
        .await
        .context("failed to create subscription")?;

    consume_subscription(&mut subscription, args.processing_delay, runtime).await
}

async fn consume_queue(client: Client, args: &ConsumerArgs, runtime: Arc<Runtime>) -> Result<()> {
    let subject: Subject = effective_subject_name(args.mode, &args.subject).into();
    let queue_group = effective_queue_group(args.mode, args.queue_group.as_deref())
        .expect("queue mode always resolves a queue group")
        .to_owned();
    let mut subscription = client
        .queue_subscribe(subject, queue_group)
        .await
        .context("failed to create queue subscription")?;

    consume_subscription(&mut subscription, args.processing_delay, runtime).await
}

async fn consume_request_reply(
    client: Client,
    args: &ConsumerArgs,
    runtime: Arc<Runtime>,
) -> Result<()> {
    let subject: Subject = effective_subject_name(args.mode, &args.subject).into();
    let queue_group = effective_queue_group(args.mode, args.queue_group.as_deref())
        .expect("req-reply mode always resolves a queue group")
        .to_owned();
    let mut subscription = client
        .queue_subscribe(subject, queue_group)
        .await
        .context("failed to create request/reply queue subscription")?;

    loop {
        if runtime.should_stop() {
            break;
        }

        let message = match timeout(Duration::from_millis(250), subscription.next()).await {
            Ok(Some(message)) => message,
            Ok(None) => break,
            Err(_) => continue,
        };

        runtime.limiter.wait_turn().await;
        maybe_delay(args.processing_delay).await;

        if let Some(reply_to) = message.reply.clone() {
            let response =
                Bytes::from(format!("wrecking-ball ack bytes={}", message.payload.len()));
            client
                .publish(reply_to, response)
                .await
                .context("failed to publish request/reply response")?;
        } else {
            warn!("request/reply message without reply subject");
        }

        runtime.record_message(message.payload.len(), extract_payload_age(&message.payload));
    }

    Ok(())
}

async fn consume_jetstream(
    client: Client,
    args: &ConsumerArgs,
    runtime: Arc<Runtime>,
    kind: &str,
) -> Result<()> {
    let jetstream = jetstream::new(client.clone());
    let subject_name = effective_subject_name(args.mode, &args.subject);
    let stream_name = effective_stream_name(args.mode, &args.stream);
    let stream =
        ensure_jetstream_stream(&jetstream, args.mode, &stream_name, &subject_name).await?;
    let consumer_name = effective_consumer_name(args.mode, &args.consumer, kind);
    let consumer = ensure_pull_consumer(
        &stream,
        &consumer_name,
        &subject_name,
        args.mode,
        args.jetstream_max_ack_pending,
    )
    .await?;
    let ack_mode = effective_jetstream_ack_mode_consumer(args);
    let mut confirmed_acker = if ack_mode == JetstreamAckMode::Confirmed {
        Some(ConfirmedAcker::new(&client).await?)
    } else {
        None
    };
    let fetch_batch_size =
        effective_jetstream_pull_batch_size(args.mode, args.jetstream_pull_batch);

    loop {
        let stop_requested = runtime.should_stop();
        if stop_requested && ack_mode == JetstreamAckMode::None {
            break;
        }

        if stop_requested
            && should_drain_jetstream_queue(args.mode)
            && jetstream_consumer_drained(&stream, &consumer).await?
        {
            break;
        }

        let mut batch = consumer
            .fetch()
            .max_messages(fetch_batch_size)
            .messages()
            .await
            .context("failed to fetch JetStream message batch")?;
        let mut received_any = false;

        while let Some(message) = batch.next().await {
            let message = message
                .map_err(|error| anyhow::anyhow!(error))
                .context("failed to receive JetStream message from batch")?;
            received_any = true;

            runtime.limiter.wait_turn().await;
            maybe_delay(args.processing_delay).await;
            let size = message.payload.len();
            let latency = extract_payload_age(&message.payload);
            acknowledge_jetstream_message(&message, ack_mode, confirmed_acker.as_mut()).await?;
            runtime.record_message(size, latency);

            if runtime.should_stop() && !should_drain_jetstream_queue(args.mode) {
                break;
            }
        }

        if runtime.should_stop() && !should_drain_jetstream_queue(args.mode) {
            break;
        }

        if !received_any {
            sleep(Duration::from_millis(10)).await;
        }
    }

    if effective_jetstream_ack_mode_consumer(args) != JetstreamAckMode::None {
        client.flush().await.map_err(|error| {
            anyhow::anyhow!("failed to flush JetStream consumer connection: {error}")
        })?;
    }

    Ok(())
}

async fn consume_subscription(
    subscription: &mut async_nats::Subscriber,
    processing_delay: Option<Duration>,
    runtime: Arc<Runtime>,
) -> Result<()> {
    loop {
        if runtime.should_stop() {
            break;
        }

        let message = match timeout(Duration::from_millis(250), subscription.next()).await {
            Ok(Some(message)) => message,
            Ok(None) => break,
            Err(_) => continue,
        };

        runtime.limiter.wait_turn().await;
        maybe_delay(processing_delay).await;
        runtime.record_message(message.payload.len(), extract_payload_age(&message.payload));
    }
    Ok(())
}

pub async fn maybe_delay(delay: Option<Duration>) {
    if let Some(delay) = delay {
        sleep(delay).await;
    }
}

pub fn parse_duration(input: &str) -> Result<Duration, String> {
    humantime::parse_duration(input).map_err(|error| error.to_string())
}

fn log_orchestrator_start(args: &OrchestratorCli, monitoring: &ResolvedMonitoring) {
    let connect = args
        .connect
        .resolve(args.profile)
        .expect("validated connect args");
    let effective_subject = effective_subject_name(args.mode, &args.subject);
    let effective_stream = effective_stream_name(args.mode, &args.stream);
    let effective_consumer = effective_consumer_name(args.mode, &args.consumer, "consumer");
    let mut lines = vec![
        format!("profile: {}", format_profile(args.profile)),
        format!("mode: {}", format_mode(args.mode)),
        format!("server: {}", connect.server),
        format!("tls: {}", yes_no(connect.tls)),
        format!("ca cert: {}", connect.ca_cert.as_deref().unwrap_or("-")),
        format!(
            "client cert: {}",
            connect.client_cert.as_deref().unwrap_or("-")
        ),
        format!(
            "client key: {}",
            connect.client_key.as_deref().unwrap_or("-")
        ),
        format!("subject: {}", effective_subject),
        format!("stream: {}", effective_stream),
        format!("consumer durable: {}", effective_consumer),
        format!(
            "queue group: {}",
            effective_queue_group(args.mode, args.queue_group.as_deref())
                .as_deref()
                .unwrap_or("-")
        ),
        format!("recreate: {}", yes_no(args.recreate)),
        format!("producers: {}", format_usize_grouped(args.producers)),
        format!("consumers: {}", format_usize_grouped(args.consumers)),
        format!("producer rate: {}", display_rate(args.producer_rate)),
        format!(
            "producer count: {}",
            display_optional_u64(args.producer_count)
        ),
        format!(
            "producer duration: {}",
            display_duration(args.producer_duration)
        ),
        format!("consumer rate: {}", display_rate(args.consumer_rate)),
        format!(
            "consumer count: {}",
            display_optional_u64(args.consumer_count)
        ),
        format!(
            "consumer duration: {}",
            display_duration(args.consumer_duration)
        ),
        format!(
            "processing delay: {}",
            display_duration(args.processing_delay)
        ),
        format!(
            "avg payload bytes: {}",
            format_usize_grouped(args.avg_payload_bytes)
        ),
        format!(
            "request timeout ms: {}",
            format_u64_grouped(args.request_timeout_ms)
        ),
        format!("drain ms: {}", format_u64_grouped(args.drain_ms)),
    ];
    if is_jetstream_mode(args.mode) {
        lines.push(format!(
            "jetstream ack mode: {}",
            format_jetstream_ack_mode(effective_jetstream_ack_mode(args))
        ));
        lines.push(format!(
            "jetstream max ack pending: {}",
            format_i64_grouped(effective_jetstream_max_ack_pending(
                args.mode,
                args.jetstream_max_ack_pending
            ))
        ));
        lines.push(format!(
            "jetstream pull batch: {}",
            format_usize_grouped(effective_jetstream_pull_batch_size(
                args.mode,
                args.jetstream_pull_batch
            ))
        ));
    }
    lines.extend(render_monitoring_start_lines(monitoring));
    print_block("Wreck Test", &lines);
}

fn log_producer_start(
    kind: &str,
    args: &ProducerArgs,
    monitoring: &ResolvedMonitoring,
    average_bytes: usize,
) {
    let connect = args
        .connect
        .resolve(args.profile)
        .expect("validated connect args");
    let effective_subject = effective_subject_name(args.mode, &args.subject);
    let effective_stream = effective_stream_name(args.mode, &args.stream);
    let mut lines = vec![
        format!("profile: {}", format_profile(args.profile)),
        format!("mode: {}", format_mode(args.mode)),
        format!("server: {}", connect.server),
        format!("tls: {}", yes_no(connect.tls)),
        format!("subject: {}", effective_subject),
        format!("stream: {}", effective_stream),
        format!("recreate: {}", yes_no(args.recreate)),
        format!("rate: {}", display_rate(args.rate)),
        format!("count: {}", display_optional_u64(args.count)),
        format!("duration: {}", display_duration(args.duration)),
        format!("avg payload bytes: {}", format_usize_grouped(average_bytes)),
        format!(
            "request timeout ms: {}",
            format_u64_grouped(args.request_timeout_ms)
        ),
    ];
    lines.extend(render_monitoring_start_lines(monitoring));
    print_block(&format!("Start {}", kind), &lines);
}

fn log_consumer_start(kind: &str, args: &ConsumerArgs, monitoring: &ResolvedMonitoring) {
    let connect = args
        .connect
        .resolve(args.profile)
        .expect("validated connect args");
    let effective_subject = effective_subject_name(args.mode, &args.subject);
    let effective_stream = effective_stream_name(args.mode, &args.stream);
    let effective_consumer = effective_consumer_name(args.mode, &args.consumer, kind);
    let mut lines = vec![
        format!("profile: {}", format_profile(args.profile)),
        format!("mode: {}", format_mode(args.mode)),
        format!("server: {}", connect.server),
        format!("tls: {}", yes_no(connect.tls)),
        format!("subject: {}", effective_subject),
        format!("stream: {}", effective_stream),
        format!("consumer durable: {}", effective_consumer),
        format!(
            "queue group: {}",
            effective_queue_group(args.mode, args.queue_group.as_deref())
                .as_deref()
                .unwrap_or("-")
        ),
        format!("recreate: {}", yes_no(args.recreate)),
        format!("rate: {}", display_rate(args.rate)),
        format!("count: {}", display_optional_u64(args.count)),
        format!("duration: {}", display_duration(args.duration)),
        format!(
            "processing delay: {}",
            display_duration(args.processing_delay)
        ),
    ];
    if is_jetstream_mode(args.mode) {
        lines.push(format!(
            "jetstream ack mode: {}",
            format_jetstream_ack_mode(effective_jetstream_ack_mode_consumer(args))
        ));
        lines.push(format!(
            "jetstream max ack pending: {}",
            format_i64_grouped(effective_jetstream_max_ack_pending(
                args.mode,
                args.jetstream_max_ack_pending
            ))
        ));
        lines.push(format!(
            "jetstream pull batch: {}",
            format_usize_grouped(effective_jetstream_pull_batch_size(
                args.mode,
                args.jetstream_pull_batch
            ))
        ));
    }
    lines.extend(render_monitoring_start_lines(monitoring));
    print_block(&format!("Start {}", kind), &lines);
}

pub fn log_summary(summary: &RunSummary) {
    let elapsed_secs = summary.elapsed.as_secs_f64().max(0.001);
    let bytes_per_sec = summary.snapshot.bytes as f64 / elapsed_secs;
    let latency_sample_ratio = if summary.snapshot.messages == 0 {
        0.0
    } else {
        summary.snapshot.latency_samples as f64 / summary.snapshot.messages as f64
    };
    print_block(&format!("Summary {}", summary.kind), &{
        let mut lines = vec![
            format!("mode: {}", format_mode(summary.mode)),
            format!("elapsed: {:.3}s", summary.elapsed.as_secs_f64()),
            format!(
                "total messages: {}",
                format_u64_grouped(summary.snapshot.messages)
            ),
            format!(
                "total bytes: {}",
                format_u64_grouped(summary.snapshot.bytes)
            ),
            format!(
                "messages/sec: {:.2}",
                summary.snapshot.messages as f64 / elapsed_secs
            ),
            format!("bytes/sec: {:.2}", bytes_per_sec),
            format!("MiB/sec: {:.2}", bytes_per_sec / (1024.0 * 1024.0)),
            format!(
                "avg payload bytes: {:.2}",
                average_payload_bytes(&summary.snapshot)
            ),
            format!(
                "payload min/max bytes: {}/{}",
                format_u64_grouped(summary.snapshot.payload_min_bytes.unwrap_or_default()),
                format_u64_grouped(summary.snapshot.payload_max_bytes.unwrap_or_default())
            ),
            format!(
                "latency samples: {}",
                format_u64_grouped(summary.snapshot.latency_samples)
            ),
            format!("latency coverage: {:.4}", latency_sample_ratio),
            format!(
                "latency avg/min/max ms: {:.3}/{:.3}/{:.3}",
                summary
                    .snapshot
                    .latency_avg()
                    .map(duration_to_millis)
                    .unwrap_or_default(),
                summary
                    .snapshot
                    .latency_min
                    .map(duration_to_millis)
                    .unwrap_or_default(),
                summary
                    .snapshot
                    .latency_max
                    .map(duration_to_millis)
                    .unwrap_or_default()
            ),
            "payload histogram:".to_owned(),
            render_payload_histogram(&summary.snapshot.payload_histogram),
            "latency histogram:".to_owned(),
            render_latency_histogram(&summary.snapshot.latency_histogram),
        ];
        lines.extend(render_resource_usage_lines(summary));
        lines.extend(summary.notes.iter().map(|note| format!("note: {note}")));
        lines
    });
}

fn log_combined_summary(
    args: &OrchestratorCli,
    producers: &[RunSummary],
    consumers: &[RunSummary],
    resources: ResourceUsageSnapshot,
    notes: Vec<String>,
) {
    let combined_producer =
        producers
            .iter()
            .fold(SummarySnapshot::default(), |mut acc, summary| {
                acc.messages += summary.snapshot.messages;
                acc.bytes += summary.snapshot.bytes;
                acc.payload_min_bytes =
                    min_u64_option(acc.payload_min_bytes, summary.snapshot.payload_min_bytes);
                acc.payload_max_bytes =
                    max_u64_option(acc.payload_max_bytes, summary.snapshot.payload_max_bytes);
                for (index, count) in summary.snapshot.payload_histogram.iter().enumerate() {
                    acc.payload_histogram[index] += count;
                }
                acc.latency_samples += summary.snapshot.latency_samples;
                acc.latency_total += summary.snapshot.latency_total;
                acc.latency_min =
                    min_duration_option(acc.latency_min, summary.snapshot.latency_min);
                acc.latency_max =
                    max_duration_option(acc.latency_max, summary.snapshot.latency_max);
                for (index, count) in summary.snapshot.latency_histogram.iter().enumerate() {
                    acc.latency_histogram[index] += count;
                }
                acc
            });
    let combined = consumers
        .iter()
        .fold(SummarySnapshot::default(), |mut acc, summary| {
            acc.messages += summary.snapshot.messages;
            acc.bytes += summary.snapshot.bytes;
            acc.payload_min_bytes =
                min_u64_option(acc.payload_min_bytes, summary.snapshot.payload_min_bytes);
            acc.payload_max_bytes =
                max_u64_option(acc.payload_max_bytes, summary.snapshot.payload_max_bytes);
            for (index, count) in summary.snapshot.payload_histogram.iter().enumerate() {
                acc.payload_histogram[index] += count;
            }
            acc.latency_samples += summary.snapshot.latency_samples;
            acc.latency_total += summary.snapshot.latency_total;
            acc.latency_min = min_duration_option(acc.latency_min, summary.snapshot.latency_min);
            acc.latency_max = max_duration_option(acc.latency_max, summary.snapshot.latency_max);
            for (index, count) in summary.snapshot.latency_histogram.iter().enumerate() {
                acc.latency_histogram[index] += count;
            }
            acc
        });

    let elapsed = producers
        .iter()
        .map(|summary| summary.elapsed)
        .chain(consumers.iter().map(|summary| summary.elapsed))
        .max()
        .unwrap_or_default();

    let combined_summary = RunSummary {
        kind: "orchestrator-total".to_owned(),
        mode: args.mode,
        elapsed,
        snapshot: combined.clone(),
        resources,
        notes,
    };

    let total_producer_messages = combined_producer.messages;
    let total_consumer_messages = combined.messages;
    let expected_consumer_messages =
        expected_consumer_messages(args, total_producer_messages).max(total_producer_messages);
    let dropped_messages = expected_consumer_messages.saturating_sub(total_consumer_messages);
    let duplicate_or_extra_messages =
        total_consumer_messages.saturating_sub(expected_consumer_messages);
    let observed_delivery_ratio = ratio(total_producer_messages, total_consumer_messages);
    let expected_delivery_ratio = ratio(total_producer_messages, expected_consumer_messages);
    let delivery_success_ratio = ratio(expected_consumer_messages, total_consumer_messages);

    print_block(
        "Combined Totals",
        &[
            format!(
                "total producer messages: {}",
                format_u64_grouped(total_producer_messages)
            ),
            format!(
                "total consumer messages handled: {}",
                format_u64_grouped(total_consumer_messages)
            ),
            format!(
                "expected consumer deliveries: {}",
                format_u64_grouped(expected_consumer_messages)
            ),
            format!(
                "missing consumer deliveries: {}",
                format_u64_grouped(dropped_messages)
            ),
            format!(
                "extra consumer deliveries: {}",
                format_u64_grouped(duplicate_or_extra_messages)
            ),
            format!(
                "observed deliveries per produced: {:.6}x",
                observed_delivery_ratio
            ),
            format!(
                "expected deliveries per produced: {:.6}x",
                expected_delivery_ratio
            ),
            format!("delivery success ratio: {:.6}", delivery_success_ratio),
            format!(
                "produced bytes: {}",
                format_u64_grouped(combined_producer.bytes)
            ),
            format!("consumed bytes: {}", format_u64_grouped(combined.bytes)),
            format!(
                "byte delta: {}",
                format_i128_grouped(combined_producer.bytes as i128 - combined.bytes as i128)
            ),
        ],
    );

    log_summary(&combined_summary);
    if producers.len() > 1 {
        print_block("Producer Shares", &render_producer_share_lines(producers));
    }
    if consumers.len() > 1 {
        print_block("Consumer Shares", &render_consumer_share_lines(consumers));
    }
}

fn expected_consumer_messages(args: &OrchestratorCli, produced_messages: u64) -> u64 {
    let fanout = match args.mode {
        TestMode::Fanout | TestMode::JetstreamReplay => args.consumers.max(1) as u64,
        TestMode::Queue
        | TestMode::ReqReply
        | TestMode::JetstreamQueueStrict
        | TestMode::JetstreamQueueConcurrent
        | TestMode::JetstreamQueueStrictExactlyOnce
        | TestMode::JetstreamQueueConcurrentExactlyOnce => 1,
    };

    produced_messages.saturating_mul(fanout)
}

fn effective_queue_group(mode: TestMode, configured_group: Option<&str>) -> Option<String> {
    match mode {
        TestMode::Queue | TestMode::ReqReply => Some(
            configured_group
                .map(str::to_owned)
                .unwrap_or_else(|| format!("{DEFAULT_QUEUE_GROUP}_{}", mode_token(mode))),
        ),
        TestMode::Fanout
        | TestMode::JetstreamQueueStrict
        | TestMode::JetstreamQueueConcurrent
        | TestMode::JetstreamQueueStrictExactlyOnce
        | TestMode::JetstreamQueueConcurrentExactlyOnce
        | TestMode::JetstreamReplay => None,
    }
}

async fn ensure_jetstream_stream<'a>(
    jetstream: &'a jetstream::Context,
    mode: TestMode,
    stream: &'a str,
    subject: &'a str,
) -> Result<jetstream::stream::Stream> {
    match mode {
        TestMode::JetstreamReplay => ensure_replay_stream(jetstream, stream, subject).await,
        TestMode::JetstreamQueueStrict
        | TestMode::JetstreamQueueConcurrent
        | TestMode::JetstreamQueueStrictExactlyOnce
        | TestMode::JetstreamQueueConcurrentExactlyOnce => {
            ensure_workqueue_stream(jetstream, stream, subject).await
        }
        TestMode::Fanout | TestMode::Queue | TestMode::ReqReply => {
            bail!("mode {} does not use a JetStream stream", format_mode(mode))
        }
    }
}

fn should_drain_jetstream_queue(mode: TestMode) -> bool {
    matches!(
        mode,
        TestMode::JetstreamQueueStrict
            | TestMode::JetstreamQueueConcurrent
            | TestMode::JetstreamQueueStrictExactlyOnce
            | TestMode::JetstreamQueueConcurrentExactlyOnce
    )
}

fn effective_jetstream_max_ack_pending(mode: TestMode, configured: Option<i64>) -> i64 {
    configured.unwrap_or(match mode {
        TestMode::JetstreamQueueStrict | TestMode::JetstreamQueueStrictExactlyOnce => 1,
        TestMode::JetstreamQueueConcurrent
        | TestMode::JetstreamQueueConcurrentExactlyOnce
        | TestMode::JetstreamReplay => 1_000,
        _ => 1_000,
    })
}

fn effective_jetstream_pull_batch_size(mode: TestMode, configured: Option<usize>) -> usize {
    configured.unwrap_or(match mode {
        TestMode::JetstreamQueueStrict | TestMode::JetstreamQueueStrictExactlyOnce => 1,
        TestMode::JetstreamQueueConcurrent
        | TestMode::JetstreamQueueConcurrentExactlyOnce
        | TestMode::JetstreamReplay => 200,
        _ => 200,
    })
}

fn effective_jetstream_ack_mode(args: &OrchestratorCli) -> JetstreamAckMode {
    if is_jetstream_exactly_once_mode(args.mode) {
        JetstreamAckMode::Confirmed
    } else {
        args.jetstream_ack_mode
    }
}

fn effective_jetstream_ack_mode_consumer(args: &ConsumerArgs) -> JetstreamAckMode {
    if is_jetstream_exactly_once_mode(args.mode) {
        JetstreamAckMode::Confirmed
    } else {
        args.jetstream_ack_mode
    }
}

fn effective_consumer_name(mode: TestMode, base: &str, kind: &str) -> String {
    let base = if base == DEFAULT_CONSUMER_NAME && is_jetstream_mode(mode) {
        format!("{base}_{}", mode_token(mode))
    } else {
        base.to_owned()
    };

    if mode == TestMode::JetstreamReplay && kind.starts_with("consumer-") {
        format!("{base}_{}", kind.replace('-', "_"))
    } else {
        base
    }
}

fn effective_subject_name(mode: TestMode, base: &str) -> String {
    if base == DEFAULT_SUBJECT {
        format!("{base}.{}", mode_token(mode))
    } else {
        base.to_owned()
    }
}

fn effective_stream_name(mode: TestMode, base: &str) -> String {
    if base == DEFAULT_STREAM_NAME && is_jetstream_mode(mode) {
        format!("{base}_{}", mode_token(mode))
    } else {
        base.to_owned()
    }
}

fn mode_token(mode: TestMode) -> &'static str {
    match mode {
        TestMode::Fanout => "fanout",
        TestMode::Queue => "queue",
        TestMode::ReqReply => "req_reply",
        TestMode::JetstreamQueueStrict => "js_queue_strict",
        TestMode::JetstreamQueueConcurrent => "js_queue_concurrent",
        TestMode::JetstreamQueueStrictExactlyOnce => "js_queue_strict_exactly_once",
        TestMode::JetstreamQueueConcurrentExactlyOnce => "js_queue_concurrent_exactly_once",
        TestMode::JetstreamReplay => "js_replay",
    }
}

fn average_payload_bytes(snapshot: &SummarySnapshot) -> f64 {
    if snapshot.messages == 0 {
        0.0
    } else {
        snapshot.bytes as f64 / snapshot.messages as f64
    }
}

fn display_rate(rate: Option<u64>) -> String {
    rate.map(|value| format!("{}/s", format_u64_grouped(value)))
        .unwrap_or_else(|| "unlimited".to_owned())
}

fn display_optional_u64(value: Option<u64>) -> String {
    value
        .map(format_u64_grouped)
        .unwrap_or_else(|| "unbounded".to_owned())
}

fn display_duration(value: Option<Duration>) -> String {
    value
        .map(humantime::format_duration)
        .map(|value| value.to_string())
        .unwrap_or_else(|| "unbounded".to_owned())
}

fn render_monitoring_start_lines(monitoring: &ResolvedMonitoring) -> Vec<String> {
    let mut lines = vec![
        format!("self pid: {}", format_u32_grouped(monitoring.self_pid)),
        format!(
            "resource sample interval: {}",
            humantime::format_duration(monitoring.resource_sample_interval)
        ),
        format!(
            "monitored nats pid: {}",
            monitoring
                .nats_pid
                .map(format_u32_grouped)
                .unwrap_or_else(|| "-".to_owned())
        ),
    ];
    lines.extend(
        monitoring
            .notes
            .iter()
            .map(|note| format!("monitor note: {note}")),
    );
    lines
}

fn render_resource_usage_lines(summary: &RunSummary) -> Vec<String> {
    let mut lines = Vec::new();

    if let Some(process) = &summary.resources.self_process {
        lines.push(format!("self pid: {}", format_u32_grouped(process.pid)));
        lines.push(format!(
            "self cpu avg/peak: {:.2}% / {:.2}%",
            process.avg_cpu_percent, process.peak_cpu_percent
        ));
        lines.push(format!(
            "self rss avg/peak: {} / {}",
            format_bytes_binary(process.avg_rss_bytes),
            format_bytes_binary(process.peak_rss_bytes)
        ));
        lines.push(format!(
            "self samples rss/cpu: {}/{}",
            format_u64_grouped(process.rss_samples),
            format_u64_grouped(process.cpu_samples)
        ));
    }

    if let Some(process) = &summary.resources.nats_process {
        lines.push(format!("nats pid: {}", format_u32_grouped(process.pid)));
        lines.push(format!(
            "nats cpu avg/peak: {:.2}% / {:.2}%",
            process.avg_cpu_percent, process.peak_cpu_percent
        ));
        lines.push(format!(
            "nats rss avg/peak: {} / {}",
            format_bytes_binary(process.avg_rss_bytes),
            format_bytes_binary(process.peak_rss_bytes)
        ));
        lines.push(format!(
            "nats samples rss/cpu: {}/{}",
            format_u64_grouped(process.rss_samples),
            format_u64_grouped(process.cpu_samples)
        ));
    }

    lines
}

fn render_consumer_share_lines(consumers: &[RunSummary]) -> Vec<String> {
    let total_messages: u64 = consumers
        .iter()
        .map(|summary| summary.snapshot.messages)
        .sum();
    let total_bytes: u64 = consumers.iter().map(|summary| summary.snapshot.bytes).sum();
    let consumer_pids = consumers
        .iter()
        .filter_map(|summary| {
            summary
                .resources
                .self_process
                .as_ref()
                .map(|usage| usage.pid)
        })
        .collect::<Vec<_>>();
    let all_same_pid = consumer_pids
        .first()
        .is_some_and(|first| consumer_pids.iter().all(|pid| pid == first));

    let mut lines = consumers
        .iter()
        .map(|summary| {
            format!(
                "{}  messages {:>6.2}%  bytes {:>6.2}%",
                summary.kind,
                percent_of(summary.snapshot.messages, total_messages),
                percent_of(summary.snapshot.bytes, total_bytes)
            )
        })
        .collect::<Vec<_>>();

    if all_same_pid {
        if let Some(pid) = consumer_pids.first() {
            lines.push(format!(
                "cpu/rss share unavailable: all orchestrated consumers run in pid {}",
                format_u32_grouped(*pid)
            ));
        }
    }

    lines
}

fn render_producer_share_lines(producers: &[RunSummary]) -> Vec<String> {
    let total_messages: u64 = producers
        .iter()
        .map(|summary| summary.snapshot.messages)
        .sum();
    let total_bytes: u64 = producers.iter().map(|summary| summary.snapshot.bytes).sum();

    producers
        .iter()
        .map(|summary| {
            format!(
                "{}  messages {:>6.2}%  bytes {:>6.2}%",
                summary.kind,
                percent_of(summary.snapshot.messages, total_messages),
                percent_of(summary.snapshot.bytes, total_bytes)
            )
        })
        .collect()
}

fn format_bytes_binary(bytes: u64) -> String {
    const UNITS: [&str; 6] = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
    let mut value = bytes as f64;
    let mut unit_index = 0usize;
    while value >= 1024.0 && unit_index < UNITS.len() - 1 {
        value /= 1024.0;
        unit_index += 1;
    }
    format!(
        "{value:.2} {} ({} B)",
        UNITS[unit_index],
        format_u64_grouped(bytes)
    )
}

fn format_u32_grouped(value: u32) -> String {
    format_u64_grouped(value as u64)
}

fn format_usize_grouped(value: usize) -> String {
    format_u64_grouped(value as u64)
}

fn format_u64_grouped(value: u64) -> String {
    format_u128_grouped(value as u128)
}

fn format_i128_grouped(value: i128) -> String {
    if value < 0 {
        format!("-{}", format_u128_grouped(value.unsigned_abs()))
    } else {
        format_u128_grouped(value as u128)
    }
}

fn format_i64_grouped(value: i64) -> String {
    format_i128_grouped(value as i128)
}

fn format_u128_grouped(value: u128) -> String {
    let digits = value.to_string();
    let mut output = String::with_capacity(digits.len() + digits.len() / 3);
    let first_group_len = match digits.len() % 3 {
        0 => 3,
        len => len,
    };

    output.push_str(&digits[..first_group_len]);
    let mut index = first_group_len;
    while index < digits.len() {
        output.push(',');
        output.push_str(&digits[index..index + 3]);
        index += 3;
    }

    output
}

fn percent_of(value: u64, total: u64) -> f64 {
    if total == 0 {
        0.0
    } else {
        value as f64 * 100.0 / total as f64
    }
}

fn format_profile(profile: ConnectProfile) -> &'static str {
    match profile {
        ConnectProfile::Generic => "generic",
        ConnectProfile::Gap3 => "gap3",
    }
}

fn format_mode(mode: TestMode) -> &'static str {
    match mode {
        TestMode::Fanout => "fanout",
        TestMode::Queue => "queue",
        TestMode::ReqReply => "req-reply",
        TestMode::JetstreamQueueStrict => "js-queue-strict",
        TestMode::JetstreamQueueConcurrent => "js-queue-concurrent",
        TestMode::JetstreamQueueStrictExactlyOnce => "js-queue-strict-exactly-once",
        TestMode::JetstreamQueueConcurrentExactlyOnce => "js-queue-concurrent-exactly-once",
        TestMode::JetstreamReplay => "js-replay",
    }
}

fn format_jetstream_ack_mode(mode: JetstreamAckMode) -> &'static str {
    match mode {
        JetstreamAckMode::Ack => "ack",
        JetstreamAckMode::Confirmed => "confirmed",
        JetstreamAckMode::None => "none",
    }
}

fn is_jetstream_mode(mode: TestMode) -> bool {
    matches!(
        mode,
        TestMode::JetstreamQueueStrict
            | TestMode::JetstreamQueueConcurrent
            | TestMode::JetstreamQueueStrictExactlyOnce
            | TestMode::JetstreamQueueConcurrentExactlyOnce
            | TestMode::JetstreamReplay
    )
}

fn is_jetstream_exactly_once_mode(mode: TestMode) -> bool {
    matches!(
        mode,
        TestMode::JetstreamQueueStrictExactlyOnce | TestMode::JetstreamQueueConcurrentExactlyOnce
    )
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "yes"
    } else {
        "no"
    }
}

fn print_block(title: &str, lines: &[String]) {
    println!("\n{title}");
    for line in lines {
        for segment in line.lines() {
            println!("  {segment}");
        }
    }
}

fn render_payload_histogram(histogram: &[u64; SIZE_BUCKETS.len()]) -> String {
    render_histogram(
        histogram,
        &[
            "<=256B", "<=1KiB", "<=4KiB", "<=16KiB", "<=64KiB", "<=256KiB", "<=1MiB", ">1MiB",
        ],
    )
}

fn render_latency_histogram(histogram: &[u64; LATENCY_BUCKETS_NS.len()]) -> String {
    render_histogram(
        histogram,
        &[
            "<=1ms", "<=5ms", "<=10ms", "<=50ms", "<=100ms", "<=500ms", "<=1s", ">1s",
        ],
    )
}

fn render_histogram<const N: usize>(histogram: &[u64; N], labels: &[&str; N]) -> String {
    let total: u64 = histogram.iter().sum();
    if total == 0 {
        return "no samples".to_owned();
    }

    let max_label_width = labels.iter().map(|label| label.len()).max().unwrap_or(0);
    let max_count = histogram.iter().copied().max().unwrap_or(0);

    labels
        .iter()
        .zip(histogram.iter())
        .map(|(label, count)| {
            let width = if *count == 0 || max_count == 0 {
                0
            } else {
                (((*count as f64 / max_count as f64) * 24.0).round() as usize).max(1)
            };
            let bar = "#".repeat(width);
            format!(
                "{label:>label_width$}  {count:>16}  {percent:>6.2}%  {bar}",
                label_width = max_label_width,
                percent = *count as f64 * 100.0 / total as f64,
                bar = bar,
                count = format_u64_grouped(*count)
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn detect_local_nats_server_pids() -> Result<Vec<u32>> {
    let mut pids = Vec::new();
    for entry in fs::read_dir("/proc").context("failed to read /proc")? {
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => continue,
        };
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<u32>() else {
            continue;
        };
        if process_looks_like_nats_server(pid) {
            pids.push(pid);
        }
    }
    pids.sort_unstable();
    Ok(pids)
}

fn process_looks_like_nats_server(pid: u32) -> bool {
    let comm_path = format!("/proc/{pid}/comm");
    if let Ok(comm) = fs::read_to_string(comm_path) {
        if comm.trim() == "nats-server" {
            return true;
        }
    }

    let cmdline_path = format!("/proc/{pid}/cmdline");
    fs::read(cmdline_path)
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .is_some_and(|cmdline| cmdline.contains("nats-server"))
}

fn read_process_sample(pid: u32) -> Option<ProcessSample> {
    let stat_path = format!("/proc/{pid}/stat");
    let stat = fs::read_to_string(stat_path).ok()?;
    let suffix = stat.rsplit_once(") ")?.1;
    let fields = suffix.split_whitespace().collect::<Vec<_>>();
    let user_ticks = fields.get(11)?.parse::<u64>().ok()?;
    let system_ticks = fields.get(12)?.parse::<u64>().ok()?;
    let rss_bytes = read_process_rss_bytes(pid)?;

    Some(ProcessSample {
        cpu_ticks: user_ticks + system_ticks,
        rss_bytes,
    })
}

fn read_process_rss_bytes(pid: u32) -> Option<u64> {
    let status_path = format!("/proc/{pid}/status");
    let status = fs::read_to_string(status_path).ok()?;
    status.lines().find_map(|line| {
        let value = line.strip_prefix("VmRSS:")?.split_whitespace().next()?;
        value.parse::<u64>().ok().map(|kilobytes| kilobytes * 1024)
    })
}

fn read_total_cpu_ticks() -> Result<u64> {
    let stat = fs::read_to_string("/proc/stat").context("failed to read /proc/stat")?;
    let cpu_line = stat
        .lines()
        .find(|line| line.starts_with("cpu "))
        .context("missing cpu line in /proc/stat")?;
    Ok(cpu_line
        .split_whitespace()
        .skip(1)
        .filter_map(|value| value.parse::<u64>().ok())
        .sum())
}

fn cpu_percent(
    previous: ProcessSample,
    current: ProcessSample,
    total_delta: u64,
    cpu_count: f64,
) -> f64 {
    if total_delta == 0 {
        return 0.0;
    }

    let process_delta = current.cpu_ticks.saturating_sub(previous.cpu_ticks) as f64;
    (process_delta / total_delta as f64) * cpu_count * 100.0
}

fn extract_payload_age(payload: &[u8]) -> Option<Duration> {
    PayloadMeta::decode(payload)?.age()
}

fn nonzero_atomic_value(value: &AtomicU64) -> Option<u64> {
    match value.load(Ordering::Relaxed) {
        0 => None,
        value => Some(value),
    }
}

fn nonzero_atomic_duration(value: &AtomicU64) -> Option<Duration> {
    match value.load(Ordering::Relaxed) {
        0 => None,
        value => Some(Duration::from_nanos(value)),
    }
}

fn update_atomic_min(target: &AtomicU64, candidate: u64) {
    let mut current = target.load(Ordering::Relaxed);
    loop {
        if current != 0 && current <= candidate {
            return;
        }
        match target.compare_exchange(current, candidate, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return,
            Err(observed) => current = observed,
        }
    }
}

fn update_atomic_max(target: &AtomicU64, candidate: u64) {
    let mut current = target.load(Ordering::Relaxed);
    loop {
        if current >= candidate {
            return;
        }
        match target.compare_exchange(current, candidate, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return,
            Err(observed) => current = observed,
        }
    }
}

fn payload_bucket_index(bytes: usize) -> usize {
    SIZE_BUCKETS
        .iter()
        .position(|limit| bytes <= *limit)
        .unwrap_or(SIZE_BUCKETS.len() - 1)
}

fn latency_bucket_index(nanos: u64) -> usize {
    LATENCY_BUCKETS_NS
        .iter()
        .position(|limit| nanos <= *limit)
        .unwrap_or(LATENCY_BUCKETS_NS.len() - 1)
}

fn min_duration_option(left: Option<Duration>, right: Option<Duration>) -> Option<Duration> {
    match (left, right) {
        (Some(left), Some(right)) => Some(left.min(right)),
        (Some(left), None) => Some(left),
        (None, Some(right)) => Some(right),
        (None, None) => None,
    }
}

fn max_duration_option(left: Option<Duration>, right: Option<Duration>) -> Option<Duration> {
    match (left, right) {
        (Some(left), Some(right)) => Some(left.max(right)),
        (Some(left), None) => Some(left),
        (None, Some(right)) => Some(right),
        (None, None) => None,
    }
}

fn min_u64_option(left: Option<u64>, right: Option<u64>) -> Option<u64> {
    match (left, right) {
        (Some(left), Some(right)) => Some(left.min(right)),
        (Some(left), None) => Some(left),
        (None, Some(right)) => Some(right),
        (None, None) => None,
    }
}

fn max_u64_option(left: Option<u64>, right: Option<u64>) -> Option<u64> {
    match (left, right) {
        (Some(left), Some(right)) => Some(left.max(right)),
        (Some(left), None) => Some(left),
        (None, Some(right)) => Some(right),
        (None, None) => None,
    }
}

fn ratio(expected: u64, actual: u64) -> f64 {
    if expected == 0 {
        0.0
    } else {
        actual as f64 / expected as f64
    }
}

fn unix_time_nanos() -> u64 {
    duration_to_nanos_u64(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock is after UNIX_EPOCH"),
    )
}

fn duration_to_nanos_u64(duration: Duration) -> u64 {
    duration.as_nanos().min(u64::MAX as u128) as u64
}

fn duration_to_millis(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

fn duration_from_nanos(nanos: u128) -> Duration {
    Duration::from_nanos(nanos.min(u64::MAX as u128) as u64)
}
