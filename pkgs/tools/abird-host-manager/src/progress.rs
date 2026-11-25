use std::collections::{BTreeMap, VecDeque};
use std::io::{self, IsTerminal, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use crate::Action;
use crate::terminal_mode::{HIDE_CURSOR, SHOW_CURSOR};
use crate::terminal_style::{TerminalStyle, Tone};

mod fleet_timing;

use fleet_timing::{HostTiming, Interval, PhaseSnapshot, RosterKind, WorkflowContext};
pub(crate) use fleet_timing::{RowOutcome, RowSnapshot};

static JSON_OUTPUT: AtomicBool = AtomicBool::new(false);
static COMMAND_REPORTER: OnceLock<ProgressReporter> = OnceLock::new();

pub fn set_json_output(enabled: bool) {
    JSON_OUTPUT.store(enabled, Ordering::Relaxed);
}

pub fn json_output() -> bool {
    JSON_OUTPUT.load(Ordering::Relaxed)
}

#[derive(Clone, Debug)]
pub struct ProgressReporter {
    enabled: bool,
    interactive: bool,
    recent_update_limit: usize,
    style: TerminalStyle,
    destination: ProgressDestination,
    state: Arc<Mutex<ProgressState>>,
    output: Arc<Mutex<()>>,
}

#[derive(Clone, Debug)]
enum ProgressDestination {
    Stderr,
    #[cfg(test)]
    Buffer(Arc<Mutex<Vec<u8>>>),
    /// Test destination that reports a terminal size through a shared cell (or
    /// `None` for an unknown size), so the viewport budget, in-place clearing,
    /// and a resize can all be exercised without a real tty.
    #[cfg(test)]
    BufferWithViewport(Arc<Mutex<Vec<u8>>>, Arc<Mutex<Option<(usize, usize)>>>),
    #[cfg(test)]
    Frames(Arc<Mutex<Vec<String>>>, Arc<Mutex<Option<(usize, usize)>>>),
}

impl ProgressDestination {
    fn write(&self, text: &str) {
        match self {
            Self::Stderr => {
                let mut stderr = io::stderr().lock();
                let _ = stderr.write_all(text.as_bytes());
                let _ = stderr.flush();
            }
            #[cfg(test)]
            Self::Buffer(buffer) | Self::BufferWithViewport(buffer, _) => {
                if let Ok(mut buffer) = buffer.lock() {
                    buffer.extend_from_slice(text.as_bytes());
                }
            }
            #[cfg(test)]
            Self::Frames(frames, _) => frames.lock().unwrap().push(text.to_owned()),
        }
    }

    fn viewport(&self) -> Option<(usize, usize)> {
        match self {
            Self::Stderr => terminal_viewport(),
            #[cfg(test)]
            Self::Buffer(_) => None,
            #[cfg(test)]
            Self::BufferWithViewport(_, viewport) | Self::Frames(_, viewport) => {
                viewport.lock().ok().and_then(|viewport| *viewport)
            }
        }
    }
}

const BEGIN_SYNCHRONIZED_UPDATE: &str = "\x1b[?2026h";
const END_SYNCHRONIZED_UPDATE: &str = "\x1b[?2026l";

/// One logical update, flushed before its caller releases the output lock.
/// Redirected output stays streaming; terminals get one synchronized frame.
struct ProgressFrame<'a> {
    destination: &'a ProgressDestination,
    interactive: bool,
    buffer: String,
    keep_cursor_hidden: bool,
}

impl<'a> ProgressFrame<'a> {
    fn new(destination: &'a ProgressDestination, interactive: bool) -> Self {
        Self {
            destination,
            interactive,
            buffer: String::new(),
            keep_cursor_hidden: false,
        }
    }

    fn write(&mut self, text: &str) {
        if !self.interactive {
            self.destination.write(text);
        } else if !text.is_empty() {
            if self.buffer.is_empty() {
                self.buffer.push_str(BEGIN_SYNCHRONIZED_UPDATE);
                self.buffer.push_str(HIDE_CURSOR);
            }
            self.buffer.push_str(text);
        }
    }
}

impl Drop for ProgressFrame<'_> {
    fn drop(&mut self) {
        if !self.buffer.is_empty() && !thread::panicking() {
            if !self.keep_cursor_hidden {
                self.buffer.push_str(SHOW_CURSOR);
            }
            self.buffer.push_str(END_SYNCHRONIZED_UPDATE);
            let stderr = matches!(self.destination, ProgressDestination::Stderr);
            // Publish before writing: a forced exit may interrupt the frame.
            if stderr {
                crate::terminal_mode::publish_cursor_hidden(true);
            }
            self.destination.write(&self.buffer);
            if stderr && !self.keep_cursor_hidden {
                crate::terminal_mode::publish_cursor_hidden(false);
            }
        }
    }
}

/// Last painted region. Retain in-place rows to rewrite only changed lines;
/// an oversized append-only snapshot can only be replaced by a screen wipe.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
enum Painted {
    #[default]
    None,
    InPlace(Vec<String>),
    Snapshot,
}

/// One frame's terminal size. `live` is what the terminal reported (or `None`
/// when unreadable); `layout` is the size to lay the frame out for, falling
/// back to the last known size so a transient unreadable read does not re-lay
/// the region out with the stale default budget.
#[derive(Clone, Copy, Debug)]
struct FrameSize {
    live: Option<(usize, usize)>,
    layout: Option<(usize, usize)>,
}

/// Whether a host roster may overflow its line budget. The plain dashboard keeps
/// every host and lets the append-only snapshot path scroll the terminal; the
/// verbose dashboard shares the screen with the logs, so it windows the roster
/// to its last hosts so the bottom stays visible.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RosterPolicy {
    Full,
    Windowed,
}

#[derive(Clone, Copy)]
enum Redraw {
    Immediate,
    Stream,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConcurrencyChange {
    Increase,
    Decrease,
}

const INPUT_FEEDBACK_DURATION: Duration = Duration::from_millis(800);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum FeedbackKey {
    Increase,
    Decrease,
    Verbose,
    Run,
    Errors,
    Cancel,
}

#[derive(Clone, Copy, Debug)]
struct KeyFeedback {
    key: FeedbackKey,
    at: Instant,
}

fn feedback_active(at: Option<Instant>, now: Instant) -> bool {
    at.is_some_and(|at| now.saturating_duration_since(at) < INPUT_FEEDBACK_DURATION)
}

#[derive(Clone)]
struct ConcurrencyHandler(Arc<dyn Fn(ConcurrencyChange) -> bool + Send + Sync>);

impl std::fmt::Debug for ConcurrencyHandler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ConcurrencyHandler")
    }
}

pub struct ConcurrencyGuard {
    reporter: ProgressReporter,
    previous: Option<ConcurrencyHandler>,
}

impl Drop for ConcurrencyGuard {
    fn drop(&mut self) {
        if let Ok(mut state) = self.reporter.state.lock() {
            state.concurrency_handler = self.previous.take();
        }
        self.reporter.refresh();
    }
}

/// One command-level field, outside the phase/step stack.
#[must_use = "the field stays live only while its guard is held"]
pub(crate) struct TimedField<'a> {
    reporter: &'a ProgressReporter,
    label: &'static str,
    value: &'static str,
    started: Instant,
    next_update: Option<Instant>,
}

impl TimedField<'_> {
    pub(crate) fn elapsed(&self) -> Duration {
        self.started.elapsed()
    }

    /// Called from the wait loop; redraw at the normal one-second cadence.
    pub(crate) fn tick(&mut self, now: Instant) {
        if self.next_update.is_some_and(|next| now >= next) {
            self.next_update = Some(now + Duration::from_secs(1));
            let elapsed = format_duration(now.saturating_duration_since(self.started));
            self.reporter.set_timed_field(Some(self.reporter.field_line(
                self.label,
                self.value,
                Some(format_args!("elapsed {elapsed}")),
            )));
        }
    }
}

impl Drop for TimedField<'_> {
    fn drop(&mut self) {
        if self.next_update.is_some() {
            self.reporter.set_timed_field(None);
        }
    }
}

#[derive(Clone, Debug, Default)]
struct ProgressState {
    stack: Vec<ActiveProgress>,
    workflow: WorkflowContext,
    timed_field: Option<String>,
    /// Protocol output stays plain even when a key-reader clone refreshes it.
    suppress_live: bool,
    concurrency_handler: Option<ConcurrencyHandler>,
    key_feedback: Option<KeyFeedback>,
    next_operation_id: u64,
    next_id: u64,
    next_update_id: u64,
    /// What the live region currently on screen is.
    painted: Painted,
    /// Last known terminal `(rows, columns)` the region was laid out for. Kept
    /// across an unknown size read so a change is still detected once the size
    /// is readable again. A change, or an unreadable read after a known size,
    /// means the terminal may have reflowed, so the counted rows no longer
    /// locate the region and the next frame wipes the screen instead.
    region_viewport: Option<(usize, usize)>,
    task_tails: VecDeque<TaskTail>,
    failed_task_tails: VecDeque<FailedTaskTail>,
    scrolling_snapshot_at: Option<Instant>,
    /// Dashboard mode shared by every handle to this state. The fleet reporter
    /// is a clone, but the key-toggle reader calls the process singleton, so
    /// the limit must live in the shared state to keep both redrawing the same
    /// region.
    recent_update_limit: usize,
    /// Whether verbose streaming is enabled right now.
    verbose_active: bool,
    /// Which streamed-log view the open verbose section shows.
    verbose_view: VerboseView,
    /// Lines scrolled up from the newest end of the active view; 0 pins the
    /// window to the newest content.
    verbose_scroll: usize,
    /// Bounded live tail of verbose lines rendered above the dashboard through
    /// the same clear/redraw path as progress, newest last.
    verbose_tail: VecDeque<VerboseLine>,
    /// Shared redraw budget for host tails, phase tails, and verbose streams.
    stream_redraw_at: Option<Instant>,
    /// Monotonic sequence over every recorded verbose line, so the retained
    /// digest can tell consecutive lines from elided ones.
    verbose_seq: u64,
    /// Last lines seen (any tone), held only long enough to supply `before`
    /// context for the next problem; ordinary output is never retained.
    verbose_recent: VecDeque<VerboseLine>,
    /// Errors and warnings with their surrounding context, kept across hiding
    /// the live tail so a reveal shows the run's problems, oldest first.
    retained_verbose: VecDeque<VerboseLine>,
    /// Trailing context lines the open digest run still wants.
    after_context_remaining: usize,
}

impl ProgressState {
    fn current_host_dashboard(&self) -> Option<&HostDashboard> {
        self.stack
            .iter()
            .rev()
            .find_map(|active| active.host_dashboard.as_ref())
    }

    fn expire_input_feedback(&mut self, now: Instant) -> bool {
        let mut expired = false;
        if self
            .key_feedback
            .is_some_and(|feedback| !feedback_active(Some(feedback.at), now))
        {
            self.key_feedback = None;
            expired = true;
        }
        for active in &mut self.stack {
            if let Some(admission) = active
                .host_dashboard
                .as_mut()
                .and_then(|dashboard| dashboard.admission.as_mut())
            {
                for at in [
                    &mut admission.running_changed_at,
                    &mut admission.target_changed_at,
                ] {
                    if at.is_some() && !feedback_active(*at, now) {
                        *at = None;
                        expired = true;
                    }
                }
            }
        }
        expired
    }

    fn concurrency_available(&self) -> bool {
        self.concurrency_handler.is_some()
            && self
                .current_host_dashboard()
                .and_then(|dashboard| dashboard.admission.as_ref())
                .is_some_and(|admission| admission.adjustable)
    }

    /// Host prefixes are an output-attribution policy, not an input-control
    /// policy. Keep one shape for a multi-host phase even while one substep is
    /// exclusive or admission is draining/stopped.
    fn host_log_attribution_needed(&self) -> bool {
        self.current_host_dashboard()
            .is_some_and(|dashboard| dashboard.order.len() > 1)
    }

    /// Whether `live` differs from the size the painted region was laid out for,
    /// so the terminal may have reflowed. An unreadable size after a known one
    /// counts, because the reflow may have happened at a width we cannot see.
    fn reflowed(&self, live: Option<(usize, usize)>) -> bool {
        self.painted != Painted::None
            && match live {
                Some(live) => self.region_viewport != Some(live),
                None => self.region_viewport.is_some(),
            }
    }

    /// Take the painted state, clearing it so a region that has been released
    /// for exit is not cleared or re-terminated a second time.
    fn take_painted(&mut self) -> Painted {
        let painted = std::mem::take(&mut self.painted);
        self.scrolling_snapshot_at = None;
        painted
    }
}

/// One verbose line, shared by the live ring and the retained digest. Its stream
/// sequence orders the digest and elides its gaps, and its recording time is what
/// the `Logs` header reports, so each view says when the oldest line it still
/// holds was recorded.
#[derive(Clone, Debug, Eq, PartialEq)]
struct VerboseLine {
    seq: u64,
    at: SystemTime,
    tone: Tone,
    text: String,
}

/// Which streamed-log view the `v` section shows.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum VerboseView {
    /// The live stream, newest last.
    #[default]
    Run,
    /// Retained errors and warnings with their surrounding context, elided by
    /// `...` between non-adjacent runs.
    Errors,
}

impl ProgressState {
    /// Line count of the active view's content, bounding how far it can scroll.
    fn verbose_content_len(&self) -> usize {
        match self.verbose_view {
            VerboseView::Run => self.verbose_tail.len(),
            // The digest renders `...` rows between non-consecutive runs, so its
            // row count differs from the number of retained lines.
            VerboseView::Errors => digest_row_count(&self.retained_verbose),
        }
    }

    /// Open the verbose section. Each view's `since` label comes from the lines
    /// it holds, so opening carries no state beyond the flag.
    fn open_verbose(&mut self) {
        self.verbose_active = true;
    }

    /// Close the verbose section, leaving the buffers to their owners: the live
    /// ring is cleared when it is hidden, and the digest outlives the hide.
    fn close_verbose(&mut self) {
        self.verbose_active = false;
    }

    /// When the active view's oldest line was recorded, for the `Logs` header.
    /// Both views read the front of the buffer they show, so the label always
    /// describes the content on screen, however much of it has been evicted.
    fn verbose_started(&self) -> Option<SystemTime> {
        let oldest = match self.verbose_view {
            VerboseView::Run => self.verbose_tail.front(),
            VerboseView::Errors => self.retained_verbose.front(),
        };
        oldest.map(|line| line.at)
    }
}

#[derive(Clone, Debug)]
struct ActiveProgress {
    id: u64,
    label: String,
    detail: Option<String>,
    detail_emitted_at: Option<Instant>,
    recent_updates: VecDeque<RecentUpdate>,
    host_dashboard: Option<HostDashboard>,
    started: Instant,
}

#[derive(Clone, Debug, Default)]
struct HostDashboard {
    kind: RosterKind,
    title: Option<String>,
    order: Vec<String>,
    rows: BTreeMap<String, HostRow>,
    stage: Option<String>,
    wave: Option<(usize, usize)>,
    concurrency: usize,
    admission: Option<AdmissionDisplay>,
}

#[derive(Clone, Debug)]
struct AdmissionDisplay {
    running: usize,
    target: usize,
    constraint: Option<String>,
    adjustable: bool,
    running_changed_at: Option<Instant>,
    target_changed_at: Option<Instant>,
}

#[derive(Clone, Debug)]
struct SuspendedHostTask {
    key: String,
    label: Option<String>,
    started: Option<Instant>,
    output: VecDeque<String>,
    heartbeat_interval: Option<Duration>,
    last_heartbeat: Option<Instant>,
    last_output: Option<Instant>,
}

#[derive(Clone, Debug)]
struct HostRow {
    state: HostRowState,
    outcome: Option<RowOutcome>,
    timing: HostTiming,
    suspended: Vec<SuspendedHostTask>,
    task_key: Option<String>,
    task: Option<String>,
    task_started: Option<Instant>,
    summary: Option<String>,
    output: VecDeque<String>,
    failure_output: VecDeque<String>,
    heartbeat_interval: Option<Duration>,
    last_heartbeat: Option<Instant>,
    last_output: Option<Instant>,
}

/// Liveness of a running step's heartbeat, for the dashboard indicator.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Heartbeat {
    /// The step declared no heartbeat; no liveness can be inferred.
    Absent,
    /// A heartbeat arrived within the expected window (or the first window is
    /// still open), so the step is actively reporting progress.
    Live,
    /// A declared heartbeat has not arrived within its expected window.
    Stalled,
}

/// A heartbeat is overdue once twice its interval has elapsed since the last
/// beat (or since the step started, before the first beat). The extra window
/// avoids flagging a step that is merely between beats.
fn heartbeat_state(row: &HostRow) -> Heartbeat {
    let Some(interval) = row.heartbeat_interval else {
        return Heartbeat::Absent;
    };
    let Some(reference) = row.last_heartbeat.or(row.task_started) else {
        return Heartbeat::Absent;
    };
    if reference.elapsed() <= interval.saturating_mul(2) {
        Heartbeat::Live
    } else {
        Heartbeat::Stalled
    }
}

impl HostRow {
    /// A running row is "quiet" once no output has arrived for a few seconds;
    /// only then does a live heartbeat pulse, so active streams stay steady.
    fn is_quiet(&self) -> bool {
        self.last_output
            .or(self.task_started)
            .is_some_and(|last| last.elapsed() >= QUIET_BLINK_AFTER)
    }

    /// Interruption is a terminal host state: any later host-level outcome for
    /// the same row keeps it instead of downgrading it to failed or skipped.
    fn keep_interrupted(&mut self, _elapsed: Option<Duration>) -> bool {
        if self.state != HostRowState::Interrupted {
            return false;
        }
        self.outcome = Some(RowOutcome::Interrupted);
        self.timing.stop(Instant::now());
        self.task_started = None;
        self.suspended.clear();
        true
    }

    fn duration(&self) -> Option<Duration> {
        self.timing
            .observed
            .then(|| self.timing.elapsed(Instant::now()))
    }

    fn duration_metadata(&self) -> String {
        self.duration()
            .map(|elapsed| format!(" · {}", format_duration(elapsed)))
            .unwrap_or_default()
    }

    fn suspend_task(&mut self) {
        if self.state == HostRowState::Running
            && let Some(key) = self.task_key.take()
        {
            self.suspended.push(SuspendedHostTask {
                key,
                label: self.task.take(),
                started: self.task_started.take(),
                output: std::mem::take(&mut self.output),
                heartbeat_interval: self.heartbeat_interval,
                last_heartbeat: self.last_heartbeat,
                last_output: self.last_output,
            });
        }
    }

    fn restore_task(&mut self) {
        if let Some(task) = self.suspended.pop() {
            self.state = HostRowState::Running;
            self.task_key = Some(task.key);
            self.task = task.label;
            self.task_started = task.started;
            self.output = task.output;
            self.heartbeat_interval = task.heartbeat_interval;
            self.last_heartbeat = task.last_heartbeat;
            self.last_output = task.last_output;
        }
    }

    fn retain_failure(&mut self, lines: VecDeque<String>) {
        for line in lines {
            if self.failure_output.back() != Some(&line) {
                self.failure_output.push_back(line);
            }
            while self.failure_output.len() > RETAINED_OUTPUT_LINES_PER_TASK {
                self.failure_output.pop_front();
            }
        }
    }
}

impl Default for HostRow {
    fn default() -> Self {
        Self {
            state: HostRowState::Pending,
            outcome: None,
            timing: HostTiming::default(),
            suspended: Vec::new(),
            task_key: None,
            task: None,
            task_started: None,
            summary: None,
            output: VecDeque::new(),
            failure_output: VecDeque::new(),
            heartbeat_interval: None,
            last_heartbeat: None,
            last_output: None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HostRowState {
    Unconfirmed,
    Pending,
    Running,
    Completed,
    Finalizing,
    Succeeded,
    Skipped,
    Warning,
    Failed,
    Interrupted,
}

/// Terminal-ish outcome of a host-attributed task. Success is either a plain
/// completed stage or a finalizing activation/rollback observer; interruption
/// is a distinct terminal outcome, not a failure of the host itself.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HostTaskOutcome {
    Unconfirmed,
    Done,
    Finalizing,
    Failed,
    Interrupted,
}

#[derive(Clone, Debug)]
struct RecentUpdate {
    key: String,
    text: String,
    tone: Tone,
    output: VecDeque<String>,
}

#[derive(Clone, Debug)]
struct TaskTail {
    key: String,
    output: VecDeque<String>,
}

#[derive(Clone, Debug)]
struct FailedTaskTail {
    label: String,
    output: VecDeque<String>,
}

const LIVE_OUTPUT_LINES_PER_TASK: usize = 5;
/// Bounded history for the live verbose tail; rendering keeps only what fits.
const VERBOSE_MAX_LIVE_LINES: usize = 10_000;
/// Errors and warnings kept, with context, across hiding the verbose tail.
const VERBOSE_MAX_RETAINED_LINES: usize = 500;
/// Context lines kept on each side of a retained problem, so a reveal shows
/// enough surrounding output to read it.
const VERBOSE_CONTEXT_LINES: usize = 2;
/// Marker inserted between digest lines that were not consecutive in the
/// stream, and before the live tail resumes.
const VERBOSE_ELISION: &str = "...";
/// Rows assumed when the terminal will not report its size (`TIOCGWINSZ`
/// returning zero, as a freshly allocated pty can). An unknown viewport budgets
/// like a plain terminal instead of like an unbounded one, so an open section
/// can never stream its whole content into the scrollback.
const DEFAULT_VIEWPORT_ROWS: usize = 24;
/// Minimum interval between live verbose redraws, capping flicker and I/O on
/// high-volume streams; the heartbeat still renders the tail afterwards.
const STREAM_REDRAW_INTERVAL: Duration = Duration::from_millis(50);
/// Shown in the `Logs` header when a timestamp cannot be resolved, so the header
/// keeps its shape instead of dropping the segment.
const UNKNOWN_CLOCK_TIME: &str = "--:--:--";
/// Lines of task output kept for a failed step's tail.
const RETAINED_OUTPUT_LINES_PER_TASK: usize = 5;
const RETAINED_ACTIVE_TASK_TAILS: usize = 128;
const RETAINED_FAILED_TASK_TAILS: usize = 8;
const SCROLLING_SNAPSHOT_INTERVAL: Duration = Duration::from_secs(5);
/// A running host row pulses its live heartbeat only after this much silence,
/// so rows that are actively streaming output stay steady.
const QUIET_BLINK_AFTER: Duration = Duration::from_secs(5);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StepProgress {
    pub transaction: String,
    pub item: String,
    pub action: Action,
    pub step: String,
    pub description: String,
    pub location: String,
}

/// One admitted operation, independent of the currently displayed substep.
/// Nested guards/tasks count once. Dropping a stale guard cannot affect a later phase.
#[derive(Debug)]
pub struct HostOperation {
    reporter: ProgressReporter,
    host: String,
    phase_id: Option<u64>,
    id: u64,
}

impl Drop for HostOperation {
    fn drop(&mut self) {
        if !self.reporter.enabled() {
            return;
        }
        let _output = self.reporter.output.lock().ok();
        let mut frame = ProgressFrame::new(&self.reporter.destination, self.reporter.interactive);
        if let Ok(mut state) = self.reporter.state.lock()
            && let Some(active) = state
                .stack
                .iter_mut()
                .find(|active| Some(active.id) == self.phase_id)
            && let Some(row) = active
                .host_dashboard
                .as_mut()
                .and_then(|dashboard| dashboard.rows.get_mut(&self.host))
        {
            row.timing
                .finish(&Interval::Operation(self.id), Instant::now(), false);
        }
        self.reporter.redraw_current(&mut frame);
    }
}

impl ProgressReporter {
    pub fn new(enabled: bool) -> Self {
        let interactive = io::stderr().is_terminal();
        Self {
            enabled,
            interactive,
            recent_update_limit: 0,
            style: TerminalStyle::for_stderr(),
            destination: ProgressDestination::Stderr,
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        }
    }

    pub fn enabled(&self) -> bool {
        self.enabled && !json_output()
    }

    pub fn without_color(mut self) -> Self {
        self.style = TerminalStyle::from_capabilities(false, false);
        self
    }

    /// GitHub workflow commands are an append-only protocol even on a terminal.
    pub fn without_terminal(mut self) -> Self {
        self.interactive = false;
        if let Ok(mut state) = self.state.lock() {
            state.suppress_live = true;
        }
        self.without_color()
    }

    /// Start the fleet command clock and discard only fleet presentation history.
    pub fn begin_workflow(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.workflow = WorkflowContext {
                started: Some(Instant::now()),
                ..WorkflowContext::default()
            };
            state.concurrency_handler = None;
            state.key_feedback = None;
            state.suppress_live = false;
        }
    }

    /// Install input handling on this reporter, with scoped restoration.
    pub fn concurrency_handler(
        &self,
        handler: impl Fn(ConcurrencyChange) -> bool + Send + Sync + 'static,
    ) -> ConcurrencyGuard {
        let handler = ConcurrencyHandler(Arc::new(handler));
        let previous = self
            .state
            .lock()
            .ok()
            .and_then(|mut state| state.concurrency_handler.replace(handler));
        self.refresh();
        ConcurrencyGuard {
            reporter: self.clone(),
            previous,
        }
    }

    pub fn concurrency_available(&self) -> bool {
        self.state
            .lock()
            .is_ok_and(|state| state.concurrency_available())
    }

    pub fn host_log_attribution_needed(&self) -> bool {
        self.state
            .lock()
            .is_ok_and(|state| state.host_log_attribution_needed())
    }

    pub fn adjust_concurrency(&self, change: ConcurrencyChange) {
        // Call outside the presentation lock: the scheduler may wake a redraw.
        let request = self.state.lock().ok().and_then(|state| {
            if !state.concurrency_available() {
                return None;
            }
            let admission = state.current_host_dashboard()?.admission.as_ref()?;
            Some((
                state.concurrency_handler.clone()?,
                (admission.running, admission.target),
            ))
        });
        if let Some((handler, before)) = request
            && (handler.0)(change)
        {
            self.concurrency_key_accepted(change, before);
        }
    }

    fn concurrency_key_accepted(&self, change: ConcurrencyChange, before: (usize, usize)) {
        if !self.interactive || !self.style.enabled() {
            return;
        }
        let at = Instant::now();
        if let Ok(mut state) = self.state.lock() {
            state.key_feedback = Some(KeyFeedback {
                key: match change {
                    ConcurrencyChange::Increase => FeedbackKey::Increase,
                    ConcurrencyChange::Decrease => FeedbackKey::Decrease,
                },
                at,
            });
            // The scheduler can publish between callback return and this lock.
            // Mark already-updated numbers now; later snapshots see key_feedback.
            if let Some(admission) = state
                .stack
                .iter_mut()
                .rev()
                .find_map(|active| active.host_dashboard.as_mut())
                .and_then(|dashboard| dashboard.admission.as_mut())
            {
                if admission.running != before.0 {
                    admission.running_changed_at = Some(at);
                }
                if admission.target != before.1 {
                    admission.target_changed_at = Some(at);
                }
            }
        }
        self.refresh();
    }

    /// Presentation-only acknowledgement; never grants execution authority.
    pub(crate) fn key_pressed(&self, key: FeedbackKey) {
        if !self.interactive || !self.style.enabled() {
            return;
        }
        if let Ok(mut state) = self.state.lock() {
            state.key_feedback = Some(KeyFeedback {
                key,
                at: Instant::now(),
            });
        }
        self.refresh();
    }

    /// Use the existing reader tick, not one timer/thread per press.
    pub(crate) fn expire_input_feedback(&self) {
        if !self.interactive || !self.style.enabled() {
            return;
        }
        let expired = self
            .state
            .try_lock()
            .is_ok_and(|mut state| state.expire_input_feedback(Instant::now()));
        if expired {
            self.refresh();
        }
    }

    pub fn host_operation(&self, host: &str) -> HostOperation {
        let mut operation = HostOperation {
            reporter: self.clone(),
            host: host.to_owned(),
            phase_id: None,
            id: 0,
        };
        if !self.enabled() {
            return operation;
        }
        if let Ok(mut state) = self.state.lock() {
            state.next_operation_id = state.next_operation_id.wrapping_add(1);
            operation.id = state.next_operation_id;
            if let Some(active) = state
                .stack
                .iter_mut()
                .rev()
                .find(|active| active.host_dashboard.is_some())
                && let Some(row) = active
                    .host_dashboard
                    .as_mut()
                    .filter(|dashboard| dashboard.kind == RosterKind::Hosts)
                    .and_then(|dashboard| dashboard.rows.get_mut(host))
                && row.outcome.is_none()
            {
                operation.phase_id = Some(active.id);
                row.timing
                    .start(Interval::Operation(operation.id), Instant::now());
            }
        }
        self.refresh();
        operation
    }

    /// Snapshot before the phase's active span is removed. Terminal calls are
    /// idempotent; unfinished rows retain observed time without claiming success.
    pub fn record_fleet_phase(
        &self,
        key: &str,
        label: &str,
        marker: &'static str,
        tone: Tone,
        elapsed: Duration,
    ) {
        if let Ok(mut state) = self.state.lock() {
            let now = Instant::now();
            let (kind, rows) = state
                .stack
                .iter_mut()
                .rev()
                .find_map(|active| active.host_dashboard.as_mut())
                .map(|dashboard| {
                    let rows = dashboard
                        .order
                        .iter()
                        .filter_map(|name| {
                            let row = dashboard.rows.get_mut(name)?;
                            row.timing.stop(now);
                            Some(RowSnapshot {
                                name: name.clone(),
                                elapsed: row.duration(),
                                outcome: row.outcome.or(match row.state {
                                    HostRowState::Interrupted => Some(RowOutcome::Interrupted),
                                    HostRowState::Unconfirmed => Some(RowOutcome::Unconfirmed),
                                    _ => None,
                                }),
                            })
                        })
                        .collect();
                    (dashboard.kind, rows)
                })
                .unwrap_or_default();
            state.workflow.phases.push(PhaseSnapshot {
                key: key.to_owned(),
                label: label.to_owned(),
                marker,
                tone,
                elapsed,
                kind,
                rows,
            });
        }
    }

    /// The retained dashboard owns successful TTY phase lines; logs still append.
    pub fn host_phase_completed(&self, label: String, elapsed: Duration) {
        if self.shows_recent_updates()
            && self
                .state
                .lock()
                .is_ok_and(|state| state.workflow.started.is_some())
        {
            self.end_silent_phase();
        } else {
            self.completed(label, elapsed);
        }
    }

    pub fn workflow_elapsed(&self) -> Option<Duration> {
        self.state
            .lock()
            .ok()
            .and_then(|state| state.workflow.started.map(|start| start.elapsed()))
    }

    pub fn phase_outcome_counts(&self, key: &str) -> Option<String> {
        let state = self.state.lock().ok()?;
        let phase = state
            .workflow
            .phases
            .iter()
            .rev()
            .find(|phase| phase.key == key)?;
        (!phase.rows.is_empty()).then(|| {
            phase
                .kind
                .counts(phase.rows.iter().map(|row| row.outcome))
                .join(" · ")
        })
    }

    pub(crate) fn phase_projects(&self, key: &str) -> Vec<RowSnapshot> {
        self.state
            .lock()
            .ok()
            .and_then(|state| {
                state
                    .workflow
                    .phases
                    .iter()
                    .rev()
                    .find(|phase| phase.key == key && phase.kind == RosterKind::Projects)
                    .map(|phase| phase.rows.clone())
            })
            .unwrap_or_default()
    }

    /// Retain summary data, but release the run heading/history before final output.
    pub fn finish_workflow(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.workflow.started = None;
        }
        self.refresh();
    }

