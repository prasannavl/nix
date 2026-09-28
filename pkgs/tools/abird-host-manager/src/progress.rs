use std::collections::{BTreeMap, VecDeque};
use std::io::{self, IsTerminal, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

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
    /// Test destination that reports a fixed terminal size, so the viewport
    /// budget and in-place clearing can be exercised without a real tty.
    #[cfg(test)]
    BufferWithViewport(Arc<Mutex<Vec<u8>>>, (usize, usize)),
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
            Self::BufferWithViewport(_, viewport) => Some(*viewport),
        }
    }
}

#[derive(Clone, Debug, Default)]
struct ProgressState {
    stack: Vec<ActiveProgress>,
    next_id: u64,
    next_update_id: u64,
    rendered_lines: usize,
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
    /// Bounded live tail of verbose lines rendered above the dashboard through
    /// the same clear/redraw path as progress, newest last.
    verbose_tail: VecDeque<(Tone, String)>,
    /// Last live-verbose redraw, throttling high-volume streams.
    verbose_redraw_at: Option<Instant>,
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
const MAX_LIVE_VERBOSE_LINES: usize = 500;
/// Minimum interval between live verbose redraws, capping flicker and I/O on
/// high-volume streams; the heartbeat still renders the tail afterwards.
const VERBOSE_REDRAW_INTERVAL: Duration = Duration::from_millis(50);
/// Interactive key hints shown as the final row of the live region while a
/// span is active. Uses the same `·` separator as the dashboard metadata and
/// stays all lowercase to match the other live labels. The footer reports live
/// state: `verbose on`/`verbose off` for the toggle and `confirm cancel` while
/// an interrupt is armed.
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

