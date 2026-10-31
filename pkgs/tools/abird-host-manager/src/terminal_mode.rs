//! Shared terminal-mode and cursor restoration for interactive controls.
//!
//! The interactive key reader puts stdin into raw mode and releases it when the
//! last producer drops. The attributes captured at entry are also published
//! process-wide so the async-signal force-exit path can restore them: a signal
//! handler cannot run destructors, so without this the terminal would be left
//! with echo and canonical input disabled after a forced exit.

use std::io::{self, IsTerminal};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};

pub(crate) const HIDE_CURSOR: &str = "\x1b[?25l";
pub(crate) const SHOW_CURSOR: &str = "\x1b[?25h";

// Published before a frame can hide the cursor; cleared after a visible frame.
static CURSOR_HIDDEN: AtomicBool = AtomicBool::new(false);

pub(crate) fn publish_cursor_hidden(hidden: bool) {
    CURSOR_HIDDEN.store(hidden, Ordering::Release);
}

fn restore_cursor() {
    if CURSOR_HIDDEN.swap(false, Ordering::AcqRel) {
        // A signal may have interrupted a synchronized frame. End it before
        // showing the cursor; no allocation or reporter/stdio locks on exit.
        const RESTORE: &[u8] = b"\x1b[?2026l\x1b[?25h";
        // SAFETY: static bytes and a standard descriptor; write is signal-safe.
        let _ = unsafe { libc::write(libc::STDERR_FILENO, RESTORE.as_ptr().cast(), RESTORE.len()) };
    }
}

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

/// Restore owned cursor visibility and raw-mode attributes, if any. Cursor
/// cleanup also applies to progress without an interactive key reader.
pub fn restore_published() {
    restore_cursor();
    let pointer = ORIGINAL.load(Ordering::Acquire);
    if pointer.is_null() {
        return;
    }
    // SAFETY: `pointer` targets a leaked, immutable `termios` published before
    // this call, and `tcsetattr` reads only the provided struct.
    let _ = unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, pointer) };
}

/// Restore from an async-signal context using only atomics, `write(2)` and
/// `tcsetattr(2)`, even when normal reporter cleanup is unavailable.
pub fn restore_for_forced_exit() {
    restore_published();
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
    fn cursor_and_terminal_modes_are_restored_for_every_exit() {
        use std::fs::File;
        use std::io::{Read, Write};
        use std::os::fd::{AsRawFd, FromRawFd};
        use std::process::{Command, Stdio};
        use std::time::{Duration, Instant};

        const CHILD: &str = "ABIRD_TEST_CURSOR_EXIT";
        const TEST: &str =
            "terminal_mode::tests::cursor_and_terminal_modes_are_restored_for_every_exit";
        if let Ok(mode) = std::env::var(CHILD) {
            let _terminal = crate::progress::guard_terminal_exit();
            if !mode.ends_with("no-reader") {
                enter_raw_mode().expect("test tty");
            }
            let reporter = crate::progress::command_reporter();
            reporter.started("cursor probe");
            match mode.as_str() {
                "normal" => reporter.complete_active("cursor probe"),
                "failure" => reporter.fail_active("cursor probe", "synthetic failure"),
                "early-return" | "no-reader" => {}
                "panic" => panic!("synthetic terminal panic"),
                "locked-panic" => {
                    struct PanicMessage;
                    impl std::fmt::Display for PanicMessage {
                        fn fmt(&self, _: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                            panic!("panic while a buffered frame owns the output lock")
                        }
                    }
                    reporter.message(PanicMessage);
                }
                "forced" | "forced-no-reader" => {
                    crate::fleet::signal::install().unwrap();
                    // Exercise force-exit with an interrupted synchronized frame.
                    io::stderr().write_all(b"\x1b[?2026h").unwrap();
                    for _ in 0..3 {
                        // SAFETY: this isolated child installed its own handler.
                        assert_eq!(unsafe { libc::raise(libc::SIGINT) }, 0);
                    }
                    panic!("third interrupt did not exit");
                }
                _ => unreachable!(),
            }
            return;
        }

        for mode in [
            "normal",
            "failure",
            "early-return",
            "no-reader",
            "panic",
            "locked-panic",
            "forced",
            "forced-no-reader",
        ] {
            let (mut master, mut slave) = (-1, -1);
            let size = libc::winsize {
                ws_row: 24,
                ws_col: 100,
                ws_xpixel: 0,
                ws_ypixel: 0,
            };
            // SAFETY: valid output descriptors and initialized window size.
            assert_eq!(
                unsafe {
                    libc::openpty(&mut master, &mut slave, ptr::null_mut(), ptr::null(), &size)
                },
                0
            );
            // SAFETY: openpty returned two owned descriptors.
            let (mut master, slave) =
                unsafe { (File::from_raw_fd(master), File::from_raw_fd(slave)) };
            let attributes = || {
                let mut value = unsafe { std::mem::zeroed::<libc::termios>() };
                // SAFETY: live slave descriptor and writable termios storage.
                assert_eq!(unsafe { libc::tcgetattr(slave.as_raw_fd(), &mut value) }, 0);
                (
                    value.c_iflag,
                    value.c_oflag,
                    value.c_cflag,
                    value.c_lflag,
                    value.c_cc,
                )
            };
            let original = attributes();
            // SAFETY: live master descriptor; nonblocking reads only affect it.
            assert_ne!(
                unsafe { libc::fcntl(master.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) },
                -1
            );
            let mut child = Command::new(std::env::current_exe().unwrap())
                .args(["--exact", TEST, "--nocapture"])
                .env(CHILD, mode)
                .env("TERM", "xterm-256color")
                .stdin(Stdio::from(slave.try_clone().unwrap()))
                .stdout(Stdio::from(slave.try_clone().unwrap()))
                .stderr(Stdio::from(slave.try_clone().unwrap()))
                .spawn()
                .unwrap();
            let deadline = Instant::now() + Duration::from_secs(10);
            let mut bytes = Vec::new();
            let mut buffer = [0; 4096];
            let status = loop {
                let exited = child.try_wait().unwrap();
                loop {
                    match master.read(&mut buffer) {
                        Ok(0) => break,
                        Ok(n) => bytes.extend_from_slice(&buffer[..n]),
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                        Err(error) => panic!("pty read: {error}"),
                    }
                }
                if let Some(status) = exited {
                    break status;
                }
                if Instant::now() > deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    panic!("{mode}: terminal cleanup hung");
                }
                let mut poll = libc::pollfd {
                    fd: master.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                // SAFETY: valid descriptor storage, bounded wait for child output.
                unsafe {
                    libc::poll(&mut poll, 1, 20);
                }
            };
            let output = String::from_utf8_lossy(&bytes);
            let hidden = output.rfind(HIDE_CURSOR).expect("live frame hides cursor");
            let shown = output.rfind(SHOW_CURSOR).expect("exit restores cursor");
            assert!(shown > hidden, "{mode}: cursor left hidden: {output:?}");
            assert_eq!(attributes(), original, "{mode}: raw mode leaked");
            if mode.starts_with("forced") {
                let interrupted_frame = output.rfind("\x1b[?2026h").unwrap();
                assert!(
                    output[interrupted_frame..].contains("\x1b[?2026l\x1b[?25h"),
                    "{mode}: interrupted frame was not closed before cursor restoration"
                );
                assert_eq!(status.code(), Some(130), "{output}");
            } else {
                assert_eq!(
                    status.success(),
                    !mode.contains("panic"),
                    "{mode}: {output}"
                );
            }
        }
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
