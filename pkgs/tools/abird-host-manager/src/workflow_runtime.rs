use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};

use abird_host_agent::resource::DataRootPlan;
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::agent_adapter::{NativeAdapter, WorkflowItemAdapter};
use crate::backup_runtime::{BackupPhase, BackupRecord};
use crate::workflow::{AuthorityKey, MoveItem, TransactionSpec, validate_workflow_id};
use crate::{Action, Store, Transaction, execute_action};

pub const TRANSACTION_RECORD_SCHEMA_VERSION: u32 = 1;

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

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WorkflowEvent {
    pub at_unix_ms: u128,
    pub action: Action,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TransactionRecord {
    pub schema_version: u32,
    pub spec: TransactionSpec,
    pub config: PathBuf,
    pub phase: WorkflowPhase,
    pub pending_action: Option<Action>,
    #[serde(default)]
    pub items: BTreeMap<String, Transaction>,
    pub created_at_unix_ms: u128,
    pub updated_at_unix_ms: u128,
    #[serde(default)]
    pub events: Vec<WorkflowEvent>,
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
            items,
            created_at_unix_ms: now,
            updated_at_unix_ms: now,
            events: Vec::new(),
        })
    }

    pub fn id(&self) -> &str {
        &self.spec.id
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

pub struct WorkflowStore {
    root: PathBuf,
    _lock: File,
}

impl WorkflowStore {
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
        Ok(Self { root, _lock: lock })
    }

    pub fn create(&self, record: &TransactionRecord) -> Result<()> {
        if self.path(record.id()).exists() {
            let existing = self.load(record.id())?;
            if existing.spec == record.spec && existing.config == record.config {
                return Ok(());
            }
            bail!(
                "transaction ID {:?} already exists with different immutable intent",
                record.id()
            );
        }
        self.reject_open_authority_overlap(record)?;
        self.reject_active_backup_overlap(record)?;
        self.save(record)
    }

    pub fn save(&self, record: &TransactionRecord) -> Result<()> {
        validate_record(record)?;
        atomic_json(&self.path(record.id()), record)
    }

    pub fn load(&self, id: &str) -> Result<TransactionRecord> {
        validate_workflow_id(id)?;
        let path = self.path(id);
        let record: TransactionRecord =
            serde_json::from_reader(BufReader::new(File::open(&path).with_context(|| {
                format!("failed to open transaction record {}", path.display())
            })?))
            .with_context(|| format!("failed to parse transaction record {}", path.display()))?;
        validate_record(&record)?;
        if record.id() != id {
            bail!("transaction record ID does not match its filename");
        }
        Ok(record)
    }

    pub fn list(&self) -> Result<Vec<TransactionRecord>> {
        let mut records = Vec::new();
        for entry in fs::read_dir(self.root.join("workflow-transactions"))? {
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
        Store::open(
            self.root
                .join("workflow-items")
                .join(record_id)
                .to_path_buf(),
        )
    }

    fn path(&self, id: &str) -> PathBuf {
        self.root
            .join("workflow-transactions")
            .join(format!("{id}.json"))
    }

    fn reject_open_authority_overlap(&self, candidate: &TransactionRecord) -> Result<()> {
        for existing in self.list()? {
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

    fn reject_active_backup_overlap(&self, candidate: &TransactionRecord) -> Result<()> {
        let directory = self.root.join("backups");
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
}

pub fn execute_workflow_action(
    store: &WorkflowStore,
    record: &mut TransactionRecord,
    action: Action,
    adapter: &mut NativeAdapter,
) -> Result<()> {
    validate_workflow_transition(record, action)?;
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
            event(record, action, "action started")?;
        }
        Some(_) => {}
    }
    store.save(record)?;

    let child_store = store.child_store(record.id())?;
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
        let mut item_adapter = WorkflowItemAdapter::new(adapter, &item);
        item_adapter
            .preflight(child, action)
            .with_context(|| format!("preflight transaction item {item_id:?}"))?;
        execute_action(&child_store, child, action, &mut item_adapter)
            .with_context(|| format!("execute transaction item {item_id:?}"))?;
        store.save(record)?;
    }

    record.phase = workflow_phase_after(action);
    record.pending_action = None;
    event(record, action, "action completed")?;
    store.save(record)
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
            source,
            target,
            ..
        } => Transaction::new_service(
            service.clone(),
            source.host.clone(),
            target.host.clone(),
            config.to_path_buf(),
        )?,
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
    Ok(())
}

fn validate_workflow_transition(record: &TransactionRecord, action: Action) -> Result<()> {
    let valid = match action {
        Action::Plan => record.phase == WorkflowPhase::Planned,
        Action::Setup => record.phase == WorkflowPhase::Planned,
        Action::Seed => matches!(record.phase, WorkflowPhase::Setup | WorkflowPhase::Seeded),
        Action::Prepare => matches!(record.phase, WorkflowPhase::Setup | WorkflowPhase::Seeded),
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
                WorkflowPhase::Setup
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
    use crate::backup_runtime::{BackupRecord, BackupStore};
    use crate::workflow::{
        BackupDestination, BackupItem, BackupSpec, HostEndpoint, MoveItem, TransactionSpec,
    };

    fn service(id: &str, name: &str, source: &str, target: &str) -> MoveItem {
        MoveItem::Service {
            id: id.to_owned(),
            service: name.to_owned(),
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
        store.create(&first).unwrap();
        store.create(&first).unwrap();

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
                .create(&conflict)
                .unwrap_err()
                .to_string()
                .contains("overlaps open transaction")
        );
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
                .create(&transaction)
                .unwrap_err()
                .to_string()
                .contains("overlaps active backup")
        );
    }
}
