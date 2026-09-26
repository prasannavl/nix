//! Crash-released builder garbage-collection lease.
//!
//! A dedicated SSH child holds the builder's shared store lock. The builder
//! helper releases that lock when this process closes stdin, the transport
//! dies, or heartbeats stop. Nothing persistent is created on the builder.

use std::io::{self, BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use sha2::{Digest, Sha256};

const READY_TIMEOUT: Duration = Duration::from_secs(35);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InvocationId(String);

impl InvocationId {
    pub fn derive(run_id: &str, started_epoch: u64, process_id: u32) -> Self {
        let mut digest = Sha256::new();
        digest.update(run_id.as_bytes());
        digest.update(b"\n");
        digest.update(started_epoch.to_string().as_bytes());
        digest.update(b"\n");
        digest.update(process_id.to_string().as_bytes());
        digest.update(b"\n");
        let value = format!("{:x}", digest.finalize());
        Self(value[..32].to_owned())
    }
}

impl std::fmt::Display for InvocationId {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct LeaseEpoch(u64);

impl LeaseEpoch {
    pub const fn initial() -> Self {
        Self(1)
    }

    fn next(self) -> Result<Self> {
        self.0
            .checked_add(1)
            .map(Self)
            .context("builder lease epoch overflow")
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LeaseProcessSpec {
    pub authority: String,
    pub program: String,
    pub args: Vec<String>,
    pub cwd: PathBuf,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LeaseObservation {
    pub epoch: LeaseEpoch,
    /// True when protection was interrupted and a replacement lease was
    /// acquired. Callers must revalidate builder paths from an older epoch.
    pub reacquired: bool,
}

pub trait ActiveLease: Send {
    fn confirm(&mut self) -> Result<()>;
    fn confirm_with_timeout(&mut self, _timeout: Duration) -> Result<()> {
        self.confirm()
    }
    fn release(&mut self);
}

pub trait LeaseConnector: Send + Sync {
    fn connect(&self, spec: &LeaseProcessSpec) -> Result<Box<dyn ActiveLease>>;
    fn connect_with_timeout(
        &self,
        spec: &LeaseProcessSpec,
        _timeout: Duration,
    ) -> Result<Box<dyn ActiveLease>> {
        self.connect(spec)
    }
}

#[derive(Clone, Copy, Debug)]
pub struct LeaseRetryPolicy {
    attempts: usize,
    delay: Duration,
    timeout: Duration,
}

impl LeaseRetryPolicy {
    pub fn new(attempts: usize, delay: Duration, timeout: Duration) -> Result<Self> {
        if attempts == 0 || timeout.is_zero() {
            bail!("builder lease retries need positive attempts and timeout");
        }
        Ok(Self {
            attempts,
            delay,
            timeout,
        })
    }

    pub fn transport(attempts: usize, delay: Duration) -> Result<Self> {
        let mut timeout = (READY_TIMEOUT + HEARTBEAT_TIMEOUT)
            .saturating_mul(u32::try_from(attempts).unwrap_or(u32::MAX));
        let waits = attempts.saturating_sub(1);
        for attempt in 1..=waits.min(32) {
            timeout = timeout.saturating_add(Self::backoff(delay, attempt));
        }
        if waits > 32 {
            timeout = timeout.saturating_add(
                Self::backoff(delay, 32)
                    .saturating_mul(u32::try_from(waits - 32).unwrap_or(u32::MAX)),
            );
        }
        Self::new(attempts, delay, timeout)
    }

    fn backoff(delay: Duration, attempt: usize) -> Duration {
        delay.saturating_mul(
            1_u32
                .checked_shl((attempt - 1).min(31) as u32)
                .unwrap_or(u32::MAX),
        )
    }
}

pub trait LeaseRetryClock: Send + Sync {
    fn now(&self) -> Duration;
    fn wait(&self, duration: Duration);
}

struct SystemLeaseRetryClock(Instant);

impl LeaseRetryClock for SystemLeaseRetryClock {
    fn now(&self) -> Duration {
        self.0.elapsed()
    }
    fn wait(&self, duration: Duration) {
        thread::sleep(duration);
    }
}

#[derive(Default)]
pub struct SystemLeaseConnector;

impl LeaseConnector for SystemLeaseConnector {
    fn connect(&self, spec: &LeaseProcessSpec) -> Result<Box<dyn ActiveLease>> {
        self.connect_with_timeout(spec, READY_TIMEOUT)
    }

    fn connect_with_timeout(
        &self,
        spec: &LeaseProcessSpec,
        timeout: Duration,
    ) -> Result<Box<dyn ActiveLease>> {
        Ok(Box::new(SystemActiveLease::spawn(
            spec,
            timeout.min(READY_TIMEOUT),
        )?))
    }
}

struct CoordinatorState {
    authority: Option<LeaseProcessSpec>,
    epoch: LeaseEpoch,
    active: Option<Box<dyn ActiveLease>>,
    ever_acquired: bool,
}

/// Serialized lease acquisition shared by all parallel build/deploy workers.
pub struct BuilderLeaseCoordinator {
    connector: Arc<dyn LeaseConnector>,
    state: Mutex<CoordinatorState>,
    retry: LeaseRetryPolicy,
    clock: Arc<dyn LeaseRetryClock>,
    cancelled: Option<Arc<dyn Fn() -> bool + Send + Sync>>,
}

impl Default for BuilderLeaseCoordinator {
    fn default() -> Self {
        Self::new(Arc::new(SystemLeaseConnector))
    }
}

impl BuilderLeaseCoordinator {
    pub fn new(connector: Arc<dyn LeaseConnector>) -> Self {
        Self::with_retry_policy(
            connector,
            LeaseRetryPolicy::transport(3, Duration::from_secs(2))
                .expect("valid default lease retry policy"),
        )
    }

    pub fn with_retry_policy(connector: Arc<dyn LeaseConnector>, retry: LeaseRetryPolicy) -> Self {
        Self::with_retry_clock(
            connector,
            retry,
            Arc::new(SystemLeaseRetryClock(Instant::now())),
        )
    }

    pub fn with_retry_clock(
        connector: Arc<dyn LeaseConnector>,
        retry: LeaseRetryPolicy,
        clock: Arc<dyn LeaseRetryClock>,
    ) -> Self {
        Self {
            connector,
            retry,
            clock,
            cancelled: None,
            state: Mutex::new(CoordinatorState {
                authority: None,
                epoch: LeaseEpoch::initial(),
                active: None,
                ever_acquired: false,
            }),
        }
    }

    pub fn with_cancellation(mut self, cancelled: Arc<dyn Fn() -> bool + Send + Sync>) -> Self {
        self.cancelled = Some(cancelled);
        self
    }

    pub fn ensure(&self, spec: &LeaseProcessSpec) -> Result<LeaseObservation> {
        self.require_not_cancelled()?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow::anyhow!("builder lease coordinator is poisoned"))?;
        match &state.authority {
            Some(authority) if authority.authority != spec.authority => {
                bail!("builder lease authority changed within one invocation")
            }
            _ => state.authority = Some(spec.clone()),
        }

        if let Some(active) = state.active.as_mut()
            && active.confirm_with_timeout(HEARTBEAT_TIMEOUT).is_ok()
        {
            self.require_not_cancelled()?;
            return Ok(LeaseObservation {
                epoch: state.epoch,
                reacquired: false,
            });
        }

        if let Some(mut stale) = state.active.take() {
            stale.release();
        }
        let reacquired = state.ever_acquired;
        // A confirmed session earns a fresh reconnect budget. Failed connects
        // and newly acquired confirmations share that episode's budget; none
        // establishes an epoch or leaves an unconfirmed lease retained.
        let started = self.clock.now();
        for attempt in 1..=self.retry.attempts {
            self.require_not_cancelled()?;
            let remaining = self.retry_remaining(started)?;
            let error = match self.connector.connect_with_timeout(spec, remaining) {
                Ok(mut active) => {
                    let confirmation = match self.retry_remaining(started) {
                        Ok(remaining) => {
                            active.confirm_with_timeout(remaining.min(HEARTBEAT_TIMEOUT))
                        }
                        Err(error) => Err(error),
                    };
                    match confirmation {
                        Ok(()) => {
                            if let Err(error) = self
                                .retry_remaining(started)
                                .and_then(|_| self.require_not_cancelled())
                            {
                                active.release();
                                return Err(error);
                            }
                            let epoch = if reacquired {
                                state.epoch.next()
                            } else {
                                Ok(state.epoch)
                            };
                            let epoch = match epoch {
                                Ok(epoch) => epoch,
                                Err(error) => {
                                    active.release();
                                    return Err(error);
                                }
                            };
                            state.epoch = epoch;
                            state.active = Some(active);
                            state.ever_acquired = true;
                            return Ok(LeaseObservation { epoch, reacquired });
                        }
                        Err(error) => {
                            active.release();
                            error.context("confirm acquired builder lease")
                        }
                    }
                }
                Err(error) => error.context("connect builder lease transport"),
            };
            self.retry_remaining(started).with_context(|| {
                format!("builder lease acquisition time budget exhausted; last failure: {error:#}")
            })?;
            self.require_not_cancelled()?;
            if attempt == self.retry.attempts {
                return Err(error).context("builder lease acquisition retry attempts exhausted");
            }
            self.wait_for_retry(
                LeaseRetryPolicy::backoff(self.retry.delay, attempt)
                    .min(self.retry_remaining(started)?),
            )?;
        }
        unreachable!("positive lease retry attempts always return")
    }

    fn require_not_cancelled(&self) -> Result<()> {
        if self.cancelled.as_ref().is_some_and(|cancelled| cancelled()) {
            bail!("builder lease acquisition cancelled");
        }
        Ok(())
    }

    fn retry_remaining(&self, started: Duration) -> Result<Duration> {
        let elapsed = self.clock.now().saturating_sub(started);
        let remaining = self.retry.timeout.saturating_sub(elapsed);
        if remaining.is_zero() {
            bail!("builder lease acquisition time budget exhausted");
        }
        Ok(remaining)
    }

    fn wait_for_retry(&self, duration: Duration) -> Result<()> {
        let mut remaining = duration;
        while !remaining.is_zero() {
            self.require_not_cancelled()?;
            let step = if self.cancelled.is_some() {
                remaining.min(Duration::from_millis(100))
            } else {
                remaining
            };
            self.clock.wait(step);
            remaining = remaining.saturating_sub(step);
        }
        self.require_not_cancelled()
    }

    pub fn release(&self) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        if let Some(mut active) = state.active.take() {
            active.release();
        }
        state.authority = None;
        state.ever_acquired = false;
        state.epoch = LeaseEpoch::initial();
    }
}

impl Drop for BuilderLeaseCoordinator {
    fn drop(&mut self) {
        self.release();
    }
}

enum DriverCommand {
    Confirm(mpsc::Sender<Result<(), String>>, Duration),
    Stop,
}

struct SystemActiveLease {
    commands: mpsc::Sender<DriverCommand>,
    worker: Option<JoinHandle<()>>,
}

impl SystemActiveLease {
    fn spawn(spec: &LeaseProcessSpec, ready_timeout: Duration) -> Result<Self> {
        let mut command = Command::new(&spec.program);
        command
            .args(&spec.args)
            .current_dir(&spec.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = command.spawn().context("start builder lease transport")?;
        let stdin = child
            .stdin
            .take()
            .context("builder lease stdin is unavailable")?;
        let stdout = child
            .stdout
            .take()
            .context("builder lease stdout is unavailable")?;
        let stderr = child
            .stderr
            .take()
            .context("builder lease stderr is unavailable")?;
        let (lines_tx, lines_rx) = mpsc::channel();
        let stdout_worker = thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                if lines_tx.send(line).is_err() {
                    break;
                }
            }
        });
        let stderr_worker = thread::spawn(move || {
            let _ = io::copy(&mut BufReader::new(stderr), &mut io::sink());
        });
        let readiness = match lines_rx.recv_timeout(ready_timeout) {
            Ok(Ok(line)) if line == "READY" => Ok(()),
            Ok(Ok(line)) => Err(anyhow::anyhow!(
                "unexpected builder lease readiness frame: {line}"
            )),
            Ok(Err(error)) => Err(error).context("read builder lease readiness"),
            Err(_) => Err(anyhow::anyhow!("builder lease did not become ready")),
        };
        if let Err(error) = readiness {
            drop(stdin);
            let _ = child.kill();
            let _ = child.wait();
            let _ = stdout_worker.join();
            let _ = stderr_worker.join();
            return Err(error);
        }
        let (commands_tx, commands_rx) = mpsc::channel();
        let worker = thread::spawn(move || {
            lease_driver(
                child,
                stdin,
                lines_rx,
                commands_rx,
                stdout_worker,
                stderr_worker,
            )
        });
        Ok(Self {
            commands: commands_tx,
            worker: Some(worker),
        })
    }
}

impl ActiveLease for SystemActiveLease {
    fn confirm(&mut self) -> Result<()> {
        self.confirm_with_timeout(HEARTBEAT_TIMEOUT)
    }

    fn confirm_with_timeout(&mut self, timeout: Duration) -> Result<()> {
        let timeout = timeout.min(HEARTBEAT_TIMEOUT);
        let (reply_tx, reply_rx) = mpsc::channel();
        self.commands
            .send(DriverCommand::Confirm(reply_tx, timeout))
            .context("builder lease driver stopped")?;
        reply_rx
            .recv_timeout(timeout)
            .context("builder lease confirmation timed out")?
            .map_err(anyhow::Error::msg)
    }

    fn release(&mut self) {
        let _ = self.commands.send(DriverCommand::Stop);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

impl Drop for SystemActiveLease {
    fn drop(&mut self) {
        self.release();
    }
}

fn lease_driver(
    mut child: std::process::Child,
    mut stdin: std::process::ChildStdin,
    lines: mpsc::Receiver<io::Result<String>>,
    commands: mpsc::Receiver<DriverCommand>,
    stdout_worker: JoinHandle<()>,
    stderr_worker: JoinHandle<()>,
) {
    loop {
        let command = match commands.recv_timeout(HEARTBEAT_INTERVAL) {
            Ok(command) => command,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                let (reply, _receiver) = mpsc::channel();
                DriverCommand::Confirm(reply, HEARTBEAT_TIMEOUT)
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => DriverCommand::Stop,
        };
        match command {
            DriverCommand::Stop => break,
            DriverCommand::Confirm(reply, timeout) => {
                let result = (|| -> Result<(), String> {
                    writeln!(stdin, "PING").map_err(|error| error.to_string())?;
                    stdin.flush().map_err(|error| error.to_string())?;
                    match lines.recv_timeout(timeout) {
                        Ok(Ok(line)) if line == "PONG" => Ok(()),
                        Ok(Ok(line)) => Err(format!("unexpected builder lease frame: {line}")),
                        Ok(Err(error)) => Err(error.to_string()),
                        Err(_) => Err("builder lease heartbeat timed out".to_owned()),
                    }
                })();
                let failed = result.is_err();
                let _ = reply.send(result);
                if failed {
                    break;
                }
            }
        }
    }
    drop(stdin);
    let _ = child.kill();
    let _ = child.wait();
    let _ = stdout_worker.join();
    let _ = stderr_worker.join();
}
