//! Native fleet workflow coordinator.

mod scheduling;

use std::collections::{BTreeMap, BTreeSet};
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, anyhow, bail};
use sha2::{Digest, Sha256};

use crate::programs::age::Age;
use crate::programs::clear_git_repository_environment;

use super::admission::{Adjustment, AdmissionControl, AdmissionLimits};
use super::bootstrap::{
    AgeDiscoveryMode, AgeIdentityPolicy, ForcedCommandInput, ForcedCommandObservation,
    ForcedCommandReadiness, age_identity_candidates, build_forced_command_check,
    classify_forced_command_readiness, temporary_transport_failure,
};
use super::build::{
    BuildArgs, BuildBatch, BuildCacheContext, BuildCacheState, BuildHostDeployMode, BuildSchedule,
    BuilderClosure, CacheSource, CommandSpec, CommandStatus, DistributionInputs, DistributionPlan,
    LocalBuildSpec, NixStorePath, RetryPolicy, automatic_build_plan_jobs, build_plan_cache_file,
    build_plan_evaluation_command, build_plan_probe_command, closure_verification_command,
    copy_derivation_command, development_build_command, local_build_command,
    validate_cached_build_plan,
};
use super::build_lease::{
    BuilderLeaseCoordinator, InvocationId, LeaseEpoch, LeaseRetryPolicy, SystemLeaseConnector,
};
use super::build_runtime::{
    ProtectedBuilder, RemoteBuildTools, UnconfirmedBuild, plan_remote_build, realize_protected,
};
use super::cli::{Action, Invocation};
use super::engine::{FleetEffects, PhaseFailure};
use super::environment::{Environment, LocalSelfTarget, Settings};
use super::host_runtime::{
    ActivationExecution, DistributionExecution, DryRun, EffectKind, HostExecutionTarget,
    HostRuntime, ProcessExecutor, ProcessOutput, builder_lease_process_spec,
    nix_sshopts_without_control_master, render_proxy_chain, retire_control_master,
    ssh_connection_args,
};
use super::host_tasks::{
    AcquireStep, BootstrapStep, BuildStep, DeployStep, HealthStep, PhaseStep, ReadinessStep,
    SnapshotStep, TransferStep, VerifyStep, run_step, run_step_with,
};
use super::inventory::{DeployMode, Inventory};
use super::orchestration::{
    FinalHostState, HostMilestone, HostQualifier, HostStage, PhaseResult, PhaseResultKind,
};
use super::plan::{Phase, WorkflowPlan};
use super::presentation::{FleetProgress, HostStatus, WorkflowResult};
use super::selection::Selection;
use super::system::{ResolvedHost, resolve_host};
use super::system_identity;
use super::task::{InternalTask, StepSpecSource, TaskOutcome, TaskScope};
use super::transport::{
    HostKeyPolicy, HostTransport, ProcessStatus, ProxyCommandTemplate, SelfTargetDecision,
    SelfTargetEvidence, SelfTargetMode, SshEndpoint, SshRoutePlan, TransportRole,
    output_indicates_transport_loss, plan_self_target,
};

const SSH_CONTROL_PATH_LIMIT: usize = 108;
const CONTROL_SOCKET_DIGEST_HEX_LEN: usize = 20;
/// System `true`, used for the transport connectivity probe without relying on
/// the ambient remote PATH.
const SYSTEM_TRUE: &str = "/run/current-system/sw/bin/true";

fn route_relevant_transport_failure(output: &str) -> bool {
    output_indicates_transport_loss(output)
        || output.contains("Connection refused")
        || output.contains("Network is unreachable")
}

fn health_failure_message(
    host: &str,
    kind: &str,
    report: &super::health_runtime::ManagedHealthReport,
) -> String {
    // Details stay raw here; the presentation boundary sanitizes the rendered
    // failure summary. Keeping this execution-side avoids a second, partial
    // redaction that could diverge from the display contract.
    let details = report
        .details
        .iter()
        .filter(|detail| !detail.trim().is_empty())
        .cloned()
        .collect::<Vec<_>>();
    let mut message = format!(
        "{host}: post-switch {kind}: {}",
        if details.is_empty() {
            "no additional health detail".to_owned()
        } else {
            details.join("; ")
        }
    );
    if !report.failure_excerpts.is_empty() {
        message.push_str("\n    Recent service evidence:");
        for excerpt in report.failure_excerpts.iter().take(4) {
            message.push_str("\n      ");
            message.push_str(excerpt);
        }
    }
    message
}

fn health_progress_line(
    attempt: usize,
    decision: &super::health::HealthDecision,
    details: &[String],
) -> String {
    let state = match decision {
        super::health::HealthDecision::Healthy { .. } => "healthy",
        super::health::HealthDecision::Settling { .. } => "settling",
        super::health::HealthDecision::ServiceFailure { .. } => "service failure",
        super::health::HealthDecision::StructuralFailure { .. } => "structural failure",
    };
    // Presentation sanitizes and allowlists the detail; execution keeps it raw
    // so there is exactly one display boundary for collector text.
    let detail = details
        .first()
        .filter(|detail| !detail.is_empty())
        .map(|detail| format!(" · {detail}"))
        .unwrap_or_default();
    format!("[health-check] attempt {attempt} · {state}{detail}")
}

/// Settled owned-build results retained by their consumer: rooted closures and
/// the activation facts evaluated with them. Deployment never re-evaluates.
pub struct OwnedHandoff {
    pub closures: BTreeMap<String, NixStorePath>,
    pub boot: BTreeMap<String, super::deploy::BootEnvironment>,
    /// Inventory host of the builder whose shared store holds the closures.
    pub builder: String,
    /// Signed publisher already verified by acquisition; targets pull from it.
    pub cache: CacheSource,
    /// Ordinary run-state directory for transport material (short SSH
    /// control paths); the retained source tree itself is read-only.
    pub runtime: PathBuf,
}

/// Run-scoped durable withdrawal; cloned by scoped workers, never installed as
/// process cancellation. A failed read also latches closed for this invocation.
#[derive(Clone)]
pub struct ForwardWorkGuard<'a>(Arc<ForwardWorkState<'a>>);

struct ForwardWorkState<'a> {
    check: &'a (dyn Fn() -> Result<()> + Sync),
    stopped: OnceLock<String>,
}

impl<'a> ForwardWorkGuard<'a> {
    pub fn new(check: &'a (dyn Fn() -> Result<()> + Sync)) -> Self {
        Self(Arc::new(ForwardWorkState {
            check,
            stopped: OnceLock::new(),
        }))
    }

    pub fn check(&self) -> Result<()> {
        if let Some(reason) = self.0.stopped.get() {
            bail!("retained deployment forward work stopped: {reason}");
        }
        if let Err(error) = (self.0.check)() {
            let _ = self.0.stopped.set(format!("{error:#}"));
            return Err(error);
        }
        if let Some(reason) = self.0.stopped.get() {
            bail!("retained deployment forward work stopped: {reason}");
        }
        Ok(())
    }

    fn stopped(&self) -> bool {
        self.0.stopped.get().is_some()
    }
}

fn check_forward_work(guard: &Option<ForwardWorkGuard<'_>>) -> Result<()> {
    match guard {
        Some(guard) => guard.check(),
        None => Ok(()),
    }
}

fn interruption_active() -> bool {
    super::signal::runtime()
        .and_then(|runtime| runtime.interruption())
        .is_some()
}

fn publish_build_result<T>(progress: &FleetProgress, host: &str, result: &Result<T>) {
    match result {
        Ok(_) => progress.host_status(host, HostStatus::BuildDone),
        Err(error) if error.downcast_ref::<UnconfirmedBuild>().is_some() => {
            progress.host_unconfirmed(host, super::presentation::build_error_summary(error));
        }
        Err(error) => progress.host_failed(host, super::presentation::build_error_summary(error)),
    }
}

fn build_failure_report(
    progress: &FleetProgress,
    host: &str,
    builder: &str,
    error: &anyhow::Error,
) -> String {
    let mut report = format!(
        "build {host} on {builder}: {}",
        super::presentation::build_error_summary(error)
    );
    match progress.build_diagnostic_path(host, builder) {
        Ok(Some(path)) => report.push_str(&format!("\n  diagnostics: {path}")),
        Ok(None) => {}
        Err(_) => report.push_str("\n  full diagnostics unavailable (recorder write failed)"),
    }
    report
}

pub struct NativeFleetEffects<'a> {
    admission: AdmissionControl,
    owned: Option<Arc<OwnedHandoff>>,
    forward_work: Option<ForwardWorkGuard<'a>>,
    invocation: &'a Invocation,
    nix_program: &'a Path,
    repository: &'a Path,
    inventory: &'a Inventory,
    selection: &'a Selection,
    host_runtime: HostRuntime<ProcessExecutor>,
    progress: FleetProgress,
    transport_store: tempfile::TempDir,
    invocation_id: InvocationId,
    builder_lease: Arc<BuilderLeaseCoordinator>,
    builder_closures: BTreeMap<String, BuilderClosure>,
    settings: Settings,
    derivations: BTreeMap<String, NixStorePath>,
    closures: BTreeMap<String, NixStorePath>,
    unconfirmed_builds: BTreeSet<String>,
    unstarted_builds: BTreeSet<String>,
    build_failed: BTreeSet<String>,
    snapshots: BTreeMap<String, super::deploy::GenerationSnapshot>,
    candidate_leases: BTreeMap<String, NixStorePath>,
    acquired: BTreeMap<String, NixStorePath>,
    acquisition_deferred: BTreeSet<String>,
    activated: BTreeSet<String>,
    successful: BTreeSet<String>,
    deploy_skipped: BTreeSet<String>,
    optional_snapshot_skipped: BTreeSet<String>,
    snapshot_failed: BTreeSet<String>,
    deploy_failed: BTreeSet<String>,
    health_failed: BTreeSet<String>,
    rollback_succeeded: BTreeSet<String>,
    rollback_failed: BTreeSet<String>,
    bootstrap_failed: BTreeSet<String>,
    phase_results: Vec<(Phase, PhaseResult)>,
    workflow_warnings: Vec<WorkflowWarning>,
    pending_rollback: BTreeSet<String>,
    deploy_failures: Vec<String>,
    bootstrap_prepared: BTreeSet<String>,
    age_identity_prepared: BTreeSet<String>,
    prepared_targets: BTreeMap<String, HostExecutionTarget>,
    diagnostic_dir: Option<PathBuf>,
}

#[derive(Clone, Debug)]
struct WorkflowWarning {
    host: String,
    detail: String,
}

struct DeployTaskOutcome {
    host: String,
    policy: DeployMode,
    result: Result<()>,
    activated: bool,
    successful: bool,
    pending_rollback: bool,
    deploy_failed: bool,
    rollback_succeeded: bool,
    rollback_failed: bool,
    candidate_lease: Option<NixStorePath>,
    cleanup_error: Option<String>,
}

struct AcquireTaskOutcome {
    host: String,
    policy: DeployMode,
    result: Result<()>,
    candidate_lease: Option<NixStorePath>,
    acquired: Option<NixStorePath>,
    deferred: bool,
}

impl AcquireTaskOutcome {
    fn stops_admission(&self) -> bool {
        self.result.is_err() && self.policy != DeployMode::Optional
    }
}

#[derive(Clone)]
struct AcquisitionTarget {
    closure: NixStorePath,
    generation: super::deploy::SystemGeneration,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CandidateAcquisition {
    Approved,
    Deferred,
}

fn execute_candidate_acquisition_pipeline<C>(
    context: &mut C,
    distribute: impl FnOnce(&mut C) -> Result<()>,
    protect: impl FnOnce(&mut C) -> Result<()>,
    admit: impl FnOnce(&mut C) -> Result<CandidateAcquisition>,
    pull_images: impl FnOnce(&mut C) -> Result<()>,
    prefetch_models: impl FnOnce(&mut C) -> Result<()>,
) -> Result<()> {
    distribute(context)?;
    protect(context)?;
    if admit(context)? == CandidateAcquisition::Approved {
        pull_images(context)?;
        prefetch_models(context)?;
    }
    Ok(())
}

impl<'a> NativeFleetEffects<'a> {
    pub fn new(
        invocation: &'a Invocation,
        nix_program: &'a Path,
        repository: &'a Path,
        inventory: &'a Inventory,
        selection: &'a Selection,
    ) -> Result<Self> {
        Self::new_with_diagnostics(
            invocation,
            nix_program,
            repository,
            inventory,
            selection,
            None,
        )
    }

    pub fn new_with_diagnostics(
        invocation: &'a Invocation,
        nix_program: &'a Path,
        repository: &'a Path,
        inventory: &'a Inventory,
        selection: &'a Selection,
        diagnostic_dir: Option<&Path>,
    ) -> Result<Self> {
        invocation.require_nix_pipeline()?;
        Self::create(
            invocation,
            nix_program,
            repository,
            inventory,
            selection,
            diagnostic_dir,
            None,
        )
    }

    /// Deployment of retained owned results from the exact evaluated source
    /// tree. No build strategy, realization or flake evaluation.
    pub fn with_owned_handoff(
        invocation: &'a Invocation,
        nix_program: &'a Path,
        source: &'a Path,
        inventory: &'a Inventory,
        selection: &'a Selection,
        handoff: OwnedHandoff,
        diagnostic_dir: &Path,
    ) -> Result<Self> {
        if !matches!(invocation.action, Action::Deploy) {
            bail!("owned handoff deploys only retained Deploy results");
        }
        if handoff.closures.keys().ne(handoff.boot.keys()) {
            bail!("owned handoff closures and activation facts differ");
        }
        Self::create(
            invocation,
            nix_program,
            source,
            inventory,
            selection,
            Some(diagnostic_dir),
            Some(Arc::new(handoff)),
        )
    }

    pub fn with_forward_work(mut self, guard: ForwardWorkGuard<'a>) -> Result<Self> {
        if self.owned.is_none() {
            bail!("durable forward-work guard requires a retained handoff");
        }
        self.forward_work = Some(guard);
        Ok(self)
    }

    fn check_forward_work(&self) -> Result<()> {
        check_forward_work(&self.forward_work)
    }

    fn create(
        invocation: &'a Invocation,
        nix_program: &'a Path,
        repository: &'a Path,
        inventory: &'a Inventory,
        selection: &'a Selection,
        diagnostic_dir: Option<&Path>,
        owned: Option<Arc<OwnedHandoff>>,
    ) -> Result<Self> {
        if !repository.is_absolute() {
            bail!("native fleet repository must be absolute");
        }
        if !nix_program.is_absolute() {
            bail!("native fleet Nix program must be absolute");
        }
        let transport_parent = match &owned {
            Some(handoff) => handoff.runtime.as_path(),
            None => repository.parent().unwrap_or(repository),
        };
        let transport_store = tempfile::Builder::new()
            .prefix("t-")
            .tempdir_in(transport_parent)
            .context("create fleet transport material directory")?;
        let started = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .context("system clock predates Unix epoch")?
            .as_secs();
        let settings = Environment::current().settings()?;
        let progress = FleetProgress::from_options(&invocation.options).with_heartbeat_intervals(
            settings.build_heartbeat_seconds,
            settings.activation_heartbeat_seconds,
        );
        let progress = match diagnostic_dir {
            Some(directory) => progress.with_diagnostics(directory)?,
            None => progress,
        };
        let builder_lease = BuilderLeaseCoordinator::with_retry_policy(
            Arc::new(SystemLeaseConnector),
            LeaseRetryPolicy::transport(
                settings.transport_retry_attempts,
                Duration::from_secs(settings.transport_retry_delay_seconds),
            )?,
        );
        let builder_lease = match super::signal::runtime() {
            Some(cancellation) => {
                builder_lease.with_cancellation(Arc::new(move || cancellation.cancel_local()))
            }
            None => builder_lease,
        };
        Ok(Self {
            admission: AdmissionControl::new(
                AdmissionLimits {
                    global: invocation.options.build_jobs,
                    per_domain: invocation.options.build_jobs,
                    hard_domain_max: None,
                },
                selection.ordered.len().max(1),
            )?,
            owned,
            forward_work: None,
            invocation,
            nix_program,
            repository,
            inventory,
            selection,
            host_runtime: HostRuntime::new(
                reporting_process_runner(&progress),
                repository.to_path_buf(),
                if invocation.options.dry_run {
                    DryRun::Yes
                } else {
                    DryRun::No
                },
            )?,
            progress,
            transport_store,
            invocation_id: InvocationId::derive(
                transport_store_name(repository),
                started,
                std::process::id(),
            ),
            builder_lease: Arc::new(builder_lease),
            builder_closures: BTreeMap::new(),
            settings,
            derivations: BTreeMap::new(),
            closures: BTreeMap::new(),
            unconfirmed_builds: BTreeSet::new(),
            unstarted_builds: BTreeSet::new(),
            build_failed: BTreeSet::new(),
            snapshots: BTreeMap::new(),
            candidate_leases: BTreeMap::new(),
            acquired: BTreeMap::new(),
            acquisition_deferred: BTreeSet::new(),
            activated: BTreeSet::new(),
            successful: BTreeSet::new(),
            deploy_skipped: BTreeSet::new(),
            optional_snapshot_skipped: BTreeSet::new(),
            snapshot_failed: BTreeSet::new(),
            deploy_failed: BTreeSet::new(),
            health_failed: BTreeSet::new(),
            rollback_succeeded: BTreeSet::new(),
            rollback_failed: BTreeSet::new(),
            bootstrap_failed: BTreeSet::new(),
            phase_results: Vec::new(),
            workflow_warnings: Vec::new(),
            pending_rollback: BTreeSet::new(),
            deploy_failures: Vec::new(),
            bootstrap_prepared: BTreeSet::new(),
            age_identity_prepared: BTreeSet::new(),
            prepared_targets: BTreeMap::new(),
            diagnostic_dir: diagnostic_dir.map(Path::to_path_buf),
        })
    }

    /// Root workflow boundary; worker construction never installs input handlers.
    /// The retained handoff, not UI state, selects the execution authority.
    pub fn execute(&mut self) -> Result<()> {
        let _keys = super::interactive::keys_available().then(|| {
            let input = self.admission.input();
            self.progress.concurrency_handler(move |change| {
                input.adjust(match change {
                    crate::progress::ConcurrencyChange::Increase => Adjustment::Increase,
                    crate::progress::ConcurrencyChange::Decrease => Adjustment::Decrease,
                })
            })
        });
        if self.owned.is_some() {
            let forward_work = self.forward_work.clone();
            super::engine::execute_retained_with_interrupt_check(self.invocation, self, || {
                super::signal::check_interrupted()?;
                check_forward_work(&forward_work)
            })
        } else {
            super::engine::execute(self.invocation, self)
        }
    }

    pub fn derivations(&self) -> &BTreeMap<String, NixStorePath> {
        &self.derivations
    }

    pub fn closures(&self) -> &BTreeMap<String, NixStorePath> {
        &self.closures
    }

