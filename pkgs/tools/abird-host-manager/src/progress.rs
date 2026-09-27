use std::collections::VecDeque;
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
            Self::Buffer(buffer) => {
                if let Ok(mut buffer) = buffer.lock() {
                    buffer.extend_from_slice(text.as_bytes());
                }
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
    task_tails: VecDeque<TaskTail>,
    failed_task_tails: VecDeque<FailedTaskTail>,
}

#[derive(Clone, Debug)]
struct ActiveProgress {
    id: u64,
    label: String,
    detail: Option<String>,
    detail_emitted_at: Option<Instant>,
    recent_updates: VecDeque<RecentUpdate>,
    started: Instant,
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

const LIVE_OUTPUT_LINES_PER_TASK: usize = 2;
const RETAINED_OUTPUT_LINES_PER_TASK: usize = 3;
const RETAINED_ACTIVE_TASK_TAILS: usize = 128;
const RETAINED_FAILED_TASK_TAILS: usize = 8;

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
        self
    }

    pub fn shows_recent_updates(&self) -> bool {
        self.interactive && self.recent_update_limit > 0
    }

    pub fn begin_task_scope(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.task_tails.clear();
            state.failed_task_tails.clear();
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
        let line = format!(
            "✓ {} complete · {}",
            action_title(action),
            format_duration(elapsed)
        );
        self.destination
            .write(&format!("{}\n\n", self.style.semantic_line(&line, false)));
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
            self.message(line);
            return;
        }
        self.update_task(key, line, Tone::Warning);
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
                "◇ {label} · interrupted · task elapsed {}",
                format_duration(elapsed)
            )
        } else {
            format!("◇ {label} · interrupted · {}", format_duration(elapsed))
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
                started: Instant::now(),
            });
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
        let line = if self.shows_recent_updates() {
            format!(
                "✓ {} · phase elapsed {}",
                label.into(),
                format_duration(elapsed)
            )
        } else {
            format!("✓ {}  {}", label.into(), format_duration(elapsed))
        };
        self.destination
            .write(&format!("{}\n", self.style.semantic_line(&line, false)));
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
        self.finish_current();
        self.destination.write(&format!(
            "{}\n",
            self.style
                .paint(Tone::Failure, format!("✗ {}", label.into()))
        ));
        for line in failure.lines() {
            self.destination.write(&format!(
                "{}\n",
                self.style.paint(Tone::FailureDetail, format!("  {line}"))
            ));
        }
        if !recent_failures.is_empty() {
            self.destination.write("  Recent command output:\n");
            for (task, output) in recent_failures {
                self.destination.write(&format!("    {task}\n"));
                for line in output {
                    self.destination.write(&format!("      {line}\n"));
                }
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

    pub fn interrupt_active(&self, label: impl Into<String>) {
        if !self.enabled() {
            return;
        }
        let _output = self.output.lock().ok();
        self.finish_current();
        self.destination.write(&format!(
            "{}\n",
            self.style
                .paint(Tone::Warning, format!("◇ {}", label.into()))
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
        if self.shows_recent_updates() {
            let lines = self.state.lock().ok().and_then(|state| {
                state
                    .stack
                    .last()
                    .map(|active| dashboard_lines(self.style, active, active.started.elapsed()))
            });
            if let Some(lines) = lines {
                redraw_lines(&self.destination, &lines);
                if let Ok(mut state) = self.state.lock() {
                    state.rendered_lines = lines.len();
                }
            }
        } else {
            let current = self.state.lock().ok().and_then(|state| {
                state
                    .stack
                    .last()
                    .map(|active| (active.label.clone(), active.detail.clone()))
            });
            if let Some((label, detail)) = current {
                redraw_active(&self.destination, self.style, &label, detail.as_deref());
                if let Ok(mut state) = self.state.lock() {
                    state.rendered_lines = 1;
                }
            }
        }
    }

    fn start_heartbeat(&self, active_id: u64) {
        let state = Arc::downgrade(&self.state);
        let output = Arc::downgrade(&self.output);
        let style = self.style;
        let destination = self.destination.clone();
        let recent_update_limit = self.recent_update_limit;
        thread::spawn(move || {
            loop {
                thread::sleep(Duration::from_secs(1));
                let (Some(state), Some(output)) = (state.upgrade(), output.upgrade()) else {
                    return;
                };
                let _output = output.lock().ok();
                let snapshot = state.lock().ok().and_then(|state| {
                    if !state.stack.iter().any(|active| active.id == active_id) {
                        return None;
                    }
                    state.stack.last().and_then(|active| {
                        (active.id == active_id).then(|| {
                            (
                                active.label.clone(),
                                active.detail.clone(),
                                active.started.elapsed(),
                            )
                        })
                    })
                });
                let Some((label, detail, elapsed)) = snapshot else {
                    if state
                        .lock()
                        .is_ok_and(|state| !state.stack.iter().any(|active| active.id == active_id))
                    {
                        return;
                    }
                    continue;
                };
                if recent_update_limit > 0 {
                    let lines = state.lock().ok().and_then(|state| {
                        state
                            .stack
                            .last()
                            .map(|active| dashboard_lines(style, active, elapsed))
                    });
                    if let Some(lines) = lines {
                        let rendered_lines = state
                            .lock()
                            .ok()
                            .map_or(0, |mut state| std::mem::take(&mut state.rendered_lines));
                        clear_rendered_lines(&destination, rendered_lines);
                        redraw_lines(&destination, &lines);
                        if let Ok(mut state) = state.lock() {
                            state.rendered_lines = lines.len();
                        }
                    }
                } else {
                    let detail = heartbeat_detail(detail.as_deref(), elapsed);
                    redraw_active(&destination, style, &label, Some(&detail));
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

fn dashboard_lines(
    style: TerminalStyle,
    active: &ActiveProgress,
    elapsed: Duration,
) -> Vec<String> {
    let mut lines = vec![format!(
        "{} {}",
        style.paint(Tone::Emphasis, format!("● {}", active.label)),
        style.paint(
            Tone::Muted,
            format!("· phase elapsed {}", format_duration(elapsed))
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

fn redraw_lines(destination: &ProgressDestination, lines: &[String]) {
    destination.write(&lines.join("\n"));
}

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
    fn styled_dashboard_bolds_only_the_phase_title() {
        let mut updates = VecDeque::new();
        push_recent_update(
            &mut updates,
            10,
            "build-gap3".to_owned(),
            "✓ Build plan gap3 gondor · task elapsed 1m 04s".to_owned(),
            Tone::Success,
        );
        let active = ActiveProgress {
            id: 1,
            label: "Build systems · 11 hosts".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: updates,
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
                "\x1b[1m● Build systems · 11 hosts\x1b[0m \x1b[2m· phase elapsed 1m 51s\x1b[0m",
                "  \x1b[32m✓ Build plan gap3 gondor · task elapsed 1m 04s\x1b[0m",
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
    fn task_output_keeps_three_lines_and_renders_the_latest_two() {
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
            ["two", "three", "four"]
        );
        let lines = dashboard_lines(
            TerminalStyle::from_capabilities(false, false),
            state.stack.last().unwrap(),
            Duration::from_secs(2),
        );
        assert!(lines.iter().any(|line| line == "    three"), "{lines:?}");
        assert!(lines.iter().any(|line| line == "    four"), "{lines:?}");
        assert!(!lines.iter().any(|line| line == "    two"), "{lines:?}");
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
        reporter.fail_active("Deploy systems · phase elapsed 2.0s", "fleet deploy failed");

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
            "✓ Build plan gap3 gondor · task elapsed 1m 04s".to_owned(),
            Tone::Success,
        );
        let active = ActiveProgress {
            id: 1,
            label: "Build systems · 11 hosts".to_owned(),
            detail: None,
            detail_emitted_at: None,
            recent_updates: updates,
            started: Instant::now(),
        };
        assert_eq!(
            dashboard_lines(
                TerminalStyle::from_capabilities(false, false),
                &active,
                Duration::from_secs(111),
            ),
            vec![
                "● Build systems · 11 hosts · phase elapsed 1m 51s",
                "  ✓ Build plan gap3 gondor · task elapsed 1m 04s",
            ]
        );
    }

    #[test]
    fn skipped_tasks_use_the_warning_tone() {
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
        reporter.task_skipped("build-gap3", "Build plan gap3 gondor");

        let output = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        assert!(
            output.contains("\x1b[33m◇ Build plan gap3 gondor · skipped\x1b[0m"),
            "{output:?}"
        );
        assert!(!output.contains("✗ Build plan gap3 gondor"), "{output:?}");
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
        reporter.task_started("build-gap3", "Build plan gap3 gondor");
        reporter.task_finished(
            "build-gap3",
            "Build plan gap3 gondor",
            Duration::from_secs(64),
            true,
        );
        reporter.message("Checking builder routes");
        reporter.completed("Build systems · 11 hosts", Duration::from_secs(111));

        let output = String::from_utf8(buffer.lock().unwrap().clone()).unwrap();
        let clear_two_lines = "\r\x1b[2K\x1b[1A\r\x1b[2K";
        assert!(output.matches(clear_two_lines).count() >= 3, "{output:?}");
        assert!(
            output.contains("\n  ✓ Build plan gap3 gondor · task elapsed 1m 04s"),
            "{output:?}"
        );
        let after_message = output
            .split_once("Checking builder routes\n")
            .map(|(_, rest)| rest)
            .expect("message should be followed by the redrawn dashboard");
        assert!(
            after_message.starts_with("● Build systems · 11 hosts · phase elapsed "),
            "{output:?}"
        );
        assert!(
            after_message.contains("\n  ✓ Build plan gap3 gondor · task elapsed 1m 04s"),
            "{output:?}"
        );
        assert!(
            output.ends_with("✓ Build systems · 11 hosts · phase elapsed 1m 51s\n"),
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
        reporter.task_started("build-gap3", "Build plan gap3 gondor");
        reporter.task_finished(
            "build-gap3",
            "Build plan gap3 gondor",
            Duration::from_secs(64),
            true,
        );
        reporter.completed("Build systems · 11 hosts", Duration::from_secs(111));

        assert_eq!(
            String::from_utf8(buffer.lock().unwrap().clone()).unwrap(),
            concat!(
                "● Build systems · 11 hosts\n",
                "  Build plan gap3 gondor · running\n",
                "✓ Build systems · 11 hosts  1m 51s\n",
            )
        );
    }
}