    /// Close a silent (GitHub) phase without publishing an extra outcome line.
    pub fn end_silent_phase(&self) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut frame = ProgressFrame::new(&self.destination, self.interactive);
        self.finish_current(&mut frame);
        self.redraw_current(&mut frame);
    }

    pub fn host_duration_summaries(&self, hosts: &[&str]) -> BTreeMap<String, String> {
        self.state
            .lock()
            .map(|state| fleet_timing::host_duration_summaries(&state.workflow.phases, hosts))
            .unwrap_or_default()
    }

    /// Keep a bounded, in-place window of recent child activity below the
    /// active span on interactive terminals. Redirected output remains the
    /// existing stable line stream.
    pub fn with_recent_updates(mut self, limit: usize) -> Self {
        self.recent_update_limit = limit;
        if let Ok(mut state) = self.state.lock() {
            state.recent_update_limit = limit;
        }
        self
    }

    pub fn shows_recent_updates(&self) -> bool {
        if !self.interactive {
            return false;
        }
        let shared = self
            .state
            .lock()
            .map_or(0, |state| state.recent_update_limit);
        self.recent_update_limit.max(shared) > 0
    }

    pub fn begin_task_scope(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.task_tails.clear();
            state.failed_task_tails.clear();
        }
    }

    pub fn begin_host_dashboard(&self, hosts: &[String]) {
        self.begin_dashboard(RosterKind::Hosts, hosts, None);
    }

    pub fn begin_fleet_dashboard(&self, hosts: &[String], title: &str) {
        self.begin_dashboard(RosterKind::Hosts, hosts, Some(title));
    }

    pub(crate) fn begin_project_dashboard(&self, projects: &[String], title: &str) {
        self.begin_dashboard(RosterKind::Projects, projects, Some(title));
    }

    fn begin_dashboard(&self, kind: RosterKind, names: &[String], title: Option<&str>) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        if let Ok(mut state) = self.state.lock()
            && let Some(active) = state.stack.last_mut()
        {
            active.host_dashboard = Some(HostDashboard {
                kind,
                title: title.map(str::to_owned),
                order: names.to_vec(),
                rows: names
                    .iter()
                    .map(|name| (name.clone(), HostRow::default()))
                    .collect(),
                ..HostDashboard::default()
            });
        }
        self.redraw_current(&mut output_frame);
    }

    pub fn host_schedule(
        &self,
        stage: impl Into<String>,
        wave: Option<(usize, usize)>,
        concurrency: usize,
    ) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        if let Ok(mut state) = self.state.lock()
            && let Some(dashboard) = state
                .stack
                .iter_mut()
                .rev()
                .find_map(|active| active.host_dashboard.as_mut())
            && dashboard.kind == RosterKind::Hosts
        {
            dashboard.stage = Some(stage.into());
            dashboard.wave = wave;
            dashboard.concurrency = concurrency;
        }
        self.redraw_current(&mut output_frame);
    }

    /// Actual scheduler occupancy. Never infer slots from the visible task row.
    pub fn phase_admission(
        &self,
        running: usize,
        target: usize,
        adjustable: bool,
        constraint: Option<&str>,
    ) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut frame = ProgressFrame::new(&self.destination, self.interactive);
        if let Ok(mut state) = self.state.lock() {
            let pressed_at = state
                .key_feedback
                .filter(|feedback| {
                    matches!(feedback.key, FeedbackKey::Increase | FeedbackKey::Decrease)
                        && feedback_active(Some(feedback.at), Instant::now())
                })
                .map(|feedback| feedback.at);
            if let Some(dashboard) = state
                .stack
                .iter_mut()
                .rev()
                .find_map(|active| active.host_dashboard.as_mut())
                && dashboard.kind == RosterKind::Hosts
            {
                let previous = dashboard.admission.as_ref();
                let running_changed_at = previous.and_then(|old| {
                    if old.running != running && pressed_at.is_some() {
                        pressed_at
                    } else {
                        old.running_changed_at
                    }
                });
                let target_changed_at = previous.and_then(|old| {
                    if old.target != target && pressed_at.is_some() {
                        pressed_at
                    } else {
                        old.target_changed_at
                    }
                });
                dashboard.admission = Some(AdmissionDisplay {
                    running,
                    target,
                    constraint: constraint.map(str::to_owned),
                    adjustable,
                    running_changed_at,
                    target_changed_at,
                });
            }
        }
        self.redraw_current(&mut frame);
    }

    pub fn host_task_started(
        &self,
        host: &str,
        key: &str,
        label: &str,
        heartbeat_interval: Option<Duration>,
    ) {
        self.start_task_tail(key);
        self.update_host_row(host, Redraw::Immediate, |row| {
            if row.outcome.is_some()
                || matches!(
                    row.state,
                    HostRowState::Interrupted | HostRowState::Unconfirmed
                )
            {
                return;
            }
            let interval = Interval::Task(key.to_owned());
            if row.task_key.as_deref() == Some(key) && row.state == HostRowState::Running {
                return;
            }
            row.suspend_task();
            row.timing.start(interval, Instant::now());
            row.state = HostRowState::Running;
            row.task_key = Some(key.to_owned());
            row.task = Some(label.to_owned());
            row.task_started = Some(Instant::now());
            row.summary = None;
            row.output.clear();
            row.heartbeat_interval = heartbeat_interval;
            row.last_heartbeat = None;
            row.last_output = Some(Instant::now());
        });
        if !self.shows_recent_updates() {
            self.detail(format!("{host} · {label} · running"));
        }
    }

    pub fn host_task_heartbeat(&self, host: &str, key: &str, label: &str) {
        if !self.shows_recent_updates() {
            return;
        }
        self.update_host_row(host, Redraw::Immediate, |row| {
            if row.task_key.as_deref() == Some(key) {
                row.task = Some(label.to_owned());
                row.last_heartbeat = Some(Instant::now());
            } else if let Some(task) = row.suspended.iter_mut().find(|task| task.key == key) {
                task.last_heartbeat = Some(Instant::now());
            }
        });
    }

    pub fn host_task_output(&self, host: &str, key: &str, line: String) {
        if line.is_empty() {
            return;
        }
        self.update_host_row(host, Redraw::Stream, |row| {
            if row.task_key.as_deref() != Some(key) {
                if let Some(task) = row.suspended.iter_mut().find(|task| task.key == key) {
                    if task.output.back() != Some(&line) {
                        task.output.push_back(line);
                    }
                    while task.output.len() > LIVE_OUTPUT_LINES_PER_TASK {
                        task.output.pop_front();
                    }
                    task.last_output = Some(Instant::now());
                }
                return;
            }
            if row.output.back() != Some(&line) {
                row.output.push_back(line);
            }
            while row.output.len() > LIVE_OUTPUT_LINES_PER_TASK {
                row.output.pop_front();
            }
            row.last_output = Some(Instant::now());
        });
    }

    pub fn host_task_finished(
        &self,
        host: &str,
        key: &str,
        label: &str,
        done: &str,
        elapsed: Duration,
        succeeded: bool,
    ) {
        self.finish_host_task(
            host,
            key,
            label,
            done,
            elapsed,
            if succeeded {
                HostTaskOutcome::Done
            } else {
                HostTaskOutcome::Failed
            },
        );
    }

    pub fn host_task_finalizing(
        &self,
        host: &str,
        key: &str,
        label: &str,
        done: &str,
        elapsed: Duration,
    ) {
        self.finish_host_task(host, key, label, done, elapsed, HostTaskOutcome::Finalizing);
    }

    pub fn host_task_interrupted(&self, host: &str, key: &str, label: &str, elapsed: Duration) {
        self.finish_host_task(
            host,
            key,
            label,
            label,
            elapsed,
            HostTaskOutcome::Interrupted,
        );
    }

    pub fn host_task_unconfirmed(&self, host: &str, key: &str, label: &str, elapsed: Duration) {
        self.finish_host_task(
            host,
            key,
            label,
            label,
            elapsed,
            HostTaskOutcome::Unconfirmed,
        );
    }

    pub fn host_unconfirmed(&self, host: &str, summary: impl Into<String>) {
        let summary = summary.into();
        self.update_host_row(host, Redraw::Immediate, |row| {
            if row.outcome.is_some() {
                return;
            }
            row.outcome = Some(RowOutcome::Unconfirmed);
            row.timing.stop(Instant::now());
            row.suspended.clear();
            row.state = HostRowState::Unconfirmed;
            row.summary = Some(summary);
            row.task_started = None;
            row.retain_failure(row.output.clone());
            row.output.clone_from(&row.failure_output);
        });
    }

    fn finish_host_task(
        &self,
        host: &str,
        key: &str,
        label: &str,
        done: &str,
        elapsed: Duration,
        outcome: HostTaskOutcome,
    ) {
        let succeeded = matches!(outcome, HostTaskOutcome::Done | HostTaskOutcome::Finalizing);
        self.finish_task_tail(
            key,
            format!(
                "{host} · {label} · task elapsed {}",
                format_duration(elapsed)
            ),
            succeeded,
        );
        self.update_host_row(host, Redraw::Immediate, |row| {
            if row.outcome.is_some() {
                return;
            }
            row.timing.finish(
                &Interval::Task(key.to_owned()),
                Instant::now(),
                outcome == HostTaskOutcome::Finalizing,
            );
            if row.task_key.as_deref() != Some(key) {
                if let Some(index) = row.suspended.iter().position(|task| task.key == key) {
                    let task = row.suspended.remove(index);
                    if !succeeded {
                        row.retain_failure(task.output);
                    }
                }
                return;
            }
            row.task = Some(done.to_owned());
            row.task_started = None;
            match outcome {
                HostTaskOutcome::Done | HostTaskOutcome::Finalizing => {
                    row.state = if outcome == HostTaskOutcome::Finalizing {
                        HostRowState::Finalizing
                    } else {
                        HostRowState::Completed
                    };
                    row.output.clear();
                }
                HostTaskOutcome::Failed
                | HostTaskOutcome::Interrupted
                | HostTaskOutcome::Unconfirmed => {
                    row.state = match outcome {
                        HostTaskOutcome::Unconfirmed => HostRowState::Unconfirmed,
                        HostTaskOutcome::Interrupted => HostRowState::Interrupted,
                        _ => HostRowState::Failed,
                    };
                    row.retain_failure(row.output.clone());
                }
            }
            if matches!(
                outcome,
                HostTaskOutcome::Interrupted | HostTaskOutcome::Unconfirmed
            ) {
                row.timing.stop(Instant::now());
                row.suspended.clear();
            } else {
                row.restore_task();
            }
        });
        if !self.shows_recent_updates() {
            let line = format!(
                "{host} · {} · {}",
                match outcome {
                    HostTaskOutcome::Done | HostTaskOutcome::Finalizing => done.to_owned(),
                    HostTaskOutcome::Unconfirmed =>
                        format!("{label} · remote execution unconfirmed"),
                    HostTaskOutcome::Failed => format!("{label} · failed"),
                    HostTaskOutcome::Interrupted => format!("{label} · interrupted"),
                },
                format_duration(elapsed)
            );
            // Interruption is a terminal outcome with no later summary of its
            // own, so it must not be rate-limited like a rolling detail line.
            if outcome == HostTaskOutcome::Unconfirmed {
                self.message(format!("? {line}"));
            } else if outcome == HostTaskOutcome::Interrupted {
                self.message(format!("⊘ {line}"));
            } else {
                self.detail(line);
            }
        }
    }

    pub fn host_finished(
        &self,
        host: &str,
        succeeded: bool,
        elapsed: Option<Duration>,
        summary: impl Into<String>,
    ) {
        let summary = summary.into();
        self.update_host_row(host, Redraw::Immediate, |row| {
            if row.outcome.is_some() || row.keep_interrupted(elapsed) {
                return;
            }
            row.timing.stop(Instant::now());
            row.suspended.clear();
            if row.state == HostRowState::Unconfirmed {
                row.outcome = Some(RowOutcome::Unconfirmed);
                return;
            }
            row.outcome = Some(if succeeded {
                RowOutcome::Succeeded
            } else {
                RowOutcome::Failed
            });
            row.state = if succeeded {
                HostRowState::Succeeded
            } else {
                HostRowState::Failed
            };
            // Legacy callers can provide a duration when no task/operation was observed.
            if !row.timing.observed
                && let Some(elapsed) = elapsed
            {
                row.timing.observed = true;
                row.timing.total = elapsed;
            }
            row.summary = (!summary.is_empty()).then_some(summary);
            row.task_started = None;
            if succeeded {
                row.output.clear();
                row.failure_output.clear();
            } else {
                row.retain_failure(row.output.clone());
                row.output.clone_from(&row.failure_output);
            }
        });
    }

    pub fn host_skipped(&self, host: &str, summary: impl Into<String>) {
        self.host_nonfatal(host, summary.into(), HostRowState::Skipped);
    }

    pub fn host_warning(&self, host: &str, summary: impl Into<String>) {
        self.host_nonfatal(host, summary.into(), HostRowState::Warning);
    }

    fn host_nonfatal(&self, host: &str, summary: String, state: HostRowState) {
        self.update_host_row(host, Redraw::Immediate, |row| {
            if row.outcome.is_some() || row.keep_interrupted(None) {
                return;
            }
            row.timing.stop(Instant::now());
            row.suspended.clear();
            if row.state == HostRowState::Unconfirmed {
                row.outcome = Some(RowOutcome::Unconfirmed);
                return;
            }
            row.outcome = Some(RowOutcome::Skipped);
            row.state = state;
            row.summary = (!summary.is_empty()).then_some(summary);
            row.task_started = None;
            row.output.clear();
            row.failure_output.clear();
        });
    }

    pub(crate) fn project_step(&self, project: &str, label: &str) {
        self.update_dashboard_row(RosterKind::Projects, project, Redraw::Immediate, |row| {
            if row.outcome.is_some() {
                return;
            }
            let now = Instant::now();
            row.timing.start(Interval::Project, now);
            row.state = HostRowState::Running;
            row.task = Some(label.to_owned());
            row.task_started = Some(now);
        });
        if !self.shows_recent_updates() {
            self.detail(format!("{project} · {label}"));
        }
    }

    pub(crate) fn project_finished(&self, project: &str, outcome: RowOutcome) {
        self.update_dashboard_row(RosterKind::Projects, project, Redraw::Immediate, |row| {
            if row.outcome.is_some() {
                return;
            }
            row.timing.stop(Instant::now());
            row.task_started = None;
            row.outcome = Some(outcome);
            row.state = match outcome {
                RowOutcome::Succeeded => HostRowState::Succeeded,
                RowOutcome::Failed => HostRowState::Failed,
                RowOutcome::Skipped => HostRowState::Skipped,
                RowOutcome::Interrupted => HostRowState::Interrupted,
                RowOutcome::Unconfirmed => HostRowState::Unconfirmed,
            };
            if outcome == RowOutcome::Skipped {
                row.summary = Some("skipped (unchanged)".to_owned());
            }
        });
    }

    fn update_host_row(&self, host: &str, redraw: Redraw, update: impl FnOnce(&mut HostRow)) {
        self.update_dashboard_row(RosterKind::Hosts, host, redraw, update);
    }

    fn update_dashboard_row(
        &self,
        kind: RosterKind,
        name: &str,
        redraw: Redraw,
        update: impl FnOnce(&mut HostRow),
    ) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        if let Ok(mut state) = self.state.lock()
            && let Some(dashboard) = state
                .stack
                .iter_mut()
                .rev()
                .find_map(|active| active.host_dashboard.as_mut())
            && dashboard.kind == kind
            && let Some(row) = dashboard.rows.get_mut(name)
        {
            update(row);
        }
        match redraw {
            Redraw::Immediate => self.redraw_current(&mut output_frame),
            Redraw::Stream => self.redraw_stream(&mut output_frame),
        }
    }

    pub fn end_task_scope(&self) {
        self.begin_task_scope();
    }

    pub fn phase_started(&self, transaction: &str, action: Action, items: usize) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        self.clear_line(&mut output_frame);
        let item_count = if items == 1 {
            String::new()
        } else {
            format!(" · {items} items")
        };
        let heading = format!("{} {transaction}{item_count}", action_title(action));
        output_frame.write(&format!(
            "\n{}\n\n",
            self.style.paint(Tone::Emphasis, heading)
        ));
        self.redraw_current(&mut output_frame);
    }

    pub fn phase_completed(&self, _transaction: &str, action: Action, elapsed: Duration) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        self.clear_line(&mut output_frame);
        let line = styled_outcome_line(
            self.style,
            "✓",
            Tone::Success,
            &format!(
                "{} complete · {}",
                action_title(action),
                format_duration(elapsed)
            ),
        );
        output_frame.write(&format!("{line}\n\n"));
        self.redraw_current(&mut output_frame);
    }

    pub fn step_started(&self, step: &StepProgress) {
        self.started(step_label(step));
    }

    pub fn detail(&self, detail: impl Into<String>) {
        if !self.enabled() {
            return;
        }
        let detail = detail.into();
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        if self.shows_recent_updates() {
            let mut state = match self.state.lock() {
                Ok(state) => state,
                Err(_) => return,
            };
            state.next_update_id = state.next_update_id.wrapping_add(1);
            let key = format!("detail:{}", state.next_update_id);
            if let Some(current) = state.stack.last_mut() {
                push_recent_update(
                    &mut current.recent_updates,
                    self.recent_update_limit,
                    key,
                    detail,
                    Tone::Muted,
                );
            }
            drop(state);
            self.redraw_current(&mut output_frame);
            return;
        }
        let mut active = None;
        let mut changed = true;
        let mut emit = true;
        if let Ok(mut state) = self.state.lock() {
            if let Some(current) = state.stack.last_mut() {
                active = Some(current.label.clone());
                changed = current.detail.as_deref() != Some(detail.as_str());
                current.detail = Some(detail.clone());
                if !self.interactive {
                    emit = current
                        .detail_emitted_at
                        .is_none_or(|last| last.elapsed() >= Duration::from_secs(10))
                        || detail.contains("100%");
                    if changed && emit {
                        current.detail_emitted_at = Some(Instant::now());
                    }
                }
            } else {
                changed = false;
            }
        }
        if !changed || !emit {
            return;
        }
        if self.interactive {
            if let Some(active) = active {
                redraw_active(&mut output_frame, self.style, &active, Some(&detail));
            }
        } else {
            output_frame.write(&format!("  {detail}\n"));
        }
    }

    pub fn step_completed(&self, step: &StepProgress, elapsed: Duration) {
        self.completed(step_label(step), elapsed);
    }

    pub fn step_failed(&self, step: &StepProgress, elapsed: Duration, error: &anyhow::Error) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        self.finish_current(&mut output_frame);
        let failure = format!("✗ {} · {}", step_label(step), format_duration(elapsed));
        output_frame.write(&format!("{}\n", self.style.paint(Tone::Failure, failure)));
        output_frame.write(&format!(
            "{}\n",
            self.style
                .paint(Tone::FailureDetail, format!("  {error:#}"))
        ));
        self.redraw_current(&mut output_frame);
    }

    pub fn task_started(&self, key: impl Into<String>, label: impl Into<String>) {
        let key = key.into();
        let label = label.into();
        self.start_task_tail(&key);
        if !self.shows_recent_updates() {
            self.detail(format!("{label} · running"));
            return;
        }
        self.update_task(key, format!("● {label} · running"), Tone::Active);
    }

    pub fn task_finished(
        &self,
        key: impl Into<String>,
        label: impl Into<String>,
        elapsed: Duration,
        succeeded: bool,
    ) {
        let key = key.into();
        let label = label.into();
        self.finish_task_tail(
            &key,
            format!("{label} · task elapsed {}", format_duration(elapsed)),
            succeeded,
        );
        if !self.shows_recent_updates() {
            self.detail(format!(
                "{label} · {} · {}",
                if succeeded { "done" } else { "failed" },
                format_duration(elapsed)
            ));
            return;
        }
        let marker = if succeeded { "✓" } else { "✗" };
        let tone = if succeeded {
            Tone::Success
        } else {
            Tone::Failure
        };
        self.update_task(
            key,
            format!(
                "{marker} {label} · task elapsed {}",
                format_duration(elapsed)
            ),
            tone,
        );
    }

    pub fn task_skipped(&self, key: impl Into<String>, label: impl Into<String>) {
        let key = key.into();
        let label = label.into();
        self.discard_task_tail(&key);
        let line = format!("◇ {label} · skipped");
        if !self.shows_recent_updates() {
            self.message_tone(Tone::Neutral, line);
            return;
        }
        self.update_task(key, line, Tone::Neutral);
    }

    pub fn task_interrupted(
        &self,
        key: impl Into<String>,
        label: impl Into<String>,
        elapsed: Duration,
    ) {
        let key = key.into();
        let label = label.into();
        self.discard_task_tail(&key);
        let line = if self.shows_recent_updates() {
            format!(
                "⊘ {label} · interrupted · task elapsed {}",
                format_duration(elapsed)
            )
        } else {
            format!("⊘ {label} · interrupted · {}", format_duration(elapsed))
        };
        if !self.shows_recent_updates() {
            self.message(line);
            return;
        }
        self.update_task(key, line, Tone::Warning);
    }

    pub fn task_heartbeat(
        &self,
        key: impl Into<String>,
        label: impl Into<String>,
        elapsed: Duration,
    ) {
        let label = label.into();
        if !self.shows_recent_updates() {
            self.detail(format!(
                "{label} · running · {} elapsed",
                format_duration(elapsed)
            ));
            return;
        }
        self.update_task(
            key.into(),
            format!("● {label} · task elapsed {}", format_duration(elapsed)),
            Tone::Active,
        );
    }

    /// Retain a small, terminal-safe output tail for failure reporting. This
    /// evidence is independent of the rolling interactive dashboard so an
    /// early parallel failure cannot be evicted by later task activity.
    pub fn task_output(
        &self,
        key: impl Into<String>,
        _label: impl Into<String>,
        line: impl Into<String>,
    ) {
        let key = key.into();
        let line = line.into();
        if line.is_empty() {
            return;
        }
        if let Ok(mut state) = self.state.lock() {
            let mut tail = state
                .task_tails
                .iter()
                .position(|tail| tail.key == key)
                .and_then(|index| state.task_tails.remove(index))
                .unwrap_or_else(|| TaskTail {
                    key: key.clone(),
                    output: VecDeque::new(),
                });
            if tail.output.back() != Some(&line) {
                tail.output.push_back(line);
            }
            while tail.output.len() > RETAINED_OUTPUT_LINES_PER_TASK {
                tail.output.pop_front();
            }
            state.task_tails.push_back(tail);
            while state.task_tails.len() > RETAINED_ACTIVE_TASK_TAILS {
                state.task_tails.pop_front();
            }
        }
    }

    /// Show an allowlisted, compact status line below a task in the
    /// interactive dashboard. Callers must not pass arbitrary child output.
    pub fn task_live_output(
        &self,
        key: impl Into<String>,
        label: impl Into<String>,
        line: impl Into<String>,
    ) {
        if !self.shows_recent_updates() {
            return;
        }
        let key = key.into();
        let label = label.into();
        let line = line.into();
        if line.is_empty() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        if let Ok(mut state) = self.state.lock()
            && let Some(current) = state.stack.last_mut()
        {
            let mut update = current
                .recent_updates
                .iter()
                .position(|update| update.key == key)
                .and_then(|index| current.recent_updates.remove(index))
                .unwrap_or_else(|| RecentUpdate {
                    key: key.clone(),
                    text: format!("● {label} · running"),
                    tone: Tone::Active,
                    output: VecDeque::new(),
                });
            if update.output.back() != Some(&line) {
                update.output.push_back(line);
            }
            while update.output.len() > RETAINED_OUTPUT_LINES_PER_TASK {
                update.output.pop_front();
            }
            current.recent_updates.push_back(update);
            trim_recent_updates(&mut current.recent_updates, self.recent_update_limit);
        }
        self.redraw_stream(&mut output_frame);
    }

    fn start_task_tail(&self, key: &str) {
        if !self.enabled() {
            return;
        }
        if let Ok(mut state) = self.state.lock() {
            if let Some(index) = state.task_tails.iter().position(|tail| tail.key == key) {
                state.task_tails.remove(index);
            }
            state.task_tails.push_back(TaskTail {
                key: key.to_owned(),
                output: VecDeque::new(),
            });
            while state.task_tails.len() > RETAINED_ACTIVE_TASK_TAILS {
                state.task_tails.pop_front();
            }
        }
    }

    fn finish_task_tail(&self, key: &str, label: String, succeeded: bool) {
        if !self.enabled() {
            return;
        }
        if let Ok(mut state) = self.state.lock()
            && let Some(index) = state.task_tails.iter().position(|tail| tail.key == key)
        {
            let tail = state
                .task_tails
                .remove(index)
                .expect("task tail index exists");
            if !succeeded && !tail.output.is_empty() {
                state.failed_task_tails.push_back(FailedTaskTail {
                    label,
                    output: tail.output,
                });
                while state.failed_task_tails.len() > RETAINED_FAILED_TASK_TAILS {
                    state.failed_task_tails.pop_front();
                }
            }
        }
    }

    fn discard_task_tail(&self, key: &str) {
        if let Ok(mut state) = self.state.lock()
            && let Some(index) = state.task_tails.iter().position(|tail| tail.key == key)
        {
            state.task_tails.remove(index);
        }
    }

    fn update_task(&self, key: String, text: String, tone: Tone) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        if let Ok(mut state) = self.state.lock()
            && let Some(current) = state.stack.last_mut()
        {
            push_recent_update(
                &mut current.recent_updates,
                self.recent_update_limit,
                key,
                text,
                tone,
            );
        }
        self.redraw_current(&mut output_frame);
    }

    pub fn started(&self, label: impl Into<String>) {
        self.start_span(label.into(), true);
    }

    pub fn started_silent(&self, label: impl Into<String>) {
        self.start_span(label.into(), false);
    }

    fn start_span(&self, label: String, announce: bool) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        let mut active_id = None;
        if let Ok(mut state) = self.state.lock() {
            state.next_id = state.next_id.wrapping_add(1);
            let id = state.next_id;
            state.stack.push(ActiveProgress {
                id,
                label: label.clone(),
                detail: None,
                detail_emitted_at: None,
                recent_updates: VecDeque::new(),
                host_dashboard: None,
                started: Instant::now(),
            });
            state.scrolling_snapshot_at = None;
            active_id = Some(id);
        }
        if self.interactive {
            self.redraw_current(&mut output_frame);
            if let Some(active_id) = active_id {
                self.start_heartbeat(active_id);
            }
        } else if announce {
            output_frame.write(&format!(
                "{}\n",
                self.style.paint(Tone::Active, format!("● {label}"))
            ));
        }
    }

    pub fn completed(&self, label: impl Into<String>, elapsed: Duration) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        self.finish_current(&mut output_frame);
        let label = label.into();
        let label = if self.shows_recent_updates() {
            format!("{label} · elapsed {}", format_duration(elapsed))
        } else {
            format!("{label}  {}", format_duration(elapsed))
        };
        let line = styled_outcome_line(self.style, "✓", Tone::Success, &label);
        output_frame.write(&format!("{line}\n"));
        self.redraw_current(&mut output_frame);
    }

    pub fn complete_active(&self, label: impl Into<String>) {
        let elapsed = self
            .state
            .lock()
            .ok()
            .and_then(|state| state.stack.last().map(|active| active.started.elapsed()))
            .unwrap_or_default();
        self.completed(label, elapsed);
    }

    pub fn fail_active(&self, label: impl Into<String>, failure: &str) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        let recent_failures = self.recent_failure_output();
        let host_failures = self.host_failure_output();
        self.finish_current(&mut output_frame);
        let label = label.into();
        output_frame.write(&format!(
            "{}\n",
            styled_outcome_line(self.style, "✗", Tone::Failure, &label)
        ));
        for line in failure.lines() {
            output_frame.write(&format!(
                "{}\n",
                self.style.paint(Tone::FailureDetail, format!("  {line}"))
            ));
        }
        if host_failures.is_empty() && !recent_failures.is_empty() {
            output_frame.write("  Recent command output:\n");
            for (task, output) in recent_failures {
                output_frame.write(&format!("    {task}\n"));
                for line in output {
                    output_frame.write(&format!("      {line}\n"));
                }
            }
        }
        for (host, summary, output) in host_failures {
            output_frame.write(&format!(
                "  {}  {}\n",
                self.style.paint_host(&host),
                self.style.paint(Tone::Failure, format!("✗ {summary}"))
            ));
            for line in output {
                output_frame.write(&format!(
                    "    {}\n",
                    self.style.paint(Tone::FailureDetail, line)
                ));
            }
        }
        self.redraw_current(&mut output_frame);
    }

    pub fn warning_active(&self, label: impl Into<String>, warning: &str) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        let host_failures = self.host_failure_output();
        self.finish_current(&mut output_frame);
        let label = label.into();
        output_frame.write(&format!(
            "{}\n",
            styled_outcome_line(self.style, "◇", Tone::Warning, &label)
        ));
        for line in warning.lines() {
            output_frame.write(&format!(
                "{}\n",
                self.style.paint(Tone::Warning, format!("  {line}"))
            ));
        }
        for (host, summary, output) in host_failures {
            output_frame.write(&format!(
                "  {}  {}\n",
                self.style.paint_host(&host),
                self.style.paint(Tone::Failure, format!("✗ {summary}"))
            ));
            for line in output {
                output_frame.write(&format!(
                    "    {}\n",
                    self.style.paint(Tone::FailureDetail, line)
                ));
            }
        }
        self.redraw_current(&mut output_frame);
    }

    pub fn report_failure_output(&self) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        let recent_failures = self.recent_failure_output();
        if !recent_failures.is_empty() {
            output_frame.write("  Recent command output:\n");
            for (task, output) in recent_failures {
                output_frame.write(&format!("    {task}\n"));
                for line in output {
                    output_frame.write(&format!("      {line}\n"));
                }
            }
        }
    }

    fn recent_failure_output(&self) -> Vec<(String, Vec<String>)> {
        self.state
            .lock()
            .ok()
            .map(|state| {
                state
                    .failed_task_tails
                    .clone()
                    .into_iter()
                    .rev()
                    .take(3)
                    .map(|failure| (failure.label, failure.output.into_iter().collect()))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    }

    fn host_failure_output(&self) -> Vec<(String, String, Vec<String>)> {
        self.state
            .lock()
            .ok()
            .and_then(|state| state.stack.last().cloned())
            .and_then(|active| active.host_dashboard)
            .map(|dashboard| {
                dashboard
                    .order
                    .into_iter()
                    .filter_map(|host| {
                        let row = dashboard.rows.get(&host)?;
                        (matches!(
                            row.state,
                            HostRowState::Failed
                                | HostRowState::Interrupted
                                | HostRowState::Unconfirmed
                        ))
                        .then(|| {
                            let summary = row
                                .summary
                                .clone()
                                .or_else(|| row.task.clone())
                                .unwrap_or_else(|| {
                                    if row.state == HostRowState::Unconfirmed {
                                        "remote execution unconfirmed".to_owned()
                                    } else if row.state == HostRowState::Interrupted {
                                        "interrupted".to_owned()
                                    } else {
                                        "failed".to_owned()
                                    }
                                });
                            let summary = format!("{summary}{}", row.duration_metadata());
                            (host, summary, row.output.iter().cloned().collect())
                        })
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn interrupt_active(&self, label: impl Into<String>) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        self.finish_current(&mut output_frame);
        let label = label.into();
        output_frame.write(&format!(
            "{}\n",
            styled_outcome_line(self.style, "◇", Tone::Warning, &label)
        ));
        self.redraw_current(&mut output_frame);
    }

    pub fn message(&self, message: impl std::fmt::Display) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        self.clear_line(&mut output_frame);
        output_frame.write(&format!(
            "{}\n",
            self.style.semantic_text(&message.to_string())
        ));
        self.redraw_current(&mut output_frame);
    }

    pub fn message_field(&self, label: &str, value: impl std::fmt::Display) {
        self.message_field_with_metadata(label, value, Option::<&str>::None);
    }

    pub fn message_field_with_metadata(
        &self,
        label: &str,
        value: impl std::fmt::Display,
        metadata: Option<impl std::fmt::Display>,
    ) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        self.clear_line(&mut output_frame);
        output_frame.write(&format!("{}\n", self.field_line(label, value, metadata)));
        self.redraw_current(&mut output_frame);
    }

    fn field_line(
        &self,
        label: &str,
        value: impl std::fmt::Display,
        metadata: Option<impl std::fmt::Display>,
    ) -> String {
        let metadata = metadata
            .map(|metadata| self.style.paint(Tone::Muted, format!(" ({metadata})")))
            .unwrap_or_default();
        format!(
            "{}: {value}{metadata}",
            self.style.paint(Tone::Label, label)
        )
    }

    /// A single in-place metadata row on a TTY, a single announcement in logs.
    pub(crate) fn timed_field(&self, label: &'static str, value: &'static str) -> TimedField<'_> {
        let started = Instant::now();
        let mut field = TimedField {
            reporter: self,
            label,
            value,
            started,
            next_update: None,
        };
        if self.enabled() && self.interactive {
            field.next_update = Some(started);
            field.tick(started);
        } else {
            self.message_field(label, value);
        }
        field
    }

    fn set_timed_field(&self, line: Option<String>) {
        let _output = self.output.lock().ok();
        if let Ok(mut state) = self.state.lock() {
            state.timed_field = line;
        }
        let mut frame = ProgressFrame::new(&self.destination, self.interactive);
        self.redraw_current(&mut frame);
    }

    pub fn message_tone(&self, tone: Tone, message: impl std::fmt::Display) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        self.clear_line(&mut output_frame);
        output_frame.write(&format!(
            "{}\n",
            self.style.paint(tone, message.to_string())
        ));
        self.redraw_current(&mut output_frame);
    }

    /// Record one streamed verbose child-process line in the live tail, opening
    /// the section if it is still closed. On an interactive terminal the tail is
    /// rendered through the normal dashboard clear/redraw path, so hiding the
    /// stream wipes it cleanly instead of leaving appended output. Redirected
    /// output still appends the line.
    pub fn verbose_line(&self, tone: Tone, message: impl std::fmt::Display) {
        if !self.enabled() {
            return;
        }
        let message = message.to_string();
        // Hold the output lock across the mutation and redraw, like every other
        // writer. Without it a verbose redraw can interleave with a dashboard
        // row or heartbeat redraw, so each writes its own region below the
        // other while the painted region tracks only one; hiding then clears
        // one copy and leaves the rest on screen.
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        if !self.interactive {
            output_frame.write(&format!("{}\n", self.style.paint(tone, message)));
            return;
        }
        if let Ok(mut state) = self.state.lock() {
            state.open_verbose();
            let line = record_verbose_line(&mut state, tone, message, SystemTime::now());
            state.verbose_tail.push_back(line);
            while state.verbose_tail.len() > VERBOSE_MAX_LIVE_LINES {
                state.verbose_tail.pop_front();
            }
            if state.verbose_view == VerboseView::Run {
                hold_scrolled_window(&mut state, 1);
            }
        }
        self.redraw_stream(&mut output_frame);
    }

    /// Record a line seen while the verbose tail is hidden so revealing it
    /// later still surfaces the run's errors and warnings. No output is written
    /// and non-interactive runs are untouched, so redirected output stays
    /// unchanged.
    pub fn retain_verbose_line(&self, tone: Tone, message: impl std::fmt::Display) {
        if !self.retains_verbose_history() {
            return;
        }
        if let Ok(mut state) = self.state.lock() {
            record_verbose_line(&mut state, tone, message.to_string(), SystemTime::now());
        }
    }

    /// Whether this reporter keeps hidden verbose lines for a later reveal;
    /// true only on an interactive terminal where the toggle can hide them.
    pub fn retains_verbose_history(&self) -> bool {
        self.enabled() && self.interactive
    }

    /// Whether the verbose section is currently open, so a producer can decide
    /// between showing a line live and retaining it for the errors view.
    pub fn verbose_showing(&self) -> bool {
        self.state.lock().is_ok_and(|state| state.verbose_active)
    }

    /// Switch the open verbose section to `view`, enabling it if needed and
    /// returning the window to the newest content.
    pub fn set_verbose_view(&self, view: VerboseView) {
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        let changed = self.state.lock().ok().is_some_and(|mut state| {
            let changed =
                !state.verbose_active || state.verbose_view != view || state.verbose_scroll != 0;
            state.open_verbose();
            state.verbose_view = view;
            state.verbose_scroll = 0;
            state.stream_redraw_at = None;
            changed
        });
        if changed {
            self.redraw_current(&mut output_frame);
        }
    }

    /// Scroll the open verbose view by `delta` lines, positive toward older
    /// content.
    pub fn scroll_verbose_lines(&self, delta: isize) {
        self.scroll_verbose(delta, 1);
    }

    /// Scroll the open verbose view by `delta` half-viewport pages.
    pub fn scroll_verbose_pages(&self, delta: isize) {
        // An unreported size assumes the same terminal `live_region_lines`
        // budgets for, so a page scrolls the window by half of it.
        let page = self
            .layout_viewport()
            .map_or(DEFAULT_VIEWPORT_ROWS / 2, |(rows, _)| (rows / 2).max(1));
        self.scroll_verbose(delta, page);
    }

    fn scroll_verbose(&self, delta: isize, step: usize) {
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        let changed = self.state.lock().ok().is_some_and(|mut state| {
            if !state.verbose_active {
                return false;
            }
            let max = state.verbose_content_len().saturating_sub(1) as isize;
            let next = (state.verbose_scroll as isize + delta * step as isize).clamp(0, max);
            let changed = next != state.verbose_scroll as isize;
            state.verbose_scroll = next as usize;
            changed
        });
        if changed {
            self.redraw_current(&mut output_frame);
        }
    }

    /// Return the open verbose view to the newest content, so a scrolled reader
    /// can jump back with `esc` instead of scrolling line by line.
    pub fn scroll_verbose_newest(&self) {
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        let changed = self.state.lock().ok().is_some_and(|mut state| {
            let changed = state.verbose_active && state.verbose_scroll != 0;
            state.verbose_scroll = 0;
            state.stream_redraw_at = None;
            changed
        });
        if changed {
            self.redraw_current(&mut output_frame);
        }
    }

    /// Disable verbose streaming and drop the live tail so the next redraw
    /// shrinks the region back to just the dashboard, as if the stream had
    /// never been shown.
    pub fn clear_verbose_output(&self) {
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        let changed = self.state.lock().ok().is_some_and(|mut state| {
            let changed = state.verbose_active || !state.verbose_tail.is_empty();
            state.close_verbose();
            state.verbose_tail.clear();
            state.stream_redraw_at = None;
            changed
        });
        if changed {
            self.redraw_current(&mut output_frame);
        }
    }

    /// Set whether the verbose section is open without redrawing. Callers that
    /// know the initial intent (`--verbose`, `--build-logs`) use this before any
    /// region exists; the key reader uses the redrawing show/clear pair.
    /// Set whether the verbose section is open without redrawing. Callers that
    /// know the initial intent (`--verbose`, `--build-logs`) use this before any
    /// region exists; the key reader uses the redrawing toggle pair. Forgetting
    /// an earlier run's lines is `reset_verbose_history`'s separate job.
    pub fn set_verbose_open(&self, open: bool) {
        if let Ok(mut state) = self.state.lock() {
            if open {
                state.open_verbose();
            } else {
                state.close_verbose();
            }
            state.verbose_scroll = 0;
            state.stream_redraw_at = None;
        }
    }

    /// Forget every verbose line seen so far, returning the section to its
    /// default view. A command calls this before it opens the section, so a
    /// process running more than one command never inherits the previous run's
    /// live ring or errors view.
    pub fn reset_verbose_history(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.verbose_tail.clear();
            state.retained_verbose.clear();
            state.verbose_recent.clear();
            state.verbose_seq = 0;
            state.after_context_remaining = 0;
            state.verbose_scroll = 0;
            state.stream_redraw_at = None;
            state.verbose_view = VerboseView::default();
        }
    }

    /// Flip the verbose section, redrawing at once so the `Logs` header appears
    /// or disappears on the key press.
    pub fn toggle_verbose_output(&self) {
        if self.verbose_showing() {
            self.clear_verbose_output();
        } else {
            self.show_verbose_output();
        }
    }

    /// Reveal verbose streaming at once, redrawing so the `Logs` header appears
    /// on the key press instead of waiting for the first line to stream. The
    /// active view and retained digest persist across a hide.
    pub fn show_verbose_output(&self) {
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        let changed = self.state.lock().ok().is_some_and(|mut state| {
            if state.verbose_active {
                return false;
            }
            state.open_verbose();
            state.stream_redraw_at = None;
            state.verbose_scroll = 0;
            true
        });
        if changed {
            self.redraw_current(&mut output_frame);
        }
    }

    /// Re-render the live region after an out-of-band state change, such as an
    /// armed interrupt, so the footer reflects it immediately.
    pub fn refresh(&self) {
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        self.redraw_current(&mut output_frame);
    }

    /// Release the interactive live region so the cursor ends on a fresh line.
    ///
    /// An in-place frame ends at the last painted row with no trailing newline,
    /// so a carriage return plus newline moves below it; an append-only snapshot
    /// frame already ends with a newline. Both restore cursor visibility. The
    /// painted state is cleared, so a second call is a no-op. `blocking` is false on
    /// the panic path so a reporter lock the panicking thread still holds cannot
    /// deadlock the hook; an unavailable lock there is treated as a possibly
    /// stranded region, and the extra newline is harmless when none was drawn.
    fn release_live_region(&self, blocking: bool) -> bool {
        if !self.interactive {
            return false;
        }
        let _output = if blocking {
            self.output.lock().ok()
        } else {
            self.output.try_lock().ok()
        };
        let painted = if blocking {
            self.state.lock().ok().map(|mut state| state.take_painted())
        } else {
            self.state
                .try_lock()
                .ok()
                .map(|mut state| state.take_painted())
        };
        let terminate = match &painted {
            Some(Painted::InPlace(_)) => true,
            Some(Painted::None | Painted::Snapshot) => false,
            None => true,
        };
        if terminate {
            self.destination.write("\r\n");
        }
        if !matches!(painted, Some(Painted::None)) {
            self.destination.write(SHOW_CURSOR);
            if matches!(self.destination, ProgressDestination::Stderr) {
                crate::terminal_mode::publish_cursor_hidden(false);
            }
        }
        terminate
    }

    pub fn message_primary_with_metadata(
        &self,
        prefix: impl std::fmt::Display,
        tone: Tone,
        primary: impl std::fmt::Display,
        metadata: impl std::fmt::Display,
    ) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        self.clear_line(&mut output_frame);
        output_frame.write(&format!(
            "{}{}{}\n",
            prefix,
            self.style.paint(tone, primary.to_string()),
            paint_if_nonempty(self.style, Tone::Neutral, &metadata.to_string())
        ));
        self.redraw_current(&mut output_frame);
    }

    pub fn message_host_summary<'a>(
        &self,
        host: &str,
        status: impl IntoIterator<Item = (Tone, &'a str)>,
        timing: Option<&str>,
        muted_row: bool,
    ) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        self.clear_line(&mut output_frame);

        let mut rendered_status = String::new();
        for (index, (tone, text)) in status.into_iter().enumerate() {
            if index != 0 {
                rendered_status.push_str(", ");
            }
            rendered_status.push_str(
                &self
                    .style
                    .paint(if muted_row { Tone::Muted } else { tone }, text),
            );
        }
        let host = if muted_row {
            self.style.paint_host_muted(host)
        } else {
            self.style.paint_host(host)
        };
        let timing = timing
            .map(|timing| self.style.paint(Tone::Muted, format!("[{timing}]")))
            .unwrap_or_default();
        let separator = if rendered_status.is_empty() || timing.is_empty() {
            ""
        } else {
            " "
        };
        output_frame.write(&format!("  {host}  {rendered_status}{separator}{timing}\n"));
        self.redraw_current(&mut output_frame);
    }

    pub fn heading(&self, heading: impl std::fmt::Display) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        self.clear_line(&mut output_frame);
        output_frame.write(&format!(
            "{}\n",
            self.style.paint(Tone::Emphasis, heading.to_string())
        ));
        self.redraw_current(&mut output_frame);
    }

    pub fn heading_with_metadata(
        &self,
        heading: impl std::fmt::Display,
        metadata: impl IntoIterator<Item = String>,
    ) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let width = self
            .layout_viewport()
            .map(|(_, columns)| columns.max(1))
            .unwrap_or(usize::MAX);
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        self.clear_line(&mut output_frame);
        output_frame.write(&format!(
            "{}\n",
            self.style.paint(Tone::Emphasis, heading.to_string())
        ));
        let fields = metadata
            .into_iter()
            .map(|field| self.style.paint(Tone::Muted, field))
            .collect::<Vec<_>>();
        for line in wrap_metadata_fields(self.style, &fields, width, "  ") {
            output_frame.write(&format!("{line}\n"));
        }
        self.redraw_current(&mut output_frame);
    }

    pub fn document(&self, document: impl std::fmt::Display) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let mut output_frame = ProgressFrame::new(&self.destination, self.interactive);
        self.clear_line(&mut output_frame);
        output_frame.write(&format!(
            "{}\n",
            self.style.semantic_document(&document.to_string())
        ));
        self.redraw_current(&mut output_frame);
    }

    fn finish_current(&self, output_frame: &mut ProgressFrame<'_>) {
        self.clear_line(output_frame);
        if let Ok(mut state) = self.state.lock() {
            state.stack.pop();
        }
    }

    /// One frame's terminal size. Read the live size once per frame; `layout`
    /// falls back to the last known size when the read is unreadable.
    fn frame_size(&self) -> FrameSize {
        let live = self.destination.viewport();
        let layout = live.or_else(|| {
            self.state
                .lock()
                .ok()
                .and_then(|state| state.region_viewport)
        });
        FrameSize { live, layout }
    }

    /// The size to lay a frame out for, without the live/known distinction.
    fn layout_viewport(&self) -> Option<(usize, usize)> {
        self.frame_size().layout
    }

    /// Erase the live region before repainting. `frame` carries the size the
    /// next frame is laid out for, so layout and the reset decision agree on one
    /// size. When the size changed the terminal has reflowed, so the counted
    /// rows no longer locate the region: wipe the visible screen and home the
    /// cursor (scrollback survives). An unreadable size after a known one is
    /// treated the same way, because the reflow may have happened at a width we
    /// cannot see and wrapped rows would otherwise survive the counted clear.
    /// A size that is never readable has no known width to compare against and
    /// no reflow to detect, so this reset cannot engage for it.
    ///
    /// `appending` is true when the next frame is an append-only snapshot.
    /// A snapshot draws no counted rows, so any frame that replaces it (rather
    /// than appending another) must wipe it, not clear zero rows and leave it
    /// stranded.
    fn clear_region(
        &self,
        frame: FrameSize,
        appending: bool,
        output_frame: &mut ProgressFrame<'_>,
    ) {
        if !self.interactive {
            return;
        }
        let (rows, wipe) = self.state.lock().map_or((0, false), |mut state| {
            let resized = state.reflowed(frame.live);
            if frame.live.is_some() {
                state.region_viewport = frame.live;
            }
            let snapshot = state.painted == Painted::Snapshot;
            let rows = match &state.painted {
                Painted::InPlace(lines) => lines.len(),
                Painted::None | Painted::Snapshot => 0,
            };
            let wipe = resized || (!appending && snapshot);
            if resized {
                // A resize re-fits the log window, so return it to the newest
                // content instead of leaving it scrolled against the old height.
                state.verbose_scroll = 0;
            }
            if wipe || rows > 0 {
                state.painted = Painted::None;
                // Clearing a painted region lets the next snapshot paint at
                // once instead of waiting out the append-only throttle.
                state.scrolling_snapshot_at = None;
            }
            (rows, wipe)
        });
        if wipe {
            clear_screen(output_frame);
        } else {
            clear_rendered_lines(output_frame, rows);
        }
    }

    /// Clear the region for callers that write a permanent line before the next
    /// redraw. Uses the same frame size as a redraw so a resize is seen once.
    fn clear_line(&self, output_frame: &mut ProgressFrame<'_>) {
        self.clear_region(self.frame_size(), false, output_frame);
    }

    /// Coalesce high-volume data, not lifecycle transitions or operator input.
    /// The existing heartbeat flushes the newest tail if a burst goes quiet.
    fn redraw_stream(&self, output_frame: &mut ProgressFrame<'_>) {
        let due = self.state.lock().is_ok_and(|mut state| {
            let now = Instant::now();
            if state
                .stream_redraw_at
                .is_some_and(|last| now.duration_since(last) < STREAM_REDRAW_INTERVAL)
            {
                return false;
            }
            state.stream_redraw_at = Some(now);
            true
        });
        if due {
            self.redraw_current(output_frame);
        }
    }

    fn redraw_current(&self, output_frame: &mut ProgressFrame<'_>) {
        if !self.enabled()
            || !self.interactive
            || self.state.lock().is_ok_and(|state| state.suppress_live)
        {
            return;
        }
        let notice = self.cancel_notice();
        // Read the size once: layout, the footer width, and the resize reset all
        // describe the same frame, even if the size becomes unreadable partway
        // through.
        let frame = self.frame_size();
        let viewport = frame.layout;
        // A resize re-fits the log window before this frame is laid out, so the
        // wiping frame already shows the newest content instead of the window it
        // was scrolled against at the old height. `clear_region` resets it again
        // for the `clear_line` path, which is then idempotent.
        if let Ok(mut state) = self.state.lock()
            && state.reflowed(frame.live)
        {
            state.verbose_scroll = 0;
        }
        let dashboard = self.shows_recent_updates();
        let lines = self.state.lock().ok().and_then(|state| {
            let footer = self.key_footer(&state, viewport);
            live_region_lines(
                self.style,
                footer.as_deref(),
                notice.as_deref(),
                &state,
                viewport,
                dashboard,
            )
        });
        output_frame.keep_cursor_hidden = lines.is_some();
        let Some(lines) = lines else {
            // Nothing left to draw: erase the previous region so an empty frame
            // never strands stale output.
            self.clear_region(frame, false, output_frame);
            return;
        };
        let appending = viewport.is_some_and(|(rows, _)| lines.len() >= rows);
        let reset = self
            .state
            .lock()
            .is_ok_and(|state| state.reflowed(frame.live) || state.painted == Painted::Snapshot);
        if appending || reset {
            self.clear_region(frame, appending, output_frame);
        }
        if appending {
            // A resize dropped the throttle in `clear_region`, so a wiped screen
            // repaints here rather than waiting out the snapshot interval.
            let should_render = self
                .state
                .lock()
                .is_ok_and(|mut state| claim_scrolling_snapshot(&mut state, Instant::now()));
            if should_render {
                redraw_lines(output_frame, &lines);
                output_frame.write("\n");
                if let Ok(mut state) = self.state.lock() {
                    state.painted = Painted::Snapshot;
                }
            }
        } else if let Ok(mut state) = self.state.lock() {
            if let Painted::InPlace(previous) = &state.painted {
                rewrite_lines(output_frame, previous, &lines);
            } else {
                redraw_lines(output_frame, &lines);
            }
            if frame.live.is_some() {
                state.region_viewport = frame.live;
            }
            state.painted = Painted::InPlace(lines);
            state.scrolling_snapshot_at = None;
        }
    }

    /// Interactive key hints rendered as the final live-region row. `None` when
    /// the reporter is not on a terminal or no key reader owns stdin. The
    /// `ctrl-c` action escalates with the signal coordinator, so the footer
    /// always advertises the next press: `cancel`, `confirm cancel`, then
    /// `force exit`.
    fn key_footer(
        &self,
        state: &ProgressState,
        viewport: Option<(usize, usize)>,
    ) -> Option<String> {
        if !self.interactive || !crate::fleet::interactive::keys_available() {
            return None;
        }
        let cancel = self.cancel_action();
        // The `Logs` header names the active view, so the footer adds the view
        // keys only while the section is open. Each key also has an `alt` form,
        // because a terminal that consumes the control bytes would otherwise
        // take the shortcut with them.
        let width = viewport.map(|(_, columns)| columns.saturating_sub(1));
        let pressed = state
            .key_feedback
            .filter(|feedback| feedback_active(Some(feedback.at), Instant::now()))
            .map(|feedback| feedback.key);
        Some(footer_hints(
            self.style,
            state.verbose_active,
            state.concurrency_available(),
            cancel,
            width,
            pressed,
        ))
    }

    /// The next Ctrl-C action, read from the signal coordinator's escalation.
    fn cancel_action(&self) -> &'static str {
        let Some(runtime) = crate::fleet::signal::runtime() else {
            return next_cancel_action(false, false);
        };
        next_cancel_action(runtime.interruption().is_some(), runtime.pending())
    }

    /// The cancelling notice shown just above the footer once a confirmed
    /// interrupt is unwinding the run, so the wait reads as deliberate rather
    /// than a stall.
    fn cancel_notice(&self) -> Option<String> {
        if !self.interactive || !crate::fleet::interactive::keys_available() {
            return None;
        }
        let runtime = crate::fleet::signal::runtime()?;
        runtime.interruption()?;
        Some(
            self.style
                .paint(Tone::Warning, "Cancel interrupt received · cancelling"),
        )
    }

    fn start_heartbeat(&self, active_id: u64) {
        // Render through the same path as every other update so the heartbeat
        // can never clear or repaint a different region than the dashboard.
        let reporter = self.clone();
        let state = Arc::downgrade(&self.state);
        let output = Arc::downgrade(&self.output);
        thread::spawn(move || {
            loop {
                thread::sleep(Duration::from_secs(1));
                let (Some(state), Some(output)) = (state.upgrade(), output.upgrade()) else {
                    return;
                };
                let Ok(_output) = output.lock() else {
                    return;
                };
                let render = match state.lock() {
                    Ok(state) => {
                        if !state.stack.iter().any(|active| active.id == active_id) {
                            return;
                        }
                        state
                            .stack
                            .last()
                            .is_some_and(|active| active.id == active_id)
                    }
                    Err(_) => return,
                };
                if render {
                    let mut output_frame =
                        ProgressFrame::new(&reporter.destination, reporter.interactive);
                    reporter.redraw_current(&mut output_frame);
                }
            }
        });
    }
}

