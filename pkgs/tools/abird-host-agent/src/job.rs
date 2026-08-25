use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::deployment::{
    DeploymentDefinition, NixbotDeployPolicy, NixbotDeployRequest, validate_nixbot_deploy_request,
};
use crate::file_state::FileStateDefinition;
use crate::instance::{
    InstanceControlRequest, InstanceDefinition, InstanceMigrationRequest, validate_instance_control,
};
use crate::instance_backup::InstanceBackupRequest;
use crate::readiness::ReadinessCheck;
use crate::resource::{
    BackupConsistency, BrokerTransferPolicy, DataRootPlan, ExpectedState, validate_data_root_plan,
};
use crate::service::ServiceTarget;
use crate::sha256::digest_bytes;
use crate::state::Timestamp;
use crate::transfer::TransferDefinition;

static TEMP_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case", tag = "kind")]
pub enum JobOperation {
    Reserve,
    Hold,
    Release,
    Activate,
    Restore {
        active_services: Vec<ServiceTarget>,
    },
    Stop,
    Start,
    Status,
    Manifest,
    WipeData,
    Ready,
    Transfer {
        name: String,
    },
    VerifyTransfer {
        name: String,
    },
    BrokerCopy {
        source: crate::transfer::RemoteSource,
        target: crate::transfer::RemoteSource,
        destination_root: Option<PathBuf>,
        #[serde(default)]
        backup_source: bool,
    },
    BrokerVerify {
        source: crate::transfer::RemoteSource,
        target: crate::transfer::RemoteSource,
        destination_root: Option<PathBuf>,
        #[serde(default)]
        backup_source: bool,
    },
    Backup,
    RestoreBackup {
        snapshot: String,
    },
    DeleteBackup {
        snapshot: String,
    },
    FileState {
        name: String,
    },
    Provision {
        name: String,
    },
    MigrateInstance {
        request: InstanceMigrationRequest,
    },
    ControlInstance {
        request: InstanceControlRequest,
    },
    BackupInstance {
        request: InstanceBackupRequest,
    },
    Deploy {
        name: String,
    },
    NixbotDeploy {
        request: NixbotDeployRequest,
    },
    Named {
        name: String,
    },
}

#[derive(Debug)]
pub struct JobExecution {
    pub result: Value,
    pub error: Option<String>,
}

/// Immutable repository projection evidence bound into a deterministic job.
///
/// The transaction identity remains `JobSpec::transaction_id`; this binding
/// proves which immutable transaction specification and desired projection
/// authorized the job.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct JobProjectionBinding {
    #[serde(alias = "transaction_digest")]
    pub intent_digest: String,
    pub projection_digest: String,
    pub generation: u64,
    #[serde(
        default,
        alias = "hold_declaration_id",
        skip_serializing_if = "Option::is_none"
    )]
    pub hold_epoch: Option<String>,
    #[serde(
        default,
        alias = "prepared_receipt_requirement",
        skip_serializing_if = "Option::is_none"
    )]
    pub activation_requirement_digest: Option<String>,
}

impl JobExecution {
    pub fn succeeded(result: Value) -> Self {
        Self {
            result,
            error: None,
        }
    }

