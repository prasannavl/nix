use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use abird_host_agent::resource::DataRootPlan;
use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};

pub mod agent_adapter;
pub mod backup_runtime;
pub mod instance_backup;
pub mod offline_store;
pub mod physical;
pub mod programs;
pub mod progress;
pub mod repository;
pub mod selector;
pub mod service_registry;
pub mod ssh_runtime;
pub mod workflow;
pub mod workflow_runtime;

const SCHEMA_VERSION: u32 = 2;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Action {
    Plan,
    Setup,
    Seed,
    Prepare,
    Verify,
    Cutover,
    Rollback,
    Close,
}

impl Action {
    pub fn is_mutating(self) -> bool {
        self != Self::Plan
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Plan => "plan",
            Self::Setup => "setup",
            Self::Seed => "seed",
            Self::Prepare => "prepare",
            Self::Verify => "verify",
            Self::Cutover => "cutover",
            Self::Rollback => "rollback",
            Self::Close => "close",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Phase {
    Planned,
    Setup,
    Seeded,
    Prepared,
    Verified,
    Cutover,
    RolledBack,
    Closed,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ResourceKind {
    Host,
    Service,
    Resource,
    Instance,
}

impl ResourceKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Host => "host",
            Self::Service => "service",
            Self::Resource => "resource",
            Self::Instance => "instance",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Event {
    pub at_unix_ms: u128,
    pub action: Action,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Transaction {
    pub schema_version: u32,
    pub id: String,
    pub resource_kind: ResourceKind,
    pub resource: String,
    pub source: String,
    pub target: String,
    pub config: PathBuf,
    pub phase: Phase,
    pub pending_action: Option<Action>,
    pub completed_steps: BTreeSet<String>,
    #[serde(default)]
    pub active_step: Option<String>,
    #[serde(default)]
    pub active_job_id: Option<String>,
    /// Per-step generations for explicit replacement of terminal failed jobs.
    /// Generation zero retains the original deterministic job ID.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub job_generations: BTreeMap<String, u32>,
    /// Immutable named source/target data-root mapping resolved before the first copy.
    #[serde(default)]
    pub data_root_plan: Vec<DataRootPlan>,
    /// Runtime state captured by a typed adapter before the source is stopped.
    /// `None` means that no authoritative stop has completed yet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_was_active: Option<bool>,
    pub target_ever_started: bool,
    pub last_error: Option<String>,
    pub created_at_unix_ms: u128,
    pub updated_at_unix_ms: u128,
    pub events: Vec<Event>,
}

impl Transaction {
    pub fn new_host(host: String, source: String, target: String, config: PathBuf) -> Result<Self> {
        Self::new(ResourceKind::Host, host, source, target, config)
    }

    pub fn new_service(
        service: String,
        source: String,
        target: String,
        config: PathBuf,
    ) -> Result<Self> {
        Self::new(ResourceKind::Service, service, source, target, config)
    }

    pub fn new_instance(
        instance: String,
        source: String,
        target: String,
        config: PathBuf,
    ) -> Result<Self> {
        Self::new(ResourceKind::Instance, instance, source, target, config)
    }

    pub fn new_resource(
        resource: String,
        source: String,
        target: String,
        config: PathBuf,
    ) -> Result<Self> {
        Self::new(ResourceKind::Resource, resource, source, target, config)
    }

    fn new(
        resource_kind: ResourceKind,
        resource: String,
        source: String,
        target: String,
        config: PathBuf,
    ) -> Result<Self> {
        validate_config(&config)?;
        if resource.trim().is_empty() || source.trim().is_empty() || target.trim().is_empty() {
            bail!("resource, source, and target must be non-empty");
        }
        if source == target && resource_kind != ResourceKind::Instance {
            bail!("source and target must be different hosts");
        }

        let now = now_unix_ms()?;
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|error| anyhow!("system clock is before Unix epoch: {error}"))?
            .as_nanos();
        Ok(Self {
            schema_version: SCHEMA_VERSION,
            id: format!("migration-{nonce}-{}", std::process::id()),
            resource_kind,
            resource,
            source,
            target,
            config,
            phase: Phase::Planned,
            pending_action: None,
            completed_steps: BTreeSet::new(),
            active_step: None,
            active_job_id: None,
            job_generations: BTreeMap::new(),
            data_root_plan: Vec::new(),
            source_was_active: None,
            target_ever_started: false,
            last_error: None,
            created_at_unix_ms: now,
            updated_at_unix_ms: now,
            events: Vec::new(),
        })
    }

    pub fn action_steps(&self, action: Action) -> Result<Vec<&'static str>> {
        validate_action_request(self, action)?;
        Ok(steps_for(action, self))
    }
}

pub trait Adapter {
    fn run(&mut self, operation: &str, transaction: &mut Transaction) -> Result<()>;
}

pub struct Store {
    root: PathBuf,
    _lock: File,
}

impl Store {
    pub fn open(root: PathBuf) -> Result<Self> {
        fs::create_dir_all(root.join("transactions"))
            .with_context(|| format!("failed to create state directory {}", root.display()))?;
        let lock_path = root.join("lock");
        let lock = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&lock_path)
            .with_context(|| format!("failed to open state lock {}", lock_path.display()))?;
        lock.lock()
            .with_context(|| format!("failed to lock state directory {}", root.display()))?;
        Ok(Self { root, _lock: lock })
    }

    pub fn save(&self, transaction: &Transaction) -> Result<()> {
        validate_id(&transaction.id)?;
        let directory = self.root.join("transactions");
        let destination = directory.join(format!("{}.json", transaction.id));
        let temporary = directory.join(format!(
            ".{}.{}.{}.tmp",
            transaction.id,
            std::process::id(),
            now_unix_ms()?
        ));

        let file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .with_context(|| format!("failed to create journal {}", temporary.display()))?;
        let mut writer = BufWriter::new(file);
        serde_json::to_writer_pretty(&mut writer, transaction)
            .context("failed to serialize transaction journal")?;
        writer.write_all(b"\n")?;
        writer.flush()?;
        writer.get_ref().sync_all()?;
        fs::rename(&temporary, &destination).with_context(|| {
            format!(
                "failed to replace transaction journal {}",
                destination.display()
            )
        })?;
        File::open(&directory)?.sync_all()?;
        Ok(())
    }

    pub fn load(&self, id: &str) -> Result<Transaction> {
        validate_id(id)?;
        let path = self.root.join("transactions").join(format!("{id}.json"));
        let reader =
            BufReader::new(File::open(&path).with_context(|| {
                format!("failed to open transaction journal {}", path.display())
            })?);
        let transaction: Transaction = serde_json::from_reader(reader)
            .with_context(|| format!("failed to parse transaction journal {}", path.display()))?;
        if transaction.schema_version != SCHEMA_VERSION {
            bail!(
                "unsupported transaction schema version {}",
                transaction.schema_version
            );
        }
        if transaction.id != id {
            bail!("transaction journal ID does not match its filename");
        }
        Ok(transaction)
    }

    pub fn load_optional(&self, id: &str) -> Result<Option<Transaction>> {
        validate_id(id)?;
        let path = self.root.join("transactions").join(format!("{id}.json"));
        if !path.exists() {
            return Ok(None);
        }
        self.load(id).map(Some)
    }

    pub fn list(&self) -> Result<Vec<Transaction>> {
        let mut transactions = Vec::new();
        for entry in fs::read_dir(self.root.join("transactions"))? {
            let entry = entry?;
            let path = entry.path();
            if path.extension() != Some(OsStr::new("json")) {
                continue;
            }
            let Some(id) = path.file_stem().and_then(OsStr::to_str) else {
                continue;
            };
            transactions.push(self.load(id)?);
        }
        transactions.sort_by_key(|transaction| transaction.created_at_unix_ms);
        Ok(transactions)
    }
}

pub fn execute_action<A: Adapter>(
    store: &Store,
    transaction: &mut Transaction,
    action: Action,
    adapter: &mut A,
) -> Result<()> {
    validate_action_request(transaction, action)?;

    if action == Action::Rollback
        && transaction.pending_action != Some(Action::Rollback)
        && transaction.active_step.is_some()
    {
        reconcile_active_job(store, transaction, adapter)?;
    }

    match transaction.pending_action {
        Some(pending) if pending != action && action != Action::Rollback => {
            bail!(
                "transaction has pending {} action; resume it or explicitly roll back",
                pending.as_str()
            );
        }
        Some(pending) if pending != action => {
            record(
                transaction,
                action,
                format!("explicit rollback superseded pending {}", pending.as_str()),
            )?;
            transaction.pending_action = Some(Action::Rollback);
        }
        None => {
            transaction.pending_action = Some(action);
            transaction.last_error = None;
            record(transaction, action, "action started")?;
        }
        Some(_) => {}
    }
    store.save(transaction)?;

    let steps = steps_for(action, transaction);
    for operation in steps {
        let step_id = format!("{}:{operation}", action.as_str());
        if transaction.completed_steps.contains(&step_id) {
            continue;
        }

        prepare_active_job(store, transaction, action, operation)?;

        // Activation is one durable target-local release-and-start job. Persist
        // the conservative fact that it may become a writer before submission;
        // a crash or ambiguous adapter response then forces reverse copy.
        if action == Action::Cutover && operation == "activate-target" {
            transaction.target_ever_started = true;
            record(transaction, action, "target start may have been attempted")?;
            store.save(transaction)?;
        }

        if let Err(error) = adapter.run(operation, transaction) {
            transaction.last_error = Some(format!("{operation}: {error:#}"));
            record(transaction, action, format!("step {operation} failed"))?;
            store.save(transaction)?;
            return Err(error).with_context(|| format!("migration step {operation} failed"));
        }

        transaction.completed_steps.insert(step_id);
        transaction.active_step = None;
        transaction.active_job_id = None;
        transaction.last_error = None;
        record(transaction, action, format!("step {operation} completed"))?;
        store.save(transaction)?;
    }

    transaction.phase = phase_after(action);
    transaction.pending_action = None;
    transaction.last_error = None;
    record(transaction, action, "action completed")?;
    store.save(transaction)
}

fn prepare_active_job(
    store: &Store,
    transaction: &mut Transaction,
    action: Action,
    operation: &str,
) -> Result<()> {
    let expected_job_id = job_id(transaction, action, operation);
    match (&transaction.active_step, &transaction.active_job_id) {
        (None, None) => {
            transaction.active_step = Some(operation.to_owned());
            transaction.active_job_id = Some(expected_job_id);
            record(
                transaction,
                action,
                format!("step {operation} job persisted"),
            )?;
            store.save(transaction)
        }
        (Some(active_step), Some(active_job_id))
            if active_step == operation && active_job_id == &expected_job_id =>
        {
            Ok(())
        }
        (Some(active_step), Some(active_job_id)) => bail!(
            "journal has active job {active_job_id} for step {active_step}; refusing to run \
             {operation}"
        ),
        _ => bail!("journal has an incomplete active job record; refusing to continue"),
    }
}

pub fn supersede_active_job(
    store: &Store,
    transaction: &mut Transaction,
    assert_terminal_failure: impl FnOnce(&str, &Transaction) -> Result<()>,
) -> Result<(String, String)> {
    let action = transaction
        .pending_action
        .context("transaction has no pending action with a job to supersede")?;
    let operation = transaction
        .active_step
        .clone()
        .context("transaction has no active step with a job to supersede")?;
    let old_job_id = transaction
        .active_job_id
        .clone()
        .context("transaction has no active job to supersede")?;
    let expected_job_id = job_id(transaction, action, &operation);
    if old_job_id != expected_job_id {
        bail!(
            "active job ID {old_job_id:?} does not match the journal generation for step {operation:?}"
        );
    }
    assert_terminal_failure(&old_job_id, transaction)?;

    let step_id = format!("{}:{operation}", action.as_str());
    let generation = transaction
        .job_generations
        .get(&step_id)
        .copied()
        .unwrap_or(0)
        .checked_add(1)
        .context("job generation overflow")?;
    transaction.job_generations.insert(step_id, generation);
    let new_job_id = job_id(transaction, action, &operation);
    transaction.active_job_id = Some(new_job_id.clone());
    transaction.last_error = None;
    record(
        transaction,
        action,
        format!("terminal failed job {old_job_id} superseded by durable attempt {new_job_id}"),
    )?;
    store.save(transaction)?;
    Ok((old_job_id, new_job_id))
}

fn reconcile_active_job<A: Adapter>(
    store: &Store,
    transaction: &mut Transaction,
    adapter: &mut A,
) -> Result<()> {
    let pending = transaction
        .pending_action
        .context("active job exists without a pending action")?;
    let operation = transaction
        .active_step
        .clone()
        .context("active job exists without an active step")?;
    let expected_job_id = job_id(transaction, pending, &operation);
    if transaction.active_job_id.as_deref() != Some(expected_job_id.as_str()) {
        bail!("active job ID does not match transaction, action, and step");
    }

    // Re-submit the same durable job ID. The adapter contract requires this to
    // attach to or poll the existing host-agent job, never create a second job.
    if let Err(error) = adapter.run(&operation, transaction) {
        transaction.last_error = Some(format!("{operation}: {error:#}"));
        record(
            transaction,
            pending,
            format!("step {operation} reconciliation failed"),
        )?;
        store.save(transaction)?;
        return Err(error).context("active remote job could not be reconciled");
    }

    transaction
        .completed_steps
        .insert(format!("{}:{operation}", pending.as_str()));
    transaction.active_step = None;
    transaction.active_job_id = None;
    transaction.last_error = None;
    record(
        transaction,
        pending,
        format!("step {operation} reconciled before rollback"),
    )?;
    store.save(transaction)
}

fn job_id(transaction: &Transaction, action: Action, operation: &str) -> String {
    let base = format!("{}-{}-{operation}", transaction.id, action.as_str());
    let step_id = format!("{}:{operation}", action.as_str());
    match transaction
        .job_generations
        .get(&step_id)
        .copied()
        .unwrap_or(0)
    {
        0 => base,
        generation => format!("{base}-attempt-{generation}"),
    }
}

fn validate_action_request(transaction: &Transaction, action: Action) -> Result<()> {
    validate_transition(transaction, action)?;
    if let Some(pending) = transaction.pending_action
        && pending != action
        && action != Action::Rollback
    {
        bail!(
            "transaction has pending {} action; resume it or explicitly roll back",
            pending.as_str()
        );
    }
    Ok(())
}

fn validate_transition(transaction: &Transaction, action: Action) -> Result<()> {
    if transaction.phase == Phase::Closed && action == Action::Close {
        return Ok(());
    }
    if transaction.phase == Phase::RolledBack && action == Action::Rollback {
        return Ok(());
    }
    if transaction.phase == Phase::Cutover && action == Action::Cutover {
        return Ok(());
    }
    if transaction.phase == Phase::Prepared && action == Action::Prepare {
        return Ok(());
    }
    if transaction.phase == Phase::Seeded && action == Action::Seed {
        return Ok(());
    }
    if transaction.phase == Phase::Setup && action == Action::Setup {
        return Ok(());
    }

    let valid = match action {
        Action::Plan => transaction.phase == Phase::Planned,
        Action::Setup => transaction.phase == Phase::Planned,
        Action::Seed => matches!(transaction.phase, Phase::Setup | Phase::Seeded),
        Action::Prepare => matches!(transaction.phase, Phase::Setup | Phase::Seeded),
        Action::Verify => matches!(transaction.phase, Phase::Prepared | Phase::Verified),
        Action::Cutover => matches!(transaction.phase, Phase::Prepared | Phase::Verified),
        Action::Rollback => {
            matches!(
                transaction.phase,
                Phase::Setup | Phase::Seeded | Phase::Prepared | Phase::Verified | Phase::Cutover
            ) || matches!(
                transaction.pending_action,
                Some(
                    Action::Setup
                        | Action::Seed
                        | Action::Prepare
                        | Action::Verify
                        | Action::Cutover
                        | Action::Rollback
                )
            )
        }
        Action::Close => matches!(transaction.phase, Phase::Cutover | Phase::RolledBack),
    };
    if !valid {
        bail!(
            "cannot {} transaction in {:?} phase",
            action.as_str(),
            transaction.phase
        );
    }
    Ok(())
}

fn steps_for(action: Action, transaction: &Transaction) -> Vec<&'static str> {
    let source_is_held = transaction.completed_steps.contains("prepare:hold-source");
    match action {
        Action::Plan => vec!["probe"],
        Action::Setup => vec![
            "provision-target",
            "reserve-target",
            "deploy-target-gated",
            "hold-target",
            "assert-target-stopped",
        ],
        Action::Seed => vec!["hold-target", "assert-target-stopped", "seed"],
        Action::Prepare => vec![
            "hold-target",
            "assert-target-stopped",
            "hold-source",
            "assert-source-stopped",
            "backup-source",
            "final-transfer",
            "verify-final",
        ],
        Action::Verify => vec![
            "assert-source-stopped",
            "assert-target-stopped",
            "verify-final",
        ],
        Action::Cutover => vec![
            "assert-source-stopped",
            "assert-target-stopped",
            "deploy-cutover",
            "activate-target",
            "verify-target-ready",
        ],
        Action::Rollback if transaction.target_ever_started => vec![
            "hold-target",
            "assert-target-stopped",
            "reverse-transfer",
            "verify-reverse",
            "deploy-rollback",
            "release-target",
            "activate-source",
            "verify-source-ready",
        ],
        Action::Rollback if source_is_held => vec![
            "hold-target",
            "assert-target-stopped",
            "deploy-rollback",
            "release-target",
            "activate-source",
            "verify-source-ready",
        ],
        Action::Rollback => vec!["deploy-rollback", "release-target"],
        Action::Close if transaction.phase == Phase::Cutover => vec!["release-source"],
        Action::Close => vec!["release-target"],
    }
}

