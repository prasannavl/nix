//! Caller-side bounded transport only. No placement exemption for installed
//! producers: those still use Runner::run/run_as and their original admission.

use std::io::ErrorKind;
use std::os::fd::AsRawFd;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, ensure};

use super::{Limits, drain, nonblocking, write_input};

pub struct Observation {
    pub status: Option<ExitStatus>,
    pub stdout: Vec<u8>,
    pub complete: bool,
}

struct Leader(Child);
impl Drop for Leader {
    fn drop(&mut self) {
        // Only our unreaped leader. No process-group/name settlement inference.
        let _ = self.0.kill();
        let _ = self.0.try_wait();
    }
}

/// Full duplex from the first byte. Retain a complete matching application
/// receipt after timeout/EPIPE/SSH failure; the caller validates it, not exit 0.
pub fn exchange(
    command: &mut Command,
    input: &[u8],
    limits: Limits,
    deadline: Instant,
) -> Result<Observation> {
    exchange_while(command, input, limits, deadline, || Ok(()))
}

/// A local disconnect veto stops only this transport leader. Already received
/// bytes remain available for application receipt validation; no remote cancel.
pub fn exchange_while(
    command: &mut Command,
    input: &[u8],
    limits: Limits,
    deadline: Instant,
    connected: impl FnMut() -> Result<()>,
) -> Result<Observation> {
    limits.validate()?;
    ensure!(
        deadline.saturating_duration_since(Instant::now()) <= Duration::from_secs(30),
        "invalid caller transport bound"
    );
    exchange_inner(command, input, limits, deadline, connected)
}

/// Larger source frames require the existing authenticated capture lifetime.
/// Ordinary callers retain their original helper limits.
pub fn exchange_capture_while(
    command: &mut Command,
    input: &[u8],
    limits: Limits,
    deadline: Instant,
    scope: &crate::build_executor::capture_role::TransportScope,
    mut connected: impl FnMut() -> Result<()>,
) -> Result<Observation> {
    limits.validate_source(scope.material_limit()?)?;
    scope.require_deadline(deadline)?;
    exchange_inner(command, input, limits, deadline, || {
        scope.active()?;
        connected()
    })
}

fn exchange_inner(
    command: &mut Command,
    input: &[u8],
    limits: Limits,
    deadline: Instant,
    mut connected: impl FnMut() -> Result<()>,
) -> Result<Observation> {
    connected()?;
    ensure!(
        input.len() <= limits.stdin && Instant::now() < deadline,
        "invalid caller transport bound"
    );
    let mut leader = Leader(
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?,
    );
    let mut stdin = leader.0.stdin.take();
    let mut stdout = leader.0.stdout.take().context("caller stdout missing")?;
    let mut stderr = leader.0.stderr.take().context("caller stderr missing")?;
    for fd in [
        stdin.as_ref().context("caller stdin missing")?.as_raw_fd(),
        stdout.as_raw_fd(),
        stderr.as_raw_fd(),
    ] {
        nonblocking(fd)?;
    }
    let mut written = 0;
    let mut output = Vec::new();
    let mut errors = Vec::new();
    let mut input_failed = false;
    let mut stderr_failed = false;
    let mut status = None;
    while Instant::now() < deadline {
        let out_done = match drain(&mut stdout, &mut output, limits.stdout) {
            Ok(done) => done,
            Err(_) => {
                return Ok(Observation {
                    status,
                    stdout: Vec::new(),
                    complete: false,
                });
            }
        };
        let err_done = if stderr_failed {
            false
        } else {
            match drain(&mut stderr, &mut errors, limits.stderr) {
                Ok(done) => done,
                Err(_) => {
                    stderr_failed = true;
                    false
                }
            }
        };
        // Drain first: an ACK already in the pipe must survive disconnect.
        // Never write another request/input chunk after the local veto.
        if connected().is_err() {
            if drain(&mut stdout, &mut output, limits.stdout).is_err() {
                output.clear();
            }
            return Ok(Observation {
                status,
                stdout: output,
                complete: false,
            });
        }
        if written == input.len() {
            stdin = None;
        }
        if let Some(writer) = &mut stdin {
            let end = (written + super::CHUNK).min(input.len());
            match write_input(writer, &input[written..end]) {
                Ok(0) => {
                    input_failed = true;
                    stdin = None;
                }
                Ok(count) => written += count,
                Err(error)
                    if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted) => {}
                Err(_) => {
                    input_failed = true;
                    stdin = None;
                }
            }
        }
        if status.is_none() {
            status = leader.0.try_wait()?;
        }
        if status.is_some() && out_done && (err_done || stderr_failed) {
            return Ok(Observation {
                status,
                stdout: output,
                complete: !input_failed && !stderr_failed && written == input.len(),
            });
        }
        std::thread::park_timeout(
            Duration::from_millis(2).min(deadline.saturating_duration_since(Instant::now())),
        );
    }
    Ok(Observation {
        status,
        stdout: output,
        complete: false,
    })
}
