// Pure build planning and command specifications for native fleet actions.
//
// Runtime code owns process execution, SSH, sleeping, and filesystem changes.
// This module validates the values crossing those boundaries and describes
// the exact Nix commands, retry decisions, scope lifecycle, and distribution
// policy that adapters must carry out.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Result, bail};
use sha2::{Digest, Sha256};

use super::build_lease::LeaseEpoch;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandSpec {
    pub program: String,
    pub args: Vec<String>,
}

impl CommandSpec {
    pub fn new(program: impl Into<String>, args: impl IntoIterator<Item = String>) -> Self {
        Self {
            program: program.into(),
            args: args.into_iter().collect(),
        }
    }
}

/// A validated single Nix store path.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct NixStorePath(String);

impl NixStorePath {
    pub fn derivation(output: &str) -> Result<Self> {
        let path = Self::closure_output(output)?;
        if !path.0.ends_with(".drv") {
            bail!(
                "build plan did not evaluate to a derivation path: {}",
                path.0
            );
        }
        Ok(path)
    }

    pub fn closure_output(output: &str) -> Result<Self> {
        let value = output.trim_end_matches(['\r', '\n']);
        if value.is_empty() {
            bail!("Nix command produced no output path");
        }
        if value.contains(['\r', '\n']) {
            bail!("Nix command produced multiple output paths");
        }
        let Some(name) = value.strip_prefix("/nix/store/") else {
            bail!("Nix command produced a non-store output path: {value}");
        };
        if name.is_empty()
            || matches!(name, "." | "..")
            || name.contains('/')
            || name.chars().any(char::is_whitespace)
        {
            bail!("Nix command produced an invalid store output path: {value}");
        }
        Ok(Self(value.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn output_installable(&self) -> String {
        format!("{}^out", self.0)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BuildPlanAttribute {
    Native,
    NixosConfiguration,
}

impl BuildPlanAttribute {
    fn installable(self, configuration: &str) -> String {
        match self {
            Self::Native => format!(".#nixbot.plans.{configuration}.drvPath"),
            Self::NixosConfiguration => format!(
                ".#nixosConfigurations.{configuration}.config.system.build.toplevel.drvPath"
            ),
        }
    }
}

pub fn build_plan_probe_command(nix: &str, nix_args: &[String]) -> CommandSpec {
    let mut args = vec!["eval".to_owned()];
    args.extend_from_slice(nix_args);
    args.extend([
        "--json".to_owned(),
        "--no-write-lock-file".to_owned(),
        ".#nixbot.plans".to_owned(),
        "--apply".to_owned(),
        "builtins.attrNames".to_owned(),
    ]);
    CommandSpec::new(nix, args)
}

pub fn build_plan_evaluation_command(
    nix: &str,
    nix_args: &[String],
    attribute: BuildPlanAttribute,
    configuration: &str,
) -> CommandSpec {
    let mut args = vec!["eval".to_owned()];
    args.extend_from_slice(nix_args);
    args.extend([
        "--raw".to_owned(),
        "--no-write-lock-file".to_owned(),
        attribute.installable(configuration),
    ]);
    CommandSpec::new(nix, args)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BuildCacheContext {
    nix_version: String,
    head: String,
    index_tree: String,
}

impl BuildCacheContext {
    pub fn new(
        nix_version: impl Into<String>,
        head: impl Into<String>,
        index_tree: impl Into<String>,
    ) -> Result<Self> {
        let context = Self {
            nix_version: nix_version.into(),
            head: head.into(),
            index_tree: index_tree.into(),
        };
        for (label, value) in [
            ("Nix version", context.nix_version.as_str()),
            ("Git HEAD", context.head.as_str()),
            ("Git index tree", context.index_tree.as_str()),
        ] {
            if value.is_empty() || value.contains(['\r', '\n']) {
                bail!("build-plan cache {label} must be one non-empty line");
            }
        }
        Ok(context)
    }

    pub fn key(&self) -> String {
        let input = format!(
            "schema=build-plan-v1\nnix={}\nhead={}\nindexTree={}\n",
            self.nix_version, self.head, self.index_tree
        );
        format!("{:x}", Sha256::digest(input.as_bytes()))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BuildCacheState {
    pub enabled: bool,
    pub inside_worktree: bool,
    pub index_refreshed: bool,
    pub unmerged_paths: bool,
    pub unstaged_changes: bool,
}

impl BuildCacheState {
    pub fn clean() -> Self {
        Self {
            enabled: true,
            inside_worktree: true,
            index_refreshed: true,
            unmerged_paths: false,
            unstaged_changes: false,
        }
    }

    pub fn allows_cache(self) -> bool {
        self.enabled
            && self.inside_worktree
            && self.index_refreshed
            && !self.unmerged_paths
            && !self.unstaged_changes
    }
}

pub fn build_plan_cache_file(
    cache_root: &Path,
    context_key: &str,
    host: &str,
    configuration: &str,
) -> Result<PathBuf> {
    if context_key.len() != 64
        || !context_key
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        bail!("build-plan cache context key must be 64 lowercase hexadecimal characters");
    }
    let safe = format!("{host}--{configuration}")
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-') {
                character
            } else {
                '_'
            }
        })
        .collect::<String>();
    Ok(cache_root
        .join(context_key)
        .join(format!("{safe}.drv-path")))
}

pub fn validate_cached_build_plan(contents: &str, store_path_exists: bool) -> Result<NixStorePath> {
    let drv = NixStorePath::derivation(contents)?;
    if !store_path_exists {
        bail!(
            "cached build-plan derivation no longer exists: {}",
            drv.as_str()
        );
    }
    Ok(drv)
}

pub fn effective_build_plan_jobs(requested: usize, host_count: usize) -> Result<usize> {
    if requested == 0 {
        bail!("build-plan jobs must be positive");
    }
    Ok(requested.min(host_count))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BuildArgs {
    pub nix_args: Vec<String>,
    pub build_logs: bool,
}

impl BuildArgs {
    pub fn new(nix_args: Vec<String>, build_logs: bool) -> Self {
        Self {
            nix_args,
            build_logs,
        }
    }

    pub fn for_concurrency(max_jobs: usize, build_logs: bool) -> Result<Self> {
        if max_jobs == 0 {
            bail!("build jobs must be positive");
        }
        let nix_args = if max_jobs > 1 {
            vec![
                "--option".to_owned(),
                "eval-cache".to_owned(),
                "false".to_owned(),
            ]
        } else {
            Vec::new()
        };
        Ok(Self::new(nix_args, build_logs))
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LocalBuildSpec {
    pub result_link: Option<PathBuf>,
}

fn append_build_prefix(args: &mut Vec<String>, build: &BuildArgs) {
    args.push("build".to_owned());
    args.extend_from_slice(&build.nix_args);
    args.push("--print-out-paths".to_owned());
}

pub fn local_build_command(
    nix: &str,
    drv: &NixStorePath,
    build: &BuildArgs,
    local: LocalBuildSpec,
) -> CommandSpec {
    let mut args = Vec::new();
    append_build_prefix(&mut args, build);
    if build.build_logs {
        args.push("-L".to_owned());
    }
    if let Some(result_link) = local.result_link {
        args.extend(["-o".to_owned(), result_link.to_string_lossy().into_owned()]);
    }
    args.push(drv.output_installable());
    CommandSpec::new(nix, args)
}

pub fn development_build_command(
    nix: &str,
    host: &str,
    drv: &NixStorePath,
    build: &BuildArgs,
) -> Result<CommandSpec> {
    validate_path_component(host, "development build host")?;
    let mut args = Vec::new();
    append_build_prefix(&mut args, build);
    args.extend(["-o".to_owned(), format!("result-dev/{host}")]);
    if build.build_logs {
        args.push("-L".to_owned());
    }
    args.push(drv.output_installable());
    Ok(CommandSpec::new(nix, args))
}

fn validate_path_component(value: &str, label: &str) -> Result<()> {
    if value.is_empty()
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        || value == "."
        || value == ".."
    {
        bail!("{label} is not a safe path component: {value}");
    }
    Ok(())
}

pub fn remote_build_command(nix: &str, drv: &NixStorePath, build: &BuildArgs) -> CommandSpec {
    let mut args = Vec::new();
    append_build_prefix(&mut args, build);
    args.push("--no-link".to_owned());
    if build.build_logs {
        args.push("-L".to_owned());
    }
    args.push(drv.output_installable());
    CommandSpec::new(nix, args)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoteBuildOutput {
    pub path: NixStorePath,
}

impl RemoteBuildOutput {
    pub fn validate(stdout: &str) -> Result<Self> {
        Ok(Self {
            path: NixStorePath::closure_output(stdout)?,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BuilderClosure {
    pub path: NixStorePath,
    pub derivation: NixStorePath,
    pub build: BuildArgs,
    pub protected_epoch: LeaseEpoch,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RemoteBuildPurpose {
    Deployment,
    BuildOnly,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BuildStage {
    CopyDerivation,
    BuildUnderGcLease,
    ValidateDeploymentCache,
    CopyClosureToLocal,
}

pub fn remote_build_stages(purpose: RemoteBuildPurpose) -> Vec<BuildStage> {
    let final_stage = match purpose {
        RemoteBuildPurpose::Deployment => BuildStage::ValidateDeploymentCache,
        RemoteBuildPurpose::BuildOnly => BuildStage::CopyClosureToLocal,
    };
    vec![
        BuildStage::CopyDerivation,
        BuildStage::BuildUnderGcLease,
        final_stage,
    ]
}

pub fn copy_derivation_command(nix: &str, store_uri: &str, drv: &NixStorePath) -> CommandSpec {
    CommandSpec::new(
        nix,
        [
            "copy".to_owned(),
            "--to".to_owned(),
            store_uri.to_owned(),
            drv.as_str().to_owned(),
        ],
    )
}

pub fn closure_verification_command(nix: &str, closure: &NixStorePath) -> CommandSpec {
    CommandSpec::new(
        nix,
        [
            "--offline".to_owned(),
            "--quiet".to_owned(),
            "store".to_owned(),
            "verify".to_owned(),
            "--no-contents".to_owned(),
            "--no-trust".to_owned(),
            "--recursive".to_owned(),
            closure.as_str().to_owned(),
        ],
    )
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CommandStatus {
    Success,
    Exit(i32),
    Signal(i32),
}

impl CommandStatus {
    pub fn code(self) -> i32 {
        match self {
            Self::Success => 0,
            Self::Exit(status) | Self::Signal(status) => status,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandAttempt {
    pub status: CommandStatus,
    pub stdout: String,
    pub stderr: String,
}

impl CommandAttempt {
    pub fn success(stdout: impl Into<String>) -> Self {
        Self {
            status: CommandStatus::Success,
            stdout: stdout.into(),
            stderr: String::new(),
        }
    }

    pub fn failure(status: i32, stdout: impl Into<String>, stderr: impl Into<String>) -> Self {
        Self {
            status: CommandStatus::Exit(status),
            stdout: stdout.into(),
            stderr: stderr.into(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RemoteFailureKind {
    Signal,
    HostKeyVerification,
    DaemonDisconnect,
    TransportLoss,
    CommandFailure,
}

impl RemoteFailureKind {
    pub fn retryable(self) -> bool {
        matches!(self, Self::DaemonDisconnect | Self::TransportLoss)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FailureEvidence {
    pub kind: RemoteFailureKind,
    pub status: i32,
    pub stdout: String,
    pub stderr: String,
}

fn classify_remote_failure(attempt: &CommandAttempt) -> RemoteFailureKind {
    if matches!(attempt.status, CommandStatus::Signal(_)) {
        return RemoteFailureKind::Signal;
    }
    let output = format!("{}\n{}", attempt.stdout, attempt.stderr);
    if [
        "REMOTE HOST IDENTIFICATION HAS CHANGED",
        "Host key verification failed",
        "Offending ",
    ]
    .iter()
    .any(|pattern| output.contains(pattern))
    {
        return RemoteFailureKind::HostKeyVerification;
    }
    if output.contains("Nix daemon disconnected unexpectedly")
        || (output.contains("cannot connect to socket at ")
            && output.contains("nix/daemon-socket/socket"))
    {
        return RemoteFailureKind::DaemonDisconnect;
    }
    if [
        "failed to start SSH connection",
        "mux_client_request_session",
        "kex_exchange_identification",
        "ssh_exchange_identification",
        "Connection reset by peer",
        "Connection closed by remote host",
        "Received disconnect",
        "client_loop: send disconnect: Broken pipe",
        "Broken pipe",
        "Bad file descriptor",
        "stdio forwarding failed",
        "Connection timed out",
        "No route to host",
    ]
    .iter()
    .any(|pattern| output.contains(pattern))
        || matches!(attempt.status, CommandStatus::Exit(124 | 255))
    {
        return RemoteFailureKind::TransportLoss;
    }
    RemoteFailureKind::CommandFailure
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetryPolicy {
    pub max_attempts: usize,
    pub base_delay: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            base_delay: Duration::from_secs(2),
        }
    }
}

impl RetryPolicy {
    pub fn new(max_attempts: usize, base_delay: Duration) -> Result<Self> {
        if max_attempts == 0 {
            bail!("retry attempts must be positive");
        }
        Ok(Self {
            max_attempts,
            base_delay,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetryDecision {
    Complete,
    Retry {
        next_attempt: usize,
        delay: Duration,
        kind: RemoteFailureKind,
    },
    Stop {
        kind: RemoteFailureKind,
        status: i32,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RetryTracker {
    policy: RetryPolicy,
    failures: Vec<FailureEvidence>,
}

impl RetryTracker {
    pub fn new(policy: RetryPolicy) -> Self {
        Self {
            policy,
            failures: Vec::new(),
        }
    }

    pub fn failures(&self) -> &[FailureEvidence] {
        &self.failures
    }

    pub fn observe(&mut self, attempt: CommandAttempt) -> RetryDecision {
        if attempt.status == CommandStatus::Success {
            return RetryDecision::Complete;
        }
        let kind = classify_remote_failure(&attempt);
        let status = attempt.status.code();
        self.failures.push(FailureEvidence {
            kind,
            status,
            stdout: attempt.stdout,
            stderr: attempt.stderr,
        });
        let attempts = self.failures.len();
        if kind.retryable() && attempts < self.policy.max_attempts {
            RetryDecision::Retry {
                next_attempt: attempts + 1,
                delay: self.policy.base_delay.saturating_mul(attempts as u32),
                kind,
            }
        } else {
            RetryDecision::Stop { kind, status }
        }
    }
}

pub trait CommandExecutor {
    fn execute(&mut self, command: &CommandSpec) -> CommandAttempt;

    fn wait_before_retry(&mut self, delay: Duration);
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RetryExecution {
    pub attempt: CommandAttempt,
    pub failures: Vec<FailureEvidence>,
}

pub fn execute_with_retry(
    executor: &mut impl CommandExecutor,
    command: &CommandSpec,
    policy: RetryPolicy,
) -> RetryExecution {
    let mut tracker = RetryTracker::new(policy);
    loop {
        let attempt = executor.execute(command);
        match tracker.observe(attempt.clone()) {
            RetryDecision::Retry { delay, .. } => executor.wait_before_retry(delay),
            RetryDecision::Complete | RetryDecision::Stop { .. } => {
                return RetryExecution {
                    attempt,
                    failures: tracker.failures,
                };
            }
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BuildBatch {
    Parallel(Vec<String>),
    Serial(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BuildSchedule {
    pub max_in_flight: usize,
    pub batches: Vec<BuildBatch>,
    build_logs: bool,
}

impl BuildSchedule {
    pub fn new(hosts: Vec<String>, max_in_flight: usize, control_plane: &[String]) -> Result<Self> {
        if max_in_flight == 0 {
            bail!("build concurrency must be positive");
        }
        if hosts.iter().any(String::is_empty) {
            bail!("build schedule contains an empty host");
        }
        let unique = hosts.iter().collect::<BTreeSet<_>>();
        if unique.len() != hosts.len() {
            bail!("build schedule contains duplicate hosts");
        }
        let control_plane = control_plane.iter().collect::<BTreeSet<_>>();
        let mut batches = Vec::new();
        let mut parallel = Vec::new();
        for host in hosts {
            if max_in_flight > 1 && control_plane.contains(&host) {
                if !parallel.is_empty() {
                    batches.push(BuildBatch::Parallel(std::mem::take(&mut parallel)));
                }
                batches.push(BuildBatch::Serial(host));
            } else {
                parallel.push(host);
            }
        }
        if !parallel.is_empty() {
            batches.push(BuildBatch::Parallel(parallel));
        }
        Ok(Self {
            max_in_flight,
            batches,
            build_logs: false,
        })
    }

    pub fn with_build_logs(mut self, build_logs: bool) -> Self {
        self.build_logs = build_logs;
        self
    }

    pub fn build_args(&self) -> BuildArgs {
        BuildArgs::for_concurrency(self.max_in_flight, self.build_logs)
            .expect("validated build concurrency")
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BuildHostDeployMode {
    Auto,
    Cache,
    LocalCopy,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CacheSource {
    pub url: String,
    pub trusted_public_keys: Vec<String>,
}

impl CacheSource {
    pub fn new(
        url: impl Into<String>,
        trusted_public_keys: impl IntoIterator<Item = impl Into<String>>,
    ) -> Result<Self> {
        let url = url.into();
        if url.trim().is_empty() {
            bail!("build cache URL cannot be empty");
        }
        Ok(Self {
            url,
            trusted_public_keys: trusted_public_keys.into_iter().map(Into::into).collect(),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DistributionInputs {
    pub build_resource: String,
    pub target_resource: String,
    pub configured_mode: BuildHostDeployMode,
    pub build_host_is_cache_host: bool,
    pub target_is_local: bool,
    pub cache: Option<CacheSource>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DistributionPlan {
    VerifyExisting {
        closure: NixStorePath,
    },
    TargetCachePull {
        closure: NixStorePath,
        cache: CacheSource,
        retry: bool,
    },
    RelayThroughLocal {
        closure: NixStorePath,
        cache: CacheSource,
    },
    TryTargetCacheThenRelay {
        closure: NixStorePath,
        cache: CacheSource,
    },
}

impl DistributionInputs {
    pub fn plan(&self, closure: &NixStorePath) -> Result<DistributionPlan> {
        if self.build_resource.is_empty() || self.target_resource.is_empty() {
            bail!("build and target resource identities must be non-empty");
        }
        // Remote deploy builds validate cache configuration after retaining the
        // scoped output, even when the destination shares the builder's store.
        let cache = self
            .cache
            .clone()
            .ok_or_else(|| anyhow::anyhow!("remote deploy build requires a configured cache"))?;
        if self.build_resource == self.target_resource {
            return Ok(DistributionPlan::VerifyExisting {
                closure: closure.clone(),
            });
        }

        let local_copy = self.configured_mode == BuildHostDeployMode::LocalCopy
            || (self.configured_mode == BuildHostDeployMode::Auto
                && !self.build_host_is_cache_host);
        if local_copy {
            return if self.target_is_local {
                Ok(DistributionPlan::TargetCachePull {
                    closure: closure.clone(),
                    cache,
                    retry: true,
                })
            } else {
                Ok(DistributionPlan::RelayThroughLocal {
                    closure: closure.clone(),
                    cache,
                })
            };
        }
        if self.configured_mode == BuildHostDeployMode::Cache {
            return Ok(DistributionPlan::TargetCachePull {
                closure: closure.clone(),
                cache,
                retry: true,
            });
        }
        if self.target_is_local {
            Ok(DistributionPlan::TargetCachePull {
                closure: closure.clone(),
                cache,
                retry: false,
            })
        } else {
            Ok(DistributionPlan::TryTargetCacheThenRelay {
                closure: closure.clone(),
                cache,
            })
        }
    }
}
