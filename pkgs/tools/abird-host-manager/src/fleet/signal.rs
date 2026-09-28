use std::fmt;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use anyhow::{Result, bail};

use super::host_runtime::ProcessCancellation;
use super::orchestration::{
    CancellationController, CancellationDecision, DeployActivity, TerminationSignal,
};

static SIGNAL_RUNTIME: OnceLock<Arc<SignalCoordinator>> = OnceLock::new();
static SIGNAL_WRITE_FD: AtomicI32 = AtomicI32::new(-1);
// Hard escalation must not depend on the coordinator thread: that thread and
// the graceful path may themselves be blocked. The worker resets this counter
// after the bounded double-signal window when it remains healthy.
static TERMINATION_SIGNAL_COUNT: AtomicUsize = AtomicUsize::new(0);
const FORCE_EXIT_WINDOW: Duration = Duration::from_secs(3);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Interrupted {
    status: i32,
}

impl Interrupted {
    pub fn status(self) -> i32 {
        self.status
    }

    pub fn from_status(status: i32) -> Self {
        Self { status }
    }
}

impl fmt::Display for Interrupted {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "fleet operation interrupted (exit {})",
            self.status
        )
    }
}

impl std::error::Error for Interrupted {}

#[derive(Debug)]
pub struct SignalCoordinator {
    controller: Mutex<CancellationController>,
    started: Instant,
    active_activations: AtomicUsize,
    requested: AtomicBool,
    cancel_local: AtomicBool,
    force_remote: AtomicBool,
    status: AtomicI32,
}

impl Default for SignalCoordinator {
    fn default() -> Self {
        Self::new()
    }
}

impl SignalCoordinator {
    pub fn new() -> Self {
        Self {
            controller: Mutex::new(CancellationController::default()),
            started: Instant::now(),
            active_activations: AtomicUsize::new(0),
            requested: AtomicBool::new(false),
            cancel_local: AtomicBool::new(false),
            force_remote: AtomicBool::new(false),
            status: AtomicI32::new(0),
        }
    }

    pub fn receive(&self, signal: TerminationSignal, elapsed: Duration) -> CancellationDecision {
        let active = self.active_activations.load(Ordering::Acquire) > 0;
        let decision = self
            .controller
            .lock()
            .expect("signal cancellation policy poisoned")
            .receive(
                signal,
                elapsed,
                if active {
                    DeployActivity::active()
                } else {
                    DeployActivity::idle()
                },
            );
        self.requested.store(true, Ordering::Release);
        self.status.store(signal.exit_status(), Ordering::Release);
        match decision {
            CancellationDecision::HangupExit { .. }
            | CancellationDecision::CancelLocalAndExit { .. } => {
                self.cancel_local.store(true, Ordering::Release);
            }
            CancellationDecision::ForceCancelRemoteAndExit { .. } => {
                self.force_remote.store(true, Ordering::Release);
                self.cancel_local.store(true, Ordering::Release);
            }
            CancellationDecision::WaitForActiveDeploys { .. }
            | CancellationDecision::AwaitEscalation { .. } => {}
        }
        decision
    }

    pub fn activation(self: &Arc<Self>) -> ActivationGuard {
        self.begin_activation();
        ActivationGuard {
            coordinator: Arc::clone(self),
        }
    }

    pub fn cancel_local(&self) -> bool {
        self.cancel_local.load(Ordering::Acquire)
    }

    pub fn force_remote(&self) -> bool {
        self.force_remote.load(Ordering::Acquire)
    }

    pub fn interruption(&self) -> Option<Interrupted> {
        self.requested.load(Ordering::Acquire).then(|| Interrupted {
            status: self.status.load(Ordering::Acquire),
        })
    }

    fn receive_now(&self, signal: TerminationSignal) -> CancellationDecision {
        self.receive(signal, self.started.elapsed())
    }

    fn begin_activation(&self) {
        self.active_activations.fetch_add(1, Ordering::AcqRel);
    }

    fn finish_activation(&self) {
        let previous = self.active_activations.fetch_sub(1, Ordering::AcqRel);
        if previous == 1 && self.requested.load(Ordering::Acquire) {
            self.cancel_local.store(true, Ordering::Release);
        }
    }
}

impl ProcessCancellation for SignalCoordinator {
    fn activation_started(&self) {
        self.begin_activation();
    }

    fn activation_finished(&self) {
        self.finish_activation();
    }

    fn cancel_local(&self) -> bool {
        self.cancel_local()
    }

    fn force_remote(&self) -> bool {
        self.force_remote()
    }
}