    pub fn report_summary(&self, outcome: &Result<()>, elapsed: Duration) {
        use super::orchestration::{HostSummaryFacts, SummaryMode};

        let interrupted = outcome
            .as_ref()
            .err()
            .is_some_and(|error| error.downcast_ref::<super::signal::Interrupted>().is_some());

        let plan = WorkflowPlan::for_action(&self.invocation.action);
        let host_action = plan.phases.iter().any(|phase| phase.uses_hosts());
        let deployment = matches!(self.invocation.action, Action::Run | Action::Deploy);
        let mode = if deployment {
            SummaryMode::Deployment
        } else {
            SummaryMode::BuildLike
        };
        let hosts = if host_action {
            self.selection
                .ordered
                .iter()
                .map(|host| {
                    if self.invocation.action == Action::Prepare {
                        return (host.clone(), self.preparation_summary(host, interrupted));
                    }
                    let rollback_succeeded = self.rollback_succeeded.contains(host);
                    let rollback_failed = self.rollback_failed.contains(host);
                    let health_failed = self.health_failed.contains(host);
                    let deploy_failed = self.deploy_failed.contains(host);
                    let check_failed = self.bootstrap_failed.contains(host);
                    let fully_skipped =
                        deployment && self.inventory.hosts[host].deploy == DeployMode::Skip;
                    let build_succeeded =
                        if matches!(self.invocation.action, Action::CheckBootstrap) {
                            !check_failed
                        } else {
                            self.closures.contains_key(host)
                        };
                    let facts = HostSummaryFacts {
                        build_unconfirmed: self.unconfirmed_builds.contains(host),
                        build_not_started: self.unstarted_builds.contains(host),
                        build_succeeded,
                        build_failed: check_failed || self.build_failed.contains(host),
                        interrupted: interrupted
                            && !fully_skipped
                            && !build_succeeded
                            && !check_failed,
                        fully_skipped,
                        snapshot_failed: self.snapshot_failed.contains(host),
                        deploy_succeeded: self.successful.contains(host),
                        deploy_skipped: self.deploy_skipped.contains(host),
                        deploy_failed,
                        optional_snapshot_skipped: self.optional_snapshot_skipped.contains(host),
                        optional_rollback_succeeded: self.inventory.hosts[host].deploy
                            == DeployMode::Optional
                            && rollback_succeeded,
                        optional_rollback_failed: self.inventory.hosts[host].deploy
                            == DeployMode::Optional
                            && rollback_failed,
                        rollback_succeeded: rollback_succeeded && !health_failed && !deploy_failed,
                        rollback_failed: rollback_failed && !health_failed && !deploy_failed,
                        deploy_rollback_succeeded: deploy_failed && rollback_succeeded,
                        deploy_rollback_failed: deploy_failed && rollback_failed,
                        health_failed,
                        health_rollback_succeeded: health_failed && rollback_succeeded,
                        health_rollback_failed: health_failed && rollback_failed,
                    };
                    (host.clone(), facts.final_state(mode))
                })
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        let phases = plan
            .phases
            .into_iter()
            .map(|phase| {
                let result = self
                    .phase_results
                    .iter()
                    .find_map(|(recorded, result)| (*recorded == phase).then_some(*result));
                (phase, result)
            })
            .collect::<Vec<_>>();
        self.progress.workflow_summary(
            &self.invocation.action,
            phases,
            hosts.iter().map(|(host, status)| (host.as_str(), *status)),
            if outcome.is_ok() && !self.workflow_warnings.is_empty() {
                WorkflowResult::SuccessWithWarnings
            } else if outcome.is_ok() {
                WorkflowResult::Success
            } else if interrupted {
                WorkflowResult::Interrupted
            } else {
                WorkflowResult::Failure
            },
            elapsed,
        );
    }

    fn verify_candidate_cleanup(&self, result: Result<()>) -> Result<()> {
        if self.candidate_leases.is_empty() {
            return result;
        }
        let detail = format!(
            "candidate lease cleanup incomplete for {}",
            self.candidate_leases
                .keys()
                .cloned()
                .collect::<Vec<_>>()
                .join(", ")
        );
        match result {
            Err(error) => Err(error.context(detail)),
            Ok(()) => Err(anyhow!(detail)),
        }
    }

    fn preparation_summary(&self, host: &str, interrupted: bool) -> FinalHostState {
        let built = self.closures.contains_key(host);
        if self.unconfirmed_builds.contains(host) {
            FinalHostState::new(
                HostMilestone::None,
                HostQualifier::Unconfirmed(HostStage::Build),
            )
        } else if self.unstarted_builds.contains(host) {
            FinalHostState::new(
                HostMilestone::None,
                HostQualifier::NotStarted(HostStage::Build),
            )
        } else if self.build_failed.contains(host) {
            FinalHostState::failed(HostMilestone::None, HostStage::Build)
        } else if self.inventory.hosts[host].deploy == DeployMode::Skip {
            FinalHostState::skipped(
                if built {
                    HostMilestone::Built
                } else {
                    HostMilestone::None
                },
                built.then_some(HostStage::Acquire),
            )
        } else if self.deploy_failed.contains(host) {
            FinalHostState::new(
                HostMilestone::Built,
                if self.inventory.hosts[host].deploy == DeployMode::Optional {
                    HostQualifier::OptionalFailed(HostStage::Acquire)
                } else {
                    HostQualifier::Failed(Some(HostStage::Acquire))
                },
            )
        } else if self.acquisition_deferred.contains(host) {
            FinalHostState::new(
                HostMilestone::Built,
                HostQualifier::Deferred(HostStage::Acquire),
            )
        } else if self.acquired.contains_key(host) {
            FinalHostState::ok(HostMilestone::Acquired)
        } else if self.invocation.options.dry_run {
            FinalHostState::new(HostMilestone::Built, HostQualifier::DryRun)
        } else if interrupted {
            FinalHostState::new(
                if built {
                    HostMilestone::Built
                } else {
                    HostMilestone::None
                },
                HostQualifier::Interrupted,
            )
        } else if built {
            FinalHostState::new(
                HostMilestone::Built,
                HostQualifier::Incomplete(HostStage::Acquire),
            )
        } else {
            FinalHostState::failed(HostMilestone::None, HostStage::Build)
        }
    }

    fn build_plan_cache_context(&self) -> Result<Option<(PathBuf, String)>> {
        let git = |args: &[&str]| -> Result<std::process::Output> {
            let mut command = Command::new("git");
            clear_git_repository_environment(&mut command);
            command
                .args(args)
                .current_dir(self.repository)
                .output()
                .with_context(|| format!("execute git {}", args.join(" ")))
        };
        let inside = git(&["rev-parse", "--is-inside-work-tree"])?;
        let refreshed = git(&["update-index", "--refresh"])?;
        let unmerged = git(&["diff", "--name-only", "--diff-filter=U"])?;
        let unstaged = git(&["diff", "--quiet"])?;
        let state = BuildCacheState {
            enabled: self.settings.build_plan_cache,
            inside_worktree: inside.status.success()
                && String::from_utf8_lossy(&inside.stdout).trim() == "true",
            index_refreshed: refreshed.status.success(),
            unmerged_paths: !unmerged.stdout.is_empty(),
            unstaged_changes: !unstaged.status.success(),
        };
        if !state.allows_cache() {
            return Ok(None);
        }
        let head = git(&["rev-parse", "HEAD"])?;
        let tree = git(&["write-tree"])?;
        if !head.status.success() || !tree.status.success() {
            return Ok(None);
        }
        let mut command = Command::new(self.nix_program);
        clear_git_repository_environment(&mut command);
        let version = command
            .arg("--version")
            .current_dir(self.repository)
            .output()
            .context("read Nix version for build-plan cache")?;
        if !version.status.success() {
            return Ok(None);
        }
        let context = BuildCacheContext::new(
            String::from_utf8(version.stdout)?.trim(),
            String::from_utf8(head.stdout)?.trim(),
            String::from_utf8(tree.stdout)?.trim(),
        )?;
        let root = self.settings.build_plan_cache_dir.clone().or_else(|| {
            std::env::var_os("XDG_CACHE_HOME")
                .map(PathBuf::from)
                .or_else(|| {
                    std::env::var_os("HOME")
                        .map(PathBuf::from)
                        .map(|home| home.join(".cache"))
                })
                .map(|home| home.join("nixbot/build-plans/v1"))
        });
        Ok(root.map(|root| (root, context.key())))
    }

    fn cached_derivation(
        &self,
        cache: Option<&(PathBuf, String)>,
        host: &str,
        configuration: &str,
    ) -> Result<Option<(PathBuf, NixStorePath)>> {
        let Some((root, context)) = cache else {
            return Ok(None);
        };
        let path = build_plan_cache_file(root, context, host, configuration)?;
        let contents = match std::fs::read_to_string(&path) {
            Ok(contents) => contents,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error).with_context(|| format!("read {}", path.display())),
        };
        match validate_cached_build_plan(&contents, Path::new(contents.trim()).is_file()) {
            Ok(derivation) => Ok(Some((path, derivation))),
            Err(_) => Ok(None),
        }
    }

    fn write_cached_derivation(&self, path: &Path, derivation: &NixStorePath) -> Result<()> {
        let parent = path
            .parent()
            .context("build-plan cache path has no parent")?;
        std::fs::create_dir_all(parent)?;
        let temporary = parent.join(format!(
            ".drv-path-{}-{}.tmp",
            std::process::id(),
            safe_component(derivation.as_str())
        ));
        std::fs::write(&temporary, format!("{}\n", derivation.as_str()))?;
        std::fs::rename(&temporary, path)?;
        Ok(())
    }

    fn run_build_phase(&mut self, development: bool) -> Result<()> {
        self.check_forward_work()?;
        if let Some(owned) = self.owned.clone() {
            // Settled, signed and consumer-rooted; never realized again here.
            if development {
                bail!("owned handoff has no development build");
            }
            for host in &self.selection.ordered {
                if let Some(closure) = owned.closures.get(host) {
                    self.closures.insert(host.clone(), closure.clone());
                    self.progress.host_status(host, HostStatus::BuildDone);
                } else {
                    self.progress.host_status(host, HostStatus::BuildSkip);
                }
            }
            if owned
                .closures
                .keys()
                .any(|host| !self.selection.ordered.contains(host))
            {
                bail!("owned handoff closure outside the retained selection");
            }
            return Ok(());
        }
        let nix = self.nix_program.to_string_lossy();
        let control = self.admission_control(self.invocation.options.build_jobs, false)?;
        let build_args = BuildArgs::for_parallelism(
            control.parallelism_possible(super::interactive::keys_available()),
            self.invocation.options.build_logs,
        );
        let requested_plan_jobs = match self.invocation.options.build_plan_jobs {
            super::cli::JobCount::Auto => automatic_build_plan_jobs(
                std::thread::available_parallelism()
                    .map(usize::from)
                    .unwrap_or(1),
            )?,
            super::cli::JobCount::Count(count) => count,
        };
        let probe_jobs = super::build::effective_build_plan_jobs(
            requested_plan_jobs,
            self.selection.ordered.len(),
        )?;
        self.progress.phase_schedule("plan probe", Some((1, 1)), 1);
        let probe_args = if probe_jobs > 1 {
            vec![
                "--option".to_owned(),
                "eval-cache".to_owned(),
                "false".to_owned(),
            ]
        } else {
            Vec::new()
        };
        let probe = build_plan_probe_command(&nix, &probe_args);
        let probe_scope: Arc<dyn TaskScope> = self.progress.phase_scope();
        let probe = run_step_with(
            &probe_scope,
            PhaseStep::BuildPlanProbe,
            |task| {
                self.host_runtime
                    .execute_local_command(&probe, EffectKind::ReadOnly, task)
            },
            process_outcome,
        )?;
        let catalog =
            super::preparation::PlanCatalog::from_probe(probe.succeeded(), &probe.stdout)?;
        let attribute = catalog.attribute();
        let targets = super::preparation::plan_targets(
            self.inventory,
            self.selection,
            &self.invocation.action,
            &self.invocation.options,
            &catalog,
        )?;
        let mut planned_hosts = Vec::new();
        for target in targets {
            let host = &target.host;
            if target.skipped {
                let spec = BuildStep::Plan.spec(host);
                self.progress
                    .task_skipped(spec.name, format!("{} {host}", spec.running));
                self.progress.host_status(host, HostStatus::BuildSkip);
            } else {
                planned_hosts.push((target.host, target.configuration));
            }
        }
        if planned_hosts.is_empty() {
            return Ok(());
        }

        // Every planned host is now waiting for build admission. Plan failures
        // overwrite their own host with `build_failed`; hosts never admitted to
        // a later build remain `build_not_started` instead of being invented as
        // failures during final summary inference.
        self.unstarted_builds
            .extend(planned_hosts.iter().map(|(host, _)| host.clone()));

        let plan_jobs =
            super::build::effective_build_plan_jobs(requested_plan_jobs, planned_hosts.len())?;
        self.progress
            .phase_schedule("evaluate plans", Some((1, 1)), plan_jobs);
        let plan_control = self.admission_control(plan_jobs, false)?;
        let plan_args = if plan_control.parallelism_possible(super::interactive::keys_available()) {
            vec![
                "--option".to_owned(),
                "eval-cache".to_owned(),
                "false".to_owned(),
            ]
        } else {
            Vec::new()
        };
        let cache = self.build_plan_cache_context()?;
        let mut pending = Vec::new();
        for (host, configuration) in &planned_hosts {
            if let Some((_, derivation)) =
                self.cached_derivation(cache.as_ref(), host, configuration)?
            {
                self.progress
                    .detail(format!("Build plan cache hit · {host}"));
                self.derivations.insert(host.clone(), derivation);
            } else {
                let plan =
                    build_plan_evaluation_command(&nix, &plan_args, attribute, configuration);
                let cache_path = cache
                    .as_ref()
                    .map(|(root, context)| {
                        build_plan_cache_file(root, context, host, configuration)
                    })
                    .transpose()?;
                pending.push((host.clone(), configuration, plan, cache_path));
            }
        }
        let repository = self.repository.to_path_buf();
        let progress = self.progress.clone();
        let pending_hosts = pending
            .iter()
            .map(|task| task.0.clone())
            .collect::<Vec<_>>();
        let evaluated = scheduling::dispatch(
            scheduling::unrestricted(pending),
            &plan_control,
            &progress,
            |(host, configuration, plan, cache_path)| -> Result<_> {
                let _operation = progress.host_operation(&host);
                let mut runtime = HostRuntime::new(
                    reporting_process_runner(&progress),
                    repository.clone(),
                    DryRun::No,
                )?;
                let derivation = {
                    let scope: Arc<dyn TaskScope> = progress.host_scope(&host);
                    run_step(&scope, BuildStep::Plan, |task| {
                        runtime.evaluate_build_plan(&plan, task)
                    })?
                }
                .executed()
                .context("build-plan evaluation was unexpectedly suppressed")?;
                Ok((host, configuration, derivation, cache_path))
            },
            // Plan errors are phase evidence, not an admission barrier: keep
            // evaluating the selected batch so every host gets a useful result.
            // Cancellation alone closes further admission.
            |_| super::signal::runtime().is_some_and(|signal| signal.cancel_local()),
            |index, result| {
                if let Err(error) = result {
                    progress.host_failed(
                        &pending_hosts[index],
                        format!("build plan failed: {error:#}"),
                    );
                }
            },
        )?;
        let mut plan_error = None;
        for (host, result) in pending_hosts.into_iter().zip(evaluated) {
            match result {
                Some(Ok((evaluated_host, _configuration, derivation, cache_path))) => {
                    debug_assert_eq!(host, evaluated_host);
                    if let Some(path) = cache_path {
                        self.write_cached_derivation(&path, &derivation)?;
                    }
                    self.derivations.insert(evaluated_host, derivation);
                }
                Some(Err(error)) => {
                    self.unstarted_builds.remove(&host);
                    self.build_failed.insert(host);
                    if plan_error.is_none() {
                        plan_error = Some(error);
                    }
                }
                None => {}
            }
        }
        if let Some(error) = plan_error {
            return Err(error);
        }
        let control_plane = self.inventory.control_plane_hosts()?;
        let schedule = BuildSchedule::new(
            planned_hosts.into_iter().map(|(host, _)| host).collect(),
            &control_plane,
        )?;
        let batch_count = schedule.batches.len();
        for (batch_index, batch) in schedule.batches.into_iter().enumerate() {
            match batch {
                BuildBatch::Parallel(hosts) => {
                    self.progress.phase_schedule(
                        "build",
                        Some((batch_index + 1, batch_count)),
                        control.snapshot().target,
                    );
                    self.build_parallel_batch(hosts, development, &build_args, &control)?;
                }
                BuildBatch::Serial(host) => {
                    self.progress
                        .phase_schedule("build", Some((batch_index + 1, batch_count)), 1);
                    self.progress.phase_admission(
                        1,
                        1,
                        false,
                        Some("exclusive control-plane build"),
                    );
                    let _operation = self.progress.host_operation(&host);
                    let derivation = self
                        .derivations
                        .get(&host)
                        .cloned()
                        .with_context(|| format!("missing evaluated derivation for {host}"))?;
                    self.unstarted_builds.remove(&host);
                    let builder = if development {
                        "local".to_owned()
                    } else {
                        self.build_host()
                    };
                    let result = self
                        .build_one(&host, development, &derivation, &build_args)
                        .with_context(|| format!("build {host}"));
                    publish_build_result(&self.progress, &host, &result);
                    let closure = result
                        .inspect_err(|error| self.record_build_error(&host, error))
                        .map_err(|error| {
                            anyhow::anyhow!(build_failure_report(
                                &self.progress,
                                &host,
                                &builder,
                                &error
                            ))
                        })?;
                    self.closures.insert(host.clone(), closure);
                }
            }
        }
        if matches!(self.invocation.action, Action::Build) {
            self.builder_lease.release();
        }
        Ok(())
    }

    fn build_parallel_batch(
        &mut self,
        hosts: Vec<String>,
        development: bool,
        build_args: &BuildArgs,
        control: &AdmissionControl,
    ) -> Result<()> {
        let tasks = hosts
            .into_iter()
            .map(|host| {
                let derivation = self
                    .derivations
                    .get(&host)
                    .cloned()
                    .with_context(|| format!("missing evaluated derivation for {host}"))?;
                Ok((host, derivation))
            })
            .collect::<Result<Vec<_>>>()?;
        let ordered_hosts = tasks
            .iter()
            .map(|(host, _)| host.clone())
            .collect::<Vec<_>>();
        let context = self.worker_context();
        let progress = self.progress.clone();
        let built = scheduling::dispatch(
            scheduling::unrestricted(tasks),
            control,
            &progress,
            |(host, derivation)| -> Result<_> {
                let _operation = progress.host_operation(&host);
                let mut worker = context.create()?;
                let closure = worker
                    .build_one(&host, development, &derivation, build_args)
                    .with_context(|| format!("build {host}"))?;
                Ok((host.clone(), closure, worker.builder_closures.remove(&host)))
            },
            |result| result.is_err() || context.stopped(),
            |index, result| publish_build_result(&progress, &ordered_hosts[index], result),
        )?;
        let mut failures = Vec::new();
        let builder = if development {
            "local".to_owned()
        } else {
            self.build_host()
        };
        // Results retain input order; None means no worker was admitted.
        for (host, result) in ordered_hosts.into_iter().zip(built) {
            if result.is_some() {
                self.unstarted_builds.remove(&host);
            }
            match result {
                Some(Ok((_host, closure, builder_closure))) => {
                    self.closures.insert(host.clone(), closure);
                    if let Some(builder_closure) = builder_closure {
                        self.builder_closures.insert(host.clone(), builder_closure);
                    }
                }
                Some(Err(error)) => {
                    self.record_build_error(&host, &error);
                    failures.push(build_failure_report(
                        &self.progress,
                        &host,
                        &builder,
                        &error,
                    ));
                }
                None => self.progress.host_status(&host, HostStatus::BuildBlocked),
            }
        }
        if !failures.is_empty() {
            bail!("fleet build did not complete: {}", failures.join("; "));
        }
        Ok(())
    }

    fn record_build_error(&mut self, host: &str, error: &anyhow::Error) {
        if error.downcast_ref::<UnconfirmedBuild>().is_some() {
            self.unconfirmed_builds.insert(host.to_owned());
        } else if error.downcast_ref::<super::signal::Interrupted>().is_some()
            || interruption_active()
        {
            // Cancellation is a terminal workflow outcome, not evidence that
            // the host build itself failed. Preserve it for final-state
            // resolution instead of letting BuildFailed shadow Interrupted.
        } else {
            self.build_failed.insert(host.to_owned());
        }
    }

    fn build_one(
        &mut self,
        host: &str,
        development: bool,
        derivation: &NixStorePath,
        build_args: &BuildArgs,
    ) -> Result<NixStorePath> {
        use abird_host_agent::build_executor::strategy::ExecutionStrategy;

        match self.invocation.options.strategy.resolve()? {
            ExecutionStrategy::Nix => self.nix_build_one(host, development, derivation, build_args),
            ExecutionStrategy::Agent => {
                anyhow::bail!(abird_host_agent::build_executor::strategy::AGENT_BACKEND_ONLY)
            }
        }
    }

