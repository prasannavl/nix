use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};

use crate::progress::RowOutcome;
use crate::progress::{
    HostOperation, ProgressReporter, TimedField, command_reporter, format_duration,
};
use crate::terminal_style::Tone;

use super::build_runtime::{FailedBuild, UnconfirmedBuild};
use super::cli::{Action, LogFormat, Options};
use super::host_runtime::{ProcessCompletion, ProcessRecorder, ProcessStream};
use super::orchestration::{
    FinalHostState, HostMilestone, HostQualifier, HostStage, PhaseResult, PhaseResultKind,
};
use super::plan::Phase;
use super::task::{StepSpecSource, Task, TaskOutcome, TaskScope};

static NEXT_TASK_ID: AtomicU64 = AtomicU64::new(1);
static FLEET_FAILURE_PRESENTED: AtomicBool = AtomicBool::new(false);
static FLEET_WARNING_PRESENTED: AtomicBool = AtomicBool::new(false);

/// Published into a failed step's retained tail so operators know where the
/// raw output went. Execution never chooses wording; presentation owns it.
const FAILURE_HINT: &str = "failed; see diagnostics";

/// How one step's raw process output is filtered for humans. Derived from
/// [`StepSpec::finalizing`](super::task::StepSpec::finalizing), so execution
/// never selects an output policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum OutputPolicy {
    /// Bounded, sanitized operational allowlist.
    Curated,
    /// Activation lifecycle allowlist while the detached unit runs.
    Activation,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkflowResult {
    Success,
    SuccessWithWarnings,
    Failure,
    Interrupted,
}

