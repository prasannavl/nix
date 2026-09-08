//! Native fleet workflow coordinator.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use sha2::{Digest, Sha256};

use super::bootstrap::{
    AgeDiscoveryMode, AgeIdentityPolicy, ForcedCommandInput, ForcedCommandObservation,
    ForcedCommandReadiness, age_identity_candidates, build_forced_command_check,
    classify_forced_command_readiness, temporary_transport_failure,
};
use super::build::{
    BuildArgs, BuildBatch, BuildCacheContext, BuildCacheState, BuildHostDeployMode,
    BuildPlanAttribute, BuildSchedule, BuilderClosure, CacheSource, CommandSpec,
    DistributionInputs, DistributionPlan, LocalBuildSpec, NixStorePath, RetryPolicy,
    build_plan_cache_file, build_plan_evaluation_command, build_plan_probe_command,
    closure_verification_command, copy_derivation_command, development_build_command,
    local_build_command, validate_cached_build_plan,
};
use super::build_lease::{BuilderLeaseCoordinator, InvocationId, LeaseEpoch};
use super::build_runtime::{RemoteBuildTools, plan_remote_build};
use super::cli::{Action, Invocation};
use super::engine::{FleetEffects, PhaseFailure};
use super::environment::{Environment, LocalSelfTarget, Settings};
use super::host_runtime::{
    ActivationExecution, DistributionExecution, DryRun, EffectKind, HostExecutionTarget,
    HostRuntime, RemoteBuildRequest, ReportingProcessRunner, builder_lease_process_spec,
    retire_control_master, ssh_connection_args,
};
use super::inventory::{DeployMode, Inventory};
use super::plan::Phase;
use super::presentation::FleetProgress;
use super::selection::Selection;
use super::system::{ResolvedHost, resolve_host};
use super::transport::{
    HostTransport, ProcessStatus, ProxyCommandTemplate, SelfTargetDecision, SelfTargetEvidence,
    SelfTargetMode, SshEndpoint, SshRoutePlan, TransportRole, plan_proxy_chain, plan_self_target,
};

pub struct NativeFleetEffects<'a> {
    invocation: &'a Invocation,
    nix_program: &'a Path,
    repository: &'a Path,
    inventory: &'a Inventory,
    selection: &'a Selection,
    host_runtime: HostRuntime<ReportingProcessRunner>,
    progress: FleetProgress,
    transport_store: tempfile::TempDir,
    invocation_id: InvocationId,
    builder_lease: Arc<BuilderLeaseCoordinator>,
    builder_closures: BTreeMap<String, BuilderClosure>,
    settings: Settings,
    derivations: BTreeMap<String, NixStorePath>,
    closures: BTreeMap<String, NixStorePath>,
    snapshots: BTreeMap<String, super::deploy::GenerationSnapshot>,
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
    terraform_status: Vec<(String, bool)>,
    pending_rollback: BTreeSet<String>,
    deploy_failures: Vec<String>,
    bootstrap_prepared: BTreeSet<String>,
    age_identity_prepared: BTreeSet<String>,
    prepared_targets: BTreeMap<String, HostExecutionTarget>,
    diagnostic_dir: Option<PathBuf>,
}