    pub fn failed(result: Value, error: impl Into<String>) -> Self {
        Self {
            result,
            error: Some(error.into()),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct JobSpec {
    pub schema_version: u32,
    pub job_id: String,
    pub transaction_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub projection: Option<JobProjectionBinding>,
    pub resource: String,
    pub operation: JobOperation,
    pub expected_state: ExpectedState,
    #[serde(default)]
    pub services: Vec<ServiceTarget>,
    #[serde(default)]
    pub data_paths: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub data_root_plan: Vec<DataRootPlan>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub argv: Option<Vec<String>>,
    #[serde(default)]
    pub readiness: Vec<ReadinessCheck>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transfer: Option<TransferDefinition>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub resource_transfers: Vec<TransferDefinition>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backup_consistency: Option<BackupConsistency>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub broker_transfer: Option<BrokerTransferPolicy>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_state: Option<FileStateDefinition>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instance: Option<InstanceDefinition>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instance_migration: Option<InstanceMigrationRequest>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deployment: Option<DeploymentDefinition>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nixbot_deploy: Option<NixbotDeployPolicy>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum JobStatus {
    Pending,
    Running,
    Succeeded,
    Failed,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct JobRecord {
    pub spec: JobSpec,
    pub status: JobStatus,
    pub attempts: u32,
    pub accepted_at: Timestamp,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<Timestamp>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<Timestamp>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct SubmitOutcome {
    pub changed: bool,
    pub job: JobRecord,
}

#[derive(Clone, Debug)]
pub struct JobStore {
    root: PathBuf,
}

impl JobStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn submit(&self, spec: JobSpec) -> Result<SubmitOutcome> {
        validate_spec(&spec)?;
        let outcome = self.with_job_lock(|| {
            if let Some(existing) = self.read_unlocked(&spec.job_id)? {
                if existing.spec != spec {
                    bail!(
                        "job ID {:?} already exists with a different specification",
                        spec.job_id
                    );
                }
                return Ok(SubmitOutcome {
                    changed: false,
                    job: existing,
                });
            }
            let job = JobRecord {
                spec,
                status: JobStatus::Pending,
                attempts: 0,
                accepted_at: now()?,
                started_at: None,
                finished_at: None,
                result: None,
                progress: None,
                error: None,
            };
            self.write_unlocked(&job)?;
            Ok(SubmitOutcome { changed: true, job })
        })?;
        if outcome.job.status == JobStatus::Pending {
            self.wake_worker()?;
        }
        Ok(outcome)
    }

    pub fn status(&self, job_id: &str) -> Result<JobRecord> {
        validate_identifier("job ID", job_id)?;
        self.with_job_lock(|| {
            self.read_unlocked(job_id)?
                .with_context(|| format!("job {job_id:?} does not exist"))
        })
    }

    pub fn status_optional(&self, job_id: &str) -> Result<Option<JobRecord>> {
        validate_identifier("job ID", job_id)?;
        self.with_job_lock(|| self.read_unlocked(job_id))
    }

    pub fn retry(&self, job_id: &str) -> Result<SubmitOutcome> {
        self.retry_with_spec(job_id, None)
    }

    pub fn retry_with_spec(
        &self,
        job_id: &str,
        replacement: Option<JobSpec>,
    ) -> Result<SubmitOutcome> {
        validate_identifier("job ID", job_id)?;
        if let Some(replacement) = &replacement {
            validate_spec(replacement)?;
            if replacement.job_id != job_id {
                bail!(
                    "replacement job specification ID {:?} does not match retry ID {job_id:?}",
                    replacement.job_id
                );
            }
        }
        let outcome = self.with_job_lock(|| {
            let mut job = self
                .read_unlocked(job_id)?
                .with_context(|| format!("job {job_id:?} does not exist"))?;
            match job.status {
                JobStatus::Failed => {
                    if let Some(replacement) = &replacement {
                        job.spec = retry_spec_with_host_key_enrichment(&job.spec, replacement)?;
                    }
                    job.status = JobStatus::Pending;
                    job.started_at = None;
                    job.finished_at = None;
                    job.result = None;
                    job.progress = None;
                    job.error = None;
                    self.write_unlocked(&job)?;
                    Ok(SubmitOutcome { changed: true, job })
                }
                JobStatus::Pending | JobStatus::Running => {
                    if replacement
                        .as_ref()
                        .is_some_and(|replacement| replacement != &job.spec)
                    {
                        bail!("retry replacement may enrich only a terminal failed broker job");
                    }
                    Ok(SubmitOutcome {
                        changed: false,
                        job,
                    })
                }
                JobStatus::Succeeded => {
                    bail!("refusing to retry succeeded job {job_id:?}")
                }
            }
        })?;
        if outcome.job.status == JobStatus::Pending {
            self.wake_worker()?;
        }
        Ok(outcome)
    }

    pub fn list(&self) -> Result<Vec<JobRecord>> {
        self.with_job_lock(|| self.list_unlocked())
    }

    pub fn update_progress(&self, job_id: &str, progress: Value) -> Result<()> {
        validate_identifier("job ID", job_id)?;
        self.with_job_lock(|| {
            let mut job = self
                .read_unlocked(job_id)?
                .with_context(|| format!("job {job_id:?} does not exist"))?;
            if job.status != JobStatus::Running {
                bail!("cannot update progress for non-running job {job_id:?}");
            }
            job.progress = Some(progress);
            self.write_unlocked(&job)
        })
    }

    pub fn run_job<F>(&self, job_id: &str, execute: F) -> Result<JobRecord>
    where
        F: FnOnce(&JobSpec) -> Result<JobExecution>,
    {
        validate_identifier("job ID", job_id)?;
        self.with_execution_lock(|| self.run_one_locked(job_id, execute))
    }

    pub fn run_pending<F>(&self, mut execute: F) -> Result<Vec<JobRecord>>
    where
        F: FnMut(&JobSpec) -> Result<JobExecution>,
    {
        self.with_execution_lock(|| {
            self.clear_worker_wakeup()?;
            let job_ids = self.with_job_lock(|| {
                Ok(self
                    .list_unlocked()?
                    .into_iter()
                    .filter(|job| matches!(job.status, JobStatus::Pending | JobStatus::Running))
                    .map(|job| job.spec.job_id)
                    .collect::<Vec<_>>())
            })?;
            let mut completed = Vec::with_capacity(job_ids.len());
            for job_id in job_ids {
                completed.push(self.run_one_locked(&job_id, |spec| execute(spec))?);
            }
            Ok(completed)
        })
    }

    fn run_one_locked<F>(&self, job_id: &str, execute: F) -> Result<JobRecord>
    where
        F: FnOnce(&JobSpec) -> Result<JobExecution>,
    {
        let mut job = self.with_job_lock(|| {
            let mut job = self
                .read_unlocked(job_id)?
                .with_context(|| format!("job {job_id:?} does not exist"))?;
            if matches!(job.status, JobStatus::Succeeded | JobStatus::Failed) {
                return Ok(job);
            }
            job.status = JobStatus::Running;
            job.attempts = job.attempts.saturating_add(1);
            job.started_at = Some(now()?);
            job.finished_at = None;
            job.result = None;
            job.progress = None;
            job.error = None;
            self.write_unlocked(&job)?;
            Ok(job)
        })?;

        if matches!(job.status, JobStatus::Succeeded | JobStatus::Failed) {
            return Ok(job);
        }
        match execute(&job.spec) {
            Ok(execution) => {
                job.status = if execution.error.is_some() {
                    JobStatus::Failed
                } else {
                    JobStatus::Succeeded
                };
                job.result = Some(execution.result);
                job.error = execution.error;
            }
            Err(error) => {
                job.status = JobStatus::Failed;
                job.error = Some(format!("{error:#}"));
            }
        }
        job.progress = self.with_job_lock(|| {
            Ok(self
                .read_unlocked(job_id)?
                .and_then(|current| current.progress))
        })?;
        job.finished_at = Some(now()?);
        self.with_job_lock(|| self.write_unlocked(&job))?;
        Ok(job)
    }

    fn with_job_lock<T>(&self, operation: impl FnOnce() -> Result<T>) -> Result<T> {
        self.prepare_directories()?;
        let lock_path = self.jobs_dir().join("jobs.lock");
        let lock = open_lock(&lock_path)?;
        lock.lock()
            .with_context(|| format!("lock job state {}", lock_path.display()))?;
        operation()
    }

    fn with_execution_lock<T>(&self, operation: impl FnOnce() -> Result<T>) -> Result<T> {
        self.prepare_directories()?;
        let lock_path = self.jobs_dir().join("execution.lock");
        let lock = open_lock(&lock_path)?;
        lock.lock()
            .with_context(|| format!("lock job execution {}", lock_path.display()))?;
        operation()
    }

    fn prepare_directories(&self) -> Result<()> {
        create_private_dir(&self.root)?;
        create_private_dir(&self.jobs_dir())
    }

    fn jobs_dir(&self) -> PathBuf {
        self.root.join("jobs")
    }

    fn worker_wakeup_path(&self) -> PathBuf {
        self.root.join("jobs-wakeup")
    }

    fn wake_worker(&self) -> Result<()> {
        self.prepare_directories()?;
        let path = self.worker_wakeup_path();
        OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&path)
            .with_context(|| format!("create job worker wakeup {}", path.display()))?
            .sync_all()
            .with_context(|| format!("sync job worker wakeup {}", path.display()))
    }

    fn clear_worker_wakeup(&self) -> Result<()> {
        let path = self.worker_wakeup_path();
        match fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error).with_context(|| format!("remove {}", path.display())),
        }
    }

    fn job_path(&self, job_id: &str) -> PathBuf {
        self.jobs_dir().join(job_file_name(job_id))
    }

    fn read_unlocked(&self, job_id: &str) -> Result<Option<JobRecord>> {
        let path = self.job_path(job_id);
        let mut file = match File::open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error).with_context(|| format!("open {}", path.display())),
        };
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)
            .with_context(|| format!("read {}", path.display()))?;
        let job: JobRecord =
            serde_json::from_slice(&bytes).with_context(|| format!("parse {}", path.display()))?;
        validate_stored_job(&job, &path)?;
        if job.spec.job_id != job_id {
            bail!("job state integrity error in {}", path.display());
        }
        Ok(Some(job))
    }

    fn list_unlocked(&self) -> Result<Vec<JobRecord>> {
        let mut paths = fs::read_dir(self.jobs_dir())
            .with_context(|| format!("list jobs in {}", self.jobs_dir().display()))?
            .map(|entry| entry.map(|entry| entry.path()))
            .collect::<std::io::Result<Vec<_>>>()?;
        paths.retain(|path| {
            path.extension()
                .is_some_and(|extension| extension == "json")
        });
        paths.sort();
        let mut jobs = Vec::with_capacity(paths.len());
        for path in paths {
            let job: JobRecord = serde_json::from_slice(
                &fs::read(&path).with_context(|| format!("read {}", path.display()))?,
            )
            .with_context(|| format!("parse {}", path.display()))?;
            validate_stored_job(&job, &path)?;
            if self.job_path(&job.spec.job_id) != path {
                bail!("job state integrity error in {}", path.display());
            }
            jobs.push(job);
        }
        jobs.sort_by(|left, right| left.spec.job_id.cmp(&right.spec.job_id));
        Ok(jobs)
    }

    fn write_unlocked(&self, job: &JobRecord) -> Result<()> {
        let final_path = self.job_path(&job.spec.job_id);
        let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp_path = self.jobs_dir().join(format!(
            ".{}.{}.{}.tmp",
            digest_bytes(job.spec.job_id.as_bytes()),
            std::process::id(),
            sequence
        ));
        let bytes = serde_json::to_vec_pretty(job)?;
        let write_result = (|| -> Result<()> {
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(&temp_path)
                .with_context(|| format!("create {}", temp_path.display()))?;
            file.write_all(&bytes)
                .with_context(|| format!("write {}", temp_path.display()))?;
            file.write_all(b"\n")
                .with_context(|| format!("write {}", temp_path.display()))?;
            file.sync_all()
                .with_context(|| format!("sync {}", temp_path.display()))?;
            fs::rename(&temp_path, &final_path).with_context(|| {
                format!(
                    "atomically replace {} with {}",
                    final_path.display(),
                    temp_path.display()
                )
            })?;
            sync_directory(&self.jobs_dir())
        })();
        if write_result.is_err() {
            let _ = fs::remove_file(&temp_path);
        }
        write_result
    }
}

