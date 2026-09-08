use std::fmt;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use anyhow::{Result, bail};

use crate::progress::command_reporter;

use super::host_runtime::ProcessCancellation;
use super::orchestration::{
    CancellationController, CancellationDecision, DeployActivity, TerminationSignal,
};

static SIGNAL_RUNTIME: OnceLock<Arc<SignalCoordinator>> = OnceLock::new();
static SIGNAL_WRITE_FD: AtomicI32 = AtomicI32::new(-1);

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
            let decision = coordinator.receive_now(signal);
            command_reporter().message(cancellation_message(decision));
            continue;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn cancellation_message(decision: CancellationDecision) -> String {
    match decision {
        CancellationDecision::HangupExit { .. } => {
            "Hangup received · stopping local work; remote activations remain untouched".to_owned()
        }
        CancellationDecision::WaitForActiveDeploys { .. } => {
            "Interrupt received · waiting for admitted activations; press twice more to force"
                .to_owned()
        }
        CancellationDecision::CancelLocalAndExit { .. } => {
            "Interrupt received · stopping local work".to_owned()
        }
        CancellationDecision::AwaitEscalation { remaining, .. } => format!(
            "Interrupt received · admitted activations still running · {remaining} more to force"
        ),
        CancellationDecision::ForceCancelRemoteAndExit { .. } => {
            "Forced interruption · cancelling admitted remote activations".to_owned()
        }
    }
}

fn install_handler(signal: i32) -> Result<()> {
    // SAFETY: zeroed `sigaction` is initialized before use, the handler has the
    // required C ABI, and its body only performs atomic operations and write(2).
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
    let byte = signal as u8;
    // SAFETY: `fd` is a nonblocking pipe descriptor and `byte` is valid for the
    // one-byte write. Errors are intentionally ignored in signal context.
    let _ = unsafe { libc::write(fd, (&byte as *const u8).cast(), 1) };
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
}
