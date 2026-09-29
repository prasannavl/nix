//! Interactive keyboard controls for fleet runs.
//!
//! Fleet operations are long and dashboard-driven, so the `v` key toggles a
//! full verbose stream of sanitized subprocess output while a run is in
//! flight. One reader serves every producer — a native fleet run and an
//! agent-driven deploy alike — and the verbose state lives in the shared
//! progress state, so they all observe one toggle. The reader owns the terminal
//! only while some producer holds it, so a later command phase can re-acquire
//! it.

use std::io::{self, IsTerminal};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::{Duration, Instant};

use crate::progress::{VerboseView, command_reporter};
use crate::terminal_mode;

/// The live reader, or a dead handle once the last owner dropped it. Exactly one
/// reader owns stdin at a time; further acquisitions share it, and the last drop
/// restores the terminal so ownership can be re-acquired later in the process.
static READER: OnceLock<Mutex<Weak<InteractiveVerbose>>> = OnceLock::new();
/// Whether an interactive reader currently owns stdin for the `v` toggle, so
/// the dashboard only advertises keys it can actually read.
static KEYS_ACTIVE: AtomicBool = AtomicBool::new(false);
static INSTALL_LOCK: Mutex<()> = Mutex::new(());

/// Keyboard poll granularity: responsive without busy-spinning the terminal.
const POLL_INTERVAL: Duration = Duration::from_millis(25);
/// The escape byte a terminal sends before the key of an `alt+` shortcut.
const ESCAPE: u8 = 0x1b;
/// How long an `alt+` prefix stays open. Long enough to span one reader poll, so
/// a pair the terminal splits across two reads still pairs up, and short enough
/// that a lone Escape does not swallow a deliberate key press.
const ALT_PREFIX_WINDOW: Duration = Duration::from_millis(50);

/// Owns the terminal mode and reader thread. Dropping it asks the reader to
/// stop, waits for it to leave stdin, and restores the terminal attributes
/// captured at install time.
pub struct InteractiveVerbose {
    original: libc::termios,
    stop: Arc<AtomicBool>,
    /// `Some` until the guard drops, which is the only time it is taken: joining
    /// consumes the handle.
    reader: Option<std::thread::JoinHandle<()>>,
}

impl Drop for InteractiveVerbose {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        KEYS_ACTIVE.store(false, Ordering::Release);
        // Wait for the reader to leave stdin before giving the terminal back, so
        // a key pressed just as the run ends cannot be consumed by a reader that
        // no longer owns the terminal. Reads cannot block while raw mode is
        // installed, so the wait is bounded by one poll interval.
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
        terminal_mode::restore(&self.original);
    }
}

/// Whether the interactive `v` toggle is currently readable.
pub fn keys_available() -> bool {
    KEYS_ACTIVE.load(Ordering::Acquire)
}

/// Acquire the `v` key reader on an interactive terminal. Returns `None` when
/// there is no terminal to read or when machine output is requested; when a
/// reader already owns the terminal this hands back a handle to that same
/// reader rather than installing a second one. Every owner shares one reader, so
/// a command that runs several phases keeps a single terminal owner, and the
/// reader can be re-acquired after the last owner drops.
pub fn install() -> Option<Arc<InteractiveVerbose>> {
    let _guard = INSTALL_LOCK.lock().ok()?;
    let slot = READER.get_or_init(|| Mutex::new(Weak::new()));
    let mut current = slot.lock().ok()?;
    if let Some(live) = current.upgrade() {
        return Some(live);
    }
    if !io::stdin().is_terminal() || !io::stderr().is_terminal() || !command_reporter().enabled() {
        return None;
    }
    let original = terminal_mode::enter_raw_mode()?;
    let stop = Arc::new(AtomicBool::new(false));
    let reader = match spawn_reader(Arc::clone(&stop)) {
        Ok(reader) => reader,
        Err(_) => {
            // Nothing will read the keys, so hand the terminal straight back
            // instead of advertising keys no reader can serve.
            terminal_mode::restore(&original);
            return None;
        }
    };
    KEYS_ACTIVE.store(true, Ordering::Release);
    let ownership = Arc::new(InteractiveVerbose {
        original,
        stop,
        reader: Some(reader),
    });
    *current = Arc::downgrade(&ownership);
    Some(ownership)
}

