//! Bounded I/O for admitted, unprivileged helpers. Not an admission, source,
//! artifact or settlement receipt. Caller supplies immutable process policy and
//! a deadline derived from the original admission, never a fresh per-command TTL.
//! Raw capture stays private; errors/Debug never print argv, environment or bytes.

pub mod offline;
pub mod transport;

use std::io::{ErrorKind, Read, Write};
use std::os::fd::AsRawFd;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, ensure};

const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_SOURCE_BYTES: usize = 512 * 1024 * 1024;
const CHUNK: usize = 4096;
const POLL_CHUNKS: usize = 8;

/// Snapshot monotonic before wall time at entry. This cap never grows on clock
/// regression, helper restart or reconnect; callers also recheck journal leases.
/// Translate the original admitted reservation once; never renew its budget.
pub fn cutoff(
    reserved: Option<u64>,
    runtime: u64,
    wall: Duration,
    monotonic: Instant,
) -> Result<Instant> {
    let absolute = reserved
        .context("worker reservation missing")?
        .checked_add(runtime)
        .context("worker deadline overflow")?;
    let remaining = Duration::from_secs(absolute)
        .checked_sub(wall)
        .filter(|remaining| !remaining.is_zero())
        .context("worker deadline expired")?;
    monotonic
        .checked_add(remaining)
        .context("worker deadline overflow")
}

#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub stdin: usize,
    pub stdout: usize,
    pub stderr: usize,
}
impl Limits {
    fn validate(self) -> Result<()> {
        self.validate_source(MAX_BYTES)
    }

    fn validate_source(self, representation_limit: usize) -> Result<()> {
        ensure!(
            (1..=MAX_SOURCE_BYTES).contains(&representation_limit)
                && self.stdin <= representation_limit
                && (1..=representation_limit).contains(&self.stdout)
                && (1..=MAX_BYTES).contains(&self.stderr),
            "invalid helper capture limits"
        );
        Ok(())
    }
}

pub struct Captured {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}
impl std::fmt::Debug for Captured {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Captured")
            .field("status", &self.status)
            .field("stdout_bytes", &self.stdout.len())
            .field("stderr_bytes", &self.stderr.len())
            .finish()
    }
}

/// Reserve a descriptor before spawn; never overwrite std::process's exec-error
/// pipe or any other child setup FD with an assumed fixed number.
pub(super) struct DirectoryFd(std::fs::File);
impl DirectoryFd {
    pub(super) fn new(directory: &std::fs::File) -> Result<Self> {
        use std::os::fd::FromRawFd;
        let fd = unsafe { libc::fcntl(directory.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 6) };
        ensure!(
            fd >= 0,
            "duplicate scoped producer directory: {}",
            std::io::Error::last_os_error()
        );
        Ok(Self(unsafe { std::fs::File::from_raw_fd(fd) }))
    }
    pub(super) fn path(&self) -> std::path::PathBuf {
        format!("/proc/self/fd/{}", self.0.as_raw_fd()).into()
    }
}

