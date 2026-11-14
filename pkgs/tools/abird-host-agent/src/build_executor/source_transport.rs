//! Authenticated data delivery into an already admitted worker. No submission,
//! executable selection, execution receipt or retry after uncertain delivery.

use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::preparation::source::MAX_MATERIAL_BYTES;

pub(super) const DIRECTORY: &str = "/run/abird/owned-input";
pub(super) const RELAY_CUTOFF: &str = "ABIRD_OWNED_INPUT_CUTOFF_NS";

fn monotonic_ns() -> Result<u64> {
    let mut time: libc::timespec = unsafe { std::mem::zeroed() };
    ensure!(
        unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut time) } == 0,
        "input monotonic clock unavailable"
    );
    u64::try_from(time.tv_sec)?
        .checked_mul(1_000_000_000)
        .and_then(|value| value.checked_add(u64::try_from(time.tv_nsec).ok()?))
        .context("input clock overflow")
}

/// Sample order never extends the original cutoff across the SSH process.
pub(super) fn relay_cutoff(deadline: Instant) -> Result<u64> {
    let now = monotonic_ns()?;
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .context("input admission expired")?;
    now.checked_add(u64::try_from(remaining.as_nanos())?)
        .context("input cutoff overflow")
}

pub(super) fn relay_deadline(cutoff: u64) -> Result<Instant> {
    let now = Instant::now();
    let remaining = cutoff
        .checked_sub(monotonic_ns()?)
        .filter(|remaining| *remaining > 0)
        .context("input admission expired")?;
    now.checked_add(Duration::from_nanos(remaining))
        .context("input cutoff overflow")
}

/// Durable delivery state, independent of event/log rotation. Never a capture,
/// preparation, verification, settlement or release receipt.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum InputState {
    Ready,
    Received { digest: String },
}

impl InputState {
    pub(super) fn validate(&self) -> Result<()> {
        if let Self::Received { digest } = self {
            super::digest(digest)?;
        }
        Ok(())
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Receipt {
    pub version: u32,
    pub attempt_id: String,
    pub request_digest: String,
    pub material_digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct EndpointBinding {
    pub device: u64,
    pub inode: u64,
    pub parent_device: u64,
    pub parent_inode: u64,
}

/// Qualified cleanup only, after original producer settlement. A crash before
/// inode binding leaves residue unadoptable; absence alone never binds a socket.
pub(super) fn retire(
    journal: &super::journal::Journal,
    cleanup: &super::Ownership,
    target: &super::Ownership,
) -> Result<()> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt};
    journal.retirement_active(cleanup, super::daemon::now()?)?;
    let allocation = journal.source_allocation(target)?;
    let Some(binding) = &allocation.endpoint else {
        ensure!(
            absent(&target.attempt_id)?,
            "unbound source endpoint residue"
        );
        return Ok(());
    };
    let parent = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(DIRECTORY)?;
    let metadata = parent.metadata()?;
    ensure!(
        metadata.uid() == 0
            && metadata.mode() & 0o022 == 0
            && (metadata.dev(), metadata.ino()) == (binding.parent_device, binding.parent_inode),
        "source endpoint parent replaced"
    );
    match std::fs::symlink_metadata(path(&target.attempt_id)?) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
        Ok(metadata) => ensure!(
            metadata.file_type().is_socket()
                && metadata.uid() == 0
                && metadata.nlink() == 1
                && (metadata.dev(), metadata.ino()) == (binding.device, binding.inode),
            "source endpoint replaced"
        ),
    }
    journal.retirement_active(cleanup, super::daemon::now()?)?;
    let name = std::ffi::CString::new(target.attempt_id.as_str())?;
    ensure!(
        unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), 0) } == 0,
        std::io::Error::last_os_error()
    );
    parent.sync_all()?;
    ensure!(
        absent(&target.attempt_id)?,
        "source endpoint removal unconfirmed"
    );
    Ok(())
}

pub(super) fn absent(attempt: &str) -> Result<bool> {
    match std::fs::symlink_metadata(path(attempt)?) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
        Err(error) => Err(error.into()),
        Ok(_) => Ok(false),
    }
}

pub(super) fn path(attempt: &str) -> Result<PathBuf> {
    super::digest(attempt)?;
    Ok(PathBuf::from(DIRECTORY).join(attempt))
}

pub(super) fn read(
    stream: &mut UnixStream,
    mut bytes: &mut [u8],
    active: &mut impl FnMut() -> Result<()>,
) -> Result<()> {
    while !bytes.is_empty() {
        active()?;
        match stream.read(bytes) {
            Ok(0) => anyhow::bail!("incomplete source frame"),
            Ok(count) => bytes = &mut bytes[count..],
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::park_timeout(Duration::from_millis(10))
            }
            Err(error) => return Err(error.into()),
        }
    }
    active()
}

pub(super) fn write(
    stream: &mut UnixStream,
    mut bytes: &[u8],
    active: &mut impl FnMut() -> Result<()>,
) -> Result<()> {
    while !bytes.is_empty() {
        active()?;
        match stream.write(bytes) {
            Ok(0) => anyhow::bail!("source transport stopped"),
            Ok(count) => bytes = &bytes[count..],
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::park_timeout(Duration::from_millis(10))
            }
            Err(error) => return Err(error.into()),
        }
    }
    active()
}

