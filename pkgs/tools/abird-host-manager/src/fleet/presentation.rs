use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};

use crate::progress::{ProgressReporter, command_reporter, format_duration};
use crate::terminal_style::Tone;

use super::cli::{LogFormat, Options};
use super::host_runtime::{ProcessCompletion, ProcessRecorder, ProcessStream};
use super::plan::Phase;
use super::task::{StepSpecSource, Task, TaskOutcome, TaskScope};

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

#[derive(Clone, Debug)]
pub struct FleetProgress {
    reporter: ProgressReporter,
    verbose: bool,
    prefix_process_logs: bool,
    github_actions: bool,
    diagnostics: Option<Arc<DiagnosticSink>>,
    build_heartbeat: Option<Duration>,
    activation_heartbeat: Option<Duration>,
}

impl FleetProgress {
    pub fn from_options(options: &Options) -> Self {
        let github_actions = github_actions_mode(
            options.log_format,
            std::env::var("GITHUB_ACTIONS").as_deref() == Ok("true"),
        );
        let reporter = if github_actions {
            command_reporter().clone().without_color()
        } else {
            command_reporter().clone().with_recent_updates(10)
        };
        Self {
            reporter,
            verbose: options.verbose || options.build_logs,
            prefix_process_logs: options.prefix_host_logs,
            github_actions,
            diagnostics: None,
            build_heartbeat: None,
            activation_heartbeat: None,
        }
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
        } else {
            self.reporter.started(label);
            self.reporter.begin_host_dashboard(hosts);
        }
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

    pub fn host_skipped(&self, host: &str, summary: impl Into<String>) {
        self.reporter
            .host_skipped(host, safe_host_summary(&summary.into()));
    }