fn push_recent_update(
    updates: &mut VecDeque<RecentUpdate>,
    limit: usize,
    key: String,
    text: String,
    tone: Tone,
) {
    if limit == 0 {
        return;
    }
    let output = updates
        .iter()
        .position(|update| update.key == key)
        .and_then(|index| updates.remove(index))
        .map(|update| update.output)
        .unwrap_or_default();
    updates.push_back(RecentUpdate {
        key,
        text,
        tone,
        output,
    });
    trim_recent_updates(updates, limit);
}

fn claim_scrolling_snapshot(state: &mut ProgressState, now: Instant) -> bool {
    if state
        .scrolling_snapshot_at
        .is_some_and(|last| now.duration_since(last) < SCROLLING_SNAPSHOT_INTERVAL)
    {
        return false;
    }
    state.scrolling_snapshot_at = Some(now);
    true
}

fn trim_recent_updates(updates: &mut VecDeque<RecentUpdate>, limit: usize) {
    while dashboard_update_line_count(updates) > limit {
        updates.pop_front();
    }
}

fn dashboard_update_line_count(updates: &VecDeque<RecentUpdate>) -> usize {
    updates
        .iter()
        .map(|update| 1 + update.output.len().min(LIVE_OUTPUT_LINES_PER_TASK))
        .sum()
}

/// Join the footer's key hints, dropping whole groups of related hints until the
/// line fits the terminal. The interrupt group is last and never dropped: it
/// escalates as the cancel is armed, so a narrow terminal must not cut it
/// mid-word, and a group such as the view pair stays together rather than one of
/// the two vanishing.
struct KeyHint<'a> {
    keys: &'static [(FeedbackKey, &'static str)],
    action: &'a str,
}

impl KeyHint<'_> {
    fn width(&self) -> usize {
        self.keys
            .iter()
            .map(|(_, label)| label.chars().count())
            .sum::<usize>()
            + self.keys.len().saturating_sub(1)
            + 2
            + self.action.chars().count()
    }

    fn render(&self, style: TerminalStyle, pressed: Option<FeedbackKey>) -> String {
        let keys = self
            .keys
            .iter()
            .map(|(key, label)| {
                style.paint(
                    if pressed == Some(*key) {
                        Tone::InputFeedback
                    } else {
                        Tone::Muted
                    },
                    label,
                )
            })
            .collect::<Vec<_>>()
            .join(&style.paint(Tone::Muted, "/"));
        format!(
            "{keys}{}",
            style.paint(Tone::Muted, format!(": {}", self.action))
        )
    }
}

fn footer_hints(
    style: TerminalStyle,
    verbose: bool,
    concurrency: bool,
    cancel: &str,
    width: Option<usize>,
    pressed: Option<FeedbackKey>,
) -> String {
    let mut groups = vec![vec![KeyHint {
        keys: &[(FeedbackKey::Verbose, "v")],
        action: "verbose",
    }]];
    if verbose {
        groups.push(vec![
            KeyHint {
                keys: &[(FeedbackKey::Run, "ctrl/alt-r")],
                action: "run",
            },
            KeyHint {
                keys: &[(FeedbackKey::Errors, "ctrl/alt-e")],
                action: "errors",
            },
        ]);
    }
    if concurrency {
        groups.push(vec![KeyHint {
            keys: &[(FeedbackKey::Increase, "+"), (FeedbackKey::Decrease, "-")],
            action: "concurrency",
        }]);
    }
    groups.push(vec![KeyHint {
        keys: &[(FeedbackKey::Cancel, "ctrl-c")],
        action: cancel,
    }]);
    loop {
        let hints = groups.iter().flatten().collect::<Vec<_>>();
        let columns = 6
            + hints.iter().map(|hint| hint.width()).sum::<usize>()
            + hints.len().saturating_sub(1) * 3;
        if width.is_none_or(|width| columns <= width) || groups.len() <= 1 {
            return format!(
                "{}{}",
                style.paint(Tone::Muted, "keys: "),
                hints
                    .iter()
                    .map(|hint| hint.render(style, pressed))
                    .collect::<Vec<_>>()
                    .join(&style.paint(Tone::Muted, " · "))
            );
        }
        let removable = (0..groups.len() - 1)
            .rev()
            .find(|index| {
                !groups[*index]
                    .iter()
                    .any(|hint| hint.keys.iter().any(|(key, _)| Some(*key) == pressed))
            })
            .unwrap_or(groups.len() - 2);
        groups.remove(removable);
    }
}

/// The next Ctrl-C action advertised in the footer, mirroring the coordinator's
/// escalation: idle offers `cancel`, an armed first press offers
/// `confirm cancel`, and a confirmed interrupt offers the forced `force exit`.
fn next_cancel_action(interrupted: bool, pending: bool) -> &'static str {
    if interrupted {
        "force exit"
    } else if pending {
        "confirm cancel"
    } else {
        "cancel"
    }
}

/// Record one verbose line into the retained digest. Problems (errors and
/// warnings) are always kept, along with up to `VERBOSE_CONTEXT_LINES` lines on
/// each side, so revealing the tail after a hide shows what went wrong instead
/// of a blank stream. Ordinary lines only pass through `verbose_recent` as
/// context and are never retained on their own.
fn record_verbose_line(
    state: &mut ProgressState,
    tone: Tone,
    text: String,
    at: SystemTime,
) -> VerboseLine {
    let line = VerboseLine {
        seq: state.verbose_seq,
        at,
        tone,
        text,
    };
    state.verbose_seq = state.verbose_seq.saturating_add(1);
    if tone.keeps_verbose_history() {
        // `before` context, skipping anything already inside the open run so a
        // line shared by two overlapping windows is never duplicated. The
        // digest's own last line is the boundary, so the list stays the one
        // source of truth for what it already holds.
        let tail = state.retained_verbose.back().map(|line| line.seq);
        let before_context = state
            .verbose_recent
            .iter()
            .filter(|before| tail.is_none_or(|tail| before.seq > tail))
            .cloned()
            .collect::<Vec<_>>();
        for before in before_context {
            push_digest_line(state, before);
        }
        push_digest_line(state, line.clone());
        state.after_context_remaining = VERBOSE_CONTEXT_LINES;
    } else if state.after_context_remaining > 0 {
        state.after_context_remaining -= 1;
        push_digest_line(state, line.clone());
    }
    state.verbose_recent.push_back(line.clone());
    while state.verbose_recent.len() > VERBOSE_CONTEXT_LINES {
        state.verbose_recent.pop_front();
    }
    line
}

/// Append one line to the retained digest, bounding its size from the front.
fn push_digest_line(state: &mut ProgressState, line: VerboseLine) {
    // The digest's own last line decides the elision, exactly as rendering does.
    let previous = state.retained_verbose.back().map(|tail| tail.seq);
    let rows = 1 + usize::from(elides_from(previous, line.seq));
    state.retained_verbose.push_back(line);
    while state.retained_verbose.len() > VERBOSE_MAX_RETAINED_LINES {
        state.retained_verbose.pop_front();
    }
    if state.verbose_view == VerboseView::Errors {
        hold_scrolled_window(state, rows);
    }
}

/// Keep a scrolled window pinned to the rows the reader is looking at: a new
/// line is appended below the window, so without this the window would slide
/// under the reader on every line. Clamping in `verbose_window_bounds` stops the
/// hold once the window reaches the oldest content, and a ring that drops its
/// oldest line keeps the window in place on its own.
fn hold_scrolled_window(state: &mut ProgressState, appended_rows: usize) {
    if state.verbose_active && state.verbose_scroll > 0 {
        state.verbose_scroll = state.verbose_scroll.saturating_add(appended_rows);
    }
}

/// Whether an elision row separates a digest line from the one before it, because
/// the stream produced lines in between. The single owner of the elision rule,
/// so rendering, row counting, and the append hold all agree.
fn elides_from(previous: Option<u64>, seq: u64) -> bool {
    previous.is_some_and(|previous| seq != previous + 1)
}