    fn nix_build_one(
        &mut self,
        host: &str,
        development: bool,
        derivation: &NixStorePath,
        build_args: &BuildArgs,
    ) -> Result<NixStorePath> {
        let nix = self.nix_program.to_string_lossy();
        let build_host = self.build_host();
        let command = if development {
            let configuration = if self.invocation.options.host.as_deref() == Some(host) {
                self.invocation
                    .options
                    .nix_config
                    .as_deref()
                    .unwrap_or(host)
            } else {
                host
            };
            development_build_command(&nix, configuration, derivation, build_args)?
        } else {
            local_build_command(
                &nix,
                derivation,
                build_args,
                LocalBuildSpec { result_link: None },
            )
        };
        if development || build_host == "local" {
            let scope: Arc<dyn TaskScope> = self.progress.host_scope(host);
            run_step(&scope, BuildStep::Build, |task| {
                self.host_runtime.local_build(&command, task)
            })?
            .executed()
            .context("local build was unexpectedly suppressed")
        } else {
            self.remote_build(host, &build_host, derivation, build_args)
        }
    }

    fn run_terraform_phase(&self, phase: Phase, position: Option<(usize, usize)>) -> Result<()> {
        use crate::progress::RowOutcome;
        let action = match (&self.invocation.action, phase) {
            (Action::TerraformProject(name), Phase::Tofu) => {
                super::terraform::TerraformAction::TfProject(name.clone())
            }
            (_, Phase::TerraformDns) => super::terraform::TerraformAction::TfDns,
            (_, Phase::TerraformPlatform) => super::terraform::TerraformAction::TfPlatform,
            (_, Phase::TerraformApps) => super::terraform::TerraformAction::TfApps,
            _ => bail!("invalid Terraform phase {phase:?} for current action"),
        };
        let override_dir = std::env::var_os("NIXBOT_TF_DIR").map(PathBuf::from);
        let mut changes = super::terraform_runtime::SystemGitChangeSource {
            git_program: PathBuf::from("git"),
        };
        let selections = super::terraform_runtime::select_projects_for_execution(
            &action,
            override_dir.as_deref(),
            self.repository,
            !self.invocation.options.force && !self.invocation.options.dry_run,
            self.invocation.options.sha.as_deref().unwrap_or("HEAD"),
            Some("origin/master"),
            &mut changes,
        )?;
        let projects = selections
            .iter()
            .map(|selection| selection.run.name.clone())
            .collect::<Vec<_>>();
        self.progress.terraform_projects(phase, &projects, position);
        for selection in selections {
            let project = &selection.run.name;
            if selection.decision == super::terraform::ChangeDecision::SkipUnchanged {
                self.progress
                    .terraform_finished(project, RowOutcome::Skipped);
                continue;
            }
            super::signal::check_interrupted()?;
            self.progress.terraform_step(project, "preparing");
            let result = self.run_terraform_project(&selection);
            let (result, outcome) = match super::signal::check_interrupted() {
                Err(error) => (Err(error), RowOutcome::Interrupted),
                Ok(()) if result.is_ok() => (result, RowOutcome::Succeeded),
                Ok(()) => (result, RowOutcome::Failed),
            };
            self.progress.terraform_finished(project, outcome);
            result.with_context(|| format!("Terraform project {project}"))?;
        }
        Ok(())
    }

    fn run_terraform_project(
        &self,
        selection: &super::terraform_runtime::ProjectSelection,
    ) -> Result<()> {
        let context = super::terraform::project_context(&selection.run.directory)?;
        let identities = age_identities(&self.invocation.options);
        let decryptor = super::terraform_runtime::AgeDecryptor { identities };
        let mut materializer = super::terraform_runtime::SecureMaterializer::new(
            self.transport_store.path(),
            decryptor,
        )?;
        let inherited = std::env::vars().collect::<BTreeMap<_, _>>();
        let environment = super::terraform_runtime::resolve_environment(
            &super::terraform::project_environment_contract(&context),
            &inherited,
            self.repository,
            &mut materializer,
        )?;
        let discovered =
            super::terraform_runtime::discover_tfvar_secrets(self.repository, &selection.run.name)?;
        let automatic_tfvars =
            super::terraform_runtime::materialize_tfvars(&discovered, &mut materializer)?;
        let apps_default = self
            .repository
            .join("pkgs")
            .join(&selection.run.name)
            .join("default.nix");
        let execution = super::terraform_runtime::prepare_project_execution(
            &super::terraform_runtime::ProjectRuntimeInput {
                selection: selection.clone(),
                environment,
                automatic_tfvars,
                project_requires_secret_tfvars: project_requires_secret_tfvars(
                    &selection.run.directory,
                )?,
                dry_run: self.invocation.options.dry_run,
                plan_file: materializer
                    .root()
                    .join(format!("{}.tfplan", safe_component(&selection.run.name))),
                apps_package_default: apps_default.is_file().then_some(apps_default),
                repo_root: self.repository.to_path_buf(),
            },
        )?;
        let programs = super::terraform_runtime::RuntimePrograms::from_pairs([
            ("tofu", PathBuf::from("tofu")),
            ("nix", self.nix_program.to_path_buf()),
        ]);
        let mut executor = super::terraform_runtime::SystemCommandExecutor::new(programs);
        let mut step = "preparing";
        let report = super::terraform_runtime::execute_phase_observed(
            &[execution],
            self.repository,
            &mut executor,
            |project, command| {
                if interruption_active() {
                    return Err(super::terraform_runtime::RuntimeError::Interrupted);
                }
                step = command.project_step().running();
                self.progress.terraform_step(project, step);
                Ok(())
            },
        );
        self.report_terraform_output(&report);
        if !report.success {
            bail!("failed while {step}");
        }
        Ok(())
    }

    fn report_terraform_output(&self, report: &super::terraform_runtime::PhaseExecutionReport) {
        for project in &report.projects {
            for output in &project.commands {
                self.progress.log_block(&project.name, &output.stdout);
                self.progress.log_block(&project.name, &output.stderr);
            }
            if let Some(diagnostic) = &project.diagnostic {
                self.progress
                    .message(format!("Terraform {} · {diagnostic}", project.name));
            }
        }
    }

    fn build_host(&self) -> String {
        self.invocation
            .options
            .build_host
            .clone()
            .or_else(|| self.inventory.config.builders.first().cloned())
            .unwrap_or_else(|| "local".to_owned())
    }

    fn remote_build(
        &mut self,
        host: &str,
        build_host: &str,
        derivation: &NixStorePath,
        build_args: &BuildArgs,
    ) -> Result<NixStorePath> {
        let resolved = resolve_host(self.inventory, build_host, &self.invocation.options)?;
        let target = self.execution_target_for_resolved(&resolved)?;
        let lease_spec = builder_lease_process_spec(&target, &remote_build_tools()?)?;
        let store_uri = ssh_store_uri(&resolved)?;
        let (closure, protected_epoch) = self.realize_protected_on_builder(
            &target,
            &lease_spec,
            &store_uri,
            host,
            derivation,
            build_args,
        )?;
        self.builder_closures.insert(
            host.to_owned(),
            BuilderClosure {
                path: closure.clone(),
                protected_epoch,
            },
        );
        if matches!(self.invocation.action, Action::Build) {
            let nix_target = self.nix_copy_target(&target)?;
            let (pull, environment) = with_nix_sshopts(
                CommandSpec::new(
                    self.nix_program.to_string_lossy(),
                    [
                        "copy".to_owned(),
                        "--from".to_owned(),
                        store_uri,
                        closure.as_str().to_owned(),
                    ],
                ),
                &nix_target,
            )?;
            let scope: Arc<dyn TaskScope> = self.progress.host_scope(host);
            run_step(&scope, BuildStep::ClosureCopy, |task| {
                let output = self.host_runtime.execute_local_command_with_env(
                    &pull,
                    &environment,
                    EffectKind::Build,
                    task,
                )?;
                if !output.succeeded() {
                    bail!("copy remote build closure to local store failed for {host}");
                }
                Ok(())
            })?;
            let verification =
                closure_verification_command(&self.nix_program.to_string_lossy(), &closure);
            run_step(&scope, BuildStep::ClosureVerify, |task| {
                let verified = self.host_runtime.execute_local_command(
                    &verification,
                    EffectKind::ReadOnly,
                    task,
                )?;
                if !verified.succeeded() {
                    bail!("verify copied remote build closure failed for {host}");
                }
                Ok(())
            })?;
            self.builder_closures.remove(host);
        }
        Ok(closure)
    }

    fn realize_protected_on_builder(
        &mut self,
        target: &HostExecutionTarget,
        lease_spec: &super::build_lease::LeaseProcessSpec,
        store_uri: &str,
        subject: &str,
        derivation: &NixStorePath,
        build_args: &BuildArgs,
    ) -> Result<(NixStorePath, LeaseEpoch)> {
        struct NativeProtectedBuilder<'runtime, 'context> {
            runtime: &'runtime mut NativeFleetEffects<'context>,
            target: &'runtime HostExecutionTarget,
            lease_spec: &'runtime super::build_lease::LeaseProcessSpec,
            store_uri: &'runtime str,
            subject: &'runtime str,
            derivation: &'runtime NixStorePath,
            build_args: &'runtime BuildArgs,
        }
        impl ProtectedBuilder for NativeProtectedBuilder<'_, '_> {
            fn ensure_lease(&mut self) -> Result<super::build_lease::LeaseObservation> {
                self.runtime.builder_lease.ensure(self.lease_spec)
            }

            fn realize(&mut self) -> Result<NixStorePath> {
                self.runtime.realize_on_builder(
                    self.target,
                    self.store_uri,
                    self.subject,
                    self.derivation,
                    self.build_args,
                )
            }

            fn verify_closure(&mut self, closure: &NixStorePath) -> Result<bool> {
                self.runtime.verify_builder_closure(self.target, closure)
            }
        }
        let attempts = self.settings.transport_retry_attempts;
        realize_protected(
            &mut NativeProtectedBuilder {
                runtime: self,
                target,
                lease_spec,
                store_uri,
                subject,
                derivation,
                build_args,
            },
            attempts,
        )
    }

    fn realize_on_builder(
        &mut self,
        target: &HostExecutionTarget,
        store_uri: &str,
        subject: &str,
        derivation: &NixStorePath,
        build_args: &BuildArgs,
    ) -> Result<NixStorePath> {
        let commands = plan_remote_build(&remote_build_tools()?, derivation, build_args);
        let nix_target = self.nix_copy_target(target)?;
        let (copy_derivation, environment) = with_nix_sshopts(
            copy_derivation_command(&self.nix_program.to_string_lossy(), store_uri, derivation),
            &nix_target,
        )?;
        let scope: Arc<dyn TaskScope> = self.progress.host_scope(subject);
        let builder = target.route.endpoint.node.clone();
        run_step(&scope, BuildStep::Copy, |task| {
            let copied = self.host_runtime.execute_local_command_with_env(
                &copy_derivation,
                &environment,
                EffectKind::Build,
                task,
            )?;
            if !copied.succeeded() {
                bail!(
                    "remote build derivation copy failed: {}",
                    copied.combined_output()
                );
            }
            Ok(())
        })?;
        let output = run_step(&scope, BuildStep::Realize { builder }, |task| {
            self.host_runtime.run_remote_build(target, &commands, task)
        })?;
        Ok(output.path)
    }

    fn verify_builder_closure(
        &mut self,
        target: &HostExecutionTarget,
        closure: &NixStorePath,
    ) -> Result<bool> {
        let output = self.host_runtime.execute_remote_command(
            target,
            &closure_verification_command("/run/current-system/sw/bin/nix", closure),
            EffectKind::ReadOnly,
            InternalTask::new(format!(
                "remote-build-verify-builder-closure-{}",
                target.route.endpoint.node
            )),
        )?;
        Ok(output.succeeded())
    }

    fn route_failure_hint(&self, host: &str, evidence: &str) -> String {
        if !route_relevant_transport_failure(evidence) {
            return String::new();
        }
        let Some(route) = self
            .inventory
            .hosts
            .get(host)
            .and_then(|host| host.routing.as_ref())
        else {
            return String::new();
        };
        if route.active == super::inventory_routing::RouteName::Default {
            String::new()
        } else if route.effective {
            "; try --route=default".to_owned()
        } else {
            format!(
                "; route {} is unavailable on this host path",
                route.active.as_str()
            )
        }
    }

    fn execution_target(&mut self, resolved: &ResolvedHost) -> Result<HostExecutionTarget> {
        if let Some(target) = self.prepared_targets.get(&resolved.inventory_name) {
            return Ok(target.clone());
        }
        let mut primary = self.execution_target_for_resolved(resolved)?;
        if primary.local || self.invocation.options.dry_run {
            self.prepared_targets
                .insert(resolved.inventory_name.clone(), primary.clone());
            return Ok(primary);
        }

        if self.invocation.options.bootstrap {
            self.ensure_bootstrap_transport(resolved)?;
            let operator = self.operator_target(resolved)?;
            self.prepared_targets
                .insert(resolved.inventory_name.clone(), operator.clone());
            return Ok(operator);
        }

        let mut probe = self.probe_primary_target(&primary, &resolved.inventory_name)?;
        if probe.succeeded() {
            self.prepared_targets
                .insert(resolved.inventory_name.clone(), primary.clone());
            return Ok(primary);
        }
        if matches!(probe.status, ProcessStatus::Signal(signal) if signal > 0) {
            bail!(
                "primary connectivity probe for {} was interrupted: {:?}",
                resolved.inventory_name,
                probe.status
            );
        }
        if let Some(full_route) = self.full_proxy_fallback_target(resolved, &primary)? {
            self.progress.detail(format!(
                "Direct path to {} is unavailable; retrying through its configured proxy chain",
                resolved.inventory_name
            ));
            retire_control_master(&primary);
            let full_probe = self.probe_primary_target(&full_route, &resolved.inventory_name)?;
            if full_probe.succeeded() {
                self.prepared_targets
                    .insert(resolved.inventory_name.clone(), full_route.clone());
                return Ok(full_route);
            }
            if matches!(full_probe.status, ProcessStatus::Signal(signal) if signal > 0) {
                bail!(
                    "proxied connectivity probe for {} was interrupted: {:?}",
                    resolved.inventory_name,
                    full_probe.status
                );
            }
            primary = full_route;
            probe = full_probe;
        }
        let evidence = probe.combined_output();
        if temporary_transport_failure(&evidence) {
            bail!(
                "primary deploy target {} has a temporary transport failure; bootstrap fallback is delayed: {}{}",
                resolved.inventory_name,
                evidence.trim(),
                self.route_failure_hint(&resolved.inventory_name, &evidence)
            );
        }
        if resolved
            .operator_user
            .as_deref()
            .is_none_or(|user| user == resolved.user)
        {
            bail!(
                "primary deploy target {} is unavailable and no distinct operatorUser is configured: {}{}",
                resolved.inventory_name,
                evidence.trim(),
                self.route_failure_hint(&resolved.inventory_name, &evidence)
            );
        }

        let forced_ready = self.forced_command_bootstrap_ready(resolved, &primary)?;
        if !forced_ready && resolved.bootstrap_key.is_some() {
            self.ensure_bootstrap_transport(resolved)?;
            let retry = self.probe_primary_target(&primary, &resolved.inventory_name)?;
            if retry.succeeded() {
                self.prepared_targets
                    .insert(resolved.inventory_name.clone(), primary.clone());
                return Ok(primary);
            }
            if matches!(retry.status, ProcessStatus::Signal(signal) if signal > 0) {
                bail!(
                    "primary connectivity re-probe for {} was interrupted: {:?}",
                    resolved.inventory_name,
                    retry.status
                );
            }
        }
        let operator = self.operator_target(resolved)?;
        self.prepared_targets
            .insert(resolved.inventory_name.clone(), operator.clone());
        Ok(operator)
    }

    fn primary_execution_target(&mut self, resolved: &ResolvedHost) -> Result<HostExecutionTarget> {
        if let Some(target) = self.prepared_targets.get(&resolved.inventory_name)
            && (target.local
                || (target.route.endpoint.user == resolved.user
                    && target.route.endpoint.port == resolved.port))
        {
            return Ok(target.clone());
        }
        let mut target = self.execution_target_for_resolved(resolved)?;
        if target.local || self.invocation.options.dry_run {
            return Ok(target);
        }
        let mut probe = self.probe_primary_target(&target, &resolved.inventory_name)?;
        if matches!(probe.status, ProcessStatus::Signal(signal) if signal > 0) {
            bail!(
                "primary connectivity probe for {} was interrupted: {:?}",
                resolved.inventory_name,
                probe.status
            );
        }
        if !probe.succeeded()
            && let Some(full_route) = self.full_proxy_fallback_target(resolved, &target)?
        {
            retire_control_master(&target);
            target = full_route;
            probe = self.probe_primary_target(&target, &resolved.inventory_name)?;
        }
        if matches!(probe.status, ProcessStatus::Signal(signal) if signal > 0) {
            bail!(
                "primary connectivity probe for {} was interrupted: {:?}",
                resolved.inventory_name,
                probe.status
            );
        }
        if !probe.succeeded() {
            retire_control_master(&target);
            let evidence = probe.combined_output();
            bail!(
                "primary deploy target {} is unavailable: {}{}",
                resolved.inventory_name,
                evidence.trim(),
                self.route_failure_hint(&resolved.inventory_name, &evidence)
            );
        }
        self.prepared_targets
            .insert(resolved.inventory_name.clone(), target.clone());
        Ok(target)
    }

    fn probe_primary_target(
        &mut self,
        target: &HostExecutionTarget,
        host: &str,
    ) -> Result<super::host_runtime::ProcessOutput> {
        let parented = self
            .inventory
            .hosts
            .get(host)
            .and_then(|configured| configured.parent.as_ref())
            .is_some();
        let (attempts, interval_seconds) = if parented {
            (
                super::orchestration::readiness_attempts(
                    self.settings.parent_snapshot_ready_timeout_seconds,
                    self.settings.parent_snapshot_ready_interval_seconds,
                )?,
                self.settings.parent_snapshot_ready_interval_seconds,
            )
        } else {
            (
                self.settings.transport_retry_attempts.max(1),
                self.settings.transport_retry_delay_seconds,
            )
        };
        for attempt in 1..=attempts {
            let output = self.host_runtime.execute_remote_command(
                target,
                &CommandSpec::new(SYSTEM_TRUE, Vec::<String>::new()),
                EffectKind::ReadOnly,
                InternalTask::new(format!(
                    "primary-connectivity-probe-{}",
                    target.route.endpoint.node
                )),
            )?;
            if output.succeeded()
                || !matches!(output.status, ProcessStatus::Code(124 | 255))
                || attempt == attempts
            {
                return Ok(output);
            }
            let delay = if parented {
                interval_seconds
            } else {
                interval_seconds.saturating_mul(attempt as u64)
            };
            self.progress.detail(format!(
                "Primary connectivity probe for {host} unavailable{} · retry {}/{attempts} in {delay}s",
                if parented {
                    " after parent barrier"
                } else {
                    ""
                },
                attempt + 1
            ));
            retire_control_master(target);
            if delay > 0 {
                self.host_runtime.wait(Duration::from_secs(delay));
                super::signal::check_interrupted()?;
            }
        }
        unreachable!("positive attempt count returns from the loop")
    }

    fn operator_target(&mut self, resolved: &ResolvedHost) -> Result<HostExecutionTarget> {
        let mut operator = resolved.clone();
        operator.user = resolved
            .operator_user
            .clone()
            .with_context(|| format!("operatorUser is required for {}", resolved.inventory_name))?;
        operator.port = resolved.operator_port;
        operator.identity_key = resolved.operator_key.clone();
        self.execution_target_for_resolved(&operator)
    }

    fn forced_command_bootstrap_ready(
        &mut self,
        resolved: &ResolvedHost,
        primary: &HostExecutionTarget,
    ) -> Result<bool> {
        if resolved.bootstrap_key.is_none() {
            return Ok(false);
        }
        let override_identity = self
            .invocation
            .options
            .ci_check_ssh_key_path
            .as_deref()
            .map(|path| {
                self.materialize_declared_key(path, &resolved.inventory_name, "bootstrap-check")
            })
            .transpose()?;
        let plan = build_forced_command_check(&ForcedCommandInput {
            node: resolved.inventory_name.clone(),
            ssh_target: primary.route.endpoint.connect_target(),
            ssh_options: ssh_connection_args(primary)?,
            override_identity,
            sha: self.invocation.options.sha.clone(),
            config_path: self.invocation.options.config.clone(),
            repo_worktree: Some(self.repository.to_path_buf()),
            repo_root: Some(self.repository.to_path_buf()),
        })?;
        let output = self.host_runtime.check_bootstrap(&plan)?;
        if matches!(output.status, ProcessStatus::Signal(signal) if signal > 0) {
            bail!(
                "bootstrap forced-command check for {} was interrupted: {:?}",
                resolved.inventory_name,
                output.status
            );
        }
        let observation = if output.succeeded() {
            ForcedCommandObservation::Succeeded
        } else {
            ForcedCommandObservation::Failed {
                output: output.combined_output(),
            }
        };
        Ok(matches!(
            classify_forced_command_readiness(&observation),
            ForcedCommandReadiness::Ready | ForcedCommandReadiness::LegacyAuthenticated
        ))
    }

