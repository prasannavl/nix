//! Bounded full-duplex I/O for the fixed acquisition helper. Its inherited run
//! exclusion survives parent loss. Reaping the helper is not daemon settlement.

use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, ensure};

struct Helper(Child);
impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let cutoff = Instant::now() + Duration::from_millis(100);
        loop {
            match self.0.try_wait() {
                Ok(Some(_)) | Err(_) => break,
                Ok(None) if Instant::now() < cutoff => {
                    std::thread::sleep(Duration::from_millis(2));
                }
                Ok(None) => break, // If still alive, the helper retains exclusion; no settlement claim.
            }
        }
    }
}

pub(super) fn run(
    command: &mut Command,
    input: &[u8],
    lock: &File,
    cutoff: Instant,
    active: impl FnMut() -> Result<()>,
) -> Result<Vec<u8>> {
    run_inner(command, input, Some(lock), cutoff, active)
}

/// A metadata-only helper has no run or import exclusion to inherit.
pub(super) fn preflight(command: &mut Command) -> Result<Vec<u8>> {
    run_inner(
        command,
        b"",
        None,
        Instant::now() + Duration::from_secs(10),
        crate::fleet::signal::check_interrupted,
    )
}

fn run_inner(
    command: &mut Command,
    input: &[u8],
    lock: Option<&File>,
    cutoff: Instant,
    mut active: impl FnMut() -> Result<()>,
) -> Result<Vec<u8>> {
    ensure!(
        input.len() <= super::MAX_REQUEST && Instant::now() < cutoff,
        "native acquisition input/deadline invalid"
    );
    active()?;
    let fd = lock.map(AsRawFd::as_raw_fd);
    let parent = unsafe { libc::getpid() };
    unsafe {
        command.pre_exec(move || {
            // Original open description, not another lock claim. Only this
            // trusted child may retain the lock across exec.
            if fd.is_some_and(|fd| libc::fcntl(fd, libc::F_SETFD, 0) != 0)
                || libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0
                || libc::getppid() != parent
            {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut helper = Helper(
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("start native acquisition helper")?,
    );
    let mut stdin = helper.0.stdin.take();
    let mut stdout = helper.0.stdout.take().context("native stdout missing")?;
    let mut stderr = helper.0.stderr.take().context("native stderr missing")?;
    for fd in [
        stdin.as_ref().context("native stdin missing")?.as_raw_fd(),
        stdout.as_raw_fd(),
        stderr.as_raw_fd(),
    ] {
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        ensure!(
            flags >= 0 && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == 0,
            "native pipe unavailable"
        );
    }
    let mut written = 0;
    let mut output = Vec::new();
    let mut errors = Vec::new();
    loop {
        let out_done = drain(&mut stdout, &mut output, super::MAX_REPLY)?;
        let err_done = drain(&mut stderr, &mut errors, 64 * 1024)?;
        if let Some(status) = helper.0.try_wait()?
            && out_done
            && err_done
        {
            ensure!(
                status.success() && written == input.len(),
                "native acquisition helper unconfirmed"
            );
            return Ok(output);
        }
        ensure!(
            Instant::now() < cutoff,
            "native acquisition deadline expired; import unconfirmed"
        );
        active()?;
        if let Some(writer) = &mut stdin {
            let end = (written + 8192).min(input.len());
            match writer.write(&input[written..end]) {
                Ok(0) if written != input.len() => anyhow::bail!("native acquisition input closed"),
                Ok(count) => written += count,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                    ) => {}
                Err(error) => return Err(error).context("deliver native acquisition input"),
            }
            if written == input.len() {
                stdin = None;
            }
        }
        std::thread::park_timeout(
            Duration::from_millis(5).min(cutoff.saturating_duration_since(Instant::now())),
        );
    }
}

fn drain(input: &mut impl Read, bytes: &mut Vec<u8>, bound: usize) -> Result<bool> {
    let mut buffer = [0u8; 4096];
    for _ in 0..8 {
        match input.read(&mut buffer) {
            Ok(0) => return Ok(true),
            Ok(count) => {
                ensure!(
                    bytes.len() + count <= bound,
                    "native acquisition output exceeds bound"
                );
                bytes.extend_from_slice(&buffer[..count]);
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => return Ok(false),
            Err(error) => return Err(error).context("read native acquisition output"),
        }
    }
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn helper_duplex_is_bounded_and_inherits_original_exclusion_descriptor() {
        let lock = tempfile::tempfile().unwrap();
        assert_eq!(
            unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );
        let mut command = Command::new("sh");
        command.args([
            "-c",
            &format!(
                "test -e /proc/self/fd/{} || exit 9; IFS= read -r value; printf done",
                lock.as_raw_fd()
            ),
        ]);
        let mut input = vec![b'x'; 256 * 1024];
        input.push(b'\n');
        assert_eq!(
            run(
                &mut command,
                &input,
                &lock,
                Instant::now() + Duration::from_secs(5),
                || Ok(())
            )
            .unwrap(),
            b"done"
        );
        // CLOEXEC is cleared only in the child descriptor table.
        assert_ne!(
            unsafe { libc::fcntl(lock.as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC,
            0
        );
    }

    #[test]
    fn cancellation_and_original_deadline_interrupt_blocked_native_helper() {
        let lock = tempfile::tempfile().unwrap();
        for cancelled in [false, true] {
            let start = Instant::now();
            let cutoff = start + Duration::from_millis(if cancelled { 1000 } else { 60 });
            let mut command = Command::new("sh");
            command.args(["-c", "while :; do :; done"]);
            let mut polls = 0;
            assert!(
                run(&mut command, b"", &lock, cutoff, || {
                    polls += 1;
                    ensure!(!cancelled || polls < 3, "durable cancellation");
                    Ok(())
                })
                .is_err()
            );
            assert!(start.elapsed() < Duration::from_secs(2));
        }
    }

    #[test]
    fn oversized_helper_reply_never_becomes_a_receipt() {
        let lock = tempfile::tempfile().unwrap();
        let mut command = Command::new("sh");
        command.args(["-c", "while :; do printf 0123456789; done"]);
        assert!(
            run(
                &mut command,
                b"",
                &lock,
                Instant::now() + Duration::from_secs(2),
                || Ok(())
            )
            .is_err()
        );
    }
}