impl WorkflowResult {
    fn label(self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::SuccessWithWarnings => "success with warnings",
            Self::Failure => "failure",
            Self::Interrupted => "interrupted",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HostStatus {
    BuildDone,
    BuildSkip,
    BuildBlocked,
    SnapshotDone,
    SnapshotSkip,
    SnapshotUnavailable,
    AcquireDone,
    AcquireSkip,
    AcquireBlocked,
    AcquireDeferred,
    DeployDone,
    DeploySkip,
    DeployBlocked,
    HealthDone,
    HealthSkip,
    HealthBlocked,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HostStatusKind {
    Done,
    Skip,
    Warning,
}

impl HostStatus {
    fn label(self) -> &'static str {
        match self {
            Self::BuildDone => "build done",
            Self::BuildSkip => "build skip",
            Self::BuildBlocked => "build blocked",
            Self::SnapshotDone => "snapshot done",
            Self::SnapshotSkip => "snapshot skip",
            Self::SnapshotUnavailable => "snapshot unavailable",
            Self::AcquireDone => "acquire done",
            Self::AcquireSkip => "acquire skip",
            Self::AcquireBlocked => "acquire blocked",
            Self::AcquireDeferred => "acquire deferred",
            Self::DeployDone => "deploy done",
            Self::DeploySkip => "deploy skip",
            Self::DeployBlocked => "deploy blocked",
            Self::HealthDone => "health done",
            Self::HealthSkip => "health skip",
            Self::HealthBlocked => "health blocked",
        }
    }

    fn kind(self) -> HostStatusKind {
        match self {
            Self::BuildDone
            | Self::SnapshotDone
            | Self::AcquireDone
            | Self::DeployDone
            | Self::HealthDone => HostStatusKind::Done,
            Self::BuildSkip
            | Self::SnapshotSkip
            | Self::AcquireSkip
            | Self::DeploySkip
            | Self::HealthSkip => HostStatusKind::Skip,
            Self::BuildBlocked
            | Self::SnapshotUnavailable
            | Self::AcquireBlocked
            | Self::AcquireDeferred
            | Self::DeployBlocked
            | Self::HealthBlocked => HostStatusKind::Warning,
        }
    }
}

#[derive(Clone, Debug)]
pub struct FleetProgress {
    reporter: ProgressReporter,
    prefix_process_logs: bool,
    auto_prefix: bool,
    github_actions: bool,
    diagnostics: Option<Arc<DiagnosticSink>>,
    build_heartbeat: Option<Duration>,
    activation_heartbeat: Option<Duration>,
}

impl FleetProgress {
    /// Start a command's presentation: forget anything an earlier command left
    /// behind, and open the verbose section up front when `--verbose` or
    /// `--build-logs` asks for it. Call this once, from the command entry.
    ///
    /// The section is operator state, so [`Self::from_options`] deliberately does
    /// not touch it: a run builds a view for every phase and every host, and none
    /// of those may close a section the operator opened or discard its history.
    pub fn begin_command(options: &Options) {
        let reporter = command_reporter();
        reporter.begin_workflow();
        reporter.reset_verbose_history();
        reporter.set_verbose_open(options.verbose || options.build_logs);
    }

    /// Build a view of the command's progress. Constructing one never changes the
    /// verbose section, so a view built mid-run inherits whatever the operator has
    /// open.
    pub fn from_options(options: &Options) -> Self {
        let github_actions = github_actions_mode(
            options.log_format,
            std::env::var("GITHUB_ACTIONS").as_deref() == Ok("true"),
        );
        let reporter = if github_actions {
            command_reporter().clone().without_terminal()
        } else {
            command_reporter().clone().with_recent_updates(10)
        };
        Self {
            reporter,
            prefix_process_logs: options.prefix_host_logs,
            auto_prefix: !options.prefix_host_logs_explicit,
            github_actions,
            diagnostics: None,
            build_heartbeat: None,
            activation_heartbeat: None,
        }
    }

    pub(crate) fn concurrency_handler(
        &self,
        handler: impl Fn(crate::progress::ConcurrencyChange) -> bool + Send + Sync + 'static,
    ) -> crate::progress::ConcurrencyGuard {
        self.reporter.concurrency_handler(handler)
    }

    fn prefix_logs(&self) -> bool {
        self.prefix_process_logs
            || (self.auto_prefix && self.reporter.host_log_attribution_needed())
    }

    /// Exact source identity comes from the workflow's source authority and is
    /// emitted once as invocation metadata, never repeated in phase headers.
    pub fn execution_source(&self, identity: &str) {
        self.reporter
            .message_field("Source", safe_host_summary(identity));
    }

    const HOST_LOCAL_LOCK: &str = "Host-local lock";

    pub(super) fn host_local_lock_wait(&self) -> TimedField<'_> {
        self.reporter.timed_field(Self::HOST_LOCAL_LOCK, "waiting")
    }

    pub(super) fn host_local_lock(&self, status: &str, waited: Option<Duration>) {
        self.reporter.message_field_with_metadata(
            Self::HOST_LOCAL_LOCK,
            status,
            waited.map(|duration| format!("waited {}", format_duration(duration))),
        );
    }

    /// Actual scheduler slots, not the number of hosts displaying a running step.
    pub fn phase_admission(
        &self,
        running: usize,
        target: usize,
        adjustable: bool,
        constraint: Option<&str>,
    ) {
        let constraint = constraint.map(safe_host_summary);
        self.reporter
            .phase_admission(running, target, adjustable, constraint.as_deref());
    }

    /// Hold for one admitted operation, including readiness, retries and settling.
    /// Drop before requeueing a separately admitted operation (eval → build).
    pub fn host_operation(&self, host: &str) -> HostOperation {
        self.reporter.host_operation(host)
    }

    pub fn with_heartbeat_intervals(mut self, build_seconds: u64, activation_seconds: u64) -> Self {
        self.build_heartbeat = (build_seconds > 0).then(|| Duration::from_secs(build_seconds));
        self.activation_heartbeat =
            (activation_seconds > 0).then(|| Duration::from_secs(activation_seconds));
        self
    }

    pub fn with_diagnostics(mut self, directory: &Path) -> Result<Self> {
        self.diagnostics = Some(Arc::new(DiagnosticSink::new(directory)?));
        Ok(self)
    }

    pub fn phase_started(&self, phase: Phase, hosts: &[String], position: Option<(usize, usize)>) {
        let label = phase_label(phase, hosts.len(), position);
        self.reporter.begin_task_scope();
        if self.github_actions {
            self.reporter.message(format!("::group::{label}"));
            self.reporter.started_silent(label);
        } else {
            self.reporter.started(label);
        }
        if phase.uses_hosts() {
            self.reporter
                .begin_fleet_dashboard(hosts, &phase_title(phase, position));
        }
    }

    pub(crate) fn terraform_projects(
        &self,
        phase: Phase,
        projects: &[String],
        position: Option<(usize, usize)>,
    ) {
        self.reporter
            .begin_project_dashboard(projects, &phase_title(phase, position));
    }

    pub(crate) fn terraform_step(&self, project: &str, label: &str) {
        self.reporter.project_step(project, label);
    }

    pub(crate) fn terraform_finished(&self, project: &str, outcome: RowOutcome) {
        self.reporter.project_finished(project, outcome);
    }

    pub fn phase_schedule(
        &self,
        stage: impl Into<String>,
        wave: Option<(usize, usize)>,
        concurrency: usize,
    ) {
        self.reporter.host_schedule(stage, wave, concurrency);
    }

    pub fn host_completed(&self, host: &str, summary: impl Into<String>) {
        self.reporter
            .host_finished(host, true, None, safe_host_summary(&summary.into()));
    }

    pub fn host_failed(&self, host: &str, summary: impl Into<String>) {
        self.reporter
            .host_finished(host, false, None, safe_host_summary(&summary.into()));
    }

    pub fn host_unconfirmed(&self, host: &str, summary: impl Into<String>) {
        self.reporter
            .host_unconfirmed(host, safe_host_summary(&summary.into()));
    }

    pub fn build_diagnostic_path(&self, host: &str, builder: &str) -> Result<Option<String>> {
        let name = if builder == "local" {
            format!("build-{host}")
        } else {
            format!("build-{host}-via-{builder}")
        };
        self.diagnostics
            .as_ref()
            .map(|sink| sink.build_log(&name))
            .transpose()
            .map(|path| path.flatten().map(|path| path.display().to_string()))
    }

    pub fn host_skipped(&self, host: &str, summary: impl Into<String>) {
        self.reporter
            .host_skipped(host, safe_host_summary(&summary.into()));
    }

    pub fn host_status(&self, host: &str, status: HostStatus) {
        match status.kind() {
            HostStatusKind::Done => {
                self.reporter
                    .host_finished(host, true, None, status.label());
            }
            HostStatusKind::Skip => self.reporter.host_skipped(host, status.label()),
            HostStatusKind::Warning => self.reporter.host_warning(host, status.label()),
        }
    }

    pub fn phase_completed(
        &self,
        phase: Phase,
        hosts: usize,
        position: Option<(usize, usize)>,
        elapsed: Duration,
    ) {
        self.record_phase(phase, "done", "✓", Tone::Success, elapsed);
        let label = phase_label(phase, hosts, position);
        if self.github_actions {
            self.reporter.end_silent_phase();
            self.reporter
                .message(format!("✓ {label}  {}", format_duration(elapsed)));
            self.reporter.message("::endgroup::");
        } else {
            self.reporter.host_phase_completed(label, elapsed);
        }
        self.reporter.end_task_scope();
    }

    pub fn phase_failed(
        &self,
        phase: Phase,
        hosts: usize,
        position: Option<(usize, usize)>,
        elapsed: Duration,
        error: &str,
    ) {
        self.record_phase(phase, "failed", "✗", Tone::Failure, elapsed);
        let error = safe_error_excerpt(error);
        let label = if self.reporter.shows_recent_updates() {
            format!(
                "{} · elapsed {}",
                phase_label(phase, hosts, position),
                format_duration(elapsed)
            )
        } else {
            format!(
                "{} · {}",
                phase_label(phase, hosts, position),
                format_duration(elapsed)
            )
        };
        if self.github_actions {
            self.reporter.message(format!(
                "::error::{}: {}",
                github_command_value(&label),
                github_command_value(&error)
            ));
            self.reporter.report_failure_output();
            self.reporter.end_silent_phase();
            self.reporter.message("::endgroup::");
        } else {
            self.reporter.fail_active(label, &error);
        }
        self.reporter.end_task_scope();
        FLEET_FAILURE_PRESENTED.store(true, Ordering::Release);
    }

    pub fn phase_warning(
        &self,
        phase: Phase,
        hosts: usize,
        position: Option<(usize, usize)>,
        elapsed: Duration,
        warning: &str,
    ) {
        self.record_phase(phase, "warnings", "◇", Tone::Warning, elapsed);
        let warning = safe_error_excerpt(warning);
        let label = format!(
            "{} · completed with warnings · elapsed {}",
            phase_label(phase, hosts, position),
            format_duration(elapsed)
        );
        if self.github_actions {
            self.reporter.message(format!(
                "::warning::{}: {}",
                github_command_value(&label),
                github_command_value(&warning)
            ));
            self.reporter.report_failure_output();
            self.reporter.end_silent_phase();
            self.reporter.message("::endgroup::");
        } else {
            self.reporter.warning_active(label, &warning);
        }
        self.reporter.end_task_scope();
        FLEET_WARNING_PRESENTED.store(true, Ordering::Release);
    }

    pub fn phase_interrupted(
        &self,
        phase: Phase,
        hosts: usize,
        position: Option<(usize, usize)>,
        elapsed: Duration,
    ) {
        self.record_phase(phase, "interrupted", "⊘", Tone::Warning, elapsed);
        let label = if self.reporter.shows_recent_updates() {
            format!(
                "{} · interrupted · elapsed {}",
                phase_label(phase, hosts, position),
                format_duration(elapsed)
            )
        } else {
            format!(
                "{} · interrupted · {}",
                phase_label(phase, hosts, position),
                format_duration(elapsed)
            )
        };
        if self.github_actions {
            self.reporter.message(format!("::warning::{label}"));
            self.reporter.end_silent_phase();
            self.reporter.message("::endgroup::");
        } else {
            self.reporter.interrupt_active(label);
        }
        self.reporter.end_task_scope();
    }

    fn record_phase(
        &self,
        phase: Phase,
        status: &str,
        marker: &'static str,
        tone: Tone,
        elapsed: Duration,
    ) {
        let key = compact_phase_label(phase);
        self.reporter
            .record_fleet_phase(key, &format!("{key} {status}"), marker, tone, elapsed);
    }

    pub fn step_started(&self, label: impl Into<String>) {
        self.reporter.started(label);
    }

    pub fn step_completed(&self, label: impl Into<String>, elapsed: Duration) {
        self.reporter.completed(label, elapsed);
    }

    pub fn step_failed(&self, label: impl Into<String>, error: &str) {
        self.reporter.fail_active(label, error);
        FLEET_FAILURE_PRESENTED.store(true, Ordering::Release);
    }

    pub fn detail(&self, detail: impl Into<String>) {
        self.reporter.detail(detail);
    }

    /// Mark a phase-level task as deliberately skipped. The caller owns the
    /// label so it stays lowercase and consistent with step vocabulary.
    pub fn task_skipped(&self, key: impl Into<String>, label: impl Into<String>) {
        self.reporter.task_skipped(key, label);
    }

    pub fn message(&self, message: impl std::fmt::Display) {
        self.reporter.message(message);
    }

    pub fn message_field_with_metadata(
        &self,
        label: &str,
        value: impl std::fmt::Display,
        metadata: Option<impl std::fmt::Display>,
    ) {
        self.reporter
            .message_field_with_metadata(label, value, metadata);
    }

    pub fn workflow_summary<'a>(
        &self,
        action: &Action,
        phases: impl IntoIterator<Item = (Phase, Option<PhaseResult>)>,
        hosts: impl IntoIterator<Item = (&'a str, FinalHostState)>,
        result: WorkflowResult,
        elapsed: Duration,
    ) {
        let elapsed = self.reporter.workflow_elapsed().unwrap_or(elapsed);
        self.reporter.finish_workflow();
        let result = result.label();
        let heading = format!("Summary · {} · {result}", summary_action_label(action));
        let metadata = [if self.reporter.shows_recent_updates() {
            format!("total elapsed {}", format_duration(elapsed))
        } else {
            format_duration(elapsed)
        }];
        if self.github_actions {
            self.reporter
                .message(format!("::notice::{heading} · {}", metadata.join(" · ")));
        } else {
            self.reporter.heading_with_metadata(heading, metadata);
        }
        let phases = phases.into_iter().collect::<Vec<_>>();
        if !phases.is_empty() {
            self.reporter.message("Phases:");
        }
        for &(phase, result) in &phases {
            let (tone, status) = phase_summary_status(result);
            let counts = self
                .reporter
                .phase_outcome_counts(compact_phase_label(phase))
                .map(|counts| format!(" · {counts}"))
                .unwrap_or_default();
            self.reporter.message_primary_with_metadata(
                "  ",
                tone,
                phase_label(phase, 0, None),
                format!(" · {status}{counts}"),
            );
            for project in self.reporter.phase_projects(compact_phase_label(phase)) {
                let (tone, outcome) = match project.outcome {
                    Some(RowOutcome::Succeeded) => (Tone::Success, "✓ done"),
                    Some(RowOutcome::Failed) => (Tone::Failure, "✗ failed"),
                    Some(RowOutcome::Skipped) => (Tone::Muted, "◇ skipped (unchanged)"),
                    Some(RowOutcome::Interrupted) => (Tone::Warning, "⊘ interrupted"),
                    Some(RowOutcome::Unconfirmed) => (Tone::Warning, "? unconfirmed"),
                    None => (Tone::Muted, "○ not run"),
                };
                let elapsed = project.elapsed.map_or_else(String::new, |elapsed| {
                    format!(" · {}", format_duration(elapsed))
                });
                self.reporter.message_primary_with_metadata(
                    "    ",
                    tone,
                    project.name,
                    format!(" · {outcome}{elapsed}"),
                );
            }
        }
        let hosts = hosts.into_iter().collect::<Vec<_>>();
        let host_names = hosts.iter().map(|(host, _)| *host).collect::<Vec<_>>();
        let mut durations = self.reporter.host_duration_summaries(&host_names);
        if !hosts.is_empty() || !durations.is_empty() {
            self.reporter.message("Hosts:");
        }
        for &(host, status) in &hosts {
            let display = host_summary_status(action, status);
            self.reporter.message_host_summary(
                host,
                display
                    .parts
                    .into_iter()
                    .flatten()
                    .map(|part| (part.tone, part.text)),
                durations.remove(host).as_deref(),
                display.muted_row,
            );
        }
        // Keep observations outside the final selection without inventing a status.
        for (host, timing) in durations {
            self.reporter
                .message_host_summary(&host, std::iter::empty(), Some(&timing), false);
        }
    }

    pub fn log_block(&self, subject: &str, output: &str) {
        for line in output.lines() {
            report_verbose_line(
                &self.reporter,
                subject,
                None,
                line,
                self.prefix_logs(),
                true,
            );
        }
    }

    /// Task factory for one host's steps.
    pub fn host_scope(&self, host: &str) -> Arc<HostScope> {
        self.scope(TaskTarget::Host(host.to_owned()))
    }

    /// Task factory for phase-level (non-host) operations.
    pub fn phase_scope(&self) -> Arc<HostScope> {
        self.scope(TaskTarget::Phase)
    }

    fn scope(&self, target: TaskTarget) -> Arc<HostScope> {
        Arc::new(HostScope {
            reporter: self.reporter.clone(),
            target,
            prefix: self.prefix_logs(),
            build_heartbeat: self.build_heartbeat,
            activation_heartbeat: self.activation_heartbeat,
        })
    }

    /// Display-independent diagnostic recorder for the steps' child processes.
    pub fn recorder(&self) -> Option<Arc<dyn ProcessRecorder>> {
        self.diagnostics
            .clone()
            .map(|sink| sink as Arc<dyn ProcessRecorder>)
    }
}

pub fn take_failure_presented() -> bool {
    FLEET_FAILURE_PRESENTED.swap(false, Ordering::AcqRel)
}

pub fn take_warning_presented() -> bool {
    FLEET_WARNING_PRESENTED.swap(false, Ordering::AcqRel)
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum TaskTarget {
    Host(String),
    Phase,
}

/// Host- or phase-bound task factory. Mints one [`ProgressTask`] per step.
pub struct HostScope {
    reporter: ProgressReporter,
    target: TaskTarget,
    prefix: bool,
    build_heartbeat: Option<Duration>,
    activation_heartbeat: Option<Duration>,
}

impl HostScope {
    /// Display host these steps belong to; phase scopes have no host.
    fn display_host(&self) -> &str {
        match &self.target {
            TaskTarget::Host(host) => host,
            TaskTarget::Phase => "",
        }
    }
}

impl TaskScope for HostScope {
    fn step(&self, step: &dyn StepSpecSource) -> Arc<dyn Task> {
        let spec = step.spec(self.display_host());
        let heartbeat = if spec.finalizing {
            self.activation_heartbeat
        } else {
            self.build_heartbeat
        };
        Arc::new(ProgressTask {
            reporter: self.reporter.clone(),
            target: self.target.clone(),
            heartbeat,
            prefix: self.prefix,
            key: format!(
                "{}#{}",
                spec.name,
                NEXT_TASK_ID.fetch_add(1, Ordering::Relaxed)
            ),
            name: spec.name,
            running: spec.running,
            done: spec.done,
            finalizing: spec.finalizing,
            interrupted: AtomicBool::new(false),
        })
    }
}

/// Renders one step's lifecycle into the host dashboard or the phase line.
#[derive(Debug)]
pub struct ProgressTask {
    reporter: ProgressReporter,
    target: TaskTarget,
    heartbeat: Option<Duration>,
    prefix: bool,
    key: String,
    name: String,
    running: String,
    done: String,
    finalizing: bool,
    interrupted: AtomicBool,
}

impl ProgressTask {
    /// Activation output is admitted only for finalizing activation/rollback.
    fn output_policy(&self) -> OutputPolicy {
        if self.finalizing {
            OutputPolicy::Activation
        } else {
            OutputPolicy::Curated
        }
    }

    /// Lowercase human subject for verbose output; host steps include the host
    /// so concurrent lines stay attributable. When the step already names the
    /// host as its executor (`build via pvl-x2`), appending the host again
    /// would duplicate the name.
    fn verbose_subject(&self) -> String {
        match &self.target {
            TaskTarget::Host(host) => {
                let executor = self.running.rsplit_once(" via ").map(|(_, via)| via);
                if executor == Some(host.as_str()) {
                    self.running.clone()
                } else {
                    format!("{} {host}", self.running)
                }
            }
            TaskTarget::Phase => self.running.clone(),
        }
    }

    /// Retain and render one semantic line for this step.
    fn publish_line(&self, line: String) {
        self.reporter
            .task_output(self.key.clone(), &self.running, line.clone());
        match &self.target {
            TaskTarget::Host(host) => self.reporter.host_task_output(host, &self.key, line),
            TaskTarget::Phase => {
                self.reporter
                    .task_live_output(self.key.clone(), &self.running, line)
            }
        }
    }
}

impl Task for ProgressTask {
    fn name(&self) -> &str {
        &self.name
    }

    fn started(&self) {
        match &self.target {
            TaskTarget::Host(host) => {
                self.reporter
                    .host_task_started(host, &self.key, &self.running, self.heartbeat)
            }
            TaskTarget::Phase => self
                .reporter
                .task_started(self.key.clone(), self.running.clone()),
        }
    }

    fn output(&self, stream: ProcessStream, chunk: &str) {
        let policy = self.output_policy();
        for line in chunk.lines() {
            report_verbose_line(
                &self.reporter,
                &self.verbose_subject(),
                Some(stream),
                line,
                self.prefix,
                verbose_line_eligible(policy, line),
            );
            let dashboard_line =
                format_process_dashboard_line(policy, stream, line).or_else(|| {
                    (stream == ProcessStream::Stderr && self.running.starts_with("build"))
                        .then(|| format_build_error_activity(line))
                        .flatten()
                });
            if let Some(dashboard_line) = dashboard_line {
                self.publish_line(dashboard_line);
            }
        }
    }

    fn note(&self, line: &str) {
        if let Some(line) = format_operation_dashboard_line(line) {
            self.publish_line(line);
        }
    }

    fn heartbeat(&self, elapsed: Duration) {
        match &self.target {
            TaskTarget::Host(host) => {
                self.reporter
                    .host_task_heartbeat(host, &self.key, &self.running)
            }
            TaskTarget::Phase => {
                self.reporter
                    .task_heartbeat(self.key.clone(), &self.running, elapsed)
            }
        }
    }

    fn finished(&self, elapsed: Duration, outcome: TaskOutcome) {
        match &self.target {
            TaskTarget::Host(host) => match outcome {
                TaskOutcome::Unconfirmed => {
                    self.reporter
                        .host_task_unconfirmed(host, &self.key, &self.running, elapsed)
                }
                TaskOutcome::Interrupted => {
                    self.reporter
                        .host_task_interrupted(host, &self.key, &self.running, elapsed)
                }
                TaskOutcome::Succeeded if self.finalizing => {
                    self.reporter.host_task_finalizing(
                        host,
                        &self.key,
                        &self.running,
                        &self.done,
                        elapsed,
                    );
                }
                TaskOutcome::Succeeded => {
                    self.reporter.host_task_finished(
                        host,
                        &self.key,
                        &self.running,
                        &self.done,
                        elapsed,
                        true,
                    );
                }
                TaskOutcome::Failed => {
                    self.publish_line(FAILURE_HINT.to_owned());
                    self.reporter.host_task_finished(
                        host,
                        &self.key,
                        &self.running,
                        &self.done,
                        elapsed,
                        false,
                    );
                }
            },
            TaskTarget::Phase => match outcome {
                TaskOutcome::Unconfirmed => self.reporter.task_interrupted(
                    self.key.clone(),
                    format!("{} · remote execution unconfirmed", self.running),
                    elapsed,
                ),
                TaskOutcome::Interrupted => {
                    self.reporter
                        .task_interrupted(self.key.clone(), self.running.clone(), elapsed);
                }
                TaskOutcome::Succeeded => self.reporter.task_finished(
                    self.key.clone(),
                    self.running.clone(),
                    elapsed,
                    true,
                ),
                TaskOutcome::Failed => {
                    self.publish_line(FAILURE_HINT.to_owned());
                    self.reporter.task_finished(
                        self.key.clone(),
                        self.running.clone(),
                        elapsed,
                        false,
                    )
                }
            },
        }
    }

    fn heartbeat_interval(&self) -> Option<Duration> {
        self.heartbeat
    }

    fn mark_interrupted(&self) {
        self.interrupted.store(true, Ordering::Release);
    }

    fn was_interrupted(&self) -> bool {
        self.interrupted.load(Ordering::Acquire)
    }
}

#[derive(Debug)]
struct DiagnosticSink {
    directory: PathBuf,
    state: Mutex<DiagnosticState>,
}

#[derive(Debug, Default)]
struct DiagnosticState {
    files: BTreeMap<String, File>,
    disabled: bool,
}

impl DiagnosticSink {
    fn new(root: &Path) -> Result<Self> {
        let directory = root.join("commands");
        std::fs::create_dir_all(&directory).with_context(|| {
            format!(
                "create command diagnostic directory {}",
                directory.display()
            )
        })?;
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))?;
        Ok(Self {
            directory,
            state: Mutex::new(DiagnosticState::default()),
        })
    }
}