fn retry_spec_with_host_key_enrichment(
    existing: &JobSpec,
    replacement: &JobSpec,
) -> Result<JobSpec> {
    if existing == replacement {
        return Ok(existing.clone());
    }
    let mut enriched = existing.clone();
    let (old_source, old_target, new_source, new_target) =
        match (&mut enriched.operation, &replacement.operation) {
            (
                JobOperation::BrokerCopy {
                    source: old_source,
                    target: old_target,
                    ..
                },
                JobOperation::BrokerCopy {
                    source: new_source,
                    target: new_target,
                    ..
                },
            )
            | (
                JobOperation::BrokerVerify {
                    source: old_source,
                    target: old_target,
                    ..
                },
                JobOperation::BrokerVerify {
                    source: new_source,
                    target: new_target,
                    ..
                },
            ) => (old_source, old_target, new_source, new_target),
            _ => bail!("retry replacement changes the immutable job specification"),
        };
    for (old, new) in [(old_source, new_source), (old_target, new_target)] {
        if !old.host_public_keys.is_empty() || new.host_public_keys.is_empty() {
            bail!("retry replacement may only add missing broker endpoint host-key pins");
        }
        old.host_public_keys = new.host_public_keys.clone();
    }
    if enriched != *replacement {
        bail!("retry replacement changes fields other than missing broker endpoint host-key pins");
    }
    Ok(enriched)
}

