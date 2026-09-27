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
use super::host_runtime::{ProcessCompletion, ProcessEventObserver, ProcessRequest, ProcessStream};
use super::plan::Phase;

static FLEET_FAILURE_PRESENTED: AtomicBool = AtomicBool::new(false);
static FLEET_WARNING_PRESENTED: AtomicBool = AtomicBool::new(false);

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
            } else {
                Tone::Success
            };
            self.reporter
                .message_tone(tone, format!("  {phase} · {status}"));
        }
        let hosts = hosts.into_iter().collect::<Vec<_>>();
        if !hosts.is_empty() {
            self.reporter.message("Hosts:");
        }
        for (host, status) in hosts {
            let tone = if status.contains("FAIL")
                || status.contains("failed")
                || status.contains("rollback failed")
            {
                Tone::Failure
            } else if status.contains("skip") || status.contains("optional") {
                Tone::Warning
            } else {
                Tone::Success
            };
            self.reporter
                .message_tone(tone, format!("  {host} · {status}"));
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

    pub fn process_observer(&self) -> Arc<dyn ProcessEventObserver> {
        Arc::new(FleetProcessObserver {
            reporter: self.reporter.clone(),
            verbose: self.verbose,
            prefix: self.prefix_process_logs,
            diagnostics: self.diagnostics.clone(),
            build_heartbeat: self.build_heartbeat,
            activation_heartbeat: self.activation_heartbeat,
        })
    }
}

pub fn take_failure_presented() -> bool {
    FLEET_FAILURE_PRESENTED.swap(false, Ordering::AcqRel)
}

pub fn take_warning_presented() -> bool {
    FLEET_WARNING_PRESENTED.swap(false, Ordering::AcqRel)
}

#[derive(Clone, Debug)]
struct FleetProcessObserver {
    reporter: ProgressReporter,
    verbose: bool,
    prefix: bool,
    diagnostics: Option<Arc<DiagnosticSink>>,
    build_heartbeat: Option<Duration>,
    activation_heartbeat: Option<Duration>,
}

impl ProcessEventObserver for FleetProcessObserver {
    fn started(&self, request: &ProcessRequest) {
        if let Some(diagnostics) = &self.diagnostics {
            diagnostics.started(request);
        }
        let label = process_label(&request.label);
        if let Some(host) = &request.host {
            self.reporter
                .host_task_started(host, &request.label, &label);
        } else {
            self.reporter.task_started(request.label.clone(), label);
        }
    }

    fn output(&self, request: &ProcessRequest, stream: ProcessStream, chunk: &str) {
        if let Some(diagnostics) = &self.diagnostics {
            diagnostics.output(request, stream, chunk);
        }
        for line in chunk.lines() {
            let Some(failure_line) = format_failure_line(line) else {
                continue;
            };
            let label = process_label(&request.label);
            self.reporter
                .task_output(request.label.clone(), &label, failure_line.clone());
            if let Some(host) = &request.host {
                if let Some(line) =
                    format_dashboard_line(line).or_else(|| format_failure_dashboard_line(line))
                {
                    self.reporter.host_task_output(host, &request.label, line);
                }
            } else if let Some(line) = format_dashboard_line(line) {
                self.reporter
                    .task_live_output(request.label.clone(), &label, line);
            }
            if self.verbose {
                let Some(line) = format_verbose_line(line) else {
                    continue;
                };
                self.reporter.message(format_process_line(
                    &label,
                    Some(stream),
                    &line,
                    self.prefix,
                ));
            }
        }
    }

    fn finished(&self, request: &ProcessRequest, elapsed: Duration, completion: ProcessCompletion) {
        if let Some(diagnostics) = &self.diagnostics {
            diagnostics.finished(request, elapsed, completion);
        }
        if completion == ProcessCompletion::Interrupted {
            self.reporter.task_interrupted(
                request.label.clone(),
                process_label(&request.label),
                elapsed,
            );
            return;
        }
        let label = process_label(&request.label);
        if let Some(host) = &request.host {
            self.reporter.host_task_finished(
                host,
                &request.label,
                &label,
                elapsed,
                completion == ProcessCompletion::Succeeded,
            );
        } else {
            self.reporter.task_finished(
                request.label.clone(),
                label,
                elapsed,
                completion == ProcessCompletion::Succeeded,
            );
        }
    }

    fn heartbeat_interval(&self, request: &ProcessRequest) -> Option<Duration> {
        if request.label.contains("activation") || request.label.contains("rollback") {
            self.activation_heartbeat
        } else if request.label.contains("build") || request.label.contains("realize") {
            self.build_heartbeat
        } else {
            None
        }
    }

