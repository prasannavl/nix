use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::workflow::{BackupDestination, BackupSpec, InstanceEndpoint, validate_workflow_id};
use crate::workflow_runtime::{TransactionRecord, WorkflowPhase};

pub const BACKUP_RECORD_SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BackupPhase {
    Created,
    Running,
    Complete,
    Verified,
    Aborted,
    Deleted,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BackupCopyStatus {
    Pending,
    Running,
    Complete,
    Failed,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum BackupArtifact {
    ControllerDirectory {
        root: PathBuf,
    },
    HostSnapshot {
        host: String,
        resource: String,
        snapshot: String,
        root: PathBuf,
    },
    InstanceExport {
        source: InstanceEndpoint,
        location: InstanceExportLocation,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        staging: Option<InstanceExportLocation>,
        sha256: String,
        size_bytes: u64,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum InstanceExportLocation {
    ControllerDirectory { root: PathBuf },
    Host { host: String, root: PathBuf },
}

impl InstanceExportLocation {
    pub fn root(&self) -> &Path {
        match self {
            Self::ControllerDirectory { root } | Self::Host { root, .. } => root,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactDeletionStatus {
    #[default]
    Pending,
    Running,
    Complete,
    Failed,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ArtifactDeletionRecord {
    pub status: ArtifactDeletionStatus,
    #[serde(default)]
    pub attempts: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BackupCopyRecord {
    pub item: String,
    pub destination: BackupDestination,
    pub status: BackupCopyStatus,
    #[serde(default)]
    pub attempts: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact: Option<BackupArtifact>,
    #[serde(default)]
    pub deletion: ArtifactDeletionRecord,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BackupItemRuntime {
    #[serde(default)]
    pub held: bool,
    #[serde(default)]
    pub attempts: u32,
    #[serde(default)]
    pub previously_active_services: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previously_active_instance: Option<bool>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RestorePhase {
    Holding,
    Restoring,
    RestoredHeld,
    RollingBack,
    RolledBackHeld,
    Activated,
}

impl RestorePhase {
    pub fn holds_authority(self) -> bool {
        !matches!(self, Self::Activated)
    }
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RestoreItemRuntime {
    #[serde(default)]
    pub held: bool,
    #[serde(default)]
    pub hold_attempts: u32,
    #[serde(default)]
    pub previously_active_services: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previously_active_instance: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub safety_snapshot: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub safety_artifact: Option<BackupArtifact>,
    #[serde(default)]
    pub restored: bool,
    #[serde(default)]
    pub rolled_back: bool,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BackupRestoreRecord {
    pub destination: BackupDestination,
    pub phase: RestorePhase,
    pub items: BTreeMap<String, RestoreItemRuntime>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BackupEvent {
    pub at_unix_ms: u128,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BackupRecord {
    pub schema_version: u32,
    pub spec: BackupSpec,
    pub phase: BackupPhase,
    pub copies: Vec<BackupCopyRecord>,
    pub items: BTreeMap<String, BackupItemRuntime>,
    pub created_at_unix_ms: u128,
    pub updated_at_unix_ms: u128,
    #[serde(default)]
    pub events: Vec<BackupEvent>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restore: Option<BackupRestoreRecord>,
}

impl BackupRecord {
    pub fn new(spec: BackupSpec) -> Result<Self> {
        spec.validate()?;
        let now = now_unix_ms()?;
        let copies = spec
            .items
            .iter()
            .flat_map(|item| {
                spec.destinations
                    .iter()
                    .cloned()
                    .map(move |destination| BackupCopyRecord {
                        item: item.id().to_owned(),
                        destination,
                        status: BackupCopyStatus::Pending,
                        attempts: 0,
                        result: None,
                        last_error: None,
                        artifact: None,
                        deletion: ArtifactDeletionRecord::default(),
                    })
            })
            .collect();
        let items = spec
            .items
            .iter()
            .map(|item| (item.id().to_owned(), BackupItemRuntime::default()))
            .collect();
        Ok(Self {
            schema_version: BACKUP_RECORD_SCHEMA_VERSION,
            spec,
            phase: BackupPhase::Created,
            copies,
            items,
            created_at_unix_ms: now,
            updated_at_unix_ms: now,
            events: Vec::new(),
            restore: None,
        })
    }

    pub fn id(&self) -> &str {
        &self.spec.id
    }

    pub fn begin(&mut self) -> Result<()> {
        if matches!(self.phase, BackupPhase::Complete | BackupPhase::Verified) {
            return Ok(());
        }
        if matches!(self.phase, BackupPhase::Aborted | BackupPhase::Deleted) {
            bail!("terminal backup cannot be resumed as a copy operation");
        }
        self.phase = BackupPhase::Running;
        self.event("backup execution started or resumed")
    }

    pub fn begin_copy(&mut self, index: usize) -> Result<()> {
        let copy = self
            .copies
            .get_mut(index)
            .context("backup copy index is out of range")?;
        if copy.status == BackupCopyStatus::Complete {
            return Ok(());
        }
        copy.attempts = copy
            .attempts
            .checked_add(1)
            .context("backup copy attempt counter overflow")?;
        copy.status = BackupCopyStatus::Running;
        copy.last_error = None;
        self.event(format!("copy {index} started"))
    }

    pub fn complete_copy(
        &mut self,
        index: usize,
        result: Value,
        artifact: BackupArtifact,
    ) -> Result<()> {
        let copy = self
            .copies
            .get_mut(index)
            .context("backup copy index is out of range")?;
        copy.status = BackupCopyStatus::Complete;
        copy.result = Some(result);
        copy.artifact = Some(artifact);
        copy.last_error = None;
        self.event(format!("copy {index} completed"))
    }

    pub fn fail_copy(&mut self, index: usize, error: String) -> Result<()> {
        let copy = self
            .copies
            .get_mut(index)
            .context("backup copy index is out of range")?;
        copy.status = BackupCopyStatus::Failed;
        copy.last_error = Some(error);
        self.event(format!("copy {index} failed"))
    }

    pub fn finish(&mut self) -> Result<()> {
        if self
            .copies
            .iter()
            .any(|copy| copy.status != BackupCopyStatus::Complete)
        {
            bail!("backup cannot complete while copies remain incomplete");
        }
        if self.items.values().any(|item| item.held) {
            bail!("backup cannot complete while a source resource remains held");
        }
        self.phase = BackupPhase::Complete;
        self.event("backup completed with independently verified copies")
    }

    pub fn verify_evidence(&self) -> Result<()> {
        if !matches!(self.phase, BackupPhase::Complete | BackupPhase::Verified) {
            bail!("only a complete backup has final verification evidence");
        }
        if self.copies.iter().any(|copy| {
            copy.status != BackupCopyStatus::Complete
                || copy.result.is_none()
                || copy.artifact.is_none()
        }) {
            bail!("backup record is missing completed copy evidence");
        }
        Ok(())
    }

    pub fn abort(&mut self) -> Result<()> {
        if matches!(
            self.phase,
            BackupPhase::Complete | BackupPhase::Verified | BackupPhase::Deleted
        ) {
            bail!("completed backup cannot be aborted");
        }
        if self.items.values().any(|item| item.held) {
            bail!("cannot abort while a source resource remains held; restore it first");
        }
        self.phase = BackupPhase::Aborted;
        self.event("backup aborted")
    }

    pub fn begin_restore(&mut self, destination: BackupDestination) -> Result<()> {
        if !matches!(self.phase, BackupPhase::Complete | BackupPhase::Verified) {
            bail!("only a complete backup can be restored");
        }
        if self
            .copies
            .iter()
            .filter(|copy| copy.destination == destination)
            .count()
            != self.spec.items.len()
        {
            bail!("restore destination does not contain every backup item");
        }
        if self.copies.iter().any(|copy| {
            copy.destination == destination
                && (copy.status != BackupCopyStatus::Complete
                    || copy.artifact.is_none()
                    || copy.deletion.status == ArtifactDeletionStatus::Complete)
        }) {
            bail!("restore destination has an unavailable backup artifact");
        }
        match &self.restore {
            Some(existing) if existing.destination != destination => {
                bail!("backup already has different immutable restore intent")
            }
            Some(_) => return Ok(()),
            None => {}
        }
        self.restore = Some(BackupRestoreRecord {
            destination,
            phase: RestorePhase::Holding,
            items: self
                .spec
                .items
                .iter()
                .map(|item| (item.id().to_owned(), RestoreItemRuntime::default()))
                .collect(),
            last_error: None,
        });
        self.event("backup restore intent persisted")
    }

    pub fn begin_artifact_deletion(&mut self, index: usize) -> Result<()> {
        let destination = self
            .copies
            .get(index)
            .context("backup copy index is out of range")?
            .destination
            .clone();
        if self.restore.as_ref().is_some_and(|restore| {
            restore.phase.holds_authority() && destination == restore.destination
        }) {
            bail!("cannot delete an artifact used by an active restore");
        }
        let copy = self
            .copies
            .get_mut(index)
            .context("backup copy index is out of range")?;
        if copy.status != BackupCopyStatus::Complete || copy.artifact.is_none() {
            bail!("cannot delete an incomplete backup artifact");
        }
        if copy.deletion.status == ArtifactDeletionStatus::Complete {
            return Ok(());
        }
        copy.deletion.attempts = copy
            .deletion
            .attempts
            .checked_add(1)
            .context("artifact deletion attempt counter overflow")?;
        copy.deletion.status = ArtifactDeletionStatus::Running;
        copy.deletion.last_error = None;
        self.event(format!("artifact {index} deletion started"))
    }

    pub fn ensure_artifacts_deletable(&self) -> Result<()> {
        if !matches!(
            self.phase,
            BackupPhase::Complete
                | BackupPhase::Verified
                | BackupPhase::Aborted
                | BackupPhase::Deleted
        ) {
            bail!("backup must be complete or explicitly aborted before artifact deletion");
        }
        if self.items.values().any(|item| item.held) {
            bail!("cannot delete backup artifacts while a creation hold remains active");
        }
        if self
            .restore
            .as_ref()
            .is_some_and(|restore| restore.phase.holds_authority())
        {
            bail!("cannot delete backup artifacts while restored resources remain held");
        }
        Ok(())
    }

    pub fn ensure_restore_rollbackable(&self) -> Result<()> {
        let phase = self
            .restore
            .as_ref()
            .context("backup has no restore to roll back")?
            .phase;
        if !matches!(
            phase,
            RestorePhase::Holding
                | RestorePhase::Restoring
                | RestorePhase::RestoredHeld
                | RestorePhase::RollingBack
                | RestorePhase::RolledBackHeld
        ) {
            bail!("backup restore cannot be rolled back in {phase:?} phase");
        }
        Ok(())
    }

    pub fn ensure_restore_activatable(&self) -> Result<()> {
        let phase = self
            .restore
            .as_ref()
            .context("backup has no restore to activate")?
            .phase;
        if !matches!(
            phase,
            RestorePhase::RestoredHeld | RestorePhase::RolledBackHeld | RestorePhase::Activated
        ) {
            bail!("backup restore cannot activate in {phase:?} phase");
        }
        Ok(())
    }

    pub fn complete_artifact_deletion(&mut self, index: usize) -> Result<()> {
        let copy = self
            .copies
            .get_mut(index)
            .context("backup copy index is out of range")?;
        copy.deletion.status = ArtifactDeletionStatus::Complete;
        copy.deletion.last_error = None;
        self.event(format!("artifact {index} deletion completed"))
    }

    pub fn finish_artifact_deletion(&mut self) -> Result<()> {
        if self
            .copies
            .iter()
            .any(|copy| copy.deletion.status != ArtifactDeletionStatus::Complete)
        {
            bail!("backup artifacts remain undeleted");
        }
        self.phase = BackupPhase::Deleted;
        self.event("all backup artifacts deleted; tombstone retained")
    }

    pub fn fail_artifact_deletion(&mut self, index: usize, error: String) -> Result<()> {
        let copy = self
            .copies
            .get_mut(index)
            .context("backup copy index is out of range")?;
        copy.deletion.status = ArtifactDeletionStatus::Failed;
        copy.deletion.last_error = Some(error);
        self.event(format!("artifact {index} deletion failed"))
    }

    pub fn set_restore_phase(&mut self, phase: RestorePhase, message: &str) -> Result<()> {
        let restore = self
            .restore
            .as_mut()
            .context("backup has no restore intent")?;
        restore.phase = phase;
        restore.last_error = None;
        self.event(message)
    }

    pub fn fail_restore(&mut self, error: String) -> Result<()> {
        let restore = self
            .restore
            .as_mut()
            .context("backup has no restore intent")?;
        restore.last_error = Some(error);
        self.event("backup restore step failed; sources remain held")
    }

    fn event(&mut self, message: impl Into<String>) -> Result<()> {
        let now = now_unix_ms()?;
        self.updated_at_unix_ms = now;
        self.events.push(BackupEvent {
            at_unix_ms: now,
            message: message.into(),
        });
        Ok(())
    }
}

pub struct BackupStore {
    root: PathBuf,
    _lock: Option<File>,
}

impl BackupStore {
    pub fn open(root: PathBuf) -> Result<Self> {
        let backups = root.join("backups");
        fs::create_dir_all(&backups)
            .with_context(|| format!("failed to create backup state {}", backups.display()))?;
        let lock_path = root.join("authority-lock");
        let lock = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&lock_path)
            .with_context(|| format!("failed to open backup lock {}", lock_path.display()))?;
        lock.lock()
            .with_context(|| format!("failed to lock backup state {}", root.display()))?;
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
            bail!("read-only backup store cannot mutate manager state");
        }
        Ok(())
    }

    pub fn create(&self, record: &BackupRecord) -> Result<()> {
        self.require_write_authority()?;
        if self.path(record.id()).exists() {
            let existing = self.load(record.id())?;
            if existing.spec == record.spec {
                return Ok(());
            }
            bail!(
                "backup ID {:?} already exists with different immutable intent",
                record.id()
            );
        }
        self.reject_active_authority_overlap(record)?;
        self.save(record)
    }

    pub fn ensure_authority_available(&self, record: &BackupRecord) -> Result<()> {
        self.reject_active_authority_overlap(record)
    }

    pub fn save(&self, record: &BackupRecord) -> Result<()> {
        self.require_write_authority()?;
        validate_record(record)?;
        atomic_json(&self.path(record.id()), record)
    }

    pub fn load(&self, id: &str) -> Result<BackupRecord> {
        validate_workflow_id(id)?;
        let path = self.path(id);
        let record: BackupRecord = serde_json::from_reader(BufReader::new(
            File::open(&path)
                .with_context(|| format!("failed to open backup record {}", path.display()))?,
        ))?;
        validate_record(&record)?;
        if record.id() != id {
            bail!("backup record ID does not match its filename");
        }
        Ok(record)
    }

    pub fn list(&self) -> Result<Vec<BackupRecord>> {
        let mut records = Vec::new();
        let backups = self.root.join("backups");
        if !backups.exists() {
            return Ok(records);
        }
        for entry in fs::read_dir(backups)? {
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

    fn path(&self, id: &str) -> PathBuf {
        self.root.join("backups").join(format!("{id}.json"))
    }

    fn reject_active_authority_overlap(&self, candidate: &BackupRecord) -> Result<()> {
        for existing in self.list()? {
            if existing.id() == candidate.id() {
                continue;
            }
            if !matches!(existing.phase, BackupPhase::Created | BackupPhase::Running)
                && !existing
                    .restore
                    .as_ref()
                    .is_some_and(|restore| restore.phase.holds_authority())
            {
                continue;
            }
            for item in &candidate.spec.items {
                if let Some(other) = existing
                    .spec
                    .items
                    .iter()
                    .find(|other| item.authority().overlaps(&other.authority()))
                {
                    bail!(
                        "backup {:?} item {:?} overlaps active backup {:?} item {:?}",
                        candidate.id(),
                        item.id(),
                        existing.id(),
                        other.id()
                    );
                }
            }
        }

        let transactions = self.root.join("workflow-transactions");
        if !transactions.exists() {
            return Ok(());
        }
        for entry in fs::read_dir(transactions)? {
            let path = entry?.path();
            if path.extension() != Some(OsStr::new("json")) {
                continue;
            }
            let transaction: TransactionRecord =
                serde_json::from_reader(BufReader::new(File::open(&path)?)).with_context(|| {
                    format!("parse transaction authority record {}", path.display())
                })?;
            if transaction.phase == WorkflowPhase::Closed {
                continue;
            }
            for item in &candidate.spec.items {
                if let Some(other) = transaction.spec.items.iter().find(|other| {
                    item.authority().overlaps(&other.source_authority())
                        || item.authority().overlaps(&other.target_authority())
                }) {
                    bail!(
                        "backup {:?} item {:?} overlaps open transaction {:?} item {:?}",
                        candidate.id(),
                        item.id(),
                        transaction.id(),
                        other.id()
                    );
                }
            }
        }
        Ok(())
    }
}

fn validate_record(record: &BackupRecord) -> Result<()> {
    if record.schema_version != BACKUP_RECORD_SCHEMA_VERSION {
        bail!(
            "unsupported backup-record schema version {}",
            record.schema_version
        );
    }
    record.spec.validate()?;
    let expected_copies = record.spec.items.len() * record.spec.destinations.len();
    if record.copies.len() != expected_copies {
        bail!("backup record copy matrix does not match its immutable spec");
    }
    if record.items.len() != record.spec.items.len()
        || record
            .spec
            .items
            .iter()
            .any(|item| !record.items.contains_key(item.id()))
    {
        bail!("backup runtime items do not match its immutable spec");
    }
    if record
        .copies
        .iter()
        .any(|copy| (copy.status == BackupCopyStatus::Complete) != copy.artifact.is_some())
    {
        bail!("backup artifact state does not match copy completion state");
    }
    let mut copy_matrix = BTreeSet::new();
    for copy in &record.copies {
        if !record.spec.items.iter().any(|item| item.id() == copy.item)
            || !record.spec.destinations.contains(&copy.destination)
            || !copy_matrix.insert((copy.item.clone(), copy.destination.clone()))
        {
            bail!("backup record contains an invalid or duplicate copy coordinate");
        }
        match (&copy.destination, &copy.artifact) {
            (
                BackupDestination::ControllerDirectory { path },
                Some(BackupArtifact::ControllerDirectory { root }),
            ) if root.is_absolute()
                && root != Path::new("/")
                && root != path
                && root.starts_with(path) => {}
            (
                BackupDestination::Host { endpoint },
                Some(BackupArtifact::HostSnapshot {
                    host,
                    snapshot,
                    root,
                    ..
                }),
            ) if host == &endpoint.host
                && root.is_absolute()
                && root != Path::new("/")
                && validate_workflow_id(snapshot).is_ok() => {}
            (_, None) => {}
            _ => bail!("backup artifact does not match its immutable destination"),
        }
    }
    for item in &record.spec.items {
        for destination in &record.spec.destinations {
            if !copy_matrix.contains(&(item.id().to_owned(), destination.clone())) {
                bail!("backup record copy matrix is incomplete");
            }
        }
    }
    if let Some(restore) = &record.restore {
        if restore.items.len() != record.spec.items.len()
            || record
                .spec
                .items
                .iter()
                .any(|item| !restore.items.contains_key(item.id()))
        {
            bail!("backup restore items do not match immutable backup items");
        }
        if !record.spec.destinations.contains(&restore.destination) {
            bail!("backup restore destination is not in the immutable specification");
        }
    }
    Ok(())
}

fn atomic_json<T: Serialize>(destination: &Path, value: &T) -> Result<()> {
    let directory = destination.parent().context("backup path has no parent")?;
    let name = destination
        .file_name()
        .and_then(OsStr::to_str)
        .context("backup path has no UTF-8 filename")?;
    let temporary = directory.join(format!(
        ".{name}.{}.{}.tmp",
        std::process::id(),
        now_unix_ms()?
    ));
    let file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&temporary)?;
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
    use crate::workflow::{BackupItem, HostEndpoint};

    fn spec(id: &str) -> BackupSpec {
        BackupSpec::new(
            Some(id),
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
        .unwrap()
    }

    fn artifact() -> BackupArtifact {
        BackupArtifact::ControllerDirectory {
            root: "/srv/backups/backup-demo".into(),
        }
    }

    #[test]
    fn record_persists_copy_progress_and_idempotent_intent() {
        let state = TempDir::new().unwrap();
        let store = BackupStore::open(state.path().to_path_buf()).unwrap();
        let mut record = BackupRecord::new(spec("backup-demo")).unwrap();
        store.create(&record).unwrap();
        store.create(&record).unwrap();
        record.begin().unwrap();
        record.begin_copy(0).unwrap();
        store.save(&record).unwrap();
        record
            .complete_copy(0, serde_json::json!({"verified": true}), artifact())
            .unwrap();
        record.finish().unwrap();
        store.save(&record).unwrap();
        assert_eq!(
            store.load("backup-demo").unwrap().phase,
            BackupPhase::Complete
        );
    }

    #[test]
    fn read_only_store_never_creates_manager_state() {
        let parent = TempDir::new().unwrap();
        let state = parent.path().join("missing-state");
        let store = BackupStore::read_only(state.clone());
        assert!(store.list().unwrap().is_empty());
        assert!(!state.exists());

        let record = BackupRecord::new(spec("backup-demo")).unwrap();
        assert!(store.save(&record).is_err());
        assert!(!state.exists());
    }

    #[test]
    fn completion_requires_all_copies_and_released_holds() {
        let mut record = BackupRecord::new(spec("backup-demo")).unwrap();
        assert!(record.finish().is_err());
        record
            .complete_copy(0, serde_json::json!({"verified": true}), artifact())
            .unwrap();
        record.items.get_mut("chat").unwrap().held = true;
        assert!(record.finish().is_err());
    }

    #[test]
    fn verification_is_read_only_and_requires_complete_evidence() {
        let mut record = BackupRecord::new(spec("backup-demo")).unwrap();
        assert!(record.verify_evidence().is_err());
        record
            .complete_copy(0, serde_json::json!({"verified": true}), artifact())
            .unwrap();
        record.finish().unwrap();
        let before = record.clone();
        record.verify_evidence().unwrap();
        assert_eq!(record, before);
    }

    #[test]
    fn restore_intent_is_immutable_and_artifacts_delete_to_a_tombstone() {
        let mut record = BackupRecord::new(spec("backup-demo")).unwrap();
        record
            .complete_copy(0, serde_json::json!({"verified": true}), artifact())
            .unwrap();
        record.finish().unwrap();
        let destination = record.spec.destinations[0].clone();
        record.begin_restore(destination.clone()).unwrap();
        record.begin_restore(destination).unwrap();
        assert_eq!(
            record.restore.as_ref().unwrap().phase,
            RestorePhase::Holding
        );
        record.ensure_restore_rollbackable().unwrap();
        assert!(record.ensure_restore_activatable().is_err());
        assert!(record.ensure_artifacts_deletable().is_err());
        assert!(record.begin_artifact_deletion(0).is_err());

        record.restore.as_mut().unwrap().phase = RestorePhase::Activated;
        record.ensure_restore_activatable().unwrap();
        record.ensure_artifacts_deletable().unwrap();
        record.begin_artifact_deletion(0).unwrap();
        record.complete_artifact_deletion(0).unwrap();
        record.finish_artifact_deletion().unwrap();
        assert_eq!(record.phase, BackupPhase::Deleted);
    }

    #[test]
    fn record_rejects_copy_coordinates_and_artifacts_outside_immutable_intent() {
        let mut record = BackupRecord::new(spec("backup-demo")).unwrap();
        record.copies[0].item = "other".to_owned();
        assert!(validate_record(&record).is_err());

        let mut record = BackupRecord::new(spec("backup-demo")).unwrap();
        record
            .complete_copy(
                0,
                serde_json::json!({"verified": true}),
                BackupArtifact::ControllerDirectory {
                    root: "/etc".into(),
                },
            )
            .unwrap();
        assert!(validate_record(&record).is_err());
    }
}
