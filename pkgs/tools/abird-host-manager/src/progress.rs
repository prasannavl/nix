use std::collections::{BTreeMap, VecDeque};
use std::io::{self, IsTerminal, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use crate::Action;
use crate::terminal_style::{TerminalStyle, Tone};

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
        }
    }

    fn viewport(&self) -> Option<(usize, usize)> {
        match self {
            Self::Stderr => terminal_viewport(),
            #[cfg(test)]
            Self::Buffer(_) => None,
            #[cfg(test)]
            Self::BufferWithViewport(_, viewport) => {
                viewport.lock().ok().and_then(|viewport| *viewport)
            }
        }
    }
}

#[derive(Clone, Debug, Default)]
struct ProgressState {
    stack: Vec<ActiveProgress>,
    next_id: u64,
    next_update_id: u64,
    rendered_lines: usize,
    /// Whether the live region is currently painted on screen. A counted clear
    /// removes it; an append-only snapshot leaves its rows behind, so it stays
    /// painted until a wipe removes it.
    region_painted: bool,
    /// Last known terminal `(rows, columns)` the region was laid out for. Kept
    /// across an unknown size read, so a resize is still detected once the size
    /// is readable again. A change means the terminal reflowed, so
    /// `rendered_lines` no longer locates the region and the next frame wipes
    /// the screen instead of clearing the wrong rows.
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
    /// Last live-verbose redraw, throttling high-volume streams.
    verbose_redraw_at: Option<Instant>,
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
    order: Vec<String>,
    rows: BTreeMap<String, HostRow>,
    stage: Option<String>,
    wave: Option<(usize, usize)>,
    concurrency: usize,
}

#[derive(Clone, Debug)]
struct HostRow {
    state: HostRowState,
    task_key: Option<String>,
    task: Option<String>,
    task_started: Option<Instant>,
    elapsed: Option<Duration>,
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
    fn keep_interrupted(&mut self, elapsed: Option<Duration>) -> bool {
        if self.state != HostRowState::Interrupted {
            return false;
        }
        self.task_started = None;
        if elapsed.is_some() {
            self.elapsed = elapsed;
        }
        true
    }
}

impl Default for HostRow {
    fn default() -> Self {
        Self {
            state: HostRowState::Pending,
            task_key: None,
            task: None,
            task_started: None,
            elapsed: None,
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
    Pending,
    Running,
    Completed,
    Finalizing,
    Succeeded,
    Skipped,
    Failed,
    Interrupted,
}

/// Terminal-ish outcome of a host-attributed task. Success is either a plain
/// completed stage or a finalizing activation/rollback observer; interruption
/// is a distinct terminal outcome, not a failure of the host itself.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HostTaskOutcome {
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
const VERBOSE_REDRAW_INTERVAL: Duration = Duration::from_millis(50);
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
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        if let Ok(mut state) = self.state.lock()
            && let Some(active) = state.stack.last_mut()
        {
            active.host_dashboard = Some(HostDashboard {
                order: hosts.to_vec(),
                rows: hosts
                    .iter()
                    .map(|host| (host.clone(), HostRow::default()))
                    .collect(),
                ..HostDashboard::default()
            });
        }
        self.redraw_current();
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
        if let Ok(mut state) = self.state.lock()
            && let Some(dashboard) = state
                .stack
                .last_mut()
                .and_then(|active| active.host_dashboard.as_mut())
        {
            dashboard.stage = Some(stage.into());
            dashboard.wave = wave;
            dashboard.concurrency = concurrency;
        }
        self.redraw_current();
    }

    pub fn host_task_started(
        &self,
        host: &str,
        key: &str,
        label: &str,
        heartbeat_interval: Option<Duration>,
    ) {
        self.start_task_tail(key);
        if !self.shows_recent_updates() {
            self.detail(format!("{host} · {label} · running"));
            return;
        }
        self.update_host_row(host, |row| {
            row.state = HostRowState::Running;
            row.task_key = Some(key.to_owned());
            row.task = Some(label.to_owned());
            row.task_started = Some(Instant::now());
            row.elapsed = None;
            row.summary = None;
            row.output.clear();
            row.heartbeat_interval = heartbeat_interval;
            row.last_heartbeat = None;
            row.last_output = Some(Instant::now());
        });
    }

    pub fn host_task_heartbeat(&self, host: &str, key: &str, label: &str) {
        if !self.shows_recent_updates() {
            return;
        }
        self.update_host_row(host, |row| {
            if row.task_key.as_deref() == Some(key) {
                row.task = Some(label.to_owned());
                row.last_heartbeat = Some(Instant::now());
            }
        });
    }

