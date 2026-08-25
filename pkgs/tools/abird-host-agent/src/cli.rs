use std::env;
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command as ProcessCommand;

use anyhow::{Context, Result, bail};
use clap::{Args, Parser, Subcommand};
use serde_json::{Value, json};

use crate::broker::{BrokerTransferRequest, run_broker_transfer_with_progress};
use crate::deployment::{DeploymentDefinition, activate};
use crate::desired_state::{
    DesiredResourceState, DesiredResourceStateKind, DesiredResourceStateManifest,
    DesiredResourceStateReceiptStore,
};
use crate::file_state::{FileStateDefinition, apply_file_state_with_reload};
use crate::instance::{
    InstanceControlAction, InstanceDefinition, InstanceMigrationRequest, control_instance,
    ensure_instance, migrate_instance,
};
use crate::instance_backup::{InstanceBackupAction, run_instance_backup, validate_instance_backup};
use crate::job::{
    JobExecution, JobOperation, JobProjectionBinding, JobSpec, JobStatus, JobStore,
    projected_hold_job_id, projected_release_job_id,
};
use crate::journal::{JournalOutput, JournalStreamResult, Journalctl};
use crate::maintenance::{CleanKind, clean};
use crate::manifest::{create_manifest, create_manifest_roots};
use crate::programs::nix::NixCollectGarbage;
use crate::programs::nixbot;
use crate::programs::systemd::Systemd;
use crate::readiness::{ReadinessCheck, run_checks, wait_for_checks};
use crate::resource::{
    BackupConsistency, DataRoot, DataRootPlan, ExpectedState, ResourceManifest,
    validate_data_root_plan,
};
use crate::service::{ServiceOperation, ServiceResult, ServiceScope, ServiceTarget, Systemctl};
use crate::sha256::digest_bytes;
use crate::state::{ActivationReleaseEvidence, HoldRecord, StateStore};
use crate::transfer::{
    PostCopyVerification, RemoteSource, TransferDefinition, clear_directory_contents_except,
    transfer_with_excludes_progress, transfer_with_excludes_progress_policy,
    transfer_with_progress, verify_transfer, verify_transfer_with_excludes,
};
use crate::wipe::wipe_data_roots;

const DEFAULT_STATE_DIR: &str = "/var/lib/abird-host-agent";
const DEFAULT_RESOURCE_MANIFEST: &str = "/etc/abird-host-agent/resources.json";
const DEFAULT_DESIRED_RESOURCE_STATE_MANIFEST: &str =
    "/etc/abird-host-agent/desired-resource-states.json";
const DEFAULT_PODMAN: &str = "/run/current-system/sw/bin/podman";
const DEFAULT_NIX_COLLECT_GARBAGE: &str = "/run/current-system/sw/bin/nix-collect-garbage";
const DEFAULT_SSH_HOST_ED25519_PUBLIC_KEY: &str = "/etc/ssh/ssh_host_ed25519_key.pub";
const JOB_SPEC_LIMIT: u64 = 4 * 1024 * 1024;
#[derive(Debug)]
struct ResolvedJobInputs {
    services: Vec<ServiceTarget>,
    data_paths: Vec<PathBuf>,
    argv: Option<Vec<String>>,
    readiness: Vec<ReadinessCheck>,
    transfer: Option<TransferDefinition>,
    resource_transfers: Vec<TransferDefinition>,
    backup_consistency: Option<BackupConsistency>,
    file_state: Option<FileStateDefinition>,
    instance: Option<InstanceDefinition>,
    instance_migration: Option<InstanceMigrationRequest>,
    deployment: Option<DeploymentDefinition>,
}

#[derive(Debug, Parser)]
#[command(
    name = "abird-host-agent",
    version,
    about = "Local Abird host resource and durable job agent"
)]
pub struct Cli {
    /// Durable state directory for persistent holds.
    #[arg(
        long,
        env = "ABIRD_HOST_AGENT_STATE_DIR",
        default_value = DEFAULT_STATE_DIR,
        global = true
    )]
    pub state_dir: PathBuf,

    /// Nix-generated declaration of resource service targets and data paths.
    #[arg(
        long,
        env = "ABIRD_HOST_AGENT_RESOURCE_MANIFEST",
        default_value = DEFAULT_RESOURCE_MANIFEST,
        global = true
    )]
    pub resource_manifest: PathBuf,

    /// Public Ed25519 host key advertised to authenticated transfer controllers.
    #[arg(
        long,
        env = "ABIRD_HOST_AGENT_SSH_HOST_ED25519_PUBLIC_KEY",
        default_value = DEFAULT_SSH_HOST_ED25519_PUBLIC_KEY,
        global = true,
        hide = true
    )]
    pub ssh_host_ed25519_public_key: PathBuf,

    /// systemctl-compatible executable, primarily overridable for tests.
    #[arg(
        long,
        env = "ABIRD_HOST_AGENT_SYSTEMCTL",
        default_value = "systemctl",
        global = true,
        hide = true
    )]
    pub systemctl: PathBuf,

    /// journalctl-compatible executable, primarily overridable for tests.
    #[arg(
        long,
        env = "ABIRD_HOST_AGENT_JOURNALCTL",
        default_value = "journalctl",
        global = true,
        hide = true
    )]
    pub journalctl: PathBuf,

    /// runuser-compatible executable used to enter a named user journal context.
    #[arg(
        long,
        env = "ABIRD_HOST_AGENT_RUNUSER",
        default_value = "runuser",
        global = true,
        hide = true
    )]
    pub runuser: PathBuf,

    /// podman-compatible executable used by native maintenance cleanup.
    #[arg(
        long,
        env = "ABIRD_HOST_AGENT_PODMAN",
        default_value = DEFAULT_PODMAN,
        global = true,
        hide = true
    )]
    pub podman: PathBuf,

    /// nix-collect-garbage-compatible executable used by native maintenance.
    #[arg(
        long,
        env = "ABIRD_HOST_AGENT_NIX_COLLECT_GARBAGE",
        default_value = DEFAULT_NIX_COLLECT_GARBAGE,
        global = true,
        hide = true
    )]
    pub nix_collect_garbage: PathBuf,

    /// Emit a single structured JSON object.
    #[arg(long, global = true)]
    pub json: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Summarize this agent's declaration and durable local state.
    Status,
    /// Read the host, one resource, or one explicit systemd unit journal.
    Logs(LogArgs),
    /// Manage persistent resource holds.
    Hold {
        #[command(subcommand)]
        command: HoldCommand,
    },
    /// Operate one explicit local systemd unit.
    #[command(alias = "service")]
    Unit {
        #[command(subcommand)]
        command: ServiceCommand,
    },
    /// Operate all Nix-declared services belonging to a resource.
    Resource {
        #[command(subcommand)]
        command: ResourceCommand,
    },
    /// Submit and inspect durable local jobs.
    Job {
        #[command(subcommand)]
        command: JobCommand,
    },
    /// Internal authenticated transfer protocol. Not an operator interface.
    #[command(name = "_transport", alias = "data", hide = true)]
    Transport {
        #[command(subcommand)]
        command: DataCommand,
    },
    /// Internal boot reconciliation invoked by the NixOS module.
    #[command(name = "_reconcile", hide = true)]
    Reconcile {
        #[command(subcommand)]
        command: ReconcileCommand,
    },
    /// Run bounded native host-maintenance operations.
    #[command(hide = true)]
    Maintenance {
        #[command(subcommand)]
        command: MaintenanceCommand,
    },
}

#[derive(Debug, Subcommand)]
enum MaintenanceCommand {
    Reboot,
    Gc(MaintenanceGcArgs),
    Clean(MaintenanceCleanArgs),
}

#[derive(Debug, Args)]
struct MaintenanceGcArgs {
    #[arg(long, conflicts_with = "delete_older_than")]
    all: bool,
    #[arg(long, default_value = "7d")]
    delete_older_than: String,
}

#[derive(Clone, Copy, Debug, clap::ValueEnum)]
enum MaintenanceCleanKind {
    Deploy,
    Podman,
    Nixbot,
}

#[derive(Debug, Args)]
struct MaintenanceCleanArgs {
    #[arg(long, value_enum, default_value_t = MaintenanceCleanKind::Deploy)]
    kind: MaintenanceCleanKind,
    #[arg(long)]
    force_held: bool,
}

#[derive(Debug, Args)]
struct LogArgs {
    #[command(flatten)]
    selector: LogSelectorArgs,
    #[arg(long, default_value_t = 200)]
    lines: usize,
    #[arg(long)]
    since: Option<String>,
    #[arg(short = 'f', long)]
    follow: bool,
    /// Journal entry encoding; JSON is emitted as one object per line.
    #[arg(short = 'o', long, value_enum, default_value_t = JournalOutput::Text)]
    output: JournalOutput,
}

#[derive(Debug, Args)]
struct LogSelectorArgs {
    /// Read journals for every declared unit in this resource.
    #[arg(long, conflicts_with = "unit")]
    resource: Option<String>,
    /// Read one explicit systemd unit journal.
    #[arg(long)]
    unit: Option<String>,
    #[arg(long, value_enum, default_value_t = ServiceScope::System)]
    scope: ServiceScope,
    /// User-manager owner; valid only with `--unit` and `--scope user`.
    #[arg(long)]
    user: Option<String>,
}

#[derive(Debug, Subcommand)]
enum HoldCommand {
    /// Materialize and enforce a claimable declarative bootstrap latch.
    #[command(hide = true)]
    Declare(HoldDeclareArgs),
    /// Persist a hold and immediately stop all declared services.
    Acquire(HoldAcquireArgs),
    /// Remove a matching hold without starting any service.
    Release(HoldReleaseArgs),
    /// Report whether one resource is held.
    Status(ResourceArgs),
    /// List every persistent hold.
    List,
    /// Re-apply one or all holds by stopping their declared services.
    #[command(hide = true)]
    Apply {
        /// Limit enforcement to one resource.
        #[arg(long)]
        resource: Option<String>,
    },
}

#[derive(Debug, Args)]
struct HoldDeclareArgs {
    #[arg(long)]
    resource: String,

    #[arg(long)]
    declaration: String,

    /// Persist the cold-start latch before the shared enforcement pass.
    #[arg(long, hide = true)]
    defer_enforcement: bool,
}

#[derive(Debug, Args)]
struct HoldAcquireArgs {
    #[arg(long)]
    resource: String,

    #[arg(long = "owner", alias = "transaction")]
    transaction: String,
}

#[derive(Debug, Args)]
struct HoldReleaseArgs {
    #[arg(long)]
    resource: String,

    #[arg(long = "owner", alias = "transaction")]
    transaction: String,
}

#[derive(Debug, Args)]
struct ResourceArgs {
    #[arg(long)]
    resource: String,
}

#[derive(Debug, Subcommand)]
enum ServiceCommand {
    Start(ServiceArgs),
    Stop(ServiceArgs),
    Restart(ServiceArgs),
    Reload(ServiceArgs),
    Status(ServiceArgs),
    #[command(hide = true)]
    Logs(LogServiceArgs),
}

#[derive(Debug, Subcommand)]
enum ResourceCommand {
    /// Return the validated local declaration and available native profiles.
    Describe(ResourceArgs),
    Start(ResourceArgs),
    Stop(ResourceArgs),
    Restart(ResourceArgs),
    Reload(ResourceArgs),
    Status(ResourceStatusArgs),
    /// Verify service state and every declared local readiness check.
    Ready(ResourceArgs),
    #[command(hide = true)]
    Logs(LogResourceArgs),
}

#[derive(Debug, Subcommand)]
enum ReconcileCommand {
    Hold {
        #[command(subcommand)]
        command: ReconcileHoldCommand,
    },
    DesiredResourceStates {
        #[arg(long, default_value = DEFAULT_DESIRED_RESOURCE_STATE_MANIFEST)]
        manifest: PathBuf,
    },
    /// Establish or hand off projected hold epochs before ordinary units start.
    DesiredResourceHolds {
        #[arg(long, default_value = DEFAULT_DESIRED_RESOURCE_STATE_MANIFEST)]
        manifest: PathBuf,
    },
    Jobs,
}

#[derive(Debug, Subcommand)]
enum ReconcileHoldCommand {
    Declare(HoldDeclareArgs),
    Apply {
        #[arg(long)]
        resource: Option<String>,
    },
}

#[derive(Debug, Subcommand)]
enum JobCommand {
    /// Persist an immutable, versioned JSON job specification.
    Submit(JobSpecSubmitArgs),
    /// Internal read-only resolver from a resource-scoped job intent to one immutable JobSpec.
    #[command(name = "_materialize", hide = true)]
    Materialize(Box<JobIntentArgs>),
    /// Show one durable job.
    #[command(alias = "status")]
    Show(JobIdArgs),
    /// Explicitly reset a terminal failed job to pending.
    Retry(JobRetryArgs),
    List,
    /// Run every pending job and recover jobs interrupted while running.
    #[command(hide = true)]
    RunPending,
}

#[derive(Clone, Copy, Debug, clap::ValueEnum)]
enum BuiltinJobOperation {
    Reserve,
    Hold,
    Release,
    Activate,
    Stop,
    Start,
    Status,
    Manifest,
    WipeData,
    Ready,
}

impl From<BuiltinJobOperation> for JobOperation {
    fn from(operation: BuiltinJobOperation) -> Self {
        match operation {
            BuiltinJobOperation::Reserve => Self::Reserve,
            BuiltinJobOperation::Hold => Self::Hold,
            BuiltinJobOperation::Release => Self::Release,
            BuiltinJobOperation::Activate => Self::Activate,
            BuiltinJobOperation::Stop => Self::Stop,
            BuiltinJobOperation::Start => Self::Start,
            BuiltinJobOperation::Status => Self::Status,
            BuiltinJobOperation::Manifest => Self::Manifest,
            BuiltinJobOperation::WipeData => Self::WipeData,
            BuiltinJobOperation::Ready => Self::Ready,
        }
    }
}

#[derive(Debug, Args)]
struct JobSpecSubmitArgs {
    /// JSON JobSpec file, or `-` to read one bounded document from stdin.
    #[arg(long, value_name = "FILE")]
    spec: String,

    /// Persist the job without running it in this process; boot reconciliation will resume it.
    #[arg(long)]
    defer: bool,
}

#[derive(Debug, Args)]
struct JobRetryArgs {
    #[arg(long)]
    job_id: String,

    /// Optional replacement JobSpec. Only missing broker host-key pins may be added.
    #[arg(long, value_name = "FILE", hide = true)]
    spec: Option<String>,
}

#[derive(Debug, Args)]
struct JobIntentArgs {
    #[arg(long, hide = true)]
    job_id: Option<String>,

    #[arg(long, hide = true)]
    transaction: Option<String>,

    /// JSON-encoded immutable repository projection binding.
    #[arg(long, hide = true)]
    projection: Option<String>,

    #[arg(long, hide = true)]
    resource: Option<String>,

    #[command(flatten)]
    job_operation: JobOperationArgs,

    /// JSON-encoded target endpoint for controller-brokered direct transfers.
    #[arg(long, hide = true)]
    target_endpoint: Option<String>,

    /// Optional absolute snapshot root for a brokered managed-host backup.
    #[arg(long, hide = true)]
    destination_root: Option<PathBuf>,

    /// JSON-encoded immutable source/target data-root mapping.
    #[arg(long, hide = true)]
    data_root_plan: Option<String>,

    /// Read immutable source roots from this agent's backup namespace.
    #[arg(long, hide = true)]
    backup_source: bool,

    /// Resource service that was active before a backup hold; valid only with --restore.
    #[arg(long = "active-service", requires = "restore", hide = true)]
    active_services: Vec<ServiceTarget>,

    /// Required service state for a built-in status job.
    #[arg(long, value_enum, default_value_t = ExpectedState::Any, hide = true)]
    expect: ExpectedState,
}

#[derive(Debug, Args)]
#[group(id = "job_operation", multiple = false)]
struct JobOperationArgs {
    /// Built-in, resource-scoped operation.
    #[arg(long, value_enum, hide = true)]
    operation: Option<BuiltinJobOperation>,

    /// Invoke only this statically allowlisted resource operation.
    #[arg(long, hide = true)]
    named_operation: Option<String>,

    /// Run one Nix-declared transfer profile.
    #[arg(long, hide = true)]
    transfer: Option<String>,

    /// Verify one Nix-declared transfer profile without copying.
    #[arg(long, hide = true)]
    verify_transfer: Option<String>,

    /// Run a controller-brokered direct copy from this JSON-encoded source endpoint.
    #[arg(long, hide = true)]
    broker_copy: Option<String>,

    /// Run a controller-brokered direct verification from this JSON-encoded source endpoint.
    #[arg(long, hide = true)]
    broker_verify: Option<String>,

    /// Copy every declared data path into an immutable local backup snapshot.
    #[arg(long, hide = true)]
    backup: bool,

    /// Restore one agent-owned immutable backup snapshot into the held resource.
    #[arg(long, hide = true)]
    restore_backup: Option<String>,

    /// Delete one exact agent-owned immutable backup snapshot.
    #[arg(long, hide = true)]
    delete_backup: Option<String>,

    /// Release a backup hold and restart only the supplied pre-backup active services.
    #[arg(long, hide = true)]
    restore: bool,

    /// Atomically apply one Nix-declared file state and reload its services.
    #[arg(long, hide = true)]
    file_state: Option<String>,

    /// Ensure one declared infrastructure instance exists.
    #[arg(long, hide = true)]
    provision: Option<String>,

    /// Run one JSON-encoded, durable Incus snapshot/copy/refresh request.
    #[arg(long, hide = true)]
    migrate_instance: Option<String>,

    /// Run one JSON-encoded, durable Incus lifecycle or snapshot request.
    #[arg(long, hide = true)]
    control_instance: Option<String>,

    /// Run one JSON-encoded, durable whole-instance archive operation.
    #[arg(long, hide = true)]
    backup_instance: Option<String>,

    /// Activate one declared NixOS system closure.
    #[arg(long, hide = true)]
    deploy: Option<String>,

    /// Run one JSON-encoded Nixbot deployment through controller policy.
    #[arg(long, hide = true)]
    nixbot_deploy: Option<String>,
}

#[derive(Debug, Args)]
struct JobIdArgs {
    #[arg(long)]
    job_id: String,
}

#[derive(Debug, Args)]
struct ResourceStatusArgs {
    #[arg(long)]
    resource: String,

    /// Fail unless every declared service has the expected state.
    #[arg(long, value_enum, default_value_t = ExpectedState::Any)]
    expect: ExpectedState,
}

#[derive(Debug, Args)]
struct ServiceArgs {
    #[arg(long, value_enum, default_value_t = ServiceScope::System)]
    scope: ServiceScope,

    /// User whose user manager owns the unit; valid only with --scope user.
    #[arg(long)]
    user: Option<String>,

    #[arg(long)]
    unit: String,
}

#[derive(Debug, Args)]
struct LogServiceArgs {
    #[command(flatten)]
    service: ServiceArgs,
    #[arg(long, default_value_t = 200)]
    lines: usize,
    #[arg(long)]
    since: Option<String>,
    #[arg(short = 'f', long)]
    follow: bool,
    #[arg(short = 'o', long, value_enum, default_value_t = JournalOutput::Text)]
    output: JournalOutput,
}

#[derive(Debug, Args)]
struct LogResourceArgs {
    #[arg(long)]
    resource: String,
    #[arg(long, default_value_t = 200)]
    lines: usize,
    #[arg(long)]
    since: Option<String>,
    #[arg(short = 'f', long)]
    follow: bool,
    #[arg(short = 'o', long, value_enum, default_value_t = JournalOutput::Text)]
    output: JournalOutput,
}

#[derive(Debug, Subcommand)]
enum DataCommand {
    /// Recursively hash declared paths without following symlinks or changing data.
    Manifest(DataManifestArgs),
    /// Return this host's public Ed25519 SSH host key for broker pinning.
    SshHostKey,
    /// Resolve an immutable target snapshot root from this agent's backup policy.
    BackupPlan(DataBackupPlanArgs),
    /// Receive a tar stream into an exact Nix-declared data root.
    Receive(DataReceiveArgs),
    /// Receive a validated rsync server invocation into an allowed data root.
    ReceiveRsync(DataReceiveRsyncArgs),
    /// Push one local resource directly to a peer using forwarded controller authentication.
    Push(DataPushArgs),
    /// Serve the read-only rsync, tar, and manifest protocol behind a forced SSH command.
    Serve(DataServeArgs),
}

#[derive(Debug, Args)]
struct DataBackupPlanArgs {
    #[arg(long)]
    resource: String,

    #[arg(long)]
    snapshot: String,

    #[arg(long = "source-path", required = true)]
    source_paths: Vec<PathBuf>,
}

#[derive(Debug, Args)]
struct DataReceiveArgs {
    /// Exact destination root declared by a local resource.
    #[arg(long)]
    destination: PathBuf,

    /// Compatibility-only peer hint. The receiver always uses its locally
    /// declared tar executable.
    #[arg(long = "tar-program", hide = true)]
    _legacy_tar_program: Option<PathBuf>,

    /// Clear existing destination entries before extracting the archive.
    #[arg(long)]
    delete: bool,

    /// Exact relative subtrees omitted from copy, deletion, and verification.
    #[arg(long = "exclude")]
    excludes: Vec<PathBuf>,
}

#[derive(Debug, Args)]
struct DataReceiveRsyncArgs {
    #[arg(long)]
    destination: PathBuf,

    /// Compatibility-only peer hint. The receiver always uses its locally
    /// declared rsync executable.
    #[arg(long = "rsync-program", hide = true)]
    _legacy_rsync_program: Option<PathBuf>,

    #[arg(long = "exclude")]
    excludes: Vec<PathBuf>,

    #[arg(last = true, allow_hyphen_values = true, required = true)]
    server_args: Vec<String>,
}

#[derive(Debug, Args)]
struct DataPushArgs {
    #[arg(long)]
    resource: String,

    /// JSON-encoded target endpoint supplied by a durable controller broker job.
    #[arg(long)]
    target_endpoint: String,

    /// Optional target snapshot root; defaults to each source data path.
    #[arg(long)]
    destination_root: Option<PathBuf>,

    /// Verify content and metadata without copying.
    #[arg(long)]
    verify: bool,

