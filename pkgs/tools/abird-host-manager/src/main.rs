use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::io::{self, IsTerminal, Read};
use std::os::unix::fs::FileTypeExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use abird_host_agent::instance::{
    IncusCopyMode, InstanceMigrationPhase, InstanceMigrationPolicy, InstanceMigrationRequest,
    RuntimeStateMode, SeedConsistency,
};
use abird_host_agent::job::{projected_hold_job_id, projected_release_job_id};
use abird_host_agent::sha256::digest_bytes;
use abird_host_agent::transfer::{TransferDefinition, transfer_with_excludes_progress};
use abird_host_manager::agent_adapter::{
    HostManagerConfig, NativeAdapter, declared_data_roots, instance_resource,
};
use abird_host_manager::backup_runtime::{
    ArtifactDeletionStatus, BackupArtifact, BackupPhase, BackupRecord, BackupStore,
    InstanceExportLocation, RestorePhase,
};
use abird_host_manager::instance_backup::{self, InstanceBackupContext};
use abird_host_manager::physical::{
    BootMode, HardwareProjection, PartitionSize, PhysicalLayoutRequest,
};
use abird_host_manager::programs::nixos_generate_config::NixosGenerateConfig;
use abird_host_manager::programs::privilege::Privilege;
use abird_host_manager::projection::{
    MoveItemObservation, MovePhase, MoveProjectionObservation, MoveProjector, PhaseProjection,
    ResourceHoldIntent, ResourceHoldPhase, ResourceHoldProjector, canonical_sha256,
};
use abird_host_manager::repository::{
    ManagedHost, ManagedHostSystem, ManagedIncus, ProjectionPublisher, Repository,
    RepositoryPrograms,
};
use abird_host_manager::selector::select_hosts;
use abird_host_manager::service_registry::{resolve_service_host, resolve_service_resource};
use abird_host_manager::workflow::{
    BackupDestination, BackupItem, BackupSpec, HostEndpoint, InstanceBackupPolicy,
    InstanceEndpoint, InstanceMovePolicy, MoveItem, TransactionSpec, wipe_id,
};
use abird_host_manager::workflow_runtime::{
    ActivationAuthorization, InitialMoveContinuation, TransactionRecord, WorkflowRegistration,
    WorkflowStore, execute_workflow_action, execute_workflow_action_until, preflight_new_workflow,
    preflight_workflow_action, supersede_failed_workflow_jobs, validate_failed_workflow_jobs,
};
use abird_host_manager::{Action, Phase as ItemPhase};
use anyhow::{Context, Result, bail};
use clap::{Args, Parser, Subcommand, ValueEnum};
use serde::Serialize;
use serde_json::{Value, json};

#[derive(Debug, Parser)]
#[command(version, about)]
struct Cli {
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
    /// Authorize backup creation and copy.
    #[arg(long, global = true, conflicts_with = "dry_run")]
    execute: bool,
    /// Print the immutable record without persisting it or contacting hosts.
    #[arg(long, global = true, conflicts_with = "execute")]
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
    /// Authorize the requested infrastructure mutation.
    #[arg(long, conflicts_with = "dry_run")]
    execute: bool,