    fn execution_target_for_resolved(
        &mut self,
        resolved: &ResolvedHost,
    ) -> Result<HostExecutionTarget> {
        self.execution_target_for_resolved_route(resolved, true)
    }

    fn full_proxy_fallback_target(
        &mut self,
        resolved: &ResolvedHost,
        effective: &HostExecutionTarget,
    ) -> Result<Option<HostExecutionTarget>> {
        let full = self.execution_target_for_resolved_route(resolved, false)?;
        Ok((full.route != effective.route).then_some(full))
    }

    fn execution_target_for_resolved_route(
        &mut self,
        resolved: &ResolvedHost,
        trim_leading_local_hops: bool,
    ) -> Result<HostExecutionTarget> {
        let mut resolved = resolved.clone();
        resolved.identity_key = resolved
            .identity_key
            .as_deref()
            .map(|path| self.materialize_declared_key(path, &resolved.inventory_name, "primary"))
            .transpose()?;
        let transports = self.resolved_transports()?;
        let route =
            super::system_route::primary_route(&resolved, &transports, trim_leading_local_hops)?;
        let local = self.local_target(&resolved)?;
        // Local (self) targets still connect over SSH for `nix copy --to
        // ssh-ng://…`, so they get the same isolated known-hosts file as remote
        // targets; otherwise `accept-new` could append to the operator's
        // ambient trust store.
        let known_hosts_file = Some(self.prepare_known_hosts(&resolved)?);
        let control_socket = if local {
            None
        } else {
            Some(control_socket_path(self.transport_store.path(), &route)?)
        };
        HostExecutionTarget::from_resolved(
            &resolved,
            route,
            self.repository,
            known_hosts_file,
            local,
        )
        .and_then(|target| {
            target.with_ssh_liveness(
                self.settings.ssh_connect_timeout_seconds,
                self.settings.ssh_server_alive_interval_seconds,
                self.settings.ssh_server_alive_count_max,
            )
        })
        .and_then(|target| {
            target.with_remote_read_timeout(self.settings.remote_read_timeout_seconds)
        })
        .and_then(|target| {
            if let Some(control_socket) = control_socket {
                target
                    .with_control_master(control_socket, self.settings.ssh_control_persist_seconds)
            } else {
                Ok(target)
            }
        })
    }

    fn nix_copy_target(&self, target: &HostExecutionTarget) -> Result<HostExecutionTarget> {
        prepare_nix_copy_target(self.transport_store.path(), target)
    }

    fn ensure_bootstrap_transport(&mut self, resolved: &ResolvedHost) -> Result<()> {
        let bootstrap = resolved
            .bootstrap_key
            .as_deref()
            .context("--bootstrap requires a bootstrap key")?;
        let bootstrap =
            self.materialize_declared_key(bootstrap, &resolved.inventory_name, "bootstrap")?;
        if self.bootstrap_prepared.contains(&resolved.inventory_name) {
            return Ok(());
        }
        let operator_user = resolved.operator_user.clone().with_context(|| {
            format!(
                "--bootstrap requires operatorUser for {}",
                resolved.inventory_name
            )
        })?;
        let mut operator = resolved.clone();
        operator.user = operator_user;
        operator.port = resolved.operator_port;
        operator.identity_key = resolved.operator_key.clone();
        let operator_target = self.execution_target_for_resolved(&operator)?;
        if operator_target.local {
            bail!("--bootstrap cannot use a local operator target");
        }

        let public = self.transport_store.path().join(format!(
            "bootstrap-public-{}",
            safe_component(&resolved.inventory_name)
        ));
        if !public.is_file() {
            let line = bootstrap_public_key_line(&bootstrap).with_context(|| {
                format!(
                    "derive bootstrap public key for {}",
                    resolved.inventory_name
                )
            })?;
            std::fs::write(&public, line)?;
            std::fs::set_permissions(&public, std::fs::Permissions::from_mode(0o600))?;
        }
        let component = format!(
            "{}.{}",
            safe_component(&resolved.inventory_name),
            self.invocation_id
        );
        let remote_key = PathBuf::from(format!("/tmp/nixbot-bootstrap-key.{component}"));
        let remote_public = PathBuf::from(format!("/tmp/nixbot-bootstrap-public.{component}"));
        let bootstrap_scope: Arc<dyn TaskScope> =
            self.progress.host_scope(&resolved.inventory_name);
        for (source, destination, step) in [
            (&bootstrap, &remote_key, BootstrapStep::PrivateKeyUpload),
            (&public, &remote_public, BootstrapStep::PublicKeyUpload),
        ] {
            let label = step.spec(&resolved.inventory_name).running;
            run_step(&bootstrap_scope, step, |task| {
                let uploaded = self.host_runtime.upload_file_to_remote(
                    &operator_target,
                    source,
                    destination,
                    task,
                )?;
                if !uploaded.succeeded() {
                    bail!(
                        "{label} failed for {}: {}",
                        resolved.inventory_name,
                        uploaded.stderr.trim()
                    );
                }
                Ok(())
            })?;
        }
        let install = bootstrap_install_command(&remote_key, &remote_public)?;
        run_step(&bootstrap_scope, BootstrapStep::Install, |task| {
            let installed = self.host_runtime.execute_remote_command(
                &operator_target,
                &install,
                EffectKind::Mutation,
                task,
            )?;
            if !installed.succeeded() {
                bail!(
                    "bootstrap key installation failed for {}: {}",
                    resolved.inventory_name,
                    installed.stderr.trim()
                );
            }
            Ok(())
        })?;
        self.bootstrap_prepared
            .insert(resolved.inventory_name.clone());
        Ok(())
    }

    fn ensure_host_age_identity(
        &mut self,
        resolved: &ResolvedHost,
        target: &HostExecutionTarget,
    ) -> Result<()> {
        let Some(declaration) = resolved.age_identity_key.as_deref() else {
            return Ok(());
        };
        if self
            .age_identity_prepared
            .contains(&resolved.inventory_name)
        {
            return Ok(());
        }
        let source = if declaration.is_absolute() {
            declaration.to_path_buf()
        } else {
            self.repository.join(declaration)
        };
        if source.extension().and_then(|value| value.to_str()) != Some("age") {
            bail!(
                "host age identity for {} must be stored as an encrypted .age file",
                resolved.inventory_name
            );
        }
        let materialized = self.materialize_declared_key(
            declaration,
            &resolved.inventory_name,
            "host-age-identity",
        )?;
        let contents = std::fs::read(&materialized).with_context(|| {
            format!(
                "read materialized host age identity for {}",
                resolved.inventory_name
            )
        })?;
        if contents.is_empty() {
            bail!(
                "materialized host age identity for {} is empty",
                resolved.inventory_name
            );
        }
        let expected_hash = format!("{:x}", Sha256::digest(&contents));
        let remote = PathBuf::from(format!(
            "/tmp/nixbot-age-identity.{}.{}",
            safe_component(&resolved.inventory_name),
            self.invocation_id
        ));
        let age_scope: Arc<dyn TaskScope> = self.progress.host_scope(&resolved.inventory_name);
        run_step(&age_scope, AcquireStep::AgeIdentityUpload, |task| {
            let uploaded =
                self.host_runtime
                    .upload_file_to_remote(target, &materialized, &remote, task)?;
            if !uploaded.succeeded() {
                bail!(
                    "host age identity upload failed for {}: {}",
                    resolved.inventory_name,
                    uploaded.stderr.trim()
                );
            }
            Ok(())
        })?;
        let install = host_age_identity_install_command(&remote, &expected_hash)?;
        run_step(&age_scope, AcquireStep::AgeIdentityInstall, |task| {
            let installed = self.host_runtime.execute_remote_command(
                target,
                &install,
                EffectKind::Mutation,
                task,
            )?;
            if !installed.succeeded()
                || installed
                    .stdout
                    .split_whitespace()
                    .next()
                    .is_none_or(|actual| actual != expected_hash)
            {
                bail!(
                    "host age identity verification failed for {}: {}",
                    resolved.inventory_name,
                    installed.combined_output().trim()
                );
            }
            Ok(())
        })?;
        self.age_identity_prepared
            .insert(resolved.inventory_name.clone());
        Ok(())
    }

    fn resolved_transports(&self) -> Result<BTreeMap<String, HostTransport>> {
        self.inventory
            .hosts
            .keys()
            .map(|name| {
                let mut host = resolve_host(self.inventory, name, &self.invocation.options)?;
                host.identity_key = host
                    .identity_key
                    .as_deref()
                    .map(|path| self.materialize_declared_key(path, name, "proxy-primary"))
                    .transpose()?;
                host.operator_key = host
                    .operator_key
                    .as_deref()
                    .map(|path| self.materialize_declared_key(path, name, "proxy-operator"))
                    .transpose()?;
                let mut transport = super::system_route::host_transport(&host, false)?;
                transport.local = self.local_target(&host)?;
                Ok((name.clone(), transport))
            })
            .collect()
    }

    fn local_target(&self, host: &ResolvedHost) -> Result<bool> {
        let mode = match self.settings.local_self_target {
            LocalSelfTarget::Auto => SelfTargetMode::Auto,
            LocalSelfTarget::On => SelfTargetMode::On,
            LocalSelfTarget::Off => SelfTargetMode::Off,
        };
        let evidence = self.self_target_evidence(host)?;
        Ok(plan_self_target(mode, &evidence) == SelfTargetDecision::Local)
    }

    fn physical_self_target(&self, host: &ResolvedHost) -> Result<bool> {
        let mode = match self.settings.local_self_target {
            LocalSelfTarget::Auto => SelfTargetMode::Auto,
            LocalSelfTarget::On => SelfTargetMode::On,
            LocalSelfTarget::Off => SelfTargetMode::Off,
        };
        let evidence = self.self_target_evidence(host)?;
        Ok(mode != SelfTargetMode::Off && (evidence.alias_matches || evidence.address_matches))
    }

    fn controller_mutex_covers_target(&self, host: &ResolvedHost) -> Result<bool> {
        Ok(!self.invocation.options.skip_global_lock
            && self.physical_self_target(host)?
            && super::runtime::action_mutex_covers_target_lock())
    }

    fn self_target_evidence(&self, host: &ResolvedHost) -> Result<SelfTargetEvidence> {
        let mut aliases = BTreeSet::from([
            "localhost".to_owned(),
            "127.0.0.1".to_owned(),
            "::1".to_owned(),
        ]);
        aliases.extend(system_identity::local_host_aliases());
        let target = host.target.trim_start_matches('[').trim_end_matches(']');
        let target_short = target.split('.').next().unwrap_or(target);
        let alias_matches = aliases.contains(target) || aliases.contains(target_short);
        let mut local_addresses = BTreeSet::from(["127.0.0.1".to_owned(), "::1".to_owned()]);
        local_addresses.extend(system_identity::local_ip_addresses().unwrap_or_default());
        let address_matches = is_ip_address(target) && local_addresses.contains(target)
            || system_identity::resolve_peer_addresses(target).is_ok_and(|addresses| {
                addresses
                    .iter()
                    .any(|address| local_addresses.contains(address))
            });
        Ok(SelfTargetEvidence {
            alias_matches,
            address_matches,
            effective_uid: system_identity::effective_uid(),
            current_user: system_identity::current_user()?,
            deploy_user: host.user.clone(),
        })
    }

    fn materialize_declared_key(
        &self,
        declaration: &Path,
        host: &str,
        role: &str,
    ) -> Result<PathBuf> {
        let source = if declaration.is_absolute() {
            declaration.to_path_buf()
        } else {
            self.repository.join(declaration)
        };
        if source.extension().and_then(|value| value.to_str()) != Some("age") {
            if !source.is_file() {
                bail!(
                    "{role} SSH key for {host} is not a file: {}",
                    source.display()
                );
            }
            return Ok(source);
        }
        let destination = self.transport_store.path().join(format!(
            "key-{}-{}",
            safe_component(host),
            safe_component(role)
        ));
        if destination.is_file() {
            // `Age::decrypt` writes to a sibling temporary file and renames it
            // into place only on success, so a failed attempt never leaves a
            // partial `destination` behind. This cache check therefore only
            // ever observes complete plaintext, and no explicit `remove_file`
            // cleanup is needed on failure.
            return Ok(destination);
        }
        let identities = age_identities(&self.invocation.options);
        if identities.is_empty() {
            bail!("no age identity is configured to decrypt the {role} SSH key for {host}");
        }
        Age::new()
            .decrypt(&source, &identities, &destination)
            .map_err(|error| {
                anyhow!("unable to decrypt the {role} SSH key for {host}: {error:#}")
            })?;
        std::fs::set_permissions(&destination, std::fs::Permissions::from_mode(0o600))?;
        Ok(destination)
    }