    /// Immutable source/target root mapping supplied by the controller job.
    #[arg(long)]
    data_root_plan: Option<String>,

    /// Permit exact source roots below this agent's immutable backup namespace.
    #[arg(long)]
    backup_source: bool,
}

#[derive(Debug, Args)]
#[group(
    id = "manifest_source",
    required = true,
    multiple = false,
    args = ["resource", "paths"]
)]
struct DataManifestArgs {
    /// Manifest the Nix-declared data paths for this resource.
    #[arg(long)]
    resource: Option<String>,

    /// Manifest explicit paths for diagnostics only.
    #[arg(long = "diagnostic-path", value_name = "PATH")]
    paths: Vec<PathBuf>,

    /// Exact relative subtrees omitted from a diagnostic root.
    #[arg(long = "exclude", requires = "paths")]
    excludes: Vec<PathBuf>,
}

#[derive(Debug, Args)]
#[group(
    id = "served_resources",
    required = true,
    multiple = false,
    args = ["resource", "all_declared"]
)]
struct DataServeArgs {
    /// Resource whose declared data roots may be served.
    #[arg(long)]
    resource: Option<String>,

    /// Serve exact data roots from every declared resource. Intended for one host-level forced key.
    #[arg(long)]
    all_declared: bool,

    /// Absolute rsync executable used for a validated rsync sender request.
    #[arg(long)]
    rsync_program: PathBuf,

    /// Absolute tar executable used for a validated archive sender request.
    #[arg(long)]
    tar_program: PathBuf,
}

#[derive(Debug)]
pub struct CommandOutput {
    pub human: String,
    pub value: Value,
}

impl Cli {
    pub fn streams_output(&self) -> bool {
        matches!(
            &self.command,
            Command::Logs(_)
                | Command::Unit {
                    command: ServiceCommand::Logs(_),
                }
                | Command::Resource {
                    command: ResourceCommand::Logs(_),
                }
        )
    }
}

pub fn execute(cli: Cli) -> Result<CommandOutput> {
    let json_output = cli.json;
    let store = StateStore::new(&cli.state_dir);
    let desired_receipts = DesiredResourceStateReceiptStore::new(&cli.state_dir);
    let jobs = JobStore::new(&cli.state_dir);
    let systemctl = Systemctl::new(&cli.systemctl);
    let journalctl = Journalctl::new(&cli.journalctl, &cli.runuser);
    let podman = cli.podman;
    let nix_collect_garbage = cli.nix_collect_garbage;
    let resource_manifest = cli.resource_manifest;
    let ssh_host_ed25519_public_key = cli.ssh_host_ed25519_public_key;

    match cli.command {
        Command::Status => execute_agent_status(&store, &jobs, &resource_manifest),
        Command::Logs(args) => execute_logs(
            args,
            &store,
            &systemctl,
            &journalctl,
            &resource_manifest,
            json_output,
        ),
        Command::Hold { command } => execute_hold(command, &store, &systemctl, &resource_manifest),
        Command::Unit { command } => {
            execute_service(command, &store, &systemctl, &journalctl, json_output)
        }
        Command::Resource { command } => execute_resource(
            command,
            &store,
            &systemctl,
            &journalctl,
            &resource_manifest,
            json_output,
        ),
        Command::Job { command } => {
            execute_job(command, &jobs, &store, &systemctl, &resource_manifest)
        }
        Command::Transport { command } => {
            execute_data(command, &resource_manifest, &ssh_host_ed25519_public_key)
        }
        Command::Reconcile { command } => match command {
            ReconcileCommand::Hold { command } => execute_hold(
                match command {
                    ReconcileHoldCommand::Declare(args) => HoldCommand::Declare(args),
                    ReconcileHoldCommand::Apply { resource } => HoldCommand::Apply { resource },
                },
                &store,
                &systemctl,
                &resource_manifest,
            ),
            ReconcileCommand::Jobs => execute_job(
                JobCommand::RunPending,
                &jobs,
                &store,
                &systemctl,
                &resource_manifest,
            ),
            ReconcileCommand::DesiredResourceStates { manifest } => {
                execute_desired_resource_states(
                    &manifest,
                    &resource_manifest,
                    &store,
                    &jobs,
                    &desired_receipts,
                    &systemctl,
                )
            }
            ReconcileCommand::DesiredResourceHolds { manifest } => {
                execute_desired_resource_holds(&manifest, &resource_manifest, &store, &systemctl)
            }
        },
        Command::Maintenance { command } => {
            execute_maintenance(command, &systemctl, &podman, &nix_collect_garbage)
        }
    }
}

fn desired_release_evidence(
    desired: &DesiredResourceState,
    include_activation_requirement: bool,
) -> ActivationReleaseEvidence {
    ActivationReleaseEvidence {
        intent_digest: desired.intent_digest.clone(),
        projection_digest: desired.projection_digest.clone(),
        generation: desired.generation,
        activation_requirement_digest: include_activation_requirement
            .then(|| desired.activation_requirement_digest.clone())
            .flatten(),
    }
}

/// Persist only the durable latches represented by desired resource states.
/// This runs early in boot, before the shared enforcement pass, so every user
/// manager can be released only after the complete projected hold set exists.
/// The subsequent `hold apply` enforces all latches uniformly.
fn execute_desired_resource_holds(
    desired_manifest_path: &Path,
    resource_manifest_path: &Path,
    store: &StateStore,
    _systemctl: &Systemctl,
) -> Result<CommandOutput> {
    let desired_manifest = DesiredResourceStateManifest::load(desired_manifest_path)?;
    let resources = ResourceManifest::load(resource_manifest_path)?;
    let mut reconciled = Vec::new();

    for desired in &desired_manifest.resources {
        let Some(declaration_id) = desired.hold_declaration_id() else {
            continue;
        };
        let resource = resources.resource(&desired.id)?;
        let transaction_id = desired
            .transaction_id
            .as_deref()
            .context("projected hold has no transaction identity")?;
        let result = match desired.state {
            DesiredResourceStateKind::Unheld => json!({
                "release": store.release_projected(
                    &desired.id,
                    transaction_id,
                    &declaration_id,
                    desired_release_evidence(desired, false),
                )?
            }),
            DesiredResourceStateKind::Active
                if !store.status(&desired.id)?.held
                    && store
                        .declaration_release(&desired.id, &declaration_id)?
                        .is_some() =>
            {
                let evidence = desired_release_evidence(desired, true);
                let release = store
                    .declaration_release(&desired.id, &declaration_id)?
                    .context("projected activation release disappeared")?;
                if release.transaction_id != transaction_id
                    || release.projection.as_ref() != Some(&evidence)
                {
                    bail!(
                        "active resource {:?} release does not match the exact desired projection",
                        desired.id
                    );
                }
                json!({ "release": release, "already_released": true })
            }
            DesiredResourceStateKind::Held
            | DesiredResourceStateKind::Inactive
            | DesiredResourceStateKind::Active => json!({
                "hold": store.acquire_projected_and_apply(
                    &desired.id,
                    transaction_id,
                    &declaration_id,
                    resource.services.clone(),
                    desired_release_evidence(desired, true),
                    |_| Ok(()),
                )?
            }),
        };
        reconciled.push(json!({
            "resource": desired.id,
            "state": desired.state,
            "result": result,
        }));
    }

    Ok(CommandOutput {
        human: format!("reconciled {} projected resource hold(s)", reconciled.len()),
        value: json!({
            "ok": true,
            "operation": "desired_resource_holds_reconcile",
            "result": {
                "count": reconciled.len(),
                "resources": reconciled,
            },
        }),
    })
}

fn execute_desired_resource_states(
    desired_manifest_path: &Path,
    resource_manifest_path: &Path,
    store: &StateStore,
    jobs: &JobStore,
    receipts: &DesiredResourceStateReceiptStore,
    systemctl: &Systemctl,
) -> Result<CommandOutput> {
    let desired_manifest = DesiredResourceStateManifest::load(desired_manifest_path)?;
    let resources = ResourceManifest::load(resource_manifest_path)?;

    // Fail before mutation when any declaration is unknown or regresses its
    // last applied projection. Runtime state is rechecked per resource below.
    for desired in &desired_manifest.resources {
        resources.resource(&desired.id)?;
        receipts.check_transition(desired)?;
        if desired.state == DesiredResourceStateKind::Active {
            preflight_desired_active_resource(
                desired,
                resources.resource(&desired.id)?,
                store,
                jobs,
            )?;
        } else if desired.state == DesiredResourceStateKind::Unheld {
            preflight_desired_unheld_resource(desired, resources.resource(&desired.id)?, store)?;
        }
    }

    let mut reconciled = Vec::with_capacity(desired_manifest.resources.len());
    for desired in &desired_manifest.resources {
        let resource = resources.resource(&desired.id)?;
        let result = match desired.state {
            DesiredResourceStateKind::Held | DesiredResourceStateKind::Inactive => {
                let declaration_id = desired
                    .hold_declaration_id()
                    .context("held desired resource has no hold epoch")?;
                let hold_job = desired_hold_job_spec(desired, resource)?;
                let submitted = jobs.submit(hold_job.clone())?;
                let job = jobs.run_job(&hold_job.job_id, |spec| {
                    execute_job_spec_with_progress(
                        spec,
                        store,
                        systemctl,
                        resource_manifest_path,
                        |progress| {
                            jobs.update_progress(&spec.job_id, serde_json::to_value(progress)?)
                        },
                    )
                })?;
                if job.status != JobStatus::Succeeded {
                    bail!(
                        "canonical hold job {:?} failed: {}",
                        hold_job.job_id,
                        job.error.as_deref().unwrap_or("unknown hold failure")
                    );
                }
                let hold = store
                    .status(&desired.id)?
                    .hold
                    .context("canonical hold job retained no durable hold")?;
                if hold.declaration_id.as_deref() != Some(&declaration_id)
                    || hold.projection.as_ref() != Some(&desired_release_evidence(desired, true))
                {
                    bail!("canonical hold job retained mismatched projection evidence");
                }
                json!({
                    "hold": hold,
                    "hold_job": job,
                    "replayed": !submitted.changed,
                })
            }
            DesiredResourceStateKind::Active => reconcile_desired_active_resource(
                desired,
                resource,
                resource_manifest_path,
                store,
                jobs,
                systemctl,
            )?,
            DesiredResourceStateKind::Unheld => {
                let declaration_id = desired
                    .hold_declaration_id()
                    .context("unheld desired resource has no hold epoch")?;
                let release_job = desired_release_job_spec(desired)?;
                let submitted = jobs.submit(release_job.clone())?;
                let job = jobs.run_job(&release_job.job_id, |spec| {
                    execute_job_spec_with_progress(
                        spec,
                        store,
                        systemctl,
                        resource_manifest_path,
                        |progress| {
                            jobs.update_progress(&spec.job_id, serde_json::to_value(progress)?)
                        },
                    )
                })?;
                if job.status != JobStatus::Succeeded {
                    bail!(
                        "canonical unhold job {:?} failed: {}",
                        release_job.job_id,
                        job.error.as_deref().unwrap_or("unknown unhold failure")
                    );
                }
                let release = store
                    .declaration_release(&desired.id, &declaration_id)?
                    .context("canonical unhold job retained no release evidence")?;
                json!({
                    "release": release,
                    "release_job": job,
                    "replayed": !submitted.changed,
                })
            }
        };
        let receipt = receipts.record(desired)?;
        reconciled.push(json!({
            "resource": desired.id,
            "state": desired.state,
            "projection_id": desired.projection_id,
            "projection_digest": desired.projection_digest,
            "generation": desired.generation,
            "result": result,
            "receipt": receipt,
        }));
    }

    Ok(CommandOutput {
        human: format!("reconciled {} desired resource state(s)", reconciled.len()),
        value: json!({
            "ok": true,
            "operation": "desired_resource_states_reconcile",
            "result": {
                "count": reconciled.len(),
                "resources": reconciled,
            },
        }),
    })
}

fn preflight_desired_unheld_resource(
    desired: &DesiredResourceState,
    resource: &crate::resource::ResourceDefinition,
    store: &StateStore,
) -> Result<()> {
    let declaration_id = desired
        .hold_declaration_id()
        .context("unheld desired resource has no hold epoch")?;
    let transaction_id = desired
        .transaction_id
        .as_deref()
        .context("unheld desired resource has no transaction identity")?;
    let evidence = desired_release_evidence(desired, false);
    let status = store.status(&desired.id)?;
    if let Some(hold) = status.hold {
        if hold.transaction_id != transaction_id
            || hold.declaration_id.as_deref() != Some(&declaration_id)
            || hold.services != resource.services
        {
            bail!(
                "unheld resource {:?} does not own the exact projected hold epoch",
                desired.id
            );
        }
        return Ok(());
    }
    let release = store
        .declaration_release(&desired.id, &declaration_id)?
        .with_context(|| {
            format!(
                "unheld resource {:?} has no exact projected release evidence",
                desired.id
            )
        })?;
    if release.transaction_id != transaction_id || release.projection.as_ref() != Some(&evidence) {
        bail!(
            "unheld resource {:?} release does not match the exact desired projection",
            desired.id
        );
    }
    Ok(())
}

fn preflight_desired_active_resource(
    desired: &DesiredResourceState,
    resource: &crate::resource::ResourceDefinition,
    store: &StateStore,
    jobs: &JobStore,
) -> Result<()> {
    let status = store.status(&desired.id)?;
    let Some(declaration_id) = desired.hold_declaration_id() else {
        if status.held {
            bail!(
                "active resource {:?} is held without a matching projected activation declaration",
                desired.id
            );
        }
        return Ok(());
    };
    let activation_requirement_digest = desired
        .activation_requirement_digest
        .clone()
        .context("activating a held resource requires an activation requirement digest")?;
    let evidence = ActivationReleaseEvidence {
        intent_digest: desired.intent_digest.clone(),
        projection_digest: desired.projection_digest.clone(),
        generation: desired.generation,
        activation_requirement_digest: Some(activation_requirement_digest),
    };
    let transaction_id = desired
        .transaction_id
        .as_deref()
        .context("active projected hold has no transaction identity")?;
    let activation_job = desired_activation_job_spec(desired, resource)?;
    if let Some(existing) = jobs.status_optional(&activation_job.job_id)?
        && existing.spec != activation_job
    {
        bail!(
            "activation job {:?} already exists with a different immutable specification",
            existing.spec.job_id
        );
    }
    if let Some(hold) = status.hold {
        if hold.transaction_id != transaction_id {
            bail!(
                "active resource {:?} is held by transaction {:?}, not {:?}",
                desired.id,
                hold.transaction_id,
                transaction_id
            );
        }
        if hold.declaration_id.as_deref() != Some(&declaration_id) {
            bail!(
                "active resource {:?} is held for declaration {:?}, not {:?}",
                desired.id,
                hold.declaration_id,
                declaration_id
            );
        }
        if hold.services != resource.services {
            bail!(
                "active resource {:?} has different service targets in its projected hold",
                desired.id
            );
        }
        return Ok(());
    }
    let release = store
        .declaration_release(&desired.id, &declaration_id)?
        .with_context(|| {
            format!(
                "active resource {:?} has no exact projected release evidence",
                desired.id
            )
        })?;
    if release.transaction_id != transaction_id || release.projection.as_ref() != Some(&evidence) {
        bail!(
            "active resource {:?} release does not match the exact desired projection",
            desired.id
        );
    }
    Ok(())
}

fn reconcile_desired_active_resource(
    desired: &DesiredResourceState,
    resource: &crate::resource::ResourceDefinition,
    resource_manifest_path: &Path,
    store: &StateStore,
    jobs: &JobStore,
    systemctl: &Systemctl,
) -> Result<Value> {
    if let Some(declaration_id) = desired.hold_declaration_id() {
        let activation_requirement_digest = desired
            .activation_requirement_digest
            .clone()
            .context("activating a held resource requires an activation requirement digest")?;
        let evidence = ActivationReleaseEvidence {
            intent_digest: desired.intent_digest.clone(),
            projection_digest: desired.projection_digest.clone(),
            generation: desired.generation,
            activation_requirement_digest: Some(activation_requirement_digest.clone()),
        };
        let activation_job = desired_activation_job_spec(desired, resource)?;
        let submitted = jobs.submit(activation_job.clone())?;
        let job = jobs.run_job(&activation_job.job_id, |spec| {
            execute_job_spec_with_progress(
                spec,
                store,
                systemctl,
                resource_manifest_path,
                |progress| jobs.update_progress(&spec.job_id, serde_json::to_value(progress)?),
            )
        })?;
        if job.status != JobStatus::Succeeded {
            bail!(
                "canonical activation job {:?} failed: {}",
                activation_job.job_id,
                job.error.as_deref().unwrap_or("unknown activation failure")
            );
        }
        let release = store
            .declaration_release(&desired.id, &declaration_id)?
            .with_context(|| {
                format!(
                    "canonical activation job {:?} retained no release evidence",
                    activation_job.job_id
                )
            })?;
        if release.transaction_id != activation_job.transaction_id
            || release.projection.as_ref() != Some(&evidence)
        {
            bail!("canonical activation job retained mismatched release evidence");
        }
        return Ok(json!({
            "release": release,
            "activation_job": job,
            "activation_requirement_digest": activation_requirement_digest,
            "authorization_issuer": "repository_deploy",
            "replayed": !submitted.changed,
        }));
    }

    let activation = store.run_if_resource_unheld(&desired.id, || {
        activate_and_verify_declared_resource(resource, systemctl)
    })?;
    Ok(json!({
        "activation": activation,
        "initial_active": true,
    }))
}

fn desired_activation_job_spec(
    desired: &DesiredResourceState,
    resource: &crate::resource::ResourceDefinition,
) -> Result<JobSpec> {
    let job_id = desired
        .activation_job_id
        .as_ref()
        .context("active held resource has no canonical activation job identity")?;
    let transaction_id = desired
        .transaction_id
        .as_ref()
        .context("active held resource has no transaction identity")?;
    Ok(JobSpec {
        schema_version: 1,
        job_id: job_id.clone(),
        transaction_id: transaction_id.clone(),
        projection: Some(JobProjectionBinding {
            intent_digest: desired.intent_digest.clone(),
            projection_digest: desired.projection_digest.clone(),
            generation: desired.generation,
            hold_epoch: desired.hold_epoch.clone(),
            activation_requirement_digest: desired.activation_requirement_digest.clone(),
        }),
        resource: desired.id.clone(),
        operation: JobOperation::Activate,
        expected_state: ExpectedState::Any,
        services: resource.services.clone(),
        data_paths: Vec::new(),
        data_root_plan: Vec::new(),
        argv: None,
        readiness: resource.readiness.clone(),
        transfer: None,
        resource_transfers: Vec::new(),
        backup_consistency: None,
        broker_transfer: None,
        file_state: None,
        instance: None,
        instance_migration: None,
        deployment: None,
        nixbot_deploy: None,
    })
}

fn desired_hold_job_spec(
    desired: &DesiredResourceState,
    resource: &crate::resource::ResourceDefinition,
) -> Result<JobSpec> {
    let hold_epoch = desired
        .hold_epoch
        .as_deref()
        .context("held projected resource has no hold epoch")?;
    let transaction_id = desired
        .transaction_id
        .as_ref()
        .context("held projected resource has no transaction identity")?;
    Ok(JobSpec {
        schema_version: 1,
        job_id: projected_hold_job_id(
            &desired.projection_id,
            &desired.id,
            hold_epoch,
            &desired.projection_digest,
        ),
        transaction_id: transaction_id.clone(),
        projection: Some(JobProjectionBinding {
            intent_digest: desired.intent_digest.clone(),
            projection_digest: desired.projection_digest.clone(),
            generation: desired.generation,
            hold_epoch: desired.hold_epoch.clone(),
            activation_requirement_digest: desired.activation_requirement_digest.clone(),
        }),
        resource: desired.id.clone(),
        operation: JobOperation::Hold,
        expected_state: ExpectedState::Any,
        services: resource.services.clone(),
        data_paths: Vec::new(),
        data_root_plan: Vec::new(),
        argv: None,
        readiness: Vec::new(),
        transfer: None,
        resource_transfers: Vec::new(),
        backup_consistency: None,
        broker_transfer: None,
        file_state: None,
        instance: None,
        instance_migration: None,
        deployment: None,
        nixbot_deploy: None,
    })
}

fn desired_release_job_spec(desired: &DesiredResourceState) -> Result<JobSpec> {
    let transaction_id = desired
        .transaction_id
        .as_ref()
        .context("unheld projected resource has no transaction identity")?;
    Ok(JobSpec {
        schema_version: 1,
        job_id: projected_release_job_id(
            &desired.projection_id,
            &desired.id,
            desired
                .hold_epoch
                .as_deref()
                .context("unheld projected resource has no hold epoch")?,
        ),
        transaction_id: transaction_id.clone(),
        projection: Some(JobProjectionBinding {
            intent_digest: desired.intent_digest.clone(),
            projection_digest: desired.projection_digest.clone(),
            generation: desired.generation,
            hold_epoch: desired.hold_epoch.clone(),
            activation_requirement_digest: None,
        }),
        resource: desired.id.clone(),
        operation: JobOperation::Release,
        expected_state: ExpectedState::Any,
        services: Vec::new(),
        data_paths: Vec::new(),
        data_root_plan: Vec::new(),
        argv: None,
        readiness: Vec::new(),
        transfer: None,
        resource_transfers: Vec::new(),
        backup_consistency: None,
        broker_transfer: None,
        file_state: None,
        instance: None,
        instance_migration: None,
        deployment: None,
        nixbot_deploy: None,
    })
}

fn activate_and_verify_declared_resource(
    resource: &crate::resource::ResourceDefinition,
    systemctl: &Systemctl,
) -> Result<Value> {
    let services = run_resource_services(ServiceOperation::Start, &resource.services, systemctl)?;
    let checks = wait_for_checks(&resource.readiness);
    if checks.iter().any(|check| !check.success) {
        let stop_error =
            run_resource_services(ServiceOperation::Stop, &resource.services, systemctl)
                .err()
                .map(|error| format!("{error:#}"));
        match stop_error {
            Some(stop_error) => bail!(
                "resource readiness failed after activation and stopping it also failed: {stop_error}"
            ),
            None => bail!("resource readiness failed after activation; services were stopped"),
        }
    }
    Ok(json!({
        "services": services,
        "checks": checks,
        "ready": true,
    }))
}

