//! One authenticated local control message per accepted Unix connection.
//!
//! Separate from supervisor/controller locks and all Nix effects. Submission is
//! deliberately closed until the complete owned runtime is qualified. UID mapping
//! is local OS authority, not a claim to distinguish SSH keys sharing one account.

use std::collections::BTreeSet;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::identifier;
use super::journal::Journal;
use super::protocol::{
    self, Command, MAX_FRAME_BYTES, Rejection, Reply, Request, Response, Unconfirmed,
};
use super::request::{AdmissionPolicy, StorageIdentity, state_root};

mod peer;

const CONFIG_VERSION: u32 = 1;
const MAX_CONFIG_BYTES: usize = 32 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Principal {
    pub uid: u32,
    pub issuer: String,
}

/// Nix-generated service declaration; contains no caller tokens or signing keys.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub version: u32,
    pub identity: StorageIdentity,
    pub policy: AdmissionPolicy,
    /// Unprivileged client and Nix build-user identities from the qualified role.
    pub workload_uids: Vec<u32>,
    pub principals: Vec<Principal>,
    pub timeout_millis: u64,
    #[serde(default)]
    pub allow_submit: bool,
}

impl Config {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.version == CONFIG_VERSION,
            "unsupported control declaration"
        );
        self.identity.validate()?;
        self.policy.validate()?;
        ensure!(
            (1..=30_000).contains(&self.timeout_millis),
            "invalid control deadline"
        );
        let workers: BTreeSet<_> = self.workload_uids.iter().copied().collect();
        ensure!(
            !workers.is_empty()
                && workers.len() <= 512
                && workers.len() == self.workload_uids.len()
                && workers.iter().all(|uid| *uid > 0 && *uid < u32::MAX),
            "invalid workload identities"
        );
        ensure!(
            !self.principals.is_empty() && self.principals.len() <= 64,
            "invalid principal count"
        );
        let mut uids = BTreeSet::new();
        let mut issuers = BTreeSet::new();
        for principal in &self.principals {
            identifier(&principal.issuer)?;
            ensure!(
                !workers.contains(&principal.uid)
                    && principal.uid < u32::MAX
                    && uids.insert(principal.uid)
                    && issuers.insert(&principal.issuer),
                "worker, duplicate or ambiguous control principal"
            );
        }
        Ok(())
    }

    /// Bind authorization/limits without the one back-edge to the daemon digest.
    pub(super) fn binding_digest(&self) -> Result<String> {
        self.validate()?;
        let mut value = self.clone();
        value.policy.capacity_digest = "0".repeat(64);
        let mut bytes = b"abird-owned-control-binding-v1\n".to_vec();
        bytes.extend(serde_json::to_vec(&serde_json::to_value(value)?)?);
        Ok(crate::sha256::digest_bytes(&bytes))
    }

    pub fn load(path: &Path) -> Result<Self> {
        ensure!(path.is_absolute(), "control declaration must be absolute");
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(path)
            .context("open control declaration")?;
        let metadata = file.metadata()?;
        ensure!(
            metadata.is_file() && metadata.uid() == 0 && metadata.mode() & 0o022 == 0,
            "control declaration is not root-controlled"
        );
        let mut bytes = Vec::new();
        file.take(MAX_CONFIG_BYTES as u64 + 1)
            .read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() <= MAX_CONFIG_BYTES,
            "control declaration exceeds bound"
        );
        // Do not include serde diagnostics or input bytes in service logs.
        let config: Self = serde_json::from_slice(&bytes)
            .map_err(|_| anyhow::anyhow!("invalid control declaration"))?;
        config.validate()?;
        Ok(config)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FrameError {
    Invalid,
    Unavailable,
}

fn reply(reply: Reply) -> Response {
    Response {
        version: protocol::VERSION,
        reply,
    }
}
fn unavailable() -> Response {
    reply(Reply::Unconfirmed {
        code: Unconfirmed::Unavailable,
    })
}

/// Kernel credential of the connected Unix stream, never a UID/PID from a frame.
pub fn peer_uid(stream: &UnixStream) -> Result<u32> {
    Ok(peer_credentials(stream)?.uid)
}

fn peer_credentials(stream: &UnixStream) -> Result<libc::ucred> {
    let mut credential: libc::ucred = unsafe { std::mem::zeroed() };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    ensure!(
        unsafe {
            libc::getsockopt(
                stream.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                (&mut credential as *mut libc::ucred).cast(),
                &mut length,
            )
        } == 0
            && length as usize == std::mem::size_of::<libc::ucred>()
            && credential.pid > 0,
        "unavailable Unix peer identity"
    );
    Ok(credential)
}