    fn write_known_hosts(&self, host: &str, contents: &str) -> Result<PathBuf> {
        if contents
            .lines()
            .all(|line| line.trim().is_empty() || line.trim_start().starts_with('#'))
        {
            bail!("known-hosts material for {host} contains no host key");
        }
        let path = self
            .transport_store
            .path()
            .join(format!("known-hosts-{}", safe_component(host)));
        if path.exists() {
            return Ok(path);
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .with_context(|| format!("create known-hosts material for {host}"))?;
        file.write_all(contents.as_bytes())?;
        if !contents.ends_with('\n') {
            file.write_all(b"\n")?;
        }
        Ok(path)
    }

    /// Isolated `0600` known-hosts file for one host. Configured inventory
    /// material is an authenticated pin; otherwise the file starts empty and
    /// the route trusts on first use through `StrictHostKeyChecking=accept-new`.
    fn prepare_known_hosts(&self, host: &ResolvedHost) -> Result<PathBuf> {
        if let Some(contents) = host.known_hosts.as_deref() {
            return self.write_known_hosts(&host.inventory_name, contents);
        }
        let path = self.transport_store.path().join(format!(
            "known-hosts-{}",
            safe_component(&host.inventory_name)
        ));
        if path.exists() {
            return Ok(path);
        }
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .with_context(|| {
                format!(
                    "create isolated known-hosts material for {}",
                    host.inventory_name
                )
            })?;
        Ok(path)
    }

    fn run_snapshot_phase(&mut self) -> Result<()> {
        self.check_forward_work()?;
        if self.invocation.options.dry_run || self.invocation.options.no_rollback {
            for host in &self.selection.ordered {
                self.snapshots.insert(
                    host.clone(),
                    super::deploy::GenerationSnapshot::not_requested(),
                );
                if self.invocation.options.dry_run {
                    self.progress.host_skipped(host, "dry run");
                } else {
                    self.progress.host_status(host, HostStatus::SnapshotSkip);
                }
            }
            return Ok(());
        }

        let mut failures = Vec::new();
        let control = self.admission_control(self.invocation.options.deploy_jobs, true)?;
        let wave_count = self.selection.levels.len();
        for (wave_index, wave) in self.selection.levels.clone().into_iter().enumerate() {
            self.check_forward_work()?;
            self.progress.phase_schedule(
                "snapshot",
                Some((wave_index + 1, wave_count)),
                control.snapshot().target,
            );
            let mut runnable = Vec::new();
            for host in wave {
                if self.inventory.hosts[&host].deploy == DeployMode::Skip {
                    self.snapshots.insert(
                        host.clone(),
                        super::deploy::GenerationSnapshot::not_requested(),
                    );
                    self.progress.host_status(&host, HostStatus::SnapshotSkip);
                } else {
                    runnable.push(host);
                }
            }
            if !runnable.is_empty() {
                self.ensure_parent_readiness(&runnable)
                    .context("snapshot parent readiness failed")?;
            }
            let context = self.worker_context();
            let inventory = self.inventory;
            let progress = self.progress.clone();
            let snapshots = scheduling::dispatch(
                self.domain_tasks(runnable, String::as_str)?,
                &control,
                &progress,
                |host| {
                    let _operation = progress.host_operation(&host);
                    let policy = inventory.hosts[&host].deploy;
                    let snapshot = (|| {
                        let mut worker = context.create()?;
                        let resolved =
                            resolve_host(worker.inventory, &host, &worker.invocation.options)?;
                        let target = worker.execution_target(&resolved)?;
                        let scope: Arc<dyn TaskScope> = progress.host_scope(&host);
                        run_step(&scope, SnapshotStep::Capture, |task| {
                            worker.host_runtime.snapshot(&target, task)
                        })
                    })();
                    (host, policy, snapshot)
                },
                // One snapshot error does not prevent independent hosts in this
                // dependency level from being observed. Withdrawal/cancellation
                // still closes further admission.
                |_| context.stopped(),
                |_, (host, policy, result)| match result {
                    Ok(snapshot) if snapshot.generation().is_some() => {
                        progress.host_status(host, HostStatus::SnapshotDone)
                    }
                    Ok(_) if *policy == DeployMode::Optional => {
                        progress.host_status(host, HostStatus::SnapshotUnavailable)
                    }
                    Ok(_) => progress.host_failed(host, "generation snapshot unavailable"),
                    Err(error) => progress.host_failed(host, format!("snapshot failed: {error:#}")),
                },
            )?;
            let mut first_error = None;
            for (host, policy, result) in snapshots.into_iter().flatten() {
                match result {
                    Ok(snapshot) => {
                        if snapshot.generation().is_none() && policy == DeployMode::Strict {
                            failures.push(host.clone());
                            self.snapshot_failed.insert(host.clone());
                        } else if snapshot.generation().is_none() && policy == DeployMode::Optional
                        {
                            self.optional_snapshot_skipped.insert(host.clone());
                            self.workflow_warnings.push(WorkflowWarning {
                                host: host.clone(),
                                detail: "snapshot unavailable".to_owned(),
                            });
                        }
                        self.snapshots.insert(host, snapshot);
                    }
                    Err(error) => {
                        self.snapshot_failed.insert(host);
                        first_error.get_or_insert(error);
                    }
                }
            }
            self.check_forward_work()?;
            if let Some(error) = first_error {
                return Err(error);
            }
        }
        if !failures.is_empty() {
            bail!(
                "required generation snapshot is unavailable for {}",
                failures.join(", ")
            );
        }
        Ok(())
    }

    fn distribute_for_deploy(&mut self, host: &str, closure: &NixStorePath) -> Result<()> {
        self.check_forward_work()?;
        let resolved = resolve_host(self.inventory, host, &self.invocation.options)?;
        if let Some(owned) = self.owned.clone() {
            // Consumer-rooted in the builder's shared store and served by its
            // signed cache: no local daemon, builder lease or local push.
            let builder = resolve_host(self.inventory, &owned.builder, &self.invocation.options)?;
            let plan = DistributionInputs {
                build_resource: builder.resource.clone(),
                target_resource: resolved.resource.clone(),
                configured_mode: match self.invocation.options.build_host_deploy_mode {
                    super::cli::BuildHostDeployMode::Auto => BuildHostDeployMode::Auto,
                    super::cli::BuildHostDeployMode::Cache => BuildHostDeployMode::Cache,
                    super::cli::BuildHostDeployMode::LocalCopy => BuildHostDeployMode::LocalCopy,
                },
                build_host_is_cache_host: true,
                target_is_local: self.local_target(&resolved)?,
                cache: Some(owned.cache.clone()),
            }
            .plan(closure)?;
            let retry = RetryPolicy::new(
                self.settings.transport_retry_attempts,
                Duration::from_secs(self.settings.transport_retry_delay_seconds),
            )?;
            return match self.execute_distribution_plan(&resolved, &plan, retry)? {
                DistributionExecution::Complete | DistributionExecution::DryRun => Ok(()),
                DistributionExecution::Failed(status) => {
                    bail!("closure distribution to {host} failed: {status:?}")
                }
            };
        }
        let build_host = self.build_host();
        if build_host == "local" {
            let target = self.execution_target(&resolved)?;
            let nix_target = self.nix_copy_target(&target)?;
            let (command, environment) = with_nix_sshopts(
                CommandSpec::new(
                    self.nix_program.to_string_lossy(),
                    [
                        "copy".to_owned(),
                        "--no-check-sigs".to_owned(),
                        "--to".to_owned(),
                        ssh_store_uri(&resolved)?,
                        closure.as_str().to_owned(),
                    ],
                ),
                &nix_target,
            )?;
            let scope: Arc<dyn TaskScope> = self.progress.host_scope(host);
            let route_hint = self.route_failure_hint(host, "connection timed out");
            run_step(&scope, TransferStep::DirectPush, |task| {
                let output = self.host_runtime.execute_local_command_with_env(
                    &command,
                    &environment,
                    EffectKind::Mutation,
                    task,
                )?;
                if !output.succeeded() {
                    let hint = if route_relevant_transport_failure(&output.stderr) {
                        route_hint.as_str()
                    } else {
                        ""
                    };
                    bail!(
                        "copy closure to {host} failed: {}{hint}",
                        output.stderr.trim()
                    );
                }
                Ok(())
            })?;
            return Ok(());
        }

        let builder = resolve_host(self.inventory, &build_host, &self.invocation.options)?;
        let lease_epoch = self.ensure_builder_closure_for_use(host, &builder)?;
        let cache_url = self
            .invocation
            .options
            .build_cache_url
            .clone()
            .or_else(|| {
                self.inventory
                    .config
                    .registries
                    .get("nix")
                    .map(|registry| registry.url.clone())
            })
            .or_else(|| {
                self.inventory
                    .config
                    .build_cache
                    .as_ref()
                    .map(|cache| cache.url.clone())
            });
        let cache = cache_url
            .map(|url| CacheSource::new(url, Vec::<String>::new()))
            .transpose()?;
        let cache_host = self
            .invocation
            .options
            .build_cache_host
            .clone()
            .or_else(|| {
                self.inventory
                    .config
                    .registries
                    .get("nix")
                    .map(|registry| registry.host.clone())
            })
            .or_else(|| {
                self.inventory
                    .config
                    .build_cache
                    .as_ref()
                    .map(|cache| cache.host.clone())
            });
        let configured_mode = match self.invocation.options.build_host_deploy_mode {
            super::cli::BuildHostDeployMode::Auto => BuildHostDeployMode::Auto,
            super::cli::BuildHostDeployMode::Cache => BuildHostDeployMode::Cache,
            super::cli::BuildHostDeployMode::LocalCopy => BuildHostDeployMode::LocalCopy,
        };
        let target_is_local = self.local_target(&resolved)?;
        let plan = DistributionInputs {
            build_resource: builder.resource.clone(),
            target_resource: resolved.resource.clone(),
            configured_mode,
            build_host_is_cache_host: cache_host
                .as_deref()
                .is_some_and(|owner| owner == build_host),
            target_is_local,
            cache,
        }
        .plan(closure)?;
        let retry = RetryPolicy::new(
            self.settings.transport_retry_attempts,
            Duration::from_secs(self.settings.transport_retry_delay_seconds),
        )?;
        let mut result = self.execute_distribution_plan(&resolved, &plan, retry)?;
        if matches!(result, DistributionExecution::Failed(_)) {
            let recovered_epoch = self.ensure_builder_closure_for_use(host, &builder)?;
            if recovered_epoch != lease_epoch {
                result = self.execute_distribution_plan(&resolved, &plan, retry)?;
            }
        }
        match result {
            DistributionExecution::Complete | DistributionExecution::DryRun => Ok(()),
            DistributionExecution::Failed(status) => {
                bail!("closure distribution to {host} failed: {status:?}")
            }
        }
    }

    fn execute_distribution_plan(
        &mut self,
        resolved: &ResolvedHost,
        plan: &DistributionPlan,
        retry: RetryPolicy,
    ) -> Result<DistributionExecution> {
        self.check_forward_work()?;
        let host = resolved.inventory_name.clone();
        let scope: Arc<dyn TaskScope> = self.progress.host_scope(&host);
        let result = match plan {
            DistributionPlan::VerifyExisting { closure } => {
                let target = self.execution_target(resolved)?;
                self.distribute_verify(&scope, &target, closure)?
            }
            DistributionPlan::TargetCachePull {
                closure,
                cache,
                retry: retry_transport,
            } => {
                let attempts = if *retry_transport {
                    retry
                } else {
                    RetryPolicy::new(1, Duration::ZERO)?
                };
                let target = self.execution_target(resolved)?;
                let status = run_step_with(
                    &scope,
                    TransferStep::CachePull,
                    |task| {
                        self.host_runtime
                            .cache_pull(&target, cache, closure, attempts, task)
                    },
                    command_outcome,
                )?;
                if status != CommandStatus::Success {
                    status
                } else {
                    self.distribute_verify(&scope, &target, closure)?
                }
            }
            DistributionPlan::RelayThroughLocal { closure, cache } => {
                let target = self.primary_execution_target(resolved)?;
                let nix_target = self.nix_copy_target(&target)?;
                let step = relay_step(&target);
                let status = run_step_with(
                    &scope,
                    step,
                    |task| {
                        self.host_runtime
                            .relay_transfer(&nix_target, closure, cache, retry, task)
                    },
                    command_outcome,
                )?;
                if status != CommandStatus::Success {
                    status
                } else {
                    self.distribute_verify(&scope, &target, closure)?
                }
            }
            DistributionPlan::TryTargetCacheThenRelay { closure, cache } => {
                let target = self.execution_target(resolved)?;
                let status = run_step_with(
                    &scope,
                    TransferStep::CachePull,
                    |task| {
                        self.host_runtime.cache_pull(
                            &target,
                            cache,
                            closure,
                            RetryPolicy::new(1, Duration::ZERO)?,
                            task,
                        )
                    },
                    command_outcome,
                )?;
                match status {
                    CommandStatus::Success => self.distribute_verify(&scope, &target, closure)?,
                    CommandStatus::Signal(signal) => CommandStatus::Signal(signal),
                    CommandStatus::Exit(_) => {
                        self.check_forward_work()?;
                        let primary = self.primary_execution_target(resolved)?;
                        let nix_primary = self.nix_copy_target(&primary)?;
                        let step = relay_step(&primary);
                        let status = run_step_with(
                            &scope,
                            step,
                            |task| {
                                self.host_runtime.relay_transfer(
                                    &nix_primary,
                                    closure,
                                    cache,
                                    retry,
                                    task,
                                )
                            },
                            command_outcome,
                        )?;
                        if status != CommandStatus::Success {
                            status
                        } else {
                            self.distribute_verify(&scope, &primary, closure)?
                        }
                    }
                }
            }
        };
        Ok(if result == CommandStatus::Success {
            DistributionExecution::Complete
        } else {
            DistributionExecution::Failed(result)
        })
    }

    fn distribute_verify(
        &mut self,
        scope: &Arc<dyn TaskScope>,
        target: &HostExecutionTarget,
        closure: &NixStorePath,
    ) -> Result<CommandStatus> {
        self.check_forward_work()?;
        run_step_with(
            scope,
            VerifyStep::Closure,
            |task| {
                self.host_runtime
                    .verify_target_closure(target, closure, task)
            },
            command_outcome,
        )
    }

    fn ensure_builder_closure_for_use(
        &mut self,
        host: &str,
        builder: &ResolvedHost,
    ) -> Result<LeaseEpoch> {
        let target = self.execution_target_for_resolved(builder)?;
        let lease_spec = builder_lease_process_spec(&target, &remote_build_tools()?)?;
        let observation = self.builder_lease.ensure(&lease_spec)?;
        let Some(mut closure) = self.builder_closures.get(host).cloned() else {
            bail!("missing builder-protected closure for {host}");
        };
        if closure.protected_epoch != observation.epoch {
            if !self.verify_builder_closure(&target, &closure.path)? {
                bail!("builder protection lost for {host}; refusing to repeat realization");
            }
            let confirmed = self.builder_lease.ensure(&lease_spec)?;
            if confirmed.epoch != observation.epoch {
                bail!("builder lease changed repeatedly while recovering {host}");
            }
            closure.protected_epoch = confirmed.epoch;
            self.builder_closures.insert(host.to_owned(), closure);
            return Ok(confirmed.epoch);
        }
        Ok(observation.epoch)
    }

    fn ensure_parent_readiness<'h>(
        &mut self,
        hosts: impl IntoIterator<Item = &'h String>,
    ) -> Result<()> {
        for host in hosts {
            self.check_forward_work()?;
            let configured = &self.inventory.hosts[host];
            let Some(parent) = configured.parent.as_deref() else {
                continue;
            };
            let commands = super::deploy::parent_readiness_commands(
                configured.resource(host),
                configured.parent_reconcile_command.as_deref(),
                configured.parent_settle_command.as_deref(),
                Duration::from_secs(self.settings.parent_settle_timeout_seconds),
            )?;
            let resolved = resolve_host(self.inventory, parent, &self.invocation.options)?;
            let target = self.execution_target(&resolved)?;
            let scope: Arc<dyn TaskScope> = self.progress.host_scope(host);
            for (step, command, effect) in [
                (
                    ReadinessStep::Reconcile {
                        parent: parent.to_owned(),
                    },
                    &commands.reconcile,
                    EffectKind::Mutation,
                ),
                (
                    ReadinessStep::Settle {
                        parent: parent.to_owned(),
                    },
                    &commands.settle,
                    EffectKind::ReadOnly,
                ),
            ] {
                self.check_forward_work()?;
                let command = CommandSpec::new(command.program.clone(), command.args.clone());
                let label = step.spec(host).running;
                run_step(&scope, step, |task| {
                    let output = self
                        .host_runtime
                        .execute_remote_root_command(&target, &command, effect, task)?;
                    if !output.succeeded() {
                        bail!(
                            "{label} failed for {host} through {parent}: {}",
                            output.stderr.trim()
                        );
                    }
                    Ok(())
                })?;
            }
        }
        Ok(())
    }

    fn set_candidate_lease(
        &mut self,
        host: &str,
        target: &HostExecutionTarget,
        generation: &super::deploy::SystemGeneration,
        acquire: bool,
    ) -> Result<()> {
        let command = if acquire {
            super::deploy::acquire_candidate_lease_command(
                &self.invocation_id.to_string(),
                host,
                generation,
            )
        } else {
            super::deploy::release_candidate_lease_command(
                &self.invocation_id.to_string(),
                host,
                generation,
            )
        };
        let operation = if acquire {
            "acquire-candidate-lease"
        } else {
            "release-candidate-lease"
        };
        let step = if acquire {
            AcquireStep::CandidateLeaseAcquire
        } else {
            AcquireStep::CandidateLeaseRelease
        };
        let scope: Arc<dyn TaskScope> = self.progress.host_scope(host);
        run_step(&scope, step, |task| {
            let output = self.host_runtime.execute_remote_root_command(
                target,
                &CommandSpec::new(command.program, command.args),
                EffectKind::Mutation,
                task,
            )?;
            if !output.succeeded() {
                let detail = output.combined_output();
                let detail = detail.trim();
                if detail.is_empty() {
                    bail!(
                        "{operation} failed for {host}: remote command exited {:?}",
                        output.status
                    );
                }
                bail!("{operation} failed for {host}: {detail}");
            }
            Ok(())
        })
    }

    fn release_candidate_lease(&mut self, host: &str, generation: &NixStorePath) -> Result<()> {
        let desired = super::deploy::SystemGeneration::parse(generation.as_str())?;
        let resolved = resolve_host(self.inventory, host, &self.invocation.options)?;
        let target = self.execution_target(&resolved)?;
        self.set_candidate_lease(host, &target, &desired, false)
    }

    fn release_all_candidate_leases(&mut self) {
        let leases = std::mem::take(&mut self.candidate_leases);
        for (host, generation) in leases {
            if let Err(error) = self.release_candidate_lease(&host, &generation) {
                self.progress.message(format!(
                    "Candidate lease cleanup deferred · {host} · {error:#}"
                ));
                self.candidate_leases.insert(host, generation);
            }
        }
    }

    fn release_tracked_candidate_lease(&mut self, host: &str) -> Result<()> {
        let Some(generation) = self.candidate_leases.get(host).cloned() else {
            return Ok(());
        };
        self.release_candidate_lease(host, &generation)?;
        self.candidate_leases.remove(host);
        Ok(())
    }

    fn candidate_for_acquisition(&mut self, host: &str) -> Result<Option<AcquisitionTarget>> {
        let policy = self.inventory.hosts[host].deploy;
        let closure = self
            .closures
            .get(host)
            .cloned()
            .with_context(|| format!("missing built closure for {host}"))?;
        let desired = super::deploy::SystemGeneration::parse(closure.as_str())?;
        // Preparation warms exact candidates; rollback eligibility belongs to a
        // later deployment and must never reuse a preparation-time snapshot.
        if self.invocation.action == Action::Prepare {
            return Ok(Some(AcquisitionTarget {
                closure,
                generation: desired,
            }));
        }
        let snapshot = self
            .snapshots
            .get(host)
            .cloned()
            .context("snapshot phase did not record every deployment host")?;
        let requirement = if policy == DeployMode::Optional {
            super::deploy::SnapshotRequirement::Optional
        } else {
            super::deploy::SnapshotRequirement::Required
        };
        match snapshot.deploy_decision(
            requirement,
            &desired,
            !self.invocation.options.force
                && !self.invocation.options.restart_managed
                && !self.invocation.options.dry_run,
        ) {
            super::deploy::DeployDecision::SkipUnchanged => {
                self.deploy_skipped.insert(host.to_owned());
                Ok(None)
            }
            super::deploy::DeployDecision::SkipOptionalMissing => {
                self.optional_snapshot_skipped.insert(host.to_owned());
                Ok(None)
            }
            super::deploy::DeployDecision::RefuseRequiredMissing => {
                bail!("required generation snapshot is unavailable for {host}")
            }
            super::deploy::DeployDecision::Deploy { .. } => Ok(Some(AcquisitionTarget {
                closure,
                generation: desired,
            })),
        }
    }

    fn acquire_one(&mut self, host: &str, candidate: &AcquisitionTarget) -> Result<()> {
        self.check_forward_work()?;
        let resolved = resolve_host(self.inventory, host, &self.invocation.options)?;
        let target = self.execution_target(&resolved)?;
        let acquisition = execute_candidate_acquisition_pipeline(
            self,
            |effects| effects.distribute_for_deploy(host, &candidate.closure),
            |effects| {
                effects.check_forward_work()?;
                effects.ensure_host_age_identity(&resolved, &target)?;
                effects.check_forward_work()?;
                effects
                    .candidate_leases
                    .insert(host.to_owned(), candidate.closure.clone());
                effects.set_candidate_lease(host, &target, &candidate.generation, true)?;
                Ok(())
            },
            |effects| {
                effects.check_forward_work()?;
                let goal = deploy_goal(effects.invocation.options.goal);
                let admission =
                    super::deploy::generation_admission_command(&candidate.generation, goal);
                let scope: Arc<dyn TaskScope> = effects.progress.host_scope(host);
                let admitted = run_step_with(
                    &scope,
                    AcquireStep::GenerationAdmission,
                    |task| {
                        effects
                            .host_runtime
                            .admit_generation(&target, &admission, task)
                    },
                    process_outcome,
                )?;
                if admitted.succeeded()
                    && admitted.stdout.lines().any(|line| {
                        line == super::deploy::GENERATION_ADMISSION_ACQUISITION_DEFERRED_MARKER
                    })
                {
                    effects.acquisition_deferred.insert(host.to_owned());
                    Ok(CandidateAcquisition::Deferred)
                } else if admitted.succeeded() {
                    Ok(CandidateAcquisition::Approved)
                } else {
                    bail!(
                        "generation admission failed for {host}: {}",
                        admitted.stderr.trim()
                    );
                }
            },
            |effects| {
                effects.check_forward_work()?;
                let command =
                    super::deploy::pre_activation_image_pull_command(&candidate.generation);
                let scope: Arc<dyn TaskScope> = effects.progress.host_scope(host);
                run_step(&scope, AcquireStep::PrefetchPodman, |task| {
                    let output = effects.host_runtime.execute_remote_root_command(
                        &target,
                        &CommandSpec::new(command.program, command.args),
                        EffectKind::Mutation,
                        task,
                    )?;
                    if !output.succeeded() {
                        bail!(
                            "Podman image prefetch failed for {host}: {}",
                            output.stderr.trim()
                        );
                    }
                    Ok(())
                })
            },
            |effects| {
                effects.check_forward_work()?;
                let command =
                    super::deploy::pre_activation_model_prefetch_command(&candidate.generation);
                let scope: Arc<dyn TaskScope> = effects.progress.host_scope(host);
                run_step(&scope, AcquireStep::PrefetchModels, |task| {
                    let output = effects.host_runtime.execute_remote_root_command(
                        &target,
                        &CommandSpec::new(command.program, command.args),
                        EffectKind::Mutation,
                        task,
                    )?;
                    if !output.succeeded() {
                        bail!(
                            "AI model prefetch failed for {host}: {}",
                            output.stderr.trim()
                        );
                    }
                    Ok(())
                })
            },
        );
        if let Err(error) = acquisition {
            if let Some(generation) = self.candidate_leases.get(host).cloned() {
                if let Err(cleanup) = self.release_candidate_lease(host, &generation) {
                    return Err(anyhow::anyhow!(
                        "{error:#}; candidate lease cleanup also failed: {cleanup:#}"
                    ));
                }
                self.candidate_leases.remove(host);
            }
            return Err(error);
        }
        self.acquired
            .insert(host.to_owned(), candidate.closure.clone());
        Ok(())
    }

    fn deploy_one(&mut self, host: &str) -> Result<()> {
        self.check_forward_work()?;
        let closure = self
            .closures
            .get(host)
            .cloned()
            .with_context(|| format!("missing built closure for {host}"))?;
        let acquired = self
            .acquired
            .get(host)
            .with_context(|| format!("missing acquired candidate for {host}"))?;
        if acquired != &closure {
            bail!(
                "acquired candidate for {host} is {}, expected {}",
                acquired.as_str(),
                closure.as_str()
            );
        }
        let desired = super::deploy::SystemGeneration::parse(closure.as_str())?;
        let resolved = resolve_host(self.inventory, host, &self.invocation.options)?;
        let acquire_host_lock = !self.controller_mutex_covers_target(&resolved)?;
        let target = self.execution_target(&resolved)?;
        // Verify or re-establish the exact target-side GC root before making
        // any activation preparation changes.
        self.check_forward_work()?;
        self.set_candidate_lease(host, &target, &desired, true)?;
        self.check_forward_work()?;
        let scope: Arc<dyn TaskScope> = self.progress.host_scope(host);
        let prepared = run_step_with(
            &scope,
            DeployStep::PreSwitch,
            |task| {
                self.host_runtime.prepare_switch(
                    &target,
                    &super::deploy::pre_switch_preparation_command(),
                    task,
                )
            },
            process_outcome,
        )?;
        if !prepared.succeeded() {
            return Err(anyhow::anyhow!(
                "pre-switch preparation failed for {host}: {}",
                prepared.stderr.trim()
            ));
        }

        self.check_forward_work()?;
        let activation_execution = (|| {
            let goal = deploy_goal(self.invocation.options.goal);
            let boot_environment = self.boot_environment(host)?;
            let activation = super::deploy::activation_command(super::deploy::ActivationCommand {
                run_id: self.invocation_id.to_string(),
                host: host.to_owned(),
                attempt: 1,
                generation: desired.clone(),
                goal,
                boot_environment,
                restart_managed: self.invocation.options.restart_managed,
                runtime_max: Duration::from_secs(
                    self.settings.remote_activation_runtime_max_seconds,
                ),
                stop_timeout: Duration::from_secs(
                    self.settings.remote_activation_stop_timeout_seconds,
                ),
                lock_wait: Duration::from_secs(self.settings.state_lock_timeout_seconds),
                acquire_host_lock,
            });
            run_step_with(
                &scope,
                DeployStep::Activation,
                |task| {
                    self.host_runtime
                        .activate(&target, &activation, &desired, goal, task)
                },
                activation_outcome,
            )
        })();
        let activation_execution = match activation_execution {
            Ok(execution) => execution,
            Err(error) => {
                if self.forward_work.is_some() {
                    // No terminal admission result: retained activation may
                    // already have mutated. Rollback admission remains final.
                    self.activated.insert(host.to_owned());
                    self.pending_rollback.insert(host.to_owned());
                }
                return Err(error);
            }
        };
        match activation_execution {
            ActivationExecution::Succeeded | ActivationExecution::SucceededAfterVerification => {
                self.activated.insert(host.to_owned());
                self.successful.insert(host.to_owned());
            }
            ActivationExecution::DryRun => {}
            ActivationExecution::Failed {
                admitted,
                status,
                diagnostics,
            } => {
                self.deploy_failed.insert(host.to_owned());
                if admitted {
                    self.activated.insert(host.to_owned());
                    self.pending_rollback.insert(host.to_owned());
                }
                bail!(
                    "activation failed for {host}: {}",
                    activation_failure_message(status, &diagnostics)
                );
            }
        }
        // Merge activation evidence before observing withdrawal. Never abandon
        // an in-flight activation observer merely because its parent cancelled.
        self.check_forward_work()?;
        let wait = self.inventory.hosts[host].wait;
        if wait > 0 {
            self.host_runtime.wait(Duration::from_secs(wait));
            super::signal::check_interrupted()?;
        }
        Ok(())
    }