fn execute_agent_status(
    store: &StateStore,
    jobs: &JobStore,
    resource_manifest_path: &Path,
) -> Result<CommandOutput> {
    let manifest = ResourceManifest::load(resource_manifest_path)?;
    let holds = store.list()?;
    let jobs = jobs.list()?;
    let pending = jobs
        .iter()
        .filter(|job| job.status == JobStatus::Pending)
        .count();
    let running = jobs
        .iter()
        .filter(|job| job.status == JobStatus::Running)
        .count();
    let failed = jobs
        .iter()
        .filter(|job| job.status == JobStatus::Failed)
        .count();
    Ok(CommandOutput {
        human: format!(
            "agent ready: {} resource(s), {} hold(s), {} durable job(s)",
            manifest.resources.len(),
            holds.len(),
            jobs.len()
        ),
        value: json!({
            "ok": true,
            "operation": "agent_status",
            "result": {
                "schema_version": manifest.schema_version,
                "resources": manifest.resources.len(),
                "holds": holds.len(),
                "jobs": {
                    "total": jobs.len(),
                    "pending": pending,
                    "running": running,
                    "failed": failed,
                },
            },
        }),
    })
}

fn execute_logs(
    args: LogArgs,
    store: &StateStore,
    systemctl: &Systemctl,
    journalctl: &Journalctl,
    resource_manifest_path: &Path,
    json_output: bool,
) -> Result<CommandOutput> {
    if let Some(resource) = args.selector.resource {
        if args.selector.user.is_some() || args.selector.scope != ServiceScope::System {
            bail!("--scope and --user are valid only with --unit");
        }
        return execute_resource(
            ResourceCommand::Logs(LogResourceArgs {
                resource,
                lines: args.lines,
                since: args.since,
                follow: args.follow,
                output: args.output,
            }),
            store,
            systemctl,
            journalctl,
            resource_manifest_path,
            json_output,
        );
    }
    if let Some(unit) = args.selector.unit {
        return execute_service(
            ServiceCommand::Logs(LogServiceArgs {
                service: ServiceArgs {
                    scope: args.selector.scope,
                    user: args.selector.user,
                    unit,
                },
                lines: args.lines,
                since: args.since,
                follow: args.follow,
                output: args.output,
            }),
            store,
            systemctl,
            journalctl,
            json_output,
        );
    }
    if args.selector.user.is_some() || args.selector.scope != ServiceScope::System {
        bail!("--scope and --user are valid only with --unit");
    }
    if json_output {
        bail!("--json cannot be combined with logs; use --output json");
    }
    let result =
        journalctl.stream_host(args.lines, args.since.as_deref(), args.follow, args.output)?;
    ensure_journal_stream_succeeded(&result)?;
    Ok(CommandOutput {
        human: "host journal stream completed".to_owned(),
        value: json!({
            "ok": true,
            "operation": "host_logs_stream",
            "result": result,
        }),
    })
}

fn ensure_journal_stream_succeeded(result: &JournalStreamResult) -> Result<()> {
    if result.success {
        return Ok(());
    }
    bail!(
        "{} journal stream failed with exit code {:?}",
        result
            .failed_context
            .as_deref()
            .unwrap_or("unknown-context"),
        result.exit_code,
    )
}

fn execute_maintenance(
    command: MaintenanceCommand,
    systemctl: &Systemctl,
    podman: &Path,
    nix_collect_garbage: &Path,
) -> Result<CommandOutput> {
    match command {
        MaintenanceCommand::Reboot => {
            let output = Systemd::new(systemctl.executable())?.reboot_no_block()?;
            if !output.success {
                bail!("systemctl reboot failed: {}", output.stderr);
            }
            Ok(CommandOutput {
                human: "reboot submitted".to_owned(),
                value: json!({"ok": true, "operation": "maintenance_reboot"}),
            })
        }
        MaintenanceCommand::Gc(args) => {
            if !args.all && !safe_age(&args.delete_older_than) {
                bail!("garbage-collection age is invalid");
            }
            let nix = NixCollectGarbage::new(nix_collect_garbage)?;
            let output = if args.all {
                nix.delete_all()?
            } else {
                nix.delete_older_than(&args.delete_older_than)?
            };
            if !output.success {
                bail!("nix garbage collection failed: {}", output.stderr);
            }
            Ok(CommandOutput {
                human: "garbage collection completed".to_owned(),
                value: json!({
                    "ok": true,
                    "operation": "maintenance_gc",
                    "stdout": output.stdout,
                    "stderr": output.stderr,
                    "stdout_truncated_bytes": output.stdout_truncated_bytes,
                    "stderr_truncated_bytes": output.stderr_truncated_bytes,
                }),
            })
        }
        MaintenanceCommand::Clean(args) => {
            let kind = match args.kind {
                MaintenanceCleanKind::Deploy => CleanKind::Deploy,
                MaintenanceCleanKind::Podman => CleanKind::Podman,
                MaintenanceCleanKind::Nixbot => CleanKind::Nixbot,
            };
            let result = clean(kind, args.force_held, podman)?;
            Ok(CommandOutput {
                human: format!(
                    "removed {} lock(s) and {} volume(s); {} held lock(s) retained",
                    result.removed.len(),
                    result.removed_volumes.len(),
                    result.held.len()
                ),
                value: json!({
                    "ok": result.held.is_empty() || args.force_held,
                    "operation": "maintenance_clean",
                    "result": result,
                }),
            })
        }
    }
}

fn safe_age(value: &str) -> bool {
    !value.is_empty()
        && !value.starts_with('-')
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'+' | b'-'))
}

fn execute_hold(
    command: HoldCommand,
    store: &StateStore,
    systemctl: &Systemctl,
    resource_manifest_path: &Path,
) -> Result<CommandOutput> {
    match command {
        HoldCommand::Declare(args) => {
            let manifest = ResourceManifest::load(resource_manifest_path)?;
            let resource = manifest.resource(&args.resource)?;
            let defer_enforcement = args.defer_enforcement;
            let outcome = store.declare_and_apply(
                &args.resource,
                &args.declaration,
                resource.services.clone(),
                |hold| {
                    if defer_enforcement {
                        Ok(())
                    } else {
                        enforce_hold(hold, systemctl)
                    }
                },
            )?;
            Ok(CommandOutput {
                human: if outcome.released {
                    format!(
                        "declarative latch {:?} for resource {:?} was already released",
                        args.declaration, args.resource
                    )
                } else {
                    format!(
                        "declared{} latch {:?} for resource {:?}",
                        if defer_enforcement {
                            ""
                        } else {
                            " and enforced"
                        },
                        args.declaration,
                        args.resource
                    )
                },
                value: json!({
                    "ok": true,
                    "operation": "hold_declare",
                    "result": outcome,
                }),
            })
        }
        HoldCommand::Acquire(args) => {
            let manifest = ResourceManifest::load(resource_manifest_path)?;
            let resource = manifest.resource(&args.resource)?;
            let outcome = store.acquire_and_apply(
                &args.resource,
                &args.transaction,
                resource.services.clone(),
                |hold| enforce_hold(hold, systemctl),
            )?;
            let human = if outcome.changed {
                format!(
                    "acquired hold on {:?} for transaction {:?}; services are stopped",
                    outcome.hold.resource, outcome.hold.transaction_id
                )
            } else {
                format!(
                    "hold on {:?} already belongs to transaction {:?}; enforcement re-applied",
                    outcome.hold.resource, outcome.hold.transaction_id
                )
            };
            Ok(CommandOutput {
                human,
                value: json!({ "ok": true, "operation": "hold_acquire", "result": outcome }),
            })
        }
        HoldCommand::Release(args) => {
            let outcome = store.release(&args.resource, &args.transaction)?;
            let human = if outcome.changed {
                format!(
                    "released hold on {:?}; no services were started",
                    outcome.resource
                )
            } else {
                format!("resource {:?} was already unheld", outcome.resource)
            };
            Ok(CommandOutput {
                human,
                value: json!({ "ok": true, "operation": "hold_release", "result": outcome }),
            })
        }
        HoldCommand::Status(args) => {
            let status = store.status(&args.resource)?;
            let human = match &status.hold {
                Some(hold) => format!(
                    "resource {:?} is held by transaction {:?}",
                    hold.resource, hold.transaction_id
                ),
                None => format!("resource {:?} is not held", status.resource),
            };
            Ok(CommandOutput {
                human,
                value: json!({ "ok": true, "operation": "hold_status", "result": status }),
            })
        }
        HoldCommand::List => {
            let holds = store.list()?;
            let count = holds.len();
            Ok(CommandOutput {
                human: format!("{count} persistent hold(s)"),
                value: json!({
                    "ok": true,
                    "operation": "hold_list",
                    "result": { "count": count, "holds": holds },
                }),
            })
        }
        HoldCommand::Apply { resource } => {
            let holds = store.apply(resource.as_deref(), |hold| enforce_hold(hold, systemctl))?;
            if let Some(resource) = resource.filter(|_| holds.is_empty()) {
                bail!("resource {resource:?} is not held");
            }
            let count = holds.len();
            Ok(CommandOutput {
                human: format!("re-applied {count} persistent hold(s)"),
                value: json!({
                    "ok": true,
                    "operation": "hold_apply",
                    "result": { "count": count, "holds": holds },
                }),
            })
        }
    }
}

fn enforce_hold(hold: &HoldRecord, systemctl: &Systemctl) -> Result<()> {
    for service in &hold.services {
        let mut stopped_units = vec![service.clone()];
        for owned in systemctl.consists_of(service)? {
            if !stopped_units.iter().any(|target| target == &owned) {
                stopped_units.push(owned);
            }
        }
        systemctl.run(ServiceOperation::Stop, service)?;
        systemctl.reset_failed(&stopped_units)?;
    }
    if let Some(request) = &hold.instance_gate {
        control_instance(request).with_context(|| {
            format!(
                "re-enforce Incus gate for held resource {:?}",
                hold.resource
            )
        })?;
    }
    Ok(())
}

fn execute_service(
    command: ServiceCommand,
    store: &StateStore,
    systemctl: &Systemctl,
    journalctl: &Journalctl,
    json_output: bool,
) -> Result<CommandOutput> {
    if let ServiceCommand::Logs(args) = command {
        let target = ServiceTarget::new(args.service.scope, args.service.user, args.service.unit)?;
        if json_output {
            bail!("--json cannot be combined with logs; use --output json");
        }
        let result = journalctl.stream_targets(
            std::slice::from_ref(&target),
            args.lines,
            args.since.as_deref(),
            args.follow,
            args.output,
        )?;
        ensure_journal_stream_succeeded(&result)?;
        return Ok(CommandOutput {
            human: format!("journal stream completed for {target}"),
            value: json!({
                "ok": true,
                "operation": "service_logs_stream",
                "result": result,
            }),
        });
    }
    let (operation, args) = match command {
        ServiceCommand::Start(args) => (ServiceOperation::Start, args),
        ServiceCommand::Stop(args) => (ServiceOperation::Stop, args),
        ServiceCommand::Restart(args) => (ServiceOperation::Restart, args),
        ServiceCommand::Reload(args) => (ServiceOperation::Reload, args),
        ServiceCommand::Status(args) => (ServiceOperation::Status, args),
        ServiceCommand::Logs(_) => unreachable!(),
    };
    let target = ServiceTarget::new(args.scope, args.user, args.unit)?;
    let result = if matches!(
        operation,
        ServiceOperation::Start | ServiceOperation::Restart | ServiceOperation::Reload
    ) {
        store.run_if_service_unheld(&target, || systemctl.run(operation, &target))?
    } else {
        systemctl.run(operation, &target)?
    };
    let human = if operation == ServiceOperation::Status {
        format!(
            "{} is {}{}",
            target,
            if result.success {
                "active"
            } else {
                "not active"
            },
            if result.stdout.is_empty() {
                String::new()
            } else {
                format!(" ({})", result.stdout)
            }
        )
    } else {
        format!("{} completed for {}", operation_name(operation), target)
    };
    Ok(CommandOutput {
        human,
        value: json!({ "ok": true, "operation": operation_name(operation), "result": result }),
    })
}

fn execute_resource(
    command: ResourceCommand,
    store: &StateStore,
    systemctl: &Systemctl,
    journalctl: &Journalctl,
    resource_manifest_path: &Path,
    json_output: bool,
) -> Result<CommandOutput> {
    if let ResourceCommand::Describe(args) = command {
        let manifest = ResourceManifest::load(resource_manifest_path)?;
        let resource = manifest.resource(&args.resource)?;
        return Ok(CommandOutput {
            human: format!("described resource {:?}", args.resource),
            value: json!({
                "ok": true,
                "operation": "resource_describe",
                "result": { "resource": resource },
            }),
        });
    }
    if let ResourceCommand::Logs(args) = command {
        let manifest = ResourceManifest::load(resource_manifest_path)?;
        let resource = manifest.resource(&args.resource)?;
        if json_output {
            bail!("--json cannot be combined with logs; use --output json");
        }
        let result = journalctl.stream_targets(
            &resource.services,
            args.lines,
            args.since.as_deref(),
            args.follow,
            args.output,
        )?;
        ensure_journal_stream_succeeded(&result)?;
        return Ok(CommandOutput {
            human: format!("journal stream completed for resource {:?}", args.resource),
            value: json!({
                "ok": true,
                "operation": "resource_logs_stream",
                "result": result,
            }),
        });
    }
    if let ResourceCommand::Ready(args) = command {
        let manifest = ResourceManifest::load(resource_manifest_path)?;
        let resource = manifest.resource(&args.resource)?;
        let services =
            run_resource_services(ServiceOperation::Status, &resource.services, systemctl)?;
        let checks = run_checks(&resource.readiness);
        let ready = services.iter().all(|result| result.success)
            && checks.iter().all(|result| result.success);
        return Ok(CommandOutput {
            human: format!("resource {:?}: ready={ready}", args.resource),
            value: json!({
                "ok": ready,
                "operation": "resource_ready",
                "result": {
                    "resource": args.resource,
                    "ready": ready,
                    "services": services,
                    "checks": checks,
                },
            }),
        });
    }
    let (resource_id, operation, expected_state) = match command {
        ResourceCommand::Describe(_) => unreachable!(),
        ResourceCommand::Start(args) => {
            (args.resource, ServiceOperation::Start, ExpectedState::Any)
        }
        ResourceCommand::Stop(args) => (args.resource, ServiceOperation::Stop, ExpectedState::Any),
        ResourceCommand::Restart(args) => {
            (args.resource, ServiceOperation::Restart, ExpectedState::Any)
        }
        ResourceCommand::Reload(args) => {
            (args.resource, ServiceOperation::Reload, ExpectedState::Any)
        }
        ResourceCommand::Status(args) => (args.resource, ServiceOperation::Status, args.expect),
        ResourceCommand::Ready(_) => unreachable!(),
        ResourceCommand::Logs(_) => unreachable!(),
    };
    let manifest = ResourceManifest::load(resource_manifest_path)?;
    let resource = manifest.resource(&resource_id)?;
    if resource.services.is_empty() {
        bail!("resource {resource_id:?} does not declare any services");
    }

    let run = || run_resource_services(operation, &resource.services, systemctl);
    let results = if matches!(
        operation,
        ServiceOperation::Start | ServiceOperation::Restart | ServiceOperation::Reload
    ) {
        store.run_if_resource_unheld(&resource_id, run)?
    } else {
        run()?
    };
    let all_active = results.iter().all(|result| result.success);
    let all_inactive = results.iter().all(|result| !result.success);
    match expected_state {
        ExpectedState::Active if !all_active => {
            bail!("resource {resource_id:?} is not fully active")
        }
        ExpectedState::Inactive if !all_inactive => {
            bail!("resource {resource_id:?} is not fully inactive")
        }
        _ => {}
    }

    Ok(CommandOutput {
        human: match operation {
            ServiceOperation::Start => format!("started resource {resource_id:?}"),
            ServiceOperation::Stop => format!("stopped resource {resource_id:?}"),
            ServiceOperation::Restart => format!("restarted resource {resource_id:?}"),
            ServiceOperation::Reload => format!("reloaded resource {resource_id:?}"),
            ServiceOperation::TryReloadOrRestart => {
                format!("reloaded or restarted resource {resource_id:?}")
            }
            ServiceOperation::Status => format!(
                "resource {resource_id:?}: all_active={all_active}, all_inactive={all_inactive}"
            ),
        },
        value: json!({
            "ok": true,
            "operation": match operation {
                ServiceOperation::Start => "resource_start",
                ServiceOperation::Stop => "resource_stop",
                ServiceOperation::Restart => "resource_restart",
                ServiceOperation::Reload => "resource_reload",
                ServiceOperation::TryReloadOrRestart => "resource_try_reload_or_restart",
                ServiceOperation::Status => "resource_status",
            },
            "result": {
                "resource": resource_id,
                "all_active": all_active,
                "all_inactive": all_inactive,
                "services": results,
            },
        }),
    })
}

fn run_resource_services(
    operation: ServiceOperation,
    services: &[ServiceTarget],
    systemctl: &Systemctl,
) -> Result<Vec<ServiceResult>> {
    services
        .iter()
        .map(|service| systemctl.run(operation, service))
        .collect()
}

fn operation_name(operation: ServiceOperation) -> &'static str {
    match operation {
        ServiceOperation::Start => "service_start",
        ServiceOperation::Stop => "service_stop",
        ServiceOperation::Restart => "service_restart",
        ServiceOperation::Reload => "service_reload",
        ServiceOperation::TryReloadOrRestart => "service_try_reload_or_restart",
        ServiceOperation::Status => "service_status",
    }
}

fn execute_job(
    command: JobCommand,
    jobs: &JobStore,
    store: &StateStore,
    systemctl: &Systemctl,
    resource_manifest_path: &Path,
) -> Result<CommandOutput> {
    match command {
        JobCommand::Submit(args) => {
            let defer = args.defer;
            let spec = read_job_spec(&args.spec)?;
            let submitted = jobs.submit(spec)?;
            let job = if defer {
                submitted.job
            } else {
                jobs.run_job(&submitted.job.spec.job_id, |spec| {
                    execute_job_spec_with_progress(
                        spec,
                        store,
                        systemctl,
                        resource_manifest_path,
                        |progress| {
                            jobs.update_progress(&spec.job_id, serde_json::to_value(progress)?)
                        },
                    )
                })?
            };
            Ok(CommandOutput {
                human: format!("job {:?} is {:?}", job.spec.job_id, job.status),
                value: json!({
                    "ok": true,
                    "operation": "job_submit",
                    "result": { "changed": submitted.changed, "job": job },
                }),
            })
        }
        JobCommand::Materialize(args) => {
            let args = *args;
            let spec = materialize_job_spec(args, resource_manifest_path)?;
            Ok(CommandOutput {
                human: format!("materialized immutable job specification {:?}", spec.job_id),
                value: json!({
                    "ok": true,
                    "operation": "job_materialize",
                    "result": { "spec": spec },
                }),
            })
        }
        JobCommand::Show(args) => {
            let job = jobs.status(&args.job_id)?;
            Ok(CommandOutput {
                human: format!("job {:?} is {:?}", job.spec.job_id, job.status),
                value: json!({ "ok": true, "operation": "job_status", "result": job }),
            })
        }
        JobCommand::Retry(args) => {
            let replacement = args.spec.as_deref().map(read_job_spec).transpose()?;
            let retried = jobs.retry_with_spec(&args.job_id, replacement)?;
            Ok(CommandOutput {
                human: format!(
                    "job {:?} is {:?}",
                    retried.job.spec.job_id, retried.job.status
                ),
                value: json!({
                    "ok": true,
                    "operation": "job_retry",
                    "result": { "changed": retried.changed, "job": retried.job },
                }),
            })
        }
        JobCommand::List => {
            let listed = jobs.list()?;
            let count = listed.len();
            Ok(CommandOutput {
                human: format!("{count} durable job(s)"),
                value: json!({
                    "ok": true,
                    "operation": "job_list",
                    "result": { "count": count, "jobs": listed },
                }),
            })
        }
        JobCommand::RunPending => {
            let completed = jobs.run_pending(|spec| {
                execute_job_spec_with_progress(
                    spec,
                    store,
                    systemctl,
                    resource_manifest_path,
                    |progress| jobs.update_progress(&spec.job_id, serde_json::to_value(progress)?),
                )
            })?;
            let count = completed.len();
            let failed = completed.iter().filter(|job| job.error.is_some()).count();
            Ok(CommandOutput {
                human: format!("processed {count} pending job(s); {failed} failed"),
                value: json!({
                    "ok": failed == 0,
                    "operation": "job_run_pending",
                    "result": { "count": count, "failed": failed, "jobs": completed },
                }),
            })
        }
    }
}

