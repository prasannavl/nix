use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::instance::{InstanceControlAction, InstanceControlRequest, validate_instance_control};
use crate::service::ServiceTarget;
use crate::sha256::digest_bytes;

static TEMP_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Timestamp {
    pub seconds: u64,
    pub nanoseconds: u32,
}

impl Timestamp {
    fn now() -> Result<Self> {
        let duration = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .context("system clock is before the Unix epoch")?;
        Ok(Self {
            seconds: duration.as_secs(),
            nanoseconds: duration.subsec_nanos(),
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct HoldRecord {
    pub schema_version: u32,
    pub resource: String,
    pub transaction_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub declaration_id: Option<String>,
    pub services: Vec<ServiceTarget>,
    /// Optional non-systemd enforcement replayed at boot while this hold owns
    /// an Incus endpoint.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub instance_gate: Option<InstanceControlRequest>,
    pub acquired_at: Timestamp,
}

#[derive(Debug, Serialize)]
pub struct AcquireOutcome {
    pub changed: bool,
    pub hold: HoldRecord,
}

#[derive(Debug, Serialize)]
pub struct DeclareOutcome {
    pub changed: bool,
    pub released: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hold: Option<HoldRecord>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DeclarationRelease {
    pub schema_version: u32,
    pub resource: String,
    pub declaration_id: String,
    pub transaction_id: String,
    pub released_at: Timestamp,
}

#[derive(Debug, Serialize)]
pub struct ReleaseOutcome {
    pub changed: bool,
    pub resource: String,
    pub transaction_id: String,
    pub held: bool,
    pub services_started: bool,
}

#[derive(Debug, Serialize)]
pub struct HoldStatus {
    pub resource: String,
    pub held: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hold: Option<HoldRecord>,
}

#[derive(Clone, Debug)]
pub struct StateStore {
    root: PathBuf,
}

impl StateStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Stable path suitable for Nix-generated systemd cold-start conditions.
    pub fn hold_path(&self, resource: &str) -> PathBuf {
        self.holds_dir().join(hold_file_name(resource))
    }

    /// Stable runtime latch consumed by Nix-generated systemd conditions.
    pub fn declaration_release_path(&self, resource: &str, declaration_id: &str) -> PathBuf {
        self.releases_dir()
            .join(digest_bytes(resource.as_bytes()))
            .join(format!("{}.json", digest_bytes(declaration_id.as_bytes())))
    }

    pub fn declare_and_apply<F>(
        &self,
        resource: &str,
        declaration_id: &str,
        services: Vec<ServiceTarget>,
        apply: F,
    ) -> Result<DeclareOutcome>
    where
        F: FnOnce(&HoldRecord) -> Result<()>,
    {
        validate_identifier("resource", resource)?;
        validate_identifier("declaration ID", declaration_id)?;
        reject_duplicate_services(&services)?;

        self.with_lock(|| {
            if self
                .declaration_release_path(resource, declaration_id)
                .try_exists()
                .with_context(|| format!("inspect declaration release for {resource:?}"))?
            {
                return Ok(DeclareOutcome {
                    changed: false,
                    released: true,
                    hold: None,
                });
            }

            let existing = self.read_hold_unlocked(resource)?;
            let (changed, hold) = match existing {
                Some(mut existing) => {
                    if existing.services != services {
                        bail!(
                            "resource {resource:?} already has different service targets while declaring latch {declaration_id:?}"
                        );
                    }
                    match existing.declaration_id.as_deref() {
                        Some(existing_id) if existing_id != declaration_id => bail!(
                            "resource {resource:?} is associated with declaration {existing_id:?}, not {declaration_id:?}"
                        ),
                        Some(_) => (false, existing),
                        None => {
                            existing.declaration_id = Some(declaration_id.to_owned());
                            self.write_hold_unlocked(&existing)?;
                            (true, existing)
                        }
                    }
                }
                None => {
                    let hold = HoldRecord {
                        schema_version: 1,
                        resource: resource.to_owned(),
                        transaction_id: declaration_owner(declaration_id),
                        declaration_id: Some(declaration_id.to_owned()),
                        services,
                        instance_gate: None,
                        acquired_at: Timestamp::now()?,
                    };
                    self.write_hold_unlocked(&hold)?;
                    (true, hold)
                }
            };

            apply(&hold)?;
            Ok(DeclareOutcome {
                changed,
                released: false,
                hold: Some(hold),
            })
        })
    }

    pub fn acquire_and_apply<F>(
        &self,
        resource: &str,
        transaction_id: &str,
        services: Vec<ServiceTarget>,
        apply: F,
    ) -> Result<AcquireOutcome>
    where
        F: FnOnce(&HoldRecord) -> Result<()>,
    {
        validate_identifier("resource", resource)?;
        validate_identifier("transaction ID", transaction_id)?;
        reject_duplicate_services(&services)?;

        self.with_lock(|| {
            let existing = self.read_hold_unlocked(resource)?;
            let (changed, hold) = match existing {
                Some(mut existing) => {
                    let mut changed = false;
                    if existing.transaction_id != transaction_id {
                        let claimable = existing.declaration_id.as_deref().is_some_and(|id| {
                            existing.transaction_id == declaration_owner(id)
                        });
                        if !claimable {
                            bail!(
                                "resource {resource:?} is held by transaction {:?}, not {:?}",
                                existing.transaction_id,
                                transaction_id
                            );
                        }
                        existing.transaction_id = transaction_id.to_owned();
                        changed = true;
                    }
                    if existing.services != services {
                        if services.is_empty() {
                            // A repeated reservation must not erase service targets learned
                            // after the target generation was deployed.
                        } else if existing.services.is_empty() {
                            existing.services = services;
                            changed = true;
                        } else {
                            bail!(
                                "resource {resource:?} already has different service targets for transaction {transaction_id:?}"
                            );
                        }
                    }
                    if changed {
                        self.write_hold_unlocked(&existing)?;
                    }
                    (changed, existing)
                }
                None => {
                    let hold = HoldRecord {
                        schema_version: 1,
                        resource: resource.to_owned(),
                        transaction_id: transaction_id.to_owned(),
                        declaration_id: None,
                        services,
                        instance_gate: None,
                        acquired_at: Timestamp::now()?,
                    };
                    self.write_hold_unlocked(&hold)?;
                    (true, hold)
                }
            };

            // The record is durable before enforcement begins. If enforcement fails, the hold
            // remains present and a later `hold apply` can safely retry it.
            apply(&hold)?;
            Ok(AcquireOutcome { changed, hold })
        })
    }

    pub fn activate_and_apply<T, F>(
        &self,
        resource: &str,
        transaction_id: &str,
        services: &[ServiceTarget],
        apply: F,
    ) -> Result<(ReleaseOutcome, T)>
    where
        F: FnOnce() -> Result<T>,
    {
        validate_identifier("resource", resource)?;
        validate_identifier("transaction ID", transaction_id)?;
        reject_duplicate_services(services)?;

        self.with_lock(|| {
            let hold = self.read_hold_unlocked(resource)?;
            let changed = if let Some(hold) = hold {
                if hold.transaction_id != transaction_id {
                    bail!(
                        "refusing to activate resource {resource:?}: held by transaction {:?}, not {:?}",
                        hold.transaction_id,
                        transaction_id
                    );
                }
                if hold.services != services {
                    bail!(
                        "resource {resource:?} has different service targets for transaction {transaction_id:?}"
                    );
                }
                if let Some(declaration_id) = &hold.declaration_id {
                    self.write_declaration_release_unlocked(
                        resource,
                        declaration_id,
                        transaction_id,
                    )?;
                }
                fs::remove_file(self.hold_path(resource))
                    .with_context(|| format!("release hold for {resource:?}"))?;
                sync_directory(&self.holds_dir())?;
                true
            } else {
                false
            };

            let result = apply()?;
            Ok((
                ReleaseOutcome {
                    changed,
                    resource: resource.to_owned(),
                    transaction_id: transaction_id.to_owned(),
                    held: false,
                    services_started: true,
                },
                result,
            ))
        })
    }

    /// Run an owner-authorized activation while the hold is still durable, then
    /// release it only after the activation and its verification succeed.
    /// This is used for non-systemd resources such as whole Incus instances,
    /// where the controlled start can safely bypass its own hold but every
    /// unrelated start path must continue to observe it.
    pub fn activate_after_apply<T, F>(
        &self,
        resource: &str,
        transaction_id: &str,
        services: &[ServiceTarget],
        apply: F,
    ) -> Result<(ReleaseOutcome, T)>
    where
        F: FnOnce() -> Result<T>,
    {
        validate_identifier("resource", resource)?;
        validate_identifier("transaction ID", transaction_id)?;
        reject_duplicate_services(services)?;

        self.with_lock(|| {
            let hold = self
                .read_hold_unlocked(resource)?
                .with_context(|| format!("resource {resource:?} is not held for activation"))?;
            if hold.transaction_id != transaction_id {
                bail!(
                    "refusing to activate resource {resource:?}: held by transaction {:?}, not {:?}",
                    hold.transaction_id,
                    transaction_id
                );
            }
            if hold.services != services {
                bail!(
                    "resource {resource:?} has different service targets for transaction {transaction_id:?}"
                );
            }

            let result = apply()?;
            if let Some(declaration_id) = &hold.declaration_id {
                self.write_declaration_release_unlocked(
                    resource,
                    declaration_id,
                    transaction_id,
                )?;
            }
            fs::remove_file(self.hold_path(resource))
                .with_context(|| format!("release hold for {resource:?}"))?;
            sync_directory(&self.holds_dir())?;
            Ok((
                ReleaseOutcome {
                    changed: true,
                    resource: resource.to_owned(),
                    transaction_id: transaction_id.to_owned(),
                    held: false,
                    services_started: true,
                },
                result,
            ))
        })
    }

    /// Attach the exact Incus stop operation to an owned hold before the first
    /// stop attempt. Boot reconciliation can then re-enforce the gate even if
    /// the manager, agent process, or controller disappears mid-operation.
    pub fn attach_instance_gate(
        &self,
        resource: &str,
        transaction_id: &str,
        request: InstanceControlRequest,
    ) -> Result<bool> {
        validate_identifier("resource", resource)?;
        validate_identifier("transaction ID", transaction_id)?;
        validate_instance_control(&request)?;
        if !matches!(&request.operation, InstanceControlAction::Stop { .. }) {
            bail!("instance hold gate must be a stop operation");
        }

        self.with_lock(|| {
            let mut hold = self
                .read_hold_unlocked(resource)?
                .with_context(|| format!("resource {resource:?} is not held for instance gate"))?;
            if hold.transaction_id != transaction_id {
                bail!(
                    "refusing to gate resource {resource:?}: held by transaction {:?}, not {:?}",
                    hold.transaction_id,
                    transaction_id
                );
            }
            match &hold.instance_gate {
                Some(existing) if existing != &request => bail!(
                    "resource {resource:?} already has a different Incus gate for transaction {transaction_id:?}"
                ),
                Some(_) => Ok(false),
                None => {
                    hold.instance_gate = Some(request);
                    self.write_hold_unlocked(&hold)?;
                    Ok(true)
                }
            }
        })
    }

    pub fn release(&self, resource: &str, transaction_id: &str) -> Result<ReleaseOutcome> {
        validate_identifier("resource", resource)?;
        validate_identifier("transaction ID", transaction_id)?;

        self.with_lock(|| {
            let Some(hold) = self.read_hold_unlocked(resource)? else {
                return Ok(ReleaseOutcome {
                    changed: false,
                    resource: resource.to_owned(),
                    transaction_id: transaction_id.to_owned(),
                    held: false,
                    services_started: false,
                });
            };
            if hold.transaction_id != transaction_id {
                bail!(
                    "refusing to release resource {resource:?}: held by transaction {:?}, not {:?}",
                    hold.transaction_id,
                    transaction_id
                );
            }

            fs::remove_file(self.hold_path(resource))
                .with_context(|| format!("release hold for {resource:?}"))?;
            sync_directory(&self.holds_dir())?;
            Ok(ReleaseOutcome {
                changed: true,
                resource: resource.to_owned(),
                transaction_id: transaction_id.to_owned(),
                held: false,
                services_started: false,
            })
        })
    }

    pub fn status(&self, resource: &str) -> Result<HoldStatus> {
        validate_identifier("resource", resource)?;
        self.with_lock(|| {
            let hold = self.read_hold_unlocked(resource)?;
            Ok(HoldStatus {
                resource: resource.to_owned(),
                held: hold.is_some(),
                hold,
            })
        })
    }

    pub fn list(&self) -> Result<Vec<HoldRecord>> {
        self.with_lock(|| self.list_unlocked())
    }

    pub fn apply<F>(&self, resource: Option<&str>, mut apply: F) -> Result<Vec<HoldRecord>>
    where
        F: FnMut(&HoldRecord) -> Result<()>,
    {
        if let Some(resource) = resource {
            validate_identifier("resource", resource)?;
        }
        self.with_lock(|| {
            let holds = match resource {
                Some(resource) => self.read_hold_unlocked(resource)?.into_iter().collect(),
                None => self.list_unlocked()?,
            };
            for hold in &holds {
                apply(hold)?;
            }
            Ok(holds)
        })
    }

    pub fn run_if_service_unheld<T, F>(&self, target: &ServiceTarget, run: F) -> Result<T>
    where
        F: FnOnce() -> Result<T>,
    {
        self.with_lock(|| {
            if let Some(hold) = self
                .list_unlocked()?
                .into_iter()
                .find(|hold| hold.services.contains(target))
            {
                bail!(
                    "refusing to start {target}: resource {:?} is held by transaction {:?}",
                    hold.resource,
                    hold.transaction_id
                );
            }
            run()
        })
    }

    pub fn run_if_resource_unheld<T, F>(&self, resource: &str, run: F) -> Result<T>
    where
        F: FnOnce() -> Result<T>,
    {
        validate_identifier("resource", resource)?;
        self.with_lock(|| {
            if let Some(hold) = self.read_hold_unlocked(resource)? {
                bail!(
                    "refusing to start resource {:?}: held by transaction {:?}",
                    hold.resource,
                    hold.transaction_id
                );
            }
            run()
        })
    }

    fn with_lock<T>(&self, operation: impl FnOnce() -> Result<T>) -> Result<T> {
        self.prepare_directories()?;
        let lock_path = self.root.join("state.lock");
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(&lock_path)
            .with_context(|| format!("open state lock {}", lock_path.display()))?;
        lock.lock()
            .with_context(|| format!("lock state directory {}", self.root.display()))?;
        operation()
    }

    fn prepare_directories(&self) -> Result<()> {
        create_private_dir(&self.root)?;
        create_private_dir(&self.holds_dir())?;
        create_private_dir(&self.releases_dir())
    }

    fn holds_dir(&self) -> PathBuf {
        self.root.join("holds")
    }

    fn releases_dir(&self) -> PathBuf {
        self.root.join("declaration-releases")
    }

    fn read_hold_unlocked(&self, resource: &str) -> Result<Option<HoldRecord>> {
        let path = self.hold_path(resource);
        let mut file = match File::open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error).with_context(|| format!("open {}", path.display())),
        };
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)
            .with_context(|| format!("read {}", path.display()))?;
        let hold: HoldRecord =
            serde_json::from_slice(&bytes).with_context(|| format!("parse {}", path.display()))?;
        if hold.schema_version != 1 {
            bail!(
                "unsupported hold schema version {} in {}",
                hold.schema_version,
                path.display()
            );
        }
        if hold.resource != resource {
            bail!(
                "hold state integrity error: {} contains resource {:?}, expected {:?}",
                path.display(),
                hold.resource,
                resource
            );
        }
        Ok(Some(hold))
    }

    fn list_unlocked(&self) -> Result<Vec<HoldRecord>> {
        let mut paths = fs::read_dir(self.holds_dir())
            .with_context(|| format!("list holds in {}", self.holds_dir().display()))?
            .map(|entry| entry.map(|entry| entry.path()))
            .collect::<std::io::Result<Vec<_>>>()?;
        paths.retain(|path| {
            path.extension()
                .is_some_and(|extension| extension == "json")
        });
        paths.sort();

        let mut holds = Vec::with_capacity(paths.len());
        for path in paths {
            let bytes = fs::read(&path).with_context(|| format!("read {}", path.display()))?;
            let hold: HoldRecord = serde_json::from_slice(&bytes)
                .with_context(|| format!("parse {}", path.display()))?;
            if hold.schema_version != 1 {
                bail!(
                    "unsupported hold schema version {} in {}",
                    hold.schema_version,
                    path.display()
                );
            }
            if self.hold_path(&hold.resource) != path {
                bail!("hold state integrity error in {}", path.display());
            }
            holds.push(hold);
        }
        holds.sort_by(|left, right| left.resource.cmp(&right.resource));
        Ok(holds)
    }

    fn write_hold_unlocked(&self, hold: &HoldRecord) -> Result<()> {
        let final_path = self.hold_path(&hold.resource);
        let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp_path = self.holds_dir().join(format!(
            ".{}.{}.{}.tmp",
            digest_bytes(hold.resource.as_bytes()),
            std::process::id(),
            sequence
        ));
        let bytes = serde_json::to_vec_pretty(hold)?;

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
            sync_directory(&self.holds_dir())?;
            Ok(())
        })();