pub struct ActivationGuard {
    coordinator: Arc<SignalCoordinator>,
}

impl Drop for ActivationGuard {
    fn drop(&mut self) {
        self.coordinator.finish_activation();
    }
}

pub fn install() -> Result<Arc<SignalCoordinator>> {
    if let Some(runtime) = SIGNAL_RUNTIME.get() {
        return Ok(Arc::clone(runtime));
    }
    let mut descriptors = [-1 as RawFd; 2];
    // SAFETY: `descriptors` points to two valid integers. Both descriptors are
    // retained for the process lifetime, and O_NONBLOCK keeps the signal
    // handler from blocking if a caller floods the pipe.
    if unsafe { libc::pipe2(descriptors.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    SIGNAL_WRITE_FD.store(descriptors[1], Ordering::Release);
    for signal in [libc::SIGHUP, libc::SIGINT, libc::SIGTERM] {
        install_handler(signal)?;
    }
    let coordinator = Arc::new(SignalCoordinator::new());
    SIGNAL_RUNTIME
        .set(Arc::clone(&coordinator))
        .map_err(|_| anyhow::anyhow!("fleet signal runtime was initialized concurrently"))?;
    let worker = Arc::clone(&coordinator);
    std::thread::spawn(move || signal_loop(descriptors[0], worker));
    Ok(coordinator)
}

pub fn runtime() -> Option<Arc<SignalCoordinator>> {
    SIGNAL_RUNTIME.get().map(Arc::clone)
}

pub fn activation_guard() -> Option<ActivationGuard> {
    runtime().map(|runtime| runtime.activation())
}

pub fn check_interrupted() -> Result<()> {
    if let Some(interrupted) = runtime().and_then(|runtime| runtime.interruption()) {
        return Err(interrupted.into());
    }
    Ok(())
}

fn signal_loop(read_fd: RawFd, coordinator: Arc<SignalCoordinator>) {
    let mut last_termination = None;
    loop {
        let mut byte = 0_u8;
        // SAFETY: `read_fd` is the retained read end of the process signal
        // pipe and `byte` is a valid one-byte destination.
        let read = unsafe { libc::read(read_fd, (&mut byte as *mut u8).cast(), 1) };
        if read == 1 {
            let signal = match byte as i32 {
                libc::SIGHUP => TerminationSignal::Hangup,
                libc::SIGINT => TerminationSignal::Interrupt,
                libc::SIGTERM => TerminationSignal::Terminate,
                _ => continue,
            };
            if signal != TerminationSignal::Hangup {
                last_termination = Some(Instant::now());
            }
            coordinator.receive_now(signal);
            continue;
        }
        if last_termination.is_some_and(|last| last.elapsed() > FORCE_EXIT_WINDOW) {
            TERMINATION_SIGNAL_COUNT.store(0, Ordering::Release);
            last_termination = None;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn install_handler(signal: i32) -> Result<()> {
    // SAFETY: zeroed `sigaction` is initialized before use, the handler has the
    // required C ABI, and its body uses only atomics plus async-signal-safe
    // write(2) and _exit(2).
    let mut action = unsafe { std::mem::zeroed::<libc::sigaction>() };
    action.sa_sigaction = signal_handler as *const () as usize;
    action.sa_flags = libc::SA_RESTART;
    // SAFETY: `action.sa_mask` is valid storage owned by this stack frame.
    unsafe { libc::sigemptyset(&mut action.sa_mask) };
    // SAFETY: `action` is fully initialized and no previous disposition is
    // needed because this executable installs one process-wide fleet policy.
    if unsafe { libc::sigaction(signal, &action, std::ptr::null_mut()) } != 0 {
        bail!(
            "install signal handler for {signal}: {}",
            std::io::Error::last_os_error()
        );
    }
    Ok(())
}

extern "C" fn signal_handler(signal: i32) {
    let fd = SIGNAL_WRITE_FD.load(Ordering::Relaxed);
    if fd < 0 {
        return;
    }
    if matches!(signal, libc::SIGINT | libc::SIGTERM) {
        let previous = TERMINATION_SIGNAL_COUNT.fetch_add(1, Ordering::AcqRel);
        if previous >= 2 {
            write_signal_message(b"\nForced interruption received; exiting immediately\n");
            // SAFETY: _exit is async-signal-safe and intentionally bypasses
            // cleanup when graceful cancellation itself is not responsive.
            unsafe { libc::_exit(128 + signal) };
        }
        if previous == 0 {
            write_signal_message(
                b"\nInterrupt received; graceful shutdown requested; press Ctrl-C twice more within 3s to force exit\n",
            );
        } else {
            write_signal_message(
                b"\nInterrupt received again; press Ctrl-C once more within 3s to force exit\n",
            );
        }
    } else if signal == libc::SIGHUP {
        write_signal_message(b"\nHangup received; stopping local work\n");
    }
    let byte = signal as u8;
    // SAFETY: `fd` is a nonblocking pipe descriptor and `byte` is valid for the
    // one-byte write. Errors are intentionally ignored in signal context.
    let _ = unsafe { libc::write(fd, (&byte as *const u8).cast(), 1) };
}

fn write_signal_message(message: &'static [u8]) {
    // SAFETY: stderr is process-owned, `message` is valid for the complete
    // static lifetime, and write(2) is async-signal-safe. A partial write is
    // acceptable for best-effort emergency feedback.
    let _ = unsafe { libc::write(libc::STDERR_FILENO, message.as_ptr().cast(), message.len()) };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_interrupt_waits_for_activation_then_releases_local_cancellation() {
        let coordinator = Arc::new(SignalCoordinator::new());
        let guard = coordinator.activation();
        assert!(matches!(
            coordinator.receive(TerminationSignal::Interrupt, Duration::from_secs(1)),
            CancellationDecision::WaitForActiveDeploys { status: 130 }
        ));
        assert!(!coordinator.cancel_local());
        drop(guard);
        assert!(coordinator.cancel_local());
        assert_eq!(coordinator.interruption().unwrap().status(), 130);
    }

    #[test]
    fn hangup_never_requests_remote_cancellation() {
        let coordinator = Arc::new(SignalCoordinator::new());
        let _guard = coordinator.activation();
        coordinator.receive(TerminationSignal::Hangup, Duration::from_secs(1));
        assert!(coordinator.cancel_local());
        assert!(!coordinator.force_remote());
        assert_eq!(coordinator.interruption().unwrap().status(), 129);
    }

    #[test]
    fn third_interrupt_inside_window_forces_remote_cancellation() {
        let coordinator = Arc::new(SignalCoordinator::new());
        let _guard = coordinator.activation();
        coordinator.receive(TerminationSignal::Interrupt, Duration::from_secs(1));
        coordinator.receive(TerminationSignal::Interrupt, Duration::from_secs(2));
        coordinator.receive(TerminationSignal::Terminate, Duration::from_secs(3));
        assert!(coordinator.cancel_local());
        assert!(coordinator.force_remote());
        assert_eq!(coordinator.interruption().unwrap().status(), 143);
    }

    #[test]
    fn third_interrupt_forces_exit_when_graceful_path_is_stuck() {
        const CHILD_ENV: &str = "ABIRD_TEST_STUCK_SIGNAL_CHILD";
        const TEST_NAME: &str =
            "fleet::signal::tests::third_interrupt_forces_exit_when_graceful_path_is_stuck";
        if let Some(marker) = std::env::var_os(CHILD_ENV) {
            install().unwrap();
            std::fs::write(marker, b"ready\n").unwrap();
            loop {
                std::thread::park_timeout(Duration::from_secs(60));
            }
        }

        let temporary = tempfile::tempdir().unwrap();
        let marker = temporary.path().join("ready");
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", TEST_NAME, "--nocapture"])
            .env(CHILD_ENV, &marker)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let started = Instant::now();
        while !marker.exists() && started.elapsed() < Duration::from_secs(5) {
            assert!(
                child.try_wait().unwrap().is_none(),
                "signal child exited early"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(marker.exists(), "signal child did not become ready");

        // SAFETY: the child pid is live and dedicated to this test.
        assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGINT) }, 0);
        std::thread::sleep(Duration::from_millis(100));
        assert!(
            child.try_wait().unwrap().is_none(),
            "the first interrupt must remain graceful"
        );
        // SAFETY: the child pid remains live after the graceful interrupt.
        assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGINT) }, 0);
        std::thread::sleep(Duration::from_millis(100));
        assert!(
            child.try_wait().unwrap().is_none(),
            "the second interrupt must request escalation without hard exit"
        );
        let forced_at = Instant::now();
        // SAFETY: the child pid remains live after two interrupts.
        assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGINT) }, 0);
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            assert!(
                forced_at.elapsed() < Duration::from_secs(1),
                "forced interrupt did not terminate promptly"
            );
            std::thread::sleep(Duration::from_millis(10));
        };
        assert_eq!(status.code(), Some(130));
    }
}