    pub fn phase_completed(
        &self,
        phase: Phase,
        hosts: usize,
        position: Option<(usize, usize)>,
        elapsed: Duration,
    ) {
        let label = phase_label(phase, hosts, position);
        if self.github_actions {
            self.reporter
                .message(format!("✓ {label}  {}", format_duration(elapsed)));
            self.reporter.message("::endgroup::");
        } else {
            self.reporter.completed(label, elapsed);
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
        let error = safe_error_excerpt(error);
        let label = if self.reporter.shows_recent_updates() {
            format!(
                "{} · phase elapsed {}",
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
        let warning = safe_error_excerpt(warning);
        let label = format!(
            "{} · completed with warnings · phase elapsed {}",
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
        let label = if self.reporter.shows_recent_updates() {
            format!(
                "{} · interrupted · phase elapsed {}",
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
            self.reporter.message("::endgroup::");
        } else {
            self.reporter.interrupt_active(label);
        }
        self.reporter.end_task_scope();
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

    pub fn task_skipped(&self, key: impl Into<String>) {
        let key = key.into();
        self.reporter.task_skipped(key.clone(), process_label(&key));
    }

    pub fn message(&self, message: impl std::fmt::Display) {
        self.reporter.message(message);
    }

    pub fn workflow_summary<'a>(
        &self,
        action: &str,
        phases: impl IntoIterator<Item = (&'a str, &'a str)>,
        hosts: impl IntoIterator<Item = (&'a str, &'a str)>,
        terraform: impl IntoIterator<Item = (&'a str, &'a str)>,
        result: WorkflowResult,
        elapsed: Duration,
    ) {
        let result = result.label();
        let heading = if self.reporter.shows_recent_updates() {
            format!(
                "Summary · {action} · {result} · total elapsed {}",
                format_duration(elapsed)
            )
        } else {
            format!(
                "Summary · {action} · {result} · {}",
                format_duration(elapsed)
            )
        };
        if self.github_actions {
            self.reporter.message(format!("::notice::{heading}"));
        } else {
            self.reporter.heading(heading);
        }
        let phases = phases.into_iter().collect::<Vec<_>>();
        if !phases.is_empty() {
            self.reporter.message("Phases:");
        }
        for (phase, status) in phases {
            let tone = if status.starts_with("FAIL") {
                Tone::Failure
            } else if status.starts_with("WARN") || status.starts_with("interrupted") {
                Tone::Warning
            } else if status.starts_with("ok") {
                Tone::Success
            } else {
                Tone::Neutral
            };
            self.reporter
                .message_primary_with_metadata("  ", tone, phase, format!(" · {status}"));
        }
        let hosts = hosts.into_iter().collect::<Vec<_>>();
        if !hosts.is_empty() {
            self.reporter.message("Hosts:");
        }
        for (host, status) in hosts {
            if status.contains("FAIL")
                || status.contains("failed")
                || status.contains("rollback failed")
            {
                self.reporter.message_primary_with_metadata(
                    "  ",
                    Tone::Failure,
                    format!("{host} · {status}"),
                    "",
                );
            } else if status.contains("skip") || status.contains("optional") {
                let tone = if status.contains("optional") {
                    Tone::Warning
                } else {
                    Tone::Neutral
                };
                self.reporter.message_primary_with_metadata(
                    "  ",
                    tone,
                    format!("{host} · {status}"),
                    "",
                );
            } else {
                let tone = if matches!(status, "ok" | "built") {
                    Tone::Success
                } else {
                    Tone::Neutral
                };
                self.reporter.message_primary_with_metadata(
                    format!("  {host} · "),
                    tone,
                    status,
                    "",
                );
            }
        }
        let terraform = terraform.into_iter().collect::<Vec<_>>();
        if !terraform.is_empty() {
            self.reporter.message("Terraform:");
        }
        for (project, status) in terraform {
            self.reporter
                .message(format!("  Terraform {project} · {status}"));
        }
    }

    pub fn log_block(&self, subject: &str, output: &str) {
        if !self.verbose {
            return;
        }
        for line in output.lines() {
            self.reporter.message(format_process_line(
                subject,
                None,
                line,
                self.prefix_process_logs,
            ));
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
            verbose: self.verbose,
            prefix: self.prefix_process_logs,
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
    verbose: bool,
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
            verbose: self.verbose,
            prefix: self.prefix,
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
    verbose: bool,
    prefix: bool,
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

    /// Retain and render one semantic line for this step.
    fn publish_line(&self, line: String) {
        self.reporter
            .task_output(self.name.clone(), &self.running, line.clone());
        match &self.target {
            TaskTarget::Host(host) => self.reporter.host_task_output(host, &self.name, line),
            TaskTarget::Phase => {
                self.reporter
                    .task_live_output(self.name.clone(), &self.running, line)
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
                    .host_task_started(host, &self.name, &self.running)
            }
            TaskTarget::Phase => self
                .reporter
                .task_started(self.name.clone(), self.running.clone()),
        }
    }

    fn output(&self, stream: ProcessStream, chunk: &str) {
        for line in chunk.lines() {
            let (dashboard_line, verbose_line) =
                format_process_line_views(self.output_policy(), stream, line, self.verbose);
            if let Some(line) = verbose_line {
                self.reporter.message(format_process_line(
                    &process_label(&self.name),
                    Some(stream),
                    &line,
                    self.prefix,
                ));
            }
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
                    .host_task_heartbeat(host, &self.name, &self.running)
            }
            TaskTarget::Phase => {
                self.reporter
                    .task_heartbeat(self.name.clone(), &self.running, elapsed)
            }
        }
    }

    fn finished(&self, elapsed: Duration, outcome: TaskOutcome) {
        match &self.target {
            TaskTarget::Host(host) => match outcome {
                TaskOutcome::Interrupted => {
                    self.reporter
                        .host_task_interrupted(host, &self.name, &self.running, elapsed)
                }
                TaskOutcome::Succeeded if self.finalizing => {
                    self.reporter.host_task_finalizing(
                        host,
                        &self.name,
                        &self.running,
                        &self.done,
                        elapsed,
                    );
                }
                TaskOutcome::Succeeded => {
                    self.reporter.host_task_finished(
                        host,
                        &self.name,
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
                        &self.name,
                        &self.running,
                        &self.done,
                        elapsed,
                        false,
                    );
                }
            },
            TaskTarget::Phase => match outcome {
                TaskOutcome::Interrupted => {
                    self.reporter.task_interrupted(
                        self.name.clone(),
                        self.running.clone(),
                        elapsed,
                    );
                }
                TaskOutcome::Succeeded => self.reporter.task_finished(
                    self.name.clone(),
                    self.running.clone(),
                    elapsed,
                    true,
                ),
                TaskOutcome::Failed => {
                    self.publish_line(FAILURE_HINT.to_owned());
                    self.reporter.task_finished(
                        self.name.clone(),
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

fn process_label(label: &str) -> String {
    for (prefix, action) in [
        ("parent-reconcile-", "Reconcile parent"),
        ("parent-settle-", "Settle parent"),
    ] {
        if let Some(parent) = label.strip_prefix(prefix) {
            return format!("{action} {}", parent.replace(['-', '_'], " "));
        }
    }
    let words = label.replace(['-', '_'], " ");
    let mut characters = words.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
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
        line if format_structured_status_line(line).is_some() => {
            return format_structured_status_line(line);
        }
        line if line.starts_with("reconciled ") || line.starts_with("re-applied ") => line,
        line if line.starts_with("Deploy duration: ") => line,
        _ => return None,
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

fn format_operation_dashboard_line(line: &str) -> Option<String> {
    let line = terminal_safe_line(line);
    if line.starts_with("[ssh] scanning ") {
        return Some("[ssh] scanning configured endpoint".to_owned());
    }
    if line.starts_with("[ssh] no host key returned by ") {
        return Some("[ssh] no host key returned".to_owned());
    }
    if line.starts_with("[ssh] host key discovered via ") {
        return Some("[ssh] host key discovered".to_owned());
    }
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

fn format_process_line_views(
    policy: OutputPolicy,
    stream: ProcessStream,
    line: &str,
    verbose: bool,
) -> (Option<String>, Option<String>) {
    let protocol = policy == OutputPolicy::Activation && activation_protocol_line(line);
    (
        format_process_dashboard_line(policy, stream, line),
        (verbose && !protocol)
            .then(|| format_verbose_line(line))
            .flatten(),
    )
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
    let named_secret = [
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
        "-----begin",
        "credential",
        "authorization:",
        "bearer ",
        "cookie:",
        "set-cookie:",
    ]
    .iter()
    .any(|needle| lowercase.contains(needle));
    let credential_url = lowercase.find("://").is_some_and(|scheme| {
        lowercase[scheme + 3..]
            .find('@')
            .is_some_and(|at| lowercase[scheme + 3..scheme + 3 + at].contains(':'))
    });
    named_secret || credential_url
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

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    use super::*;

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
        assert_eq!(
            format_dashboard_line(
                "[system-units] action=restarting count=1 units=\"dbus-broker.service\""
            ),
            Some(
                "[system-units] action=restarting count=1 units=\"dbus-broker.service\"".to_owned()
            )
        );
        for prefix in [
            "[generation-admission]",
            "[prefetch-podman-image]",
            "[prefetch-ai-model]",
            "[pre-switch]",
            "[system-units]",
            "[user-units]",
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
    fn semantic_host_operation_lines_are_allowlisted_and_normalized() {
        assert_eq!(
            format_operation_dashboard_line("[ssh] scanning secret-host.example:22"),
            Some("[ssh] scanning configured endpoint".to_owned())
        );
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
            format_process_line_views(
                OutputPolicy::Curated,
                ProcessStream::Stdout,
                "ordinary child output",
                true,
            ),
            (None, Some("ordinary child output".to_owned()))
        );
        assert_eq!(
            format_process_line_views(
                OutputPolicy::Curated,
                ProcessStream::Stderr,
                "OPENAI_API_KEY=secret",
                true,
            ),
            (None, Some("[sensitive output redacted]".to_owned()))
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
            assert_eq!(
                format_process_line_views(
                    OutputPolicy::Activation,
                    ProcessStream::Stderr,
                    marker,
                    true,
                ),
                (None, None),
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
    fn internal_process_labels_render_as_human_status() {
        assert_eq!(
            process_label("pre-switch-preparation"),
            "Pre switch preparation"
        );
        assert_eq!(process_label("remote_build"), "Remote build");
        assert_eq!(
            process_label("parent-reconcile-gap3-gondor"),
            "Reconcile parent gap3 gondor"
        );
        assert_eq!(
            process_label("parent-settle-gap3-gondor"),
            "Settle parent gap3 gondor"
        );
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