/// One direct child, never PID lookup/adoption. The original spawn child stays
/// inside the same producer group and reports its namespace init's actual exit.
/// Closing its FD copies also releases std::process's exec-error pipe: spawn
/// must not wait for the complete checkout before starting bounded pipe I/O.
pub(super) fn namespace_child() -> std::io::Result<()> {
    // Raw fork-equivalent clone avoids libc atfork hooks in this pre-exec child.
    // No shared memory/FD table, alternate stack, signal changes or new owner.
    let child = unsafe {
        libc::syscall(
            libc::SYS_clone,
            libc::SIGCHLD as libc::c_ulong,
            0usize,
            0usize,
            0usize,
            0usize,
        )
    };
    if child < 0 {
        return Err(std::io::Error::last_os_error());
    }
    if child == 0 {
        return Ok(());
    }
    unsafe {
        if libc::syscall(libc::SYS_close_range, 0u32, u32::MAX, 0u32) != 0 {
            libc::_exit(125);
        }
        let mut status = 0;
        loop {
            let waited = libc::waitpid(child as libc::pid_t, &mut status, 0);
            if waited == child as libc::pid_t {
                break;
            }
            if waited < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            libc::_exit(125);
        }
        if libc::WIFEXITED(status) {
            libc::_exit(libc::WEXITSTATUS(status));
        }
        if libc::WIFSIGNALED(status) {
            let signal = libc::WTERMSIG(status);
            // Child-only restoration, not a change to the caller's handlers/mask.
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = libc::SIG_DFL;
            libc::sigemptyset(&mut action.sa_mask);
            libc::sigaction(signal, &action, std::ptr::null_mut());
            let mut mask: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut mask);
            libc::sigaddset(&mut mask, signal);
            libc::sigprocmask(libc::SIG_UNBLOCK, &mask, std::ptr::null_mut());
            libc::raise(signal);
        }
        libc::_exit(125);
    }
}

/// Dedicated exec'd helpers only. Exec resets dumpability, so the fixed entry
/// calls this before reading private inputs or invoking caller-controlled Git.
/// Same-UID helper descendants must not read the producer's memory/FD aliases.
pub fn protect_worker_memory() -> std::io::Result<()> {
    if unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

/// Dedicated native evaluator only, after its trusted library is loaded and
/// before source evaluation. Git/SSH/filter providers must run under a separate
/// non-native identity; this process cannot exec them, even from existing threads.
/// This is not filesystem, network or native-RPC effect closure.
pub fn restrict_worker_exec() -> std::io::Result<()> {
    #[cfg(target_arch = "x86_64")]
    let architecture = Some(0xc000_003eu32);
    #[cfg(target_arch = "aarch64")]
    let architecture = Some(0xc000_00b7u32);
    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    let architecture: Option<u32> = None;
    let architecture =
        architecture.ok_or_else(|| std::io::Error::from_raw_os_error(libc::EOPNOTSUPP))?;
    let statement = |code: u32, k: u32| libc::sock_filter {
        code: code as u16,
        jt: 0,
        jf: 0,
        k,
    };
    let jump = |code: u32, k: u32, jt: u8| libc::sock_filter {
        code: code as u16,
        jt,
        jf: 0,
        k,
    };
    let deny = libc::SECCOMP_RET_ERRNO | libc::EPERM as u32;
    // seccomp_data: nr at0, arch at4. Reject foreign ABI and x32, not just
    // the native exec syscall numbers. No pathname/argv/FD-number exception.
    let filter = [
        statement(libc::BPF_LD | libc::BPF_W | libc::BPF_ABS, 4),
        jump(libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K, architecture, 1),
        statement(libc::BPF_RET | libc::BPF_K, deny),
        statement(libc::BPF_LD | libc::BPF_W | libc::BPF_ABS, 0),
        jump(
            libc::BPF_JMP | libc::BPF_JSET | libc::BPF_K,
            if cfg!(target_arch = "x86_64") {
                0x4000_0000
            } else {
                0
            },
            3,
        ),
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::SYS_execve as u32,
            2,
        ),
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::SYS_execveat as u32,
            1,
        ),
        statement(libc::BPF_RET | libc::BPF_K, libc::SECCOMP_RET_ALLOW),
        statement(libc::BPF_RET | libc::BPF_K, deny),
    ];
    let program = libc::sock_fprog {
        len: filter.len() as u16,
        filter: filter.as_ptr().cast_mut(),
    };
    restrict_privileges()?;
    let result = unsafe {
        libc::syscall(
            libc::SYS_seccomp,
            libc::SECCOMP_SET_MODE_FILTER,
            libc::SECCOMP_FILTER_FLAG_TSYNC,
            &program,
        )
    };
    if result < 0 {
        return Err(std::io::Error::last_os_error());
    }
    // A positive result names a thread that could not be synchronized. It is
    // failure, never permission to run a partially constrained evaluator.
    if result != 0 {
        return Err(std::io::Error::from_raw_os_error(libc::EBUSY));
    }
    Ok(())
}