fn remaining(deadline: Instant) -> std::result::Result<Duration, FrameError> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        Err(FrameError::Unavailable)
    } else {
        Ok(remaining)
    }
}

fn read_exact(
    stream: &mut UnixStream,
    mut bytes: &mut [u8],
    deadline: Instant,
) -> std::result::Result<(), FrameError> {
    while !bytes.is_empty() {
        stream
            .set_read_timeout(Some(remaining(deadline)?))
            .map_err(|_| FrameError::Unavailable)?;
        match stream.read(bytes) {
            Ok(0) => return Err(FrameError::Invalid),
            Ok(count) => {
                bytes = &mut bytes[count..];
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return Err(FrameError::Unavailable),
        }
    }
    Ok(())
}

/// Four-byte big-endian length and bounded payload. A complete validated reply
/// remains a receipt even if the peer subsequently resets the connection.
fn read_frame(
    stream: &mut UnixStream,
    deadline: Instant,
) -> std::result::Result<Vec<u8>, FrameError> {
    let mut prefix = [0; 4];
    read_exact(stream, &mut prefix, deadline)?;
    let length = u32::from_be_bytes(prefix) as usize;
    if length == 0 || length > MAX_FRAME_BYTES {
        return Err(FrameError::Invalid);
    }
    let mut bytes = vec![0; length];
    read_exact(stream, &mut bytes, deadline)?;
    Ok(bytes)
}

/// Request write-half EOF is mandatory before any effect. Never partially
/// dispatch pipelined/trailing data; responses need only their complete frame.
fn read_request(
    stream: &mut UnixStream,
    deadline: Instant,
) -> std::result::Result<Vec<u8>, FrameError> {
    let bytes = read_frame(stream, deadline)?;
    loop {
        stream
            .set_read_timeout(Some(remaining(deadline)?))
            .map_err(|_| FrameError::Unavailable)?;
        match stream.read(&mut [0; 1]) {
            Ok(0) => return Ok(bytes),
            Ok(_) => return Err(FrameError::Invalid),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return Err(FrameError::Unavailable),
        }
    }
}

fn write_frame(
    stream: &mut UnixStream,
    bytes: &[u8],
    deadline: Instant,
) -> std::result::Result<(), FrameError> {
    if bytes.is_empty() || bytes.len() > MAX_FRAME_BYTES {
        return Err(FrameError::Invalid);
    }
    let prefix = (bytes.len() as u32).to_be_bytes();
    for mut part in [&prefix[..], bytes] {
        while !part.is_empty() {
            stream
                .set_write_timeout(Some(remaining(deadline)?))
                .map_err(|_| FrameError::Unavailable)?;
            match stream.write(part) {
                Ok(0) => return Err(FrameError::Unavailable),
                Ok(count) => {
                    part = &part[count..];
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                Err(_) => return Err(FrameError::Unavailable),
            }
        }
    }
    stream
        .shutdown(Shutdown::Write)
        .map_err(|_| FrameError::Unavailable)
}

/// The opening closure is trusted service code. Neither journal paths nor server
/// time come from the caller. Authentication/framing precede every journal access.
pub fn serve_one(
    config: &Config,
    mut stream: UnixStream,
    open: impl FnOnce() -> Result<Journal>,
) -> Result<()> {
    config.validate()?;
    let deadline = Instant::now() + Duration::from_millis(config.timeout_millis);
    let peer = peer::Peer::open(&stream).ok();
    let issuer = peer.as_ref().and_then(|peer| {
        config
            .principals
            .iter()
            .find(|principal| principal.uid == peer.uid)
    });
    let response = if let Some(principal) = issuer {
        match read_request(&mut stream, deadline) {
            Ok(_) if peer.as_ref().is_none_or(|peer| peer.check().is_err()) => {
                reply(Reply::Rejected {
                    code: Rejection::Unauthorized,
                })
            }
            Ok(bytes) => match Request::decode(&bytes) {
                Err(code) => reply(Reply::Rejected { code }),
                // Closing new execution must not disable withdrawal of an in-flight
                // intent. Withdraw can only create stopped metadata, never work.
                Ok(request)
                    if !config.allow_submit
                        && matches!(
                            request.command,
                            Command::Submit { .. } | Command::SubmitNative { .. }
                        ) =>
                {
                    reply(Reply::Rejected {
                        code: Rejection::CapabilityUnavailable,
                    })
                }
                Ok(_) => match SystemTime::now().duration_since(UNIX_EPOCH) {
                    Err(_) => unavailable(),
                    Ok(time) => match open() {
                        Ok(journal)
                            if journal.identity() == &config.identity
                                && journal.admission_policy() == &config.policy =>
                        {
                            journal.handle(&principal.issuer, &bytes, time.as_secs())
                        }
                        Ok(_) => unavailable(),
                        Err(error) => reply(Reply::Unconfirmed {
                            code: error
                                .downcast_ref::<Unconfirmed>()
                                .copied()
                                .unwrap_or(Unconfirmed::Unavailable),
                        }),
                    },
                },
            },
            Err(FrameError::Invalid) => reply(Reply::Rejected {
                code: Rejection::InvalidRequest,
            }),
            Err(FrameError::Unavailable) => unavailable(),
        }
    } else {
        reply(Reply::Rejected {
            code: Rejection::Unauthorized,
        })
    };
    let bytes = response.encode()?;
    write_frame(&mut stream, &bytes, deadline).map_err(|error| {
        anyhow::anyhow!(match error {
            FrameError::Invalid => "control reply delivery unconfirmed (frame)",
            FrameError::Unavailable if Instant::now() >= deadline => {
                "control reply delivery unconfirmed (deadline)"
            }
            FrameError::Unavailable => "control reply delivery unconfirmed (peer)",
        })
    })
}

/// Contact failure or malformed reply is always unconfirmed, never remote failure
/// or permission to repeat realization. Authenticate the listener before secrets.
pub fn exchange(
    mut stream: UnixStream,
    expected_service_uid: u32,
    request: &[u8],
    timeout: Duration,
) -> Response {
    if timeout.is_zero()
        || timeout > Duration::from_secs(30)
        || peer_uid(&stream).ok() != Some(expected_service_uid)
    {
        return unavailable();
    }
    let deadline = Instant::now() + timeout;
    if request.is_empty() || request.len() > MAX_FRAME_BYTES {
        return unavailable();
    }
    // An authenticated peer may reject before consuming the request. A complete
    // response is still authoritative after EPIPE; otherwise remain unconfirmed.
    let _ = write_frame(&mut stream, request, deadline);
    read_frame(&mut stream, deadline)
        .ok()
        .and_then(|bytes| Response::decode(&bytes).ok())
        .unwrap_or_else(unavailable)
}

/// Only an accepted Unix stream on stdin, not a caller-supplied descriptor/path.
fn accepted_stdin() -> Result<UnixStream> {
    for (option, expected) in [
        (libc::SO_TYPE, libc::SOCK_STREAM),
        (libc::SO_DOMAIN, libc::AF_UNIX),
        (libc::SO_ACCEPTCONN, 0),
    ] {
        let mut value: libc::c_int = -1;
        let mut length = std::mem::size_of_val(&value) as libc::socklen_t;
        ensure!(
            unsafe {
                libc::getsockopt(
                    0,
                    libc::SOL_SOCKET,
                    option,
                    (&mut value as *mut libc::c_int).cast(),
                    &mut length,
                )
            } == 0
                && value == expected,
            "accepted Unix stream required on stdin"
        );
    }
    let descriptor: RawFd = unsafe { libc::fcntl(0, libc::F_DUPFD_CLOEXEC, 3) };
    ensure!(descriptor >= 0, "cannot retain accepted stream");
    // Newly duplicated descriptor is exclusively owned by this stream.
    Ok(unsafe { UnixStream::from_raw_fd(descriptor) })
}

pub fn run_service(config_path: &Path) -> Result<()> {
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "owned control service requires root"
    );
    let stream = accepted_stdin()?;
    let config = Config::load(config_path)?;
    let root = state_root(
        std::env::var_os("XDG_STATE_HOME").as_deref().map(Path::new),
        std::env::var_os("HOME").as_deref().map(Path::new),
    )?;
    serve_one(&config, stream, || {
        if config.allow_submit {
            super::bootstrap::validate(&root, &config.policy.capacity_digest)?;
        }
        Journal::open(&root, config.identity.clone(), config.policy.clone())
    })
}

#[cfg(test)]
mod tests;