        if write_result.is_err() {
            let _ = fs::remove_file(&temp_path);
        }
        write_result
    }

    fn write_declaration_release_unlocked(
        &self,
        resource: &str,
        declaration_id: &str,
        transaction_id: &str,
    ) -> Result<()> {
        let final_path = self.declaration_release_path(resource, declaration_id);
        if final_path
            .try_exists()
            .with_context(|| format!("inspect {}", final_path.display()))?
        {
            let release: DeclarationRelease = serde_json::from_slice(
                &fs::read(&final_path).with_context(|| format!("read {}", final_path.display()))?,
            )
            .with_context(|| format!("parse {}", final_path.display()))?;
            if release.resource != resource
                || release.declaration_id != declaration_id
                || release.transaction_id != transaction_id
            {
                bail!(
                    "declaration release state conflicts at {}",
                    final_path.display()
                );
            }
            return Ok(());
        }

        let directory = final_path
            .parent()
            .context("declaration release path has no parent")?;
        create_private_dir(directory)?;
        let release = DeclarationRelease {
            schema_version: 1,
            resource: resource.to_owned(),
            declaration_id: declaration_id.to_owned(),
            transaction_id: transaction_id.to_owned(),
            released_at: Timestamp::now()?,
        };
        let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp_path = directory.join(format!(".{}.{}.tmp", std::process::id(), sequence));
        let bytes = serde_json::to_vec_pretty(&release)?;
        let write_result = (|| -> Result<()> {
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(&temp_path)
                .with_context(|| format!("create {}", temp_path.display()))?;
            file.write_all(&bytes)?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            fs::rename(&temp_path, &final_path)?;
            sync_directory(directory)
        })();
        if write_result.is_err() {
            let _ = fs::remove_file(&temp_path);
        }
        write_result
    }
}

