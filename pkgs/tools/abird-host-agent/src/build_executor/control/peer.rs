//! A caller UID reused by a source actor is not fresh caller authority. Pin the
//! connecting process before payload; veto workload placement and later movement.
//! This is not proof against delegated sockets or remote effects.

use std::fs::File;
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;

use anyhow::{Result, ensure};

// Linux 6.5+. No PID-open fallback: it could bind a reused numeric PID.
const SO_PEERPIDFD: libc::c_int = 77;
const MAX_PROC_BYTES: u64 = 4096;

pub(super) struct Peer {
    pub uid: u32,
    pid: i32,
    descriptor: OwnedFd,
    group: String,
}

impl Peer {
    pub fn open(stream: &UnixStream) -> Result<Self> {
        let credential = super::peer_credentials(stream)?;
        let mut descriptor: libc::c_int = -1;
        let mut length = std::mem::size_of_val(&descriptor) as libc::socklen_t;
        ensure!(
            unsafe {
                libc::getsockopt(
                    stream.as_raw_fd(),
                    libc::SOL_SOCKET,
                    SO_PEERPIDFD,
                    (&mut descriptor as *mut libc::c_int).cast(),
                    &mut length,
                )
            } == 0
                && descriptor >= 0,
            "control peer process unavailable"
        );
        let descriptor = unsafe { OwnedFd::from_raw_fd(descriptor) };
        ensure!(
            length as usize == std::mem::size_of::<libc::c_int>(),
            "invalid control peer descriptor"
        );
        let flags = unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_GETFD) };
        ensure!(
            flags >= 0 && flags & libc::FD_CLOEXEC != 0,
            "control peer descriptor is inheritable"
        );
        let mut peer = Self {
            uid: credential.uid,
            pid: credential.pid,
            descriptor,
            group: String::new(),
        };
        peer.alive()?;
        let info = read(&format!(
            "/proc/self/fdinfo/{}",
            peer.descriptor.as_raw_fd()
        ))?;
        ensure!(
            descriptor_pid(&info)? == peer.pid,
            "control peer PID differs"
        );
        peer.group = read(&format!("/proc/{}/cgroup", peer.pid))?;
        outside_workload(&peer.group)?;
        peer.check()?;
        Ok(peer)
    }

    pub fn check(&self) -> Result<()> {
        self.alive()?;
        let group = read(&format!("/proc/{}/cgroup", self.pid))?;
        ensure!(group == self.group, "control peer placement changed");
        outside_workload(&group)?;
        self.alive()
    }

    fn alive(&self) -> Result<()> {
        let mut poll = libc::pollfd {
            fd: self.descriptor.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        ensure!(
            unsafe { libc::poll(&mut poll, 1, 0) } == 0 && poll.revents == 0,
            "control peer lifetime ended or is unconfirmed"
        );
        Ok(())
    }
}

fn read(path: &str) -> Result<String> {
    let mut value = String::new();
    File::open(path)?
        .take(MAX_PROC_BYTES + 1)
        .read_to_string(&mut value)?;
    ensure!(
        value.len() as u64 <= MAX_PROC_BYTES,
        "control peer observation exceeds bound"
    );
    Ok(value)
}

fn descriptor_pid(info: &str) -> Result<i32> {
    let mut values = info.lines().filter_map(|line| line.strip_prefix("Pid:"));
    let pid: i32 = values
        .next()
        .ok_or_else(|| anyhow::anyhow!("control peer PID missing"))?
        .trim()
        .parse()?;
    ensure!(
        pid > 0 && values.next().is_none(),
        "invalid control peer PID"
    );
    Ok(pid)
}

fn outside_workload(group: &str) -> Result<()> {
    let path = group
        .strip_prefix("0::")
        .and_then(|value| value.strip_suffix('\n'))
        .ok_or_else(|| anyhow::anyhow!("control peer cgroup unavailable"))?;
    ensure!(
        path.starts_with('/')
            && !path.chars().any(char::is_control)
            && (path == "/"
                || path[1..]
                    .split('/')
                    .all(|part| !part.is_empty() && !matches!(part, "." | ".."))),
        "invalid control peer cgroup"
    );
    let workload = super::super::workload::BUDGET_RELATIVE;
    ensure!(
        path != workload
            && !path
                .strip_prefix(workload)
                .is_some_and(|suffix| suffix.starts_with('/')),
        "workload cannot act as a control caller"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn caller_uid_does_not_exempt_a_workload_group_or_descendant() {
        for group in [
            "0::/\n",
            "0::/user.slice/session.scope\n",
            "0::/abird.slice/abird-control.slice/abird-owned-fleet@id.service/observer\n",
            "0::/abird.slice/abird-build.slice-other\n",
        ] {
            outside_workload(group).unwrap();
        }
        for group in [
            "0::/abird.slice/abird-build.slice\n",
            "0::/abird.slice/abird-build.slice/abird-build-client@id.service/capture\n",
            "0::/abird.slice/abird-build.slice/nix-daemon.service/producer\n",
            "0::/../user.slice\n",
            "0:://user.slice\n",
            "0::/user.slice/\n",
            "0::/",
            "1:cpu:/user.slice\n",
            "0::/\n0::/user.slice\n",
        ] {
            assert!(outside_workload(group).is_err());
        }
    }

    #[test]
    fn pidfd_metadata_never_adopts_absent_exited_or_ambiguous_identity() {
        assert_eq!(
            descriptor_pid("pos:\t0\nPid:\t42\nNSpid:\t42\n").unwrap(),
            42
        );
        for info in [
            "",
            "Pid:\t-1\n",
            "Pid:\t0\n",
            "Pid:\t42\nPid:\t42\n",
            "Pid:\t42 other\n",
        ] {
            assert!(descriptor_pid(info).is_err());
        }
    }

    #[test]
    fn connected_peer_uses_cloexec_kernel_pidfd_not_a_caller_pid() {
        let (local, _remote) = UnixStream::pair().unwrap();
        let peer = Peer::open(&local).unwrap();
        assert_eq!(peer.pid, std::process::id() as i32);
        assert_eq!(peer.uid, unsafe { libc::geteuid() });
        peer.check().unwrap();
    }
}
