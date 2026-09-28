//! Shared raw-terminal handling for interactive controls.
//!
//! Both the fleet verbose toggle and the host-agent log toggle put stdin into
//! raw mode. The attributes captured at entry are also published process-wide
//! so the async-signal force-exit path can restore them: a signal handler
//! cannot run destructors, so without this the terminal would be left with
//! echo and canonical input disabled after a forced exit.

use std::io::{self, IsTerminal};
use std::ptr;
use std::sync::atomic::{AtomicPtr, Ordering};

/// Attributes captured when raw mode was entered, published for the force-exit
/// signal handler and intentionally never freed: a handler may read it at any
/// point, so the allocation must outlive every invocation.
static ORIGINAL: AtomicPtr<libc::termios> = AtomicPtr::new(ptr::null_mut());

/// Put stdin into raw mode and publish the previous attributes. Line buffering
/// and echo are disabled while signal generation (`ISIG`) is left enabled so
/// Ctrl-C still interrupts. Returns `None` when stdin/stderr is not a terminal
/// or the terminal calls fail.
pub fn enter_raw_mode() -> Option<libc::termios> {
    if !io::stdin().is_terminal() || !io::stderr().is_terminal() {
        return None;
    }
    // SAFETY: zeroed `termios` is initialized by `tcgetattr` before use.
    let mut original = unsafe { std::mem::zeroed::<libc::termios>() };
    if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } != 0 {
        return None;
    }
    let mut raw = original;
    raw.c_lflag = raw_local_flags(raw.c_lflag);
    raw.c_cc[libc::VMIN] = 0;
    raw.c_cc[libc::VTIME] = 0;
    // SAFETY: `raw` is a fully initialized termios for the same descriptor.
    if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) } != 0 {
        return None;
    }
    publish(original);
    Some(original)
}

/// Restore stdin attributes captured at raw-mode entry.
pub fn restore(original: &libc::termios) {
    // SAFETY: `original` was captured from the same stdin descriptor, and
    // `tcsetattr` reads only the provided struct.
    let _ = unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, original) };
}

/// Restore the published attributes from an async-signal context, using only
/// async-signal-safe operations: an atomic load plus `tcsetattr(2)`.
pub fn restore_for_forced_exit() {
    let pointer = ORIGINAL.load(Ordering::Acquire);
    if pointer.is_null() {
        return;
    }
    // SAFETY: `pointer` targets a leaked, immutable `termios` published before
    // this handler could run, and `tcsetattr` is async-signal-safe.
    let _ = unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, pointer) };
}

/// Disable line buffering and echo while leaving signal generation (`ISIG`)
/// enabled so Ctrl-C still interrupts.
fn raw_local_flags(current: libc::tcflag_t) -> libc::tcflag_t {
    current & !(libc::ICANON | libc::ECHO)
}

/// Publish the entry attributes once, racing safely if multiple controls are
/// installed at the same time.
fn publish(original: libc::termios) {
    if !ORIGINAL.load(Ordering::Acquire).is_null() {
        return;
    }
    let pointer = Box::into_raw(Box::new(original));
    match ORIGINAL.compare_exchange(
        ptr::null_mut(),
        pointer,
        Ordering::AcqRel,
        Ordering::Acquire,
    ) {
        Ok(_) => {}
        // SAFETY: another thread published first; reclaim the unused box. The
        // winning box is never freed, so a concurrent handler cannot race it.
        Err(_) => unsafe { drop(Box::from_raw(pointer)) },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_mode_disables_echo_and_canonical_input_but_keeps_signals() {
        let current = libc::ICANON | libc::ECHO | libc::ISIG;
        let raw = raw_local_flags(current);
        assert_eq!(raw & (libc::ICANON | libc::ECHO), 0);
        assert_ne!(raw & libc::ISIG, 0);
    }

    #[test]
    fn publishing_the_restore_snapshot_is_idempotent() {
        // SAFETY: a zeroed `termios` is a valid value for this pointer-sized
        // snapshot; nothing here submits it to the terminal.
        let attributes = unsafe { std::mem::zeroed::<libc::termios>() };
        publish(attributes);
        let first = ORIGINAL.load(Ordering::Acquire);
        assert!(!first.is_null(), "the snapshot must be published");
        publish(attributes);
        assert_eq!(
            ORIGINAL.load(Ordering::Acquire),
            first,
            "a second publish must keep the first snapshot"
        );
    }
}