fn create_private_dir(path: &Path) -> Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true).mode(0o700);
    builder
        .create(path)
        .with_context(|| format!("create state directory {}", path.display()))
}

fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)
        .with_context(|| format!("open directory {} for sync", path.display()))?
        .sync_all()
        .with_context(|| format!("sync directory {}", path.display()))
}

fn validate_identifier(name: &str, value: &str) -> Result<()> {
    if value.trim().is_empty() {
        bail!("{name} cannot be empty");
    }
    if value.contains('\0') {
        bail!("{name} cannot contain NUL");
    }
    Ok(())
}

fn reject_duplicate_services(services: &[ServiceTarget]) -> Result<()> {
    for (index, service) in services.iter().enumerate() {
        if services[..index].contains(service) {
            bail!("duplicate service target {service}");
        }
    }
    Ok(())
}

/// Stable filename used for the durable hold record of a declared resource.
pub fn hold_file_name(resource: &str) -> String {
    format!("{}.json", digest_bytes(resource.as_bytes()))
}

fn declaration_owner(declaration_id: &str) -> String {
    format!("declared:{}", digest_bytes(declaration_id.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn acquire_is_idempotent_and_release_requires_owner() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let services = vec![ServiceTarget::system("zulip.service")];

        let first = store
            .acquire_and_apply("service:zulip", "tx-1", services.clone(), |_| Ok(()))
            .unwrap();
        assert!(first.changed);
        let second = store
            .acquire_and_apply("service:zulip", "tx-1", services, |_| Ok(()))
            .unwrap();
        assert!(!second.changed);
        assert_eq!(first.hold.acquired_at, second.hold.acquired_at);

        let error = store.release("service:zulip", "tx-2").unwrap_err();
        assert!(error.to_string().contains("refusing to release"));
        assert!(store.status("service:zulip").unwrap().held);

        let released = store.release("service:zulip", "tx-1").unwrap();
        assert!(released.changed);
        assert!(!released.services_started);
        assert!(!store.release("service:zulip", "tx-1").unwrap().changed);
    }

    #[test]
    fn external_activation_releases_only_after_success() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        store
            .acquire_and_apply("instance:zulip", "tx-1", Vec::new(), |_| Ok(()))
            .unwrap();

        let failed = store.activate_after_apply("instance:zulip", "tx-1", &[], || -> Result<()> {
            anyhow::bail!("injected activation failure")
        });
        assert!(failed.is_err());
        assert!(store.status("instance:zulip").unwrap().held);

        let (release, value) = store
            .activate_after_apply("instance:zulip", "tx-1", &[], || Ok("running"))
            .unwrap();
        assert_eq!(value, "running");
        assert!(!release.held);
        assert!(!store.status("instance:zulip").unwrap().held);
    }

    #[test]
    fn instance_gate_is_persisted_before_stop_and_is_immutable() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        store
            .acquire_and_apply("instance:zulip", "tx-1", Vec::new(), |_| Ok(()))
            .unwrap();
        let request = InstanceControlRequest {
            program: "/bin/incus".into(),
            remote: "local".to_owned(),
            project: "default".to_owned(),
            instance: "zulip".to_owned(),
            stop_timeout_seconds: 60,
            force_after_timeout: false,
            operation: InstanceControlAction::Stop { allow_absent: true },
        };

        assert!(
            store
                .attach_instance_gate("instance:zulip", "tx-1", request.clone())
                .unwrap()
        );
        assert!(
            !store
                .attach_instance_gate("instance:zulip", "tx-1", request.clone())
                .unwrap()
        );
        assert_eq!(
            store
                .status("instance:zulip")
                .unwrap()
                .hold
                .unwrap()
                .instance_gate,
            Some(request.clone())
        );

        let mut changed = request;
        changed.instance = "other".to_owned();
        assert!(
            store
                .attach_instance_gate("instance:zulip", "tx-1", changed)
                .is_err()
        );
    }

    #[test]
    fn declarative_latch_is_claimed_without_an_unheld_window() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let services = vec![ServiceTarget::system("zulip.service")];

        let declared = store
            .declare_and_apply(
                "service:zulip",
                "bootstrap-v1",
                services.clone(),
                |_| Ok(()),
            )
            .unwrap();
        assert!(declared.changed);
        assert!(!declared.released);
        assert!(store.status("service:zulip").unwrap().held);

        let claimed = store
            .acquire_and_apply("service:zulip", "tx-1", services.clone(), |_| Ok(()))
            .unwrap();
        assert!(claimed.changed);
        assert_eq!(claimed.hold.transaction_id, "tx-1");
        assert_eq!(claimed.hold.declaration_id.as_deref(), Some("bootstrap-v1"));
        assert!(store.status("service:zulip").unwrap().held);
        assert!(
            !store
                .declaration_release_path("service:zulip", "bootstrap-v1")
                .exists()
        );

        let error = store
            .acquire_and_apply("service:zulip", "tx-2", services.clone(), |_| Ok(()))
            .unwrap_err();
        assert!(error.to_string().contains("held by transaction"));

        let (released, started) = store
            .activate_and_apply("service:zulip", "tx-1", &services, || Ok(true))
            .unwrap();
        assert!(released.changed);
        assert!(released.services_started);
        assert!(started);
        assert!(!store.status("service:zulip").unwrap().held);
        assert!(
            store
                .declaration_release_path("service:zulip", "bootstrap-v1")
                .exists()
        );

        let redeclared = store
            .declare_and_apply("service:zulip", "bootstrap-v1", services, |_| {
                bail!("released declaration must not be re-enforced")
            })
            .unwrap();
        assert!(redeclared.released);
        assert!(redeclared.hold.is_none());
    }

    #[test]
    fn plain_release_does_not_consume_a_declarative_latch() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let services = vec![ServiceTarget::system("zulip.service")];
        store
            .declare_and_apply(
                "service:zulip",
                "bootstrap-v1",
                services.clone(),
                |_| Ok(()),
            )
            .unwrap();
        store
            .acquire_and_apply("service:zulip", "tx-1", services.clone(), |_| Ok(()))
            .unwrap();
        store.release("service:zulip", "tx-1").unwrap();

        assert!(
            !store
                .declaration_release_path("service:zulip", "bootstrap-v1")
                .exists()
        );
        let redeclared = store
            .declare_and_apply("service:zulip", "bootstrap-v1", services, |_| Ok(()))
            .unwrap();
        assert!(redeclared.changed);
        assert!(store.status("service:zulip").unwrap().held);
    }

    #[test]
    fn failed_apply_preserves_the_hold_for_retry() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let result = store.acquire_and_apply("service:zulip", "tx-1", Vec::new(), |_| {
            bail!("injected enforcement failure")
        });
        assert!(result.is_err());
        assert!(store.status("service:zulip").unwrap().held);
    }

    #[test]
    fn reservation_learns_services_after_the_target_generation_exists() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        store
            .acquire_and_apply("service:zulip", "tx-1", Vec::new(), |_| Ok(()))
            .unwrap();

        let services = vec![ServiceTarget::system("zulip.service")];
        let reconciled = store
            .acquire_and_apply("service:zulip", "tx-1", services.clone(), |_| Ok(()))
            .unwrap();
        assert!(reconciled.changed);
        assert_eq!(reconciled.hold.services, services);

        let repeated_reservation = store
            .acquire_and_apply("service:zulip", "tx-1", Vec::new(), |_| Ok(()))
            .unwrap();
        assert!(!repeated_reservation.changed);
        assert_eq!(repeated_reservation.hold.services, services);
    }

    #[test]
    fn held_service_cannot_start_through_the_store() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let target = ServiceTarget::system("zulip.service");
        store
            .acquire_and_apply("service:zulip", "tx-1", vec![target.clone()], |_| Ok(()))
            .unwrap();

        let error = store.run_if_service_unheld(&target, || Ok(())).unwrap_err();
        assert!(error.to_string().contains("refusing to start"));
    }

    #[test]
    fn writes_only_complete_json_state_files() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        store
            .acquire_and_apply("service:zulip", "tx-1", Vec::new(), |_| Ok(()))
            .unwrap();

        let files = fs::read_dir(temp.path().join("holds"))
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect::<Vec<_>>();
        assert_eq!(files.len(), 1);
        let hold: HoldRecord = serde_json::from_slice(&fs::read(&files[0]).unwrap()).unwrap();
        assert_eq!(hold.resource, "service:zulip");
    }

    #[test]
    fn hold_filename_is_stable_for_cold_start_conditions() {
        assert_eq!(
            hold_file_name("service:zulip"),
            "68e46dc2fa58b18984f9aa48ab19bc95e522c72a3ea503c826cc482e63f720c1.json"
        );
    }
}
