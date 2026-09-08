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

use super::cli::{LogFormat, Options};
use super::host_runtime::{ProcessEventObserver, ProcessRequest, ProcessStream};
use super::plan::Phase;

static FLEET_FAILURE_PRESENTED: AtomicBool = AtomicBool::new(false);

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
            command_reporter().clone()
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

    pub fn phase_started(&self, phase: Phase, hosts: usize) {
        let label = phase_label(phase, hosts);
        if self.github_actions {
            self.reporter.message(format!("::group::{label}"));
        } else {
            self.reporter.started(label);
        }
    }

    pub fn phase_completed(&self, phase: Phase, hosts: usize, elapsed: Duration) {
        let label = phase_label(phase, hosts);
        if self.github_actions {
            self.reporter
                .message(format!("✓ {label}  {}", format_duration(elapsed)));
            self.reporter.message("::endgroup::");
        } else {
            self.reporter.completed(label, elapsed);
        }
    }

    pub fn phase_failed(&self, phase: Phase, hosts: usize, elapsed: Duration, error: &str) {
        let label = format!(
            "{} · {}",
            phase_label(phase, hosts),
            format_duration(elapsed)
        );
        if self.github_actions {
            self.reporter.message(format!("::error::{label}: {error}"));
            self.reporter.message("::endgroup::");
        } else {
            self.reporter.fail_active(label, error);
        }
        FLEET_FAILURE_PRESENTED.store(true, Ordering::Release);
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

    pub fn message(&self, message: impl std::fmt::Display) {
        self.reporter.message(message);
    }

    pub fn workflow_summary<'a>(
        &self,
        action: &str,
        hosts: impl IntoIterator<Item = (&'a str, &'a str)>,
        terraform: impl IntoIterator<Item = (&'a str, &'a str)>,
        succeeded: bool,
        elapsed: Duration,
    ) {
        let result = if succeeded { "success" } else { "failure" };
        let heading = format!(
            "Summary · {action} · {result} · {}",
            format_duration(elapsed)
        );
        if self.github_actions {
            self.reporter.message(format!("::notice::{heading}"));
        } else {
            self.reporter.message(heading);
        }
        for (host, status) in hosts {
            self.reporter.message(format!("  {host} · {status}"));
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
        self.reporter
            .detail(format!("{} · running", process_label(&request.label)));
    }

    fn output(&self, request: &ProcessRequest, stream: ProcessStream, chunk: &str) {
        if let Some(diagnostics) = &self.diagnostics {
            diagnostics.output(request, stream, chunk);
        }
        if !self.verbose {
            return;
        }
        for line in chunk.lines() {
            self.reporter.message(format_process_line(
                &process_label(&request.label),
                Some(stream),
                line,
                self.prefix,
            ));
        }
    }

    fn finished(&self, request: &ProcessRequest, elapsed: Duration, succeeded: bool) {
        if let Some(diagnostics) = &self.diagnostics {
            diagnostics.finished(request, elapsed, succeeded);
        }
        self.reporter.detail(format!(
            "{} · {} · {}",
            process_label(&request.label),
            if succeeded { "done" } else { "failed" },
            format_duration(elapsed)
        ));
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
        self.reporter.detail(format!(
            "{} · running · {} elapsed",
            process_label(&request.label),
            format_duration(elapsed)
        ));
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

    fn finished(&self, request: &ProcessRequest, elapsed: Duration, succeeded: bool) {
        self.append(
            &format!("{}.status", diagnostic_name(&request.label)),
            format!(
                "{} {}\n",
                if succeeded { "ok" } else { "failed" },
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

pub fn phase_label(phase: Phase, hosts: usize) -> String {
    let action = match phase {
        Phase::TerraformDns => "Apply DNS infrastructure",
        Phase::TerraformPlatform => "Apply platform infrastructure",
        Phase::TerraformApps => "Apply application infrastructure",
        Phase::Tofu => "Apply infrastructure project",
        Phase::Build => "Build systems",
        Phase::Snapshot => "Snapshot generations",
        Phase::Deploy => "Deploy systems",
        Phase::Health => "Verify deployment health",
        Phase::DevelopmentBuild => "Build development system",
        Phase::BootstrapCheck => "Check bootstrap access",
        Phase::Clean => "Clean runtime state",
        Phase::RepositorySync => "Synchronize repository",
        Phase::DependencyCheck => "Check runtime dependencies",
    };
    match hosts {
        0 => action.to_owned(),
        1 => format!("{action} · 1 host"),
        count => format!("{action} · {count} hosts"),
    }
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
        assert_eq!(phase_label(Phase::Build, 3), "Build systems · 3 hosts");
        assert_eq!(
            phase_label(Phase::Health, 1),
            "Verify deployment health · 1 host"
        );
        assert_eq!(
            phase_label(Phase::TerraformDns, 0),
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
    fn github_group_mode_is_explicit_or_environment_driven() {
        assert!(github_actions_mode(LogFormat::GithubActions, false));
        assert!(github_actions_mode(LogFormat::Auto, true));
        assert!(!github_actions_mode(LogFormat::Plain, true));
    }

    #[test]
    fn internal_process_labels_render_as_human_status() {
        assert_eq!(
            process_label("pre-switch-admission"),
            "Pre switch admission"
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
            cwd: temporary.path().to_path_buf(),
            stdin: Some("secret-input-is-not-logged".to_owned()),
            effect: super::super::host_runtime::EffectKind::ReadOnly,
            label: "build alpha".to_owned(),
        };
        observer.started(&request);
        observer.output(&request, ProcessStream::Stdout, "plain output\n");
        observer.output(&request, ProcessStream::Stderr, "plain error\n");
        observer.finished(&request, Duration::from_millis(5), true);

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