    pub fn host_task_output(&self, host: &str, key: &str, line: String) {
        if !self.shows_recent_updates() || line.is_empty() {
            return;
        }
        self.update_host_row(host, |row| {
            if row.task_key.as_deref() != Some(key) {
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
        if !self.shows_recent_updates() {
            let line = format!(
                "{host} · {} · {}",
                match outcome {
                    HostTaskOutcome::Done | HostTaskOutcome::Finalizing => done.to_owned(),
                    HostTaskOutcome::Failed => format!("{label} · failed"),
                    HostTaskOutcome::Interrupted => format!("{label} · interrupted"),
                },
                format_duration(elapsed)
            );
            // Interruption is a terminal outcome with no later summary of its
            // own, so it must not be rate-limited like a rolling detail line.
            if outcome == HostTaskOutcome::Interrupted {
                self.message(format!("⊘ {line}"));
            } else {
                self.detail(line);
            }
            return;
        }
        self.update_host_row(host, |row| {
            if row.task_key.as_deref() != Some(key) {
                return;
            }
            row.task = Some(done.to_owned());
            row.task_started = None;
            row.elapsed = Some(elapsed);
            match outcome {
                HostTaskOutcome::Done => {
                    row.state = HostRowState::Completed;
                    row.output.clear();
                }
                HostTaskOutcome::Finalizing => {
                    row.state = HostRowState::Finalizing;
                    row.output.clear();
                }
                HostTaskOutcome::Failed | HostTaskOutcome::Interrupted => {
                    row.state = if outcome == HostTaskOutcome::Interrupted {
                        HostRowState::Interrupted
                    } else {
                        HostRowState::Failed
                    };
                    for line in row.output.clone() {
                        if row.failure_output.back() != Some(&line) {
                            row.failure_output.push_back(line);
                        }
                        while row.failure_output.len() > RETAINED_OUTPUT_LINES_PER_TASK {
                            row.failure_output.pop_front();
                        }
                    }
                }
            }
        });
    }

    pub fn host_finished(
        &self,
        host: &str,
        succeeded: bool,
        elapsed: Option<Duration>,
        summary: impl Into<String>,
    ) {
        let summary = summary.into();
        self.update_host_row(host, |row| {
            if row.keep_interrupted(elapsed) {
                return;
            }
            row.state = if succeeded {
                HostRowState::Succeeded
            } else {
                HostRowState::Failed
            };
            // Preserve the elapsed time recorded by the host's last task when
            // the terminal outcome does not carry its own duration, so a
            // completed row still reports how long the host actually took.
            if elapsed.is_some() {
                row.elapsed = elapsed;
            }
            row.summary = (!summary.is_empty()).then_some(summary);
            row.task_started = None;
            if succeeded {
                row.output.clear();
                row.failure_output.clear();
            } else {
                row.output.clone_from(&row.failure_output);
            }
        });
    }

    pub fn host_skipped(&self, host: &str, summary: impl Into<String>) {
        let summary = summary.into();
        self.update_host_row(host, |row| {
            if row.keep_interrupted(None) {
                return;
            }
            row.state = HostRowState::Skipped;
            row.summary = (!summary.is_empty()).then_some(summary);
            row.task_started = None;
            row.output.clear();
            row.failure_output.clear();
        });
    }

    fn update_host_row(&self, host: &str, update: impl FnOnce(&mut HostRow)) {
        let _output = self.output.lock().ok();
        if let Ok(mut state) = self.state.lock()
            && let Some(dashboard) = state
                .stack
                .last_mut()
                .and_then(|active| active.host_dashboard.as_mut())
            && let Some(row) = dashboard.rows.get_mut(host)
        {
            update(row);
        }
        self.redraw_current();
    }

    pub fn end_task_scope(&self) {
        self.begin_task_scope();
    }

    pub fn phase_started(&self, transaction: &str, action: Action, items: usize) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        self.clear_line();
        let item_count = if items == 1 {
            String::new()
        } else {
            format!(" · {items} items")
        };
        let heading = format!("{} {transaction}{item_count}", action_title(action));
        self.destination.write(&format!(
            "\n{}\n\n",
            self.style.paint(Tone::Emphasis, heading)
        ));
        self.redraw_current();
    }

    pub fn phase_completed(&self, _transaction: &str, action: Action, elapsed: Duration) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        self.clear_line();
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
        self.destination.write(&format!("{line}\n\n"));
        self.redraw_current();
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
            self.redraw_current();
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
                redraw_active(&self.destination, self.style, &active, Some(&detail));
            }
        } else {
            self.destination.write(&format!("  {detail}\n"));
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
        self.finish_current();
        let failure = format!("✗ {} · {}", step_label(step), format_duration(elapsed));
        self.destination
            .write(&format!("{}\n", self.style.paint(Tone::Failure, failure)));
        self.destination.write(&format!(
            "{}\n",
            self.style
                .paint(Tone::FailureDetail, format!("  {error:#}"))
        ));
        self.redraw_current();
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
        self.redraw_current();
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
        self.redraw_current();
    }