fn materialize_job_spec(args: JobIntentArgs, resource_manifest_path: &Path) -> Result<JobSpec> {
    let job_id = args
        .job_id
        .clone()
        .context("job intent requires --job-id")?;
    let transaction = args
        .transaction
        .clone()
        .context("job intent requires --transaction")?;
    let projection: Option<JobProjectionBinding> = args
        .projection
        .as_deref()
        .map(serde_json::from_str)
        .transpose()
        .context("parse immutable projection binding")?;
    let resource_id = args
        .resource
        .clone()
        .context("job intent requires --resource")?;
    let operation = if let Some(operation) = args.job_operation.operation {
        operation.into()
    } else if let Some(name) = args.job_operation.named_operation {
        JobOperation::Named { name }
    } else if let Some(name) = args.job_operation.transfer {
        JobOperation::Transfer { name }
    } else if let Some(name) = args.job_operation.verify_transfer {
        JobOperation::VerifyTransfer { name }
    } else if let Some(source) = args.job_operation.broker_copy {
        JobOperation::BrokerCopy {
            source: parse_broker_endpoint(&source, "source")?,
            target: parse_broker_endpoint(
                args.target_endpoint
                    .as_deref()
                    .context("--target-endpoint is required with --broker-copy")?,
                "target",
            )?,
            destination_root: validate_destination_root(args.destination_root.clone())?,
            backup_source: args.backup_source,
        }
    } else if let Some(source) = args.job_operation.broker_verify {
        JobOperation::BrokerVerify {
            source: parse_broker_endpoint(&source, "source")?,
            target: parse_broker_endpoint(
                args.target_endpoint
                    .as_deref()
                    .context("--target-endpoint is required with --broker-verify")?,
                "target",
            )?,
            destination_root: validate_destination_root(args.destination_root.clone())?,
            backup_source: args.backup_source,
        }
    } else if args.job_operation.backup {
        JobOperation::Backup
    } else if let Some(snapshot) = args.job_operation.restore_backup {
        JobOperation::RestoreBackup { snapshot }
    } else if let Some(snapshot) = args.job_operation.delete_backup {
        JobOperation::DeleteBackup { snapshot }
    } else if args.job_operation.restore {
        JobOperation::Restore {
            active_services: args.active_services,
        }
    } else if let Some(name) = args.job_operation.file_state {
        JobOperation::FileState { name }
    } else if let Some(name) = args.job_operation.provision {
        JobOperation::Provision { name }
    } else if let Some(request) = args.job_operation.migrate_instance {
        JobOperation::MigrateInstance {
            request: serde_json::from_str(&request).context("parse --migrate-instance request")?,
        }
    } else if let Some(request) = args.job_operation.control_instance {
        JobOperation::ControlInstance {
            request: serde_json::from_str(&request).context("parse --control-instance request")?,
        }
    } else if let Some(request) = args.job_operation.backup_instance {
        JobOperation::BackupInstance {
            request: serde_json::from_str(&request).context("parse --backup-instance request")?,
        }
    } else if let Some(name) = args.job_operation.deploy {
        JobOperation::Deploy { name }
    } else if let Some(request) = args.job_operation.nixbot_deploy {
        JobOperation::NixbotDeploy {
            request: serde_json::from_str(&request).context("parse --nixbot-deploy request")?,
        }
    } else {
        bail!("job intent requires exactly one operation selector")
    };
    if args.target_endpoint.is_some()
        && !matches!(
            operation,
            JobOperation::BrokerCopy { .. } | JobOperation::BrokerVerify { .. }
        )
    {
        bail!("--target-endpoint is valid only with a broker operation");
    }
    if args.destination_root.is_some()
        && !matches!(
            operation,
            JobOperation::BrokerCopy { .. } | JobOperation::BrokerVerify { .. }
        )
    {
        bail!("--destination-root is valid only with a broker operation");
    }
    if args.backup_source
        && !matches!(
            operation,
            JobOperation::BrokerCopy { .. } | JobOperation::BrokerVerify { .. }
        )
    {
        bail!("--backup-source is valid only with a broker operation");
    }
    let inputs = resolve_job_inputs(&operation, &resource_id, &job_id, resource_manifest_path)?;
    let nixbot_deploy = if matches!(operation, JobOperation::NixbotDeploy { .. }) {
        let manifest = ResourceManifest::load(resource_manifest_path)?;
        let resource = manifest.resource(&resource_id)?;
        if !resource.nixbot_deploy {
            bail!(
                "resource {:?} does not allow Nixbot deployments",
                resource_id
            );
        }
        Some(
            manifest
                .nixbot_deploy
                .context("host agent has no Nixbot controller policy")?,
        )
    } else {
        None
    };
    let broker_transfer = if matches!(
        operation,
        JobOperation::BrokerCopy { .. } | JobOperation::BrokerVerify { .. }
    ) {
        Some(
            ResourceManifest::load(resource_manifest_path)?
                .broker_transfer
                .context("this host agent is not configured as a transfer broker")?,
        )
    } else {
        None
    };
    let mut data_root_plan: Vec<DataRootPlan> = args
        .data_root_plan
        .as_deref()
        .map(serde_json::from_str)
        .transpose()
        .context("parse immutable data-root plan")?
        .unwrap_or_default();
    if data_root_plan.is_empty()
        && matches!(
            &operation,
            JobOperation::Backup | JobOperation::RestoreBackup { .. }
        )
    {
        let manifest = ResourceManifest::load(resource_manifest_path)?;
        let roots = manifest.resource(&resource_id)?.effective_data_roots();
        let restoring = matches!(&operation, JobOperation::RestoreBackup { .. });
        data_root_plan = roots
            .into_iter()
            .zip(&inputs.resource_transfers)
            .map(|(root, transfer)| DataRootPlan {
                name: root.name,
                source: if restoring {
                    transfer.source.clone()
                } else {
                    root.path.clone()
                },
                target: if restoring {
                    root.path
                } else {
                    transfer.destination.clone()
                },
                excludes: root.excludes,
            })
            .collect();
    }
    if data_root_plan.is_empty() && matches!(&operation, JobOperation::WipeData) {
        let manifest = ResourceManifest::load(resource_manifest_path)?;
        data_root_plan = manifest
            .resource(&resource_id)?
            .effective_data_roots()
            .into_iter()
            .map(|root| DataRootPlan {
                name: root.name,
                source: root.path.clone(),
                target: root.path,
                excludes: root.excludes,
            })
            .collect();
    }
    Ok(JobSpec {
        schema_version: 1,
        job_id,
        transaction_id: transaction,
        projection,
        resource: resource_id,
        operation,
        expected_state: args.expect,
        services: inputs.services,
        data_paths: inputs.data_paths,
        data_root_plan,
        argv: inputs.argv,
        readiness: inputs.readiness,
        transfer: inputs.transfer,
        resource_transfers: inputs.resource_transfers,
        backup_consistency: inputs.backup_consistency,
        broker_transfer,
        file_state: inputs.file_state,
        instance: inputs.instance,
        instance_migration: inputs.instance_migration,
        deployment: inputs.deployment,
        nixbot_deploy,
    })
}

fn read_job_spec(source: &str) -> Result<JobSpec> {
    let mut bytes = Vec::new();
    if source == "-" {
        std::io::stdin()
            .lock()
            .take(JOB_SPEC_LIMIT + 1)
            .read_to_end(&mut bytes)
            .context("read job specification from stdin")?;
    } else {
        std::fs::File::open(source)
            .with_context(|| format!("open job specification {source}"))?
            .take(JOB_SPEC_LIMIT + 1)
            .read_to_end(&mut bytes)
            .with_context(|| format!("read job specification {source}"))?;
    }
    if bytes.len() as u64 > JOB_SPEC_LIMIT {
        bail!("job specification exceeds {JOB_SPEC_LIMIT} bytes");
    }
    serde_json::from_slice(&bytes).with_context(|| format!("parse job specification {source}"))
}

fn require_owned_inactive_hold(
    spec: &JobSpec,
    store: &StateStore,
    systemctl: &Systemctl,
    operation: &str,
) -> Result<()> {
    let hold = store.status(&spec.resource)?.hold.with_context(|| {
        format!(
            "{operation} requires resource {:?} to be held",
            spec.resource
        )
    })?;
    if hold.transaction_id != spec.transaction_id {
        bail!(
            "{operation} transaction {:?} does not own resource {:?} hold",
            spec.transaction_id,
            spec.resource
        );
    }
    let statuses = run_resource_services(ServiceOperation::Status, &spec.services, systemctl)?;
    if statuses.iter().any(|status| status.success) {
        bail!("{operation} requires every resource service to be inactive");
    }
    Ok(())
}

fn validate_materialized_backup_job(spec: &JobSpec, manifest_path: &Path) -> Result<()> {
    let expected =
        resolve_job_inputs(&spec.operation, &spec.resource, &spec.job_id, manifest_path)?;
    if spec.services != expected.services
        || spec.data_paths != expected.data_paths
        || spec.resource_transfers != expected.resource_transfers
        || spec.backup_consistency != expected.backup_consistency
    {
        bail!("backup job inputs differ from the current immutable host declaration");
    }
    if matches!(
        spec.operation,
        JobOperation::Backup | JobOperation::RestoreBackup { .. }
    ) {
        let manifest = ResourceManifest::load(manifest_path)?;
        let roots = manifest.resource(&spec.resource)?.effective_data_roots();
        let restoring = matches!(spec.operation, JobOperation::RestoreBackup { .. });
        let expected_plan = roots
            .into_iter()
            .zip(&expected.resource_transfers)
            .map(|(root, transfer)| DataRootPlan {
                name: root.name,
                source: if restoring {
                    transfer.source.clone()
                } else {
                    root.path.clone()
                },
                target: if restoring {
                    root.path
                } else {
                    transfer.destination.clone()
                },
                excludes: root.excludes,
            })
            .collect::<Vec<_>>();
        if spec.data_root_plan != expected_plan {
            bail!("backup job data-root plan differs from the host declaration");
        }
    } else if !spec.data_root_plan.is_empty() {
        bail!("backup deletion job cannot carry a data-root plan");
    }
    Ok(())
}

fn validate_materialized_wipe_job(spec: &JobSpec, manifest_path: &Path) -> Result<()> {
    let expected = resolve_job_inputs(
        &JobOperation::WipeData,
        &spec.resource,
        &spec.job_id,
        manifest_path,
    )?;
    let roots = ResourceManifest::load(manifest_path)?
        .resource(&spec.resource)?
        .effective_data_roots();
    let expected_plan = roots
        .into_iter()
        .map(|root| DataRootPlan {
            name: root.name,
            source: root.path.clone(),
            target: root.path,
            excludes: root.excludes,
        })
        .collect::<Vec<_>>();
    if spec.services != expected.services
        || spec.data_paths != expected.data_paths
        || spec.data_root_plan != expected_plan
    {
        bail!("data-wipe job inputs differ from the current immutable host declaration");
    }
    Ok(())
}

#[cfg(test)]
fn execute_job_spec(
    spec: &JobSpec,
    store: &StateStore,
    systemctl: &Systemctl,
) -> Result<JobExecution> {
    execute_job_spec_with_progress(spec, store, systemctl, Path::new("/does/not/exist"), |_| {
        Ok(())
    })
}

fn execute_job_spec_with_progress(
    spec: &JobSpec,
    store: &StateStore,
    systemctl: &Systemctl,
    resource_manifest_path: &Path,
    mut progress: impl FnMut(&crate::transfer::TransferProgress) -> Result<()>,
) -> Result<JobExecution> {
    match &spec.operation {
        JobOperation::Reserve => {
            let outcome = match projection_hold_declaration_id(spec) {
                Some(declaration_id) => store.acquire_projected_and_apply(
                    &spec.resource,
                    &spec.transaction_id,
                    &declaration_id,
                    Vec::new(),
                    projection_hold_evidence(spec)?,
                    |_| Ok(()),
                )?,
                None => store.acquire_and_apply(
                    &spec.resource,
                    &spec.transaction_id,
                    Vec::new(),
                    |_| Ok(()),
                )?,
            };
            Ok(JobExecution::succeeded(json!({ "hold": outcome })))
        }
        JobOperation::Hold => {
            let outcome = match projection_hold_declaration_id(spec) {
                Some(declaration_id) => store.acquire_projected_and_apply(
                    &spec.resource,
                    &spec.transaction_id,
                    &declaration_id,
                    spec.services.clone(),
                    projection_hold_evidence(spec)?,
                    |hold| enforce_hold(hold, systemctl),
                )?,
                None => store.acquire_and_apply(
                    &spec.resource,
                    &spec.transaction_id,
                    spec.services.clone(),
                    |hold| enforce_hold(hold, systemctl),
                )?,
            };
            Ok(JobExecution::succeeded(json!({ "hold": outcome })))
        }
        JobOperation::Release => {
            let outcome = match projection_hold_declaration_id(spec) {
                Some(declaration_id) => {
                    let projection = spec.projection.as_ref().context(
                        "projection hold declaration requires an immutable projection binding",
                    )?;
                    store.release_projected(
                        &spec.resource,
                        &spec.transaction_id,
                        &declaration_id,
                        ActivationReleaseEvidence {
                            intent_digest: projection.intent_digest.clone(),
                            projection_digest: projection.projection_digest.clone(),
                            generation: projection.generation,
                            activation_requirement_digest: None,
                        },
                    )?
                }
                None => store.release(&spec.resource, &spec.transaction_id)?,
            };
            Ok(JobExecution::succeeded(json!({ "release": outcome })))
        }
        JobOperation::Activate => {
            let (release, (services, checks)) = match projection_hold_declaration_id(spec) {
                Some(declaration_id) => {
                    let projection = spec.projection.as_ref().context(
                        "projection hold declaration requires an immutable projection binding",
                    )?;
                    store.activate_projected_and_apply(
                        &spec.resource,
                        &spec.transaction_id,
                        &declaration_id,
                        &spec.services,
                        ActivationReleaseEvidence {
                            intent_digest: projection.intent_digest.clone(),
                            projection_digest: projection.projection_digest.clone(),
                            generation: projection.generation,
                            activation_requirement_digest: Some(
                                projection
                                    .activation_requirement_digest
                                    .clone()
                                    .context(
                                        "projection activation requires a requirement digest",
                                    )?,
                            ),
                        },
                        || {
                            let services = run_resource_services(
                                ServiceOperation::Start,
                                &spec.services,
                                systemctl,
                            )?;
                            let checks = wait_for_checks(&spec.readiness);
                            if checks.iter().any(|check| !check.success) {
                                let stop_error = run_resource_services(
                                    ServiceOperation::Stop,
                                    &spec.services,
                                    systemctl,
                                )
                                .err()
                                .map(|error| format!("{error:#}"));
                                match stop_error {
                                    Some(stop_error) => bail!(
                                        "resource readiness failed after activation and stopping it also failed: {stop_error}"
                                    ),
                                    None => bail!(
                                        "resource readiness failed after activation; services were stopped"
                                    ),
                                }
                            }
                            Ok((services, checks))
                        },
                    )?
                }
                None => store.activate_and_apply(
                    &spec.resource,
                    &spec.transaction_id,
                    &spec.services,
                    || {
                        let services = run_resource_services(
                            ServiceOperation::Start,
                            &spec.services,
                            systemctl,
                        )?;
                        let checks = wait_for_checks(&spec.readiness);
                        if checks.iter().any(|check| !check.success) {
                            let stop_error = run_resource_services(
                                ServiceOperation::Stop,
                                &spec.services,
                                systemctl,
                            )
                            .err()
                            .map(|error| format!("{error:#}"));
                            match stop_error {
                                Some(stop_error) => bail!(
                                    "resource readiness failed after activation and stopping it also failed: {stop_error}"
                                ),
                                None => bail!(
                                    "resource readiness failed after activation; services were stopped"
                                ),
                            }
                        }
                        Ok((services, checks))
                    },
                )?,
            };
            Ok(JobExecution::succeeded(json!({
                "release": release,
                "services": services,
                "checks": checks,
            })))
        }
        JobOperation::Restore { active_services } => {
            let (release, services) = store.activate_and_apply(
                &spec.resource,
                &spec.transaction_id,
                &spec.services,
                || run_resource_services(ServiceOperation::Start, active_services, systemctl),
            )?;
            Ok(JobExecution::succeeded(json!({
                "release": release,
                "services": services,
            })))
        }
        JobOperation::Stop => {
            let results = run_resource_services(ServiceOperation::Stop, &spec.services, systemctl)?;
            Ok(JobExecution::succeeded(json!({ "services": results })))
        }
        JobOperation::Start => {
            let results = store.run_if_resource_unheld(&spec.resource, || {
                run_resource_services(ServiceOperation::Start, &spec.services, systemctl)
            })?;
            Ok(JobExecution::succeeded(json!({ "services": results })))
        }
        JobOperation::Status => {
            let results =
                run_resource_services(ServiceOperation::Status, &spec.services, systemctl)?;
            let all_active = results.iter().all(|result| result.success);
            let all_inactive = results.iter().all(|result| !result.success);
            match spec.expected_state {
                ExpectedState::Active if !all_active => {
                    bail!("resource {:?} is not fully active", spec.resource)
                }
                ExpectedState::Inactive if !all_inactive => {
                    bail!("resource {:?} is not fully inactive", spec.resource)
                }
                _ => {}
            }
            Ok(JobExecution::succeeded(json!({
                "all_active": all_active,
                "all_inactive": all_inactive,
                "services": results,
            })))
        }
        JobOperation::Manifest => {
            let manifest = if spec.data_root_plan.is_empty() {
                create_manifest(&spec.data_paths)?
            } else {
                create_manifest_roots(
                    &spec
                        .data_root_plan
                        .iter()
                        .map(DataRootPlan::source_root)
                        .collect::<Vec<_>>(),
                )?
            };
            Ok(JobExecution::succeeded(json!({ "manifest": manifest })))
        }
        JobOperation::WipeData => {
            validate_materialized_wipe_job(spec, resource_manifest_path)?;
            require_owned_inactive_hold(spec, store, systemctl, "data wipe")?;
            let roots = spec
                .data_root_plan
                .iter()
                .map(DataRootPlan::target_root)
                .collect::<Vec<_>>();
            Ok(JobExecution::succeeded(json!({
                "wipe": wipe_data_roots(&roots, &mut progress)?,
            })))
        }
        JobOperation::Ready => {
            let services =
                run_resource_services(ServiceOperation::Status, &spec.services, systemctl)?;
            let checks = run_checks(&spec.readiness);
            let ready = services.iter().all(|result| result.success)
                && checks.iter().all(|result| result.success);
            let result = json!({
                "ready": ready,
                "services": services,
                "checks": checks,
            });
            if ready {
                Ok(JobExecution::succeeded(result))
            } else {
                Ok(JobExecution::failed(
                    result,
                    format!("resource {:?} is not ready", spec.resource),
                ))
            }
        }
        JobOperation::Transfer { .. } => Ok(JobExecution::succeeded(json!({
            "transfer": transfer_with_progress(
                spec.transfer
                    .as_ref()
                    .context("transfer job has no resolved transfer definition")?,
                &mut progress,
            )?,
        }))),
        JobOperation::VerifyTransfer { .. } => {
            let verification = verify_transfer(
                spec.transfer
                    .as_ref()
                    .context("verify job has no resolved transfer definition")?,
            )?;
            let matches = verification.matches;
            let result = json!({ "verification": verification });
            if matches {
                Ok(JobExecution::succeeded(result))
            } else {
                Ok(JobExecution::failed(
                    result,
                    format!("resource {:?} transfer verification failed", spec.resource),
                ))
            }
        }
        JobOperation::Backup => {
            validate_materialized_backup_job(spec, resource_manifest_path)?;
            if matches!(&spec.operation, JobOperation::Backup)
                && spec.backup_consistency == Some(BackupConsistency::Quiesced)
            {
                let hold = store.status(&spec.resource)?.hold.with_context(|| {
                    format!(
                        "quiesced backup requires resource {:?} to be held",
                        spec.resource
                    )
                })?;
                if hold.transaction_id != spec.transaction_id {
                    bail!(
                        "quiesced backup transaction {:?} does not own resource {:?} hold",
                        spec.transaction_id,
                        spec.resource
                    );
                }
                let statuses =
                    run_resource_services(ServiceOperation::Status, &spec.services, systemctl)?;
                if statuses.iter().any(|status| status.success) {
                    bail!("quiesced backup requires every resource service to be inactive");
                }
            }
            let transfers = spec
                .resource_transfers
                .iter()
                .map(|transfer| {
                    let excludes = spec
                        .data_root_plan
                        .iter()
                        .find(|root| {
                            root.source == transfer.source && root.target == transfer.destination
                        })
                        .map_or(&[][..], |root| root.excludes.as_slice());
                    transfer_with_excludes_progress(transfer, excludes, &mut progress)
                })
                .collect::<Result<Vec<_>>>()?;
            Ok(JobExecution::succeeded(json!({ "transfers": transfers })))
        }
        JobOperation::RestoreBackup { .. } => {
            validate_materialized_backup_job(spec, resource_manifest_path)?;
            require_owned_inactive_hold(spec, store, systemctl, "backup restore")?;
            let transfers = spec
                .resource_transfers
                .iter()
                .map(|transfer| {
                    let excludes = spec
                        .data_root_plan
                        .iter()
                        .find(|root| {
                            root.source == transfer.source && root.target == transfer.destination
                        })
                        .map_or(&[][..], |root| root.excludes.as_slice());
                    transfer_with_excludes_progress(transfer, excludes, &mut progress)
                })
                .collect::<Result<Vec<_>>>()?;
            Ok(JobExecution::succeeded(json!({
                "restored": true,
                "transfers": transfers,
            })))
        }
        JobOperation::DeleteBackup { .. } => {
            validate_materialized_backup_job(spec, resource_manifest_path)?;
            let manifest = ResourceManifest::load(resource_manifest_path)?;
            let snapshot = spec
                .data_paths
                .first()
                .context("backup deletion job has no snapshot root")?;
            if !snapshot.starts_with(&manifest.backup_root) || snapshot == &manifest.backup_root {
                bail!("backup deletion path is outside the configured backup root");
            }
            let existed = snapshot.exists();
            if existed {
                std::fs::remove_dir_all(snapshot)
                    .with_context(|| format!("delete backup snapshot {}", snapshot.display()))?;
                if let Some(parent) = snapshot.parent() {
                    std::fs::File::open(parent)?.sync_all()?;
                }
            }
            Ok(JobExecution::succeeded(json!({
                "deleted": true,
                "existed": existed,
                "snapshot": snapshot,
            })))
        }
        JobOperation::BrokerCopy {
            source,
            target,
            destination_root,
            backup_source,
        }
        | JobOperation::BrokerVerify {
            source,
            target,
            destination_root,
            backup_source,
        } => {
            let verify = matches!(&spec.operation, JobOperation::BrokerVerify { .. });
            let response = run_broker_transfer_with_progress(
                spec.broker_transfer
                    .as_ref()
                    .context("broker job has no resolved transfer policy")?,
                BrokerTransferRequest {
                    source,
                    target,
                    resource: &spec.resource,
                    job_id: &spec.job_id,
                    verify,
                    destination_root: destination_root.as_deref(),
                    runtime_root: Path::new("/run/abird-host-agent/broker"),
                    data_root_plan: &spec.data_root_plan,
                    backup_source: *backup_source,
                },
                &mut progress,
            )?;
            Ok(JobExecution::succeeded(json!({
                "direct_peer": true,
                "verification_only": verify,
                "source_response": response,
            })))
        }
        JobOperation::FileState { .. } => {
            let state = spec
                .file_state
                .as_ref()
                .context("file-state job has no resolved definition")?;
            // Always reload after confirming the durable file state. A previous
            // attempt may have replaced the file and then lost the reload, so
            // changed=false cannot be treated as proof that the consumer
            // applied this state.
            let result = apply_file_state_with_reload(state, |service| {
                systemctl.run(ServiceOperation::TryReloadOrRestart, service)
            })?;
            let value = json!({
                "file_state": result.file_state,
                "reloads": result.reloads,
                "rollback_reloads": result.rollback_reloads,
            });
            match result.error {
                Some(error) => Ok(JobExecution::failed(value, error)),
                None => Ok(JobExecution::succeeded(value)),
            }
        }
        JobOperation::Provision { .. } => Ok(JobExecution::succeeded(json!({
            "instance": ensure_instance(
                spec.instance
                    .as_ref()
                    .context("provision job has no resolved instance definition")?
            )?,
        }))),
        JobOperation::MigrateInstance { .. } => {
            let hold = store.status(&spec.resource)?.hold.with_context(|| {
                format!(
                    "instance migration requires destination resource {:?} to be held",
                    spec.resource
                )
            })?;
            if hold.transaction_id != spec.transaction_id {
                bail!(
                    "instance migration transaction {:?} does not own resource {:?} hold",
                    spec.transaction_id,
                    spec.resource
                );
            }
            Ok(JobExecution::succeeded(json!({
                "instance_migration": migrate_instance(
                    spec.instance_migration
                        .as_ref()
                        .context("instance migration job has no resolved request")?
                )?,
            })))
        }
        JobOperation::ControlInstance { request } => {
            let requires_hold = !matches!(
                &request.operation,
                InstanceControlAction::Inspect
                    | InstanceControlAction::VerifyMigrationTarget { .. }
                    | InstanceControlAction::AssertStopped { .. }
                    | InstanceControlAction::AssertRunning
                    | InstanceControlAction::SnapshotDelete { .. }
            );
            if requires_hold {
                let hold = store.status(&spec.resource)?.hold.with_context(|| {
                    format!(
                        "instance control requires resource {:?} to be held",
                        spec.resource
                    )
                })?;
                if hold.transaction_id != spec.transaction_id {
                    bail!(
                        "instance control transaction {:?} does not own resource {:?} hold",
                        spec.transaction_id,
                        spec.resource
                    );
                }
            }
            if matches!(&request.operation, InstanceControlAction::Stop { .. }) {
                store.attach_instance_gate(
                    &spec.resource,
                    &spec.transaction_id,
                    request.clone(),
                )?;
            }
            if matches!(&request.operation, InstanceControlAction::Activate) {
                let (release, result) = store.activate_after_apply(
                    &spec.resource,
                    &spec.transaction_id,
                    &[],
                    || control_instance(request),
                )?;
                Ok(JobExecution::succeeded(json!({
                    "instance_control": result,
                    "release": release,
                })))
            } else {
                Ok(JobExecution::succeeded(json!({
                    "instance_control": control_instance(request)?,
                })))
            }
        }
        JobOperation::BackupInstance { request } => {
            let manifest = ResourceManifest::load(resource_manifest_path)?;
            validate_instance_backup(request, &manifest.backup_root, &spec.resource)?;
            let requires_hold = matches!(
                &request.operation,
                InstanceBackupAction::Export { .. } | InstanceBackupAction::Replace { .. }
            );
            if requires_hold {
                let hold = store.status(&spec.resource)?.hold.with_context(|| {
                    format!(
                        "instance backup operation requires resource {:?} to be held",
                        spec.resource
                    )
                })?;
                if hold.transaction_id != spec.transaction_id {
                    bail!(
                        "instance backup transaction {:?} does not own resource {:?} hold",
                        spec.transaction_id,
                        spec.resource
                    );
                }
            }
            Ok(JobExecution::succeeded(json!({
                "instance_backup": run_instance_backup(
                    request,
                    &manifest.backup_root,
                    &spec.resource,
                )?,
            })))
        }
        JobOperation::Deploy { .. } => Ok(JobExecution::succeeded(json!({
            "deployment": activate(
                spec.deployment
                    .as_ref()
                    .context("deploy job has no resolved deployment definition")?
            )?,
        }))),
        JobOperation::NixbotDeploy { request } => {
            let policy = spec
                .nixbot_deploy
                .as_ref()
                .context("Nixbot deploy job has no resolved controller policy")?;
            let result = nixbot::deploy(policy, request)?;
            let value = json!({
                    "nixbot_deploy": result,
                    "host": request.host,
                    "nix_config": request.nix_config,
            });
            if result.success {
                Ok(JobExecution::succeeded(value))
            } else {
                Ok(JobExecution::failed(
                    value,
                    format!(
                        "Nixbot deployment of {:?} failed with {:?}",
                        request.host, result.exit_code
                    ),
                ))
            }
        }
        JobOperation::Named { .. } => execute_named_operation(spec),
    }
}