impl ProcessRecorder for DiagnosticSink {
    fn started(&self, name: &str) {
        self.append(&format!("{}.status", diagnostic_name(name)), b"started\n");
    }

    fn output(&self, name: &str, stream: ProcessStream, chunk: &str) {
        let stream = match stream {
            ProcessStream::Stdout => "stdout",
            ProcessStream::Stderr => "stderr",
        };
        self.append(
            &format!("{}.{}.log", diagnostic_name(name), stream),
            chunk.as_bytes(),
        );
    }

    fn finished(&self, name: &str, elapsed: Duration, completion: ProcessCompletion) {
        let name = diagnostic_name(name);
        self.append(
            &format!("{name}.status"),
            format!(
                "{} {}\n",
                match completion {
                    ProcessCompletion::Succeeded => "ok",
                    ProcessCompletion::Failed => "failed",
                    ProcessCompletion::Interrupted => "interrupted",
                },
                format_duration(elapsed)
            )
            .as_bytes(),
        );
        self.close_command_files(&name);
    }
}

impl DiagnosticSink {
    fn build_log(&self, name: &str) -> Result<Option<PathBuf>> {
        let state = self
            .state
            .lock()
            .map_err(|_| anyhow::anyhow!("diagnostic recorder lock poisoned"))?;
        if state.disabled {
            anyhow::bail!("diagnostic recorder write failed");
        }
        let path = self
            .directory
            .join(format!("{}.stderr.log", diagnostic_name(name)));
        Ok(path.is_file().then_some(path))
    }

    fn close_command_files(&self, name: &str) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        for suffix in ["status", "stdout.log", "stderr.log"] {
            state.files.remove(&format!("{name}.{suffix}"));
        }
    }

    fn append(&self, name: &str, bytes: &[u8]) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        if state.disabled {
            return;
        }
        let result = (|| -> std::io::Result<()> {
            if !state.files.contains_key(name) {
                let file = OpenOptions::new()
                    .create(true)
                    .append(true)
                    .mode(0o600)
                    .open(self.directory.join(name))?;
                state.files.insert(name.to_owned(), file);
            }
            state
                .files
                .get_mut(name)
                .expect("diagnostic file inserted above")
                .write_all(bytes)
        })();
        if result.is_err() {
            state.disabled = true;
        }
    }
}

fn diagnostic_name(label: &str) -> String {
    let mut name = label
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-') {
                character
            } else {
                '-'
            }
        })
        .collect::<String>();
    name.truncate(96);
    if name.is_empty() {
        "command".to_owned()
    } else {
        name
    }
}

fn phase_summary_status(result: Option<PhaseResult>) -> (Tone, String) {
    let Some(result) = result else {
        return (Tone::Neutral, "not run".to_owned());
    };
    let (tone, label) = match result.kind {
        PhaseResultKind::Succeeded => (Tone::Success, "ok"),
        PhaseResultKind::Warning => (Tone::Warning, "WARN"),
        PhaseResultKind::Failed => (Tone::Failure, "FAIL"),
        PhaseResultKind::Interrupted => (Tone::Warning, "interrupted"),
    };
    (
        tone,
        format!("{label} · {}", format_duration(result.elapsed)),
    )
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct HostSummaryPart {
    tone: Tone,
    text: &'static str,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct HostSummaryStatus {
    parts: [Option<HostSummaryPart>; 3],
    muted_row: bool,
}

fn host_summary_status(action: &Action, status: FinalHostState) -> HostSummaryStatus {
    let muted_row = successful_skip_before_goal(action, status);
    let mut rendered = Vec::with_capacity(3);

    if let Some(text) = milestone_text(action, status) {
        rendered.push(HostSummaryPart {
            tone: Tone::Success,
            text,
        });
    }
    match status.qualifier {
        HostQualifier::Ok => {
            if rendered.is_empty() {
                rendered.push(HostSummaryPart {
                    tone: Tone::Success,
                    text: "ok",
                });
            }
        }
        HostQualifier::Skipped(stage) => rendered.push(HostSummaryPart {
            tone: Tone::Muted,
            text: stage.map_or("skip", skip_stage_text),
        }),
        HostQualifier::Deferred(stage) => rendered.push(HostSummaryPart {
            tone: Tone::Warning,
            text: defer_stage_text(stage),
        }),
        HostQualifier::OptionalFailed(stage) => rendered.push(HostSummaryPart {
            tone: Tone::Warning,
            text: fail_stage_text(stage),
        }),
        HostQualifier::Failed(stage) => rendered.push(HostSummaryPart {
            tone: Tone::Failure,
            text: stage.map_or("fail", fail_stage_text),
        }),
        HostQualifier::DryRun => rendered.push(HostSummaryPart {
            tone: Tone::Muted,
            text: "dry run",
        }),
        HostQualifier::Incomplete(stage) => rendered.push(HostSummaryPart {
            tone: Tone::Warning,
            text: incomplete_stage_text(stage),
        }),
        HostQualifier::Unconfirmed(stage) => rendered.push(HostSummaryPart {
            tone: Tone::Warning,
            text: unconfirmed_stage_text(stage),
        }),
        HostQualifier::NotStarted(stage) => rendered.push(HostSummaryPart {
            tone: Tone::Warning,
            text: not_started_stage_text(stage),
        }),
        HostQualifier::Interrupted => rendered.push(HostSummaryPart {
            tone: Tone::Warning,
            text: "interrupted",
        }),
        HostQualifier::OptionalSkipped(stage) => rendered.push(HostSummaryPart {
            tone: Tone::Warning,
            text: optional_skipped_stage_text(stage),
        }),
        HostQualifier::RolledBack { failed, optional } => {
            if let Some(stage) = failed {
                rendered.push(HostSummaryPart {
                    tone: if optional {
                        Tone::Warning
                    } else {
                        Tone::Failure
                    },
                    text: fail_stage_text(stage),
                });
                rendered.push(HostSummaryPart {
                    tone: Tone::Muted,
                    text: "rolled back",
                });
            } else {
                rendered.push(HostSummaryPart {
                    tone: Tone::Warning,
                    text: "rolled back",
                });
            }
        }
        HostQualifier::RollbackFailed { failed, optional } => {
            let tone = if optional {
                Tone::Warning
            } else {
                Tone::Failure
            };
            if let Some(stage) = failed {
                rendered.push(HostSummaryPart {
                    tone,
                    text: fail_stage_text(stage),
                });
            }
            rendered.push(HostSummaryPart {
                tone,
                text: "rollback fail",
            });
        }
    }
    let mut parts = [None, None, None];
    for (slot, part) in parts.iter_mut().zip(rendered) {
        *slot = Some(part);
    }
    HostSummaryStatus { parts, muted_row }
}

fn milestone_text(action: &Action, status: FinalHostState) -> Option<&'static str> {
    if status.qualifier == HostQualifier::DryRun {
        return None;
    }
    match (status.milestone, status.qualifier) {
        (HostMilestone::None, _) => None,
        (HostMilestone::Built, HostQualifier::Ok)
            if matches!(action, Action::Build | Action::DevBuild) =>
        {
            Some("built")
        }
        (HostMilestone::Acquired, HostQualifier::Ok) if *action == Action::Prepare => {
            Some("acquired")
        }
        (HostMilestone::Deployed, HostQualifier::Ok) => Some("ok"),
        (HostMilestone::Built, _) => Some("built"),
        (HostMilestone::Acquired, HostQualifier::RolledBack { failed: None, .. })
        | (HostMilestone::Acquired, HostQualifier::RollbackFailed { failed: None, .. }) => None,
        (HostMilestone::Acquired, _) => Some("acquired"),
        // Health/deploy failure phrases already imply the later milestone; avoid
        // adding redundant `deployed` noise to the compact final row.
        (HostMilestone::Deployed, _) => None,
    }
}

fn fail_stage_text(stage: HostStage) -> &'static str {
    match stage {
        HostStage::Build => "fail build",
        HostStage::Snapshot => "fail snapshot",
        HostStage::Acquire => "fail acquire",
        HostStage::Deploy => "fail deploy",
        HostStage::Health => "fail health",
    }
}

fn skip_stage_text(stage: HostStage) -> &'static str {
    match stage {
        HostStage::Build => "skip build",
        HostStage::Snapshot => "skip snapshot",
        HostStage::Acquire => "skip acquire",
        HostStage::Deploy => "skip deploy",
        HostStage::Health => "skip health",
    }
}

fn defer_stage_text(stage: HostStage) -> &'static str {
    match stage {
        HostStage::Acquire => "defer acquire",
        _ => "deferred",
    }
}

fn incomplete_stage_text(stage: HostStage) -> &'static str {
    match stage {
        HostStage::Acquire => "no acquire",
        _ => "incomplete",
    }
}

fn unconfirmed_stage_text(stage: HostStage) -> &'static str {
    match stage {
        HostStage::Build => "build unconfirmed",
        _ => "unconfirmed",
    }
}

fn not_started_stage_text(stage: HostStage) -> &'static str {
    match stage {
        HostStage::Build => "build not started",
        _ => "not started",
    }
}

fn optional_skipped_stage_text(stage: HostStage) -> &'static str {
    match stage {
        HostStage::Snapshot => "snapshot unavailable",
        _ => "unavailable",
    }
}

