//! Input-only SSH starts inside the original admitted worker. Its listener,
//! cryptographic monitor, session and forced relay inherit the owned budget;
//! no ordinary sshd session is moved/adopted and no PAM session may escape it.

use std::fs::{File, OpenOptions};
use std::io::Read;
use std::net::TcpListener;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, ensure};

use crate::build_executor::{Ownership, role::InputTransport, stage::Stage, workload};

struct Connection {
    stage: Stage,
    child: Child,
    exited: bool,
    relative: String,
}

pub(super) struct Ingress {
    listener: Option<TcpListener>,
    policy: InputTransport,
    owner: Ownership,
    cutoff: u64,
    connections: Vec<Connection>,
    finished: bool,
}

impl Ingress {
    pub(super) fn bind(
        policy: &InputTransport,
        owner: &Ownership,
        deadline: Instant,
    ) -> Result<Self> {
        workload::require_client_placement(owner)?;
        policy.ready()?;
        // Exclusive per-admission listener. An occupied port is a veto, never
        // permission to reuse another process or fall back to ordinary sshd.
        let listener = listen(policy.port)?;
        Ok(Self {
            listener: Some(listener),
            policy: policy.clone(),
            owner: owner.clone(),
            cutoff: crate::build_executor::source_transport::relay_cutoff(deadline)?,
            connections: Vec::new(),
            finished: false,
        })
    }

    pub(super) fn poll(&mut self) -> Result<()> {
        if let Some(connection) = self.connections.last_mut() {
            if !connection.exited {
                connection.exited = connection.child.try_wait()?.is_some();
            }
            if !connection.exited {
                return Ok(());
            }
            if !connection.stage.empty()? {
                connection.stage.request_stop()?;
                return Ok(());
            }
        }
        let listener = self.listener.as_ref().context("input listener closed")?;
        let stream = match listener.accept() {
            Ok((stream, _)) => stream,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                ) =>
            {
                return Ok(());
            }
            Err(error) => return Err(error.into()),
        };
        let ordinal = u16::try_from(self.connections.len())?;
        let mut stage = Stage::input_transport(&self.owner, ordinal)?;
        let relative = format!(
            "{}/{}/input-ssh-{ordinal:02}",
            workload::RELATIVE,
            self.owner.unit_name()?
        );
        let placement = stage.claim_process_fd()?;
        let mut command = Command::new(&self.policy.sshd);
        command
            .args(["-i", "-e", "-f"])
            .arg(&self.policy.configuration)
            // Server-owned environment; every connection retains this admission.
            .arg("-o")
            .arg(format!(
                "SetEnv={}={}",
                crate::build_executor::source_transport::RELAY_CUTOFF,
                self.cutoff
            ))
            .current_dir("/var/empty")
            .env_clear()
            .env("PATH", "/run/current-system/sw/bin")
            .env("LC_ALL", "C")
            .stdin(Stdio::from(OwnedFd::from(stream.try_clone()?)))
            .stdout(Stdio::from(OwnedFd::from(stream)))
            .stderr(Stdio::null());
        unsafe {
            command.pre_exec(move || {
                // Self-placement through the retained original subgroup FD,
                // before exec. Never attach a PID observed after spawn.
                if libc::write(placement, b"0\n".as_ptr().cast(), 2) != 2 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        match command.spawn() {
            Ok(child) => self.connections.push(Connection {
                stage,
                child,
                exited: false,
                relative,
            }),
            Err(error) => {
                let _ = stage.request_stop();
                return Err(error.into());
            }
        }
        Ok(())
    }

    /// UID alone does not prove work placement. Pin the connecting process with
    /// SO_PEERPIDFD, then inspect its proc directory while it is still live.
    /// A missing/reused PID can never authenticate this original subgroup.
    pub(super) fn authenticates(&self, stream: &UnixStream) -> Result<bool> {
        let Some(connection) = self.connections.last() else {
            return Ok(false);
        };
        if connection.stage.empty()? {
            return Ok(false);
        }
        let mut descriptor: libc::c_int = -1;
        let mut size = std::mem::size_of_val(&descriptor) as libc::socklen_t;
        ensure!(
            unsafe {
                libc::getsockopt(
                    stream.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_PEERPIDFD,
                    (&mut descriptor as *mut libc::c_int).cast(),
                    &mut size,
                )
            } == 0,
            "input peer pidfd unavailable"
        );
        ensure!(
            descriptor >= 0 && size as usize == std::mem::size_of_val(&descriptor),
            "invalid input peer pidfd"
        );
        let descriptor = unsafe { OwnedFd::from_raw_fd(descriptor) };
        let alive = || unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                descriptor.as_raw_fd(),
                0,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            ) == 0
        };
        if !alive() {
            return Ok(false);
        }
        let mut peer: libc::ucred = unsafe { std::mem::zeroed() };
        let mut size = std::mem::size_of_val(&peer) as libc::socklen_t;
        ensure!(
            unsafe {
                libc::getsockopt(
                    stream.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_PEERCRED,
                    (&mut peer as *mut libc::ucred).cast(),
                    &mut size,
                )
            } == 0
                && size as usize == std::mem::size_of_val(&peer)
                && peer.pid > 0,
            "input peer identity unavailable"
        );
        let process = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(format!("/proc/{}", peer.pid))?;
        let mut group = String::new();
        File::open(format!("/proc/self/fd/{}/cgroup", process.as_raw_fd()))?
            .take(4097)
            .read_to_string(&mut group)?;
        ensure!(group.len() <= 4096, "input peer placement exceeds bound");
        if !alive() {
            return Ok(false);
        }
        Ok(group == format!("0::{}\n", connection.relative) && !connection.stage.empty()?)
    }