    /// Validate the intended action without writing a journal or mutating hosts.
    #[arg(long, conflicts_with = "execute")]
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
    Seed(TransactionPhaseArgs),
    /// Stop all writers, finish and verify the authoritative copy, and remain held.
    Prepare(ProjectedTransactionPhaseArgs),
    /// Reverify the prepared data while both sides remain held.
    Verify(TransactionPhaseArgs),
    /// Declaratively select and explicitly activate the target writer.
    Cutover(ProjectedTransactionPhaseArgs),
    /// Restore and explicitly activate the source writer.
    Rollback(ProjectedTransactionPhaseArgs),
    /// Reconcile runtime to the already-published desired projection.
    Reconcile(TransactionReconcileArgs),
    /// Resume the exact pending action after an interrupted or failed step.
    Resume(TransactionResumeArgs),
    /// End the rollback window and release the inactive side without starting it.
    Close(TransactionPhaseArgs),
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
struct TransactionReconcileArgs {
    id: String,
    /// Require the repository document consumed by this reconciliation to be
    /// exactly the digest injected into the deployed controller generation.
    #[arg(long)]
    expected_projection_sha256: Option<String>,
    #[command(flatten)]
    guard: ExecutionGuard,
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

const CONTROLLER_EXECUTION_ENV: &str = "ABIRD_HOST_MANAGER_CONTROLLER_EXECUTION";
const CONTROLLER_REPOSITORY: &str = "/var/lib/nixbot/nix";
const CONTROLLER_CONFIG: &str = "/var/lib/nixbot/nix/hosts/nixbot.nix";
const CONTROLLER_STATE_DIR: &str = "/var/lib/nixbot/abird-host-manager";
const CONTROLLER_MANAGER: &str = "/run/current-system/sw/bin/abird-host-manager";

fn main() -> Result<()> {
    let mut cli = Cli::parse();
    select_local_run(&mut cli)?;
    if should_dispatch_to_controller(&cli) {
        return dispatch_to_controller(&cli);
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
        PublicationAuthority::Required => {
            require_local_ssh_agent()?;
            true
        }
        PublicationAuthority::Possible => local_ssh_agent_available()?,
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
    config.run_inventory_command_interactive(&controller, &argv, forward_agent)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PublicationAuthority {
    Required,
    Possible,
    None,
}

fn controller_publication_authority(command: &Command) -> PublicationAuthority {
    match command {
        Command::Instance {
            command: InstanceCommand::Move(args),
        } if args.guard.execution.execute => PublicationAuthority::Required,
        Command::Host {
            command: HostCommand::Move(args),
        } if args.guard.execution.execute => PublicationAuthority::Required,
        Command::Service {
            command: ServiceCommand::Move(args),
        }
        | Command::Resource {
            command: ResourceCommand::Move(args),
        } if args.guard.execution.execute => PublicationAuthority::Required,
        Command::Resource {
            command:
                ResourceCommand::Hold {
                    command: ResourceHoldCommand::Set(args) | ResourceHoldCommand::Clear(args),
                },
        } if args.guard.execute => PublicationAuthority::Required,
        Command::Transaction { command } => match command {
            TransactionCommand::Create(args) if args.guard.execute => {
                PublicationAuthority::Required
            }
            TransactionCommand::Prepare(args)
            | TransactionCommand::Cutover(args)
            | TransactionCommand::Rollback(args)
                if args.guard.execute =>
            {
                PublicationAuthority::Possible
            }
            _ => PublicationAuthority::None,
        },
        _ => PublicationAuthority::None,
    }
}

fn require_local_ssh_agent() -> Result<()> {
    let socket = env::var_os("SSH_AUTH_SOCK")
        .filter(|socket| !socket.is_empty())
        .context("projection publication requires a local SSH_AUTH_SOCK")?;
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
    Ok(())
}

fn local_ssh_agent_available() -> Result<bool> {
    match env::var_os("SSH_AUTH_SOCK").filter(|socket| !socket.is_empty()) {
        Some(_) => require_local_ssh_agent().map(|()| true),
        None => Ok(false),
    }
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
    if !args.guard.execute {
        if !args.guard.dry_run {
            bail!("instance migration is mutating; pass --execute or --dry-run");
        }
        return print_json(&json!({
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
    adapter.run_profile_job(
        &args.controller,
        &format!("{job_id}-reserve"),
        &args.transaction,
        &resource,
        &["--operation".to_owned(), "reserve".to_owned()],
    )?;
    let job = adapter.run_profile_job_result(
        &args.controller,
        &job_id,
        &args.transaction,
        &resource,
        &["--migrate-instance".to_owned(), encoded],
    )?;
    print_json(&json!({
        "ok": true,
        "controller": args.controller,
        "transaction": args.transaction,
        "job_id": job_id,
        "job": job,
    }))
}

fn job_command(config: &HostManagerConfig, command: JobCommand) -> Result<()> {
    let (host, arguments) = match command {
        JobCommand::Show(args) => (
            args.host,
            vec![
                "--json".to_owned(),
                "job".to_owned(),
                "show".to_owned(),
                "--job-id".to_owned(),
                args.job_id,
            ],
        ),
        JobCommand::List { host } => (
            host,
            vec!["--json".to_owned(), "job".to_owned(), "list".to_owned()],
        ),
        JobCommand::Retry(args) => {
            if !args.guard.execute {
                if !args.guard.dry_run {
                    bail!("job retry is mutating; pass --execute or --dry-run");
                }
                return print_json(&json!({
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
            )
        }
    };
    print_json(&config.run_agent(&host, &arguments)?)
}

enum ResourceType {
    Host,
    Service,
    Resource,
}

struct ProjectionExecution {
    repo_root: Option<PathBuf>,
    git_program: PathBuf,
    nix_program: PathBuf,
    branch: String,
    publish_git_ssh_command: Option<String>,
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
        return print_json(&json!({
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
    let publisher = ProjectionPublisher::prepare(
        &source_repository,
        &authority,
        &state_dir,
        &execution.branch,
        execution.git_program,
        execution.nix_program,
        execution.publish_git_ssh_command,
    )?;
    let previous = publisher.repository().load_phase_projection(&args.id)?;
    let projection = ResourceHoldProjector::derive(
        &intent,
        phase,
        previous.as_ref(),
        Some(publisher.revision()?),
    )?;
    let publication = publisher.publish(&projection, config.controller_host()?)?;
    if args.skip_runtime {
        return print_json(&json!({
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
    let job = adapter.run_profile_job_result(
        &args.resource.host,
        &job_id,
        &args.id,
        &args.resource.resource,
        &["--operation".to_owned(), operation.to_owned()],
    )?;
    print_json(&json!({
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
    let mut spec = TransactionSpec::new(caller_id, items, Vec::new(), Vec::new())?;
    spec.declarative_scope = declarative_scope;
    spec.validate()?;
    let mut candidate = TransactionRecord::new(spec, config)?;

    if guard.execution.dry_run {
        if let Some(mut record) = WorkflowStore::load_matching(&state_dir, &candidate)? {
            return dry_run_existing_move(&mut record, guard.force_existing, guard.skip_runtime);
        }
        if guard.skip_runtime {
            return print_json(&json!({
                "dry_run": true,
                "runtime": "skipped",
                "transaction": candidate,
                "authorized_phases": ["setup", "seed"],
                "stops_before": "prepare",
            }));
        }
        let mut adapter = NativeAdapter::load(&candidate.config)?;
        let preflight = preflight_new_workflow(&mut candidate, &mut adapter)?;
        return print_json(&json!({
            "dry_run": true,
            "preflight": preflight,
            "transaction": candidate,
            "authorized_phases": ["setup", "seed"],
            "stops_before": "prepare",
        }));
    }

    let store = WorkflowStore::open(state_dir.clone())?;
    let mut record = match store.register(candidate)? {
        WorkflowRegistration::Created(record) => record,
        WorkflowRegistration::Existing(mut record) => {
            if record.projection.is_none()
                && record.phase == abird_host_manager::workflow_runtime::WorkflowPhase::Planned
            {
                publish_seeded_projection(&store, &mut record, &state_dir, projection_execution)?;
            }
            return execute_existing_move(&store, record, guard.force_existing, guard.skip_runtime);
        }
    };

    let publication =
        publish_seeded_projection(&store, &mut record, &state_dir, projection_execution)?;

    if guard.skip_runtime {
        return print_json(&json!({
            "repository": publication,
            "runtime": "skipped",
            "transaction": record,
        }));
    }

    eprintln!(
        "transaction {} persisted; beginning setup and seed",
        record.id()
    );
    let mut adapter = NativeAdapter::load(&record.config)?;
    adapter.bind_projection(
        record
            .projection
            .clone()
            .context("new move has no published phase projection")?,
    )?;
    execute_workflow_action(&store, &mut record, Action::Setup, &mut adapter)?;
    execute_workflow_action(&store, &mut record, Action::Seed, &mut adapter)?;
    print_json(&json!({
        "repository": publication,
        "runtime": "reconciled",
        "transaction": record,
    }))
}

fn publish_seeded_projection(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    state_dir: &Path,
    execution: ProjectionExecution,
) -> Result<abird_host_manager::repository::ProjectionPublication> {
    let source_repository = Repository::discover(execution.repo_root)?;
    let publisher = ProjectionPublisher::prepare(
        &source_repository,
        store,
        state_dir,
        &execution.branch,
        execution.git_program,
        execution.nix_program,
        execution.publish_git_ssh_command,
    )?;
    let manager_config = HostManagerConfig::load(&record.config)?;
    let existing = publisher.repository().load_phase_projection(record.id())?;
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
    let publication = publisher.publish(&projection, manager_config.controller_host()?)?;
    record.set_projection(projection)?;
    store.save(record)?;
    Ok(publication)
}

fn dry_run_existing_move(
    record: &mut TransactionRecord,
    force_existing: bool,
    skip_runtime: bool,
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
        let mut adapter = load_workflow_adapter(record)?;
        preflight_workflow_action(record, action, &mut adapter)?;
    }
    print_json(&json!({
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
    eprintln!("{}", continuation_message);
    record.record_reinvocation(continuation_message)?;
    store.save(&record)?;

    if skip_runtime {
        return print_json(&json!({
            "runtime": "skipped",
            "transaction": record,
        }));
    }

    match continuation {
        InitialMoveContinuation::Resume(Action::Setup) => {
            let mut adapter = load_workflow_adapter(&record)?;
            execute_workflow_action(store, &mut record, Action::Setup, &mut adapter)?;
            execute_workflow_action(store, &mut record, Action::Seed, &mut adapter)?;
        }
        InitialMoveContinuation::Resume(action)
        | InitialMoveContinuation::RequiresForce(Some(action)) => {
            let mut adapter = load_workflow_adapter(&record)?;
            execute_workflow_action(store, &mut record, action, &mut adapter)?;
        }
        InitialMoveContinuation::Complete | InitialMoveContinuation::RequiresForce(None) => {}
    }
    print_json(&record)
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
                let mut adapter = NativeAdapter::load(&record.config)?;
                let preflight = preflight_new_workflow(&mut record, &mut adapter)?;
                return print_json(&json!({
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
                publish_seeded_projection(&store, &mut record, &state_dir, projection)?;
            eprintln!(
                "transaction {} persisted; beginning setup and seed",
                record.id()
            );
            let mut adapter = load_workflow_adapter(&record)?;
            execute_workflow_action(&store, &mut record, Action::Setup, &mut adapter)?;
            execute_workflow_action(&store, &mut record, Action::Seed, &mut adapter)?;
            print_json(&json!({
                "repository": publication,
                "runtime": "reconciled",
                "transaction": record,
            }))
        }
        TransactionCommand::Show { id } => print_json(&WorkflowStore::open(state_dir)?.load(&id)?),
        TransactionCommand::List => print_json(&WorkflowStore::open(state_dir)?.list()?),
        TransactionCommand::Seed(args) => {
            transaction_phase(&WorkflowStore::open(state_dir)?, args, Action::Seed)
        }
        TransactionCommand::Prepare(args) => projected_transaction_phase(
            &WorkflowStore::open(state_dir.clone())?,
            args,
            Action::Prepare,
            MovePhase::Prepared,
            &state_dir,
            projection,
        ),
        TransactionCommand::Verify(args) => {
            transaction_phase(&WorkflowStore::open(state_dir)?, args, Action::Verify)
        }
        TransactionCommand::Cutover(args) => projected_transaction_phase(
            &WorkflowStore::open(state_dir.clone())?,
            args,
            Action::Cutover,
            MovePhase::Cutover,
            &state_dir,
            projection,
        ),
        TransactionCommand::Rollback(args) => projected_transaction_phase(
            &WorkflowStore::open(state_dir.clone())?,
            args,
            Action::Rollback,
            MovePhase::RolledBack,
            &state_dir,
            projection,
        ),
        TransactionCommand::Reconcile(args) => reconcile_projected_transaction(
            &WorkflowStore::open(state_dir.clone())?,
            args,
            &state_dir,
            projection,
        ),
        TransactionCommand::Close(args) => {
            transaction_phase(&WorkflowStore::open(state_dir)?, args, Action::Close)
        }
        TransactionCommand::Resume(args) => {
            let store = WorkflowStore::open(state_dir)?;
            let mut record = store.load(&args.id)?;
            let action = record
                .pending_action
                .context("transaction has no pending action to resume")?;
            ensure_legacy_projection_boundary(
                record.id(),
                record.projection.is_some(),
                action,
                true,
            )?;
            if should_dry_run(action, &args.guard)? {
                let mut adapter = load_workflow_adapter(&record)?;
                preflight_workflow_action(&mut record, action, &mut adapter)?;
                let supersede_candidates = if args.supersede_failed_job {
                    validate_failed_workflow_jobs(&store, &mut record, &mut adapter)?
                } else {
                    Vec::new()
                };
                return print_json(&json!({
                    "dry_run": true,
                    "validated_phase": action,
                    "transaction": record,
                    "action": action,
                    "supersede_failed_job": args.supersede_failed_job,
                    "supersede_candidates": supersede_candidates,
                }));
            }
            let mut adapter = load_workflow_adapter(&record)?;
            if args.supersede_failed_job {
                preflight_workflow_action(&mut record, action, &mut adapter)?;
                let superseded = supersede_failed_workflow_jobs(&store, &mut record, &mut adapter)?;
                for (old_job_id, new_job_id) in superseded {
                    eprintln!(
                        "transaction {} superseded terminal failed job {} with {}",
                        record.id(),
                        old_job_id,
                        new_job_id
                    );
                }
            }
            execute_workflow_action(&store, &mut record, action, &mut adapter)?;
            print_json(&record)
        }
    }
}

fn transaction_phase(
    store: &WorkflowStore,
    args: TransactionPhaseArgs,
    action: Action,
) -> Result<()> {
    let mut record = store.load(&args.id)?;
    ensure_legacy_projection_boundary(record.id(), record.projection.is_some(), action, false)?;
    if should_dry_run(action, &args.guard)? {
        let mut adapter = load_workflow_adapter(&record)?;
        preflight_workflow_action(&mut record, action, &mut adapter)?;
        return print_json(&json!({
            "dry_run": true,
            "validated_phase": action,
            "transaction": record,
            "action": action,
        }));
    }
    let mut adapter = load_workflow_adapter(&record)?;
    execute_workflow_action(store, &mut record, action, &mut adapter)?;
    print_json(&record)
}

fn ensure_legacy_projection_boundary(
    transaction_id: &str,
    has_projection: bool,
    action: Action,
    resume: bool,
) -> Result<()> {
    if !has_projection {
        return Ok(());
    }
    if resume {
        bail!(
            "projected transaction {transaction_id:?} cannot use transaction resume because activation authorization must run through projected reconciliation; run `abird-host-manager transaction reconcile {transaction_id} --execute`"
        );
    }
    if action == Action::Close {
        bail!(
            "projected transaction {transaction_id:?} cannot be closed until canonical projection closeout is implemented; its inactive endpoint must remain held"
        );
    }
    Ok(())
}

fn load_workflow_adapter(record: &TransactionRecord) -> Result<NativeAdapter> {
    let mut adapter = NativeAdapter::load(&record.config)?;
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
    let mut record = store.load(&args.id)?;
    let dry_run = should_dry_run(action, &args.guard)?;
    let source_repository = Repository::discover(execution.repo_root)?;
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
            );
        }
    }
    let publisher = ProjectionPublisher::prepare(
        &source_repository,
        store,
        state_dir,
        &execution.branch,
        execution.git_program,
        execution.nix_program,
        execution.publish_git_ssh_command,
    )?;
    let repository_projection = publisher.repository().load_phase_projection(record.id())?;
    if record.projection.is_none() {
        if let Some(published) = &repository_projection {
            validate_projection_adoption(None, published, &record.spec)?;
            record.set_projection(published.clone())?;
            if !dry_run {
                store.save(&record)?;
            }
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
        let mut adoption_adapter = NativeAdapter::load(&record.config)?;
        adoption_adapter.bind_projection(previous.clone())?;
        adopt_repository_activation(
            store,
            &mut record,
            MovePhase::Cutover,
            &previous,
            &adoption_adapter,
        )?;
    }
    let manager_config = HostManagerConfig::load(&record.config)?;
    let observation = move_projection_observation(&record);
    let projection = MoveProjector::derive_with_observation(
        &record.spec,
        &manager_config,
        desired_phase,
        Some(&previous),
        Some(publisher.revision()?),
        &observation,
    )?;
    let runtime_actions = reconciliation_actions(&record, desired_phase)?;

    if dry_run {
        if !args.skip_runtime
            && let Some(first_action) = runtime_actions.first().copied()
        {
            let mut adapter = NativeAdapter::load(&record.config)?;
            adapter.bind_projection(projection.clone())?;
            preflight_workflow_action(&mut record, first_action, &mut adapter)?;
        }
        return print_json(&json!({
            "dry_run": true,
            "action": action,
            "projection": projection,
            "repository_path": format!("data/phase-projections/{}.json", record.id()),
            "runtime_actions": runtime_actions,
            "runtime": if args.skip_runtime { "skipped" } else { "planned" },
            "transaction": record,
        }));
    }

    let repository_publication =
        publisher.publish(&projection, manager_config.controller_host()?)?;
    record.set_projection(projection.clone())?;
    store.save(&record)?;
    if args.skip_runtime {
        return print_json(&json!({
            "projection": projection,
            "repository": repository_publication,
            "runtime": "skipped",
            "transaction": record,
        }));
    }
    let mut adapter = NativeAdapter::load(&record.config)?;
    adapter.bind_projection(projection.clone())?;
    reconcile_projected_runtime(
        store,
        &mut record,
        desired_phase,
        runtime_actions,
        &mut adapter,
    )?;
    print_json(&json!({
        "projection": record.projection,
        "repository": repository_publication,
        "runtime": "reconciled",
        "transaction": record,
    }))
}

fn reconcile_projected_transaction(
    store: &WorkflowStore,
    args: TransactionReconcileArgs,
    state_dir: &Path,
    execution: ProjectionExecution,
) -> Result<()> {
    require_guard(&args.guard, "transaction reconcile")?;
    let mut record = store.load(&args.id)?;
    let desired_phase = record
        .projection
        .as_ref()
        .map(|projection| projection.move_phase())
        .transpose()?
        .context("transaction has no repository-backed desired projection")?;
    let actions = reconciliation_actions(&record, desired_phase)?;
    if args.guard.dry_run {
        return print_json(&json!({
            "dry_run": true,
            "desired_phase": desired_phase,
            "actions": actions,
            "projection": record.projection,
            "runtime": "planned",
            "transaction": record,
        }));
    }
    let source_repository = Repository::discover(execution.repo_root)?;
    let publisher = ProjectionPublisher::prepare(
        &source_repository,
        store,
        state_dir,
        &execution.branch,
        execution.git_program,
        execution.nix_program,
        execution.publish_git_ssh_command,
    )?;
    let published = publisher
        .repository()
        .load_phase_projection(record.id())?
        .context("repository-backed transaction projection disappeared during refresh")?;
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
    let mut adapter = NativeAdapter::load(&record.config)?;
    adapter.bind_projection(
        record
            .projection
            .clone()
            .context("transaction has no phase projection")?,
    )?;
    reconcile_projected_runtime(store, &mut record, desired_phase, actions, &mut adapter)?;
    print_json(&json!({
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
            if target >= 3 {
                actions.push(Action::Cutover);
            }
        }
        WorkflowPhase::Cutover if target == 3 => {}
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
            print_json(&summaries)
        }
        HostCommand::Show { host } => print_json(config.host(&host)?),
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
    if !args.guard.execute {
        if !args.guard.dry_run {
            bail!("host generation mutates the repository; pass --execute or --dry-run");
        }
        return print_json(&json!({
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
    let change = if let Some(request) = physical_request {
        let hardware_source = if let Some(path) = args.hardware_config {
            fs::read_to_string(&path)
                .with_context(|| format!("read hardware config {}", path.display()))?
        } else {
            NixosGenerateConfig::new(nixos_generate_config_program.to_path_buf())?
                .show_hardware_config(&Privilege::new(&programs.privilege)?, repository.root())?
        };
        let hardware = HardwareProjection::from_nixos_hardware_config(&hardware_source)?;
        repository.generate_physical(
            &args.host,
            record,
            request,
            &hardware,
            args.fresh_storage_ids,
            args.force,
        )?
    } else {
        repository.generate(
            &args.host,
            record,
            args.system_module.as_deref(),
            args.force,
        )?
    };
    print_json(&change)
}

fn repository_build(
    repo_root: Option<PathBuf>,
    programs: &RepositoryPrograms,
    args: HostBuildArgs,
) -> Result<()> {
    let repository = Repository::discover(repo_root)?;
    if !args.guard.execute {
        if !args.guard.dry_run {
            bail!("host build writes the Nix store; pass --execute or --dry-run");
        }
        return print_json(&json!({
            "dry_run": true,
            "operation": "host_build",
            "repository": repository.root(),
            "host": args.host,
            "offline_cache": args.offline_cache,
        }));
    }
    print_json(&repository.build_artifacts(programs, &args.host, args.offline_cache.as_deref())?)
}

fn repository_install(
    repo_root: Option<PathBuf>,
    programs: &RepositoryPrograms,
    args: HostInstallArgs,
) -> Result<()> {
    let repository = Repository::discover(repo_root)?;
    if !args.guard.execute {
        if !args.guard.dry_run {
            bail!("live install is destructive; pass --execute or --dry-run");
        }
        return print_json(&json!({
            "dry_run": true,
            "operation": "host_live_install",
            "repository": repository.root(),
            "host": args.host,
            "root": args.root,
            "offline_cache": args.offline_cache,
            "wipe_disks": args.wipe_disks,
        }));
    }
    let prepared = repository.prepare_live_install(
        programs,
        &args.host,
        &args.root,
        args.offline_cache.as_deref(),
    )?;
    repository.execute_prepared_install(programs, &prepared, args.wipe_disks)?;
    print_json(&prepared)
}

fn repository_delete(repo_root: Option<PathBuf>, args: HostDeleteArgs) -> Result<()> {
    let repository = Repository::discover(repo_root)?;
    if !args.guard.execute {
        if !args.guard.dry_run {
            bail!("host deletion mutates the repository; pass --execute or --dry-run");
        }
        return print_json(&json!({
            "dry_run": true,
            "operation": "host_delete",
            "repository": repository.root(),
            "host": args.host,
        }));
    }
    print_json(&repository.delete(&args.host)?)
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
    if !args.guard.execute {
        if !args.guard.dry_run {
            bail!("host {operation} is mutating; pass --execute or --dry-run");
        }
        return print_json(&json!({
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
    }
    print_json(&json!({
        "ok": failures == 0,
        "operation": operation,
        "jobs": args.jobs,
        "failures": failures,
        "results": results,
    }))?;
    if failures != 0 {
        bail!("{operation} failed on {failures} host(s)");
    }
    Ok(())
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
            let adapter = NativeAdapter::from_config(config.clone());
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
    if let Some(guard) = guard
        && direct_mutation_guard("service", operation, &target, &guard)?
    {
        return Ok(());
    }
    let agent_args = service_agent_args(operation, target, true)?;
    print_json(&config.run_agent(&agent_args[0], &agent_args[1..])?)
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
    if let Some(guard) = guard
        && direct_mutation_guard("unit", operation, &target, &guard)?
    {
        return Ok(());
    }
    let agent_args = service_agent_args(operation, target, true)?;
    print_json(&config.run_agent(&agent_args[0], &agent_args[1..])?)
}

fn direct_mutation_guard(
    kind: &str,
    operation: &str,
    target: &ResolvedServiceTarget,
    guard: &ExecutionGuard,
) -> Result<bool> {
    if guard.execute {
        return Ok(false);
    }
    if !guard.dry_run {
        bail!("{kind} {operation} is mutating; pass --execute or --dry-run");
    }
    print_json(&json!({
        "dry_run": true,
        "kind": kind,
        "operation": operation,
        "target": format!("{target:?}"),
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
    if let Some(guard) = guard
        && !guard.execute
    {
        if !guard.dry_run {
            bail!("resource {operation} is mutating; pass --execute or --dry-run");
        }
        return print_json(&json!({
            "dry_run": true,
            "kind": "resource",
            "operation": operation,
            "host": args.host,
            "resource": args.resource,
        }));
    }
    print_json(&config.run_agent(
        &args.host,
        &[
            "--json".to_owned(),
            "resource".to_owned(),
            operation.to_owned(),
            "--resource".to_owned(),
            args.resource,
        ],
    )?)
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
    if !guard.execute {
        if !guard.dry_run {
            bail!("service data wipe is mutating; pass --execute or --dry-run");
        }
        return print_json(&json!({
            "dry_run": true,
            "operation": "wipe-and-remain-held",
            "host": host,
            "resource": resource,
            "wipe_id": wipe,
            "hold_owner": owner,
            "data_roots": "resolved by the target host agent from its immutable declaration",
        }));
    }

    eprintln!("wipe {wipe} selected; acquiring durable hold owned by {owner}");
    adapter.run_profile_job(
        host,
        &format!("{wipe}-hold"),
        &owner,
        resource,
        &["--operation".to_owned(), "hold".to_owned()],
    )?;
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
    )?;
    let job_id = format!("{wipe}-wipe");
    let job = adapter.run_profile_job_result(
        host,
        &job_id,
        &owner,
        resource,
        &["--operation".to_owned(), "wipe-data".to_owned()],
    )?;
    print_json(&json!({
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
    if !args.guard.execute {
        if !args.guard.dry_run {
            bail!("resource {operation} is mutating; pass --execute or --dry-run");
        }
        return print_json(&json!({
            "dry_run": true,
            "host": args.resource.host,
            "resource": args.resource.resource,
            "transaction": args.transaction,
            "operation": operation,
        }));
    }
    let adapter = NativeAdapter::from_config(config.clone());
    let digest = digest_bytes(
        format!(
            "{}\0{}\0{}\0{}",
            args.resource.host, args.resource.resource, args.transaction, operation
        )
        .as_bytes(),
    );
    adapter.run_profile_job(
        &args.resource.host,
        &format!("resource-{operation}-{}", &digest[..24]),
        &args.transaction,
        &args.resource.resource,
        &["--operation".to_owned(), operation.to_owned()],
    )?;
    print_json(&json!({
        "ok": true,
        "host": args.resource.host,
        "resource": args.resource.resource,
        "transaction": args.transaction,
        "operation": operation,
    }))
}

fn hold_list(config: &HostManagerConfig, host: String) -> Result<()> {
    print_json(&config.run_agent(
        &host,
        &["--json".to_owned(), "hold".to_owned(), "list".to_owned()],
    )?)
}

fn hold_show(config: &HostManagerConfig, resource: ResourceArgs) -> Result<()> {
    print_json(&config.run_agent(
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
        BackupCommand::Show { id } => print_json(&BackupStore::open(state_dir)?.load(&id)?),
        BackupCommand::List => print_json(&BackupStore::open(state_dir)?.list()?),
        BackupCommand::Verify { id } => {
            let record = BackupStore::open(state_dir)?.load(&id)?;
            record.verify_evidence()?;
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            for index in 0..record.copies.len() {
                validate_backup_artifact(&adapter, &record, index, true)?;
            }
            print_json(&json!({
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
                return print_json(&json!({
                    "dry_run": true,
                    "backup": record,
                }));
            }
            ensure_backup_execution_supported(&record.spec)?;
            let store = BackupStore::open(state_dir)?;
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            store.create(&record)?;
            eprintln!("backup {} persisted; beginning copy", record.id());
            execute_backup_record(&store, &mut record, &adapter)?;
            print_json(&record)
        }
        BackupCommand::Resume(args) => {
            require_guard(&args.guard, "backup resume")?;
            let store = BackupStore::open(state_dir)?;
            let mut record = store.load(&args.id)?;
            if args.guard.dry_run {
                return print_json(&json!({
                    "dry_run": true,
                    "backup": record,
                    "pending_copies": record.copies.iter().filter(|copy| copy.status != abird_host_manager::backup_runtime::BackupCopyStatus::Complete).count(),
                }));
            }
            ensure_backup_execution_supported(&record.spec)?;
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            match record.restore.as_ref().map(|restore| restore.phase) {
                Some(RestorePhase::Holding | RestorePhase::Restoring) => {
                    execute_backup_restore(&store, &mut record, &adapter)?;
                }
                Some(RestorePhase::RollingBack) => {
                    execute_backup_restore_rollback(&store, &mut record, &adapter)?;
                }
                Some(RestorePhase::RestoredHeld) => {
                    bail!("restore is complete and held; use backup activate or backup rollback")
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
                    delete_backup_artifacts(&store, &mut record, &adapter)?
                }
                _ => execute_backup_record(&store, &mut record, &adapter)?,
            }
            print_json(&record)
        }
        BackupCommand::Abort(args) => {
            require_guard(&args.guard, "backup abort")?;
            let store = BackupStore::open(state_dir)?;
            let mut record = store.load(&args.id)?;
            if args.guard.dry_run {
                return print_json(&json!({
                    "dry_run": true,
                    "backup": record,
                    "operation": "restore-held-sources-and-abort",
                }));
            }
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            restore_backup_holds(&store, &mut record, &adapter)?;
            record.abort()?;
            store.save(&record)?;
            print_json(&record)
        }
        BackupCommand::Restore(args) => {
            require_guard(&args.guard, "backup restore")?;
            let store = BackupStore::open(state_dir)?;
            let mut record = store.load(&args.id)?;
            let destination = parse_backup_destination(&args.source);
            record.begin_restore(destination)?;
            store.ensure_authority_available(&record)?;
            if args.guard.dry_run {
                return print_json(&json!({
                    "dry_run": true,
                    "backup": record,
                    "operation": "restore-and-remain-held",
                }));
            }
            ensure_backup_execution_supported(&record.spec)?;
            store.save(&record)?;
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            execute_backup_restore(&store, &mut record, &adapter)?;
            print_json(&record)
        }
        BackupCommand::Rollback(args) => {
            require_guard(&args.guard, "backup rollback")?;
            let store = BackupStore::open(state_dir)?;
            let mut record = store.load(&args.id)?;
            record.ensure_restore_rollbackable()?;
            if args.guard.dry_run {
                return print_json(&json!({
                    "dry_run": true,
                    "backup": record,
                    "operation": "restore-pre-restore-safety-snapshots-and-remain-held",
                }));
            }
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            execute_backup_restore_rollback(&store, &mut record, &adapter)?;
            print_json(&record)
        }
        BackupCommand::Activate(args) => {
            require_guard(&args.guard, "backup activate")?;
            let store = BackupStore::open(state_dir)?;
            let mut record = store.load(&args.id)?;
            record.ensure_restore_activatable()?;
            if args.guard.dry_run {
                return print_json(&json!({
                    "dry_run": true,
                    "backup": record,
                    "operation": "release-restore-holds-and-restore-prior-writers",
                }));
            }
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            activate_backup_restore(&store, &mut record, &adapter)?;
            print_json(&record)
        }
        BackupCommand::Delete(args) => {
            require_guard(&args.guard, "backup delete")?;
            let store = BackupStore::open(state_dir)?;
            let mut record = store.load(&args.id)?;
            record.ensure_artifacts_deletable()?;
            if args.guard.dry_run {
                return print_json(&json!({
                    "dry_run": true,
                    "backup": record,
                    "operation": "delete-artifacts-and-retain-tombstone",
                }));
            }
            let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
            let adapter = NativeAdapter::load(&config)?;
            delete_backup_artifacts(&store, &mut record, &adapter)?;
            print_json(&record)
        }
        BackupCommand::Prune(args) => {
            require_guard(&args.guard, "backup prune")?;
            prune_backups(state_dir, config, repo_root, args)
        }
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
    let store = BackupStore::open(state_dir)?;
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
        return print_json(&json!({
            "dry_run": true,
            "older_than_ms": age_ms,
            "keep_last_per_equivalent_set": args.keep_last,
            "delete": selected,
        }));
    }
    if selected.is_empty() {
        return print_json(&json!({
            "ok": true,
            "deleted": [],
        }));
    }
    let config = resolve_config(config.as_deref(), repo_root.as_deref())?;
    let adapter = NativeAdapter::load(&config)?;
    for id in &selected {
        let mut record = store.load(id)?;
        delete_backup_artifacts(&store, &mut record, &adapter)?;
    }
    print_json(&json!({
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
                transfer_with_excludes_progress(&definition, &root.excludes, |progress| {
                    if io::stderr().is_terminal() {
                        eprintln!(
                            "[controller backup {}] {}",
                            root.name,
                            serde_json::to_string(progress)?
                        );
                    }
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
    if action.is_mutating() && !guard.execute {
        if !guard.dry_run {
            bail!(
                "{} is mutating; pass --execute or --dry-run",
                action.as_str()
            );
        }
        return Ok(true);
    }
    Ok(guard.dry_run)
}

fn require_guard(guard: &ExecutionGuard, operation: &str) -> Result<()> {
    if !guard.execute && !guard.dry_run {
        bail!("{operation} is mutating; pass --execute or --dry-run");
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

fn print_json(value: &impl Serialize) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
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
                "reconcile",
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

        let repo_root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .nth(3)
            .unwrap();
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
            vec![
                "abird-host-manager",
                "transaction",
                "prepare",
                "move-zulip",
                "--execute",
            ],
        ] {
            let cli = Cli::try_parse_from(argv).unwrap();
            assert_ne!(
                controller_publication_authority(&cli.command),
                PublicationAuthority::None
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
                "reconcile",
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
        let cli = Cli::try_parse_from([
            "abird-host-manager",
            "transaction",
            "prepare",
            "move-zulip",
            "--execute",
        ])
        .unwrap();
        assert_eq!(
            controller_publication_authority(&cli.command),
            PublicationAuthority::Possible
        );
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
            "reconcile",
            "move-zulip",
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
        record.pending_action = Some(Action::Rollback);
        assert_eq!(
            reconciliation_actions(&record, MovePhase::RolledBack).unwrap(),
            vec![Action::Rollback]
        );
    }

    #[test]
    fn projected_resume_and_close_fail_closed_at_the_legacy_boundary() {
        assert!(
            ensure_legacy_projection_boundary("move-zulip", false, Action::Close, false).is_ok()
        );
        let close = ensure_legacy_projection_boundary("move-zulip", true, Action::Close, false)
            .unwrap_err()
            .to_string();
        assert!(close.contains("inactive endpoint must remain held"));

        let resume = ensure_legacy_projection_boundary("move-zulip", true, Action::Rollback, true)
            .unwrap_err()
            .to_string();
        assert!(resume.contains("transaction reconcile move-zulip --execute"));
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
        execute_existing_move(&store, record, false, false).unwrap();
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
            execute_existing_move(&store, prepared.clone(), false, false)
                .unwrap_err()
                .to_string()
                .contains("--force-existing")
        );
        execute_existing_move(&store, prepared, true, false).unwrap();
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
        for phase in [
            "seed", "prepare", "verify", "cutover", "rollback", "resume", "close",
        ] {
            Cli::try_parse_from([
                "abird-host-manager",
                "transaction",
                phase,
                "migration-1",
                "--dry-run",
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