/// A deliberately skipped host that still satisfies the command's outcome is
/// supporting information, not an exception. Mute the whole final row. Warning
/// and failure skip-like states remain visually prominent.
fn successful_skip_before_goal(action: &Action, status: FinalHostState) -> bool {
    final_host_goal(action).is_some() && matches!(status.qualifier, HostQualifier::Skipped(_))
}

fn final_host_goal(action: &Action) -> Option<HostStage> {
    match action {
        Action::Deploy | Action::Run => Some(HostStage::Deploy),
        Action::Prepare => Some(HostStage::Acquire),
        Action::Build | Action::DevBuild => Some(HostStage::Build),
        _ => None,
    }
}

fn summary_action_label(action: &Action) -> &'static str {
    match action {
        Action::Run => "run",
        Action::Deploy => "deploy",
        Action::Prepare => "prepare",
        Action::Build => "build",
        Action::DevBuild => "dev-build",
        Action::TerraformAll => "tf",
        Action::TerraformDns => "tf-dns",
        Action::TerraformPlatform => "tf-platform",
        Action::TerraformApps => "tf-apps",
        Action::TerraformProject(_) => "tf/project",
        Action::CheckBootstrap => "check-bootstrap",
        _ => "fleet",
    }
}

fn sentence_title(value: &str) -> String {
    let mut characters = value.chars();
    characters
        .next()
        .map(|first| first.to_uppercase().collect::<String>() + characters.as_str())
        .unwrap_or_default()
}

fn phase_title(phase: Phase, position: Option<(usize, usize)>) -> String {
    let mut title = match phase {
        Phase::TerraformDns => "DNS".to_owned(),
        _ => sentence_title(compact_phase_label(phase)),
    };
    if let Some((current, total)) = position {
        title.push_str(&format!(" · phase {current}/{total}"));
    }
    title
}

fn compact_phase_label(phase: Phase) -> &'static str {
    match phase {
        Phase::TerraformDns => "dns",
        Phase::TerraformPlatform => "platform",
        Phase::TerraformApps => "apps",
        Phase::Tofu => "infrastructure",
        Phase::Build => "build",
        Phase::Snapshot => "snapshot",
        Phase::Acquire => "acquire",
        Phase::Deploy => "deploy",
        Phase::Health => "health",
        Phase::DevelopmentBuild => "development build",
        Phase::BootstrapCheck => "bootstrap",
        Phase::Clean => "clean",
        Phase::RepositorySync => "repository",
        Phase::DependencyCheck => "dependencies",
    }
}

pub fn phase_label(phase: Phase, hosts: usize, position: Option<(usize, usize)>) -> String {
    let action = match phase {
        Phase::TerraformDns => "Apply DNS infrastructure",
        Phase::TerraformPlatform => "Apply platform infrastructure",
        Phase::TerraformApps => "Apply application infrastructure",
        Phase::Tofu => "Apply infrastructure project",
        Phase::Build => "Build systems",
        Phase::Snapshot => "Snapshot generations",
        Phase::Acquire => "Acquire deployment artifacts",
        Phase::Deploy => "Deploy systems",
        Phase::Health => "Verify deployment health",
        Phase::DevelopmentBuild => "Build development system",
        Phase::BootstrapCheck => "Check bootstrap access",
        Phase::Clean => "Clean runtime state",
        Phase::RepositorySync => "Synchronize repository",
        Phase::DependencyCheck => "Check runtime dependencies",
    };
    let mut label = match hosts {
        0 => action.to_owned(),
        1 => format!("{action} · 1 host"),
        count => format!("{action} · {count} hosts"),
    };
    if let Some((current, total)) = position {
        label.push_str(&format!(" · phase {current}/{total}"));
    }
    label
}

fn format_dashboard_line(line: &str) -> Option<String> {
    let line = terminal_safe_line(line);
    if line.is_empty() {
        return None;
    }
    if sensitive_output(&line) && line.trim() != "[agenix] decrypting secrets..." {
        return None;
    }
    if line == "copying 0 paths..." {
        return Some("[copy] closure already present".to_owned());
    }
    if let Some(count) = line
        .strip_prefix("copying ")
        .and_then(|line| line.strip_suffix(" paths..."))
        .filter(|count| count.chars().all(|character| character.is_ascii_digit()))
    {
        return Some(format!("[copy] copying {count} store paths"));
    }
    if let Some(path) = quoted_store_path(&line, "building '", "'...") {
        return Some(format!("[build] {}", store_basename(path)));
    }
    if let Some(path) = first_quoted_store_path(&line, "copying path '") {
        return Some(format!("[copy] {}", store_basename(path)));
    }
    if validated_store_path(&line).is_some() {
        return Some(format!("[store] {}", store_basename(&line)));
    }
    let normalized = match line.trim() {
        "Checking switch inhibitors... done" => "[switch] inhibitors ok",
        "activating the configuration..." => "[switch] activating configuration",
        "setting up /etc..." => "[switch] updating /etc",
        "[agenix] decrypting secrets..." | "[agenix] decrypting secrets" => {
            "[agenix] decrypting secrets"
        }
        "[agenix] chowning..." | "[agenix] fixing ownership" => "[agenix] fixing ownership",
        "[switch] inhibitors ok" => "[switch] inhibitors ok",
        "[switch] activating configuration" => "[switch] activating configuration",
        "[switch] updating /etc" => "[switch] updating /etc",
        line if format_agenix_status_line(line).is_some() => line,
        line if line.starts_with("reconciled ") || line.starts_with("re-applied ") => line,
        line if line.starts_with("Deploy duration: ") => line,
        line => return format_structured_status_line(line),
    };
    Some(normalized.to_owned())
}

fn format_process_dashboard_line(
    policy: OutputPolicy,
    stream: ProcessStream,
    line: &str,
) -> Option<String> {
    match policy {
        OutputPolicy::Curated => format_dashboard_line(line),
        OutputPolicy::Activation => format_activation_dashboard_line(line, stream),
    }
}

fn format_build_error_activity(line: &str) -> Option<String> {
    let line = line.trim();
    if !line.starts_with("error: Cannot build ") && !line.starts_with("error[") {
        return None;
    }
    format_failure_line(line).map(|line| format!("[error] {line}"))
}

fn format_operation_dashboard_line(line: &str) -> Option<String> {
    let line = terminal_safe_line(line);
    let rest = line.strip_prefix("[health-check] attempt ")?;
    let (attempt, status) = rest.split_once(" · ")?;
    if !ascii_digits(attempt) {
        return None;
    }
    let (state, detail) = status
        .split_once(" · ")
        .map_or((status, None), |(state, detail)| (state, Some(detail)));
    if !matches!(
        state,
        "healthy" | "settling" | "service failure" | "structural failure"
    ) {
        return None;
    }
    let mut rendered = format!("[health-check] attempt {attempt} · {state}");
    if let Some(detail) = detail.and_then(format_health_progress_detail) {
        rendered.push_str(" · ");
        rendered.push_str(&detail);
    }
    Some(rendered)
}

fn format_health_progress_detail(detail: &str) -> Option<String> {
    let detail = terminal_safe_line(detail);
    if detail.is_empty() {
        return None;
    }
    if sensitive_output(&detail) {
        return Some("detail redacted; see diagnostics".to_owned());
    }
    if matches!(
        detail.as_str(),
        "durable host-agent hold state is unavailable"
            | "deferred resource isolation is unavailable"
            | "deferred resource state reported"
            | "detail redacted; see diagnostics"
            | "detail available; see diagnostics"
    ) {
        return Some(detail);
    }
    for (prefix, label) in [
        ("failed system unit: ", "failed system unit: "),
        (
            "system unit still settling: ",
            "system unit still settling: ",
        ),
    ] {
        if let Some(unit) = detail.strip_prefix(prefix) {
            return valid_unit_name(unit).then(|| format!("{label}{unit}"));
        }
    }
    if detail.starts_with("resource=") {
        return Some("deferred resource state reported".to_owned());
    }
    if let Some(rest) = detail.strip_prefix("user=") {
        let (user, status) = rest.split_once(' ')?;
        if !safe_name(user) {
            return None;
        }
        if matches!(
            status,
            "hold=active account=missing"
                | "declaration-query=failed"
                | "user-manager=inactive"
                | "expected-runtime=query-failed"
                | "runtime settling"
                | "runtime issue; see diagnostics"
        ) {
            return Some(format!("user={user} {status}"));
        }
        if let Some(unit) = status.strip_prefix("failed-unit=") {
            return valid_unit_name(unit).then(|| format!("user={user} failed-unit={unit}"));
        }
        if let Some(unit) = status
            .strip_prefix("unit=")
            .and_then(|status| status.strip_suffix(" settling"))
        {
            return valid_unit_name(unit).then(|| format!("user={user} unit={unit} settling"));
        }
        return Some(format!(
            "user={user} {}",
            if status.starts_with("starting ") {
                "runtime settling"
            } else {
                "runtime issue; see diagnostics"
            }
        ));
    }
    Some("detail available; see diagnostics".to_owned())
}

/// Whether a streamed line may reach the verbose stream. Activation result
/// frames are structured protocol, not human output, so they are excluded.
fn verbose_line_eligible(policy: OutputPolicy, line: &str) -> bool {
    policy != OutputPolicy::Activation || !activation_protocol_line(line)
}

fn format_activation_dashboard_line(line: &str, _stream: ProcessStream) -> Option<String> {
    let line = terminal_safe_line(line);
    if line.is_empty() || activation_protocol_line(&line) {
        return None;
    }
    if let Some(line) = format_dashboard_line(&line) {
        return Some(line);
    }
    if sensitive_output(&line) {
        return None;
    }
    let trimmed = line.trim();
    let lifecycle_prefix = [
        "stopping the following ",
        "NOT stopping the following ",
        "reloading the following ",
        "restarting the following ",
        "NOT restarting the following ",
        "starting the following ",
        "the following units failed:",
    ]
    .iter()
    .find(|prefix| trimmed.starts_with(**prefix));
    if let Some(prefix) = lifecycle_prefix
        && valid_lifecycle_line(trimmed, prefix)
    {
        return format_failure_line(trimmed);
    }
    if trimmed.starts_with("[managed-restart]") {
        return Some("[managed-restart] service reconciliation update".to_owned());
    }
    None
}

fn activation_protocol_line(line: &str) -> bool {
    matches!(
        line.trim(),
        "--- abird-activation-result begin ---"
            | "--- abird-activation-result end ---"
            | "OutcomeSource=marker"
            | "Result=running"
            | "Result=success"
    ) || line.trim().starts_with("Result=")
        || line.trim().starts_with("ExecMainStatus=")
        || line.trim().starts_with("Admitted=")
}

fn format_structured_status_line(line: &str) -> Option<String> {
    if let Some(rest) = line.strip_prefix("[generation-admission] ") {
        if matches!(
            rest,
            "rejected-before-switch"
                | "current authority is absent; deferring candidate acquisition until first activation"
        ) {
            return Some(line.to_owned());
        }
        if let Some((mode, path)) = rest
            .strip_prefix("mode=")
            .and_then(|rest| rest.split_once(" admitted "))
            && matches!(mode, "normal" | "rollback")
            && path.starts_with("/nix/store/")
            && !path.chars().any(char::is_whitespace)
        {
            return Some(format!(
                "[generation-admission] mode={mode} admitted {}",
                store_basename(path)
            ));
        }
        return Some("[generation-admission] update; see diagnostics".to_owned());
    }
    if let Some(rest) = line.strip_prefix("[prefetch-podman-image] ") {
        return match rest {
            "start" => Some("[prefetch-podman-image] start".to_owned()),
            rest if rest.starts_with("skipped ") => {
                Some("[prefetch-podman-image] skipped".to_owned())
            }
            rest if rest.starts_with("deferred ") => {
                Some("[prefetch-podman-image] deferred".to_owned())
            }
            _ => Some("[prefetch-podman-image] activity; see diagnostics".to_owned()),
        };
    }
    if let Some(rest) = line.strip_prefix("[prefetch-ai-model] ") {
        let numeric_summary = (rest.strip_prefix("start total=").is_some_and(ascii_digits)
            || valid_ai_prefetch_summary(rest))
        .then(|| format!("[prefetch-ai-model] {rest}"));
        return numeric_summary.or_else(|| {
            Some(if rest.starts_with("failed id=") {
                "[prefetch-ai-model] item failed; see diagnostics".to_owned()
            } else if rest.starts_with("skipped ") {
                "[prefetch-ai-model] skipped".to_owned()
            } else if rest.starts_with("deferred ") {
                "[prefetch-ai-model] deferred".to_owned()
            } else {
                "[prefetch-ai-model] activity; see diagnostics".to_owned()
            })
        });
    }
    if let Some(rest) = line.strip_prefix("[pre-switch] ") {
        return Some(match rest {
            "resetting failed system units:" => {
                "[pre-switch] resetting failed system units".to_owned()
            }
            "unable to enumerate logind users" => {
                "[pre-switch] unable to enumerate logind users".to_owned()
            }
            rest if valid_pre_switch_user_status(rest) => format!("[pre-switch] {rest}"),
            _ => "[pre-switch] activity; see diagnostics".to_owned(),
        });
    }
    if let Some(rest) = line.strip_prefix("[store] ") {
        return valid_store_basename(rest).then(|| format!("[store] {rest}"));
    }
    if let Some(rest) = line.strip_prefix("[user-jobs] ") {
        return Some(
            format_user_jobs_status(rest)
                .unwrap_or_else(|| "[user-jobs] activity; see diagnostics".to_owned()),
        );
    }
    for (prefix, label) in [
        ("[system-units] ", "[system-units]"),
        ("[user-units] ", "[user-units]"),
    ] {
        if let Some(rest) = line.strip_prefix(prefix) {
            return Some(if valid_unit_status(label, rest) {
                format!("{label} {rest}")
            } else {
                format!("{label} activity; see diagnostics")
            });
        }
    }
    None
}