/// One recognised verbose key from stdin.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum VerboseKey {
    /// `v`/`V`: show or hide the log section.
    Toggle,
    /// `ctrl-r`/`ctrl-e`: switch the section to a view, opening it if hidden.
    View(VerboseView),
    /// `ctrl-j`/`ctrl-k`: scroll by single lines, positive toward older output.
    Lines(isize),
    /// `ctrl-h`/`ctrl-l`: scroll by half-viewport pages, positive toward older.
    Pages(isize),
    /// `esc`/`ctrl-g`/`alt-g`: return the window to the newest content.
    Newest,
}

/// Every verbose key recognised in one read of stdin, folded into one action.
/// Repeats collapse, so holding a key reads as one steady move instead of one
/// step per byte, and a key held across a redraw cannot flicker the section.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct VerboseInput {
    toggle: bool,
    view: Option<VerboseView>,
    lines: isize,
    pages: isize,
    newest: bool,
}

impl VerboseInput {
    fn is_empty(&self) -> bool {
        !self.toggle && self.view.is_none() && self.lines == 0 && self.pages == 0 && !self.newest
    }

    /// Fold one recognised key in: scroll deltas accumulate, the last view key
    /// in the burst wins, and `v` collapses to a single toggle.
    fn record(&mut self, key: VerboseKey) {
        match key {
            VerboseKey::Toggle => self.toggle = true,
            VerboseKey::View(view) => self.view = Some(view),
            VerboseKey::Lines(delta) => self.lines = self.lines.saturating_add(delta),
            VerboseKey::Pages(delta) => self.pages = self.pages.saturating_add(delta),
            VerboseKey::Newest => self.newest = true,
        }
    }
}

/// Tracks an `alt+` prefix. Terminals send `alt+key` as an escape byte followed
/// by the key, so a byte is an `alt+` key only while a prefix is still open.
#[derive(Clone, Copy, Debug, Default)]
struct AltPrefix {
    started_at: Option<Instant>,
}

impl AltPrefix {
    /// Fold one stdin byte into `input`, reading it as the key of an `alt+`
    /// shortcut while a fresh escape prefix is open. A prefix that aged out, or
    /// a second escape inside the window, is a bare `esc` and returns to the
    /// newest content.
    fn feed(&mut self, byte: u8, at: Instant, input: &mut VerboseInput) {
        if let Some(started) = self.started_at.take() {
            if at.duration_since(started) <= ALT_PREFIX_WINDOW {
                if byte == ESCAPE {
                    input.record(VerboseKey::Newest);
                } else if let Some(key) = alt_verbose_key(byte) {
                    input.record(key);
                }
                return;
            }
            // The prefix aged out before this byte arrived: it was a bare `esc`.
            input.record(VerboseKey::Newest);
        }
        if byte == ESCAPE {
            self.started_at = Some(at);
        } else if let Some(key) = verbose_key(byte) {
            input.record(key);
        }
    }

    /// Emit the bare-`Esc` action once its `alt+` window closes with no key, so
    /// a lone `Esc` returns the view to the newest content instead of being
    /// swallowed as an unfinished prefix.
    fn expire(&mut self, at: Instant, input: &mut VerboseInput) {
        if self
            .started_at
            .is_some_and(|started| at.duration_since(started) > ALT_PREFIX_WINDOW)
        {
            self.started_at = None;
            input.record(VerboseKey::Newest);
        }
    }
}

