// Native process and SSH adapter for the pure fleet contracts.
//
// Values from inventory and command planners remain argv entries. Remote argv
// is base64 framed into a constant stdin decoder, avoiding interpolation into
// a login-shell command. The only exception is the intentionally restricted
// forced-command readiness probe, whose arguments are validated first.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{self, Read, Write};
#[cfg(not(unix))]
use std::io::{BufRead, BufReader};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

#[cfg(unix)]
use std::os::fd::AsRawFd;

use anyhow::{Context, Result, bail};
use base64::Engine as _;

use crate::programs::clear_git_repository_environment;

use super::bootstrap::ForcedCommandPlan;
use super::build::{
    self, CacheSource, CommandAttempt, CommandSpec, CommandStatus,
    FailureEvidence as BuildFailureEvidence, NixStorePath, RemoteBuildOutput, RetryDecision,
    RetryPolicy, RetryTracker,
};
use super::build_lease::LeaseProcessSpec;
use super::build_runtime::{RemoteBuildTools, builder_lease_hold_command};
use super::deploy::{
    self, ActivationGoal, ActivationSample, DeployDecision, GenerationSnapshot, RemoteCommand,
    SnapshotRequirement, SystemGeneration, VerificationDecision,
};
use super::health::{
    self, AgentStatusResponse, DurableHoldResponse, HealthDecision, PodmanContainer, PodmanHealth,
    SystemdJob, UnitSnapshot,
};
use super::system::ResolvedHost;
use super::task::{InternalTask, Task};
use super::transport::{
    HostKeyPolicy, ProcessStatus, ProxyHop, SshEndpoint, SshRoutePlan, TransportRole,
};