    fn run_acquire_phase(&mut self) -> Result<()> {
        self.check_forward_work()?;
        if self.invocation.options.dry_run {
            for host in &self.selection.ordered {
                self.progress.host_skipped(host, "dry run");
            }
            return Ok(());
        }
        let control = self.admission_control(self.invocation.options.deploy_jobs, true)?;
        self.progress
            .phase_schedule("acquire", None, control.snapshot().target);
        let mut tasks = Vec::new();
        for host in &self.selection.ordered {
            self.check_forward_work()?;
            if self.inventory.hosts[host].deploy == DeployMode::Skip {
                self.progress.host_status(host, HostStatus::AcquireSkip);
            } else if let Some(candidate) = self.candidate_for_acquisition(host)? {
                let builder = self.builder_closures.get(host).cloned();
                tasks.push((host.clone(), candidate, builder));
            } else {
                self.progress.host_status(
                    host,
                    if self.optional_snapshot_skipped.contains(host) {
                        HostStatus::AcquireBlocked
                    } else {
                        HostStatus::AcquireSkip
                    },
                );
            }
        }
        // Reconcile guests parent-first. Transferring their candidates needs no
        // deployment ordering once the targets are reachable.
        self.ensure_parent_readiness(tasks.iter().map(|(host, _, _)| host))
            .context("acquisition parent readiness failed")?;
        let context = self.worker_context();
        let inventory = self.inventory;
        let progress = self.progress.clone();
        let outcomes = scheduling::dispatch(
            self.domain_tasks(tasks, |task| &task.0)?,
            &control,
            &progress,
            |(host, candidate, builder_closure)| {
                let _operation = progress.host_operation(&host);
                let policy = inventory.hosts[&host].deploy;
                let mut worker = match context.create() {
                    Ok(worker) => worker,
                    Err(error) => {
                        return AcquireTaskOutcome {
                            host,
                            policy,
                            result: Err(error),
                            candidate_lease: None,
                            acquired: None,
                            deferred: false,
                        };
                    }
                };
                if let Some(closure) = builder_closure {
                    worker.builder_closures.insert(host.clone(), closure);
                }
                let result = worker.acquire_one(&host, &candidate).and_then(|()| {
                    if worker.invocation.action == Action::Prepare {
                        worker.release_tracked_candidate_lease(&host)
                    } else {
                        Ok(())
                    }
                });
                AcquireTaskOutcome {
                    candidate_lease: worker.candidate_leases.get(&host).cloned(),
                    acquired: worker.acquired.get(&host).cloned(),
                    deferred: worker.acquisition_deferred.contains(&host),
                    host,
                    policy,
                    result,
                }
            },
            |outcome| context.stopped() || outcome.stops_admission(),
            |_, outcome| {
                if let Err(error) = &outcome.result {
                    progress.host_failed(&outcome.host, format!("acquisition failed: {error:#}"));
                } else if outcome.deferred {
                    progress.host_status(&outcome.host, HostStatus::AcquireDeferred);
                } else {
                    progress.host_status(&outcome.host, HostStatus::AcquireDone);
                }
            },
        )?;
        for outcome in outcomes.into_iter().flatten() {
            if let Some(generation) = outcome.candidate_lease {
                self.candidate_leases
                    .insert(outcome.host.clone(), generation);
            }
            if let Some(generation) = outcome.acquired {
                self.acquired.insert(outcome.host.clone(), generation);
            }
            if outcome.deferred {
                self.acquisition_deferred.insert(outcome.host.clone());
                self.workflow_warnings.push(WorkflowWarning {
                    host: outcome.host.clone(),
                    detail: "prefetch deferred until first activation".to_owned(),
                });
            }
            if let Err(error) = outcome.result {
                self.deploy_failed.insert(outcome.host.clone());
                if let Err(cleanup) = self.release_tracked_candidate_lease(&outcome.host) {
                    self.deploy_failures.push(format!(
                        "{} candidate lease cleanup: {cleanup:#}",
                        outcome.host
                    ));
                }
                if outcome.policy == DeployMode::Optional {
                    self.workflow_warnings.push(WorkflowWarning {
                        host: outcome.host,
                        detail: format!("acquisition failed: {error:#}"),
                    });
                } else {
                    self.deploy_failures
                        .push(format!("{} acquisition: {error:#}", outcome.host));
                }
            }
        }
        // All admitted outcomes are retained before cancellation or cleanup.
        self.check_forward_work()?;
        self.builder_lease.release();
        if self.deploy_failures.is_empty() {
            Ok(())
        } else {
            self.release_all_candidate_leases();
            bail!("{}", self.deploy_failures.join("; "))
        }
    }

    fn run_deploy_phase(&mut self) -> Result<()> {
        self.check_forward_work()?;
        if self.invocation.options.dry_run {
            for host in &self.selection.ordered {
                self.progress.host_skipped(host, "dry run");
            }
            return Ok(());
        }
        for host in &self.selection.ordered {
            if !self.acquired.contains_key(host) {
                self.progress.host_status(
                    host,
                    if self.inventory.hosts[host].deploy == DeployMode::Skip
                        || self.deploy_skipped.contains(host)
                    {
                        HostStatus::DeploySkip
                    } else {
                        HostStatus::DeployBlocked
                    },
                );
            }
        }
        let control = self.admission_control(self.invocation.options.deploy_jobs, true)?;
        let wave_count = self.selection.levels.len();
        for (wave_index, wave) in self.selection.levels.clone().into_iter().enumerate() {
            self.check_forward_work()?;
            self.progress.phase_schedule(
                "deploy",
                Some((wave_index + 1, wave_count)),
                control.snapshot().target,
            );
            let tasks =
                wave.into_iter()
                    .filter(|host| self.acquired.contains_key(host))
                    .map(|host| {
                        Ok((
                            host.clone(),
                            self.closures
                                .get(&host)
                                .cloned()
                                .with_context(|| format!("missing built closure for {host}"))?,
                            self.acquired.get(&host).cloned().with_context(|| {
                                format!("missing acquired candidate for {host}")
                            })?,
                            self.snapshots.get(&host).cloned(),
                        ))
                    })
                    .collect::<Result<Vec<_>>>()?;
            if let Err(error) = self.ensure_parent_readiness(tasks.iter().map(|task| &task.0)) {
                self.deploy_failures
                    .push(format!("parent readiness: {error:#}"));
                break;
            }
            let context = self.worker_context();
            let inventory = self.inventory;
            let invocation = self.invocation;
            let progress = self.progress.clone();
            let outcomes = scheduling::dispatch(
                self.domain_tasks(tasks, |task| &task.0)?,
                &control,
                &progress,
                |(host, closure, acquired, snapshot)| {
                    let _operation = progress.host_operation(&host);
                    let policy = inventory.hosts[&host].deploy;
                    let mut worker = match context.create() {
                        Ok(worker) => worker,
                        Err(error) => {
                            return DeployTaskOutcome {
                                host,
                                policy,
                                result: Err(error),
                                activated: false,
                                successful: false,
                                pending_rollback: false,
                                deploy_failed: true,
                                rollback_succeeded: false,
                                rollback_failed: false,
                                candidate_lease: Some(acquired),
                                cleanup_error: None,
                            };
                        }
                    };
                    worker.closures.insert(host.clone(), closure);
                    worker
                        .candidate_leases
                        .insert(host.clone(), acquired.clone());
                    worker.acquired.insert(host.clone(), acquired);
                    if let Some(snapshot) = snapshot {
                        worker.snapshots.insert(host.clone(), snapshot);
                    }
                    let mut result = worker.deploy_one(&host);
                    if result.is_err()
                        && policy == DeployMode::Optional
                        && worker.pending_rollback.contains(&host)
                        && !invocation.options.no_rollback
                        && let Err(rollback) = worker.rollback_activated()
                    {
                        result = Err(anyhow!(
                            "{}; optional rollback also failed: {rollback:#}",
                            result.expect_err("checked deploy failure")
                        ));
                    }
                    let cleanup_error = worker
                        .release_tracked_candidate_lease(&host)
                        .err()
                        .map(|error| format!("candidate lease cleanup deferred: {error:#}"));
                    DeployTaskOutcome {
                        candidate_lease: worker.candidate_leases.get(&host).cloned(),
                        cleanup_error,
                        activated: worker.activated.contains(&host),
                        successful: worker.successful.contains(&host),
                        pending_rollback: worker.pending_rollback.contains(&host),
                        deploy_failed: result.is_err(),
                        rollback_succeeded: worker.rollback_succeeded.contains(&host),
                        rollback_failed: worker.rollback_failed.contains(&host),
                        host,
                        policy,
                        result,
                    }
                },
                |outcome| {
                    context.stopped()
                        || (outcome.result.is_err() && outcome.policy != DeployMode::Optional)
                },
                |_, outcome| {
                    if let Err(error) = &outcome.result {
                        progress.host_failed(&outcome.host, format!("{error:#}"));
                    } else if outcome.successful {
                        progress.host_status(&outcome.host, HostStatus::DeployDone);
                    }
                },
            )?;
            for outcome in outcomes.into_iter().flatten() {
                let host = outcome.host;
                if let Some(generation) = outcome.candidate_lease {
                    self.candidate_leases.insert(host.clone(), generation);
                } else {
                    self.candidate_leases.remove(&host);
                }
                if let Some(detail) = outcome.cleanup_error {
                    self.progress.message(format!("{host} · {detail}"));
                    self.workflow_warnings.push(WorkflowWarning {
                        host: host.clone(),
                        detail,
                    });
                }
                if outcome.activated {
                    self.activated.insert(host.clone());
                }
                if outcome.successful {
                    self.successful.insert(host.clone());
                }
                if outcome.pending_rollback {
                    self.pending_rollback.insert(host.clone());
                }
                if outcome.deploy_failed {
                    self.deploy_failed.insert(host.clone());
                }
                if outcome.rollback_succeeded {
                    self.rollback_succeeded.insert(host.clone());
                }
                if outcome.rollback_failed {
                    self.rollback_failed.insert(host.clone());
                }
                if let Err(error) = outcome.result {
                    if outcome.policy == DeployMode::Optional {
                        self.workflow_warnings.push(WorkflowWarning {
                            host: host.clone(),
                            detail: format!("activation failed: {error:#}"),
                        });
                    } else {
                        self.deploy_failures.push(format!("{host}: {error:#}"));
                    }
                }
            }
            // Rollback consumes every joined receipt, not completion order.
            self.check_forward_work()?;
            if !self.deploy_failures.is_empty() {
                break;
            }
        }
        self.release_all_candidate_leases();
        if self.deploy_failures.is_empty() {
            Ok(())
        } else {
            bail!(
                "fleet deployment failed: {}",
                self.deploy_failures.join("; ")
            )
        }
    }

    fn run_health_phase(&mut self) -> Result<()> {
        self.check_forward_work()?;
        let mut failures = Vec::new();
        let control = self.admission_control(self.invocation.options.verify_jobs, false)?;
        self.progress
            .phase_schedule("verify", Some((1, 1)), control.snapshot().target);
        for host in &self.selection.ordered {
            if !self.successful.contains(host) {
                self.progress.host_status(
                    host,
                    if self.deploy_failed.contains(host)
                        || self.optional_snapshot_skipped.contains(host)
                        || self.acquisition_deferred.contains(host)
                    {
                        HostStatus::HealthBlocked
                    } else {
                        HostStatus::HealthSkip
                    },
                );
            }
        }
        if !self.invocation.options.no_verify && !self.invocation.options.dry_run {
            let mut tasks = Vec::new();
            for host in self.successful.clone() {
                self.check_forward_work()?;
                let target = (|| -> Result<HostExecutionTarget> {
                    let resolved = resolve_host(self.inventory, &host, &self.invocation.options)?;
                    self.execution_target(&resolved)
                })();
                match target {
                    Ok(target) => {
                        let ignored_system_units = self.inventory.hosts[&host]
                            .health_check
                            .ignore
                            .iter()
                            .cloned()
                            .collect::<BTreeSet<_>>();
                        tasks.push((host, target, ignored_system_units));
                    }
                    Err(error) => {
                        self.progress
                            .host_failed(&host, format!("health transport failed: {error:#}"));
                        failures.push(format!(
                            "{host}: post-switch health transport failed: {error:#}"
                        ));
                    }
                }
            }
            let repository = self.repository.to_path_buf();
            let progress = self.progress.clone();
            let forward_work = self.forward_work.clone();
            let checked = scheduling::dispatch(
                scheduling::unrestricted(tasks),
                &control,
                &progress,
                |(host, target, ignored_system_units)| {
                    let _operation = progress.host_operation(&host);
                    if let Err(error) = check_forward_work(&forward_work) {
                        return (host, Err(error));
                    }
                    let scope: Arc<dyn TaskScope> = progress.host_scope(&host);
                    let result = run_step_with(
                        &scope,
                        HealthStep::Check,
                        |task| -> Result<super::health_runtime::ManagedHealthReport> {
                            let mut runtime = HostRuntime::new(
                                reporting_process_runner(&progress),
                                repository.clone(),
                                DryRun::No,
                            )?;
                            let report = super::health_runtime::check_managed_health_with_progress(
                                &mut runtime,
                                &target,
                                &ignored_system_units,
                                Some(&task),
                                |attempt, decision, details| {
                                    task.note(&health_progress_line(attempt, decision, details));
                                },
                            );
                            if report.is_err() {
                                task.note("[health-check] probe failed; see diagnostics");
                            }
                            report
                        },
                        |report| {
                            if matches!(
                                report.decision,
                                super::health::HealthDecision::Healthy { .. }
                            ) {
                                TaskOutcome::Succeeded
                            } else {
                                TaskOutcome::Failed
                            }
                        },
                    );
                    (host, result)
                },
                |_| forward_work.as_ref().is_some_and(ForwardWorkGuard::stopped),
                |_, (host, result)| match result {
                    Ok(report) => match report.decision {
                        super::health::HealthDecision::Healthy { .. } => {
                            progress.host_status(host, HostStatus::HealthDone)
                        }
                        super::health::HealthDecision::Settling { .. } => {
                            progress.host_failed(host, "health is still settling")
                        }
                        super::health::HealthDecision::ServiceFailure { .. } => {
                            progress.host_failed(host, "service health failed")
                        }
                        super::health::HealthDecision::StructuralFailure { .. } => {
                            progress.host_failed(host, "structural health failed")
                        }
                    },
                    Err(error) => {
                        progress.host_failed(host, format!("health probe failed: {error:#}"))
                    }
                },
            )?;
            for (host, checked) in checked.into_iter().flatten() {
                match checked {
                    Ok(report) => {
                        for failure in &report.ignored_system_failures {
                            self.progress
                                .detail(format!("{host} · health ignored system unit · {failure}"));
                        }
                        if report.decision.requires_generation_rollback() {
                            self.pending_rollback.insert(host.clone());
                        }
                        match &report.decision {
                            super::health::HealthDecision::Healthy { .. } => {
                                self.progress.host_status(&host, HostStatus::HealthDone);
                                self.progress.detail(format!(
                                    "{host} · health ok · {} attempt{}",
                                    report.attempts,
                                    if report.attempts == 1 { "" } else { "s" }
                                ));
                            }
                            super::health::HealthDecision::Settling { .. } => {
                                self.progress.host_failed(&host, "health is still settling");
                                self.health_failed.insert(host.clone());
                                failures.push(health_failure_message(
                                    &host,
                                    "health is still settling",
                                    &report,
                                ));
                            }
                            super::health::HealthDecision::ServiceFailure { .. } => {
                                self.progress.host_failed(&host, "service health failed");
                                self.health_failed.insert(host.clone());
                                failures.push(health_failure_message(
                                    &host,
                                    "service health failed",
                                    &report,
                                ));
                            }
                            super::health::HealthDecision::StructuralFailure { .. } => {
                                self.progress.host_failed(&host, "structural health failed");
                                self.health_failed.insert(host.clone());
                                failures.push(health_failure_message(
                                    &host,
                                    "structural health failed",
                                    &report,
                                ));
                            }
                        }
                    }
                    Err(error) => {
                        self.progress
                            .host_failed(&host, format!("health probe failed: {error:#}"));
                        self.health_failed.insert(host.clone());
                        failures.push(format!(
                            "{host}: post-switch health probe failed: {error:#}"
                        ));
                    }
                }
            }
            self.check_forward_work()?;
        } else {
            for host in self.successful.clone() {
                if self.invocation.options.dry_run {
                    self.progress.host_skipped(&host, "dry run");
                } else {
                    self.progress.host_status(&host, HostStatus::HealthSkip);
                }
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            bail!("fleet deployment failed:\n  {}", failures.join("\n  "))
        }
    }

    fn run_bootstrap_check_phase(&mut self) -> Result<()> {
        let mut failures = Vec::new();
        for host in &self.selection.ordered {
            let resolved = resolve_host(self.inventory, host, &self.invocation.options)?;
            let Some(key) = resolved.bootstrap_key.as_deref() else {
                self.progress
                    .detail(format!("{host} · no bootstrap key configured"));
                continue;
            };
            let materialized = match self.materialize_declared_key(key, host, "bootstrap") {
                Ok(path) => path,
                Err(error) => {
                    self.bootstrap_failed.insert(host.clone());
                    failures.push(format!("{host}: {error:#}"));
                    continue;
                }
            };
            let fingerprint = match bootstrap_key_fingerprint(&materialized) {
                Ok(fingerprint) => fingerprint,
                Err(_) => {
                    self.bootstrap_failed.insert(host.clone());
                    failures.push(format!("{host}: bootstrap key is unreadable"));
                    continue;
                }
            };
            self.progress
                .detail(format!("{host} · bootstrap key valid · {fingerprint}"));
        }
        if failures.is_empty() {
            Ok(())
        } else {
            bail!("bootstrap key checks failed: {}", failures.join("; "))
        }
    }

    fn boot_environment(&self, host: &str) -> Result<super::deploy::BootEnvironment> {
        if let Some(owned) = &self.owned {
            return owned
                .boot
                .get(host)
                .copied()
                .with_context(|| format!("retained activation fact missing for {host}"));
        }
        let configuration = if self.invocation.options.host.as_deref() == Some(host) {
            self.invocation
                .options
                .nix_config
                .as_deref()
                .unwrap_or(host)
        } else {
            host
        };
        let command = super::deploy::boot_is_container_command(
            &self.nix_program.to_string_lossy(),
            &[],
            configuration,
        );
        let output = run_output(
            self.repository,
            &CommandSpec::new(command.program, command.args),
        )?;
        require_success("boot environment evaluation", &output)?;
        super::deploy::BootEnvironment::parse_nix_json(&String::from_utf8(output.stdout)?)
    }

    fn rollback_activated(&mut self) -> Result<()> {
        let mut failures = Vec::new();
        let eligible = self.pending_rollback.clone();
        for wave in super::deploy::rollback_waves(&self.selection.levels) {
            for host in wave {
                if !eligible.contains(&host) {
                    continue;
                }
                let Some(generation) = self
                    .snapshots
                    .get(&host)
                    .and_then(super::deploy::GenerationSnapshot::generation)
                    .cloned()
                else {
                    failures.push(format!("{host}: rollback generation unavailable"));
                    self.rollback_failed.insert(host.clone());
                    continue;
                };
                let result = (|| {
                    let resolved = resolve_host(self.inventory, &host, &self.invocation.options)?;
                    let acquire_host_lock = !self.controller_mutex_covers_target(&resolved)?;
                    let target = self.execution_target(&resolved)?;
                    let boot_environment = self.boot_environment(&host)?;
                    let command = super::deploy::rollback_command(
                        &self.invocation_id.to_string(),
                        &host,
                        generation.clone(),
                        boot_environment,
                        Duration::from_secs(self.settings.remote_activation_runtime_max_seconds),
                        Duration::from_secs(self.settings.remote_activation_stop_timeout_seconds),
                        Duration::from_secs(self.settings.state_lock_timeout_seconds),
                        acquire_host_lock,
                    );
                    let scope: Arc<dyn TaskScope> = self.progress.host_scope(&host);
                    match run_step_with(
                        &scope,
                        DeployStep::Rollback,
                        |task| {
                            self.host_runtime.activate(
                                &target,
                                &command,
                                &generation,
                                super::deploy::ActivationGoal::Switch,
                                task,
                            )
                        },
                        activation_outcome,
                    )? {
                        ActivationExecution::Succeeded
                        | ActivationExecution::SucceededAfterVerification
                        | ActivationExecution::DryRun => Ok(()),
                        ActivationExecution::Failed {
                            status,
                            diagnostics,
                            ..
                        } => {
                            bail!(
                                "rollback activation failed: {}",
                                activation_failure_message(status, &diagnostics)
                            )
                        }
                    }
                })();
                if let Err(error) = result {
                    failures.push(format!("{host}: {error:#}"));
                    self.rollback_failed.insert(host.clone());
                } else {
                    self.pending_rollback.remove(&host);
                    self.rollback_succeeded.insert(host);
                }
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            bail!("rollback failures: {}", failures.join("; "))
        }
    }
}

impl Drop for NativeFleetEffects<'_> {
    fn drop(&mut self) {
        for target in self.prepared_targets.values() {
            retire_control_master(target);
        }
    }
}

fn transport_store_name(repository: &Path) -> &str {
    repository
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("fleet")
}

fn relay_step(target: &HostExecutionTarget) -> TransferStep {
    if target.local {
        TransferStep::RelayPull
    } else {
        TransferStep::RelayPush
    }
}

fn command_outcome(status: &CommandStatus) -> TaskOutcome {
    if *status == CommandStatus::Success {
        TaskOutcome::Succeeded
    } else {
        TaskOutcome::Failed
    }
}

fn process_outcome(output: &ProcessOutput) -> TaskOutcome {
    if output.succeeded() {
        TaskOutcome::Succeeded
    } else {
        TaskOutcome::Failed
    }
}

fn activation_failure_message(status: CommandStatus, diagnostics: &[String]) -> String {
    let mut rendered = format!("{status:?}");
    for diagnostic in diagnostics.iter().take(4) {
        rendered.push_str(" · ");
        rendered.push_str(diagnostic);
    }
    rendered
}

fn activation_outcome(execution: &ActivationExecution) -> TaskOutcome {
    match execution {
        ActivationExecution::Succeeded
        | ActivationExecution::SucceededAfterVerification
        | ActivationExecution::DryRun => TaskOutcome::Succeeded,
        ActivationExecution::Failed { .. } => TaskOutcome::Failed,
    }
}

fn reporting_process_runner(progress: &FleetProgress) -> ProcessExecutor {
    let runner = ProcessExecutor::new(progress.recorder());
    match super::signal::runtime() {
        Some(cancellation) => runner.with_cancellation(cancellation),
        None => runner,
    }
}

fn control_socket_path(store: &Path, route: &SshRoutePlan) -> Result<PathBuf> {
    let digest = ssh_route_digest(route);
    let path = store.join(format!("cm-{}", &digest[..CONTROL_SOCKET_DIGEST_HEX_LEN]));
    let length = path.as_os_str().as_bytes().len();
    if length >= SSH_CONTROL_PATH_LIMIT {
        bail!(
            "SSH control path is {length} bytes, but OpenSSH requires fewer than {SSH_CONTROL_PATH_LIMIT}: {}",
            path.display()
        );
    }
    Ok(path)
}

fn ssh_route_digest(route: &SshRoutePlan) -> String {
    let mut digest = Sha256::new();
    digest.update(b"abird-ssh-route-v1\0");
    hash_ssh_endpoint(&mut digest, &route.endpoint);
    hash_field(
        &mut digest,
        match route.host_key_policy {
            HostKeyPolicy::Strict => b"strict",
            HostKeyPolicy::AcceptNew => b"accept-new",
        },
    );
    hash_optional_field(
        &mut digest,
        route
            .proxy_command
            .as_ref()
            .map(ProxyCommandTemplate::as_str),
    );
    hash_field(&mut digest, &route.proxy.hops.len().to_be_bytes());
    for hop in &route.proxy.hops {
        hash_field(&mut digest, hop.node.as_bytes());
        hash_ssh_endpoint(&mut digest, &hop.endpoint);
        hash_optional_field(
            &mut digest,
            hop.proxy_command.as_ref().map(ProxyCommandTemplate::as_str),
        );
        hash_field(&mut digest, &[u8::from(hop.local)]);
    }
    format!("{:x}", digest.finalize())
}

fn hash_ssh_endpoint(digest: &mut Sha256, endpoint: &SshEndpoint) {
    hash_field(digest, endpoint.node.as_bytes());
    hash_field(digest, endpoint.host.as_bytes());
    hash_field(digest, endpoint.user.as_bytes());
    hash_field(digest, &endpoint.port.to_be_bytes());
    hash_field(
        digest,
        match endpoint.role {
            TransportRole::Primary => b"primary",
            TransportRole::Operator => b"operator",
        },
    );
    // The materialized identity lives below a per-worker RAII directory. Its
    // path is deliberately not route authority; whether the route uses an
    // identity is. This keeps parallel workers on one semantic builder lease.
    hash_field(digest, &[u8::from(endpoint.identity.is_some())]);
}

fn hash_optional_field(digest: &mut Sha256, value: Option<&str>) {
    match value {
        Some(value) => {
            hash_field(digest, &[1]);
            hash_field(digest, value.as_bytes());
        }
        None => hash_field(digest, &[0]),
    }
}

fn hash_field(digest: &mut Sha256, value: &[u8]) {
    digest.update(value.len().to_be_bytes());
    digest.update(value);
}

fn safe_component(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-') {
                character
            } else {
                '_'
            }
        })
        .collect()
}

