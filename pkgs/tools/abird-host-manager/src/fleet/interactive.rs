//! Interactive keyboard controls for native fleet runs.
//!
//! Fleet operations are long and dashboard-driven, so the `v` key toggles a
//! full verbose stream of sanitized subprocess output while a run is in
//! flight. The verbose state is shared process-wide so nested build workers
//! observe one toggle, and the terminal mode is restored when the owning guard
//! drops.

use std::io::{self, IsTerminal};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use crate::progress::command_reporter;
use crate::terminal_mode;

/// Shared verbose state. Published only when an interactive reader owns the
/// terminal, so non-interactive and test runs keep private per-view state.
static VERBOSE: OnceLock<Arc<AtomicBool>> = OnceLock::new();
/// One reader owns stdin for the process lifetime; later installs observe the
/// published state without touching the terminal.
static READER_INSTALLED: AtomicBool = AtomicBool::new(false);
/// Whether an interactive reader currently owns stdin for the `v` toggle, so
/// the dashboard only advertises keys it can actually read.
static KEYS_ACTIVE: AtomicBool = AtomicBool::new(false);
static INSTALL_LOCK: Mutex<()> = Mutex::new(());

/// Keyboard poll granularity: responsive without busy-spinning the terminal.
const POLL_INTERVAL: Duration = Duration::from_millis(25);

/// Owns the terminal mode and reader thread. Dropping it asks the reader to
/// stop and restores the terminal attributes captured at install time.
pub struct InteractiveVerbose {
    original: libc::termios,
    stop: Arc<AtomicBool>,
}

impl Drop for InteractiveVerbose {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        KEYS_ACTIVE.store(false, Ordering::Release);
        terminal_mode::restore(&self.original);
    }
}

/// Whether the interactive `v` toggle is currently readable.
pub fn keys_available() -> bool {
    KEYS_ACTIVE.load(Ordering::Acquire)
}

/// Verbose state a fleet view should observe. When no interactive reader is
/// installed each caller receives a private handle initialized to `initial`,
/// keeping tests and non-interactive runs independent.
pub fn verbose_handle(initial: bool) -> Arc<AtomicBool> {
    match VERBOSE.get() {
        Some(state) => Arc::clone(state),
        None => Arc::new(AtomicBool::new(initial)),
    }
}

/// Capture the `v` key on an interactive terminal and publish the shared
/// verbose state. Returns `None` when there is no terminal to read, when a
/// reader already owns stdin, or when machine output is requested.
pub fn install(initial_verbose: bool) -> Option<InteractiveVerbose> {
    let _guard = INSTALL_LOCK.lock().ok()?;
    if READER_INSTALLED.swap(true, Ordering::AcqRel) {
        return None;
    }
    if !io::stdin().is_terminal() || !io::stderr().is_terminal() || !command_reporter().enabled() {
        return None;
    }
    let original = terminal_mode::enter_raw_mode()?;
    let verbose = Arc::clone(VERBOSE.get_or_init(|| Arc::new(AtomicBool::new(initial_verbose))));
    let stop = Arc::new(AtomicBool::new(false));
    spawn_reader(verbose, Arc::clone(&stop));
    KEYS_ACTIVE.store(true, Ordering::Release);
    Some(InteractiveVerbose { original, stop })
}

fn spawn_reader(verbose: Arc<AtomicBool>, stop: Arc<AtomicBool>) {
    let _ = std::thread::Builder::new()
        .name("fleet-verbose-toggle".to_owned())
        .spawn(move || {
            while !stop.load(Ordering::Acquire) {
                if !stdin_ready() {
                    std::thread::sleep(POLL_INTERVAL);
                    continue;
                }
                if drain_verbose_key() {
                    // The footer names the next press (`verbose on`/`verbose
                    // off`), so redraw immediately for visible feedback.
                    let was_enabled = verbose.fetch_xor(true, Ordering::AcqRel);
                    if was_enabled {
                        command_reporter().clear_verbose_output();
                    } else {
                        command_reporter().show_verbose_output();
                    }
                }
            }
        });
}

fn stdin_ready() -> bool {
    let mut descriptor = libc::pollfd {
        fd: libc::STDIN_FILENO,
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: one initialized `pollfd` for the live stdin descriptor with a
    // zero timeout that never blocks the reader.
    let ready = unsafe { libc::poll(&mut descriptor, 1, 0) };
    // Require readable data: a hangup or error must not send the reader into a
    // tight read-returns-zero loop.
    ready > 0 && descriptor.revents & libc::POLLIN != 0
}

/// Consume every pending stdin byte and report whether `v`/`V` appeared.
fn drain_verbose_key() -> bool {
    let mut verbose = false;
    let mut byte = 0_u8;
    // SAFETY: stdin is a valid descriptor and `byte` is a valid one-byte
    // destination. `VMIN = 0` keeps the read from blocking.
    while unsafe { libc::read(libc::STDIN_FILENO, (&mut byte as *mut u8).cast(), 1) } == 1 {
        verbose |= matches!(byte, b'v' | b'V');
    }
    verbose
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn private_verbose_handles_start_at_the_requested_value_and_are_independent() {
        let handle = verbose_handle(true);
        assert!(handle.load(Ordering::Relaxed));
        handle.store(false, Ordering::Relaxed);
        assert!(verbose_handle(true).load(Ordering::Relaxed));
    }
}