pub fn job_file_name(job_id: &str) -> String {
    format!("{}.json", digest_bytes(job_id.as_bytes()))
}

/// Canonical bounded job identity shared by deploy and controller reconciliation
/// for an exact projected unhold.
pub fn projected_release_job_id(projection_id: &str, resource: &str, hold_epoch: &str) -> String {
    let digest =
        digest_bytes(format!("{projection_id}\0{resource}\0{hold_epoch}\0unheld").as_bytes());
    format!("projection-unhold-{}", &digest[..32])
}

/// Canonical bounded manager job identity for one projected hold epoch.
pub fn projected_hold_job_id(
    projection_id: &str,
    resource: &str,
    hold_epoch: &str,
    projection_digest: &str,
) -> String {
    let digest = digest_bytes(
        format!("{projection_id}\0{resource}\0{hold_epoch}\0{projection_digest}\0held").as_bytes(),
    );
    format!("projection-hold-{}", &digest[..32])
}

fn validate_spec(spec: &JobSpec) -> Result<()> {
    if spec.schema_version != 1 {
        bail!(
            "unsupported job specification schema version {}",
            spec.schema_version
        );
    }
    validate_identifier("job ID", &spec.job_id)?;
    validate_identifier("transaction ID", &spec.transaction_id)?;
    if let Some(projection) = &spec.projection {
        validate_digest("intent digest", &projection.intent_digest)?;
        validate_digest("projection digest", &projection.projection_digest)?;
        if projection.generation == 0 {
            bail!("projection generation must be greater than zero");
        }
        if let Some(epoch) = &projection.hold_epoch {
            validate_identifier("hold epoch", epoch)?;
        }
        if let Some(requirement) = &projection.activation_requirement_digest {
            validate_digest("activation requirement digest", requirement)?;
        }
        if matches!(&spec.operation, JobOperation::Activate)
            && projection.activation_requirement_digest.is_none()
        {
            bail!("projection-bound activation requires an activation requirement digest");
        }
        if matches!(
            &spec.operation,
            JobOperation::Reserve | JobOperation::Hold | JobOperation::Activate
        ) && projection.hold_epoch.is_none()
        {
            bail!("projection-bound hold and activation jobs require a hold epoch");
        }
    }
    validate_identifier("resource", &spec.resource)?;
    if let JobOperation::Named { name } = &spec.operation {
        validate_identifier("named operation", name)?;
    }
    if let JobOperation::Transfer { name } | JobOperation::VerifyTransfer { name } = &spec.operation
    {
        validate_identifier("transfer", name)?;
    }
    if let JobOperation::Restore { active_services } = &spec.operation {
        if active_services.is_empty() {
            bail!("restore requires at least one previously active service");
        }
        for (index, service) in active_services.iter().enumerate() {
            service.validate()?;
            if !spec.services.contains(service) {
                bail!("restore service {service} is not declared by the resource");
            }
            if active_services[..index].contains(service) {
                bail!("restore services cannot contain duplicates");
            }
        }
    }
    if let JobOperation::FileState { name } = &spec.operation {
        validate_identifier("file state", name)?;
    }
    if let JobOperation::Provision { name } | JobOperation::Deploy { name } = &spec.operation {
        validate_identifier("profile", name)?;
    }
    if let JobOperation::NixbotDeploy { request } = &spec.operation {
        validate_nixbot_deploy_request(request)?;
    }
    if let JobOperation::ControlInstance { request } = &spec.operation {
        validate_instance_control(request)?;
    }
    for root in &spec.data_root_plan {
        validate_data_root_plan(root)?;
    }
    if !matches!(&spec.operation, JobOperation::Status) && spec.expected_state != ExpectedState::Any
    {
        bail!("--expect is only valid for status jobs");
    }
    match &spec.operation {
        JobOperation::Activate
        | JobOperation::Restore { .. }
        | JobOperation::Stop
        | JobOperation::Start
            if spec.services.is_empty() =>
        {
            bail!(
                "job operation {:?} requires declared services",
                spec.operation
            )
        }
        JobOperation::Reserve if !spec.services.is_empty() => {
            bail!("reserve job must not snapshot service targets")
        }
        JobOperation::Manifest if spec.data_paths.is_empty() => {
            bail!("manifest job requires declared data paths")
        }
        JobOperation::WipeData if spec.data_paths.is_empty() || spec.data_root_plan.is_empty() => {
            bail!("data-wipe job requires declared data roots")
        }
        JobOperation::Named { .. } => {
            let argv = spec
                .argv
                .as_ref()
                .context("named job requires resolved argv")?;
            let executable = argv.first().context("named job argv cannot be empty")?;
            if !Path::new(executable).is_absolute() {
                bail!("named job executable must be absolute");
            }
            if argv.iter().any(|argument| argument.contains('\0')) {
                bail!("named job argv cannot contain NUL");
            }
        }
        JobOperation::Transfer { .. } | JobOperation::VerifyTransfer { .. }
            if spec.transfer.is_none() =>
        {
            bail!("transfer job requires a resolved transfer definition")
        }
        JobOperation::Backup | JobOperation::RestoreBackup { .. }
            if spec.resource_transfers.is_empty() =>
        {
            bail!("resource copy job requires metadata-derived transfers")
        }
        JobOperation::DeleteBackup { .. } if spec.data_paths.len() != 1 => {
            bail!("backup deletion job requires one resolved snapshot root")
        }
        JobOperation::FileState { .. } if spec.file_state.is_none() => {
            bail!("file-state job requires a resolved file-state definition")
        }
        JobOperation::Provision { .. } if spec.instance.is_none() => {
            bail!("provision job requires a resolved instance definition")
        }
        JobOperation::Deploy { .. } if spec.deployment.is_none() => {
            bail!("deploy job requires a resolved deployment definition")
        }
        JobOperation::NixbotDeploy { .. } if spec.nixbot_deploy.is_none() => {
            bail!("Nixbot deploy job requires a resolved controller policy")
        }
        _ => {}
    }
    if !matches!(&spec.operation, JobOperation::Named { .. }) && spec.argv.is_some() {
        bail!("resolved argv is only valid for named jobs");
    }
    if !matches!(
        &spec.operation,
        JobOperation::Transfer { .. } | JobOperation::VerifyTransfer { .. }
    ) && spec.transfer.is_some()
    {
        bail!("resolved transfer is only valid for transfer jobs");
    }
    if !matches!(
        &spec.operation,
        JobOperation::Backup | JobOperation::RestoreBackup { .. }
    ) && !spec.resource_transfers.is_empty()
    {
        bail!("metadata-derived transfers are only valid for resource copy jobs");
    }
    if matches!(
        &spec.operation,
        JobOperation::Backup | JobOperation::RestoreBackup { .. }
    ) {
        if spec.backup_consistency.is_none() {
            bail!("backup copy job requires resolved consistency policy");
        }
    } else if spec.backup_consistency.is_some() {
        bail!("backup consistency policy is only valid for backup jobs");
    }
    if matches!(
        &spec.operation,
        JobOperation::BrokerCopy { .. } | JobOperation::BrokerVerify { .. }
    ) {
        if spec.broker_transfer.is_none() {
            bail!("broker job requires a resolved broker transfer policy");
        }
    } else if spec.broker_transfer.is_some() {
        bail!("broker transfer policy is only valid for broker jobs");
    }
    for transfer in &spec.resource_transfers {
        crate::transfer::validate_transfer(transfer)?;
    }
    if !matches!(&spec.operation, JobOperation::FileState { .. }) && spec.file_state.is_some() {
        bail!("resolved file state is only valid for file-state jobs");
    }
    if !matches!(&spec.operation, JobOperation::Provision { .. }) && spec.instance.is_some() {
        bail!("resolved instance is only valid for provision jobs");
    }
    if !matches!(&spec.operation, JobOperation::Deploy { .. }) && spec.deployment.is_some() {
        bail!("resolved deployment is only valid for deploy jobs");
    }
    if !matches!(&spec.operation, JobOperation::NixbotDeploy { .. }) && spec.nixbot_deploy.is_some()
    {
        bail!("resolved Nixbot policy is only valid for Nixbot deploy jobs");
    }
    Ok(())
}

