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
use std::time::Duration;

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
    fn release(&mut self);
}

pub trait LeaseConnector: Send + Sync {
    fn connect(&self, spec: &LeaseProcessSpec) -> Result<Box<dyn ActiveLease>>;
}

#[derive(Default)]
pub struct SystemLeaseConnector;

impl LeaseConnector for SystemLeaseConnector {
    fn connect(&self, spec: &LeaseProcessSpec) -> Result<Box<dyn ActiveLease>> {
        Ok(Box::new(SystemActiveLease::spawn(spec)?))
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
}

impl Default for BuilderLeaseCoordinator {
    fn default() -> Self {
        Self::new(Arc::new(SystemLeaseConnector))
    }
}

impl BuilderLeaseCoordinator {
    pub fn new(connector: Arc<dyn LeaseConnector>) -> Self {
        Self {
            connector,
            state: Mutex::new(CoordinatorState {
                authority: None,
                epoch: LeaseEpoch::initial(),
                active: None,
                ever_acquired: false,
            }),
        }
    }

    pub fn ensure(&self, spec: &LeaseProcessSpec) -> Result<LeaseObservation> {
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
            && active.confirm().is_ok()
        {
            return Ok(LeaseObservation {
                epoch: state.epoch,
                reacquired: false,
            });
        }

        if let Some(mut stale) = state.active.take() {
            stale.release();
        }
        let reacquired = state.ever_acquired;
        if reacquired {
            state.epoch = state.epoch.next()?;
        }
        let mut active = self.connector.connect(spec)?;
        active.confirm().context("confirm acquired builder lease")?;
        state.active = Some(active);
        state.ever_acquired = true;
        Ok(LeaseObservation {
            epoch: state.epoch,
            reacquired,
        })
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
    Confirm(mpsc::Sender<Result<(), String>>),
    Stop,
}

struct SystemActiveLease {
    commands: mpsc::Sender<DriverCommand>,
    worker: Option<JoinHandle<()>>,
}

impl SystemActiveLease {
    fn spawn(spec: &LeaseProcessSpec) -> Result<Self> {
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
        let readiness = match lines_rx.recv_timeout(READY_TIMEOUT) {
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
        let (reply_tx, reply_rx) = mpsc::channel();
        self.commands
            .send(DriverCommand::Confirm(reply_tx))
            .context("builder lease driver stopped")?;
        reply_rx
            .recv_timeout(HEARTBEAT_TIMEOUT)
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
                DriverCommand::Confirm(reply)
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => DriverCommand::Stop,
        };
        match command {
            DriverCommand::Stop => break,
            DriverCommand::Confirm(reply) => {
                let result = (|| -> Result<(), String> {
                    writeln!(stdin, "PING").map_err(|error| error.to_string())?;
                    stdin.flush().map_err(|error| error.to_string())?;
                    match lines.recv_timeout(HEARTBEAT_TIMEOUT) {
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
