//! Unprivileged reconnect/control client. No journal access, execution or retries.

use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::{Result, ensure};

use super::control;
use super::events::EventCursor;
use super::protocol::{self, Command, Reply, Request, Response, Snapshot, Unconfirmed};

pub const SOCKET: &str = "/run/abird/abird-host-agent/owned-build/control.sock";
const TIMEOUT: Duration = Duration::from_secs(10);

fn unavailable() -> Response {
    Response {
        version: protocol::VERSION,
        reply: Reply::Unconfirmed {
            code: Unconfirmed::Unavailable,
        },
    }
}

// Nonblocking AF_UNIX admission: a full backlog is unavailable, not permission to
// wait indefinitely or retry a potentially delivered operation.
pub(super) fn connect(path: &Path) -> Result<UnixStream> {
    let bytes = path.as_os_str().as_bytes();
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    ensure!(
        path.is_absolute() && !bytes.contains(&0) && bytes.len() < address.sun_path.len(),
        "invalid control socket path"
    );
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (target, byte) in address.sun_path.iter_mut().zip(bytes) {
        *target = *byte as libc::c_char;
    }
    let fd = unsafe {
        libc::socket(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
            0,
        )
    };
    ensure!(fd >= 0, "control socket unavailable");
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    let length = std::mem::offset_of!(libc::sockaddr_un, sun_path) + bytes.len() + 1;
    ensure!(
        unsafe {
            libc::connect(
                fd.as_raw_fd(),
                (&address as *const libc::sockaddr_un).cast(),
                length as libc::socklen_t,
            )
        } == 0,
        "control connection unavailable"
    );
    let stream = UnixStream::from(fd);
    stream.set_nonblocking(false)?;
    Ok(stream)
}

fn exchange(path: &Path, uid: u32, command: Command, deadline: Instant) -> Result<Response> {
    let request = Request {
        version: protocol::VERSION,
        command,
    };
    let bytes = serde_json::to_vec(&request)?;
    // Validate before contacting a service. Never render request bytes/tokens.
    Request::decode(&bytes)?;
    if Instant::now() >= deadline {
        return Ok(unavailable());
    }
    let Ok(stream) = connect(path) else {
        return Ok(unavailable());
    };
    let response = control::exchange(
        stream,
        uid,
        &bytes,
        deadline.saturating_duration_since(Instant::now()),
    );
    Ok(if response.validate_for(&request).is_ok() {
        response
    } else {
        unavailable()
    })
}

/// One authenticated transaction to the installed root service. An unavailable
/// service remains unconfirmed; no legacy execution or alternate endpoint.
pub fn request(command: Command) -> Result<Response> {
    request_until(command, Instant::now() + TIMEOUT)
}

/// Share the observer's remaining lifetime; an RPC never renews that lifetime.
pub fn request_until(command: Command, deadline: Instant) -> Result<Response> {
    exchange(
        Path::new(SOCKET),
        0,
        command,
        deadline.min(Instant::now() + TIMEOUT),
    )
}

fn cancel_at(path: &Path, uid: u32, attempt_id: &str, deadline: Instant) -> Result<Response> {
    let response = exchange(
        path,
        uid,
        Command::Status {
            attempt_id: attempt_id.to_owned(),
        },
        deadline,
    )?;
    let expected = match &response.reply {
        Reply::Status { snapshot } => match snapshot.as_ref() {
            Snapshot::Live {
                outcome: None,
                ownership,
                ..
            } => ownership.clone(),
            // Preserve an already-settled outcome, never relabel it cancelled.
            _ => return Ok(response),
        },
        _ => return Ok(response),
    };
    exchange(
        path,
        uid,
        Command::Cancel {
            attempt_id: attempt_id.to_owned(),
            expected,
        },
        deadline,
    )
}

/// Observe the original fence, then request stop once within one I/O deadline.
/// Lost status sends no cancel; lost cancel reply requires a later status query.
/// StopRequested is an ACK, not descendant settlement.
pub fn cancel(attempt_id: &str) -> Result<Response> {
    cancel_at(Path::new(SOCKET), 0, attempt_id, Instant::now() + TIMEOUT)
}

pub fn events(attempt_id: &str, after: Option<u64>, limit: usize) -> Result<Response> {
    request(Command::Events {
        attempt_id: attempt_id.to_owned(),
        cursor: after.map(|after| EventCursor {
            attempt_id: attempt_id.to_owned(),
            after,
        }),
        limit,
    })
}

pub fn logs(
    attempt_id: &str,
    generation: Option<String>,
    offset: Option<u64>,
    limit: usize,
) -> Result<Response> {
    let cursor = match (generation, offset) {
        (None, None) => None,
        (Some(generation), Some(offset)) => Some(super::events::LogCursor {
            attempt_id: attempt_id.to_owned(),
            generation,
            offset,
        }),
        _ => anyhow::bail!("log generation and offset must be supplied together"),
    };
    request(Command::Logs {
        attempt_id: attempt_id.to_owned(),
        cursor,
        limit,
    })
}

#[cfg(test)]
mod tests;