const SYSTEM_BASH: &str = "/run/current-system/sw/bin/bash";
const SYSTEM_BASE64: &str = "/run/current-system/sw/bin/base64";
const SYSTEM_ENV: &str = "/run/current-system/sw/bin/env";
const SYSTEM_SUDO: &str = "/run/wrappers/bin/sudo";
const REMOTE_RUNTIME_PATH: &str = "/run/wrappers/bin:/run/current-system/sw/bin";
const UNIX_SOCKET_PATH_LIMIT_BYTES: usize = 108;
/// Grace between SIGTERM and SIGKILL when a bounded read exceeds its deadline.
const BOUNDED_READ_KILL_AFTER: Duration = Duration::from_secs(5);
/// Exit status reported for a bounded read that exceeded its deadline.
const TIMEOUT_EXIT_CODE: i32 = 124;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DryRun {
    No,
    Yes,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EffectKind {
    ReadOnly,
    /// Realize or copy immutable Nix store paths. Dry deploys deliberately
    /// execute these effects so they validate the complete build boundary.
    Build,
    Mutation,
}

#[derive(Clone, Debug)]
pub struct ProcessRequest {
    pub program: String,
    pub args: Vec<String>,
    pub environment: Vec<(String, String)>,
    pub clear_git_repository_environment: bool,
    pub cwd: PathBuf,
    pub stdin: Option<String>,
    pub effect: EffectKind,
    /// Progress identity: the diagnostic name lives on the task, and any step
    /// row is rendered from the same handle.
    pub task: Arc<dyn Task>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProcessOutput {
    pub status: ProcessStatus,
    pub stdout: String,
    pub stderr: String,
    pub skipped: bool,
}

impl ProcessOutput {
    pub fn succeeded(&self) -> bool {
        self.status == ProcessStatus::Code(0)
    }

    fn dry_run() -> Self {
        Self {
            status: ProcessStatus::Code(0),
            stdout: String::new(),
            stderr: String::new(),
            skipped: true,
        }
    }

    pub(crate) fn combined_output(&self) -> String {
        match (self.stdout.is_empty(), self.stderr.is_empty()) {
            (true, _) => self.stderr.clone(),
            (_, true) => self.stdout.clone(),
            (false, false) => format!("{}\n{}", self.stdout, self.stderr),
        }
    }
}

pub trait ProcessRunner {
    fn run(&mut self, request: &ProcessRequest) -> io::Result<ProcessOutput>;

    /// Run `request`, terminating it if it does not finish within `timeout`.
    ///
    /// Required rather than defaulted so a runner that cannot enforce a
    /// deadline must decide explicitly instead of silently accepting one.
    fn run_with_timeout(
        &mut self,
        request: &ProcessRequest,
        timeout: Duration,
    ) -> io::Result<ProcessOutput>;

    fn wait(&mut self, duration: Duration);

    fn activation_started(&self) {}
    fn activation_finished(&self) {}
    fn force_remote_cancellation(&self) -> bool {
        false
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProcessStream {
    Stdout,
    Stderr,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProcessCompletion {
    Succeeded,
    Failed,
    Interrupted,
}

/// Process diagnostics, independent of progress display.
pub trait ProcessRecorder: Send + Sync {
    fn started(&self, name: &str);
    fn output(&self, name: &str, stream: ProcessStream, chunk: &str);
    fn finished(&self, name: &str, elapsed: Duration, completion: ProcessCompletion);
}

/// Fans one process's output to both its progress task and the diagnostic
/// recorder, so display and retained diagnostics never diverge.
#[derive(Clone)]
struct ProcessSink {
    name: String,
    task: Arc<dyn Task>,
    recorder: Option<Arc<dyn ProcessRecorder>>,
}

impl ProcessSink {
    fn output(&self, stream: ProcessStream, chunk: &str) {
        if let Some(recorder) = &self.recorder {
            recorder.output(&self.name, stream, chunk);
        }
        self.task.output(stream, chunk);
    }
}

pub trait ProcessCancellation: Send + Sync {
    fn activation_started(&self);
    fn activation_finished(&self);
    fn cancel_local(&self) -> bool;
    fn force_remote(&self) -> bool;
}

#[derive(Default)]
pub struct SystemProcessRunner;

impl SystemProcessRunner {
    fn run_with_deadline(
        &self,
        request: &ProcessRequest,
        timeout: Option<Duration>,
    ) -> io::Result<ProcessOutput> {
        let sink = ProcessSink {
            name: request.task.name().to_owned(),
            task: Arc::clone(&request.task),
            recorder: None,
        };
        run_process(request, sink, None, timeout)
    }
}

impl ProcessRunner for SystemProcessRunner {
    fn run(&mut self, request: &ProcessRequest) -> io::Result<ProcessOutput> {
        self.run_with_deadline(request, None)
    }

    fn run_with_timeout(
        &mut self,
        request: &ProcessRequest,
        timeout: Duration,
    ) -> io::Result<ProcessOutput> {
        self.run_with_deadline(request, Some(timeout))
    }

    fn wait(&mut self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

pub struct ProcessExecutor {
    recorder: Option<Arc<dyn ProcessRecorder>>,
    cancellation: Option<Arc<dyn ProcessCancellation>>,
}

impl ProcessExecutor {
    pub fn new(recorder: Option<Arc<dyn ProcessRecorder>>) -> Self {
        Self {
            recorder,
            cancellation: None,
        }
    }

    pub fn with_cancellation(mut self, cancellation: Arc<dyn ProcessCancellation>) -> Self {
        self.cancellation = Some(cancellation);
        self
    }
}

impl ProcessExecutor {
    fn run_inner(
        &mut self,
        request: &ProcessRequest,
        timeout: Option<Duration>,
    ) -> io::Result<ProcessOutput> {
        let started = Instant::now();
        let name = request.task.name().to_owned();
        if let Some(recorder) = &self.recorder {
            recorder.started(&name);
        }
        let sink = ProcessSink {
            name: name.clone(),
            task: Arc::clone(&request.task),
            recorder: self.recorder.clone(),
        };
        let result = run_process(request, sink, self.cancellation.as_deref(), timeout);
        let completion = if result.as_ref().is_ok_and(ProcessOutput::succeeded) {
            ProcessCompletion::Succeeded
        } else if self
            .cancellation
            .as_ref()
            .is_some_and(|cancellation| cancellation.cancel_local())
        {
            ProcessCompletion::Interrupted
        } else {
            ProcessCompletion::Failed
        };
        if completion == ProcessCompletion::Interrupted {
            request.task.mark_interrupted();
        }
        if let Some(recorder) = &self.recorder {
            recorder.finished(&name, started.elapsed(), completion);
        }
        result
    }
}

impl ProcessRunner for ProcessExecutor {
    fn run(&mut self, request: &ProcessRequest) -> io::Result<ProcessOutput> {
        self.run_inner(request, None)
    }

    fn run_with_timeout(
        &mut self,
        request: &ProcessRequest,
        timeout: Duration,
    ) -> io::Result<ProcessOutput> {
        self.run_inner(request, Some(timeout))
    }

    fn wait(&mut self, duration: Duration) {
        let started = Instant::now();
        while started.elapsed() < duration {
            if self
                .cancellation
                .as_ref()
                .is_some_and(|cancellation| cancellation.cancel_local())
            {
                break;
            }
            std::thread::sleep(
                duration
                    .saturating_sub(started.elapsed())
                    .min(Duration::from_millis(100)),
            );
        }
    }

    fn activation_started(&self) {
        if let Some(cancellation) = &self.cancellation {
            cancellation.activation_started();
        }
    }

    fn activation_finished(&self) {
        if let Some(cancellation) = &self.cancellation {
            cancellation.activation_finished();
        }
    }

    fn force_remote_cancellation(&self) -> bool {
        self.cancellation
            .as_ref()
            .is_some_and(|cancellation| cancellation.force_remote())
    }
}

fn run_process(
    request: &ProcessRequest,
    sink: ProcessSink,
    cancellation: Option<&dyn ProcessCancellation>,
    timeout: Option<Duration>,
) -> io::Result<ProcessOutput> {
    let started = Instant::now();
    let mut command = Command::new(&request.program);
    command
        .args(&request.args)
        .current_dir(&request.cwd)
        .stdin(if request.stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (name, value) in &request.environment {
        command.env(name, value);
    }
    if request.clear_git_repository_environment {
        clear_git_repository_environment(&mut command);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        command.process_group(0);
    }
    let mut child = command.spawn()?;
    if let (Some(input), Some(mut stdin)) = (&request.stdin, child.stdin.take()) {
        stdin.write_all(input.as_bytes())?;
    }
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("child stdout pipe is unavailable"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| io::Error::other("child stderr pipe is unavailable"))?;
    let child_exited = Arc::new(AtomicBool::new(false));
    let stdout_sink = sink.clone();
    let stdout_child_exited = Arc::clone(&child_exited);
    let stdout_thread = std::thread::spawn(move || {
        observe_stream(
            stdout,
            ProcessStream::Stdout,
            stdout_sink,
            &stdout_child_exited,
        )
    });
    let stderr_sink = sink.clone();
    let stderr_child_exited = Arc::clone(&child_exited);
    let stderr_thread = std::thread::spawn(move || {
        observe_stream(
            stderr,
            ProcessStream::Stderr,
            stderr_sink,
            &stderr_child_exited,
        )
    });
    let heartbeat_interval = sink.task.heartbeat_interval();
    let mut next_heartbeat = heartbeat_interval;
    #[cfg(unix)]
    let deadline = timeout.map(|timeout| started + timeout);
    #[cfg(unix)]
    let mut timed_out = false;
    #[cfg(unix)]
    let mut kill_deadline: Option<Instant> = None;
    #[cfg(not(unix))]
    let _ = timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if cancellation.is_some_and(ProcessCancellation::cancel_local) {
            terminate_process_group(&mut child)?;
            break child.wait()?;
        }
        #[cfg(unix)]
        if let Some(deadline) = deadline {
            if kill_deadline.is_none() && Instant::now() >= deadline {
                timed_out = true;
                signal_process_group(&child, libc::SIGTERM)?;
                kill_deadline = Some(Instant::now() + BOUNDED_READ_KILL_AFTER);
            } else if kill_deadline.is_some_and(|kill_at| Instant::now() >= kill_at) {
                signal_process_group(&child, libc::SIGKILL)?;
            }
        }
        if next_heartbeat.is_some_and(|next| started.elapsed() >= next) {
            sink.task.heartbeat(started.elapsed());
            next_heartbeat = heartbeat_interval.map(|interval| started.elapsed() + interval);
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    // A daemon or detached descendant can retain a duplicate of a child's
    // output descriptor after the direct child has exited. Do not let that
    // unrelated writer keep process completion or signal handling blocked.
    // Stream readers drain bytes already available, then stop at this boundary.
    child_exited.store(true, Ordering::Release);
    let stdout = stdout_thread
        .join()
        .map_err(|_| io::Error::other("stdout observer thread panicked"))??;
    let stderr = stderr_thread
        .join()
        .map_err(|_| io::Error::other("stderr observer thread panicked"))??;
    #[cfg(unix)]
    let status = if timed_out {
        ProcessStatus::Code(TIMEOUT_EXIT_CODE)
    } else {
        use std::os::unix::process::ExitStatusExt as _;
        status
            .code()
            .map(ProcessStatus::Code)
            .or_else(|| status.signal().map(ProcessStatus::Signal))
            .unwrap_or(ProcessStatus::Code(1))
    };
    #[cfg(not(unix))]
    let status = ProcessStatus::Code(status.code().unwrap_or(1));
    Ok(ProcessOutput {
        status,
        stdout,
        stderr,
        skipped: false,
    })
}

/// Signal the process group created for `child` without reaping it.
#[cfg(unix)]
fn signal_process_group(child: &std::process::Child, signal: i32) -> io::Result<()> {
    let process_group = -(child.id() as i32);
    // SAFETY: the child is placed in a process group whose id is its pid at
    // spawn, so a negative pid targets that group and never the manager.
    let result = unsafe { libc::kill(process_group, signal) };
    if result != 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::ESRCH) {
            return Err(error);
        }
    }
    Ok(())
}

#[cfg(unix)]
fn terminate_process_group(child: &mut std::process::Child) -> io::Result<()> {
    signal_process_group(child, libc::SIGTERM)?;
    let started = Instant::now();
    while started.elapsed() < Duration::from_secs(2) {
        if child.try_wait()?.is_some() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    signal_process_group(child, libc::SIGKILL)?;
    Ok(())
}

#[cfg(not(unix))]
fn terminate_process_group(child: &mut std::process::Child) -> io::Result<()> {
    child.kill()
}

#[cfg(unix)]
fn observe_stream(
    mut reader: impl Read + AsRawFd,
    stream: ProcessStream,
    sink: ProcessSink,
    child_exited: &AtomicBool,
) -> io::Result<String> {
    const POLL_INTERVAL_MILLIS: i32 = 50;
    let mut bytes = Vec::new();
    let mut emitted = 0;
    let mut buffer = [0_u8; 8192];
    let mut descriptor = libc::pollfd {
        fd: reader.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    loop {
        descriptor.revents = 0;
        // SAFETY: `descriptor` points to one initialized pollfd for the live
        // reader descriptor, and the call cannot outlive `reader`.
        let ready = unsafe { libc::poll(&mut descriptor, 1, POLL_INTERVAL_MILLIS) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if ready > 0 && descriptor.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => {
                    bytes.extend_from_slice(&buffer[..count]);
                    while let Some(relative) =
                        bytes[emitted..].iter().position(|byte| *byte == b'\n')
                    {
                        let end = emitted + relative + 1;
                        sink.output(stream, &String::from_utf8_lossy(&bytes[emitted..end]));
                        emitted = end;
                    }
                    continue;
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        if child_exited.load(Ordering::Acquire) {
            break;
        }
    }
    if emitted < bytes.len() {
        sink.output(stream, &String::from_utf8_lossy(&bytes[emitted..]));
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

#[cfg(not(unix))]
fn observe_stream(
    reader: impl Read,
    stream: ProcessStream,
    sink: ProcessSink,
    _child_exited: &AtomicBool,
) -> io::Result<String> {
    let mut reader = BufReader::new(reader);
    let mut bytes = Vec::new();
    loop {
        let start = bytes.len();
        if reader.read_until(b'\n', &mut bytes)? == 0 {
            break;
        }
        sink.output(stream, &String::from_utf8_lossy(&bytes[start..]));
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostExecutionTarget {
    pub route: SshRoutePlan,
    pub cwd: PathBuf,
    pub known_hosts_file: Option<PathBuf>,
    pub local: bool,
    pub ssh_connect_timeout_seconds: u64,
    pub ssh_server_alive_interval_seconds: u64,
    pub ssh_server_alive_count_max: usize,
    pub remote_read_timeout_seconds: u64,
    pub control_master: Option<ControlMaster>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ControlMaster {
    pub socket: PathBuf,
    pub persist_seconds: u64,
}

impl HostExecutionTarget {
    pub fn from_resolved(
        host: &ResolvedHost,
        route: SshRoutePlan,
        cwd: &Path,
        known_hosts_file: Option<PathBuf>,
        local: bool,
    ) -> Result<Self> {
        if !cwd.is_absolute() {
            bail!("host execution working directory must be absolute");
        }
        let endpoint = &route.endpoint;
        if endpoint.node != host.inventory_name
            || endpoint.host != host.target
            || endpoint.user != host.user
            || endpoint.port != host.port
            || endpoint.identity != host.identity_key
        {
            bail!(
                "SSH route does not match resolved host authority for {}",
                host.inventory_name
            );
        }
        Ok(Self {
            route,
            cwd: cwd.to_path_buf(),
            known_hosts_file,
            local,
            ssh_connect_timeout_seconds: 30,
            ssh_server_alive_interval_seconds: 5,
            ssh_server_alive_count_max: 3,
            remote_read_timeout_seconds: 20,
            control_master: None,
        })
    }

    pub fn with_ssh_liveness(
        mut self,
        connect_timeout_seconds: u64,
        server_alive_interval_seconds: u64,
        server_alive_count_max: usize,
    ) -> Result<Self> {
        if connect_timeout_seconds == 0
            || server_alive_interval_seconds == 0
            || server_alive_count_max == 0
        {
            bail!("SSH liveness settings must be positive");
        }
        self.ssh_connect_timeout_seconds = connect_timeout_seconds;
        self.ssh_server_alive_interval_seconds = server_alive_interval_seconds;
        self.ssh_server_alive_count_max = server_alive_count_max;
        Ok(self)
    }

    pub fn with_remote_read_timeout(mut self, timeout_seconds: u64) -> Result<Self> {
        if timeout_seconds == 0 {
            bail!("remote read timeout must be positive");
        }
        self.remote_read_timeout_seconds = timeout_seconds;
        Ok(self)
    }

    pub fn with_control_master(mut self, socket: PathBuf, persist_seconds: u64) -> Result<Self> {
        if !socket.is_absolute() {
            bail!("SSH control-master socket path must be absolute");
        }
        let socket_path_bytes = socket.as_os_str().as_bytes().len();
        if socket_path_bytes >= UNIX_SOCKET_PATH_LIMIT_BYTES {
            bail!(
                concat!(
                    "SSH control-master socket path is {} bytes, but Unix sockets ",
                    "require fewer than {} bytes: {}; ",
                    "use a shorter runtime directory"
                ),
                socket_path_bytes,
                UNIX_SOCKET_PATH_LIMIT_BYTES,
                socket.display()
            );
        }
        if persist_seconds == 0 {
            bail!("SSH control-master persistence must be positive");
        }
        self.control_master = Some(ControlMaster {
            socket,
            persist_seconds,
        });
        Ok(self)
    }
}

fn validate_environment(environment: &[(String, String)]) -> Result<()> {
    for (name, _) in environment {
        let mut bytes = name.bytes();
        let valid_first = bytes
            .next()
            .is_some_and(|byte| byte.is_ascii_alphabetic() || byte == b'_');
        if !valid_first || !bytes.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_') {
            bail!("invalid remote environment name: {name}");
        }
    }
    Ok(())
}

fn encoded_remote_script(argv: &[String], environment: &[(String, String)]) -> Result<String> {
    if argv.is_empty() || argv[0].is_empty() {
        bail!("remote argv must contain a program");
    }
    validate_environment(environment)?;
    let mut framed = Vec::new();
    if environment.is_empty() {
        framed.extend_from_slice(argv);
    } else {
        framed.extend(["env".to_owned(), "--".to_owned()]);
        framed.extend(
            environment
                .iter()
                .map(|(name, value)| format!("{name}={value}")),
        );
        framed.extend_from_slice(argv);
    }
    let payload = framed
        .iter()
        .map(|argument| base64::engine::general_purpose::STANDARD.encode(argument))
        .collect::<Vec<_>>()
        .join("\n");
    Ok(format!(
        r#"set -Eeuo pipefail
argv=()
while IFS= read -r encoded; do
    [ -n "$encoded" ] || continue
    decoded="$(printf '%s' "$encoded" | {SYSTEM_BASE64} -d; printf .)"
    argv+=("${{decoded%?}}")
done <<'NIXBOT_ARGV'
{payload}
NIXBOT_ARGV
exec "${{argv[@]}}"
"#
    ))
}

fn root_argv(
    target: &HostExecutionTarget,
    argv: &[String],
    environment: &[(String, String)],
) -> Result<Vec<String>> {
    if argv.is_empty() || argv[0].is_empty() {
        bail!("root argv must contain a program");
    }
    validate_environment(environment)?;
    let mut elevated = Vec::with_capacity(argv.len() + environment.len() + 6);
    if target.route.endpoint.user != "root" {
        elevated.extend([SYSTEM_SUDO.to_owned(), "-n".to_owned(), "--".to_owned()]);
    }
    elevated.extend([
        SYSTEM_ENV.to_owned(),
        "--".to_owned(),
        format!("PATH={REMOTE_RUNTIME_PATH}"),
    ]);
    elevated.extend(
        environment
            .iter()
            .map(|(name, value)| format!("{name}={value}")),
    );
    elevated.extend_from_slice(argv);
    Ok(elevated)
}

pub fn build_ssh_request(
    target: &HostExecutionTarget,
    argv: &[String],
    environment: &[(String, String)],
    effect: EffectKind,
    task: Arc<dyn Task>,
) -> Result<ProcessRequest> {
    let mut args = ssh_connection_args(target)?;
    let endpoint = &target.route.endpoint;
    args.extend([
        "--".to_owned(),
        endpoint.connect_target(),
        SYSTEM_BASH.to_owned(),
        "-s".to_owned(),
    ]);
    Ok(ProcessRequest {
        program: "ssh".to_owned(),
        args,
        environment: Vec::new(),
        clear_git_repository_environment: false,
        cwd: target.cwd.clone(),
        stdin: Some(encoded_remote_script(argv, environment)?),
        effect,
        task,
    })
}

/// Build the transport-only SSH argv shared by ordinary remote execution and
/// the deliberately restricted forced-command readiness probe.
pub fn ssh_connection_args(target: &HostExecutionTarget) -> Result<Vec<String>> {
    let route = &target.route;
    let endpoint = &route.endpoint;
    let mut args = vec![
        "-F".to_owned(),
        "/dev/null".to_owned(),
        "-o".to_owned(),
        "BatchMode=yes".to_owned(),
        "-o".to_owned(),
        format!("ConnectTimeout={}", target.ssh_connect_timeout_seconds),
        "-o".to_owned(),
        "ConnectionAttempts=1".to_owned(),
        "-o".to_owned(),
        format!(
            "ServerAliveInterval={}",
            target.ssh_server_alive_interval_seconds
        ),
        "-o".to_owned(),
        format!("ServerAliveCountMax={}", target.ssh_server_alive_count_max),
        "-o".to_owned(),
        "LogLevel=ERROR".to_owned(),
        "-p".to_owned(),
        endpoint.port.to_string(),
    ];
    if let Some(identity) = &endpoint.identity {
        args.extend([
            "-i".to_owned(),
            identity.display().to_string(),
            "-o".to_owned(),
            "IdentitiesOnly=yes".to_owned(),
        ]);
    }
    if let Some(known_hosts) = &target.known_hosts_file {
        args.extend([
            "-o".to_owned(),
            format!("UserKnownHostsFile={}", known_hosts.display()),
            "-o".to_owned(),
            "GlobalKnownHostsFile=/dev/null".to_owned(),
        ]);
    }
    args.extend([
        "-o".to_owned(),
        match route.host_key_policy {
            HostKeyPolicy::Strict => "StrictHostKeyChecking=yes".to_owned(),
            HostKeyPolicy::AcceptNew => "StrictHostKeyChecking=accept-new".to_owned(),
        },
    ]);
    if let Some(proxy) = render_proxy_chain(target)? {
        args.extend(["-o".to_owned(), format!("ProxyCommand={proxy}")]);
    }
    if let Some(proxy) = &route.proxy_command {
        args.extend([
            "-o".to_owned(),
            format!(
                "ProxyCommand={}",
                proxy.render(&endpoint.host, endpoint.port)
            ),
        ]);
    }
    if let Some(control) = &target.control_master {
        args.extend([
            "-o".to_owned(),
            "ControlMaster=auto".to_owned(),
            "-o".to_owned(),
            format!("ControlPath={}", control.socket.display()),
            "-o".to_owned(),
            format!("ControlPersist={}", control.persist_seconds),
        ]);
    }
    Ok(args)
}

pub fn ssh_connection_args_without_control_master(
    target: &HostExecutionTarget,
) -> Result<Vec<String>> {
    let mut isolated = target.clone();
    isolated.control_master = None;
    let mut args = ssh_connection_args(&isolated)?;
    args.extend([
        "-o".to_owned(),
        "ControlMaster=no".to_owned(),
        "-o".to_owned(),
        "ControlPath=none".to_owned(),
    ]);
    Ok(args)
}

#[derive(serde::Serialize)]
struct LeaseEndpointAuthority<'a> {
    node: &'a str,
    host: &'a str,
    user: &'a str,
    port: u16,
    role: TransportRole,
    has_identity: bool,
}

impl<'a> From<&'a SshEndpoint> for LeaseEndpointAuthority<'a> {
    fn from(endpoint: &'a SshEndpoint) -> Self {
        Self {
            node: &endpoint.node,
            host: &endpoint.host,
            user: &endpoint.user,
            port: endpoint.port,
            role: endpoint.role,
            has_identity: endpoint.identity.is_some(),
        }
    }
}

#[derive(serde::Serialize)]
struct LeaseProxyAuthority<'a> {
    node: &'a str,
    endpoint: LeaseEndpointAuthority<'a>,
    proxy_command: Option<&'a str>,
    local: bool,
}

impl<'a> From<&'a ProxyHop> for LeaseProxyAuthority<'a> {
    fn from(hop: &'a ProxyHop) -> Self {
        Self {
            node: &hop.node,
            endpoint: (&hop.endpoint).into(),
            proxy_command: hop.proxy_command.as_ref().map(|command| command.as_str()),
            local: hop.local,
        }
    }
}

#[derive(serde::Serialize)]
struct LeaseRouteAuthority<'a> {
    endpoint: LeaseEndpointAuthority<'a>,
    proxy: Vec<LeaseProxyAuthority<'a>>,
    proxy_command: Option<&'a str>,
    host_key_policy: HostKeyPolicy,
}

fn lease_route_authority(route: &SshRoutePlan) -> Result<String> {
    let authority = LeaseRouteAuthority {
        endpoint: (&route.endpoint).into(),
        proxy: route.proxy.hops.iter().map(Into::into).collect(),
        proxy_command: route.proxy_command.as_ref().map(|command| command.as_str()),
        host_key_policy: route.host_key_policy,
    };
    serde_json::to_string(&authority).context("serialize builder lease route authority")
}

pub fn builder_lease_process_spec(
    target: &HostExecutionTarget,
    tools: &RemoteBuildTools,
) -> Result<LeaseProcessSpec> {
    if target.local {
        bail!("a remote builder lease cannot target the local host");
    }
    let command = builder_lease_hold_command(tools);
    let remote_command = std::iter::once(command.program)
        .chain(command.args)
        .map(|argument| shell_quote(&argument))
        .collect::<Vec<_>>()
        .join(" ");
    let mut args = ssh_connection_args_without_control_master(target)?;
    args.extend([
        "-T".to_owned(),
        "--".to_owned(),
        target.route.endpoint.connect_target(),
        remote_command,
    ]);
    Ok(LeaseProcessSpec {
        authority: lease_route_authority(&target.route)?,
        program: "ssh".to_owned(),
        args,
        cwd: target.cwd.clone(),
    })
}

pub fn control_master_exit_request(target: &HostExecutionTarget) -> Result<Option<ProcessRequest>> {
    let Some(control) = &target.control_master else {
        return Ok(None);
    };
    if target.local {
        bail!("local execution targets cannot own SSH control masters");
    }
    let mut isolated = target.clone();
    isolated.control_master = None;
    let mut args = ssh_connection_args(&isolated)?;
    args.extend([
        "-S".to_owned(),
        control.socket.display().to_string(),
        "-O".to_owned(),
        "exit".to_owned(),
        "--".to_owned(),
        target.route.endpoint.connect_target(),
    ]);
    Ok(Some(ProcessRequest {
        program: "ssh".to_owned(),
        args,
        environment: Vec::new(),
        clear_git_repository_environment: false,
        cwd: target.cwd.clone(),
        stdin: None,
        effect: EffectKind::Mutation,
        task: InternalTask::new("ssh-control-master-exit"),
    }))
}

pub fn retire_control_master(target: &HostExecutionTarget) {
    let Some(control) = &target.control_master else {
        return;
    };
    if let Ok(Some(request)) = control_master_exit_request(target) {
        let _ = Command::new(&request.program)
            .args(&request.args)
            .current_dir(&request.cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    let _ = std::fs::remove_file(&control.socket);
}

pub fn build_ssh_upload_request(
    target: &HostExecutionTarget,
    contents: String,
    remote_destination: &Path,
    task: Arc<dyn Task>,
) -> Result<ProcessRequest> {
    if target.local {
        bail!("SSH upload is not valid for a local execution target");
    }
    let destination = remote_destination
        .to_str()
        .filter(|path| {
            path.starts_with('/')
                && path.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'.' | b'_' | b'-')
                })
        })
        .context("SSH upload destination must be an absolute shell-safe UTF-8 path")?;
    let upload_script = format!("set -Eeuo pipefail; umask 077; cat > {destination}");
    let remote_command = [SYSTEM_BASH, "-c", &upload_script]
        .into_iter()
        .map(shell_quote)
        .collect::<Vec<_>>()
        .join(" ");
    let mut args = ssh_connection_args(target)?;
    args.extend([
        "--".to_owned(),
        target.route.endpoint.connect_target(),
        remote_command,
    ]);
    Ok(ProcessRequest {
        program: "ssh".to_owned(),
        args,
        environment: Vec::new(),
        clear_git_repository_environment: false,
        cwd: target.cwd.clone(),
        stdin: Some(contents),
        effect: EffectKind::Mutation,
        task,
    })
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub fn render_proxy_chain(target: &HostExecutionTarget) -> Result<Option<String>> {
    let mut upstream: Option<String> = None;
    for (index, hop) in target.route.proxy.hops.iter().enumerate() {
        if hop.proxy_command.is_some() && upstream.is_some() {
            bail!("nested proxy hop cannot combine ProxyCommand with an upstream hop");
        }
        let endpoint = &hop.endpoint;
        let forward_destination = target
            .route
            .proxy
            .hops
            .get(index + 1)
            .map(|next| &next.endpoint)
            .unwrap_or(&target.route.endpoint)
            .forward_destination();
        let mut tokens = vec![
            "ssh".to_owned(),
            "-F".to_owned(),
            "/dev/null".to_owned(),
            "-o".to_owned(),
            "BatchMode=yes".to_owned(),
            "-o".to_owned(),
            format!("ConnectTimeout={}", target.ssh_connect_timeout_seconds),
            "-o".to_owned(),
            "ConnectionAttempts=1".to_owned(),
            "-o".to_owned(),
            format!(
                "ServerAliveInterval={}",
                target.ssh_server_alive_interval_seconds
            ),
            "-o".to_owned(),
            format!("ServerAliveCountMax={}", target.ssh_server_alive_count_max),
            "-o".to_owned(),
            "LogLevel=ERROR".to_owned(),
            "-p".to_owned(),
            endpoint.port.to_string(),
        ];
        if let Some(identity) = &endpoint.identity {
            tokens.extend([
                "-i".to_owned(),
                identity.display().to_string(),
                "-o".to_owned(),
                "IdentitiesOnly=yes".to_owned(),
            ]);
        }
        if let Some(known_hosts) = &target.known_hosts_file {
            tokens.extend([
                "-o".to_owned(),
                format!("UserKnownHostsFile={}", known_hosts.display()),
                "-o".to_owned(),
                "GlobalKnownHostsFile=/dev/null".to_owned(),
                "-o".to_owned(),
                "StrictHostKeyChecking=accept-new".to_owned(),
            ]);
        }
        let proxy = hop
            .proxy_command
            .as_ref()
            .map(|template| template.render(&endpoint.host, endpoint.port))
            .or(upstream.take());
        if let Some(proxy) = proxy {
            tokens.extend(["-o".to_owned(), format!("ProxyCommand={proxy}")]);
        }
        tokens.extend([
            "-W".to_owned(),
            forward_destination,
            "--".to_owned(),
            endpoint.connect_target(),
        ]);
        upstream = Some(
            tokens
                .iter()
                .map(|token| shell_quote(token))
                .collect::<Vec<_>>()
                .join(" "),
        );
    }
    Ok(upstream)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Execution<T> {
    Executed(T),
    DryRun,
}

impl<T> Execution<T> {
    pub fn executed(self) -> Option<T> {
        match self {
            Self::Executed(value) => Some(value),
            Self::DryRun => None,
        }
    }

    pub fn is_dry_run(&self) -> bool {
        matches!(self, Self::DryRun)
    }
}

pub struct HostRuntime<R> {
    runner: R,
    cwd: PathBuf,
    dry_run: DryRun,
}

impl<R: ProcessRunner> HostRuntime<R> {
    pub fn new(runner: R, cwd: PathBuf, dry_run: DryRun) -> Result<Self> {
        if !cwd.is_absolute() {
            bail!("runtime working directory must be absolute");
        }
        Ok(Self {
            runner,
            cwd,
            dry_run,
        })
    }

    pub fn runner(&self) -> &R {
        &self.runner
    }

    pub fn into_runner(self) -> R {
        self.runner
    }

    fn run(&mut self, request: ProcessRequest) -> Result<ProcessOutput> {
        self.dispatch(request, None)
    }

    fn run_bounded_read(
        &mut self,
        request: ProcessRequest,
        timeout_seconds: u64,
    ) -> Result<ProcessOutput> {
        if timeout_seconds == 0 {
            bail!("bounded read timeout must be positive");
        }
        self.dispatch(request, Some(Duration::from_secs(timeout_seconds)))
    }

    /// Apply the dry-run rule once, then run with an optional deadline.
    fn dispatch(
        &mut self,
        request: ProcessRequest,
        timeout: Option<Duration>,
    ) -> Result<ProcessOutput> {
        if self.dry_run == DryRun::Yes && request.effect == EffectKind::Mutation {
            return Ok(ProcessOutput::dry_run());
        }
        let result = match timeout {
            Some(timeout) => self.runner.run_with_timeout(&request, timeout),
            None => self.runner.run(&request),
        };
        result.with_context(|| format!("failed to execute {}", request.task.name()))
    }

    fn local_request(
        &self,
        command: &CommandSpec,
        effect: EffectKind,
        task: Arc<dyn Task>,
    ) -> ProcessRequest {
        ProcessRequest {
            program: command.program.clone(),
            args: command.args.clone(),
            environment: Vec::new(),
            clear_git_repository_environment: true,
            cwd: self.cwd.clone(),
            stdin: None,
            effect,
            task,
        }
    }

    fn validate_target(&self, target: &HostExecutionTarget) -> Result<()> {
        if target.cwd != self.cwd {
            bail!(
                "host execution target working directory {} does not match runtime authority {}",
                target.cwd.display(),
                self.cwd.display()
            );
        }
        Ok(())
    }

    fn remote_command_request(
        &self,
        target: &HostExecutionTarget,
        command: &CommandSpec,
        effect: EffectKind,
        task: Arc<dyn Task>,
    ) -> Result<ProcessRequest> {
        self.validate_target(target)?;
        if target.local {
            Ok(ProcessRequest {
                cwd: target.cwd.clone(),
                ..self.local_request(command, effect, task)
            })
        } else {
            let mut argv = Vec::with_capacity(command.args.len() + 1);
            argv.push(command.program.clone());
            argv.extend_from_slice(&command.args);
            build_ssh_request(target, &argv, &[], effect, task)
        }
    }

    fn remote_root_command_request(
        &self,
        target: &HostExecutionTarget,
        command: &CommandSpec,
        effect: EffectKind,
        task: Arc<dyn Task>,
    ) -> Result<ProcessRequest> {
        self.validate_target(target)?;
        let mut argv = Vec::with_capacity(command.args.len() + 1);
        argv.push(command.program.clone());
        argv.extend_from_slice(&command.args);
        let mut argv = root_argv(target, &argv, &[])?;
        if target.local {
            Ok(ProcessRequest {
                program: argv.remove(0),
                args: argv,
                environment: Vec::new(),
                clear_git_repository_environment: true,
                cwd: target.cwd.clone(),
                stdin: None,
                effect,
                task,
            })
        } else {
            build_ssh_request(target, &argv, &[], effect, task)
        }
    }

    fn remote_root_command_request_without_control_master(
        &self,
        target: &HostExecutionTarget,
        command: &CommandSpec,
        effect: EffectKind,
        task: Arc<dyn Task>,
    ) -> Result<ProcessRequest> {
        let mut isolated = target.clone();
        isolated.control_master = None;
        let mut request = self.remote_root_command_request(&isolated, command, effect, task)?;
        if !target.local {
            let separator = request
                .args
                .iter()
                .position(|argument| argument == "--")
                .context("SSH request has no option separator")?;
            request.args.splice(
                separator..separator,
                [
                    "-o".to_owned(),
                    "ControlMaster=no".to_owned(),
                    "-o".to_owned(),
                    "ControlPath=none".to_owned(),
                ],
            );
        }
        Ok(request)
    }

    fn deploy_request(
        &self,
        target: &HostExecutionTarget,
        command: &RemoteCommand,
        effect: EffectKind,
        task: Arc<dyn Task>,
    ) -> Result<ProcessRequest> {
        self.validate_target(target)?;
        let mut argv = vec![command.program.clone()];
        let mut stdin = None;
        if command.args.as_slice() == ["-s"] {
            if target.local {
                argv.push("-s".to_owned());
                stdin = Some(command.script.clone());
            } else {
                argv.extend(["-c".to_owned(), command.script.clone()]);
            }
        } else {
            argv.extend_from_slice(&command.args);
        }
        let mut argv = root_argv(target, &argv, &command.environment)?;
        if target.local {
            Ok(ProcessRequest {
                program: argv.remove(0),
                args: argv,
                environment: Vec::new(),
                clear_git_repository_environment: true,
                cwd: target.cwd.clone(),
                stdin,
                effect,
                task,
            })
        } else {
            build_ssh_request(target, &argv, &[], effect, task)
        }
    }

    pub fn evaluate_build_plan(
        &mut self,
        command: &CommandSpec,
        task: Arc<dyn Task>,
    ) -> Result<Execution<NixStorePath>> {
        let request = self.local_request(command, EffectKind::ReadOnly, task);
        let output = self.run(request)?;
        require_success(&output, "build-plan evaluation")?;
        Ok(Execution::Executed(NixStorePath::derivation(
            &output.stdout,
        )?))
    }

    pub fn local_build(
        &mut self,
        command: &CommandSpec,
        task: Arc<dyn Task>,
    ) -> Result<Execution<NixStorePath>> {
        let request = self.local_request(command, EffectKind::Build, task);
        let output = self.run(request)?;
        if output.skipped {
            return Ok(Execution::DryRun);
        }
        require_success(&output, "local build")?;
        Ok(Execution::Executed(NixStorePath::closure_output(
            &output.stdout,
        )?))
    }

    pub fn execute_local_command(
        &mut self,
        command: &CommandSpec,
        effect: EffectKind,
        task: Arc<dyn Task>,
    ) -> Result<ProcessOutput> {
        let request = self.local_request(command, effect, task);
        self.run(request)
    }

    /// Run a command locally with an explicit environment, used where a program
    /// relies on an environment variable rather than a wrapper process (for
    /// example `NIX_SSHOPTS` for `nix copy`).
    pub fn execute_local_command_with_env(
        &mut self,
        command: &CommandSpec,
        environment: &[(String, String)],
        effect: EffectKind,
        task: Arc<dyn Task>,
    ) -> Result<ProcessOutput> {
        let mut request = self.local_request(command, effect, task);
        request.environment = environment.to_vec();
        self.run(request)
    }

    pub fn execute_remote_command(
        &mut self,
        target: &HostExecutionTarget,
        command: &CommandSpec,
        effect: EffectKind,
        task: Arc<dyn Task>,
    ) -> Result<ProcessOutput> {
        let request = self.remote_command_request(target, command, effect, task)?;
        self.run(request)
    }

    pub fn execute_remote_root_command(
        &mut self,
        target: &HostExecutionTarget,
        command: &CommandSpec,
        effect: EffectKind,
        task: Arc<dyn Task>,
    ) -> Result<ProcessOutput> {
        let request = self.remote_root_command_request(target, command, effect, task)?;
        self.run(request)
    }

    pub fn execute_remote_command_bounded(
        &mut self,
        target: &HostExecutionTarget,
        command: &CommandSpec,
        effect: EffectKind,
        task: Arc<dyn Task>,
    ) -> Result<ProcessOutput> {
        let request = self.remote_command_request(target, command, effect, task)?;
        self.run_bounded_read(request, target.remote_read_timeout_seconds)
    }

    pub fn execute_remote_root_command_bounded(
        &mut self,
        target: &HostExecutionTarget,
        command: &CommandSpec,
        effect: EffectKind,
        task: Arc<dyn Task>,
    ) -> Result<ProcessOutput> {
        let request = self.remote_root_command_request(target, command, effect, task)?;
        self.run_bounded_read(request, target.remote_read_timeout_seconds)
    }

    pub fn wait(&mut self, duration: Duration) {
        self.runner.wait(duration);
    }

    pub fn upload_file_to_remote(
        &mut self,
        target: &HostExecutionTarget,
        local_source: &Path,
        remote_destination: &Path,
        task: Arc<dyn Task>,
    ) -> Result<ProcessOutput> {
        self.validate_target(target)?;
        if !local_source.is_absolute() || !local_source.is_file() {
            bail!("SSH upload source must be an absolute regular file");
        }
        let contents = std::fs::read_to_string(local_source)
            .with_context(|| format!("read SSH upload source {}", local_source.display()))?;
        let request = build_ssh_upload_request(target, contents, remote_destination, task)?;
        self.run(request)
    }

    pub fn run_remote_build(
        &mut self,
        target: &HostExecutionTarget,
        command: &CommandSpec,
        retry: RetryPolicy,
        task: Arc<dyn Task>,
    ) -> Result<RemoteBuildExecution> {
        let mut tracker = RetryTracker::new(retry);
        let action_attempt = loop {
            let process =
                self.remote_command_request(target, command, EffectKind::Build, Arc::clone(&task))?;
            let output = self.run(process)?;
            let attempt = command_attempt(&output);
            match tracker.observe(attempt.clone()) {
                RetryDecision::Retry { delay, .. } => self.runner.wait(delay),
                RetryDecision::Complete | RetryDecision::Stop { .. } => break attempt,
            }
        };

        let output = if action_attempt.status == CommandStatus::Success {
            RemoteBuildOutput::validate(&action_attempt.stdout).ok()
        } else {
            None
        };
        let status = if output.is_some() {
            CommandStatus::Success
        } else if action_attempt.status == CommandStatus::Success {
            CommandStatus::Exit(1)
        } else {
            action_attempt.status
        };
        Ok(RemoteBuildExecution {
            output,
            failures: tracker.failures().to_vec(),
            status,
        })
    }

    pub fn cache_pull(
        &mut self,
        target: &HostExecutionTarget,
        cache: &CacheSource,
        closure: &NixStorePath,
        retry: RetryPolicy,
        task: Arc<dyn Task>,
    ) -> Result<CommandStatus> {
        let copy = cache_pull_command(cache, closure);
        let copied =
            self.run_remote_with_retry(target, &copy, EffectKind::Mutation, retry, task)?;
        Ok(copied.attempt.status)
    }

    fn run_remote_with_retry(
        &mut self,
        target: &HostExecutionTarget,
        command: &CommandSpec,
        effect: EffectKind,
        retry: RetryPolicy,
        task: Arc<dyn Task>,
    ) -> Result<build::RetryExecution> {
        let mut tracker = RetryTracker::new(retry);
        loop {
            let request =
                self.remote_command_request(target, command, effect, Arc::clone(&task))?;
            let attempt = command_attempt(&self.run(request)?);
            match tracker.observe(attempt.clone()) {
                RetryDecision::Retry { delay, .. } => self.runner.wait(delay),
                RetryDecision::Complete | RetryDecision::Stop { .. } => {
                    return Ok(build::RetryExecution {
                        attempt,
                        failures: tracker.failures().to_vec(),
                    });
                }
            }
        }
    }

    pub fn verify_target_closure(
        &mut self,
        target: &HostExecutionTarget,
        closure: &NixStorePath,
        task: Arc<dyn Task>,
    ) -> Result<CommandStatus> {
        let command = build::closure_verification_command("nix", closure);
        let request = self.remote_command_request(target, &command, EffectKind::ReadOnly, task)?;
        Ok(command_status(self.run(request)?.status))
    }

    pub fn relay_transfer(
        &mut self,
        target: &HostExecutionTarget,
        closure: &NixStorePath,
        cache: &CacheSource,
        retry: RetryPolicy,
        task: Arc<dyn Task>,
    ) -> Result<CommandStatus> {
        if target.local {
            let local_pull = cache_pull_command(cache, closure);
            let request = self.local_request(&local_pull, EffectKind::Mutation, Arc::clone(&task));
            let pulled = self.run(request)?;
            return Ok(command_status(pulled.status));
        }
        let endpoint = &target.route.endpoint;
        let host = uri_authority_component(&endpoint.host)?;
        let host = if host.contains(':') {
            format!("[{host}]")
        } else {
            host.to_owned()
        };
        let store_uri = format!(
            "ssh-ng://{}@{host}",
            uri_authority_component(&endpoint.user)?
        );
        let relay = cache_relay_command(cache, &store_uri, closure);
        let nix_sshopts = nix_sshopts_without_control_master(target)?;
        let mut tracker = RetryTracker::new(retry);
        let relayed = loop {
            let mut request = self.local_request(&relay, EffectKind::Mutation, Arc::clone(&task));
            request
                .environment
                .push(("NIX_SSHOPTS".to_owned(), nix_sshopts.clone()));
            let attempt = command_attempt(&self.run(request)?);
            match tracker.observe(attempt.clone()) {
                RetryDecision::Retry { delay, .. } => self.runner.wait(delay),
                RetryDecision::Complete | RetryDecision::Stop { .. } => break attempt.status,
            }
        };
        Ok(relayed)
    }

    pub fn snapshot(
        &mut self,
        target: &HostExecutionTarget,
        task: Arc<dyn Task>,
    ) -> Result<GenerationSnapshot> {
        let command = deploy::snapshot_command();
        let command = CommandSpec::new(command.program, command.args);
        let request = self.remote_command_request(target, &command, EffectKind::ReadOnly, task)?;
        let output = self.run_bounded_read(request, target.remote_read_timeout_seconds)?;
        if output.succeeded() {
            GenerationSnapshot::parse(&output.stdout)
        } else {
            Ok(GenerationSnapshot::missing())
        }
    }

    pub fn prepare_switch(
        &mut self,
        target: &HostExecutionTarget,
        command: &RemoteCommand,
        task: Arc<dyn Task>,
    ) -> Result<ProcessOutput> {
        let request = self.deploy_request(target, command, EffectKind::Mutation, task)?;
        self.run(request)
    }

    pub fn admit_generation(
        &mut self,
        target: &HostExecutionTarget,
        command: &RemoteCommand,
        task: Arc<dyn Task>,
    ) -> Result<ProcessOutput> {
        let request = self.deploy_request(target, command, EffectKind::Mutation, task)?;
        self.run(request)
    }

    pub fn activate(
        &mut self,
        target: &HostExecutionTarget,
        command: &RemoteCommand,
        desired: &SystemGeneration,
        goal: ActivationGoal,
        task: Arc<dyn Task>,
    ) -> Result<ActivationExecution> {
        let submit = self.deploy_request(
            target,
            command,
            EffectKind::Mutation,
            InternalTask::child(format!("{}-submit", task.name()), Arc::clone(&task)),
        )?;
        let submitted = self.run(submit)?;
        if submitted.skipped {
            return Ok(ActivationExecution::DryRun);
        }
        if !submitted.succeeded() {
            return Ok(ActivationExecution::Failed {
                status: command_status(submitted.status),
                admitted: false,
            });
        }

        self.runner.activation_started();
        let observer_status = (|| {
            if let Some(observer) = &command.observer_script {
                let observer = CommandSpec::new(SYSTEM_BASH, ["-c".to_owned(), observer.clone()]);
                let request = self.remote_root_command_request_without_control_master(
                    target,
                    &observer,
                    EffectKind::ReadOnly,
                    Arc::clone(&task),
                )?;
                self.run(request)
            } else {
                Ok(submitted)
            }
        })();
        let force_remote_cancellation = self.runner.force_remote_cancellation();
        let cancellation_result = if force_remote_cancellation {
            let cancellation = CommandSpec::new(
                "systemctl",
                [
                    "kill".to_owned(),
                    "--kill-whom=all".to_owned(),
                    "--signal=KILL".to_owned(),
                    command.unit.clone(),
                ],
            );
            self.remote_root_command_request_without_control_master(
                target,
                &cancellation,
                EffectKind::Mutation,
                InternalTask::child(format!("{}-force-cancel", task.name()), Arc::clone(&task)),
            )
            .and_then(|request| {
                let mut runner = SystemProcessRunner;
                runner.run(&request).map_err(Into::into)
            })
            .map(|_| ())
        } else {
            Ok(())
        };
        self.runner.activation_finished();
        cancellation_result?;
        let observer_status = observer_status?;

        if observer_status.succeeded() {
            return Ok(ActivationExecution::Succeeded);
        }
        let observer_command_status = command_status(observer_status.status);
        let marker_admitted = ActivationSample::parse_observer_marker(&observer_status.stderr)
            .ok()
            .and_then(|sample| sample.admitted);
        if marker_admitted == Some(false) {
            return Ok(ActivationExecution::Failed {
                status: observer_command_status,
                admitted: false,
            });
        }
        let failure = deploy::classify_deploy_failure(
            observer_command_status.code(),
            &observer_status.combined_output(),
            true,
            1,
            1,
        );
        if failure == deploy::DeployFailureAction::RejectBeforeSwitch {
            return Ok(ActivationExecution::Failed {
                status: observer_command_status,
                admitted: false,
            });
        }
        if matches!(observer_status.status, ProcessStatus::Signal(_))
            || failure != deploy::DeployFailureAction::VerifyTarget
        {
            return Ok(ActivationExecution::Failed {
                status: observer_command_status,
                admitted: marker_admitted.unwrap_or(true),
            });
        }

        let verification = deploy::activation_verification_command(&command.unit);
        let request = self.deploy_request(
            target,
            &verification,
            EffectKind::ReadOnly,
            InternalTask::child(format!("{}-verify", task.name()), Arc::clone(&task)),
        )?;
        let verified = self.run_bounded_read(request, target.remote_read_timeout_seconds)?;
        if verified.succeeded()
            && let Ok(sample) = ActivationSample::parse(&verified.stdout)
            && deploy::verify_activation(&sample, desired, goal) == VerificationDecision::Succeeded
        {
            return Ok(ActivationExecution::SucceededAfterVerification);
        }
        Ok(ActivationExecution::Failed {
            status: observer_command_status,
            admitted: marker_admitted.unwrap_or(true),
        })
    }

    pub fn post_switch_health(
        &mut self,
        target: &HostExecutionTarget,
        commands: &[CommandSpec],
        evaluator: &mut impl HealthEvaluator,
    ) -> Result<HealthDecision> {
        let mut samples = Vec::with_capacity(commands.len());
        for command in commands {
            let request = self.remote_root_command_request(
                target,
                command,
                EffectKind::ReadOnly,
                InternalTask::new(format!("post-switch-health-{}", target.route.endpoint.node)),
            )?;
            samples.push(self.run(request)?);
        }
        evaluator.evaluate(&samples)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn deploy_host(
        &mut self,
        target: &HostExecutionTarget,
        desired: &SystemGeneration,
        requirement: SnapshotRequirement,
        if_changed: bool,
        admission: &RemoteCommand,
        activation: &RemoteCommand,
        activation_goal: ActivationGoal,
        rollback_factory: Option<&dyn Fn(&SystemGeneration) -> RemoteCommand>,
        health_commands: &[CommandSpec],
        health_evaluator: &mut impl HealthEvaluator,
    ) -> Result<DeployOutcome> {
        if self.dry_run == DryRun::Yes {
            return Ok(DeployOutcome::DryRun);
        }
        let snapshot = self.snapshot(
            target,
            InternalTask::new(format!("snapshot-{}", target.route.endpoint.node)),
        )?;
        let rollback_generation = match snapshot.deploy_decision(requirement, desired, if_changed) {
            DeployDecision::SkipUnchanged => return Ok(DeployOutcome::SkippedUnchanged),
            DeployDecision::SkipOptionalMissing => {
                return Ok(DeployOutcome::SkippedOptionalMissing);
            }
            DeployDecision::RefuseRequiredMissing => return Ok(DeployOutcome::MissingSnapshot),
            DeployDecision::Deploy {
                rollback_generation,
            } => rollback_generation,
        };
        let prepared = self.prepare_switch(
            target,
            admission,
            InternalTask::new(format!(
                "pre-switch-preparation-{}",
                target.route.endpoint.node
            )),
        )?;
        if !prepared.succeeded() {
            return Ok(DeployOutcome::FailedBeforeActivation(command_status(
                prepared.status,
            )));
        }
        let activated = self.activate(
            target,
            activation,
            desired,
            activation_goal,
            InternalTask::new(format!("activation-{}", target.route.endpoint.node)),
        )?;
        let activation_status = match activated {
            ActivationExecution::Succeeded | ActivationExecution::SucceededAfterVerification => {
                let health = self.post_switch_health(target, health_commands, health_evaluator);
                if matches!(health, Ok(HealthDecision::Healthy { .. })) {
                    return Ok(DeployOutcome::Succeeded);
                }
                CommandStatus::Exit(1)
            }
            ActivationExecution::DryRun => return Ok(DeployOutcome::DryRun),
            ActivationExecution::Failed {
                status,
                admitted: false,
            } => {
                return Ok(DeployOutcome::FailedBeforeActivation(status));
            }
            ActivationExecution::Failed {
                status,
                admitted: true,
            } => status,
        };
        let (Some(rollback_factory), Some(rollback_generation)) =
            (rollback_factory, rollback_generation)
        else {
            return Ok(DeployOutcome::FailedAfterActivation(activation_status));
        };
        let rollback = rollback_factory(&rollback_generation);
        let rollback_status = match self.activate(
            target,
            &rollback,
            &rollback_generation,
            ActivationGoal::Switch,
            InternalTask::new(format!("rollback-{}", target.route.endpoint.node)),
        )? {
            ActivationExecution::Succeeded | ActivationExecution::SucceededAfterVerification => {
                CommandStatus::Success
            }
            ActivationExecution::DryRun => CommandStatus::Success,
            ActivationExecution::Failed { status, .. } => status,
        };
        Ok(DeployOutcome::RolledBack {
            activation: activation_status,
            rollback: rollback_status,
        })
    }

    pub fn check_bootstrap(&mut self, plan: &ForcedCommandPlan) -> Result<ProcessOutput> {
        if plan.ssh_target.is_empty() {
            bail!("forced-command SSH target cannot be empty");
        }
        if plan.ssh_args.iter().any(|argument| argument == "--") {
            bail!("forced-command SSH options cannot contain --");
        }
        if plan.remote_command.is_empty()
            || plan
                .remote_command
                .iter()
                .any(|argument| !safe_forced_command_argument(argument))
        {
            bail!("forced-command argv contains unsafe characters");
        }
        let mut args = plan.ssh_args.clone();
        args.extend(["--".to_owned(), plan.ssh_target.clone()]);
        args.extend_from_slice(&plan.remote_command);
        self.run(ProcessRequest {
            program: "ssh".to_owned(),
            args,
            environment: Vec::new(),
            clear_git_repository_environment: false,
            cwd: self.cwd.clone(),
            stdin: None,
            effect: EffectKind::ReadOnly,
            task: InternalTask::new("check-bootstrap"),
        })
    }
}

fn safe_forced_command_argument(argument: &str) -> bool {
    !argument.is_empty()
        && argument.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'.' | b'_' | b'-' | b':' | b'@')
        })
}

fn command_status(status: ProcessStatus) -> CommandStatus {
    match status {
        ProcessStatus::Code(0) => CommandStatus::Success,
        ProcessStatus::Code(code) => CommandStatus::Exit(code),
        ProcessStatus::Signal(signal) => CommandStatus::Signal(signal.saturating_add(128)),
    }
}

fn command_attempt(output: &ProcessOutput) -> CommandAttempt {
    CommandAttempt {
        status: command_status(output.status),
        stdout: output.stdout.clone(),
        stderr: output.stderr.clone(),
    }
}

fn require_success(output: &ProcessOutput, label: &str) -> Result<()> {
    if output.succeeded() {
        Ok(())
    } else {
        bail!("{label} failed: {}", output.combined_output())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoteBuildExecution {
    pub output: Option<RemoteBuildOutput>,
    pub failures: Vec<BuildFailureEvidence>,
    pub status: CommandStatus,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ActivationExecution {
    DryRun,
    Succeeded,
    SucceededAfterVerification,
    Failed {
        status: CommandStatus,
        admitted: bool,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeployOutcome {
    DryRun,
    SkippedUnchanged,
    SkippedOptionalMissing,
    MissingSnapshot,
    Succeeded,
    FailedBeforeActivation(CommandStatus),
    FailedAfterActivation(CommandStatus),
    RolledBack {
        activation: CommandStatus,
        rollback: CommandStatus,
    },
}

pub trait HealthEvaluator {
    fn evaluate(&mut self, samples: &[ProcessOutput]) -> Result<HealthDecision>;
}

/// Concrete, fail-closed health probe using the pure health classifiers.
///
/// Required host-agent responses are parsed through the schema-aware health
/// contracts. Unit evidence must contain every requested unit exactly once;
/// failed commands and malformed records are errors rather than healthy empty
/// results.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SystemHealthProbe {
    expected_units: BTreeSet<String>,
    held_units: BTreeSet<String>,
    host_agent: HostAgentProbe,
    check_podman: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HostAgentProbe {
    Disabled,
    Optional,
    Required,
}

const HOST_AGENT_ABSENT: &str = "__ABIRD_HOST_AGENT_ABSENT__";

impl SystemHealthProbe {
    pub fn new(
        expected_units: impl IntoIterator<Item = String>,
        held_units: impl IntoIterator<Item = String>,
        require_host_agent: bool,
        check_podman: bool,
    ) -> Result<Self> {
        let expected_units = expected_units.into_iter().collect::<BTreeSet<_>>();
        let held_units = held_units.into_iter().collect::<BTreeSet<_>>();
        if expected_units
            .iter()
            .chain(&held_units)
            .any(String::is_empty)
        {
            bail!("health unit names cannot be empty");
        }
        if expected_units.iter().any(|unit| held_units.contains(unit)) {
            bail!("a health unit cannot be both expected and held");
        }
        Ok(Self {
            expected_units,
            held_units,
            host_agent: if require_host_agent {
                HostAgentProbe::Required
            } else {
                HostAgentProbe::Disabled
            },
            check_podman,
        })
    }

    pub fn with_optional_host_agent(mut self) -> Self {
        self.host_agent = HostAgentProbe::Optional;
        self
    }

    pub fn commands(&self) -> Vec<CommandSpec> {
        let mut commands = Vec::new();
        if !self.expected_units.is_empty() || !self.held_units.is_empty() {
            let mut args = vec![
                "show".to_owned(),
                "--property=Id,LoadState,ActiveState,SubState,NeedDaemonReload".to_owned(),
                "--".to_owned(),
            ];
            args.extend(self.expected_units.iter().cloned());
            args.extend(self.held_units.iter().cloned());
            commands.push(CommandSpec::new("systemctl", args));
        }
        commands.push(CommandSpec::new(
            "systemctl",
            [
                "list-jobs".to_owned(),
                "--no-legend".to_owned(),
                "--plain".to_owned(),
            ],
        ));
        if self.host_agent != HostAgentProbe::Disabled {
            for arguments in ["--json hold list", "--json status"] {
                if self.host_agent == HostAgentProbe::Required {
                    commands.push(CommandSpec::new(
                        "/run/current-system/sw/bin/abird-host-agent",
                        arguments.split_whitespace().map(str::to_owned),
                    ));
                } else {
                    commands.push(CommandSpec::new(
                        SYSTEM_BASH,
                        [
                            "-c".to_owned(),
                            format!(
                                "if [ -x /run/current-system/sw/bin/abird-host-agent ]; then exec /run/current-system/sw/bin/abird-host-agent {arguments}; else printf '%s\\n' {HOST_AGENT_ABSENT}; fi"
                            ),
                        ],
                    ));
                }
            }
        }
        if self.check_podman {
            for health in ["unhealthy", "starting"] {
                commands.push(CommandSpec::new(
                    "podman",
                    [
                        "ps".to_owned(),
                        "--filter".to_owned(),
                        format!("health={health}"),
                        "--format".to_owned(),
                        "{{.Names}}\t{{.Status}}".to_owned(),
                    ],
                ));
            }
        }
        commands
    }
}

impl HealthEvaluator for SystemHealthProbe {
    fn evaluate(&mut self, samples: &[ProcessOutput]) -> Result<HealthDecision> {
        let expected_count =
            usize::from(!self.expected_units.is_empty() || !self.held_units.is_empty())
                + 1
                + if self.host_agent != HostAgentProbe::Disabled {
                    2
                } else {
                    0
                }
                + if self.check_podman { 2 } else { 0 };
        if samples.len() != expected_count {
            bail!("health evidence count mismatch");
        }
        if let Some(failed) = samples.iter().find(|sample| !sample.succeeded()) {
            bail!("health probe failed: {}", failed.combined_output());
        }

        let mut index = 0;
        let units = if !self.expected_units.is_empty() || !self.held_units.is_empty() {
            let units = parse_unit_snapshots(&samples[index].stdout)?;
            index += 1;
            units
        } else {
            BTreeMap::new()
        };
        let jobs = parse_systemd_jobs(&samples[index].stdout)?;
        index += 1;

        let mut decision = HealthDecision::healthy();
        for name in &self.expected_units {
            let unit = units
                .get(name)
                .ok_or_else(|| anyhow::anyhow!("missing required unit evidence for {name}"))?;
            decision = decision.merge(health::classify_expected_unit(unit, &jobs));
        }
        for name in &self.held_units {
            let unit = units
                .get(name)
                .ok_or_else(|| anyhow::anyhow!("missing held-unit evidence for {name}"))?;
            decision = decision.merge(health::classify_held_unit(unit));
        }
        let requested = self.expected_units.len() + self.held_units.len();
        if units.len() != requested {
            bail!("health response contains unexpected or duplicate units");
        }

        if self.host_agent != HostAgentProbe::Disabled {
            let hold_output = samples[index].stdout.trim();
            index += 1;
            let status_output = samples[index].stdout.trim();
            index += 1;
            let absent = (
                hold_output == HOST_AGENT_ABSENT,
                status_output == HOST_AGENT_ABSENT,
            );
            match absent {
                (true, true) if self.host_agent == HostAgentProbe::Optional => {}
                (true, true) => bail!("required host agent is not installed"),
                (true, false) | (false, true) => {
                    bail!("host-agent health evidence is internally inconsistent")
                }
                (false, false) => {
                    let holds: DurableHoldResponse = serde_json::from_str(hold_output)
                        .context("invalid durable host-agent hold JSON")?;
                    health::validate_durable_holds(Some(&holds))
                        .context("invalid durable host-agent hold response")?;
                    let status: AgentStatusResponse = serde_json::from_str(status_output)
                        .context("invalid host-agent status JSON")?;
                    health::validate_deferred_resources(Some(&status))
                        .context("invalid host-agent deferred-resource response")?;
                }
            }
        }

        if self.check_podman {
            let mut containers =
                parse_podman_health(&samples[index].stdout, PodmanHealth::Unhealthy)?;
            index += 1;
            containers.extend(parse_podman_health(
                &samples[index].stdout,
                PodmanHealth::Starting,
            )?);
            decision = decision.merge(health::classify_podman_runtime(&containers, &[], false));
        }
        Ok(decision)
    }
}

fn parse_unit_snapshots(output: &str) -> Result<BTreeMap<String, UnitSnapshot>> {
    let mut units = BTreeMap::new();
    for block in output
        .split("\n\n")
        .filter(|block| !block.trim().is_empty())
    {
        let properties = parse_properties(block)?;
        let name = required_property(&properties, "Id")?.to_owned();
        let needs_daemon_reload = match required_property(&properties, "NeedDaemonReload")? {
            "yes" => true,
            "no" => false,
            value => bail!("invalid NeedDaemonReload value for {name}: {value}"),
        };
        let unit = UnitSnapshot {
            name: name.clone(),
            load_state: required_property(&properties, "LoadState")?.to_owned(),
            active_state: required_property(&properties, "ActiveState")?.to_owned(),
            sub_state: required_property(&properties, "SubState")?.to_owned(),
            needs_daemon_reload,
        };
        if units.insert(name.clone(), unit).is_some() {
            bail!("duplicate unit health evidence for {name}");
        }
    }
    Ok(units)
}

fn parse_properties(block: &str) -> Result<BTreeMap<&str, &str>> {
    let mut properties = BTreeMap::new();
    for line in block.lines() {
        let Some((key, value)) = line.split_once('=') else {
            bail!("malformed health property: {line}");
        };
        if properties.insert(key, value).is_some() {
            bail!("duplicate health property: {key}");
        }
    }
    Ok(properties)
}

fn required_property<'a>(properties: &'a BTreeMap<&str, &str>, key: &str) -> Result<&'a str> {
    properties
        .get(key)
        .copied()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow::anyhow!("missing required health property: {key}"))
}

fn parse_systemd_jobs(output: &str) -> Result<Vec<SystemdJob>> {
    output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let fields = line.split_whitespace().collect::<Vec<_>>();
            if fields.len() != 4 {
                bail!("malformed systemd job evidence: {line}");
            }
            Ok(SystemdJob {
                id: fields[0]
                    .parse()
                    .with_context(|| format!("invalid systemd job id: {}", fields[0]))?,
                unit: fields[1].to_owned(),
                kind: fields[2].to_owned(),
                state: fields[3].to_owned(),
            })
        })
        .collect()
}

fn parse_podman_health(output: &str, health: PodmanHealth) -> Result<Vec<PodmanContainer>> {
    output
        .lines()
        .filter(|line| !line.is_empty())
        .map(|line| {
            let Some((name, status)) = line.split_once('\t') else {
                bail!("malformed Podman health evidence: {line}");
            };
            if name.is_empty() || status.is_empty() {
                bail!("incomplete Podman health evidence: {line}");
            }
            Ok(PodmanContainer {
                name: name.to_owned(),
                health: health.clone(),
                status: status.to_owned(),
            })
        })
        .collect()
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DistributionExecution {
    DryRun,
    Complete,
    Failed(CommandStatus),
}

fn cache_pull_command(cache: &CacheSource, closure: &NixStorePath) -> CommandSpec {
    let mut args = vec!["copy".to_owned(), "--from".to_owned(), cache.url.clone()];
    if !cache.trusted_public_keys.is_empty() {
        args.extend([
            "--option".to_owned(),
            "extra-trusted-public-keys".to_owned(),
            cache.trusted_public_keys.join(" "),
        ]);
    }
    args.push(closure.as_str().to_owned());
    CommandSpec::new("nix", args)
}

fn cache_relay_command(
    cache: &CacheSource,
    target_store_uri: &str,
    closure: &NixStorePath,
) -> CommandSpec {
    let mut args = vec!["copy".to_owned(), "--from".to_owned(), cache.url.clone()];
    if !cache.trusted_public_keys.is_empty() {
        args.extend([
            "--option".to_owned(),
            "extra-trusted-public-keys".to_owned(),
            cache.trusted_public_keys.join(" "),
        ]);
    }
    args.extend([
        "--to".to_owned(),
        target_store_uri.to_owned(),
        closure.as_str().to_owned(),
    ]);
    CommandSpec::new("nix", args)
}

fn nix_sshopts_without_control_master(target: &HostExecutionTarget) -> Result<String> {
    Ok(ssh_connection_args_without_control_master(target)?
        .iter()
        .map(|option| shell_quote(option))
        .collect::<Vec<_>>()
        .join(" "))
}

fn uri_authority_component(value: &str) -> Result<&str> {
    if value.is_empty()
        || value
            .bytes()
            .any(|byte| byte.is_ascii_whitespace() || matches!(byte, b'/' | b'?' | b'#' | b'@'))
    {
        bail!("SSH store URI authority contains unsafe characters");
    }
    Ok(value)
}

#[cfg(test)]
mod bounded_read_tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn bounded_read_kills_a_child_that_exceeds_its_deadline() {
        let mut executor = ProcessExecutor::new(None);
        let request = ProcessRequest {
            // A self-contained busy loop needs no external tool and would run
            // forever without an enforced deadline.
            program: "/bin/sh".to_owned(),
            args: vec!["-c".to_owned(), "while :; do :; done".to_owned()],
            environment: Vec::new(),
            clear_git_repository_environment: false,
            cwd: std::env::current_dir().unwrap(),
            stdin: None,
            effect: EffectKind::ReadOnly,
            task: InternalTask::new("bounded-read-timeout-probe"),
        };
        let started = Instant::now();
        let output = executor
            .run_with_timeout(&request, Duration::from_millis(250))
            .unwrap();
        assert_eq!(output.status, ProcessStatus::Code(TIMEOUT_EXIT_CODE));
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "deadline was not enforced promptly: {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn bounded_read_escalates_to_sigkill_when_the_child_ignores_term() {
        let mut executor = ProcessExecutor::new(None);
        let request = ProcessRequest {
            // The child ignores SIGTERM, so only the SIGKILL escalation can end
            // it; this proves the grace period does not leave a runaway process.
            program: "/bin/sh".to_owned(),
            args: vec![
                "-c".to_owned(),
                "trap '' TERM; while :; do :; done".to_owned(),
            ],
            environment: Vec::new(),
            clear_git_repository_environment: false,
            cwd: std::env::current_dir().unwrap(),
            stdin: None,
            effect: EffectKind::ReadOnly,
            task: InternalTask::new("bounded-read-kill-escalation-probe"),
        };
        let started = Instant::now();
        let output = executor
            .run_with_timeout(&request, Duration::from_millis(100))
            .unwrap();
        assert_eq!(output.status, ProcessStatus::Code(TIMEOUT_EXIT_CODE));
        assert!(
            started.elapsed() >= BOUNDED_READ_KILL_AFTER,
            "child ignored SIGTERM for less than the grace period: {:?}",
            started.elapsed()
        );
        assert!(
            started.elapsed() < BOUNDED_READ_KILL_AFTER + Duration::from_secs(5),
            "SIGKILL escalation did not terminate the child: {:?}",
            started.elapsed()
        );
    }
}