/// Spawn the reader thread, reporting failure so the caller can give the
/// terminal back when nothing will read it.
fn spawn_reader(stop: Arc<AtomicBool>) -> std::io::Result<std::thread::JoinHandle<()>> {
    std::thread::Builder::new()
        .name("fleet-verbose-toggle".to_owned())
        .spawn(move || {
            let mut alt = AltPrefix::default();
            while !stop.load(Ordering::Acquire) {
                let mut input = if stdin_ready() {
                    drain_verbose_keys(&mut alt)
                } else {
                    VerboseInput::default()
                };
                // A lone `esc` resolves to "newest" once its alt window closes.
                alt.expire(Instant::now(), &mut input);
                if input.is_empty() {
                    // Nothing recognised: back off rather than spinning on a
                    // descriptor that stays readable without yielding keys.
                    std::thread::sleep(POLL_INTERVAL);
                    continue;
                }
                let reporter = command_reporter();
                if input.toggle {
                    // Redraw immediately so the `Logs` header appears or
                    // disappears on the key press.
                    reporter.toggle_verbose_output();
                }
                if let Some(view) = input.view {
                    // A view key also opens the section, so `ctrl-e` on a
                    // running deploy jumps straight to the retained errors.
                    reporter.set_verbose_view(view);
                }
                if input.lines != 0 {
                    reporter.scroll_verbose_lines(input.lines);
                }
                if input.pages != 0 {
                    reporter.scroll_verbose_pages(input.pages);
                }
                if input.newest {
                    reporter.scroll_verbose_newest();
                }
            }
        })
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

/// Consume every pending stdin byte, folding the recognised keys into one
/// action. Scroll keys on a closed section are ignored by the reporter.
fn drain_verbose_keys(alt: &mut AltPrefix) -> VerboseInput {
    let mut input = VerboseInput::default();
    let mut byte = 0_u8;
    // SAFETY: stdin is a valid descriptor and `byte` is a valid one-byte
    // destination. `VMIN = 0` keeps the read from blocking.
    while unsafe { libc::read(libc::STDIN_FILENO, (&mut byte as *mut u8).cast(), 1) } == 1 {
        alt.feed(byte, Instant::now(), &mut input);
    }
    input
}

/// The verbose key one stdin byte selects, if any. `ctrl-r`/`ctrl-e` pick the
/// view, `ctrl-k`/`ctrl-j` scroll by lines toward older/newer output, `ctrl-h`/
/// `ctrl-l` scroll by half-viewport pages, and `ctrl-g` returns to the newest.
fn verbose_key(byte: u8) -> Option<VerboseKey> {
    match byte {
        0x05 => Some(VerboseKey::View(VerboseView::Errors)), // ctrl-e
        0x12 => Some(VerboseKey::View(VerboseView::Run)),    // ctrl-r
        0x0b => Some(VerboseKey::Lines(1)),                  // ctrl-k
        0x0a => Some(VerboseKey::Lines(-1)),                 // ctrl-j
        0x08 => Some(VerboseKey::Pages(1)),                  // ctrl-h
        0x0c => Some(VerboseKey::Pages(-1)),                 // ctrl-l
        0x07 => Some(VerboseKey::Newest),                    // ctrl-g
        b'v' | b'V' => Some(VerboseKey::Toggle),
        _ => None,
    }
}

/// The verbose key an `alt+` (escape-prefixed) byte selects. It mirrors
/// [`verbose_key`], so a terminal that consumes the control bytes still drives
/// the same views and scrolling.
fn alt_verbose_key(byte: u8) -> Option<VerboseKey> {
    match byte {
        b'r' | b'R' => Some(VerboseKey::View(VerboseView::Run)),
        b'e' | b'E' => Some(VerboseKey::View(VerboseView::Errors)),
        b'k' | b'K' => Some(VerboseKey::Lines(1)),
        b'j' | b'J' => Some(VerboseKey::Lines(-1)),
        b'h' | b'H' => Some(VerboseKey::Pages(1)),
        b'l' | b'L' => Some(VerboseKey::Pages(-1)),
        b'g' | b'G' => Some(VerboseKey::Newest),
        // `alt+v` toggles as well, which also keeps a quick `Escape` followed by
        // `v` from being swallowed as an unrecognised `alt+` key.
        b'v' | b'V' => Some(VerboseKey::Toggle),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verbose_keys_map_control_bytes_and_the_letter_v() {
        assert_eq!(verbose_key(b'v'), Some(VerboseKey::Toggle));
        assert_eq!(verbose_key(b'V'), Some(VerboseKey::Toggle));
        assert_eq!(verbose_key(0x12), Some(VerboseKey::View(VerboseView::Run)));
        assert_eq!(
            verbose_key(0x05),
            Some(VerboseKey::View(VerboseView::Errors))
        );
        assert_eq!(verbose_key(0x0b), Some(VerboseKey::Lines(1)));
        assert_eq!(verbose_key(0x0a), Some(VerboseKey::Lines(-1)));
        assert_eq!(verbose_key(0x08), Some(VerboseKey::Pages(1)));
        assert_eq!(verbose_key(0x0c), Some(VerboseKey::Pages(-1)));
        assert_eq!(verbose_key(0x07), Some(VerboseKey::Newest));
        // Enter arrives as a carriage return once raw mode stops translating it
        // into the line feed `ctrl-j` sends, so it must not scroll anything.
        assert_eq!(verbose_key(0x0d), None);
        assert_eq!(verbose_key(b'q'), None);
    }

    #[test]
    fn alt_keys_mirror_the_control_shortcuts() {
        assert_eq!(
            alt_verbose_key(b'r'),
            Some(VerboseKey::View(VerboseView::Run))
        );
        assert_eq!(
            alt_verbose_key(b'e'),
            Some(VerboseKey::View(VerboseView::Errors))
        );
        assert_eq!(alt_verbose_key(b'k'), Some(VerboseKey::Lines(1)));
        assert_eq!(alt_verbose_key(b'j'), Some(VerboseKey::Lines(-1)));
        assert_eq!(alt_verbose_key(b'h'), Some(VerboseKey::Pages(1)));
        assert_eq!(alt_verbose_key(b'l'), Some(VerboseKey::Pages(-1)));
        assert_eq!(alt_verbose_key(b'g'), Some(VerboseKey::Newest));
        assert_eq!(alt_verbose_key(b'v'), Some(VerboseKey::Toggle));
        assert_eq!(alt_verbose_key(b'x'), None);
    }

    #[test]
    fn an_escape_prefix_pairs_the_alt_key_within_the_window() {
        let start = Instant::now();
        let mut input = VerboseInput::default();
        let mut alt = AltPrefix::default();
        alt.feed(ESCAPE, start, &mut input);
        alt.feed(b'r', start + Duration::from_millis(5), &mut input);
        assert_eq!(input.view, Some(VerboseView::Run));

        // A stale prefix must not swallow the next deliberate key press: it was
        // a bare `esc`, so it returns to the newest, and the key still applies.
        let mut input = VerboseInput::default();
        let mut alt = AltPrefix::default();
        alt.feed(ESCAPE, start, &mut input);
        assert!(input.is_empty());
        alt.feed(
            b'v',
            start + ALT_PREFIX_WINDOW + Duration::from_millis(1),
            &mut input,
        );
        assert!(input.newest, "a stale prefix is a bare esc");
        assert!(input.toggle, "a stale prefix must not consume the key");
    }

    #[test]
    fn a_double_escape_returns_to_the_newest() {
        let start = Instant::now();
        let mut input = VerboseInput::default();
        let mut alt = AltPrefix::default();
        alt.feed(ESCAPE, start, &mut input);
        alt.feed(ESCAPE, start + Duration::from_millis(5), &mut input);
        assert!(input.newest, "two quick escapes are a bare esc");
    }

    #[test]
    fn a_lone_escape_returns_to_the_newest_once_its_window_closes() {
        let start = Instant::now();
        let mut input = VerboseInput::default();
        let mut alt = AltPrefix::default();
        alt.feed(ESCAPE, start, &mut input);
        assert!(input.is_empty(), "a pending prefix is not a key yet");

        // Still inside the alt window: not a bare `esc`.
        alt.expire(start + Duration::from_millis(5), &mut input);
        assert!(input.is_empty());

        // Window closed with no key: the bare `esc` resets to the newest.
        alt.expire(
            start + ALT_PREFIX_WINDOW + Duration::from_millis(1),
            &mut input,
        );
        assert!(input.newest);
        assert!(!input.is_empty());
    }

    #[test]
    fn repeated_keys_fold_into_one_steady_action() {
        let mut input = VerboseInput::default();
        for byte in [0x0b, 0x0b, 0x0b] {
            input.record(verbose_key(byte).expect("ctrl-k is a scroll key"));
        }
        assert_eq!(input.lines, 3, "held scroll keys accumulate");

        for byte in [b'v', b'v'] {
            input.record(verbose_key(byte).expect("v is the toggle"));
        }
        assert!(input.toggle, "a held v toggles once per burst");
        assert!(!input.is_empty());

        input.record(verbose_key(0x12).expect("ctrl-r selects a view"));
        input.record(verbose_key(0x05).expect("ctrl-e selects a view"));
        assert_eq!(input.view, Some(VerboseView::Errors));
        assert!(VerboseInput::default().is_empty());
    }
}