    pub(super) fn close(&mut self) {
        self.listener.take();
    }

    pub(super) fn settle(&mut self, mut active: impl FnMut() -> Result<()>) -> Result<()> {
        self.close();
        // Let the bounded receipt/channel close leave normally. Lost delivery
        // ACKs reconcile from the durable intake record; they never resend.
        let graceful = Instant::now() + Duration::from_secs(2);
        loop {
            active()?;
            let mut empty = true;
            for connection in &mut self.connections {
                if !connection.exited {
                    connection.exited = connection.child.try_wait()?.is_some();
                }
                if !connection.stage.empty()? {
                    empty = false;
                    if Instant::now() >= graceful {
                        connection.stage.request_stop()?;
                    }
                }
            }
            if empty {
                self.finished = true;
                return Ok(());
            }
            std::thread::park_timeout(Duration::from_millis(10));
        }
    }
}

fn listen(port: u16) -> Result<TcpListener> {
    let fd = unsafe {
        libc::socket(
            libc::AF_INET6,
            libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            0,
        )
    };
    ensure!(fd >= 0, std::io::Error::last_os_error());
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    for (level, option, value) in [
        (libc::IPPROTO_IPV6, libc::IPV6_V6ONLY, 0i32),
        (libc::SOL_SOCKET, libc::SO_REUSEADDR, 1i32),
    ] {
        ensure!(
            unsafe {
                libc::setsockopt(
                    fd.as_raw_fd(),
                    level,
                    option,
                    (&value as *const i32).cast(),
                    std::mem::size_of_val(&value) as libc::socklen_t,
                )
            } == 0,
            std::io::Error::last_os_error()
        );
    }
    let mut address: libc::sockaddr_in6 = unsafe { std::mem::zeroed() };
    address.sin6_family = libc::AF_INET6 as libc::sa_family_t;
    address.sin6_port = port.to_be();
    ensure!(
        unsafe {
            libc::bind(
                fd.as_raw_fd(),
                (&address as *const libc::sockaddr_in6).cast(),
                std::mem::size_of_val(&address) as libc::socklen_t,
            )
        } == 0,
        std::io::Error::last_os_error()
    );
    // SO_REUSEADDR permits later attempts after TCP TIME_WAIT, never reuse of a
    // live listener. SO_REUSEPORT is deliberately not enabled.
    ensure!(
        unsafe { libc::listen(fd.as_raw_fd(), 8) } == 0,
        std::io::Error::last_os_error()
    );
    Ok(TcpListener::from(fd))
}

impl Drop for Ingress {
    fn drop(&mut self) {
        self.close();
        if !self.finished {
            for connection in &self.connections {
                let _ = connection.stage.request_stop();
            }
        }
        // Only the live handles above are used. On worker loss the existing
        // supervisor fences/stops the original whole unit/domain, not new PIDs.
    }
}