/// The digest as rendered rows, lazily: an elision row is yielded before any
/// line that did not follow its predecessor in the stream. The single rendering
/// source, so counting, windowing, and the append hold can never disagree about
/// how many rows the digest occupies or where an elision falls.
fn digest_rendered(retained: &VecDeque<VerboseLine>) -> impl Iterator<Item = (Tone, &str)> {
    let mut previous: Option<u64> = None;
    retained.iter().flat_map(move |line| {
        let elision = elides_from(previous, line.seq).then_some((Tone::Muted, VERBOSE_ELISION));
        previous = Some(line.seq);
        elision
            .into_iter()
            .chain(std::iter::once((line.tone, line.text.as_str())))
    })
}

/// Rows the digest renders, counting the `...` elision rows without building
/// them.
fn digest_row_count(retained: &VecDeque<VerboseLine>) -> usize {
    digest_rendered(retained).count()
}

/// The digest rows in `[start, end)`, cloning only the rows the window shows.
fn digest_rows(retained: &VecDeque<VerboseLine>, start: usize, end: usize) -> Vec<(Tone, String)> {
    digest_rendered(retained)
        .skip(start)
        .take(end.saturating_sub(start))
        .map(|(tone, text)| (tone, text.to_owned()))
        .collect()
}

/// Wall-clock time `when` happened, as `HH:MM:SS` in the local zone, so a
/// `since` label reads like a timestamp the reader can line up with other logs
/// instead of an age they have to subtract.
fn format_clock_time(when: SystemTime) -> String {
    let Ok(since_epoch) = when.duration_since(SystemTime::UNIX_EPOCH) else {
        return UNKNOWN_CLOCK_TIME.to_owned();
    };
    let seconds = since_epoch.as_secs() as libc::time_t;
    // SAFETY: `local` is a valid writable `tm` that outlives the call, and
    // `localtime_r` is the reentrant form, so the reader thread cannot race a
    // redraw. It fills `local` from the process time zone or reports failure.
    let mut local = unsafe { std::mem::zeroed::<libc::tm>() };
    if unsafe { libc::localtime_r(&seconds, &mut local) }.is_null() {
        return UNKNOWN_CLOCK_TIME.to_owned();
    }
    format!(
        "{:02}:{:02}:{:02}",
        local.tm_hour, local.tm_min, local.tm_sec
    )
}

/// The `Logs` section title: the active view so the filter is obvious, and when
/// its content began, because hiding and revealing restarts the live ring while
/// the retained digest keeps counting.
fn verbose_header(style: TerminalStyle, view: VerboseView, since: Option<SystemTime>) -> String {
    let view = match view {
        VerboseView::Run => "run",
        VerboseView::Errors => "errors",
    };
    let mut header = format!(
        "{} {}",
        style.paint(Tone::Emphasis, "● Logs"),
        style.paint(Tone::Muted, format!("· {view}"))
    );
    if let Some(since) = since {
        header.push_str(&format!(
            " {}",
            style.paint(Tone::Muted, format!("· since {}", format_clock_time(since)))
        ));
    }
    header
}

/// The visible slice of the active verbose view plus how many lines are hidden
/// above and below it, so the region can scroll and point at the rest.
fn verbose_window(state: &ProgressState, budget: usize) -> (Vec<(Tone, String)>, usize, usize) {
    match state.verbose_view {
        VerboseView::Run => {
            let len = state.verbose_tail.len();
            let (start, end) = verbose_window_bounds(len, budget, state.verbose_scroll);
            (
                state
                    .verbose_tail
                    .range(start..end)
                    .map(|line| (line.tone, line.text.clone()))
                    .collect(),
                start,
                len - end,
            )
        }
        VerboseView::Errors => {
            let len = digest_row_count(&state.retained_verbose);
            let (start, end) = verbose_window_bounds(len, budget, state.verbose_scroll);
            (
                digest_rows(&state.retained_verbose, start, end),
                start,
                len - end,
            )
        }
    }
}

/// The `[start, end)` slice of a `len`-line view scrolled `scroll` lines up from
/// the newest content, showing at most `budget` lines.
fn verbose_window_bounds(len: usize, budget: usize, scroll: usize) -> (usize, usize) {
    let offset = scroll.min(len.saturating_sub(budget));
    let end = len - offset;
    (end.saturating_sub(budget), end)
}

/// Muted elision row placed between the logs and the dashboard when the active
/// view has more content than the window shows, naming the scroll keys instead
/// of crowding the footer. `esc`/`ctrl-g`/`alt-g` returns to the newest content.
fn verbose_overflow_line(style: TerminalStyle, above: usize, below: usize) -> Option<String> {
    let mut parts = Vec::new();
    if above > 0 {
        parts.push(format!("▲ {above} above"));
    }
    if below > 0 {
        parts.push(format!("▼ {below} below"));
    }
    if parts.is_empty() {
        return None;
    }
    parts.push("ctrl/alt-h/j/k/l: scroll".to_owned());
    parts.push("esc/ctrl/alt-g: newest".to_owned());
    Some(style.paint(Tone::Muted, parts.join(" · ")))
}

/// Build the live, overwriteable region for the current span: the verbose
/// section (when open), a blank separator or overflow marker, the dashboard, and
/// the key footer. The result always fits inside the viewport so the region is
/// cleared in place instead of scrolling, which is what lets hiding the verbose
/// stream wipe it cleanly. Returns `None` when there is nothing to draw — no
/// active span and no open verbose section. An open section still renders without
/// a span, so a wait that owns no dashboard can show its logs.
fn live_region_lines(
    style: TerminalStyle,
    footer: Option<&str>,
    notice: Option<&str>,
    state: &ProgressState,
    viewport: Option<(usize, usize)>,
    dashboard: bool,
) -> Option<Vec<String>> {
    let active = state.stack.last();
    let mut context = workflow_lines(style, &state.workflow);
    context.extend(state.timed_field.iter().cloned());
    // A blank separator row, an optional cancelling notice, and the footer row.
    let footer_rows = if footer.is_some() {
        2 + usize::from(notice.is_some())
    } else {
        0
    };
    // The `Logs` header is the verbose indicator, so the block shows whenever
    // verbose is active, even before any line is retained or streamed.
    let verbose = state.verbose_active;
    let header_rows = 1;
    // Terminal columns, used to keep every region line on exactly one row:
    // the clear counts rows, so a wrapped line would leave the extra rows
    // uncleared when the tail is hidden.
    let columns = viewport.map(|(_, columns)| columns);
    // Leave the final viewport row unused so a full region never scrolls.
    let room = viewport
        .map(|(rows, _)| rows.saturating_sub(1))
        .unwrap_or(DEFAULT_VIEWPORT_ROWS.saturating_sub(1))
        .saturating_sub(context.len());

    let mut lines = if verbose {
        // Reserve roughly half the room for the dashboard and stream the rest
        // as logs, keeping space for the blank separator and the footer.
        let stream_room = room.saturating_sub(footer_rows + 1 + header_rows);
        let dashboard_budget = (stream_room / 2).max(1);
        let dashboard_lines = match active {
            Some(active) if dashboard => dashboard_lines_with_viewport_mode(
                style,
                active,
                active.started.elapsed(),
                viewport.map(|(_, columns)| (dashboard_budget + 1, columns)),
                RosterPolicy::Windowed,
            ),
            Some(active) => vec![active_line(style, &active.label, active.detail.as_deref())],
            // A long wait may own no dashboard; the logs still render.
            None => Vec::new(),
        };
        // The windowed dashboard already fits its budget; this is a last-resort
        // guard so the log tail always keeps a row.
        let dashboard_limit = stream_room.saturating_sub(1).max(1);
        let dashboard_lines = if dashboard_lines.len() > dashboard_limit {
            dashboard_lines[..dashboard_limit].to_vec()
        } else {
            dashboard_lines
        };
        let tail_budget = stream_room.saturating_sub(dashboard_lines.len());
        let (window, above, below) = verbose_window(state, tail_budget);
        let mut streamed: Vec<String> = vec![verbose_header(
            style,
            state.verbose_view,
            state.verbose_started(),
        )];
        streamed.extend(window.into_iter().map(|(tone, text)| {
            let text = match columns {
                Some(columns) => truncate_text(&text, columns),
                None => text,
            };
            style.paint(tone, text)
        }));
        let overflow = verbose_overflow_line(style, above, below);
        if dashboard_lines.is_empty() {
            if let Some(overflow) = overflow {
                streamed.push(overflow);
            }
        } else {
            streamed.push(overflow.unwrap_or_default());
            streamed.extend(dashboard_lines);
        }
        streamed
    } else if let Some(active) = active {
        if dashboard {
            dashboard_lines_with_viewport_mode(
                style,
                active,
                active.started.elapsed(),
                viewport.map(|(rows, columns)| {
                    (rows.saturating_sub(footer_rows + context.len()), columns)
                }),
                RosterPolicy::Full,
            )
        } else {
            let detail = heartbeat_detail(active.detail.as_deref(), active.started.elapsed());
            vec![active_line(style, &active.label, Some(&detail))]
        }
    } else if !context.is_empty() {
        Vec::new()
    } else {
        // Nothing to draw: no span, workflow or open verbose section.
        return None;
    };

    if !context.is_empty() {
        lines.splice(0..0, context);
    }
    if let Some(footer) = footer {
        // Keep one blank row between the dashboard and the footer so the keys
        // read as chrome rather than another host row, then show the cancelling
        // notice immediately above the keys.
        lines.push(String::new());
        if let Some(notice) = notice {
            lines.push(notice.to_owned());
        }
        lines.push(footer.to_owned());
    }
    // Keep every line on one terminal row (a wrapped line would occupy rows
    // the counted clear does not include), but let the region take only the
    // space it needs from the current cursor and scroll the terminal naturally
    // as it grows; do not reserve a fixed block at the bottom of the screen.
    if let Some((_, columns)) = viewport {
        let width = columns.saturating_sub(1).max(1);
        for line in &mut lines {
            *line = truncate_ansi(line, width);
        }
    }
    Some(lines)
}

fn workflow_lines(style: TerminalStyle, workflow: &WorkflowContext) -> Vec<String> {
    if workflow.started.is_none() {
        return Vec::new();
    }
    workflow
        .phases
        .iter()
        .map(|phase| {
            let compact = phase.compact();
            let label = compact
                .strip_prefix(phase.marker)
                .unwrap_or(&compact)
                .trim_start();
            styled_outcome_line(style, phase.marker, phase.tone, label)
        })
        .collect()
}

#[cfg(test)]
fn dashboard_lines(
    style: TerminalStyle,
    active: &ActiveProgress,
    elapsed: Duration,
) -> Vec<String> {
    dashboard_lines_with_viewport(style, active, elapsed, None)
}

#[cfg(test)]
fn dashboard_lines_with_viewport(
    style: TerminalStyle,
    active: &ActiveProgress,
    elapsed: Duration,
    viewport: Option<(usize, usize)>,
) -> Vec<String> {
    dashboard_lines_with_viewport_mode(style, active, elapsed, viewport, RosterPolicy::Full)
}

/// `roster` windows an oversized host roster to its last rows (with a marker for
/// the hidden ones) instead of letting it overflow the budget; the verbose
/// dashboard asks for that so a full roster reads from the bottom, and the plain
/// dashboard passes [`RosterPolicy::Full`] so the append-only snapshot path can
/// still scroll a roster taller than the screen.
fn dashboard_lines_with_viewport_mode(
    style: TerminalStyle,
    active: &ActiveProgress,
    elapsed: Duration,
    viewport: Option<(usize, usize)>,
    roster: RosterPolicy,
) -> Vec<String> {
    if let Some(dashboard) = &active.host_dashboard {
        return host_dashboard_lines(style, active, dashboard, elapsed, viewport, roster);
    }
    let mut lines = vec![format!(
        "{} {}",
        style.paint(Tone::Emphasis, format!("● {}", active.label)),
        style.paint(
            Tone::Muted,
            format!("· elapsed {}", format_duration(elapsed))
        )
    )];
    for update in &active.recent_updates {
        lines.push(format!("  {}", style.paint(update.tone, &update.text)));
        let start = update
            .output
            .len()
            .saturating_sub(LIVE_OUTPUT_LINES_PER_TASK);
        lines.extend(
            update
                .output
                .iter()
                .skip(start)
                .map(|line| format!("    {}", style.paint(Tone::Muted, line))),
        );
    }
    lines
}

fn host_dashboard_lines(
    style: TerminalStyle,
    active: &ActiveProgress,
    dashboard: &HostDashboard,
    elapsed: Duration,
    viewport: Option<(usize, usize)>,
    roster: RosterPolicy,
) -> Vec<String> {
    // The quiet-heartbeat pulse alternates once per second; the dashboard
    // redraws on the same cadence, so only silent rows visibly blink.
    let blink_on = elapsed.as_secs().is_multiple_of(2);
    let mut metadata = Vec::new();
    if let Some(stage) = &dashboard.stage
        && !dashboard
            .title
            .as_deref()
            .unwrap_or(&active.label)
            .to_ascii_lowercase()
            .starts_with(&stage.to_ascii_lowercase())
    {
        metadata.push(style.paint(Tone::Muted, format!("stage {stage}")));
    }
    if let Some((current, total)) = dashboard.wave
        && total > 1
    {
        metadata.push(style.paint(Tone::Muted, format!("wave {current}/{total}")));
    }
    if let Some(admission) = &dashboard.admission {
        let now = Instant::now();
        let number = |value: usize, at: Option<Instant>| {
            style.paint(
                if feedback_active(at, now) {
                    Tone::InputFeedback
                } else {
                    Tone::Muted
                },
                value.to_string(),
            )
        };
        metadata.push(format!(
            "{}{}{}",
            number(admission.running, admission.running_changed_at),
            style.paint(Tone::Muted, " running · limit "),
            number(admission.target, admission.target_changed_at)
        ));
        if let Some(constraint) = &admission.constraint {
            metadata.push(style.paint(Tone::Muted, constraint));
        }
    } else if dashboard.concurrency > 0 {
        metadata.push(style.paint(Tone::Muted, format!("slots —/{}", dashboard.concurrency)));
    }
    metadata.extend(
        dashboard
            .kind
            .counts(dashboard.rows.values().map(|row| row.outcome))
            .into_iter()
            .map(|field| style.paint(Tone::Muted, field)),
    );
    metadata.push(style.paint(Tone::Muted, format!("elapsed {}", format_duration(elapsed))));
    let max_lines = viewport
        .map(|(rows, _)| rows.saturating_sub(1).max(1))
        .unwrap_or(usize::MAX);
    let max_columns = viewport.map(|(_, columns)| columns.max(1));
    let heading = format!("● {}", dashboard.title.as_deref().unwrap_or(&active.label));
    let heading = truncate_text(&heading, max_columns.unwrap_or(usize::MAX));
    let mut lines = vec![style.paint(Tone::Emphasis, heading)];
    lines.extend(
        wrap_metadata_fields(style, &metadata, max_columns.unwrap_or(usize::MAX), "  ")
            .into_iter()
            .take(max_lines.saturating_sub(1)),
    );
    let header_rows = lines.len();

    // Window an oversized roster to its last rows so the bottom of the roster
    // stays visible, naming how many rows were dropped above. The marker is
    // only emitted when there is a row budgeted for it, so the result never
    // exceeds `max_lines`.
    let roster_overflow =
        roster == RosterPolicy::Windowed && header_rows + dashboard.order.len() > max_lines;
    let marker_rows = usize::from(roster_overflow && max_lines > header_rows);
    let shown_hosts = if roster_overflow {
        max_lines.saturating_sub(header_rows + marker_rows)
    } else {
        dashboard.order.len()
    };
    let host_start = dashboard.order.len().saturating_sub(shown_hosts);
    let shown_order = &dashboard.order[host_start..];
    if marker_rows > 0 {
        lines.push(format!(
            "  {}",
            style.paint(
                Tone::Muted,
                format!("▲ {host_start} {} above", dashboard.kind.noun())
            )
        ));
    }

    let base_lines = header_rows + marker_rows + shown_order.len();
    let available_detail_lines = max_lines.saturating_sub(base_lines);
    let detailed_hosts = shown_order
        .iter()
        .filter(|host| {
            dashboard.rows.get(*host).is_some_and(|row| {
                matches!(
                    row.state,
                    HostRowState::Running
                        | HostRowState::Failed
                        | HostRowState::Interrupted
                        | HostRowState::Unconfirmed
                ) && !row.output.is_empty()
            })
        })
        .count();
    let generic_budget = if viewport.is_some() {
        available_detail_lines.saturating_sub(detailed_hosts).min(2)
    } else {
        usize::MAX
    };
    let mut generic_rendered = 0;
    for update in &active.recent_updates {
        if generic_rendered >= generic_budget {
            break;
        }
        let text = truncate_text(
            &update.text,
            max_columns
                .map(|columns| columns.saturating_sub(2))
                .unwrap_or(usize::MAX),
        );
        lines.push(format!("  {}", style.paint(update.tone, text)));
        generic_rendered += 1;
        let start = update
            .output
            .len()
            .saturating_sub(LIVE_OUTPUT_LINES_PER_TASK);
        for line in update.output.iter().skip(start) {
            if generic_rendered >= generic_budget {
                break;
            }
            let line = truncate_text(
                line,
                max_columns
                    .map(|columns| columns.saturating_sub(4))
                    .unwrap_or(usize::MAX),
            );
            lines.push(format!("    {}", style.paint(Tone::Muted, line)));
            generic_rendered += 1;
        }
    }
    let host_detail_budget = available_detail_lines.saturating_sub(generic_rendered);
    let base_host_detail_limit = host_detail_budget
        .checked_div(detailed_hosts)
        .map_or(0, |limit| limit.min(LIVE_OUTPUT_LINES_PER_TASK));
    let extra_host_details = if base_host_detail_limit < LIVE_OUTPUT_LINES_PER_TASK {
        host_detail_budget.saturating_sub(base_host_detail_limit * detailed_hosts)
    } else {
        0
    };
    let mut detailed_host_index = 0;
    for host in shown_order {
        let Some(row) = dashboard.rows.get(host) else {
            continue;
        };
        let (tone, status, metadata) = match row.state {
            HostRowState::Unconfirmed => (
                Tone::Warning,
                format!(
                    "? {}",
                    row.summary
                        .as_deref()
                        .unwrap_or("remote execution unconfirmed")
                ),
                row.duration_metadata(),
            ),
            HostRowState::Pending => (Tone::Muted, "○ pending".to_owned(), row.duration_metadata()),
            HostRowState::Completed | HostRowState::Finalizing => (
                Tone::Muted,
                format!("○ {}", row.task.as_deref().unwrap_or("done")),
                row.duration_metadata(),
            ),
            HostRowState::Running => {
                let elapsed = row
                    .task_started
                    .map(|started| started.elapsed())
                    .unwrap_or_default();
                let total = row.duration().unwrap_or(elapsed);
                let mut metadata = format!(" · {}", format_duration(total));
                // Subsecond differences are rounding noise, not useful context.
                if total.saturating_sub(elapsed) >= Duration::from_secs(1) {
                    metadata.push_str(&format!(" · step {}", format_duration(elapsed)));
                }
                let (tone, glyph) = match heartbeat_state(row) {
                    Heartbeat::Live if row.is_quiet() => {
                        (Tone::Active, if blink_on { "●" } else { "○" })
                    }
                    Heartbeat::Stalled => {
                        let age = row
                            .last_heartbeat
                            .or(row.task_started)
                            .map(|reference| reference.elapsed())
                            .unwrap_or_default();
                        metadata.push_str(&format!(" · no heartbeat · {}", format_duration(age)));
                        (Tone::Warning, "●")
                    }
                    Heartbeat::Live | Heartbeat::Absent => (Tone::Active, "●"),
                };
                (
                    tone,
                    format!("{glyph} {}", row.task.as_deref().unwrap_or("running")),
                    metadata,
                )
            }
            HostRowState::Succeeded => (
                Tone::Success,
                format!("✓ {}", row.summary.as_deref().unwrap_or("complete")),
                row.duration_metadata(),
            ),
            HostRowState::Skipped => (
                Tone::Muted,
                format!("◇ {}", row.summary.as_deref().unwrap_or("skipped")),
                row.duration_metadata(),
            ),
            HostRowState::Warning => (
                Tone::Warning,
                format!("◇ {}", row.summary.as_deref().unwrap_or("warning")),
                row.duration_metadata(),
            ),
            HostRowState::Failed => (
                Tone::Failure,
                format!("✗ {}", row.summary.as_deref().unwrap_or("failed")),
                row.duration_metadata(),
            ),
            HostRowState::Interrupted => (
                Tone::Warning,
                format!("⊘ {}", row.summary.as_deref().unwrap_or("interrupted")),
                row.duration_metadata(),
            ),
        };
        let host_width = max_columns
            .map(|columns| {
                columns
                    .saturating_sub(4 + metadata.chars().count() + 3)
                    .min(host.chars().count())
            })
            .unwrap_or_else(|| host.chars().count());
        let host = truncate_text(host, host_width);
        let available_status_width = max_columns
            .map(|columns| columns.saturating_sub(host.chars().count() + 4))
            .unwrap_or(usize::MAX);
        // Reserve timing before shortening a verbose stage/failure label.
        let metadata = truncate_text(&metadata, available_status_width.saturating_sub(2));
        let status = truncate_text(
            &status,
            available_status_width.saturating_sub(metadata.chars().count()),
        );
        let skipped = row.state == HostRowState::Skipped;
        let host = if skipped {
            style.paint_host_muted(&host)
        } else {
            style.paint_host(&host)
        };
        lines.push(format!(
            "  {}  {}{}",
            host,
            style.paint(tone, status),
            paint_if_nonempty(
                style,
                if skipped { Tone::Muted } else { Tone::Neutral },
                &metadata
            )
        ));
        if matches!(
            row.state,
            HostRowState::Running
                | HostRowState::Failed
                | HostRowState::Interrupted
                | HostRowState::Unconfirmed
        ) && !row.output.is_empty()
        {
            let limit = (base_host_detail_limit
                + usize::from(detailed_host_index < extra_host_details))
            .min(LIVE_OUTPUT_LINES_PER_TASK);
            detailed_host_index += 1;
            let start = row.output.len().saturating_sub(limit);
            lines.extend(row.output.iter().skip(start).map(|line| {
                let line = truncate_text(
                    line,
                    max_columns
                        .map(|columns| columns.saturating_sub(6))
                        .unwrap_or(usize::MAX),
                );
                format!("    │ {}", style.paint(Tone::Muted, line))
            }));
        }
    }
    lines
}

fn truncate_text(value: &str, max_columns: usize) -> String {
    if value.chars().count() <= max_columns {
        return value.to_owned();
    }
    if max_columns == 0 {
        return String::new();
    }
    if max_columns == 1 {
        return "…".to_owned();
    }
    let mut truncated = value.chars().take(max_columns - 1).collect::<String>();
    truncated.push('…');
    truncated
}

fn wrap_metadata_fields(
    style: TerminalStyle,
    fields: &[String],
    max_columns: usize,
    indent: &str,
) -> Vec<String> {
    if fields.is_empty() {
        return Vec::new();
    }
    let indent_width = indent.chars().count();
    let content_width = max_columns.saturating_sub(indent_width).max(1);
    let separator = style.paint(Tone::Muted, " · ");
    let separator_width: usize = 3;
    let mut lines = Vec::new();
    let mut current = String::new();
    let mut current_width = 0usize;

    for field in fields {
        let field_width = ansi_visible_width(field);
        let extra = if current.is_empty() {
            field_width
        } else {
            separator_width.saturating_add(field_width)
        };
        if !current.is_empty() && current_width.saturating_add(extra) > content_width {
            lines.push(format!(
                "{indent}{}",
                truncate_ansi(&current, content_width)
            ));
            current.clear();
            current_width = 0;
        }
        if !current.is_empty() {
            current.push_str(&separator);
            current_width = current_width.saturating_add(separator_width);
        }
        current.push_str(field);
        current_width = current_width.saturating_add(field_width);
    }
    if !current.is_empty() {
        lines.push(format!(
            "{indent}{}",
            truncate_ansi(&current, content_width)
        ));
    }
    lines
}

fn ansi_visible_width(value: &str) -> usize {
    let mut visible = 0usize;
    let mut characters = value.chars().peekable();
    while let Some(character) = characters.next() {
        if character == '\x1b' {
            if characters.peek() == Some(&'[') {
                characters.next();
                for control in characters.by_ref() {
                    if ('@'..='~').contains(&control) {
                        break;
                    }
                }
            }
            continue;
        }
        visible += 1;
    }
    visible
}

/// Truncate a possibly styled line to `max_columns` visible columns, copying
/// CSI escape sequences without counting them so color is preserved and never
/// cut mid-sequence. A reset is appended when an open style was truncated.
fn truncate_ansi(value: &str, max_columns: usize) -> String {
    let mut out = String::with_capacity(value.len());
    let mut visible = 0usize;
    let mut truncated = false;
    let mut characters = value.chars().peekable();
    while let Some(character) = characters.next() {
        if character == '\x1b' {
            out.push(character);
            if characters.peek() == Some(&'[') {
                characters.next();
                out.push('[');
                for control in characters.by_ref() {
                    out.push(control);
                    if ('@'..='~').contains(&control) {
                        break;
                    }
                }
            }
            continue;
        }
        if visible >= max_columns {
            truncated = true;
            break;
        }
        out.push(character);
        visible += 1;
    }
    if truncated && out.contains('\x1b') {
        out.push_str("\x1b[0m");
    }
    out
}

fn terminal_viewport() -> Option<(usize, usize)> {
    let mut size = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: `size` is a valid writable winsize and STDERR_FILENO remains
    // open for the duration of this synchronous ioctl call.
    let result = unsafe { libc::ioctl(libc::STDERR_FILENO, libc::TIOCGWINSZ, &mut size) };
    if result == 0 && size.ws_row > 0 && size.ws_col > 0 {
        Some((usize::from(size.ws_row), usize::from(size.ws_col)))
    } else {
        None
    }
}

fn clear_rendered_lines(output_frame: &mut ProgressFrame<'_>, lines: usize) {
    if lines == 0 {
        return;
    }
    output_frame.write("\r\x1b[2K");
    for _ in 1..lines {
        output_frame.write("\x1b[1A\r\x1b[2K");
    }
}

/// Wipe the visible screen and home the cursor, leaving scrollback intact. Used
/// when the terminal was resized: the reflow means the previous row count no
/// longer locates the live region, so the only reliable reset is to clear the
/// screen and redraw the region from the top-left.
fn clear_screen(output_frame: &mut ProgressFrame<'_>) {
    output_frame.write("\x1b[2J\x1b[H");
}

/// Terminal rows one streamed line occupies, so a later hide can erase it.
fn redraw_lines(output_frame: &mut ProgressFrame<'_>, lines: &[String]) {
    for (index, line) in lines.iter().enumerate() {
        if index > 0 {
            output_frame.write("\n");
        }
        output_frame.write(line);
    }
}

/// Rewrite in place without exposing an empty region. Unchanged rows emit no
/// text; shortened rows erase only the old suffix, after their replacement.
fn rewrite_lines(output_frame: &mut ProgressFrame<'_>, previous: &[String], lines: &[String]) {
    let mut cursor = previous.len().saturating_sub(1);
    // Reserve only added rows. Newlines let a growing inline region scroll
    // naturally at the bottom; cursor-down alone cannot create that space.
    for _ in previous.len()..lines.len() {
        output_frame.write("\n");
        cursor += 1;
    }
    let move_to = |output_frame: &mut ProgressFrame<'_>, cursor: &mut usize, row: usize| {
        if row != *cursor {
            let direction = if row < *cursor { 'A' } else { 'B' };
            output_frame.write(&format!("\x1b[{}{direction}", row.abs_diff(*cursor)));
            *cursor = row;
        }
    };
    for row in 0..previous.len().max(lines.len()) {
        if previous.get(row) == lines.get(row) {
            continue;
        }
        move_to(output_frame, &mut cursor, row);
        output_frame.write("\r");
        if let Some(line) = lines.get(row) {
            output_frame.write(line);
        }
        output_frame.write("\x1b[K");
    }
    move_to(output_frame, &mut cursor, lines.len().saturating_sub(1));
}

/// Detail with the live elapsed appended, so a quiet step still visibly ticks
/// between heartbeats.
fn heartbeat_detail(detail: Option<&str>, elapsed: Duration) -> String {
    let elapsed = format_duration(elapsed);
    detail
        .map(|detail| format!("{detail} · {elapsed} elapsed"))
        .unwrap_or(elapsed)
}

pub fn command_reporter() -> &'static ProgressReporter {
    COMMAND_REPORTER.get_or_init(|| ProgressReporter::new(true))
}

/// Tear down the interactive terminal on process exit: release the live region
/// and restore the terminal mode captured by [`crate::terminal_mode`]. Safe and
/// idempotent on every exit path, and a no-op when nothing ever entered raw
/// mode or painted a region.
pub fn finish_terminal() {
    finish_terminal_impl(true);
}

/// Best-effort teardown for a panic hook. Behaves like [`finish_terminal`] but
/// never blocks on a reporter lock the panicking thread may still hold.
pub fn finish_terminal_after_panic() {
    finish_terminal_impl(false);
}

fn finish_terminal_impl(blocking: bool) {
    if let Some(reporter) = COMMAND_REPORTER.get() {
        reporter.release_live_region(blocking);
    }
    crate::terminal_mode::restore_published();
}

/// Restores the terminal and releases the live region when dropped. Install one
/// in `main` so a normal return from `run` hands the terminal back.
#[must_use = "the terminal is restored only while the guard is alive"]
pub struct TerminalExitGuard;

impl Drop for TerminalExitGuard {
    fn drop(&mut self) {
        finish_terminal();
    }
}

/// Install a panic hook that tears the terminal down before the default hook
/// prints, so a panic is not glued into the dashboard and the terminal is not
/// left in raw mode, then return a guard for the normal-return path. Call once
/// at the top of `main`.
#[must_use = "the terminal is restored only while the guard is alive"]
pub fn guard_terminal_exit() -> TerminalExitGuard {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        finish_terminal_after_panic();
        previous(info);
    }));
    TerminalExitGuard
}

pub fn command_step_started(description: &str) {
    command_reporter().started(sentence_case(description));
}

pub fn command_step_completed(description: &str) {
    command_reporter().complete_active(sentence_case(description));
}

pub fn command_step_failed(description: &str, failure: &str) {
    command_reporter().fail_active(sentence_case(description), failure);
}

fn action_title(action: Action) -> &'static str {
    match action {
        Action::Plan => "Plan",
        Action::Setup => "Set up",
        Action::Seed => "Warm seed",
        Action::Prepare => "Prepare",
        Action::Verify => "Verify",
        Action::Cutover => "Run",
        Action::Rollback => "Roll back",
        Action::Close => "Close",
    }
}

fn step_label(step: &StepProgress) -> String {
    let description = sentence_case(&step.description);
    if step.item == "item-001" || step.transaction.ends_with("--item-001") {
        description
    } else {
        format!("{description} · {}", step.item)
    }
}