    pub fn started(&self, label: impl Into<String>) {
        if !self.enabled() {
            return;
        }
        let label = label.into();
        let _output = self.output.lock().ok();
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
            self.redraw_current();
            if let Some(active_id) = active_id {
                self.start_heartbeat(active_id);
            }
        } else {
            self.destination.write(&format!(
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
        self.finish_current();
        let label = label.into();
        let label = if self.shows_recent_updates() {
            format!("{label} · elapsed {}", format_duration(elapsed))
        } else {
            format!("{label}  {}", format_duration(elapsed))
        };
        let line = styled_outcome_line(self.style, "✓", Tone::Success, &label);
        self.destination.write(&format!("{line}\n"));
        self.redraw_current();
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
        let recent_failures = self.recent_failure_output();
        let host_failures = self.host_failure_output();
        self.finish_current();
        let label = label.into();
        self.destination.write(&format!(
            "{}\n",
            styled_outcome_line(self.style, "✗", Tone::Failure, &label)
        ));
        for line in failure.lines() {
            self.destination.write(&format!(
                "{}\n",
                self.style.paint(Tone::FailureDetail, format!("  {line}"))
            ));
        }
        if host_failures.is_empty() && !recent_failures.is_empty() {
            self.destination.write("  Recent command output:\n");
            for (task, output) in recent_failures {
                self.destination.write(&format!("    {task}\n"));
                for line in output {
                    self.destination.write(&format!("      {line}\n"));
                }
            }
        }
        for (host, summary, output) in host_failures {
            self.destination.write(&format!(
                "  {}  {}\n",
                self.style.paint_host(&host),
                self.style.paint(Tone::Failure, format!("✗ {summary}"))
            ));
            for line in output {
                self.destination.write(&format!(
                    "    {}\n",
                    self.style.paint(Tone::FailureDetail, line)
                ));
            }
        }
        self.redraw_current();
    }

    pub fn warning_active(&self, label: impl Into<String>, warning: &str) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let host_failures = self.host_failure_output();
        self.finish_current();
        let label = label.into();
        self.destination.write(&format!(
            "{}\n",
            styled_outcome_line(self.style, "◇", Tone::Warning, &label)
        ));
        for line in warning.lines() {
            self.destination.write(&format!(
                "{}\n",
                self.style.paint(Tone::Warning, format!("  {line}"))
            ));
        }
        for (host, summary, output) in host_failures {
            self.destination.write(&format!(
                "  {}  {}\n",
                self.style.paint_host(&host),
                self.style.paint(Tone::Failure, format!("✗ {summary}"))
            ));
            for line in output {
                self.destination.write(&format!(
                    "    {}\n",
                    self.style.paint(Tone::FailureDetail, line)
                ));
            }
        }
        self.redraw_current();
    }

    pub fn report_failure_output(&self) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        let recent_failures = self.recent_failure_output();
        if !recent_failures.is_empty() {
            self.destination.write("  Recent command output:\n");
            for (task, output) in recent_failures {
                self.destination.write(&format!("    {task}\n"));
                for line in output {
                    self.destination.write(&format!("      {line}\n"));
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
                        (matches!(row.state, HostRowState::Failed | HostRowState::Interrupted))
                            .then(|| {
                                let summary = row
                                    .summary
                                    .clone()
                                    .or_else(|| row.task.clone())
                                    .unwrap_or_else(|| {
                                        if row.state == HostRowState::Interrupted {
                                            "interrupted".to_owned()
                                        } else {
                                            "failed".to_owned()
                                        }
                                    });
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
        self.finish_current();
        let label = label.into();
        self.destination.write(&format!(
            "{}\n",
            styled_outcome_line(self.style, "◇", Tone::Warning, &label)
        ));
        self.redraw_current();
    }

    pub fn message(&self, message: impl std::fmt::Display) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        self.clear_line();
        self.destination.write(&format!(
            "{}\n",
            self.style.semantic_text(&message.to_string())
        ));
        self.redraw_current();
    }

    pub fn message_tone(&self, tone: Tone, message: impl std::fmt::Display) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        self.clear_line();
        self.destination.write(&format!(
            "{}\n",
            self.style.paint(tone, message.to_string())
        ));
        self.redraw_current();
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
        // other while `rendered_lines` tracks only one; hiding then clears one
        // copy and leaves the rest on screen.
        let _output = self.output.lock().ok();
        if !self.interactive {
            self.destination
                .write(&format!("{}\n", self.style.paint(tone, message)));
            return;
        }
        let due = if let Ok(mut state) = self.state.lock() {
            state.open_verbose();
            let line = record_verbose_line(&mut state, tone, message, SystemTime::now());
            state.verbose_tail.push_back(line);
            while state.verbose_tail.len() > VERBOSE_MAX_LIVE_LINES {
                state.verbose_tail.pop_front();
            }
            if state.verbose_view == VerboseView::Run {
                hold_scrolled_window(&mut state, 1);
            }
            let now = Instant::now();
            let due = state
                .verbose_redraw_at
                .is_none_or(|last| now.duration_since(last) >= VERBOSE_REDRAW_INTERVAL);
            if due {
                state.verbose_redraw_at = Some(now);
            }
            due
        } else {
            false
        };
        if due {
            self.redraw_current();
        }
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
        let changed = self.state.lock().ok().is_some_and(|mut state| {
            let changed =
                !state.verbose_active || state.verbose_view != view || state.verbose_scroll != 0;
            state.open_verbose();
            state.verbose_view = view;
            state.verbose_scroll = 0;
            state.verbose_redraw_at = None;
            changed
        });
        if changed {
            self.redraw_current();
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
            .destination
            .viewport()
            .map_or(DEFAULT_VIEWPORT_ROWS / 2, |(rows, _)| (rows / 2).max(1));
        self.scroll_verbose(delta, page);
    }

    fn scroll_verbose(&self, delta: isize, step: usize) {
        let _output = self.output.lock().ok();
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
            self.redraw_current();
        }
    }

    /// Disable verbose streaming and drop the live tail so the next redraw
    /// shrinks the region back to just the dashboard, as if the stream had
    /// never been shown.
    pub fn clear_verbose_output(&self) {
        let _output = self.output.lock().ok();
        let changed = self.state.lock().ok().is_some_and(|mut state| {
            let changed = state.verbose_active || !state.verbose_tail.is_empty();
            state.close_verbose();
            state.verbose_tail.clear();
            state.verbose_redraw_at = None;
            changed
        });
        if changed {
            self.redraw_current();
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
            state.verbose_redraw_at = None;
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
            state.verbose_redraw_at = None;
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
        let changed = self.state.lock().ok().is_some_and(|mut state| {
            if state.verbose_active {
                return false;
            }
            state.open_verbose();
            state.verbose_redraw_at = None;
            state.verbose_scroll = 0;
            true
        });
        if changed {
            self.redraw_current();
        }
    }

    /// Re-render the live region after an out-of-band state change, such as an
    /// armed interrupt, so the footer reflects it immediately.
    pub fn refresh(&self) {
        let _output = self.output.lock().ok();
        self.redraw_current();
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
        self.clear_line();
        self.destination.write(&format!(
            "{}{}{}\n",
            prefix,
            self.style.paint(tone, primary.to_string()),
            paint_if_nonempty(self.style, Tone::Neutral, &metadata.to_string())
        ));
        self.redraw_current();
    }

    pub fn heading(&self, heading: impl std::fmt::Display) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        self.clear_line();
        self.destination.write(&format!(
            "{}\n",
            self.style.paint(Tone::Emphasis, heading.to_string())
        ));
        self.redraw_current();
    }

    pub fn document(&self, document: impl std::fmt::Display) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        self.clear_line();
        self.destination.write(&format!(
            "{}\n",
            self.style.semantic_document(&document.to_string())
        ));
        self.redraw_current();
    }

    fn finish_current(&self) {
        self.clear_line();
        if let Ok(mut state) = self.state.lock() {
            state.stack.pop();
        }
    }

    /// The terminal size to lay the next frame out for: the live size when it
    /// can be read, otherwise the last known size. Falling back to the last
    /// known size keeps a transient unknown read (a pty reporting zero while it
    /// resizes) from re-laying the region out with the stale default budget.
    fn layout_viewport(&self) -> Option<(usize, usize)> {
        self.destination.viewport().or_else(|| {
            self.state
                .lock()
                .ok()
                .and_then(|state| state.region_viewport)
        })
    }

    /// Erase the live region before repainting. `viewport` is the size the next
    /// frame is laid out for, so layout and the reset decision agree on one
    /// size. When the region was painted for a different size the terminal has
    /// reflowed, so `rendered_lines` no longer locates it: wipe the visible
    /// screen and home the cursor (scrollback survives). An unknown size is not
    /// a resize, so it neither wipes nor forgets the last known size; a known
    /// size that follows an unknown first paint is a resize.
    ///
    /// `replacing` is true when the next frame replaces the region (a counted
    /// frame or nothing at all). An append-only snapshot is taller than the
    /// screen and draws no counted rows, so a replacing clear must wipe it, not
    /// clear zero rows and leave it stranded.
    fn clear_region(&self, viewport: Option<(usize, usize)>, replacing: bool) {
        if !self.interactive {
            return;
        }
        let (rendered_lines, wipe) = self.state.lock().map_or((0, false), |mut state| {
            let resized =
                state.region_painted && viewport.is_some() && state.region_viewport != viewport;
            if viewport.is_some() {
                state.region_viewport = viewport;
            }
            let snapshot_present = state.region_painted && state.rendered_lines == 0;
            let rendered_lines = std::mem::take(&mut state.rendered_lines);
            let wipe = resized || (replacing && snapshot_present);
            if wipe || rendered_lines > 0 {
                state.region_painted = false;
                // Clearing a painted region lets the next snapshot paint at
                // once instead of waiting out the append-only throttle.
                state.scrolling_snapshot_at = None;
            }
            (rendered_lines, wipe)
        });
        if wipe {
            clear_screen(&self.destination);
        } else {
            clear_rendered_lines(&self.destination, rendered_lines);
        }
    }

    /// Clear the region for callers that write a permanent line before the next
    /// redraw. Uses the same layout size as a redraw so a resize is seen once.
    fn clear_line(&self) {
        self.clear_region(self.layout_viewport(), true);
    }

    fn redraw_current(&self) {
        if !self.interactive {
            return;
        }
        let notice = self.cancel_notice();
        // Resolve one size for layout, the footer width, and the resize reset so
        // they all describe the same frame, even if the size becomes unreadable
        // partway through.
        let viewport = self.layout_viewport();
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
        let Some(lines) = lines else {
            // Nothing left to draw: erase the previous region so an empty frame
            // never strands stale output.
            self.clear_region(viewport, true);
            return;
        };
        let appending = viewport.is_some_and(|(rows, _)| lines.len() >= rows);
        self.clear_region(viewport, !appending);
        if appending {
            // A resize dropped the throttle in `clear_region`, so a wiped screen
            // repaints here rather than waiting out the snapshot interval.
            let should_render = self
                .state
                .lock()
                .is_ok_and(|mut state| claim_scrolling_snapshot(&mut state, Instant::now()));
            if should_render {
                self.destination.write(&format!("{}\n", lines.join("\n")));
                if let Ok(mut state) = self.state.lock() {
                    state.region_painted = true;
                }
            }
        } else {
            redraw_lines(&self.destination, &lines);
            if let Ok(mut state) = self.state.lock() {
                state.rendered_lines = lines.len();
                state.scrolling_snapshot_at = None;
                state.region_painted = true;
            }
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
        let mut groups = vec![vec!["v: verbose".to_owned()]];
        if state.verbose_active {
            groups.push(vec![
                "ctrl/alt-r: run".to_owned(),
                "ctrl/alt-e: errors".to_owned(),
            ]);
        }
        groups.push(vec![format!("ctrl-c: {cancel}")]);
        let width = viewport.map(|(_, columns)| columns.saturating_sub(1));
        Some(
            self.style
                .paint(Tone::Muted, join_key_hints(&groups, width)),
        )
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
                    reporter.redraw_current();
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
fn join_key_hints(groups: &[Vec<String>], width: Option<usize>) -> String {
    let mut kept = groups.to_vec();
    loop {
        let hints = kept.iter().flatten().cloned().collect::<Vec<_>>();
        let text = format!("keys: {}", hints.join(" · "));
        if width.is_none_or(|width| text.chars().count() <= width) || kept.len() <= 1 {
            return text;
        }
        kept.remove(kept.len() - 2);
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
/// of crowding the footer.
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
    // `rendered_lines` counts rows, so a wrapped line would leave the extra
    // rows uncleared when the tail is hidden.
    let columns = viewport.map(|(_, columns)| columns);
    // Leave the final viewport row unused so a full region never scrolls.
    let room = viewport
        .map(|(rows, _)| rows.saturating_sub(1))
        .unwrap_or(DEFAULT_VIEWPORT_ROWS.saturating_sub(1));

    let mut lines = if verbose {
        // Reserve roughly half the room for the dashboard and stream the rest
        // as logs, keeping space for the blank separator and the footer.
        let stream_room = room.saturating_sub(footer_rows + 1 + header_rows);
        let dashboard_budget = (stream_room / 2).max(1);
        let dashboard_lines = match active {
            Some(active) if dashboard => dashboard_lines_with_viewport(
                style,
                active,
                active.started.elapsed(),
                viewport.map(|(_, columns)| (dashboard_budget + 1, columns)),
            ),
            Some(active) => vec![active_line(style, &active.label, active.detail.as_deref())],
            // A long wait may own no dashboard; the logs still render.
            None => Vec::new(),
        };
        // A dashboard taller than its budget (many hosts) is truncated from the
        // bottom so the tail still gets a row.
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
            dashboard_lines_with_viewport(
                style,
                active,
                active.started.elapsed(),
                viewport.map(|(rows, columns)| (rows.saturating_sub(footer_rows), columns)),
            )
        } else {
            let detail = heartbeat_detail(active.detail.as_deref(), active.started.elapsed());
            vec![active_line(style, &active.label, Some(&detail))]
        }
    } else {
        // Nothing to draw: no span and no open verbose section.
        return None;
    };

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
    // that `rendered_lines` does not count), but let the region take only the
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

#[cfg(test)]
fn dashboard_lines(
    style: TerminalStyle,
    active: &ActiveProgress,
    elapsed: Duration,
) -> Vec<String> {
    dashboard_lines_with_viewport(style, active, elapsed, None)
}

fn dashboard_lines_with_viewport(
    style: TerminalStyle,
    active: &ActiveProgress,
    elapsed: Duration,
    viewport: Option<(usize, usize)>,
) -> Vec<String> {
    if let Some(dashboard) = &active.host_dashboard {
        return host_dashboard_lines(style, active, dashboard, elapsed, viewport);
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
) -> Vec<String> {
    // The quiet-heartbeat pulse alternates once per second; the dashboard
    // redraws on the same cadence, so only silent rows visibly blink.
    let blink_on = elapsed.as_secs().is_multiple_of(2);
    let running = dashboard
        .rows
        .values()
        .filter(|row| row.state == HostRowState::Running)
        .count();
    let done = dashboard
        .rows
        .values()
        .filter(|row| {
            matches!(
                row.state,
                HostRowState::Succeeded
                    | HostRowState::Skipped
                    | HostRowState::Failed
                    | HostRowState::Interrupted
            )
        })
        .count();
    let mut metadata = Vec::new();
    if let Some(stage) = &dashboard.stage {
        metadata.push(format!("stage {stage}"));
    }
    if let Some((current, total)) = dashboard.wave
        && total > 1
    {
        metadata.push(format!("wave {current}/{total}"));
    }
    if dashboard.concurrency > 0 {
        metadata.push(format!("{running}/{} running", dashboard.concurrency));
    } else {
        metadata.push(format!("{running} running"));
    }
    metadata.push(format!("done {done}/{}", dashboard.rows.len()));
    metadata.push(format!("elapsed {}", format_duration(elapsed)));
    let max_lines = viewport
        .map(|(rows, _)| rows.saturating_sub(1).max(1))
        .unwrap_or(usize::MAX);
    let max_columns = viewport.map(|(_, columns)| columns.max(1));
    let heading = format!("● {}", active.label);
    let metadata = format!("· {}", metadata.join(" · "));
    let metadata_width = max_columns
        .map(|columns| columns.saturating_sub(heading.chars().count() + 1))
        .unwrap_or(usize::MAX);
    let heading = truncate_text(&heading, max_columns.unwrap_or(usize::MAX));
    let metadata = truncate_text(&metadata, metadata_width);
    let mut lines = vec![if metadata.is_empty() {
        style.paint(Tone::Emphasis, heading)
    } else {
        format!(
            "{} {}",
            style.paint(Tone::Emphasis, heading),
            style.paint(Tone::Muted, metadata)
        )
    }];

    let base_lines = 1 + dashboard.order.len();
    let available_detail_lines = max_lines.saturating_sub(base_lines);
    let detailed_hosts = dashboard
        .order
        .iter()
        .filter(|host| {
            dashboard.rows.get(*host).is_some_and(|row| {
                matches!(
                    row.state,
                    HostRowState::Running | HostRowState::Failed | HostRowState::Interrupted
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
    for host in &dashboard.order {
        let Some(row) = dashboard.rows.get(host) else {
            continue;
        };
        let (tone, status, metadata) = match row.state {
            HostRowState::Pending => (Tone::Muted, "○ pending".to_owned(), String::new()),
            HostRowState::Completed | HostRowState::Finalizing => (
                Tone::Muted,
                format!("○ {}", row.task.as_deref().unwrap_or("done")),
                row.elapsed
                    .map(|elapsed| format!(" · {}", format_duration(elapsed)))
                    .unwrap_or_default(),
            ),
            HostRowState::Running => {
                let elapsed = row
                    .task_started
                    .map(|started| started.elapsed())
                    .unwrap_or_default();
                let mut metadata = format!(" · task elapsed {}", format_duration(elapsed));
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
                row.elapsed
                    .map(|elapsed| format!(" · {}", format_duration(elapsed)))
                    .unwrap_or_default(),
            ),
            HostRowState::Skipped => (
                Tone::Neutral,
                format!("◇ {}", row.summary.as_deref().unwrap_or("skipped")),
                String::new(),
            ),
            HostRowState::Failed => (
                Tone::Failure,
                format!("✗ {}", row.summary.as_deref().unwrap_or("failed")),
                String::new(),
            ),
            HostRowState::Interrupted => (
                Tone::Warning,
                format!("⊘ {}", row.summary.as_deref().unwrap_or("interrupted")),
                row.elapsed
                    .map(|elapsed| format!(" · {}", format_duration(elapsed)))
                    .unwrap_or_default(),
            ),
        };
        let host_width = max_columns
            .map(|columns| columns.saturating_sub(4).min(host.chars().count()))
            .unwrap_or_else(|| host.chars().count());
        let host = truncate_text(host, host_width);
        let available_status_width = max_columns
            .map(|columns| columns.saturating_sub(host.chars().count() + 4))
            .unwrap_or(usize::MAX);
        let status = truncate_text(&status, available_status_width);
        let metadata = truncate_text(
            &metadata,
            available_status_width.saturating_sub(status.chars().count()),
        );
        lines.push(format!(
            "  {}  {}{}",
            style.paint_host(&host),
            style.paint(tone, status),
            paint_if_nonempty(style, Tone::Neutral, &metadata)
        ));
        if matches!(
            row.state,
            HostRowState::Running | HostRowState::Failed | HostRowState::Interrupted
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

fn clear_rendered_lines(destination: &ProgressDestination, lines: usize) {
    if lines == 0 {
        return;
    }
    let mut sequence = String::from("\r\x1b[2K");
    for _ in 1..lines {
        sequence.push_str("\x1b[1A\r\x1b[2K");
    }
    destination.write(&sequence);
}

/// Wipe the visible screen and home the cursor, leaving scrollback intact. Used
/// when the terminal was resized: the reflow means the previous row count no
/// longer locates the live region, so the only reliable reset is to clear the
/// screen and redraw the region from the top-left.
fn clear_screen(destination: &ProgressDestination) {
    destination.write("\x1b[2J\x1b[H");
}

/// Terminal rows one streamed line occupies, so a later hide can erase it.
fn redraw_lines(destination: &ProgressDestination, lines: &[String]) {
    destination.write(&lines.join("\n"));
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
    destination: &ProgressDestination,
    style: TerminalStyle,
    label: &str,
    detail: Option<&str>,
) {
    destination.write(&format!("\r\x1b[2K{}", active_line(style, label, detail)));
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
        let groups = vec![
            vec!["v: verbose".to_owned()],
            vec![
                "ctrl/alt-r: run".to_owned(),
                "ctrl/alt-e: errors".to_owned(),
            ],
            vec!["ctrl-c: confirm cancel".to_owned()],
        ];
        let wide = join_key_hints(&groups, Some(120));
        assert!(wide.contains("ctrl/alt-e: errors"), "{wide}");
        assert!(wide.ends_with("ctrl-c: confirm cancel"), "{wide}");

        // The view pair drops as a unit, and the interrupt label, which escalates
        // as the cancel is armed, survives intact instead of being cut mid-word.
        assert_eq!(
            join_key_hints(&groups, Some(60)),
            "keys: v: verbose · ctrl-c: confirm cancel"
        );
        assert_eq!(
            join_key_hints(&groups, Some(20)),
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

        // The hide clears the old region and redraws only the dashboard.
        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(rendered.contains("\r\x1b[2K"), "{rendered:?}");
        let final_frame = rendered.rsplit("\r\x1b[2K").next().unwrap_or("");
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
            reporter.state.lock().unwrap().verbose_redraw_at = None;
            reporter.verbose_line(Tone::Neutral, format!("  │ log {index}"));
        }
        let region = reporter.state.lock().unwrap().rendered_lines;
        assert!(region > 2, "region should hold tail + dashboard: {region}");
        assert!(region < 24, "region must fit the viewport: {region}");
        buffer.lock().unwrap().clear();

        reporter.clear_verbose_output();

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            !rendered.contains("log 39"),
            "tail not cleared: {rendered:?}"
        );
        let ups = rendered.matches("\x1b[1A").count();
        assert_eq!(ups, region - 1, "clear must cover the whole old region");
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
        assert!(state.rendered_lines > 0 && state.rendered_lines < 12);
    }

    #[test]
    fn an_unchanged_viewport_still_clears_only_the_drawn_rows() {
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
        let rendered_lines = reporter.state.lock().unwrap().rendered_lines;
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
            rendered.contains("\x1b[1A"),
            "an unchanged viewport clears the drawn rows: {rendered:?}"
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
        assert!(reporter.state.lock().unwrap().region_painted);

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
            assert!(state.region_painted);
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
            assert_eq!(state.rendered_lines, 0, "a snapshot draws no counted rows");
            assert!(state.region_painted);
        }
        buffer.lock().unwrap().clear();

        reporter.clear_line();

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            rendered.contains("\x1b[2J\x1b[H"),
            "a replacing clear must wipe the stranded snapshot: {rendered:?}"
        );
        assert!(!reporter.state.lock().unwrap().region_painted);
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
        assert!(reporter.state.lock().unwrap().rendered_lines > 0);
        buffer.lock().unwrap().clear();

        reporter.clear_verbose_output();

        let rendered = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            !rendered.contains("log 1"),
            "an empty frame must still erase the region: {rendered:?}"
        );
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
        assert!(rendered.contains("stage activate · wave 2/3 · 0/4 running"));
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
    fn terminal_host_success_retains_the_last_task_elapsed() {
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
        assert!(render(4).contains("app  ● build · task elapsed"));
        assert!(render(5).contains("app  ● build · task elapsed"));

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
        assert!(render(4).contains("app  ● build · task elapsed"));
        assert!(render(5).contains("app  ○ build · task elapsed"));

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
        assert!(stalled.contains("app  ● build · task elapsed"), "{stalled}");
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
        assert_eq!(
            lines[0],
            "● Build systems · 11 hosts · phase 1/5 · stage build · 1/1 running · done 0/11 · elapsed 4m 05s"
        );
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
        assert!(rendered.contains("11/11 running"));
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
    fn host_dashboard_uses_gray_for_skips_and_success_only_for_primary_status() {
        let active = ActiveProgress {
            id: 1,
            label: "Deploy systems · 2 hosts".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: VecDeque::new(),
            host_dashboard: Some(HostDashboard {
                order: vec!["app".to_owned(), "external".to_owned()],
                rows: BTreeMap::from([
                    (
                        "app".to_owned(),
                        HostRow {
                            state: HostRowState::Succeeded,
                            summary: Some("deployed".to_owned()),
                            elapsed: Some(Duration::from_secs(12)),
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
        assert!(
            rendered.contains("\x1b[90m◇ deployment skipped\x1b[0m"),
            "{rendered:?}"
        );
        assert!(!rendered.contains("\x1b[33m◇ deployment skipped"));
    }

    #[test]
    fn interactive_sequence_clears_and_redraws_the_whole_dashboard() {
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
        assert!(output.matches(clear_two_lines).count() >= 3, "{output:?}");
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
            output.ends_with("✓ Build systems · 11 hosts · elapsed 1m 51s\n"),
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
}
