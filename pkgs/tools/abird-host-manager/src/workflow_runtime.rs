use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::time::Instant;

use abird_host_agent::resource::DataRootPlan;
use abird_host_agent::sha256::digest_bytes;
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::agent_adapter::{NativeAdapter, WorkflowItemAdapter};
use crate::backup_runtime::{BackupPhase, BackupRecord};
use crate::progress::{
    StepProgress, command_step_completed, command_step_failed, command_step_started,
};
use crate::projection::{ActivationReceipt, PhaseProjection};
use crate::workflow::{AuthorityKey, MoveItem, TransactionSpec, validate_workflow_id};
use crate::{
    Action, Store, Transaction, execute_action_until, plan_retire_pending_action,
    reset_action_epoch, supersede_active_job,
};

pub const TRANSACTION_RECORD_SCHEMA_VERSION: u32 = 1;
pub const COMMAND_PLAN_SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LifecycleCommand {
    Move,
    Prepare,
    Run,
    Close,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LifecycleState {
    SourceActive,
    Moved,
    Preparing,
    Prepared,
    Running,
    TargetActive,
    ClosingComplete,
    ClosingRollback,
    ClosedOnTarget,
    ClosedOnSource,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DataAuthority {
    Source,
    Target,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CloseDecision {
    Complete,
    Rollback,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CommandStatus {
    Running,
    Succeeded,
    Failed,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StepStatus {
    Pending,
    Running,
    Succeeded,
    Failed,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StepKind {
    Check,
    Mutation,
    Publication,
    Deployment,
    Transfer,
    Verification,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CommandStepExecution {
    pub id: String,
    pub version: u32,
    pub description: String,
    pub kind: StepKind,
    pub executor: String,
    pub input_sha256: String,
    pub status: StepStatus,
    #[serde(default)]
    pub attempt: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evidence: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<String>,
}

impl CommandStepExecution {
    fn pending(transaction_id: &str, command: LifecycleCommand, id: impl Into<String>) -> Self {
        let id = id.into();
        let (kind, executor) = step_contract(&id);
        Self {
            input_sha256: digest_bytes(
                format!(
                    "{transaction_id}:{}:{id}:1",
                    lifecycle_command_name(command)
                )
                .as_bytes(),
            ),
            description: id.replace(['.', '-'], " "),
            id,
            version: 1,
            kind,
            executor: executor.to_owned(),
            status: StepStatus::Pending,
            attempt: 0,
            job_id: None,
            evidence: None,
            failure: None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CommandExecution {
    pub id: String,
    pub schema_version: u32,
    pub command: LifecycleCommand,
    pub from_state: LifecycleState,
    pub desired_state: LifecycleState,
    pub status: CommandStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub close_decision: Option<CloseDecision>,
    pub steps: Vec<CommandStepExecution>,
    pub created_at_unix_ms: u128,
    pub updated_at_unix_ms: u128,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkflowPhase {
    Planned,
    Setup,
    Seeded,
    Prepared,
    Verified,
    Cutover,
    RolledBack,
    Closed,
}

impl WorkflowPhase {
    pub fn is_open(self) -> bool {
        self != Self::Closed
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InitialMoveContinuation {
    Resume(Action),
    Complete,
    RequiresForce(Option<Action>),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkflowRegistration {
    Created(TransactionRecord),
    Existing(TransactionRecord),
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WorkflowEvent {
    pub at_unix_ms: u128,
    pub action: Action,
    pub message: String,
}

/// Durable proof of which authority released a projected activation latch.
/// The immutable job is identical for both issuers; only the controller-side
/// authorization evidence differs.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "issuer", rename_all = "snake_case")]
pub enum ActivationAuthorization {
    RepositoryDeploy {
        projection_digest: String,
        generation: u64,
        evidence_sha256: String,
    },
    BrokeredReceipt {
        receipt: ActivationReceipt,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TransactionRecord {
    pub schema_version: u32,
    pub spec: TransactionSpec,
    pub config: PathBuf,
    pub phase: WorkflowPhase,
    pub pending_action: Option<Action>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lifecycle_state: Option<LifecycleState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data_authority: Option<DataAuthority>,
    #[serde(default)]
    pub run_epoch: u64,
    #[serde(default)]
    pub current_run_succeeded: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub close_decision: Option<CloseDecision>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub command_executions: Vec<CommandExecution>,
    #[serde(default)]
    pub items: BTreeMap<String, Transaction>,
    /// Last desired projection published for new repository-backed moves.
    /// Missing means this is a legacy runtime-only transaction.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub projection: Option<PhaseProjection>,
    /// Superseded projections retained by digest so mixed deploy/runtime
    /// reconciliation can inspect the exact prior generation after Git has
    /// advanced to a compensating phase.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub projection_history: BTreeMap<String, PhaseProjection>,
    /// Concrete authority evidence retained independently from desired state.
    /// Repository deployment and manager-brokered receipt are co-equal
    /// issuers, but only the latter proves runtime preparation.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub activation_authorizations: BTreeMap<String, ActivationAuthorization>,
    pub created_at_unix_ms: u128,
    pub updated_at_unix_ms: u128,
    #[serde(default)]
    pub events: Vec<WorkflowEvent>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct WorkflowPreflightReport {
    pub validated_phases: Vec<Action>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub deferred_phases: Vec<Action>,
}

impl TransactionRecord {
    pub fn new(spec: TransactionSpec, config: PathBuf) -> Result<Self> {
        spec.validate()?;
        if !config.is_absolute() {
            bail!("manager config path must be absolute");
        }
        let now = now_unix_ms()?;
        let mut items = BTreeMap::new();
        for item in &spec.items {
            let child = item_transaction(&spec.id, item, &config)?;
            if items.insert(item.id().to_owned(), child).is_some() {
                bail!("duplicate move item ID {:?}", item.id());
            }
        }
        Ok(Self {
            schema_version: TRANSACTION_RECORD_SCHEMA_VERSION,
            spec,
            config,
            phase: WorkflowPhase::Planned,
            pending_action: None,
            lifecycle_state: Some(LifecycleState::SourceActive),
            data_authority: Some(DataAuthority::Source),
            run_epoch: 0,
            current_run_succeeded: false,
            close_decision: None,
            command_executions: Vec::new(),
            items,
            projection: None,
            projection_history: BTreeMap::new(),
            activation_authorizations: BTreeMap::new(),
            created_at_unix_ms: now,
            updated_at_unix_ms: now,
            events: Vec::new(),
        })
    }

    pub fn id(&self) -> &str {
        &self.spec.id
    }

    pub fn effective_lifecycle_state(&self) -> LifecycleState {
        self.lifecycle_state.unwrap_or(match self.phase {
            WorkflowPhase::Planned => LifecycleState::SourceActive,
            WorkflowPhase::Setup | WorkflowPhase::Seeded => LifecycleState::Moved,
            WorkflowPhase::Prepared | WorkflowPhase::Verified => LifecycleState::Prepared,
            WorkflowPhase::Cutover => LifecycleState::TargetActive,
            WorkflowPhase::RolledBack => LifecycleState::ClosingRollback,
            WorkflowPhase::Closed => {
                if self.close_decision == Some(CloseDecision::Complete) {
                    LifecycleState::ClosedOnTarget
                } else {
                    LifecycleState::ClosedOnSource
                }
            }
        })
    }

    pub fn effective_data_authority(&self) -> DataAuthority {
        self.data_authority.unwrap_or_else(|| {
            if self.phase == WorkflowPhase::Cutover
                || self.items.values().any(|item| item.target_ever_started)
                    && !matches!(
                        self.phase,
                        WorkflowPhase::RolledBack | WorkflowPhase::Closed
                    )
            {
                DataAuthority::Target
            } else {
                DataAuthority::Source
            }
        })
    }

    pub fn select_close_decision(
        &mut self,
        requested: Option<CloseDecision>,
    ) -> Result<CloseDecision> {
        let selected = requested.unwrap_or(if self.current_run_succeeded {
            CloseDecision::Complete
        } else {
            CloseDecision::Rollback
        });
        match self.close_decision {
            Some(existing) if existing != selected => bail!(
                "transaction close decision is already {existing:?}; refusing to change it to {selected:?}"
            ),
            Some(existing) => Ok(existing),
            None => {
                self.close_decision = Some(selected);
                self.lifecycle_state = Some(match selected {
                    CloseDecision::Complete => LifecycleState::ClosingComplete,
                    CloseDecision::Rollback => LifecycleState::ClosingRollback,
                });
                Ok(selected)
            }
        }
    }

    pub fn begin_command(
        &mut self,
        command: LifecycleCommand,
        desired_state: LifecycleState,
        close_decision: Option<CloseDecision>,
        step_ids: impl IntoIterator<Item = impl Into<String>>,
    ) -> Result<usize> {
        if let Some(index) = self
            .command_executions
            .iter()
            .rposition(|execution| execution.status == CommandStatus::Running)
        {
            let execution = &self.command_executions[index];
            if execution.command != command || execution.close_decision != close_decision {
                bail!(
                    "transaction has running {:?} command {}; resume it before starting {command:?}",
                    execution.command,
                    execution.id
                );
            }
            return Ok(index);
        }
        let now = now_unix_ms()?;
        let sequence = self.command_executions.len() + 1;
        let execution = CommandExecution {
            id: format!(
                "{}/{}/{sequence:04}",
                self.id(),
                lifecycle_command_name(command)
            ),
            schema_version: COMMAND_PLAN_SCHEMA_VERSION,
            command,
            from_state: self.effective_lifecycle_state(),
            desired_state,
            status: CommandStatus::Running,
            close_decision,
            steps: step_ids
                .into_iter()
                .map(|step| CommandStepExecution::pending(self.id(), command, step.into()))
                .collect(),
            created_at_unix_ms: now,
            updated_at_unix_ms: now,
        };
        self.command_executions.push(execution);
        Ok(self.command_executions.len() - 1)
    }

    pub fn start_command_step(&mut self, execution: usize, step_id: &str) -> Result<()> {
        let command = self
            .command_executions
            .get_mut(execution)
            .context("command execution index is absent")?;
        if command.status != CommandStatus::Running {
            bail!("cannot start a step in a finished command execution");
        }
        let position = command
            .steps
            .iter()
            .position(|step| step.id == step_id)
            .with_context(|| format!("command plan has no step {step_id:?}"))?;
        if command.steps[..position]
            .iter()
            .any(|step| step.status != StepStatus::Succeeded)
        {
            bail!("cannot start step {step_id:?} before earlier steps succeed");
        }
        let step = &mut command.steps[position];
        let description = step.description.clone();
        match step.status {
            StepStatus::Succeeded => return Ok(()),
            StepStatus::Running => return Ok(()),
            StepStatus::Pending | StepStatus::Failed => {
                step.status = StepStatus::Running;
                step.attempt = step
                    .attempt
                    .checked_add(1)
                    .context("step attempt overflow")?;
                step.failure = None;
            }
        }
        let now = now_unix_ms()?;
        command.updated_at_unix_ms = now;
        self.updated_at_unix_ms = now;
        command_step_started(&description);
        Ok(())
    }

    pub fn complete_command_step(
        &mut self,
        execution: usize,
        step_id: &str,
        evidence: Option<serde_json::Value>,
    ) -> Result<()> {
        let command = self
            .command_executions
            .get_mut(execution)
            .context("command execution index is absent")?;
        let step = command
            .steps
            .iter_mut()
            .find(|step| step.id == step_id)
            .with_context(|| format!("command plan has no step {step_id:?}"))?;
        if !matches!(step.status, StepStatus::Running | StepStatus::Succeeded) {
            bail!("step {step_id:?} was not started");
        }
        let already_succeeded = step.status == StepStatus::Succeeded;
        let description = step.description.clone();
        step.status = StepStatus::Succeeded;
        step.evidence = evidence;
        step.failure = None;
        let now = now_unix_ms()?;
        command.updated_at_unix_ms = now;
        self.updated_at_unix_ms = now;
        if !already_succeeded {
            command_step_completed(&description);
        }
        Ok(())
    }

    pub fn bind_command_step_job(
        &mut self,
        execution: usize,
        step_id: &str,
        job_id: impl Into<String>,
        evidence: Option<serde_json::Value>,
    ) -> Result<()> {
        let command = self
            .command_executions
            .get_mut(execution)
            .context("command execution index is absent")?;
        let step = command
            .steps
            .iter_mut()
            .find(|step| step.id == step_id)
            .with_context(|| format!("command plan has no step {step_id:?}"))?;
        if step.status != StepStatus::Running {
            bail!("step {step_id:?} was not running");
        }
        let job_id = job_id.into();
        if step
            .job_id
            .as_ref()
            .is_some_and(|existing| existing != &job_id)
        {
            bail!("step {step_id:?} is already bound to a different durable job");
        }
        step.job_id = Some(job_id);
        step.evidence = evidence;
        let now = now_unix_ms()?;
        command.updated_at_unix_ms = now;
        self.updated_at_unix_ms = now;
        Ok(())
    }

    pub fn annotate_command_step(
        &mut self,
        execution: usize,
        step_id: &str,
        evidence: serde_json::Value,
    ) -> Result<()> {
        let command = self
            .command_executions
            .get_mut(execution)
            .context("command execution index is absent")?;
        let step = command
            .steps
            .iter_mut()
            .find(|step| step.id == step_id)
            .with_context(|| format!("command plan has no step {step_id:?}"))?;
        if !matches!(step.status, StepStatus::Pending | StepStatus::Running) {
            bail!("cannot annotate finished step {step_id:?}");
        }
        step.evidence = Some(evidence);
        let now = now_unix_ms()?;
        command.updated_at_unix_ms = now;
        self.updated_at_unix_ms = now;
        Ok(())
    }

    pub fn fail_command_step(
        &mut self,
        execution: usize,
        step_id: &str,
        failure: impl Into<String>,
    ) -> Result<()> {
        let failure = failure.into();
        let command = self
            .command_executions
            .get_mut(execution)
            .context("command execution index is absent")?;
        let step = command
            .steps
            .iter_mut()
            .find(|step| step.id == step_id)
            .with_context(|| format!("command plan has no step {step_id:?}"))?;
        if step.status != StepStatus::Running {
            bail!("step {step_id:?} was not running");
        }
        let description = step.description.clone();
        step.status = StepStatus::Failed;
        step.failure = Some(failure.clone());
        command.status = CommandStatus::Failed;
        let now = now_unix_ms()?;
        command.updated_at_unix_ms = now;
        self.updated_at_unix_ms = now;
        command_step_failed(&description, &failure);
        Ok(())
    }

    pub fn complete_command(&mut self, execution: usize) -> Result<()> {
        let command = self
            .command_executions
            .get_mut(execution)
            .context("command execution index is absent")?;
        if command
            .steps
            .iter()
            .any(|step| step.status != StepStatus::Succeeded)
        {
            bail!("cannot complete a command with unfinished steps");
        }
        command.status = CommandStatus::Succeeded;
        self.lifecycle_state = Some(command.desired_state);
        let now = now_unix_ms()?;
        command.updated_at_unix_ms = now;
        self.updated_at_unix_ms = now;
        Ok(())
    }

    pub fn fail_running_command(&mut self, failure: impl Into<String>) -> Result<()> {
        let failure = failure.into();
        let execution = self
            .command_executions
            .iter()
            .rposition(|execution| execution.status == CommandStatus::Running)
            .context("transaction has no running command execution")?;
        let command = &mut self.command_executions[execution];
        let step = command
            .steps
            .iter_mut()
            .find(|step| matches!(step.status, StepStatus::Running | StepStatus::Pending))
            .context("running command has no unfinished step")?;
        if step.status == StepStatus::Pending {
            step.status = StepStatus::Running;
            step.attempt = step
                .attempt
                .checked_add(1)
                .context("step attempt overflow")?;
        }
        let description = step.description.clone();
        step.status = StepStatus::Failed;
        step.failure = Some(failure.clone());
        command.status = CommandStatus::Failed;
        let now = now_unix_ms()?;
        command.updated_at_unix_ms = now;
        self.updated_at_unix_ms = now;
        command_step_failed(&description, &failure);
        Ok(())
    }

    /// Supersede an in-flight command only when it is the expected lifecycle
    /// command. This is used by explicit rollback, whose safety semantics are
    /// allowed to interrupt a run without letting unrelated commands vanish.
    pub fn fail_running_command_if(
        &mut self,
        expected: LifecycleCommand,
        failure: impl Into<String>,
    ) -> Result<bool> {
        let Some(execution) = self
            .command_executions
            .iter()
            .rposition(|execution| execution.status == CommandStatus::Running)
        else {
            return Ok(false);
        };
        if self.command_executions[execution].command != expected {
            bail!(
                "transaction has running {:?} command {}; refusing to supersede it as {expected:?}",
                self.command_executions[execution].command,
                self.command_executions[execution].id
            );
        }
        self.fail_running_command(failure)?;
        Ok(true)
    }

    pub fn initial_move_continuation(&self) -> InitialMoveContinuation {
        match self.pending_action {
            Some(Action::Setup) if self.phase == WorkflowPhase::Planned => {
                InitialMoveContinuation::Resume(Action::Setup)
            }
            Some(Action::Seed)
                if matches!(self.phase, WorkflowPhase::Setup | WorkflowPhase::Seeded) =>
            {
                InitialMoveContinuation::Resume(Action::Seed)
            }
            Some(action) => InitialMoveContinuation::RequiresForce(Some(action)),
            None => match self.phase {
                WorkflowPhase::Planned => InitialMoveContinuation::Resume(Action::Setup),
                WorkflowPhase::Setup => InitialMoveContinuation::Resume(Action::Seed),
                WorkflowPhase::Seeded => InitialMoveContinuation::Complete,
                WorkflowPhase::Prepared
                | WorkflowPhase::Verified
                | WorkflowPhase::Cutover
                | WorkflowPhase::RolledBack
                | WorkflowPhase::Closed => InitialMoveContinuation::RequiresForce(None),
            },
        }
    }

    pub fn record_reinvocation(&mut self, message: impl Into<String>) -> Result<()> {
        let action = self.pending_action.unwrap_or(match self.phase {
            WorkflowPhase::Planned => Action::Setup,
            WorkflowPhase::Setup | WorkflowPhase::Seeded => Action::Seed,
            WorkflowPhase::Prepared => Action::Prepare,
            WorkflowPhase::Verified => Action::Verify,
            WorkflowPhase::Cutover => Action::Cutover,
            WorkflowPhase::RolledBack => Action::Rollback,
            WorkflowPhase::Closed => Action::Close,
        });
        event(self, action, message)
    }

    pub fn record_authorization_event(
        &mut self,
        action: Action,
        message: impl Into<String>,
    ) -> Result<()> {
        event(self, action, message)
    }

    pub fn set_projection(&mut self, projection: PhaseProjection) -> Result<()> {
        projection.validate()?;
        if let Some(previous) = self.projection.take()
            && previous.projection_sha256 != projection.projection_sha256
        {
            self.projection_history
                .insert(previous.projection_sha256.clone(), previous);
        }
        self.projection = Some(projection);
        Ok(())
    }

    pub fn projection_by_digest(&self, digest: &str) -> Option<&PhaseProjection> {
        self.projection
            .as_ref()
            .filter(|projection| projection.projection_sha256 == digest)
            .or_else(|| self.projection_history.get(digest))
    }

    fn authorities(&self) -> Vec<(&str, AuthorityKey)> {
        self.spec
            .items
            .iter()
            .flat_map(|item| {
                [
                    (item.id(), item.source_authority()),
                    (item.id(), item.target_authority()),
                ]
            })
            .collect()
    }
}

fn lifecycle_command_name(command: LifecycleCommand) -> &'static str {
    match command {
        LifecycleCommand::Move => "move",
        LifecycleCommand::Prepare => "prepare",
        LifecycleCommand::Run => "run",
        LifecycleCommand::Close => "close",
    }
}

fn step_contract(id: &str) -> (StepKind, &'static str) {
    if id.starts_with("git.") || id.starts_with("repository.") || id.starts_with("projection.") {
        (StepKind::Publication, "repository-publisher")
    } else if id.starts_with("nixbot.") || id.contains("deploy") {
        (StepKind::Deployment, "nixbot")
    } else if id.starts_with("data.") {
        if id.contains("verify") {
            (StepKind::Verification, "transfer-broker")
        } else {
            (StepKind::Transfer, "transfer-broker")
        }
    } else if id.contains("verify")
        || id.contains("check")
        || id.contains("determine")
        || id.contains("resolve")
        || id.contains("validate")
    {
        (StepKind::Check, "host-manager")
    } else if id.starts_with("state.") || id.starts_with("checkpoint.") {
        (StepKind::Verification, "host-manager")
    } else {
        (StepKind::Mutation, "host-manager")
    }
}

pub struct WorkflowStore {
    root: PathBuf,
    _lock: Option<File>,
}

impl WorkflowStore {
    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn load_matching(
        root: &Path,
        candidate: &TransactionRecord,
    ) -> Result<Option<TransactionRecord>> {
        validate_record(candidate)?;
        let path = root
            .join("workflow-transactions")
            .join(format!("{}.json", candidate.id()));
        if !path.exists() {
            return Ok(None);
        }
        let existing = read_transaction_record(&path, candidate.id())?;
        if existing.spec != candidate.spec || existing.config != candidate.config {
            bail!(
                "transaction ID {:?} already exists with different immutable intent",
                candidate.id()
            );
        }
        Ok(Some(existing))
    }

    pub fn open(root: PathBuf) -> Result<Self> {
        let transactions = root.join("workflow-transactions");
        fs::create_dir_all(&transactions).with_context(|| {
            format!(
                "failed to create workflow state directory {}",
                transactions.display()
            )
        })?;
        let lock_path = root.join("authority-lock");
        let lock = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&lock_path)
            .with_context(|| format!("failed to open workflow lock {}", lock_path.display()))?;
        lock.lock()
            .with_context(|| format!("failed to lock workflow state {}", root.display()))?;
        Ok(Self {
            root,
            _lock: Some(lock),
        })
    }

    pub fn read_only(root: PathBuf) -> Self {
        Self { root, _lock: None }
    }

    fn require_write_authority(&self) -> Result<()> {
        if self._lock.is_none() {
            bail!("read-only workflow store cannot mutate manager state");
        }
        Ok(())
    }

    pub fn register(&self, record: TransactionRecord) -> Result<WorkflowRegistration> {
        self.require_write_authority()?;
        if self.path(record.id()).exists() {
            let existing = self.load(record.id())?;
            if existing.spec == record.spec && existing.config == record.config {
                return Ok(WorkflowRegistration::Existing(existing));
            }
            bail!(
                "transaction ID {:?} already exists with different immutable intent",
                record.id()
            );
        }
        self.reject_open_authority_overlap(&record)?;
        self.reject_active_backup_overlap(&record)?;
        self.save(&record)?;
        Ok(WorkflowRegistration::Created(record))
    }

    /// Validate a prospective registration without creating the state
    /// directory, lock, journal, or any other durable artifact. Registration
    /// repeats these checks while holding the authority lock to close the race
    /// between planning and execution.
    pub fn validate_registration(root: &Path, candidate: &TransactionRecord) -> Result<()> {
        validate_record(candidate)?;
        reject_open_authority_overlap_at(root, candidate)?;
        reject_active_backup_overlap_at(root, candidate)
    }

    pub fn save(&self, record: &TransactionRecord) -> Result<()> {
        self.require_write_authority()?;
        validate_record(record)?;
        atomic_json(&self.path(record.id()), record)
    }

    pub fn load(&self, id: &str) -> Result<TransactionRecord> {
        validate_workflow_id(id)?;
        let path = self.path(id);
        read_transaction_record(&path, id)
    }

    pub fn list(&self) -> Result<Vec<TransactionRecord>> {
        let mut records = Vec::new();
        let directory = self.root.join("workflow-transactions");
        if !directory.exists() {
            return Ok(records);
        }
        for entry in fs::read_dir(directory)? {
            let path = entry?.path();
            if path.extension() != Some(OsStr::new("json")) {
                continue;
            }
            let Some(id) = path.file_stem().and_then(OsStr::to_str) else {
                continue;
            };
            records.push(self.load(id)?);
        }
        records.sort_by_key(|record| record.created_at_unix_ms);
        Ok(records)
    }

    pub fn child_store(&self, record_id: &str) -> Result<Store> {
        validate_workflow_id(record_id)?;
        let root = self
            .root
            .join("workflow-items")
            .join(record_id)
            .to_path_buf();
        if self._lock.is_some() {
            Store::open(root)
        } else {
            Ok(Store::read_only(root))
        }
    }

    fn path(&self, id: &str) -> PathBuf {
        self.root
            .join("workflow-transactions")
            .join(format!("{id}.json"))
    }

    fn reject_open_authority_overlap(&self, candidate: &TransactionRecord) -> Result<()> {
        reject_open_authority_overlap_at(&self.root, candidate)
    }

    fn reject_active_backup_overlap(&self, candidate: &TransactionRecord) -> Result<()> {
        reject_active_backup_overlap_at(&self.root, candidate)
    }
}

fn reject_open_authority_overlap_at(root: &Path, candidate: &TransactionRecord) -> Result<()> {
    let directory = root.join("workflow-transactions");
    if !directory.exists() {
        return Ok(());
    }
    for entry in fs::read_dir(directory)? {
        let path = entry?.path();
        if path.extension() != Some(OsStr::new("json")) {
            continue;
        }
        let Some(id) = path.file_stem().and_then(OsStr::to_str) else {
            continue;
        };
        let existing = read_transaction_record(&path, id)?;
        if !existing.phase.is_open() || existing.id() == candidate.id() {
            continue;
        }
        for (candidate_item, candidate_key) in candidate.authorities() {
            if let Some((existing_item, existing_key)) = existing
                .authorities()
                .into_iter()
                .find(|(_, key)| candidate_key.overlaps(key))
            {
                bail!(
                    "transaction {:?} item {:?} overlaps open transaction {:?} item {:?}: {:?} conflicts with {:?}",
                    candidate.id(),
                    candidate_item,
                    existing.id(),
                    existing_item,
                    candidate_key,
                    existing_key
                );
            }
        }
    }
    Ok(())
}

fn reject_active_backup_overlap_at(root: &Path, candidate: &TransactionRecord) -> Result<()> {
    let directory = root.join("backups");
    if !directory.exists() {
        return Ok(());
    }
    for entry in fs::read_dir(directory)? {
        let path = entry?.path();
        if path.extension() != Some(OsStr::new("json")) {
            continue;
        }
        let backup: BackupRecord = serde_json::from_reader(BufReader::new(File::open(&path)?))
            .with_context(|| format!("parse backup authority record {}", path.display()))?;
        if !matches!(backup.phase, BackupPhase::Created | BackupPhase::Running)
            && !backup
                .restore
                .as_ref()
                .is_some_and(|restore| restore.phase.holds_authority())
        {
            continue;
        }
        for (candidate_item, candidate_key) in candidate.authorities() {
            if let Some(backup_item) = backup
                .spec
                .items
                .iter()
                .find(|item| candidate_key.overlaps(&item.authority()))
            {
                bail!(
                    "transaction {:?} item {:?} overlaps active backup {:?} item {:?}",
                    candidate.id(),
                    candidate_item,
                    backup.id(),
                    backup_item.id()
                );
            }
        }
    }
    Ok(())
}

fn read_transaction_record(path: &Path, expected_id: &str) -> Result<TransactionRecord> {
    let record: TransactionRecord =
        serde_json::from_reader(BufReader::new(File::open(path).with_context(|| {
            format!("failed to open transaction record {}", path.display())
        })?))
        .with_context(|| format!("failed to parse transaction record {}", path.display()))?;
    validate_record(&record)?;
    if record.id() != expected_id {
        bail!("transaction record ID does not match its filename");
    }
    Ok(record)
}

fn refresh_child_journals(store: &WorkflowStore, record: &mut TransactionRecord) -> Result<()> {
    let child_store = store.child_store(record.id())?;
    for (item_id, child) in &mut record.items {
        let Some(persisted) = child_store.load_optional(&child.id)? else {
            continue;
        };
        if persisted.id != child.id
            || persisted.resource_kind != child.resource_kind
            || persisted.resource != child.resource
            || persisted.source != child.source
            || persisted.target != child.target
            || persisted.config != child.config
        {
            bail!(
                "persisted child journal for item {item_id:?} does not match immutable transaction intent"
            );
        }
        *child = persisted;
    }
    Ok(())
}

pub fn execute_workflow_action(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    action: Action,
    adapter: &mut NativeAdapter,
) -> Result<()> {
    if !execute_workflow_action_until(store, record, action, adapter, None)? {
        unreachable!("unbounded workflow action execution must complete");
    }
    Ok(())
}

pub fn execute_workflow_action_until(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    action: Action,
    adapter: &mut NativeAdapter,
    stop_before: Option<&str>,
) -> Result<bool> {
    begin_workflow_action(store, record, action)?;

    let phase_started = Instant::now();
    let item_ids = ordered_items(record, action)?;
    adapter
        .progress()
        .phase_started(record.id(), action, item_ids.len());
    let child_store = store.child_store(record.id())?;
    let mut completed = true;
    for item_id in item_ids {
        let item = record
            .spec
            .items
            .iter()
            .find(|item| item.id() == item_id)
            .cloned()
            .with_context(|| format!("transaction item {item_id:?} has no immutable spec"))?;
        let child = record
            .items
            .get_mut(&item_id)
            .with_context(|| format!("transaction item {item_id:?} has no journal"))?;
        let mut item_adapter = WorkflowItemAdapter::new(adapter, &item);
        let preflight = StepProgress {
            transaction: child.id.clone(),
            item: item_id.clone(),
            action,
            step: "preflight".to_owned(),
            description: "validate endpoints, resources, routes, and job policy".to_owned(),
            location: "manager and declared endpoints".to_owned(),
        };
        let preflight_started = Instant::now();
        item_adapter.native_progress().step_started(&preflight);
        if let Err(error) = item_adapter.preflight(child, action) {
            item_adapter.native_progress().step_failed(
                &preflight,
                preflight_started.elapsed(),
                &error,
            );
            return Err(error).with_context(|| format!("preflight transaction item {item_id:?}"));
        }
        item_adapter
            .native_progress()
            .step_completed(&preflight, preflight_started.elapsed());
        let result =
            execute_action_until(&child_store, child, action, &mut item_adapter, stop_before)
                .with_context(|| format!("execute transaction item {item_id:?}"));
        let persisted = child_store.load(&child.id)?;
        record.items.insert(item_id.clone(), persisted);
        store.save(record)?;
        completed &= result?;
    }

    if !completed {
        return Ok(false);
    }

    record.phase = workflow_phase_after(action);
    record.pending_action = None;
    match action {
        Action::Seed => record.lifecycle_state = Some(LifecycleState::Moved),
        Action::Prepare => {
            record.run_epoch = record
                .run_epoch
                .checked_add(1)
                .context("run epoch overflow")?;
            record.current_run_succeeded = false;
            record.lifecycle_state = Some(LifecycleState::Prepared);
        }
        Action::Cutover => {
            record.current_run_succeeded = true;
            record.data_authority = Some(DataAuthority::Target);
            record.lifecycle_state = Some(LifecycleState::TargetActive);
        }
        Action::Rollback => {
            record.current_run_succeeded = false;
            record.data_authority = Some(DataAuthority::Source);
            record.lifecycle_state = Some(LifecycleState::ClosingRollback);
        }
        Action::Close => {
            record.lifecycle_state = Some(match record.close_decision {
                Some(CloseDecision::Complete) => LifecycleState::ClosedOnTarget,
                _ => LifecycleState::ClosedOnSource,
            });
        }
        _ => {}
    }
    event(record, action, "action completed")?;
    store.save(record)?;
    adapter
        .progress()
        .phase_completed(record.id(), action, phase_started.elapsed());
    Ok(true)
}

/// Establish one workflow action epoch before rendering its repository
/// projection. This allocates the same deterministic child-job generation that
/// runtime execution will consume, so declarative and direct reconciliation
/// cannot publish different activation identities.
pub fn begin_workflow_action(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    action: Action,
) -> Result<()> {
    refresh_child_journals(store, record)?;
    plan_workflow_action(record, action)?;
    let child_store = store.child_store(record.id())?;
    for child in record.items.values() {
        child_store.save(child)?;
    }
    store.save(record)
}

/// Apply the exact in-memory state transition used by `begin_workflow_action`.
/// Dry planning uses this after read-only evidence validation so projected job
/// generations are identical to execution without writing a journal.
pub fn plan_workflow_action(record: &mut TransactionRecord, action: Action) -> Result<()> {
    validate_workflow_transition(record, action)?;
    let starts_new_epoch = record.pending_action.is_none()
        && (action == Action::Prepare
            && matches!(
                record.phase,
                WorkflowPhase::Prepared | WorkflowPhase::Cutover
            )
            || action == Action::Cutover
                && record.phase == WorkflowPhase::Prepared
                && record.items.values().any(|item| {
                    item.completed_steps
                        .iter()
                        .any(|step| step.starts_with("cutover:"))
                }));
    if starts_new_epoch {
        for child in record.items.values_mut() {
            reset_action_epoch(child, action)?;
        }
    }
    match record.pending_action {
        Some(pending) if pending != action && action != Action::Rollback => bail!(
            "transaction has pending {} action; resume it or explicitly roll back",
            pending.as_str()
        ),
        Some(pending) if pending != action => {
            event(
                record,
                action,
                format!("rollback superseded pending {}", pending.as_str()),
            )?;
            record.pending_action = Some(Action::Rollback);
        }
        None => {
            record.pending_action = Some(action);
            record.lifecycle_state = Some(match action {
                Action::Prepare => LifecycleState::Preparing,
                Action::Cutover => LifecycleState::Running,
                Action::Rollback => LifecycleState::ClosingRollback,
                Action::Close => match record.close_decision {
                    Some(CloseDecision::Complete) => LifecycleState::ClosingComplete,
                    _ => LifecycleState::ClosingRollback,
                },
                _ => record.effective_lifecycle_state(),
            });
            if action == Action::Prepare {
                record.current_run_succeeded = false;
            }
            event(record, action, "action started")?;
        }
        Some(_) => {}
    }
    Ok(())
}

/// End a proven terminal failed run before an explicit prepare starts a fresh
/// checkpoint epoch. Running or ambiguous activation jobs remain a hard block.
pub fn supersede_terminal_failed_run_for_prepare(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    mut active_job_state: impl FnMut(&MoveItem, &Transaction) -> Result<String>,
) -> Result<Vec<String>> {
    refresh_child_journals(store, record)?;
    let retired = plan_terminal_failed_run_for_prepare(record, &mut active_job_state)?;
    let child_store = store.child_store(record.id())?;
    for child in record.items.values() {
        child_store.save(child)?;
    }
    store.save(record)?;
    Ok(retired)
}

/// Plan the failed-run retirement entirely in memory after callers obtain
/// read-only terminal job evidence.
pub fn plan_terminal_failed_run_for_prepare(
    record: &mut TransactionRecord,
    mut active_job_state: impl FnMut(&MoveItem, &Transaction) -> Result<String>,
) -> Result<Vec<String>> {
    if record.pending_action != Some(Action::Cutover) {
        bail!("transaction has no pending run to supersede with prepare");
    }
    if !matches!(
        record.phase,
        WorkflowPhase::Prepared | WorkflowPhase::Verified
    ) {
        bail!("only a prepared transaction can replace a failed run with prepare");
    }

    let item_ids = ordered_items(record, Action::Cutover)?;
    let mut failed_jobs = BTreeMap::new();
    for item_id in &item_ids {
        let item = record
            .spec
            .items
            .iter()
            .find(|item| item.id() == item_id)
            .with_context(|| format!("transaction item {item_id:?} has no immutable spec"))?;
        let child = record
            .items
            .get(item_id)
            .with_context(|| format!("transaction item {item_id:?} has no journal"))?;
        match child.pending_action {
            None if child.active_step.is_none() && child.active_job_id.is_none() => continue,
            Some(Action::Cutover) => {}
            Some(action) => bail!(
                "transaction item {item_id:?} has pending {} action, expected cutover",
                action.as_str()
            ),
            None => bail!("transaction item {item_id:?} has active work without a pending action"),
        }
        match (&child.active_step, &child.active_job_id) {
            (None, None) => {}
            (Some(_), Some(job_id)) => {
                let status = active_job_state(item, child)?;
                if status != "failed" {
                    bail!(
                        "host-agent job {job_id:?} is {status:?}; prepare cannot supersede an unresolved run"
                    );
                }
                failed_jobs.insert(item_id.clone(), job_id.clone());
            }
            _ => bail!("transaction item {item_id:?} has an incomplete active job record"),
        }
    }

    if let Some(execution) = record
        .command_executions
        .iter()
        .rposition(|execution| execution.status == CommandStatus::Running)
    {
        match record.command_executions[execution].command {
            LifecycleCommand::Run => {
                record.fail_running_command(
                    "explicit prepare superseded a terminal failed run attempt",
                )?;
            }
            LifecycleCommand::Prepare => {}
            command => bail!(
                "transaction has running {command:?} command {}; prepare cannot supersede it",
                record.command_executions[execution].id
            ),
        }
    }

    let mut retired = Vec::new();
    for item_id in item_ids {
        let child = record
            .items
            .get_mut(&item_id)
            .with_context(|| format!("transaction item {item_id:?} disappeared"))?;
        if child.pending_action != Some(Action::Cutover) {
            continue;
        }
        let expected_failed_job = failed_jobs.get(&item_id).cloned();
        if let Some(job_id) =
            plan_retire_pending_action(child, Action::Cutover, move |actual_job_id, _| {
                if expected_failed_job.as_deref() != Some(actual_job_id) {
                    bail!("terminal failed job changed during prepare transition");
                }
                Ok(())
            })?
        {
            retired.push(job_id);
        }
    }

    record.pending_action = None;
    record.lifecycle_state = Some(LifecycleState::Prepared);
    record.current_run_succeeded = false;
    event(
        record,
        Action::Prepare,
        "explicit prepare superseded a terminal failed run attempt",
    )?;
    Ok(retired)
}

pub fn supersede_failed_workflow_jobs(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    adapter: &mut NativeAdapter,
) -> Result<Vec<(String, String)>> {
    let candidates = validate_failed_workflow_jobs(store, record, adapter)?;
    let action = record
        .pending_action
        .context("validated transaction lost its pending action")?;
    let child_store = store.child_store(record.id())?;
    let mut superseded = Vec::with_capacity(candidates.len());

    for item_id in candidates {
        let child = record
            .items
            .get_mut(&item_id)
            .with_context(|| format!("validated transaction item {item_id:?} disappeared"))?;
        let (old_job_id, new_job_id) =
            supersede_active_job(&child_store, child, |_job_id, _transaction| Ok(()))?;
        event(
            record,
            action,
            format!("item {item_id} superseded terminal failed job {old_job_id} with {new_job_id}"),
        )?;
        superseded.push((old_job_id, new_job_id));
    }

    store.save(record)?;
    Ok(superseded)
}

/// Refresh durable child state and determine whether deployed closeout is
/// resuming an already-started Close action. A clean closeout has no pending
/// workflow action and must proceed directly to `execute_workflow_action`;
/// only a retained Close action may have terminal jobs to supersede.
pub fn has_pending_close_workflow_action(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
) -> Result<bool> {
    refresh_child_journals(store, record)?;
    match record.pending_action {
        None => {
            for (item_id, child) in &record.items {
                if child.pending_action.is_some()
                    || child.active_step.is_some()
                    || child.active_job_id.is_some()
                {
                    bail!(
                        "transaction item {item_id:?} has active workflow state without a parent pending action"
                    );
                }
            }
            Ok(false)
        }
        Some(Action::Close) => {
            for (item_id, child) in &record.items {
                if let Some(action) = child.pending_action
                    && action != Action::Close
                {
                    bail!(
                        "transaction item {item_id:?} has pending {} action while its parent is closing",
                        action.as_str()
                    );
                }
            }
            Ok(true)
        }
        Some(action) => bail!(
            "deployed closeout has pending {} action; reconcile it before finalizing Close",
            action.as_str()
        ),
    }
}

/// A fresh explicit lifecycle-command invocation treats retained terminal
/// failures as predecessor attempts, while pending/running jobs remain adopted.
pub fn supersede_terminal_failed_workflow_jobs(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    adapter: &mut NativeAdapter,
) -> Result<Vec<(String, String)>> {
    refresh_child_journals(store, record)?;
    let action = record
        .pending_action
        .context("transaction has no pending action with a job to inspect")?;
    let child_store = store.child_store(record.id())?;
    let mut failed_items = Vec::new();
    for item_id in ordered_items(record, action)? {
        let item = record
            .spec
            .items
            .iter()
            .find(|item| item.id() == item_id)
            .cloned()
            .with_context(|| format!("transaction item {item_id:?} has no immutable spec"))?;
        let child = record
            .items
            .get(&item_id)
            .with_context(|| format!("transaction item {item_id:?} has no journal"))?;
        if child.active_job_id.is_none() {
            continue;
        }
        let item_adapter = WorkflowItemAdapter::new(adapter, &item);
        let (_, _, status) = item_adapter.active_job_status(child)?;
        if status == "failed" {
            failed_items.push(item_id);
        }
    }

    let mut superseded = Vec::new();
    for item_id in failed_items {
        let child = record
            .items
            .get_mut(&item_id)
            .with_context(|| format!("transaction item {item_id:?} disappeared"))?;
        let (old_job_id, new_job_id) =
            supersede_active_job(&child_store, child, |_job_id, _transaction| Ok(()))?;
        event(
            record,
            action,
            format!(
                "item {item_id} automatically superseded terminal failed job {old_job_id} with {new_job_id}"
            ),
        )?;
        superseded.push((old_job_id, new_job_id));
    }
    store.save(record)?;
    Ok(superseded)
}

pub fn validate_failed_workflow_jobs(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    adapter: &mut NativeAdapter,
) -> Result<Vec<String>> {
    refresh_child_journals(store, record)?;
    let action = record
        .pending_action
        .context("transaction has no pending action with a job to supersede")?;
    let mut candidates = Vec::new();

    for item_id in ordered_items(record, action)? {
        let item = record
            .spec
            .items
            .iter()
            .find(|item| item.id() == item_id)
            .cloned()
            .with_context(|| format!("transaction item {item_id:?} has no immutable spec"))?;
        let child = record
            .items
            .get_mut(&item_id)
            .with_context(|| format!("transaction item {item_id:?} has no journal"))?;
        if child.active_job_id.is_none() {
            continue;
        }
        let item_adapter = WorkflowItemAdapter::new(adapter, &item);
        item_adapter.assert_active_job_failed(child)?;
        candidates.push(item_id);
    }

    if candidates.is_empty() {
        bail!("transaction has no active terminal failed job to supersede");
    }
    Ok(candidates)
}

pub fn preflight_new_workflow(
    record: &mut TransactionRecord,
    adapter: &mut NativeAdapter,
) -> Result<WorkflowPreflightReport> {
    if record.phase != WorkflowPhase::Planned || record.pending_action.is_some() {
        bail!("only a new planned transaction can preflight setup and seed");
    }
    preflight_workflow_items(record, Action::Setup, adapter)?;
    let target_metadata_ready = record.spec.items.iter().all(|item| {
        matches!(item, MoveItem::Instance { .. })
            || record
                .items
                .get(item.id())
                .is_some_and(|transaction| !transaction.data_root_plan.is_empty())
    });
    if target_metadata_ready {
        preflight_workflow_items(record, Action::Seed, adapter)?;
        Ok(WorkflowPreflightReport {
            validated_phases: vec![Action::Setup, Action::Seed],
            deferred_phases: Vec::new(),
        })
    } else {
        Ok(WorkflowPreflightReport {
            validated_phases: vec![Action::Setup],
            deferred_phases: vec![Action::Seed],
        })
    }
}

pub fn preflight_workflow_action(
    record: &mut TransactionRecord,
    action: Action,
    adapter: &mut NativeAdapter,
) -> Result<()> {
    validate_workflow_transition(record, action)?;
    preflight_workflow_items(record, action, adapter)
}

fn preflight_workflow_items(
    record: &mut TransactionRecord,
    action: Action,
    adapter: &mut NativeAdapter,
) -> Result<()> {
    for item_id in ordered_items(record, action)? {
        let item = record
            .spec
            .items
            .iter()
            .find(|item| item.id() == item_id)
            .cloned()
            .with_context(|| format!("transaction item {item_id:?} has no immutable spec"))?;
        let child = record
            .items
            .get_mut(&item_id)
            .with_context(|| format!("transaction item {item_id:?} has no journal"))?;
        WorkflowItemAdapter::new(adapter, &item)
            .preflight(child, action)
            .with_context(|| format!("preflight transaction item {item_id:?}"))?;
    }
    Ok(())
}

fn item_transaction(parent_id: &str, item: &MoveItem, config: &Path) -> Result<Transaction> {
    let mut child = match item {
        MoveItem::Host {
            id, source, target, ..
        } => Transaction::new_host(
            id.clone(),
            source.host.clone(),
            target.host.clone(),
            config.to_path_buf(),
        )?,
        MoveItem::Service {
            service,
            source_resource,
            target_resource,
            source,
            target,
            ..
        } => {
            let mut transaction = Transaction::new_service(
                service.clone(),
                source.host.clone(),
                target.host.clone(),
                config.to_path_buf(),
            )?;
            transaction.source_resource = source_resource.clone();
            transaction.target_resource = target_resource.clone();
            transaction
        }
        MoveItem::Resource {
            resource,
            source,
            target,
            ..
        } => Transaction::new_resource(
            resource.clone(),
            source.host.clone(),
            target.host.clone(),
            config.to_path_buf(),
        )?,
        MoveItem::Instance { source, target, .. } => Transaction::new_instance(
            source.instance.clone(),
            source.controller.clone(),
            target.controller.clone(),
            config.to_path_buf(),
        )?,
    };
    child.id = child_id(parent_id, item.id());
    child.data_root_plan = match item {
        MoveItem::Host { data_roots, .. }
        | MoveItem::Service { data_roots, .. }
        | MoveItem::Resource { data_roots, .. } => data_roots
            .iter()
            .map(|root| DataRootPlan {
                name: root.name.clone(),
                source: root.source.clone(),
                target: root.target.clone(),
                excludes: root.excludes.clone(),
            })
            .collect(),
        MoveItem::Instance { .. } => Vec::new(),
    };
    Ok(child)
}

fn child_id(parent: &str, item: &str) -> String {
    format!("{parent}--{item}")
}

fn ordered_items(record: &TransactionRecord, action: Action) -> Result<Vec<String>> {
    let all = record
        .spec
        .items
        .iter()
        .map(|item| item.id().to_owned())
        .collect::<Vec<_>>();
    if !matches!(action, Action::Cutover | Action::Rollback) {
        return Ok(all);
    }

    let mut ordered = Vec::new();
    let mut seen = BTreeSet::new();
    let waves: Box<dyn Iterator<Item = _>> = if action == Action::Rollback {
        Box::new(record.spec.activation_waves.iter().rev())
    } else {
        Box::new(record.spec.activation_waves.iter())
    };
    for wave in waves {
        for item in &wave.items {
            if seen.insert(item.clone()) {
                ordered.push(item.clone());
            }
        }
    }
    for item in all {
        if seen.insert(item.clone()) {
            ordered.push(item);
        }
    }
    Ok(ordered)
}

fn validate_record(record: &TransactionRecord) -> Result<()> {
    if record.schema_version != TRANSACTION_RECORD_SCHEMA_VERSION {
        bail!(
            "unsupported transaction-record schema version {}",
            record.schema_version
        );
    }
    let mut command_ids = BTreeSet::new();
    let mut running_commands = 0;
    for command in &record.command_executions {
        if command.schema_version != COMMAND_PLAN_SCHEMA_VERSION
            || command.id.is_empty()
            || !command_ids.insert(command.id.as_str())
        {
            bail!("transaction has an invalid or duplicate command execution");
        }
        running_commands += usize::from(command.status == CommandStatus::Running);
        let mut step_ids = BTreeSet::new();
        for step in &command.steps {
            if step.version == 0
                || step.id.is_empty()
                || step.description.is_empty()
                || step.executor.is_empty()
                || !step_ids.insert(step.id.as_str())
            {
                bail!("command execution has an invalid or duplicate step");
            }
            validate_sha256(&step.input_sha256, "command step input")?;
            if step.status == StepStatus::Succeeded && step.failure.is_some() {
                bail!("successful command step cannot retain failure evidence");
            }
        }
        if command.status == CommandStatus::Succeeded
            && command
                .steps
                .iter()
                .any(|step| step.status != StepStatus::Succeeded)
        {
            bail!("successful command execution has unfinished steps");
        }
        if command.status == CommandStatus::Failed
            && !command
                .steps
                .iter()
                .any(|step| step.status == StepStatus::Failed)
        {
            bail!("failed command execution has no failed step");
        }
    }
    if running_commands > 1 {
        bail!("transaction has more than one running command execution");
    }
    record.spec.validate()?;
    if !record.config.is_absolute() {
        bail!("transaction record config path must be absolute");
    }
    let expected = record
        .spec
        .items
        .iter()
        .map(|item| item.id().to_owned())
        .collect::<BTreeSet<_>>();
    let actual = record.items.keys().cloned().collect::<BTreeSet<_>>();
    if expected != actual {
        bail!("transaction record item journals do not match its immutable spec");
    }
    for (item, child) in &record.items {
        if child.id != child_id(record.id(), item) || child.config != record.config {
            bail!("transaction item {item:?} journal does not match its parent record");
        }
    }
    if let Some(projection) = &record.projection {
        projection.validate()?;
        if projection.projection_id != record.spec.id
            || projection.intent != serde_json::to_value(&record.spec)?
        {
            bail!("transaction projection does not match immutable transaction intent");
        }
        for (digest, historical) in &record.projection_history {
            historical.validate()?;
            if digest != &historical.projection_sha256
                || historical.projection_id != record.spec.id
                || historical.intent != serde_json::to_value(&record.spec)?
                || digest == &projection.projection_sha256
            {
                bail!("transaction projection history does not match immutable intent");
            }
        }
        for (requirement_digest, authorization) in &record.activation_authorizations {
            validate_sha256(requirement_digest, "activation authorization requirement")?;
            match authorization {
                ActivationAuthorization::RepositoryDeploy {
                    projection_digest,
                    generation,
                    evidence_sha256,
                } => {
                    validate_sha256(projection_digest, "repository activation projection")?;
                    validate_sha256(evidence_sha256, "repository activation evidence")?;
                    if *generation == 0 {
                        bail!("repository activation generation must be greater than zero");
                    }
                    let authorized_projection =
                        record.projection_by_digest(projection_digest).context(
                            "repository activation authorization references an unknown projection",
                        )?;
                    if authorized_projection.generation != *generation
                        || authorized_projection
                            .activation_requirement
                            .as_ref()
                            .map(|requirement| requirement.requirement_sha256.as_str())
                            != Some(requirement_digest.as_str())
                    {
                        bail!(
                            "repository activation authorization does not match its exact projected generation and requirement"
                        );
                    }
                }
                ActivationAuthorization::BrokeredReceipt { receipt } => {
                    if requirement_digest != &receipt.requirement_digest {
                        bail!(
                            "activation authorization key does not match its receipt requirement"
                        );
                    }
                    receipt
                        .validate_identity(&projection.projection_id, &projection.intent_sha256)?;
                    if projection
                        .activation_requirement
                        .as_ref()
                        .is_some_and(|requirement| {
                            requirement.requirement_sha256 == *requirement_digest
                        })
                    {
                        receipt.validate_for(projection)?;
                    }
                }
            }
        }
    } else if !record.activation_authorizations.is_empty() || !record.projection_history.is_empty()
    {
        if record.phase != WorkflowPhase::Closed || record.projection_history.is_empty() {
            bail!(
                "legacy transaction cannot retain projection history or activation authorizations"
            );
        }
        for (digest, historical) in &record.projection_history {
            historical.validate()?;
            if digest != &historical.projection_sha256
                || historical.projection_id != record.spec.id
                || historical.intent != serde_json::to_value(&record.spec)?
            {
                bail!("closed transaction projection history does not match immutable intent");
            }
        }
        for (requirement_digest, authorization) in &record.activation_authorizations {
            validate_sha256(requirement_digest, "activation authorization requirement")?;
            match authorization {
                ActivationAuthorization::RepositoryDeploy {
                    projection_digest,
                    generation,
                    evidence_sha256,
                } => {
                    validate_sha256(projection_digest, "repository activation projection")?;
                    validate_sha256(evidence_sha256, "repository activation evidence")?;
                    let authorized_projection =
                        record.projection_by_digest(projection_digest).context(
                            "closed transaction authorization references an unknown projection",
                        )?;
                    if *generation == 0
                        || authorized_projection.generation != *generation
                        || authorized_projection
                            .activation_requirement
                            .as_ref()
                            .map(|requirement| requirement.requirement_sha256.as_str())
                            != Some(requirement_digest.as_str())
                    {
                        bail!("closed transaction authorization does not match its projection");
                    }
                }
                ActivationAuthorization::BrokeredReceipt { receipt } => {
                    if requirement_digest != &receipt.requirement_digest {
                        bail!("closed transaction receipt key does not match its requirement");
                    }
                    let projection = record
                        .projection_history
                        .values()
                        .next()
                        .context("closed transaction has no projection identity")?;
                    receipt
                        .validate_identity(&projection.projection_id, &projection.intent_sha256)?;
                }
            }
        }
    }
    Ok(())
}

fn validate_sha256(value: &str, label: &str) -> Result<()> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        bail!("{label} must be a lowercase SHA-256 digest");
    }
    Ok(())
}

fn validate_workflow_transition(record: &TransactionRecord, action: Action) -> Result<()> {
    let valid = match action {
        Action::Plan => record.phase == WorkflowPhase::Planned,
        Action::Setup => record.phase == WorkflowPhase::Planned,
        Action::Seed => matches!(record.phase, WorkflowPhase::Setup | WorkflowPhase::Seeded),
        Action::Prepare => matches!(
            record.phase,
            WorkflowPhase::Setup
                | WorkflowPhase::Seeded
                | WorkflowPhase::Prepared
                | WorkflowPhase::Cutover
        ),
        Action::Verify => matches!(
            record.phase,
            WorkflowPhase::Prepared | WorkflowPhase::Verified
        ),
        Action::Cutover => matches!(
            record.phase,
            WorkflowPhase::Prepared | WorkflowPhase::Verified
        ),
        Action::Rollback => {
            matches!(
                record.phase,
                WorkflowPhase::Planned
                    | WorkflowPhase::Setup
                    | WorkflowPhase::Seeded
                    | WorkflowPhase::Prepared
                    | WorkflowPhase::Verified
                    | WorkflowPhase::Cutover
            ) || record.pending_action.is_some()
        }
        Action::Close => matches!(
            record.phase,
            WorkflowPhase::Cutover | WorkflowPhase::RolledBack
        ),
    };
    if !valid {
        bail!(
            "cannot {} transaction in {:?} phase",
            action.as_str(),
            record.phase
        );
    }
    Ok(())
}

fn workflow_phase_after(action: Action) -> WorkflowPhase {
    match action {
        Action::Plan => WorkflowPhase::Planned,
        Action::Setup => WorkflowPhase::Setup,
        Action::Seed => WorkflowPhase::Seeded,
        Action::Prepare => WorkflowPhase::Prepared,
        Action::Verify => WorkflowPhase::Verified,
        Action::Cutover => WorkflowPhase::Cutover,
        Action::Rollback => WorkflowPhase::RolledBack,
        Action::Close => WorkflowPhase::Closed,
    }
}

fn event(record: &mut TransactionRecord, action: Action, message: impl Into<String>) -> Result<()> {
    let now = now_unix_ms()?;
    record.updated_at_unix_ms = now;
    record.events.push(WorkflowEvent {
        at_unix_ms: now,
        action,
        message: message.into(),
    });
    Ok(())
}

fn atomic_json<T: Serialize>(destination: &Path, value: &T) -> Result<()> {
    let directory = destination
        .parent()
        .context("state destination has no parent directory")?;
    fs::create_dir_all(directory)?;
    let name = destination
        .file_name()
        .and_then(OsStr::to_str)
        .context("state destination has no UTF-8 filename")?;
    let temporary = directory.join(format!(
        ".{name}.{}.{}.tmp",
        std::process::id(),
        now_unix_ms()?
    ));
    let file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&temporary)
        .with_context(|| format!("failed to create state file {}", temporary.display()))?;
    let mut writer = BufWriter::new(file);
    serde_json::to_writer_pretty(&mut writer, value)?;
    writer.write_all(b"\n")?;
    writer.flush()?;
    writer.get_ref().sync_all()?;
    fs::rename(&temporary, destination)?;
    File::open(directory)?.sync_all()?;
    Ok(())
}

fn now_unix_ms() -> Result<u128> {
    Ok(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .context("system clock is before Unix epoch")?
        .as_millis())
}

#[cfg(test)]
mod tests {
    use tempfile::TempDir;

    use super::*;
    use crate::agent_adapter::HostManagerConfig;
    use crate::backup_runtime::{BackupRecord, BackupStore};
    use crate::projection::{
        MoveItemObservation, MovePhase, MoveProjectionObservation, MoveProjector,
    };
    use crate::workflow::{
        BackupDestination, BackupItem, BackupSpec, HostEndpoint, MoveItem, TransactionSpec,
    };

    fn service(id: &str, name: &str, source: &str, target: &str) -> MoveItem {
        MoveItem::Service {
            id: id.to_owned(),
            service: name.to_owned(),
            source_resource: None,
            target_resource: None,
            source: HostEndpoint {
                host: source.to_owned(),
                instance: None,
            },
            target: HostEndpoint {
                host: target.to_owned(),
                instance: None,
            },
            data_roots: Vec::new(),
        }
    }

    #[test]
    fn record_has_deterministic_child_ids_and_immutable_config() {
        let spec = TransactionSpec::new(
            Some("move-demo"),
            vec![service("chat", "zulip", "source", "target")],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        let record = TransactionRecord::new(spec, "/tmp/config.json".into()).unwrap();
        assert_eq!(record.items["chat"].id, "move-demo--chat");
        assert_eq!(
            record.items["chat"].config,
            PathBuf::from("/tmp/config.json")
        );
    }

    #[test]
    fn command_execution_persists_ordered_step_success_and_failure() {
        let spec = TransactionSpec::new(
            Some("move-command"),
            vec![service("chat", "zulip", "source", "target")],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        let mut record = TransactionRecord::new(spec, "/tmp/config.json".into()).unwrap();
        let execution = record
            .begin_command(
                LifecycleCommand::Prepare,
                LifecycleState::Prepared,
                None,
                ["check", "mutate", "verify"],
            )
            .unwrap();
        assert!(record.start_command_step(execution, "mutate").is_err());
        record.start_command_step(execution, "check").unwrap();
        record
            .complete_command_step(execution, "check", Some(serde_json::json!({"ok": true})))
            .unwrap();
        record.start_command_step(execution, "mutate").unwrap();
        record
            .fail_command_step(execution, "mutate", "terminal failure")
            .unwrap();
        validate_record(&record).unwrap();
        assert_eq!(record.command_executions[0].status, CommandStatus::Failed);

        let successor = record
            .begin_command(
                LifecycleCommand::Prepare,
                LifecycleState::Prepared,
                None,
                ["check", "mutate", "verify"],
            )
            .unwrap();
        assert_ne!(execution, successor);
        assert!(record.command_executions[successor].id.ends_with("/0002"));
    }

    #[test]
    fn explicit_rollback_can_supersede_only_a_running_run() {
        let spec = TransactionSpec::new(
            Some("move-rollback"),
            vec![service("chat", "zulip", "source", "target")],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        let mut record = TransactionRecord::new(spec, "/tmp/config.json".into()).unwrap();
        record
            .begin_command(
                LifecycleCommand::Run,
                LifecycleState::TargetActive,
                None,
                ["activate", "verify"],
            )
            .unwrap();
        assert!(
            record
                .fail_running_command_if(LifecycleCommand::Prepare, "wrong command")
                .is_err()
        );
        assert!(
            record
                .fail_running_command_if(LifecycleCommand::Run, "rollback selected")
                .unwrap()
        );
        let close = record
            .begin_command(
                LifecycleCommand::Close,
                LifecycleState::ClosedOnSource,
                Some(CloseDecision::Rollback),
                ["close"],
            )
            .unwrap();
        assert_eq!(record.command_executions[0].status, CommandStatus::Failed);
        assert_eq!(
            record.command_executions[close].command,
            LifecycleCommand::Close
        );
    }

    #[test]
    fn automatic_close_does_not_treat_phase_alone_as_run_evidence() {
        let spec = TransactionSpec::new(
            Some("move-close-evidence"),
            vec![service("chat", "zulip", "source", "target")],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        let mut record = TransactionRecord::new(spec, "/tmp/config.json".into()).unwrap();
        record.phase = WorkflowPhase::Cutover;
        record.current_run_succeeded = false;
        assert_eq!(
            record.select_close_decision(None).unwrap(),
            CloseDecision::Rollback
        );
    }

    #[test]
    fn legacy_transaction_record_without_projection_remains_readable() {
        let spec = TransactionSpec::new(
            Some("move-legacy"),
            vec![service("chat", "zulip", "source", "target")],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        let record = TransactionRecord::new(spec, "/tmp/config.json".into()).unwrap();
        let mut value = serde_json::to_value(record).unwrap();
        value.as_object_mut().unwrap().remove("projection");
        let decoded: TransactionRecord = serde_json::from_value(value).unwrap();
        assert!(decoded.projection.is_none());
        validate_record(&decoded).unwrap();
    }

    #[test]
    fn projection_history_binds_repository_authorization_to_its_exact_generation() {
        let config: HostManagerConfig = serde_json::from_value(serde_json::json!({
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
                    "executor": "source",
                    "phase_projection": {"executor": "proxy", "resource": "service:nginx"}
                },
                "deploy-rollback": {
                    "executor": "source",
                    "phase_projection": {"executor": "proxy", "resource": "service:nginx"}
                }
            }
        }))
        .unwrap();
        let mut spec = TransactionSpec::new(
            Some("move-history"),
            vec![service("chat", "zulip", "source", "target")],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        spec.declarative_scope = Some("demo".to_owned());
        let seeded = MoveProjector::derive(&spec, &config, MovePhase::Seeded, None, None).unwrap();
        let prepared =
            MoveProjector::derive(&spec, &config, MovePhase::Prepared, Some(&seeded), None)
                .unwrap();
        let cutover =
            MoveProjector::derive(&spec, &config, MovePhase::Cutover, Some(&prepared), None)
                .unwrap();
        let mut observation = MoveProjectionObservation::default();
        observation.insert(
            "chat",
            MoveItemObservation {
                source_held: true,
                target_ever_started: true,
                ..MoveItemObservation::default()
            },
        );
        let rolled_back = MoveProjector::derive_with_observation(
            &spec,
            &config,
            MovePhase::RolledBack,
            Some(&cutover),
            None,
            &observation,
        )
        .unwrap();
        let mut record = TransactionRecord::new(spec, "/tmp/config.json".into()).unwrap();
        record.set_projection(seeded).unwrap();
        record.set_projection(prepared).unwrap();
        record.set_projection(cutover.clone()).unwrap();
        record.set_projection(rolled_back).unwrap();
        let requirement = cutover.activation_requirement.as_ref().unwrap();
        record.activation_authorizations.insert(
            requirement.requirement_sha256.clone(),
            ActivationAuthorization::RepositoryDeploy {
                projection_digest: cutover.projection_sha256.clone(),
                generation: cutover.generation,
                evidence_sha256: "a".repeat(64),
            },
        );
        validate_record(&record).unwrap();

        let ActivationAuthorization::RepositoryDeploy { generation, .. } = record
            .activation_authorizations
            .get_mut(&requirement.requirement_sha256)
            .unwrap()
        else {
            unreachable!();
        };
        *generation += 1;
        assert!(
            validate_record(&record)
                .unwrap_err()
                .to_string()
                .contains("exact projected generation")
        );
    }

    #[test]
    fn store_replays_same_intent_and_rejects_conflicting_authority() {
        let state = TempDir::new().unwrap();
        let store = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let first = TransactionRecord::new(
            TransactionSpec::new(
                Some("move-one"),
                vec![service("chat", "zulip", "source", "target")],
                Vec::new(),
                Vec::new(),
            )
            .unwrap(),
            "/tmp/config.json".into(),
        )
        .unwrap();
        assert!(matches!(
            store.register(first.clone()).unwrap(),
            WorkflowRegistration::Created(_)
        ));

        let mut progressed = first.clone();
        progressed.phase = WorkflowPhase::Setup;
        progressed.pending_action = Some(Action::Seed);
        progressed
            .record_reinvocation("existing progress must survive registration")
            .unwrap();
        store.save(&progressed).unwrap();

        let WorkflowRegistration::Existing(existing) = store.register(first).unwrap() else {
            panic!("matching registration should load the existing transaction");
        };
        assert_eq!(existing.phase, WorkflowPhase::Setup);
        assert_eq!(existing.pending_action, Some(Action::Seed));
        assert_eq!(
            existing.events.last().unwrap().message,
            "existing progress must survive registration"
        );

        let conflict = TransactionRecord::new(
            TransactionSpec::new(
                Some("move-two"),
                vec![service("chat", "zulip", "source", "other")],
                Vec::new(),
                Vec::new(),
            )
            .unwrap(),
            "/tmp/config.json".into(),
        )
        .unwrap();
        assert!(
            store
                .register(conflict)
                .unwrap_err()
                .to_string()
                .contains("overlaps open transaction")
        );

        let conflict = TransactionRecord::new(
            TransactionSpec::new(
                Some("move-three"),
                vec![service("chat", "zulip", "source", "elsewhere")],
                Vec::new(),
                Vec::new(),
            )
            .unwrap(),
            "/tmp/config.json".into(),
        )
        .unwrap();
        assert!(
            WorkflowStore::validate_registration(state.path(), &conflict)
                .unwrap_err()
                .to_string()
                .contains("overlaps open transaction")
        );
    }

    #[test]
    fn registration_validation_is_read_only_for_an_empty_state_root() {
        let state = TempDir::new().unwrap();
        let candidate = TransactionRecord::new(
            TransactionSpec::new(
                Some("move-dry"),
                vec![service("chat", "zulip", "source", "target")],
                Vec::new(),
                Vec::new(),
            )
            .unwrap(),
            "/tmp/config.json".into(),
        )
        .unwrap();
        WorkflowStore::validate_registration(state.path(), &candidate).unwrap();
        assert!(!state.path().join("authority-lock").exists());
        assert!(!state.path().join("workflow-transactions").exists());
    }

    #[test]
    fn read_only_workflow_store_never_creates_or_saves_state() {
        let state = TempDir::new().unwrap();
        let candidate = TransactionRecord::new(
            TransactionSpec::new(
                Some("move-read-only"),
                vec![service("chat", "zulip", "source", "target")],
                Vec::new(),
                Vec::new(),
            )
            .unwrap(),
            "/tmp/config.json".into(),
        )
        .unwrap();
        let store = WorkflowStore::read_only(state.path().to_path_buf());
        assert!(store.list().unwrap().is_empty());
        assert!(store.save(&candidate).is_err());
        assert!(store.register(candidate).is_err());
        assert!(
            store
                .child_store("move-read-only")
                .unwrap()
                .list()
                .unwrap()
                .is_empty()
        );
        assert!(!state.path().join("authority-lock").exists());
        assert!(!state.path().join("workflow-transactions").exists());
        assert!(!state.path().join("workflow-items").exists());
    }

    #[test]
    fn parent_record_refreshes_durable_child_progress_after_interruption() {
        let state = TempDir::new().unwrap();
        let store = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let mut record = TransactionRecord::new(
            TransactionSpec::new(
                Some("move-refresh"),
                vec![service("chat", "zulip", "source", "target")],
                Vec::new(),
                Vec::new(),
            )
            .unwrap(),
            "/tmp/config.json".into(),
        )
        .unwrap();
        store.save(&record).unwrap();

        let child_store = store.child_store(record.id()).unwrap();
        let child = record.items.get_mut("chat").unwrap();
        child.pending_action = Some(Action::Rollback);
        child.active_step = Some("deploy-rollback".to_owned());
        child.active_job_id = Some("move-refresh--chat-rollback-deploy-rollback".to_owned());
        child_store.save(child).unwrap();
        drop(child_store);

        record.items.get_mut("chat").unwrap().active_step = None;
        record.items.get_mut("chat").unwrap().active_job_id = None;
        refresh_child_journals(&store, &mut record).unwrap();

        assert_eq!(
            record.items["chat"].active_step.as_deref(),
            Some("deploy-rollback")
        );
        assert_eq!(
            record.items["chat"].active_job_id.as_deref(),
            Some("move-refresh--chat-rollback-deploy-rollback")
        );
    }

    #[test]
    fn clean_deployed_closeout_does_not_require_failed_job_supersession() {
        let state = TempDir::new().unwrap();
        let store = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let mut record = TransactionRecord::new(
            TransactionSpec::new(
                Some("move-close-clean"),
                vec![service("chat", "zulip", "source", "target")],
                Vec::new(),
                Vec::new(),
            )
            .unwrap(),
            "/tmp/config.json".into(),
        )
        .unwrap();
        record.phase = WorkflowPhase::Cutover;

        assert!(!has_pending_close_workflow_action(&store, &mut record).unwrap());
    }

    #[test]
    fn deployed_closeout_adopts_a_retained_close_action() {
        let state = TempDir::new().unwrap();
        let store = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let mut record = TransactionRecord::new(
            TransactionSpec::new(
                Some("move-close-retry"),
                vec![service("chat", "zulip", "source", "target")],
                Vec::new(),
                Vec::new(),
            )
            .unwrap(),
            "/tmp/config.json".into(),
        )
        .unwrap();
        record.phase = WorkflowPhase::Cutover;
        record.pending_action = Some(Action::Close);
        record.items.get_mut("chat").unwrap().pending_action = Some(Action::Close);

        assert!(has_pending_close_workflow_action(&store, &mut record).unwrap());
    }

    #[test]
    fn deployed_closeout_rejects_orphaned_child_work() {
        let state = TempDir::new().unwrap();
        let store = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let mut record = TransactionRecord::new(
            TransactionSpec::new(
                Some("move-close-orphan"),
                vec![service("chat", "zulip", "source", "target")],
                Vec::new(),
                Vec::new(),
            )
            .unwrap(),
            "/tmp/config.json".into(),
        )
        .unwrap();
        record.phase = WorkflowPhase::Cutover;
        record.items.get_mut("chat").unwrap().pending_action = Some(Action::Close);

        let error = has_pending_close_workflow_action(&store, &mut record).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("without a parent pending action")
        );
    }

    #[test]
    fn workflow_action_epoch_allocates_retry_identity_before_runtime() {
        let state = TempDir::new().unwrap();
        let store = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let mut record = TransactionRecord::new(
            TransactionSpec::new(
                Some("move-retry-identity"),
                vec![service("chat", "zulip", "source", "target")],
                Vec::new(),
                Vec::new(),
            )
            .unwrap(),
            "/tmp/config.json".into(),
        )
        .unwrap();
        record.phase = WorkflowPhase::Prepared;
        let child = record.items.get_mut("chat").unwrap();
        child
            .completed_steps
            .insert("cutover:activate-target".to_owned());
        store.save(&record).unwrap();
        store
            .child_store(record.id())
            .unwrap()
            .save(&record.items["chat"])
            .unwrap();

        begin_workflow_action(&store, &mut record, Action::Cutover).unwrap();

        let child = store
            .child_store(record.id())
            .unwrap()
            .load(&record.items["chat"].id)
            .unwrap();
        assert_eq!(record.pending_action, Some(Action::Cutover));
        assert_eq!(
            crate::deterministic_job_id(&child, Action::Cutover, "activate-target"),
            "move-retry-identity--chat-cutover-activate-target-attempt-1"
        );
        assert!(!child.completed_steps.contains("cutover:activate-target"));
    }

    #[test]
    fn prepare_retires_a_terminal_failed_run_and_starts_a_fresh_epoch() {
        let state = TempDir::new().unwrap();
        let store = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let mut record = TransactionRecord::new(
            TransactionSpec::new(
                Some("move-reprepare"),
                vec![service("chat", "zulip", "source", "target")],
                Vec::new(),
                Vec::new(),
            )
            .unwrap(),
            "/tmp/config.json".into(),
        )
        .unwrap();
        record.phase = WorkflowPhase::Prepared;
        record.lifecycle_state = Some(LifecycleState::Running);
        record.pending_action = Some(Action::Cutover);
        record.current_run_succeeded = true;
        let run = record
            .begin_command(
                LifecycleCommand::Run,
                LifecycleState::TargetActive,
                None,
                [
                    "runtime.reconcile-target-active",
                    "state.verify-target-active",
                ],
            )
            .unwrap();
        record
            .start_command_step(run, "runtime.reconcile-target-active")
            .unwrap();

        let child = record.items.get_mut("chat").unwrap();
        child.phase = crate::Phase::Prepared;
        child.pending_action = Some(Action::Cutover);
        child.active_step = Some("activate-target".to_owned());
        child.active_job_id = Some(crate::deterministic_job_id(
            child,
            Action::Cutover,
            "activate-target",
        ));
        child.target_ever_started = true;
        child
            .completed_steps
            .insert("prepare:backup-target".to_owned());
        store.save(&record).unwrap();
        store
            .child_store(record.id())
            .unwrap()
            .save(&record.items["chat"])
            .unwrap();

        let retired =
            supersede_terminal_failed_run_for_prepare(&store, &mut record, |_item, _child| {
                Ok("failed".to_owned())
            })
            .unwrap();
        assert_eq!(retired, ["move-reprepare--chat-cutover-activate-target"]);
        assert_eq!(record.command_executions[run].status, CommandStatus::Failed);
        assert_eq!(record.pending_action, None);
        assert_eq!(record.lifecycle_state, Some(LifecycleState::Prepared));
        assert!(!record.current_run_succeeded);
        assert_eq!(record.items["chat"].pending_action, None);
        assert_eq!(record.items["chat"].active_job_id, None);

        begin_workflow_action(&store, &mut record, Action::Prepare).unwrap();
        assert_eq!(record.pending_action, Some(Action::Prepare));
        assert_eq!(record.lifecycle_state, Some(LifecycleState::Preparing));
        assert!(
            !record.items["chat"]
                .completed_steps
                .contains("prepare:backup-target")
        );
        assert_eq!(
            record.items["chat"]
                .job_generations
                .get("prepare:backup-target"),
            Some(&1)
        );
    }

    #[test]
    fn prepare_cannot_supersede_an_unresolved_run_job() {
        let state = TempDir::new().unwrap();
        let store = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let mut record = TransactionRecord::new(
            TransactionSpec::new(
                Some("move-running"),
                vec![service("chat", "zulip", "source", "target")],
                Vec::new(),
                Vec::new(),
            )
            .unwrap(),
            "/tmp/config.json".into(),
        )
        .unwrap();
        record.phase = WorkflowPhase::Prepared;
        record.pending_action = Some(Action::Cutover);
        let child = record.items.get_mut("chat").unwrap();
        child.pending_action = Some(Action::Cutover);
        child.active_step = Some("activate-target".to_owned());
        child.active_job_id = Some(crate::deterministic_job_id(
            child,
            Action::Cutover,
            "activate-target",
        ));
        store.save(&record).unwrap();
        store
            .child_store(record.id())
            .unwrap()
            .save(&record.items["chat"])
            .unwrap();

        let error =
            supersede_terminal_failed_run_for_prepare(&store, &mut record, |_item, _child| {
                Ok("running".to_owned())
            })
            .unwrap_err();
        assert!(error.to_string().contains("unresolved run"));
        assert_eq!(record.pending_action, Some(Action::Cutover));
        assert_eq!(record.items["chat"].pending_action, Some(Action::Cutover));
        assert!(record.items["chat"].active_job_id.is_some());
    }

    #[test]
    fn read_only_matching_does_not_create_manager_state() {
        let state = TempDir::new().unwrap();
        let candidate = TransactionRecord::new(
            TransactionSpec::new(
                Some("move-read-only"),
                vec![service("chat", "zulip", "source", "target")],
                Vec::new(),
                Vec::new(),
            )
            .unwrap(),
            "/tmp/config.json".into(),
        )
        .unwrap();

        assert!(
            WorkflowStore::load_matching(state.path(), &candidate)
                .unwrap()
                .is_none()
        );
        assert!(!state.path().join("workflow-transactions").exists());
        assert!(!state.path().join("authority-lock").exists());
    }

    #[test]
    fn activation_waves_control_forward_and_reverse_order() {
        use crate::workflow::ActivationWave;

        let spec = TransactionSpec::new(
            Some("move-wave"),
            vec![
                service("app", "app", "s1", "t1"),
                service("db", "db", "s2", "t2"),
            ],
            Vec::new(),
            vec![
                ActivationWave {
                    id: "database".to_owned(),
                    items: vec!["db".to_owned()],
                },
                ActivationWave {
                    id: "application".to_owned(),
                    items: vec!["app".to_owned()],
                },
            ],
        )
        .unwrap();
        let record = TransactionRecord::new(spec, "/tmp/config.json".into()).unwrap();
        assert_eq!(
            ordered_items(&record, Action::Cutover).unwrap(),
            vec!["db", "app"]
        );
        assert_eq!(
            ordered_items(&record, Action::Rollback).unwrap(),
            vec!["app", "db"]
        );
    }

    #[test]
    fn transaction_creation_rejects_an_active_backup_authority() {
        let state = TempDir::new().unwrap();
        let backup = BackupRecord::new(
            BackupSpec::new(
                Some("backup-chat"),
                vec![BackupItem::Service {
                    id: "chat".to_owned(),
                    service: "zulip".to_owned(),
                    source: HostEndpoint {
                        host: "source".to_owned(),
                        instance: None,
                    },
                    data_roots: Vec::new(),
                }],
                vec![BackupDestination::ControllerDirectory {
                    path: "/srv/backups".into(),
                }],
                Vec::new(),
            )
            .unwrap(),
        )
        .unwrap();
        let backup_store = BackupStore::open(state.path().to_path_buf()).unwrap();
        backup_store.create(&backup).unwrap();
        drop(backup_store);

        let transaction = TransactionRecord::new(
            TransactionSpec::new(
                Some("move-chat"),
                vec![service("chat", "zulip", "source", "target")],
                Vec::new(),
                Vec::new(),
            )
            .unwrap(),
            "/tmp/config.json".into(),
        )
        .unwrap();
        let workflow_store = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        assert!(
            workflow_store
                .register(transaction)
                .unwrap_err()
                .to_string()
                .contains("overlaps active backup")
        );
    }

    #[test]
    fn initial_move_reinvocation_resumes_only_before_the_prepare_boundary() {
        let spec = TransactionSpec::new(
            Some("move-reinvoke"),
            vec![service("chat", "zulip", "source", "target")],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        let mut record = TransactionRecord::new(spec, "/tmp/config.json".into()).unwrap();

        assert_eq!(
            record.initial_move_continuation(),
            InitialMoveContinuation::Resume(Action::Setup)
        );
        record.phase = WorkflowPhase::Setup;
        assert_eq!(
            record.initial_move_continuation(),
            InitialMoveContinuation::Resume(Action::Seed)
        );
        record.pending_action = Some(Action::Seed);
        assert_eq!(
            record.initial_move_continuation(),
            InitialMoveContinuation::Resume(Action::Seed)
        );
        record.pending_action = None;
        record.phase = WorkflowPhase::Seeded;
        assert_eq!(
            record.initial_move_continuation(),
            InitialMoveContinuation::Complete
        );

        record.pending_action = Some(Action::Prepare);
        assert_eq!(
            record.initial_move_continuation(),
            InitialMoveContinuation::RequiresForce(Some(Action::Prepare))
        );
        record.pending_action = None;
        for phase in [
            WorkflowPhase::Prepared,
            WorkflowPhase::Verified,
            WorkflowPhase::Cutover,
            WorkflowPhase::RolledBack,
            WorkflowPhase::Closed,
        ] {
            record.phase = phase;
            assert_eq!(
                record.initial_move_continuation(),
                InitialMoveContinuation::RequiresForce(None)
            );
        }
    }
}