fn is_ip_address(value: &str) -> bool {
    value.parse::<std::net::IpAddr>().is_ok()
}

/// Parse a bootstrap private key in-process. Encrypted keys have no
/// non-interactive unlock path, so they are rejected rather than prompting.
fn read_bootstrap_private_key(private_key: &Path) -> Result<ssh_key::PrivateKey> {
    let contents = std::fs::read(private_key)
        .with_context(|| format!("read bootstrap private key {}", private_key.display()))?;
    let key = ssh_key::PrivateKey::from_openssh(&contents)
        .with_context(|| format!("parse bootstrap private key {}", private_key.display()))?;
    if key.is_encrypted() {
        bail!(
            "bootstrap private key {} is encrypted and has no non-interactive unlock path",
            private_key.display()
        );
    }
    Ok(key)
}

/// OpenSSH public-key line derived from a bootstrap private key, equivalent to
/// the `ssh-keygen -y` output streamed to the target.
fn bootstrap_public_key_line(private_key: &Path) -> Result<String> {
    Ok(read_bootstrap_private_key(private_key)?
        .public_key()
        .to_openssh()?)
}

/// `SHA256:` fingerprint of a bootstrap private key, in the same form
/// `ssh-keygen -lf` prints as its second field.
fn bootstrap_key_fingerprint(private_key: &Path) -> Result<String> {
    Ok(read_bootstrap_private_key(private_key)?
        .public_key()
        .fingerprint(ssh_key::HashAlg::Sha256)
        .to_string())
}

fn bootstrap_install_command(remote_key: &Path, remote_public: &Path) -> Result<CommandSpec> {
    let path = |value: &Path| -> Result<String> {
        value
            .to_str()
            .filter(|value| {
                value.starts_with('/')
                    && value.bytes().all(|byte| {
                        byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'.' | b'_' | b'-')
                    })
            })
            .map(str::to_owned)
            .context("bootstrap temporary path must be absolute and shell-safe")
    };
    let remote_key = path(remote_key)?;
    let remote_public = path(remote_public)?;
    let script = format!(
        r#"set -Eeuo pipefail
key_tmp={remote_key}
pub_tmp={remote_public}
key_dir=/var/lib/nixbot/.ssh
key_dest=/var/lib/nixbot/.ssh/id_ed25519
legacy_dest=/var/lib/nixbot/.ssh/id_ed25519_legacy
authorized=/etc/ssh/authorized_keys.d/nixbot
cleanup() {{ rm -f "$key_tmp" "$pub_tmp" "${{auth_tmp:-}}"; }}
trap cleanup EXIT
if [ "$(id -u)" -eq 0 ]; then
    elevate=()
else
    sudo -n true
    elevate=(sudo -n)
fi
"${{elevate[@]}}" install -d -m 0755 /var/lib/nixbot
"${{elevate[@]}}" install -d -m 0700 "$key_dir"
if ! "${{elevate[@]}}" test -f "$key_dest" || ! "${{elevate[@]}}" cmp -s "$key_tmp" "$key_dest"; then
    if "${{elevate[@]}}" test -f "$key_dest"; then
        "${{elevate[@]}}" install -m 0400 "$key_dest" "$legacy_dest"
    fi
    "${{elevate[@]}}" install -m 0400 "$key_tmp" "$key_dest"
fi
if "${{elevate[@]}}" id -u nixbot >/dev/null 2>&1; then
    "${{elevate[@]}}" chown -R nixbot:nixbot "$key_dir"
fi
public_key="$(cat "$pub_tmp")"
if "${{elevate[@]}}" test -f "$authorized" && "${{elevate[@]}}" grep -qxF "$public_key" "$authorized"; then
    exit 0
fi
auth_tmp="$(mktemp)"
if "${{elevate[@]}}" test -f "$authorized"; then
    "${{elevate[@]}}" cat "$authorized" >"$auth_tmp"
fi
printf '%s\n' "$public_key" >>"$auth_tmp"
"${{elevate[@]}}" install -D -m 0444 -o root -g root "$auth_tmp" "$authorized"
"#,
    );
    Ok(CommandSpec::new(
        "/run/current-system/sw/bin/bash",
        ["-c".to_owned(), script],
    ))
}

fn host_age_identity_install_command(remote: &Path, expected_hash: &str) -> Result<CommandSpec> {
    let remote = remote
        .to_str()
        .filter(|value| {
            value.starts_with('/')
                && value.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'.' | b'_' | b'-')
                })
        })
        .context("host age identity temporary path must be absolute and shell-safe")?;
    if expected_hash.len() != 64
        || !expected_hash
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        bail!("host age identity hash must be lowercase SHA-256");
    }
    let script = format!(
        r#"set -Eeuo pipefail
source={remote}
destination=/var/lib/nixbot/.age/identity
cleanup() {{ rm -f "$source"; }}
trap cleanup EXIT
actual="$(sha256sum "$source" | cut -d' ' -f1)"
[ "$actual" = {expected_hash} ]
if [ "$(id -u)" -eq 0 ]; then
    elevate=()
else
    sudo -n true
    elevate=(sudo -n)
fi
"${{elevate[@]}}" install -d -m 0755 /var/lib/nixbot
"${{elevate[@]}}" install -d -m 0710 -o root -g nixbot /var/lib/nixbot/.age
if ! "${{elevate[@]}}" test -f "$destination" || [ "$("${{elevate[@]}}" sha256sum "$destination" | cut -d' ' -f1)" != "$actual" ]; then
    "${{elevate[@]}}" install -m 0440 -o root -g nixbot "$source" "$destination"
fi
"${{elevate[@]}}" sha256sum "$destination"
"#,
    );
    Ok(CommandSpec::new(
        "/run/current-system/sw/bin/bash",
        ["-c".to_owned(), script],
    ))
}

pub(super) fn age_identities(options: &super::cli::Options) -> Vec<PathBuf> {
    let configured_explicitly = options.age_key_file.is_some();
    let configured = options.age_key_file.clone().unwrap_or_else(|| {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .map(|home| home.join(".ssh/id_ed25519"))
            .unwrap_or_default()
    });
    let discovery = match options.discover_keys {
        super::cli::DiscoverKeys::Auto => AgeDiscoveryMode::Auto,
        super::cli::DiscoverKeys::On => AgeDiscoveryMode::On,
        super::cli::DiscoverKeys::Off => AgeDiscoveryMode::Off,
    };
    age_identity_candidates(&AgeIdentityPolicy {
        configured,
        configured_explicitly,
        discovery,
    })
}

fn project_requires_secret_tfvars(root: &Path) -> Result<bool> {
    if !root.is_dir() {
        return Ok(false);
    }
    for entry in std::fs::read_dir(root)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        if kind.is_dir() {
            if project_requires_secret_tfvars(&entry.path())? {
                return Ok(true);
            }
            continue;
        }
        if !kind.is_file()
            || entry.path().extension().and_then(|value| value.to_str()) != Some("tfvars")
        {
            continue;
        }
        let contents = std::fs::read_to_string(entry.path())?;
        if contents.contains("config_secret_refs")
            || contents
                .split(|character: char| !character.is_ascii_alphanumeric() && character != '_')
                .any(|word| {
                    word.starts_with("secret_") && (word.ends_with("ref") || word.ends_with("refs"))
                })
        {
            return Ok(true);
        }
    }
    Ok(false)
}

fn ssh_store_uri(host: &ResolvedHost) -> Result<String> {
    if host.user.is_empty()
        || host
            .user
            .bytes()
            .any(|byte| byte.is_ascii_whitespace() || matches!(byte, b'@' | b'/' | b'?' | b'#'))
    {
        bail!("unsafe SSH store user for {}", host.inventory_name);
    }
    if host.target.is_empty()
        || host
            .target
            .bytes()
            .any(|byte| byte.is_ascii_whitespace() || matches!(byte, b'@' | b'/' | b'?' | b'#'))
    {
        bail!("unsafe SSH store target for {}", host.inventory_name);
    }
    let target = if host.target.contains(':') {
        format!("[{}]", host.target)
    } else {
        host.target.clone()
    };
    Ok(format!("ssh-ng://{}@{target}", host.user))
}

fn materialize_nix_proxy_command(directory: &Path, command: &str) -> Result<PathBuf> {
    let digest = format!("{:x}", Sha256::digest(command.as_bytes()));
    let path = directory.join(format!("nix-proxy-{}", &digest[..20]));
    if path.exists() {
        return Ok(path);
    }
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o700)
        .open(&path)
        .context("create Nix SSH proxy command")?;
    writeln!(file, "#!/bin/sh\nexec {command}")?;
    Ok(path)
}

fn prepare_nix_copy_target(
    directory: &Path,
    target: &HostExecutionTarget,
) -> Result<HostExecutionTarget> {
    let mut target = target.clone();
    let proxy = if let Some(command) = &target.route.proxy_command {
        Some(command.render(&target.route.endpoint.host, target.route.endpoint.port))
    } else {
        render_proxy_chain(&target)?
    };
    if let Some(proxy) = proxy {
        let path = materialize_nix_proxy_command(directory, &proxy)?;
        target.route.proxy = Default::default();
        target.route.proxy_command = Some(ProxyCommandTemplate::new(
            path.to_string_lossy().into_owned(),
        )?);
    }
    target.control_master = None;
    Ok(target)
}

fn include_successful_for_interrupted_rollback(
    pending: &mut BTreeSet<String>,
    successful: &BTreeSet<String>,
    force_remote: bool,
) {
    if force_remote {
        pending.extend(successful.iter().cloned());
    }
}

fn with_nix_sshopts(
    command: CommandSpec,
    target: &HostExecutionTarget,
) -> Result<(CommandSpec, Vec<(String, String)>)> {
    Ok((
        command,
        vec![(
            "NIX_SSHOPTS".to_owned(),
            nix_sshopts_without_control_master(target)?,
        )],
    ))
}

fn remote_build_tools() -> Result<RemoteBuildTools> {
    RemoteBuildTools::new(
        "/run/current-system/sw/bin/nix",
        "/run/current-system/sw/bin/bash",
        "/run/current-system/sw/bin/flock",
        "/nix/var/nix",
    )
}

fn deploy_goal(goal: super::cli::ActivationGoal) -> super::deploy::ActivationGoal {
    match goal {
        super::cli::ActivationGoal::Switch => super::deploy::ActivationGoal::Switch,
        super::cli::ActivationGoal::Boot => super::deploy::ActivationGoal::Boot,
        super::cli::ActivationGoal::Test => super::deploy::ActivationGoal::Test,
        super::cli::ActivationGoal::DryActivate => super::deploy::ActivationGoal::DryActivate,
    }
}

impl FleetEffects for NativeFleetEffects<'_> {
    fn run_phase(&mut self, phase: Phase) -> std::result::Result<(), PhaseFailure> {
        let started = Instant::now();
        let phase_hosts = if phase.uses_hosts() {
            self.selection.ordered.as_slice()
        } else {
            &[]
        };
        let host_count = phase_hosts.len();
        let plan = WorkflowPlan::for_action(&self.invocation.action);
        let position = plan
            .phases
            .iter()
            .position(|candidate| *candidate == phase)
            .map(|index| (index + 1, plan.phases.len()));
        self.progress.phase_started(phase, phase_hosts, position);
        let warning_start = self.workflow_warnings.len();
        let result = match phase {
            Phase::TerraformDns | Phase::TerraformPlatform | Phase::TerraformApps | Phase::Tofu => {
                self.run_terraform_phase(phase, position)
            }
            Phase::Build => self.run_build_phase(false),
            Phase::Snapshot => self.run_snapshot_phase(),
            Phase::Acquire => {
                let result = self.run_acquire_phase();
                if result.is_err() || self.invocation.action == Action::Prepare {
                    self.builder_lease.release();
                    self.release_all_candidate_leases();
                }
                if self.invocation.action == Action::Prepare {
                    self.verify_candidate_cleanup(result)
                } else {
                    result
                }
            }

            Phase::Deploy => {
                let result = self.run_deploy_phase();
                if result.is_err() {
                    self.release_all_candidate_leases();
                }
                result
            }
            Phase::Health => self.run_health_phase(),
            Phase::DevelopmentBuild => self.run_build_phase(true),
            Phase::BootstrapCheck => self.run_bootstrap_check_phase(),
            other => Err(anyhow::anyhow!("native phase {other:?} is not integrated")),
        };
        match result {
            Ok(()) => {
                let elapsed = started.elapsed();
                let warnings = &self.workflow_warnings[warning_start..];
                let kind = if warnings.is_empty() {
                    PhaseResultKind::Succeeded
                } else {
                    PhaseResultKind::Warning
                };
                self.phase_results
                    .push((phase, PhaseResult { kind, elapsed }));
                if warnings.is_empty() {
                    self.progress
                        .phase_completed(phase, host_count, position, elapsed);
                } else {
                    let warning = warnings
                        .iter()
                        .map(|warning| format!("{} · {}", warning.host, warning.detail))
                        .collect::<Vec<_>>()
                        .join("\n");
                    self.progress
                        .phase_warning(phase, host_count, position, elapsed, &warning);
                }
                Ok(())
            }
            Err(error) => {
                let message = format!("{error:#}");
                let elapsed = started.elapsed();
                let interrupted = interruption_active();
                self.phase_results.push((
                    phase,
                    PhaseResult {
                        kind: if interrupted {
                            PhaseResultKind::Interrupted
                        } else {
                            PhaseResultKind::Failed
                        },
                        elapsed,
                    },
                ));
                if interrupted {
                    self.progress
                        .phase_interrupted(phase, host_count, position, elapsed);
                } else {
                    self.progress
                        .phase_failed(phase, host_count, position, elapsed, &message);
                }
                if phase == Phase::Deploy {
                    Err(PhaseFailure::continuing_through(
                        phase,
                        message,
                        Phase::Health,
                    ))
                } else {
                    Err(PhaseFailure::new(phase, message))
                }
            }
        }
    }

    fn rollback(&mut self, failed_phase: Phase) -> Result<()> {
        if !matches!(failed_phase, Phase::Deploy | Phase::Health) {
            bail!("rollback is not valid for phase {failed_phase:?}");
        }
        if failed_phase == Phase::Deploy {
            include_successful_for_interrupted_rollback(
                &mut self.pending_rollback,
                &self.successful,
                super::signal::runtime().is_some_and(|runtime| runtime.force_remote()),
            );
        }
        self.rollback_activated()
    }

    fn rollback_interrupted(&mut self, phase: Phase) -> Result<()> {
        if !matches!(phase, Phase::Deploy | Phase::Health) {
            bail!("rollback is not valid for phase {phase:?}");
        }
        if self
            .forward_work
            .as_ref()
            .is_some_and(|guard| guard.check().is_err())
        {
            self.pending_rollback.extend(
                self.activated
                    .union(&self.successful)
                    .filter(|host| !self.rollback_succeeded.contains(*host))
                    .cloned(),
            );
            self.pending_rollback
                .retain(|host| !self.rollback_succeeded.contains(host));
            // No forward guard inside rollback: target-local authority still
            // admits/refuses every original snapshot, and all effects settle.
            self.rollback_activated()
        } else {
            self.rollback(phase)
        }
    }
}

