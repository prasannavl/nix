use std::io::{Read, Write};
use std::os::fd::FromRawFd;
use std::os::unix::net::UnixStream;
use std::process::Command as Process;
use std::time::{Duration, Instant};

use anyhow::{Result, ensure};
use serde::Serialize;

use super::{Command, MAX_FRAME, Policy, Reply, SOCKET, State};
use crate::build_executor::{control, process};

fn read(stream: &mut UnixStream, deadline: Instant) -> Result<Vec<u8>> {
    timeouts(stream, deadline)?;
    let mut length = [0; 4];
    stream.read_exact(&mut length)?;
    let length = u32::from_be_bytes(length) as usize;
    ensure!(
        (1..=MAX_FRAME).contains(&length),
        "capture frame exceeds bound"
    );
    let mut bytes = vec![0; length];
    timeouts(stream, deadline)?;
    stream.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn write(stream: &mut UnixStream, value: &impl Serialize) -> Result<()> {
    let bytes = serde_json::to_vec(value)?;
    ensure!(
        !bytes.is_empty() && bytes.len() <= MAX_FRAME,
        "capture reply exceeds bound"
    );
    stream.write_all(&u32::try_from(bytes.len())?.to_be_bytes())?;
    stream.write_all(&bytes)?;
    Ok(())
}

fn timeouts(stream: &UnixStream, deadline: Instant) -> Result<()> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    ensure!(!remaining.is_zero(), "capture observation deadline expired");
    let timeout = Some(remaining.min(Duration::from_secs(3)));
    stream.set_read_timeout(timeout)?;
    stream.set_write_timeout(timeout)?;
    Ok(())
}

pub fn client(command: &Command) -> Result<Reply> {
    client_until(command, Instant::now() + Duration::from_secs(3))
}

pub fn client_until(command: &Command, deadline: Instant) -> Result<Reply> {
    ensure!(
        Instant::now() < deadline,
        "capture observation deadline expired"
    );
    let mut stream = crate::build_executor::client::connect(std::path::Path::new(SOCKET))?;
    ensure!(
        control::peer_uid(&stream)? == 0,
        "capture service is not root"
    );
    timeouts(&stream, deadline)?;
    write(&mut stream, command)?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let bytes = read(&mut stream, deadline)?;
    serde_json::from_slice(&bytes).map_err(|_| anyhow::anyhow!("invalid capture reply"))
}

/// systemd Accept=yes socket on stdin; source helpers cannot enter this service.
/// Authorization is the kernel peer UID, never a payload/account name.
pub fn serve() -> Result<()> {
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "capture control requires root"
    );
    process::protect_worker_memory()?;
    let policy = Policy::load()?;
    let mut stream = unsafe { UnixStream::from_raw_fd(0) };
    let deadline = Instant::now() + Duration::from_secs(3);
    timeouts(&stream, deadline)?;
    let uid = control::peer_uid(&stream)?;
    policy.caller(uid)?;
    let request: Command = serde_json::from_slice(&read(&mut stream, deadline)?)
        .map_err(|_| anyhow::anyhow!("invalid capture command"))?;
    let mut extra = [0];
    timeouts(&stream, deadline)?;
    ensure!(stream.read(&mut extra)? == 0, "trailing capture request");
    let reply = handle(&policy, uid, request).unwrap_or(Reply::Unconfirmed);
    write(&mut stream, &reply)
}

fn handle(policy: &Policy, uid: u32, request: Command) -> Result<Reply> {
    let state = State::open(policy)?;
    let status = match request {
        Command::Check => {
            // Ordinary callers cannot traverse root-only key directories. This
            // metadata-only preflight reads no key bytes and allocates no job.
            super::trusted_ssh_file(&policy.relay_key, true)?;
            return Ok(Reply::Ready);
        }
        Command::Begin { input } => {
            input.validate()?;
            // Private environment/bootstrap equivalence and live admission are
            // checked by the immutable worker before its first source effect.
            let (start, status) = state.begin(uid, *input)?;
            if start {
                let mut command = Process::new(&policy.systemctl);
                command
                    .args(["start", "--no-block", "--", &super::unit(&status.attempt)?])
                    .env_clear()
                    .env("PATH", "/var/empty")
                    .env("LC_ALL", "C");
                let output = process::transport::exchange(
                    &mut command,
                    &[],
                    process::Limits {
                        stdin: 1,
                        stdout: 4096,
                        stderr: 4096,
                    },
                    Instant::now() + Duration::from_secs(2),
                )?;
                ensure!(
                    output.complete && output.status.is_some_and(|status| status.success()),
                    "capture launch unconfirmed; never repeat StartUnit"
                );
            }
            status
        }
        Command::Revoke { input } => state.revoke(uid, *input)?,
        Command::Status {
            attempt,
            request_digest,
        } => state.status(uid, &attempt, &request_digest, false)?,
        Command::Acknowledge { request } => match state.acknowledge(uid, &request)? {
            Some(status) => status,
            None => {
                return Ok(Reply::RetentionClosed {
                    attempt: request.attempt_id()?,
                    request_digest: request.digest()?,
                });
            }
        },
        Command::Cancel {
            attempt,
            request_digest,
        } => state.status(uid, &attempt, &request_digest, true)?,
    };
    Ok(Reply::Status {
        status: Box::new(status),
    })
}