    /// Record one streamed verbose child-process line in the live tail. On an
    /// interactive terminal the tail is rendered through the normal dashboard
    /// clear/redraw path, so hiding the stream wipes it cleanly instead of
    /// leaving appended output. Redirected output still appends the line.
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
            state.verbose_active = true;
            state.verbose_tail.push_back((tone, message));
            while state.verbose_tail.len() > MAX_LIVE_VERBOSE_LINES {
                state.verbose_tail.pop_front();
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

    /// Disable verbose streaming and drop the live tail so the next redraw
    /// shrinks the region back to just the dashboard, as if the stream had
    /// never been shown.
    pub fn clear_verbose_output(&self) {
        let _output = self.output.lock().ok();
        let changed = self.state.lock().ok().is_some_and(|mut state| {
            let changed = state.verbose_active || !state.verbose_tail.is_empty();
            state.verbose_active = false;
            state.verbose_tail.clear();
            state.verbose_redraw_at = None;
            changed
        });
        if changed {
            self.redraw_current();
        }
    }

    /// Mark verbose streaming shown and redraw at once, so the toggle footer
    /// flips to `verbose off` on the key press instead of waiting for the first
    /// tail line to arrive.
    pub fn show_verbose_output(&self) {
        let _output = self.output.lock().ok();
        let changed = self.state.lock().ok().is_some_and(|mut state| {
            let changed = !state.verbose_active;
            state.verbose_active = true;
            state.verbose_redraw_at = None;
            changed
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

    fn clear_line(&self) {
        if !self.interactive {
            return;
        }
        let rendered_lines = self
            .state
            .lock()
            .ok()
            .map_or(0, |mut state| std::mem::take(&mut state.rendered_lines));
        clear_rendered_lines(&self.destination, rendered_lines);
    }

    fn redraw_current(&self) {
        if !self.interactive {
            return;
        }
        self.clear_line();
        let footer = self.key_footer();
        let viewport = self.destination.viewport();
        let dashboard = self.shows_recent_updates();
        let lines = self.state.lock().ok().and_then(|state| {
            live_region_lines(self.style, footer.as_deref(), &state, viewport, dashboard)
        });
        let Some(lines) = lines else {
            return;
        };
        if viewport.is_some_and(|(rows, _)| lines.len() >= rows) {
            let should_render = self
                .state
                .lock()
                .is_ok_and(|mut state| claim_scrolling_snapshot(&mut state, Instant::now()));
            if should_render {
                self.destination.write(&format!("{}\n", lines.join("\n")));
            }
        } else {
            redraw_lines(&self.destination, &lines);
            if let Ok(mut state) = self.state.lock() {
                state.rendered_lines = lines.len();
                state.scrolling_snapshot_at = None;
            }
        }
    }

    /// Interactive key hints rendered as the final live-region row. `None` when
    /// the reporter is not on a terminal or no key reader owns stdin. The `v`
    /// action reflects the live toggle state, read from the shared key handle,
    /// so the footer flips the moment the key is pressed.
    fn key_footer(&self) -> Option<String> {
        if !self.interactive || !crate::fleet::interactive::keys_available() {
            return None;
        }
        let verbose_on = crate::fleet::interactive::verbose_handle(false).load(Ordering::Relaxed);
        let verbose = if verbose_on { "on" } else { "off" };
        let cancel = if crate::fleet::signal::runtime().is_some_and(|runtime| runtime.pending()) {
            "confirm cancel"
        } else {
            "cancel"
        };
        let text = format!("keys: v: verbose {verbose} · ctrl-c: {cancel} · ctrl-c x3: force exit");
        let text = match self.destination.viewport() {
            Some((_, columns)) => truncate_text(&text, columns),
            None => text,
        };
        Some(self.style.paint(Tone::Muted, text))
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

/// Build the live, overwriteable region for the current span: the verbose tail
/// (when active), a blank separator, the dashboard, and the key footer. The
/// result always fits inside the viewport so the region is cleared in place
/// instead of scrolling, which is what lets hiding the verbose stream wipe it
/// cleanly. Returns `None` when no span is active.
fn live_region_lines(
    style: TerminalStyle,
    footer: Option<&str>,
    state: &ProgressState,
    viewport: Option<(usize, usize)>,
    dashboard: bool,
) -> Option<Vec<String>> {
    let active = state.stack.last()?;
    // A blank separator row plus the footer row.
    let footer_rows = if footer.is_some() { 2 } else { 0 };
    let verbose = state.verbose_active && !state.verbose_tail.is_empty();
    // Terminal columns, used to keep every region line on exactly one row:
    // `rendered_lines` counts rows, so a wrapped line would leave the extra
    // rows uncleared when the tail is hidden.
    let columns = viewport.map(|(_, columns)| columns);
    // Leave the final viewport row unused so a full region never scrolls.
    let room = viewport.map_or(usize::MAX, |(rows, _)| rows.saturating_sub(1));

    let mut lines = if verbose {
        // Reserve roughly half the room for the dashboard and stream the rest
        // as logs, keeping space for the blank separator and the footer.
        let stream_room = room.saturating_sub(footer_rows + 1);
        let dashboard_budget = (stream_room / 2).max(1);
        let dashboard_lines = if dashboard {
            dashboard_lines_with_viewport(
                style,
                active,
                active.started.elapsed(),
                viewport.map(|(_, columns)| (dashboard_budget + 1, columns)),
            )
        } else {
            vec![active_line(style, &active.label, active.detail.as_deref())]
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
        let start = state.verbose_tail.len().saturating_sub(tail_budget);
        let mut streamed: Vec<String> = state
            .verbose_tail
            .range(start..)
            .map(|(tone, text)| {
                let text = match columns {
                    Some(columns) => truncate_text(text, columns),
                    None => text.clone(),
                };
                style.paint(*tone, text)
            })
            .collect();
        if streamed.is_empty() {
            dashboard_lines
        } else {
            streamed.push(String::new());
            streamed.extend(dashboard_lines);
            streamed
        }
    } else if dashboard {
        dashboard_lines_with_viewport(
            style,
            active,
            active.started.elapsed(),
            viewport.map(|(rows, columns)| (rows.saturating_sub(footer_rows), columns)),
        )
    } else {
        let detail = heartbeat_detail(active.detail.as_deref(), active.started.elapsed());
        vec![active_line(style, &active.label, Some(&detail))]
    };

    if let Some(footer) = footer {
        // Keep one blank row between the dashboard and the footer so the keys
        // read as chrome rather than another host row.
        lines.push(String::new());
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
                .push_back((Tone::Neutral, format!("log line {index}")));
        }

        let style = TerminalStyle::from_capabilities(false, false);
        let lines = live_region_lines(style, Some("keys"), &state, Some((24, 80)), true)
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
            destination: ProgressDestination::BufferWithViewport(Arc::clone(&buffer), (24, 100)),
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
        state.verbose_tail.push_back((
            Tone::Neutral,
            format!("  │ [build via pvl-x2 pvl-l5 err] {}", "x".repeat(200)),
        ));

        let lines = live_region_lines(
            TerminalStyle::from_capabilities(false, false),
            Some("keys: v: verbose off"),
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
            destination: ProgressDestination::BufferWithViewport(Arc::clone(&buffer), (24, 80)),
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
            for _index in 0..40 {
                state.verbose_tail.push_back((
                    Tone::Neutral,
                    format!("  │ [build via host-0 host-7 err] {}", "y".repeat(200)),
                ));
            }
        }
        let state = reporter.state.lock().unwrap();
        let lines = live_region_lines(
            TerminalStyle::from_capabilities(false, false),
            Some("keys: v: verbose on"),
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
        let small = live_region_lines(style, Some("keys"), &state, Some((24, 80)), true)
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
                .push_back((Tone::Neutral, format!("line {index}")));
        }
        let large = live_region_lines(style, Some("keys"), &state, Some((24, 80)), true)
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