fn format_user_jobs_status(value: &str) -> Option<String> {
    const MAX_SAMPLE_NAMES: usize = 3;
    const SAMPLE_DISPLAY_BYTES: usize = 120;

    let (user, value) = value.strip_prefix("user=")?.split_once(' ')?;
    let (action, value) = value.strip_prefix("action=")?.split_once(" count=")?;
    let (count, units) = value.split_once(" units=")?;
    if !safe_name(user)
        || !matches!(action, "start" | "stop" | "restart" | "reload")
        || !ascii_digits(count)
    {
        return None;
    }
    let count = count.parse::<usize>().ok().filter(|&count| count > 0)?;
    let units = units.strip_prefix('"')?.strip_suffix('"')?;
    if units.contains('"') {
        return None;
    }

    let noun = if count == 1 { "job" } else { "jobs" };
    let mut rendered = format!("[user-jobs] {user} user manager: {count} pending {action} {noun}");
    let header_len = rendered.len();
    let mut displayed = 0;
    for unit in units.split(',') {
        if displayed == count.min(MAX_SAMPLE_NAMES) {
            break;
        }
        let separator = if displayed == 0 { ": " } else { ", " };
        if rendered.len() - header_len + separator.len() + unit.len() > SAMPLE_DISPLAY_BYTES
            || !valid_user_job_unit_name(unit)
        {
            continue;
        }
        rendered.push_str(separator);
        rendered.push_str(unit);
        displayed += 1;
    }
    // With no displayable sample, the total alone tells the whole story.
    if displayed > 0 && displayed < count {
        let remaining = count - displayed;
        rendered.push_str(&format!(" (+{remaining})"));
    }
    Some(rendered)
}

fn valid_user_job_unit_name(unit: &str) -> bool {
    let Some((stem, kind)) = unit.rsplit_once('.') else {
        return false;
    };
    if stem.is_empty()
        || stem.starts_with('@')
        || !matches!(
            kind,
            "service"
                | "socket"
                | "target"
                | "device"
                | "mount"
                | "automount"
                | "swap"
                | "timer"
                | "path"
                | "slice"
                | "scope"
        )
    {
        return false;
    }
    let mut bytes = stem.bytes();
    while let Some(byte) = bytes.next() {
        if byte == b'\\' {
            // Keep systemd's literal escape spelling; never decode it.
            if bytes.next() != Some(b'x')
                || !(0..2).all(|_| bytes.next().is_some_and(|digit| digit.is_ascii_hexdigit()))
            {
                return false;
            }
        } else if !byte.is_ascii_alphanumeric() && !matches!(byte, b'.' | b'_' | b'-' | b':' | b'@')
        {
            return false;
        }
    }
    true
}

fn ascii_digits(value: &str) -> bool {
    !value.is_empty() && value.chars().all(|character| character.is_ascii_digit())
}

fn valid_ai_prefetch_summary(value: &str) -> bool {
    let Some((ok, rest)) = value
        .strip_prefix("ok=")
        .and_then(|value| value.split_once('/'))
    else {
        return false;
    };
    let Some((total, rest)) = rest.split_once(" deferred=") else {
        return false;
    };
    let Some((deferred, failed)) = rest.split_once(" failed=") else {
        return false;
    };
    [ok, total, deferred, failed].into_iter().all(ascii_digits)
}

fn safe_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-' | '@')
        })
}

fn valid_pre_switch_user_status(value: &str) -> bool {
    let Some(rest) = value.strip_prefix("user=") else {
        return false;
    };
    let Some((user, state)) = rest.split_once(' ') else {
        return false;
    };
    safe_name(user)
        && matches!(
            state,
            "manager=active bus=unreachable"
                | "manager=inactive action=starting"
                | "manager=start-failed"
        )
}

fn valid_store_basename(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 240
        && !value.contains('/')
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '+' | '-')
        })
}

fn valid_unit_name(value: &str) -> bool {
    valid_unit_list(value) && !value.contains(',')
}

fn valid_unit_status(label: &str, value: &str) -> bool {
    let value = if label == "[user-units]" {
        let Some(value) = value.strip_prefix("user=") else {
            return false;
        };
        let Some((user, value)) = value.split_once(' ') else {
            return false;
        };
        if !safe_name(user) {
            return false;
        }
        if value == "reload" {
            return true;
        }
        value
    } else {
        value
    };
    let Some(value) = value.strip_prefix("action=") else {
        return false;
    };
    let Some((action, value)) = value.split_once(" count=") else {
        return false;
    };
    if !matches!(
        action,
        "stopping" | "reloading" | "restarting" | "starting" | "restart"
    ) {
        return false;
    }
    let Some((count, units)) = value.split_once(" units=") else {
        return false;
    };
    ascii_digits(count) && valid_quoted_unit_list(units)
}

fn valid_quoted_unit_list(value: &str) -> bool {
    let Some(value) = value
        .strip_prefix('"')
        .and_then(|value| value.strip_suffix('"'))
    else {
        return false;
    };
    valid_unit_list(value)
}

fn valid_unit_list(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 400
        && value.split(',').all(|unit| {
            let unit = unit.trim();
            safe_name(unit)
                && [
                    ".service", ".socket", ".target", ".mount", ".timer", ".path", ".scope",
                    ".slice",
                ]
                .iter()
                .any(|suffix| unit.ends_with(suffix))
        })
}

fn valid_lifecycle_line(line: &str, prefix: &str) -> bool {
    if line == "the following units failed:" {
        return true;
    }
    let Some((_, units)) = line
        .strip_prefix(prefix)
        .and_then(|rest| rest.split_once(':'))
    else {
        return false;
    };
    let units = units.trim();
    valid_unit_list(units)
}

fn format_agenix_status_line(line: &str) -> Option<&str> {
    let value = line.strip_prefix("[agenix] ")?;
    let valid_generation = |value: &str| {
        !value.is_empty() && value.chars().all(|character| character.is_ascii_digit())
    };
    if let Some(value) = value.strip_prefix("creating generation=")
        && valid_generation(value)
    {
        return Some(line);
    }
    if let Some(value) = value.strip_prefix("removed generation=")
        && valid_generation(value)
    {
        return Some(line);
    }
    if let Some(value) = value
        .strip_prefix("generation=")
        .and_then(|value| value.strip_suffix(" active"))
        && valid_generation(value)
    {
        return Some(line);
    }
    if let Some(value) = value.strip_prefix("decrypted ")
        && !value.is_empty()
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-')
        })
    {
        return Some(line);
    }
    None
}

fn format_verbose_line(line: &str) -> Option<String> {
    let line = redact_sensitive_line(terminal_safe_line(line));
    (!line.is_empty()).then_some(line)
}

/// Classify one streamed verbose line so failures and warnings stand out while
/// ordinary chatter stays muted. Mirrors nixbot's `color_for` intent: red wins
/// over mild amber, everything else keeps the neutral nixbot gray, and zero
/// counters such as `failed=0` or `deferred=0` stay neutral.
fn verbose_line_tone(line: &str) -> Tone {
    let lowercase = line.to_ascii_lowercase();
    if lowercase.contains('✗')
        || ["error", "failed", "failure", "fatal", "panic", "unhealthy"]
            .iter()
            .any(|needle| contains_positive_signal(&lowercase, needle))
    {
        return Tone::Failure;
    }
    if [
        "warning",
        "retrying",
        "timed out",
        "timeout",
        "still settling",
        "unavailable",
        "deferred",
        "starting)",
    ]
    .iter()
    .any(|needle| contains_positive_signal(&lowercase, needle))
    {
        return Tone::LogWarning;
    }
    Tone::Neutral
}

/// Whether `needle` occurs with a value other than a zero counter, so a summary
/// line like `deferred=0 failed=0` stays muted instead of turning red or amber.
fn contains_positive_signal(lowercase: &str, needle: &str) -> bool {
    lowercase
        .match_indices(needle)
        .any(|(index, _)| !is_zero_counter(&lowercase[index + needle.len()..]))
}

fn is_zero_counter(rest: &str) -> bool {
    let rest = rest.strip_prefix('s').unwrap_or(rest);
    let rest = rest
        .strip_prefix('=')
        .or_else(|| rest.strip_prefix(':'))
        .map(str::trim_start);
    rest.is_some_and(|rest| {
        let mut characters = rest.chars();
        characters.next() == Some('0')
            && !characters.next().is_some_and(|next| next.is_ascii_digit())
    })
}

fn format_failure_line(line: &str) -> Option<String> {
    let mut line = redact_sensitive_line(terminal_safe_line(line));
    if line.is_empty() {
        return None;
    }
    if line.chars().count() > 500 {
        line = line.chars().take(499).collect::<String>();
        line.push('…');
    }
    Some(line)
}

fn github_command_value(value: &str) -> String {
    value
        .replace('%', "%25")
        .replace('\r', "%0D")
        .replace('\n', "%0A")
}

fn safe_error_excerpt(value: &str) -> String {
    let lines = value
        .lines()
        .filter_map(format_failure_line)
        .take(10)
        .collect::<Vec<_>>();
    if lines.is_empty() {
        "command failed without output".to_owned()
    } else {
        lines.join("\n")
    }
}

/// Display-only explanation; result certainty remains at the build boundary.
pub(crate) fn build_error_summary(error: &anyhow::Error) -> String {
    let (title, stderr) = if let Some(failed) = error.downcast_ref::<FailedBuild>() {
        (
            format!("Nix build failed (exit {})", failed.status()),
            failed.observation().stderr.as_str(),
        )
    } else if let Some(unknown) = error.downcast_ref::<UnconfirmedBuild>() {
        (
            format!(
                "remote build unconfirmed ({}); remote work may still be running; realization was not retried",
                unknown.reason()
            ),
            unknown
                .observation()
                .map_or("", |attempt| attempt.stderr.as_str()),
        )
    } else {
        return safe_error_excerpt(&format!("{error:#}")).replace('\n', "; ");
    };
    match build_root_cause(stderr) {
        Some(cause) => format!("{title}: {cause}"),
        None => title,
    }
}

fn build_root_cause(stderr: &str) -> Option<String> {
    let mut best: Option<(u8, String)> = None;
    for raw in stderr.lines() {
        let line = raw.trim().trim_start_matches('>').trim();
        let priority = super::build_runtime::build_error_priority(line);
        if priority == 0 || best.as_ref().is_some_and(|(score, _)| *score >= priority) {
            continue;
        }
        if let Some(safe) = format_failure_line(line) {
            best = Some((priority, safe));
        }
    }
    best.map(|(_, line)| line)
}

fn safe_host_summary(value: &str) -> String {
    value
        .lines()
        .filter_map(format_failure_line)
        .find(|line| !line.is_empty())
        .unwrap_or_else(|| "no details".to_owned())
}