fn sentence_case(value: &str) -> String {
    let mut characters = value.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

fn redraw_active(
    output_frame: &mut ProgressFrame<'_>,
    style: TerminalStyle,
    label: &str,
    detail: Option<&str>,
) {
    output_frame.write("\r\x1b[2K");
    output_frame.write(&active_line(style, label, detail));
}

fn active_line(style: TerminalStyle, label: &str, detail: Option<&str>) -> String {
    let mut line = style.paint(Tone::Active, format!("● {label}"));
    if let Some(detail) = detail {
        line.push_str("  ");
        line.push_str(&style.paint(Tone::Muted, detail));
    }
    line
}

fn styled_outcome_line(style: TerminalStyle, marker: &str, tone: Tone, label: &str) -> String {
    let (primary, metadata) = label
        .split_once(" · ")
        .map_or((label, ""), |(primary, metadata)| (primary, metadata));
    let primary = style.paint(tone, format!("{marker} {primary}"));
    if metadata.is_empty() {
        primary
    } else {
        format!(
            "{primary}{}",
            style.paint(Tone::Neutral, format!(" · {metadata}"))
        )
    }
}

fn paint_if_nonempty(style: TerminalStyle, tone: Tone, value: &str) -> String {
    if value.is_empty() {
        String::new()
    } else {
        style.paint(tone, value)
    }
}

pub fn format_duration(duration: Duration) -> String {
    let milliseconds = duration.as_millis();
    if milliseconds < 1_000 {
        format!("{milliseconds}ms")
    } else if duration.as_secs() < 60 {
        format!("{:.1}s", duration.as_secs_f64())
    } else {
        format!(
            "{}m {:02}s",
            duration.as_secs() / 60,
            duration.as_secs() % 60
        )
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn poisoned_presentation_lock_does_not_panic_or_install_keyboard_authority() {
        let reporter = super::ProgressReporter::new(false);
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _state = reporter.state.lock().unwrap();
            panic!("fixture: presentation failed");
        }));
        let guard = reporter.concurrency_handler(|_| panic!("poisoned handler was invoked"));
        assert!(!reporter.concurrency_available());
        reporter.adjust_concurrency(super::ConcurrencyChange::Increase);
        drop(guard);
    }

    #[test]
    fn invocation_handler_serves_new_pools_but_only_active_work_advertises_controls() {
        use crate::fleet::admission::{self, Adjustment, AdmissionControl, AdmissionLimits};
        let reporter = interactive_reporter();
        let control = AdmissionControl::new(
            AdmissionLimits {
                global: 1,
                per_domain: 1,
                hard_domain_max: None,
            },
            8,
        )
        .unwrap();
        let input = control.input();
        let guard = reporter.concurrency_handler(move |change| {
            input.adjust(match change {
                ConcurrencyChange::Increase => Adjustment::Increase,
                ConcurrencyChange::Decrease => Adjustment::Decrease,
            })
        });
        assert!(!reporter.concurrency_available());
        reporter.adjust_concurrency(ConcurrencyChange::Increase);
        assert_eq!(control.snapshot().target, 1);
        for (global, expected) in [(4, 4), (2, 5)] {
            reporter.begin_host_dashboard(&["app".into()]);
            let pool = control
                .with_limits(AdmissionLimits {
                    global,
                    per_domain: global,
                    hard_domain_max: None,
                })
                .unwrap();
            let mut first = true;
            admission::dispatch(
                vec![(None, ()); 8],
                &pool,
                |_| {},
                |_| false,
                |_, _| {},
                |snapshot| {
                    reporter.phase_admission(
                        snapshot.running,
                        snapshot.target,
                        snapshot.adjustable(),
                        None,
                    );
                    assert_eq!(reporter.concurrency_available(), snapshot.adjustable());
                    if first {
                        first = false;
                        assert_eq!(snapshot.target, expected);
                        if global == 4 {
                            reporter.adjust_concurrency(ConcurrencyChange::Increase);
                            assert_eq!(pool.snapshot().target, 5);
                        }
                    }
                },
            )
            .unwrap();
            assert!(!reporter.concurrency_available());
            assert!(reporter.state.lock().unwrap().concurrency_handler.is_some());
            reporter.adjust_concurrency(ConcurrencyChange::Decrease);
            assert_eq!(pool.snapshot().target, 5);
        }
        // An exclusive build or a non-host phase must not inherit a live hint.
        reporter.phase_admission(1, 1, false, Some("exclusive"));
        assert!(!reporter.concurrency_available());
        reporter.phase_admission(1, 2, true, None);
        assert!(reporter.concurrency_available());
        reporter.end_silent_phase();
        reporter.started("Apply infrastructure");
        assert!(!reporter.concurrency_available());
        drop(guard);
        assert!(reporter.state.lock().unwrap().concurrency_handler.is_none());
    }

    #[test]
    fn input_feedback_marks_only_changed_numbers_and_expires_without_new_work() {
        let mut reporter = interactive_reporter();
        reporter.style = TerminalStyle::from_capabilities(true, false);
        reporter.begin_host_dashboard(&["app".into()]);
        reporter.phase_admission(2, 2, true, None);
        {
            let _rejected = reporter.concurrency_handler(|_| false);
            reporter.adjust_concurrency(ConcurrencyChange::Increase);
            assert!(reporter.state.lock().unwrap().key_feedback.is_none());
            assert!(!host_frame(&reporter).contains("\x1b[38;5;204m"));
        }
        let _guard = reporter.concurrency_handler(|_| true);
        reporter.adjust_concurrency(ConcurrencyChange::Increase);
        // An accepted press without a changed snapshot flashes the hint, not the values.
        assert!(!host_frame(&reporter).contains("\x1b[38;5;204m"));
        reporter.phase_admission(2, 3, true, None);
        let header = host_frame(&reporter);
        assert!(header.contains("\x1b[38;5;204m3\x1b[0m"));
        assert!(!header.contains("\x1b[38;5;204m2\x1b[0m"));
        reporter.phase_admission(3, 3, true, None);
        reporter.phase_admission(3, 3, true, Some("waiting"));
        assert_eq!(
            host_frame(&reporter)
                .matches("\x1b[38;5;204m3\x1b[0m")
                .count(),
            2
        );
        reporter.adjust_concurrency(ConcurrencyChange::Decrease);
        reporter.phase_admission(3, 2, true, Some("draining"));
        assert!(host_frame(&reporter).contains("\x1b[38;5;204m2\x1b[0m"));
        let expired = Instant::now() + INPUT_FEEDBACK_DURATION;
        {
            let mut state = reporter.state.lock().unwrap();
            assert!(state.expire_input_feedback(expired));
            assert!(!state.expire_input_feedback(expired));
            assert!(state.key_feedback.is_none());
        }
        assert!(!host_frame(&reporter).contains("\x1b[38;5;204m"));
        // Unprompted occupancy updates don't create distracting flashes.
        reporter.phase_admission(1, 2, true, None);
        assert!(!host_frame(&reporter).contains("\x1b[38;5;204m"));
        let redirected = reporter.clone().without_terminal();
        redirected.key_pressed(FeedbackKey::Verbose);
        assert!(reporter.state.lock().unwrap().key_feedback.is_none());
        reporter.style = TerminalStyle::from_capabilities(true, true);
        reporter.key_pressed(FeedbackKey::Verbose);
        assert!(reporter.state.lock().unwrap().key_feedback.is_none());
        assert!(!host_frame(&reporter).contains('\x1b'));
    }

    #[test]
    fn accepted_concurrency_feedback_catches_a_snapshot_published_inside_the_callback() {
        let mut reporter = interactive_reporter();
        reporter.style = TerminalStyle::from_capabilities(true, false);
        reporter.begin_host_dashboard(&["app".into()]);
        reporter.phase_admission(2, 2, true, None);
        let publisher = reporter.clone();
        let _guard = reporter.concurrency_handler(move |_| {
            publisher.phase_admission(3, 3, true, None);
            true
        });

        reporter.adjust_concurrency(ConcurrencyChange::Increase);

        let header = host_frame(&reporter);
        assert_eq!(header.matches("\x1b[38;5;204m3\x1b[0m").count(), 2);
    }

    #[test]
    fn footer_feedback_is_key_specific_and_width_is_independent_of_ansi() {
        let strip_ansi = |text: &str| {
            text.replace("\x1b[2m", "")
                .replace("\x1b[38;5;204m", "")
                .replace("\x1b[0m", "")
        };
        let color = TerminalStyle::from_capabilities(true, false);
        let plain = TerminalStyle::from_capabilities(true, true);
        for (key, label) in [
            (FeedbackKey::Increase, "+"),
            (FeedbackKey::Decrease, "-"),
            (FeedbackKey::Verbose, "v"),
            (FeedbackKey::Run, "ctrl/alt-r"),
            (FeedbackKey::Errors, "ctrl/alt-e"),
            (FeedbackKey::Cancel, "ctrl-c"),
        ] {
            let text = footer_hints(color, true, true, "cancel", Some(180), Some(key));
            assert_eq!(text.matches("\x1b[38;5;204m").count(), 1);
            assert!(text.contains(&color.paint(Tone::InputFeedback, label)));
            assert_eq!(
                strip_ansi(&text),
                footer_hints(plain, true, true, "cancel", Some(180), Some(key))
            );
        }
        let narrow = footer_hints(
            color,
            true,
            true,
            "cancel",
            Some(60),
            Some(FeedbackKey::Increase),
        );
        assert!(narrow.contains(&color.paint(Tone::InputFeedback, "+")));
        assert!(strip_ansi(&narrow).ends_with("ctrl-c: cancel"));
        assert!(strip_ansi(&narrow).chars().count() <= 60);
    }

    #[test]
    fn concurrency_guard_releases_registration_on_success_error_and_unwind() {
        for exit in 0..3 {
            let reporter = interactive_reporter();
            reporter.begin_host_dashboard(&["app".into()]);
            reporter.phase_admission(1, 2, true, None);
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let _guard = reporter.concurrency_handler(|_| true);
                assert!(reporter.concurrency_available());
                match exit {
                    0 => Ok(()),
                    1 => Err("fixture: workflow error"),
                    _ => panic!("fixture: workflow panic"),
                }
            }));
            assert!(!reporter.concurrency_available());
            assert!(reporter.state.lock().unwrap().concurrency_handler.is_none());
            match exit {
                0 => assert!(result.unwrap().is_ok()),
                1 => assert!(result.unwrap().is_err()),
                _ => assert!(result.is_err()),
            }
        }
    }

    #[test]
    fn concurrency_callbacks_are_scoped_reporter_local_and_invoked_without_its_lock() {
        let reporter = interactive_reporter();
        reporter.begin_host_dashboard(&["app".into()]);
        reporter.phase_admission(1, 2, true, None);
        let other = super::ProgressReporter::new(false);
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = calls.clone();
        let clone = reporter.clone();
        let guard = reporter.concurrency_handler(move |_| {
            assert!(clone.concurrency_available());
            counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            true
        });
        assert!(!other.concurrency_available());
        reporter.adjust_concurrency(super::ConcurrencyChange::Increase);
        {
            let _nested = reporter.concurrency_handler(|_| true);
            reporter.adjust_concurrency(super::ConcurrencyChange::Decrease);
        }
        reporter.adjust_concurrency(super::ConcurrencyChange::Decrease);
        drop(guard);
        reporter.adjust_concurrency(super::ConcurrencyChange::Increase);
        assert!(!reporter.concurrency_available());
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 2);
    }

    use super::*;

    #[test]
    fn formats_short_and_long_durations_compactly() {
        assert_eq!(format_duration(Duration::from_millis(42)), "42ms");
        assert_eq!(format_duration(Duration::from_millis(1_250)), "1.2s");
        assert_eq!(format_duration(Duration::from_secs(125)), "2m 05s");
    }

    #[test]
    fn heartbeat_keeps_quiet_and_detailed_steps_visibly_alive() {
        assert_eq!(heartbeat_detail(None, Duration::from_secs(3)), "3.0s");
        assert_eq!(
            heartbeat_detail(Some("Waiting · running"), Duration::from_secs(65)),
            "Waiting · running · 1m 05s elapsed"
        );
    }

    #[test]
    fn step_label_is_short_and_human_readable() {
        let step = StepProgress {
            transaction: "move-zulip--item-001".to_owned(),
            item: "item-001".to_owned(),
            action: Action::Seed,
            step: "seed".to_owned(),
            description: "copy source data to target".to_owned(),
            location: "controller (source -> target)".to_owned(),
        };
        assert_eq!(step_label(&step), "Copy source data to target");
    }

    #[test]
    fn nested_steps_restore_the_parent_span() {
        set_json_output(false);
        let reporter = ProgressReporter {
            enabled: true,
            interactive: false,
            recent_update_limit: 0,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Stderr,
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.started("Publish projection");
        reporter.started("Push projection");
        assert_eq!(reporter.state.lock().unwrap().stack.len(), 2);

        reporter.complete_active("Push projection");
        let state = reporter.state.lock().unwrap();
        assert_eq!(state.stack.len(), 1);
        assert_eq!(state.stack[0].label, "Publish projection");
        drop(state);

        reporter.complete_active("Publish projection");
        assert!(reporter.state.lock().unwrap().stack.is_empty());
    }

    #[test]
    fn active_terminal_line_distinguishes_work_from_progress_detail() {
        let style = TerminalStyle::from_capabilities(true, false);
        let line = active_line(style, "Copy source data", Some("42% · 100 MiB"));
        assert_eq!(
            line,
            "\x1b[36m● Copy source data\x1b[0m  \x1b[2m42% · 100 MiB\x1b[0m"
        );
    }

    #[test]
    fn messages_are_body_text_and_headings_are_explicit() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: false,
            recent_update_limit: 0,
            style: TerminalStyle::from_capabilities(true, false),
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.message("  │ [Build plan err] warning: dirty tree");
        reporter.message("  abird-gondor-ci · ok");
        reporter.heading("Summary · deploy · success");

        assert_eq!(
            String::from_utf8(buffer.lock().unwrap().clone()).unwrap(),
            concat!(
                "  │ [Build plan err] warning: dirty tree\n",
                "  abird-gondor-ci · ok\n",
                "\x1b[1mSummary · deploy · success\x1b[0m\n",
            )
        );
    }

    #[test]
    fn summary_metadata_and_labeled_values_use_secondary_lines_and_tone() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: false,
            recent_update_limit: 0,
            style: TerminalStyle::from_capabilities(true, false),
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.message_field("Source", "d968b388 + staged:abc");
        reporter.message_field_with_metadata("Build strategy", "auto", Some("nix"));
        reporter.heading_with_metadata(
            "Summary · deploy · success",
            [
                "d968b388 + staged:abc".to_owned(),
                "total elapsed 23.8s".to_owned(),
            ],
        );

        assert_eq!(
            String::from_utf8(buffer.lock().unwrap().clone()).unwrap(),
            concat!(
                "\x1b[34mSource\x1b[0m: d968b388 + staged:abc\n",
                "\x1b[34mBuild strategy\x1b[0m: auto\x1b[2m (nix)\x1b[0m\n",
                "\x1b[1mSummary · deploy · success\x1b[0m\n",
                "  \x1b[2md968b388 + staged:abc\x1b[0m\x1b[2m · \x1b[0m\x1b[2mtotal elapsed 23.8s\x1b[0m\n",
            )
        );
    }

    /// Interactive reporter over an in-memory buffer, mirroring the process
    /// singleton the key-toggle path drives.
    fn interactive_reporter() -> ProgressReporter {
        set_json_output(false);
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::new(Mutex::new(Vec::new()))),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };
        reporter.state.lock().unwrap().stack.push(ActiveProgress {
            id: 1,
            label: "Deploy systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: None,
            started: Instant::now(),
        });
        reporter
    }

    #[test]
    fn timed_field_ticks_in_place_without_creating_a_step() {
        let reporter = interactive_reporter();
        reporter.state.lock().unwrap().stack.clear();
        let mut wait = reporter.timed_field("Host-local lock", "waiting");
        let start = wait.started;
        let painted = || reporter.state.lock().unwrap().painted.clone();
        assert_eq!(
            painted(),
            Painted::InPlace(vec!["Host-local lock: waiting (elapsed 0ms)".into()])
        );
        wait.tick(start + Duration::from_millis(500));
        assert_eq!(
            painted(),
            Painted::InPlace(vec!["Host-local lock: waiting (elapsed 0ms)".into()])
        );
        wait.tick(start + Duration::from_millis(1250));
        assert_eq!(
            painted(),
            Painted::InPlace(vec!["Host-local lock: waiting (elapsed 1.2s)".into()])
        );
        assert!(reporter.state.lock().unwrap().stack.is_empty());
        drop(wait);
        assert_eq!(painted(), Painted::None);

        let ProgressDestination::Buffer(buffer) = &reporter.destination else {
            panic!("expected buffer");
        };
        let output = buffer.lock().unwrap();
        assert!(!output.contains(&b'\n'), "only one row should be written");
    }

    #[test]
    fn timed_field_announces_once_without_a_terminal() {
        let mut reporter = interactive_reporter();
        reporter.interactive = false;
        let mut wait = reporter.timed_field("Host-local lock", "waiting");
        wait.tick(wait.started + Duration::from_secs(30));
        drop(wait);
        let ProgressDestination::Buffer(buffer) = &reporter.destination else {
            panic!("expected buffer");
        };
        assert_eq!(*buffer.lock().unwrap(), b"Host-local lock: waiting\n");
    }

    /// One verbose line at a fixed time, so fixtures read like a stream.
    fn line(seq: u64, tone: Tone, text: &str) -> VerboseLine {
        VerboseLine {
            seq,
            at: SystemTime::UNIX_EPOCH,
            tone,
            text: text.to_owned(),
        }
    }

    /// The retained digest flattened exactly as the errors view renders it.
    fn digest_texts(reporter: &ProgressReporter) -> Vec<String> {
        let state = reporter.state.lock().unwrap();
        let retained = &state.retained_verbose;
        digest_rows(retained, 0, digest_row_count(retained))
            .into_iter()
            .map(|(_, text)| text)
            .collect()
    }

    /// Render the live region for the reporter's current state.
    fn region_lines(reporter: &ProgressReporter, viewport: (usize, usize)) -> Vec<String> {
        let state = reporter.state.lock().unwrap();
        live_region_lines(
            TerminalStyle::from_capabilities(false, false),
            Some("keys"),
            None,
            &state,
            Some(viewport),
            false,
        )
        .expect("active span renders a region")
    }

    #[test]
    fn retained_digest_keeps_two_context_lines_around_a_problem() {
        let reporter = interactive_reporter();
        reporter.retain_verbose_line(Tone::Neutral, "  │ before one");
        reporter.retain_verbose_line(Tone::Neutral, "  │ before two");
        reporter.retain_verbose_line(Tone::Failure, "  │ error: boom");
        reporter.retain_verbose_line(Tone::Neutral, "  │ after one");
        reporter.retain_verbose_line(Tone::Neutral, "  │ after two");
        reporter.retain_verbose_line(Tone::Neutral, "  │ dropped");

        assert_eq!(
            digest_texts(&reporter),
            vec![
                "  │ before one",
                "  │ before two",
                "  │ error: boom",
                "  │ after one",
                "  │ after two",
            ]
        );
    }

    #[test]
    fn adjacent_problems_merge_without_duplicating_context() {
        let reporter = interactive_reporter();
        reporter.retain_verbose_line(Tone::Neutral, "before");
        reporter.retain_verbose_line(Tone::Failure, "error one");
        reporter.retain_verbose_line(Tone::LogWarning, "warning two");
        reporter.retain_verbose_line(Tone::Neutral, "after");

        assert_eq!(
            digest_texts(&reporter),
            vec!["before", "error one", "warning two", "after"]
        );
    }

    #[test]
    fn non_adjacent_problems_are_separated_by_an_elision() {
        let reporter = interactive_reporter();
        reporter.retain_verbose_line(Tone::Failure, "early error");
        for index in 0..8 {
            reporter.retain_verbose_line(Tone::Neutral, format!("noise {index}"));
        }
        reporter.retain_verbose_line(Tone::Failure, "late error");

        assert_eq!(
            digest_texts(&reporter),
            vec![
                "early error",
                "noise 0",
                "noise 1",
                "...",
                "noise 6",
                "noise 7",
                "late error",
            ]
        );
    }

    #[test]
    fn digest_rereads_problems_recorded_while_hidden() {
        let reporter = interactive_reporter();
        reporter.verbose_line(Tone::Failure, "error while shown");
        reporter.clear_verbose_output();
        reporter.retain_verbose_line(Tone::Neutral, "hidden noise");
        reporter.retain_verbose_line(Tone::LogWarning, "warning while hidden");

        let digest = digest_texts(&reporter);
        assert!(
            digest.contains(&"error while shown".to_owned()),
            "{digest:?}"
        );
        assert!(
            digest.contains(&"warning while hidden".to_owned()),
            "{digest:?}"
        );
    }

    #[test]
    fn run_view_renders_the_live_ring() {
        let reporter = interactive_reporter();
        reporter.set_verbose_view(VerboseView::Run);
        reporter.verbose_line(Tone::Neutral, "live one");
        reporter.verbose_line(Tone::Failure, "live error");

        let lines = region_lines(&reporter, (24, 100));
        assert!(
            lines
                .first()
                .is_some_and(|line| line.starts_with("● Logs · run")),
            "{lines:?}"
        );
        assert!(lines.iter().any(|line| line == "live error"), "{lines:?}");
    }

    #[test]
    fn errors_view_renders_the_retained_digest() {
        let reporter = interactive_reporter();
        reporter.retain_verbose_line(Tone::Neutral, "  │ before");
        reporter.retain_verbose_line(Tone::Failure, "  │ error: boom");
        reporter.retain_verbose_line(Tone::LogWarning, "  │ warning: hmm");

        reporter.set_verbose_view(VerboseView::Errors);

        let lines = region_lines(&reporter, (24, 100));
        assert!(
            lines
                .first()
                .is_some_and(|line| line.starts_with("● Logs · errors")),
            "{lines:?}"
        );
        assert!(
            lines.iter().any(|line| line == "  │ error: boom"),
            "{lines:?}"
        );
        assert!(
            lines.iter().any(|line| line == "  │ warning: hmm"),
            "{lines:?}"
        );
    }

    #[test]
    fn overflow_row_names_hidden_lines_and_scroll_keys() {
        let reporter = interactive_reporter();
        reporter.set_verbose_view(VerboseView::Run);
        for index in 0..80 {
            reporter.verbose_line(Tone::Neutral, format!("live {index}"));
        }

        let lines = region_lines(&reporter, (20, 100));
        let overflow = lines
            .iter()
            .find(|line| line.contains('▲') || line.contains('▼'))
            .unwrap_or_else(|| panic!("no overflow row in {lines:?}"));
        assert!(overflow.contains("above"), "{overflow:?}");
        assert!(overflow.contains("ctrl/alt-h/j/k/l"), "{overflow:?}");
        assert!(overflow.contains("esc/ctrl/alt-g: newest"), "{overflow:?}");
    }

    #[test]
    fn scrolling_moves_the_visible_window() {
        let reporter = interactive_reporter();
        reporter.set_verbose_view(VerboseView::Run);
        for index in 0..80 {
            reporter.verbose_line(Tone::Neutral, format!("live {index}"));
        }

        let newest = region_lines(&reporter, (20, 100));
        assert!(newest.iter().any(|line| line == "live 79"), "{newest:?}");

        reporter.scroll_verbose_lines(10);

        let scrolled = region_lines(&reporter, (20, 100));
        assert!(
            !scrolled.iter().any(|line| line == "live 79"),
            "{scrolled:?}"
        );
        assert!(
            scrolled.iter().any(|line| line == "live 65"),
            "{scrolled:?}"
        );
        assert!(
            scrolled.iter().any(|line| line.contains("below")),
            "{scrolled:?}"
        );
    }

    #[test]
    fn a_scrolled_window_holds_its_lines_as_new_output_arrives() {
        let reporter = interactive_reporter();
        reporter.set_verbose_view(VerboseView::Run);
        for index in 0..80 {
            reporter.verbose_line(Tone::Neutral, format!("live {index}"));
        }
        reporter.scroll_verbose_lines(10);
        let held = region_lines(&reporter, (20, 100));
        assert!(held.iter().any(|line| line == "live 56"), "{held:?}");

        for index in 80..85 {
            reporter.verbose_line(Tone::Neutral, format!("live {index}"));
        }

        // The window must stay on the lines the reader is looking at instead of
        // sliding with every arriving line.
        let after = region_lines(&reporter, (20, 100));
        assert!(
            after.iter().any(|line| line == "live 56"),
            "window slid: {after:?}"
        );
        assert!(!after.iter().any(|line| line == "live 55"), "{after:?}");
    }

    #[test]
    fn a_scrolled_errors_window_holds_its_rows_as_problems_arrive() {
        let reporter = interactive_reporter();
        reporter.set_verbose_view(VerboseView::Errors);
        for index in 0..40 {
            reporter.retain_verbose_line(Tone::Failure, format!("error {index}"));
        }
        reporter.scroll_verbose_lines(10);
        let before = region_lines(&reporter, (20, 100));
        assert_ne!(before[1], "error 39", "the window left the newest rows");

        reporter.retain_verbose_line(Tone::Failure, "error 40");

        // The top row stays put, so the reader keeps the problem they were on;
        // only the hidden-row count moves.
        let after = region_lines(&reporter, (20, 100));
        assert_eq!(before[1], after[1], "the window slid");
    }

    #[test]
    fn a_scrolled_run_window_holds_its_rows_when_the_ring_evicts() {
        let reporter = interactive_reporter();
        reporter.set_verbose_view(VerboseView::Run);
        {
            let mut state = reporter.state.lock().unwrap();
            for index in 0..VERBOSE_MAX_LIVE_LINES {
                state.verbose_tail.push_back(line(
                    index as u64,
                    Tone::Neutral,
                    &format!("live {index}"),
                ));
            }
        }
        reporter.scroll_verbose_lines(10);
        let before = region_lines(&reporter, (20, 100));

        // Every line past the cap evicts one from the front while the window
        // holds the rows the reader is on.
        for index in 0..5 {
            reporter.verbose_line(
                Tone::Neutral,
                format!("live {}", VERBOSE_MAX_LIVE_LINES + index),
            );
        }

        let after = region_lines(&reporter, (20, 100));
        assert_eq!(
            before[1], after[1],
            "the window slid while the ring evicted"
        );
    }

    #[test]
    fn errors_windows_count_elisions_as_rows() {
        let reporter = interactive_reporter();
        reporter.retain_verbose_line(Tone::Failure, "error 0");
        reporter.retain_verbose_line(Tone::Neutral, "noise 0");
        reporter.retain_verbose_line(Tone::Neutral, "noise 1");
        for index in 2..8 {
            reporter.retain_verbose_line(Tone::Neutral, format!("noise {index}"));
        }
        reporter.retain_verbose_line(Tone::Failure, "error 1");

        let state = reporter.state.lock().unwrap();
        let retained = &state.retained_verbose;
        // Two context lines survive either side of each problem, and the skipped
        // `noise 2..=5` collapse into one `...` row that still occupies a row of
        // the view, so a scrolled window must account for it.
        assert_eq!(digest_row_count(retained), 7);
        let window = |start, end| {
            digest_rows(retained, start, end)
                .into_iter()
                .map(|(_, text)| text)
                .collect::<Vec<_>>()
        };
        assert_eq!(window(2, 6), vec!["noise 1", "...", "noise 6", "noise 7"]);
        assert_eq!(window(5, 7), vec!["noise 7", "error 1"]);
    }

    #[test]
    fn the_logs_header_reports_when_the_view_started() {
        let style = TerminalStyle::from_capabilities(false, false);
        // The process time zone decides the digits, so assert the shape of the
        // clock reading rather than a fixed time.
        let header = verbose_header(style, VerboseView::Run, Some(SystemTime::now()));
        let clock = header
            .strip_prefix("● Logs · run · since ")
            .expect("the header names the view and when it started");
        assert_eq!(clock.len(), 8, "{clock}");
        assert_eq!(
            (clock.as_bytes()[2], clock.as_bytes()[5]),
            (b':', b':'),
            "{clock}"
        );
        assert!(
            clock
                .chars()
                .filter(|character| *character != ':')
                .all(|character| character.is_ascii_digit()),
            "{clock}"
        );

        // A view with nothing to show yet has no start to report.
        assert_eq!(
            verbose_header(style, VerboseView::Errors, None),
            "● Logs · errors"
        );
    }

    #[test]
    fn an_unrepresentable_clock_time_keeps_the_header_shape() {
        // A stamp before the epoch cannot be rendered, so the segment degrades to
        // a placeholder instead of vanishing mid-header.
        let before_epoch = SystemTime::UNIX_EPOCH - Duration::from_secs(1);
        assert_eq!(format_clock_time(before_epoch), UNKNOWN_CLOCK_TIME);
    }

    #[test]
    fn the_footer_drops_hints_before_cutting_the_interrupt_label() {
        let plain = TerminalStyle::from_capabilities(false, false);
        let wide = footer_hints(plain, true, false, "confirm cancel", Some(120), None);
        assert!(wide.contains("ctrl/alt-e: errors"), "{wide}");
        assert!(wide.ends_with("ctrl-c: confirm cancel"), "{wide}");

        // The view pair drops as a unit, and the interrupt label, which escalates
        // as the cancel is armed, survives intact instead of being cut mid-word.
        assert_eq!(
            footer_hints(plain, true, false, "confirm cancel", Some(60), None),
            "keys: v: verbose · ctrl-c: confirm cancel"
        );
        assert_eq!(
            footer_hints(plain, true, false, "confirm cancel", Some(20), None),
            "keys: ctrl-c: confirm cancel"
        );
    }

    #[test]
    fn the_logs_label_comes_from_the_oldest_line_each_view_holds() {
        let earlier = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000);
        let later = SystemTime::UNIX_EPOCH + Duration::from_secs(2_000);
        let at = |seq, at, text: &str| VerboseLine {
            seq,
            at,
            tone: Tone::Neutral,
            text: text.to_owned(),
        };
        let reporter = interactive_reporter();
        reporter.set_verbose_view(VerboseView::Run);

        // A view holding nothing has nothing to date.
        assert_eq!(reporter.state.lock().unwrap().verbose_started(), None);

        {
            let mut state = reporter.state.lock().unwrap();
            state.verbose_tail.push_back(at(0, earlier, "first"));
            state.verbose_tail.push_back(at(1, later, "second"));
        }
        assert_eq!(
            reporter.state.lock().unwrap().verbose_started(),
            Some(earlier)
        );

        // Evicting the oldest line moves the label with the content it describes,
        // instead of reporting when the buffer was created.
        reporter.state.lock().unwrap().verbose_tail.pop_front();
        assert_eq!(
            reporter.state.lock().unwrap().verbose_started(),
            Some(later)
        );

        // The errors view dates its own buffer, which outlives a hide.
        reporter
            .state
            .lock()
            .unwrap()
            .retained_verbose
            .push_back(at(9, earlier, "error"));
        reporter.set_verbose_view(VerboseView::Errors);
        assert_eq!(
            reporter.state.lock().unwrap().verbose_started(),
            Some(earlier)
        );
        reporter.clear_verbose_output();
        reporter.set_verbose_view(VerboseView::Errors);
        assert_eq!(
            reporter.state.lock().unwrap().verbose_started(),
            Some(earlier),
            "a hide retains the digest and its label"
        );
    }

    #[test]
    fn reset_verbose_history_forgets_a_previous_command() {
        let reporter = interactive_reporter();
        reporter.set_verbose_view(VerboseView::Errors);
        reporter.verbose_line(Tone::Failure, "old error");

        reporter.reset_verbose_history();

        let state = reporter.state.lock().unwrap();
        assert!(state.verbose_tail.is_empty());
        assert!(state.retained_verbose.is_empty());
        assert!(state.verbose_recent.is_empty());
        assert_eq!(state.verbose_seq, 0);
        assert_eq!(state.verbose_scroll, 0);
    }

    #[test]
    fn an_unreported_viewport_still_bounds_the_region() {
        let reporter = interactive_reporter();
        reporter.set_verbose_view(VerboseView::Run);
        for index in 0..(DEFAULT_VIEWPORT_ROWS * 4) {
            reporter.verbose_line(Tone::Neutral, format!("live {index}"));
        }

        // A terminal that will not report its size must still bound the region,
        // instead of streaming the whole ring into the scrollback.
        let state = reporter.state.lock().unwrap();
        let lines = live_region_lines(
            TerminalStyle::from_capabilities(false, false),
            Some("keys"),
            None,
            &state,
            None,
            true,
        )
        .expect("active span renders a region");
        assert!(
            lines.len() < DEFAULT_VIEWPORT_ROWS,
            "region rows {} must stay bounded",
            lines.len()
        );
    }

    #[test]
    fn errors_view_scroll_bound_counts_elision_rows() {
        let state = ProgressState {
            verbose_view: VerboseView::Errors,
            retained_verbose: VecDeque::from([
                line(0, Tone::Failure, "early"),
                line(5, Tone::Failure, "late"),
            ]),
            ..ProgressState::default()
        };
        // Rendered as `early`, `...`, `late`, so the scroll bound must count
        // the elision row rather than just the retained entries.
        assert_eq!(state.verbose_content_len(), 3);
    }

    #[test]
    fn retained_digest_is_bounded() {
        let reporter = interactive_reporter();
        for index in 0..(VERBOSE_MAX_RETAINED_LINES + 50) {
            reporter.retain_verbose_line(Tone::Failure, format!("error {index}"));
        }
        assert_eq!(
            reporter.state.lock().unwrap().retained_verbose.len(),
            VERBOSE_MAX_RETAINED_LINES
        );
    }

    #[test]
    fn non_interactive_runs_never_retain_hidden_lines() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: false,
            recent_update_limit: 0,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.retain_verbose_line(Tone::Failure, "hidden error");

        assert!(reporter.state.lock().unwrap().retained_verbose.is_empty());
        assert!(buffer.lock().unwrap().is_empty());
    }

    #[test]
    fn live_region_shows_the_logs_header_while_verbose_is_active() {
        let mut state = ProgressState::default();
        state.stack.push(ActiveProgress {
            id: 1,
            label: "Deploy systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: None,
            started: Instant::now(),
        });
        let style = TerminalStyle::from_capabilities(false, false);

        let hidden = live_region_lines(style, Some("keys"), None, &state, Some((24, 80)), true)
            .expect("active span renders a region");
        assert!(
            !hidden.iter().any(|line| line == "● Logs · run"),
            "{hidden:?}"
        );

        state.verbose_active = true;
        let revealed = live_region_lines(style, Some("keys"), None, &state, Some((24, 80)), true)
            .expect("active span renders a region");
        assert_eq!(revealed.first().map(String::as_str), Some("● Logs · run"));
    }

    #[test]
    fn verbose_section_renders_without_an_active_span() {
        // A host-agent job can own no dashboard, so the logs must still render.
        let state = ProgressState {
            verbose_active: true,
            verbose_tail: VecDeque::from([line(0, Tone::Failure, "  │ error: boom")]),
            ..ProgressState::default()
        };

        let lines = live_region_lines(
            TerminalStyle::from_capabilities(false, false),
            Some("keys"),
            None,
            &state,
            Some((24, 80)),
            true,
        )
        .expect("an open verbose section renders without a span");
        assert!(
            lines
                .first()
                .is_some_and(|line| line.starts_with("● Logs · run")),
            "{lines:?}"
        );
        assert!(
            lines.iter().any(|line| line == "  │ error: boom"),
            "{lines:?}"
        );
        assert_eq!(lines.last().map(String::as_str), Some("keys"));
    }

    #[test]
    fn idle_reporter_without_a_span_renders_nothing() {
        let state = ProgressState::default();
        assert!(
            live_region_lines(
                TerminalStyle::from_capabilities(false, false),
                Some("keys"),
                None,
                &state,
                Some((24, 80)),
                true,
            )
            .is_none()
        );
    }

    #[test]
    fn footer_escalates_the_ctrl_c_action() {
        assert_eq!(next_cancel_action(false, false), "cancel");
        assert_eq!(next_cancel_action(false, true), "confirm cancel");
        assert_eq!(next_cancel_action(true, false), "force exit");
    }

    #[test]
    fn cancel_notice_renders_just_above_the_footer() {
        let mut state = ProgressState::default();
        state.stack.push(ActiveProgress {
            id: 1,
            label: "Deploy systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: None,
            started: Instant::now(),
        });
        let lines = live_region_lines(
            TerminalStyle::from_capabilities(false, false),
            Some("keys: v: verbose · ctrl-c: force exit"),
            Some("Cancel interrupt received · cancelling"),
            &state,
            Some((24, 80)),
            true,
        )
        .expect("active span renders a region");
        let chrome = &lines[lines.len() - 3..];
        assert_eq!(chrome[0], "");
        assert_eq!(chrome[1], "Cancel interrupt received · cancelling");
        assert_eq!(chrome[2], "keys: v: verbose · ctrl-c: force exit");
        assert!(lines.len() < 24, "region rows {} must fit", lines.len());
    }

    #[test]
    fn hiding_verbose_logs_drops_the_live_tail() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };
        reporter.state.lock().unwrap().stack.push(ActiveProgress {
            id: 1,
            label: "Build systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: None,
            started: Instant::now(),
        });

        reporter.verbose_line(Tone::Neutral, "  │ first");
        reporter.verbose_line(Tone::Neutral, "  │ second");
        assert!(reporter.state.lock().unwrap().verbose_active);
        assert_eq!(reporter.state.lock().unwrap().verbose_tail.len(), 2);

        reporter.clear_verbose_output();
        assert!(!reporter.state.lock().unwrap().verbose_active);
        assert!(reporter.state.lock().unwrap().verbose_tail.is_empty());

        // Hiding replaces the header with the dashboard and erases the tail.
        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        let final_frame = rendered.rsplit(BEGIN_SYNCHRONIZED_UPDATE).next().unwrap();
        assert!(final_frame.contains("● Build systems"), "{rendered:?}");
        assert!(final_frame.contains("\r\x1b[K"), "{rendered:?}");
        assert!(!final_frame.contains("  │ second"), "{rendered:?}");
        // A second hide changes nothing.
        let before = buffer.lock().unwrap().len();
        reporter.clear_verbose_output();
        assert_eq!(buffer.lock().unwrap().len(), before);
    }

    #[test]
    fn non_interactive_verbose_lines_are_appended() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: false,
            recent_update_limit: 0,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.verbose_line(Tone::Neutral, "  │ first");
        assert_eq!(
            String::from_utf8(buffer.lock().unwrap().clone()).unwrap(),
            "  │ first\n"
        );
        let before = buffer.lock().unwrap().len();
        reporter.clear_verbose_output();
        assert_eq!(buffer.lock().unwrap().len(), before);
    }

    #[test]
    fn verbose_lines_serialize_on_the_output_lock() {
        set_json_output(false);
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::new(Mutex::new(Vec::new()))),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };
        let guard = reporter.output.lock().unwrap();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let writer = reporter.clone();
        let handle = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            writer.verbose_line(Tone::Neutral, "blocked");
        });
        started_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("writer thread should start");
        std::thread::sleep(Duration::from_millis(150));
        // A verbose redraw must wait for the same output lock every other
        // writer holds, or its region write interleaves with the dashboard's.
        assert!(
            !handle.is_finished(),
            "verbose_line should block on the output lock"
        );
        drop(guard);
        handle.join().unwrap();
    }

    #[test]
    fn verbose_block_is_separated_from_the_dashboard_by_a_blank_line() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };
        reporter.state.lock().unwrap().stack.push(ActiveProgress {
            id: 1,
            label: "Build systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: None,
            started: Instant::now(),
        });

        reporter.verbose_line(Tone::Neutral, "  │ first");

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        // The dashboard redraw after the verbose line starts with a blank row.
        assert!(rendered.contains("  │ first\n\n"), "{rendered:?}");
    }

    #[test]
    fn dashboard_mode_is_shared_across_reporter_clones() {
        set_json_output(false);
        let base = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 0,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::new(Mutex::new(Vec::new()))),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };
        assert!(!base.shows_recent_updates());
        let fleet = base.clone().with_recent_updates(10);
        assert!(fleet.shows_recent_updates());
        // The key-toggle reader calls the process singleton, a separate clone
        // that only shares state, so the mode must live in the shared state for
        // hiding to redraw the same dashboard region.
        assert!(base.shows_recent_updates());
    }

    #[test]
    fn live_region_bounds_verbose_logs_and_footer_to_the_viewport() {
        let mut state = ProgressState::default();
        state.stack.push(ActiveProgress {
            id: 1,
            label: "Deploy systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: None,
            started: Instant::now(),
        });
        state.verbose_active = true;
        for index in 0..200 {
            state
                .verbose_tail
                .push_back(line(index, Tone::Neutral, &format!("log line {index}")));
        }

        let style = TerminalStyle::from_capabilities(false, false);
        let lines = live_region_lines(style, Some("keys"), None, &state, Some((24, 80)), true)
            .expect("active span renders a region");
        // The whole region must fit so it is cleared in place, never scrolled.
        assert!(lines.len() < 24, "region overflowed: {}", lines.len());
        assert_eq!(lines.last().map(String::as_str), Some("keys"));
        let rendered = lines.join("\n");
        assert!(rendered.contains("log line 199"), "{rendered:?}");
        assert!(!rendered.contains("log line 0\n"), "{rendered:?}");
        // One blank row separates the tail from the dashboard, and another the
        // dashboard from the key footer.
        assert!(rendered.contains("\n\n"), "{rendered:?}");
        assert!(rendered.ends_with("\n\nkeys"), "{rendered:?}");
    }

    #[test]
    fn showing_verbose_marks_the_region_active_immediately() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };
        reporter.state.lock().unwrap().stack.push(ActiveProgress {
            id: 1,
            label: "Deploy systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: None,
            started: Instant::now(),
        });

        reporter.show_verbose_output();

        assert!(reporter.state.lock().unwrap().verbose_active);
        assert!(!buffer.lock().unwrap().is_empty());
    }

    #[test]
    fn hiding_verbose_clears_the_whole_region_not_just_one_row() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::BufferWithViewport(
                Arc::clone(&buffer),
                Arc::new(Mutex::new(Some((24, 100)))),
            ),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };
        reporter.state.lock().unwrap().stack.push(ActiveProgress {
            id: 1,
            label: "Build systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: None,
            started: Instant::now(),
        });
        for index in 0..40 {
            // Bypass the redraw throttle so the tail is actually rendered.
            reporter.state.lock().unwrap().stream_redraw_at = None;
            reporter.verbose_line(Tone::Neutral, format!("  │ log {index}"));
        }
        let region = painted_rows(&reporter);
        assert!(region > 2, "region should hold tail + dashboard: {region}");
        assert!(region < 24, "region must fit the viewport: {region}");
        buffer.lock().unwrap().clear();

        reporter.clear_verbose_output();

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            !rendered.contains("log 39"),
            "tail not cleared: {rendered:?}"
        );
        assert_eq!(
            rendered.matches("\x1b[K").count(),
            region,
            "replace the first row and erase every obsolete tail row"
        );
        assert!(
            rendered.ends_with(&format!("\x1b[{}A{END_SYNCHRONIZED_UPDATE}", region - 1)),
            "cursor must return to the remaining dashboard row: {rendered:?}"
        );
        assert!(!reporter.state.lock().unwrap().verbose_active);
    }

    /// A reporter on a test terminal whose reported size can change between
    /// frames, so resize behavior can be exercised without a real tty.
    fn reporter_with_viewport(
        buffer: &Arc<Mutex<Vec<u8>>>,
        viewport: &Arc<Mutex<Option<(usize, usize)>>>,
    ) -> ProgressReporter {
        set_json_output(false);
        ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::BufferWithViewport(
                Arc::clone(buffer),
                Arc::clone(viewport),
            ),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        }
    }

    fn push_active_span(reporter: &ProgressReporter) {
        reporter.state.lock().unwrap().stack.push(ActiveProgress {
            id: 1,
            label: "Build systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: None,
            started: Instant::now(),
        });
    }

    fn push_host_dashboard_span(reporter: &ProgressReporter, hosts: &[String]) {
        reporter.state.lock().unwrap().stack.push(ActiveProgress {
            id: 1,
            label: "Build systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: Some(HostDashboard {
                order: hosts.to_vec(),
                rows: hosts
                    .iter()
                    .map(|host| (host.clone(), HostRow::default()))
                    .collect(),
                ..HostDashboard::default()
            }),
            started: Instant::now(),
        });
    }

    /// Rows of the in-place region on screen: 0 for a snapshot or nothing.
    fn painted_rows(reporter: &ProgressReporter) -> usize {
        match &reporter.state.lock().unwrap().painted {
            Painted::InPlace(lines) => lines.len(),
            Painted::None | Painted::Snapshot => 0,
        }
    }

    fn is_painted(reporter: &ProgressReporter) -> bool {
        reporter.state.lock().unwrap().painted != Painted::None
    }

    #[test]
    fn a_resize_wipes_the_screen_and_redraws_the_region_from_home() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((24usize, 100usize))));
        let reporter = reporter_with_viewport(&buffer, &viewport);
        push_active_span(&reporter);
        reporter.refresh();
        assert_eq!(
            reporter.state.lock().unwrap().region_viewport,
            Some((24, 100))
        );
        buffer.lock().unwrap().clear();

        // Shrinking the terminal reflows the screen, so the stored row count no
        // longer locates the region; the frame must wipe and redraw from home.
        *viewport.lock().unwrap() = Some((12, 100));
        reporter.refresh();

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            rendered.contains("\x1b[2J\x1b[H"),
            "resize must wipe the screen: {rendered:?}"
        );
        assert!(
            !rendered.contains("\x1b[1A"),
            "resize must not clear by the stale row count: {rendered:?}"
        );
        assert!(
            rendered.contains("Build systems"),
            "the region must redraw after the wipe: {rendered:?}"
        );
        let state = reporter.state.lock().unwrap();
        assert_eq!(state.region_viewport, Some((12, 100)));
        drop(state);
        assert!(painted_rows(&reporter) > 0 && painted_rows(&reporter) < 12);
    }

    #[test]
    fn an_unchanged_viewport_preserves_the_drawn_rows() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((24usize, 100usize))));
        let reporter = reporter_with_viewport(&buffer, &viewport);
        push_active_span(&reporter);
        {
            let mut state = reporter.state.lock().unwrap();
            state.verbose_active = true;
            for index in 0..6 {
                state.verbose_tail.push_back(line(
                    index,
                    Tone::Neutral,
                    &format!("  │ log {index}"),
                ));
            }
        }
        reporter.refresh();
        let rendered_lines = painted_rows(&reporter);
        assert!(
            rendered_lines > 1,
            "region should hold the tail: {rendered_lines}"
        );
        buffer.lock().unwrap().clear();

        reporter.refresh();

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            !rendered.contains("\x1b[2J"),
            "an unchanged viewport must not wipe the screen: {rendered:?}"
        );
        assert!(
            rendered.is_empty(),
            "unchanged content must remain painted: {rendered:?}"
        );
    }

    #[test]
    fn a_columns_only_resize_also_wipes_the_screen() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((24usize, 100usize))));
        let reporter = reporter_with_viewport(&buffer, &viewport);
        push_active_span(&reporter);
        reporter.refresh();
        buffer.lock().unwrap().clear();

        // A width change reflows committed lines too, so it must wipe as well.
        *viewport.lock().unwrap() = Some((24, 80));
        reporter.refresh();

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            rendered.contains("\x1b[2J\x1b[H"),
            "a width change must wipe the screen: {rendered:?}"
        );
    }

    #[test]
    fn an_unknown_size_does_not_mask_the_next_resize() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((24usize, 100usize))));
        let reporter = reporter_with_viewport(&buffer, &viewport);
        push_active_span(&reporter);
        reporter.refresh();
        assert!(is_painted(&reporter));

        // A resize can make the size momentarily unreadable. The frame must lay
        // out against the last known size and keep it, not forget it.
        *viewport.lock().unwrap() = None;
        reporter.refresh();
        assert_eq!(
            reporter.state.lock().unwrap().region_viewport,
            Some((24, 100))
        );
        buffer.lock().unwrap().clear();

        // Once the size is readable again, the change must still wipe.
        *viewport.lock().unwrap() = Some((12, 100));
        reporter.refresh();
        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            rendered.contains("\x1b[2J\x1b[H"),
            "a resize after an unknown read must still wipe: {rendered:?}"
        );
    }

    #[test]
    fn a_first_frame_at_an_unknown_size_is_wiped_once_the_size_is_known() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(None::<(usize, usize)>));
        let reporter = reporter_with_viewport(&buffer, &viewport);
        push_active_span(&reporter);
        reporter.refresh();
        {
            let state = reporter.state.lock().unwrap();
            assert!(state.painted != Painted::None);
            assert_eq!(state.region_viewport, None);
        }
        buffer.lock().unwrap().clear();

        // The first readable size must be treated as a resize, not as the
        // first paint, because the region was already laid out at an unknown
        // size (a fresh pty reporting zero).
        *viewport.lock().unwrap() = Some((12, 100));
        reporter.refresh();

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            rendered.contains("\x1b[2J\x1b[H"),
            "the first readable size must wipe the region: {rendered:?}"
        );
        assert_eq!(
            reporter.state.lock().unwrap().region_viewport,
            Some((12, 100))
        );
    }

    #[test]
    fn a_replacing_clear_wipes_a_stranded_snapshot() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((6usize, 100usize))));
        let reporter = reporter_with_viewport(&buffer, &viewport);
        let hosts = (0..20)
            .map(|index| format!("host-{index}"))
            .collect::<Vec<_>>();
        push_host_dashboard_span(&reporter, &hosts);
        reporter.refresh();
        {
            let state = reporter.state.lock().unwrap();
            assert_eq!(state.painted, Painted::Snapshot);
        }
        buffer.lock().unwrap().clear();

        {
            let mut frame = ProgressFrame::new(&reporter.destination, reporter.interactive);
            reporter.clear_line(&mut frame);
        }

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            rendered.contains("\x1b[2J\x1b[H"),
            "a replacing clear must wipe the stranded snapshot: {rendered:?}"
        );
        assert!(!is_painted(&reporter));
    }

    #[test]
    fn an_unreadable_size_after_a_known_one_wipes_the_screen() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((24usize, 100usize))));
        let reporter = reporter_with_viewport(&buffer, &viewport);
        push_active_span(&reporter);
        reporter.refresh();
        buffer.lock().unwrap().clear();

        // An unreadable size after a known one may have reflowed at a width we
        // cannot see, so the counted row clear cannot be trusted: wipe.
        *viewport.lock().unwrap() = None;
        reporter.refresh();

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            rendered.contains("\x1b[2J\x1b[H"),
            "an unreadable size after a known one must wipe: {rendered:?}"
        );
    }

    #[test]
    fn a_second_resize_wipes_again() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((24usize, 100usize))));
        let reporter = reporter_with_viewport(&buffer, &viewport);
        push_active_span(&reporter);
        reporter.refresh();

        *viewport.lock().unwrap() = Some((12, 100));
        reporter.refresh();
        buffer.lock().unwrap().clear();

        // A later resize must wipe again, not treat the first as one-shot.
        *viewport.lock().unwrap() = Some((30, 90));
        reporter.refresh();

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            rendered.contains("\x1b[2J\x1b[H"),
            "a second resize must wipe too: {rendered:?}"
        );
    }

    #[test]
    fn a_resize_while_verbose_is_open_wipes_and_redraws_the_tail() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((24usize, 100usize))));
        let reporter = reporter_with_viewport(&buffer, &viewport);
        push_active_span(&reporter);
        {
            let mut state = reporter.state.lock().unwrap();
            state.verbose_active = true;
            for index in 0..30 {
                state.verbose_tail.push_back(line(
                    index,
                    Tone::Neutral,
                    &format!("  │ log {index}"),
                ));
            }
        }
        reporter.refresh();
        buffer.lock().unwrap().clear();

        *viewport.lock().unwrap() = Some((12, 100));
        reporter.refresh();

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            rendered.contains("\x1b[2J\x1b[H"),
            "verbose resize must wipe: {rendered:?}"
        );
        assert!(rendered.contains("● Logs"), "the header must redraw");
        assert!(rendered.contains("log 29"), "the tail must redraw");
    }

    #[test]
    fn scroll_verbose_newest_returns_the_window_to_the_newest_line() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((24usize, 100usize))));
        let reporter = reporter_with_viewport(&buffer, &viewport);
        push_active_span(&reporter);
        {
            let mut state = reporter.state.lock().unwrap();
            state.verbose_active = true;
            for index in 0..30 {
                state.verbose_tail.push_back(line(
                    index,
                    Tone::Neutral,
                    &format!("  │ log {index}"),
                ));
            }
        }
        reporter.refresh();
        reporter.scroll_verbose_lines(5);
        assert!(reporter.state.lock().unwrap().verbose_scroll > 0);

        buffer.lock().unwrap().clear();
        reporter.scroll_verbose_newest();

        assert_eq!(reporter.state.lock().unwrap().verbose_scroll, 0);
        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            rendered.contains("log 29"),
            "the newest line is shown: {rendered:?}"
        );
    }

    #[test]
    fn a_resize_returns_the_log_view_to_the_newest() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((24usize, 100usize))));
        let reporter = reporter_with_viewport(&buffer, &viewport);
        push_active_span(&reporter);
        {
            let mut state = reporter.state.lock().unwrap();
            state.verbose_active = true;
            for index in 0..30 {
                state.verbose_tail.push_back(line(
                    index,
                    Tone::Neutral,
                    &format!("  │ log {index}"),
                ));
            }
        }
        reporter.refresh();
        reporter.scroll_verbose_lines(5);
        assert!(reporter.state.lock().unwrap().verbose_scroll > 0);
        buffer.lock().unwrap().clear();

        *viewport.lock().unwrap() = Some((12, 100));
        reporter.refresh();

        assert_eq!(
            reporter.state.lock().unwrap().verbose_scroll,
            0,
            "a resize re-fits the window to the newest content"
        );
        // The wiping frame itself must already show the newest, not the window
        // it was scrolled against at the old height.
        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            rendered.contains("\x1b[2J\x1b[H") && rendered.contains("log 29"),
            "the resize frame shows the newest line: {rendered:?}"
        );
        assert!(
            !rendered.contains('▼'),
            "the resize frame is not still scrolled: {rendered:?}"
        );
    }

    #[test]
    fn an_oversized_verbose_roster_keeps_the_newest_hosts() {
        let hosts = (0..20)
            .map(|index| format!("host-{index:02}"))
            .collect::<Vec<_>>();
        let dashboard = HostDashboard {
            order: hosts.clone(),
            rows: hosts
                .iter()
                .map(|host| (host.clone(), HostRow::default()))
                .collect(),
            ..HostDashboard::default()
        };
        let active = ActiveProgress {
            id: 1,
            label: "Build systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: Some(dashboard.clone()),
            started: Instant::now(),
        };
        let lines = host_dashboard_lines(
            TerminalStyle::from_capabilities(false, false),
            &active,
            &dashboard,
            Duration::from_secs(1),
            Some((8, 80)),
            RosterPolicy::Windowed,
        )
        .join("\n");

        assert!(
            lines.contains("▲ 16 hosts above"),
            "the hidden count is exact: {lines:?}"
        );
        assert!(
            lines.contains("host-19"),
            "the newest host stays: {lines:?}"
        );
        assert!(
            !lines.contains("host-00"),
            "the oldest host is dropped: {lines:?}"
        );
        assert!(
            lines.lines().count() <= 7,
            "roster fits its budget: {lines:?}"
        );
    }

    #[test]
    fn a_single_row_dashboard_budget_never_overflows() {
        let hosts = (0..5)
            .map(|index| format!("host-{index}"))
            .collect::<Vec<_>>();
        let dashboard = HostDashboard {
            order: hosts.clone(),
            rows: hosts
                .iter()
                .map(|host| (host.clone(), HostRow::default()))
                .collect(),
            ..HostDashboard::default()
        };
        let active = ActiveProgress {
            id: 1,
            label: "Build systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: Some(dashboard.clone()),
            started: Instant::now(),
        };
        // A two-row terminal leaves a one-row dashboard budget: only the heading
        // fits, so the marker row is omitted rather than overflowing.
        let lines = host_dashboard_lines(
            TerminalStyle::from_capabilities(false, false),
            &active,
            &dashboard,
            Duration::from_secs(1),
            Some((2, 80)),
            RosterPolicy::Windowed,
        );
        assert_eq!(
            lines.len(),
            1,
            "a one-row budget emits only the heading: {lines:?}"
        );
    }

    #[test]
    fn the_verbose_region_windows_an_oversized_roster() {
        let hosts = (0..20)
            .map(|index| format!("host-{index:02}"))
            .collect::<Vec<_>>();
        let mut state = ProgressState {
            verbose_active: true,
            ..ProgressState::default()
        };
        state.stack.push(ActiveProgress {
            id: 1,
            label: "Build systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: Some(HostDashboard {
                order: hosts.clone(),
                rows: hosts
                    .iter()
                    .map(|host| (host.clone(), HostRow::default()))
                    .collect(),
                ..HostDashboard::default()
            }),
            started: Instant::now(),
        });
        let lines = live_region_lines(
            TerminalStyle::from_capabilities(false, false),
            Some("keys"),
            None,
            &state,
            Some((20, 80)),
            true,
        )
        .expect("a span renders a region");
        let rendered = lines.join("\n");

        // The integration path actually passes `RosterPolicy::Windowed`.
        assert!(rendered.contains("hosts above"), "{rendered:?}");
        assert!(rendered.contains("host-19"), "{rendered:?}");
        assert!(!rendered.contains("host-00"), "{rendered:?}");
        assert!(lines.len() < 20, "the region fits the viewport");
    }

    #[test]
    fn hiding_verbose_without_a_span_still_clears_the_region() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((24usize, 100usize))));
        let reporter = reporter_with_viewport(&buffer, &viewport);
        // No active span: the open logs block is the whole live region.
        {
            let mut state = reporter.state.lock().unwrap();
            state.verbose_active = true;
            state
                .verbose_tail
                .push_back(line(0, Tone::Neutral, "  │ log 0"));
            state
                .verbose_tail
                .push_back(line(1, Tone::Neutral, "  │ log 1"));
        }
        reporter.refresh();
        let rows = painted_rows(&reporter);
        assert!(rows > 0);
        buffer.lock().unwrap().clear();

        reporter.clear_verbose_output();

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert_eq!(
            rendered.matches("\x1b[2K").count(),
            rows,
            "an empty frame must erase every drawn row: {rendered:?}"
        );
        assert!(!rendered.contains("log 1"));
    }

    #[test]
    fn a_resize_before_a_permanent_line_still_repaints_the_snapshot() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((6usize, 100usize))));
        let reporter = reporter_with_viewport(&buffer, &viewport);
        let hosts = (0..20)
            .map(|index| format!("host-{index}"))
            .collect::<Vec<_>>();
        push_host_dashboard_span(&reporter, &hosts);
        reporter.refresh();
        buffer.lock().unwrap().clear();

        *viewport.lock().unwrap() = Some((8, 100));
        // `message` clears the region for its permanent line before redrawing;
        // the resize must survive that clear so the snapshot still repaints.
        reporter.message("hello");

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            rendered.contains("\x1b[2J\x1b[H"),
            "resize must wipe the screen: {rendered:?}"
        );
        assert!(
            rendered.contains("hello"),
            "the permanent line must be written: {rendered:?}"
        );
        assert!(
            rendered.contains("host-19"),
            "the snapshot must repaint after the resize: {rendered:?}"
        );
    }

    #[test]
    fn a_resize_repaints_a_scrolling_snapshot_even_while_throttled() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((6usize, 100usize))));
        let reporter = reporter_with_viewport(&buffer, &viewport);
        let hosts = (0..20)
            .map(|index| format!("host-{index}"))
            .collect::<Vec<_>>();
        push_host_dashboard_span(&reporter, &hosts);
        // More hosts than rows forces the append-only scrolling snapshot path.
        reporter.refresh();
        assert!(
            reporter
                .state
                .lock()
                .unwrap()
                .scrolling_snapshot_at
                .is_some()
        );
        buffer.lock().unwrap().clear();

        *viewport.lock().unwrap() = Some((8, 100));
        reporter.refresh();

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            rendered.contains("\x1b[2J\x1b[H"),
            "resize must wipe the screen: {rendered:?}"
        );
        assert!(
            rendered.contains("host-19"),
            "the snapshot must repaint after the wipe: {rendered:?}"
        );
    }

    #[test]
    fn verbose_tail_lines_are_truncated_to_one_terminal_row() {
        let mut state = ProgressState::default();
        state.stack.push(ActiveProgress {
            id: 1,
            label: "Build systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: None,
            started: Instant::now(),
        });
        state.verbose_active = true;
        state.verbose_tail.push_back(line(
            0,
            Tone::Neutral,
            &format!("  │ [build via pvl-x2 pvl-l5 err] {}", "x".repeat(200)),
        ));

        let lines = live_region_lines(
            TerminalStyle::from_capabilities(false, false),
            Some("keys: v: verbose · ctrl-c: cancel"),
            None,
            &state,
            Some((24, 40)),
            true,
        )
        .expect("active span renders a region");
        // A wrapped line would occupy an uncounted second row and survive a
        // hide, so every region line must fit the terminal width exactly.
        for line in &lines {
            assert!(
                line.chars().count() <= 40,
                "line stays on one row: {} chars: {line:?}",
                line.chars().count()
            );
        }
    }

    #[test]
    fn realistic_host_dashboard_region_fits_and_stays_one_row_per_line() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::BufferWithViewport(
                Arc::clone(&buffer),
                Arc::new(Mutex::new(Some((24, 80)))),
            ),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };
        let hosts = (0..8)
            .map(|index| format!("host-{index}"))
            .collect::<Vec<_>>();
        reporter.started("Deploy systems");
        reporter.begin_host_dashboard(&hosts);
        for (index, host) in hosts.iter().enumerate() {
            let key = format!("k{index}");
            reporter.host_task_started(host, &key, "deploy", None);
            reporter.host_task_output(host, &key, format!("    │ [build] {}", "x".repeat(200)));
        }
        {
            let mut state = reporter.state.lock().unwrap();
            state.verbose_active = true;
            for index in 0..40 {
                state.verbose_tail.push_back(line(
                    index,
                    Tone::Neutral,
                    &format!("  │ [build via host-0 host-7 err] {}", "y".repeat(200)),
                ));
            }
        }
        let state = reporter.state.lock().unwrap();
        let lines = live_region_lines(
            TerminalStyle::from_capabilities(false, false),
            Some("keys: v: verbose · ctrl-c: cancel"),
            None,
            &state,
            Some((24, 80)),
            true,
        )
        .expect("active span renders a region");
        assert!(lines.len() < 24, "region rows {} must fit", lines.len());
        for line in &lines {
            assert!(
                line.chars().count() <= 80,
                "line exceeds width ({} chars): {line:?}",
                line.chars().count()
            );
        }
    }

    #[test]
    fn live_region_is_content_sized_and_grows_without_reserving_space() {
        let style = TerminalStyle::from_capabilities(false, false);
        let mut state = ProgressState::default();
        state.stack.push(ActiveProgress {
            id: 1,
            label: "Deploy systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: None,
            started: Instant::now(),
        });
        let small = live_region_lines(style, Some("keys"), None, &state, Some((24, 80)), true)
            .expect("active span renders a region");
        // No reserved rows: the region is content-sized and starts at the
        // cursor rather than being padded to the bottom of the screen.
        assert!(small.len() < 5, "region should be compact: {}", small.len());
        assert!(
            !small.first().expect("non-empty").is_empty(),
            "no leading blank padding"
        );
        state.verbose_active = true;
        for index in 0..100 {
            state
                .verbose_tail
                .push_back(line(index, Tone::Neutral, &format!("line {index}")));
        }
        let large = live_region_lines(style, Some("keys"), None, &state, Some((24, 80)), true)
            .expect("active span renders a region");
        assert!(large.len() > small.len(), "region grows with the tail");
        assert!(large.len() < 24, "region still fits the viewport");
    }

    #[test]
    fn styled_dashboard_bolds_only_the_phase_title() {
        let mut updates = VecDeque::new();
        push_recent_update(
            &mut updates,
            10,
            "build-gap3".to_owned(),
            "✓ build plan gap3-gondor · task elapsed 1m 04s".to_owned(),
            Tone::Success,
        );
        let active = ActiveProgress {
            id: 1,
            label: "Build systems · 11 hosts".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: updates,
            host_dashboard: None,
            started: Instant::now(),
        };
        let lines = dashboard_lines(
            TerminalStyle::from_capabilities(true, false),
            &active,
            Duration::from_secs(111),
        );

        assert_eq!(
            lines,
            vec![
                "\x1b[1m● Build systems · 11 hosts\x1b[0m \x1b[2m· elapsed 1m 51s\x1b[0m",
                "  \x1b[32m✓ build plan gap3-gondor · task elapsed 1m 04s\x1b[0m",
            ]
        );
        assert_eq!(lines.join("\n").matches("\x1b[1m").count(), 1);
    }

    #[test]
    fn recent_updates_are_keyed_and_bounded() {
        let mut updates = VecDeque::new();
        for index in 0..11 {
            push_recent_update(
                &mut updates,
                10,
                format!("task-{index}"),
                format!("task {index}"),
                Tone::Muted,
            );
        }
        assert_eq!(updates.len(), 10);
        assert_eq!(updates.front().unwrap().key, "task-1");

        push_recent_update(
            &mut updates,
            10,
            "task-5".to_owned(),
            "task 5 complete".to_owned(),
            Tone::Success,
        );
        assert_eq!(updates.len(), 10);
        assert_eq!(updates.back().unwrap().key, "task-5");
        assert_eq!(updates.back().unwrap().text, "task 5 complete");
    }

    #[test]
    fn task_output_keeps_and_renders_up_to_five_lines() {
        set_json_output(false);
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::new(Mutex::new(Vec::new()))),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.started("Deploy systems · 1 host");
        reporter.task_started("activation-app", "Activation app");
        for line in ["one", "two", "three", "four"] {
            reporter.task_output("activation-app", "Activation app", line);
            reporter.task_live_output("activation-app", "Activation app", line);
        }
        reporter.task_finished(
            "activation-app",
            "Activation app",
            Duration::from_secs(2),
            false,
        );

        let state = reporter.state.lock().unwrap();
        let update = state.stack.last().unwrap().recent_updates.back().unwrap();
        assert_eq!(
            update.output.iter().map(String::as_str).collect::<Vec<_>>(),
            ["one", "two", "three", "four"]
        );
        let lines = dashboard_lines(
            TerminalStyle::from_capabilities(false, false),
            state.stack.last().unwrap(),
            Duration::from_secs(2),
        );
        assert!(lines.iter().any(|line| line == "    three"), "{lines:?}");
        assert!(lines.iter().any(|line| line == "    four"), "{lines:?}");
        assert!(lines.iter().any(|line| line == "    two"), "{lines:?}");
    }

    fn age_host_task(reporter: &ProgressReporter, host: &str, seconds: u64) {
        let mut state = reporter.state.lock().unwrap();
        let row = state
            .stack
            .last_mut()
            .unwrap()
            .host_dashboard
            .as_mut()
            .unwrap()
            .rows
            .get_mut(host)
            .unwrap();
        let started = Instant::now() - Duration::from_secs(seconds);
        row.task_started = Some(started);
        row.timing.since = Some(started);
    }

    #[test]
    fn host_dashboard_shows_schedule_full_inventory_and_bounded_failure_tail() {
        set_json_output(false);
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::new(Mutex::new(Vec::new()))),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };
        let hosts = (1..=11)
            .map(|index| format!("host-{index}"))
            .collect::<Vec<_>>();

        reporter.started("Deploy systems · 11 hosts");
        reporter.begin_host_dashboard(&hosts);
        reporter.host_schedule("activate", Some((2, 3)), 4);
        reporter.phase_admission(0, 4, true, None);
        reporter.host_task_started("host-1", "activation-host-1", "Activation", None);
        for index in 0..6 {
            reporter.host_task_output("host-1", "activation-host-1", format!("line-{index}"));
        }
        reporter.host_task_finished(
            "host-1",
            "activation-host-1",
            "Activation",
            "activation done",
            Duration::from_secs(2),
            false,
        );
        reporter.host_task_started("host-1", "rollback-host-1", "Rollback", None);
        reporter.host_task_output("host-1", "rollback-host-1", "rollback completed".to_owned());
        reporter.host_task_finished(
            "host-1",
            "rollback-host-1",
            "Rollback",
            "rollback done",
            Duration::from_secs(1),
            true,
        );
        reporter.host_finished("host-1", false, None, "activation failed");
        reporter.host_task_started("host-2", "activation-host-2", "Activation", None);
        reporter.host_task_output(
            "host-2",
            "activation-host-2",
            "temporary success output".to_owned(),
        );
        reporter.host_finished("host-2", true, None, "deployed");

        let state = reporter.state.lock().unwrap();
        let lines = dashboard_lines(
            TerminalStyle::from_capabilities(false, false),
            state.stack.last().unwrap(),
            Duration::from_secs(3),
        );
        let rendered = lines.join("\n");
        assert!(rendered.contains("stage activate · wave 2/3 · 0 running · limit 4"));
        assert!(
            hosts.iter().all(|host| rendered.contains(host)),
            "{rendered}"
        );
        assert!(!rendered.contains("line-0"), "{rendered}");
        for index in 1..=5 {
            assert!(rendered.contains(&format!("line-{index}")), "{rendered}");
        }
        assert!(!rendered.contains("temporary success output"), "{rendered}");
        assert!(!rendered.contains("rollback completed"), "{rendered}");
        assert!(rendered.contains("host-2  ✓ deployed"), "{rendered}");
    }

    fn host_row(reporter: &ProgressReporter, host: &str) -> HostRow {
        reporter
            .state
            .lock()
            .unwrap()
            .stack
            .last()
            .unwrap()
            .host_dashboard
            .as_ref()
            .unwrap()
            .rows[host]
            .clone()
    }

    fn host_frame(reporter: &ProgressReporter) -> String {
        dashboard_lines(
            reporter.style,
            reporter.state.lock().unwrap().stack.last().unwrap(),
            Duration::from_secs(12),
        )
        .join("\n")
    }

    #[test]
    fn stage_counts_wait_for_host_outcomes_and_repeated_outcomes_freeze_time() {
        let reporter = interactive_reporter();
        reporter.begin_host_dashboard(&["app".to_owned()]);
        reporter.phase_admission(1, 2, true, None);
        reporter.host_task_started("app", "eval", "evaluate", None);
        age_host_task(&reporter, "app", 2);
        reporter.host_task_finished(
            "app",
            "eval",
            "evaluate",
            "evaluate done",
            Duration::from_secs(2),
            true,
        );
        let evaluated = host_row(&reporter, "app").duration().unwrap();
        assert!(host_frame(&reporter).contains("done 0/1"));
        assert!(
            host_frame(&reporter).contains("1 running · limit 2"),
            "completed substeps still occupy their admitted slot"
        );
        reporter.host_task_started("app", "build", "build", None);
        assert!(host_row(&reporter, "app").duration().unwrap() >= evaluated);
        assert!(
            host_frame(&reporter).contains(" · step "),
            "prior work makes the step time meaningful"
        );
        reporter.host_task_output("app", "build", "retryable failure".to_owned());
        reporter.host_task_finished("app", "build", "build", "build done", Duration::ZERO, false);
        assert!(host_frame(&reporter).contains("done 0/1"));
        assert_eq!(host_row(&reporter, "app").outcome, None);
        reporter.host_finished("app", false, None, "build failed");
        let finished = host_row(&reporter, "app").duration();
        assert!(host_frame(&reporter).contains("done 1/1"));
        assert!(host_frame(&reporter).contains("✗ build failed · 2.0s"));
        reporter.host_finished("app", false, Some(Duration::from_secs(900)), "duplicate");
        reporter.host_skipped("app", "duplicate skip");
        assert_eq!(host_row(&reporter, "app").duration(), finished);
        assert_eq!(
            host_row(&reporter, "app").summary.as_deref(),
            Some("build failed")
        );
        assert!(host_frame(&reporter).contains("retryable failure"));
    }

    #[test]
    fn nested_task_identity_restores_parent_timer_and_rejects_stale_completion() {
        let reporter = interactive_reporter();
        reporter.begin_host_dashboard(&["app".to_owned()]);
        reporter.host_task_started("app", "same#1", "parent", None);
        age_host_task(&reporter, "app", 8);
        let started = host_row(&reporter, "app").task_started;
        reporter.host_task_output("app", "same#1", "parent output".to_owned());
        reporter.host_task_started("app", "same#2", "child", None);
        reporter.host_task_finished(
            "app",
            "unrelated",
            "stale",
            "stale done",
            Duration::from_secs(99),
            true,
        );
        assert_eq!(
            host_row(&reporter, "app").task_key.as_deref(),
            Some("same#2")
        );
        reporter.host_task_finished("app", "same#2", "child", "child done", Duration::ZERO, true);
        let row = host_row(&reporter, "app");
        assert_eq!(row.task_key.as_deref(), Some("same#1"));
        assert_eq!(row.task_started, started);
        assert_eq!(row.output.back().map(String::as_str), Some("parent output"));
        reporter.host_task_finished(
            "app",
            "same#1",
            "parent",
            "parent done",
            Duration::from_secs(8),
            true,
        );
        let row = host_row(&reporter, "app");
        assert_eq!(format_duration(row.duration().unwrap()), "8.0s");
        assert_eq!(row.state, HostRowState::Completed);
    }

    #[test]
    fn operation_guards_cover_finalizing_and_cannot_touch_a_later_phase() {
        let reporter = interactive_reporter();
        reporter.begin_host_dashboard(&["app".to_owned()]);
        let operation = reporter.host_operation("app");
        reporter.host_task_started("app", "activation", "activation", None);
        age_host_task(&reporter, "app", 10);
        reporter.host_task_finalizing(
            "app",
            "activation",
            "activation",
            "activation done, finalizing",
            Duration::from_secs(10),
        );
        assert!(host_row(&reporter, "app").timing.since.is_some());
        reporter.host_finished("app", true, None, "deploy done");
        let elapsed = host_row(&reporter, "app").duration();
        reporter.record_fleet_phase(
            "deploy",
            "deploy done",
            "✓",
            Tone::Success,
            Duration::from_secs(10),
        );
        reporter.end_silent_phase();
        reporter.started_silent("Health");
        reporter.begin_host_dashboard(&["app".to_owned()]);
        drop(operation);
        assert_eq!(host_row(&reporter, "app").duration(), None);
        let state = reporter.state.lock().unwrap();
        assert_eq!(state.workflow.phases[0].rows[0].elapsed, elapsed);
    }

    #[test]
    fn project_roster_tracks_steps_and_does_not_leak_into_host_phases() {
        let reporter = interactive_reporter();
        reporter.begin_workflow();
        let project = "cloudflare-dns";
        let skipped = "cloudflare-apps";
        reporter.begin_project_dashboard(&[project.into(), skipped.into()], "DNS · phase 1/8");
        reporter.project_step(project, "initializing");
        assert!(host_frame(&reporter).contains("cloudflare-dns  ● initializing"));
        reporter.project_step(project, "planning");
        assert!(host_frame(&reporter).contains("cloudflare-dns  ● planning"));
        reporter.project_step(project, "applying");
        reporter.host_skipped(project, "host events must not update project rows");
        reporter.phase_admission(1, 3, true, None);
        let frame = host_frame(&reporter);
        assert!(frame.contains("● DNS · phase 1/8"), "{frame}");
        assert!(frame.contains("done 0/2 projects"), "{frame}");
        assert!(frame.contains("cloudflare-dns  ● applying"), "{frame}");
        assert!(!frame.contains(" limit "), "{frame}");
        reporter.project_finished(project, RowOutcome::Succeeded);
        reporter.project_finished(skipped, RowOutcome::Skipped);
        assert!(host_frame(&reporter).contains("done 2/2 projects · 1 skipped"));
        reporter.record_fleet_phase("dns", "dns done", "✓", Tone::Success, Duration::ZERO);
        reporter.end_silent_phase();
        reporter.started_silent("Build");
        reporter.begin_fleet_dashboard(&[project.into(), "host-only".into()], "Build · phase 3/8");
        reporter.project_finished(project, RowOutcome::Failed);
        let frame = host_frame(&reporter);
        assert!(frame.contains("● Build · phase 3/8"), "{frame}");
        assert!(frame.contains("done 0/2 ·"), "{frame}");
        assert!(frame.contains("cloudflare-dns  ○ pending"), "{frame}");
        assert!(frame.contains("host-only  ○ pending"), "{frame}");
        let rows = reporter.phase_projects("dns");
        assert_eq!(rows[0].name, project);
        assert_eq!(rows[0].outcome, Some(RowOutcome::Succeeded));
        assert!(rows[0].elapsed.is_some());
        assert_eq!(rows[1].outcome, Some(RowOutcome::Skipped));
        assert_eq!(rows[1].elapsed, None);
        assert!(reporter.host_duration_summaries(&[project]).is_empty());
    }

    #[test]
    fn project_failure_and_interruption_do_not_settle_queued_rows() {
        let reporter = interactive_reporter();
        reporter
            .begin_project_dashboard(&["failed".into(), "stopped".into(), "later".into()], "DNS");
        reporter.project_step("failed", "planning");
        reporter.project_finished("failed", RowOutcome::Failed);
        reporter.project_step("stopped", "applying");
        reporter.project_finished("stopped", RowOutcome::Interrupted);
        reporter.project_finished("stopped", RowOutcome::Succeeded);
        let frame = host_frame(&reporter);
        assert!(
            frame.contains("done 2/3 projects · 1 failed · 1 interrupted"),
            "{frame}"
        );
        assert!(frame.contains("later  ○ pending"), "{frame}");
        reporter.record_fleet_phase("dns", "dns failed", "✗", Tone::Failure, Duration::ZERO);
        let projects = reporter.phase_projects("dns");
        assert_eq!(projects[0].outcome, Some(RowOutcome::Failed));
        assert_eq!(projects[1].outcome, Some(RowOutcome::Interrupted));
        assert_eq!(projects[2].outcome, None);
        assert_eq!(projects[2].elapsed, None);
    }

    #[test]
    fn phase_history_survives_transition_and_begin_workflow_resets_context() {
        let reporter = interactive_reporter();
        reporter.begin_workflow();
        reporter.begin_host_dashboard(&["app".to_owned(), "later".to_owned()]);
        reporter.host_task_started("app", "build", "build", None);
        age_host_task(&reporter, "app", 3);
        reporter.host_finished("app", true, None, "build done");
        reporter.record_fleet_phase(
            "build",
            "build done",
            "✓",
            Tone::Success,
            Duration::from_secs(5),
        );
        reporter.host_phase_completed("Build".to_owned(), Duration::from_secs(5));
        let between = reporter.state.lock().unwrap();
        assert!(
            live_region_lines(reporter.style, None, None, &between, Some((24, 100)), true)
                .unwrap()
                .join("\n")
                .contains("✓ build done")
        );
        drop(between);
        reporter.started_silent("Acquire");
        reporter.begin_fleet_dashboard(&["app".to_owned(), "later".to_owned()], "Acquire");
        let state = reporter.state.lock().unwrap();
        let lines = live_region_lines(reporter.style, None, None, &state, Some((24, 160)), true)
            .unwrap()
            .join("\n");
        assert!(!lines.contains("source "), "{lines}");
        assert!(!lines.contains("Run · elapsed"));
        assert_eq!(lines.matches("elapsed").count(), 1);
        assert!(lines.contains("✓ build done · done 1/2 · 5.0s"), "{lines}");
        assert!(lines.contains("● Acquire"));
        assert!(lines.contains("done 0/2"));
        drop(state);
        let summary = reporter
            .host_duration_summaries(&["app", "later"])
            .into_values()
            .collect::<Vec<_>>()
            .join("\n");
        assert_eq!(summary, "b3.0s");
        reporter.end_silent_phase();
        reporter.finish_workflow();
        let state = reporter.state.lock().unwrap();
        assert!(
            live_region_lines(reporter.style, None, None, &state, Some((24, 100)), true).is_none()
        );
        drop(state);
        reporter.begin_workflow();
        assert!(reporter.state.lock().unwrap().workflow.phases.is_empty());
    }

    #[test]
    fn scheduler_snapshot_is_independent_of_steps_and_advertises_controls_only_when_active() {
        let reporter = interactive_reporter();
        reporter.begin_host_dashboard(&["app".to_owned()]);
        reporter.host_schedule("build", None, 4);
        reporter.host_task_started("app", "build", "build", None);
        assert!(!host_frame(&reporter).contains("1 running · limit 4"));
        reporter.phase_admission(3, 2, true, Some("domain limit"));
        let frame = host_frame(&reporter);
        assert!(
            frame.contains("3 running · limit 2 · domain limit"),
            "{frame}"
        );
        assert!(
            !frame.contains("draining"),
            "renderer must not infer scheduler policy"
        );
        reporter.phase_admission(3, 2, true, Some("draining"));
        assert_eq!(host_frame(&reporter).matches("draining").count(), 1);
        assert!(!footer_hints(reporter.style, false, false, "cancel", None, None).contains("+/-"));
        assert!(
            footer_hints(reporter.style, false, true, "cancel", None, None)
                .contains("+/-: concurrency")
        );
        assert!(!footer_hints(reporter.style, true, true, "cancel", None, None).contains("t: "));
        assert!(
            footer_hints(reporter.style, true, true, "force exit", Some(30), None)
                .ends_with("ctrl-c: force exit")
        );
    }

    #[test]
    fn redirected_fleet_rows_share_accounting_without_terminal_frames() {
        let reporter = interactive_reporter();
        reporter.begin_workflow();
        let key_reader = reporter.clone();
        let reporter = reporter.without_terminal();
        reporter.begin_host_dashboard(&["app".to_owned()]);
        reporter.host_task_started("app", "build", "build", None);
        age_host_task(&reporter, "app", 4);
        reporter.host_task_finished(
            "app",
            "build",
            "build",
            "build done",
            Duration::from_secs(4),
            true,
        );
        reporter.host_finished("app", true, None, "build done");
        reporter.record_fleet_phase(
            "build",
            "build done",
            "✓",
            Tone::Success,
            Duration::from_secs(4),
        );
        assert_eq!(reporter.host_duration_summaries(&["app"])["app"], "b4.0s");
        key_reader.refresh();
        let _keys = key_reader.concurrency_handler(|_| true);
        let ProgressDestination::Buffer(buffer) = &reporter.destination else {
            panic!("test buffer")
        };
        let output = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(!output.contains('\u{1b}'), "{output:?}");
    }

    #[test]
    fn completed_host_task_uses_a_clear_finalizing_state() {
        set_json_output(false);
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::new(Mutex::new(Vec::new()))),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.started("Deploy systems · 1 host");
        reporter.begin_host_dashboard(&["app".to_owned()]);
        reporter.host_task_started("app", "activation-app", "Activation observe app", None);
        reporter.host_task_output(
            "app",
            "activation-app",
            "starting the following units: app.service".to_owned(),
        );
        age_host_task(&reporter, "app", 11);
        reporter.host_task_finalizing(
            "app",
            "activation-app",
            "activation observe",
            "activation done, finalizing",
            Duration::from_secs(11),
        );

        let state = reporter.state.lock().unwrap();
        let rendered = dashboard_lines(
            TerminalStyle::from_capabilities(false, false),
            state.stack.last().unwrap(),
            Duration::from_secs(12),
        )
        .join("\n");
        assert!(
            rendered.contains("app  ○ activation done, finalizing · 11.0s"),
            "{rendered}"
        );
        assert!(!rendered.contains("activation observe"), "{rendered}");
        assert!(
            !rendered.contains("starting the following units"),
            "{rendered}"
        );
    }

    #[test]
    fn terminal_host_success_retains_the_stage_total() {
        set_json_output(false);
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::new(Mutex::new(Vec::new()))),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.started("Deploy systems · 1 host");
        reporter.begin_host_dashboard(&["app".to_owned()]);
        reporter.host_task_started("app", "activation-app", "Activation observe app", None);
        age_host_task(&reporter, "app", 11);
        reporter.host_task_finalizing(
            "app",
            "activation-app",
            "activation observe",
            "activation done, finalizing",
            Duration::from_secs(11),
        );
        reporter.host_finished("app", true, None, "deploy done");

        let state = reporter.state.lock().unwrap();
        let rendered = dashboard_lines(
            TerminalStyle::from_capabilities(false, false),
            state.stack.last().unwrap(),
            Duration::from_secs(12),
        )
        .join("\n");
        assert!(
            rendered.contains("app  ✓ deploy done · 11.0s"),
            "{rendered}"
        );
    }

    #[test]
    fn completed_host_task_renders_the_done_label() {
        set_json_output(false);
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::new(Mutex::new(Vec::new()))),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.started("Build systems · 1 host");
        reporter.begin_host_dashboard(&["app".to_owned()]);
        reporter.host_task_started("app", "build-app", "build", None);
        reporter.host_task_output("app", "build-app", "[build] compiling".to_owned());
        age_host_task(&reporter, "app", 3);
        reporter.host_task_finished(
            "app",
            "build-app",
            "build",
            "build done",
            Duration::from_secs(3),
            true,
        );

        let state = reporter.state.lock().unwrap();
        let rendered = dashboard_lines(
            TerminalStyle::from_capabilities(false, false),
            state.stack.last().unwrap(),
            Duration::from_secs(3),
        )
        .join("\n");
        assert!(rendered.contains("app  ○ build done · 3.0s"), "{rendered}");
        assert!(!rendered.contains("compiling"), "{rendered}");
    }

    #[test]
    fn unconfirmed_remote_task_keeps_evidence_and_resists_terminal_overwrite() {
        set_json_output(false);
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::new(Mutex::new(Vec::new()))),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };
        reporter.started("Build systems");
        reporter.begin_host_dashboard(&["app".to_owned()]);
        reporter.host_task_started("app", "build-app", "build", None);
        reporter.host_task_output("app", "build-app", "last remote observation".to_owned());
        reporter.host_task_unconfirmed("app", "build-app", "build", Duration::from_secs(3));
        reporter.host_unconfirmed("app", "remote build unconfirmed; may still be running");
        reporter.host_finished("app", false, None, "failed");
        reporter.host_finished("app", true, None, "done");
        reporter.host_skipped("app", "not started");

        let state = reporter.state.lock().unwrap();
        let dashboard = state.stack.last().unwrap();
        let row = &dashboard.host_dashboard.as_ref().unwrap().rows["app"];
        assert_eq!(row.state, HostRowState::Unconfirmed);
        let rendered = dashboard_lines(
            TerminalStyle::from_capabilities(false, false),
            dashboard,
            Duration::from_secs(3),
        )
        .join("\n");
        assert!(
            rendered.contains("? remote build unconfirmed; may still be running"),
            "{rendered}"
        );
        assert!(rendered.contains("last remote observation"), "{rendered}");
        assert!(!rendered.contains("✗"), "{rendered}");
    }

    #[test]
    fn interrupted_host_task_gets_its_own_state_and_tail() {
        set_json_output(false);
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::new(Mutex::new(Vec::new()))),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.started("Deploy systems · 1 host");
        reporter.begin_host_dashboard(&["app".to_owned()]);
        reporter.host_task_started("app", "activation-app", "activation observe", None);
        reporter.host_task_output("app", "activation-app", "stopping app.service".to_owned());
        age_host_task(&reporter, "app", 4);
        reporter.host_task_interrupted(
            "app",
            "activation-app",
            "activation observe",
            Duration::from_secs(4),
        );

        let state = reporter.state.lock().unwrap();
        let rendered = dashboard_lines(
            TerminalStyle::from_capabilities(false, false),
            state.stack.last().unwrap(),
            Duration::from_secs(4),
        )
        .join("\n");
        assert!(rendered.contains("app  ⊘ interrupted · 4.0s"), "{rendered}");
        assert!(rendered.contains("stopping app.service"), "{rendered}");
    }

    #[test]
    fn host_level_interruption_keeps_its_state_and_tail() {
        set_json_output(false);
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::new(Mutex::new(Vec::new()))),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.started("Verify deployment health · 1 host");
        reporter.begin_host_dashboard(&["app".to_owned()]);
        reporter.host_task_started("app", "health-check-app", "health check", None);
        reporter.host_task_output(
            "app",
            "health-check-app",
            "[health-check] attempt 1 · settling".to_owned(),
        );
        reporter.host_task_interrupted(
            "app",
            "health-check-app",
            "health check",
            Duration::from_secs(2),
        );
        // A later host-level failure must not overwrite the interruption.
        reporter.host_finished("app", false, None, "health probe failed");
        // Neither must a later skip (for example an optional host).
        reporter.host_skipped("app", "optional snapshot unavailable");

        let state = reporter.state.lock().unwrap();
        let row = &state
            .stack
            .last()
            .unwrap()
            .host_dashboard
            .as_ref()
            .unwrap()
            .rows["app"];
        assert_eq!(row.state, HostRowState::Interrupted);
        assert_eq!(row.summary, None);
        let rendered = dashboard_lines(
            TerminalStyle::from_capabilities(false, false),
            state.stack.last().unwrap(),
            Duration::from_secs(2),
        )
        .join("\n");
        assert!(rendered.contains("app  ⊘ interrupted"), "{rendered}");
        assert!(rendered.contains("[health-check] attempt 1"), "{rendered}");
    }

    #[test]
    fn quiet_running_heartbeat_pulses_and_warns_when_overdue() {
        set_json_output(false);
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::new(Mutex::new(Vec::new()))),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.started("Build systems · 1 host");
        reporter.begin_host_dashboard(&["app".to_owned()]);
        reporter.host_task_started("app", "build-app", "build", Some(Duration::from_secs(30)));
        reporter.host_task_output("app", "build-app", "compiling".to_owned());

        let render = |secs: u64| {
            dashboard_lines(
                TerminalStyle::from_capabilities(false, false),
                reporter.state.lock().unwrap().stack.last().unwrap(),
                Duration::from_secs(secs),
            )
            .join("\n")
        };

        // Active output keeps the live row steady on both pulse ticks.
        assert!(render(4).contains("app  ● build · "));
        assert!(render(5).contains("app  ● build · "));

        // Quiet past the pulse window: the live heartbeat blinks.
        {
            let mut state = reporter.state.lock().unwrap();
            let row = state
                .stack
                .last_mut()
                .unwrap()
                .host_dashboard
                .as_mut()
                .unwrap()
                .rows
                .get_mut("app")
                .unwrap();
            row.last_output = Some(Instant::now() - Duration::from_secs(10));
        }
        assert!(render(4).contains("app  ● build · "));
        assert!(render(5).contains("app  ○ build · "));

        // Past twice the interval with no beat: warned and explained.
        {
            let mut state = reporter.state.lock().unwrap();
            let row = state
                .stack
                .last_mut()
                .unwrap()
                .host_dashboard
                .as_mut()
                .unwrap()
                .rows
                .get_mut("app")
                .unwrap();
            row.task_started = Some(Instant::now() - Duration::from_secs(70));
        }
        let stalled = render(6);
        assert!(stalled.contains("app  ● build · "), "{stalled}");
        assert!(stalled.contains("no heartbeat"), "{stalled}");
    }

    #[test]
    fn host_dashboard_header_collapses_redundant_counts() {
        let started = Instant::now();
        let hosts = (1..=11)
            .map(|index| format!("host-{index}"))
            .collect::<Vec<_>>();
        let mut dashboard = HostDashboard {
            order: hosts.clone(),
            stage: Some("build".to_owned()),
            wave: Some((1, 1)),
            concurrency: 1,
            admission: Some(AdmissionDisplay {
                running: 1,
                target: 1,
                constraint: None,
                adjustable: true,
                running_changed_at: None,
                target_changed_at: None,
            }),
            ..HostDashboard::default()
        };
        for host in &hosts {
            dashboard.rows.insert(host.clone(), HostRow::default());
        }
        let row = dashboard.rows.get_mut("host-1").unwrap();
        row.state = HostRowState::Running;
        row.task = Some("build via abird-gondor-ci".to_owned());
        row.task_started = Some(started);
        let active = ActiveProgress {
            id: 1,
            label: "Build systems · 11 hosts · phase 1/5".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: Some(dashboard),
            started,
        };
        let lines = dashboard_lines(
            TerminalStyle::from_capabilities(false, false),
            &active,
            Duration::from_secs(245),
        );
        assert_eq!(lines[0], "● Build systems · 11 hosts · phase 1/5");
        assert_eq!(
            lines[1],
            "  1 running · limit 1 · done 0/11 · elapsed 4m 05s"
        );

        let narrow = dashboard_lines_with_viewport(
            TerminalStyle::from_capabilities(false, false),
            &active,
            Duration::from_secs(245),
            Some((24, 44)),
        );
        assert_eq!(narrow[0], "● Build systems · 11 hosts · phase 1/5");
        assert_eq!(narrow[1], "  1 running · limit 1 · done 0/11");
        assert_eq!(narrow[2], "  elapsed 4m 05s");
        assert!(narrow.iter().all(|line| line.chars().count() <= 44));
    }

    #[test]
    fn host_dashboard_bounds_parallel_tails_to_the_terminal_viewport() {
        let hosts = (1..=11)
            .map(|index| format!("host-{index}"))
            .collect::<Vec<_>>();
        let mut dashboard = HostDashboard {
            order: hosts.clone(),
            stage: Some("activate".to_owned()),
            wave: Some((1, 2)),
            concurrency: 11,
            admission: Some(AdmissionDisplay {
                running: 11,
                target: 11,
                constraint: None,
                adjustable: true,
                running_changed_at: None,
                target_changed_at: None,
            }),
            ..HostDashboard::default()
        };
        for host in &hosts {
            let row = dashboard.rows.entry(host.clone()).or_default();
            row.state = HostRowState::Running;
            row.task = Some("Activation".to_owned());
            row.task_started = Some(Instant::now());
            row.output = (0..6)
                .map(|index| format!("{host} log line {index} that stays bounded"))
                .collect();
        }
        let active = ActiveProgress {
            id: 1,
            label: "Deploy systems · 11 hosts".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: Some(dashboard),
            started: Instant::now(),
        };
        let lines = dashboard_lines_with_viewport(
            TerminalStyle::from_capabilities(false, false),
            &active,
            Duration::from_secs(3),
            Some((24, 80)),
        );
        let rendered = lines.join("\n");
        assert!(lines.len() <= 23, "{} lines", lines.len());
        assert!(lines.iter().all(|line| line.chars().count() <= 80));
        assert!(hosts.iter().all(|host| rendered.contains(host)));
        assert!(rendered.contains("wave 1/2"));
        assert!(rendered.contains("11 running · limit 11"));
    }

    #[test]
    fn scrolling_snapshots_are_rate_limited_and_narrow_rows_do_not_wrap() {
        let started = Instant::now();
        let mut state = ProgressState::default();
        assert!(claim_scrolling_snapshot(&mut state, started));
        assert!(!claim_scrolling_snapshot(
            &mut state,
            started + Duration::from_secs(1)
        ));
        assert!(claim_scrolling_snapshot(
            &mut state,
            started + SCROLLING_SNAPSHOT_INTERVAL
        ));

        let host = "host-with-a-very-long-name".to_owned();
        let mut row = HostRow {
            state: HostRowState::Failed,
            summary: Some("a long failure summary that must be truncated".to_owned()),
            ..HostRow::default()
        };
        row.output
            .push_back("a long retained failure line".to_owned());
        let active = ActiveProgress {
            id: 1,
            label: "Deploy systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: Some(HostDashboard {
                order: vec![host.clone()],
                rows: BTreeMap::from([(host, row)]),
                ..HostDashboard::default()
            }),
            started,
        };
        let lines = dashboard_lines_with_viewport(
            TerminalStyle::from_capabilities(false, false),
            &active,
            Duration::from_secs(1),
            Some((24, 12)),
        );
        assert!(
            lines.iter().all(|line| line.chars().count() <= 12),
            "{lines:?}"
        );
    }

    #[test]
    fn host_dashboard_keeps_generic_probe_status_before_hosts_start() {
        let mut updates = VecDeque::new();
        push_recent_update(
            &mut updates,
            10,
            "build-plan-probe".to_owned(),
            "● Build plan probe · running".to_owned(),
            Tone::Active,
        );
        updates
            .back_mut()
            .unwrap()
            .output
            .push_back("[build] probing native plan attributes".to_owned());
        let hosts = vec!["host-1".to_owned(), "host-2".to_owned()];
        let dashboard = HostDashboard {
            order: hosts.clone(),
            rows: hosts
                .into_iter()
                .map(|host| (host, HostRow::default()))
                .collect(),
            ..HostDashboard::default()
        };
        let active = ActiveProgress {
            id: 1,
            label: "Build systems · 2 hosts".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: updates,
            host_dashboard: Some(dashboard),
            started: Instant::now(),
        };
        let rendered = dashboard_lines_with_viewport(
            TerminalStyle::from_capabilities(false, false),
            &active,
            Duration::from_secs(1),
            Some((24, 80)),
        )
        .join("\n");
        assert!(rendered.contains("Build plan probe"), "{rendered}");
        assert!(rendered.contains("probing native plan"), "{rendered}");
    }

    #[test]
    fn phase_failure_preserves_recent_failed_command_output() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.started("Deploy systems · 1 host");
        reporter.task_started("activation-app", "Activation app");
        reporter.task_output("activation-app", "Activation app", "switch failed");
        reporter.task_finished(
            "activation-app",
            "Activation app",
            Duration::from_secs(2),
            false,
        );
        reporter.fail_active("Deploy systems · elapsed 2.0s", "fleet deploy failed");

        let output = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(output.contains("Recent command output:"), "{output:?}");
        assert!(
            output.contains("Activation app · task elapsed 2.0s"),
            "{output:?}"
        );
        assert!(output.contains("switch failed"), "{output:?}");
    }

    #[test]
    fn redirected_phase_failure_preserves_early_failed_task_output() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: false,
            recent_update_limit: 0,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.started("Build systems · 20 hosts");
        reporter.task_started("build-early", "Build early");
        reporter.task_output("build-early", "Build early", "connection closed");
        reporter.task_finished("build-early", "Build early", Duration::from_secs(1), false);
        for index in 0..20 {
            let key = format!("build-{index}");
            reporter.task_started(&key, format!("Build {index}"));
            reporter.task_output(&key, format!("Build {index}"), "later output");
            reporter.task_finished(&key, format!("Build {index}"), Duration::ZERO, true);
        }
        reporter.fail_active("Build systems · 2.0s", "fleet build failed");

        let output = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(output.contains("Recent command output:"), "{output:?}");
        assert!(
            output.contains("Build early · task elapsed 1.0s"),
            "{output:?}"
        );
        assert!(output.contains("connection closed"), "{output:?}");
    }

    #[test]
    fn detached_task_scope_preserves_github_failure_output() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: false,
            recent_update_limit: 0,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.begin_task_scope();
        reporter.task_started("activation-app", "Activation app");
        reporter.task_output("activation-app", "Activation app", "connection closed");
        reporter.task_finished(
            "activation-app",
            "Activation app",
            Duration::from_secs(2),
            false,
        );
        reporter.report_failure_output();

        let output = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(output.contains("Recent command output:"), "{output:?}");
        assert!(
            output.contains("Activation app · task elapsed 2.0s"),
            "{output:?}"
        );
        assert!(output.contains("connection closed"), "{output:?}");
    }

    #[test]
    fn dashboard_labels_phase_and_task_elapsed_time_separately() {
        let mut updates = VecDeque::new();
        push_recent_update(
            &mut updates,
            10,
            "build-gap3".to_owned(),
            "✓ build plan gap3-gondor · task elapsed 1m 04s".to_owned(),
            Tone::Success,
        );
        let active = ActiveProgress {
            id: 1,
            label: "Build systems · 11 hosts".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: updates,
            host_dashboard: None,
            started: Instant::now(),
        };
        assert_eq!(
            dashboard_lines(
                TerminalStyle::from_capabilities(false, false),
                &active,
                Duration::from_secs(111),
            ),
            vec![
                "● Build systems · 11 hosts · elapsed 1m 51s",
                "  ✓ build plan gap3-gondor · task elapsed 1m 04s",
            ]
        );
    }

    #[test]
    fn skipped_tasks_use_the_neutral_nixbot_tone() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(true, false),
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.started("Build systems · 8 hosts");
        reporter.task_skipped("build-gap3", "build plan gap3-gondor");

        let output = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            output.contains("\x1b[90m◇ build plan gap3-gondor · skipped\x1b[0m"),
            "{output:?}"
        );
        assert!(!output.contains("✗ build plan gap3-gondor"), "{output:?}");
    }

    #[test]
    fn completed_outcomes_color_only_primary_work_and_keep_metadata_gray() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: false,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(true, false),
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        assert_eq!(
            styled_outcome_line(
                reporter.style,
                "✓",
                Tone::Success,
                "Build systems · 8 hosts · phase 1/5 · elapsed 2m 45s",
            ),
            concat!(
                "\x1b[32m✓ Build systems\x1b[0m",
                "\x1b[90m · 8 hosts · phase 1/5 · elapsed 2m 45s\x1b[0m",
            )
        );
        reporter.message_primary_with_metadata(
            "  ",
            Tone::Success,
            "Build systems",
            " · ok · 2m 45s",
        );
        reporter.message_primary_with_metadata("  ", Tone::Neutral, "gap3-gondor · skip", "");

        assert_eq!(
            String::from_utf8(buffer.lock().unwrap().clone()).unwrap(),
            concat!(
                "  \x1b[32mBuild systems\x1b[0m",
                "\x1b[90m · ok · 2m 45s\x1b[0m\n",
                "  \x1b[90mgap3-gondor · skip\x1b[0m\n",
            )
        );
    }

    #[test]
    fn final_host_summary_uses_identity_color_compact_segments_and_muted_timing() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let style = TerminalStyle::from_capabilities(true, false);
        let reporter = ProgressReporter {
            enabled: true,
            interactive: false,
            recent_update_limit: 10,
            style,
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.message_host_summary(
            "gap3-gondor",
            [(Tone::Success, "acquired"), (Tone::Failure, "fail deploy")],
            Some("b2.8s s327ms a23s d11s"),
            false,
        );
        reporter.message_host_summary(
            "abird-gondor-data",
            [(Tone::Success, "built"), (Tone::Muted, "skip deploy")],
            Some("b48s s900ms"),
            true,
        );

        let output = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            output.contains(&style.paint_host("gap3-gondor")),
            "{output:?}"
        );
        assert!(output.contains("\x1b[32macquired\x1b[0m, \x1b[31mfail deploy\x1b[0m"));
        assert!(output.contains("\x1b[2m[b2.8s s327ms a23s d11s]\x1b[0m"));
        assert!(
            output.contains(&style.paint_host_muted("abird-gondor-data")),
            "{output:?}"
        );
        assert!(output.contains("\x1b[2mbuilt\x1b[0m, \x1b[2mskip deploy\x1b[0m"));
        assert!(output.contains("\x1b[2m[b48s s900ms]\x1b[0m"));
    }

    #[test]
    fn host_dashboard_mutes_skips_and_uses_success_only_for_primary_status() {
        let active = ActiveProgress {
            id: 1,
            label: "Deploy systems · 3 hosts".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: Some(HostDashboard {
                order: vec![
                    "app".to_owned(),
                    "external".to_owned(),
                    "blocked".to_owned(),
                ],
                rows: BTreeMap::from([
                    (
                        "app".to_owned(),
                        HostRow {
                            state: HostRowState::Succeeded,
                            summary: Some("deployed".to_owned()),
                            timing: {
                                let mut timing = HostTiming::default();
                                timing.observed = true;
                                timing.total = Duration::from_secs(12);
                                timing
                            },
                            ..HostRow::default()
                        },
                    ),
                    (
                        "external".to_owned(),
                        HostRow {
                            state: HostRowState::Skipped,
                            summary: Some("deployment skipped".to_owned()),
                            ..HostRow::default()
                        },
                    ),
                    (
                        "blocked".to_owned(),
                        HostRow {
                            state: HostRowState::Warning,
                            outcome: Some(RowOutcome::Skipped),
                            summary: Some("deploy blocked".to_owned()),
                            ..HostRow::default()
                        },
                    ),
                ]),
                ..HostDashboard::default()
            }),
            started: Instant::now(),
        };

        let rendered = dashboard_lines(
            TerminalStyle::from_capabilities(true, false),
            &active,
            Duration::from_secs(12),
        )
        .join("\n");
        assert!(
            rendered.contains("\x1b[32m✓ deployed\x1b[0m\x1b[90m · 12.0s\x1b[0m"),
            "{rendered:?}"
        );
        let style = TerminalStyle::from_capabilities(true, false);
        assert!(
            rendered.contains(&style.paint_host_muted("external")),
            "{rendered:?}"
        );
        assert!(
            rendered.contains("\x1b[2m◇ deployment skipped\x1b[0m"),
            "{rendered:?}"
        );
        assert!(!rendered.contains("\x1b[33m◇ deployment skipped"));
        assert!(
            rendered.contains(&style.paint_host("blocked")),
            "{rendered:?}"
        );
        assert!(rendered.contains("\x1b[33m◇ deploy blocked\x1b[0m"));
        assert!(!rendered.contains(&style.paint_host_muted("blocked")));
    }

    #[test]
    fn interactive_sequence_clears_only_for_permanent_output() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: true,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.started("Build systems · 11 hosts");
        reporter.task_started("build-gap3", "build plan gap3-gondor");
        reporter.task_finished(
            "build-gap3",
            "build plan gap3-gondor",
            Duration::from_secs(64),
            true,
        );
        reporter.message("Checking builder routes");
        reporter.completed("Build systems · 11 hosts", Duration::from_secs(111));

        let output = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        let clear_two_lines = "\r\x1b[2K\x1b[1A\r\x1b[2K";
        assert_eq!(
            output.matches(clear_two_lines).count(),
            2,
            "only the permanent message and completion clear the live region: {output:?}"
        );
        assert!(
            output.contains("\n  ✓ build plan gap3-gondor · task elapsed 1m 04s"),
            "{output:?}"
        );
        let after_message = output
            .split_once("Checking builder routes\n")
            .map(|(_, rest)| rest)
            .expect("message should be followed by the redrawn dashboard");
        assert!(
            after_message.starts_with("● Build systems · 11 hosts · elapsed "),
            "{output:?}"
        );
        assert!(
            after_message.contains("\n  ✓ build plan gap3-gondor · task elapsed 1m 04s"),
            "{output:?}"
        );
        assert!(
            output.ends_with(&format!(
                "✓ Build systems · 11 hosts · elapsed 1m 51s\n{SHOW_CURSOR}{END_SYNCHRONIZED_UPDATE}"
            )),
            "{output:?}"
        );
        assert!(
            !output.contains("task elapsed 1m 04s · 1m 51s elapsed"),
            "{output:?}"
        );
    }

    #[test]
    fn recent_window_preserves_redirected_line_output() {
        set_json_output(false);
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = ProgressReporter {
            enabled: true,
            interactive: false,
            recent_update_limit: 10,
            style: TerminalStyle::from_capabilities(false, false),
            destination: ProgressDestination::Buffer(Arc::clone(&buffer)),
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };

        reporter.started("Build systems · 11 hosts");
        reporter.task_started("build-gap3", "build plan gap3-gondor");
        reporter.task_finished(
            "build-gap3",
            "build plan gap3-gondor",
            Duration::from_secs(64),
            true,
        );
        reporter.completed("Build systems · 11 hosts", Duration::from_secs(111));

        assert_eq!(
            String::from_utf8(buffer.lock().unwrap().clone()).unwrap(),
            concat!(
                "● Build systems · 11 hosts\n",
                "  build plan gap3-gondor · running\n",
                "✓ Build systems · 11 hosts  1m 51s\n",
            )
        );
    }

    /// A reporter with one active span and an in-memory destination, so a test
    /// can inspect exactly what a frame painted without a heartbeat thread.
    fn reporter_over(destination: ProgressDestination, interactive: bool) -> ProgressReporter {
        set_json_output(false);
        let reporter = ProgressReporter {
            enabled: true,
            interactive,
            recent_update_limit: 0,
            style: TerminalStyle::from_capabilities(false, false),
            destination,
            state: Arc::new(Mutex::new(ProgressState::default())),
            output: Arc::new(Mutex::new(())),
        };
        reporter.state.lock().unwrap().stack.push(ActiveProgress {
            id: 1,
            label: "Deploy systems".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: None,
            started: Instant::now(),
        });
        reporter
    }

    /// Minimal VT rows for the rewrite primitives; synchronized output is not
    /// needed for correctness. LF includes the tty's ordinary ONLCR behavior.
    struct RewriteScreen {
        rows: Vec<Vec<char>>,
        row: usize,
        column: usize,
    }

    impl RewriteScreen {
        fn feed(&mut self, text: &str) {
            let mut chars = text.chars();
            while let Some(ch) = chars.next() {
                match ch {
                    '\x1b' => {
                        assert_eq!(chars.next(), Some('['));
                        let mut parameter = String::new();
                        loop {
                            let ch = chars.next().expect("complete CSI");
                            if ch.is_ascii_digit() {
                                parameter.push(ch);
                                continue;
                            }
                            let n = parameter.parse::<usize>().unwrap_or(1);
                            match ch {
                                'A' => {
                                    self.row = self.row.checked_sub(n).expect("cursor above screen")
                                }
                                'B' => {
                                    self.row += n;
                                    assert!(self.row < self.rows.len());
                                }
                                'K' => {
                                    assert!(parameter.is_empty());
                                    self.rows[self.row].truncate(self.column);
                                }
                                _ => panic!("unexpected rewrite CSI {parameter}{ch}"),
                            }
                            break;
                        }
                    }
                    '\r' => self.column = 0,
                    '\n' => {
                        self.column = 0;
                        if self.row + 1 == self.rows.len() {
                            self.rows.remove(0);
                            self.rows.push(Vec::new());
                        } else {
                            self.row += 1;
                        }
                    }
                    ch => {
                        let row = &mut self.rows[self.row];
                        if row.len() <= self.column {
                            row.resize(self.column + 1, ' ');
                        }
                        row[self.column] = ch;
                        self.column += 1;
                    }
                }
            }
        }
    }

    #[test]
    fn changed_rows_match_full_frames_across_growth_shrink_and_bottom_scroll() {
        for origin in [1, 18] {
            for old_len in 1..8 {
                for new_len in 1..8 {
                    for pattern in 0..4 {
                        let previous = (0..old_len)
                            .map(|i| format!("row-{i}-long-label"))
                            .collect::<Vec<_>>();
                        let lines = (0..new_len)
                            .map(|i| match pattern {
                                1 if i % 2 == 0 => "short".to_owned(),
                                2 => format!("row-{}-long-label", i + 1),
                                3 if i % 2 == 0 => String::new(),
                                _ => format!("row-{i}-long-label"),
                            })
                            .collect::<Vec<_>>();
                        let mut screen = RewriteScreen {
                            rows: vec![Vec::new(); 20],
                            row: origin,
                            column: 0,
                        };
                        screen.rows[0] = "committed output".chars().collect();
                        screen.feed(&previous.join("\n"));
                        let buffer = Arc::new(Mutex::new(Vec::new()));
                        let destination = ProgressDestination::Buffer(Arc::clone(&buffer));
                        rewrite_lines(
                            &mut ProgressFrame::new(&destination, false),
                            &previous,
                            &lines,
                        );
                        let delta = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
                        screen.feed(&delta);
                        let top = origin.min(20 - old_len.max(new_len));
                        assert_eq!(screen.row, top + new_len - 1, "cursor: {delta:?}");
                        for (i, line) in lines.iter().enumerate() {
                            assert_eq!(
                                screen.rows[top + i].iter().collect::<String>(),
                                *line,
                                "row {i}: {delta:?}"
                            );
                        }
                        for row in &screen.rows[top + new_len..] {
                            assert!(row.is_empty(), "stale rows: {delta:?}");
                        }
                        if origin == 1 {
                            assert_eq!(
                                screen.rows[0].iter().collect::<String>(),
                                "committed output"
                            );
                        }
                        if previous == lines {
                            assert!(delta.is_empty());
                        }
                        assert!(!delta.contains("\x1b[2K"));
                        assert!(!delta.contains("\x1b[2J"));
                    }
                }
            }
        }
    }

    #[test]
    fn phase_and_verbose_streams_share_the_host_tail_budget() {
        let frames = Arc::new(Mutex::new(Vec::new()));
        let reporter = reporter_over(
            ProgressDestination::Frames(Arc::clone(&frames), Arc::new(Mutex::new(Some((56, 149))))),
            true,
        )
        .with_recent_updates(12);
        reporter.refresh();
        frames.lock().unwrap().clear();
        reporter.state.lock().unwrap().stream_redraw_at =
            Some(Instant::now() + Duration::from_secs(60));
        for i in 0..1000 {
            reporter.task_live_output("build-plan", "build plan", format!("phase-line-{i}"));
            reporter.verbose_line(Tone::Neutral, format!("verbose-line-{i}"));
        }
        assert!(frames.lock().unwrap().is_empty());
        // Lifecycle and operator updates bypass the stream budget and flush it.
        reporter.message("lifecycle transition");
        let frames = frames.lock().unwrap();
        assert_eq!(frames.len(), 1);
        assert!(frames[0].contains("phase-line-999"));
        assert!(frames[0].contains("verbose-line-999"));
        assert!(frames[0].contains("lifecycle transition"));
    }

    #[test]
    fn unchanged_dashboard_refresh_writes_nothing() {
        let frames = Arc::new(Mutex::new(Vec::new()));
        let reporter = reporter_over(
            ProgressDestination::Frames(Arc::clone(&frames), Arc::new(Mutex::new(Some((56, 149))))),
            true,
        );
        reporter
            .state
            .lock()
            .unwrap()
            .stack
            .last_mut()
            .unwrap()
            .started = Instant::now() + Duration::from_secs(60);
        reporter.refresh();
        frames.lock().unwrap().clear();
        reporter.refresh();
        assert!(
            frames.lock().unwrap().is_empty(),
            "identical frames must not repaint"
        );
    }

    #[test]
    fn host_update_rewrites_only_the_changed_row_without_blank_clear() {
        let frames = Arc::new(Mutex::new(Vec::new()));
        let reporter = reporter_over(
            ProgressDestination::Frames(Arc::clone(&frames), Arc::new(Mutex::new(Some((56, 149))))),
            true,
        )
        .with_recent_updates(12);
        reporter.begin_host_dashboard(&["active-host".to_owned(), "untouched-host".to_owned()]);
        reporter.host_task_started("active-host", "build-active", "build", None);
        reporter.host_task_started("untouched-host", "build-other", "build", None);
        {
            let mut state = reporter.state.lock().unwrap();
            let active = state.stack.last_mut().unwrap();
            active.started = Instant::now() + Duration::from_secs(60);
            for row in active.host_dashboard.as_mut().unwrap().rows.values_mut() {
                row.task_started = Some(active.started);
            }
        }
        reporter.refresh();
        frames.lock().unwrap().clear();
        reporter.host_task_heartbeat("active-host", "build-active", "build newer derivation");
        let frames = frames.lock().unwrap();
        assert_eq!(frames.len(), 1);
        assert!(frames[0].contains("newer derivation"));
        assert!(
            !frames[0].contains("untouched-host"),
            "unchanged rows must stay on screen"
        );
        assert!(
            !frames[0].contains("\x1b[2K"),
            "overwrite before erasing stale suffixes"
        );
    }

    #[test]
    fn build_output_burst_shares_the_verbose_redraw_budget() {
        let frames = Arc::new(Mutex::new(Vec::new()));
        let reporter = reporter_over(
            ProgressDestination::Frames(Arc::clone(&frames), Arc::new(Mutex::new(Some((56, 149))))),
            true,
        )
        .with_recent_updates(12);
        let hosts = (0..12).map(|i| format!("host-{i}")).collect::<Vec<_>>();
        reporter.begin_host_dashboard(&hosts);
        reporter.host_task_started("host-0", "build-0", "build", None);
        frames.lock().unwrap().clear();
        // Pin a claimed interval: burst size, not machine speed, determines this test.
        reporter.state.lock().unwrap().stream_redraw_at =
            Some(Instant::now() + Duration::from_secs(60));
        for i in 0..1000 {
            reporter.host_task_output("host-0", "build-0", format!("building derivation-{i}"));
        }
        let writes = frames.lock().unwrap();
        eprintln!(
            "burst: {} writes, {} bytes",
            writes.len(),
            writes.iter().map(String::len).sum::<usize>()
        );
        assert!(
            writes.is_empty(),
            "host output bypassed the stream redraw budget: {} writes",
            writes.len()
        );
        drop(writes);
        reporter.refresh();
        let writes = frames.lock().unwrap();
        assert_eq!(writes.len(), 1);
        assert!(
            writes[0].contains("derivation-999"),
            "coalescing must retain the newest output"
        );
    }

    #[test]
    fn live_cursor_is_hidden_until_the_region_finishes() {
        let frames = Arc::new(Mutex::new(Vec::new()));
        let reporter = reporter_over(
            ProgressDestination::Frames(Arc::clone(&frames), Arc::new(Mutex::new(Some((56, 149))))),
            true,
        );
        reporter.refresh();
        let initial = frames.lock().unwrap().pop().unwrap();
        assert!(
            initial.contains("\x1b[?25l"),
            "the live cursor must be hidden"
        );
        assert!(!initial.contains("\x1b[?25h"));

        reporter.message("permanent message above the active region");
        let message = frames.lock().unwrap().pop().unwrap();
        assert!(
            !message.contains("\x1b[?25h"),
            "a message does not release the live region"
        );

        reporter.completed("Deploy systems", Duration::from_secs(1));
        let complete = frames.lock().unwrap().pop().unwrap();
        assert!(
            complete.contains("\x1b[?25h"),
            "completion must restore the cursor"
        );
        assert!(complete.rfind("\x1b[?25h") > complete.rfind("\x1b[?25l"));
        reporter.refresh();
        assert!(
            frames.lock().unwrap().is_empty(),
            "empty refresh must not hide it again"
        );
    }

    #[test]
    fn changed_dashboard_row_is_one_synchronized_frame() {
        let frames = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((60, 120))));
        let reporter = reporter_over(
            ProgressDestination::Frames(Arc::clone(&frames), viewport),
            true,
        );
        reporter.refresh();
        frames.lock().unwrap().clear();
        reporter
            .state
            .lock()
            .unwrap()
            .stack
            .last_mut()
            .unwrap()
            .detail = Some("new status".to_owned());
        reporter.refresh();
        let frames = frames.lock().unwrap();
        assert_eq!(frames.len(), 1, "one changed frame: {frames:?}");
        assert!(!frames[0].contains("\x1b[2K"));
        assert!(frames[0].contains("new status"));
        assert!(frames[0].contains("Deploy systems"));
        assert!(frames[0].starts_with(BEGIN_SYNCHRONIZED_UPDATE));
        assert!(frames[0].ends_with(END_SYNCHRONIZED_UPDATE));
    }

    #[test]
    fn permanent_messages_and_live_tails_share_one_synchronized_frame() {
        let frames = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((60, 120))));
        let reporter = reporter_over(
            ProgressDestination::Frames(Arc::clone(&frames), viewport),
            true,
        )
        .with_recent_updates(12);
        let hosts = (0..12)
            .map(|index| format!("host-{index}"))
            .collect::<Vec<_>>();
        reporter.begin_host_dashboard(&hosts);
        reporter.host_task_started("host-0", "build-0", "build", None);
        reporter.host_task_output("host-0", "build-0", "building a closure".to_owned());
        frames.lock().unwrap().clear();

        reporter.message("Checking builder routes");
        let frames = frames.lock().unwrap();
        assert_eq!(frames.len(), 1, "{frames:?}");
        let frame = &frames[0];
        assert_eq!(frame.matches(BEGIN_SYNCHRONIZED_UPDATE).count(), 1);
        assert_eq!(frame.matches(END_SYNCHRONIZED_UPDATE).count(), 1);
        assert!(frame.starts_with(BEGIN_SYNCHRONIZED_UPDATE));
        assert!(frame.ends_with(END_SYNCHRONIZED_UPDATE));
        assert!(frame.contains("Checking builder routes\n"));
        assert!(frame.contains("building a closure"));
        for host in hosts {
            assert!(frame.contains(&host), "{frame:?}");
        }
    }

    #[test]
    fn resize_and_snapshot_redraws_are_batched_without_empty_frames() {
        let frames = Arc::new(Mutex::new(Vec::new()));
        let viewport = Arc::new(Mutex::new(Some((1, 40))));
        let reporter = reporter_over(
            ProgressDestination::Frames(Arc::clone(&frames), Arc::clone(&viewport)),
            true,
        );
        reporter.refresh();
        let initial = frames.lock().unwrap().pop().unwrap();
        assert!(initial.starts_with(BEGIN_SYNCHRONIZED_UPDATE));
        assert!(initial.ends_with(&format!("\n{END_SYNCHRONIZED_UPDATE}")));
        reporter.refresh();
        assert!(
            frames.lock().unwrap().is_empty(),
            "throttled snapshot must not write"
        );

        *viewport.lock().unwrap() = Some((30, 80));
        reporter.refresh();
        let frames = frames.lock().unwrap();
        assert_eq!(frames.len(), 1);
        assert!(frames[0].starts_with(&format!(
            "{BEGIN_SYNCHRONIZED_UPDATE}{HIDE_CURSOR}\x1b[2J\x1b[H"
        )));
        assert!(frames[0].contains("Deploy systems"));
        assert!(frames[0].ends_with(END_SYNCHRONIZED_UPDATE));
    }

    #[test]
    fn redirected_output_is_immediate_and_unframed() {
        let frames = Arc::new(Mutex::new(Vec::new()));
        let destination =
            ProgressDestination::Frames(Arc::clone(&frames), Arc::new(Mutex::new(None)));
        let mut frame = ProgressFrame::new(&destination, false);
        frame.write("first\n");
        assert_eq!(*frames.lock().unwrap(), ["first\n"]);
        frame.write("second\n");
        drop(frame);
        assert_eq!(*frames.lock().unwrap(), ["first\n", "second\n"]);
    }

    #[test]
    fn unwinding_does_not_publish_a_partial_frame() {
        let frames = Arc::new(Mutex::new(Vec::new()));
        let destination =
            ProgressDestination::Frames(Arc::clone(&frames), Arc::new(Mutex::new(None)));
        let result = std::panic::catch_unwind(|| {
            let mut frame = ProgressFrame::new(&destination, true);
            frame.write("\r\x1b[2K");
            panic!("interrupted frame construction");
        });
        assert!(result.is_err());
        assert!(frames.lock().unwrap().is_empty());
    }

    #[test]
    fn releasing_an_in_place_live_region_ends_the_line_once() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = reporter_over(ProgressDestination::Buffer(Arc::clone(&buffer)), true);
        reporter.refresh();

        let painted = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            !painted.ends_with('\n'),
            "an in-place frame leaves the cursor on its last row: {painted:?}"
        );

        assert!(reporter.release_live_region(true));
        let released = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            released.ends_with(&format!("\r\n{SHOW_CURSOR}")),
            "release must move the cursor to a fresh line: {released:?}"
        );

        assert!(!reporter.release_live_region(true));
        assert_eq!(
            String::from_utf8(buffer.lock().unwrap().clone()).unwrap(),
            released,
            "a second release writes nothing"
        );
    }

    #[test]
    fn releasing_a_snapshot_live_region_adds_no_extra_newline() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        // One row forces the append-only snapshot path, whose frame already
        // ends with a newline.
        let viewport = Arc::new(Mutex::new(Some((1_usize, 40_usize))));
        let reporter = reporter_over(
            ProgressDestination::BufferWithViewport(Arc::clone(&buffer), viewport),
            true,
        );
        reporter.refresh();

        let painted = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            painted
                .strip_suffix(END_SYNCHRONIZED_UPDATE)
                .is_some_and(|frame| frame.ends_with('\n') && !frame.ends_with("\r\n")),
            "a snapshot frame already ends the line: {painted:?}"
        );

        assert!(!reporter.release_live_region(true));
        let released = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert_eq!(
            released,
            format!("{painted}{SHOW_CURSOR}"),
            "a snapshot release restores the cursor without adding a newline"
        );
        assert!(!reporter.release_live_region(true));
        assert_eq!(
            String::from_utf8(buffer.lock().unwrap().clone()).unwrap(),
            released,
            "a second snapshot release writes nothing"
        );
    }

    #[test]
    fn releasing_a_non_interactive_region_is_a_no_op() {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let reporter = reporter_over(ProgressDestination::Buffer(Arc::clone(&buffer)), false);
        reporter.refresh();

        assert!(!reporter.release_live_region(true));
        assert!(
            buffer.lock().unwrap().is_empty(),
            "non-interactive output is append-only and never released"
        );
    }
}
