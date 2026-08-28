use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::io::{self, IsTerminal, Read, Write};
use std::os::unix::fs::FileTypeExt;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use abird_host_agent::instance::{
    IncusCopyMode, InstanceMigrationPhase, InstanceMigrationPolicy, InstanceMigrationRequest,
    RuntimeStateMode, SeedConsistency,
};
use abird_host_agent::job::{projected_hold_job_id, projected_release_job_id};
use abird_host_agent::sha256::digest_bytes;
use abird_host_agent::transfer::{TransferDefinition, transfer_with_excludes_progress};
use abird_host_manager::agent_adapter::{
    HostManagerConfig, NativeAdapter, RenderedInventoryCommandFailure, WorkflowItemAdapter,
    declared_data_roots, format_job_progress, instance_resource, run_local_nixbot_deploy,
};
use abird_host_manager::backup_runtime::{
    ArtifactDeletionStatus, BackupArtifact, BackupPhase, BackupRecord, BackupStore,
    InstanceExportLocation, RestorePhase,
};
use abird_host_manager::instance_backup::{self, InstanceBackupContext};
use abird_host_manager::physical::{
    BootMode, HardwareProjection, PartitionSize, PhysicalLayoutRequest,
};
use abird_host_manager::presentation::{
    CommandPresentation, OutputContract, PresentationKind, render as render_presentation,
};
use abird_host_manager::programs::nixos_generate_config::NixosGenerateConfig;
use abird_host_manager::programs::privilege::Privilege;
use abird_host_manager::progress::{command_reporter, json_output, set_json_output};
use abird_host_manager::projection::{
    MoveItemObservation, MovePhase, MoveProjectionObservation, MoveProjector, PhaseProjection,
    ResourceHoldIntent, ResourceHoldPhase, ResourceHoldProjector, canonical_sha256,
};
use abird_host_manager::repository::{
    CanonicalProjectionCloseout, ManagedHost, ManagedHostSystem, ManagedIncus,
    ProjectionCleanupEvent, ProjectionCleanupStage, ProjectionCloseoutEvent,
    ProjectionCloseoutPublication, ProjectionCloseoutStage, ProjectionPublication,
    ProjectionPublicationEvent, ProjectionPublicationMode, ProjectionPublicationStage,
    ProjectionPublisher, Repository, RepositoryPrograms, is_nix_native_service_move,
};
use abird_host_manager::selector::select_hosts;
use abird_host_manager::service_registry::{resolve_service_host, resolve_service_resource};
use abird_host_manager::terminal_style::{TerminalStyle, Tone};
use abird_host_manager::workflow::{
    BackupDestination, BackupItem, BackupSpec, HostEndpoint, InstanceBackupPolicy,
    InstanceEndpoint, InstanceMovePolicy, MoveItem, TransactionSpec, wipe_id,
};
use abird_host_manager::workflow_runtime::{
    ActivationAuthorization, CloseDecision, CommandStatus, InitialMoveContinuation,
    LifecycleCommand, LifecycleState, StepStatus, TransactionRecord, WorkflowRegistration,
    WorkflowStore, begin_workflow_action, execute_workflow_action, execute_workflow_action_until,
    has_pending_close_workflow_action, plan_terminal_failed_run_for_prepare, plan_workflow_action,
    preflight_new_workflow, preflight_workflow_action, supersede_failed_workflow_jobs,
    supersede_terminal_failed_run_for_prepare, supersede_terminal_failed_workflow_jobs,
    validate_failed_workflow_jobs,
};
use abird_host_manager::{Action, Phase as ItemPhase, deterministic_job_id};
use anyhow::{Context, Result, bail};
use clap::{Args, Parser, Subcommand, ValueEnum};
use serde::Serialize;
use serde_json::{Value, json};

static COMMAND_PRESENTATION: OnceLock<CommandPresentation> = OnceLock::new();

#[derive(Debug, Parser)]
#[command(version, about)]
struct Cli {
    /// Emit one stable JSON document instead of human-readable output.
    #[arg(long, global = true, help_heading = "Global options")]
    json: bool,

    /// Keep the controller, journal, commits, and deployment source in this checkout; never push.
    #[arg(
        long,
        global = true,
        conflicts_with = "local_run",
        help_heading = "Global options"
    )]
    local: bool,

    /// Durable manager state directory.
    #[arg(
        long,
        global = true,
        env = "ABIRD_HOST_MANAGER_STATE_DIR",
        conflicts_with = "local_run",
        help_heading = "Global options"
    )]
    state_dir: Option<PathBuf>,

    /// Execute stateful commands locally and keep state under .agents/runs/NAME.
    #[arg(
        long,
        global = true,
        value_name = "NAME",
        conflicts_with_all = ["controller", "state_dir"],
        help_heading = "Global options"
    )]
    local_run: Option<String>,

    /// Workflow controller host resource, inventory name, or "local".
    #[arg(
        long,
        global = true,
        env = "ABIRD_HOST_MANAGER_CONTROLLER",
        value_name = "HOST|local",
        conflicts_with = "local_run",
        help_heading = "Global options"
    )]
    controller: Option<String>,

    /// Native configuration; defaults to hosts/nixbot.nix in the enclosing Abird repository.
    #[arg(
        long,
        global = true,
        env = "ABIRD_HOST_MANAGER_CONFIG",
        help_heading = "Global options"
    )]
    config: Option<PathBuf>,

    /// Abird repository root for config discovery and declarative host lifecycle operations.
    #[arg(
        long,
        global = true,
        env = "ABIRD_HOST_MANAGER_REPO_ROOT",
        help_heading = "Global options"
    )]
    repo_root: Option<PathBuf>,

    /// Nix executable used by repository host lifecycle operations.
    #[arg(
        long,
        global = true,
        env = "ABIRD_HOST_MANAGER_NIX",
        default_value = "/run/current-system/sw/bin/nix",
        help_heading = "Global options"
    )]
    nix_program: PathBuf,

    /// Non-interactive privilege executable used by live installation.
    #[arg(
        long,
        global = true,
        env = "ABIRD_HOST_MANAGER_PRIVILEGE",
        default_value = "/run/wrappers/bin/sudo",
        help_heading = "Global options"
    )]
    privilege_program: PathBuf,

    /// NixOS installer executable invoked through the privilege program.
    #[arg(
        long,
        global = true,
        env = "ABIRD_HOST_MANAGER_NIXOS_INSTALL",
        default_value = "/run/current-system/sw/bin/nixos-install",
        help_heading = "Global options"
    )]
    nixos_install_program: PathBuf,

    /// Hardware probe executable used by physical host generation.
    #[arg(
        long,
        global = true,
        env = "ABIRD_HOST_MANAGER_NIXOS_GENERATE_CONFIG",
        default_value = "/run/current-system/sw/bin/nixos-generate-config",
        help_heading = "Global options"
    )]
    nixos_generate_config_program: PathBuf,

    /// Git executable used only by the manager-owned projection publisher.
    #[arg(
        long,
        global = true,
        env = "ABIRD_HOST_MANAGER_GIT",
        default_value = "git",
        help_heading = "Global options"
    )]
    git_program: PathBuf,

    /// SSH command reserved for authenticated projection publication.
    #[arg(
        long,
        global = true,
        env = "ABIRD_HOST_MANAGER_PUBLISH_GIT_SSH_COMMAND",
        hide = true
    )]
    publish_git_ssh_command: Option<String>,

    /// Authoritative fast-forward branch for migration projections.
    #[arg(
        long,
        global = true,
        env = "ABIRD_HOST_MANAGER_PROJECTION_BRANCH",
        default_value = "master",
        help_heading = "Global options"
    )]
    projection_branch: String,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Run durable infrastructure-instance operations on an Incus controller agent.
    Instance {
        #[command(subcommand)]
        command: InstanceCommand,
    },
    /// Inspect or continue a durable migration transaction.
    Transaction {
        #[command(subcommand)]
        command: TransactionCommand,
    },
    /// Inspect inventory or run a command through native SSH transport.
    Host {
        #[command(subcommand)]
        command: HostCommand,
    },
    /// Operate one declared logical service.
    Service {
        #[command(subcommand)]
        command: ServiceCommand,
    },
    /// Operate one explicit systemd unit without repository service discovery.
    Unit {
        #[command(subcommand)]
        command: UnitCommand,
    },
    /// Operate one declared resource through the host agent.
    Resource {
        #[command(subcommand)]
        command: ResourceCommand,
    },
    /// Create and inspect durable backup records.
    Backup {
        #[command(subcommand)]
        command: BackupCommand,
    },
    /// Inspect and explicitly retry durable host-agent jobs.
    Job {
        #[command(subcommand)]
        command: JobCommand,
    },
}

#[derive(Debug, Subcommand)]
enum InstanceCommand {
    /// Move one or more whole Incus instances through durable explicit phases.
    Move(InstanceMoveArgs),
    /// Seed or finalize an Incus snapshot/copy/refresh between arbitrary locations.
    #[command(hide = true)]
    Sync(InstanceSyncArgs),
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum InstancePhase {
    Seed,
    Prepare,
}

impl From<InstancePhase> for InstanceMigrationPhase {
    fn from(value: InstancePhase) -> Self {
        match value {
            InstancePhase::Seed => Self::Seed,
            InstancePhase::Prepare => Self::Final,
        }
    }
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum InstanceCopyMode {
    Pull,
    Push,
    Relay,
}

impl From<InstanceCopyMode> for IncusCopyMode {
    fn from(value: InstanceCopyMode) -> Self {
        match value {
            InstanceCopyMode::Pull => Self::Pull,
            InstanceCopyMode::Push => Self::Push,
            InstanceCopyMode::Relay => Self::Relay,
        }
    }
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum InstanceSeedConsistency {
    Strict,
    AllowInconsistent,
}

impl From<InstanceSeedConsistency> for SeedConsistency {
    fn from(value: InstanceSeedConsistency) -> Self {
        match value {
            InstanceSeedConsistency::Strict => Self::Strict,
            InstanceSeedConsistency::AllowInconsistent => Self::AllowInconsistent,
        }
    }
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum InstanceRuntimeState {
    Discard,
    Preserve,
}

impl From<InstanceRuntimeState> for RuntimeStateMode {
    fn from(value: InstanceRuntimeState) -> Self {
        match value {
            InstanceRuntimeState::Discard => Self::Discard,
            InstanceRuntimeState::Preserve => Self::Preserve,
        }
    }
}

#[derive(Debug, Args)]
struct InstanceSyncArgs {
    /// Inventory host whose durable host-agent owns the Incus client operation.
    #[arg(long)]
    controller: String,
    #[arg(long)]
    source_instance: String,
    #[arg(long)]
    target_instance: String,
    #[arg(long, default_value = "local")]
    source_remote: String,
    #[arg(long, default_value = "local")]
    target_remote: String,
    #[arg(long, default_value = "default")]
    source_project: String,
    #[arg(long, default_value = "default")]
    target_project: String,
    #[arg(long, value_enum)]
    phase: InstancePhase,
    #[arg(long)]
    transaction: String,
    #[arg(long, default_value = "/run/current-system/sw/bin/incus")]
    incus_program: PathBuf,
    #[arg(long)]
    force_refresh_existing: bool,
    #[arg(long, value_enum, default_value_t = InstanceCopyMode::Pull)]
    copy_mode: InstanceCopyMode,
    #[arg(long)]
    target_storage_pool: Option<String>,
    #[arg(long, default_value_t = 60)]
    stop_timeout_seconds: u64,
    #[arg(long)]
    force_after_timeout: bool,
    #[arg(long, value_enum, default_value_t = InstanceSeedConsistency::AllowInconsistent)]
    seed_consistency: InstanceSeedConsistency,
    #[arg(long, value_enum, default_value_t = InstanceRuntimeState::Discard)]
    runtime_state: InstanceRuntimeState,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Subcommand)]
enum BackupCommand {
    /// Create one immutable backup record and perform its authorized copy.
    Create(Box<BackupCreateArgs>),
    /// Show one durable backup record.
    Show { id: String },
    /// List durable backup records.
    List,
    /// Revalidate the persisted verification evidence for a completed backup.
    Verify { id: String },
    /// Resume only the pending copies in an interrupted backup.
    Resume(BackupRecordMutationArgs),
    /// Abort an incomplete backup after restoring any held source resources.
    Abort(BackupRecordMutationArgs),
    /// Restore one completed destination back to every original source and remain held.
    Restore(BackupRestoreArgs),
    /// Replace a failed restore with its pre-restore safety snapshots and remain held.
    Rollback(BackupRecordMutationArgs),
    /// Explicitly release restored or rolled-back resources and restart only prior writers.
    Activate(BackupRecordMutationArgs),
    /// Delete every artifact while retaining an auditable tombstone record.
    Delete(BackupRecordMutationArgs),
    /// Apply age and keep-last retention independently to equivalent backup sets.
    Prune(BackupPruneArgs),
}

#[derive(Debug, Args)]
struct BackupCreateArgs {
    /// BackupSpec JSON file, or `-` for one bounded document on stdin.
    #[arg(long)]
    spec: Option<String>,
    /// Optional caller idempotency key for a typed backup.
    #[arg(long, global = true)]
    id: Option<String>,
    /// Deprecated compatibility flag; mutating commands execute by default.
    #[arg(long, global = true, conflicts_with = "dry_run", hide = true)]
    execute: bool,
    /// Print the immutable record without persisting it or contacting hosts.
    #[arg(
        long = "dry",
        visible_alias = "dry-run",
        global = true,
        conflicts_with = "execute"
    )]
    dry_run: bool,
    #[command(subcommand)]
    resource: Option<BackupCreateResource>,
}

impl BackupCreateArgs {
    fn guard(&self) -> ExecutionGuard {
        ExecutionGuard {
            execute: self.execute,
            dry_run: self.dry_run,
        }
    }
}

#[derive(Debug, Args)]
struct BackupRecordMutationArgs {
    id: String,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct BackupRestoreArgs {
    id: String,
    /// One exact destination from the immutable backup specification.
    #[arg(long = "from", value_name = "DESTINATION")]
    source: String,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct BackupPruneArgs {
    /// Delete terminal backup sets older than this duration.
    #[arg(long, value_parser = parse_duration)]
    older_than: Duration,
    /// Retain at least this many newest records in each equivalent backup set.
    #[arg(long, default_value_t = 1)]
    keep_last: usize,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Subcommand)]
enum BackupCreateResource {
    /// Back up one or more declared logical services from the same host.
    Service(BackupArgs),
    /// Back up one or more arbitrary declared resources from the same host.
    Resource(BackupArgs),
    /// Back up one or more hosts' aggregate resources.
    Host(HostBackupArgs),
    /// Back up one or more complete Incus instances.
    Instance(InstanceBackupArgs),
}

#[derive(Debug, Args)]
struct InstanceBackupArgs {
    #[arg(required = true, num_args = 1.., value_name = "INSTANCE")]
    instances: Vec<String>,
    #[arg(long)]
    controller: String,
    #[arg(long, default_value = "local")]
    remote: String,
    #[arg(long, default_value = "default")]
    project: String,
    /// Inventory controller agent that can reach the Incus remote.
    #[arg(long)]
    executor_controller: Option<String>,
    #[arg(long, default_value = "/run/current-system/sw/bin/incus", hide = true)]
    incus_program: PathBuf,
    #[arg(long, default_value_t = 300)]
    stop_timeout_seconds: u64,
    #[arg(long)]
    force_after_timeout: bool,
    /// Exclude existing instance snapshots from the export.
    #[arg(long)]
    instance_only: bool,
    /// Use a storage-driver-specific export that requires a compatible restore pool.
    #[arg(long)]
    optimized_storage: bool,
    #[arg(long)]
    restore_storage_pool: Option<String>,
    #[arg(long = "to", required = true, value_name = "DESTINATION")]
    targets: Vec<String>,
}

#[derive(Debug, Subcommand)]
enum JobCommand {
    /// Show one durable job accepted by a host agent.
    Show(JobIdArgs),
    /// List durable jobs accepted by one host agent.
    List { host: String },
    /// Retry one terminal failed job without changing its immutable specification.
    Retry(JobMutationArgs),
}

#[derive(Debug, Args)]
struct BackupArgs {
    #[arg(required = true, num_args = 1.., value_name = "NAME")]
    names: Vec<String>,
    /// Inventory host containing the authoritative data.
    #[arg(long = "from", alias = "source")]
    source: String,
    /// Repeat for managed-host and absolute controller-directory destinations.
    #[arg(long = "to", required = true, value_name = "DESTINATION")]
    targets: Vec<String>,
}

#[derive(Debug, Args)]
struct HostBackupArgs {
    #[arg(required = true, num_args = 1.., value_name = "HOST")]
    hosts: Vec<String>,
    /// Repeat for managed-host and absolute controller-directory destinations.
    #[arg(long = "to", required = true, value_name = "DESTINATION")]
    targets: Vec<String>,
}

#[derive(Debug, Args)]
struct MoveArgs {
    /// One or more entities sharing this source and target.
    #[arg(required = true, num_args = 1.., value_name = "NAME")]
    entities: Vec<String>,

    #[arg(long = "from", alias = "source")]
    source: String,

    #[arg(long = "to", alias = "target")]
    target: String,

    /// Declarative stack namespace; otherwise require one unique production stack.
    #[arg(long)]
    stack: Option<String>,

    /// Optional caller idempotency key; otherwise a sortable ID is generated.
    #[arg(long)]
    id: Option<String>,

    #[command(flatten)]
    guard: MoveGuard,
}

#[derive(Debug, Args)]
struct HostMoveArgs {
    /// Current authoritative inventory host.
    #[arg(long = "from", alias = "source")]
    source: String,
    /// Held target inventory host.
    #[arg(long = "to", alias = "target")]
    target: String,
    /// Optional caller idempotency key; otherwise a sortable ID is generated.
    #[arg(long)]
    id: Option<String>,
    #[command(flatten)]
    guard: MoveGuard,
}

#[derive(Debug, Args)]
struct InstanceMoveArgs {
    /// One or more instance names sharing the same controller/project mapping.
    #[arg(required = true, num_args = 1..)]
    instances: Vec<String>,
    #[arg(long = "from-controller")]
    source_controller: String,
    #[arg(long = "to-controller")]
    target_controller: String,
    #[arg(long = "from-remote", default_value = "local")]
    source_remote: String,
    #[arg(long = "to-remote", default_value = "local")]
    target_remote: String,
    #[arg(long = "from-project", default_value = "default")]
    source_project: String,
    #[arg(long = "to-project", default_value = "default")]
    target_project: String,
    /// Inventory host whose agent has both Incus remotes configured.
    /// Defaults to --from-controller.
    #[arg(long)]
    executor_controller: Option<String>,
    #[arg(long, default_value = "/run/current-system/sw/bin/incus")]
    incus_program: PathBuf,
    #[arg(long, value_enum, default_value_t = InstanceCopyMode::Pull)]
    copy_mode: InstanceCopyMode,
    /// Adopt an existing unmarked target on the first seed. This permits an
    /// Incus refresh only while the target is durably held.
    #[arg(long)]
    adopt_existing_target: bool,
    #[arg(long)]
    target_storage_pool: Option<String>,
    /// Original source pool used when a post-cutover rollback copies back.
    #[arg(long, requires = "target_storage_pool")]
    rollback_storage_pool: Option<String>,
    #[arg(long, default_value_t = 60)]
    stop_timeout_seconds: u64,
    #[arg(long)]
    force_after_timeout: bool,
    #[arg(long, value_enum, default_value_t = InstanceSeedConsistency::AllowInconsistent)]
    seed_consistency: InstanceSeedConsistency,
    /// Optional caller idempotency key; otherwise a sortable ID is generated.
    #[arg(long)]
    id: Option<String>,
    #[command(flatten)]
    guard: MoveGuard,
}

#[derive(Debug, Args)]
struct MoveGuard {
    /// Attach an advanced existing transaction and resume only its pending authorized phase.
    #[arg(long)]
    force_existing: bool,

    /// Persist only repository desired state; do not construct a runtime adapter or contact agents.
    #[arg(long)]
    skip_runtime: bool,

    #[command(flatten)]
    execution: ExecutionGuard,
}

#[derive(Debug, Args)]
struct ExecutionGuard {
    /// Deprecated compatibility flag; mutating commands execute by default.
    #[arg(long, conflicts_with = "dry_run", hide = true)]
    execute: bool,

    /// Validate the intended action without writing a journal or mutating hosts.
    #[arg(long = "dry", visible_alias = "dry-run", conflicts_with = "execute")]
    dry_run: bool,
}

#[derive(Debug, Subcommand)]
enum TransactionCommand {
    /// Create an immutable heterogeneous transaction from a versioned JSON specification.
    Create(TransactionCreateArgs),
    /// Show one transaction journal.
    Show { id: String },
    /// List transaction journals.
    List,
    /// Refresh the verified non-authoritative seed copy.
    #[command(hide = true)]
    Seed(TransactionPhaseArgs),
    /// Stop all writers, finish and verify the authoritative copy, and remain held.
    Prepare(ProjectedTransactionPhaseArgs),
    /// Reverify the prepared data while both sides remain held.
    #[command(hide = true)]
    Verify(TransactionPhaseArgs),
    /// Activate and verify the target writer, retaining source for recovery.
    #[command(visible_alias = "cutover")]
    Run(ProjectedTransactionPhaseArgs),
    /// Deprecated alias for `close --rollback`.
    #[command(hide = true)]
    Rollback(ProjectedTransactionPhaseArgs),
    /// Reconcile one deployed projection. Reserved for the controller service.
    #[command(name = "_reconcile", hide = true)]
    ReconcileInternal(TransactionInternalReconcileArgs),
    /// Finalize a close only after its canonical placement generation is deployed.
    #[command(name = "_close-reconcile", hide = true)]
    CloseReconcileInternal(TransactionCloseReconcileArgs),
    /// Resume interrupted work without choosing a new transaction phase.
    Resume(TransactionResumeArgs),
    /// Finish on the successful target or roll back to source.
    Close(TransactionCloseArgs),
}

#[derive(Debug, Args)]
struct TransactionCreateArgs {
    /// TransactionSpec JSON file, or `-` for one bounded document on stdin.
    #[arg(long)]
    spec: String,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct TransactionPhaseArgs {
    id: String,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct ProjectedTransactionPhaseArgs {
    id: String,
    /// Persist only repository desired state; do not construct a runtime adapter or contact agents.
    #[arg(long)]
    skip_runtime: bool,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct TransactionCloseArgs {
    id: String,
    /// Select target as the terminal authority; safety checks remain mandatory.
    #[arg(short = 'c', long, conflicts_with = "rollback")]
    complete: bool,
    /// Select source as the terminal authority.
    #[arg(short = 'r', long, conflicts_with = "complete")]
    rollback: bool,
    /// Break glass: complete a published target-active projection without a
    /// successful current-run journal. Live terminal checks remain mandatory.
    #[arg(long, requires = "complete", conflicts_with = "rollback")]
    force: bool,
    /// Persist repository intent only and leave runtime steps for deployment.
    #[arg(long)]
    skip_runtime: bool,
    /// Deploy the published closeout without an interactive confirmation.
    #[arg(long, conflicts_with = "manual_deploy")]
    yes: bool,
    /// Stop after verified publication and print the exact Nixbot deploy command.
    #[arg(long, conflicts_with = "yes")]
    manual_deploy: bool,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct TransactionInternalReconcileArgs {
    id: String,
    /// Require the repository document consumed by this reconciliation to be
    /// exactly the digest injected into the deployed controller generation.
    #[arg(long)]
    expected_projection_sha256: String,
    /// Preserve a terminal failed job whose immutable policy changed and continue with a new durable attempt ID.
    #[arg(long)]
    supersede_failed_job: bool,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct TransactionCloseReconcileArgs {
    id: String,
    #[arg(long)]
    expected_projection_sha256: String,
}

#[derive(Debug, Args)]
struct TransactionResumeArgs {
    id: String,
    /// Preserve a terminal failed job and continue the same logical step with a new durable attempt ID.
    #[arg(long)]
    supersede_failed_job: bool,
    #[command(flatten)]
    guard: ExecutionGuard,
}

struct ProjectedReconcileRequest {
    id: String,
    expected_projection_sha256: Option<String>,
    supersede_failed_job: bool,
    guard: ExecutionGuard,
    command_name: &'static str,
}

#[derive(Debug, Subcommand)]
enum HostCommand {
    /// List inventory hosts, optionally selected by group or glob.
    List(HostSelectionArgs),
    /// Show one resolved inventory host and transport policy.
    Show { host: String },
    /// Move the aggregate resource owned by one host.
    Move(HostMoveArgs),
    /// Run a fixed argv on a host through the configured SSH transport.
    Exec {
        host: String,
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        argv: Vec<String>,
    },
    /// Open an interactive SSH session through the native inventory transport.
    Ssh(HostSshArgs),
    /// Read structured system journal entries through the host agent.
    Logs(HostLogArgs),
    /// List durable resource holds enforced on this host.
    Holds { host: String },
    /// Persist a whole-host hold and stop every managed host resource unit.
    Drain(DurableHostActionArgs),
    /// Explicitly release a whole-host hold and start its declared units.
    Activate(DurableHostActionArgs),
    /// Reboot selected hosts through a detached systemd job.
    Reboot(FleetActionArgs),
    /// Run Nix garbage collection on selected hosts.
    Gc(HostGcArgs),
    /// Remove stale deployment locks and unused anonymous Podman volumes.
    Clean(HostCleanArgs),
    /// Create and register a typed host scaffold.
    Create {
        #[command(subcommand)]
        kind: HostCreateKind,
    },
    /// Build a declarative host system and optionally copy it to a file cache.
    Build(HostBuildArgs),
    /// Partition and install an already generated physical host configuration.
    Install(HostInstallArgs),
    /// Remove a host whose direct Nix registrations are manager-owned.
    Delete(HostDeleteArgs),
}

#[derive(Debug, Subcommand)]
enum HostCreateKind {
    /// Register a host whose system lifecycle is managed outside this repository.
    External(HostCreateExternalArgs),
    /// Register a declarative Incus guest.
    Incus(HostCreateIncusArgs),
    /// Generate a physical NixOS host with a typed disk layout.
    Physical(HostCreatePhysicalArgs),
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum HostSystem {
    None,
    Live,
    Incus,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum HostBootMode {
    #[value(alias = "uefi")]
    Efi,
    Bios,
}

impl From<HostBootMode> for BootMode {
    fn from(value: HostBootMode) -> Self {
        match value {
            HostBootMode::Efi => Self::Efi,
            HostBootMode::Bios => Self::Bios,
        }
    }
}

impl From<HostSystem> for ManagedHostSystem {
    fn from(value: HostSystem) -> Self {
        match value {
            HostSystem::None => Self::None,
            HostSystem::Live => Self::Live,
            HostSystem::Incus => Self::Incus,
        }
    }
}

#[derive(Debug, Args)]
struct HostCreateCommonArgs {
    host: String,
    #[arg(long)]
    stack: Option<String>,
    #[arg(long)]
    target: Option<String>,
    #[arg(long)]
    proxy_jump: Option<String>,
    #[arg(long = "group")]
    groups: Vec<String>,
    #[arg(long)]
    force: bool,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct HostCreateExternalArgs {
    #[command(flatten)]
    common: HostCreateCommonArgs,
    #[arg(long)]
    system_module: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct HostCreateIncusArgs {
    #[command(flatten)]
    common: HostCreateCommonArgs,
    #[arg(long)]
    system_module: Option<PathBuf>,
    #[arg(long)]
    incus_parent: String,
    #[arg(long, default_value = "default")]
    incus_project: String,
    #[arg(long)]
    incus_ipv4: String,
    #[arg(long, default_value_t = 50)]
    start_priority: u16,
    #[arg(long, default_value_t = true, action = clap::ArgAction::Set)]
    nested_containers: bool,
}

#[derive(Debug, Args)]
struct HostCreatePhysicalArgs {
    #[command(flatten)]
    common: HostCreateCommonArgs,
    /// Stable by-id path for a manager-generated physical disk layout.
    #[arg(long)]
    disk: PathBuf,
    /// Existing nixos-generate-config output; otherwise physical generation probes this host.
    #[arg(long)]
    hardware_config: Option<PathBuf>,
    #[arg(long, value_enum, default_value_t = HostBootMode::Efi)]
    boot_mode: HostBootMode,
    #[arg(long, default_value = "1G")]
    esp_size: PartitionSize,
    #[arg(long, default_value = "1G")]
    boot_size: PartitionSize,
    #[arg(long, default_value_t = 0)]
    swap_size_mib: u64,
    /// Rotate manager-owned partition and LUKS UUIDs during an explicit forced regeneration.
    #[arg(long)]
    fresh_storage_ids: bool,
}

#[derive(Debug)]
struct HostGenerateArgs {
    host: String,
    system: HostSystem,
    stack: Option<String>,
    target: Option<String>,
    proxy_jump: Option<String>,
    groups: Vec<String>,
    system_module: Option<PathBuf>,
    disk: Option<PathBuf>,
    hardware_config: Option<PathBuf>,
    boot_mode: HostBootMode,
    esp_size: PartitionSize,
    boot_size: PartitionSize,
    swap_size_mib: u64,
    fresh_storage_ids: bool,
    incus_parent: Option<String>,
    incus_project: String,
    incus_ipv4: Option<String>,
    start_priority: u16,
    nested_containers: bool,
    force: bool,
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct HostBuildArgs {
    host: String,
    #[arg(long)]
    offline_cache: Option<PathBuf>,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct HostInstallArgs {
    host: String,
    #[arg(long, default_value = "/mnt")]
    root: PathBuf,
    /// Previously prepared file binary cache; all resolution is forced offline.
    #[arg(long)]
    offline_cache: Option<PathBuf>,
    #[arg(long)]
    wipe_disks: bool,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct HostDeleteArgs {
    host: String,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct HostSshArgs {
    host: String,
    #[arg(last = true, allow_hyphen_values = true)]
    args: Vec<String>,
}

#[derive(Debug, Args)]
struct FleetActionArgs {
    #[command(flatten)]
    selection: HostSelectionArgs,
    #[arg(long, default_value_t = 8)]
    jobs: usize,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct HostGcArgs {
    #[command(flatten)]
    fleet: FleetActionArgs,
    #[arg(long, default_value = "7d", conflicts_with = "all_generations")]
    delete_older_than: String,
    #[arg(long)]
    all_generations: bool,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum CleanKind {
    Deploy,
    Podman,
    Nixbot,
}

#[derive(Debug, Args)]
struct HostCleanArgs {
    #[command(flatten)]
    fleet: FleetActionArgs,
    #[arg(long, value_enum, default_value_t = CleanKind::Deploy)]
    scope: CleanKind,
    #[arg(long)]
    force_held: bool,
}

#[derive(Debug, Args)]
struct HostSelectionArgs {
    /// Restrict selection to one inventory group.
    #[arg(long)]
    group: Option<String>,
    /// Comma/space-separated exact names, globs, `all`, and `-` exclusions.
    #[arg(long)]
    hosts: Option<String>,
}

#[derive(Debug, Args)]
struct LogOptions {
    #[arg(long, default_value_t = 200)]
    lines: usize,
    #[arg(long)]
    since: Option<String>,
    #[arg(short = 'f', long)]
    follow: bool,
    /// Journal entry encoding; JSON is emitted as one object per line.
    #[arg(short = 'o', long, value_enum, default_value_t = LogOutput::Text)]
    output: LogOutput,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum LogOutput {
    Text,
    Json,
}

impl LogOutput {
    fn as_str(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Json => "json",
        }
    }
}

fn append_log_options(arguments: &mut Vec<String>, options: &LogOptions) {
    arguments.extend([
        "--lines".to_owned(),
        options.lines.to_string(),
        "--output".to_owned(),
        options.output.as_str().to_owned(),
    ]);
    if let Some(since) = &options.since {
        arguments.extend(["--since".to_owned(), since.clone()]);
    }
    if options.follow {
        arguments.push("--follow".to_owned());
    }
}

#[derive(Debug, Args)]
struct HostLogArgs {
    host: String,
    #[command(flatten)]
    logs: LogOptions,
}

#[derive(Debug, Args)]
struct DurableHostActionArgs {
    host: String,
    /// Stable owner of this durable hold and activation decision.
    #[arg(long = "owner", alias = "transaction")]
    transaction: String,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
enum Scope {
    System,
    User,
}

impl Scope {
    fn as_str(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::User => "user",
        }
    }
}

#[derive(Debug, Args)]
struct LogicalServiceArgs {
    /// Logical service name from the repository service registry.
    service: String,
    /// Override the host for a logical service without consulting a repository.
    #[arg(long)]
    host: Option<String>,
    /// Stack for logical placement; otherwise discover the unique production stack.
    #[arg(long)]
    stack: Option<String>,
}

#[derive(Debug, Subcommand)]
enum ServiceCommand {
    /// Move one or more logical services between managed hosts.
    Move(MoveArgs),
    /// Start one logical service.
    Start(ServiceMutationArgs),
    /// Stop one logical service.
    Stop(ServiceMutationArgs),
    /// Restart one logical service.
    Restart(ServiceMutationArgs),
    /// Reload one logical service.
    Reload(ServiceMutationArgs),
    /// Irreversibly clear one logical service's declared data and remain held.
    Wipe(ServiceWipeArgs),
    /// Show one logical service's status.
    Status(LogicalServiceArgs),
    /// Read one logical service's journal.
    Logs(ServiceLogArgs),
}

#[derive(Debug, Args)]
struct ServiceMutationArgs {
    #[command(flatten)]
    service: LogicalServiceArgs,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct ServiceWipeArgs {
    #[command(flatten)]
    service: LogicalServiceArgs,
    /// Optional stable idempotency key; otherwise a sortable wipe ID is generated.
    #[arg(long)]
    id: Option<String>,
    /// Existing transaction that owns the resource hold; defaults to the wipe ID.
    #[arg(long)]
    owner: Option<String>,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct ServiceLogArgs {
    #[command(flatten)]
    service: LogicalServiceArgs,
    #[command(flatten)]
    logs: LogOptions,
}

#[derive(Debug, Args)]
struct UnitArgs {
    host: String,
    unit: String,
    #[arg(long, value_enum, default_value_t = Scope::System)]
    scope: Scope,
    /// User-manager owner; valid only with `--scope user`.
    #[arg(long)]
    user: Option<String>,
}

#[derive(Debug, Args)]
struct UnitMutationArgs {
    #[command(flatten)]
    unit: UnitArgs,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct UnitLogArgs {
    #[command(flatten)]
    unit: UnitArgs,
    #[command(flatten)]
    logs: LogOptions,
}

#[derive(Debug, Subcommand)]
enum UnitCommand {
    Start(UnitMutationArgs),
    Stop(UnitMutationArgs),
    Restart(UnitMutationArgs),
    Reload(UnitMutationArgs),
    Status(UnitArgs),
    Logs(UnitLogArgs),
}

#[derive(Debug, Args)]
struct ResourceArgs {
    host: String,
    resource: String,
}

#[derive(Debug, Subcommand)]
enum ResourceCommand {
    /// Move one or more generic declared resources between managed hosts.
    Move(MoveArgs),
    /// Show one resource's immutable host-agent declaration.
    Describe(ResourceArgs),
    /// Start every unit owned by one resource.
    Start(ResourceMutationArgs),
    /// Stop every unit owned by one resource.
    Stop(ResourceMutationArgs),
    /// Restart every unit owned by one resource.
    Restart(ResourceMutationArgs),
    /// Reload every unit owned by one resource.
    Reload(ResourceMutationArgs),
    /// Irreversibly clear one resource's declared data and remain held.
    Wipe(ResourceWipeArgs),
    /// Show one resource's unit status.
    Status(ResourceArgs),
    /// Run one resource's declared readiness checks.
    Ready(ResourceArgs),
    /// Read the journals for every unit owned by one resource.
    Logs(ResourceLogArgs),
    /// Inspect or acquire a durable transaction-owned resource hold.
    Hold {
        #[command(subcommand)]
        command: ResourceHoldCommand,
    },
    /// Release the matching hold and explicitly start the resource.
    #[command(hide = true)]
    Activate(DurableResourceActionArgs),
}

#[derive(Debug, Subcommand)]
enum ResourceHoldCommand {
    /// Show the durable hold for one resource on one host.
    Show(ResourceArgs),
    /// Persist a transaction-owned hold before stopping the resource.
    #[command(hide = true)]
    Acquire(DurableResourceActionArgs),
    /// Publish a held phase projection and optionally reconcile it immediately.
    Set(ProjectedResourceHoldArgs),
    /// Publish the unheld phase and optionally release it immediately.
    Clear(ProjectedResourceHoldArgs),
}

#[derive(Debug, Args)]
struct ProjectedResourceHoldArgs {
    #[command(flatten)]
    resource: ResourceArgs,
    /// Stable phase-projection identity reused across hold and unhold phases.
    #[arg(long)]
    id: String,
    /// Publish only repository desired state; let a later deploy reconcile it.
    #[arg(long)]
    skip_runtime: bool,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct ResourceMutationArgs {
    #[command(flatten)]
    resource: ResourceArgs,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct ResourceWipeArgs {
    #[command(flatten)]
    resource: ResourceArgs,
    /// Optional stable idempotency key; otherwise a sortable wipe ID is generated.
    #[arg(long)]
    id: Option<String>,
    /// Existing transaction that owns the resource hold; defaults to the wipe ID.
    #[arg(long)]
    owner: Option<String>,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct DurableResourceActionArgs {
    #[command(flatten)]
    resource: ResourceArgs,
    /// Stable owner of this durable hold and activation decision.
    #[arg(long = "owner", alias = "transaction")]
    transaction: String,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct JobIdArgs {
    host: String,
    #[arg(long)]
    job_id: String,
}

#[derive(Debug, Args)]
struct JobMutationArgs {
    #[command(flatten)]
    job: JobIdArgs,
    #[command(flatten)]
    guard: ExecutionGuard,
}

#[derive(Debug, Args)]
struct ResourceLogArgs {
    #[command(flatten)]
    resource: ResourceArgs,
    #[command(flatten)]
    logs: LogOptions,
}

fn command_presentation(command: &Command) -> CommandPresentation {
    match command {
        Command::Instance { command } => match command {
            InstanceCommand::Move(args) => workflow_presentation(
                format!("Move {}", named_subjects("instance", &args.instances)),
                format!(
                    "Initialized migration for {}",
                    named_subjects("instance", &args.instances)
                ),
                args.guard.execution.dry_run,
            ),
            InstanceCommand::Sync(args) => mutation_presentation(
                format!("Synchronize instance {}", args.source_instance),
                format!("Synchronized instance {}", args.source_instance),
                args.guard.dry_run,
            ),
        },
        Command::Transaction { command } => match command {
            TransactionCommand::Create(args) => workflow_presentation(
                "Create transaction",
                "Created transaction",
                args.guard.dry_run,
            ),
            TransactionCommand::Show { id } => CommandPresentation::inspect(
                format!("Transaction {id}"),
                PresentationKind::Workflow,
            ),
            TransactionCommand::List => specialized_collection_presentation(
                "Transactions",
                PresentationKind::WorkflowCollection,
            ),
            TransactionCommand::Seed(args) => workflow_presentation(
                format!("Refresh warm seed for {}", args.id),
                format!("Refreshed warm seed for {}", args.id),
                args.guard.dry_run,
            ),
            TransactionCommand::Prepare(args) => workflow_presentation(
                format!("Prepare {}", args.id),
                format!("Prepared checkpoint for {}", args.id),
                args.guard.dry_run,
            ),
            TransactionCommand::Verify(args) => workflow_presentation(
                format!("Verify {}", args.id),
                format!("Verified checkpoint for {}", args.id),
                args.guard.dry_run,
            ),
            TransactionCommand::Run(args) => workflow_presentation(
                format!("Run {}", args.id),
                format!("Moved traffic to target for {}", args.id),
                args.guard.dry_run,
            ),
            TransactionCommand::Rollback(args) => workflow_presentation(
                format!("Roll back {}", args.id),
                format!("Restored source for {}", args.id),
                args.guard.dry_run,
            ),
            TransactionCommand::ReconcileInternal(args) => workflow_presentation(
                format!("Reconcile {}", args.id),
                format!("Reconciled desired state for {}", args.id),
                args.guard.dry_run,
            ),
            TransactionCommand::CloseReconcileInternal(args) => workflow_presentation(
                format!("Finalize closeout for {}", args.id),
                format!("Finalized closeout for {}", args.id),
                false,
            ),
            TransactionCommand::Resume(args) => workflow_presentation(
                format!("Resume {}", args.id),
                format!("Reconciled transaction {}", args.id),
                args.guard.dry_run,
            ),
            TransactionCommand::Close(args) => workflow_presentation(
                format!("Close {}", args.id),
                format!("Closed migration {}", args.id),
                args.guard.dry_run,
            ),
        },
        Command::Host { command } => match command {
            HostCommand::List(_) => collection_presentation("Hosts"),
            HostCommand::Show { host } => inspect_presentation(format!("Host {host}")),
            HostCommand::Move(args) => workflow_presentation(
                format!("Move host {}", args.source),
                format!("Initialized migration for host {}", args.source),
                args.guard.execution.dry_run,
            ),
            HostCommand::Exec { host, .. } => {
                CommandPresentation::passthrough(format!("Execute command on {host}"))
            }
            HostCommand::Ssh(args) => {
                CommandPresentation::passthrough(format!("SSH to {}", args.host))
            }
            HostCommand::Logs(args) => {
                CommandPresentation::stream(format!("Logs for {}", args.host))
            }
            HostCommand::Holds { host } => collection_presentation(format!("Holds on {host}")),
            HostCommand::Drain(args) => mutation_presentation(
                format!("Drain host {}", args.host),
                format!("Drained host {}", args.host),
                args.guard.dry_run,
            ),
            HostCommand::Activate(args) => mutation_presentation(
                format!("Activate host {}", args.host),
                format!("Activated host {}", args.host),
                args.guard.dry_run,
            ),
            HostCommand::Reboot(args) => fleet_presentation(
                "Submit reboot for hosts",
                "Submitted reboot for hosts",
                args.guard.dry_run,
            ),
            HostCommand::Gc(args) => fleet_presentation(
                "Collect garbage on hosts",
                "Collected garbage on hosts",
                args.fleet.guard.dry_run,
            ),
            HostCommand::Clean(args) => fleet_presentation(
                format!("Clean {} state on hosts", clean_kind(args.scope)),
                format!("Cleaned {} state on hosts", clean_kind(args.scope)),
                args.fleet.guard.dry_run,
            ),
            HostCommand::Create { kind } => {
                let (kind_name, common) = match kind {
                    HostCreateKind::External(args) => ("external", &args.common),
                    HostCreateKind::Incus(args) => ("Incus", &args.common),
                    HostCreateKind::Physical(args) => ("physical", &args.common),
                };
                mutation_presentation(
                    format!("Create {kind_name} host {}", common.host),
                    format!("Created {kind_name} host {}", common.host),
                    common.guard.dry_run,
                )
            }
            HostCommand::Build(args) => mutation_presentation(
                format!("Build host {}", args.host),
                format!("Built host {}", args.host),
                args.guard.dry_run,
            ),
            HostCommand::Install(args) => mutation_presentation(
                format!("Install host {}", args.host),
                format!("Installed host {}", args.host),
                args.guard.dry_run,
            ),
            HostCommand::Delete(args) => mutation_presentation(
                format!("Delete host {}", args.host),
                format!("Deleted host {}", args.host),
                args.guard.dry_run,
            ),
        },
        Command::Service { command } => match command {
            ServiceCommand::Move(args) => workflow_presentation(
                format!("Move {}", named_subjects("service", &args.entities)),
                format!(
                    "Initialized migration for {}",
                    named_subjects("service", &args.entities)
                ),
                args.guard.execution.dry_run,
            ),
            ServiceCommand::Start(args) => service_mutation("Start", "Started", args),
            ServiceCommand::Stop(args) => service_mutation("Stop", "Stopped", args),
            ServiceCommand::Restart(args) => service_mutation("Restart", "Restarted", args),
            ServiceCommand::Reload(args) => service_mutation("Reload", "Reloaded", args),
            ServiceCommand::Wipe(args) => mutation_presentation(
                format!("Wipe service {}", args.service.service),
                format!("Wiped service {} · hold retained", args.service.service),
                args.guard.dry_run,
            ),
            ServiceCommand::Status(args) => {
                inspect_presentation(format!("Service {}", args.service))
            }
            ServiceCommand::Logs(args) => {
                CommandPresentation::stream(format!("Logs for service {}", args.service.service))
            }
        },
        Command::Unit { command } => match command {
            UnitCommand::Start(args) => unit_mutation("Start", "Started", args),
            UnitCommand::Stop(args) => unit_mutation("Stop", "Stopped", args),
            UnitCommand::Restart(args) => unit_mutation("Restart", "Restarted", args),
            UnitCommand::Reload(args) => unit_mutation("Reload", "Reloaded", args),
            UnitCommand::Status(args) => {
                inspect_presentation(format!("Unit {} · {}", args.unit, args.host))
            }
            UnitCommand::Logs(args) => CommandPresentation::stream(format!(
                "Logs for unit {} · {}",
                args.unit.unit, args.unit.host
            )),
        },
        Command::Resource { command } => match command {
            ResourceCommand::Move(args) => workflow_presentation(
                format!("Move {}", named_subjects("resource", &args.entities)),
                format!(
                    "Initialized migration for {}",
                    named_subjects("resource", &args.entities)
                ),
                args.guard.execution.dry_run,
            ),
            ResourceCommand::Describe(args) => {
                inspect_presentation(format!("Resource {} · {}", args.resource, args.host))
            }
            ResourceCommand::Start(args) => resource_mutation("Start", "Started", args),
            ResourceCommand::Stop(args) => resource_mutation("Stop", "Stopped", args),
            ResourceCommand::Restart(args) => resource_mutation("Restart", "Restarted", args),
            ResourceCommand::Reload(args) => resource_mutation("Reload", "Reloaded", args),
            ResourceCommand::Wipe(args) => mutation_presentation(
                format!(
                    "Wipe resource {} · {}",
                    args.resource.resource, args.resource.host
                ),
                format!("Wiped resource {} · hold retained", args.resource.resource),
                args.guard.dry_run,
            ),
            ResourceCommand::Status(args) => {
                inspect_presentation(format!("Resource {} · {}", args.resource, args.host))
            }
            ResourceCommand::Ready(args) => {
                inspect_presentation(format!("Readiness for {} · {}", args.resource, args.host))
            }
            ResourceCommand::Logs(args) => CommandPresentation::stream(format!(
                "Logs for resource {} · {}",
                args.resource.resource, args.resource.host
            )),
            ResourceCommand::Hold { command } => match command {
                ResourceHoldCommand::Show(args) => {
                    inspect_presentation(format!("Hold for {} · {}", args.resource, args.host))
                }
                ResourceHoldCommand::Acquire(args) => {
                    resource_action_presentation("Acquire hold for", "Acquired hold for", args)
                }
                ResourceHoldCommand::Set(args) => mutation_presentation(
                    format!(
                        "Set hold for {} · {}",
                        args.resource.resource, args.resource.host
                    ),
                    format!("Set hold for {}", args.resource.resource),
                    args.guard.dry_run,
                ),
                ResourceHoldCommand::Clear(args) => mutation_presentation(
                    format!(
                        "Clear hold for {} · {}",
                        args.resource.resource, args.resource.host
                    ),
                    format!("Cleared hold for {}", args.resource.resource),
                    args.guard.dry_run,
                ),
            },
            ResourceCommand::Activate(args) => {
                resource_action_presentation("Activate", "Activated", args)
            }
        },
        Command::Backup { command } => match command {
            BackupCommand::Create(args) => {
                backup_presentation("Create backup", "Created backup", args.dry_run)
            }
            BackupCommand::Show { id } => {
                CommandPresentation::inspect(format!("Backup {id}"), PresentationKind::Backup)
            }
            BackupCommand::List => {
                specialized_collection_presentation("Backups", PresentationKind::BackupCollection)
            }
            BackupCommand::Verify { id } => backup_presentation(
                format!("Verify backup {id}"),
                format!("Verified backup {id}"),
                false,
            ),
            BackupCommand::Resume(args) => backup_mutation("Resume", "Resumed", args),
            BackupCommand::Abort(args) => backup_mutation("Abort", "Aborted", args),
            BackupCommand::Restore(args) => backup_presentation(
                format!("Restore backup {}", args.id),
                format!("Restored backup {} · resources held", args.id),
                args.guard.dry_run,
            ),
            BackupCommand::Rollback(args) => backup_mutation("Roll back", "Rolled back", args),
            BackupCommand::Activate(args) => backup_mutation("Activate", "Activated", args),
            BackupCommand::Delete(args) => backup_mutation("Delete", "Deleted", args),
            BackupCommand::Prune(args) => {
                backup_presentation("Prune backups", "Pruned backups", args.guard.dry_run)
            }
        },
        Command::Job { command } => match command {
            JobCommand::Show(args) => CommandPresentation::inspect(
                format!("Job {} · {}", args.job_id, args.host),
                PresentationKind::Job,
            ),
            JobCommand::List { host } => specialized_collection_presentation(
                format!("Jobs on {host}"),
                PresentationKind::JobCollection,
            ),
            JobCommand::Retry(args) => job_presentation(
                format!("Retry job {} · {}", args.job.job_id, args.job.host),
                format!("Retried job {}", args.job.job_id),
                args.guard.dry_run,
            ),
        },
    }
}

fn inspect_presentation(heading: impl Into<String>) -> CommandPresentation {
    CommandPresentation::inspect(heading, PresentationKind::Inspect)
}

fn collection_presentation(heading: impl Into<String>) -> CommandPresentation {
    CommandPresentation::collection(heading, PresentationKind::Collection)
}

fn specialized_collection_presentation(
    heading: impl Into<String>,
    kind: PresentationKind,
) -> CommandPresentation {
    CommandPresentation::collection(heading, kind)
}

fn mutation_presentation(
    heading: impl Into<String>,
    completed: impl Into<String>,
    dry_run: bool,
) -> CommandPresentation {
    CommandPresentation::structured(heading, completed, PresentationKind::Mutation, dry_run)
}

fn fleet_presentation(
    heading: impl Into<String>,
    completed: impl Into<String>,
    dry_run: bool,
) -> CommandPresentation {
    CommandPresentation::structured(heading, completed, PresentationKind::Fleet, dry_run)
}

fn workflow_presentation(
    heading: impl Into<String>,
    completed: impl Into<String>,
    dry_run: bool,
) -> CommandPresentation {
    CommandPresentation::structured(heading, completed, PresentationKind::Workflow, dry_run)
}

fn backup_presentation(
    heading: impl Into<String>,
    completed: impl Into<String>,
    dry_run: bool,
) -> CommandPresentation {
    CommandPresentation::structured(heading, completed, PresentationKind::Backup, dry_run)
}

fn job_presentation(
    heading: impl Into<String>,
    completed: impl Into<String>,
    dry_run: bool,
) -> CommandPresentation {
    CommandPresentation::structured(heading, completed, PresentationKind::Job, dry_run)
}

fn named_subjects(kind: &str, names: &[String]) -> String {
    match names {
        [] => format!("{kind}s"),
        [name] => format!("{kind} {name}"),
        names => format!("{} {kind}s", names.len()),
    }
}

fn service_mutation(
    action: &str,
    completed: &str,
    args: &ServiceMutationArgs,
) -> CommandPresentation {
    mutation_presentation(
        format!("{action} service {}", args.service.service),
        format!("{completed} service {}", args.service.service),
        args.guard.dry_run,
    )
}

fn unit_mutation(action: &str, completed: &str, args: &UnitMutationArgs) -> CommandPresentation {
    mutation_presentation(
        format!("{action} unit {} · {}", args.unit.unit, args.unit.host),
        format!("{completed} unit {}", args.unit.unit),
        args.guard.dry_run,
    )
}

fn resource_mutation(
    action: &str,
    completed: &str,
    args: &ResourceMutationArgs,
) -> CommandPresentation {
    mutation_presentation(
        format!(
            "{action} resource {} · {}",
            args.resource.resource, args.resource.host
        ),
        format!("{completed} resource {}", args.resource.resource),
        args.guard.dry_run,
    )
}

fn resource_action_presentation(
    action: &str,
    completed: &str,
    args: &DurableResourceActionArgs,
) -> CommandPresentation {
    mutation_presentation(
        format!(
            "{action} {} · {}",
            args.resource.resource, args.resource.host
        ),
        format!("{completed} {}", args.resource.resource),
        args.guard.dry_run,
    )
}

fn backup_mutation(
    action: &str,
    completed: &str,
    args: &BackupRecordMutationArgs,
) -> CommandPresentation {
    backup_presentation(
        format!("{action} backup {}", args.id),
        format!("{completed} backup {}", args.id),
        args.guard.dry_run,
    )
}

fn clean_kind(kind: CleanKind) -> &'static str {
    match kind {
        CleanKind::Deploy => "deploy",
        CleanKind::Podman => "Podman",
        CleanKind::Nixbot => "Nixbot",
    }
}

const CONTROLLER_EXECUTION_ENV: &str = "ABIRD_HOST_MANAGER_CONTROLLER_EXECUTION";
const CONTROLLER_REPOSITORY: &str = "/var/lib/nixbot/nix";
const CONTROLLER_CONFIG: &str = "/var/lib/nixbot/nix/hosts/nixbot.nix";
const CONTROLLER_STATE_DIR: &str = "/var/lib/nixbot/abird-host-manager";
const CONTROLLER_MANAGER: &str = "/run/current-system/sw/bin/abird-host-manager";

#[derive(Debug)]
struct RenderedControllerJsonFailure;

impl std::fmt::Display for RenderedControllerJsonFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("controller returned a rendered JSON failure")
    }
}

impl std::error::Error for RenderedControllerJsonFailure {}

#[derive(Debug)]
struct RenderedCommandFailure;

impl std::fmt::Display for RenderedCommandFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("command failure was already rendered")
    }
}

impl std::error::Error for RenderedCommandFailure {}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            if error
                .downcast_ref::<RenderedControllerJsonFailure>()
                .is_some()
                || error.downcast_ref::<RenderedCommandFailure>().is_some()
                || error
                    .downcast_ref::<RenderedInventoryCommandFailure>()
                    .is_some()
            {
                // The controller's one authoritative JSON document was
                // already forwarded verbatim.
            } else if json_output() {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&json!({
                        "schema_version": 1,
                        "ok": false,
                        "error": {"message": format!("{error:#}")},
                    }))
                    .expect("serialize bounded command error")
                );
            } else {
                command_reporter().fail_active("Command stopped", &format!("{error:#}"));
            }
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<()> {
    let mut cli = Cli::parse();
    set_json_output(cli.json);
    select_local_mode(&mut cli)?;
    select_local_run(&mut cli)?;
    let presentation = command_presentation(&cli.command);
    validate_output_contract(cli.json, &presentation)?;
    COMMAND_PRESENTATION
        .set(presentation)
        .map_err(|_| anyhow::anyhow!("command presentation was initialized more than once"))?;
    if should_dispatch_to_controller(&cli) {
        return dispatch_to_controller(&cli);
    }
    if controller_publication_authority(&cli.command) == PublicationAuthority::Required {
        transient_step("Verify projection publication access", || {
            preflight_projection_publication(&cli)
        })?;
    }
    let repository_programs = RepositoryPrograms {
        nix: cli.nix_program,
        privilege: cli.privilege_program,
        nixos_install: cli.nixos_install_program,
    };
    match cli.command {
        Command::Instance { command } => {
            let config = resolve_config(cli.config.as_deref(), cli.repo_root.as_deref())?;
            instance_command(
                resolve_state_dir(cli.state_dir)?,
                config,
                ProjectionExecution {
                    repo_root: cli.repo_root,
                    git_program: cli.git_program,
                    nix_program: repository_programs.nix.clone(),
                    branch: cli.projection_branch,
                    publish_git_ssh_command: cli.publish_git_ssh_command,
                    mode: publication_mode(cli.local),
                },
                command,
            )
        }
        Command::Transaction { command } => transaction_command(
            resolve_state_dir(cli.state_dir)?,
            cli.config,
            ProjectionExecution {
                repo_root: cli.repo_root,
                git_program: cli.git_program,
                nix_program: repository_programs.nix,
                branch: cli.projection_branch,
                publish_git_ssh_command: cli.publish_git_ssh_command,
                mode: publication_mode(cli.local),
            },
            command,
        ),
        Command::Host { command } => match command {
            HostCommand::Move(args) => move_resource(
                resolve_state_dir(cli.state_dir)?,
                resolve_config(cli.config.as_deref(), cli.repo_root.as_deref())?,
                ProjectionExecution {
                    repo_root: cli.repo_root,
                    git_program: cli.git_program,
                    nix_program: repository_programs.nix.clone(),
                    branch: cli.projection_branch,
                    publish_git_ssh_command: cli.publish_git_ssh_command,
                    mode: publication_mode(cli.local),
                },
                MoveArgs {
                    entities: vec![args.source.clone()],
                    source: args.source,
                    target: args.target,
                    stack: None,
                    id: args.id,
                    guard: args.guard,
                },
                ResourceType::Host,
            ),
            HostCommand::Create { kind } => repository_generate(
                cli.repo_root,
                &repository_programs,
                &cli.nixos_generate_config_program,
                host_create_args(kind)?,
            ),
            HostCommand::Build(args) => repository_build(cli.repo_root, &repository_programs, args),
            HostCommand::Install(args) => {
                repository_install(cli.repo_root, &repository_programs, args)
            }
            HostCommand::Delete(args) => repository_delete(cli.repo_root, args),
            command => {
                let config = HostManagerConfig::load(&resolve_config(
                    cli.config.as_deref(),
                    cli.repo_root.as_deref(),
                )?)?;
                host_command(&config, command)
            }
        },
        Command::Service { command } => match command {
            ServiceCommand::Move(args) => move_resource(
                resolve_state_dir(cli.state_dir)?,
                resolve_config(cli.config.as_deref(), cli.repo_root.as_deref())?,
                ProjectionExecution {
                    repo_root: cli.repo_root,
                    git_program: cli.git_program,
                    nix_program: repository_programs.nix.clone(),
                    branch: cli.projection_branch,
                    publish_git_ssh_command: cli.publish_git_ssh_command,
                    mode: publication_mode(cli.local),
                },
                args,
                ResourceType::Service,
            ),
            command => {
                let config = HostManagerConfig::load(&resolve_config(
                    cli.config.as_deref(),
                    cli.repo_root.as_deref(),
                )?)?;
                service_command(&config, cli.repo_root, &repository_programs.nix, command)
            }
        },
        Command::Unit { command } => {
            let config = HostManagerConfig::load(&resolve_config(
                cli.config.as_deref(),
                cli.repo_root.as_deref(),
            )?)?;
            unit_command(&config, command)
        }
        Command::Resource { command } => match command {
            ResourceCommand::Move(args) => move_resource(
                resolve_state_dir(cli.state_dir)?,
                resolve_config(cli.config.as_deref(), cli.repo_root.as_deref())?,
                ProjectionExecution {
                    repo_root: cli.repo_root,
                    git_program: cli.git_program,
                    nix_program: repository_programs.nix.clone(),
                    branch: cli.projection_branch,
                    publish_git_ssh_command: cli.publish_git_ssh_command,
                    mode: publication_mode(cli.local),
                },
                args,
                ResourceType::Resource,
            ),
            ResourceCommand::Hold {
                command: ResourceHoldCommand::Set(args),
            } => project_resource_hold(
                resolve_state_dir(cli.state_dir)?,
                resolve_config(cli.config.as_deref(), cli.repo_root.as_deref())?,
                ProjectionExecution {
                    repo_root: cli.repo_root,
                    git_program: cli.git_program,
                    nix_program: repository_programs.nix.clone(),
                    branch: cli.projection_branch,
                    publish_git_ssh_command: cli.publish_git_ssh_command,
                    mode: publication_mode(cli.local),
                },
                args,
                ResourceHoldPhase::Held,
            ),
            ResourceCommand::Hold {
                command: ResourceHoldCommand::Clear(args),
            } => project_resource_hold(
                resolve_state_dir(cli.state_dir)?,
                resolve_config(cli.config.as_deref(), cli.repo_root.as_deref())?,
                ProjectionExecution {
                    repo_root: cli.repo_root,
                    git_program: cli.git_program,
                    nix_program: repository_programs.nix.clone(),
                    branch: cli.projection_branch,
                    publish_git_ssh_command: cli.publish_git_ssh_command,
                    mode: publication_mode(cli.local),
                },
                args,
                ResourceHoldPhase::Unheld,
            ),
            command => {
                let adapter = NativeAdapter::load(&resolve_config(
                    cli.config.as_deref(),
                    cli.repo_root.as_deref(),
                )?)?;
                resource_command(&adapter, command)
            }
        },
        Command::Backup { command } => backup_command(
            resolve_state_dir(cli.state_dir)?,
            cli.config,
            cli.repo_root,
            command,
        ),
        Command::Job { command } => job_command(
            &HostManagerConfig::load(&resolve_config(
                cli.config.as_deref(),
                cli.repo_root.as_deref(),
            )?)?,
            command,
        ),
    }
}

fn validate_output_contract(json: bool, presentation: &CommandPresentation) -> Result<()> {
    if !json || presentation.contract == OutputContract::Structured {
        return Ok(());
    }
    match presentation.contract {
        OutputContract::Stream => bail!(
            "global --json is unavailable for {}; use the command's --output json option for the JSONL stream",
            presentation.heading
        ),
        OutputContract::Passthrough => bail!(
            "global --json is unavailable for {}; this command preserves the remote byte stream",
            presentation.heading
        ),
        OutputContract::Structured => Ok(()),
    }
}

fn should_dispatch_to_controller(cli: &Cli) -> bool {
    if env::var_os(CONTROLLER_EXECUTION_ENV).is_some() || cli.controller.as_deref() == Some("local")
    {
        return false;
    }
    if cli.controller.is_none() && (cli.config.is_some() || cli.state_dir.is_some()) {
        return false;
    }
    is_controller_authority_command(&cli.command)
}

fn is_controller_authority_command(command: &Command) -> bool {
    matches!(
        command,
        Command::Instance {
            command: InstanceCommand::Move(_),
        } | Command::Host {
            command: HostCommand::Move(_),
        } | Command::Service {
            command: ServiceCommand::Move(_),
        } | Command::Resource {
            command: ResourceCommand::Move(_),
        } | Command::Resource {
            command: ResourceCommand::Hold {
                command: ResourceHoldCommand::Set(_) | ResourceHoldCommand::Clear(_),
            },
        } | Command::Transaction { .. }
    )
}

fn dispatch_to_controller(cli: &Cli) -> Result<()> {
    let publication_authority = controller_publication_authority(&cli.command);
    let forward_agent = match publication_authority {
        PublicationAuthority::Required => local_ssh_agent_available()?,
        PublicationAuthority::None => false,
    };
    if forward_agent {
        Repository::discover(cli.repo_root.clone())?
            .verify_projection_publication_base(&cli.git_program, &cli.projection_branch)?;
    }
    let config_path = resolve_config(None, cli.repo_root.as_deref())?;
    let config = HostManagerConfig::load(&config_path)?;
    let controller = match cli.controller.as_deref() {
        Some(selector) => config.resolve_host_reference(selector)?,
        None => config.controller_host()?.to_owned(),
    };
    let state_dir = remote_controller_state_dir(cli.state_dir.as_deref())?;
    let mut argv = vec![
        "/usr/bin/env".to_owned(),
        format!("{CONTROLLER_EXECUTION_ENV}=1"),
        CONTROLLER_MANAGER.to_owned(),
        "--repo-root".to_owned(),
        CONTROLLER_REPOSITORY.to_owned(),
        "--config".to_owned(),
        CONTROLLER_CONFIG.to_owned(),
        "--state-dir".to_owned(),
        state_dir,
    ];
    argv.extend(controller_command_arguments(env::args().skip(1))?);
    if cli.json {
        let output = config.run_inventory_command(&controller, &argv, forward_agent)?;
        serde_json::from_slice::<Value>(&output.stdout).with_context(|| {
            format!(
                "controller returned invalid JSON: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            )
        })?;
        io::stdout().write_all(&output.stdout)?;
        if !output.stdout.ends_with(b"\n") {
            println!();
        }
        if !output.status.success() {
            return Err(RenderedControllerJsonFailure.into());
        }
        Ok(())
    } else {
        config.run_inventory_command_interactive(&controller, &argv, forward_agent)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PublicationAuthority {
    Required,
    None,
}

fn controller_publication_authority(command: &Command) -> PublicationAuthority {
    match command {
        Command::Instance {
            command: InstanceCommand::Move(args),
        } if !args.guard.execution.dry_run => PublicationAuthority::Required,
        Command::Host {
            command: HostCommand::Move(args),
        } if !args.guard.execution.dry_run => PublicationAuthority::Required,
        Command::Service {
            command: ServiceCommand::Move(args),
        }
        | Command::Resource {
            command: ResourceCommand::Move(args),
        } if !args.guard.execution.dry_run => PublicationAuthority::Required,
        Command::Resource {
            command:
                ResourceCommand::Hold {
                    command: ResourceHoldCommand::Set(args) | ResourceHoldCommand::Clear(args),
                },
        } if !args.guard.dry_run => PublicationAuthority::Required,
        Command::Transaction { command } => match command {
            TransactionCommand::Create(args) if !args.guard.dry_run => {
                PublicationAuthority::Required
            }
            TransactionCommand::Prepare(args)
            | TransactionCommand::Run(args)
            | TransactionCommand::Rollback(args)
                if !args.guard.dry_run =>
            {
                PublicationAuthority::Required
            }
            TransactionCommand::Close(args) if !args.guard.dry_run => {
                PublicationAuthority::Required
            }
            _ => PublicationAuthority::None,
        },
        _ => PublicationAuthority::None,
    }
}

fn local_ssh_agent_available() -> Result<bool> {
    let Some(socket) = env::var_os("SSH_AUTH_SOCK").filter(|socket| !socket.is_empty()) else {
        return Ok(false);
    };
    let metadata = fs::metadata(&socket).with_context(|| {
        format!(
            "inspect local SSH_AUTH_SOCK {}",
            Path::new(&socket).display()
        )
    })?;
    if !metadata.file_type().is_socket() {
        bail!(
            "local SSH_AUTH_SOCK {} is not a Unix socket",
            Path::new(&socket).display()
        );
    }
    Ok(true)
}

fn preflight_projection_publication(cli: &Cli) -> Result<()> {
    if controller_publication_authority(&cli.command) == PublicationAuthority::None {
        return Ok(());
    }
    let source_repository = Repository::discover(cli.repo_root.clone())?;
    let state_dir = resolve_state_dir(cli.state_dir.clone())?;
    let authority = WorkflowStore::open(state_dir.clone())?;
    let publisher = if cli.local {
        ProjectionPublisher::prepare_local(
            &source_repository,
            &authority,
            &state_dir,
            &cli.projection_branch,
            cli.git_program.clone(),
            cli.nix_program.clone(),
        )?
    } else {
        ProjectionPublisher::prepare(
            &source_repository,
            &authority,
            &state_dir,
            &cli.projection_branch,
            cli.git_program.clone(),
            cli.nix_program.clone(),
            cli.publish_git_ssh_command.clone(),
        )?
    };
    publisher
        .verify_push_access()
        .context("Git publication preflight failed before lifecycle journal mutation")
}

fn controller_command_arguments(
    arguments: impl IntoIterator<Item = String>,
) -> Result<Vec<String>> {
    let mut filtered = Vec::new();
    let mut arguments = arguments.into_iter();
    while let Some(argument) = arguments.next() {
        if matches!(
            argument.as_str(),
            "--repo-root"
                | "--config"
                | "--state-dir"
                | "--controller"
                | "--local-run"
                | "--publish-git-ssh-command"
        ) {
            arguments
                .next()
                .with_context(|| format!("global option {argument} has no value"))?;
            continue;
        }
        if [
            "--repo-root=",
            "--config=",
            "--state-dir=",
            "--controller=",
            "--local-run=",
            "--publish-git-ssh-command=",
        ]
        .iter()
        .any(|prefix| argument.starts_with(prefix))
        {
            continue;
        }
        filtered.push(argument);
    }
    Ok(filtered)
}

fn instance_command(
    state_dir: PathBuf,
    config: PathBuf,
    projection: ProjectionExecution,
    command: InstanceCommand,
) -> Result<()> {
    match command {
        InstanceCommand::Move(args) => move_instances(state_dir, config, projection, args),
        InstanceCommand::Sync(args) => sync_instance_command(&NativeAdapter::load(&config)?, args),
    }
}

fn move_instances(
    state_dir: PathBuf,
    config: PathBuf,
    projection: ProjectionExecution,
    args: InstanceMoveArgs,
) -> Result<()> {
    require_guard(&args.guard.execution, "instance move")?;
    let items = args
        .instances
        .iter()
        .enumerate()
        .map(|(index, name)| MoveItem::Instance {
            id: format!("item-{:03}", index + 1),
            source: InstanceEndpoint {
                controller: args.source_controller.clone(),
                remote: args.source_remote.clone(),
                project: args.source_project.clone(),
                instance: name.clone(),
            },
            target: InstanceEndpoint {
                controller: args.target_controller.clone(),
                remote: args.target_remote.clone(),
                project: args.target_project.clone(),
                instance: name.clone(),
            },
            policy: InstanceMovePolicy {
                executor_controller: args.executor_controller.clone(),
                program: args.incus_program.clone(),
                copy_mode: args.copy_mode.into(),
                adopt_existing_target: args.adopt_existing_target,
                target_storage_pool: args.target_storage_pool.clone(),
                rollback_storage_pool: args.rollback_storage_pool.clone(),
                stop_timeout_seconds: args.stop_timeout_seconds,
                force_after_timeout: args.force_after_timeout,
                seed_consistency: args.seed_consistency.into(),
                runtime_state: RuntimeStateMode::Discard,
            },
        })
        .collect();
    execute_new_move(
        state_dir,
        config,
        projection,
        None,
        args.id.as_deref(),
        items,
        &args.guard,
    )
}

fn sync_instance_command(adapter: &NativeAdapter, args: InstanceSyncArgs) -> Result<()> {
    adapter.config().host(&args.controller)?;
    let phase = InstanceMigrationPhase::from(args.phase);
    let request = InstanceMigrationRequest {
        program: args.incus_program,
        phase,
        source_instance: args.source_instance,
        target_instance: args.target_instance,
        source_remote: args.source_remote,
        target_remote: args.target_remote,
        source_project: args.source_project,
        target_project: args.target_project,
        snapshot: format!(
            "abird-host-manager-{}-{}",
            &digest_bytes(args.transaction.as_bytes())[..16],
            match phase {
                InstanceMigrationPhase::Seed => "seed",
                InstanceMigrationPhase::Final => "prepare",
            }
        ),
        force_refresh_existing: args.force_refresh_existing,
        start_target: false,
        policy: InstanceMigrationPolicy {
            copy_mode: args.copy_mode.into(),
            target_storage_pool: args.target_storage_pool,
            stop_timeout_seconds: args.stop_timeout_seconds,
            force_after_timeout: args.force_after_timeout,
            seed_consistency: args.seed_consistency.into(),
            runtime_state: args.runtime_state.into(),
        },
    };
    if args.guard.dry_run {
        return emit_result(&json!({
            "dry_run": true,
            "controller": args.controller,
            "transaction": args.transaction,
            "request": request,
        }));
    }
    let job_id = format!(
        "instance-migrate-{}-{}",
        &digest_bytes(args.transaction.as_bytes())[..20],
        match phase {
            InstanceMigrationPhase::Seed => "seed",
            InstanceMigrationPhase::Final => "final",
        }
    );
    let encoded = serde_json::to_string(&request)?;
    let resource = format!("instance:{}", request.target_instance);
    transient_step("Reserve target instance", || {
        adapter.run_profile_job(
            &args.controller,
            &format!("{job_id}-reserve"),
            &args.transaction,
            &resource,
            &["--operation".to_owned(), "reserve".to_owned()],
        )
    })?;
    let job = transient_step("Synchronize and verify instance", || {
        adapter.run_profile_job_result(
            &args.controller,
            &job_id,
            &args.transaction,
            &resource,
            &["--migrate-instance".to_owned(), encoded],
        )
    })?;
    emit_result(&json!({
        "ok": true,
        "controller": args.controller,
        "transaction": args.transaction,
        "job_id": job_id,
        "job": job,
    }))
}

fn job_command(config: &HostManagerConfig, command: JobCommand) -> Result<()> {
    let (host, arguments, retry) = match command {
        JobCommand::Show(args) => (
            args.host,
            vec![
                "--json".to_owned(),
                "job".to_owned(),
                "show".to_owned(),
                "--job-id".to_owned(),
                args.job_id,
            ],
            false,
        ),
        JobCommand::List { host } => (
            host,
            vec!["--json".to_owned(), "job".to_owned(), "list".to_owned()],
            false,
        ),
        JobCommand::Retry(args) => {
            if args.guard.dry_run {
                return emit_result(&json!({
                    "dry_run": true,
                    "operation": "job_retry",
                    "host": args.job.host,
                    "job_id": args.job.job_id,
                }));
            }
            (
                args.job.host,
                vec![
                    "--json".to_owned(),
                    "job".to_owned(),
                    "retry".to_owned(),
                    "--job-id".to_owned(),
                    args.job.job_id,
                ],
                true,
            )
        }
    };
    let result = if retry {
        transient_step("Submit durable host-agent retry", || {
            config.run_agent(&host, &arguments)
        })?
    } else {
        config.run_agent(&host, &arguments)?
    };
    emit_result(&result)
}

enum ResourceType {
    Host,
    Service,
    Resource,
}

#[derive(Clone, Debug)]
struct ProjectionExecution {
    repo_root: Option<PathBuf>,
    git_program: PathBuf,
    nix_program: PathBuf,
    branch: String,
    publish_git_ssh_command: Option<String>,
    mode: ProjectionPublicationMode,
}

fn publication_mode(local: bool) -> ProjectionPublicationMode {
    if local {
        ProjectionPublicationMode::Local
    } else {
        ProjectionPublicationMode::Remote
    }
}

fn prepare_projection_publisher(
    source_repository: &Repository,
    authority: &WorkflowStore,
    state_dir: &Path,
    execution: &ProjectionExecution,
) -> Result<ProjectionPublisher> {
    match execution.mode {
        ProjectionPublicationMode::Remote => ProjectionPublisher::prepare(
            source_repository,
            authority,
            state_dir,
            &execution.branch,
            execution.git_program.clone(),
            execution.nix_program.clone(),
            execution.publish_git_ssh_command.clone(),
        ),
        ProjectionPublicationMode::Local => ProjectionPublisher::prepare_local(
            source_repository,
            authority,
            state_dir,
            &execution.branch,
            execution.git_program.clone(),
            execution.nix_program.clone(),
        ),
    }
}

fn load_execution_adapter(config: &Path, execution: &ProjectionExecution) -> Result<NativeAdapter> {
    let mut adapter = NativeAdapter::load(config)?;
    if execution.mode == ProjectionPublicationMode::Local {
        let repository = Repository::discover(execution.repo_root.clone())?;
        let revision = repository.revision(&execution.git_program)?;
        adapter.bind_local_nixbot(
            repository.root().to_path_buf(),
            execution.nix_program.clone(),
            revision,
        )?;
    }
    Ok(adapter)
}

fn move_resource(
    state_dir: PathBuf,
    config: PathBuf,
    projection: ProjectionExecution,
    args: MoveArgs,
    resource_type: ResourceType,
) -> Result<()> {
    require_guard(&args.guard.execution, "move")?;
    let mut service_resources = BTreeMap::new();
    let declarative_scope = if matches!(resource_type, ResourceType::Service) {
        let repository = Repository::discover(projection.repo_root.clone())?;
        let inventory = HostManagerConfig::load(&config)?;
        let mut scopes = BTreeSet::new();
        for service in &args.entities {
            let resolved = resolve_service_host(
                &repository,
                &projection.nix_program,
                &inventory,
                args.stack.as_deref(),
                service,
            )?;
            if resolved.host != args.source {
                bail!(
                    "service {service:?} is declared on {:?}, not requested source {:?}",
                    resolved.host,
                    args.source
                );
            }
            let source_resource = resolve_service_resource(
                &repository,
                &projection.nix_program,
                &args.source,
                service,
            )?;
            let target_resource = resolve_service_resource(
                &repository,
                &projection.nix_program,
                &args.target,
                service,
            )?;
            service_resources.insert(service.clone(), (source_resource, target_resource));
            scopes.insert(resolved.stack);
        }
        if scopes.len() != 1 {
            bail!("one service move transaction must use exactly one declarative stack scope");
        }
        scopes.into_iter().next()
    } else {
        if args.stack.is_some() {
            bail!("--stack is valid only for logical service moves");
        }
        None
    };
    let source = HostEndpoint {
        host: args.source.clone(),
        instance: None,
    };
    let target = HostEndpoint {
        host: args.target.clone(),
        instance: None,
    };
    let items = args
        .entities
        .iter()
        .enumerate()
        .map(|(index, name)| {
            let id = format!("item-{:03}", index + 1);
            match resource_type {
                ResourceType::Host => MoveItem::Host {
                    id,
                    source: source.clone(),
                    target: target.clone(),
                    data_roots: Vec::new(),
                },
                ResourceType::Service => MoveItem::Service {
                    id,
                    service: name.clone(),
                    source_resource: service_resources
                        .get(name)
                        .map(|resources| resources.0.clone()),
                    target_resource: service_resources
                        .get(name)
                        .map(|resources| resources.1.clone()),
                    source: source.clone(),
                    target: target.clone(),
                    data_roots: Vec::new(),
                },
                ResourceType::Resource => MoveItem::Resource {
                    id,
                    resource: name.clone(),
                    source: source.clone(),
                    target: target.clone(),
                    data_roots: Vec::new(),
                },
            }
        })
        .collect();
    execute_new_move(
        state_dir,
        config,
        projection,
        declarative_scope,
        args.id.as_deref(),
        items,
        &args.guard,
    )
}

fn project_resource_hold(
    state_dir: PathBuf,
    config_path: PathBuf,
    execution: ProjectionExecution,
    args: ProjectedResourceHoldArgs,
    phase: ResourceHoldPhase,
) -> Result<()> {
    require_guard(&args.guard, "resource hold projection")?;
    let config = HostManagerConfig::load(&config_path)?;
    let intent = ResourceHoldIntent {
        projection_id: args.id.clone(),
        host: args.resource.host.clone(),
        host_resource: config.host_resource(&args.resource.host)?,
        resource: args.resource.resource.clone(),
    };
    let source_repository = Repository::discover(execution.repo_root.clone())?;

    if args.guard.dry_run {
        let previous = source_repository.load_phase_projection(&args.id)?;
        let projection = ResourceHoldProjector::derive(&intent, phase, previous.as_ref(), None)?;
        return emit_result(&json!({
            "dry_run": true,
            "projection": projection,
            "repository_path": format!("data/phase-projections/{}.json", args.id),
            "runtime": if args.skip_runtime { "skipped" } else { "planned" },
        }));
    }

    // Every projection kind shares this authority lock from repository
    // publication through the runtime handoff. This serializes the one
    // manager-owned checkout and prevents cross-kind publication races.
    let authority = WorkflowStore::open(state_dir.clone())?;
    let (projection, publication) = transient_step("Publish resource hold projection", || {
        let publisher =
            prepare_projection_publisher(&source_repository, &authority, &state_dir, &execution)?;
        let previous = publisher.repository().load_phase_projection(&args.id)?;
        let projection = ResourceHoldProjector::derive(
            &intent,
            phase,
            previous.as_ref(),
            Some(publisher.revision()?),
        )?;
        let publication = publisher.publish(&projection, config.controller_host()?)?;
        Ok((projection, publication))
    })?;
    if args.skip_runtime {
        return emit_result(&json!({
            "projection": projection,
            "repository": publication,
            "runtime": "skipped",
        }));
    }

    let mut adapter = NativeAdapter::load(&config_path)?;
    let hold_epoch = projection
        .hold_epoch_for_execution(&args.resource.host, &args.resource.resource)?
        .context("resource-hold projection has no hold epoch")?;
    adapter.bind_projection(projection.clone())?;
    let (operation, job_id) = match phase {
        ResourceHoldPhase::Held => (
            "hold",
            projected_hold_job_id(
                &args.id,
                &args.resource.resource,
                &hold_epoch,
                &projection.projection_sha256,
            ),
        ),
        ResourceHoldPhase::Unheld => (
            "release",
            projected_release_job_id(&args.id, &args.resource.resource, &hold_epoch),
        ),
    };
    let job = transient_step("Reconcile projected resource hold", || {
        adapter.run_profile_job_result(
            &args.resource.host,
            &job_id,
            &args.id,
            &args.resource.resource,
            &["--operation".to_owned(), operation.to_owned()],
        )
    })?;
    emit_result(&json!({
        "projection": projection,
        "repository": publication,
        "runtime": "reconciled",
        "job": job,
    }))
}

fn execute_new_move(
    state_dir: PathBuf,
    config: PathBuf,
    projection_execution: ProjectionExecution,
    declarative_scope: Option<String>,
    caller_id: Option<&str>,
    items: Vec<MoveItem>,
    guard: &MoveGuard,
) -> Result<()> {
    let publication_mode = projection_execution.mode;
    let mut spec = TransactionSpec::new(caller_id, items, Vec::new(), Vec::new())?;
    spec.declarative_scope = declarative_scope;
    spec.validate()?;
    let mut candidate = TransactionRecord::new(spec, config)?;
    let command_execution = candidate.begin_command(
        LifecycleCommand::Move,
        LifecycleState::Moved,
        None,
        move_command_steps(publication_mode),
    )?;

    if guard.execution.dry_run {
        if let Some(mut record) = WorkflowStore::load_matching(&state_dir, &candidate)? {
            return dry_run_existing_move(
                &mut record,
                guard.force_existing,
                guard.skip_runtime,
                &projection_execution,
            );
        }
        WorkflowStore::validate_registration(&state_dir, &candidate)?;
        let mut adapter = load_execution_adapter(&candidate.config, &projection_execution)?;
        let preflight = transient_step("Check move endpoints and readiness", || {
            preflight_new_workflow(&mut candidate, &mut adapter)
        })?;
        complete_move_prepublication_steps(&mut candidate, command_execution)?;
        return emit_result(&json!({
            "dry_run": true,
            "preflight": preflight,
            "transaction": candidate,
            "authorized_phases": ["setup", "seed"],
            "stops_before": "prepare",
        }));
    }

    if let Some(mut record) = WorkflowStore::load_matching(&state_dir, &candidate)? {
        let store = WorkflowStore::open(state_dir.clone())?;
        if record.projection.is_none()
            && record.phase == abird_host_manager::workflow_runtime::WorkflowPhase::Planned
        {
            publish_seeded_projection(&store, &mut record, &state_dir, &projection_execution)?;
        }
        return execute_existing_move(
            &store,
            record,
            guard.force_existing,
            guard.skip_runtime,
            &projection_execution,
        );
    }
    let mut adapter = load_execution_adapter(&candidate.config, &projection_execution)?;
    let preflight = transient_step("Check move endpoints and readiness", || {
        preflight_new_workflow(&mut candidate, &mut adapter)
    })?;
    complete_move_prepublication_steps(&mut candidate, command_execution)?;
    let store = WorkflowStore::open(state_dir.clone())?;
    let mut record = match store.register(candidate)? {
        WorkflowRegistration::Created(record) => record,
        WorkflowRegistration::Existing(_) => {
            unreachable!("matching workflows were handled before new-move preflight")
        }
    };

    let publication =
        publish_seeded_projection(&store, &mut record, &state_dir, &projection_execution)?;

    if guard.skip_runtime {
        return emit_result(&json!({
            "repository": publication,
            "runtime": "skipped",
            "transaction": record,
        }));
    }

    human_status(format!(
        "Transaction {} persisted · beginning setup and warm seed",
        record.id()
    ));
    let mut adapter = load_execution_adapter(&record.config, &projection_execution)?;
    adapter.bind_projection(
        record
            .projection
            .clone()
            .context("new move has no published phase projection")?,
    )?;
    record.start_command_step(command_execution, "target.provision-or-adopt")?;
    store.save(&record)?;
    let runtime_result = execute_workflow_action(&store, &mut record, Action::Setup, &mut adapter)
        .and_then(|()| execute_workflow_action(&store, &mut record, Action::Seed, &mut adapter));
    if let Err(error) = runtime_result {
        let terminal_failure = matches!(
            validate_failed_workflow_jobs(&store, &mut record, &mut adapter),
            Ok(failed) if !failed.is_empty()
        );
        if terminal_failure {
            record.fail_running_command(format!("{error:#}"))?;
            store.save(&record)?;
        }
        return Err(error);
    }
    for step in move_command_runtime_steps() {
        record.start_command_step(command_execution, step)?;
        record.complete_command_step(command_execution, step, None)?;
    }
    record.complete_command(command_execution)?;
    store.save(&record)?;
    emit_result(&json!({
        "preflight": preflight,
        "repository": publication,
        "runtime": "reconciled",
        "transaction": record,
    }))
}

fn move_command_steps(mode: ProjectionPublicationMode) -> Vec<&'static str> {
    let mut steps = vec![
        "source.resolve-placement",
        "target.resolve-placement",
        "intent.validate",
        "transaction.check-overlap",
        "source.check-agent",
        "source.check-resource",
        "source.check-data-paths",
        "source.check-readiness",
        "target.check-agent-or-provision-route",
        "target.check-deployment-route",
        "repository.prepare-publication",
        "projection.render-seeded",
        "projection.validate",
    ];
    steps.extend(projection_publication_steps(mode));
    steps.extend([
        "target.provision-or-adopt",
        "target.reserve-hold",
        "target.deploy-gated",
        "target.apply-hold",
        "target.verify-stopped",
        "data.warm-seed",
        "data.verify-warm-seed",
        "state.verify-moved",
    ]);
    steps
}

fn complete_move_prepublication_steps(
    record: &mut TransactionRecord,
    execution: usize,
) -> Result<()> {
    for step in move_command_steps(ProjectionPublicationMode::Remote)
        .into_iter()
        .take(10)
    {
        record.start_command_step(execution, step)?;
        record.complete_command_step(execution, step, None)?;
    }
    Ok(())
}

fn move_command_runtime_steps() -> [&'static str; 8] {
    [
        "target.provision-or-adopt",
        "target.reserve-hold",
        "target.deploy-gated",
        "target.apply-hold",
        "target.verify-stopped",
        "data.warm-seed",
        "data.verify-warm-seed",
        "state.verify-moved",
    ]
}

fn projection_publication_steps(mode: ProjectionPublicationMode) -> [&'static str; 3] {
    match mode {
        ProjectionPublicationMode::Remote => [
            "git.commit-projection",
            "git.push-projection",
            "git.verify-remote",
        ],
        ProjectionPublicationMode::Local => [
            "git.commit-projection",
            "git.retain-local-projection",
            "git.verify-local-commit",
        ],
    }
}

fn projection_publication_step(
    stage: ProjectionPublicationStage,
    mode: ProjectionPublicationMode,
) -> &'static str {
    match stage {
        ProjectionPublicationStage::Validate => "projection.validate",
        ProjectionPublicationStage::Commit => "git.commit-projection",
        ProjectionPublicationStage::RetainLocal => "git.retain-local-projection",
        ProjectionPublicationStage::Push => "git.push-projection",
        ProjectionPublicationStage::Verify => match mode {
            ProjectionPublicationMode::Remote => "git.verify-remote",
            ProjectionPublicationMode::Local => "git.verify-local-commit",
        },
    }
}

fn command_has_step(record: &TransactionRecord, execution: usize, step_id: &str) -> bool {
    record
        .command_executions
        .get(execution)
        .is_some_and(|command| command.steps.iter().any(|step| step.id == step_id))
}

fn publish_projection_with_progress(
    publisher: &ProjectionPublisher,
    projection: &PhaseProjection,
    controller_host: &str,
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    command_execution: Option<usize>,
    mode: ProjectionPublicationMode,
) -> Result<ProjectionPublication> {
    let mut active_step = None;
    let mut transient_started = None;
    let result = publisher.publish_observed(projection, controller_host, |event| {
        match event {
            ProjectionPublicationEvent::Started(stage) => {
                let step = projection_publication_step(stage, mode);
                active_step = Some(step);
                if let Some(execution) = command_execution {
                    record.start_command_step(execution, step)?;
                    store.save(record)?;
                } else {
                    command_reporter().started(step.replace(['.', '-'], " "));
                    transient_started = Some(Instant::now());
                }
            }
            ProjectionPublicationEvent::Progress { stage, detail } => {
                debug_assert_eq!(stage, ProjectionPublicationStage::Validate);
                command_reporter().detail(detail);
            }
            ProjectionPublicationEvent::Completed { stage, revision } => {
                let step = projection_publication_step(stage, mode);
                if let Some(execution) = command_execution {
                    record.complete_command_step(
                        execution,
                        step,
                        revision.map(|revision| json!({"revision": revision})),
                    )?;
                    store.save(record)?;
                } else {
                    command_reporter().completed(
                        step.replace(['.', '-'], " "),
                        transient_started
                            .take()
                            .map(|started| started.elapsed())
                            .unwrap_or_default(),
                    );
                }
                active_step = None;
            }
        }
        Ok(())
    });
    if let Err(error) = &result
        && let Some(step) = active_step
    {
        if let Some(execution) = command_execution {
            if record
                .command_executions
                .get(execution)
                .and_then(|command| command.steps.iter().find(|candidate| candidate.id == step))
                .is_some_and(|step| step.status == StepStatus::Running)
            {
                record.fail_command_step(execution, step, format!("{error:#}"))?;
                store.save(record)?;
            }
        } else {
            command_reporter().fail_active(step.replace(['.', '-'], " "), &format!("{error:#}"));
        }
    }
    result
}

fn publish_seeded_projection(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    state_dir: &Path,
    execution: &ProjectionExecution,
) -> Result<abird_host_manager::repository::ProjectionPublication> {
    let command_execution = record.command_executions.iter().rposition(|command| {
        command.command == LifecycleCommand::Move && command.status == CommandStatus::Running
    });
    let preparation_execution = command_execution
        .filter(|execution| command_has_step(record, *execution, "repository.prepare-publication"));
    let source_repository = Repository::discover(execution.repo_root.clone())?;
    if let Some(command_execution) = preparation_execution {
        record.start_command_step(command_execution, "repository.prepare-publication")?;
        store.save(record)?;
    } else {
        command_reporter().started("Prepare publication repository");
    }
    let publisher_result =
        prepare_projection_publisher(&source_repository, store, state_dir, execution);
    let publisher = match publisher_result {
        Ok(publisher) => {
            if let Some(command_execution) = preparation_execution {
                record.complete_command_step(
                    command_execution,
                    "repository.prepare-publication",
                    None,
                )?;
                store.save(record)?;
            } else {
                command_reporter().complete_active("Prepare publication repository");
            }
            publisher
        }
        Err(error) => {
            if let Some(command_execution) = preparation_execution {
                record.fail_command_step(
                    command_execution,
                    "repository.prepare-publication",
                    format!("{error:#}"),
                )?;
                store.save(record)?;
            } else {
                command_reporter()
                    .fail_active("Prepare publication repository", &format!("{error:#}"));
            }
            return Err(error);
        }
    };
    let manager_config = HostManagerConfig::load(&record.config)?;
    if let Some(command_execution) = command_execution {
        record.start_command_step(command_execution, "projection.render-seeded")?;
        store.save(record)?;
    } else {
        command_reporter().started("Render seeded projection");
    }
    let existing = publisher.load_projection(record.id())?;
    let projection = if let Some(existing) = existing {
        existing.validate()?;
        if existing.intent != serde_json::to_value(&record.spec)? || existing.phase != "seeded" {
            bail!("existing repository projection does not match new seeded transaction intent");
        }
        existing
    } else {
        MoveProjector::derive(
            &record.spec,
            &manager_config,
            MovePhase::Seeded,
            None,
            Some(publisher.revision()?),
        )?
    };
    if let Some(command_execution) = command_execution {
        record.complete_command_step(command_execution, "projection.render-seeded", None)?;
        store.save(record)?;
    } else {
        command_reporter().complete_active("Render seeded projection");
    }
    let publication = publish_projection_with_progress(
        &publisher,
        &projection,
        manager_config.controller_host()?,
        store,
        record,
        command_execution,
        execution.mode,
    )?;
    record.set_projection(publication.projection.clone())?;
    store.save(record)?;
    Ok(publication)
}

fn dry_run_existing_move(
    record: &mut TransactionRecord,
    force_existing: bool,
    skip_runtime: bool,
    execution: &ProjectionExecution,
) -> Result<()> {
    let continuation = record.initial_move_continuation();
    let requires_force = matches!(continuation, InitialMoveContinuation::RequiresForce(_));
    let would_resume = match continuation {
        InitialMoveContinuation::Resume(action) => Some(action),
        InitialMoveContinuation::RequiresForce(Some(action)) if force_existing => Some(action),
        InitialMoveContinuation::Complete | InitialMoveContinuation::RequiresForce(_) => None,
    };
    if let Some(action) = would_resume
        && !skip_runtime
    {
        let mut adapter = load_workflow_adapter(record, execution)?;
        preflight_workflow_action(record, action, &mut adapter)?;
    }
    emit_result(&json!({
        "dry_run": true,
        "existing": true,
        "force_existing": force_existing,
        "requires_force_existing": requires_force,
        "would_resume": would_resume,
        "runtime": if skip_runtime { "skipped" } else { "planned" },
        "transaction": record,
    }))
}

fn execute_existing_move(
    store: &WorkflowStore,
    mut record: TransactionRecord,
    force_existing: bool,
    skip_runtime: bool,
    execution: &ProjectionExecution,
) -> Result<()> {
    let continuation = record.initial_move_continuation();
    if let InitialMoveContinuation::RequiresForce(pending) = continuation
        && !force_existing
    {
        let pending = pending
            .map(|action| format!(" with pending {}", action.as_str()))
            .unwrap_or_default();
        bail!(
            "move transaction {:?} was reinvoked in {:?} phase{pending}; inspect it with \
             `transaction show {}` and repeat the move with --force-existing to attach without \
             resetting its journal",
            record.id(),
            record.phase,
            record.id()
        );
    }

    let continuation_message = match continuation {
        InitialMoveContinuation::Resume(action) => format!(
            "move command reinvoked; attached to existing transaction and resuming {}",
            action.as_str()
        ),
        InitialMoveContinuation::Complete => {
            "move command reinvoked; initial setup and seed are already complete".to_owned()
        }
        InitialMoveContinuation::RequiresForce(Some(action)) => format!(
            "move command reinvoked with --force-existing; attached to existing transaction and \
             resuming previously authorized {}",
            action.as_str()
        ),
        InitialMoveContinuation::RequiresForce(None) => format!(
            "move command reinvoked with --force-existing; attached to existing {:?} transaction \
             with no pending action",
            record.phase
        ),
    };
    human_status(&continuation_message);
    record.record_reinvocation(continuation_message)?;
    store.save(&record)?;

    if skip_runtime {
        return emit_result(&json!({
            "runtime": "skipped",
            "transaction": record,
        }));
    }

    match continuation {
        InitialMoveContinuation::Resume(Action::Setup) => {
            let mut adapter = load_workflow_adapter(&record, execution)?;
            execute_workflow_action(store, &mut record, Action::Setup, &mut adapter)?;
            execute_workflow_action(store, &mut record, Action::Seed, &mut adapter)?;
        }
        InitialMoveContinuation::Resume(action)
        | InitialMoveContinuation::RequiresForce(Some(action)) => {
            let mut adapter = load_workflow_adapter(&record, execution)?;
            execute_workflow_action(store, &mut record, action, &mut adapter)?;
        }
        InitialMoveContinuation::Complete | InitialMoveContinuation::RequiresForce(None) => {}
    }
    emit_result(&record)
}

fn transaction_command(
    state_dir: PathBuf,
    config: Option<PathBuf>,
    projection: ProjectionExecution,
    command: TransactionCommand,
) -> Result<()> {
    match command {
        TransactionCommand::Create(args) => {
            require_guard(&args.guard, "transaction create")?;
            let spec: TransactionSpec = read_json_document(&args.spec, "transaction spec")?;
            spec.validate()?;
            let config = resolve_config(config.as_deref(), projection.repo_root.as_deref())?;
            let mut record = TransactionRecord::new(spec, config)?;
            if args.guard.dry_run {
                let mut adapter = load_execution_adapter(&record.config, &projection)?;
                let preflight = transient_step("Check move endpoints and readiness", || {
                    preflight_new_workflow(&mut record, &mut adapter)
                })?;
                return emit_result(&json!({
                    "dry_run": true,
                    "preflight": preflight,
                    "transaction": record,
                    "authorized_phases": ["setup", "seed"],
                    "stops_before": "prepare",
                }));
            }
            let store = WorkflowStore::open(state_dir.clone())?;
            record = match store.register(record)? {
                WorkflowRegistration::Created(record) => record,
                WorkflowRegistration::Existing(record) => bail!(
                    "transaction {:?} already exists in {:?} phase; use an explicit transaction \
                     command to inspect or continue it",
                    record.id(),
                    record.phase
                ),
            };
            let publication =
                publish_seeded_projection(&store, &mut record, &state_dir, &projection)?;
            human_status(format!(
                "Transaction {} persisted · beginning setup and warm seed",
                record.id()
            ));
            let mut adapter = load_workflow_adapter(&record, &projection)?;
            execute_workflow_action(&store, &mut record, Action::Setup, &mut adapter)?;
            execute_workflow_action(&store, &mut record, Action::Seed, &mut adapter)?;
            emit_result(&json!({
                "repository": publication,
                "runtime": "reconciled",
                "transaction": record,
            }))
        }
        TransactionCommand::Show { id } => {
            emit_result(&WorkflowStore::read_only(state_dir).load(&id)?)
        }
        TransactionCommand::List => emit_result(&WorkflowStore::read_only(state_dir).list()?),
        TransactionCommand::Seed(args) => {
            let store = workflow_store(state_dir, args.guard.dry_run)?;
            transaction_phase(&store, args, Action::Seed, &projection)
        }
        TransactionCommand::Prepare(args) => {
            let store = workflow_store(state_dir.clone(), args.guard.dry_run)?;
            projected_transaction_phase(
                &store,
                args,
                Action::Prepare,
                MovePhase::Prepared,
                &state_dir,
                projection,
            )
        }
        TransactionCommand::Verify(args) => {
            let store = workflow_store(state_dir, args.guard.dry_run)?;
            transaction_phase(&store, args, Action::Verify, &projection)
        }
        TransactionCommand::Run(args) => {
            let store = workflow_store(state_dir.clone(), args.guard.dry_run)?;
            projected_transaction_phase(
                &store,
                args,
                Action::Cutover,
                MovePhase::Cutover,
                &state_dir,
                projection,
            )
        }
        TransactionCommand::Rollback(args) => {
            let dry_run = args.guard.dry_run;
            close_transaction(
                workflow_store(state_dir.clone(), dry_run)?,
                TransactionCloseArgs {
                    id: args.id,
                    complete: false,
                    rollback: true,
                    force: false,
                    skip_runtime: args.skip_runtime,
                    yes: false,
                    manual_deploy: false,
                    guard: args.guard,
                },
                &state_dir,
                projection,
            )
        }
        TransactionCommand::ReconcileInternal(args) => {
            let request = ProjectedReconcileRequest {
                id: args.id,
                expected_projection_sha256: Some(args.expected_projection_sha256),
                supersede_failed_job: args.supersede_failed_job,
                guard: args.guard,
                command_name: "transaction _reconcile",
            };
            let store = workflow_store(state_dir.clone(), request.guard.dry_run)?;
            reconcile_projected_transaction(&store, request, &state_dir, projection, config)
        }
        TransactionCommand::CloseReconcileInternal(args) => {
            reconcile_deployed_closeout(&WorkflowStore::open(state_dir)?, args)
        }
        TransactionCommand::Close(args) => {
            let store = workflow_store(state_dir.clone(), args.guard.dry_run)?;
            close_transaction(store, args, &state_dir, projection)
        }
        TransactionCommand::Resume(args) => {
            let store = workflow_store(state_dir.clone(), args.guard.dry_run)?;
            resume_transaction(store, args, &state_dir, projection)
        }
    }
}

fn workflow_store(state_dir: PathBuf, read_only: bool) -> Result<WorkflowStore> {
    if read_only {
        Ok(WorkflowStore::read_only(state_dir))
    } else {
        WorkflowStore::open(state_dir)
    }
}

fn load_read_only_controller_projection(
    state_dir: &Path,
    source_repository: &Repository,
    projection_id: &str,
    journal_projection: Option<&PhaseProjection>,
) -> Result<Option<PhaseProjection>> {
    let owned = Repository::from_root(state_dir.join("projection-repository"))
        .and_then(|repository| repository.load_phase_projection(projection_id))
        .ok()
        .flatten();
    if owned.is_some() {
        return Ok(owned);
    }
    if let Some(journal) = journal_projection {
        return Ok(Some(journal.clone()));
    }
    source_repository.load_phase_projection(projection_id)
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum TransactionResumeStrategy {
    DeployedCloseout {
        projection_sha256: String,
    },
    ActiveCommand {
        command: LifecycleCommand,
        close_decision: Option<CloseDecision>,
    },
    PendingAction(Action),
    ProjectedReconciliation,
}

fn transaction_resume_strategy(record: &TransactionRecord) -> Result<TransactionResumeStrategy> {
    if record.close_decision.is_some()
        && let Some(projection) = &record.projection
        && record.command_executions.iter().rev().any(|execution| {
            execution.command == LifecycleCommand::Close
                && execution.status == CommandStatus::Running
                && execution.steps.iter().any(|step| {
                    is_adoption_deploy_step(&step.id) && step.status == StepStatus::Succeeded
                })
        })
    {
        return Ok(TransactionResumeStrategy::DeployedCloseout {
            projection_sha256: projection.projection_sha256.clone(),
        });
    }
    if let Some(execution) = record
        .command_executions
        .iter()
        .rev()
        .find(|execution| execution.status == CommandStatus::Running)
    {
        return Ok(TransactionResumeStrategy::ActiveCommand {
            command: execution.command,
            close_decision: execution.close_decision,
        });
    }
    if record.projection.is_some() {
        return Ok(TransactionResumeStrategy::ProjectedReconciliation);
    }
    record
        .pending_action
        .map(TransactionResumeStrategy::PendingAction)
        .context("transaction has neither a desired projection nor a pending action to resume")
}

fn resume_transaction(
    store: WorkflowStore,
    args: TransactionResumeArgs,
    state_dir: &Path,
    projection: ProjectionExecution,
) -> Result<()> {
    let mut record = store.load(&args.id)?;
    match transaction_resume_strategy(&record)? {
        TransactionResumeStrategy::DeployedCloseout { projection_sha256 } => {
            require_guard(&args.guard, "transaction resume")?;
            if args.guard.dry_run {
                return emit_result(&json!({
                    "dry_run": true,
                    "resume": "deployed_closeout",
                    "projection_sha256": projection_sha256,
                    "transaction": record,
                }));
            }
            reconcile_deployed_closeout(
                &store,
                TransactionCloseReconcileArgs {
                    id: args.id,
                    expected_projection_sha256: projection_sha256,
                },
            )
        }
        TransactionResumeStrategy::ActiveCommand {
            command: LifecycleCommand::Prepare,
            ..
        } => projected_transaction_phase(
            &store,
            ProjectedTransactionPhaseArgs {
                id: args.id,
                skip_runtime: false,
                guard: args.guard,
            },
            Action::Prepare,
            MovePhase::Prepared,
            state_dir,
            projection,
        ),
        TransactionResumeStrategy::ActiveCommand {
            command: LifecycleCommand::Run,
            ..
        } => projected_transaction_phase(
            &store,
            ProjectedTransactionPhaseArgs {
                id: args.id,
                skip_runtime: false,
                guard: args.guard,
            },
            Action::Cutover,
            MovePhase::Cutover,
            state_dir,
            projection,
        ),
        TransactionResumeStrategy::ActiveCommand {
            command: LifecycleCommand::Close,
            close_decision,
        } => close_transaction(
            store,
            TransactionCloseArgs {
                id: args.id,
                complete: close_decision == Some(CloseDecision::Complete),
                rollback: close_decision == Some(CloseDecision::Rollback),
                force: false,
                skip_runtime: false,
                yes: false,
                manual_deploy: false,
                guard: args.guard,
            },
            state_dir,
            projection,
        ),
        TransactionResumeStrategy::ActiveCommand {
            command: LifecycleCommand::Move,
            ..
        } => {
            if record.projection.is_none() {
                let action = record
                    .pending_action
                    .context("running move has neither a projection nor a pending action")?;
                transaction_phase(
                    &store,
                    TransactionPhaseArgs {
                        id: args.id,
                        guard: args.guard,
                    },
                    action,
                    &projection,
                )
            } else {
                reconcile_projected_transaction(
                    &store,
                    ProjectedReconcileRequest {
                        id: args.id,
                        expected_projection_sha256: None,
                        supersede_failed_job: args.supersede_failed_job,
                        guard: args.guard,
                        command_name: "transaction resume",
                    },
                    state_dir,
                    projection,
                    None,
                )
            }
        }
        TransactionResumeStrategy::ProjectedReconciliation => {
            let request = ProjectedReconcileRequest {
                id: args.id,
                expected_projection_sha256: None,
                supersede_failed_job: args.supersede_failed_job,
                guard: args.guard,
                command_name: "transaction resume",
            };
            reconcile_projected_transaction(&store, request, state_dir, projection, None)
        }
        TransactionResumeStrategy::PendingAction(action) => {
            if should_dry_run(action, &args.guard)? {
                let mut adapter = load_workflow_adapter(&record, &projection)?;
                preflight_workflow_action(&mut record, action, &mut adapter)?;
                let supersede_candidates = if args.supersede_failed_job {
                    validate_failed_workflow_jobs(&store, &mut record, &mut adapter)?
                } else {
                    Vec::new()
                };
                return emit_result(&json!({
                    "dry_run": true,
                    "validated_phase": action,
                    "transaction": record,
                    "action": action,
                    "supersede_failed_job": args.supersede_failed_job,
                    "supersede_candidates": supersede_candidates,
                }));
            }
            let mut adapter = load_workflow_adapter(&record, &projection)?;
            if args.supersede_failed_job {
                preflight_workflow_action(&mut record, action, &mut adapter)?;
                let superseded = supersede_failed_workflow_jobs(&store, &mut record, &mut adapter)?;
                for (old_job_id, new_job_id) in superseded {
                    human_status(format!(
                        "Transaction {} · retrying failed job {} as {}",
                        record.id(),
                        old_job_id,
                        new_job_id
                    ));
                }
            }
            execute_workflow_action(&store, &mut record, action, &mut adapter)?;
            emit_result(&record)
        }
    }
}

fn close_transaction(
    store: WorkflowStore,
    args: TransactionCloseArgs,
    state_dir: &Path,
    execution: ProjectionExecution,
) -> Result<()> {
    let publication_mode = execution.mode;
    let nix_program = execution.nix_program.clone();
    require_guard(&args.guard, "transaction close")?;
    let mut record = store.load(&args.id)?;
    if record.phase == abird_host_manager::workflow_runtime::WorkflowPhase::Closed {
        return emit_result(&json!({
            "already_closed": true,
            "transaction": record,
        }));
    }
    let requested = if args.complete {
        Some(CloseDecision::Complete)
    } else if args.rollback {
        Some(CloseDecision::Rollback)
    } else {
        None
    };
    let source_repository = Repository::discover(execution.repo_root.clone())?;
    let repository_projection = load_read_only_controller_projection(
        state_dir,
        &source_repository,
        record.id(),
        record.projection.as_ref(),
    )?;
    let current = repository_projection
        .as_ref()
        .context("transaction has no repository-backed projection to close")?
        .clone();
    let repository_kind = if is_nix_native_service_move(&current) {
        CloseoutRepositoryKind::NixNative
    } else {
        CloseoutRepositoryKind::Legacy
    };
    let current_phase = current.move_phase()?;
    if requested.is_none() && record.pending_action == Some(Action::Cutover) {
        if args.guard.dry_run {
            return emit_result(&json!({
                "dry_run": true,
                "decision": null,
                "selection": "deferred_until_current_run_reconciles",
                "next": "close will complete if the current run succeeds, roll back on proven terminal failure, and block while outcome remains ambiguous",
                "transaction": record,
            }));
        }
        reconcile_current_run_before_close(&store, &mut record)?;
    }

    let interrupt_run_for_rollback = record.pending_action == Some(Action::Cutover)
        && (args.rollback || requested.is_none() && !record.current_run_succeeded);
    if interrupt_run_for_rollback {
        if args.guard.dry_run {
            mark_interrupted_run_as_potential_writer(None, &mut record)?;
        } else {
            if current_phase == MovePhase::Cutover {
                let mut adapter = load_execution_adapter(&record.config, &execution)?;
                adapter.bind_projection(current.clone())?;
                if let Err(error) = adopt_repository_activation(
                    &store,
                    &mut record,
                    MovePhase::Cutover,
                    &current,
                    &adapter,
                ) {
                    let terminal_failure = matches!(
                        validate_failed_workflow_jobs(&store, &mut record, &mut adapter),
                        Ok(failed) if !failed.is_empty()
                    );
                    if !terminal_failure {
                        return Err(error)
                            .context("cannot safely classify the interrupted target activation");
                    }
                }
            }
            mark_interrupted_run_as_potential_writer(Some(&store), &mut record)?;
            record.fail_running_command_if(
                LifecycleCommand::Run,
                "close rollback superseded the unfinished run attempt",
            )?;
            store.save(&record)?;
        }
    }

    let run_succeeded = current_phase == MovePhase::Cutover && record.current_run_succeeded;
    if args.complete && !args.force && !run_succeeded {
        bail!(
            "completion requires successful current-run evidence; retry `transaction run {}` first, choose `close --rollback`, or use break-glass `close --complete --force` after independently verifying the target",
            record.id()
        );
    }
    if args.force && current_phase != MovePhase::Cutover {
        bail!(
            "forced completion requires the currently published projection to be target-active; publish and verify `transaction run {}` first",
            record.id()
        );
    }
    if args.force && args.skip_runtime {
        bail!(
            "--complete --force requires live endpoint and route verification; remove --skip-runtime"
        );
    }
    let forced_evidence = if args.force && !args.guard.dry_run {
        let mut adapter = load_execution_adapter(&record.config, &execution)?;
        adapter.bind_projection(current.clone())?;
        let evidence = transient_step("Verify forced completion safety", || {
            adapter.verify_forced_completion(true)
        })?;
        record.fail_running_command_if(
            LifecycleCommand::Run,
            "forced completion superseded the unfinished run attempt",
        )?;
        record.record_authorization_event(
            Action::Close,
            "operator forced completion without successful current-run evidence",
        )?;
        store.save(&record)?;
        Some(evidence)
    } else {
        None
    };
    let decision = record.select_close_decision(requested)?;

    match decision {
        CloseDecision::Complete if !run_succeeded && !args.force => {
            bail!(
                "completion requires a successful run; retry `transaction run {}` first, or choose `close --rollback`",
                record.id()
            );
        }
        CloseDecision::Rollback
            if args.skip_runtime
                && record.phase
                    != abird_host_manager::workflow_runtime::WorkflowPhase::RolledBack =>
        {
            bail!(
                "--skip-runtime cannot omit the rollback data path; run close without it, or resume until rollback runtime is complete"
            );
        }
        _ => {}
    }
    let desired_state = match decision {
        CloseDecision::Complete => LifecycleState::ClosedOnTarget,
        CloseDecision::Rollback => LifecycleState::ClosedOnSource,
    };
    let command_execution = record.begin_command(
        LifecycleCommand::Close,
        desired_state,
        Some(decision),
        close_command_steps(publication_mode, repository_kind),
    )?;
    for step in ["state.reconcile-current-run", "close.select-outcome"] {
        record.start_command_step(command_execution, step)?;
        record.complete_command_step(command_execution, step, None)?;
    }

    if args.guard.dry_run {
        let manager_config = HostManagerConfig::load(&record.config)?;
        let terminal_projection = match decision {
            CloseDecision::Complete => current.clone(),
            CloseDecision::Rollback if current_phase == MovePhase::RolledBack => current.clone(),
            CloseDecision::Rollback => MoveProjector::derive_with_observation(
                &record.spec,
                &manager_config,
                MovePhase::RolledBack,
                Some(&current),
                None,
                &move_projection_observation(&record),
            )?,
        };
        if !args.skip_runtime {
            let action = match decision {
                CloseDecision::Complete => Action::Close,
                CloseDecision::Rollback
                    if record.phase
                        != abird_host_manager::workflow_runtime::WorkflowPhase::RolledBack =>
                {
                    Action::Rollback
                }
                _ => Action::Close,
            };
            let mut adapter = load_execution_adapter(&record.config, &execution)?;
            adapter.bind_projection(terminal_projection.clone())?;
            preflight_workflow_action(&mut record, action, &mut adapter)?;
        }
        let forced_live_verification = if args.force {
            let mut adapter = load_execution_adapter(&record.config, &execution)?;
            adapter.bind_projection(terminal_projection.clone())?;
            Some(transient_step("Verify forced completion safety", || {
                adapter.verify_forced_completion(false)
            })?)
        } else {
            None
        };
        return emit_result(&json!({
            "dry_run": true,
            "decision": decision,
            "terminal_projection": terminal_projection,
            "repository_steps": close_command_steps(publication_mode, repository_kind),
            "runtime": if args.skip_runtime { "skipped" } else { "planned" },
            "deployment": if args.manual_deploy { "manual handoff" } else if args.yes { "managed without prompt" } else { "managed after interactive confirmation" },
            "forced_live_verification": forced_live_verification,
            "transaction": record,
        }));
    }

    record.start_command_step(command_execution, "close.persist-decision")?;
    record.complete_command_step(
        command_execution,
        "close.persist-decision",
        Some(json!({
            "decision": decision,
            "forced": args.force,
            "forced_live_verification": forced_evidence,
        })),
    )?;
    store.save(&record)?;
    let journal_repository_preparation =
        command_has_step(&record, command_execution, "repository.prepare-publication");
    if journal_repository_preparation {
        record.start_command_step(command_execution, "repository.prepare-publication")?;
        store.save(&record)?;
    } else {
        command_reporter().started("Prepare publication repository");
    }
    let publisher =
        match prepare_projection_publisher(&source_repository, &store, state_dir, &execution) {
            Ok(publisher) => {
                if journal_repository_preparation {
                    record.complete_command_step(
                        command_execution,
                        "repository.prepare-publication",
                        None,
                    )?;
                    store.save(&record)?;
                } else {
                    command_reporter().complete_active("Prepare publication repository");
                }
                publisher
            }
            Err(error) => {
                if journal_repository_preparation {
                    record.fail_command_step(
                        command_execution,
                        "repository.prepare-publication",
                        format!("{error:#}"),
                    )?;
                    store.save(&record)?;
                } else {
                    command_reporter()
                        .fail_active("Prepare publication repository", &format!("{error:#}"));
                }
                return Err(error);
            }
        };
    let published = match publisher.load_projection(record.id())? {
        Some(published) => published,
        None => {
            let decision_name = match decision {
                CloseDecision::Complete => "complete",
                CloseDecision::Rollback => "rollback",
            };
            if repository_kind == CloseoutRepositoryKind::NixNative {
                publisher.validate_clean_nix_service_move(
                    &current,
                    decision_name,
                    HostManagerConfig::load(&record.config)?.controller_host()?,
                )?;
            } else {
                let closeout = publisher
                    .load_closeout(record.id())?
                    .context("transaction projection disappeared without a canonical closeout")?;
                if closeout.projection_sha256 != current.projection_sha256
                    || closeout.decision != decision_name
                {
                    bail!("canonical closeout does not match the retained close decision");
                }
            }
            let revision = publisher.revision()?;
            let publication = ProjectionCloseoutPublication {
                placement_path: publisher.repository().root().join(match repository_kind {
                    CloseoutRepositoryKind::Legacy => "data/service-placements.json",
                    CloseoutRepositoryKind::NixNative => "data/service-placements.nix",
                }),
                projection_path: publisher.repository().root().join(match repository_kind {
                    CloseoutRepositoryKind::Legacy => {
                        format!("data/phase-projections/{}.json", record.id())
                    }
                    CloseoutRepositoryKind::NixNative => {
                        format!("data/service-moves/{}.nix", record.id())
                    }
                }),
                branch: execution.branch.clone(),
                revision,
                pushed: publisher.pushed(),
            };
            for step in close_command_steps(publication_mode, repository_kind)
                .into_iter()
                .take_while(|step| !is_adoption_deploy_step(step))
                .skip(3)
            {
                record.start_command_step(command_execution, step)?;
                record.complete_command_step(
                    command_execution,
                    step,
                    Some(json!({
                        "adopted_from_canonical_closeout": true,
                        "revision": publication.revision,
                    })),
                )?;
            }
            store.save(&record)?;
            let manager_config = HostManagerConfig::load(&record.config)?;
            return deploy_closeout_and_wait(
                CloseoutDeployContext {
                    store,
                    state_dir,
                    manager_config: &manager_config,
                    nix_program: &nix_program,
                    publisher: &publisher,
                },
                record,
                command_execution,
                decision,
                publication,
                CloseoutDeployOptions {
                    yes: args.yes,
                    manual: args.manual_deploy,
                },
            );
        }
    };
    validate_projection_adoption(record.projection.as_ref(), &published, &record.spec)?;
    record.set_projection(published.clone())?;
    store.save(&record)?;

    let manager_config = HostManagerConfig::load(&record.config)?;
    let terminal_projection = match decision {
        CloseDecision::Complete if published.move_phase()? == MovePhase::Cutover => published,
        CloseDecision::Complete => bail!(
            "completion requires the published target-active projection; retry `transaction run {}`",
            record.id()
        ),
        CloseDecision::Rollback if published.move_phase()? == MovePhase::RolledBack => published,
        CloseDecision::Rollback => {
            if published.move_phase()? == MovePhase::Cutover {
                let mut adoption_adapter = load_execution_adapter(&record.config, &execution)?;
                adoption_adapter.bind_projection(published.clone())?;
                adopt_repository_activation(
                    &store,
                    &mut record,
                    MovePhase::Cutover,
                    &published,
                    &adoption_adapter,
                )?;
            }
            let rollback = MoveProjector::derive_with_observation(
                &record.spec,
                &manager_config,
                MovePhase::RolledBack,
                Some(&published),
                Some(publisher.revision()?),
                &move_projection_observation(&record),
            )?;
            publish_projection_with_progress(
                &publisher,
                &rollback,
                manager_config.controller_host()?,
                &store,
                &mut record,
                None,
                publication_mode,
            )?;
            record.set_projection(rollback.clone())?;
            store.save(&record)?;
            rollback
        }
    };
    record.start_command_step(command_execution, "authority.ensure-terminal")?;
    store.save(&record)?;
    if !args.skip_runtime {
        let mut adapter = load_execution_adapter(&record.config, &execution)?;
        adapter.bind_projection(terminal_projection.clone())?;
        if decision == CloseDecision::Rollback
            && record.phase != abird_host_manager::workflow_runtime::WorkflowPhase::RolledBack
        {
            let actions = reconciliation_actions(&record, MovePhase::RolledBack)?;
            if let Err(error) = reconcile_projected_runtime(
                &store,
                &mut record,
                MovePhase::RolledBack,
                actions,
                &mut adapter,
            ) {
                let terminal_failure = matches!(
                    validate_failed_workflow_jobs(&store, &mut record, &mut adapter),
                    Ok(failed) if !failed.is_empty()
                );
                if terminal_failure {
                    record.fail_command_step(
                        command_execution,
                        "authority.ensure-terminal",
                        format!("{error:#}"),
                    )?;
                    store.save(&record)?;
                }
                return Err(error);
            }
        }
    }
    record.complete_command_step(
        command_execution,
        "authority.ensure-terminal",
        Some(json!({
            "decision": decision,
            "phase": terminal_projection.phase,
            "projection_sha256": terminal_projection.projection_sha256,
            "runtime_phase": record.phase,
        })),
    )?;
    store.save(&record)?;

    let decision_name = match decision {
        CloseDecision::Complete => "complete",
        CloseDecision::Rollback => "rollback",
    };
    let publication = publish_closeout_with_progress(
        &publisher,
        &terminal_projection,
        decision_name,
        manager_config.controller_host()?,
        &store,
        &mut record,
        command_execution,
        publication_mode,
    )?;
    record.lifecycle_state = Some(match decision {
        CloseDecision::Complete => {
            abird_host_manager::workflow_runtime::LifecycleState::ClosingComplete
        }
        CloseDecision::Rollback => {
            abird_host_manager::workflow_runtime::LifecycleState::ClosingRollback
        }
    });
    store.save(&record)?;

    deploy_closeout_and_wait(
        CloseoutDeployContext {
            store,
            state_dir,
            manager_config: &manager_config,
            nix_program: &nix_program,
            publisher: &publisher,
        },
        record,
        command_execution,
        decision,
        publication,
        CloseoutDeployOptions {
            yes: args.yes,
            manual: args.manual_deploy,
        },
    )
}

fn mark_interrupted_run_as_potential_writer(
    store: Option<&WorkflowStore>,
    record: &mut TransactionRecord,
) -> Result<()> {
    let child_store = store
        .map(|store| store.child_store(record.id()))
        .transpose()?;
    for child in record.items.values_mut() {
        child.target_ever_started = true;
        if let Some(child_store) = &child_store {
            child_store.save(child)?;
        }
    }
    record.data_authority = Some(abird_host_manager::workflow_runtime::DataAuthority::Target);
    record.record_authorization_event(
        Action::Rollback,
        "interrupted run conservatively treated target as a potential writer",
    )
}

struct CloseoutDeployContext<'a> {
    store: WorkflowStore,
    state_dir: &'a Path,
    manager_config: &'a HostManagerConfig,
    nix_program: &'a Path,
    publisher: &'a ProjectionPublisher,
}

struct CloseoutDeployOptions {
    yes: bool,
    manual: bool,
}

fn deploy_closeout_and_wait(
    context: CloseoutDeployContext<'_>,
    mut record: TransactionRecord,
    command_execution: usize,
    decision: CloseDecision,
    publication: ProjectionCloseoutPublication,
    options: CloseoutDeployOptions,
) -> Result<()> {
    let CloseoutDeployContext {
        store,
        state_dir,
        manager_config,
        nix_program,
        publisher,
    } = context;
    let controller = manager_config.controller_host()?.to_owned();
    let mut deploy_request = manager_config
        .host(&controller)?
        .nixbot_deploy
        .clone()
        .context("controller has no durable Nixbot deployment identity")?;
    deploy_request.revision = Some(publication.revision.clone());
    let deploy_job_id = format!(
        "closeout-deploy-{}",
        &digest_bytes(format!("{}\0{}", record.id(), publication.revision).as_bytes())[..24]
    );
    let deploy_arguments = [
        "--nixbot-deploy".to_owned(),
        serde_json::to_string(&deploy_request)?,
    ];
    let manual_command = render_manual_nixbot_deploy_command(&deploy_request)?;
    let nix_native = publication
        .projection_path
        .extension()
        .and_then(|value| value.to_str())
        == Some("nix");
    let cleanup_already_published = nix_native && !publication.projection_path.exists();
    let adoption_deploy_step = adoption_deploy_step(nix_native);
    let terminal_projection = record
        .projection
        .clone()
        .context("closeout has no retained terminal projection")?;
    let decision_name = match decision {
        CloseDecision::Complete => "complete",
        CloseDecision::Rollback => "rollback",
    };
    let deploy_mode = select_closeout_deploy_mode(
        options.yes,
        options.manual,
        &publication.revision,
        !publication.pushed,
        nix_native,
    )?;
    if deploy_mode == CloseoutDeployMode::Manual {
        record.annotate_command_step(
            command_execution,
            adoption_deploy_step,
            json!({
                "mode": if publication.pushed { "manual" } else { "local_manual" },
                "revision": publication.revision,
                "controller": controller,
                "request": deploy_request,
                "command": manual_command,
            }),
        )?;
        store.save(&record)?;
        let stage = if nix_native { "Adoption" } else { "Closeout" };
        let continuation = if nix_native {
            "verify the adoption, publish and deploy cleanup, then release recovery holds"
        } else {
            "deploy idempotently and finalize it"
        };
        command_reporter().message(format!(
            "\n{stage} {}. From this repository root, deploy it manually:\n\n  {manual_command}\n\nThe journal remains pending; rerun `transaction close {} {}--yes` to {continuation}.",
            if publication.pushed { "published" } else { "committed locally" },
            record.id(),
            if publication.pushed { "" } else { "--local " },
        ));
        return emit_result(&json!({
            "decision": decision,
            "repository": publication,
            "deployment": {
                "mode": if publication.pushed { "manual" } else { "local_manual" },
                "command": manual_command,
                "request": deploy_request,
            },
            "next": format!(
                "run the deploy command, then transaction close {} {}--yes",
                record.id(),
                if publication.pushed { "" } else { "--local " },
            ),
            "transaction": record,
        }));
    }
    if !publication.pushed {
        record.start_command_step(command_execution, adoption_deploy_step)?;
        store.save(&record)?;
        let repository_root = publication
            .placement_path
            .parent()
            .and_then(Path::parent)
            .context("local closeout placement path has no repository root")?;
        if !cleanup_already_published {
            run_local_nixbot_deploy(nix_program, repository_root, &deploy_request)?;
        }
        record.complete_command_step(
            command_execution,
            adoption_deploy_step,
            Some(json!({
                "revision": publication.revision,
                "adopted_from_cleanup_lineage": cleanup_already_published,
            })),
        )?;
        store.save(&record)?;
        if nix_native {
            let cleanup = if cleanup_already_published {
                publication.clone()
            } else {
                publish_cleanup_with_progress(
                    publisher,
                    &terminal_projection,
                    decision_name,
                    manager_config.controller_host()?,
                    &store,
                    &mut record,
                    command_execution,
                    ProjectionPublicationMode::Local,
                )?
            };
            let mut cleanup_request = deploy_request.clone();
            cleanup_request.revision = Some(cleanup.revision.clone());
            record.start_command_step(command_execution, "nixbot.deploy-cleanup")?;
            store.save(&record)?;
            run_local_nixbot_deploy(nix_program, repository_root, &cleanup_request)?;
            record.complete_command_step(
                command_execution,
                "nixbot.deploy-cleanup",
                Some(json!({"revision": cleanup.revision})),
            )?;
            store.save(&record)?;
        }
        return reconcile_deployed_closeout(
            &store,
            TransactionCloseReconcileArgs {
                id: record.id().to_owned(),
                expected_projection_sha256: record
                    .projection
                    .as_ref()
                    .context("local closeout has no retained terminal projection")?
                    .projection_sha256
                    .clone(),
            },
        );
    }
    record.start_command_step(command_execution, adoption_deploy_step)?;
    if !cleanup_already_published {
        record.bind_command_step_job(
            command_execution,
            adoption_deploy_step,
            &deploy_job_id,
            Some(json!({
                "revision": publication.revision,
                "controller": controller,
                "request": deploy_request,
            })),
        )?;
    }
    store.save(&record)?;
    let deploy_adapter = NativeAdapter::load(&record.config)?;
    if !cleanup_already_published {
        deploy_adapter.submit_profile_job_deferred(
            &controller,
            &deploy_job_id,
            record.id(),
            "controller:nixbot",
            &deploy_arguments,
        )?;
    }

    // The durable Nixbot job owns deployment while the command releases its
    // journal lock. Nix-native closeout is finalized only after the separate
    // cleanup deployment returns successfully.
    drop(store);
    if !cleanup_already_published {
        deploy_adapter.run_profile_job_result(
            &controller,
            &deploy_job_id,
            record.id(),
            "controller:nixbot",
            &deploy_arguments,
        )?;
    }
    let store = WorkflowStore::open(state_dir.to_path_buf())?;
    let mut adoption_record = store.load(record.id())?;
    if !nix_native
        && adoption_record.phase != abird_host_manager::workflow_runtime::WorkflowPhase::Closed
    {
        bail!(
            "closeout revision deployed, but transaction {} is not closed; rerun `transaction close {}` to reconcile the retained close command",
            record.id(),
            record.id()
        );
    }
    if nix_native {
        adoption_record.complete_command_step(
            command_execution,
            adoption_deploy_step,
            Some(json!({
                "revision": publication.revision,
                "adopted_from_cleanup_lineage": cleanup_already_published,
            })),
        )?;
        store.save(&adoption_record)?;
    }
    let cleanup = if nix_native {
        let cleanup = if cleanup_already_published {
            publication.clone()
        } else {
            publish_cleanup_with_progress(
                publisher,
                &terminal_projection,
                decision_name,
                manager_config.controller_host()?,
                &store,
                &mut adoption_record,
                command_execution,
                ProjectionPublicationMode::Remote,
            )?
        };
        let mut cleanup_request = deploy_request.clone();
        cleanup_request.revision = Some(cleanup.revision.clone());
        let cleanup_arguments = [
            "--nixbot-deploy".to_owned(),
            serde_json::to_string(&cleanup_request)?,
        ];
        let cleanup_job_id = format!(
            "closeout-cleanup-deploy-{}",
            &digest_bytes(format!("{}\0{}", record.id(), cleanup.revision).as_bytes())[..24]
        );
        adoption_record.start_command_step(command_execution, "nixbot.deploy-cleanup")?;
        adoption_record.bind_command_step_job(
            command_execution,
            "nixbot.deploy-cleanup",
            &cleanup_job_id,
            Some(json!({
                "revision": cleanup.revision,
                "controller": controller,
                "request": cleanup_request,
            })),
        )?;
        store.save(&adoption_record)?;
        deploy_adapter.submit_profile_job_deferred(
            &controller,
            &cleanup_job_id,
            record.id(),
            "controller:nixbot",
            &cleanup_arguments,
        )?;
        deploy_adapter.run_profile_job_result(
            &controller,
            &cleanup_job_id,
            record.id(),
            "controller:nixbot",
            &cleanup_arguments,
        )?;
        adoption_record = store.load(record.id())?;
        adoption_record.complete_command_step(
            command_execution,
            "nixbot.deploy-cleanup",
            Some(json!({"revision": cleanup.revision})),
        )?;
        store.save(&adoption_record)?;
        Some(cleanup)
    } else {
        None
    };
    let final_record = if nix_native {
        reconcile_deployed_closeout_record(
            &store,
            TransactionCloseReconcileArgs {
                id: record.id().to_owned(),
                expected_projection_sha256: terminal_projection.projection_sha256.clone(),
            },
        )?
    } else {
        store.load(record.id())?
    };
    if final_record.phase != abird_host_manager::workflow_runtime::WorkflowPhase::Closed {
        bail!(
            "clean closeout revision deployed, but transaction {} is not closed; rerun `transaction close {}` to reconcile the retained close command",
            record.id(),
            record.id()
        );
    }
    emit_result(&json!({
        "decision": decision,
        "repository": publication,
        "cleanup": cleanup,
        "deployment_job_id": deploy_job_id,
        "runtime": "closeout deployed and journal closed",
        "transaction": final_record,
    }))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CloseoutDeployMode {
    Managed,
    Manual,
}

fn select_closeout_deploy_mode(
    yes: bool,
    manual: bool,
    revision: &str,
    local: bool,
    nix_native: bool,
) -> Result<CloseoutDeployMode> {
    if manual {
        return Ok(CloseoutDeployMode::Manual);
    }
    if yes || json_output() || !io::stdin().is_terminal() || !io::stderr().is_terminal() {
        return Ok(CloseoutDeployMode::Managed);
    }
    loop {
        let prompt = format!(
            "Deploy {} {} {} now? [Y/m]",
            if local { "local" } else { "published" },
            if nix_native { "adoption" } else { "closeout" },
            &revision[..revision.len().min(12)]
        );
        eprint!(
            "\n{} ",
            TerminalStyle::for_stderr().paint(Tone::Active, prompt)
        );
        io::stderr().flush()?;
        let mut answer = String::new();
        if io::stdin().read_line(&mut answer)? == 0 {
            bail!(
                "deployment confirmation ended without a choice; rerun with --yes or --manual-deploy"
            );
        }
        match answer.trim().to_ascii_lowercase().as_str() {
            "" | "y" | "yes" => return Ok(CloseoutDeployMode::Managed),
            "m" | "manual" => return Ok(CloseoutDeployMode::Manual),
            _ => {
                terminal_warning("Choose Enter/y to deploy here, or m for a manual deploy handoff.")
            }
        }
    }
}

fn render_manual_nixbot_deploy_command(
    request: &abird_host_agent::deployment::NixbotDeployRequest,
) -> Result<String> {
    let revision = request
        .revision
        .as_deref()
        .context("closeout deploy request has no published revision")?;
    let mut arguments = vec![
        "nix run .#nixbot -- deploy".to_owned(),
        format!("--sha {}", shell_word(revision)),
    ];
    if request.exclude_hosts.is_empty() {
        arguments.push(format!("--host {}", shell_word(&request.host)));
    } else {
        let hosts = std::iter::once(request.host.clone())
            .chain(request.exclude_hosts.iter().map(|host| format!("-{host}")))
            .collect::<Vec<_>>()
            .join(",");
        arguments.push(format!("--hosts {}", shell_word(&hosts)));
    }
    if let Some(nix_config) = &request.nix_config {
        arguments.push(format!("--nix-config {}", shell_word(nix_config)));
    }
    arguments.extend([
        "--build-plan-jobs 1".to_owned(),
        "--build-jobs 1".to_owned(),
        "--deploy-jobs 1".to_owned(),
        "--verify-jobs 1".to_owned(),
        "--no-rollback".to_owned(),
    ]);
    Ok(arguments.join(" \\\n    "))
}

fn shell_word(value: &str) -> String {
    if value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"_@%+=:,./-".contains(&byte))
    {
        value.to_owned()
    } else {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
}

fn reconcile_current_run_before_close(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
) -> Result<()> {
    let projection = record
        .projection
        .clone()
        .context("pending run has no target-active projection")?;
    if projection.move_phase()? != MovePhase::Cutover {
        bail!("pending run is not bound to a target-active projection");
    }
    let mut adapter = NativeAdapter::load(&record.config)?;
    adapter.bind_projection(projection)?;
    let terminal_failure = matches!(
        validate_failed_workflow_jobs(store, record, &mut adapter),
        Ok(failed) if !failed.is_empty()
    );
    if terminal_failure {
        record.current_run_succeeded = false;
        let _ = record.fail_running_command("current run has a terminal failed host-agent job");
        record.record_authorization_event(
            Action::Cutover,
            "bare close observed terminal failure in the current run attempt",
        )?;
        return store.save(record);
    }

    let actions = reconciliation_actions(record, MovePhase::Cutover)?;
    if let Err(error) =
        reconcile_projected_runtime(store, record, MovePhase::Cutover, actions, &mut adapter)
    {
        let terminal_failure = matches!(
            validate_failed_workflow_jobs(store, record, &mut adapter),
            Ok(failed) if !failed.is_empty()
        );
        if !terminal_failure {
            return Err(error).context("current run outcome remains incomplete or ambiguous");
        }
        record.current_run_succeeded = false;
        let _ = record.fail_running_command("current run reconciled to terminal failure");
        record.record_authorization_event(
            Action::Cutover,
            "bare close reconciled the current run to a proven terminal failure",
        )?;
        store.save(record)?;
    } else {
        let execution = record.begin_command(
            LifecycleCommand::Run,
            LifecycleState::TargetActive,
            None,
            projected_command_steps(LifecycleCommand::Run, ProjectionPublicationMode::Remote),
        )?;
        for step in projected_command_published_steps(
            LifecycleCommand::Run,
            ProjectionPublicationMode::Remote,
        ) {
            record.start_command_step(execution, step)?;
            record.complete_command_step(
                execution,
                step,
                Some(json!({"adopted_during_close_reconciliation": true})),
            )?;
        }
        complete_projected_command(store, record, execution, LifecycleCommand::Run)?;
    }
    Ok(())
}

fn reconcile_deployed_closeout_record(
    store: &WorkflowStore,
    args: TransactionCloseReconcileArgs,
) -> Result<TransactionRecord> {
    let mut record = store.load(&args.id)?;
    if record.phase == abird_host_manager::workflow_runtime::WorkflowPhase::Closed {
        if !record
            .projection_history
            .contains_key(&args.expected_projection_sha256)
        {
            bail!("deployed closeout digest is not retained by the closed transaction");
        }
        return Ok(record);
    }
    let decision = record
        .close_decision
        .context("deployed closeout has no persisted terminal decision")?;
    let publication_mode = record
        .command_executions
        .iter()
        .rev()
        .find(|execution| {
            execution.command == LifecycleCommand::Close
                && execution.status == abird_host_manager::workflow_runtime::CommandStatus::Running
        })
        .map(|execution| {
            if execution
                .steps
                .iter()
                .any(|step| step.id == "git.retain-local-closeout")
            {
                ProjectionPublicationMode::Local
            } else {
                ProjectionPublicationMode::Remote
            }
        })
        .unwrap_or(ProjectionPublicationMode::Remote);
    let projection = record
        .projection
        .clone()
        .context("deployed closeout journal has no terminal projection")?;
    let repository_kind = if is_nix_native_service_move(&projection) {
        CloseoutRepositoryKind::NixNative
    } else {
        CloseoutRepositoryKind::Legacy
    };
    let command_execution = record.begin_command(
        LifecycleCommand::Close,
        match decision {
            CloseDecision::Complete => LifecycleState::ClosedOnTarget,
            CloseDecision::Rollback => LifecycleState::ClosedOnSource,
        },
        Some(decision),
        close_command_steps(publication_mode, repository_kind),
    )?;
    if projection.projection_sha256 != args.expected_projection_sha256 {
        bail!(
            "deployed closeout digest {} does not match journal terminal projection {}",
            args.expected_projection_sha256,
            projection.projection_sha256
        );
    }
    let expected_phase = match decision {
        CloseDecision::Complete => MovePhase::Cutover,
        CloseDecision::Rollback => MovePhase::RolledBack,
    };
    if projection.move_phase()? != expected_phase {
        bail!("deployed closeout projection does not match its terminal decision");
    }
    let expected_runtime_phase = match decision {
        CloseDecision::Complete => abird_host_manager::workflow_runtime::WorkflowPhase::Cutover,
        CloseDecision::Rollback => abird_host_manager::workflow_runtime::WorkflowPhase::RolledBack,
    };
    if record.phase != expected_runtime_phase {
        bail!(
            "deployed closeout runtime is {:?}, expected {:?}; resume terminal reconciliation before releasing holds",
            record.phase,
            expected_runtime_phase
        );
    }
    for step in close_command_steps(publication_mode, repository_kind)
        .into_iter()
        .take_while(|step| *step != "inactive.release-projection-hold")
    {
        record.start_command_step(command_execution, step)?;
        record.complete_command_step(
            command_execution,
            step,
            Some(json!({
                "adopted_from_deployed_closeout": true,
                "projection_sha256": args.expected_projection_sha256,
            })),
        )?;
    }
    store.save(&record)?;
    let mut adapter = NativeAdapter::load(&record.config)?;
    adapter.bind_projection(projection.clone())?;
    let superseded = if has_pending_close_workflow_action(store, &mut record)? {
        supersede_terminal_failed_workflow_jobs(store, &mut record, &mut adapter)?
    } else {
        Vec::new()
    };
    for (old_job_id, new_job_id) in superseded {
        human_status(format!(
            "Transaction {} · retrying failed close job {} as {}",
            record.id(),
            old_job_id,
            new_job_id
        ));
    }
    execute_workflow_action(store, &mut record, Action::Close, &mut adapter)?;
    record.start_command_step(command_execution, "inactive.release-projection-hold")?;
    record.complete_command_step(command_execution, "inactive.release-projection-hold", None)?;
    if let Some(projection) = record.projection.take() {
        record
            .projection_history
            .insert(projection.projection_sha256.clone(), projection);
    }
    record.start_command_step(command_execution, "transaction.archive")?;
    record.complete_command_step(command_execution, "transaction.archive", None)?;
    record.start_command_step(command_execution, "state.verify-closed")?;
    record.complete_command_step(
        command_execution,
        "state.verify-closed",
        Some(json!({"state": record.effective_lifecycle_state()})),
    )?;
    record.complete_command(command_execution)?;
    store.save(&record)?;
    Ok(record)
}

fn reconcile_deployed_closeout(
    store: &WorkflowStore,
    args: TransactionCloseReconcileArgs,
) -> Result<()> {
    let record = reconcile_deployed_closeout_record(store, args)?;
    emit_result(&json!({
        "deployed_closeout": true,
        "decision": record.close_decision,
        "transaction": record,
    }))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CloseoutRepositoryKind {
    Legacy,
    NixNative,
}

fn close_command_steps(
    mode: ProjectionPublicationMode,
    kind: CloseoutRepositoryKind,
) -> Vec<&'static str> {
    let mut steps = vec![
        "state.reconcile-current-run",
        "close.select-outcome",
        "close.persist-decision",
        "repository.prepare-publication",
        "authority.ensure-terminal",
        "repository.fold-placement",
    ];
    match kind {
        CloseoutRepositoryKind::Legacy => {
            steps.extend(["projection.remove", "repository.validate-closeout"])
        }
        CloseoutRepositoryKind::NixNative => {
            steps.extend(["move.retain-adoption", "repository.validate-adoption"])
        }
    }
    steps.extend(closeout_publication_steps(mode));
    steps.push(adoption_deploy_step(
        kind == CloseoutRepositoryKind::NixNative,
    ));
    if kind == CloseoutRepositoryKind::NixNative {
        steps.extend(["move.remove-adopted", "repository.validate-cleanup"]);
        steps.extend(cleanup_publication_steps(mode));
        steps.push("nixbot.deploy-cleanup");
    }
    steps.extend([
        "inactive.release-projection-hold",
        "transaction.archive",
        "state.verify-closed",
    ]);
    steps
}

fn adoption_deploy_step(nix_native: bool) -> &'static str {
    if nix_native {
        "nixbot.deploy-adoption"
    } else {
        "nixbot.deploy-closeout"
    }
}

fn is_adoption_deploy_step(step: &str) -> bool {
    matches!(step, "nixbot.deploy-adoption" | "nixbot.deploy-closeout")
}

fn closeout_publication_steps(mode: ProjectionPublicationMode) -> [&'static str; 3] {
    match mode {
        ProjectionPublicationMode::Remote => [
            "git.commit-closeout",
            "git.push-closeout",
            "git.verify-remote",
        ],
        ProjectionPublicationMode::Local => [
            "git.commit-closeout",
            "git.retain-local-closeout",
            "git.verify-local-commit",
        ],
    }
}

fn cleanup_publication_steps(mode: ProjectionPublicationMode) -> [&'static str; 3] {
    match mode {
        ProjectionPublicationMode::Remote => [
            "git.commit-cleanup",
            "git.push-cleanup",
            "git.verify-remote-cleanup",
        ],
        ProjectionPublicationMode::Local => [
            "git.commit-cleanup",
            "git.retain-local-cleanup",
            "git.verify-local-cleanup",
        ],
    }
}

fn closeout_publication_step(
    stage: ProjectionCloseoutStage,
    mode: ProjectionPublicationMode,
) -> &'static str {
    match stage {
        ProjectionCloseoutStage::FoldPlacement => "repository.fold-placement",
        ProjectionCloseoutStage::RetainAdoption => "move.retain-adoption",
        ProjectionCloseoutStage::RemoveProjection => "projection.remove",
        ProjectionCloseoutStage::ValidateAdoption => "repository.validate-adoption",
        ProjectionCloseoutStage::Validate => "repository.validate-closeout",
        ProjectionCloseoutStage::Commit => "git.commit-closeout",
        ProjectionCloseoutStage::RetainLocal => "git.retain-local-closeout",
        ProjectionCloseoutStage::Push => "git.push-closeout",
        ProjectionCloseoutStage::Verify => match mode {
            ProjectionPublicationMode::Remote => "git.verify-remote",
            ProjectionPublicationMode::Local => "git.verify-local-commit",
        },
    }
}

fn cleanup_publication_step(
    stage: ProjectionCleanupStage,
    mode: ProjectionPublicationMode,
) -> &'static str {
    match stage {
        ProjectionCleanupStage::RemoveAdoptedMove => "move.remove-adopted",
        ProjectionCleanupStage::Validate => "repository.validate-cleanup",
        ProjectionCleanupStage::Commit => "git.commit-cleanup",
        ProjectionCleanupStage::RetainLocal => "git.retain-local-cleanup",
        ProjectionCleanupStage::Push => "git.push-cleanup",
        ProjectionCleanupStage::Verify => match mode {
            ProjectionPublicationMode::Remote => "git.verify-remote-cleanup",
            ProjectionPublicationMode::Local => "git.verify-local-cleanup",
        },
    }
}

#[allow(clippy::too_many_arguments)]
fn publish_closeout_with_progress(
    publisher: &ProjectionPublisher,
    projection: &PhaseProjection,
    decision: &str,
    controller_host: &str,
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    command_execution: usize,
    mode: ProjectionPublicationMode,
) -> Result<ProjectionCloseoutPublication> {
    let mut active_step = None;
    let result =
        publisher.publish_closeout_observed(projection, decision, controller_host, |event| {
            match event {
                ProjectionCloseoutEvent::Started(stage) => {
                    let step = closeout_publication_step(stage, mode);
                    active_step = Some(step);
                    record.start_command_step(command_execution, step)?;
                    store.save(record)?;
                }
                ProjectionCloseoutEvent::Progress { stage, detail } => {
                    debug_assert!(matches!(
                        stage,
                        ProjectionCloseoutStage::Validate
                            | ProjectionCloseoutStage::ValidateAdoption
                    ));
                    command_reporter().detail(detail);
                }
                ProjectionCloseoutEvent::Completed { stage, revision } => {
                    let step = closeout_publication_step(stage, mode);
                    record.complete_command_step(
                        command_execution,
                        step,
                        revision.map(|revision| json!({"revision": revision})),
                    )?;
                    store.save(record)?;
                    active_step = None;
                }
            }
            Ok(())
        });
    if let Err(error) = &result
        && let Some(step) = active_step
        && record
            .command_executions
            .get(command_execution)
            .and_then(|command| command.steps.iter().find(|candidate| candidate.id == step))
            .is_some_and(|step| step.status == StepStatus::Running)
    {
        record.fail_command_step(command_execution, step, format!("{error:#}"))?;
        store.save(record)?;
    }
    result
}

#[allow(clippy::too_many_arguments)]
fn publish_cleanup_with_progress(
    publisher: &ProjectionPublisher,
    projection: &PhaseProjection,
    decision: &str,
    controller_host: &str,
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    command_execution: usize,
    mode: ProjectionPublicationMode,
) -> Result<ProjectionCloseoutPublication> {
    let mut active_step = None;
    let result = publisher.cleanup_nix_service_move_observed(
        projection,
        decision,
        controller_host,
        |event| {
            match event {
                ProjectionCleanupEvent::Started(stage) => {
                    let step = cleanup_publication_step(stage, mode);
                    active_step = Some(step);
                    record.start_command_step(command_execution, step)?;
                    store.save(record)?;
                }
                ProjectionCleanupEvent::Progress { stage, detail } => {
                    debug_assert_eq!(stage, ProjectionCleanupStage::Validate);
                    command_reporter().detail(detail);
                }
                ProjectionCleanupEvent::Completed { stage, revision } => {
                    let step = cleanup_publication_step(stage, mode);
                    record.complete_command_step(
                        command_execution,
                        step,
                        revision.map(|revision| json!({"revision": revision})),
                    )?;
                    store.save(record)?;
                    active_step = None;
                }
            }
            Ok(())
        },
    );
    if let Err(error) = &result
        && let Some(step) = active_step
        && record
            .command_executions
            .get(command_execution)
            .and_then(|command| command.steps.iter().find(|candidate| candidate.id == step))
            .is_some_and(|step| step.status == StepStatus::Running)
    {
        record.fail_command_step(command_execution, step, format!("{error:#}"))?;
        store.save(record)?;
    }
    result
}

fn transaction_phase(
    store: &WorkflowStore,
    args: TransactionPhaseArgs,
    action: Action,
    execution: &ProjectionExecution,
) -> Result<()> {
    let mut record = store.load(&args.id)?;
    if should_dry_run(action, &args.guard)? {
        let mut adapter = load_workflow_adapter(&record, execution)?;
        preflight_workflow_action(&mut record, action, &mut adapter)?;
        return emit_result(&json!({
            "dry_run": true,
            "validated_phase": action,
            "transaction": record,
            "action": action,
        }));
    }
    let mut adapter = load_workflow_adapter(&record, execution)?;
    execute_workflow_action(store, &mut record, action, &mut adapter)?;
    emit_result(&record)
}

fn load_workflow_adapter(
    record: &TransactionRecord,
    execution: &ProjectionExecution,
) -> Result<NativeAdapter> {
    let mut adapter = load_execution_adapter(&record.config, execution)?;
    if let Some(projection) = &record.projection {
        adapter.bind_projection(projection.clone())?;
    }
    Ok(adapter)
}

fn projected_transaction_phase(
    store: &WorkflowStore,
    args: ProjectedTransactionPhaseArgs,
    action: Action,
    desired_phase: MovePhase,
    state_dir: &Path,
    execution: ProjectionExecution,
) -> Result<()> {
    let publication_mode = execution.mode;
    let mut record = store.load(&args.id)?;
    let dry_run = should_dry_run(action, &args.guard)?;
    let source_repository = Repository::discover(execution.repo_root.clone())?;
    if record.projection.is_none() {
        let source_has_projection = source_repository
            .load_phase_projection(record.id())?
            .is_some();
        let owned_has_projection = Repository::from_root(state_dir.join("projection-repository"))
            .and_then(|repository| repository.load_phase_projection(record.id()))
            .ok()
            .flatten()
            .is_some();
        if !source_has_projection && !owned_has_projection {
            if args.skip_runtime {
                bail!(
                    "--skip-runtime requires a repository-backed transaction; this legacy journal has no move projection"
                );
            }
            return transaction_phase(
                store,
                TransactionPhaseArgs {
                    id: args.id,
                    guard: args.guard,
                },
                action,
                &execution,
            );
        }
    }
    if dry_run {
        let repository_projection = load_read_only_controller_projection(
            state_dir,
            &source_repository,
            record.id(),
            record.projection.as_ref(),
        )?;
        if let Some(published) = &repository_projection {
            validate_projection_adoption(record.projection.as_ref(), published, &record.spec)?;
            record.set_projection(published.clone())?;
        }
        let previous = repository_projection
            .as_ref()
            .or(record.projection.as_ref())
            .context("repository-backed transaction has no prior projection")?
            .clone();
        let lifecycle_command = match action {
            Action::Prepare => LifecycleCommand::Prepare,
            Action::Cutover => LifecycleCommand::Run,
            _ => unreachable!("projected public phases are prepare and run"),
        };
        let desired_state = match action {
            Action::Prepare => LifecycleState::Prepared,
            Action::Cutover => LifecycleState::TargetActive,
            _ => unreachable!("projected public phases are prepare and run"),
        };
        let mut retired_run_jobs = Vec::new();
        if action == Action::Prepare && record.pending_action == Some(Action::Cutover) {
            if previous.move_phase()? != MovePhase::Cutover {
                bail!("pending run is not bound to a target-active projection");
            }
            let mut transition_adapter = load_execution_adapter(&record.config, &execution)?;
            transition_adapter.bind_projection(previous.clone())?;
            retired_run_jobs = plan_terminal_failed_run_for_prepare(&mut record, |item, child| {
                let item_adapter = WorkflowItemAdapter::new(&mut transition_adapter, item);
                let (_, _, status) = item_adapter.active_job_status(child)?;
                Ok(status)
            })?;
        }
        let command_execution = record.begin_command(
            lifecycle_command,
            desired_state,
            None,
            projected_command_steps(lifecycle_command, publication_mode),
        )?;
        plan_workflow_action(&mut record, action)?;
        let manager_config = HostManagerConfig::load(&record.config)?;
        let projection = MoveProjector::derive_with_observation(
            &record.spec,
            &manager_config,
            desired_phase,
            Some(&previous),
            Some(source_repository.revision(&execution.git_program)?),
            &move_projection_observation(&record),
        )?;
        let runtime_actions = reconciliation_actions(&record, desired_phase)?;
        for step in projected_command_prepublication_steps(lifecycle_command) {
            record.start_command_step(command_execution, step)?;
            record.complete_command_step(command_execution, step, None)?;
        }
        if !args.skip_runtime
            && let Some(first_action) = runtime_actions.first().copied()
        {
            let mut adapter = load_execution_adapter(&record.config, &execution)?;
            adapter.bind_projection(projection.clone())?;
            preflight_workflow_action(&mut record, first_action, &mut adapter)?;
        }
        return emit_result(&json!({
            "dry_run": true,
            "action": action,
            "projection": projection,
            "repository_path": if is_nix_native_service_move(&projection) {
                format!("data/service-moves/{}.nix", record.id())
            } else {
                format!("data/phase-projections/{}.json", record.id())
            },
            "runtime_actions": runtime_actions,
            "retired_run_jobs": retired_run_jobs,
            "runtime": if args.skip_runtime { "skipped" } else { "planned" },
            "transaction": record,
        }));
    }
    let lifecycle_command = match action {
        Action::Prepare => LifecycleCommand::Prepare,
        Action::Cutover => LifecycleCommand::Run,
        _ => unreachable!("projected public phases are prepare and run"),
    };
    let desired_state = match action {
        Action::Prepare => LifecycleState::Prepared,
        Action::Cutover => LifecycleState::TargetActive,
        _ => unreachable!("projected public phases are prepare and run"),
    };
    if action == Action::Prepare && record.pending_action == Some(Action::Cutover) {
        let current_projection = record
            .projection
            .clone()
            .context("pending run has no retained target-active projection")?;
        if current_projection.move_phase()? != MovePhase::Cutover {
            bail!("pending run is not bound to a target-active projection");
        }
        let mut transition_adapter = load_execution_adapter(&record.config, &execution)?;
        transition_adapter.bind_projection(current_projection)?;
        command_reporter().started("Resolve terminal failed run");
        let retired_jobs =
            match supersede_terminal_failed_run_for_prepare(store, &mut record, |item, child| {
                let item_adapter = WorkflowItemAdapter::new(&mut transition_adapter, item);
                let (_, _, status) = item_adapter.active_job_status(child)?;
                Ok(status)
            }) {
                Ok(retired_jobs) => {
                    command_reporter().complete_active("Resolve terminal failed run");
                    retired_jobs
                }
                Err(error) => {
                    command_reporter()
                        .fail_active("Resolve terminal failed run", &format!("{error:#}"));
                    return Err(error);
                }
            };
        if retired_jobs.is_empty() {
            human_status(format!(
                "Transaction {} · prepare is replacing the resolved failed run",
                record.id()
            ));
        } else {
            for job_id in retired_jobs {
                human_status(format!(
                    "Transaction {} · prepare retired terminal failed run job {}",
                    record.id(),
                    job_id
                ));
            }
        }
    }
    let mut transition_preview = record.clone();
    plan_workflow_action(&mut transition_preview, action)?;
    let command_execution = record.begin_command(
        lifecycle_command,
        desired_state,
        None,
        projected_command_steps(lifecycle_command, publication_mode),
    )?;
    let prepublication_steps = projected_command_prepublication_steps(lifecycle_command);
    for step in &prepublication_steps[..2] {
        record.start_command_step(command_execution, step)?;
        record.complete_command_step(command_execution, step, None)?;
    }
    let journal_repository_preparation =
        command_has_step(&record, command_execution, "repository.prepare-publication");
    if journal_repository_preparation {
        record.start_command_step(command_execution, "repository.prepare-publication")?;
        store.save(&record)?;
    } else {
        command_reporter().started("Prepare publication repository");
    }
    let publisher =
        match prepare_projection_publisher(&source_repository, store, state_dir, &execution) {
            Ok(publisher) => {
                if journal_repository_preparation {
                    record.complete_command_step(
                        command_execution,
                        "repository.prepare-publication",
                        None,
                    )?;
                    store.save(&record)?;
                } else {
                    command_reporter().complete_active("Prepare publication repository");
                }
                publisher
            }
            Err(error) => {
                if journal_repository_preparation {
                    record.fail_command_step(
                        command_execution,
                        "repository.prepare-publication",
                        format!("{error:#}"),
                    )?;
                    store.save(&record)?;
                } else {
                    command_reporter()
                        .fail_active("Prepare publication repository", &format!("{error:#}"));
                }
                return Err(error);
            }
        };
    let repository_projection = publisher.load_projection(record.id())?;
    if record.projection.is_none() {
        if let Some(published) = &repository_projection {
            validate_projection_adoption(None, published, &record.spec)?;
            record.set_projection(published.clone())?;
            store.save(&record)?;
        } else {
            bail!("repository-backed transaction projection disappeared during refresh");
        }
    }
    if let (Some(journal), Some(published)) =
        (record.projection.as_ref(), repository_projection.as_ref())
        && journal.projection_sha256 != published.projection_sha256
    {
        validate_projection_adoption(Some(journal), published, &record.spec)?;
        record.set_projection(published.clone())?;
        store.save(&record)?;
    }
    let previous = repository_projection
        .as_ref()
        .or(record.projection.as_ref())
        .context("repository-backed transaction has no prior projection")?
        .clone();
    if desired_phase == MovePhase::RolledBack
        && !dry_run
        && !args.skip_runtime
        && previous.move_phase()? == MovePhase::Cutover
    {
        let mut adoption_adapter = load_execution_adapter(&record.config, &execution)?;
        adoption_adapter.bind_projection(previous.clone())?;
        adopt_repository_activation(
            store,
            &mut record,
            MovePhase::Cutover,
            &previous,
            &adoption_adapter,
        )?;
    }
    let mut identity_adapter = load_execution_adapter(&record.config, &execution)?;
    identity_adapter.bind_projection(previous.clone())?;
    if should_auto_supersede_projected_action(action, record.pending_action) {
        let superseded =
            supersede_terminal_failed_workflow_jobs(store, &mut record, &mut identity_adapter)?;
        let command_name = match lifecycle_command {
            LifecycleCommand::Prepare => "prepare",
            LifecycleCommand::Run => "run",
            _ => unreachable!("only prepare and run reconcile projected runtime"),
        };
        for (old_job_id, new_job_id) in superseded {
            human_status(format!(
                "Transaction {} · retrying failed {} job {} as {}",
                record.id(),
                command_name,
                old_job_id,
                new_job_id
            ));
        }
    }
    begin_workflow_action(store, &mut record, action)?;
    let manager_config = HostManagerConfig::load(&record.config)?;
    let observation = move_projection_observation(&record);
    let render_step = match lifecycle_command {
        LifecycleCommand::Prepare => "projection.render-prepared",
        LifecycleCommand::Run => "projection.render-target-active",
        _ => unreachable!(),
    };
    record.start_command_step(command_execution, render_step)?;
    store.save(&record)?;
    let projection = MoveProjector::derive_with_observation(
        &record.spec,
        &manager_config,
        desired_phase,
        Some(&previous),
        Some(publisher.revision()?),
        &observation,
    )?;
    record.complete_command_step(command_execution, render_step, None)?;
    let runtime_actions = reconciliation_actions(&record, desired_phase)?;
    store.save(&record)?;
    let repository_publication = publish_projection_with_progress(
        &publisher,
        &projection,
        manager_config.controller_host()?,
        store,
        &mut record,
        Some(command_execution),
        publication_mode,
    )?;
    let projection = repository_publication.projection.clone();
    record.set_projection(projection.clone())?;
    store.save(&record)?;
    if args.skip_runtime {
        return emit_result(&json!({
            "projection": projection,
            "repository": repository_publication,
            "runtime": "skipped",
            "transaction": record,
        }));
    }
    let mut adapter = load_execution_adapter(&record.config, &execution)?;
    adapter.bind_projection(projection.clone())?;
    let runtime_step = match lifecycle_command {
        LifecycleCommand::Prepare => "runtime.reconcile-prepared",
        LifecycleCommand::Run => "runtime.reconcile-target-active",
        _ => unreachable!(),
    };
    record.start_command_step(command_execution, runtime_step)?;
    store.save(&record)?;
    if let Err(error) = reconcile_projected_runtime(
        store,
        &mut record,
        desired_phase,
        runtime_actions,
        &mut adapter,
    ) {
        let terminal_failure = matches!(
            validate_failed_workflow_jobs(store, &mut record, &mut adapter),
            Ok(failed) if !failed.is_empty()
        );
        if terminal_failure {
            record.fail_command_step(command_execution, runtime_step, format!("{error:#}"))?;
            store.save(&record)?;
        }
        return Err(error);
    }
    complete_projected_command(store, &mut record, command_execution, lifecycle_command)?;
    emit_result(&json!({
        "projection": record.projection,
        "repository": repository_publication,
        "runtime": "reconciled",
        "transaction": record,
    }))
}

fn should_auto_supersede_projected_action(action: Action, pending: Option<Action>) -> bool {
    matches!(action, Action::Prepare | Action::Cutover) && pending == Some(action)
}

fn projected_command_steps(
    command: LifecycleCommand,
    mode: ProjectionPublicationMode,
) -> Vec<&'static str> {
    let (mut steps, runtime): (Vec<&'static str>, [&'static str; 3]) = match command {
        LifecycleCommand::Prepare => (
            vec![
                "state.check-transition",
                "authority.determine",
                "repository.prepare-publication",
                "projection.render-prepared",
                "projection.validate",
            ],
            [
                "runtime.reconcile-prepared",
                "checkpoint.record",
                "state.verify-prepared",
            ],
        ),
        LifecycleCommand::Run => (
            vec![
                "state.check-prepared",
                "checkpoint.verify",
                "repository.prepare-publication",
                "projection.render-target-active",
                "projection.validate",
            ],
            [
                "runtime.reconcile-target-active",
                "state.record-run-success",
                "state.verify-target-active",
            ],
        ),
        _ => unreachable!("only prepare and run have projected command plans"),
    };
    steps.extend(projection_publication_steps(mode));
    steps.extend(runtime);
    steps
}

fn projected_command_prepublication_steps(command: LifecycleCommand) -> Vec<&'static str> {
    projected_command_steps(command, ProjectionPublicationMode::Remote)
        .into_iter()
        .take(4)
        .collect()
}

fn projected_command_published_steps(
    command: LifecycleCommand,
    mode: ProjectionPublicationMode,
) -> Vec<&'static str> {
    projected_command_prepublication_steps(command)
        .into_iter()
        .chain(["projection.validate"])
        .chain(projection_publication_steps(mode))
        .collect()
}

fn complete_projected_command(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    execution: usize,
    command: LifecycleCommand,
) -> Result<()> {
    let steps: &[&str] = match command {
        LifecycleCommand::Prepare => &[
            "runtime.reconcile-prepared",
            "checkpoint.record",
            "state.verify-prepared",
        ],
        LifecycleCommand::Run => &[
            "runtime.reconcile-target-active",
            "state.record-run-success",
            "state.verify-target-active",
        ],
        _ => unreachable!("only prepare and run complete projected command plans"),
    };
    for step in steps {
        record.start_command_step(execution, step)?;
        record.complete_command_step(execution, step, None)?;
    }
    record.complete_command(execution)?;
    store.save(record)
}

fn validate_canonical_closeout_supersedes_projection(
    record: &TransactionRecord,
    closeout: &CanonicalProjectionCloseout,
    expected_projection_sha256: Option<&str>,
) -> Result<()> {
    let projection = record
        .projection
        .as_ref()
        .context("canonical closeout has no retained journal projection to supersede")?;
    if closeout.projection_sha256 != projection.projection_sha256 {
        bail!(
            "canonical closeout digest {} does not match retained journal projection {}",
            closeout.projection_sha256,
            projection.projection_sha256
        );
    }
    if let Some(expected) = expected_projection_sha256
        && closeout.projection_sha256 != expected
    {
        bail!(
            "canonical closeout digest {} does not match deployed controller digest {expected}",
            closeout.projection_sha256
        );
    }
    let decision = record
        .close_decision
        .context("canonical closeout has no persisted journal decision")?;
    let (expected_decision, expected_phase) = match decision {
        CloseDecision::Complete => ("complete", MovePhase::Cutover),
        CloseDecision::Rollback => ("rollback", MovePhase::RolledBack),
    };
    if closeout.decision != expected_decision {
        bail!(
            "canonical closeout decision {:?} does not match persisted journal decision {expected_decision:?}",
            closeout.decision
        );
    }
    if projection.move_phase()? != expected_phase {
        bail!("canonical closeout does not match the retained terminal projection phase");
    }
    Ok(())
}

fn reconcile_projected_transaction(
    store: &WorkflowStore,
    args: ProjectedReconcileRequest,
    state_dir: &Path,
    execution: ProjectionExecution,
    config: Option<PathBuf>,
) -> Result<()> {
    let publication_mode = execution.mode;
    require_guard(&args.guard, args.command_name)?;
    let existing_record = if store.contains(&args.id)? {
        Some(store.load(&args.id)?)
    } else {
        None
    };
    if args.guard.dry_run {
        let mut record = existing_record.context(
            "a dry projected reconcile requires an existing runtime journal; deploy nonterminal Nix intent to initialize it",
        )?;
        let desired_phase = record
            .projection
            .as_ref()
            .map(|projection| projection.move_phase())
            .transpose()?
            .context("transaction has no repository-backed desired projection")?;
        let actions = reconciliation_actions(&record, desired_phase)?;
        let supersede_candidates = if args.supersede_failed_job {
            let action = record
                .pending_action
                .context("transaction has no pending action to supersede")?;
            let mut adapter = load_execution_adapter(&record.config, &execution)?;
            adapter.bind_projection(
                record
                    .projection
                    .clone()
                    .context("transaction has no phase projection")?,
            )?;
            preflight_workflow_action(&mut record, action, &mut adapter)?;
            validate_failed_workflow_jobs(store, &mut record, &mut adapter)?
        } else {
            Vec::new()
        };
        return emit_result(&json!({
            "dry_run": true,
            "desired_phase": desired_phase,
            "actions": actions,
            "projection": record.projection,
            "supersede_failed_job": args.supersede_failed_job,
            "supersede_candidates": supersede_candidates,
            "runtime": "planned",
            "transaction": record,
        }));
    }
    let source_repository = Repository::discover(execution.repo_root.clone())?;
    let publisher = prepare_projection_publisher(&source_repository, store, state_dir, &execution)?;
    let (published, requires_existing_journal) = publisher.load_projection_admission(&args.id)?;
    let mut record = if let Some(record) = existing_record {
        record
    } else {
        let projection = published.as_ref().with_context(|| {
            format!(
                "transaction {:?} has neither a runtime journal nor a Nix-native move declaration",
                args.id
            )
        })?;
        if !is_nix_native_service_move(projection) {
            bail!(
                "legacy repository projection {:?} cannot create a runtime journal; start it through host-manager",
                args.id
            );
        }
        if requires_existing_journal {
            bail!(
                "Nix-native adoption {:?} has no retained runtime journal; terminal placement changes require proven run or rollback evidence",
                args.id
            );
        }
        if let Some(expected) = &args.expected_projection_sha256
            && projection.projection_sha256 != *expected
        {
            bail!(
                "repository projection digest {} does not match deployed controller digest {expected}",
                projection.projection_sha256
            );
        }
        let spec: TransactionSpec = serde_json::from_value(projection.intent.clone())
            .context("decode Nix-native move intent into a runtime transaction")?;
        let config = resolve_config(config.as_deref(), execution.repo_root.as_deref())?;
        let mut candidate = TransactionRecord::new(spec, config)?;
        candidate.set_projection(projection.clone())?;
        let created = match store.register(candidate)? {
            WorkflowRegistration::Created(record) => record,
            WorkflowRegistration::Existing(_) => {
                bail!("Nix-native transaction journal appeared during exclusive registration")
            }
        };
        human_status(format!(
            "Transaction {} · initialized runtime journal from committed Nix intent",
            created.id()
        ));
        created
    };
    let published = match published {
        Some(published) => published,
        None => {
            let closeout = publisher
                .load_closeout(record.id())?
                .context("repository-backed transaction projection disappeared during refresh")?;
            validate_canonical_closeout_supersedes_projection(
                &record,
                &closeout,
                args.expected_projection_sha256.as_deref(),
            )?;
            return emit_result(&json!({
                "superseded_by_closeout": true,
                "closeout": closeout,
                "transaction": record,
            }));
        }
    };
    if let Some(expected) = &args.expected_projection_sha256
        && published.projection_sha256 != *expected
    {
        bail!(
            "repository projection digest {} does not match deployed controller digest {expected}",
            published.projection_sha256
        );
    }
    validate_projection_adoption(record.projection.as_ref(), &published, &record.spec)?;
    if record
        .projection
        .as_ref()
        .is_none_or(|projection| projection.projection_sha256 != published.projection_sha256)
    {
        record.set_projection(published)?;
        store.save(&record)?;
    }
    let desired_phase = record
        .projection
        .as_ref()
        .context("transaction has no repository-backed desired projection")?
        .move_phase()?;
    let actions = reconciliation_actions(&record, desired_phase)?;
    let mut adapter = load_execution_adapter(&record.config, &execution)?;
    adapter.bind_projection(
        record
            .projection
            .clone()
            .context("transaction has no phase projection")?,
    )?;
    if args.supersede_failed_job {
        let action = record
            .pending_action
            .context("transaction has no pending action to supersede")?;
        preflight_workflow_action(&mut record, action, &mut adapter)?;
        let superseded = supersede_failed_workflow_jobs(store, &mut record, &mut adapter)?;
        for (old_job_id, new_job_id) in superseded {
            human_status(format!(
                "Transaction {} · retrying failed job {} as {}",
                record.id(),
                old_job_id,
                new_job_id
            ));
        }
    }
    let projected_command = match desired_phase {
        MovePhase::Seeded => Some((LifecycleCommand::Move, LifecycleState::Moved)),
        MovePhase::Prepared => Some((LifecycleCommand::Prepare, LifecycleState::Prepared)),
        MovePhase::Cutover => Some((LifecycleCommand::Run, LifecycleState::TargetActive)),
        MovePhase::RolledBack => None,
    };
    let command_execution = if let Some((command, state)) = projected_command {
        let plan = match command {
            LifecycleCommand::Move => move_command_steps(publication_mode),
            LifecycleCommand::Prepare | LifecycleCommand::Run => {
                projected_command_steps(command, publication_mode)
            }
            LifecycleCommand::Close => unreachable!(),
        };
        let execution = record.begin_command(command, state, None, plan)?;
        let adopted_steps: Vec<&str> = match command {
            LifecycleCommand::Move => move_command_steps(publication_mode)
                .into_iter()
                .take_while(|step| *step != "target.provision-or-adopt")
                .collect(),
            LifecycleCommand::Prepare | LifecycleCommand::Run => {
                projected_command_published_steps(command, publication_mode)
            }
            LifecycleCommand::Close => unreachable!(),
        };
        for step in adopted_steps {
            record.start_command_step(execution, step)?;
            record.complete_command_step(
                execution,
                step,
                Some(json!({
                    "adopted": true,
                    "projection_sha256": record.projection.as_ref().map(|value| &value.projection_sha256),
                })),
            )?;
        }
        store.save(&record)?;
        Some((execution, command))
    } else {
        None
    };
    if let Some((execution, command)) = command_execution {
        let runtime_step = match command {
            LifecycleCommand::Move => "target.provision-or-adopt",
            LifecycleCommand::Prepare => "runtime.reconcile-prepared",
            LifecycleCommand::Run => "runtime.reconcile-target-active",
            LifecycleCommand::Close => unreachable!(),
        };
        record.start_command_step(execution, runtime_step)?;
        store.save(&record)?;
    }
    reconcile_projected_runtime(store, &mut record, desired_phase, actions, &mut adapter)?;
    if let Some((execution, command)) = command_execution {
        match command {
            LifecycleCommand::Move => {
                for step in move_command_runtime_steps() {
                    record.start_command_step(execution, step)?;
                    record.complete_command_step(execution, step, None)?;
                }
                record.complete_command(execution)?;
                store.save(&record)?;
            }
            LifecycleCommand::Prepare | LifecycleCommand::Run => {
                complete_projected_command(store, &mut record, execution, command)?;
            }
            LifecycleCommand::Close => unreachable!(),
        }
    }
    emit_result(&json!({
        "desired_phase": desired_phase,
        "projection": record.projection,
        "runtime": "reconciled",
        "transaction": record,
    }))
}

fn reconcile_projected_runtime(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    desired_phase: MovePhase,
    mut actions: Vec<Action>,
    adapter: &mut NativeAdapter,
) -> Result<()> {
    if desired_phase == MovePhase::RolledBack {
        adopt_prior_cutover_activation(store, record, adapter)?;
        actions = reconciliation_actions(record, desired_phase)?;
    }
    let projection = record
        .projection
        .clone()
        .context("projected reconciliation requires a current projection")?;
    adapter.bind_projection(projection.clone())?;
    if adopt_repository_activation(store, record, desired_phase, &projection, adapter)? {
        actions = reconciliation_actions(record, desired_phase)?;
    }
    for action in actions {
        if action == Action::Cutover {
            ensure_activation_receipt(store, record, adapter)?;
        }
        if action == Action::Rollback
            && record
                .projection
                .as_ref()
                .and_then(|projection| projection.activation_requirement.as_ref())
                .is_some_and(|requirement| {
                    requirement.kind == "rollback_receipt"
                        && !matches!(
                            record
                                .activation_authorizations
                                .get(&requirement.requirement_sha256),
                            Some(ActivationAuthorization::RepositoryDeploy { .. })
                        )
                })
        {
            let completed = execute_workflow_action_until(
                store,
                record,
                action,
                adapter,
                Some("activate-source"),
            )?;
            if completed {
                bail!("rollback activation barrier was not reached");
            }
            ensure_rollback_receipt(store, record, adapter)?;
            execute_workflow_action(store, record, action, adapter)?;
            continue;
        }
        execute_workflow_action(store, record, action, adapter)?;
        if action == Action::Prepare {
            ensure_activation_receipt(store, record, adapter)?;
        }
    }
    if matches!(desired_phase, MovePhase::Prepared | MovePhase::Cutover) {
        ensure_activation_receipt(store, record, adapter)?;
    }
    Ok(())
}

fn adopt_prior_cutover_activation(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    adapter: &mut NativeAdapter,
) -> Result<()> {
    let current = record
        .projection
        .clone()
        .context("rollback reconciliation requires a current projection")?;
    let Some(previous_digest) = current.previous_projection_sha256.as_deref() else {
        return Ok(());
    };
    let Some(previous) = record.projection_by_digest(previous_digest).cloned() else {
        bail!(
            "rollback projection references prior generation {previous_digest}, but the manager journal does not retain it"
        );
    };
    if previous.move_phase()? != MovePhase::Cutover {
        return Ok(());
    }
    adapter.bind_projection(previous.clone())?;
    adopt_repository_activation(store, record, MovePhase::Cutover, &previous, adapter)?;
    adapter.bind_projection(current)?;
    Ok(())
}

fn adopt_repository_activation(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    desired_phase: MovePhase,
    projection: &PhaseProjection,
    adapter: &NativeAdapter,
) -> Result<bool> {
    use abird_host_manager::workflow_runtime::WorkflowPhase;

    let (role, action) = match desired_phase {
        MovePhase::Cutover if record.phase != WorkflowPhase::Cutover => ("target", Action::Cutover),
        MovePhase::RolledBack if record.phase != WorkflowPhase::RolledBack => {
            ("source", Action::Rollback)
        }
        _ => return Ok(false),
    };
    let Some(evidence) = adapter.retained_repository_activation(role)? else {
        return Ok(false);
    };
    let requirement = projection
        .activation_requirement
        .as_ref()
        .context("repository activation adoption requires an activation requirement")?;
    let evidence_sha256 = canonical_sha256(&evidence)?;
    record.activation_authorizations.insert(
        requirement.requirement_sha256.clone(),
        ActivationAuthorization::RepositoryDeploy {
            projection_digest: projection.projection_sha256.clone(),
            generation: projection.generation,
            evidence_sha256,
        },
    );

    let child_store = store.child_store(record.id())?;
    for child in record.items.values_mut() {
        let completed = match action {
            Action::Cutover => [
                "cutover:assert-source-stopped",
                "cutover:assert-target-stopped",
                "cutover:activate-target",
                "cutover:verify-target-ready",
            ]
            .as_slice(),
            Action::Rollback => [
                "rollback:hold-target",
                "rollback:assert-target-stopped",
                "rollback:reverse-transfer",
                "rollback:verify-reverse",
                "rollback:activate-source",
                "rollback:verify-source-ready",
            ]
            .as_slice(),
            _ => unreachable!("repository adoption supports only activation actions"),
        };
        child
            .overridden_steps
            .extend(completed.iter().map(|step| (*step).to_owned()));
        child.pending_action = None;
        child.active_step = None;
        child.active_job_id = None;
        child.last_error = None;
        if action == Action::Cutover {
            child.phase = ItemPhase::Prepared;
            child.target_ever_started = true;
        } else if matches!(child.phase, ItemPhase::Planned | ItemPhase::Setup) {
            child.phase = ItemPhase::Seeded;
        }
        child_store.save(child)?;
    }
    if action == Action::Cutover {
        record.phase = WorkflowPhase::Prepared;
    } else if matches!(record.phase, WorkflowPhase::Planned | WorkflowPhase::Setup) {
        record.phase = WorkflowPhase::Seeded;
    }
    record.pending_action = None;
    record.record_authorization_event(
        action,
        format!(
            "adopted trusted repository deployment activation for projection {}",
            projection.projection_sha256
        ),
    )?;
    store.save(record)?;
    Ok(true)
}

fn ensure_rollback_receipt(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    adapter: &mut NativeAdapter,
) -> Result<()> {
    let projection = record
        .projection
        .clone()
        .context("transaction has no rollback projection")?;
    let requirement = projection
        .activation_requirement
        .as_ref()
        .filter(|requirement| requirement.kind == "rollback_receipt")
        .context("rollback projection has no rollback activation requirement")?;
    if let Some(authorization) = record
        .activation_authorizations
        .get(&requirement.requirement_sha256)
        .cloned()
    {
        match authorization {
            ActivationAuthorization::BrokeredReceipt { receipt } => {
                receipt.validate_for(&projection)?
            }
            ActivationAuthorization::RepositoryDeploy { .. } => return Ok(()),
        }
    } else {
        let evidence = adapter.retained_rollback_evidence(record)?;
        let receipt = MoveProjector::derive_rollback_receipt(&projection, &evidence)?;
        record.activation_authorizations.insert(
            receipt.requirement_digest.clone(),
            ActivationAuthorization::BrokeredReceipt { receipt },
        );
    }
    store.save(record)?;
    Ok(())
}

fn ensure_activation_receipt(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    adapter: &mut NativeAdapter,
) -> Result<()> {
    use abird_host_manager::workflow_runtime::WorkflowPhase;

    if !matches!(
        record.phase,
        WorkflowPhase::Prepared | WorkflowPhase::Verified | WorkflowPhase::Cutover
    ) {
        bail!("activation receipt requires successfully completed prepare runtime state");
    }
    let projection = record
        .projection
        .clone()
        .context("transaction has no phase projection")?;
    let requirement = projection
        .activation_requirement
        .as_ref()
        .context("phase projection has no activation requirement")?;
    if let Some(authorization) = record
        .activation_authorizations
        .get(&requirement.requirement_sha256)
        .cloned()
    {
        match authorization {
            ActivationAuthorization::BrokeredReceipt { receipt } => {
                receipt.validate_for(&projection)?
            }
            ActivationAuthorization::RepositoryDeploy { .. } => return Ok(()),
        }
    } else {
        let evidence = adapter.retained_prepare_evidence(record)?;
        let receipt = MoveProjector::derive_activation_receipt(&projection, &evidence)?;
        record.activation_authorizations.insert(
            receipt.requirement_digest.clone(),
            ActivationAuthorization::BrokeredReceipt { receipt },
        );
    }
    store.save(record)?;
    Ok(())
}

fn reconciliation_actions(
    record: &TransactionRecord,
    desired_phase: MovePhase,
) -> Result<Vec<Action>> {
    use abird_host_manager::workflow_runtime::WorkflowPhase;

    if desired_phase == MovePhase::RolledBack {
        return match record.phase {
            WorkflowPhase::RolledBack => Ok(Vec::new()),
            WorkflowPhase::Closed => bail!("closed transaction cannot be reconciled"),
            _ => Ok(vec![Action::Rollback]),
        };
    }
    let rank = |phase: MovePhase| match phase {
        MovePhase::Seeded => 1,
        MovePhase::Prepared => 2,
        MovePhase::Cutover => 3,
        MovePhase::RolledBack => unreachable!(),
    };
    let target = rank(desired_phase);
    let mut actions = Vec::new();
    match record.phase {
        WorkflowPhase::Planned => {
            actions.push(Action::Setup);
            actions.push(Action::Seed);
            if target >= 2 {
                actions.push(Action::Prepare);
            }
            if target >= 3 {
                actions.push(Action::Cutover);
            }
        }
        WorkflowPhase::Setup => {
            actions.push(Action::Seed);
            if target >= 2 {
                actions.push(Action::Prepare);
            }
            if target >= 3 {
                actions.push(Action::Cutover);
            }
        }
        WorkflowPhase::Seeded => {
            if target >= 2 {
                actions.push(Action::Prepare);
            }
            if target >= 3 {
                actions.push(Action::Cutover);
            }
        }
        WorkflowPhase::Prepared | WorkflowPhase::Verified => {
            if desired_phase == MovePhase::Prepared
                && record.pending_action == Some(Action::Prepare)
            {
                actions.push(Action::Prepare);
            } else if target >= 3 {
                actions.push(Action::Cutover);
            }
        }
        WorkflowPhase::Cutover if target == 3 => {}
        WorkflowPhase::Cutover if target == 2 => actions.push(Action::Prepare),
        WorkflowPhase::Cutover => bail!("repository desired phase is behind observed cutover"),
        WorkflowPhase::RolledBack => bail!("rolled-back transaction cannot reconcile forward"),
        WorkflowPhase::Closed => bail!("closed transaction cannot be reconciled"),
    }
    if let Some(pending) = record.pending_action
        && actions.first().copied() != Some(pending)
    {
        bail!(
            "transaction has pending {} outside the projected reconciliation path",
            pending.as_str()
        );
    }
    Ok(actions)
}

fn move_projection_observation(record: &TransactionRecord) -> MoveProjectionObservation {
    let mut observation = MoveProjectionObservation::default();
    for (item_id, item) in &record.items {
        observation.insert(
            item_id,
            MoveItemObservation {
                source_held: item.completed_steps.contains("prepare:hold-source"),
                target_ever_started: item.target_ever_started,
                source_activation_job_id: Some(deterministic_job_id(
                    item,
                    Action::Rollback,
                    "activate-source",
                )),
                target_activation_job_id: Some(deterministic_job_id(
                    item,
                    Action::Cutover,
                    "activate-target",
                )),
            },
        );
    }
    observation
}

fn validate_projection_adoption(
    journal: Option<&abird_host_manager::projection::PhaseProjection>,
    published: &abird_host_manager::projection::PhaseProjection,
    spec: &TransactionSpec,
) -> Result<()> {
    published.validate()?;
    if published.intent != serde_json::to_value(spec)? || published.projection_id != spec.id {
        bail!("repository projection does not match immutable transaction intent");
    }
    let Some(journal) = journal else {
        if published.generation != 1 || published.previous_projection_sha256.is_some() {
            bail!("controller can adopt only a first-generation projection without a predecessor");
        }
        return Ok(());
    };
    if journal.projection_sha256 == published.projection_sha256 {
        return Ok(());
    }
    if published.generation != journal.generation + 1
        || published.previous_projection_sha256.as_deref()
            != Some(journal.projection_sha256.as_str())
        || !published.move_phase()?.can_follow(journal.move_phase()?)
    {
        bail!(
            "repository projection generation {} does not directly and validly follow controller generation {}",
            published.generation,
            journal.generation
        );
    }
    Ok(())
}

fn host_command(config: &HostManagerConfig, command: HostCommand) -> Result<()> {
    match command {
        HostCommand::List(selection) => {
            let selected = select_hosts(
                &config.hosts,
                selection.group.as_deref(),
                selection.hosts.as_deref(),
            )?;
            let summaries = selected
                .into_iter()
                .map(|name| config.host_summary(name))
                .collect::<Result<Vec<_>>>()?;
            emit_result(&summaries)
        }
        HostCommand::Show { host } => emit_result(config.host(&host)?),
        HostCommand::Exec { host, argv } => config.run_host_command_interactive(&host, &argv),
        HostCommand::Ssh(args) => config.open_ssh(&args.host, &args.args),
        HostCommand::Logs(args) => {
            let mut agent_args = vec!["logs".to_owned()];
            append_log_options(&mut agent_args, &args.logs);
            config.run_agent_interactive(&args.host, &agent_args)
        }
        HostCommand::Holds { host } => hold_list(config, host),
        HostCommand::Drain(args) => durable_host_action(config, args, "hold"),
        HostCommand::Activate(args) => durable_host_action(config, args, "activate"),
        HostCommand::Reboot(args) => {
            fleet_agent_action(config, args, "reboot", &["maintenance", "reboot"])
        }
        HostCommand::Gc(args) => host_gc(config, args),
        HostCommand::Clean(args) => host_clean(config, args),
        HostCommand::Move(_)
        | HostCommand::Create { .. }
        | HostCommand::Build(_)
        | HostCommand::Install(_)
        | HostCommand::Delete(_) => unreachable!(),
    }
}

fn host_create_args(kind: HostCreateKind) -> Result<HostGenerateArgs> {
    let (
        common,
        system_module,
        system,
        disk,
        hardware_config,
        boot_mode,
        esp_size,
        boot_size,
        swap_size_mib,
        fresh_storage_ids,
        incus_parent,
        incus_project,
        incus_ipv4,
        start_priority,
        nested_containers,
    ) = match kind {
        HostCreateKind::External(args) => (
            args.common,
            args.system_module,
            HostSystem::None,
            None,
            None,
            HostBootMode::Efi,
            "1G".parse()?,
            "1G".parse()?,
            0,
            false,
            None,
            "default".to_owned(),
            None,
            50,
            true,
        ),
        HostCreateKind::Incus(args) => (
            args.common,
            args.system_module,
            HostSystem::Incus,
            None,
            None,
            HostBootMode::Efi,
            "1G".parse()?,
            "1G".parse()?,
            0,
            false,
            Some(args.incus_parent),
            args.incus_project,
            Some(args.incus_ipv4),
            args.start_priority,
            args.nested_containers,
        ),
        HostCreateKind::Physical(args) => (
            args.common,
            None,
            HostSystem::Live,
            Some(args.disk),
            args.hardware_config,
            args.boot_mode,
            args.esp_size,
            args.boot_size,
            args.swap_size_mib,
            args.fresh_storage_ids,
            None,
            "default".to_owned(),
            None,
            50,
            true,
        ),
    };
    Ok(HostGenerateArgs {
        host: common.host,
        system,
        stack: common.stack,
        target: common.target,
        proxy_jump: common.proxy_jump,
        groups: common.groups,
        system_module,
        disk,
        hardware_config,
        boot_mode,
        esp_size,
        boot_size,
        swap_size_mib,
        fresh_storage_ids,
        incus_parent,
        incus_project,
        incus_ipv4,
        start_priority,
        nested_containers,
        force: common.force,
        guard: common.guard,
    })
}

fn repository_generate(
    repo_root: Option<PathBuf>,
    programs: &RepositoryPrograms,
    nixos_generate_config_program: &Path,
    args: HostGenerateArgs,
) -> Result<()> {
    let repository = Repository::discover(repo_root)?;
    let physical = args.disk.is_some();
    let system = match (ManagedHostSystem::from(args.system), physical) {
        (ManagedHostSystem::None, true) => ManagedHostSystem::Live,
        (system, _) => system,
    };
    if system == ManagedHostSystem::Live && !physical && args.system_module.is_none() {
        bail!("physical --system live generation requires --disk or --system-module");
    }
    if system == ManagedHostSystem::Incus && physical {
        bail!("--disk cannot be combined with --system incus");
    }
    if args.fresh_storage_ids && !args.force {
        bail!("--fresh-storage-ids requires --force");
    }
    let incus = if system == ManagedHostSystem::Incus {
        Some(ManagedIncus {
            parent: args
                .incus_parent
                .clone()
                .context("--system incus requires --incus-parent")?,
            project: args.incus_project,
            ipv4_address: args
                .incus_ipv4
                .clone()
                .context("--system incus requires --incus-ipv4")?,
            start_priority: args.start_priority,
            nested_containers: args.nested_containers,
        })
    } else {
        if args.incus_parent.is_some() || args.incus_ipv4.is_some() {
            bail!("Incus placement options require --system incus");
        }
        None
    };
    let record = ManagedHost {
        system,
        stack: args.stack,
        target: args
            .target
            .unwrap_or_else(|| args.incus_ipv4.unwrap_or_else(|| args.host.clone())),
        proxy_jump: args
            .proxy_jump
            .or_else(|| incus.as_ref().map(|value| value.parent.clone())),
        groups: args.groups,
        incus,
    };
    let physical_request = args
        .disk
        .clone()
        .map(PhysicalLayoutRequest::new)
        .transpose()?
        .map(|mut request| {
            request.boot_mode = BootMode::from(args.boot_mode);
            request.esp_size = args.esp_size.clone();
            request.boot_size = args.boot_size.clone();
            request.swap_size_mib = args.swap_size_mib;
            request
        });
    if args.guard.dry_run {
        return emit_result(&json!({
            "dry_run": true,
            "operation": "host_generate",
            "repository": repository.root(),
            "host": args.host,
            "record": record,
            "system_module": args.system_module,
            "physical": physical_request.as_ref().map(|request| json!({
                "disk": request.disk,
                "boot_mode": request.boot_mode,
                "esp_size": request.esp_size.as_str(),
                "boot_size": request.boot_size.as_str(),
                "swap_size_mib": request.swap_size_mib,
                "hardware_config": args.hardware_config,
                "fresh_storage_ids": args.fresh_storage_ids,
            })),
            "force": args.force,
        }));
    }
    let change = transient_step("Generate host declaration", || {
        if let Some(request) = physical_request {
            let hardware_source = if let Some(path) = args.hardware_config {
                fs::read_to_string(&path)
                    .with_context(|| format!("read hardware config {}", path.display()))?
            } else {
                NixosGenerateConfig::new(nixos_generate_config_program.to_path_buf())?
                    .show_hardware_config(
                        &Privilege::new(&programs.privilege)?,
                        repository.root(),
                    )?
            };
            let hardware = HardwareProjection::from_nixos_hardware_config(&hardware_source)?;
            repository.generate_physical(
                &args.host,
                record,
                request,
                &hardware,
                args.fresh_storage_ids,
                args.force,
            )
        } else {
            repository.generate(
                &args.host,
                record,
                args.system_module.as_deref(),
                args.force,
            )
        }
    })?;
    emit_result(&change)
}

fn repository_build(
    repo_root: Option<PathBuf>,
    programs: &RepositoryPrograms,
    args: HostBuildArgs,
) -> Result<()> {
    let repository = Repository::discover(repo_root)?;
    if args.guard.dry_run {
        return emit_result(&json!({
            "dry_run": true,
            "operation": "host_build",
            "repository": repository.root(),
            "host": args.host,
            "offline_cache": args.offline_cache,
        }));
    }
    let artifacts = transient_step("Build host system", || {
        repository.build_artifacts(programs, &args.host, args.offline_cache.as_deref())
    })?;
    emit_result(&artifacts)
}

fn repository_install(
    repo_root: Option<PathBuf>,
    programs: &RepositoryPrograms,
    args: HostInstallArgs,
) -> Result<()> {
    let repository = Repository::discover(repo_root)?;
    if args.guard.dry_run {
        return emit_result(&json!({
            "dry_run": true,
            "operation": "host_live_install",
            "repository": repository.root(),
            "host": args.host,
            "root": args.root,
            "offline_cache": args.offline_cache,
            "wipe_disks": args.wipe_disks,
        }));
    }
    let prepared = transient_step("Resolve exact offline installation", || {
        repository.prepare_live_install(
            programs,
            &args.host,
            &args.root,
            args.offline_cache.as_deref(),
        )
    })?;
    transient_step("Install prepared host system", || {
        repository.execute_prepared_install(programs, &prepared, args.wipe_disks)
    })?;
    emit_result(&prepared)
}

fn repository_delete(repo_root: Option<PathBuf>, args: HostDeleteArgs) -> Result<()> {
    let repository = Repository::discover(repo_root)?;
    if args.guard.dry_run {
        return emit_result(&json!({
            "dry_run": true,
            "operation": "host_delete",
            "repository": repository.root(),
            "host": args.host,
        }));
    }
    let change = transient_step("Remove manager-owned host registration", || {
        repository.delete(&args.host)
    })?;
    emit_result(&change)
}

fn host_gc(config: &HostManagerConfig, args: HostGcArgs) -> Result<()> {
    if !args.all_generations && !safe_age(&args.delete_older_than) {
        bail!("--delete-older-than must contain only letters, digits, '.', '+', or '-'");
    }
    let command = if args.all_generations {
        vec!["maintenance", "gc", "--all"]
    } else {
        vec![
            "maintenance",
            "gc",
            "--delete-older-than",
            args.delete_older_than.as_str(),
        ]
    };
    fleet_agent_action(config, args.fleet, "gc", &command)
}

fn host_clean(config: &HostManagerConfig, args: HostCleanArgs) -> Result<()> {
    let kind = match args.scope {
        CleanKind::Deploy => "deploy",
        CleanKind::Podman => "podman",
        CleanKind::Nixbot => "nixbot",
    };
    let mut command = vec!["maintenance", "clean", "--kind", kind];
    if args.force_held {
        command.push("--force-held");
    }
    fleet_agent_action(config, args.fleet, "clean", &command)
}

fn fleet_agent_action(
    config: &HostManagerConfig,
    args: FleetActionArgs,
    operation: &str,
    agent_command: &[&str],
) -> Result<()> {
    if args.jobs == 0 || args.jobs > 128 {
        bail!("--jobs must be between 1 and 128");
    }
    let hosts = select_hosts(
        &config.hosts,
        args.selection.group.as_deref(),
        args.selection.hosts.as_deref(),
    )?;
    if args.guard.dry_run {
        return emit_result(&json!({
            "dry_run": true,
            "operation": operation,
            "hosts": hosts,
            "jobs": args.jobs,
            "agent_argv": agent_command,
        }));
    }
    let mut argv = vec!["--json".to_owned()];
    argv.extend(agent_command.iter().map(|value| (*value).to_owned()));
    let hosts = hosts.into_iter().map(str::to_owned).collect::<Vec<_>>();
    let mut results = Vec::with_capacity(hosts.len());
    let mut failures = 0_usize;
    for batch in hosts.chunks(args.jobs) {
        let batch_label = fleet_batch_label(operation, batch.len());
        let batch_started = Instant::now();
        command_reporter().started(batch_label.clone());
        let failures_before = failures;
        let handles = batch
            .iter()
            .map(|host| {
                let config = config.clone();
                let host = host.clone();
                let argv = argv.clone();
                std::thread::spawn(move || {
                    let result = config.run_agent(&host, &argv);
                    (host, result)
                })
            })
            .collect::<Vec<_>>();
        for handle in handles {
            let (host, output) = handle
                .join()
                .map_err(|_| anyhow::anyhow!("fleet worker panicked"))?;
            match output {
                Ok(output) => results.push(json!({
                    "host": host,
                    "ok": true,
                    "result": output,
                })),
                Err(error) => {
                    failures += 1;
                    results.push(json!({
                        "host": host,
                        "ok": false,
                        "error": format!("{error:#}"),
                    }));
                }
            }
        }
        if failures == failures_before {
            command_reporter().completed(batch_label, batch_started.elapsed());
        } else {
            command_reporter().fail_active(
                batch_label,
                &format!("{} host operations failed", failures - failures_before),
            );
        }
    }
    emit_result(&json!({
        "ok": failures == 0,
        "operation": operation,
        "jobs": args.jobs,
        "failures": failures,
        "results": results,
    }))?;
    if failures != 0 {
        return Err(RenderedCommandFailure.into());
    }
    Ok(())
}

fn fleet_batch_label(operation: &str, hosts: usize) -> String {
    if operation == "reboot" {
        format!("Submit reboot request to {hosts} hosts")
    } else {
        format!("Apply {operation} on {hosts} hosts")
    }
}

fn safe_age(value: &str) -> bool {
    !value.is_empty()
        && !value.starts_with('-')
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'+' | b'-'))
}

fn durable_host_action(
    config: &HostManagerConfig,
    args: DurableHostActionArgs,
    operation: &str,
) -> Result<()> {
    let resource = config.host_resource(&args.host)?;
    durable_resource_action_with_config(
        config,
        DurableResourceActionArgs {
            resource: ResourceArgs {
                host: args.host,
                resource,
            },
            transaction: args.transaction,
            guard: args.guard,
        },
        operation,
    )
}

fn service_command(
    config: &HostManagerConfig,
    repo_root: Option<PathBuf>,
    nix_program: &Path,
    command: ServiceCommand,
) -> Result<()> {
    let command = match command {
        ServiceCommand::Wipe(args) => {
            let target = resolve_logical_service(config, repo_root, nix_program, args.service)?;
            let ResolvedServiceTarget::Resource { host, resource } = target else {
                bail!("logical service wipe requires a declared host-agent resource");
            };
            let adapter = NativeAdapter::from_config(config.clone()).with_progress(true);
            return wipe_resource(
                &adapter,
                &host,
                &resource,
                args.id.as_deref(),
                args.owner.as_deref(),
                &args.guard,
            );
        }
        ServiceCommand::Logs(args) => {
            let target = resolve_logical_service(config, repo_root, nix_program, args.service)?;
            let mut agent_args = service_agent_args("logs", target, false)?;
            append_log_options(&mut agent_args, &args.logs);
            return config.run_agent_interactive(&agent_args[0], &agent_args[1..]);
        }
        command => command,
    };
    let (operation, args, guard) = match command {
        ServiceCommand::Start(args) => ("start", args.service, Some(args.guard)),
        ServiceCommand::Stop(args) => ("stop", args.service, Some(args.guard)),
        ServiceCommand::Restart(args) => ("restart", args.service, Some(args.guard)),
        ServiceCommand::Reload(args) => ("reload", args.service, Some(args.guard)),
        ServiceCommand::Status(args) => ("status", args, None),
        ServiceCommand::Move(_) | ServiceCommand::Wipe(_) | ServiceCommand::Logs(_) => {
            unreachable!()
        }
    };
    let target = resolve_logical_service(config, repo_root, nix_program, args)?;
    let mutating = guard.is_some();
    if let Some(guard) = guard
        && direct_mutation_guard("service", operation, &target, &guard)?
    {
        return Ok(());
    }
    let agent_args = service_agent_args(operation, target, true)?;
    let result = if mutating {
        transient_step(
            format!("{} logical service", operation_title(operation)),
            || config.run_agent(&agent_args[0], &agent_args[1..]),
        )?
    } else {
        config.run_agent(&agent_args[0], &agent_args[1..])?
    };
    emit_result(&result)
}

fn unit_command(config: &HostManagerConfig, command: UnitCommand) -> Result<()> {
    let command = match command {
        UnitCommand::Logs(args) => {
            let target = resolve_unit(args.unit)?;
            let mut agent_args = service_agent_args("logs", target, false)?;
            append_log_options(&mut agent_args, &args.logs);
            return config.run_agent_interactive(&agent_args[0], &agent_args[1..]);
        }
        command => command,
    };
    let (operation, args, guard) = match command {
        UnitCommand::Start(args) => ("start", args.unit, Some(args.guard)),
        UnitCommand::Stop(args) => ("stop", args.unit, Some(args.guard)),
        UnitCommand::Restart(args) => ("restart", args.unit, Some(args.guard)),
        UnitCommand::Reload(args) => ("reload", args.unit, Some(args.guard)),
        UnitCommand::Status(args) => ("status", args, None),
        UnitCommand::Logs(_) => unreachable!(),
    };
    let target = resolve_unit(args)?;
    let mutating = guard.is_some();
    if let Some(guard) = guard
        && direct_mutation_guard("unit", operation, &target, &guard)?
    {
        return Ok(());
    }
    let agent_args = service_agent_args(operation, target, true)?;
    let result = if mutating {
        transient_step(
            format!("{} systemd unit", operation_title(operation)),
            || config.run_agent(&agent_args[0], &agent_args[1..]),
        )?
    } else {
        config.run_agent(&agent_args[0], &agent_args[1..])?
    };
    emit_result(&result)
}

fn direct_mutation_guard(
    kind: &str,
    operation: &str,
    target: &ResolvedServiceTarget,
    guard: &ExecutionGuard,
) -> Result<bool> {
    if !guard.dry_run {
        return Ok(false);
    }
    emit_result(&json!({
        "dry_run": true,
        "kind": kind,
        "operation": operation,
        "target": resolved_target_value(target),
    }))?;
    Ok(true)
}

#[derive(Debug, Eq, PartialEq)]
enum ResolvedServiceTarget {
    Unit {
        host: String,
        unit: String,
        scope: Scope,
        user: Option<String>,
    },
    Resource {
        host: String,
        resource: String,
    },
}

fn resolved_target_value(target: &ResolvedServiceTarget) -> Value {
    match target {
        ResolvedServiceTarget::Unit {
            host,
            unit,
            scope,
            user,
        } => json!({
            "kind": "unit",
            "host": host,
            "unit": unit,
            "scope": scope.as_str(),
            "user": user,
        }),
        ResolvedServiceTarget::Resource { host, resource } => json!({
            "kind": "resource",
            "host": host,
            "resource": resource,
        }),
    }
}

fn resolve_logical_service(
    config: &HostManagerConfig,
    repo_root: Option<PathBuf>,
    nix_program: &Path,
    args: LogicalServiceArgs,
) -> Result<ResolvedServiceTarget> {
    let (host, resource) = if let Some(host) = args.host {
        config.host(&host)?;
        let resource = match Repository::discover(repo_root.clone()) {
            Ok(repository) => {
                resolve_service_resource(&repository, nix_program, &host, &args.service)?
            }
            Err(_) if repo_root.is_none() => format!("service:{}", args.service),
            Err(error) => return Err(error),
        };
        (host, resource)
    } else {
        let repository = Repository::discover(repo_root)?;
        let resolved = resolve_service_host(
            &repository,
            nix_program,
            config,
            args.stack.as_deref(),
            &args.service,
        )?;
        (resolved.host, resolved.resource)
    };
    Ok(ResolvedServiceTarget::Resource { host, resource })
}

fn resolve_unit(args: UnitArgs) -> Result<ResolvedServiceTarget> {
    if args.user.is_some() && args.scope != Scope::User {
        bail!("--user is valid only with --scope user");
    }
    Ok(ResolvedServiceTarget::Unit {
        host: args.host,
        unit: args.unit,
        scope: args.scope,
        user: args.user,
    })
}

fn service_agent_args(
    operation: &str,
    target: ResolvedServiceTarget,
    json_output: bool,
) -> Result<Vec<String>> {
    let host = match &target {
        ResolvedServiceTarget::Unit { host, .. } | ResolvedServiceTarget::Resource { host, .. } => {
            host.clone()
        }
    };
    let mut agent_args = vec![host];
    if json_output {
        agent_args.push("--json".to_owned());
    }
    match target {
        ResolvedServiceTarget::Unit {
            unit, scope, user, ..
        } => {
            if operation == "logs" {
                agent_args.extend(["logs".to_owned(), "--unit".to_owned(), unit]);
            } else {
                agent_args.extend([
                    "unit".to_owned(),
                    operation.to_owned(),
                    "--unit".to_owned(),
                    unit,
                ]);
            }
            agent_args.extend(["--scope".to_owned(), scope.as_str().to_owned()]);
            if let Some(user) = user {
                agent_args.push("--user".to_owned());
                agent_args.push(user);
            }
        }
        ResolvedServiceTarget::Resource { resource, .. } => {
            if operation == "logs" {
                agent_args.extend(["logs".to_owned(), "--resource".to_owned(), resource]);
            } else {
                agent_args.extend([
                    "resource".to_owned(),
                    operation.to_owned(),
                    "--resource".to_owned(),
                    resource,
                ]);
            }
        }
    }
    Ok(agent_args)
}

fn resource_command(adapter: &NativeAdapter, command: ResourceCommand) -> Result<()> {
    let config = adapter.config();
    let command = match command {
        ResourceCommand::Logs(args) => {
            let mut agent_args = vec![
                "logs".to_owned(),
                "--resource".to_owned(),
                args.resource.resource,
            ];
            append_log_options(&mut agent_args, &args.logs);
            return config.run_agent_interactive(&args.resource.host, &agent_args);
        }
        ResourceCommand::Hold { command } => {
            return match command {
                ResourceHoldCommand::Show(resource) => hold_show(config, resource),
                ResourceHoldCommand::Acquire(args) => {
                    durable_resource_action_with_config(config, args, "hold")
                }
                ResourceHoldCommand::Set(_) | ResourceHoldCommand::Clear(_) => unreachable!(),
            };
        }
        ResourceCommand::Activate(args) => {
            return durable_resource_action_with_config(config, args, "activate");
        }
        ResourceCommand::Wipe(args) => {
            return wipe_resource(
                adapter,
                &args.resource.host,
                &args.resource.resource,
                args.id.as_deref(),
                args.owner.as_deref(),
                &args.guard,
            );
        }
        command => command,
    };
    let (operation, args, guard) = match command {
        ResourceCommand::Describe(args) => ("describe", args, None),
        ResourceCommand::Start(args) => ("start", args.resource, Some(args.guard)),
        ResourceCommand::Stop(args) => ("stop", args.resource, Some(args.guard)),
        ResourceCommand::Restart(args) => ("restart", args.resource, Some(args.guard)),
        ResourceCommand::Reload(args) => ("reload", args.resource, Some(args.guard)),
        ResourceCommand::Status(args) => ("status", args, None),
        ResourceCommand::Ready(args) => ("ready", args, None),
        ResourceCommand::Move(_)
        | ResourceCommand::Logs(_)
        | ResourceCommand::Wipe(_)
        | ResourceCommand::Hold { .. }
        | ResourceCommand::Activate(_) => unreachable!(),
    };
    let mutating = guard.is_some();
    if let Some(guard) = guard
        && guard.dry_run
    {
        return emit_result(&json!({
            "dry_run": true,
            "kind": "resource",
            "operation": operation,
            "host": args.host,
            "resource": args.resource,
        }));
    }
    let run = || {
        config.run_agent(
            &args.host,
            &[
                "--json".to_owned(),
                "resource".to_owned(),
                operation.to_owned(),
                "--resource".to_owned(),
                args.resource,
            ],
        )
    };
    let result = if mutating {
        transient_step(
            format!("{} declared resource", operation_title(operation)),
            run,
        )?
    } else {
        run()?
    };
    emit_result(&result)
}

fn operation_title(operation: &str) -> String {
    let mut characters = operation.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

fn wipe_resource(
    adapter: &NativeAdapter,
    host: &str,
    resource: &str,
    caller_id: Option<&str>,
    hold_owner: Option<&str>,
    guard: &ExecutionGuard,
) -> Result<()> {
    adapter.config().host(host)?;
    let wipe = wipe_id(caller_id)?;
    let owner = hold_owner.map_or_else(|| wipe.clone(), str::to_owned);
    abird_host_manager::workflow::validate_workflow_id(&owner)?;
    if guard.dry_run {
        return emit_result(&json!({
            "dry_run": true,
            "operation": "wipe-and-remain-held",
            "host": host,
            "resource": resource,
            "wipe_id": wipe,
            "hold_owner": owner,
            "data_roots": "resolved by the target host agent from its immutable declaration",
        }));
    }

    transient_step("Acquire durable resource hold", || {
        adapter.run_profile_job(
            host,
            &format!("{wipe}-hold"),
            &owner,
            resource,
            &["--operation".to_owned(), "hold".to_owned()],
        )
    })?;
    transient_step("Verify every declared writer is inactive", || {
        adapter.run_profile_job(
            host,
            &format!("{wipe}-inactive"),
            &owner,
            resource,
            &[
                "--operation".to_owned(),
                "status".to_owned(),
                "--expect".to_owned(),
                "inactive".to_owned(),
            ],
        )
    })?;
    let job_id = format!("{wipe}-wipe");
    let job = transient_step("Clear declared data and retain hold", || {
        adapter.run_profile_job_result(
            host,
            &job_id,
            &owner,
            resource,
            &["--operation".to_owned(), "wipe-data".to_owned()],
        )
    })?;
    emit_result(&json!({
        "ok": true,
        "operation": "wipe-and-remain-held",
        "host": host,
        "resource": resource,
        "wipe_id": wipe,
        "hold_owner": owner,
        "job_id": job_id,
        "held": true,
        "job": job,
    }))
}

fn durable_resource_action_with_config(
    config: &HostManagerConfig,
    args: DurableResourceActionArgs,
    operation: &str,
) -> Result<()> {
    config.host(&args.resource.host)?;
    if args.guard.dry_run {
        return emit_result(&json!({
            "dry_run": true,
            "host": args.resource.host,
            "resource": args.resource.resource,
            "transaction": args.transaction,
            "operation": operation,
        }));
    }
    let adapter = NativeAdapter::from_config(config.clone()).with_progress(true);
    let digest = digest_bytes(
        format!(
            "{}\0{}\0{}\0{}",
            args.resource.host, args.resource.resource, args.transaction, operation
        )
        .as_bytes(),
    );
    transient_step(
        match operation {
            "hold" => "Acquire durable resource hold",
            "activate" => "Release hold and activate resource",
            _ => "Apply durable resource action",
        },
        || {
            adapter.run_profile_job(
                &args.resource.host,
                &format!("resource-{operation}-{}", &digest[..24]),
                &args.transaction,
                &args.resource.resource,
                &["--operation".to_owned(), operation.to_owned()],
            )
        },
    )?;
    emit_result(&json!({
        "ok": true,
        "host": args.resource.host,
        "resource": args.resource.resource,
        "transaction": args.transaction,
        "operation": operation,
    }))
}

fn hold_list(config: &HostManagerConfig, host: String) -> Result<()> {
    emit_result(&config.run_agent(
        &host,
        &["--json".to_owned(), "hold".to_owned(), "list".to_owned()],
    )?)
}

fn hold_show(config: &HostManagerConfig, resource: ResourceArgs) -> Result<()> {
    emit_result(&config.run_agent(
        &resource.host,
        &[
            "--json".to_owned(),
            "hold".to_owned(),
            "status".to_owned(),
            "--resource".to_owned(),
            resource.resource,
        ],
    )?)
}

fn backup_command(
    state_dir: PathBuf,
    config: Option<PathBuf>,
    repo_root: Option<PathBuf>,
    command: BackupCommand,
) -> Result<()> {
    match command {
        BackupCommand::Show { id } => emit_result(&BackupStore::read_only(state_dir).load(&id)?),
        BackupCommand::List => emit_result(&BackupStore::read_only(state_dir).list()?),
        BackupCommand::Verify { id } => {
            let record = BackupStore::read_only(state_dir).load(&id)?;
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            transient_step("Verify retained evidence and live backup artifacts", || {
                record.verify_evidence()?;
                for index in 0..record.copies.len() {
                    validate_backup_artifact(&adapter, &record, index, true)?;
                }
                Ok(())
            })?;
            emit_result(&json!({
                "ok": true,
                "backup": record,
                "verification": "persisted_evidence_and_live_artifacts_complete",
            }))
        }
        BackupCommand::Create(args) => {
            let args = *args;
            require_guard(&args.guard(), "backup create")?;
            let spec =
                backup_spec_from_args(args.spec.as_deref(), args.id.as_deref(), args.resource)?;
            let mut record = BackupRecord::new(spec)?;
            if args.dry_run {
                return emit_result(&json!({
                    "dry_run": true,
                    "backup": record,
                }));
            }
            ensure_backup_execution_supported(&record.spec)?;
            let store = backup_store(state_dir, false)?;
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            store.create(&record)?;
            transient_step("Copy and verify backup artifacts", || {
                execute_backup_record(&store, &mut record, &adapter)
            })?;
            emit_result(&record)
        }
        BackupCommand::Resume(args) => {
            require_guard(&args.guard, "backup resume")?;
            let store = backup_store(state_dir, args.guard.dry_run)?;
            let mut record = store.load(&args.id)?;
            if args.guard.dry_run {
                return emit_result(&json!({
                    "dry_run": true,
                    "backup": record,
                    "pending_copies": record.copies.iter().filter(|copy| copy.status != abird_host_manager::backup_runtime::BackupCopyStatus::Complete).count(),
                }));
            }
            ensure_backup_execution_supported(&record.spec)?;
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            transient_step("Resume pending backup work", || {
                match record.restore.as_ref().map(|restore| restore.phase) {
                    Some(RestorePhase::Holding | RestorePhase::Restoring) => {
                        execute_backup_restore(&store, &mut record, &adapter)
                    }
                    Some(RestorePhase::RollingBack) => {
                        execute_backup_restore_rollback(&store, &mut record, &adapter)
                    }
                    Some(RestorePhase::RestoredHeld) => {
                        bail!(
                            "restore is complete and held; use backup activate or backup rollback"
                        )
                    }
                    Some(RestorePhase::RolledBackHeld) => {
                        bail!("restore rollback is complete and held; use backup activate")
                    }
                    Some(RestorePhase::Activated) => {
                        bail!("backup restore has no pending operation")
                    }
                    _ if record.copies.iter().any(|copy| {
                        matches!(
                            copy.deletion.status,
                            ArtifactDeletionStatus::Running | ArtifactDeletionStatus::Failed
                        )
                    }) =>
                    {
                        delete_backup_artifacts(&store, &mut record, &adapter)
                    }
                    _ => execute_backup_record(&store, &mut record, &adapter),
                }
            })?;
            emit_result(&record)
        }
        BackupCommand::Abort(args) => {
            require_guard(&args.guard, "backup abort")?;
            let store = backup_store(state_dir, args.guard.dry_run)?;
            let mut record = store.load(&args.id)?;
            if args.guard.dry_run {
                return emit_result(&json!({
                    "dry_run": true,
                    "backup": record,
                    "operation": "restore-held-sources-and-abort",
                }));
            }
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            transient_step("Restore source holds and abort backup", || {
                restore_backup_holds(&store, &mut record, &adapter)?;
                record.abort()?;
                store.save(&record)
            })?;
            emit_result(&record)
        }
        BackupCommand::Restore(args) => {
            require_guard(&args.guard, "backup restore")?;
            let store = backup_store(state_dir, args.guard.dry_run)?;
            let mut record = store.load(&args.id)?;
            let destination = parse_backup_destination(&args.source);
            record.begin_restore(destination)?;
            store.ensure_authority_available(&record)?;
            if args.guard.dry_run {
                return emit_result(&json!({
                    "dry_run": true,
                    "backup": record,
                    "operation": "restore-and-remain-held",
                }));
            }
            ensure_backup_execution_supported(&record.spec)?;
            store.save(&record)?;
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            transient_step("Restore exact backup and retain resource holds", || {
                execute_backup_restore(&store, &mut record, &adapter)
            })?;
            emit_result(&record)
        }
        BackupCommand::Rollback(args) => {
            require_guard(&args.guard, "backup rollback")?;
            let store = backup_store(state_dir, args.guard.dry_run)?;
            let mut record = store.load(&args.id)?;
            record.ensure_restore_rollbackable()?;
            if args.guard.dry_run {
                return emit_result(&json!({
                    "dry_run": true,
                    "backup": record,
                    "operation": "restore-pre-restore-safety-snapshots-and-remain-held",
                }));
            }
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            transient_step("Restore pre-restore safety snapshots", || {
                execute_backup_restore_rollback(&store, &mut record, &adapter)
            })?;
            emit_result(&record)
        }
        BackupCommand::Activate(args) => {
            require_guard(&args.guard, "backup activate")?;
            let store = backup_store(state_dir, args.guard.dry_run)?;
            let mut record = store.load(&args.id)?;
            record.ensure_restore_activatable()?;
            if args.guard.dry_run {
                return emit_result(&json!({
                    "dry_run": true,
                    "backup": record,
                    "operation": "release-restore-holds-and-restore-prior-writers",
                }));
            }
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            transient_step("Release restore holds and restore prior writers", || {
                activate_backup_restore(&store, &mut record, &adapter)
            })?;
            emit_result(&record)
        }
        BackupCommand::Delete(args) => {
            require_guard(&args.guard, "backup delete")?;
            let store = backup_store(state_dir, args.guard.dry_run)?;
            let mut record = store.load(&args.id)?;
            record.ensure_artifacts_deletable()?;
            if args.guard.dry_run {
                return emit_result(&json!({
                    "dry_run": true,
                    "backup": record,
                    "operation": "delete-artifacts-and-retain-tombstone",
                }));
            }
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            transient_step("Delete backup artifacts and retain tombstone", || {
                delete_backup_artifacts(&store, &mut record, &adapter)
            })?;
            emit_result(&record)
        }
        BackupCommand::Prune(args) => {
            require_guard(&args.guard, "backup prune")?;
            prune_backups(state_dir, config, repo_root, args)
        }
    }
}

fn backup_store(state_dir: PathBuf, read_only: bool) -> Result<BackupStore> {
    if read_only {
        Ok(BackupStore::read_only(state_dir))
    } else {
        BackupStore::open(state_dir)
    }
}

fn backup_spec_from_args(
    spec_path: Option<&str>,
    caller_id: Option<&str>,
    resource: Option<BackupCreateResource>,
) -> Result<BackupSpec> {
    if let Some(path) = spec_path {
        if caller_id.is_some() || resource.is_some() {
            bail!("--spec cannot be combined with --id or a typed backup resource");
        }
        let spec: BackupSpec = read_json_document(path, "backup spec")?;
        spec.validate()?;
        return Ok(spec);
    }
    let resource = resource.context("backup create requires --spec or a typed resource")?;
    let (items, targets) = match resource {
        BackupCreateResource::Service(args) => (
            args.names
                .into_iter()
                .enumerate()
                .map(|(index, service)| BackupItem::Service {
                    id: format!("item-{:03}", index + 1),
                    service,
                    source: HostEndpoint {
                        host: args.source.clone(),
                        instance: None,
                    },
                    data_roots: Vec::new(),
                })
                .collect(),
            args.targets,
        ),
        BackupCreateResource::Resource(args) => (
            args.names
                .into_iter()
                .enumerate()
                .map(|(index, resource)| BackupItem::Resource {
                    id: format!("item-{:03}", index + 1),
                    resource,
                    source: HostEndpoint {
                        host: args.source.clone(),
                        instance: None,
                    },
                    data_roots: Vec::new(),
                })
                .collect(),
            args.targets,
        ),
        BackupCreateResource::Host(args) => (
            args.hosts
                .into_iter()
                .enumerate()
                .map(|(index, host)| BackupItem::Host {
                    id: format!("item-{:03}", index + 1),
                    source: HostEndpoint {
                        host,
                        instance: None,
                    },
                    data_roots: Vec::new(),
                })
                .collect(),
            args.targets,
        ),
        BackupCreateResource::Instance(args) => (
            args.instances
                .into_iter()
                .enumerate()
                .map(|(index, instance)| BackupItem::Instance {
                    id: format!("item-{:03}", index + 1),
                    source: InstanceEndpoint {
                        controller: args.controller.clone(),
                        remote: args.remote.clone(),
                        project: args.project.clone(),
                        instance,
                    },
                    policy: InstanceBackupPolicy {
                        executor_controller: args.executor_controller.clone(),
                        program: args.incus_program.clone(),
                        stop_timeout_seconds: args.stop_timeout_seconds,
                        force_after_timeout: args.force_after_timeout,
                        include_snapshots: !args.instance_only,
                        optimized_storage: args.optimized_storage,
                        restore_storage_pool: args.restore_storage_pool.clone(),
                    },
                })
                .collect(),
            args.targets,
        ),
    };
    let destinations = targets
        .into_iter()
        .map(|target| {
            if Path::new(&target).is_absolute() {
                BackupDestination::ControllerDirectory {
                    path: target.into(),
                }
            } else {
                BackupDestination::Host {
                    endpoint: HostEndpoint {
                        host: target,
                        instance: None,
                    },
                }
            }
        })
        .collect();
    BackupSpec::new(caller_id, items, destinations, Vec::new())
}

fn ensure_backup_execution_supported(spec: &BackupSpec) -> Result<()> {
    spec.validate()
}

fn parse_backup_destination(value: &str) -> BackupDestination {
    if Path::new(value).is_absolute() {
        BackupDestination::ControllerDirectory { path: value.into() }
    } else {
        BackupDestination::Host {
            endpoint: HostEndpoint {
                host: value.to_owned(),
                instance: None,
            },
        }
    }
}

struct PreparedRestoreExecution {
    item_id: String,
    prepared: PreparedBackupItem,
    artifact: BackupArtifact,
    hold_prefix: String,
}

fn execute_backup_restore(
    store: &BackupStore,
    record: &mut BackupRecord,
    adapter: &NativeAdapter,
) -> Result<()> {
    let destination = record
        .restore
        .as_ref()
        .context("backup has no restore intent")?
        .destination
        .clone();
    if matches!(
        record.restore.as_ref().map(|restore| restore.phase),
        Some(RestorePhase::RestoredHeld | RestorePhase::Activated)
    ) {
        return Ok(());
    }

    let mut executions = Vec::new();
    let record_id = record.id().to_owned();
    for item in &record.spec.items {
        let mut prepared = prepare_restore_item(adapter, item)?;
        let copy_index = record
            .copies
            .iter()
            .position(|copy| copy.item == item.id() && copy.destination == destination)
            .with_context(|| format!("backup item {:?} has no restore copy", item.id()))?;
        validate_backup_artifact(adapter, record, copy_index, true)?;
        let artifact = record.copies[copy_index]
            .artifact
            .clone()
            .with_context(|| format!("backup item {:?} has no restore artifact", item.id()))?;
        let needs_instance_state = prepared.instance.is_some()
            && record.restore.as_ref().unwrap().items[item.id()]
                .previously_active_instance
                .is_none();
        if needs_instance_state {
            let was_running = instance_backup::inspect(
                adapter,
                prepared.instance.as_ref().unwrap(),
                record.id(),
                &format!("{}-{}-restore-inspect", record.id(), item.id()),
            )?;
            record
                .restore
                .as_mut()
                .unwrap()
                .items
                .get_mut(item.id())
                .unwrap()
                .previously_active_instance = Some(was_running);
        }
        if let Some(instance) = &mut prepared.instance {
            instance.was_running =
                record.restore.as_ref().unwrap().items[item.id()].previously_active_instance;
        }
        let runtime = record
            .restore
            .as_mut()
            .expect("validated restore intent")
            .items
            .get_mut(item.id())
            .context("restore runtime item disappeared")?;
        if !runtime.held {
            runtime.previously_active_services = prepared.active_services.clone();
            runtime.hold_attempts = runtime
                .hold_attempts
                .checked_add(1)
                .context("restore hold attempt counter overflow")?;
            runtime.held = true;
        }
        let hold_attempts = runtime.hold_attempts;
        executions.push(PreparedRestoreExecution {
            item_id: item.id().to_owned(),
            artifact,
            hold_prefix: format!("{}-{}-restore-a{}", record_id, item.id(), hold_attempts),
            prepared,
        });
    }
    store.save(record)?;

    let result = (|| -> Result<()> {
        for execution in &executions {
            hold_backup_source(
                adapter,
                &execution.prepared,
                record.id(),
                &execution.hold_prefix,
            )?;
        }

        for execution in &executions {
            let runtime = &record.restore.as_ref().unwrap().items[&execution.item_id];
            if runtime.safety_snapshot.is_some() || runtime.safety_artifact.is_some() {
                continue;
            }
            if let Some(instance) = &execution.prepared.instance {
                let snapshot = format!("{}-{}-pre-restore", record.id(), execution.item_id);
                let artifact = instance_backup::create_safety_export(
                    adapter,
                    instance,
                    record.id(),
                    &snapshot,
                )?;
                record
                    .restore
                    .as_mut()
                    .unwrap()
                    .items
                    .get_mut(&execution.item_id)
                    .unwrap()
                    .safety_artifact = Some(artifact);
            } else {
                let snapshot = format!("{}-{}-pre-restore", record.id(), execution.item_id);
                adapter.run_profile_job(
                    &execution.prepared.source,
                    &snapshot,
                    record.id(),
                    &execution.prepared.resource,
                    &["--backup".to_owned()],
                )?;
                record
                    .restore
                    .as_mut()
                    .unwrap()
                    .items
                    .get_mut(&execution.item_id)
                    .unwrap()
                    .safety_snapshot = Some(snapshot);
            }
            store.save(record)?;
        }

        record.set_restore_phase(RestorePhase::Restoring, "backup data restore started")?;
        store.save(record)?;
        for execution in &executions {
            if record.restore.as_ref().unwrap().items[&execution.item_id].restored {
                continue;
            }
            restore_backup_artifact(
                adapter,
                &execution.prepared,
                &execution.artifact,
                record.id(),
            )?;
            record
                .restore
                .as_mut()
                .unwrap()
                .items
                .get_mut(&execution.item_id)
                .unwrap()
                .restored = true;
            store.save(record)?;
        }
        record.set_restore_phase(
            RestorePhase::RestoredHeld,
            "backup restore verified; sources remain held",
        )?;
        store.save(record)
    })();
    if let Err(error) = result {
        record.fail_restore(format!("{error:#}"))?;
        store.save(record)?;
        return Err(error);
    }
    Ok(())
}

fn prepare_restore_item(adapter: &NativeAdapter, item: &BackupItem) -> Result<PreparedBackupItem> {
    let mut prepared = prepare_backup_item(adapter, item)?;
    if prepared.consistency == "live" {
        let status = adapter.config().run_agent(
            &prepared.source,
            &[
                "--json".to_owned(),
                "resource".to_owned(),
                "status".to_owned(),
                "--resource".to_owned(),
                prepared.resource.clone(),
            ],
        )?;
        prepared.active_services = parse_active_services(&status)?;
    }
    Ok(prepared)
}

fn restore_backup_artifact(
    adapter: &NativeAdapter,
    prepared: &PreparedBackupItem,
    artifact: &BackupArtifact,
    owner: &str,
) -> Result<Value> {
    if let BackupArtifact::InstanceExport { .. } = artifact {
        return instance_backup::restore(
            adapter,
            prepared
                .instance
                .as_ref()
                .context("instance export cannot restore a data resource")?,
            artifact,
            owner,
        );
    }
    let plans = restore_data_root_plan(prepared, artifact)?;
    match artifact {
        BackupArtifact::ControllerDirectory { .. } => {
            require_controller_backup_privileges()?;
            let remote_destination = if adapter.config().host(&prepared.source)?.local {
                None
            } else {
                Some(adapter.config().remote_source(&prepared.source)?)
            };
            let transfers = plans
                .iter()
                .map(|plan| {
                    transfer_with_excludes_progress(
                        &TransferDefinition {
                            source: plan.source.clone(),
                            destination: plan.target.clone(),
                            rsync_program: adapter.config().ssh.rsync_program.clone(),
                            remote_source: None,
                            remote_destination: remote_destination.clone(),
                            tar_program: adapter.config().ssh.tar_program.clone(),
                            delete: true,
                            fallback_copy: true,
                        },
                        &plan.excludes,
                        |_| Ok(()),
                    )
                })
                .collect::<Result<Vec<_>>>()?;
            Ok(json!({ "engine": "controller", "transfers": transfers }))
        }
        BackupArtifact::HostSnapshot {
            host,
            resource,
            snapshot,
            ..
        } if host == &prepared.source => {
            if resource != &prepared.resource {
                bail!("host backup artifact resource does not match restore resource");
            }
            adapter.run_profile_job_result(
                &prepared.source,
                &format!(
                    "{owner}-restore-{}",
                    &digest_bytes(snapshot.as_bytes())[..16]
                ),
                owner,
                &prepared.resource,
                &["--restore-backup".to_owned(), snapshot.clone()],
            )
        }
        BackupArtifact::HostSnapshot { host, resource, .. } => {
            if resource != &prepared.resource {
                bail!("host backup artifact resource does not match restore resource");
            }
            let copy_id = format!(
                "{owner}-restore-{}",
                &digest_bytes(format!("{host}\0{}", prepared.source).as_bytes())[..16]
            );
            let copy = adapter.run_broker_profile_job(
                &format!("{copy_id}-copy"),
                owner,
                &prepared.resource,
                host,
                &prepared.source,
                false,
                None,
                Some(&plans),
                true,
            )?;
            let verification = adapter.run_broker_profile_job(
                &format!("{copy_id}-verify"),
                owner,
                &prepared.resource,
                host,
                &prepared.source,
                true,
                None,
                Some(&plans),
                true,
            )?;
            Ok(json!({
                "engine": "controller_broker",
                "copy": copy,
                "verification": verification,
            }))
        }
        BackupArtifact::InstanceExport { .. } => unreachable!(),
    }
}

fn restore_data_root_plan(
    prepared: &PreparedBackupItem,
    artifact: &BackupArtifact,
) -> Result<Vec<abird_host_agent::resource::DataRootPlan>> {
    let root = match artifact {
        BackupArtifact::ControllerDirectory { root }
        | BackupArtifact::HostSnapshot { root, .. } => root,
        BackupArtifact::InstanceExport { .. } => {
            bail!("instance exports do not contain data-root restore plans")
        }
    };
    if !root.is_absolute() || root == Path::new("/") {
        bail!("backup artifact root must be an absolute non-root path");
    }
    prepared
        .roots
        .iter()
        .map(|data_root| {
            Ok(abird_host_agent::resource::DataRootPlan {
                name: data_root.name.clone(),
                source: root.join(data_root.path.strip_prefix("/")?),
                target: data_root.path.clone(),
                excludes: data_root.excludes.clone(),
            })
        })
        .collect()
}

fn execute_backup_restore_rollback(
    store: &BackupStore,
    record: &mut BackupRecord,
    adapter: &NativeAdapter,
) -> Result<()> {
    record.ensure_restore_rollbackable()?;
    let phase = record
        .restore
        .as_ref()
        .context("backup has no restore to roll back")?
        .phase;
    if phase == RestorePhase::RolledBackHeld {
        return Ok(());
    }
    record.set_restore_phase(
        RestorePhase::RollingBack,
        "pre-restore safety rollback started",
    )?;
    store.save(record)?;
    let items = record.spec.items.clone();
    for item in items.iter().rev() {
        let runtime = &record.restore.as_ref().unwrap().items[item.id()];
        if runtime.rolled_back {
            continue;
        }
        if !runtime.restored {
            record
                .restore
                .as_mut()
                .unwrap()
                .items
                .get_mut(item.id())
                .unwrap()
                .rolled_back = true;
            store.save(record)?;
            continue;
        }
        let mut prepared = prepare_restore_item(adapter, item)?;
        let runtime = &record.restore.as_ref().unwrap().items[item.id()];
        if let Some(instance) = &mut prepared.instance {
            instance.was_running = runtime.previously_active_instance;
        }
        if let Some(artifact) = runtime.safety_artifact.clone() {
            restore_backup_artifact(adapter, &prepared, &artifact, record.id())?;
        } else {
            let snapshot = runtime
                .safety_snapshot
                .clone()
                .with_context(|| format!("restore item {:?} has no safety artifact", item.id()))?;
            adapter.run_profile_job(
                &prepared.source,
                &format!("{}-{}-safety-rollback", record.id(), item.id()),
                record.id(),
                &prepared.resource,
                &["--restore-backup".to_owned(), snapshot],
            )?;
        }
        record
            .restore
            .as_mut()
            .unwrap()
            .items
            .get_mut(item.id())
            .unwrap()
            .rolled_back = true;
        store.save(record)?;
    }
    record.set_restore_phase(
        RestorePhase::RolledBackHeld,
        "pre-restore safety rollback verified; sources remain held",
    )?;
    store.save(record)
}

fn activate_backup_restore(
    store: &BackupStore,
    record: &mut BackupRecord,
    adapter: &NativeAdapter,
) -> Result<()> {
    record.ensure_restore_activatable()?;
    let phase = record
        .restore
        .as_ref()
        .context("backup has no restore to activate")?
        .phase;
    if phase == RestorePhase::Activated {
        return Ok(());
    }
    let items = record.spec.items.clone();
    for item in items.iter().rev() {
        let runtime = &record.restore.as_ref().unwrap().items[item.id()];
        if !runtime.held {
            continue;
        }
        let mut prepared = prepare_restore_item(adapter, item)?;
        prepared.active_services = runtime.previously_active_services.clone();
        if let Some(instance) = &mut prepared.instance {
            instance.was_running = runtime.previously_active_instance;
        }
        restore_backup_source(
            adapter,
            &prepared,
            record.id(),
            &format!("{}-{}-restore-activate", record.id(), item.id()),
        )?;
        record
            .restore
            .as_mut()
            .unwrap()
            .items
            .get_mut(item.id())
            .unwrap()
            .held = false;
        store.save(record)?;
    }
    record.set_restore_phase(
        RestorePhase::Activated,
        "backup restore explicitly activated",
    )?;
    store.save(record)
}

fn delete_backup_artifacts(
    store: &BackupStore,
    record: &mut BackupRecord,
    adapter: &NativeAdapter,
) -> Result<()> {
    record.ensure_artifacts_deletable()?;
    for index in 0..record.copies.len() {
        if record.copies[index].deletion.status == ArtifactDeletionStatus::Complete {
            continue;
        }
        validate_backup_artifact(adapter, record, index, false)?;
        let Some(artifact) = record.copies[index].artifact.clone() else {
            record.complete_artifact_deletion(index)?;
            store.save(record)?;
            continue;
        };
        record.begin_artifact_deletion(index)?;
        store.save(record)?;
        let item = record
            .spec
            .items
            .iter()
            .find(|item| item.id() == record.copies[index].item)
            .context("backup deletion item disappeared")?;
        if let Err(error) = delete_backup_artifact(adapter, record.id(), item, &artifact) {
            record.fail_artifact_deletion(index, format!("{error:#}"))?;
            store.save(record)?;
            return Err(error).with_context(|| format!("delete backup artifact {index}"));
        }
        record.complete_artifact_deletion(index)?;
        store.save(record)?;
    }

    let safety = record
        .restore
        .as_ref()
        .map(|restore| {
            restore
                .items
                .iter()
                .filter_map(|(item, runtime)| {
                    runtime
                        .safety_snapshot
                        .as_ref()
                        .map(|snapshot| (item.clone(), snapshot.clone()))
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    for (item_id, snapshot) in safety {
        let item = record
            .spec
            .items
            .iter()
            .find(|item| item.id() == item_id)
            .context("restore safety item disappeared")?;
        let (resource, source) = backup_item_resource(adapter, item)?;
        adapter.run_profile_job(
            &source,
            &format!("{}-{item_id}-delete-safety", record.id()),
            record.id(),
            &resource,
            &["--delete-backup".to_owned(), snapshot],
        )?;
    }
    let safety_artifacts = record
        .restore
        .as_ref()
        .map(|restore| {
            restore
                .items
                .iter()
                .filter_map(|(item, runtime)| {
                    runtime
                        .safety_artifact
                        .as_ref()
                        .map(|artifact| (item.clone(), artifact.clone()))
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    for (item_id, artifact) in safety_artifacts {
        let item = record
            .spec
            .items
            .iter()
            .find(|item| item.id() == item_id)
            .context("restore safety item disappeared")?;
        delete_backup_artifact(adapter, record.id(), item, &artifact)?;
    }
    record.finish_artifact_deletion()?;
    store.save(record)
}

fn validate_backup_artifact(
    adapter: &NativeAdapter,
    record: &BackupRecord,
    copy_index: usize,
    verify_content: bool,
) -> Result<()> {
    let copy = record
        .copies
        .get(copy_index)
        .context("backup copy index is out of range")?;
    let Some(artifact) = &copy.artifact else {
        return Ok(());
    };
    let item = record
        .spec
        .items
        .iter()
        .find(|item| item.id() == copy.item)
        .context("backup artifact item disappeared")?;
    let (resource, source) = backup_item_resource(adapter, item)?;
    let target = match &copy.destination {
        BackupDestination::Host { endpoint } => endpoint.host.clone(),
        BackupDestination::ControllerDirectory { path } => path.display().to_string(),
    };
    let copy_id = backup_copy_id(record.id(), &copy.item, &target);
    match (&copy.destination, artifact) {
        (
            BackupDestination::ControllerDirectory { path },
            BackupArtifact::ControllerDirectory { root },
        ) => {
            let expected = path.join(digest_bytes(resource.as_bytes())).join(&copy_id);
            if root != &expected {
                bail!(
                    "controller backup artifact {} differs from its exact derived root {}",
                    root.display(),
                    expected.display()
                );
            }
        }
        (
            BackupDestination::Host { endpoint },
            BackupArtifact::HostSnapshot {
                host,
                resource: artifact_resource,
                snapshot,
                root,
            },
        ) => {
            let expected_snapshot = if source == endpoint.host {
                format!("{copy_id}-copy")
            } else {
                copy_id
            };
            let expected_suffix =
                PathBuf::from(digest_bytes(resource.as_bytes())).join(&expected_snapshot);
            if host != &endpoint.host
                || artifact_resource != &resource
                || snapshot != &expected_snapshot
                || !root.ends_with(&expected_suffix)
            {
                bail!("host backup artifact differs from its exact derived identity");
            }
        }
        (
            BackupDestination::ControllerDirectory { path },
            BackupArtifact::InstanceExport {
                source: artifact_source,
                location: InstanceExportLocation::ControllerDirectory { root },
                staging,
                sha256,
                size_bytes,
            },
        ) => {
            let BackupItem::Instance { source, .. } = item else {
                bail!("instance export is attached to a non-instance backup item");
            };
            let expected = path.join(digest_bytes(resource.as_bytes())).join(&copy_id);
            if artifact_source != source
                || root != &expected
                || staging.is_some()
                || sha256.len() != 64
                || *size_bytes == 0
            {
                bail!("controller instance export differs from its exact derived identity");
            }
            if verify_content {
                instance_backup::verify_controller_export(root, sha256, *size_bytes)?;
            }
        }
        (
            BackupDestination::Host { endpoint },
            BackupArtifact::InstanceExport {
                source: artifact_source,
                location: InstanceExportLocation::Host { host, root },
                staging,
                sha256,
                size_bytes,
            },
        ) => {
            let BackupItem::Instance { source, .. } = item else {
                bail!("instance export is attached to a non-instance backup item");
            };
            let expected_suffix = PathBuf::from(digest_bytes(resource.as_bytes())).join(&copy_id);
            if artifact_source != source
                || host != &endpoint.host
                || !root.ends_with(&expected_suffix)
                || staging.is_some()
                || sha256.len() != 64
                || *size_bytes == 0
            {
                bail!("host instance export differs from its exact derived identity");
            }
            if verify_content {
                let prepared = prepare_backup_item(adapter, item)?;
                instance_backup::verify_on_host_fresh(
                    adapter,
                    prepared.instance.as_ref().unwrap(),
                    host,
                    record.id(),
                    root,
                    sha256,
                    *size_bytes,
                )?;
            }
        }
        _ => bail!("backup artifact kind differs from its immutable destination"),
    }
    Ok(())
}

fn delete_backup_artifact(
    adapter: &NativeAdapter,
    owner: &str,
    item: &BackupItem,
    artifact: &BackupArtifact,
) -> Result<()> {
    match artifact {
        BackupArtifact::ControllerDirectory { root } => {
            require_controller_backup_privileges()?;
            if !root.is_absolute() || root == Path::new("/") {
                bail!("refusing to delete an invalid controller backup root");
            }
            if root.exists() {
                fs::remove_dir_all(root)
                    .with_context(|| format!("delete controller backup {}", root.display()))?;
                if let Some(parent) = root.parent() {
                    fs::File::open(parent)?.sync_all()?;
                }
            }
            Ok(())
        }
        BackupArtifact::HostSnapshot {
            host,
            resource,
            snapshot,
            ..
        } => {
            adapter.run_profile_job(
                host,
                &format!(
                    "{owner}-delete-{}",
                    &digest_bytes(snapshot.as_bytes())[..16]
                ),
                owner,
                resource,
                &["--delete-backup".to_owned(), snapshot.clone()],
            )?;
            Ok(())
        }
        BackupArtifact::InstanceExport { .. } => {
            let prepared = prepare_backup_item(adapter, item)?;
            instance_backup::delete(
                adapter,
                prepared.instance.as_ref().unwrap(),
                owner,
                artifact,
            )
        }
    }
}

fn prune_backups(
    state_dir: PathBuf,
    config: Option<PathBuf>,
    repo_root: Option<PathBuf>,
    args: BackupPruneArgs,
) -> Result<()> {
    let store = backup_store(state_dir, args.guard.dry_run)?;
    let records = store.list()?;
    let age_ms = args.older_than.as_millis();
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .context("system clock is before Unix epoch")?
        .as_millis();
    let cutoff = now_ms.saturating_sub(age_ms);
    let mut groups = std::collections::BTreeMap::<String, Vec<BackupRecord>>::new();
    for record in records {
        if !matches!(record.phase, BackupPhase::Complete | BackupPhase::Verified)
            || record
                .restore
                .as_ref()
                .is_some_and(|restore| restore.phase.holds_authority())
        {
            continue;
        }
        let mut authorities = record
            .spec
            .items
            .iter()
            .map(BackupItem::authority)
            .collect::<Vec<_>>();
        authorities.sort();
        let mut destinations = record.spec.destinations.clone();
        destinations.sort();
        let key = serde_json::to_string(&(authorities, destinations))?;
        groups.entry(key).or_default().push(record);
    }
    let mut selected = Vec::new();
    for records in groups.values_mut() {
        records.sort_by_key(|record| std::cmp::Reverse(record.created_at_unix_ms));
        selected.extend(
            records
                .iter()
                .skip(args.keep_last)
                .filter(|record| record.created_at_unix_ms <= cutoff)
                .map(|record| record.id().to_owned()),
        );
    }
    selected.sort();
    if args.guard.dry_run {
        return emit_result(&json!({
            "dry_run": true,
            "older_than_ms": age_ms,
            "keep_last_per_equivalent_set": args.keep_last,
            "delete": selected,
        }));
    }
    if selected.is_empty() {
        return emit_result(&json!({
            "ok": true,
            "deleted": [],
        }));
    }
    let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
    let adapter = NativeAdapter::load(&config)?;
    transient_step("Delete selected backup artifacts", || {
        for id in &selected {
            let mut record = store.load(id)?;
            delete_backup_artifacts(&store, &mut record, &adapter)?;
        }
        Ok(())
    })?;
    emit_result(&json!({
        "ok": true,
        "deleted": selected,
    }))
}

fn parse_duration(input: &str) -> std::result::Result<Duration, String> {
    humantime::parse_duration(input).map_err(|error| error.to_string())
}

fn execute_backup_record(
    store: &BackupStore,
    record: &mut BackupRecord,
    adapter: &NativeAdapter,
) -> Result<()> {
    record.begin()?;
    store.save(record)?;
    for group in backup_execution_groups(record) {
        execute_backup_group(store, record, adapter, &group)?;
    }
    record.finish()?;
    store.save(record)
}

struct PreparedBackupExecution {
    item_id: String,
    pending: Vec<usize>,
    prepared: PreparedBackupItem,
    hold_prefix: String,
}

fn backup_copy_id(record_id: &str, item_id: &str, target: &str) -> String {
    format!(
        "{record_id}-{item_id}-{}",
        &digest_bytes(target.as_bytes())[..12]
    )
}

fn execute_backup_group(
    store: &BackupStore,
    record: &mut BackupRecord,
    adapter: &NativeAdapter,
    group: &[String],
) -> Result<()> {
    let mut executions = Vec::new();
    for item_id in group {
        let pending = record
            .copies
            .iter()
            .enumerate()
            .filter(|(_, copy)| {
                copy.item == *item_id
                    && copy.status != abird_host_manager::backup_runtime::BackupCopyStatus::Complete
            })
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        let was_held = record.items[item_id].held;
        if pending.is_empty() && !was_held {
            continue;
        }
        let item = record
            .spec
            .items
            .iter()
            .find(|item| item.id() == item_id)
            .with_context(|| format!("backup item {item_id:?} disappeared"))?;
        let mut prepared = prepare_backup_item(adapter, item)?;
        if was_held {
            prepared.active_services = record.items[item_id].previously_active_services.clone();
            if let Some(instance) = &mut prepared.instance {
                instance.was_running = record.items[item_id].previously_active_instance;
            }
        } else if prepared.instance.is_some() {
            let was_running = instance_backup::inspect(
                adapter,
                prepared.instance.as_ref().unwrap(),
                record.id(),
                &format!("{}-{item_id}-inspect", record.id()),
            )?;
            prepared
                .instance
                .as_mut()
                .expect("checked instance backup")
                .was_running = Some(was_running);
        }
        let record_id = record.id().to_owned();
        let runtime = record
            .items
            .get_mut(item_id)
            .context("backup runtime item disappeared")?;
        if !was_held {
            runtime.previously_active_services = prepared.active_services.clone();
            runtime.previously_active_instance = prepared
                .instance
                .as_ref()
                .and_then(|instance| instance.was_running);
        }
        if prepared.consistency == "quiesced" {
            runtime.attempts = runtime
                .attempts
                .checked_add(1)
                .context("backup item attempt counter overflow")?;
            runtime.held = true;
        }
        executions.push(PreparedBackupExecution {
            item_id: item_id.clone(),
            pending,
            hold_prefix: format!("{record_id}-{item_id}-a{}", runtime.attempts),
            prepared,
        });
    }
    store.save(record)?;

    for execution in &executions {
        if execution.prepared.consistency == "quiesced" {
            hold_backup_source(
                adapter,
                &execution.prepared,
                record.id(),
                &execution.hold_prefix,
            )?;
        }
    }

    for execution in &executions {
        for &index in &execution.pending {
            let destination = record.copies[index].destination.clone();
            record.begin_copy(index)?;
            store.save(record)?;
            let target = match &destination {
                BackupDestination::Host { endpoint } => endpoint.host.clone(),
                BackupDestination::ControllerDirectory { path } => path.display().to_string(),
            };
            let copy_id = backup_copy_id(record.id(), &execution.item_id, &target);
            match backup_from_to(adapter, &execution.prepared, &target, record.id(), &copy_id) {
                Ok(result) => {
                    record.complete_copy(index, result.evidence, result.artifact)?;
                    store.save(record)?;
                    cleanup_instance_copy_staging(
                        store,
                        record,
                        adapter,
                        &execution.prepared,
                        index,
                    )?;
                }
                Err(error) => {
                    record.fail_copy(index, format!("{error:#}"))?;
                    store.save(record)?;
                    return Err(error).with_context(|| format!("backup copy {index} failed"));
                }
            }
        }
        let completed = record
            .copies
            .iter()
            .enumerate()
            .filter(|(_, copy)| copy.item == execution.item_id)
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        for index in completed {
            cleanup_instance_copy_staging(store, record, adapter, &execution.prepared, index)?;
        }
    }

    for execution in executions.iter().rev() {
        if execution.prepared.consistency == "quiesced" {
            restore_backup_source(
                adapter,
                &execution.prepared,
                record.id(),
                &execution.hold_prefix,
            )?;
            record.items.get_mut(&execution.item_id).unwrap().held = false;
            store.save(record)?;
        }
    }
    Ok(())
}

fn cleanup_instance_copy_staging(
    store: &BackupStore,
    record: &mut BackupRecord,
    adapter: &NativeAdapter,
    prepared: &PreparedBackupItem,
    copy_index: usize,
) -> Result<()> {
    let staging = match record.copies[copy_index].artifact.as_ref() {
        Some(BackupArtifact::InstanceExport { staging, .. }) => staging.clone(),
        _ => None,
    };
    let Some(staging) = staging else {
        return Ok(());
    };
    instance_backup::cleanup_staging(
        adapter,
        prepared.instance.as_ref().unwrap(),
        record.id(),
        &staging,
    )?;
    if let Some(BackupArtifact::InstanceExport { staging, .. }) =
        record.copies[copy_index].artifact.as_mut()
    {
        *staging = None;
    }
    store.save(record)
}

fn backup_execution_groups(record: &BackupRecord) -> Vec<Vec<String>> {
    let mut assigned = std::collections::BTreeSet::new();
    let mut groups = record
        .spec
        .consistency_groups
        .iter()
        .map(|group| {
            assigned.extend(group.items.iter().cloned());
            group.items.clone()
        })
        .collect::<Vec<_>>();
    groups.extend(
        record
            .spec
            .items
            .iter()
            .filter(|item| !assigned.contains(item.id()))
            .map(|item| vec![item.id().to_owned()]),
    );
    groups
}

fn restore_backup_holds(
    store: &BackupStore,
    record: &mut BackupRecord,
    adapter: &NativeAdapter,
) -> Result<()> {
    let held = record
        .items
        .iter()
        .filter(|(_, runtime)| runtime.held)
        .map(|(id, _)| id.clone())
        .collect::<Vec<_>>();
    for item_id in held {
        let item = record
            .spec
            .items
            .iter()
            .find(|item| item.id() == item_id)
            .context("held backup item disappeared")?;
        let mut prepared = prepare_backup_item(adapter, item)?;
        prepared.active_services = record.items[&item_id].previously_active_services.clone();
        if let Some(instance) = &mut prepared.instance {
            instance.was_running = record.items[&item_id].previously_active_instance;
        }
        if let Some(instance) = &prepared.instance {
            for copy in record.copies.iter().filter(|copy| {
                copy.item == item_id
                    && copy.status != abird_host_manager::backup_runtime::BackupCopyStatus::Complete
            }) {
                let target = match &copy.destination {
                    BackupDestination::Host { endpoint } => endpoint.host.clone(),
                    BackupDestination::ControllerDirectory { path } => path.display().to_string(),
                };
                let copy_id = backup_copy_id(record.id(), &item_id, &target);
                let same_host = !Path::new(&target).is_absolute() && prepared.source == target;
                instance_backup::cleanup_pending_stage(
                    adapter,
                    instance,
                    record.id(),
                    &copy_id,
                    same_host,
                )?;
            }
        }
        restore_backup_source(
            adapter,
            &prepared,
            record.id(),
            &format!("{}-{item_id}-abort", record.id()),
        )?;
        record.items.get_mut(&item_id).unwrap().held = false;
        store.save(record)?;
    }
    Ok(())
}

struct PreparedBackupItem {
    resource: String,
    source: String,
    consistency: String,
    active_services: Vec<String>,
    roots: Vec<abird_host_agent::resource::DataRoot>,
    instance: Option<InstanceBackupContext>,
}

fn backup_item_resource(adapter: &NativeAdapter, item: &BackupItem) -> Result<(String, String)> {
    match item {
        BackupItem::Host { source, .. } => Ok((
            adapter.config().host_resource(&source.host)?,
            source.host.clone(),
        )),
        BackupItem::Service {
            service, source, ..
        } => Ok((format!("service:{service}"), source.host.clone())),
        BackupItem::Resource {
            resource, source, ..
        } => Ok((resource.clone(), source.host.clone())),
        BackupItem::Instance { source, policy, .. } => Ok((
            instance_resource(source)?,
            policy.executor(source).to_owned(),
        )),
    }
}

fn prepare_backup_item(adapter: &NativeAdapter, item: &BackupItem) -> Result<PreparedBackupItem> {
    let (resource, source) = backup_item_resource(adapter, item)?;
    let config = adapter.config();
    config.host(&source)?;
    if let BackupItem::Instance {
        source: endpoint,
        policy,
        ..
    } = item
    {
        return Ok(PreparedBackupItem {
            resource,
            source,
            consistency: "quiesced".to_owned(),
            active_services: Vec::new(),
            roots: Vec::new(),
            instance: Some(InstanceBackupContext::new(endpoint, policy)?),
        });
    }
    let declaration = config.run_agent(
        &source,
        &[
            "--json".to_owned(),
            "resource".to_owned(),
            "describe".to_owned(),
            "--resource".to_owned(),
            resource.to_owned(),
        ],
    )?;
    let resource_value = declaration
        .pointer("/result/resource")
        .context("source resource description has no resource")?;
    let consistency = resource_value
        .get("backup_consistency")
        .and_then(|value| value.as_str())
        .unwrap_or("quiesced")
        .to_owned();
    if !matches!(consistency.as_str(), "live" | "quiesced") {
        bail!("resource returned unsupported backup consistency {consistency:?}");
    }
    let active_services = if consistency == "quiesced" {
        let status = config.run_agent(
            &source,
            &[
                "--json".to_owned(),
                "resource".to_owned(),
                "status".to_owned(),
                "--resource".to_owned(),
                resource.to_owned(),
            ],
        )?;
        parse_active_services(&status)?
    } else {
        Vec::new()
    };
    let declared_roots = declared_data_roots(resource_value)?;
    let explicit_roots: &[abird_host_manager::workflow::DeclaredDataRoot] = match item {
        BackupItem::Host { data_roots, .. }
        | BackupItem::Service { data_roots, .. }
        | BackupItem::Resource { data_roots, .. } => data_roots,
        BackupItem::Instance { .. } => &[],
    };
    let roots = if explicit_roots.is_empty() {
        declared_roots
    } else {
        let explicit = explicit_roots
            .iter()
            .map(|root| abird_host_agent::resource::DataRoot {
                name: root.name.clone(),
                path: root.path.clone(),
                excludes: root.excludes.clone(),
            })
            .collect::<Vec<_>>();
        if explicit != declared_roots {
            bail!(
                "backup item {:?} explicit data roots differ from the source agent declaration",
                item.id()
            );
        }
        explicit
    };
    if roots.is_empty() {
        bail!("resource {resource:?} has no declared data paths");
    }
    Ok(PreparedBackupItem {
        resource,
        source,
        consistency,
        active_services,
        roots,
        instance: None,
    })
}

fn backup_from_to(
    adapter: &NativeAdapter,
    prepared: &PreparedBackupItem,
    target: &str,
    owner: &str,
    copy_id: &str,
) -> Result<CompletedBackupCopy> {
    if let Some(instance) = &prepared.instance {
        let completed = instance_backup::copy(adapter, instance, target, owner, copy_id)?;
        return Ok(CompletedBackupCopy {
            evidence: completed.evidence,
            artifact: completed.artifact,
        });
    }
    let config = adapter.config();
    let resource = &prepared.resource;
    let source_paths = prepared
        .roots
        .iter()
        .map(|root| root.path.clone())
        .collect::<Vec<_>>();

    let controller_target = Path::new(target).is_absolute();
    if !controller_target {
        config.host(target)?;
    } else if Path::new(target) == Path::new("/") {
        bail!("controller backup destination cannot be the filesystem root");
    }
    if controller_target {
        require_controller_backup_privileges()?;
    }

    let (copy_result, artifact) = if controller_target {
        let destination_root = PathBuf::from(target)
            .join(digest_bytes(resource.as_bytes()))
            .join(copy_id);
        let remote_source = config.remote_source(&prepared.source)?;
        let transfers = prepared
            .roots
            .iter()
            .map(|root| {
                let definition = TransferDefinition {
                    source: root.path.clone(),
                    destination: destination_root.join(
                        root.path
                            .strip_prefix("/")
                            .expect("agent validated absolute source data path"),
                    ),
                    rsync_program: config.ssh.rsync_program.clone(),
                    remote_source: Some(remote_source.clone()),
                    remote_destination: None,
                    tar_program: config.ssh.tar_program.clone(),
                    delete: true,
                    fallback_copy: true,
                };
                let transfer_started = Instant::now();
                transfer_with_excludes_progress(&definition, &root.excludes, |progress| {
                    let progress = serde_json::to_value(progress)?;
                    command_reporter().detail(format!(
                        "{} · {}",
                        root.name,
                        format_job_progress(&progress, transfer_started.elapsed())
                    ));
                    Ok(())
                })
            })
            .collect::<Result<Vec<_>>>()?;
        (
            json!({
                "destination_root": destination_root,
                "transfers": transfers,
            }),
            BackupArtifact::ControllerDirectory {
                root: destination_root,
            },
        )
    } else {
        let (job_id, job, verification, destination_root, snapshot) = if prepared.source == target {
            let job_id = format!("{copy_id}-copy");
            let plan = backup_plan_for_target(config, target, resource, &job_id, &source_paths)?;
            let job = adapter.run_profile_job_result(
                target,
                &job_id,
                owner,
                resource,
                &["--backup".to_owned()],
            )?;
            (job_id.clone(), job, Value::Null, plan, job_id)
        } else {
            let mut plan_args = vec![
                "--json".to_owned(),
                "data".to_owned(),
                "backup-plan".to_owned(),
                "--resource".to_owned(),
                resource.to_owned(),
                "--snapshot".to_owned(),
                copy_id.to_owned(),
            ];
            for path in &source_paths {
                plan_args.push("--source-path".to_owned());
                plan_args.push(path.to_string_lossy().into_owned());
            }
            let plan = config.run_agent(target, &plan_args)?;
            let destination_root = PathBuf::from(
                plan.pointer("/result/destination_root")
                    .and_then(Value::as_str)
                    .context("target backup plan has no destination_root")?,
            );
            let job_id = format!("{copy_id}-copy");
            let job = adapter.run_broker_profile_job(
                &job_id,
                owner,
                resource,
                &prepared.source,
                target,
                false,
                Some(&destination_root),
                None,
                false,
            )?;
            let verify_job_id = format!("{copy_id}-verify");
            let verification = adapter.run_broker_profile_job(
                &verify_job_id,
                owner,
                resource,
                &prepared.source,
                target,
                true,
                Some(&destination_root),
                None,
                false,
            )?;
            (
                job_id,
                job,
                verification,
                destination_root,
                copy_id.to_owned(),
            )
        };
        (
            json!({
                "destination_host": target,
                "destination_root": destination_root,
                "job_id": job_id,
                "job": job,
                "verification": verification,
            }),
            BackupArtifact::HostSnapshot {
                host: target.to_owned(),
                resource: resource.to_owned(),
                snapshot,
                root: destination_root,
            },
        )
    };

    Ok(CompletedBackupCopy {
        evidence: json!({
            "ok": true,
            "resource": resource,
            "from": prepared.source,
            "to": target,
            "backup": owner,
            "copy_id": copy_id,
            "consistency": prepared.consistency,
            "data_paths": source_paths,
            "data_roots": prepared.roots,
            "restored_active_services": prepared.active_services,
            "copy": copy_result,
        }),
        artifact,
    })
}

struct CompletedBackupCopy {
    evidence: Value,
    artifact: BackupArtifact,
}

fn backup_plan_for_target(
    config: &HostManagerConfig,
    target: &str,
    resource: &str,
    snapshot: &str,
    source_paths: &[PathBuf],
) -> Result<PathBuf> {
    let mut arguments = vec![
        "--json".to_owned(),
        "data".to_owned(),
        "backup-plan".to_owned(),
        "--resource".to_owned(),
        resource.to_owned(),
        "--snapshot".to_owned(),
        snapshot.to_owned(),
    ];
    for path in source_paths {
        arguments.extend([
            "--source-path".to_owned(),
            path.to_string_lossy().into_owned(),
        ]);
    }
    let plan = config.run_agent(target, &arguments)?;
    plan.pointer("/result/destination_root")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .context("target backup plan has no destination_root")
}

fn hold_backup_source(
    adapter: &NativeAdapter,
    prepared: &PreparedBackupItem,
    owner: &str,
    job_prefix: &str,
) -> Result<()> {
    if let Some(instance) = &prepared.instance {
        return instance_backup::hold(adapter, instance, owner, job_prefix);
    }
    adapter.run_profile_job(
        &prepared.source,
        &format!("{job_prefix}-hold"),
        owner,
        &prepared.resource,
        &["--operation".to_owned(), "hold".to_owned()],
    )?;
    adapter.run_profile_job(
        &prepared.source,
        &format!("{job_prefix}-inactive"),
        owner,
        &prepared.resource,
        &[
            "--operation".to_owned(),
            "status".to_owned(),
            "--expect".to_owned(),
            "inactive".to_owned(),
        ],
    )
}

fn restore_backup_source(
    adapter: &NativeAdapter,
    prepared: &PreparedBackupItem,
    owner: &str,
    job_prefix: &str,
) -> Result<()> {
    if let Some(instance) = &prepared.instance {
        return instance_backup::release(adapter, instance, owner, job_prefix);
    }
    let (job_suffix, arguments) = restore_arguments(&prepared.active_services);
    adapter.run_profile_job(
        &prepared.source,
        &format!("{job_prefix}-{job_suffix}"),
        owner,
        &prepared.resource,
        &arguments,
    )
}

fn restore_arguments(active_services: &[String]) -> (&'static str, Vec<String>) {
    if active_services.is_empty() {
        (
            "release",
            vec!["--operation".to_owned(), "release".to_owned()],
        )
    } else {
        let mut arguments = vec!["--restore".to_owned()];
        for service in active_services {
            arguments.push("--active-service".to_owned());
            arguments.push(service.clone());
        }
        ("restore", arguments)
    }
}

fn parse_active_services(status: &serde_json::Value) -> Result<Vec<String>> {
    status
        .pointer("/result/services")
        .and_then(|value| value.as_array())
        .context("resource status response has no services")?
        .iter()
        .filter(|result| result.get("success").and_then(|value| value.as_bool()) == Some(true))
        .map(|result| {
            let target = result
                .get("target")
                .context("resource status entry has no target")?;
            let scope = target
                .get("scope")
                .and_then(|value| value.as_str())
                .context("resource status target has no scope")?;
            let unit = target
                .get("unit")
                .and_then(|value| value.as_str())
                .context("resource status target has no unit")?;
            match scope {
                "system" => Ok(format!("system:{unit}")),
                "user" => match target.get("user").and_then(|value| value.as_str()) {
                    Some(user) => Ok(format!("user:{user}:{unit}")),
                    None => Ok(format!("user:{unit}")),
                },
                value => bail!("resource status target has invalid scope {value:?}"),
            }
        })
        .collect()
}

fn require_controller_backup_privileges() -> Result<()> {
    let status = fs::read_to_string("/proc/self/status").context("read process credentials")?;
    let effective_uid = status
        .lines()
        .find_map(|line| line.strip_prefix("Uid:"))
        .and_then(|uids| uids.split_whitespace().nth(1))
        .context("process status has no effective UID")?
        .parse::<u32>()
        .context("parse effective UID")?;
    if effective_uid != 0 {
        bail!(
            "controller-directory backups must run through local sudo so ownership, ACLs, xattrs, and restrictive modes can be reproduced and verified"
        );
    }
    Ok(())
}

fn should_dry_run(action: Action, guard: &ExecutionGuard) -> Result<bool> {
    let _ = action;
    if guard.execute {
        terminal_warning("warning: --execute is deprecated; mutating commands execute by default");
    }
    Ok(guard.dry_run)
}

fn require_guard(guard: &ExecutionGuard, operation: &str) -> Result<()> {
    let _ = operation;
    if guard.execute {
        terminal_warning("warning: --execute is deprecated; mutating commands execute by default");
    }
    Ok(())
}

fn read_json_document<T: serde::de::DeserializeOwned>(source: &str, label: &str) -> Result<T> {
    const MAX_DOCUMENT_BYTES: u64 = 4 * 1024 * 1024;
    let bytes = if source == "-" {
        let mut bytes = Vec::new();
        io::stdin()
            .take(MAX_DOCUMENT_BYTES + 1)
            .read_to_end(&mut bytes)
            .with_context(|| format!("read {label} from stdin"))?;
        bytes
    } else {
        let path = Path::new(source);
        let metadata =
            fs::metadata(path).with_context(|| format!("inspect {label} {}", path.display()))?;
        if metadata.len() > MAX_DOCUMENT_BYTES {
            bail!("{label} exceeds the 4 MiB input limit");
        }
        fs::read(path).with_context(|| format!("read {label} {}", path.display()))?
    };
    if bytes.len() as u64 > MAX_DOCUMENT_BYTES {
        bail!("{label} exceeds the 4 MiB input limit");
    }
    serde_json::from_slice(&bytes).with_context(|| format!("parse {label} as JSON"))
}

fn emit_result(value: &impl Serialize) -> Result<()> {
    let value = serde_json::to_value(value)?;
    if json_output() {
        println!("{}", serde_json::to_string_pretty(&value)?);
    } else {
        let fallback = inspect_presentation("Result");
        let presentation = COMMAND_PRESENTATION.get().unwrap_or(&fallback);
        let rendered = render_presentation(presentation, &value);
        print!(
            "{}",
            TerminalStyle::for_stdout().semantic_document(&rendered)
        );
    }
    Ok(())
}

fn human_status(message: impl std::fmt::Display) {
    if !json_output() {
        command_reporter().message(message);
    }
}

fn terminal_warning(message: &str) {
    eprintln!(
        "{}",
        TerminalStyle::for_stderr().paint(Tone::Warning, message)
    );
}

fn transient_step<T>(
    description: impl Into<String>,
    operation: impl FnOnce() -> Result<T>,
) -> Result<T> {
    let description = description.into();
    let started = Instant::now();
    command_reporter().started(description.clone());
    match operation() {
        Ok(value) => {
            command_reporter().completed(description, started.elapsed());
            Ok(value)
        }
        Err(error) if json_output() => Err(error),
        Err(error) => {
            command_reporter().fail_active(description, &format!("{error:#}"));
            Err(RenderedCommandFailure.into())
        }
    }
}

fn resolve_config(config: Option<&Path>, repo_root: Option<&Path>) -> Result<PathBuf> {
    let current = env::current_dir().context("resolve current directory for config discovery")?;
    resolve_config_from(config, repo_root, &current)
}

fn resolve_config_from(
    config: Option<&Path>,
    repo_root: Option<&Path>,
    current: &Path,
) -> Result<PathBuf> {
    if let Some(config) = config {
        let config = if config.is_absolute() {
            config.to_path_buf()
        } else {
            current.join(config)
        };
        return config
            .canonicalize()
            .with_context(|| format!("resolve manager config {}", config.display()));
    }
    Repository::discover_from(repo_root.map(Path::to_path_buf), current)
        .map(|repository| repository.nixbot_config_path())
        .context(
            "native manager config is unavailable; pass --config, set \
             ABIRD_HOST_MANAGER_CONFIG, or run inside an Abird repository",
        )
}

fn default_state_dir() -> Result<PathBuf> {
    if let Some(path) = env::var_os("XDG_STATE_HOME") {
        return Ok(PathBuf::from(path).join("abird-host-manager"));
    }
    let home = env::var_os("HOME")
        .context("cannot choose state directory: set --state-dir, XDG_STATE_HOME, or HOME")?;
    Ok(PathBuf::from(home)
        .join(".local")
        .join("state")
        .join("abird-host-manager"))
}

fn resolve_state_dir(configured: Option<PathBuf>) -> Result<PathBuf> {
    configured.map(Ok).unwrap_or_else(default_state_dir)
}

fn select_local_run(cli: &mut Cli) -> Result<()> {
    let Some(name) = cli.local_run.as_deref() else {
        return Ok(());
    };
    validate_local_run_name(name)?;
    let repository = Repository::discover(cli.repo_root.clone())?;
    cli.controller = Some("local".to_owned());
    cli.state_dir = Some(
        repository
            .root()
            .join(".agents")
            .join("runs")
            .join(name)
            .join("host-manager"),
    );
    Ok(())
}

fn select_local_mode(cli: &mut Cli) -> Result<()> {
    if !cli.local {
        return Ok(());
    }
    let repository = Repository::discover(cli.repo_root.clone())?;
    cli.controller = Some("local".to_owned());
    cli.state_dir = Some(
        repository
            .root()
            .join(".agents")
            .join("runs")
            .join("local")
            .join("host-manager"),
    );
    cli.publish_git_ssh_command = None;
    Ok(())
}

fn validate_local_run_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name.len() > 128
        || name == "locks"
        || name.starts_with('-')
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    {
        bail!(
            "--local-run must be 1-128 lowercase letters, digits, or non-leading hyphens, and cannot be 'locks'"
        );
    }
    Ok(())
}

fn remote_controller_state_dir(configured: Option<&Path>) -> Result<String> {
    let Some(configured) = configured else {
        return Ok(CONTROLLER_STATE_DIR.to_owned());
    };
    if configured.is_absolute()
        || configured.as_os_str().is_empty()
        || !configured
            .components()
            .all(|component| matches!(component, std::path::Component::Normal(_)))
    {
        bail!("remote --state-dir must be a safe relative path below {CONTROLLER_STATE_DIR}");
    }
    Ok(Path::new(CONTROLLER_STATE_DIR)
        .join(configured)
        .to_string_lossy()
        .into_owned())
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use abird_host_manager::workflow::HostEndpoint;
    use clap::CommandFactory;

    use super::*;

    fn parsed_presentation(arguments: &[&str]) -> CommandPresentation {
        let mut argv = vec!["abird-host-manager"];
        argv.extend_from_slice(arguments);
        let cli = Cli::try_parse_from(argv).unwrap();
        command_presentation(&cli.command)
    }

    fn remote_test_execution() -> ProjectionExecution {
        ProjectionExecution {
            repo_root: None,
            git_program: PathBuf::from("git"),
            nix_program: PathBuf::from("nix"),
            branch: "master".to_owned(),
            publish_git_ssh_command: None,
            mode: ProjectionPublicationMode::Remote,
        }
    }

    #[test]
    fn closeout_deploy_flags_choose_noninteractive_modes() {
        assert_eq!(
            select_closeout_deploy_mode(true, false, "0123456789abcdef", false, true).unwrap(),
            CloseoutDeployMode::Managed
        );
        assert_eq!(
            select_closeout_deploy_mode(false, true, "0123456789abcdef", false, false).unwrap(),
            CloseoutDeployMode::Manual
        );
    }

    #[test]
    fn local_mode_uses_an_isolated_local_controller_journal() {
        let temp = tempfile::tempdir().unwrap();
        for directory in ["pkgs", "hosts", "data/secrets"] {
            fs::create_dir_all(temp.path().join(directory)).unwrap();
        }
        for file in [
            "flake.nix",
            "pkgs/manifest.nix",
            "hosts/default.nix",
            "hosts/nixbot.nix",
            "data/secrets/default.nix",
        ] {
            fs::write(temp.path().join(file), "{}\n").unwrap();
        }
        let mut cli = Cli::try_parse_from([
            "abird-host-manager",
            "--repo-root",
            temp.path().to_str().unwrap(),
            "transaction",
            "list",
            "--local",
        ])
        .unwrap();

        select_local_mode(&mut cli).unwrap();
        assert_eq!(cli.controller.as_deref(), Some("local"));
        assert_eq!(
            cli.state_dir,
            Some(temp.path().join(".agents/runs/local/host-manager"))
        );
        assert!(!should_dispatch_to_controller(&cli));
    }

    #[test]
    fn local_command_plans_never_claim_a_git_push() {
        for steps in [
            move_command_steps(ProjectionPublicationMode::Local),
            projected_command_steps(LifecycleCommand::Prepare, ProjectionPublicationMode::Local),
            close_command_steps(
                ProjectionPublicationMode::Local,
                CloseoutRepositoryKind::Legacy,
            ),
            close_command_steps(
                ProjectionPublicationMode::Local,
                CloseoutRepositoryKind::NixNative,
            ),
        ] {
            assert!(steps.iter().any(|step| step.contains("retain-local")));
            assert!(!steps.iter().any(|step| step.contains("push")));
            assert!(!steps.iter().any(|step| step.contains("remote")));
        }
    }

    #[test]
    fn nix_native_closeout_releases_recovery_only_after_clean_deployment() {
        let steps = close_command_steps(
            ProjectionPublicationMode::Remote,
            CloseoutRepositoryKind::NixNative,
        );
        let position = |step| {
            steps
                .iter()
                .position(|candidate| *candidate == step)
                .unwrap()
        };

        assert!(position("move.retain-adoption") < position("nixbot.deploy-adoption"));
        assert!(position("nixbot.deploy-adoption") < position("move.remove-adopted"));
        assert!(position("move.remove-adopted") < position("nixbot.deploy-cleanup"));
        assert!(position("nixbot.deploy-cleanup") < position("inactive.release-projection-hold"));
    }

    #[test]
    fn repeated_prepare_and_run_supersede_only_their_terminal_failed_attempts() {
        assert!(should_auto_supersede_projected_action(
            Action::Prepare,
            Some(Action::Prepare)
        ));
        assert!(should_auto_supersede_projected_action(
            Action::Cutover,
            Some(Action::Cutover)
        ));
        assert!(!should_auto_supersede_projected_action(
            Action::Prepare,
            Some(Action::Cutover)
        ));
        assert!(!should_auto_supersede_projected_action(
            Action::Close,
            Some(Action::Close)
        ));
    }

    #[test]
    fn lifecycle_headings_report_achieved_state_without_claiming_early_cutover() {
        for (arguments, expected) in [
            (
                vec!["service", "move", "zulip", "--from", "a", "--to", "b"],
                "Initialized migration for service zulip",
            ),
            (
                vec![
                    "resource",
                    "move",
                    "service:zulip",
                    "--from",
                    "a",
                    "--to",
                    "b",
                ],
                "Initialized migration for resource service:zulip",
            ),
            (
                vec!["host", "move", "--from", "a", "--to", "b"],
                "Initialized migration for host a",
            ),
            (
                vec!["transaction", "prepare", "move-zulip"],
                "Prepared checkpoint for move-zulip",
            ),
            (
                vec!["transaction", "run", "move-zulip"],
                "Moved traffic to target for move-zulip",
            ),
            (
                vec!["transaction", "close", "move-zulip"],
                "Closed migration move-zulip",
            ),
        ] {
            let presentation = parsed_presentation(&arguments);
            assert_eq!(presentation.completed_heading, expected);
        }
    }

    #[test]
    fn every_lifecycle_publication_plan_exposes_repository_work_in_execution_order() {
        for mode in [
            ProjectionPublicationMode::Remote,
            ProjectionPublicationMode::Local,
        ] {
            for steps in [
                move_command_steps(mode),
                projected_command_steps(LifecycleCommand::Prepare, mode),
                projected_command_steps(LifecycleCommand::Run, mode),
                close_command_steps(mode, CloseoutRepositoryKind::Legacy),
            ] {
                let prepare = steps
                    .iter()
                    .position(|step| *step == "repository.prepare-publication")
                    .unwrap();
                let commit = steps
                    .iter()
                    .position(|step| step.starts_with("git.commit"))
                    .unwrap();
                assert!(prepare < commit, "invalid publication plan: {steps:?}");
                assert!(
                    steps[prepare + 1..commit]
                        .iter()
                        .any(|step| step.contains("validate")),
                    "publication plan validates no staged state: {steps:?}"
                );
            }
        }
    }

    #[test]
    fn manual_closeout_handoff_renders_the_exact_bounded_deploy() {
        let request = abird_host_agent::deployment::NixbotDeployRequest {
            host: "abird-ci".to_owned(),
            revision: Some("0123456789abcdef".to_owned()),
            nix_config: Some("abird-ci-closeout".to_owned()),
            exclude_hosts: vec!["gap3-gondor".to_owned()],
        };
        assert_eq!(
            render_manual_nixbot_deploy_command(&request).unwrap(),
            "nix run .#nixbot -- deploy \\\n    --sha 0123456789abcdef \\\n    --hosts abird-ci,-gap3-gondor \\\n    --nix-config abird-ci-closeout \\\n    --build-plan-jobs 1 \\\n    --build-jobs 1 \\\n    --deploy-jobs 1 \\\n    --verify-jobs 1 \\\n    --no-rollback"
        );
    }

    #[test]
    fn every_public_command_family_has_an_explicit_output_contract() {
        let structured = [
            vec![
                "instance",
                "move",
                "guest",
                "--from-controller",
                "a",
                "--to-controller",
                "b",
            ],
            vec!["transaction", "create", "--spec", "/tmp/spec.json", "--dry"],
            vec!["transaction", "show", "move-1"],
            vec!["transaction", "list"],
            vec!["transaction", "prepare", "move-1", "--dry"],
            vec!["transaction", "run", "move-1", "--dry"],
            vec!["transaction", "resume", "move-1", "--dry"],
            vec!["transaction", "close", "move-1", "--dry"],
            vec!["host", "list"],
            vec!["host", "show", "target"],
            vec!["host", "move", "--from", "a", "--to", "b", "--dry"],
            vec!["host", "holds", "target"],
            vec!["host", "drain", "target", "--owner", "maintenance", "--dry"],
            vec![
                "host",
                "activate",
                "target",
                "--owner",
                "maintenance",
                "--dry",
            ],
            vec!["host", "reboot", "--hosts", "target", "--dry"],
            vec!["host", "gc", "--hosts", "target", "--dry"],
            vec!["host", "clean", "--hosts", "target", "--dry"],
            vec!["host", "create", "external", "external", "--dry"],
            vec![
                "host",
                "create",
                "incus",
                "guest",
                "--incus-parent",
                "parent",
                "--incus-ipv4",
                "10.0.0.2",
                "--dry",
            ],
            vec![
                "host",
                "create",
                "physical",
                "physical",
                "--disk",
                "/dev/example",
                "--dry",
            ],
            vec!["host", "build", "target", "--dry"],
            vec!["host", "install", "target", "--dry"],
            vec!["host", "delete", "target", "--dry"],
            vec![
                "service", "move", "mail", "--from", "a", "--to", "b", "--dry",
            ],
            vec!["service", "start", "mail", "--dry"],
            vec!["service", "stop", "mail", "--dry"],
            vec!["service", "restart", "mail", "--dry"],
            vec!["service", "reload", "mail", "--dry"],
            vec!["service", "wipe", "mail", "--host", "target", "--dry"],
            vec!["service", "status", "mail"],
            vec!["unit", "start", "target", "mail.service", "--dry"],
            vec!["unit", "stop", "target", "mail.service", "--dry"],
            vec!["unit", "restart", "target", "mail.service", "--dry"],
            vec!["unit", "reload", "target", "mail.service", "--dry"],
            vec!["unit", "status", "target", "mail.service"],
            vec![
                "resource",
                "move",
                "service:mail",
                "--from",
                "a",
                "--to",
                "b",
                "--dry",
            ],
            vec!["resource", "describe", "target", "service:mail"],
            vec!["resource", "start", "target", "service:mail", "--dry"],
            vec!["resource", "stop", "target", "service:mail", "--dry"],
            vec!["resource", "restart", "target", "service:mail", "--dry"],
            vec!["resource", "reload", "target", "service:mail", "--dry"],
            vec!["resource", "wipe", "target", "service:mail", "--dry"],
            vec!["resource", "status", "target", "service:mail"],
            vec!["resource", "ready", "target", "service:mail"],
            vec!["resource", "hold", "show", "target", "service:mail"],
            vec![
                "resource",
                "hold",
                "set",
                "target",
                "service:mail",
                "--id",
                "maintenance",
                "--dry",
            ],
            vec![
                "resource",
                "hold",
                "clear",
                "target",
                "service:mail",
                "--id",
                "maintenance",
                "--dry",
            ],
            vec!["backup", "create", "--spec", "/tmp/spec.json", "--dry"],
            vec!["backup", "show", "backup-1"],
            vec!["backup", "list"],
            vec!["backup", "verify", "backup-1"],
            vec!["backup", "resume", "backup-1", "--dry"],
            vec!["backup", "abort", "backup-1", "--dry"],
            vec!["backup", "restore", "backup-1", "--from", "target", "--dry"],
            vec!["backup", "rollback", "backup-1", "--dry"],
            vec!["backup", "activate", "backup-1", "--dry"],
            vec!["backup", "delete", "backup-1", "--dry"],
            vec!["backup", "prune", "--older-than", "30d", "--dry"],
            vec!["job", "show", "target", "--job-id", "job-1"],
            vec!["job", "list", "target"],
            vec!["job", "retry", "target", "--job-id", "job-1", "--dry"],
        ];
        for arguments in structured {
            let presentation = parsed_presentation(&arguments);
            assert_eq!(
                presentation.contract,
                OutputContract::Structured,
                "unexpected contract for {arguments:?}"
            );
        }

        for arguments in [
            vec!["host", "logs", "target"],
            vec!["service", "logs", "mail"],
            vec!["unit", "logs", "target", "mail.service"],
            vec!["resource", "logs", "target", "service:mail"],
        ] {
            assert_eq!(
                parsed_presentation(&arguments).contract,
                OutputContract::Stream
            );
        }
        for arguments in [
            vec!["host", "exec", "target", "--", "true"],
            vec!["host", "ssh", "target"],
        ] {
            assert_eq!(
                parsed_presentation(&arguments).contract,
                OutputContract::Passthrough
            );
        }
    }

    #[test]
    fn global_json_rejects_stream_and_passthrough_contracts() {
        let stream = parsed_presentation(&["service", "logs", "mail"]);
        let error = validate_output_contract(true, &stream).unwrap_err();
        assert!(format!("{error:#}").contains("--output json"));

        let passthrough = parsed_presentation(&["host", "ssh", "target"]);
        let error = validate_output_contract(true, &passthrough).unwrap_err();
        assert!(format!("{error:#}").contains("preserves the remote byte stream"));

        let structured = parsed_presentation(&["host", "show", "target"]);
        validate_output_contract(true, &structured).unwrap();
    }

    #[test]
    fn reboot_reports_submission_instead_of_unobserved_completion() {
        let presentation = parsed_presentation(&["host", "reboot", "--hosts", "target"]);
        assert_eq!(presentation.heading, "Submit reboot for hosts");
        assert_eq!(presentation.completed_heading, "Submitted reboot for hosts");
        assert_eq!(
            fleet_batch_label("reboot", 3),
            "Submit reboot request to 3 hosts"
        );
    }

    fn projection_test_spec() -> TransactionSpec {
        let mut spec = TransactionSpec::new(
            Some("move-lineage"),
            vec![MoveItem::Service {
                id: "zulip".to_owned(),
                service: "zulip".to_owned(),
                source_resource: None,
                target_resource: None,
                source: HostEndpoint {
                    host: "source".to_owned(),
                    instance: None,
                },
                target: HostEndpoint {
                    host: "target".to_owned(),
                    instance: None,
                },
                data_roots: Vec::new(),
            }],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        spec.declarative_scope = Some("abird".to_owned());
        spec
    }

    fn projection_test_config() -> HostManagerConfig {
        serde_json::from_value(json!({
            "schema_version": 1,
            "ssh": {
                "program": "/bin/false",
                "connect_timeout_seconds": 1,
                "agent_poll_interval_ms": 1,
                "job_timeout_seconds": 1,
                "rsync_program": "/bin/false",
                "tar_program": "/bin/false"
            },
            "hosts": {
                "source": {"address": "source", "host_resource": "host:source"},
                "target": {"address": "target", "host_resource": "host:target"},
                "proxy": {"address": "proxy", "host_resource": "host:proxy"}
            },
            "operation_routes": {
                "deploy-cutover": {
                    "executor": "proxy",
                    "phase_projection": {"executor": "proxy", "resource": "service:proxy"}
                },
                "deploy-rollback": {
                    "executor": "proxy",
                    "phase_projection": {"executor": "proxy", "resource": "service:proxy"}
                }
            }
        }))
        .unwrap()
    }

    #[test]
    fn projection_adoption_requires_direct_valid_lineage() {
        let spec = projection_test_spec();
        let config = projection_test_config();
        let seeded = MoveProjector::derive(&spec, &config, MovePhase::Seeded, None, None).unwrap();
        let prepared = MoveProjector::derive(
            &spec,
            &config,
            MovePhase::Prepared,
            Some(&seeded),
            Some("seeded-revision".to_owned()),
        )
        .unwrap();
        let cutover = MoveProjector::derive(
            &spec,
            &config,
            MovePhase::Cutover,
            Some(&prepared),
            Some("prepared-revision".to_owned()),
        )
        .unwrap();

        validate_projection_adoption(None, &seeded, &spec).unwrap();
        validate_projection_adoption(Some(&seeded), &prepared, &spec).unwrap();
        assert!(validate_projection_adoption(None, &prepared, &spec).is_err());
        assert!(validate_projection_adoption(Some(&seeded), &cutover, &spec).is_err());
        assert!(validate_projection_adoption(Some(&prepared), &seeded, &spec).is_err());
    }

    #[test]
    fn stateful_repository_moves_and_three_phase_commands_use_controller_authority() {
        for argv in [
            vec![
                "abird-host-manager",
                "service",
                "move",
                "zulip",
                "--from",
                "source",
                "--to",
                "target",
                "--dry-run",
            ],
            vec![
                "abird-host-manager",
                "transaction",
                "create",
                "--spec",
                "/tmp/move.json",
                "--dry-run",
            ],
            vec![
                "abird-host-manager",
                "transaction",
                "prepare",
                "move-zulip",
                "--dry-run",
            ],
            vec![
                "abird-host-manager",
                "transaction",
                "cutover",
                "move-zulip",
                "--dry-run",
            ],
            vec![
                "abird-host-manager",
                "transaction",
                "rollback",
                "move-zulip",
                "--dry-run",
            ],
            vec![
                "abird-host-manager",
                "transaction",
                "resume",
                "move-zulip",
                "--dry-run",
            ],
            vec![
                "abird-host-manager",
                "resource",
                "hold",
                "set",
                "target",
                "service:zulip",
                "--id",
                "hold-zulip",
                "--dry-run",
            ],
            vec![
                "abird-host-manager",
                "resource",
                "hold",
                "clear",
                "target",
                "service:zulip",
                "--id",
                "hold-zulip",
                "--skip-runtime",
                "--execute",
            ],
        ] {
            let cli = Cli::try_parse_from(argv).unwrap();
            assert!(is_controller_authority_command(&cli.command));
        }
        let local = Cli::try_parse_from([
            "abird-host-manager",
            "--state-dir",
            "/tmp/state",
            "transaction",
            "prepare",
            "move-zulip",
            "--dry-run",
        ])
        .unwrap();
        assert!(!should_dispatch_to_controller(&local));
    }

    #[test]
    fn forced_close_is_break_glass_completion_only() {
        let cli = Cli::try_parse_from([
            "abird-host-manager",
            "transaction",
            "close",
            "move-zulip",
            "--complete",
            "--force",
        ])
        .unwrap();
        let Command::Transaction {
            command: TransactionCommand::Close(args),
        } = cli.command
        else {
            panic!("expected close command");
        };
        assert!(args.complete);
        assert!(args.force);
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                "close",
                "move-zulip",
                "--force",
            ])
            .is_err()
        );
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                "close",
                "move-zulip",
                "--rollback",
                "--force",
            ])
            .is_err()
        );
    }

    #[test]
    fn explicit_controller_and_remote_state_keep_controller_dispatch() {
        let cli = Cli::try_parse_from([
            "abird-host-manager",
            "--controller",
            "abird-ci",
            "--state-dir",
            "zulip-move",
            "transaction",
            "prepare",
            "move-zulip",
            "--dry-run",
        ])
        .unwrap();

        assert!(should_dispatch_to_controller(&cli));
        assert_eq!(
            remote_controller_state_dir(cli.state_dir.as_deref()).unwrap(),
            "/var/lib/nixbot/abird-host-manager/zulip-move"
        );
        assert!(remote_controller_state_dir(Some(Path::new("../escape"))).is_err());
        assert!(remote_controller_state_dir(Some(Path::new("/absolute"))).is_err());
    }

    #[test]
    fn local_run_is_a_safe_repo_run_state_shortcut() {
        for invalid in ["", "locks", "-bad", "Bad", "slash/name", "under_score"] {
            assert!(
                validate_local_run_name(invalid).is_err(),
                "accepted {invalid:?}"
            );
        }
        validate_local_run_name("zulip-move-20260824").unwrap();

        let fixture = tempfile::tempdir().unwrap();
        for directory in ["pkgs", "hosts", "data/secrets"] {
            fs::create_dir_all(fixture.path().join(directory)).unwrap();
        }
        for file in [
            "flake.nix",
            "pkgs/manifest.nix",
            "hosts/default.nix",
            "hosts/nixbot.nix",
            "data/secrets/default.nix",
        ] {
            fs::write(fixture.path().join(file), "").unwrap();
        }
        let repo_root = fixture.path().canonicalize().unwrap();
        let mut cli = Cli::try_parse_from([
            "abird-host-manager",
            "--repo-root",
            repo_root.to_str().unwrap(),
            "--local-run",
            "zulip-move-20260824",
            "transaction",
            "show",
            "move-zulip",
        ])
        .unwrap();
        select_local_run(&mut cli).unwrap();

        assert_eq!(cli.controller.as_deref(), Some("local"));
        assert_eq!(
            cli.state_dir.as_deref(),
            Some(
                repo_root
                    .join(".agents/runs/zulip-move-20260824/host-manager")
                    .as_path()
            )
        );
        assert!(!should_dispatch_to_controller(&cli));
    }

    #[test]
    fn local_run_rejects_explicit_controller_or_state() {
        for conflict in [
            vec!["--local-run", "run", "--controller", "local"],
            vec!["--local-run", "run", "--state-dir", "state"],
        ] {
            let mut argv = vec!["abird-host-manager"];
            argv.extend(conflict);
            argv.extend(["transaction", "show", "move-zulip"]);
            assert!(Cli::try_parse_from(argv).is_err());
        }
    }

    #[test]
    fn controller_dispatch_strips_only_locally_selected_authority_paths() {
        assert_eq!(
            controller_command_arguments(
                [
                    "--repo-root",
                    "/operator/repo",
                    "--controller=abird-ci",
                    "--git-program=/bin/git",
                    "transaction",
                    "cutover",
                    "move-zulip",
                    "--execute",
                ]
                .into_iter()
                .map(str::to_owned),
            )
            .unwrap(),
            [
                "--git-program=/bin/git",
                "transaction",
                "cutover",
                "move-zulip",
                "--execute",
            ]
        );
    }

    #[test]
    fn publication_authority_is_lent_only_to_executed_publishers() {
        for argv in [
            vec![
                "abird-host-manager",
                "service",
                "move",
                "zulip",
                "--from",
                "source",
                "--to",
                "target",
                "--execute",
            ],
            vec![
                "abird-host-manager",
                "resource",
                "hold",
                "set",
                "target",
                "service:zulip",
                "--id",
                "hold-zulip",
                "--execute",
            ],
        ] {
            let cli = Cli::try_parse_from(argv).unwrap();
            assert_eq!(
                controller_publication_authority(&cli.command),
                PublicationAuthority::Required
            );
        }
        for command in ["prepare", "run", "rollback", "close"] {
            let cli =
                Cli::try_parse_from(["abird-host-manager", "transaction", command, "move-zulip"])
                    .unwrap();
            assert_eq!(
                controller_publication_authority(&cli.command),
                PublicationAuthority::Required,
                "non-dry transaction {command} must preflight publication access",
            );
        }
        for argv in [
            vec![
                "abird-host-manager",
                "service",
                "move",
                "zulip",
                "--from",
                "source",
                "--to",
                "target",
                "--dry-run",
            ],
            vec!["abird-host-manager", "transaction", "show", "move-zulip"],
            vec![
                "abird-host-manager",
                "transaction",
                "resume",
                "move-zulip",
                "--execute",
            ],
        ] {
            let cli = Cli::try_parse_from(argv).unwrap();
            assert_eq!(
                controller_publication_authority(&cli.command),
                PublicationAuthority::None
            );
        }
        for command in ["prepare", "run", "rollback", "close"] {
            let cli = Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                command,
                "move-zulip",
                "--dry",
            ])
            .unwrap();
            assert_eq!(
                controller_publication_authority(&cli.command),
                PublicationAuthority::None,
                "dry transaction {command} must not preflight publication access",
            );
        }
    }

    #[test]
    fn controller_arguments_do_not_forward_local_publication_transport() {
        assert_eq!(
            controller_command_arguments(
                [
                    "--publish-git-ssh-command",
                    "operator-ssh",
                    "transaction",
                    "prepare",
                    "move-zulip",
                    "--execute",
                ]
                .into_iter()
                .map(str::to_owned),
            )
            .unwrap(),
            ["transaction", "prepare", "move-zulip", "--execute"]
        );
    }

    #[test]
    fn all_three_operator_decisions_accept_declarative_only_execution() {
        Cli::try_parse_from([
            "abird-host-manager",
            "service",
            "move",
            "zulip",
            "--from",
            "source",
            "--to",
            "target",
            "--skip-runtime",
            "--execute",
        ])
        .unwrap();
        for phase in ["prepare", "cutover", "rollback"] {
            Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                phase,
                "move-zulip",
                "--skip-runtime",
                "--execute",
            ])
            .unwrap();
        }
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                "seed",
                "move-zulip",
                "--skip-runtime",
                "--execute",
            ])
            .is_err()
        );
        Cli::try_parse_from([
            "abird-host-manager",
            "transaction",
            "resume",
            "move-zulip",
            "--supersede-failed-job",
            "--execute",
        ])
        .unwrap();
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                "reconcile",
                "move-zulip",
                "--execute",
            ])
            .is_err()
        );
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                "_reconcile",
                "move-zulip",
                "--execute",
            ])
            .is_err()
        );
        Cli::try_parse_from([
            "abird-host-manager",
            "transaction",
            "_reconcile",
            "move-zulip",
            "--expected-projection-sha256",
            &"a".repeat(64),
            "--execute",
        ])
        .unwrap();
    }

    #[test]
    fn cutover_reconciliation_includes_skipped_prepare() {
        let spec = TransactionSpec::new(
            Some("move-reconcile"),
            vec![MoveItem::Service {
                id: "item-001".to_owned(),
                service: "zulip".to_owned(),
                source_resource: None,
                target_resource: None,
                source: HostEndpoint {
                    host: "source".to_owned(),
                    instance: None,
                },
                target: HostEndpoint {
                    host: "target".to_owned(),
                    instance: None,
                },
                data_roots: Vec::new(),
            }],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        let mut record = TransactionRecord::new(spec, "/tmp/config.json".into()).unwrap();
        record.phase = abird_host_manager::workflow_runtime::WorkflowPhase::Seeded;
        assert_eq!(
            reconciliation_actions(&record, MovePhase::Cutover).unwrap(),
            vec![Action::Prepare, Action::Cutover]
        );

        record.phase = abird_host_manager::workflow_runtime::WorkflowPhase::Cutover;
        record.pending_action = None;
        assert_eq!(
            reconciliation_actions(&record, MovePhase::Prepared).unwrap(),
            vec![Action::Prepare]
        );
        record.phase = abird_host_manager::workflow_runtime::WorkflowPhase::Prepared;
        record.pending_action = Some(Action::Prepare);
        assert_eq!(
            reconciliation_actions(&record, MovePhase::Prepared).unwrap(),
            vec![Action::Prepare]
        );
        record.pending_action = Some(Action::Rollback);
        assert_eq!(
            reconciliation_actions(&record, MovePhase::RolledBack).unwrap(),
            vec![Action::Rollback]
        );
    }

    #[test]
    fn resume_selects_pending_legacy_work_or_projected_reconciliation() {
        let spec = projection_test_spec();
        let mut record = TransactionRecord::new(spec.clone(), "/tmp/config.json".into()).unwrap();
        assert!(transaction_resume_strategy(&record).is_err());

        record.pending_action = Some(Action::Prepare);
        assert_eq!(
            transaction_resume_strategy(&record).unwrap(),
            TransactionResumeStrategy::PendingAction(Action::Prepare)
        );

        record.projection = Some(
            MoveProjector::derive(
                &spec,
                &projection_test_config(),
                MovePhase::Seeded,
                None,
                None,
            )
            .unwrap(),
        );
        assert_eq!(
            transaction_resume_strategy(&record).unwrap(),
            TransactionResumeStrategy::ProjectedReconciliation
        );

        let terminal = MoveProjector::derive(
            &spec,
            &projection_test_config(),
            MovePhase::RolledBack,
            record.projection.as_ref(),
            None,
        )
        .unwrap();
        let terminal_digest = terminal.projection_sha256.clone();
        record.projection = Some(terminal);
        record.phase = abird_host_manager::workflow_runtime::WorkflowPhase::RolledBack;
        record.pending_action = Some(Action::Close);
        record.close_decision = Some(CloseDecision::Rollback);
        record.lifecycle_state = Some(LifecycleState::ClosingRollback);
        let execution = record
            .begin_command(
                LifecycleCommand::Close,
                LifecycleState::ClosedOnSource,
                Some(CloseDecision::Rollback),
                close_command_steps(
                    ProjectionPublicationMode::Remote,
                    CloseoutRepositoryKind::Legacy,
                ),
            )
            .unwrap();
        for step in close_command_steps(
            ProjectionPublicationMode::Remote,
            CloseoutRepositoryKind::Legacy,
        ) {
            record.start_command_step(execution, step).unwrap();
            record.complete_command_step(execution, step, None).unwrap();
            if step == "nixbot.deploy-closeout" {
                break;
            }
        }
        assert_eq!(
            transaction_resume_strategy(&record).unwrap(),
            TransactionResumeStrategy::DeployedCloseout {
                projection_sha256: terminal_digest.clone(),
            }
        );
        record.pending_action = None;
        assert_eq!(
            transaction_resume_strategy(&record).unwrap(),
            TransactionResumeStrategy::DeployedCloseout {
                projection_sha256: terminal_digest,
            }
        );
    }

    #[test]
    fn resume_routes_to_the_running_command_before_the_published_projection() {
        let spec = projection_test_spec();
        let mut record = TransactionRecord::new(spec.clone(), "/tmp/config.json".into()).unwrap();
        record.phase = abird_host_manager::workflow_runtime::WorkflowPhase::Prepared;
        record.projection = Some(
            MoveProjector::derive(
                &spec,
                &projection_test_config(),
                MovePhase::Cutover,
                Some(
                    &MoveProjector::derive(
                        &spec,
                        &projection_test_config(),
                        MovePhase::Prepared,
                        Some(
                            &MoveProjector::derive(
                                &spec,
                                &projection_test_config(),
                                MovePhase::Seeded,
                                None,
                                None,
                            )
                            .unwrap(),
                        ),
                        None,
                    )
                    .unwrap(),
                ),
                None,
            )
            .unwrap(),
        );
        record
            .begin_command(
                LifecycleCommand::Prepare,
                LifecycleState::Prepared,
                None,
                ["state.check-transition", "runtime.reconcile-prepared"],
            )
            .unwrap();

        assert_eq!(
            transaction_resume_strategy(&record).unwrap(),
            TransactionResumeStrategy::ActiveCommand {
                command: LifecycleCommand::Prepare,
                close_decision: None,
            }
        );
    }

    #[test]
    fn canonical_closeout_supersedes_only_its_exact_terminal_projection() {
        let spec = projection_test_spec();
        let mut record = TransactionRecord::new(spec.clone(), "/tmp/config.json".into()).unwrap();
        let seeded = MoveProjector::derive(
            &spec,
            &projection_test_config(),
            MovePhase::Seeded,
            None,
            None,
        )
        .unwrap();
        let projection = MoveProjector::derive(
            &spec,
            &projection_test_config(),
            MovePhase::RolledBack,
            Some(&seeded),
            None,
        )
        .unwrap();
        let digest = projection.projection_sha256.clone();
        record.projection = Some(projection);
        record.close_decision = Some(CloseDecision::Rollback);
        let closeout = CanonicalProjectionCloseout {
            affected_hosts: vec!["source".to_owned(), "target".to_owned()],
            controller_reconcile: true,
            decision: "rollback".to_owned(),
            projection_sha256: digest.clone(),
        };

        validate_canonical_closeout_supersedes_projection(&record, &closeout, Some(&digest))
            .unwrap();

        let mut mismatched = closeout;
        mismatched.decision = "complete".to_owned();
        assert!(
            validate_canonical_closeout_supersedes_projection(&record, &mismatched, Some(&digest),)
                .unwrap_err()
                .to_string()
                .contains("persisted journal decision")
        );
    }

    #[test]
    fn interrupted_run_is_conservatively_target_authoritative_for_rollback() {
        let mut record =
            TransactionRecord::new(projection_test_spec(), "/tmp/config.json".into()).unwrap();
        assert!(record.items.values().all(|item| !item.target_ever_started));
        mark_interrupted_run_as_potential_writer(None, &mut record).unwrap();
        assert!(record.items.values().all(|item| item.target_ever_started));
        assert_eq!(
            record.data_authority,
            Some(abird_host_manager::workflow_runtime::DataAuthority::Target)
        );
    }

    #[test]
    fn close_flags_are_explicit_or_automatic_and_have_short_aliases() {
        for flag in [
            None,
            Some("--complete"),
            Some("-c"),
            Some("--rollback"),
            Some("-r"),
        ] {
            let mut argv = vec![
                "abird-host-manager",
                "transaction",
                "close",
                "move-zulip",
                "--dry",
            ];
            if let Some(flag) = flag {
                argv.push(flag);
            }
            Cli::try_parse_from(argv).unwrap();
        }
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                "close",
                "move-zulip",
                "--complete",
                "--rollback",
            ])
            .is_err()
        );
        for flag in ["--yes", "--manual-deploy"] {
            Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                "close",
                "move-zulip",
                flag,
            ])
            .unwrap();
        }
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                "close",
                "move-zulip",
                "--yes",
                "--manual-deploy",
            ])
            .is_err()
        );
    }

    #[test]
    fn parses_output_for_every_remote_log_scope_and_follow_mode() {
        for arguments in [
            vec![
                "abird-host-manager",
                "host",
                "logs",
                "target",
                "--output",
                "json",
            ],
            vec![
                "abird-host-manager",
                "service",
                "logs",
                "zulip",
                "--follow",
                "--output",
                "text",
            ],
            vec![
                "abird-host-manager",
                "unit",
                "logs",
                "target",
                "zulip.service",
                "-f",
                "--output",
                "json",
            ],
            vec![
                "abird-host-manager",
                "resource",
                "logs",
                "target",
                "service:zulip",
                "-f",
                "--output",
                "text",
            ],
        ] {
            Cli::try_parse_from(arguments).unwrap();
        }
    }

    #[test]
    fn log_options_encode_text_snapshots_and_json_follow_identically() {
        let mut snapshot = vec!["logs".to_owned()];
        append_log_options(
            &mut snapshot,
            &LogOptions {
                lines: 50,
                since: None,
                follow: false,
                output: LogOutput::Text,
            },
        );
        assert_eq!(snapshot, ["logs", "--lines", "50", "--output", "text"]);

        let mut follow = vec!["logs".to_owned()];
        append_log_options(
            &mut follow,
            &LogOptions {
                lines: 10,
                since: Some("today".to_owned()),
                follow: true,
                output: LogOutput::Json,
            },
        );
        assert_eq!(
            follow,
            [
                "logs", "--lines", "10", "--output", "json", "--since", "today", "--follow",
            ]
        );
    }

    #[test]
    fn logical_services_and_raw_units_have_distinct_syntax() {
        Cli::try_parse_from(["abird-host-manager", "service", "status", "zulip"]).unwrap();
        Cli::try_parse_from([
            "abird-host-manager",
            "service",
            "status",
            "zulip",
            "--host",
            "abird-gondor-corp",
        ])
        .unwrap();
        Cli::try_parse_from([
            "abird-host-manager",
            "unit",
            "status",
            "abird-gondor-corp",
            "zulip.service",
            "--scope",
            "user",
            "--user",
            "zulip",
        ])
        .unwrap();
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "service",
                "status",
                "abird-gondor-corp",
                "zulip.service",
            ])
            .is_err()
        );
    }

    #[test]
    fn repeated_typed_moves_accept_an_explicit_existing_transaction_guard() {
        for arguments in [
            vec![
                "abird-host-manager",
                "service",
                "move",
                "zulip",
                "--from",
                "source",
                "--to",
                "target",
                "--id",
                "move-zulip",
                "--force-existing",
                "--execute",
            ],
            vec![
                "abird-host-manager",
                "resource",
                "move",
                "service:zulip",
                "--from",
                "source",
                "--to",
                "target",
                "--force-existing",
                "--dry-run",
            ],
            vec![
                "abird-host-manager",
                "host",
                "move",
                "--from",
                "source",
                "--to",
                "target",
                "--force-existing",
                "--dry-run",
            ],
            vec![
                "abird-host-manager",
                "instance",
                "move",
                "zulip",
                "--from-controller",
                "source",
                "--to-controller",
                "target",
                "--force-existing",
                "--dry-run",
            ],
        ] {
            Cli::try_parse_from(arguments).unwrap();
        }
    }

    #[test]
    fn repeated_move_preserves_seeded_and_advanced_journals() {
        let state = tempfile::tempdir().unwrap();
        let store = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let spec = TransactionSpec::new(
            Some("move-repeated"),
            vec![MoveItem::Service {
                id: "item-001".to_owned(),
                service: "zulip".to_owned(),
                source_resource: None,
                target_resource: None,
                source: HostEndpoint {
                    host: "source".to_owned(),
                    instance: None,
                },
                target: HostEndpoint {
                    host: "target".to_owned(),
                    instance: None,
                },
                data_roots: Vec::new(),
            }],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        let candidate = TransactionRecord::new(spec, "/missing/config.json".into()).unwrap();
        let WorkflowRegistration::Created(mut record) = store.register(candidate).unwrap() else {
            panic!("first registration should create the transaction");
        };

        record.phase = abird_host_manager::workflow_runtime::WorkflowPhase::Seeded;
        store.save(&record).unwrap();
        execute_existing_move(&store, record, false, false, &remote_test_execution()).unwrap();
        let seeded = store.load("move-repeated").unwrap();
        assert_eq!(
            seeded.phase,
            abird_host_manager::workflow_runtime::WorkflowPhase::Seeded
        );
        assert!(
            seeded
                .events
                .last()
                .unwrap()
                .message
                .contains("already complete")
        );

        let mut prepared = seeded;
        prepared.phase = abird_host_manager::workflow_runtime::WorkflowPhase::Prepared;
        store.save(&prepared).unwrap();
        assert!(
            execute_existing_move(
                &store,
                prepared.clone(),
                false,
                false,
                &remote_test_execution(),
            )
            .unwrap_err()
            .to_string()
            .contains("--force-existing")
        );
        execute_existing_move(&store, prepared, true, false, &remote_test_execution()).unwrap();
        let attached = store.load("move-repeated").unwrap();
        assert_eq!(
            attached.phase,
            abird_host_manager::workflow_runtime::WorkflowPhase::Prepared
        );
        assert!(
            attached
                .events
                .last()
                .unwrap()
                .message
                .contains("with no pending action")
        );
    }

    #[test]
    fn parses_typed_physical_and_offline_lifecycle_options() {
        Cli::try_parse_from([
            "abird-host-manager",
            "host",
            "create",
            "physical",
            "new-host",
            "--disk",
            "/dev/disk/by-id/nvme-example",
            "--boot-mode",
            "bios",
            "--boot-size",
            "2G",
            "--swap-size-mib",
            "4096",
            "--execute",
        ])
        .unwrap();
        Cli::try_parse_from([
            "abird-host-manager",
            "host",
            "install",
            "new-host",
            "--offline-cache",
            "/media/cache",
            "--wipe-disks",
            "--execute",
        ])
        .unwrap();
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "host",
                "create",
                "external",
                "new-host",
                "--esp-size",
                "2G",
                "--dry-run",
            ])
            .is_err()
        );
        assert!(
            Cli::try_parse_from(["abird-host-manager", "host", "generate", "new-host"]).is_err()
        );
        assert!(
            Cli::try_parse_from(["abird-host-manager", "host", "live-install", "new-host"])
                .is_err()
        );
        Cli::try_parse_from([
            "abird-host-manager",
            "host",
            "gc",
            "--hosts",
            "new-host",
            "--all-generations",
            "--dry-run",
        ])
        .unwrap();
        Cli::try_parse_from([
            "abird-host-manager",
            "host",
            "clean",
            "--hosts",
            "new-host",
            "--scope",
            "podman",
            "--dry-run",
        ])
        .unwrap();
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "host",
                "gc",
                "--hosts",
                "new-host",
                "--all",
            ])
            .is_err()
        );
    }

    #[test]
    fn parses_prepare_only_instance_policy() {
        Cli::try_parse_from([
            "abird-host-manager",
            "instance",
            "sync",
            "--controller",
            "abird-nest",
            "--source-instance",
            "old",
            "--target-instance",
            "new",
            "--phase",
            "prepare",
            "--transaction",
            "move-1",
            "--copy-mode",
            "relay",
            "--target-storage-pool",
            "fast",
            "--stop-timeout-seconds",
            "120",
            "--force-after-timeout",
            "--runtime-state",
            "preserve",
            "--execute",
        ])
        .unwrap();
        assert!(Cli::try_parse_from(["abird-host-manager", "instance", "migrate"]).is_err());
    }

    #[test]
    fn moves_are_owned_by_typed_entities() {
        for entity in ["service", "resource"] {
            Cli::try_parse_from([
                "abird-host-manager",
                entity,
                "move",
                "zulip",
                "--from",
                "source",
                "--to",
                "target",
                "--dry-run",
            ])
            .unwrap();
        }
        Cli::try_parse_from([
            "abird-host-manager",
            "host",
            "move",
            "--from",
            "source",
            "--to",
            "target",
            "--dry-run",
        ])
        .unwrap();
        Cli::try_parse_from([
            "abird-host-manager",
            "instance",
            "move",
            "zulip",
            "--from-controller",
            "source",
            "--to-controller",
            "target",
            "--dry-run",
        ])
        .unwrap();
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "move",
                "service",
                "zulip",
                "--from",
                "source",
                "--to",
                "target",
            ])
            .is_err()
        );
    }

    #[test]
    fn transaction_phases_are_explicit_commands() {
        for phase in ["prepare", "run", "resume", "close"] {
            Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                phase,
                "migration-1",
                "--dry-run",
            ])
            .unwrap();
        }
        for compatibility_alias in ["cutover", "rollback"] {
            Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                compatibility_alias,
                "migration-1",
                "--dry",
            ])
            .unwrap();
        }
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                "advance",
                "migration-1",
                "seed",
            ])
            .is_err()
        );
    }

    #[test]
    fn backup_creation_is_record_oriented_and_typed() {
        for resource in ["service", "resource"] {
            Cli::try_parse_from([
                "abird-host-manager",
                "backup",
                "create",
                resource,
                "zulip",
                "--from",
                "source",
                "--to",
                "target",
                "--id",
                "backup-1",
                "--dry-run",
            ])
            .unwrap();
        }
        Cli::try_parse_from([
            "abird-host-manager",
            "backup",
            "create",
            "host",
            "source",
            "--to",
            "/srv/backups",
            "--id",
            "backup-1",
            "--dry-run",
        ])
        .unwrap();
        assert!(Cli::try_parse_from(["abird-host-manager", "backup", "service", "zulip"]).is_err());
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "resource",
                "backup",
                "source",
                "service:zulip",
            ])
            .is_err()
        );
        for command in ["rollback", "activate", "delete"] {
            Cli::try_parse_from([
                "abird-host-manager",
                "backup",
                command,
                "backup-1",
                "--dry-run",
            ])
            .unwrap();
        }
        Cli::try_parse_from([
            "abird-host-manager",
            "backup",
            "restore",
            "backup-1",
            "--from",
            "backup-host",
            "--dry-run",
        ])
        .unwrap();
        Cli::try_parse_from([
            "abird-host-manager",
            "backup",
            "prune",
            "--older-than",
            "30d",
            "--keep-last",
            "3",
            "--dry-run",
        ])
        .unwrap();
    }

    #[test]
    fn typed_instance_moves_and_backups_are_executable() {
        let endpoint = InstanceEndpoint {
            controller: "controller-a".to_owned(),
            remote: "local".to_owned(),
            project: "default".to_owned(),
            instance: "zulip".to_owned(),
        };
        let move_spec = TransactionSpec::new(
            Some("move-instance"),
            vec![MoveItem::Instance {
                id: "zulip".to_owned(),
                source: endpoint.clone(),
                target: InstanceEndpoint {
                    controller: "controller-b".to_owned(),
                    ..endpoint.clone()
                },
                policy: InstanceMovePolicy::default(),
            }],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        assert!(move_spec.validate().is_ok());

        let backup_spec = BackupSpec::new(
            Some("backup-instance"),
            vec![BackupItem::Instance {
                id: "zulip".to_owned(),
                source: endpoint,
                policy: InstanceBackupPolicy::default(),
            }],
            vec![BackupDestination::ControllerDirectory {
                path: "/srv/backups".into(),
            }],
            Vec::new(),
        )
        .unwrap();
        assert!(ensure_backup_execution_supported(&backup_spec).is_ok());
    }

    #[test]
    fn mutations_accept_one_explicit_guard() {
        for arguments in [
            vec![
                "abird-host-manager",
                "service",
                "restart",
                "zulip",
                "--execute",
            ],
            vec![
                "abird-host-manager",
                "unit",
                "stop",
                "target",
                "zulip.service",
                "--dry-run",
            ],
            vec![
                "abird-host-manager",
                "resource",
                "start",
                "target",
                "service:zulip",
                "--execute",
            ],
            vec![
                "abird-host-manager",
                "service",
                "wipe",
                "zulip",
                "--host",
                "target",
                "--id",
                "wipe-zulip",
                "--owner",
                "move-zulip",
                "--dry-run",
            ],
            vec![
                "abird-host-manager",
                "resource",
                "wipe",
                "target",
                "service:zulip",
                "--execute",
            ],
        ] {
            Cli::try_parse_from(arguments).unwrap();
        }
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "unit",
                "stop",
                "target",
                "zulip.service",
                "--execute",
                "--dry-run",
            ])
            .is_err()
        );
    }

    #[test]
    fn mutations_execute_by_default_and_dry_is_explicit() {
        let cli = Cli::try_parse_from([
            "abird-host-manager",
            "service",
            "move",
            "zulip",
            "--from",
            "source",
            "--to",
            "target",
        ])
        .unwrap();
        assert_eq!(
            controller_publication_authority(&cli.command),
            PublicationAuthority::Required
        );

        for dry in ["--dry", "--dry-run"] {
            let cli = Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                "run",
                "move-zulip",
                dry,
            ])
            .unwrap();
            assert_eq!(
                controller_publication_authority(&cli.command),
                PublicationAuthority::None
            );
        }
    }

    #[test]
    fn logical_services_use_declared_agent_resources() {
        assert_eq!(
            service_agent_args(
                "status",
                ResolvedServiceTarget::Resource {
                    host: "abird-gondor-corp".to_owned(),
                    resource: "service:zulip".to_owned(),
                },
                true,
            )
            .unwrap(),
            [
                "abird-gondor-corp",
                "--json",
                "resource",
                "status",
                "--resource",
                "service:zulip",
            ]
        );
    }

    #[test]
    fn explicit_units_preserve_scope_and_user() {
        assert_eq!(
            service_agent_args(
                "restart",
                ResolvedServiceTarget::Unit {
                    host: "target".to_owned(),
                    unit: "zulip.service".to_owned(),
                    scope: Scope::User,
                    user: Some("zulip".to_owned()),
                },
                true,
            )
            .unwrap(),
            [
                "target",
                "--json",
                "unit",
                "restart",
                "--unit",
                "zulip.service",
                "--scope",
                "user",
                "--user",
                "zulip",
            ]
        );
    }

    #[test]
    fn hold_inspection_lives_under_its_owner() {
        Cli::try_parse_from(["abird-host-manager", "host", "holds", "target"]).unwrap();
        Cli::try_parse_from([
            "abird-host-manager",
            "resource",
            "hold",
            "show",
            "target",
            "service:zulip",
        ])
        .unwrap();
        assert!(Cli::try_parse_from(["abird-host-manager", "hold", "list", "target"]).is_err());
    }

    #[test]
    fn hold_inspection_runs_the_configured_local_agent_once() {
        let temp = tempfile::tempdir().unwrap();
        let agent = temp.path().join("agent");
        let capture = temp.path().join("arguments");
        fs::write(
            &agent,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > {}\nprintf '%s\\n' '{{\"ok\":true}}'\n",
                capture.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&agent, fs::Permissions::from_mode(0o700)).unwrap();
        let config_path = temp.path().join("manager.json");
        fs::write(
            &config_path,
            format!(
                r#"{{
                  "schema_version": 1,
                  "ssh": {{"program": "/does/not/exist"}},
                  "hosts": {{
                    "target": {{
                      "address": "local",
                      "local": true,
                      "agent_program": "{}"
                    }}
                  }}
                }}"#,
                agent.display()
            ),
        )
        .unwrap();
        let config = HostManagerConfig::load(&config_path).unwrap();

        hold_show(
            &config,
            ResourceArgs {
                host: "target".to_owned(),
                resource: "service:zulip".to_owned(),
            },
        )
        .unwrap();

        assert_eq!(
            fs::read_to_string(capture)
                .unwrap()
                .lines()
                .collect::<Vec<_>>(),
            ["--json", "hold", "status", "--resource", "service:zulip"]
        );
    }

    #[test]
    fn top_level_help_shows_only_noun_first_public_surfaces() {
        let help = Cli::command().render_long_help().to_string();
        for noun in [
            "host",
            "instance",
            "service",
            "unit",
            "resource",
            "backup",
            "transaction",
            "job",
        ] {
            assert!(help.contains(noun), "missing {noun:?} from help:\n{help}");
        }
        assert!(
            !help
                .lines()
                .any(|line| line.trim_start().starts_with("move "))
        );
        assert!(
            !help
                .lines()
                .any(|line| line.trim_start().starts_with("hold "))
        );
    }

    #[test]
    fn json_is_an_explicit_global_output_mode() {
        let before = Cli::try_parse_from([
            "abird-host-manager",
            "--json",
            "transaction",
            "show",
            "move-zulip",
        ])
        .unwrap();
        assert!(before.json);

        let after = Cli::try_parse_from([
            "abird-host-manager",
            "transaction",
            "show",
            "move-zulip",
            "--json",
        ])
        .unwrap();
        assert!(after.json);
    }

    #[test]
    fn transaction_help_exposes_one_recovery_command() {
        let mut command = Cli::command();
        let help = command
            .find_subcommand_mut("transaction")
            .unwrap()
            .render_long_help()
            .to_string();
        assert!(
            help.lines()
                .any(|line| line.trim_start().starts_with("resume "))
        );
        assert!(!help.contains("_reconcile"));
        assert!(
            !help
                .lines()
                .any(|line| { line.trim_start().starts_with("reconcile ") })
        );
    }

    #[test]
    fn job_surface_exposes_records_not_agent_protocol_selectors() {
        Cli::try_parse_from([
            "abird-host-manager",
            "job",
            "show",
            "target",
            "--job-id",
            "job-1",
        ])
        .unwrap();
        Cli::try_parse_from(["abird-host-manager", "job", "list", "target"]).unwrap();
        Cli::try_parse_from([
            "abird-host-manager",
            "job",
            "retry",
            "target",
            "--job-id",
            "job-1",
            "--execute",
        ])
        .unwrap();
        assert!(
            Cli::try_parse_from([
                "abird-host-manager",
                "job",
                "submit",
                "target",
                "--kind",
                "backup",
            ])
            .is_err()
        );

        let mut command = Cli::command();
        let job = command.find_subcommand_mut("job").unwrap();
        let help = job.render_long_help().to_string();
        for legacy in ["--kind", "--profile", "--operation", "submit"] {
            assert!(
                !help.contains(legacy),
                "unexpected {legacy:?} in help:\n{help}"
            );
        }
    }

    #[test]
    fn backup_restore_preserves_only_previously_active_services() {
        let active = parse_active_services(&json!({
            "result": {
                "services": [
                    {
                        "success": true,
                        "target": {"scope": "system", "unit": "postgres.service"}
                    },
                    {
                        "success": false,
                        "target": {
                            "scope": "user",
                            "user": "abird",
                            "unit": "stopped.service"
                        }
                    },
                    {
                        "success": true,
                        "target": {
                            "scope": "user",
                            "user": "abird",
                            "unit": "zulip.service"
                        }
                    }
                ]
            }
        }))
        .unwrap();

        assert_eq!(
            active,
            ["system:postgres.service", "user:abird:zulip.service"]
        );
    }

    #[test]
    fn explicit_config_takes_precedence_over_repository_discovery() {
        let temp = tempfile::tempdir().unwrap();
        let config = temp.path().join("manager.json");
        fs::write(&config, "{}\n").unwrap();

        assert_eq!(
            resolve_config_from(
                Some(Path::new("manager.json")),
                Some(Path::new("/does/not/exist")),
                temp.path(),
            )
            .unwrap(),
            config.canonicalize().unwrap()
        );
    }

    #[test]
    fn config_defaults_to_discovered_repository_inventory() {
        let temp = tempfile::tempdir().unwrap();
        for directory in ["pkgs", "hosts", "data/secrets", "nested/deeper"] {
            fs::create_dir_all(temp.path().join(directory)).unwrap();
        }
        for file in [
            "flake.nix",
            "pkgs/manifest.nix",
            "hosts/default.nix",
            "hosts/nixbot.nix",
            "data/secrets/default.nix",
        ] {
            fs::write(temp.path().join(file), "{}\n").unwrap();
        }

        assert_eq!(
            resolve_config_from(None, None, &temp.path().join("nested/deeper")).unwrap(),
            temp.path().canonicalize().unwrap().join("hosts/nixbot.nix")
        );
    }
}