fn quoted_store_path<'a>(line: &'a str, prefix: &str, suffix: &str) -> Option<&'a str> {
    line.strip_prefix(prefix)?
        .strip_suffix(suffix)
        .filter(|path| validated_store_path(path).is_some())
}

fn first_quoted_store_path<'a>(line: &'a str, prefix: &str) -> Option<&'a str> {
    let remainder = line.strip_prefix(prefix)?;
    let path = remainder.split_once('\'')?.0;
    validated_store_path(path).map(|_| path)
}

fn validated_store_path(path: &str) -> Option<&str> {
    let basename = path.strip_prefix("/nix/store/")?;
    valid_store_basename(basename).then_some(basename)
}

fn store_basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn terminal_safe_line(line: &str) -> String {
    // Progress tools commonly redraw one logical line with carriage returns.
    // Only the final frame is useful in a bounded dashboard.
    let line = line.rsplit('\r').next().unwrap_or(line);
    let mut output = String::with_capacity(line.len().min(240));
    let mut characters = line.chars().peekable();
    while let Some(character) = characters.next() {
        if character == '\u{1b}' {
            match characters.next() {
                Some('[') => {
                    for control in characters.by_ref() {
                        if ('@'..='~').contains(&control) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    let mut escaped = false;
                    for control in characters.by_ref() {
                        if control == '\u{7}' || (escaped && control == '\\') {
                            break;
                        }
                        escaped = control == '\u{1b}';
                    }
                }
                Some(_) | None => {}
            }
            continue;
        }
        if character == '\t' {
            output.push(' ');
        } else if !character.is_control() {
            output.push(character);
        }
    }
    output.trim_end().to_owned()
}

fn redact_sensitive_line(line: String) -> String {
    if sensitive_output(&line) {
        "[sensitive output redacted]".to_owned()
    } else {
        line
    }
}

fn sensitive_output(line: &str) -> bool {
    let lowercase = line.to_ascii_lowercase();
    // Structural markers are secret regardless of surrounding context.
    if [
        "-----begin",
        "authorization:",
        "bearer ",
        "cookie:",
        "set-cookie:",
    ]
    .iter()
    .any(|needle| lowercase.contains(needle))
    {
        return true;
    }
    credential_url(&lowercase) || secret_assignments(&lowercase)
}

/// Redact only when a secret-shaped field name is followed by a separator and
/// a value. This keeps benign store paths and filenames readable in the full
/// verbose stream (for example `<hash>-api-token.key.age`, `libsecret`, or
/// `etc-ipsec.secrets`) while still hiding `api_key=...`, `token: ...`, and
/// `password is ...`.
fn secret_assignments(lowercase: &str) -> bool {
    const FIELDS: [&str; 15] = [
        "password",
        "passwd",
        "token",
        "secret",
        "api_key",
        "api-key",
        "apikey",
        "access_key",
        "access-key",
        "client_secret",
        "client-secret",
        "private_key",
        "private-key",
        "private key",
        "credential",
    ];
    FIELDS.iter().any(|field| {
        lowercase.match_indices(field).any(|(index, _)| {
            let mut characters = lowercase[index + field.len()..].chars();
            // Accept a plural suffix so `secrets=`, `tokens=`, and
            // `credentials=...` stay redacted without matching `secrets/` paths.
            let separator = match characters.next() {
                Some('s') => characters.next(),
                other => other,
            };
            let Some(separator) = separator else {
                return false;
            };
            matches!(separator, '=' | ':' | ' ' | '\t' | '"' | '\\')
                && characters.any(|character| !character.is_whitespace())
        })
    })
}

fn credential_url(lowercase: &str) -> bool {
    let mut remainder = lowercase;
    while let Some(scheme) = remainder.find("://") {
        let after = &remainder[scheme + 3..];
        // An authority ends at the first delimiter that closes it. Stop there
        // so a later URL in the same line cannot be mistaken for credentials.
        let authority_end = after
            .find(|character: char| {
                character.is_whitespace() || matches!(character, '/' | '?' | '#' | '\'' | '"')
            })
            .unwrap_or(after.len());
        let authority = &after[..authority_end];
        if authority
            .find('@')
            .is_some_and(|at| authority[..at].contains(':'))
        {
            return true;
        }
        remainder = &after[authority_end..];
    }
    false
}

pub fn github_actions_mode(log_format: LogFormat, environment: bool) -> bool {
    match log_format {
        LogFormat::Auto => environment,
        LogFormat::GithubActions => true,
        LogFormat::Plain => false,
    }
}

pub fn format_process_line(
    subject: &str,
    stream: Option<ProcessStream>,
    line: &str,
    prefix: bool,
) -> String {
    if !prefix {
        return format!("  │ {line}");
    }
    let stream = match stream {
        Some(ProcessStream::Stdout) => "out",
        Some(ProcessStream::Stderr) => "err",
        None => "log",
    };
    format!("  │ [{subject} {stream}] {line}")
}

/// Classify, sanitize, and attribute one streamed line for the verbose section,
/// or `None` when nothing survives sanitizing. Tone is read from the raw line,
/// so a secret-bearing error line still classifies as a failure even though its
/// body is replaced by the redaction marker.
fn verbose_stream_line(
    subject: &str,
    stream: Option<ProcessStream>,
    line: &str,
    prefix: bool,
) -> Option<(Tone, String)> {
    let tone = verbose_line_tone(line);
    let line = format_verbose_line(line)?;
    Some((tone, format_process_line(subject, stream, &line, prefix)))
}

/// Feed one streamed output line into the verbose section. The reporter decides
/// whether to show it live while the section is open or retain it for the errors
/// view while it is closed, so every producer — native child processes and
/// host-agent jobs alike — routes lines through this one entry point.
///
/// `eligible` lets a producer suppress lines that must never reach the verbose
/// stream, such as activation protocol frames.
pub fn report_verbose_line(
    reporter: &ProgressReporter,
    subject: &str,
    stream: Option<ProcessStream>,
    line: &str,
    prefix: bool,
    eligible: bool,
) {
    if !eligible {
        return;
    }
    let showing = reporter.verbose_showing();
    if !showing && !reporter.retains_verbose_history() {
        return;
    }
    let Some((tone, formatted)) = verbose_stream_line(subject, stream, line, prefix) else {
        return;
    };
    if showing {
        reporter.verbose_line(tone, formatted);
    } else {
        reporter.retain_verbose_line(tone, formatted);
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn build_failure_digest_prefers_cause_over_cascading_nix_errors() {
        use super::super::build::{CommandAttempt, NixStorePath};
        use super::super::build_runtime::{BuildReceipt, validate_remote_build_output};
        let expected = BuildReceipt::new(
            "0123456789abcdef0123456789abcdef",
            NixStorePath::derivation("/nix/store/abc-system.drv").unwrap(),
        )
        .unwrap();
        let stderr = "error: Cannot build '/nix/store/abc-voxtype-onnx.drv'.\n\
        Reason: builder failed with exit code 101.\n\
        >   Unable to find oniguruma in pkg-config\n\
        >   The system library `oniguruma` required by `onig_sys` was not found.\n\
        error: Cannot build '/nix/store/other-home-manager.drv'.\n";
        let attempt = CommandAttempt {
            status: super::super::build::CommandStatus::Exit(101),
            stdout: "abird-build-result-v1\t0123456789abcdef0123456789abcdef\t/nix/store/abc-system.drv\t101\t-\n".to_owned(),
            stderr: stderr.to_owned(),
        };
        let error = validate_remote_build_output(&attempt, &expected).unwrap_err();
        let summary = build_error_summary(&error);
        assert!(summary.contains("Nix build failed (exit 101)"), "{summary}");
        assert!(summary.contains("oniguruma"), "{summary}");
        assert!(!summary.contains("home-manager"), "{summary}");

        let unknown =
            validate_remote_build_output(&CommandAttempt::failure(1, "", stderr), &expected)
                .unwrap_err();
        let summary = build_error_summary(&unknown);
        assert!(summary.contains("unconfirmed"), "{summary}");
        assert!(summary.contains("oniguruma"), "{summary}");
    }

    #[test]
    fn diagnostic_paths_are_reported_only_when_recording_is_healthy() {
        let root = tempfile::tempdir().unwrap();
        let recorder = DiagnosticSink::new(root.path()).unwrap();
        let step = "build-app-via-builder";
        assert_eq!(recorder.build_log(step).unwrap(), None);

        recorder.output(step, ProcessStream::Stderr, "error: unavailable\n");
        let path = recorder.build_log(step).unwrap().unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "error: unavailable\n");

        recorder.close_command_files(&diagnostic_name(step));
        fs::remove_file(&path).unwrap();
        fs::remove_dir_all(&recorder.directory).unwrap();
        recorder.output(step, ProcessStream::Stderr, "another error\n");
        assert!(recorder.build_log(step).is_err());
    }

    #[test]
    fn phase_labels_are_short_and_include_fanout_size() {
        assert_eq!(
            phase_label(Phase::Build, 3, Some((1, 5))),
            "Build systems · 3 hosts · phase 1/5"
        );
        assert_eq!(
            phase_label(Phase::Acquire, 2, None),
            "Acquire deployment artifacts · 2 hosts"
        );
        assert_eq!(
            phase_label(Phase::Health, 1, None),
            "Verify deployment health · 1 host"
        );
        assert_eq!(
            phase_label(Phase::TerraformDns, 0, None),
            "Apply DNS infrastructure"
        );
    }

    #[test]
    fn automatic_log_prefix_tracks_multi_host_attribution_not_input_controls() {
        let mut progress = FleetProgress::from_options(&Options::default());
        progress.reporter = ProgressReporter::new(true);
        assert!(!progress.prefix_logs());
        let guard = progress.reporter.concurrency_handler(|_| true);
        assert!(!progress.prefix_logs());

        progress.phase_started(Phase::Build, &["app".into(), "db".into()], None);
        assert!(progress.prefix_logs());
        progress.phase_admission(1, 1, false, Some("exclusive"));
        assert!(progress.prefix_logs());
        progress.phase_admission(1, 2, false, Some("closed"));
        assert!(progress.prefix_logs());
        drop(guard);
        assert!(progress.prefix_logs());

        let disabled = FleetProgress {
            auto_prefix: false,
            ..progress.clone()
        };
        assert!(!disabled.prefix_logs());
        let explicit = FleetProgress {
            prefix_process_logs: true,
            ..progress.clone()
        };
        assert!(explicit.prefix_logs());

        progress.reporter.end_silent_phase();
        assert!(!progress.prefix_logs());
        progress.phase_started(Phase::Build, &["app".into()], None);
        progress.phase_admission(1, 2, true, None);
        assert!(!progress.prefix_logs());
    }

    #[test]
    fn phase_summary_formats_typed_outcomes_and_keeps_not_run_distinct() {
        for (kind, tone, label) in [
            (PhaseResultKind::Succeeded, Tone::Success, "ok"),
            (PhaseResultKind::Warning, Tone::Warning, "WARN"),
            (PhaseResultKind::Failed, Tone::Failure, "FAIL"),
            (PhaseResultKind::Interrupted, Tone::Warning, "interrupted"),
        ] {
            assert_eq!(
                phase_summary_status(Some(PhaseResult {
                    kind,
                    elapsed: Duration::from_secs(2)
                })),
                (tone, format!("{label} · 2.0s"))
            );
        }
        assert_eq!(
            phase_summary_status(None),
            (Tone::Neutral, "not run".to_owned())
        );
        assert_eq!(compact_phase_label(Phase::Acquire), "acquire");
    }

    #[test]
    fn final_host_status_is_compact_typed_and_composable() {
        let parts = |action, status| {
            host_summary_status(action, status)
                .parts
                .into_iter()
                .flatten()
                .map(|part| (part.tone, part.text))
                .collect::<Vec<_>>()
        };

        assert_eq!(
            parts(
                &Action::Prepare,
                FinalHostState::ok(HostMilestone::Acquired)
            ),
            vec![(Tone::Success, "acquired")]
        );
        assert_eq!(
            parts(
                &Action::Prepare,
                FinalHostState::skipped(HostMilestone::Built, Some(HostStage::Acquire))
            ),
            vec![(Tone::Success, "built"), (Tone::Muted, "skip acquire")]
        );
        assert_eq!(
            parts(
                &Action::Deploy,
                FinalHostState::skipped(HostMilestone::Built, Some(HostStage::Deploy))
            ),
            vec![(Tone::Success, "built"), (Tone::Muted, "skip deploy")]
        );
        assert_eq!(
            parts(
                &Action::Deploy,
                FinalHostState::failed(HostMilestone::Acquired, HostStage::Deploy)
            ),
            vec![(Tone::Success, "acquired"), (Tone::Failure, "fail deploy")]
        );
        assert_eq!(
            parts(
                &Action::Deploy,
                FinalHostState::new(
                    HostMilestone::Built,
                    HostQualifier::OptionalSkipped(HostStage::Snapshot)
                )
            ),
            vec![
                (Tone::Success, "built"),
                (Tone::Warning, "snapshot unavailable")
            ]
        );
        assert_eq!(
            parts(
                &Action::Deploy,
                FinalHostState::new(
                    HostMilestone::Acquired,
                    HostQualifier::RollbackFailed {
                        failed: Some(HostStage::Deploy),
                        optional: false,
                    }
                )
            ),
            vec![
                (Tone::Success, "acquired"),
                (Tone::Failure, "fail deploy"),
                (Tone::Failure, "rollback fail")
            ]
        );
        assert_eq!(
            parts(&Action::Build, FinalHostState::ok(HostMilestone::Built)),
            vec![(Tone::Success, "built")]
        );
        assert_eq!(
            parts(&Action::Deploy, FinalHostState::ok(HostMilestone::Deployed)),
            vec![(Tone::Success, "ok")]
        );
        assert!(
            host_summary_status(
                &Action::Deploy,
                FinalHostState::skipped(HostMilestone::None, None)
            )
            .muted_row
        );
        assert!(
            host_summary_status(
                &Action::Deploy,
                FinalHostState::skipped(HostMilestone::Built, Some(HostStage::Deploy))
            )
            .muted_row
        );
        assert!(
            host_summary_status(
                &Action::Prepare,
                FinalHostState::skipped(HostMilestone::Built, Some(HostStage::Acquire))
            )
            .muted_row
        );
        assert!(
            host_summary_status(
                &Action::Build,
                FinalHostState::skipped(HostMilestone::None, None)
            )
            .muted_row
        );
        assert!(
            !host_summary_status(
                &Action::Deploy,
                FinalHostState::new(
                    HostMilestone::Built,
                    HostQualifier::OptionalSkipped(HostStage::Snapshot)
                )
            )
            .muted_row
        );
        assert!(
            !host_summary_status(
                &Action::Deploy,
                FinalHostState::failed(HostMilestone::Acquired, HostStage::Deploy)
            )
            .muted_row
        );
        assert_eq!(HostStatus::DeploySkip.kind(), HostStatusKind::Skip);
        assert_eq!(HostStatus::DeployBlocked.kind(), HostStatusKind::Warning);
        assert_eq!(HostStatus::AcquireDeferred.kind(), HostStatusKind::Warning);
        assert_eq!(HostStatus::HealthDone.kind(), HostStatusKind::Done);
    }

    #[test]
    fn verbose_lines_can_be_plain_or_attributed() {
        assert_eq!(
            format_process_line("build alpha", Some(ProcessStream::Stderr), "copying", false),
            "  │ copying"
        );
        assert_eq!(
            format_process_line("build alpha", Some(ProcessStream::Stderr), "copying", true),
            "  │ [build alpha err] copying"
        );
    }

    fn progress_task(target: TaskTarget, running: &str) -> ProgressTask {
        ProgressTask {
            reporter: command_reporter().clone(),
            target,
            heartbeat: None,
            prefix: false,
            key: "build#test".to_owned(),
            name: "build".to_owned(),
            running: running.to_owned(),
            done: "build done".to_owned(),
            finalizing: false,
            interrupted: AtomicBool::new(false),
        }
    }

    #[test]
    fn verbose_subject_does_not_repeat_a_self_executing_host() {
        assert_eq!(
            progress_task(TaskTarget::Host("pvl-x2".to_owned()), "build via pvl-x2")
                .verbose_subject(),
            "build via pvl-x2"
        );
        assert_eq!(
            progress_task(TaskTarget::Host("pvl-a1".to_owned()), "build via pvl-x2")
                .verbose_subject(),
            "build via pvl-x2 pvl-a1"
        );
        assert_eq!(
            progress_task(TaskTarget::Host("pvl-a1".to_owned()), "build").verbose_subject(),
            "build pvl-a1"
        );
    }

    #[test]
    fn dashboard_lines_are_allowlisted_sanitized_and_compacted() {
        assert_eq!(
            format_dashboard_line("\x1b[31mbuilding '/nix/store/abc-app.drv'...\x1b[0m"),
            Some("[build] abc-app.drv".to_owned())
        );
        assert_eq!(
            format_dashboard_line("copying 0 paths..."),
            Some("[copy] closure already present".to_owned())
        );
        for line in [
            "copying path '/nix/store/abc-unit.service' to 'ssh-ng://nixbot@host'...",
            "copying path '/nix/store/xyz-asar' from 'https://cache.invalid'...",
        ] {
            let rendered = format_dashboard_line(line).unwrap();
            assert!(rendered.starts_with("[copy] "), "{rendered}");
            assert!(!rendered.contains("ssh-ng"), "{rendered}");
            assert!(!rendered.contains("https://"), "{rendered}");
        }
        for line in [
            "building '/nix/store/foo sk-live-value'...",
            "copying path '/nix/store/foo sk-live-value' to 'ssh-ng://host'...",
            "/nix/store/foo sk-live-value",
            "/nix/store/valid-name/../../sk-live-value",
        ] {
            assert_eq!(format_dashboard_line(line), None, "{line}");
        }
        assert_eq!(
            format_dashboard_line("old frame\rTOKEN=visible\x1b]0;host-title\x07 ready"),
            None
        );
        assert_eq!(format_dashboard_line("arbitrary subprocess chatter"), None);
        assert_eq!(
            format_dashboard_line("[pre-switch] candidate resources ready"),
            Some("[pre-switch] activity; see diagnostics".to_owned())
        );
        assert_eq!(
            format_dashboard_line("[prefetch-podman-image] pulled=3 skipped=1"),
            Some("[prefetch-podman-image] activity; see diagnostics".to_owned())
        );
        for prefix in [
            "[generation-admission]",
            "[prefetch-podman-image]",
            "[prefetch-ai-model]",
            "[pre-switch]",
            "[system-units]",
            "[user-units]",
            "[user-jobs]",
        ] {
            let rendered =
                format_dashboard_line(&format!("{prefix} signing material=sk-live-value")).unwrap();
            assert!(!rendered.contains("sk-live-value"), "{rendered}");
        }
        assert_eq!(
            format_activation_dashboard_line(
                "NOT restarting the following user units: dbus-broker.service",
                ProcessStream::Stdout,
            ),
            Some("NOT restarting the following user units: dbus-broker.service".to_owned())
        );
        assert_eq!(
            format_activation_dashboard_line("Result=exit-code", ProcessStream::Stderr),
            None
        );
        assert_eq!(
            format_activation_dashboard_line(
                "[switch] signing material=sk-live-value",
                ProcessStream::Stdout,
            ),
            None
        );
        assert_eq!(format_dashboard_line("\t\r"), None);
    }

    #[test]
    fn dashboard_preserves_legacy_unit_lifecycle_lines() {
        for line in [
            r#"[system-units] action=restarting count=1 units="dbus-broker.service""#,
            r#"[system-units] action=restart count=0 units="a.service""#,
            r#"[user-units] user=pvl action=starting count=18 units="a.service,b.service,c.service""#,
            r#"[user-units] user=pvl action=stopping count=2 units="a.service, b.service""#,
            "[user-units] user=pvl reload",
        ] {
            assert_eq!(format_dashboard_line(line).as_deref(), Some(line));
        }
        for (label, payload) in [
            (
                "[user-units]",
                r#"user=pvl action=start count=1 units="a.service""#,
            ),
            (
                "[user-units]",
                r#"user=pvl action=starting count=1 units="a:b.service""#,
            ),
            ("[user-units]", "user=bad user reload"),
            (
                "[system-units]",
                r#"action=restarting count=1 units="a\x2db.service""#,
            ),
            ("[system-units]", r#"action=starting count=1 units="""#),
        ] {
            assert_eq!(
                format_dashboard_line(&format!("{label} {payload}")),
                Some(format!("{label} activity; see diagnostics")),
                "{payload}"
            );
        }
    }

    #[test]
    fn activation_dashboard_labels_each_pending_user_manager_job_kind() {
        for action in ["start", "stop", "restart", "reload"] {
            let line = format!(r#"[user-jobs] user=pvl action={action} count=1 units="a.service""#);
            assert_eq!(
                format_activation_dashboard_line(&line, ProcessStream::Stdout),
                Some(format!(
                    "[user-jobs] pvl user manager: 1 pending {action} job: a.service"
                ))
            );
        }
    }

    #[test]
    fn dashboard_preserves_exact_user_job_names_and_caps_the_sample() {
        assert_eq!(
            format_dashboard_line(
                r#"[user-jobs] user=pvl action=start count=5 units="podman:pvl--app.service,podman:pvl-app.service,worker@foo\x2Dbar\x1b.service,other.slice""#
            ).as_deref(),
            Some(r"[user-jobs] pvl user manager: 5 pending start jobs: podman:pvl--app.service, podman:pvl-app.service, worker@foo\x2Dbar\x1b.service (+2)")
        );
        assert_eq!(
            format_dashboard_line(
                r#"[user-jobs] user=pvl action=start count=3 units="my.automount,my.device,my.swap""#
            ).as_deref(),
            Some("[user-jobs] pvl user manager: 3 pending start jobs: my.automount, my.device, my.swap")
        );
        assert_eq!(
            format_dashboard_line(
                r#"[user-jobs] user=pvl action=start count=1 units="a.service,b.service""#
            )
            .as_deref(),
            Some("[user-jobs] pvl user manager: 1 pending start job: a.service")
        );
    }

    #[test]
    fn dashboard_skips_oversized_user_job_names_without_truncating() {
        let oversized = format!("{}.service", "x".repeat(240));
        let shown = format!("{}.service", "a".repeat(60));
        let over_budget = format!("{}.service", "b".repeat(50));
        let line = format!(
            r#"[user-jobs] user=pvl action=reload count=6 units="{oversized},{shown},{over_budget},ok.timer,last.target""#
        );
        assert_eq!(
            format_dashboard_line(&line),
            Some(format!(
                "[user-jobs] pvl user manager: 6 pending reload jobs: {shown}, ok.timer, last.target (+3)"
            ))
        );
    }

    #[test]
    fn dashboard_skips_malformed_user_job_names_and_supports_count_only() {
        assert_eq!(
            format_dashboard_line(
                r#"[user-jobs] user=pvl action=restart count=14 units="bad name.service, a.service,bad%name.service,foo/bar.service,💥.service,.service,@bad.service,wrong.suffix,bad\a.service,bad\x1.service,bad\xQ2.service,,ok.path""#
            ).as_deref(),
            Some("[user-jobs] pvl user manager: 14 pending restart jobs: ok.path (+13)")
        );
        let oversized = format!("{}.service", "x".repeat(240));
        for sample in ["", "bad name.service", oversized.as_str()] {
            let line = format!(r#"[user-jobs] user=pvl action=stop count=7 units="{sample}""#);
            assert_eq!(
                format_dashboard_line(&line).as_deref(),
                Some("[user-jobs] pvl user manager: 7 pending stop jobs")
            );
        }
    }

    #[test]
    fn dashboard_rejects_malformed_user_job_fields() {
        let overflow = format!(r#"user=pvl action=start count={}0 units="""#, usize::MAX);
        for payload in [
            "user=pvl",
            r#"action=start count=1 units="a.service""#,
            r#"user= action=start count=1 units="a.service""#,
            r#"user=bad user action=start count=1 units="a.service""#,
            r#"user=pvl:dev action=start count=1 units="a.service""#,
            r#"user=pvl\x2ddev action=start count=1 units="a.service""#,
            r#"user=pvl action=starting count=1 units="a.service""#,
            r#"user=pvl action=try-restart count=1 units="a.service""#,
            r#"user=pvl action=start count=0 units="""#,
            r#"user=pvl action=start count=-1 units="a.service""#,
            r#"user=pvl action=start count=+1 units="a.service""#,
            r#"user=pvl action=start count=1x units="a.service""#,
            r#"user=pvl action=start count= units="a.service""#,
            &overflow,
            "user=pvl action=start count=1",
            "user=pvl action=start count=1 units=a.service",
            r#"user=pvl action=start count=1 units="a.service" extra="field""#,
        ] {
            assert_eq!(
                format_dashboard_line(&format!("[user-jobs] {payload}")).as_deref(),
                Some("[user-jobs] activity; see diagnostics"),
                "{payload}"
            );
        }
    }

    #[test]
    fn dashboard_keeps_user_job_lines_subject_to_the_output_prefilter() {
        let line =
            r#"[user-jobs] user=pvl action=start count=2 units="ok.service,cookie:demo.service""#;
        assert_eq!(format_dashboard_line(line), None);
        assert_eq!(
            format_activation_dashboard_line(line, ProcessStream::Stdout),
            None
        );
        assert_eq!(
            format_verbose_line(line).as_deref(),
            Some("[sensitive output redacted]")
        );
    }

    #[test]
    fn semantic_host_operation_lines_are_allowlisted_and_normalized() {
        assert_eq!(
            format_operation_dashboard_line(
                "[health-check] attempt 2 · service failure · user=abird failed-unit=abird-agent.service"
            ),
            Some(
                "[health-check] attempt 2 · service failure · user=abird failed-unit=abird-agent.service"
                    .to_owned()
            )
        );
        assert_eq!(
            format_operation_dashboard_line(
                "[health-check] attempt 2 · service failure · user=abird arbitrary sk-live-value"
            ),
            Some(
                "[health-check] attempt 2 · service failure · user=abird runtime issue; see diagnostics"
                    .to_owned()
            )
        );
        assert_eq!(
            format_operation_dashboard_line("arbitrary operation output sk-live-value"),
            None
        );
    }

    #[test]
    fn verbose_output_is_independent_from_dashboard_admission() {
        assert_eq!(
            verbose_stream_line(
                "host",
                Some(ProcessStream::Stdout),
                "ordinary child output",
                true,
            ),
            Some((
                Tone::Neutral,
                "  │ [host out] ordinary child output".to_owned()
            ))
        );
        assert_eq!(
            verbose_stream_line(
                "host",
                Some(ProcessStream::Stderr),
                "OPENAI_API_KEY=secret",
                true,
            ),
            Some((
                Tone::Neutral,
                "  │ [host err] [sensitive output redacted]".to_owned()
            ))
        );
        assert_eq!(
            format_process_dashboard_line(
                OutputPolicy::Curated,
                ProcessStream::Stderr,
                "error: arbitrary subprocess payload",
            ),
            None
        );
        assert_eq!(
            format_process_dashboard_line(
                OutputPolicy::Activation,
                ProcessStream::Stderr,
                "error: arbitrary activation payload",
            ),
            None
        );
    }

    #[test]
    fn a_redacted_error_line_is_still_classified_as_a_failure() {
        // The errors view keeps a secret-bearing failure even though its body is
        // replaced, so tone must come from the raw line before redaction.
        let (tone, text) = verbose_stream_line(
            "host",
            Some(ProcessStream::Stderr),
            "error: token=sk-live-value",
            false,
        )
        .expect("a redacted line still renders");
        assert_eq!(tone, Tone::Failure);
        assert_eq!(text, "  │ [sensitive output redacted]");
    }

    #[test]
    fn machine_protocol_output_is_never_admitted_to_human_progress() {
        let health_record = "user-failed\tabird\tYWJpcmQtYWdlbnQuc2VydmljZQ==";
        assert_eq!(
            format_process_dashboard_line(
                OutputPolicy::Curated,
                ProcessStream::Stdout,
                health_record
            ),
            None
        );
        for marker in [
            "--- abird-activation-result begin ---",
            "OutcomeSource=marker",
            "ExecMainStatus=1",
            "Admitted=1",
            "--- abird-activation-result end ---",
        ] {
            assert_eq!(
                format_process_dashboard_line(
                    OutputPolicy::Activation,
                    ProcessStream::Stderr,
                    marker,
                ),
                None,
                "{marker}"
            );
            assert!(
                !verbose_line_eligible(OutputPolicy::Activation, marker),
                "{marker}"
            );
        }
    }

    #[test]
    fn verbose_and_failure_lines_are_terminal_safe_and_redact_whole_secrets() {
        assert_eq!(
            format_verbose_line("  exact   spacing /nix/store/abc-app\n"),
            Some("  exact   spacing /nix/store/abc-app".to_owned())
        );
        for secret in [
            "TOKEN='abc def' still-secret",
            r#"{\"token\":\"abc def\"}"#,
            "Authorization: Bearer abc",
            "OPENAI_API_KEY=abc",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "fetch https://user:password@example.test/path",
        ] {
            assert_eq!(
                format_verbose_line(secret),
                Some("[sensitive output redacted]".to_owned()),
                "{secret}"
            );
            assert_eq!(
                format_failure_line(secret),
                Some("[sensitive output redacted]".to_owned()),
                "{secret}"
            );
        }
    }

    #[test]
    fn verbose_lines_classify_errors_and_warnings_for_mild_color() {
        assert_eq!(verbose_line_tone("ordinary child output"), Tone::Neutral);
        assert_eq!(
            verbose_line_tone("error: unit failed to start"),
            Tone::Failure
        );
        assert_eq!(verbose_line_tone("✗ /nix/store/x.drv"), Tone::Failure);
        assert_eq!(
            verbose_line_tone("warning: target cache unavailable; retrying"),
            Tone::LogWarning
        );
        // Red wins over amber when a line carries both signals.
        assert_eq!(verbose_line_tone("warning: deploy failed"), Tone::Failure);
        // Zero counters stay neutral; a single non-zero counter colors the line.
        assert_eq!(
            verbose_line_tone("[prefetch-ai-model] ok=13/27 deferred=0 failed=0"),
            Tone::Neutral
        );
        assert_eq!(
            verbose_line_tone("[prefetch-ai-model] ok=13/27 deferred=14 failed=0"),
            Tone::LogWarning
        );
        assert_eq!(
            verbose_line_tone("[prefetch-ai-model] ok=13/27 deferred=0 failed=1"),
            Tone::Failure
        );
    }

    #[test]
    fn verbose_lines_keep_benign_secret_shaped_paths_readable() {
        for line in [
            "copying path '/nix/store/abc-python3.13-secretstorage-3.5.0' to 'ssh-ng://nixbot@host'...",
            "copying path '/nix/store/abc-git-secrets-1.3.0' to 'ssh-ng://nixbot@host'...",
            "copying path '/nix/store/abc-etc-ipsec.secrets' to 'ssh-ng://nixbot@host'...",
            "copying path '/nix/store/abc-libsecret-0.21.7' to 'ssh-ng://nixbot@host'...",
            "copying path '/nix/store/abc-api-token.key.age' to 'ssh-ng://nixbot@host'...",
            "copying path '/nix/store/abc-postgres-password.key.age' to 'ssh-ng://nixbot@host'...",
            "copying path '/nix/store/abc-app-secret' to 'ssh-ng://nixbot@host'...",
        ] {
            assert_eq!(format_verbose_line(line), Some(line.to_owned()), "{line}");
        }
    }

    #[test]
    fn verbose_lines_keep_multi_url_copy_lines_readable() {
        // The relay push prints both the cache source and the target store, and
        // the target-store user must not be read as cache credentials.
        for line in [
            "copying path '/nix/store/abc' from 'http://pvl-x2:5000' to 'ssh-ng://nixbot@pvl-vlab-1'...",
            "copying path '/nix/store/abc' from 'http://cache:5000' to 'ssh-ng://root@192.0.2.42'...",
        ] {
            assert_eq!(format_verbose_line(line), Some(line.to_owned()), "{line}");
        }
        // A genuine credentialed URL is still redacted.
        assert_eq!(
            format_verbose_line("fetch https://user:password@example.test/path"),
            Some("[sensitive output redacted]".to_owned())
        );
    }

    #[test]
    fn plural_secret_fields_are_still_redacted() {
        for secret in [
            "DB_CREDENTIALS=abc",
            "api_tokens=abc",
            "my_secrets: abc",
            "PASSWORDS abc",
        ] {
            assert_eq!(
                format_verbose_line(secret),
                Some("[sensitive output redacted]".to_owned()),
                "{secret}"
            );
        }
    }

    #[test]
    fn host_summaries_are_single_line_bounded_and_redacted() {
        assert_eq!(
            safe_host_summary("first failure\nsecond failure\x1b[31m"),
            "first failure"
        );
        assert_eq!(
            safe_host_summary("OPENAI_API_KEY=abc\nconnection closed"),
            "[sensitive output redacted]"
        );
        assert!(safe_host_summary(&"x".repeat(600)).chars().count() <= 500);
    }

    #[test]
    fn github_group_mode_is_explicit_or_environment_driven() {
        assert!(github_actions_mode(LogFormat::GithubActions, false));
        assert!(github_actions_mode(LogFormat::Auto, true));
        assert!(!github_actions_mode(LogFormat::Plain, true));
    }

    #[test]
    fn github_command_values_escape_multiline_failure_evidence() {
        assert_eq!(
            github_command_value("failed 100%\r\nsecond line"),
            "failed 100%25%0D%0Asecond line"
        );
    }

    #[test]
    fn verbose_options_open_the_section_when_the_command_starts() {
        // `begin_command` owns the initial open state, so dropping that call would
        // silently leave `--verbose`/`--build-logs` rendering nothing until the
        // reader toggled it.
        FleetProgress::begin_command(&Options {
            verbose: true,
            ..Options::default()
        });
        assert!(command_reporter().verbose_showing(), "--verbose opens it");

        FleetProgress::begin_command(&Options {
            build_logs: true,
            ..Options::default()
        });
        assert!(
            command_reporter().verbose_showing(),
            "--build-logs opens it"
        );

        // A plain command starts closed, and leaves the shared reporter closed
        // for the tests that follow.
        FleetProgress::begin_command(&Options::default());
        assert!(
            !command_reporter().verbose_showing(),
            "a plain run starts closed"
        );
    }

    #[test]
    fn a_view_built_mid_run_keeps_the_open_section() {
        // One view is built per phase and per host, so none of them may reset the
        // history or close a section the operator opened.
        FleetProgress::begin_command(&Options {
            verbose: true,
            ..Options::default()
        });
        assert!(command_reporter().verbose_showing(), "the command opens it");

        let _mid_run = FleetProgress::from_options(&Options::default());

        assert!(
            command_reporter().verbose_showing(),
            "a view built mid-run must not close the operator's section"
        );
        FleetProgress::begin_command(&Options::default());
    }

    #[test]
    fn diagnostic_sink_keeps_raw_streams_and_plain_status() {
        let temporary = tempfile::tempdir().unwrap();
        let progress = FleetProgress::from_options(&Options::default())
            .with_diagnostics(temporary.path())
            .unwrap();
        let recorder = progress.recorder().expect("diagnostics recorder");
        recorder.started("build alpha");
        recorder.output("build alpha", ProcessStream::Stdout, "plain output\n");
        recorder.output("build alpha", ProcessStream::Stderr, "plain error\n");
        recorder.finished(
            "build alpha",
            Duration::from_millis(5),
            ProcessCompletion::Succeeded,
        );

        let root = temporary.path().join("commands");
        assert_eq!(
            fs::read_to_string(root.join("build-alpha.stdout.log")).unwrap(),
            "plain output\n"
        );
        assert_eq!(
            fs::read_to_string(root.join("build-alpha.stderr.log")).unwrap(),
            "plain error\n"
        );
        let status = fs::read_to_string(root.join("build-alpha.status")).unwrap();
        assert!(status.starts_with("started\nok "));
        assert!(!status.contains("secret"));
        assert_eq!(
            fs::metadata(root.join("build-alpha.stdout.log"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert!(
            progress
                .diagnostics
                .as_ref()
                .unwrap()
                .state
                .lock()
                .unwrap()
                .files
                .is_empty()
        );
    }
}