#[cfg(test)]
mod cancellation_tests;
#[cfg(test)]
mod preparation_tests;

fn run_output(
    repository: &Path,
    command: &super::build::CommandSpec,
) -> Result<std::process::Output> {
    repository_command(&command.program)
        .args(&command.args)
        .current_dir(repository)
        .output()
        .with_context(|| format!("execute {}", command.program))
}

fn repository_command(program: &str) -> Command {
    let mut command = Command::new(program);
    clear_git_repository_environment(&mut command);
    command
}

fn require_success(program: &str, output: &std::process::Output) -> Result<()> {
    if output.status.success() {
        Ok(())
    } else {
        bail!(
            "{program} failed with {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        )
    }
}

pub fn action_needs_inventory(action: &Action) -> bool {
    matches!(
        action,
        Action::Run
            | Action::Deploy
            | Action::Prepare
            | Action::Build
            | Action::DevBuild
            | Action::CheckBootstrap
    )
}
#[cfg(test)]
mod tests {
    use super::*;

    /// Throwaway OpenSSH key pairs generated for this test suite only.
    const ED25519_PRIVATE_KEY: &str = "\
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCQnHU3VS3K3jkmnEaaHFcozUvZy0zS0EPn5jUATg1rBAAAAKhIj7rISI+6
yAAAAAtzc2gtZWQyNTUxOQAAACCQnHU3VS3K3jkmnEaaHFcozUvZy0zS0EPn5jUATg1rBA
AAAEDkzBKB91su4AW3mj8r2WxzSKJZZ1qA3qqCn2jB5vqr0ZCcdTdVLcreOSacRpocVyjN
S9nLTNLQQ+fmNQBODWsEAAAAH2FiaXJkLWhvc3QtbWFuYWdlciB0ZXN0IGZpeHR1cmUBAg
MEBQY=
-----END OPENSSH PRIVATE KEY-----
";
    const ED25519_PUBLIC_KEY: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJCcdTdVLcreOSacRpocVyjNS9nLTNLQQ+fmNQBODWsE abird-host-manager test fixture";
    const ED25519_FINGERPRINT: &str = "SHA256:Q/rWFyBY9l0AYppaCCUlFtTg32cu5xk6GBpOvbjk4Vk";

    const RSA_PRIVATE_KEY: &str = "\
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
NhAAAAAwEAAQAAAQEA8UWC3ai+BGnl4K6Kbx7LHRLe06pYTi0601Dhoun1Vcez717nT/zr
vqSj6I5njZ0O8KBTXf1cuabVFlajswticy552LsG9lIeKrldOCh0zl+xlpy9vFDKUWSjZj
pdzUFoprC0Ll/xaIu3kXTh/8magVt5kJio8CEjcC7chAVT0tOy9OmXIKHp24UzuoGjhTek
eq1+R36QJzq0F3d5rOsKB+96VR7+ypc0WPOR7lJhZeLYQo3kFVQvb4PzTybIN0ajlnvp3P
XVhm7aCvDmQlSpB8iUKjIvg13NHeKDG3bq+9YEjMTFM9rg4NvMdO9E2PC2WP/APzn7UmTW
44q4GqjKZwAAA9ivdAGbr3QBmwAAAAdzc2gtcnNhAAABAQDxRYLdqL4EaeXgropvHssdEt
7TqlhOLTrTUOGi6fVVx7PvXudP/Ou+pKPojmeNnQ7woFNd/Vy5ptUWVqOzC2JzLnnYuwb2
Uh4quV04KHTOX7GWnL28UMpRZKNmOl3NQWimsLQuX/Foi7eRdOH/yZqBW3mQmKjwISNwLt
yEBVPS07L06ZcgoenbhTO6gaOFN6R6rX5HfpAnOrQXd3ms6woH73pVHv7KlzRY85HuUmFl
4thCjeQVVC9vg/NPJsg3RqOWe+nc9dWGbtoK8OZCVKkHyJQqMi+DXc0d4oMbdur71gSMxM
Uz2uDg28x070TY8LZY/8A/OftSZNbjirgaqMpnAAAAAwEAAQAAAQATCl1NiOeWCZVuqdea
9V8qKDcVlTfq03709kkYRkZqQpxco6y1j0w7e1rEG5jogCCRtNVfcYND03q1jJjWpGtck6
piBECEZ+6hiIdmyyqMrtig/jWrCuUsjzil9K06aZMMtJ1Dm6a9jWkrPYIoYYyj8MgjNSj/
6l2VmN0mPhVjadJWqtgaACaZ+O+Z5Fn8N6CsRv83qZ/oDjjNIjBOf8lvHTwmD7hKj7gBk6
5KLAWYHIMJi6xl6+s3Hx/7WAws1BJZ5T+Tbil3Qd/t4nKDXkEaKz1QaXSAWHn76KlKQsT8
epBjXMWBKpkUc3CPmxTqBLfMXWblsuc9kQuNf+BItQ+hAAAAgQCW55JJgVHj0DwRJ5+No6
9y5EVM3PKeePT4JQk0CYV/JQ6GaXy0SInwV0bq/ZiVcKzILG9jsxa+i8L9NJtO1KFDc57L
FF5Qi9oKTvZ7sZ7NntQK8hGpq1tp0tQiVtSghvHIYC2Vmyqav2BdpM5gUbmworzbnqR9E3
Mo7QwoOKK4kAAAAIEA+/6aKaqQ90zrQqcGpQbb6eFpHMNNBG1+4zyYxEJvTk9epXlITKSs
Jx/iTO91QUrKiD4hRlwiMLB2CTBYaCPD8lWSNBBcktVc6inOtIlsE+SNxcDaoLpYAaloj6
9jdnjiqD1PDVNAI1KPuHGiLyWWEQ6tDctkLfkwN2g1C4wHTisAAACBAPUbRpQ5qsFZwtj6
u/DN3sDwZhBoPEIwOUxunq/WlK7n83dxU7VmqP6B8WZdMLA8QL6XZWRs9CqMpjZsBT36jT
n3epC93IhQSTddjRa0tnfQdAz+SnH82O8S70ySFkOlOZqU5YoLwtIxnM7DkPglUKgCMhC9
ZeRKvPtruMdBvpK1AAAAH2FiaXJkLWhvc3QtbWFuYWdlciB0ZXN0IGZpeHR1cmUBAgM=
-----END OPENSSH PRIVATE KEY-----
";
    const RSA_PUBLIC_KEY: &str = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDxRYLdqL4EaeXgropvHssdEt7TqlhOLTrTUOGi6fVVx7PvXudP/Ou+pKPojmeNnQ7woFNd/Vy5ptUWVqOzC2JzLnnYuwb2Uh4quV04KHTOX7GWnL28UMpRZKNmOl3NQWimsLQuX/Foi7eRdOH/yZqBW3mQmKjwISNwLtyEBVPS07L06ZcgoenbhTO6gaOFN6R6rX5HfpAnOrQXd3ms6woH73pVHv7KlzRY85HuUmFl4thCjeQVVC9vg/NPJsg3RqOWe+nc9dWGbtoK8OZCVKkHyJQqMi+DXc0d4oMbdur71gSMxMUz2uDg28x070TY8LZY/8A/OftSZNbjirgaqMpn abird-host-manager test fixture";
    const RSA_FINGERPRINT: &str = "SHA256:3uZzW3pDHgjkmvEG1PXN9BEXT4N1gb0PuiInQzUyxmo";

    /// The `ssh-ed25519` fixture protected with a passphrase, which has no
    /// non-interactive unlock path.
    const ENCRYPTED_PRIVATE_KEY: &str = "\
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDoa+NFG6
o0CVzqmgpbwF4GAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIIuxkpGM/cX5cQjX
Crw8JqVPao1X5z+gCP4SFHK+b7tbAAAAsOl4Ha//Cx/t7F4pbfmxMP/Cy2xv3qmmOOQP1Y
7Mrxy1zymryym3chXpOckZZzafv3SotPSZ5uoXzP2o51qqYukgWQgH+8SZ5rurXv/rYzYE
WK2RuW0p77MMbXuYMdQ9J6l/aLoeL9Ao9Gu04iS4qs0eKrf7UhZyuXlUVpU2si4lFkdgUt
yqPpbFFUX2lXWPH9I3zqYt2VnWDScGTitnk6RpLFwc3nSFWiDm1rkzj/Tf
-----END OPENSSH PRIVATE KEY-----
";

    #[test]
    fn bootstrap_public_key_and_fingerprint_are_derived_in_process() -> anyhow::Result<()> {
        let directory = tempfile::tempdir()?;
        for (name, private_key, public_key, fingerprint) in [
            (
                "ed25519",
                ED25519_PRIVATE_KEY,
                ED25519_PUBLIC_KEY,
                ED25519_FINGERPRINT,
            ),
            ("rsa", RSA_PRIVATE_KEY, RSA_PUBLIC_KEY, RSA_FINGERPRINT),
        ] {
            let path = directory.path().join(name);
            std::fs::write(&path, private_key)?;
            assert_eq!(bootstrap_public_key_line(&path)?, public_key, "{name}");
            assert_eq!(bootstrap_key_fingerprint(&path)?, fingerprint, "{name}");
        }
        Ok(())
    }

    #[test]
    fn encrypted_bootstrap_private_key_has_no_non_interactive_unlock_path() -> anyhow::Result<()> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("bootstrap.key");
        std::fs::write(&path, ENCRYPTED_PRIVATE_KEY)?;
        for error in [
            bootstrap_public_key_line(&path).unwrap_err().to_string(),
            bootstrap_key_fingerprint(&path).unwrap_err().to_string(),
        ] {
            assert!(error.contains("is encrypted"), "{error}");
        }
        Ok(())
    }

    #[test]
    fn nix_ssh_options_are_delivered_as_environment_not_an_env_wrapper() -> anyhow::Result<()> {
        let endpoint = SshEndpoint::new(
            "builder",
            "builder.example",
            "root",
            22,
            TransportRole::Primary,
            None,
        )?;
        let target = HostExecutionTarget {
            route: SshRoutePlan::direct(endpoint),
            cwd: PathBuf::from("/repo"),
            known_hosts_file: None,
            local: false,
            ssh_connect_timeout_seconds: 30,
            ssh_server_alive_interval_seconds: 5,
            ssh_server_alive_count_max: 3,
            remote_read_timeout_seconds: 20,
            control_master: None,
        };
        let command = CommandSpec::new(
            "nix",
            [
                "copy".to_owned(),
                "--to".to_owned(),
                "ssh-ng://root@builder.example".to_owned(),
            ],
        );
        let expected = command.clone();
        let (command, environment) = with_nix_sshopts(command, &target)?;
        // The command must not gain an `env` wrapper; the transport options
        // travel as a process environment entry instead.
        assert_eq!(command, expected);
        assert_eq!(environment.len(), 1);
        let (name, value) = &environment[0];
        assert_eq!(name, "NIX_SSHOPTS");
        assert!(value.contains("-o"), "{value}");
        assert!(value.contains("BatchMode=yes"), "{value}");
        assert!(value.contains("-S none"), "{value}");
        assert!(value.contains("ControlMaster=no"), "{value}");
        assert!(!value.contains("ControlMaster=auto"), "{value}");
        assert!(!value.contains('\''), "{value}");
        assert!(!value.contains("env"), "{value}");
        Ok(())
    }

    #[test]
    fn nix_ssh_proxy_is_materialized_as_one_whitespace_free_option() -> anyhow::Result<()> {
        let directory = tempfile::tempdir()?;
        let endpoint = SshEndpoint::new(
            "builder",
            "builder.example",
            "root",
            22,
            TransportRole::Primary,
            None,
        )?;
        let mut target = HostExecutionTarget {
            route: SshRoutePlan::via_command(
                endpoint,
                ProxyCommandTemplate::new("cloudflared access ssh --hostname builder.example")?,
            ),
            cwd: PathBuf::from("/repo"),
            known_hosts_file: None,
            local: false,
            ssh_connect_timeout_seconds: 30,
            ssh_server_alive_interval_seconds: 5,
            ssh_server_alive_count_max: 3,
            remote_read_timeout_seconds: 20,
            control_master: None,
        };
        let command = CommandSpec::new("nix", ["copy".to_owned()]);
        assert!(with_nix_sshopts(command.clone(), &target).is_err());

        target = prepare_nix_copy_target(directory.path(), &target)?;
        let proxy = PathBuf::from(target.route.proxy_command.as_ref().unwrap().as_str());
        assert_eq!(
            std::fs::metadata(&proxy)?.permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            std::fs::read_to_string(&proxy)?,
            "#!/bin/sh\nexec cloudflared access ssh --hostname builder.example\n"
        );
        let (_, environment) = with_nix_sshopts(command, &target)?;
        let value = &environment[0].1;
        assert!(value.contains(&format!("ProxyCommand={}", proxy.display())));
        assert!(!value.contains("cloudflared"));
        assert!(!value.contains('\''));
        Ok(())
    }

    #[test]
    fn health_progress_line_carries_attempt_state_and_raw_detail() {
        let decision = super::super::health::HealthDecision::ServiceFailure {
            evidence: Vec::new(),
        };
        // Sanitization and allowlisting are presentation-owned; this only pins
        // the line shape that presentation parses back.
        assert_eq!(
            health_progress_line(2, &decision, &["first.service loaded failed".into()]),
            "[health-check] attempt 2 · service failure · first.service loaded failed"
        );
        assert_eq!(
            health_progress_line(3, &decision, &[]),
            "[health-check] attempt 3 · service failure"
        );
        assert_eq!(
            health_progress_line(4, &decision, &[String::new()]),
            "[health-check] attempt 4 · service failure"
        );
    }

    #[test]
    fn only_forced_interruption_adds_successful_hosts_to_rollback() {
        let successful = BTreeSet::from(["app".to_owned(), "db".to_owned()]);
        let mut pending = BTreeSet::from(["failed".to_owned()]);
        include_successful_for_interrupted_rollback(&mut pending, &successful, false);
        assert_eq!(pending, BTreeSet::from(["failed".to_owned()]));

        include_successful_for_interrupted_rollback(&mut pending, &successful, true);
        assert_eq!(
            pending,
            BTreeSet::from(["app".to_owned(), "db".to_owned(), "failed".to_owned()])
        );
    }

    #[test]
    fn repository_commands_remove_git_checkout_selectors() {
        let command = repository_command("nix");
        for selector in crate::programs::GIT_REPOSITORY_ENVIRONMENT {
            assert_eq!(
                command
                    .get_envs()
                    .find(|(name, _)| name == selector)
                    .map(|(_, value)| value),
                Some(None),
                "{selector} was not removed"
            );
        }
    }

    #[test]
    fn control_socket_names_are_short_fixed_and_route_specific() -> anyhow::Result<()> {
        let store = Path::new("/dev/shm/nixbot/run-15bb7f2539a04b6388ed51b71ea23e89/t-n8k91C");
        let first = SshRoutePlan::direct(SshEndpoint::new(
            "builder-a",
            "10.10.30.80",
            "root",
            22,
            TransportRole::Primary,
            None,
        )?);
        let second = SshRoutePlan::direct(SshEndpoint::new(
            "builder-b",
            "10.10.30.81",
            "root",
            22,
            TransportRole::Primary,
            None,
        )?);

        let first = control_socket_path(store, &first)?;
        let second = control_socket_path(store, &second)?;

        assert_ne!(first, second);
        for socket in [first, second] {
            assert!(socket.as_os_str().as_bytes().len() < SSH_CONTROL_PATH_LIMIT);
            assert_eq!(
                socket.file_name().unwrap().as_bytes().len(),
                3 + CONTROL_SOCKET_DIGEST_HEX_LEN
            );
        }
        Ok(())
    }

    #[test]
    fn candidate_acquisition_pipeline_runs_each_stage_in_order() -> anyhow::Result<()> {
        let mut stages = Vec::new();

        execute_candidate_acquisition_pipeline(
            &mut stages,
            |stages| {
                stages.push("distribute");
                Ok(())
            },
            |stages| {
                stages.push("protect");
                Ok(())
            },
            |stages| {
                stages.push("admit-generation");
                Ok(CandidateAcquisition::Approved)
            },
            |stages| {
                stages.push("pull-images");
                Ok(())
            },
            |stages| {
                stages.push("prefetch-models");
                Ok(())
            },
        )?;

        assert_eq!(
            stages,
            [
                "distribute",
                "protect",
                "admit-generation",
                "pull-images",
                "prefetch-models"
            ]
        );
        Ok(())
    }

    #[test]
    fn candidate_acquisition_pipeline_stops_before_later_mutations_on_failure() {
        let mut stages = Vec::new();

        let error = execute_candidate_acquisition_pipeline(
            &mut stages,
            |stages| {
                stages.push("distribute");
                Ok(())
            },
            |stages| {
                stages.push("protect");
                Ok(())
            },
            |stages| {
                stages.push("admit-generation");
                Err(anyhow::anyhow!("admission failed"))
            },
            |stages| {
                stages.push("pull-images");
                Ok(())
            },
            |stages| {
                stages.push("prefetch-models");
                Ok(())
            },
        )
        .expect_err("admission failure must stop candidate acquisition");

        assert_eq!(error.to_string(), "admission failed");
        assert_eq!(stages, ["distribute", "protect", "admit-generation"]);
    }

    #[test]
    fn route_remediation_is_limited_to_transport_failures() {
        for evidence in [
            "ssh: connect to host example port 22: Connection refused",
            "ssh: connect to host example port 22: Network is unreachable",
            "ssh: connect to host example port 22: No route to host",
            "Connection timed out during banner exchange",
        ] {
            assert!(route_relevant_transport_failure(evidence), "{evidence}");
        }
        for evidence in [
            "Permission denied (publickey)",
            "Host key verification failed",
            "No space left on device",
        ] {
            assert!(!route_relevant_transport_failure(evidence), "{evidence}");
        }
    }

    #[test]
    fn candidate_acquisition_pipeline_honors_first_activation_deferral() -> anyhow::Result<()> {
        let mut stages = Vec::new();

        execute_candidate_acquisition_pipeline(
            &mut stages,
            |stages| {
                stages.push("distribute");
                Ok(())
            },
            |stages| {
                stages.push("protect");
                Ok(())
            },
            |stages| {
                stages.push("defer-acquisition");
                Ok(CandidateAcquisition::Deferred)
            },
            |stages| {
                stages.push("unexpected-image-pull");
                Ok(())
            },
            |stages| {
                stages.push("unexpected-model-prefetch");
                Ok(())
            },
        )?;

        assert_eq!(stages, ["distribute", "protect", "defer-acquisition"]);
        Ok(())
    }
}