fn projection_hold_declaration_id(spec: &JobSpec) -> Option<String> {
    spec.projection.as_ref()?.hold_epoch.as_ref().map(|epoch| {
        let prefix = format!("{}:", spec.transaction_id);
        if epoch.starts_with(&prefix) {
            // Compatibility with the former public `hold_declaration_id`,
            // which carried the already-qualified declaration identifier.
            epoch.clone()
        } else {
            format!("{prefix}{epoch}")
        }
    })
}

fn projection_hold_evidence(spec: &JobSpec) -> Result<ActivationReleaseEvidence> {
    let projection = spec
        .projection
        .as_ref()
        .context("projected hold requires an immutable projection binding")?;
    Ok(ActivationReleaseEvidence {
        intent_digest: projection.intent_digest.clone(),
        projection_digest: projection.projection_digest.clone(),
        generation: projection.generation,
        activation_requirement_digest: projection.activation_requirement_digest.clone(),
    })
}

fn resolve_job_inputs(
    operation: &JobOperation,
    resource_id: &str,
    job_id: &str,
    resource_manifest_path: &Path,
) -> Result<ResolvedJobInputs> {
    if let JobOperation::MigrateInstance { request } = operation {
        return Ok(ResolvedJobInputs {
            services: Vec::new(),
            data_paths: Vec::new(),
            argv: None,
            readiness: Vec::new(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            file_state: None,
            instance: None,
            instance_migration: Some(request.clone()),
            deployment: None,
        });
    }
    if matches!(operation, JobOperation::ControlInstance { .. }) {
        return Ok(ResolvedJobInputs {
            services: Vec::new(),
            data_paths: Vec::new(),
            argv: None,
            readiness: Vec::new(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            file_state: None,
            instance: None,
            instance_migration: None,
            deployment: None,
        });
    }
    if let JobOperation::BackupInstance { request } = operation {
        let manifest = ResourceManifest::load(resource_manifest_path)?;
        validate_instance_backup(request, &manifest.backup_root, resource_id)?;
        return Ok(ResolvedJobInputs {
            services: Vec::new(),
            data_paths: Vec::new(),
            argv: None,
            readiness: Vec::new(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            file_state: None,
            instance: None,
            instance_migration: None,
            deployment: None,
        });
    }
    if matches!(
        operation,
        JobOperation::Reserve
            | JobOperation::Release
            | JobOperation::BrokerCopy { .. }
            | JobOperation::BrokerVerify { .. }
            | JobOperation::NixbotDeploy { .. }
    ) {
        return Ok(ResolvedJobInputs {
            services: Vec::new(),
            data_paths: Vec::new(),
            argv: None,
            readiness: Vec::new(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            file_state: None,
            instance: None,
            instance_migration: None,
            deployment: None,
        });
    }
    let manifest = ResourceManifest::load(resource_manifest_path)?;
    if let JobOperation::DeleteBackup { snapshot } = operation {
        validate_backup_snapshot_name(snapshot)?;
        return Ok(ResolvedJobInputs {
            services: Vec::new(),
            data_paths: vec![
                manifest
                    .backup_root
                    .join(digest_bytes(resource_id.as_bytes()))
                    .join(snapshot),
            ],
            argv: None,
            readiness: Vec::new(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            file_state: None,
            instance: None,
            instance_migration: None,
            deployment: None,
        });
    }
    let resource = manifest.resource(resource_id)?;
    match operation {
        JobOperation::Hold
        | JobOperation::Restore { .. }
        | JobOperation::Stop
        | JobOperation::Start
        | JobOperation::Status => Ok(ResolvedJobInputs {
            services: resource.services.clone(),
            data_paths: Vec::new(),
            argv: None,
            readiness: Vec::new(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            file_state: None,
            instance: None,
            instance_migration: None,
            deployment: None,
        }),
        JobOperation::Activate => Ok(ResolvedJobInputs {
            services: resource.services.clone(),
            data_paths: Vec::new(),
            argv: None,
            readiness: resource.readiness.clone(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            file_state: None,
            instance: None,
            instance_migration: None,
            deployment: None,
        }),
        JobOperation::Ready => Ok(ResolvedJobInputs {
            services: resource.services.clone(),
            data_paths: Vec::new(),
            argv: None,
            readiness: resource.readiness.clone(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            file_state: None,
            instance: None,
            instance_migration: None,
            deployment: None,
        }),
        JobOperation::Manifest => Ok(ResolvedJobInputs {
            services: Vec::new(),
            data_paths: resource.data_paths.clone(),
            argv: None,
            readiness: Vec::new(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            file_state: None,
            instance: None,
            instance_migration: None,
            deployment: None,
        }),
        JobOperation::WipeData => {
            let roots = resource.effective_data_roots();
            if roots.is_empty() {
                bail!("resource {resource_id:?} has no declared data roots");
            }
            Ok(ResolvedJobInputs {
                services: resource.services.clone(),
                data_paths: roots.into_iter().map(|root| root.path).collect(),
                argv: None,
                readiness: Vec::new(),
                transfer: None,
                resource_transfers: Vec::new(),
                backup_consistency: None,
                file_state: None,
                instance: None,
                instance_migration: None,
                deployment: None,
            })
        }
        JobOperation::Named { name } => {
            let operation = resource.operations.get(name).with_context(|| {
                format!("operation {name:?} is not allowlisted for resource {resource_id:?}")
            })?;
            Ok(ResolvedJobInputs {
                services: Vec::new(),
                data_paths: Vec::new(),
                argv: Some(operation.argv.clone()),
                readiness: Vec::new(),
                transfer: None,
                resource_transfers: Vec::new(),
                backup_consistency: None,
                file_state: None,
                instance: None,
                instance_migration: None,
                deployment: None,
            })
        }
        JobOperation::RestoreBackup { snapshot } => {
            validate_backup_snapshot_name(snapshot)?;
            let roots = resource.effective_data_roots();
            if roots.is_empty() {
                bail!("resource {resource_id:?} has no declared data paths");
            }
            let snapshot_root = manifest
                .backup_root
                .join(digest_bytes(resource_id.as_bytes()))
                .join(snapshot);
            let resource_transfers = roots
                .iter()
                .map(|root| TransferDefinition {
                    source: snapshot_root.join(
                        root.path
                            .strip_prefix("/")
                            .expect("validated absolute resource data path"),
                    ),
                    destination: root.path.clone(),
                    rsync_program: manifest.rsync_program.clone(),
                    remote_source: None,
                    remote_destination: None,
                    tar_program: manifest.tar_program.clone(),
                    delete: true,
                    fallback_copy: true,
                })
                .collect();
            Ok(ResolvedJobInputs {
                services: resource.services.clone(),
                data_paths: roots.iter().map(|root| root.path.clone()).collect(),
                argv: None,
                readiness: Vec::new(),
                transfer: None,
                resource_transfers,
                backup_consistency: Some(BackupConsistency::Quiesced),
                file_state: None,
                instance: None,
                instance_migration: None,
                deployment: None,
            })
        }
        JobOperation::DeleteBackup { .. } => unreachable!(),
        JobOperation::Transfer { name } | JobOperation::VerifyTransfer { name } => {
            let transfer = resource.transfers.get(name).with_context(|| {
                format!("transfer {name:?} is not declared for resource {resource_id:?}")
            })?;
            Ok(ResolvedJobInputs {
                services: Vec::new(),
                data_paths: Vec::new(),
                argv: None,
                readiness: Vec::new(),
                transfer: Some(transfer.clone()),
                resource_transfers: Vec::new(),
                backup_consistency: None,
                file_state: None,
                instance: None,
                instance_migration: None,
                deployment: None,
            })
        }
        JobOperation::Backup => {
            let roots = resource.effective_data_roots();
            if roots.is_empty() {
                bail!("resource {resource_id:?} has no declared data paths");
            }
            let snapshot_root = manifest
                .backup_root
                .join(digest_bytes(resource_id.as_bytes()))
                .join(job_id);
            let resource_transfers = roots
                .iter()
                .map(|root| TransferDefinition {
                    source: root.path.clone(),
                    destination: snapshot_root.join(
                        root.path
                            .strip_prefix("/")
                            .expect("validated absolute resource data path"),
                    ),
                    rsync_program: manifest.rsync_program.clone(),
                    remote_source: None,
                    remote_destination: None,
                    tar_program: manifest.tar_program.clone(),
                    delete: true,
                    fallback_copy: true,
                })
                .collect();
            Ok(ResolvedJobInputs {
                services: resource.services.clone(),
                data_paths: roots.iter().map(|root| root.path.clone()).collect(),
                argv: None,
                readiness: Vec::new(),
                transfer: None,
                resource_transfers,
                backup_consistency: Some(resource.backup_consistency),
                file_state: None,
                instance: None,
                instance_migration: None,
                deployment: None,
            })
        }
        JobOperation::FileState { name } => {
            let state = resource.file_states.get(name).with_context(|| {
                format!("file state {name:?} is not declared for resource {resource_id:?}")
            })?;
            Ok(ResolvedJobInputs {
                services: Vec::new(),
                data_paths: Vec::new(),
                argv: None,
                readiness: Vec::new(),
                transfer: None,
                resource_transfers: Vec::new(),
                backup_consistency: None,
                file_state: Some(state.clone()),
                instance: None,
                instance_migration: None,
                deployment: None,
            })
        }
        JobOperation::Provision { name } => {
            let instance = resource.instances.get(name).with_context(|| {
                format!("instance {name:?} is not declared for resource {resource_id:?}")
            })?;
            Ok(ResolvedJobInputs {
                services: Vec::new(),
                data_paths: Vec::new(),
                argv: None,
                readiness: Vec::new(),
                transfer: None,
                resource_transfers: Vec::new(),
                backup_consistency: None,
                file_state: None,
                instance: Some(instance.clone()),
                instance_migration: None,
                deployment: None,
            })
        }
        JobOperation::MigrateInstance { .. }
        | JobOperation::ControlInstance { .. }
        | JobOperation::BackupInstance { .. } => {
            unreachable!()
        }
        JobOperation::Deploy { name } => {
            let deployment = resource.deployments.get(name).with_context(|| {
                format!("deployment {name:?} is not declared for resource {resource_id:?}")
            })?;
            Ok(ResolvedJobInputs {
                services: Vec::new(),
                data_paths: Vec::new(),
                argv: None,
                readiness: Vec::new(),
                transfer: None,
                resource_transfers: Vec::new(),
                backup_consistency: None,
                file_state: None,
                instance: None,
                instance_migration: None,
                deployment: Some(deployment.clone()),
            })
        }
        JobOperation::Release => unreachable!(),
        JobOperation::Reserve => unreachable!(),
        JobOperation::BrokerCopy { .. }
        | JobOperation::BrokerVerify { .. }
        | JobOperation::NixbotDeploy { .. } => unreachable!(),
    }
}

fn parse_broker_endpoint(value: &str, label: &str) -> Result<RemoteSource> {
    let endpoint: RemoteSource =
        serde_json::from_str(value).with_context(|| format!("parse broker {label} endpoint"))?;
    if endpoint.identity_file.is_some() {
        bail!("broker {label} endpoint cannot contain a private identity path");
    }
    Ok(endpoint)
}

fn validate_destination_root(value: Option<PathBuf>) -> Result<Option<PathBuf>> {
    if let Some(path) = &value
        && (!path.is_absolute() || path == Path::new("/"))
    {
        bail!("broker destination root must be an absolute non-root path");
    }
    Ok(value)
}

fn validate_backup_snapshot_name(snapshot: &str) -> Result<()> {
    if snapshot.is_empty()
        || !snapshot
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
    {
        bail!("backup snapshot contains unsupported characters");
    }
    Ok(())
}

fn execute_named_operation(spec: &JobSpec) -> Result<JobExecution> {
    let JobOperation::Named { name } = &spec.operation else {
        bail!("job is not a named operation");
    };
    let argv = spec
        .argv
        .as_ref()
        .context("named job has no resolved argv")?;
    let executable = argv.first().context("named job argv is empty")?;
    let output = crate::command::CommandSpec::new(executable)
        .args(&argv[1..])
        .env("ABIRD_HOST_AGENT_JOB_ID", &spec.job_id)
        .env("ABIRD_HOST_AGENT_TRANSACTION_ID", &spec.transaction_id)
        .env("ABIRD_HOST_AGENT_RESOURCE", &spec.resource)
        .output()
        .with_context(|| format!("run allowlisted operation {name:?} for {:?}", spec.resource))?;
    let result = json!({
        "resource": spec.resource,
        "named_operation": name,
        "argv": argv,
        "success": output.success,
        "exit_code": output.exit_code,
        "stdout": output.stdout,
        "stderr": output.stderr,
        "stdout_truncated_bytes": output.stdout_truncated_bytes,
        "stderr_truncated_bytes": output.stderr_truncated_bytes,
    });
    if output.success {
        Ok(JobExecution::succeeded(result))
    } else {
        Ok(JobExecution::failed(
            result,
            format!(
                "allowlisted operation {name:?} exited with status {:?}",
                output.exit_code
            ),
        ))
    }
}

fn execute_data(
    command: DataCommand,
    resource_manifest_path: &Path,
    ssh_host_ed25519_public_key: &Path,
) -> Result<CommandOutput> {
    match command {
        DataCommand::Manifest(args) => {
            let (resource, roots) = match args.resource {
                Some(resource) => {
                    let manifest = ResourceManifest::load(resource_manifest_path)?;
                    let roots = manifest.resource(&resource)?.effective_data_roots();
                    if roots.is_empty() {
                        bail!("resource {resource:?} does not declare any data paths");
                    }
                    (Some(resource), roots)
                }
                None => {
                    if !args.excludes.is_empty() && args.paths.len() != 1 {
                        bail!("--exclude requires exactly one --diagnostic-path");
                    }
                    let roots = args
                        .paths
                        .into_iter()
                        .enumerate()
                        .map(|(index, path)| DataRoot {
                            name: format!("diagnostic-{index}"),
                            path,
                            excludes: args.excludes.clone(),
                        })
                        .collect();
                    (None, roots)
                }
            };
            let manifest = create_manifest_roots(&roots)?;
            let root_count = manifest.roots.len();
            let entry_count = manifest
                .roots
                .iter()
                .map(|root| root.entries.len())
                .sum::<usize>();
            Ok(CommandOutput {
                human: format!(
                    "manifested {entry_count} entries under {root_count} declared path(s)"
                ),
                value: json!({
                    "ok": true,
                    "operation": "data_manifest",
                    "resource": resource,
                    "result": { "manifest": manifest },
                }),
            })
        }
        DataCommand::BackupPlan(args) => backup_plan(args, resource_manifest_path),
        DataCommand::Receive(args) => receive_data(args, resource_manifest_path),
        DataCommand::ReceiveRsync(args) => receive_rsync(args, resource_manifest_path),
        DataCommand::Push(args) => push_data(args, resource_manifest_path),
        DataCommand::Serve(args) => serve_data(args, resource_manifest_path),
        DataCommand::SshHostKey => ssh_host_key(ssh_host_ed25519_public_key),
    }
}

fn ssh_host_key(path: &Path) -> Result<CommandOutput> {
    if !path.is_absolute() || path == Path::new("/") {
        bail!("public SSH host-key path must be absolute and cannot be root");
    }
    let public_key = std::fs::read_to_string(path)
        .with_context(|| format!("read public SSH host key {}", path.display()))?;
    let fields = public_key.split_whitespace().take(2).collect::<Vec<_>>();
    if fields.len() != 2 || fields[0] != "ssh-ed25519" {
        bail!("public SSH host key is not a valid Ed25519 key");
    }
    let public_key = fields.join(" ");
    Ok(CommandOutput {
        human: "read public SSH host key".to_owned(),
        value: json!({
            "ok": true,
            "operation": "data_ssh_host_key",
            "result": { "public_key": public_key },
        }),
    })
}

fn receive_rsync(
    args: DataReceiveRsyncArgs,
    resource_manifest_path: &Path,
) -> Result<CommandOutput> {
    let manifest = ResourceManifest::load(resource_manifest_path)?;
    validate_receive_destination(&args.destination, &args.excludes, &manifest)?;
    validate_rsync_receiver_args(&args.destination, &args.server_args)?;
    let error = ProcessCommand::new(&manifest.rsync_program)
        .args(&args.server_args)
        .exec();
    Err(error).with_context(|| format!("exec {}", manifest.rsync_program.display()))
}

fn validate_rsync_receiver_args(destination: &Path, server_args: &[String]) -> Result<()> {
    let requested = server_args
        .last()
        .map(|value| PathBuf::from(value.trim_end_matches('/')))
        .context("rsync receiver argv has no destination")?;
    if requested != destination {
        if server_args
            .last()
            .is_some_and(|argument| argument.starts_with('-'))
        {
            bail!(
                "rsync receiver did not expose its destination in argv; protected-args mode is not supported by the guarded receiver"
            );
        }
        bail!("rsync receiver argv does not name the exact allowed destination");
    }
    if !server_args.iter().any(|argument| argument == "--server")
        || server_args.iter().any(|argument| argument == "--sender")
        || server_args[..server_args.len() - 1]
            .iter()
            .any(|argument| argument.contains('/') || argument.contains(".."))
    {
        bail!("rsync receiver argv is not an allowed destination request");
    }
    Ok(())
}

fn validate_receive_destination(
    destination: &Path,
    excludes: &[PathBuf],
    manifest: &ResourceManifest,
) -> Result<()> {
    if !destination.is_absolute() || destination == Path::new("/") {
        bail!("data receive destination must be an absolute non-root path");
    }
    let declared = manifest
        .resources
        .iter()
        .flat_map(|resource| resource.effective_data_roots())
        .any(|root| root.path == destination && root.excludes == excludes);
    if !declared && !destination.starts_with(&manifest.backup_root) {
        bail!(
            "data receive destination is neither an exact declared data root nor below the backup root: {}",
            destination.display()
        );
    }
    Ok(())
}

fn backup_plan(args: DataBackupPlanArgs, resource_manifest_path: &Path) -> Result<CommandOutput> {
    for (label, value) in [("resource", &args.resource), ("snapshot", &args.snapshot)] {
        if value.is_empty()
            || !value.bytes().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':')
            })
        {
            bail!("backup {label} contains unsupported characters");
        }
    }
    if args
        .source_paths
        .iter()
        .any(|path| !path.is_absolute() || path == Path::new("/"))
    {
        bail!("backup source paths must be absolute and cannot be root");
    }
    let manifest = ResourceManifest::load(resource_manifest_path)?;
    let destination_root = manifest
        .backup_root
        .join(digest_bytes(args.resource.as_bytes()))
        .join(&args.snapshot);
    let destinations = args
        .source_paths
        .iter()
        .map(|path| {
            destination_root.join(
                path.strip_prefix("/")
                    .expect("validated absolute backup source path"),
            )
        })
        .collect::<Vec<_>>();
    Ok(CommandOutput {
        human: format!("planned backup snapshot {}", destination_root.display()),
        value: json!({
            "ok": true,
            "operation": "data_backup_plan",
            "result": {
                "resource": args.resource,
                "snapshot": args.snapshot,
                "destination_root": destination_root,
                "source_paths": args.source_paths,
                "destinations": destinations,
            },
        }),
    })
}

fn receive_data(args: DataReceiveArgs, resource_manifest_path: &Path) -> Result<CommandOutput> {
    let manifest = ResourceManifest::load(resource_manifest_path)?;
    validate_receive_destination(&args.destination, &args.excludes, &manifest)?;
    std::fs::create_dir_all(&args.destination)
        .with_context(|| format!("create data receive root {}", args.destination.display()))?;
    if args.delete {
        clear_directory_contents_except(&args.destination, &args.excludes)?;
    }
    let error = ProcessCommand::new(&manifest.tar_program)
        .args([
            "--acls",
            "--xattrs",
            "--numeric-owner",
            "--same-owner",
            "--same-permissions",
            "-C",
        ])
        .arg(&args.destination)
        .args(["-xpf", "-"])
        .exec();
    Err(error).with_context(|| format!("exec {}", manifest.tar_program.display()))
}

fn push_data(args: DataPushArgs, resource_manifest_path: &Path) -> Result<CommandOutput> {
    if env::var_os("SSH_AUTH_SOCK").is_none() {
        bail!(
            "source received no controller-forwarded SSH_AUTH_SOCK; allow agent forwarding for the transfer account and preserve SSH_AUTH_SOCK through its privilege boundary"
        );
    }
    let mut endpoint: RemoteSource =
        serde_json::from_str(&args.target_endpoint).context("parse broker target endpoint")?;
    if endpoint.identity_file.is_some() {
        bail!("broker target endpoint cannot carry a private identity path");
    }
    let known_hosts = materialize_broker_known_hosts(&endpoint)?;
    endpoint.ssh_args.extend([
        "-o".to_owned(),
        format!("UserKnownHostsFile={}", known_hosts.display()),
        "-o".to_owned(),
        "StrictHostKeyChecking=yes".to_owned(),
    ]);
    let manifest = ResourceManifest::load(resource_manifest_path)?;
    let declared_roots = if args.backup_source {
        Vec::new()
    } else {
        let roots = manifest.resource(&args.resource)?.effective_data_roots();
        if roots.is_empty() {
            bail!("resource {:?} has no declared data paths", args.resource);
        }
        roots
    };
    let plans = if let Some(encoded) = &args.data_root_plan {
        if args.destination_root.is_some() {
            bail!("--data-root-plan cannot be combined with --destination-root");
        }
        let plans: Vec<DataRootPlan> =
            serde_json::from_str(encoded).context("parse immutable data-root plan")?;
        if args.backup_source {
            validate_backup_source_plans(&manifest, &args.resource, &plans)?;
        } else {
            for plan in &plans {
                let source = plan.source_root();
                if !declared_roots.contains(&source) {
                    bail!(
                        "data-root plan {:?} does not match the declared source root",
                        plan.name
                    );
                }
            }
        }
        plans
    } else {
        if args.backup_source {
            bail!("backup-source transfer requires an immutable data-root plan");
        }
        declared_roots
            .iter()
            .map(|root| DataRootPlan {
                name: root.name.clone(),
                source: root.path.clone(),
                target: args.destination_root.as_ref().map_or_else(
                    || root.path.clone(),
                    |destination| {
                        destination.join(
                            root.path
                                .strip_prefix("/")
                                .expect("validated absolute resource data root"),
                        )
                    },
                ),
                excludes: root.excludes.clone(),
            })
            .collect()
    };
    let transfers = plans
        .iter()
        .map(|plan| TransferDefinition {
            source: plan.source.clone(),
            destination: plan.target.clone(),
            rsync_program: manifest.rsync_program.clone(),
            remote_source: None,
            remote_destination: Some(endpoint.clone()),
            tar_program: manifest.tar_program.clone(),
            delete: true,
            fallback_copy: true,
        })
        .collect::<Vec<_>>();
    if args.verify {
        let verifications = transfers
            .iter()
            .zip(&plans)
            .map(|(transfer, plan)| verify_transfer_with_excludes(transfer, &plan.excludes))
            .collect::<Result<Vec<_>>>()?;
        if verifications
            .iter()
            .any(|verification| !verification.matches)
        {
            bail!(
                "direct peer verification failed for resource {:?}",
                args.resource
            );
        }
        Ok(CommandOutput {
            human: format!(
                "verified resource {:?} directly against peer",
                args.resource
            ),
            value: json!({
                "ok": true,
                "operation": "data_push_verify",
                "result": { "data_root_plan": plans, "verifications": verifications },
            }),
        })
    } else {
        let transfers = transfers
            .iter()
            .zip(&plans)
            .map(|(transfer, plan)| {
                transfer_with_excludes_progress_policy(
                    transfer,
                    &plan.excludes,
                    PostCopyVerification::AllowSourceDrift,
                    |progress| {
                        eprintln!(
                            "abird-host-agent-progress {}",
                            serde_json::to_string(progress)?
                        );
                        Ok(())
                    },
                )
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(CommandOutput {
            human: format!("pushed resource {:?} directly to peer", args.resource),
            value: json!({
                "ok": true,
                "operation": "data_push",
                "result": { "data_root_plan": plans, "transfers": transfers },
            }),
        })
    }
}

fn validate_backup_source_plans(
    manifest: &ResourceManifest,
    resource: &str,
    plans: &[DataRootPlan],
) -> Result<()> {
    if plans.is_empty() {
        bail!("backup-source transfer requires at least one data root");
    }
    let namespace = manifest.backup_root.join(digest_bytes(resource.as_bytes()));
    for plan in plans {
        validate_data_root_plan(plan)?;
        let relative = plan.source.strip_prefix(&namespace).with_context(|| {
            format!(
                "backup source {} is outside resource namespace {}",
                plan.source.display(),
                namespace.display()
            )
        })?;
        let snapshot = relative
            .components()
            .next()
            .and_then(|component| match component {
                std::path::Component::Normal(value) => value.to_str(),
                _ => None,
            })
            .context("backup source has no safe snapshot component")?;
        validate_backup_snapshot_name(snapshot)?;
        let snapshot_root = namespace.join(snapshot);
        if plan.source == snapshot_root {
            continue;
        }
        let expected = namespace.join(snapshot).join(
            plan.target
                .strip_prefix("/")
                .context("backup restore target is not absolute")?,
        );
        if plan.source != expected {
            bail!(
                "backup source {} does not correspond exactly to restore target {}",
                plan.source.display(),
                plan.target.display()
            );
        }
    }
    Ok(())
}

fn materialize_broker_known_hosts(endpoint: &RemoteSource) -> Result<PathBuf> {
    if endpoint.host_public_keys.is_empty() {
        bail!("broker target endpoint has no controller-authenticated public host key");
    }
    let directory = Path::new("/run/abird-host-agent/known-hosts");
    std::fs::create_dir_all(directory)
        .with_context(|| format!("create {}", directory.display()))?;
    let key_material = endpoint.host_public_keys.join("\n");
    let path = directory.join(digest_bytes(
        format!(
            "{}\0{}\0{key_material}",
            endpoint.host,
            endpoint.port.unwrap_or(22)
        )
        .as_bytes(),
    ));
    let host = if endpoint.port.is_some_and(|port| port != 22) {
        format!(
            "[{}]:{}",
            endpoint.host,
            endpoint.port.expect("checked port")
        )
    } else {
        endpoint.host.clone()
    };
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&path)
        .with_context(|| format!("write broker known-hosts file {}", path.display()))?;
    for key in &endpoint.host_public_keys {
        if key.contains(['\0', '\r', '\n']) || !key.starts_with("ssh-") {
            bail!("broker target public host key is invalid");
        }
        writeln!(file, "{host} {key}")?;
    }
    file.sync_all()?;
    Ok(path)
}

fn serve_data(args: DataServeArgs, resource_manifest_path: &Path) -> Result<CommandOutput> {
    if !args.rsync_program.is_absolute() || !args.tar_program.is_absolute() {
        bail!("transfer server programs must be absolute");
    }
    let resource_manifest = ResourceManifest::load(resource_manifest_path)?;
    let data_roots = if let Some(resource_id) = &args.resource {
        let resource = resource_manifest.resource(resource_id)?;
        let roots = resource.effective_data_roots();
        if roots.is_empty() {
            bail!("resource {resource_id:?} does not declare any data paths");
        }
        roots
    } else {
        let roots = resource_manifest
            .resources
            .iter()
            .flat_map(|resource| resource.effective_data_roots())
            .collect::<Vec<_>>();
        if roots.is_empty() {
            bail!("resource manifest does not declare any data paths");
        }
        roots
    };
    let original = env::var("SSH_ORIGINAL_COMMAND")
        .context("data serve requires SSH_ORIGINAL_COMMAND from a forced SSH command")?;
    let argv = shlex::split(&original).context("parse SSH_ORIGINAL_COMMAND")?;
    if argv.is_empty() {
        bail!("SSH_ORIGINAL_COMMAND is empty");
    }

    if let Some((path, excludes)) = manifest_request(&argv) {
        let root = require_declared_data_root(&data_roots, &path, &excludes)?;
        let manifest = create_manifest_roots(std::slice::from_ref(root))?;
        return Ok(CommandOutput {
            human: format!("served a read-only manifest for {}", path.display()),
            value: json!({
                "ok": true,
                "operation": "data_manifest",
                "resource": args.resource,
                "result": { "manifest": manifest },
            }),
        });
    }

    if let Some((path, excludes)) = tar_request(&argv, &args.tar_program) {
        require_declared_data_root(&data_roots, &path, &excludes)?;
        let error = ProcessCommand::new(&args.tar_program)
            .args(&argv[1..])
            .exec();
        return Err(error).with_context(|| format!("exec {}", args.tar_program.display()));
    }

    if let Some(path) = rsync_request_path(&argv) {
        require_declared_data_path(
            &data_roots
                .iter()
                .map(|root| root.path.clone())
                .collect::<Vec<_>>(),
            path,
        )?;
        let error = ProcessCommand::new(&args.rsync_program)
            .args(&argv[1..])
            .exec();
        return Err(error).with_context(|| format!("exec {}", args.rsync_program.display()));
    }

    bail!("SSH_ORIGINAL_COMMAND is not an allowed read-only transfer request")
}

fn manifest_request(argv: &[String]) -> Option<(PathBuf, Vec<PathBuf>)> {
    if argv.len() >= 6
        && Path::new(&argv[0])
            .file_name()
            .and_then(|name| name.to_str())
            == Some("abird-host-agent")
        && argv[1..5] == ["--json", "data", "manifest", "--diagnostic-path"]
    {
        parse_excludes(&argv[6..]).map(|excludes| (PathBuf::from(&argv[5]), excludes))
    } else {
        None
    }
}

fn tar_request(argv: &[String], tar_program: &Path) -> Option<(PathBuf, Vec<PathBuf>)> {
    if argv.len() < 11
        || Path::new(&argv[0]) != tar_program
        || argv[1..6]
            != [
                "--acls",
                "--xattrs",
                "--numeric-owner",
                "--same-owner",
                "--same-permissions",
            ]
        || argv[6] != "-C"
    {
        return None;
    }
    let tail = &argv[8..];
    let marker = tail.iter().position(|argument| argument == "-cpf")?;
    if tail[marker..] != ["-cpf", "-", "."] {
        return None;
    }
    let filters = &tail[..marker];
    let filters = if filters
        .first()
        .is_some_and(|value| value == "--no-wildcards")
    {
        &filters[1..]
    } else {
        filters
    };
    let excludes = filters
        .iter()
        .map(|argument| argument.strip_prefix("--exclude=./").map(PathBuf::from))
        .collect::<Option<Vec<_>>>()?;
    Some((PathBuf::from(&argv[7]), excludes))
}

fn parse_excludes(argv: &[String]) -> Option<Vec<PathBuf>> {
    let mut excludes = Vec::new();
    let mut chunks = argv.chunks_exact(2);
    for pair in &mut chunks {
        if pair[0] != "--exclude" {
            return None;
        }
        excludes.push(PathBuf::from(&pair[1]));
    }
    chunks.remainder().is_empty().then_some(excludes)
}

fn require_declared_data_root<'a>(
    declared: &'a [DataRoot],
    requested: &Path,
    excludes: &[PathBuf],
) -> Result<&'a DataRoot> {
    let requested = PathBuf::from(requested.to_string_lossy().trim_end_matches('/'));
    declared
        .iter()
        .find(|root| root.path == requested && root.excludes == excludes)
        .with_context(|| {
            format!(
                "transfer request {} and excludes do not match an exact declared data root",
                requested.display()
            )
        })
}

fn rsync_request_path(argv: &[String]) -> Option<&Path> {
    let executable = argv
        .first()
        .and_then(|value| Path::new(value).file_name())?;
    let path = Path::new(argv.last()?);
    if executable != "rsync"
        || argv.len() < 5
        || !argv.iter().any(|argument| argument == "--server")
        || !argv.iter().any(|argument| argument == "--sender")
        || argv[1..argv.len() - 1].iter().any(|argument| {
            argument.contains("..")
                || argument.contains('/')
                || (argument.contains('=') && !argument.starts_with("--log-format="))
                || !(argument == "." || argument.starts_with('-'))
        })
    {
        return None;
    }
    Some(path)
}

fn require_declared_data_path(declared: &[PathBuf], requested: &Path) -> Result<()> {
    let requested = PathBuf::from(requested.to_string_lossy().trim_end_matches('/'));
    if declared.iter().any(|path| path == &requested) {
        Ok(())
    } else {
        bail!(
            "transfer request path {} is not an exact declared data root",
            requested.display()
        )
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    use clap::{CommandFactory, Parser};

    use super::*;

    fn write_reconcile_resource_manifest(directory: &Path) -> PathBuf {
        let path = directory.join("resources.json");
        fs::write(
            &path,
            serde_json::to_vec(&json!({
                "schema_version": 1,
                "resources": [{
                    "id": "service:zulip",
                    "services": [{
                        "scope": "system",
                        "unit": "zulip.service"
                    }]
                }]
            }))
            .unwrap(),
        )
        .unwrap();
        path
    }

    fn desired_resource(
        generation: u64,
        state: DesiredResourceStateKind,
        hold_epoch: Option<&str>,
    ) -> DesiredResourceState {
        DesiredResourceState {
            id: "service:zulip".to_owned(),
            state,
            projection_id: "move-1".to_owned(),
            intent_digest: "a".repeat(64),
            phase: format!("opaque-{generation}"),
            projection_digest: format!("{:064x}", generation),
            generation,
            hold_epoch: hold_epoch.map(str::to_owned),
            transaction_id: hold_epoch.map(|_| "move-1--item-001".to_owned()),
            activation_job_id: if matches!(state, DesiredResourceStateKind::Active)
                && hold_epoch.is_some()
            {
                Some("move-1--item-001-cutover-activate-target".to_owned())
            } else {
                None
            },
            activation_requirement_kind: hold_epoch.map(|_| "opaque-proof".to_owned()),
            activation_requirement_digest: hold_epoch.map(|_| "b".repeat(64)),
        }
    }

    fn write_desired_manifest(directory: &Path, desired: DesiredResourceState) -> PathBuf {
        let path = directory.join("desired.json");
        fs::write(
            &path,
            serde_json::to_vec(&DesiredResourceStateManifest {
                schema_version: 1,
                resources: vec![desired],
            })
            .unwrap(),
        )
        .unwrap();
        path
    }

    fn fake_systemctl(directory: &Path) -> Systemctl {
        let path = directory.join("systemctl");
        fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        Systemctl::new(path)
    }

    #[test]
    fn parses_global_configuration_after_subcommands() {
        let cli = Cli::try_parse_from([
            "abird-host-agent",
            "hold",
            "status",
            "--resource",
            "service:zulip",
            "--state-dir",
            "/tmp/test-state",
            "--ssh-host-ed25519-public-key",
            "/var/lib/machine/ssh_host_ed25519_key.pub",
            "--json",
        ])
        .unwrap();
        assert_eq!(cli.state_dir, PathBuf::from("/tmp/test-state"));
        assert_eq!(
            cli.ssh_host_ed25519_public_key,
            PathBuf::from("/var/lib/machine/ssh_host_ed25519_key.pub")
        );
        assert!(cli.json);
    }

    #[test]
    fn desired_reconcile_replays_activation_interrupted_after_release() {
        let temp = tempfile::tempdir().unwrap();
        let resource_manifest = write_reconcile_resource_manifest(temp.path());
        let systemctl = fake_systemctl(temp.path());
        let state_root = temp.path().join("state");
        let store = StateStore::new(&state_root);
        let jobs = JobStore::new(&state_root);
        let receipts = DesiredResourceStateReceiptStore::new(&state_root);

        let held = desired_resource(1, DesiredResourceStateKind::Held, Some("target"));
        let held_manifest = write_desired_manifest(temp.path(), held.clone());
        execute_desired_resource_states(
            &held_manifest,
            &resource_manifest,
            &store,
            &jobs,
            &receipts,
            &systemctl,
        )
        .unwrap();
        assert!(store.status(&held.id).unwrap().held);

        // Simulate interruption after exact release/start but before the
        // desired-state receipt advances to the active generation.
        let declaration = held.hold_declaration_id().unwrap();
        let active = desired_resource(2, DesiredResourceStateKind::Active, Some("target"));
        store
            .activate_projected_and_apply(
                &held.id,
                active.transaction_id.as_deref().unwrap(),
                &declaration,
                &[ServiceTarget::system("zulip.service")],
                ActivationReleaseEvidence {
                    intent_digest: active.intent_digest.clone(),
                    projection_digest: active.projection_digest.clone(),
                    generation: active.generation,
                    activation_requirement_digest: active.activation_requirement_digest.clone(),
                },
                || Ok(()),
            )
            .unwrap();
        assert!(!store.status(&held.id).unwrap().held);
        assert_eq!(receipts.read(&held.id).unwrap().unwrap().desired, held);
        let release = store
            .declaration_release(&active.id, &declaration)
            .unwrap()
            .unwrap();
        assert_eq!(
            release.projection.unwrap().projection_digest,
            active.projection_digest
        );

        let active_manifest = write_desired_manifest(temp.path(), active.clone());
        execute_desired_resource_states(
            &active_manifest,
            &resource_manifest,
            &store,
            &jobs,
            &receipts,
            &systemctl,
        )
        .unwrap();
        assert_eq!(receipts.read(&active.id).unwrap().unwrap().desired, active);
    }

    #[test]
    fn desired_reconcile_issues_exact_activation_from_projected_requirement() {
        let temp = tempfile::tempdir().unwrap();
        let resource_manifest = write_reconcile_resource_manifest(temp.path());
        let systemctl = fake_systemctl(temp.path());
        let state_root = temp.path().join("state");
        let store = StateStore::new(&state_root);
        let jobs = JobStore::new(&state_root);
        let receipts = DesiredResourceStateReceiptStore::new(&state_root);

        let held = desired_resource(1, DesiredResourceStateKind::Held, Some("target"));
        execute_desired_resource_states(
            &write_desired_manifest(temp.path(), held.clone()),
            &resource_manifest,
            &store,
            &jobs,
            &receipts,
            &systemctl,
        )
        .unwrap();

        let active = desired_resource(2, DesiredResourceStateKind::Active, Some("target"));
        execute_desired_resource_states(
            &write_desired_manifest(temp.path(), active.clone()),
            &resource_manifest,
            &store,
            &jobs,
            &receipts,
            &systemctl,
        )
        .unwrap();

        assert!(!store.status(&held.id).unwrap().held);
        let evidence = ActivationReleaseEvidence {
            intent_digest: active.intent_digest.clone(),
            projection_digest: active.projection_digest.clone(),
            generation: active.generation,
            activation_requirement_digest: active.activation_requirement_digest.clone(),
        };
        let release = store
            .declaration_release(&held.id, &held.hold_declaration_id().unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(release.projection.as_ref(), Some(&evidence));
        assert!(
            store
                .activation_authorization_path(&held.id)
                .try_exists()
                .unwrap()
        );
        assert_eq!(receipts.read(&active.id).unwrap().unwrap().desired, active);
        let job = jobs
            .status("move-1--item-001-cutover-activate-target")
            .unwrap();
        assert_eq!(job.status, JobStatus::Succeeded);
        assert_eq!(job.spec.transaction_id, "move-1--item-001");

        // A controller attaching after deploy sees the same terminal job, and
        // another deploy is an exact no-op rather than a second activation.
        execute_desired_resource_states(
            &write_desired_manifest(temp.path(), active),
            &resource_manifest,
            &store,
            &jobs,
            &receipts,
            &systemctl,
        )
        .unwrap();
        assert_eq!(
            jobs.status("move-1--item-001-cutover-activate-target")
                .unwrap()
                .attempts,
            1
        );
    }

    #[test]
    fn early_projected_hold_atomically_claims_a_bootstrap_latch() {
        let temp = tempfile::tempdir().unwrap();
        let resource_manifest = write_reconcile_resource_manifest(temp.path());
        let systemctl = fake_systemctl(temp.path());
        let store = StateStore::new(temp.path().join("state"));
        let resource = "service:zulip";
        store
            .declare_and_apply(
                resource,
                "zulip-target-bootstrap-v1",
                vec![ServiceTarget::system("zulip.service")],
                |_| Ok(()),
            )
            .unwrap();
        let desired = desired_resource(1, DesiredResourceStateKind::Held, Some("hold-v1"));

        execute_desired_resource_holds(
            &write_desired_manifest(temp.path(), desired.clone()),
            &resource_manifest,
            &store,
            &systemctl,
        )
        .unwrap();

        let hold = store.status(resource).unwrap().hold.unwrap();
        assert_eq!(
            hold.transaction_id,
            desired.transaction_id.as_deref().unwrap()
        );
        assert_eq!(
            hold.declaration_id,
            Some(desired.hold_declaration_id().unwrap())
        );
    }

    #[test]
    fn desired_unheld_releases_without_creating_activation_authority() {
        let temp = tempfile::tempdir().unwrap();
        let resource_manifest = write_reconcile_resource_manifest(temp.path());
        let systemctl = fake_systemctl(temp.path());
        let state_root = temp.path().join("state");
        let store = StateStore::new(&state_root);
        let jobs = JobStore::new(&state_root);
        let receipts = DesiredResourceStateReceiptStore::new(&state_root);
        let held = desired_resource(1, DesiredResourceStateKind::Held, Some("hold-v1"));
        execute_desired_resource_states(
            &write_desired_manifest(temp.path(), held.clone()),
            &resource_manifest,
            &store,
            &jobs,
            &receipts,
            &systemctl,
        )
        .unwrap();

        let mut unheld = desired_resource(2, DesiredResourceStateKind::Unheld, Some("hold-v1"));
        unheld.activation_requirement_kind = None;
        unheld.activation_requirement_digest = None;
        let output = execute_desired_resource_states(
            &write_desired_manifest(temp.path(), unheld.clone()),
            &resource_manifest,
            &store,
            &jobs,
            &receipts,
            &systemctl,
        )
        .unwrap();

        assert!(!store.status(&unheld.id).unwrap().held);
        assert_eq!(
            output
                .value
                .pointer("/result/resources/0/result/release_job/result/release/services_started",),
            Some(&json!(false))
        );
        assert!(
            !store
                .activation_authorization_path(&unheld.id)
                .try_exists()
                .unwrap()
        );
        let release = store
            .declaration_release(&unheld.id, &unheld.hold_declaration_id().unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(
            release.projection.unwrap().activation_requirement_digest,
            None
        );
        assert_eq!(
            jobs.status(&projected_release_job_id(
                &unheld.projection_id,
                &unheld.id,
                unheld.hold_epoch.as_deref().unwrap(),
            ))
            .unwrap()
            .status,
            JobStatus::Succeeded
        );
        assert_eq!(receipts.read(&unheld.id).unwrap().unwrap().desired, unheld);
    }

    #[test]
    fn desired_reconcile_adopts_the_controller_activation_job() {
        let temp = tempfile::tempdir().unwrap();
        let resource_manifest = write_reconcile_resource_manifest(temp.path());
        let systemctl = fake_systemctl(temp.path());
        let state_root = temp.path().join("state");
        let store = StateStore::new(&state_root);
        let jobs = JobStore::new(&state_root);
        let receipts = DesiredResourceStateReceiptStore::new(&state_root);

        let held = desired_resource(1, DesiredResourceStateKind::Held, Some("target"));
        execute_desired_resource_states(
            &write_desired_manifest(temp.path(), held),
            &resource_manifest,
            &store,
            &jobs,
            &receipts,
            &systemctl,
        )
        .unwrap();

        let active = desired_resource(2, DesiredResourceStateKind::Active, Some("target"));
        let resources = ResourceManifest::load(&resource_manifest).unwrap();
        let spec =
            desired_activation_job_spec(&active, resources.resource("service:zulip").unwrap())
                .unwrap();
        jobs.submit(spec.clone()).unwrap();
        let controller_job = jobs
            .run_job(&spec.job_id, |spec| {
                execute_job_spec(spec, &store, &systemctl)
            })
            .unwrap();
        assert_eq!(controller_job.status, JobStatus::Succeeded);

        execute_desired_resource_states(
            &write_desired_manifest(temp.path(), active.clone()),
            &resource_manifest,
            &store,
            &jobs,
            &receipts,
            &systemctl,
        )
        .unwrap();
        assert_eq!(receipts.read(&active.id).unwrap().unwrap().desired, active);
        assert_eq!(jobs.status(&spec.job_id).unwrap().attempts, 1);
    }

    #[test]
    fn desired_reconcile_rejects_epoch_mismatch_without_releasing_hold() {
        let temp = tempfile::tempdir().unwrap();
        let resource_manifest = write_reconcile_resource_manifest(temp.path());
        let systemctl = fake_systemctl(temp.path());
        let state_root = temp.path().join("state");
        let store = StateStore::new(&state_root);
        let jobs = JobStore::new(&state_root);
        let receipts = DesiredResourceStateReceiptStore::new(&state_root);
        let first = desired_resource(1, DesiredResourceStateKind::Held, Some("source-1"));
        let first_manifest = write_desired_manifest(temp.path(), first.clone());
        execute_desired_resource_states(
            &first_manifest,
            &resource_manifest,
            &store,
            &jobs,
            &receipts,
            &systemctl,
        )
        .unwrap();

        let mismatch = desired_resource(2, DesiredResourceStateKind::Held, Some("source-2"));
        let mismatch_manifest = write_desired_manifest(temp.path(), mismatch);
        assert!(
            execute_desired_resource_states(
                &mismatch_manifest,
                &resource_manifest,
                &store,
                &jobs,
                &receipts,
                &systemctl,
            )
            .is_err()
        );
        let hold = store.status(&first.id).unwrap().hold.unwrap();
        assert_eq!(
            hold.declaration_id.as_deref(),
            first.hold_declaration_id().as_deref()
        );
    }

    #[test]
    fn desired_reconcile_rejects_missing_activation_requirement_before_mutation() {
        let temp = tempfile::tempdir().unwrap();
        let resource_manifest = write_reconcile_resource_manifest(temp.path());
        let systemctl = fake_systemctl(temp.path());
        let state_root = temp.path().join("state");
        let store = StateStore::new(&state_root);
        let jobs = JobStore::new(&state_root);
        let receipts = DesiredResourceStateReceiptStore::new(&state_root);
        let mut active = desired_resource(2, DesiredResourceStateKind::Active, Some("target"));
        active.activation_requirement_kind = None;
        active.activation_requirement_digest = None;
        let active_manifest = write_desired_manifest(temp.path(), active);

        assert!(
            execute_desired_resource_states(
                &active_manifest,
                &resource_manifest,
                &store,
                &jobs,
                &receipts,
                &systemctl,
            )
            .is_err()
        );
        assert!(!store.status("service:zulip").unwrap().held);
    }

    #[test]
    fn ssh_host_key_uses_the_configured_ed25519_public_path() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("host-key.pub");
        fs::write(&path, "ssh-ed25519 configured-key host\n").unwrap();

        let output = ssh_host_key(&path).unwrap();
        assert_eq!(
            output.value["result"]["public_key"],
            "ssh-ed25519 configured-key"
        );

        fs::write(&path, "ssh-rsa wrong-key host\n").unwrap();
        assert!(ssh_host_key(&path).is_err());
        assert!(ssh_host_key(Path::new("relative-key.pub")).is_err());
    }

    #[test]
    fn public_help_shows_only_the_small_operator_surface() {
        let mut command = Cli::command();
        let help = command.render_long_help().to_string();
        for public in ["status", "logs", "hold", "unit", "resource", "job"] {
            assert!(help.contains(public), "missing public command {public}");
        }
        for hidden in [
            "\n  service ",
            "\n  data ",
            "\n  _transport ",
            "\n  _reconcile ",
            "\n  maintenance ",
            "--systemctl",
            "--journalctl",
            "--runuser",
            "--podman",
            "--nix-collect-garbage",
        ] {
            assert!(!help.contains(hidden), "leaked hidden surface {hidden}");
        }

        let mut submit = Cli::command()
            .find_subcommand("job")
            .unwrap()
            .find_subcommand("submit")
            .unwrap()
            .clone();
        let submit_help = submit.render_long_help().to_string();
        assert!(submit_help.contains("--spec <FILE>"));
        assert!(submit_help.contains("--defer"));
        for legacy in [
            "--operation",
            "--broker-copy",
            "--migrate-instance",
            "--named-operation",
            "--target-endpoint",
        ] {
            assert!(!submit_help.contains(legacy));
        }
    }

    #[test]
    fn parses_unified_logs_and_rejects_ambiguous_selectors() {
        for arguments in [
            vec!["abird-host-agent", "logs", "--follow"],
            vec![
                "abird-host-agent",
                "logs",
                "--resource",
                "service:zulip",
                "--follow",
            ],
            vec![
                "abird-host-agent",
                "logs",
                "--unit",
                "zulip.service",
                "--scope",
                "user",
                "--user",
                "abird",
                "--follow",
            ],
        ] {
            let cli = Cli::try_parse_from(arguments).unwrap();
            assert!(cli.streams_output());
        }
        assert!(
            Cli::try_parse_from([
                "abird-host-agent",
                "logs",
                "--resource",
                "service:zulip",
                "--unit",
                "zulip.service",
            ])
            .is_err()
        );
    }

    #[test]
    fn hidden_rolling_compatibility_aliases_still_parse() {
        for arguments in [
            vec![
                "abird-host-agent",
                "service",
                "status",
                "--unit",
                "zulip.service",
            ],
            vec![
                "abird-host-agent",
                "data",
                "manifest",
                "--diagnostic-path",
                "/var/lib/zulip",
            ],
            vec![
                "abird-host-agent",
                "hold",
                "apply",
                "--resource",
                "service:zulip",
            ],
            vec!["abird-host-agent", "job", "run-pending"],
            vec!["abird-host-agent", "job", "status", "--job-id", "job-1"],
        ] {
            Cli::try_parse_from(arguments).unwrap();
        }
        Cli::try_parse_from([
            "abird-host-agent",
            "_reconcile",
            "hold",
            "declare",
            "--resource",
            "service:zulip",
            "--declaration",
            "bootstrap-1",
        ])
        .unwrap();
        Cli::try_parse_from(["abird-host-agent", "_reconcile", "jobs"]).unwrap();
        Cli::try_parse_from([
            "abird-host-agent",
            "_reconcile",
            "desired-resource-states",
            "--manifest",
            "/etc/abird-host-agent/desired-resource-states.json",
        ])
        .unwrap();
        Cli::try_parse_from([
            "abird-host-agent",
            "_transport",
            "manifest",
            "--diagnostic-path",
            "/var/lib/zulip",
        ])
        .unwrap();
    }

    #[test]
    fn data_manifest_uses_the_canonical_nested_response_contract() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("data");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("value"), b"zulip").unwrap();

        let cli = Cli::try_parse_from([
            "abird-host-agent",
            "--json",
            "data",
            "manifest",
            "--diagnostic-path",
            root.to_str().unwrap(),
        ])
        .unwrap();
        let output = execute(cli).unwrap();

        assert_eq!(output.value["operation"], "data_manifest");
        assert_eq!(output.value["result"]["manifest"]["schema_version"], 1);
        assert!(output.value["result"]["roots"].is_null());
    }

    #[test]
    fn guarded_rsync_receiver_requires_an_explicit_exact_destination() {
        let destination = Path::new("/var/lib/abird/zulip");
        let visible_destination = vec![
            "--server".to_owned(),
            "-logDtpre.iLfxCIvu".to_owned(),
            ".".to_owned(),
            "/var/lib/abird/zulip/".to_owned(),
        ];
        validate_rsync_receiver_args(destination, &visible_destination).unwrap();

        let protected_args = vec!["--server".to_owned(), "-slHogDtpAXre.iLsfxCIvu".to_owned()];
        assert!(
            validate_rsync_receiver_args(destination, &protected_args)
                .unwrap_err()
                .to_string()
                .contains("protected-args")
        );

        let wrong_destination = vec![
            "--server".to_owned(),
            "-logDtpre.iLfxCIvu".to_owned(),
            ".".to_owned(),
            "/var/lib/abird/other/".to_owned(),
        ];
        assert!(validate_rsync_receiver_args(destination, &wrong_destination).is_err());
    }

    #[test]
    fn guarded_receiver_owns_its_declared_rsync_executable() {
        let temp = tempfile::tempdir().unwrap();
        let destination = temp.path().join("zulip");
        let manifest_path = temp.path().join("resources.json");
        let declared_rsync = temp.path().join("declared-rsync");
        fs::create_dir(&destination).unwrap();
        fs::write(
            &manifest_path,
            serde_json::to_vec(&json!({
                "schema_version": 1,
                "backup_root": temp.path().join("backups"),
                "rsync_program": declared_rsync.clone(),
                "tar_program": "/run/current-system/sw/bin/tar",
                "resources": [{
                    "id": "service:zulip",
                    "data_paths": [destination.clone()]
                }]
            }))
            .unwrap(),
        )
        .unwrap();
        let error = receive_rsync(
            DataReceiveRsyncArgs {
                destination: destination.clone(),
                _legacy_rsync_program: Some(PathBuf::from("/peer/selected/rsync")),
                excludes: Vec::new(),
                server_args: vec![
                    "--server".to_owned(),
                    "-logDtpre.iLfxCIvu".to_owned(),
                    ".".to_owned(),
                    format!("{}/", destination.display()),
                ],
            },
            &manifest_path,
        )
        .unwrap_err();

        let error = format!("{error:#}");
        assert!(error.contains(declared_rsync.to_str().unwrap()));
        assert!(!error.contains("/peer/selected/rsync"));
    }

    #[test]
    fn top_level_status_summarizes_validated_durable_state() {
        let temp = tempfile::tempdir().unwrap();
        let manifest_path = temp.path().join("resources.json");
        let state_dir = temp.path().join("state");
        fs::write(
            &manifest_path,
            r#"{
              "schema_version": 1,
              "resources": [{
                "id": "service:zulip",
                "data_paths": ["/var/lib/zulip"]
              }]
            }"#,
        )
        .unwrap();
        StateStore::new(&state_dir)
            .acquire_and_apply("service:zulip", "tx-1", Vec::new(), |_| Ok(()))
            .unwrap();
        let cli = Cli::try_parse_from([
            "abird-host-agent",
            "--state-dir",
            state_dir.to_str().unwrap(),
            "--resource-manifest",
            manifest_path.to_str().unwrap(),
            "status",
        ])
        .unwrap();
        let output = execute(cli).unwrap();
        assert_eq!(output.value["operation"], "agent_status");
        assert_eq!(output.value["result"]["resources"], 1);
        assert_eq!(output.value["result"]["holds"], 1);
        assert_eq!(output.value["result"]["jobs"]["total"], 0);
    }

    #[test]
    fn parses_output_for_every_log_scope_and_follow_mode() {
        for arguments in [
            vec!["abird-host-agent", "logs", "--output", "json"],
            vec![
                "abird-host-agent",
                "service",
                "logs",
                "--unit",
                "zulip.service",
                "--follow",
                "--output",
                "text",
            ],
            vec![
                "abird-host-agent",
                "resource",
                "logs",
                "--resource",
                "service:zulip",
                "-f",
                "--output",
                "json",
            ],
        ] {
            let cli = Cli::try_parse_from(arguments).unwrap();
            assert!(cli.streams_output());
        }
    }

    #[test]
    fn rejects_single_document_json_for_streamed_logs() {
        let cli = Cli::try_parse_from([
            "abird-host-agent",
            "--json",
            "--journalctl",
            "/bin/true",
            "logs",
        ])
        .unwrap();

        assert_eq!(
            execute(cli).unwrap_err().to_string(),
            "--json cannot be combined with logs; use --output json"
        );
    }

    #[test]
    fn forced_transfer_server_accepts_only_pinned_read_only_requests() {
        let root = Path::new("/var/lib/abird/zulip");
        let tar = Path::new("/nix/store/tar/bin/tar");
        let manifest = vec![
            "/run/current-system/sw/bin/abird-host-agent".to_owned(),
            "--json".to_owned(),
            "data".to_owned(),
            "manifest".to_owned(),
            "--diagnostic-path".to_owned(),
            root.display().to_string(),
        ];
        assert_eq!(
            manifest_request(&manifest),
            Some((root.to_path_buf(), Vec::new()))
        );

        let archive = vec![
            tar.display().to_string(),
            "--acls".to_owned(),
            "--xattrs".to_owned(),
            "--numeric-owner".to_owned(),
            "--same-owner".to_owned(),
            "--same-permissions".to_owned(),
            "-C".to_owned(),
            root.display().to_string(),
            "-cpf".to_owned(),
            "-".to_owned(),
            ".".to_owned(),
        ];
        assert_eq!(
            tar_request(&archive, tar),
            Some((root.to_path_buf(), Vec::new()))
        );

        let rsync = vec![
            "rsync".to_owned(),
            "--server".to_owned(),
            "--sender".to_owned(),
            "-logDtpre.iLsfxCIvu".to_owned(),
            ".".to_owned(),
            format!("{}/", root.display()),
        ];
        assert_eq!(rsync_request_path(&rsync), Some(Path::new(&rsync[5])));
        require_declared_data_path(&[root.to_path_buf()], Path::new(&rsync[5])).unwrap();

        let mut escaped = rsync.clone();
        escaped[4] = "--files-from=/etc/passwd".to_owned();
        assert!(rsync_request_path(&escaped).is_none());
        assert!(require_declared_data_path(&[root.to_path_buf()], Path::new("/etc")).is_err());
    }

    #[test]
    fn job_materialization_requires_exactly_one_operation_selector() {
        let base = [
            "abird-host-agent",
            "job",
            "_materialize",
            "--job-id",
            "copy-1",
            "--transaction",
            "tx-1",
            "--resource",
            "service:zulip",
        ];
        let mut valid = base.to_vec();
        valid.extend(["--transfer", "source-to-target"]);
        Cli::try_parse_from(valid).unwrap();

        let mut conflicting = base.to_vec();
        conflicting.extend(["--transfer", "source-to-target", "--file-state", "target"]);
        assert!(Cli::try_parse_from(conflicting).is_err());

        let mut broker = base.to_vec();
        broker.extend([
            "--broker-copy",
            r#"{"host":"source","ssh_program":"/bin/ssh"}"#,
            "--target-endpoint",
            r#"{"host":"target","ssh_program":"/bin/ssh"}"#,
            "--backup-source",
        ]);
        Cli::try_parse_from(broker).unwrap();

        let mut restore = base.to_vec();
        restore.extend(["--restore", "--active-service", "user:abird:zulip.service"]);
        Cli::try_parse_from(restore).unwrap();
    }

    #[test]
    fn projection_hold_epochs_are_qualified_once_for_new_and_legacy_specs() {
        let base = json!({
            "schema_version": 1,
            "job_id": "hold-1",
            "transaction_id": "tx-1",
            "resource": "service:zulip",
            "operation": { "kind": "hold" },
            "expected_state": "any"
        });
        let mut current = base.clone();
        current["projection"] = json!({
            "intent_digest": "a".repeat(64),
            "projection_digest": "b".repeat(64),
            "generation": 3,
            "hold_epoch": "target:g3"
        });
        let current: JobSpec = serde_json::from_value(current).unwrap();
        assert_eq!(
            projection_hold_declaration_id(&current).as_deref(),
            Some("tx-1:target:g3")
        );

        let mut legacy = base;
        legacy["projection"] = json!({
            "transaction_digest": "a".repeat(64),
            "projection_digest": "b".repeat(64),
            "generation": 3,
            "hold_declaration_id": "tx-1:target:g3"
        });
        let legacy: JobSpec = serde_json::from_value(legacy).unwrap();
        assert_eq!(
            projection_hold_declaration_id(&legacy).as_deref(),
            Some("tx-1:target:g3")
        );
    }

    #[test]
    fn stable_job_spec_submission_persists_the_exact_versioned_spec() {
        let temp = tempfile::tempdir().unwrap();
        let state_dir = temp.path().join("state");
        let spec_path = temp.path().join("job.json");
        let spec = JobSpec {
            schema_version: 1,
            job_id: "reserve-1".to_owned(),
            transaction_id: "tx-1".to_owned(),
            projection: None,
            resource: "service:zulip".to_owned(),
            operation: JobOperation::Reserve,
            expected_state: ExpectedState::Any,
            services: Vec::new(),
            data_paths: Vec::new(),
            data_root_plan: Vec::new(),
            argv: None,
            readiness: Vec::new(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            broker_transfer: None,
            file_state: None,
            instance: None,
            instance_migration: None,
            deployment: None,
            nixbot_deploy: None,
        };
        fs::write(&spec_path, serde_json::to_vec_pretty(&spec).unwrap()).unwrap();
        let cli = Cli::try_parse_from([
            "abird-host-agent",
            "--state-dir",
            state_dir.to_str().unwrap(),
            "job",
            "submit",
            "--spec",
            spec_path.to_str().unwrap(),
            "--defer",
        ])
        .unwrap();
        execute(cli).unwrap();

        let stored = JobStore::new(&state_dir).status("reserve-1").unwrap();
        assert_eq!(stored.spec, spec);
    }

    #[test]
    fn stable_job_spec_rejects_unknown_versions_and_selector_mixing() {
        let temp = tempfile::tempdir().unwrap();
        let state_dir = temp.path().join("state");
        let spec_path = temp.path().join("job.json");
        fs::write(
            &spec_path,
            serde_json::to_vec(&json!({
                "schema_version": 2,
                "job_id": "future-1",
                "transaction_id": "tx-1",
                "resource": "service:zulip",
                "operation": {"kind": "reserve"},
                "expected_state": "any"
            }))
            .unwrap(),
        )
        .unwrap();
        let cli = Cli::try_parse_from([
            "abird-host-agent",
            "--state-dir",
            state_dir.to_str().unwrap(),
            "job",
            "submit",
            "--spec",
            spec_path.to_str().unwrap(),
            "--defer",
        ])
        .unwrap();
        assert!(
            execute(cli)
                .unwrap_err()
                .to_string()
                .contains("schema version")
        );

        assert!(
            Cli::try_parse_from([
                "abird-host-agent",
                "job",
                "submit",
                "--spec",
                spec_path.to_str().unwrap(),
                "--job-id",
                "legacy-1",
                "--operation",
                "reserve",
            ])
            .is_err()
        );
    }

    #[test]
    fn release_does_not_invoke_systemctl() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        store
            .acquire_and_apply("service:zulip", "tx-1", Vec::new(), |_| Ok(()))
            .unwrap();
        let cli = Cli::try_parse_from([
            "abird-host-agent",
            "--state-dir",
            temp.path().to_str().unwrap(),
            "--systemctl",
            "/does/not/exist",
            "hold",
            "release",
            "--resource",
            "service:zulip",
            "--transaction",
            "tx-1",
        ])
        .unwrap();
        execute(cli).unwrap();
    }

    #[test]
    fn hold_acquire_resolves_an_immutable_resource_declaration() {
        let temp = tempfile::tempdir().unwrap();
        let manifest_path = temp.path().join("resources.json");
        fs::write(
            &manifest_path,
            r#"{
              "schema_version": 1,
              "resources": [{
                "id": "service:zulip",
                "data_paths": ["/var/lib/zulip"]
              }]
            }"#,
        )
        .unwrap();
        let cli = Cli::try_parse_from([
            "abird-host-agent",
            "--state-dir",
            temp.path().join("state").to_str().unwrap(),
            "--resource-manifest",
            manifest_path.to_str().unwrap(),
            "hold",
            "acquire",
            "--resource",
            "service:zulip",
            "--transaction",
            "tx-1",
        ])
        .unwrap();

        execute(cli).unwrap();
        let hold = StateStore::new(temp.path().join("state"))
            .status("service:zulip")
            .unwrap()
            .hold
            .unwrap();
        assert_eq!(hold.transaction_id, "tx-1");
        assert!(hold.services.is_empty());
    }

    #[test]
    fn resource_start_is_rejected_before_systemctl_when_held() {
        let temp = tempfile::tempdir().unwrap();
        let state_dir = temp.path().join("state");
        let manifest_path = temp.path().join("resources.json");
        fs::write(
            &manifest_path,
            r#"{
              "schema_version": 1,
              "resources": [{
                "id": "service:zulip",
                "services": [{"scope":"system","unit":"zulip.service"}]
              }]
            }"#,
        )
        .unwrap();
        StateStore::new(&state_dir)
            .acquire_and_apply(
                "service:zulip",
                "tx-1",
                vec![ServiceTarget::system("zulip.service")],
                |_| Ok(()),
            )
            .unwrap();
        let cli = Cli::try_parse_from([
            "abird-host-agent",
            "--state-dir",
            state_dir.to_str().unwrap(),
            "--resource-manifest",
            manifest_path.to_str().unwrap(),
            "--systemctl",
            "/does/not/exist",
            "resource",
            "start",
            "--resource",
            "service:zulip",
        ])
        .unwrap();

        let error = execute(cli).unwrap_err();
        assert!(error.to_string().contains("refusing to start resource"));
    }

    #[test]
    fn resource_restart_and_reload_are_rejected_while_held() {
        let temp = tempfile::tempdir().unwrap();
        let state_dir = temp.path().join("state");
        let manifest_path = temp.path().join("resources.json");
        fs::write(
            &manifest_path,
            r#"{
              "schema_version": 1,
              "resources": [{
                "id": "service:zulip",
                "services": [
                  {"scope":"system","unit":"zulip-web.service"},
                  {"scope":"system","unit":"zulip-worker.service"}
                ]
              }]
            }"#,
        )
        .unwrap();
        StateStore::new(&state_dir)
            .acquire_and_apply("service:zulip", "tx-1", Vec::new(), |_| Ok(()))
            .unwrap();

        for operation in ["restart", "reload"] {
            let cli = Cli::try_parse_from([
                "abird-host-agent",
                "--state-dir",
                state_dir.to_str().unwrap(),
                "--resource-manifest",
                manifest_path.to_str().unwrap(),
                "--systemctl",
                "/does/not/exist",
                "resource",
                operation,
                "--resource",
                "service:zulip",
            ])
            .unwrap();
            let error = execute(cli).unwrap_err();
            assert!(error.to_string().contains("held by transaction"));
        }
    }

    #[test]
    fn explicit_release_job_removes_hold_without_starting_services() {
        let temp = tempfile::tempdir().unwrap();
        let state_dir = temp.path().join("state");
        let store = StateStore::new(&state_dir);
        store
            .acquire_and_apply(
                "service:zulip",
                "tx-1",
                vec![ServiceTarget::system("zulip.service")],
                |_| Ok(()),
            )
            .unwrap();
        let jobs = JobStore::new(&state_dir);
        let submitted = jobs
            .submit(JobSpec {
                schema_version: 1,
                job_id: "release-1".to_owned(),
                transaction_id: "tx-1".to_owned(),
                projection: None,
                resource: "service:zulip".to_owned(),
                operation: JobOperation::Release,
                expected_state: ExpectedState::Any,
                services: Vec::new(),
                data_paths: Vec::new(),
                data_root_plan: Vec::new(),
                argv: None,
                readiness: Vec::new(),
                transfer: None,
                resource_transfers: Vec::new(),
                backup_consistency: None,
                broker_transfer: None,
                file_state: None,
                instance: None,
                instance_migration: None,
                deployment: None,
                nixbot_deploy: None,
            })
            .unwrap();
        assert!(submitted.changed);

        let systemctl = Systemctl::new("/does/not/exist");
        let job = jobs
            .run_job("release-1", |spec| {
                execute_job_spec(spec, &store, &systemctl)
            })
            .unwrap();
        assert_eq!(job.status, crate::job::JobStatus::Succeeded);
        assert!(!store.status("service:zulip").unwrap().held);
    }

    #[test]
    fn activation_job_releases_and_starts_as_one_recoverable_operation() {
        let temp = tempfile::tempdir().unwrap();
        let state_dir = temp.path().join("state");
        let service = ServiceTarget::system("zulip.service");
        let store = StateStore::new(&state_dir);
        store
            .acquire_and_apply("service:zulip", "tx-1", vec![service.clone()], |_| Ok(()))
            .unwrap();
        let jobs = JobStore::new(&state_dir);
        jobs.submit(JobSpec {
            schema_version: 1,
            job_id: "activate-1".to_owned(),
            transaction_id: "tx-1".to_owned(),
            projection: None,
            resource: "service:zulip".to_owned(),
            operation: JobOperation::Activate,
            expected_state: ExpectedState::Any,
            services: vec![service],
            data_paths: Vec::new(),
            data_root_plan: Vec::new(),
            argv: None,
            readiness: Vec::new(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            broker_transfer: None,
            file_state: None,
            instance: None,
            instance_migration: None,
            deployment: None,
            nixbot_deploy: None,
        })
        .unwrap();

        let fake_systemctl = temp.path().join("systemctl");
        fs::write(&fake_systemctl, "#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(&fake_systemctl, fs::Permissions::from_mode(0o700)).unwrap();
        let systemctl = Systemctl::new(fake_systemctl);
        let job = jobs
            .run_job("activate-1", |spec| {
                execute_job_spec(spec, &store, &systemctl)
            })
            .unwrap();
        assert_eq!(job.status, crate::job::JobStatus::Succeeded);
        assert!(!store.status("service:zulip").unwrap().held);
        assert_eq!(job.result.unwrap()["services"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn file_state_job_reloads_or_restarts_consumers() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("route");
        let calls = temp.path().join("systemctl-calls");
        let fake_systemctl = temp.path().join("systemctl");
        fs::write(
            &fake_systemctl,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\n",
                calls.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&fake_systemctl, fs::Permissions::from_mode(0o700)).unwrap();
        let spec = JobSpec {
            schema_version: 1,
            job_id: "route-1".to_owned(),
            transaction_id: "move-1".to_owned(),
            projection: None,
            resource: "service:abird-nginx".to_owned(),
            operation: JobOperation::FileState {
                name: "route-corp".to_owned(),
            },
            expected_state: ExpectedState::Any,
            services: Vec::new(),
            data_paths: Vec::new(),
            data_root_plan: Vec::new(),
            argv: None,
            readiness: Vec::new(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            broker_transfer: None,
            file_state: Some(crate::file_state::FileStateDefinition {
                path: state_path.clone(),
                content: "corp\n".to_owned(),
                mode: 0o644,
                reload_services: vec![
                    ServiceTarget::new(
                        crate::service::ServiceScope::User,
                        Some("abird".to_owned()),
                        "abird-nginx.service".to_owned(),
                    )
                    .unwrap(),
                ],
                expected_previous_sha256: None,
                accepted_previous_sha256: Vec::new(),
                validation_argv: Vec::new(),
            }),
            instance: None,
            instance_migration: None,
            deployment: None,
            nixbot_deploy: None,
        };

        let execution = execute_job_spec(
            &spec,
            &StateStore::new(temp.path().join("state")),
            &Systemctl::new(fake_systemctl),
        )
        .unwrap();

        assert!(execution.error.is_none());
        assert_eq!(fs::read_to_string(state_path).unwrap(), "corp\n");
        assert_eq!(
            fs::read_to_string(calls).unwrap(),
            "--user --machine abird@ try-reload-or-restart -- abird-nginx.service\n"
        );
    }

    #[test]
    fn restore_job_starts_only_services_active_before_backup() {
        let temp = tempfile::tempdir().unwrap();
        let state_dir = temp.path().join("state");
        let active = ServiceTarget::system("active.service");
        let inactive = ServiceTarget::system("inactive.service");
        let services = vec![active.clone(), inactive];
        let store = StateStore::new(&state_dir);
        store
            .acquire_and_apply("host:demo", "backup-1", services.clone(), |_| Ok(()))
            .unwrap();
        let jobs = JobStore::new(&state_dir);
        jobs.submit(JobSpec {
            schema_version: 1,
            job_id: "restore-1".to_owned(),
            transaction_id: "backup-1".to_owned(),
            projection: None,
            resource: "host:demo".to_owned(),
            operation: JobOperation::Restore {
                active_services: vec![active],
            },
            expected_state: ExpectedState::Any,
            services,
            data_paths: Vec::new(),
            data_root_plan: Vec::new(),
            argv: None,
            readiness: Vec::new(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            broker_transfer: None,
            file_state: None,
            instance: None,
            instance_migration: None,
            deployment: None,
            nixbot_deploy: None,
        })
        .unwrap();

        let calls = temp.path().join("calls");
        let fake_systemctl = temp.path().join("systemctl");
        fs::write(
            &fake_systemctl,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\n",
                calls.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&fake_systemctl, fs::Permissions::from_mode(0o700)).unwrap();
        let systemctl = Systemctl::new(fake_systemctl);
        let job = jobs
            .run_job("restore-1", |spec| {
                execute_job_spec(spec, &store, &systemctl)
            })
            .unwrap();

        assert_eq!(job.status, crate::job::JobStatus::Succeeded);
        assert!(!store.status("host:demo").unwrap().held);
        let calls = fs::read_to_string(calls).unwrap();
        assert!(calls.contains("active.service"));
        assert!(!calls.contains("inactive.service"));
    }

    #[test]
    fn named_job_runs_only_static_argv_and_preserves_exit_details() {
        let temp = tempfile::tempdir().unwrap();
        let manifest_path = temp.path().join("resources.json");
        let executable = std::env::current_exe().unwrap();
        fs::write(
            &manifest_path,
            serde_json::to_vec(&json!({
                "schema_version": 1,
                "resources": [{
                    "id": "service:zulip",
                    "operations": {
                        "seed": {
                            "argv": [
                                executable,
                                "--definitely-not-a-libtest-option"
                            ]
                        }
                    }
                }]
            }))
            .unwrap(),
        )
        .unwrap();
        let operation = JobOperation::Named {
            name: "seed".to_owned(),
        };
        let inputs =
            resolve_job_inputs(&operation, "service:zulip", "seed-1", &manifest_path).unwrap();
        let spec = JobSpec {
            schema_version: 1,
            job_id: "seed-1".to_owned(),
            transaction_id: "tx-1".to_owned(),
            projection: None,
            resource: "service:zulip".to_owned(),
            operation,
            expected_state: ExpectedState::Any,
            services: Vec::new(),
            data_paths: Vec::new(),
            data_root_plan: Vec::new(),
            argv: inputs.argv,
            readiness: Vec::new(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            broker_transfer: None,
            file_state: None,
            instance: None,
            instance_migration: None,
            deployment: None,
            nixbot_deploy: None,
        };

        assert!(
            resolve_job_inputs(
                &JobOperation::Named {
                    name: "not-allowed".to_owned()
                },
                "service:zulip",
                "not-allowed-1",
                &manifest_path
            )
            .unwrap_err()
            .to_string()
            .contains("not allowlisted")
        );

        // Accepted jobs keep their resolved immutable argv even if the host's next
        // configuration generation changes the resource manifest.
        fs::write(&manifest_path, b"not valid JSON").unwrap();
        let execution = execute_named_operation(&spec).unwrap();
        assert!(execution.error.is_some());
        assert_eq!(execution.result["success"], false);
        assert!(execution.result["exit_code"].is_number());
    }

    #[test]
    fn backup_jobs_are_derived_from_data_paths() {
        let temp = tempfile::tempdir().unwrap();
        let manifest_path = temp.path().join("resources.json");
        let data_path = temp.path().join("zulip");
        let backup_root = temp.path().join("backups");
        fs::create_dir(&data_path).unwrap();
        fs::write(
            &manifest_path,
            serde_json::to_vec(&json!({
                "schema_version": 1,
                "backup_root": backup_root,
                "rsync_program": "/run/current-system/sw/bin/rsync",
                "tar_program": "/run/current-system/sw/bin/tar",
                "resources": [{
                    "id": "service:zulip",
                    "data_paths": [data_path],
                    "backup_consistency": "quiesced"
                }]
            }))
            .unwrap(),
        )
        .unwrap();

        let backup = resolve_job_inputs(
            &JobOperation::Backup,
            "service:zulip",
            "backup-1",
            &manifest_path,
        )
        .unwrap();
        assert_eq!(backup.backup_consistency, Some(BackupConsistency::Quiesced));
        assert!(
            backup.resource_transfers[0]
                .destination
                .starts_with(&backup_root)
        );
        assert!(
            backup.resource_transfers[0]
                .destination
                .ends_with("backup-1".to_owned() + data_path.to_str().unwrap())
        );

        let restore = resolve_job_inputs(
            &JobOperation::RestoreBackup {
                snapshot: "backup-1".to_owned(),
            },
            "service:zulip",
            "restore-1",
            &manifest_path,
        )
        .unwrap();
        assert_eq!(
            restore.backup_consistency,
            Some(BackupConsistency::Quiesced)
        );
        assert_eq!(restore.resource_transfers[0].destination, data_path);
        assert!(
            restore.resource_transfers[0]
                .source
                .starts_with(&backup_root)
        );

        let deletion = resolve_job_inputs(
            &JobOperation::DeleteBackup {
                snapshot: "backup-1".to_owned(),
            },
            "service:zulip",
            "delete-1",
            &manifest_path,
        )
        .unwrap();
        assert_eq!(deletion.data_paths.len(), 1);
        assert!(deletion.data_paths[0].starts_with(&backup_root));

        let outside = temp.path().join("outside");
        fs::create_dir(&outside).unwrap();
        let mut deletion_spec = JobSpec {
            schema_version: 1,
            job_id: "delete-1".to_owned(),
            transaction_id: "backup-1".to_owned(),
            projection: None,
            resource: "service:zulip".to_owned(),
            operation: JobOperation::DeleteBackup {
                snapshot: "backup-1".to_owned(),
            },
            expected_state: ExpectedState::Any,
            services: deletion.services,
            data_paths: deletion.data_paths,
            data_root_plan: Vec::new(),
            argv: None,
            readiness: Vec::new(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            broker_transfer: None,
            file_state: None,
            instance: None,
            instance_migration: None,
            deployment: None,
            nixbot_deploy: None,
        };
        deletion_spec.data_paths[0] = outside.clone();
        let state = StateStore::new(temp.path().join("state"));
        let systemctl = Systemctl::new("/does/not/exist");
        let error = execute_job_spec_with_progress(
            &deletion_spec,
            &state,
            &systemctl,
            &manifest_path,
            |_| Ok(()),
        )
        .unwrap_err();
        assert!(error.to_string().contains("immutable host declaration"));
        assert!(outside.exists());

        let manifest = ResourceManifest::load(&manifest_path).unwrap();
        let restore_plan = DataRootPlan {
            name: "path".to_owned(),
            source: restore.resource_transfers[0].source.clone(),
            target: restore.resource_transfers[0].destination.clone(),
            excludes: Vec::new(),
        };
        validate_backup_source_plans(
            &manifest,
            "service:zulip",
            std::slice::from_ref(&restore_plan),
        )
        .unwrap();
        let mut escaped = restore_plan;
        escaped.source = backup_root.join("other-resource/backup-1/zulip");
        assert!(validate_backup_source_plans(&manifest, "service:zulip", &[escaped]).is_err());
    }

    #[test]
    fn data_wipe_requires_its_hold_and_preserves_declared_excludes() {
        let temp = tempfile::tempdir().unwrap();
        let state_dir = temp.path().join("state");
        let manifest_path = temp.path().join("resources.json");
        let data_path = temp.path().join("zulip");
        fs::create_dir_all(data_path.join("runtime/cache")).unwrap();
        fs::write(data_path.join("database"), b"remove").unwrap();
        fs::write(data_path.join("runtime/cache/keep"), b"keep").unwrap();
        fs::write(
            &manifest_path,
            serde_json::to_vec(&json!({
                "schema_version": 1,
                "resources": [{
                    "id": "service:zulip",
                    "data_roots": [{
                        "name": "data",
                        "path": data_path,
                        "excludes": ["runtime/cache"]
                    }]
                }]
            }))
            .unwrap(),
        )
        .unwrap();

        let inputs = resolve_job_inputs(
            &JobOperation::WipeData,
            "service:zulip",
            "wipe-1",
            &manifest_path,
        )
        .unwrap();
        let root = ResourceManifest::load(&manifest_path)
            .unwrap()
            .resource("service:zulip")
            .unwrap()
            .effective_data_roots()
            .remove(0);
        let spec = JobSpec {
            schema_version: 1,
            job_id: "wipe-1".to_owned(),
            transaction_id: "wipe-owner".to_owned(),
            projection: None,
            resource: "service:zulip".to_owned(),
            operation: JobOperation::WipeData,
            expected_state: ExpectedState::Any,
            services: inputs.services,
            data_paths: inputs.data_paths,
            data_root_plan: vec![DataRootPlan {
                name: root.name,
                source: root.path.clone(),
                target: root.path,
                excludes: root.excludes,
            }],
            argv: None,
            readiness: Vec::new(),
            transfer: None,
            resource_transfers: Vec::new(),
            backup_consistency: None,
            broker_transfer: None,
            file_state: None,
            instance: None,
            instance_migration: None,
            deployment: None,
            nixbot_deploy: None,
        };
        let store = StateStore::new(&state_dir);
        let systemctl = Systemctl::new("/does/not/exist");

        let error =
            execute_job_spec_with_progress(&spec, &store, &systemctl, &manifest_path, |_| Ok(()))
                .unwrap_err();
        assert!(error.to_string().contains("requires resource"));
        assert!(data_path.join("database").exists());

        store
            .acquire_and_apply("service:zulip", "wipe-owner", Vec::new(), |_| Ok(()))
            .unwrap();
        let result =
            execute_job_spec_with_progress(&spec, &store, &systemctl, &manifest_path, |_| Ok(()))
                .unwrap();

        assert!(result.result["wipe"]["verified_empty"].as_bool().unwrap());
        assert!(!data_path.join("database").exists());
        assert_eq!(
            fs::read(data_path.join("runtime/cache/keep")).unwrap(),
            b"keep"
        );
        assert!(store.status("service:zulip").unwrap().held);
    }

    #[test]
    fn instance_archive_jobs_are_confined_to_the_resource_namespace() {
        let temp = tempfile::tempdir().unwrap();
        let manifest_path = temp.path().join("resources.json");
        let backup_root = temp.path().join("backups");
        fs::write(
            &manifest_path,
            serde_json::to_vec(&json!({
                "schema_version": 1,
                "backup_root": backup_root,
                "resources": []
            }))
            .unwrap(),
        )
        .unwrap();
        let resource = "instance:0123456789abcdef";
        let archive_root = backup_root
            .join(digest_bytes(resource.as_bytes()))
            .join("backup-1");
        let request = crate::instance_backup::InstanceBackupRequest {
            program: "/run/current-system/sw/bin/incus".into(),
            remote: "local".to_owned(),
            project: "default".to_owned(),
            instance: "zulip".to_owned(),
            operation: InstanceBackupAction::DeleteArchive {
                archive_root: archive_root.clone(),
            },
        };
        resolve_job_inputs(
            &JobOperation::BackupInstance {
                request: request.clone(),
            },
            resource,
            "delete-1",
            &manifest_path,
        )
        .unwrap();

        let escaped = crate::instance_backup::InstanceBackupRequest {
            operation: InstanceBackupAction::DeleteArchive {
                archive_root: backup_root
                    .join(digest_bytes(b"instance:other"))
                    .join("backup-1"),
            },
            ..request
        };
        assert!(
            resolve_job_inputs(
                &JobOperation::BackupInstance { request: escaped },
                resource,
                "delete-2",
                &manifest_path,
            )
            .is_err()
        );
    }
}