/// Pre-exec child only; never alter the caller's saved IDs/groups/capabilities.
pub(super) fn child_credentials(uid: u32, gid: u32, groups: &[u32]) -> std::io::Result<()> {
    if uid == 0
        || uid == u32::MAX
        || gid == 0
        || gid == u32::MAX
        || groups.len() > 64
        || groups.iter().any(|gid| *gid == 0 || *gid == u32::MAX)
    {
        return Err(std::io::Error::from_raw_os_error(libc::EINVAL));
    }
    unsafe {
        if libc::setgroups(groups.len(), groups.as_ptr()) != 0
            || libc::setresgid(gid, gid, gid) != 0
            || libc::setresuid(uid, uid, uid) != 0
        {
            return Err(std::io::Error::last_os_error());
        }
    }
    restrict_privileges()
}

// Explicit child-only defense, independent of inherited service securebits.
// Clearing all capability sets also prevents inheritable/file-capability reuse.
fn restrict_privileges() -> std::io::Result<()> {
    #[repr(C)]
    struct Header {
        version: u32,
        pid: i32,
    }
    #[derive(Clone, Copy)]
    #[repr(C)]
    struct Data {
        effective: u32,
        permitted: u32,
        inheritable: u32,
    }
    let header = Header {
        version: 0x2008_0522,
        pid: 0,
    };
    let data = [Data {
        effective: 0,
        permitted: 0,
        inheritable: 0,
    }; 2];
    unsafe {
        if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0
            || libc::prctl(
                libc::PR_CAP_AMBIENT,
                libc::PR_CAP_AMBIENT_CLEAR_ALL,
                0,
                0,
                0,
            ) != 0
            || libc::syscall(libc::SYS_capset, &header, data.as_ptr()) != 0
        {
            return Err(std::io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Shared by all installed child entries. No inherited socket/file authority;
/// only the separately validated filesystem decoder's scoped directory survives.
fn child_descriptor_policy(directory: Option<&std::fs::File>) -> std::io::Result<()> {
    if unsafe {
        libc::syscall(
            libc::SYS_close_range,
            3u32,
            u32::MAX,
            libc::CLOSE_RANGE_CLOEXEC | libc::CLOSE_RANGE_UNSHARE,
        )
    } != 0
    {
        return Err(std::io::Error::last_os_error());
    }
    if let Some(directory) = directory
        && unsafe { libc::fcntl(directory.as_raw_fd(), libc::F_SETFD, 0) } != 0
    {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

enum ChildScope {
    Plain,
    Directory(std::fs::File),
    Capture(offline::CaptureView),
    Caller(super::build_worker::caller_view::View),
    Native(super::build_worker::caller_view::View),
}

/// Shared installed entry, after original producer placement. Keeping namespace,
/// credential, policy and descriptor ordering here lets the privileged kernel
/// regression exercise the actual path without inventing a test sandbox.
fn child_scope_entry(
    scope: &ChildScope,
    uid: u32,
    gid: u32,
    groups: &[u32],
) -> std::io::Result<()> {
    match scope {
        ChildScope::Caller(view) => view.enter(true)?,
        ChildScope::Native(view) => view.enter(false)?,
        ChildScope::Capture(view) => view.enter()?,
        _ => {}
    }
    child_credentials(uid, gid, groups)?;
    match scope {
        ChildScope::Caller(_) => offline::restrict_ipc()?,
        ChildScope::Capture(view) => view.restrict()?,
        _ => {}
    }
    child_descriptor_policy(match scope {
        ChildScope::Directory(directory) => Some(directory),
        _ => None,
    })
}

pub struct Runner {
    uid: u32,
    limits: Limits,
    deadline: Instant,
    child: Option<Child>,
    poisoned: bool,
    umask: Option<u32>,
}
impl Runner {
    pub fn new(uid: u32, limits: Limits, deadline: Instant) -> Result<Self> {
        limits.validate()?;
        Self::new_source(uid, limits, deadline, MAX_BYTES)
    }

    /// Explicit bounded source representation, not a control-service allowance.
    /// The admitted worker additionally enforces its declared source byte/entry
    /// limits. No eager allocation; ordinary helpers retain the16MiB ceiling.
    pub fn new_source(
        uid: u32,
        limits: Limits,
        deadline: Instant,
        representation_limit: usize,
    ) -> Result<Self> {
        ensure!(uid > 0 && uid < u32::MAX, "invalid helper UID");
        limits.validate_source(representation_limit)?;
        ensure!(Instant::now() < deadline, "helper deadline expired");
        Ok(Self {
            uid,
            limits,
            deadline,
            child: None,
            poisoned: false,
            umask: None,
        })
    }

    /// Immutable child context; never inspect/change the caller's process mask.
    pub fn with_umask(mut self, mask: u32) -> Result<Self> {
        self.ready()?;
        ensure!(
            mask <= 0o777 && self.umask.is_none(),
            "invalid/replaced helper umask"
        );
        self.umask = Some(mask);
        Ok(self)
    }

    /// Scope entry/exit check, including native helpers that discard errors.
    /// Not admission, producer settlement or a source receipt.
    pub fn check_ready(&self) -> Result<()> {
        ensure!(unsafe { libc::geteuid() } == self.uid, "wrong helper UID");
        super::workload::require_wrapper_placement()?;
        self.ready()
    }

    fn ready(&self) -> Result<()> {
        ensure!(
            !self.poisoned && self.child.is_none(),
            "helper runner unresolved"
        );
        ensure!(Instant::now() < self.deadline, "helper deadline expired");
        Ok(())
    }

    /// Command profile/credential/FD setup is the trusted caller's responsibility.
    /// No automatic retry. Failure poisons this runner even after its child exits.
    pub fn run(&mut self, command: &mut Command, input: &[u8]) -> Result<Captured> {
        self.check_ready()?;
        offline::require_if_requested()?;
        self.execute(command, input)
    }

    /// Additional fail-closed veto during the existing bounded I/O loop. This
    /// does not grant admission or turn child termination into settlement.
    pub fn run_while(
        &mut self,
        command: &mut Command,
        input: &[u8],
        mut active: impl FnMut() -> Result<()>,
    ) -> Result<Captured> {
        self.check_ready()?;
        offline::require_if_requested()?;
        self.execute_while(command, input, &mut active)
    }

    /// Trusted discovery can keep reading bounded regular configuration files
    /// while each Git decoder/helper gets its own complete immutable read scope.
    /// No ambient-scope fallback: Policy::enter fails before exec without reads.
    pub fn run_offline_while(
        &mut self,
        command: &mut Command,
        input: &[u8],
        policy: offline::Policy,
        mut active: impl FnMut() -> Result<()>,
    ) -> Result<Captured> {
        use std::os::unix::process::CommandExt;
        self.check_ready()?;
        unsafe {
            command.pre_exec(move || {
                child_descriptor_policy(None)?;
                policy.enter()
            });
        }
        self.execute_while(command, input, &mut active)
    }

    /// Trusted installed root worker only. Credentials/FDs change in its child;
    /// one original deadline and the existing capture/poisoning rules still apply.
    pub(super) fn run_as(
        &mut self,
        command: &mut Command,
        input: &[u8],
        gid: u32,
        stage: &mut super::stage::Stage,
    ) -> Result<Captured> {
        self.run_as_groups(command, input, gid, &[], stage)
    }

    /// Same stage/deadline barrier, with an immutable installed supplementary set.
    pub(super) fn run_as_groups(
        &mut self,
        command: &mut Command,
        input: &[u8],
        gid: u32,
        groups: &[u32],
        stage: &mut super::stage::Stage,
    ) -> Result<Captured> {
        self.run_as_scoped(command, input, gid, groups, ChildScope::Plain, stage)
    }

    /// One root-provisioned producer-directory FD enters only this child. No
    /// control/journal/store FD, pathname traversal grant or placement exemption.
    pub(super) fn run_as_directory(
        &mut self,
        command: &mut Command,
        input: &[u8],
        gid: u32,
        directory: DirectoryFd,
        stage: &mut super::stage::Stage,
    ) -> Result<Captured> {
        use std::os::unix::fs::MetadataExt;
        let metadata = directory.0.metadata()?;
        ensure!(
            metadata.is_dir()
                && metadata.uid() == self.uid
                && metadata.gid() == gid
                && metadata.mode() & 0o7777 == 0o700,
            "invalid scoped producer directory"
        );
        self.run_as_scoped(
            command,
            input,
            gid,
            &[],
            ChildScope::Directory(directory.0),
            stage,
        )
    }

    /// Offline caller capture: private scratch/proc/IPC, readonly host mounts,
    /// then inherited kernel effect restrictions before the fixed manager exec.
    pub fn run_as_capture(
        &mut self,
        command: &mut Command,
        input: &[u8],
        gid: u32,
        groups: &[u32],
        view: offline::CaptureView,
        stage: &mut super::stage::Stage,
    ) -> Result<Captured> {
        ensure!(view.uid == self.uid, "capture scratch credential differs");
        command.env(offline::REQUIRED, "1");
        self.run_as_scoped(
            command,
            input,
            gid,
            groups,
            ChildScope::Capture(view),
            stage,
        )
    }

    pub(super) fn run_as_view(
        &mut self,
        command: &mut Command,
        input: &[u8],
        gid: u32,
        groups: &[u32],
        view: super::build_worker::caller_view::View,
        stage: &mut super::stage::Stage,
    ) -> Result<Captured> {
        command.env(offline::REQUIRED, "1");
        self.run_as_scoped(command, input, gid, groups, ChildScope::Caller(view), stage)
    }

    /// Fixed trusted native client only: same sealed view/stage/credentials, but
    /// daemon and normal native acquisition remain available. Never caller Git.
    pub(super) fn run_as_native_view(
        &mut self,
        command: &mut Command,
        input: &[u8],
        gid: u32,
        groups: &[u32],
        view: super::build_worker::caller_view::View,
        stage: &mut super::stage::Stage,
    ) -> Result<Captured> {
        self.run_as_scoped(command, input, gid, groups, ChildScope::Native(view), stage)
    }

    fn run_as_scoped(
        &mut self,
        command: &mut Command,
        input: &[u8],
        gid: u32,
        groups: &[u32],
        scope: ChildScope,
        stage: &mut super::stage::Stage,
    ) -> Result<Captured> {
        use std::os::unix::process::CommandExt;
        ensure!(
            groups.len() <= 64 && groups.iter().all(|gid| *gid > 0 && *gid < u32::MAX),
            "invalid installed helper groups"
        );
        let groups = groups.to_vec();
        ensure!(
            unsafe { libc::getuid() } == 0 && unsafe { libc::geteuid() } == 0,
            "credentialed helper requires root"
        );
        ensure!(gid > 0 && gid < u32::MAX, "invalid helper GID");
        super::workload::require_wrapper_placement()?;
        self.ready()?;
        let group = stage.claim_process_fd()?;
        let uid = self.uid;
        unsafe {
            command.pre_exec(move || {
                if libc::write(group, b"0".as_ptr().cast(), 1) != 1 {
                    return Err(std::io::Error::last_os_error());
                }
                child_scope_entry(&scope, uid, gid, &groups)
            });
        }
        let result = (|| -> Result<Captured> {
            let captured = self.execute(command, input)?;
            if !stage.empty()? {
                // Helpers do not get to leave background writers behind. Preserve
                // their actual exit/capture, but do not seal inputs until all exit.
                stage.request_stop()?;
                while !stage.empty()? {
                    if Instant::now() >= self.deadline {
                        self.poisoned = true;
                        anyhow::bail!("producer settlement deadline expired");
                    }
                    std::thread::park_timeout(Duration::from_millis(10));
                }
            }
            self.ready()?;
            Ok(captured)
        })();
        if result.is_err() {
            self.poisoned = true;
        }
        result
    }

    fn execute(&mut self, command: &mut Command, input: &[u8]) -> Result<Captured> {
        self.execute_while(command, input, &mut || Ok(()))
    }

    fn execute_while(
        &mut self,
        command: &mut Command,
        input: &[u8],
        active: &mut impl FnMut() -> Result<()>,
    ) -> Result<Captured> {
        self.ready()?;
        if let Err(error) = active() {
            self.poisoned = true;
            return Err(error);
        }
        ensure!(
            input.len() <= self.limits.stdin,
            "helper input exceeds bound"
        );
        if let Some(mask) = self.umask {
            use std::os::unix::process::CommandExt;
            unsafe {
                command.pre_exec(move || {
                    libc::umask(mask);
                    Ok(())
                });
            }
        }
        // No shell/profile selection here. Spawn itself is not a bounded syscall;
        // the aggregate supervisor still owns deadline enforcement and settlement.
        let child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn();
        match child {
            Ok(child) => self.child = Some(child),
            Err(error) => {
                self.poisoned = true;
                return Err(error).context("spawn owned helper");
            }
        }
        let result = self.capture(input, active);
        if result.is_err() {
            self.poisoned = true;
            self.stop_child();
        }
        result
    }

    fn capture(
        &mut self,
        input: &[u8],
        active: &mut impl FnMut() -> Result<()>,
    ) -> Result<Captured> {
        let child = self.child.as_mut().context("missing helper")?;
        let stdin = child.stdin.take().context("missing helper stdin")?;
        let mut stdout = child.stdout.take().context("missing helper stdout")?;
        let mut stderr = child.stderr.take().context("missing helper stderr")?;
        for fd in [stdin.as_raw_fd(), stdout.as_raw_fd(), stderr.as_raw_fd()] {
            nonblocking(fd)?;
        }
        let mut written = 0;
        let mut input_pipe = if input.is_empty() {
            drop(stdin);
            None
        } else {
            Some(stdin)
        };
        let mut output = Vec::new();
        let mut errors = Vec::new();
        let mut status = None;
        loop {
            ensure!(Instant::now() < self.deadline, "helper deadline expired");
            active()?;
            let out_done = drain(&mut stdout, &mut output, self.limits.stdout)?;
            let err_done = drain(&mut stderr, &mut errors, self.limits.stderr)?;
            if let Some(writer) = &mut input_pipe {
                let end = (written + CHUNK).min(input.len());
                match write_input(writer, &input[written..end]) {
                    Ok(0) => anyhow::bail!("helper stdin closed before delivery"),
                    Ok(count) => written += count,
                    Err(error)
                        if matches!(
                            error.kind(),
                            ErrorKind::WouldBlock | ErrorKind::Interrupted
                        ) => {}
                    Err(error) => return Err(error).context("deliver helper input"),
                }
                if written == input.len() {
                    input_pipe = None;
                }
            }
            if status.is_none() {
                status = child.try_wait()?;
            }
            if let Some(status) = status
                && out_done
                && err_done
            {
                ensure!(
                    written == input.len(),
                    "helper exited before input delivery"
                );
                ensure!(Instant::now() < self.deadline, "helper deadline expired");
                active()?;
                self.child = None;
                return Ok(Captured {
                    status,
                    stdout: output,
                    stderr: errors,
                });
            }
            std::thread::park_timeout(Duration::from_millis(2));
        }
    }

    fn stop_child(&mut self) {
        if let Some(child) = &mut self.child {
            // Child::kill does not signal a PID already reaped by Child::try_wait.
            // Never kill by group/PID/name after losing identity; descendants stay
            // accounted by the aggregate supervisor, not this helper's exit.
            let _ = child.kill();
            if matches!(child.try_wait(), Ok(Some(_))) {
                self.child = None;
            }
        }
    }
}
impl Drop for Runner {
    fn drop(&mut self) {
        self.stop_child();
    }
}

// Pipe writes must return EPIPE even when the service uses SIG_DFL. Never change
// the process-wide disposition or consume a SIGPIPE already pending for caller.
struct PipeSignal {
    set: libc::sigset_t,
    previous: libc::sigset_t,
    pending: bool,
}
impl PipeSignal {
    fn block() -> std::io::Result<Self> {
        let mut guard: Self = unsafe { std::mem::zeroed() };
        unsafe {
            libc::sigemptyset(&mut guard.set);
            libc::sigaddset(&mut guard.set, libc::SIGPIPE);
        }
        let code =
            unsafe { libc::pthread_sigmask(libc::SIG_BLOCK, &guard.set, &mut guard.previous) };
        if code != 0 {
            // No mask was installed; do not run the restoration destructor.
            std::mem::forget(guard);
            return Err(std::io::Error::from_raw_os_error(code));
        }
        let mut pending = unsafe { std::mem::zeroed() };
        if unsafe { libc::sigpending(&mut pending) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        guard.pending = unsafe { libc::sigismember(&pending, libc::SIGPIPE) } == 1;
        Ok(guard)
    }
    fn consume_generated(&self) -> std::io::Result<()> {
        if self.pending {
            return Ok(());
        }
        let zero = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        // Finite attempts: interruptions cannot spin beyond the helper budget.
        for _ in 0..8 {
            let signal = unsafe { libc::sigtimedwait(&self.set, std::ptr::null_mut(), &zero) };
            if signal == libc::SIGPIPE {
                return Ok(());
            }
            let error = std::io::Error::last_os_error();
            if error.kind() == ErrorKind::WouldBlock {
                return Ok(());
            }
            if error.kind() != ErrorKind::Interrupted {
                return Err(error);
            }
        }
        Err(std::io::Error::from(ErrorKind::Interrupted))
    }
}
impl Drop for PipeSignal {
    fn drop(&mut self) {
        unsafe {
            libc::pthread_sigmask(libc::SIG_SETMASK, &self.previous, std::ptr::null_mut());
        }
    }
}
fn write_input(writer: &mut impl Write, bytes: &[u8]) -> std::io::Result<usize> {
    let guard = PipeSignal::block()?;
    let result = writer.write(bytes);
    if result
        .as_ref()
        .is_err_and(|error| error.raw_os_error() == Some(libc::EPIPE))
    {
        guard.consume_generated()?;
    }
    result
}

fn nonblocking(fd: i32) -> Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    ensure!(
        flags >= 0 && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == 0,
        "cannot bound helper pipes"
    );
    Ok(())
}
fn drain(reader: &mut impl Read, output: &mut Vec<u8>, limit: usize) -> Result<bool> {
    let mut buffer = [0; CHUNK];
    for _ in 0..POLL_CHUNKS {
        match reader.read(&mut buffer) {
            Ok(0) => return Ok(true),
            Ok(count) => {
                ensure!(
                    count <= limit.saturating_sub(output.len()),
                    "helper output exceeds bound"
                );
                output.extend_from_slice(&buffer[..count]);
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => return Ok(false),
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(error) => return Err(error).context("read helper output"),
        }
    }
    Ok(false)
}

#[cfg(test)]
mod tests;