struct DeployTaskOutcome {
    host: String,
    policy: DeployMode,
    result: Result<()>,
    activated: bool,
    successful: bool,
    pending_rollback: bool,
    deploy_skipped: bool,
    optional_snapshot_skipped: bool,
    deploy_failed: bool,
    rollback_succeeded: bool,
    rollback_failed: bool,
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
        if !repository.is_absolute() {
            bail!("native fleet repository must be absolute");
        }
        if !nix_program.is_absolute() {
            bail!("native fleet Nix program must be absolute");
        }
        let transport_store = tempfile::Builder::new()
            .prefix("abird-fleet-transport-")
            .tempdir_in(repository.parent().unwrap_or(repository))
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
        Ok(Self {
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
            builder_lease: Arc::new(BuilderLeaseCoordinator::default()),
            builder_closures: BTreeMap::new(),
            settings,
            derivations: BTreeMap::new(),
            closures: BTreeMap::new(),
            snapshots: BTreeMap::new(),
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
            terraform_status: Vec::new(),
            pending_rollback: BTreeSet::new(),
            deploy_failures: Vec::new(),
            bootstrap_prepared: BTreeSet::new(),
            age_identity_prepared: BTreeSet::new(),
            prepared_targets: BTreeMap::new(),
            diagnostic_dir: diagnostic_dir.map(Path::to_path_buf),
        })
    }

    pub fn derivations(&self) -> &BTreeMap<String, NixStorePath> {
        &self.derivations
    }

    pub fn closures(&self) -> &BTreeMap<String, NixStorePath> {
        &self.closures
    }

    pub fn report_summary(&self, succeeded: bool, elapsed: Duration) {
        use super::orchestration::{HostSummaryFacts, SummaryMode};

        let host_action = matches!(
            self.invocation.action,
            Action::Run
                | Action::Deploy
                | Action::Build
                | Action::DevBuild
                | Action::CheckBootstrap
        );
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
                                || (self.invocation.options.dry_run
                                    && self.derivations.contains_key(host))
                        };
                    let facts = HostSummaryFacts {
                        build_succeeded,
                        build_failed: check_failed
                            || (!fully_skipped
                                && !build_succeeded
                                && !matches!(self.invocation.action, Action::CheckBootstrap)),
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
                    (host.clone(), facts.final_state(mode).label().to_owned())
                })
                .collect::<Vec<_>>()
        } else {
            Vec::new()
        };
        let terraform = self
            .terraform_status
            .iter()
            .map(|(project, ok)| {
                (
                    project.clone(),
                    if *ok { "ok" } else { "FAIL (tf)" }.to_owned(),
                )
            })
            .collect::<Vec<_>>();
        self.progress.workflow_summary(
            action_summary_label(&self.invocation.action),
            hosts
                .iter()
                .map(|(host, status)| (host.as_str(), status.as_str())),
            terraform
                .iter()
                .map(|(project, status)| (project.as_str(), status.as_str())),
            succeeded,
            elapsed,
        );
    }

    fn build_plan_cache_context(&self) -> Result<Option<(PathBuf, String)>> {
        let git = |args: &[&str]| -> Result<std::process::Output> {
            Command::new("git")
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
        let version = Command::new(self.nix_program)
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
        let nix = self.nix_program.to_string_lossy();
        let build_args = BuildArgs::for_concurrency(
            self.invocation.options.build_jobs,
            self.invocation.options.build_logs,
        )?;
        let plan_args = if self.selection.ordered.len() > 1 {
            vec![
                "--option".to_owned(),
                "eval-cache".to_owned(),
                "false".to_owned(),
            ]
        } else {
            Vec::new()
        };
        let probe = build_plan_probe_command(&nix, &plan_args);
        let probe = self.host_runtime.execute_local_command(
            &probe,
            EffectKind::ReadOnly,
            "build-plan-probe",
        )?;
        let attribute = if probe.succeeded() {
            BuildPlanAttribute::Native
        } else {
            BuildPlanAttribute::NixosConfiguration
        };
        let cache = self.build_plan_cache_context()?;
        let mut pending = Vec::new();
        for host in &self.selection.ordered {
            let configuration = if self.invocation.options.host.as_deref() == Some(host)
                && let Some(configuration) = &self.invocation.options.nix_config
            {
                configuration.clone()
            } else {
                host.clone()
            };
            if let Some((_, derivation)) =
                self.cached_derivation(cache.as_ref(), host, &configuration)?
            {
                self.progress
                    .detail(format!("Build plan cache hit · {host}"));
                self.derivations.insert(host.clone(), derivation);
            } else {
                let plan =
                    build_plan_evaluation_command(&nix, &plan_args, attribute, &configuration);
                let cache_path = cache
                    .as_ref()
                    .map(|(root, context)| {
                        build_plan_cache_file(root, context, host, &configuration)
                    })
                    .transpose()?;
                pending.push((host.clone(), configuration, plan, cache_path));
            }
        }
        let plan_jobs = match self.invocation.options.build_plan_jobs {
            super::cli::JobCount::Auto => std::thread::available_parallelism()
                .map(usize::from)
                .unwrap_or(1),
            super::cli::JobCount::Count(count) => count,
        };
        let repository = self.repository.to_path_buf();
        let progress = self.progress.clone();
        let evaluated = super::orchestration::bounded_parallel_map(
            pending,
            plan_jobs,
            |(host, configuration, plan, cache_path)| -> Result<_> {
                let mut runtime = HostRuntime::new(
                    reporting_process_runner(&progress),
                    repository.clone(),
                    DryRun::No,
                )?;
                let derivation = runtime
                    .evaluate_build_plan_labeled(&plan, &format!("build-plan-{host}"))?
                    .executed()
                    .context("build-plan evaluation was unexpectedly suppressed")?;
                Ok((host, configuration, derivation, cache_path))
            },
        )?;
        for result in evaluated {
            let (host, _configuration, derivation, cache_path) = result?;
            if let Some(path) = cache_path {
                self.write_cached_derivation(&path, &derivation)?;
            }
            self.derivations.insert(host, derivation);
        }

        if self.invocation.options.dry_run {
            return Ok(());
        }
        let control_plane = self.inventory.control_plane_hosts()?;
        let schedule = BuildSchedule::new(
            self.selection.ordered.clone(),
            self.invocation.options.build_jobs,
            &control_plane,
        )?;
        for batch in schedule.batches {
            match batch {
                BuildBatch::Parallel(hosts) => {
                    self.build_parallel_batch(hosts, development, &build_args)?;
                }
                BuildBatch::Serial(host) => {
                    let derivation = self
                        .derivations
                        .get(&host)
                        .cloned()
                        .with_context(|| format!("missing evaluated derivation for {host}"))?;
                    let closure = self.build_one(&host, development, &derivation, &build_args)?;
                    self.closures.insert(host, closure);
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
        let invocation = self.invocation;
        let nix_program = self.nix_program;
        let repository = self.repository;
        let inventory = self.inventory;
        let selection = self.selection;
        let invocation_id = self.invocation_id.clone();
        let builder_lease = Arc::clone(&self.builder_lease);
        let diagnostic_dir = self.diagnostic_dir.clone();
        let built = super::orchestration::bounded_parallel_map(
            tasks,
            self.invocation.options.build_jobs,
            |(host, derivation)| -> Result<_> {
                let mut worker = NativeFleetEffects::new_with_diagnostics(
                    invocation,
                    nix_program,
                    repository,
                    inventory,
                    selection,
                    diagnostic_dir.as_deref(),
                )?;
                worker.invocation_id = invocation_id.clone();
                worker.builder_lease = Arc::clone(&builder_lease);
                let closure = worker
                    .build_one(&host, development, &derivation, build_args)
                    .with_context(|| format!("build {host}"))?;
                Ok((host.clone(), closure, worker.builder_closures.remove(&host)))
            },
        )?;
        let mut failures = Vec::new();
        for result in built {
            match result {
                Ok((host, closure, builder_closure)) => {
                    self.closures.insert(host.clone(), closure);
                    if let Some(builder_closure) = builder_closure {
                        self.builder_closures.insert(host, builder_closure);
                    }
                }
                Err(error) => failures.push(format!("{error:#}")),
            }
        }
        if !failures.is_empty() {
            bail!("fleet build failed: {}", failures.join("; "));
        }
        Ok(())
    }

    fn build_one(
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
            self.host_runtime
                .local_build_labeled(&command, &format!("build-{host}"))?
                .executed()
                .context("local build was unexpectedly suppressed")
        } else {
            self.remote_build(host, &build_host, derivation, build_args)
        }
    }

    fn run_terraform_phase(&mut self, phase: Phase) -> Result<()> {
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
        for selection in selections {
            if selection.decision == super::terraform::ChangeDecision::SkipUnchanged {
                self.terraform_status
                    .push((selection.run.name.clone(), true));
                continue;
            }
            let context = super::terraform::project_context(&selection.run.directory)?;
            let identities = age_identities(&self.invocation.options);
            let decryptor = super::terraform_runtime::AgeCommandDecryptor {
                program: PathBuf::from("age"),
                identities,
            };
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
            let discovered = super::terraform_runtime::discover_tfvar_secrets(
                self.repository,
                &selection.run.name,
            )?;
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
            let report = super::terraform_runtime::execute_phase(
                &[execution],
                self.repository,
                &mut executor,
            );
            let report_success = report.success;
            for project in report.projects {
                for output in project.commands {
                    self.progress.log_block(&selection.run.name, &output.stdout);
                    self.progress.log_block(&selection.run.name, &output.stderr);
                }
                if let Some(diagnostic) = project.diagnostic {
                    self.progress
                        .message(format!("Terraform {} · {diagnostic}", selection.run.name));
                }
            }
            self.terraform_status
                .push((selection.run.name.clone(), report_success));
            if !report_success {
                bail!("Terraform project {} failed", selection.run.name);
            }
        }
        Ok(())
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
            derivation,
            build_args,
        )?;
        self.builder_closures.insert(
            host.to_owned(),
            BuilderClosure {
                path: closure.clone(),
                derivation: derivation.clone(),
                build: build_args.clone(),
                protected_epoch,
            },
        );
        if matches!(self.invocation.action, Action::Build) {
            let pull = with_nix_sshopts(
                CommandSpec::new(
                    self.nix_program.to_string_lossy(),
                    [
                        "copy".to_owned(),
                        "--from".to_owned(),
                        store_uri,
                        closure.as_str().to_owned(),
                    ],
                ),
                &target,
            )?;
            let output = self.host_runtime.execute_local_command(
                &pull,
                EffectKind::Mutation,
                "remote-build-copy-closure-local",
            )?;
            if !output.succeeded() {
                bail!("copy remote build closure to local store failed for {host}");
            }
            let verified = self.host_runtime.execute_local_command(
                &closure_verification_command(&self.nix_program.to_string_lossy(), &closure),
                EffectKind::ReadOnly,
                "remote-build-verify-local-closure",
            )?;
            if !verified.succeeded() {
                bail!("verify copied remote build closure failed for {host}");
            }
            self.builder_closures.remove(host);
        }
        Ok(closure)
    }

    fn realize_protected_on_builder(
        &mut self,
        target: &HostExecutionTarget,
        lease_spec: &super::build_lease::LeaseProcessSpec,
        store_uri: &str,
        derivation: &NixStorePath,
        build_args: &BuildArgs,
    ) -> Result<(NixStorePath, LeaseEpoch)> {
        for _ in 0..self.settings.transport_retry_attempts {
            let before = self.builder_lease.ensure(lease_spec)?;
            let closure = self.realize_on_builder(target, store_uri, derivation, build_args)?;
            let after = self.builder_lease.ensure(lease_spec)?;
            if after.epoch == before.epoch || self.verify_builder_closure(target, &closure)? {
                return Ok((closure, after.epoch));
            }
        }
        bail!("builder lease changed repeatedly while realizing closure")
    }

    fn realize_on_builder(
        &mut self,
        target: &HostExecutionTarget,
        store_uri: &str,
        derivation: &NixStorePath,
        build_args: &BuildArgs,
    ) -> Result<NixStorePath> {
        let commands = plan_remote_build(&remote_build_tools()?, derivation, build_args);
        let copy_derivation = with_nix_sshopts(
            copy_derivation_command(&self.nix_program.to_string_lossy(), store_uri, derivation),
            target,
        )?;
        let execution = self.host_runtime.remote_build(RemoteBuildRequest {
            target: target.clone(),
            copy_derivation,
            build: commands.build,
            retry: RetryPolicy::new(
                self.settings.transport_retry_attempts,
                Duration::from_secs(self.settings.transport_retry_delay_seconds),
            )?,
        })?;
        if execution.status != super::build::CommandStatus::Success {
            bail!("remote build failed: {:?}", execution.status);
        }
        Ok(execution
            .output
            .context("remote build produced no output")?
            .path)
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
            "remote-build-verify-builder-closure",
        )?;
        Ok(output.succeeded())
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
                "primary deploy target {} has a temporary transport failure; bootstrap fallback is delayed: {}",
                resolved.inventory_name,
                evidence.trim()
            );
        }
        if resolved
            .operator_user
            .as_deref()
            .is_none_or(|user| user == resolved.user)
        {
            bail!(
                "primary deploy target {} is unavailable and no distinct operatorUser is configured: {}",
                resolved.inventory_name,
                evidence.trim()
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
            bail!(
                "primary deploy target {} is unavailable: {}",
                resolved.inventory_name,
                probe.combined_output().trim()
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
                &CommandSpec::new("true", Vec::<String>::new()),
                EffectKind::ReadOnly,
                "primary-connectivity-probe",
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
        let proxy = plan_proxy_chain(&transports, resolved.proxy_jump.as_deref())?;
        let proxy = if trim_leading_local_hops {
            proxy.with_leading_local_hops_trimmed()
        } else {
            proxy
        };
        let local = self.local_target(&resolved)?;
        let known_hosts_file = if local {
            None
        } else {
            Some(self.prepare_known_hosts(&resolved, &proxy)?)
        };
        let endpoint = primary_endpoint(&resolved)?;
        let route = if let Some(command) = &resolved.proxy_command {
            SshRoutePlan::via_command(endpoint, ProxyCommandTemplate::new(command.clone())?)
        } else if proxy.is_empty() {
            SshRoutePlan::direct(endpoint)
        } else {
            SshRoutePlan::via_chain(endpoint, proxy)
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
            if local {
                Ok(target)
            } else {
                target.with_control_master(
                    self.transport_store.path().join(format!(
                        "cm-{}-{}-{}",
                        safe_component(&resolved.inventory_name),
                        safe_component(&resolved.user),
                        resolved.port
                    )),
                    self.settings.ssh_control_persist_seconds,
                )
            }
        })
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
            let output = Command::new("ssh-keygen")
                .args(["-y", "-f"])
                .arg(&bootstrap)
                .output()
                .with_context(|| {
                    format!(
                        "derive bootstrap public key for {}",
                        resolved.inventory_name
                    )
                })?;
            if !output.status.success() || output.stdout.is_empty() {
                bail!(
                    "unable to derive bootstrap public key for {}",
                    resolved.inventory_name
                );
            }
            std::fs::write(&public, output.stdout)?;
            std::fs::set_permissions(&public, std::fs::Permissions::from_mode(0o600))?;
        }
        let component = format!(
            "{}.{}",
            safe_component(&resolved.inventory_name),
            self.invocation_id
        );
        let remote_key = PathBuf::from(format!("/tmp/nixbot-bootstrap-key.{component}"));
        let remote_public = PathBuf::from(format!("/tmp/nixbot-bootstrap-public.{component}"));
        for (source, destination, label) in [
            (&bootstrap, &remote_key, "bootstrap-private-key-upload"),
            (&public, &remote_public, "bootstrap-public-key-upload"),
        ] {
            let uploaded = self.host_runtime.upload_file_to_remote(
                &operator_target,
                source,
                destination,
                label,
            )?;
            if !uploaded.succeeded() {
                bail!(
                    "{label} failed for {}: {}",
                    resolved.inventory_name,
                    uploaded.stderr.trim()
                );
            }
        }
        let install = bootstrap_install_command(&remote_key, &remote_public)?;
        let installed = self.host_runtime.execute_remote_command(
            &operator_target,
            &install,
            EffectKind::Mutation,
            "bootstrap-key-install",
        )?;
        if !installed.succeeded() {
            bail!(
                "bootstrap key installation failed for {}: {}",
                resolved.inventory_name,
                installed.stderr.trim()
            );
        }
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
        let uploaded = self.host_runtime.upload_file_to_remote(
            target,
            &materialized,
            &remote,
            "host-age-identity-upload",
        )?;
        if !uploaded.succeeded() {
            bail!(
                "host age identity upload failed for {}: {}",
                resolved.inventory_name,
                uploaded.stderr.trim()
            );
        }
        let installed = self.host_runtime.execute_remote_command(
            target,
            &host_age_identity_install_command(&remote, &expected_hash)?,
            EffectKind::Mutation,
            "host-age-identity-install",
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
                let operator = host
                    .operator_user
                    .clone()
                    .map(|user| {
                        SshEndpoint::new(
                            host.inventory_name.clone(),
                            host.target.clone(),
                            user,
                            host.operator_port,
                            TransportRole::Operator,
                            host.operator_key.clone(),
                        )
                    })
                    .transpose()?;
                let proxy_command = host
                    .proxy_command
                    .clone()
                    .map(ProxyCommandTemplate::new)
                    .transpose()?;
                let local = self.local_target(&host)?;
                Ok((
                    name.clone(),
                    HostTransport {
                        primary: primary_endpoint(&host)?,
                        operator,
                        proxy_jump: host.proxy_jump,
                        proxy_command,
                        local,
                    },
                ))
            })
            .collect()
    }

    fn local_target(&self, host: &ResolvedHost) -> Result<bool> {
        let mode = match self.settings.local_self_target {
            LocalSelfTarget::Auto => SelfTargetMode::Auto,
            LocalSelfTarget::On => SelfTargetMode::On,
            LocalSelfTarget::Off => SelfTargetMode::Off,
        };
        if mode == SelfTargetMode::Off {
            return Ok(false);
        }
        let mut aliases = BTreeSet::from([
            "localhost".to_owned(),
            "127.0.0.1".to_owned(),
            "::1".to_owned(),
        ]);
        for arguments in [vec!["-s"], Vec::new(), vec!["-f"]] {
            if let Ok(output) = run_output(
                self.repository,
                &CommandSpec::new("hostname", arguments.into_iter().map(str::to_owned)),
            ) && output.status.success()
            {
                for alias in String::from_utf8_lossy(&output.stdout).split_whitespace() {
                    aliases.insert(alias.to_owned());
                    aliases.insert(alias.split('.').next().unwrap_or(alias).to_owned());
                }
            }
        }
        let target = host.target.trim_start_matches('[').trim_end_matches(']');
        let target_short = target.split('.').next().unwrap_or(target);
        let alias_matches = aliases.contains(target) || aliases.contains(target_short);
        let mut local_addresses = BTreeSet::from(["127.0.0.1".to_owned(), "::1".to_owned()]);
        if let Ok(output) = run_output(
            self.repository,
            &CommandSpec::new("ip", ["-o", "addr", "show", "up"].map(str::to_owned)),
        ) && output.status.success()
        {
            for line in String::from_utf8_lossy(&output.stdout).lines() {
                if let Some(address) = line.split_whitespace().nth(3) {
                    local_addresses.insert(address.split('/').next().unwrap_or(address).to_owned());
                }
            }
        }
        let resolved = run_output(
            self.repository,
            &CommandSpec::new("getent", ["ahosts".to_owned(), target.to_owned()]),
        );
        let address_matches = is_ip_address(target) && local_addresses.contains(target)
            || resolved.is_ok_and(|output| {
                output.status.success()
                    && String::from_utf8_lossy(&output.stdout)
                        .lines()
                        .filter_map(|line| line.split_whitespace().next())
                        .any(|address| local_addresses.contains(address))
            });
        let uid = run_output(self.repository, &CommandSpec::new("id", ["-u".to_owned()]))?;
        let user = run_output(self.repository, &CommandSpec::new("id", ["-un".to_owned()]))?;
        if !uid.status.success() || !user.status.success() {
            return Ok(false);
        }
        let evidence = SelfTargetEvidence {
            alias_matches,
            address_matches,
            effective_uid: String::from_utf8_lossy(&uid.stdout)
                .trim()
                .parse()
                .context("local effective uid is not an unsigned integer")?,
            current_user: String::from_utf8_lossy(&user.stdout).trim().to_owned(),
            deploy_user: host.user.clone(),
        };
        Ok(plan_self_target(mode, &evidence) == SelfTargetDecision::Local)
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
            return Ok(destination);
        }
        let identities = age_identities(&self.invocation.options);
        if identities.is_empty() {
            bail!("no age identity is configured to decrypt the {role} SSH key for {host}");
        }
        let mut last_status = None;
        for identity in identities.into_iter().filter(|path| path.is_file()) {
            let status = Command::new("age")
                .args(["--decrypt", "-i"])
                .arg(&identity)
                .arg("-o")
                .arg(&destination)
                .arg(&source)
                .status()
                .with_context(|| format!("decrypt {role} SSH key for {host}"))?;
            last_status = status.code();
            if status.success() {
                std::fs::set_permissions(&destination, std::fs::Permissions::from_mode(0o600))?;
                return Ok(destination);
            }
            let _ = std::fs::remove_file(&destination);
        }
        bail!(
            "unable to decrypt the {role} SSH key for {host} (last status {:?})",
            last_status
        )
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

    fn prepare_known_hosts(
        &self,
        host: &ResolvedHost,
        proxy: &super::transport::ProxyPlan,
    ) -> Result<PathBuf> {
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
        let scan_host = if host.proxy_command.is_some() {
            None
        } else if let Some(first) = proxy.hops.first() {
            Some((&first.endpoint.host, first.endpoint.port))
        } else {
            Some((&host.target, host.port))
        };
        let mut contents = Vec::new();
        if let Some((target, port)) = scan_host {
            for algorithm in [Some("ed25519"), None] {
                let mut command = Command::new("ssh-keyscan");
                command.args([
                    "-T",
                    &self.settings.ssh_connect_timeout_seconds.to_string(),
                    "-p",
                    &port.to_string(),
                ]);
                if let Some(algorithm) = algorithm {
                    command.args(["-t", algorithm]);
                }
                let output = command
                    .arg(target)
                    .current_dir(self.repository)
                    .output()
                    .with_context(|| format!("scan SSH host key for {target}"))?;
                if output.status.success() && !output.stdout.is_empty() {
                    contents = output.stdout;
                    break;
                }
            }
            if contents.is_empty() {
                bail!("could not determine SSH host key for {target}:{port}");
            }
        }
        let mut file = OpenOptions::new()
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
        file.write_all(&contents)?;
        Ok(path)
    }

    fn run_snapshot_phase(&mut self) -> Result<()> {
        let mut tasks = Vec::new();
        let snapshot_order = self.selection.ordered.clone();
        for host in &snapshot_order {
            let policy = self.inventory.hosts[host].deploy;
            if policy == DeployMode::Skip
                || self.invocation.options.dry_run
                || self.invocation.options.no_rollback
            {
                self.snapshots.insert(
                    host.clone(),
                    super::deploy::GenerationSnapshot::not_requested(),
                );
                continue;
            }
            let resolved = resolve_host(self.inventory, host, &self.invocation.options)?;
            let target = self.execution_target(&resolved)?;
            tasks.push((host.clone(), policy, target));
        }
        let repository = self.repository.to_path_buf();
        let progress = self.progress.clone();
        let snapshots = super::orchestration::bounded_parallel_map(
            tasks,
            self.invocation.options.deploy_jobs,
            |(host, policy, target)| -> Result<_> {
                let mut runtime = HostRuntime::new(
                    reporting_process_runner(&progress),
                    repository.clone(),
                    DryRun::No,
                )?;
                Ok((host, policy, runtime.snapshot(&target)?))
            },
        )?;
        let mut failures = Vec::new();
        for snapshot in snapshots {
            let (host, policy, snapshot) = snapshot?;
            if snapshot.generation().is_none() && policy == DeployMode::Strict {
                failures.push(host.clone());
                self.snapshot_failed.insert(host.clone());
            }
            self.snapshots.insert(host, snapshot);
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
        let resolved = resolve_host(self.inventory, host, &self.invocation.options)?;
        let build_host = self.build_host();
        if build_host == "local" {
            let target = self.execution_target(&resolved)?;
            let command = with_nix_sshopts(
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
                &target,
            )?;
            let output = self.host_runtime.execute_local_command(
                &command,
                EffectKind::Mutation,
                "deploy-copy-closure",
            )?;
            if !output.succeeded() {
                bail!("copy closure to {host} failed: {}", output.stderr.trim());
            }
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
        match plan {
            DistributionPlan::RelayThroughLocal { .. } => {
                let target = self.primary_execution_target(resolved)?;
                self.host_runtime.distribute_closure(&target, plan, retry)
            }
            DistributionPlan::TryTargetCacheThenRelay { closure, cache } => {
                let target = self.execution_target(resolved)?;
                let direct = DistributionPlan::TargetCachePull {
                    closure: closure.clone(),
                    cache: cache.clone(),
                    retry: false,
                };
                let result = match self
                    .host_runtime
                    .distribute_closure(&target, &direct, retry)?
                {
                    DistributionExecution::Failed(super::build::CommandStatus::Exit(_)) => {
                        let primary = self.primary_execution_target(resolved)?;
                        self.host_runtime.distribute_closure(
                            &primary,
                            &DistributionPlan::RelayThroughLocal {
                                closure: closure.clone(),
                                cache: cache.clone(),
                            },
                            retry,
                        )?
                    }
                    result => result,
                };
                Ok(result)
            }
            _ => {
                let target = self.execution_target(resolved)?;
                self.host_runtime.distribute_closure(&target, plan, retry)
            }
        }
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
            let mut recovered_epoch = observation.epoch;
            if !self.verify_builder_closure(&target, &closure.path)? {
                let store_uri = ssh_store_uri(builder)?;
                let (rebuilt, rebuilt_epoch) = self.realize_protected_on_builder(
                    &target,
                    &lease_spec,
                    &store_uri,
                    &closure.derivation,
                    &closure.build,
                )?;
                if rebuilt != closure.path {
                    bail!(
                        "recovered remote build for {host} produced {}, expected {}",
                        rebuilt.as_str(),
                        closure.path.as_str()
                    );
                }
                recovered_epoch = rebuilt_epoch;
            }
            let confirmed = self.builder_lease.ensure(&lease_spec)?;
            if confirmed.epoch != recovered_epoch {
                bail!("builder lease changed repeatedly while recovering {host}");
            }
            closure.protected_epoch = confirmed.epoch;
            self.builder_closures.insert(host.to_owned(), closure);
            return Ok(confirmed.epoch);
        }
        Ok(observation.epoch)
    }

    fn ensure_wave_parent_readiness(&mut self, wave: &[String]) -> Result<()> {
        for host in wave {
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
            for (label, command, effect) in [
                (
                    "parent-reconcile",
                    &commands.reconcile,
                    EffectKind::Mutation,
                ),
                ("parent-settle", &commands.settle, EffectKind::ReadOnly),
            ] {
                let command = CommandSpec::new(command.program.clone(), command.args.clone());
                let output = self
                    .host_runtime
                    .execute_remote_command(&target, &command, effect, label)?;
                if !output.succeeded() {
                    bail!(
                        "{label} failed for {host} through {parent}: {}",
                        output.stderr.trim()
                    );
                }
            }
        }
        Ok(())
    }

    fn deploy_one(&mut self, host: &str) -> Result<()> {
        let policy = self.inventory.hosts[host].deploy;
        let closure = self
            .closures
            .get(host)
            .cloned()
            .with_context(|| format!("missing built closure for {host}"))?;
        let desired = super::deploy::SystemGeneration::parse(closure.as_str())?;
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
                return Ok(());
            }
            super::deploy::DeployDecision::SkipOptionalMissing => {
                self.optional_snapshot_skipped.insert(host.to_owned());
                return Ok(());
            }
            super::deploy::DeployDecision::RefuseRequiredMissing => {
                bail!("required generation snapshot is unavailable for {host}")
            }
            super::deploy::DeployDecision::Deploy { .. } => {}
        }
        self.distribute_for_deploy(host, &closure)?;
        let resolved = resolve_host(self.inventory, host, &self.invocation.options)?;
        let target = self.execution_target(&resolved)?;
        self.ensure_host_age_identity(&resolved, &target)?;
        let image_pull = super::deploy::pre_activation_image_pull_command(&desired);
        let image_pull = CommandSpec::new(image_pull.program, image_pull.args);
        let pulled = self.host_runtime.execute_remote_command(
            &target,
            &image_pull,
            EffectKind::Mutation,
            "pre-activation-image-pull",
        )?;
        if !pulled.succeeded() {
            bail!(
                "pre-activation image pull failed for {host}: {}",
                pulled.stderr.trim()
            );
        }
        let admitted = self
            .host_runtime
            .pre_switch(&target, &super::deploy::pre_switch_admission_command())?;
        if !admitted.succeeded() {
            bail!(
                "pre-switch admission failed for {host}: {}",
                admitted.stderr.trim()
            );
        }
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
            runtime_max: Duration::from_secs(self.settings.remote_activation_runtime_max_seconds),
            stop_timeout: Duration::from_secs(self.settings.remote_activation_stop_timeout_seconds),
            lock_wait: Duration::from_secs(self.settings.state_lock_timeout_seconds),
        });
        match self
            .host_runtime
            .activate(&target, &activation, &desired, goal, "activation")?
        {
            ActivationExecution::Succeeded | ActivationExecution::SucceededAfterVerification => {
                self.activated.insert(host.to_owned());
                self.successful.insert(host.to_owned());
            }
            ActivationExecution::DryRun => {}
            ActivationExecution::Failed { admitted, status } => {
                self.deploy_failed.insert(host.to_owned());
                if admitted {
                    self.activated.insert(host.to_owned());
                    self.pending_rollback.insert(host.to_owned());
                }
                bail!("activation failed for {host}: {status:?}");
            }
        }
        let wait = self.inventory.hosts[host].wait;
        if wait > 0 {
            self.host_runtime.wait(Duration::from_secs(wait));
            super::signal::check_interrupted()?;
        }
        Ok(())
    }

    fn run_deploy_phase(&mut self) -> Result<()> {
        if self.invocation.options.dry_run {
            return Ok(());
        }
        'waves: for wave in self.selection.waves.clone() {
            if let Err(error) = self.ensure_wave_parent_readiness(&wave) {
                self.deploy_failures
                    .push(format!("parent readiness: {error:#}"));
                break;
            }
            let runnable = wave
                .into_iter()
                .filter(|host| self.inventory.hosts[host].deploy != DeployMode::Skip)
                .collect::<Vec<_>>();
            for chunk in runnable.chunks(self.invocation.options.deploy_jobs) {
                let tasks = chunk
                    .iter()
                    .map(|host| {
                        Ok((
                            host.clone(),
                            self.closures
                                .get(host)
                                .cloned()
                                .with_context(|| format!("missing built closure for {host}"))?,
                            self.snapshots.get(host).cloned().with_context(|| {
                                format!("missing generation snapshot for {host}")
                            })?,
                            self.builder_closures.get(host).cloned(),
                        ))
                    })
                    .collect::<Result<Vec<_>>>()?;
                let invocation = self.invocation;
                let nix_program = self.nix_program;
                let repository = self.repository;
                let inventory = self.inventory;
                let selection = self.selection;
                let invocation_id = self.invocation_id.clone();
                let builder_lease = Arc::clone(&self.builder_lease);
                let diagnostic_dir = self.diagnostic_dir.clone();
                let outcomes = super::orchestration::bounded_parallel_map(
                    tasks,
                    self.invocation.options.deploy_jobs,
                    |(host, closure, snapshot, builder_closure)| {
                        let policy = inventory.hosts[&host].deploy;
                        let mut worker = match NativeFleetEffects::new_with_diagnostics(
                            invocation,
                            nix_program,
                            repository,
                            inventory,
                            selection,
                            diagnostic_dir.as_deref(),
                        ) {
                            Ok(worker) => worker,
                            Err(error) => {
                                return DeployTaskOutcome {
                                    host,
                                    policy,
                                    result: Err(error),
                                    activated: false,
                                    successful: false,
                                    pending_rollback: false,
                                    deploy_skipped: false,
                                    optional_snapshot_skipped: false,
                                    deploy_failed: true,
                                    rollback_succeeded: false,
                                    rollback_failed: false,
                                };
                            }
                        };
                        worker.invocation_id = invocation_id.clone();
                        worker.builder_lease = Arc::clone(&builder_lease);
                        worker.closures.insert(host.clone(), closure);
                        if let Some(builder_closure) = builder_closure {
                            worker
                                .builder_closures
                                .insert(host.clone(), builder_closure);
                        }
                        worker.snapshots.insert(host.clone(), snapshot);
                        let mut result = worker.deploy_one(&host);
                        if result.is_err()
                            && policy == DeployMode::Optional
                            && worker.pending_rollback.contains(&host)
                            && !invocation.options.no_rollback
                            && let Err(rollback) = worker.rollback_activated()
                        {
                            result = Err(anyhow::anyhow!(
                                "{}; optional rollback also failed: {rollback:#}",
                                result.expect_err("checked deploy failure")
                            ));
                        }
                        DeployTaskOutcome {
                            activated: worker.activated.contains(&host),
                            successful: worker.successful.contains(&host),
                            pending_rollback: worker.pending_rollback.contains(&host),
                            deploy_skipped: worker.deploy_skipped.contains(&host),
                            optional_snapshot_skipped: worker
                                .optional_snapshot_skipped
                                .contains(&host),
                            deploy_failed: result.is_err(),
                            rollback_succeeded: worker.rollback_succeeded.contains(&host),
                            rollback_failed: worker.rollback_failed.contains(&host),
                            host,
                            policy,
                            result,
                        }
                    },
                )?;
                let mut required_failed = false;
                for outcome in outcomes {
                    if outcome.activated {
                        self.activated.insert(outcome.host.clone());
                    }
                    if outcome.successful {
                        self.successful.insert(outcome.host.clone());
                    }
                    if outcome.pending_rollback {
                        self.pending_rollback.insert(outcome.host.clone());
                    }
                    if outcome.deploy_skipped {
                        self.deploy_skipped.insert(outcome.host.clone());
                    }
                    if outcome.optional_snapshot_skipped {
                        self.optional_snapshot_skipped.insert(outcome.host.clone());
                    }
                    if outcome.deploy_failed {
                        self.deploy_failed.insert(outcome.host.clone());
                    }
                    if outcome.rollback_succeeded {
                        self.rollback_succeeded.insert(outcome.host.clone());
                    }
                    if outcome.rollback_failed {
                        self.rollback_failed.insert(outcome.host.clone());
                    }
                    if let Err(error) = outcome.result {
                        if outcome.policy == DeployMode::Optional {
                            self.progress.message(format!(
                                "Optional deploy failed · {} · {error:#}",
                                outcome.host
                            ));
                        } else {
                            self.deploy_failures
                                .push(format!("{}: {error:#}", outcome.host));
                            required_failed = true;
                        }
                    }
                }
                if required_failed {
                    break 'waves;
                }
            }
        }
        // Every completed target has independently verified its closure. Any
        // remaining host causes this invocation to fail rather than depending
        // on the builder during health or rollback.
        self.builder_lease.release();
        Ok(())
    }

    fn run_health_phase(&mut self) -> Result<()> {
        let mut failures = self.deploy_failures.clone();
        if !self.invocation.options.no_verify && !self.invocation.options.dry_run {
            let mut tasks = Vec::new();
            for host in self.successful.clone() {
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
                        self.pending_rollback.insert(host.clone());
                        failures.push(format!(
                            "{host}: post-switch health transport failed: {error:#}"
                        ));
                    }
                }
            }
            let repository = self.repository.to_path_buf();
            let progress = self.progress.clone();
            let checked = super::orchestration::bounded_parallel_map(
                tasks,
                self.invocation.options.verify_jobs,
                |(host, target, ignored_system_units)| {
                    let result = (|| -> Result<super::health_runtime::ManagedHealthReport> {
                        let mut runtime = HostRuntime::new(
                            reporting_process_runner(&progress),
                            repository.clone(),
                            DryRun::No,
                        )?;
                        super::health_runtime::check_managed_health_with_ignored_system_units(
                            &mut runtime,
                            &target,
                            &ignored_system_units,
                        )
                    })();
                    (host, result)
                },
            )?;
            for (host, checked) in checked {
                match checked {
                    Ok(report) => {
                        for failure in &report.ignored_system_failures {
                            self.progress
                                .detail(format!("{host} · health ignored system unit · {failure}"));
                        }
                        match report.decision {
                            super::health::HealthDecision::Healthy { .. } => {
                                self.progress.detail(format!(
                                    "{host} · health ok · {} attempt{}",
                                    report.attempts,
                                    if report.attempts == 1 { "" } else { "s" }
                                ));
                            }
                            super::health::HealthDecision::Settling { .. } => {
                                self.health_failed.insert(host.clone());
                                failures.push(format!(
                                    "{host}: post-switch health is still settling: {}",
                                    report.details.join("; ")
                                ));
                            }
                            super::health::HealthDecision::ServiceFailure { .. } => {
                                self.health_failed.insert(host.clone());
                                failures.push(format!(
                                    "{host}: post-switch service health failed: {}",
                                    report.details.join("; ")
                                ));
                            }
                            super::health::HealthDecision::StructuralFailure { .. } => {
                                self.health_failed.insert(host.clone());
                                self.pending_rollback.insert(host.clone());
                                failures.push(format!(
                                    "{host}: post-switch structural health failed: {}",
                                    report.details.join("; ")
                                ));
                            }
                        }
                    }
                    Err(error) => {
                        self.health_failed.insert(host.clone());
                        self.pending_rollback.insert(host.clone());
                        failures.push(format!(
                            "{host}: post-switch health probe failed: {error:#}"
                        ));
                    }
                }
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            bail!("fleet deployment failed: {}", failures.join("; "))
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
            let output = Command::new("ssh-keygen")
                .args(["-lf"])
                .arg(&materialized)
                .output()
                .with_context(|| format!("inspect bootstrap key for {host}"))?;
            if !output.status.success() {
                self.bootstrap_failed.insert(host.clone());
                failures.push(format!("{host}: bootstrap key is unreadable"));
                continue;
            }
            let fingerprint = String::from_utf8_lossy(&output.stdout)
                .split_whitespace()
                .nth(1)
                .unwrap_or_default()
                .to_owned();
            if fingerprint.is_empty() {
                self.bootstrap_failed.insert(host.clone());
                failures.push(format!("{host}: bootstrap key has no fingerprint"));
            } else {
                self.progress
                    .detail(format!("{host} · bootstrap key valid · {fingerprint}"));
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            bail!("bootstrap key checks failed: {}", failures.join("; "))
        }
    }

    fn boot_environment(&self, host: &str) -> Result<super::deploy::BootEnvironment> {
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
                    );
                    match self.host_runtime.activate(
                        &target,
                        &command,
                        &generation,
                        super::deploy::ActivationGoal::Switch,
                        "rollback",
                    )? {
                        ActivationExecution::Succeeded
                        | ActivationExecution::SucceededAfterVerification
                        | ActivationExecution::DryRun => Ok(()),
                        ActivationExecution::Failed { status, .. } => {
                            bail!("rollback activation failed: {status:?}")
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

fn action_summary_label(action: &Action) -> &str {
    match action {
        Action::Run => "run",
        Action::Deploy => "deploy",
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

fn reporting_process_runner(progress: &FleetProgress) -> ReportingProcessRunner {
    let runner = ReportingProcessRunner::new(progress.process_observer());
    match super::signal::runtime() {
        Some(cancellation) => runner.with_cancellation(cancellation),
        None => runner,
    }
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

fn primary_endpoint(host: &ResolvedHost) -> Result<SshEndpoint> {
    SshEndpoint::new(
        host.inventory_name.clone(),
        host.target.clone(),
        host.user.clone(),
        host.port,
        TransportRole::Primary,
        host.identity_key.clone(),
    )
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

fn quote_nix_sshopts(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn with_nix_sshopts(command: CommandSpec, target: &HostExecutionTarget) -> Result<CommandSpec> {
    let options = ssh_connection_args(target)?;
    let rendered = options
        .iter()
        .map(|option| quote_nix_sshopts(option))
        .collect::<Vec<_>>()
        .join(" ");
    let mut args = vec![format!("NIX_SSHOPTS={rendered}"), command.program];
    args.extend(command.args);
    Ok(CommandSpec::new("env", args))
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
        let host_count = self.selection.ordered.len();
        self.progress.phase_started(phase, host_count);
        let result = match phase {
            Phase::TerraformDns | Phase::TerraformPlatform | Phase::TerraformApps | Phase::Tofu => {
                self.run_terraform_phase(phase)
            }
            Phase::Build => self.run_build_phase(false),
            Phase::Snapshot => self.run_snapshot_phase(),
            Phase::Deploy => self.run_deploy_phase(),
            Phase::Health => self.run_health_phase(),
            Phase::DevelopmentBuild => self.run_build_phase(true),
            Phase::BootstrapCheck => self.run_bootstrap_check_phase(),
            other => Err(anyhow::anyhow!("native phase {other:?} is not integrated")),
        };
        match result {
            Ok(()) => {
                self.progress
                    .phase_completed(phase, host_count, started.elapsed());
                Ok(())
            }
            Err(error) => {
                let message = format!("{error:#}");
                self.progress
                    .phase_failed(phase, host_count, started.elapsed(), &message);
                Err(PhaseFailure::new(phase, message))
            }
        }
    }

    fn rollback(&mut self, failed_phase: Phase) -> Result<()> {
        if !matches!(failed_phase, Phase::Deploy | Phase::Health) {
            bail!("rollback is not valid for phase {failed_phase:?}");
        }
        self.rollback_activated()
    }
}

fn run_output(
    repository: &Path,
    command: &super::build::CommandSpec,
) -> Result<std::process::Output> {
    Command::new(&command.program)
        .args(&command.args)
        .current_dir(repository)
        .output()
        .with_context(|| format!("execute {}", command.program))
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
        Action::Run | Action::Deploy | Action::Build | Action::DevBuild | Action::CheckBootstrap
    )
}