fn validate_digest(label: &str, value: &str) -> Result<()> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
    {
        bail!("{label} must be a lowercase SHA-256 digest");
    }
    Ok(())
}

fn validate_stored_job(job: &JobRecord, path: &Path) -> Result<()> {
    validate_spec(&job.spec).with_context(|| format!("invalid job in {}", path.display()))
}

fn validate_identifier(name: &str, value: &str) -> Result<()> {
    if value.trim().is_empty() || value.contains('\0') {
        bail!("{name} must be non-empty and cannot contain NUL");
    }
    Ok(())
}

fn now() -> Result<Timestamp> {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before the Unix epoch")?;
    Ok(Timestamp {
        seconds: duration.as_secs(),
        nanoseconds: duration.subsec_nanos(),
    })
}

fn open_lock(path: &Path) -> Result<File> {
    OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("open lock {}", path.display()))
}

fn create_private_dir(path: &Path) -> Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true).mode(0o700);
    builder
        .create(path)
        .with_context(|| format!("create job state directory {}", path.display()))
}

fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)
        .with_context(|| format!("open directory {} for sync", path.display()))?
        .sync_all()
        .with_context(|| format!("sync directory {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projected_hold_job_ids_rotate_with_the_epoch() {
        let digest_v1 = "1".repeat(64);
        let digest_v2 = "2".repeat(64);
        let held_v1 = projected_hold_job_id("hold-zulip", "service:zulip", "hold-v1", &digest_v1);
        let held_v1_next =
            projected_hold_job_id("hold-zulip", "service:zulip", "hold-v1", &digest_v2);
        let held_v3 = projected_hold_job_id("hold-zulip", "service:zulip", "hold-v3", &digest_v1);
        let clear_v1 = projected_release_job_id("hold-zulip", "service:zulip", "hold-v1");
        let clear_v3 = projected_release_job_id("hold-zulip", "service:zulip", "hold-v3");
        assert_ne!(held_v1, held_v3);
        assert_ne!(held_v1, held_v1_next);
        assert_ne!(clear_v1, clear_v3);
        assert_ne!(held_v1, clear_v1);
    }

    fn broker_endpoint(host: &str, keys: Vec<String>) -> crate::transfer::RemoteSource {
        crate::transfer::RemoteSource {
            host: host.to_owned(),
            host_public_keys: keys,
            user: Some("nixbot".to_owned()),
            port: None,
            identity_file: None,
            ssh_program: PathBuf::from("/bin/ssh"),
            ssh_args: Vec::new(),
            agent_program: PathBuf::from("/bin/abird-host-agent"),
            agent_prefix: Vec::new(),
            rsync_program: PathBuf::from("/bin/rsync"),
            rsync_prefix: Vec::new(),
            tar_program: PathBuf::from("/bin/tar"),
        }
    }

    fn broker_spec(job_id: &str, source_keys: Vec<String>, target_keys: Vec<String>) -> JobSpec {
        let mut spec = spec(
            job_id,
            JobOperation::BrokerCopy {
                source: broker_endpoint("source", source_keys),
                target: broker_endpoint("target", target_keys),
                destination_root: None,
                backup_source: false,
            },
        );
        spec.broker_transfer = Some(BrokerTransferPolicy {
            identity_file: PathBuf::from("/identity"),
            ssh_program: PathBuf::from("/bin/ssh"),
            ssh_agent_program: PathBuf::from("/bin/ssh-agent"),
            ssh_add_program: PathBuf::from("/bin/ssh-add"),
            ssh_args: Vec::new(),
        });
        spec
    }

    fn spec(job_id: &str, operation: JobOperation) -> JobSpec {
        let services = if matches!(
            &operation,
            JobOperation::Hold
                | JobOperation::Activate
                | JobOperation::Stop
                | JobOperation::Start
                | JobOperation::Status
                | JobOperation::Ready
        ) {
            vec![ServiceTarget::system("zulip.service")]
        } else {
            Vec::new()
        };
        let data_paths = if matches!(&operation, JobOperation::Manifest | JobOperation::WipeData) {
            vec![PathBuf::from("/var/lib/zulip")]
        } else {
            Vec::new()
        };
        JobSpec {
            schema_version: 1,
            job_id: job_id.to_owned(),
            transaction_id: "tx-1".to_owned(),
            projection: None,
            resource: "service:zulip".to_owned(),
            operation,
            expected_state: ExpectedState::Any,
            services,
            data_paths,
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
        }
    }

    #[test]
    fn data_only_resources_can_be_held_and_checked() {
        for operation in [JobOperation::Hold, JobOperation::Status] {
            let mut spec = spec("data-only", operation);
            spec.services.clear();
            validate_spec(&spec).unwrap();
        }
    }

    #[test]
    fn submission_is_idempotent_but_rejects_a_changed_spec() {
        let temp = tempfile::tempdir().unwrap();
        let store = JobStore::new(temp.path());
        assert!(
            store
                .submit(spec("job-1", JobOperation::Stop))
                .unwrap()
                .changed
        );
        assert!(
            !store
                .submit(spec("job-1", JobOperation::Stop))
                .unwrap()
                .changed
        );
        assert!(store.submit(spec("job-1", JobOperation::Start)).is_err());
    }

    #[test]
    fn legacy_job_spec_deserializes_without_projection_binding() {
        let mut value = serde_json::to_value(spec("job-1", JobOperation::Status)).unwrap();
        value.as_object_mut().unwrap().remove("projection");
        let decoded: JobSpec = serde_json::from_value(value).unwrap();
        assert!(decoded.projection.is_none());
        validate_spec(&decoded).unwrap();
    }

    #[test]
    fn legacy_projection_fields_decode_but_serialize_with_generic_names() {
        let digest = "a".repeat(64);
        let binding: JobProjectionBinding = serde_json::from_value(serde_json::json!({
            "transaction_digest": digest,
            "projection_digest": "b".repeat(64),
            "generation": 3,
            "hold_declaration_id": "tx-1:target:g3",
            "prepared_receipt_requirement": "c".repeat(64)
        }))
        .unwrap();
        assert_eq!(binding.intent_digest, "a".repeat(64));
        assert_eq!(binding.hold_epoch.as_deref(), Some("tx-1:target:g3"));
        let encoded = serde_json::to_value(binding).unwrap();
        assert!(encoded.get("transaction_digest").is_none());
        assert!(encoded.get("hold_declaration_id").is_none());
        assert!(encoded.get("prepared_receipt_requirement").is_none());
        assert_eq!(encoded["intent_digest"], "a".repeat(64));
        assert_eq!(encoded["hold_epoch"], "tx-1:target:g3");
        assert_eq!(encoded["activation_requirement_digest"], "c".repeat(64));
    }

    #[test]
    fn projection_binding_validates_digests_generation_and_activation_requirement() {
        let digest = "a".repeat(64);
        let mut bound = spec("job-1", JobOperation::Status);
        bound.projection = Some(JobProjectionBinding {
            intent_digest: digest.clone(),
            projection_digest: digest.clone(),
            generation: 1,
            hold_epoch: None,
            activation_requirement_digest: None,
        });
        validate_spec(&bound).unwrap();

        bound.projection.as_mut().unwrap().generation = 0;
        assert!(validate_spec(&bound).is_err());
        bound.projection.as_mut().unwrap().generation = 1;
        bound.projection.as_mut().unwrap().projection_digest = "ABC".to_owned();
        assert!(validate_spec(&bound).is_err());

        let mut activation = spec("activate-1", JobOperation::Activate);
        activation.projection = Some(JobProjectionBinding {
            intent_digest: digest.clone(),
            projection_digest: digest.clone(),
            generation: 2,
            hold_epoch: Some("target:epoch-1".to_owned()),
            activation_requirement_digest: None,
        });
        assert!(validate_spec(&activation).is_err());
        activation
            .projection
            .as_mut()
            .unwrap()
            .activation_requirement_digest = Some(digest);
        validate_spec(&activation).unwrap();

        let mut hold = spec("hold-1", JobOperation::Hold);
        hold.projection = activation.projection.clone();
        hold.projection.as_mut().unwrap().hold_epoch = None;
        assert!(validate_spec(&hold).is_err());
        hold.projection.as_mut().unwrap().hold_epoch = Some(String::new());
        assert!(validate_spec(&hold).is_err());
        hold.projection.as_mut().unwrap().hold_epoch = Some("target:epoch-1".to_owned());
        validate_spec(&hold).unwrap();
    }

    #[test]
    fn execution_persists_success_and_failure() {
        let temp = tempfile::tempdir().unwrap();
        let store = JobStore::new(temp.path());
        store.submit(spec("success", JobOperation::Status)).unwrap();
        let success = store
            .run_job("success", |_| {
                Ok(JobExecution::succeeded(serde_json::json!({"active": true})))
            })
            .unwrap();
        assert_eq!(success.status, JobStatus::Succeeded);
        assert_eq!(success.attempts, 1);

        store.submit(spec("failure", JobOperation::Status)).unwrap();
        let failure = store
            .run_job("failure", |_| bail!("injected failure"))
            .unwrap();
        assert_eq!(failure.status, JobStatus::Failed);
        assert!(failure.error.unwrap().contains("injected failure"));
    }

    #[test]
    fn failed_job_can_be_explicitly_retried_with_the_same_specification() {
        let temp = tempfile::tempdir().unwrap();
        let store = JobStore::new(temp.path());
        store.submit(spec("job-1", JobOperation::Status)).unwrap();
        store
            .run_job("job-1", |_| {
                Ok(JobExecution::failed(serde_json::json!({}), "failed"))
            })
            .unwrap();

        let retried = store.retry("job-1").unwrap();
        assert!(retried.changed);
        assert_eq!(retried.job.status, JobStatus::Pending);
        assert_eq!(retried.job.attempts, 1);
        assert!(retried.job.error.is_none());

        let completed = store
            .run_job("job-1", |_| {
                Ok(JobExecution::succeeded(serde_json::json!({})))
            })
            .unwrap();
        assert_eq!(completed.status, JobStatus::Succeeded);
        assert_eq!(completed.attempts, 2);
        assert!(store.retry("job-1").is_err());
    }

    #[test]
    fn failed_broker_job_can_atomically_add_missing_authenticated_host_keys() {
        let temp = tempfile::tempdir().unwrap();
        let store = JobStore::new(temp.path());
        store
            .submit(broker_spec("job-1", Vec::new(), Vec::new()))
            .unwrap();
        store
            .run_job("job-1", |_| bail!("injected failure before copy"))
            .unwrap();

        let replacement = broker_spec(
            "job-1",
            vec!["ssh-ed25519 source-key".to_owned()],
            vec!["ssh-ed25519 target-key".to_owned()],
        );
        let retried = store
            .retry_with_spec("job-1", Some(replacement.clone()))
            .unwrap();
        assert_eq!(retried.job.status, JobStatus::Pending);
        assert_eq!(retried.job.spec, replacement);
        assert_eq!(store.status("job-1").unwrap().spec, replacement);
    }

    #[test]
    fn broker_retry_enrichment_rejects_every_other_specification_change() {
        let mut existing = broker_spec("job-1", Vec::new(), Vec::new());
        let mut replacement = broker_spec(
            "job-1",
            vec!["ssh-ed25519 source-key".to_owned()],
            vec!["ssh-ed25519 target-key".to_owned()],
        );
        replacement.resource = "service:other".to_owned();
        assert!(retry_spec_with_host_key_enrichment(&existing, &replacement).is_err());

        existing = replacement.clone();
        let mut rotated = replacement;
        let JobOperation::BrokerCopy { source, .. } = &mut rotated.operation else {
            unreachable!()
        };
        source.host_public_keys = vec!["ssh-ed25519 rotated-key".to_owned()];
        assert!(retry_spec_with_host_key_enrichment(&existing, &rotated).is_err());
    }

    #[test]
    fn running_job_progress_is_durable_and_terminal_safe() {
        let temp = tempfile::tempdir().unwrap();
        let store = JobStore::new(temp.path());
        store.submit(spec("job-1", JobOperation::Status)).unwrap();
        let completed = store
            .run_job("job-1", |_| {
                store.update_progress(
                    "job-1",
                    serde_json::json!({"stage":"copying","entries_completed":128}),
                )?;
                Ok(JobExecution::succeeded(serde_json::json!({"done":true})))
            })
            .unwrap();
        assert_eq!(
            completed.progress.unwrap()["entries_completed"],
            serde_json::json!(128)
        );
        assert!(
            store
                .update_progress("job-1", serde_json::json!({"stage":"late"}))
                .is_err()
        );
    }

    #[test]
    fn run_pending_recovers_a_running_job() {
        let temp = tempfile::tempdir().unwrap();
        let store = JobStore::new(temp.path());
        store.submit(spec("job-1", JobOperation::Manifest)).unwrap();
        store
            .with_job_lock(|| {
                let mut job = store.read_unlocked("job-1")?.unwrap();
                job.status = JobStatus::Running;
                job.attempts = 1;
                store.write_unlocked(&job)
            })
            .unwrap();

        let completed = store
            .run_pending(|_| Ok(JobExecution::succeeded(serde_json::json!({"entries": 2}))))
            .unwrap();
        assert_eq!(completed.len(), 1);
        assert_eq!(completed[0].status, JobStatus::Succeeded);
        assert_eq!(completed[0].attempts, 2);
    }

    #[test]
    fn pending_jobs_use_a_separate_consumable_worker_wakeup() {
        let temp = tempfile::tempdir().unwrap();
        let store = JobStore::new(temp.path());
        store.submit(spec("job-1", JobOperation::Status)).unwrap();
        assert!(store.worker_wakeup_path().is_file());

        let completed = store
            .run_pending(|_| Ok(JobExecution::succeeded(serde_json::json!({}))))
            .unwrap();
        assert_eq!(completed.len(), 1);
        assert!(!store.worker_wakeup_path().exists());
    }
}