fn phase_after(action: Action) -> Phase {
    match action {
        Action::Plan => Phase::Planned,
        Action::Setup => Phase::Setup,
        Action::Seed => Phase::Seeded,
        Action::Prepare => Phase::Prepared,
        Action::Verify => Phase::Verified,
        Action::Cutover => Phase::Cutover,
        Action::Rollback => Phase::RolledBack,
        Action::Close => Phase::Closed,
    }
}

fn validate_config(path: &Path) -> Result<()> {
    if !path.is_absolute() {
        bail!("manager config path must be absolute");
    }
    Ok(())
}

fn validate_id(id: &str) -> Result<()> {
    if id.is_empty()
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        bail!("invalid transaction ID");
    }
    Ok(())
}

fn record(transaction: &mut Transaction, action: Action, message: impl Into<String>) -> Result<()> {
    let now = now_unix_ms()?;
    transaction.updated_at_unix_ms = now;
    transaction.events.push(Event {
        at_unix_ms: now,
        action,
        message: message.into(),
    });
    Ok(())
}

fn now_unix_ms() -> Result<u128> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| anyhow!("system clock is before Unix epoch: {error}"))?
        .as_millis())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[derive(Default)]
    struct FakeAdapter {
        calls: Vec<String>,
        job_ids: Vec<String>,
        fail_once_at: Option<String>,
    }

    impl Adapter for FakeAdapter {
        fn run(&mut self, operation: &str, transaction: &mut Transaction) -> Result<()> {
            self.calls.push(operation.to_owned());
            self.job_ids.push(
                transaction
                    .active_job_id
                    .clone()
                    .context("test adapter did not receive an active job ID")?,
            );
            if self.fail_once_at.as_deref() == Some(operation) {
                self.fail_once_at = None;
                bail!("injected failure");
            }
            Ok(())
        }
    }

    fn fixture() -> Result<(TempDir, Store, Transaction)> {
        let temporary = TempDir::new()?;
        let store = Store::open(temporary.path().join("state"))?;
        let transaction = Transaction::new_service(
            "zulip".into(),
            "source".into(),
            "target".into(),
            PathBuf::from("/test/adapter"),
        )?;
        Ok((temporary, store, transaction))
    }

    #[test]
    fn instance_transactions_allow_one_controller_to_own_both_locations() {
        let transaction = Transaction::new_instance(
            "zulip".into(),
            "controller".into(),
            "controller".into(),
            PathBuf::from("/test/adapter"),
        )
        .unwrap();
        assert_eq!(transaction.source, transaction.target);
    }

    fn setup(
        store: &Store,
        transaction: &mut Transaction,
        adapter: &mut FakeAdapter,
    ) -> Result<()> {
        execute_action(store, transaction, Action::Setup, adapter)?;
        adapter.calls.clear();
        adapter.job_ids.clear();
        Ok(())
    }

    #[test]
    fn prepare_leaves_both_sides_stopped() -> Result<()> {
        let (_temporary, store, mut transaction) = fixture()?;
        let mut adapter = FakeAdapter::default();
        setup(&store, &mut transaction, &mut adapter)?;

        execute_action(&store, &mut transaction, Action::Prepare, &mut adapter)?;

        assert_eq!(transaction.phase, Phase::Prepared);
        assert_eq!(
            adapter.calls,
            [
                "hold-target",
                "assert-target-stopped",
                "hold-source",
                "assert-source-stopped",
                "backup-source",
                "final-transfer",
                "verify-final",
            ]
        );
        assert!(!adapter.calls.iter().any(|step| step.contains("start")));
        assert!(!adapter.calls.iter().any(|step| step.contains("release")));
        Ok(())
    }

    #[test]
    fn setup_reserves_before_deploy_and_seed_never_touches_the_source() -> Result<()> {
        let (_temporary, store, mut transaction) = fixture()?;
        let mut adapter = FakeAdapter::default();

        execute_action(&store, &mut transaction, Action::Setup, &mut adapter)?;
        assert_eq!(
            adapter.calls,
            [
                "provision-target",
                "reserve-target",
                "deploy-target-gated",
                "hold-target",
                "assert-target-stopped",
            ]
        );
        adapter.calls.clear();
        execute_action(&store, &mut transaction, Action::Seed, &mut adapter)?;
        assert_eq!(
            adapter.calls,
            ["hold-target", "assert-target-stopped", "seed"]
        );
        assert!(!adapter.calls.iter().any(|step| step.contains("source")));
        Ok(())
    }

    #[test]
    fn rollback_before_prepare_does_not_restart_the_live_source() -> Result<()> {
        let (_temporary, store, mut transaction) = fixture()?;
        let mut adapter = FakeAdapter::default();
        setup(&store, &mut transaction, &mut adapter)?;

        execute_action(&store, &mut transaction, Action::Rollback, &mut adapter)?;

        assert_eq!(adapter.calls, ["deploy-rollback", "release-target"]);
        assert!(!adapter.calls.iter().any(|step| step.contains("source")));
        Ok(())
    }

    #[test]
    fn cutover_activates_only_the_target() -> Result<()> {
        let (_temporary, store, mut transaction) = fixture()?;
        let mut adapter = FakeAdapter::default();
        setup(&store, &mut transaction, &mut adapter)?;
        execute_action(&store, &mut transaction, Action::Prepare, &mut adapter)?;
        adapter.calls.clear();

        execute_action(&store, &mut transaction, Action::Cutover, &mut adapter)?;

        assert_eq!(transaction.phase, Phase::Cutover);
        assert!(transaction.target_ever_started);
        assert_eq!(
            adapter.calls,
            [
                "assert-source-stopped",
                "assert-target-stopped",
                "deploy-cutover",
                "activate-target",
                "verify-target-ready",
            ]
        );
        assert!(
            !adapter
                .calls
                .iter()
                .any(|step| step.contains("source-ready"))
        );
        Ok(())
    }

    #[test]
    fn rollback_after_target_start_requires_reverse_transfer() -> Result<()> {
        let (_temporary, store, mut transaction) = fixture()?;
        let mut adapter = FakeAdapter::default();
        setup(&store, &mut transaction, &mut adapter)?;
        execute_action(&store, &mut transaction, Action::Prepare, &mut adapter)?;
        execute_action(&store, &mut transaction, Action::Cutover, &mut adapter)?;
        adapter.calls.clear();

        execute_action(&store, &mut transaction, Action::Rollback, &mut adapter)?;

        assert_eq!(transaction.phase, Phase::RolledBack);
        assert_eq!(
            adapter.calls,
            [
                "hold-target",
                "assert-target-stopped",
                "reverse-transfer",
                "verify-reverse",
                "deploy-rollback",
                "release-target",
                "activate-source",
                "verify-source-ready",
            ]
        );
        Ok(())
    }

    #[test]
    fn rollback_from_prepared_does_not_reverse_copy() -> Result<()> {
        let (_temporary, store, mut transaction) = fixture()?;
        let mut adapter = FakeAdapter::default();
        setup(&store, &mut transaction, &mut adapter)?;
        execute_action(&store, &mut transaction, Action::Prepare, &mut adapter)?;
        adapter.calls.clear();

        execute_action(&store, &mut transaction, Action::Rollback, &mut adapter)?;

        assert_eq!(
            adapter.calls,
            [
                "hold-target",
                "assert-target-stopped",
                "deploy-rollback",
                "release-target",
                "activate-source",
                "verify-source-ready",
            ]
        );
        assert_eq!(transaction.phase, Phase::RolledBack);
        Ok(())
    }

    #[test]
    fn failed_step_resumes_without_repeating_completed_steps() -> Result<()> {
        let (_temporary, store, mut transaction) = fixture()?;
        let mut adapter = FakeAdapter {
            fail_once_at: Some("final-transfer".into()),
            ..FakeAdapter::default()
        };
        setup(&store, &mut transaction, &mut adapter)?;

        assert!(execute_action(&store, &mut transaction, Action::Prepare, &mut adapter).is_err());
        assert_eq!(transaction.pending_action, Some(Action::Prepare));
        let failed_job_id = transaction
            .active_job_id
            .clone()
            .context("failed job ID was not retained")?;
        let persisted = store.load(&transaction.id)?;
        assert_eq!(persisted.active_step.as_deref(), Some("final-transfer"));
        assert_eq!(
            persisted.active_job_id.as_deref(),
            Some(failed_job_id.as_str())
        );
        adapter.calls.clear();
        adapter.job_ids.clear();

        execute_action(&store, &mut transaction, Action::Prepare, &mut adapter)?;

        assert_eq!(adapter.calls, ["final-transfer", "verify-final"]);
        assert_eq!(adapter.job_ids.first(), Some(&failed_job_id));
        assert_eq!(transaction.active_step, None);
        assert_eq!(transaction.active_job_id, None);
        assert_eq!(transaction.phase, Phase::Prepared);
        Ok(())
    }

    #[test]
    fn terminal_failed_job_can_be_preserved_and_superseded_explicitly() -> Result<()> {
        let (_temporary, store, mut transaction) = fixture()?;
        let mut adapter = FakeAdapter {
            fail_once_at: Some("final-transfer".into()),
            ..FakeAdapter::default()
        };
        setup(&store, &mut transaction, &mut adapter)?;
        assert!(execute_action(&store, &mut transaction, Action::Prepare, &mut adapter).is_err());
        let failed_job_id = transaction.active_job_id.clone().unwrap();

        let (old_job_id, new_job_id) =
            supersede_active_job(&store, &mut transaction, |job_id, _transaction| {
                assert_eq!(job_id, failed_job_id);
                Ok(())
            })?;

        assert_eq!(old_job_id, failed_job_id);
        assert_eq!(new_job_id, format!("{failed_job_id}-attempt-1"));
        assert_eq!(
            transaction.active_job_id.as_deref(),
            Some(new_job_id.as_str())
        );
        adapter.calls.clear();
        adapter.job_ids.clear();

        execute_action(&store, &mut transaction, Action::Prepare, &mut adapter)?;

        assert_eq!(adapter.calls, ["final-transfer", "verify-final"]);
        assert_eq!(adapter.job_ids.first(), Some(&new_job_id));
        assert_eq!(transaction.phase, Phase::Prepared);
        assert!(transaction.events.iter().any(|event| {
            event.message.contains(&failed_job_id) && event.message.contains(&new_job_id)
        }));
        Ok(())
    }

    #[test]
    fn ambiguous_target_activation_forces_reverse_copy() -> Result<()> {
        let (_temporary, store, mut transaction) = fixture()?;
        let mut adapter = FakeAdapter::default();
        setup(&store, &mut transaction, &mut adapter)?;
        execute_action(&store, &mut transaction, Action::Prepare, &mut adapter)?;
        adapter.fail_once_at = Some("activate-target".into());

        assert!(execute_action(&store, &mut transaction, Action::Cutover, &mut adapter).is_err());
        assert!(transaction.target_ever_started);
        adapter.calls.clear();

        execute_action(&store, &mut transaction, Action::Rollback, &mut adapter)?;

        assert!(adapter.calls.contains(&"reverse-transfer".to_owned()));
        Ok(())
    }

    #[test]
    fn store_round_trips_and_lists_transactions() -> Result<()> {
        let (_temporary, store, transaction) = fixture()?;
        store.save(&transaction)?;

        assert_eq!(store.load(&transaction.id)?, transaction);
        assert_eq!(store.list()?, [transaction]);
        Ok(())
    }

    #[test]
    fn instance_transactions_use_the_same_state_machine() -> Result<()> {
        let temporary = TempDir::new()?;
        let store = Store::open(temporary.path().join("state"))?;
        let mut transaction = Transaction::new_instance(
            "abird-zulip".into(),
            "gondor-a".into(),
            "gondor-b".into(),
            PathBuf::from("/test/adapter"),
        )?;
        let mut adapter = FakeAdapter::default();
        setup(&store, &mut transaction, &mut adapter)?;

        execute_action(&store, &mut transaction, Action::Prepare, &mut adapter)?;

        assert_eq!(transaction.resource_kind, ResourceKind::Instance);
        assert_eq!(transaction.resource, "abird-zulip");
        assert!(adapter.calls.contains(&"final-transfer".to_owned()));
        assert_eq!(transaction.phase, Phase::Prepared);
        Ok(())
    }
}
