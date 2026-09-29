//! Shared raw-terminal handling for interactive controls.
//!
//! The interactive key reader puts stdin into raw mode and releases it when the
//! last producer drops. The attributes captured at entry are also published
//! process-wide so the async-signal force-exit path can restore them: a signal
//! handler cannot run destructors, so without this the terminal would be left
//! with echo and canonical input disabled after a forced exit.

use std::io::{self, IsTerminal};
use std::ptr;
use std::sync::atomic::{AtomicPtr, Ordering};

/// Attributes captured when raw mode was entered, published for the force-exit
/// signal handler and intentionally never freed: a handler may read it at any
/// point, so the allocation must outlive every invocation.
static ORIGINAL: AtomicPtr<libc::termios> = AtomicPtr::new(ptr::null_mut());

/// Put stdin into raw mode and publish the previous attributes. Line buffering,
/// echo, and the CR-to-NL input translation are disabled, while signal
/// generation (`ISIG`) stays enabled so Ctrl-C still interrupts. Returns `None`
/// when stdin/stderr is not a terminal or the terminal calls fail.
pub fn enter_raw_mode() -> Option<libc::termios> {
    if !io::stdin().is_terminal() || !io::stderr().is_terminal() {
        return None;
    }
    // SAFETY: zeroed `termios` is initialized by `tcgetattr` before use.
    let mut original = unsafe { std::mem::zeroed::<libc::termios>() };
    if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } != 0 {
        return None;
    }
    let raw = raw_attributes(original);
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

/// The attributes stdin runs with while a key reader owns it: non-canonical and
/// un-echoed so single keys arrive as they are typed, `ISIG` left on so Ctrl-C
/// still interrupts, and `ICRNL` cleared so the carriage return a terminal sends
/// for Enter stays distinct from the line feed `ctrl-j` sends. Zero `VMIN` and
/// `VTIME` make reads non-blocking, so polling stdin never parks a thread.
fn raw_attributes(original: libc::termios) -> libc::termios {
    let mut raw = original;
    raw.c_iflag &= !libc::ICRNL;
    raw.c_lflag &= !(libc::ICANON | libc::ECHO);
    raw.c_cc[libc::VMIN] = 0;
    raw.c_cc[libc::VTIME] = 0;
    raw
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
    fn raw_mode_disables_line_discipline_but_keeps_signals_and_flow_control() {
        let mut original = unsafe { std::mem::zeroed::<libc::termios>() };
        original.c_iflag = libc::ICRNL | libc::IXON;
        original.c_lflag = libc::ICANON | libc::ECHO | libc::ISIG;
        original.c_cc[libc::VMIN] = 1;

        let raw = raw_attributes(original);

        // Enter must stay distinct from `ctrl-j`: under `ICRNL` the driver
        // delivers the carriage return Enter sends as the same byte `ctrl-j`
        // sends, so the reader could not tell them apart.
        assert_eq!(raw.c_iflag & libc::ICRNL, 0);
        assert_ne!(raw.c_iflag & libc::IXON, 0, "flow control stays the user's");
        assert_eq!(raw.c_lflag & (libc::ICANON | libc::ECHO), 0);
        assert_ne!(raw.c_lflag & libc::ISIG, 0, "Ctrl-C must still interrupt");
        assert_eq!(raw.c_cc[libc::VMIN], 0);
        assert_eq!(raw.c_cc[libc::VTIME], 0);
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