    fn heartbeat(&self, request: &ProcessRequest, elapsed: Duration) {
        if let Some(host) = &request.host {
            self.reporter
                .host_task_heartbeat(host, &request.label, &process_label(&request.label));
        } else {
            self.reporter.task_heartbeat(
                request.label.clone(),
                process_label(&request.label),
                elapsed,
            );
        }
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

    fn started(&self, request: &ProcessRequest) {
        self.append(
            &format!("{}.status", diagnostic_name(&request.label)),
            b"started\n",
        );
    }

    fn output(&self, request: &ProcessRequest, stream: ProcessStream, chunk: &str) {
        let stream = match stream {
            ProcessStream::Stdout => "stdout",
            ProcessStream::Stderr => "stderr",
        };
        self.append(
            &format!("{}.{}.log", diagnostic_name(&request.label), stream),
            chunk.as_bytes(),
        );
    }

    fn finished(&self, request: &ProcessRequest, elapsed: Duration, completion: ProcessCompletion) {
        self.append(
            &format!("{}.status", diagnostic_name(&request.label)),
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
    if let Some(path) = quoted_store_path(&line, "copying path '", "'") {
        return Some(format!("[copy] {}", store_basename(path)));
    }
    if line.starts_with("/nix/store/") {
        return Some(format!("[store] {}", store_basename(&line)));
    }
    let normalized = match line.trim() {
        "Checking switch inhibitors... done" => "[switch] inhibitors ok",
        "activating the configuration..." => "[switch] activating configuration",
        "setting up /etc..." => "[switch] updating /etc",
        "[agenix] decrypting secrets..." => "[agenix] decrypting secrets",
        "[agenix] chowning..." => "[agenix] fixing ownership",
        line if dashboard_status_prefix(line).is_some() => line,
        line if line.starts_with("reconciled ") || line.starts_with("re-applied ") => line,
        line if line.starts_with("Deploy duration: ") => line,
        _ => return None,
    };
    Some(normalized.to_owned())
}

fn format_failure_dashboard_line(line: &str) -> Option<String> {
    let line = terminal_safe_line(line);
    if line.is_empty() || sensitive_output(&line) {
        return None;
    }
    let lowercase = line.to_ascii_lowercase();
    [
        "error",
        "failed",
        "failure",
        "denied",
        "unavailable",
        "timeout",
        "timed out",
        "connection",
        "refused",
        "closed",
        "reset",
        "no route",
        "could not",
        "cannot",
        "exit",
        "signal",
        "rejected",
        "missing",
        "not found",
        "command not found",
        "start-limit",
        "status=",
        "result=",
    ]
    .iter()
    .any(|needle| lowercase.contains(needle))
    .then(|| format_failure_line(&line))
    .flatten()
}

fn dashboard_status_prefix(line: &str) -> Option<&str> {
    [
        "[agenix]",
        "[generation-admission]",
        "[health-check]",
        "[prefetch-ai-model]",
        "[store]",
        "[switch]",
        "[system-units]",
        "[user-units]",
    ]
    .into_iter()
    .find(|prefix| line.starts_with(prefix))
}

fn format_verbose_line(line: &str) -> Option<String> {
    let line = redact_sensitive_line(terminal_safe_line(line));
    (!line.is_empty()).then_some(line)
}

pub(crate) fn format_failure_line(line: &str) -> Option<String> {
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
        .filter(|path| path.starts_with("/nix/store/"))
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
        assert_eq!(
            format_dashboard_line("old frame\rTOKEN=visible\x1b]0;host-title\x07 ready"),
            None
        );
        assert_eq!(format_dashboard_line("arbitrary subprocess chatter"), None);
        assert_eq!(
            format_failure_dashboard_line("arbitrary subprocess chatter"),
            None
        );
        assert_eq!(
            format_failure_dashboard_line("error: connection closed by peer"),
            Some("error: connection closed by peer".to_owned())
        );
        assert_eq!(format_dashboard_line("\t\r"), None);
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
    }

    #[test]
    fn diagnostic_sink_keeps_raw_streams_and_plain_status() {
        let temporary = tempfile::tempdir().unwrap();
        let progress = FleetProgress::from_options(&Options::default())
            .with_diagnostics(temporary.path())
            .unwrap();
        let observer = progress.process_observer();
        let request = ProcessRequest {
            program: "tool".to_owned(),
            args: vec!["secret-argument-is-not-logged".to_owned()],
            environment: Vec::new(),
            clear_git_repository_environment: false,
            cwd: temporary.path().to_path_buf(),
            stdin: Some("secret-input-is-not-logged".to_owned()),
            effect: super::super::host_runtime::EffectKind::ReadOnly,
            label: "build alpha".to_owned(),
            host: None,
        };
        observer.started(&request);
        observer.output(&request, ProcessStream::Stdout, "plain output\n");
        observer.output(&request, ProcessStream::Stderr, "plain error\n");
        observer.finished(
            &request,
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
    }
}