pub(super) fn end(stream: &mut UnixStream, active: &mut impl FnMut() -> Result<()>) -> Result<()> {
    let mut byte = [0];
    loop {
        active()?;
        match stream.read(&mut byte) {
            Ok(0) => return Ok(()),
            Ok(_) => anyhow::bail!("pipelined source frame"),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::park_timeout(Duration::from_millis(10))
            }
            Err(error) => return Err(error.into()),
        }
    }
}

/// Caller has observed InputReady for this original attempt. A failed/lost reply
/// is unconfirmed, never permission to reconnect and resend source material.
pub fn deliver(attempt: &str, request_digest: &str, bytes: &[u8]) -> Result<Receipt> {
    deliver_until(
        attempt,
        request_digest,
        bytes,
        Instant::now() + Duration::from_secs(30),
    )
}

/// One original observer/data-lane deadline; no new budget on a later RPC.
pub fn deliver_until(
    attempt: &str,
    request_digest: &str,
    bytes: &[u8],
    deadline: Instant,
) -> Result<Receipt> {
    deliver_reader(
        attempt,
        request_digest,
        bytes.len(),
        &mut std::io::Cursor::new(bytes),
        deadline.min(Instant::now() + Duration::from_secs(30)),
    )
}

/// The relay keeps a fixed buffer. Installed remote SSH ingress (including
/// decryption and this relay) runs in the original admitted worker's subgroup.
/// A commit trailer is sent only after exact stdin length and EOF, so an aborted
/// relay cannot turn a complete payload prefix into accepted source.
pub fn deliver_stdin(attempt: &str, request_digest: &str, length: usize) -> Result<Receipt> {
    deliver_stdin_until(
        attempt,
        request_digest,
        length,
        Instant::now() + Duration::from_secs(30),
    )
}

/// Fixed admitted relay only. The receiver still authenticates its original
/// subgroup and checks its own admission throughout intake.
pub(super) fn deliver_stdin_until(
    attempt: &str,
    request_digest: &str,
    length: usize,
    deadline: Instant,
) -> Result<Receipt> {
    struct Flags(i32);
    impl Drop for Flags {
        fn drop(&mut self) {
            unsafe {
                libc::fcntl(0, libc::F_SETFL, self.0);
            }
        }
    }
    let flags = unsafe { libc::fcntl(0, libc::F_GETFL) };
    ensure!(
        flags >= 0 && unsafe { libc::fcntl(0, libc::F_SETFL, flags | libc::O_NONBLOCK) } == 0,
        "source stdin cannot be bounded"
    );
    let _flags = Flags(flags);
    deliver_reader(
        attempt,
        request_digest,
        length,
        &mut std::io::stdin().lock(),
        deadline,
    )
}

fn input_read(
    input: &mut impl Read,
    bytes: &mut [u8],
    active: &mut impl FnMut() -> Result<()>,
) -> Result<usize> {
    loop {
        active()?;
        match input.read(bytes) {
            Ok(count) => return Ok(count),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::park_timeout(Duration::from_millis(10))
            }
            Err(error) => return Err(error.into()),
        }
    }
}

fn deliver_reader(
    attempt: &str,
    request_digest: &str,
    length: usize,
    input: &mut impl Read,
    deadline: Instant,
) -> Result<Receipt> {
    use crate::sha256::Sha256;
    super::digest(request_digest)?;
    ensure!(
        (1..=MAX_MATERIAL_BYTES).contains(&length),
        "source frame exceeds bound"
    );
    let mut active = || {
        ensure!(
            Instant::now() < deadline,
            "source delivery deadline expired"
        );
        Ok(())
    };
    active()?;
    let mut stream = super::client::connect(&path(attempt)?)?;
    ensure!(
        super::control::peer_uid(&stream)? == 0,
        "source receiver is not root"
    );
    stream.set_nonblocking(true)?;
    write(
        &mut stream,
        &u32::try_from(length)?.to_be_bytes(),
        &mut active,
    )?;
    let mut remaining = length;
    let mut buffer = [0u8; 64 * 1024];
    let mut hash = Sha256::new();
    while remaining > 0 {
        let end = remaining.min(buffer.len());
        let count = input_read(input, &mut buffer[..end], &mut active)?;
        ensure!(count > 0, "incomplete source input");
        hash.update(&buffer[..count]);
        write(&mut stream, &buffer[..count], &mut active)?;
        remaining -= count;
    }
    ensure!(
        input_read(input, &mut [0], &mut active)? == 0,
        "trailing source input"
    );
    let digest = crate::sha256::to_hex(&hash.finish());
    write(&mut stream, digest.as_bytes(), &mut active)?;
    stream.shutdown(Shutdown::Write)?;
    let mut length = [0; 4];
    read(&mut stream, &mut length, &mut active)?;
    let length = u32::from_be_bytes(length) as usize;
    ensure!((1..=512).contains(&length), "source receipt exceeds bound");
    let mut body = vec![0; length];
    read(&mut stream, &mut body, &mut active)?;
    let receipt: Receipt =
        serde_json::from_slice(&body).map_err(|_| anyhow::anyhow!("invalid source receipt"))?;
    ensure!(
        receipt.version == 1
            && receipt.attempt_id == attempt
            && receipt.request_digest == request_digest
            && receipt.material_digest == digest,
        "source receipt differs"
    );
    // A complete matching receipt survives subsequent transport loss.
    Ok(receipt)
}
