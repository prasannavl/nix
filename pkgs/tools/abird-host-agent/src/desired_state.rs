use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::sha256::digest_bytes;
use crate::state::Timestamp;

const MANIFEST_LIMIT: u64 = 4 * 1024 * 1024;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DesiredResourceStateKind {
    Held,
    Inactive,
    Active,
    Unheld,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DesiredResourceState {
    pub id: String,
    pub state: DesiredResourceStateKind,
    pub projection_id: String,
    pub intent_digest: String,
    pub phase: String,
    pub projection_digest: String,
    pub generation: u64,
    pub hold_epoch: Option<String>,
    pub transaction_id: Option<String>,
    pub activation_job_id: Option<String>,
    pub activation_requirement_kind: Option<String>,
    pub activation_requirement_digest: Option<String>,
}

impl DesiredResourceState {
    pub fn hold_declaration_id(&self) -> Option<String> {
        self.hold_epoch
            .as_ref()
            .zip(self.transaction_id.as_ref())
            .map(|(epoch, transaction_id)| format!("{transaction_id}:{epoch}"))
    }

    fn validate(&self) -> Result<()> {
        validate_identifier("desired resource ID", &self.id)?;
        validate_identifier("projection ID", &self.projection_id)?;
        validate_digest("intent digest", &self.intent_digest)?;
        validate_identifier("opaque phase", &self.phase)?;
        validate_digest("projection digest", &self.projection_digest)?;
        if self.generation == 0 {
            bail!("desired resource projection generation must be greater than zero");
        }
        if let Some(epoch) = &self.hold_epoch {
            validate_identifier("hold epoch", epoch)?;
        }
        if self.hold_epoch.is_some() != self.transaction_id.is_some() {
            bail!("desired hold epoch and transaction identity must be declared together");
        }
        if let Some(transaction_id) = &self.transaction_id {
            validate_identifier("hold transaction ID", transaction_id)?;
        }
        if let Some(job_id) = &self.activation_job_id {
            validate_identifier("activation job ID", job_id)?;
        }
        match (
            &self.activation_requirement_kind,
            &self.activation_requirement_digest,
        ) {
            (Some(kind), Some(digest)) => {
                validate_identifier("activation requirement kind", kind)?;
                validate_digest("activation requirement digest", digest)?;
            }
            (None, None) => {}
            _ => bail!(
                "activation requirement kind and digest must be declared together for {:?}",
                self.id
            ),
        }
        if !matches!(self.state, DesiredResourceStateKind::Active) && self.hold_epoch.is_none() {
            bail!("held, inactive, and unheld desired resources require a hold epoch");
        }
        if self.hold_epoch.is_none() && self.activation_requirement_digest.is_some() {
            bail!("activation requirement requires a hold epoch");
        }
        if matches!(self.state, DesiredResourceStateKind::Active)
            && self.hold_epoch.is_some()
            && self.activation_requirement_digest.is_none()
        {
            bail!("activating a held resource requires an activation requirement digest");
        }
        let activation_required =
            matches!(self.state, DesiredResourceStateKind::Active) && self.hold_epoch.is_some();
        if activation_required != self.activation_job_id.is_some() {
            bail!("exactly active held desired resources require an activation job identity");
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DesiredResourceStateManifest {
    pub schema_version: u32,
    pub resources: Vec<DesiredResourceState>,
}

impl DesiredResourceStateManifest {
    pub fn load(path: &Path) -> Result<Self> {
        let mut bytes = Vec::new();
        File::open(path)
            .with_context(|| format!("open desired resource state manifest {}", path.display()))?
            .take(MANIFEST_LIMIT + 1)
            .read_to_end(&mut bytes)
            .with_context(|| format!("read desired resource state manifest {}", path.display()))?;
        if bytes.len() as u64 > MANIFEST_LIMIT {
            bail!("desired resource state manifest exceeds {MANIFEST_LIMIT} bytes");
        }
        let manifest: Self = serde_json::from_slice(&bytes)
            .with_context(|| format!("parse desired resource state manifest {}", path.display()))?;
        manifest.validate()?;
        Ok(manifest)
    }

    fn validate(&self) -> Result<()> {
        if self.schema_version != 1 {
            bail!(
                "unsupported desired resource state manifest schema version {}",
                self.schema_version
            );
        }
        for (index, resource) in self.resources.iter().enumerate() {
            resource.validate()?;
            if self.resources[..index]
                .iter()
                .any(|existing| existing.id == resource.id)
            {
                bail!(
                    "desired resource state manifest contains duplicate resource {:?}",
                    resource.id
                );
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DesiredResourceStateReceipt {
    pub schema_version: u32,
    pub desired: DesiredResourceState,
    pub applied_at: Timestamp,
}

#[derive(Clone, Debug)]
pub struct DesiredResourceStateReceiptStore {
    root: PathBuf,
}

impl DesiredResourceStateReceiptStore {
    pub fn new(state_root: impl AsRef<Path>) -> Self {
        Self {
            root: state_root.as_ref().join("desired-resource-state-receipts"),
        }
    }

    pub fn check_transition(&self, desired: &DesiredResourceState) -> Result<()> {
        let Some(existing) = self.read(&desired.id)? else {
            return Ok(());
        };
        if existing.desired.projection_id != desired.projection_id {
            return Ok(());
        }
        if existing.desired.intent_digest != desired.intent_digest {
            bail!(
                "desired resource {:?} changes immutable intent within projection {:?}",
                desired.id,
                desired.projection_id
            );
        }
        if desired.generation < existing.desired.generation {
            bail!(
                "desired resource {:?} projection generation regresses from {} to {}",
                desired.id,
                existing.desired.generation,
                desired.generation
            );
        }
        if desired.generation == existing.desired.generation && desired != &existing.desired {
            bail!(
                "desired resource {:?} changes projection content at generation {}",
                desired.id,
                desired.generation
            );
        }
        Ok(())
    }

    pub fn record(&self, desired: &DesiredResourceState) -> Result<DesiredResourceStateReceipt> {
        self.check_transition(desired)?;
        if let Some(existing) = self.read(&desired.id)?
            && existing.desired == *desired
        {
            return Ok(existing);
        }
        let receipt = DesiredResourceStateReceipt {
            schema_version: 1,
            desired: desired.clone(),
            applied_at: Timestamp::now()?,
        };
        create_private_dir(&self.root)?;
        let final_path = self.path(&desired.id);
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temporary = self
            .root
            .join(format!(".{}.{}.tmp", std::process::id(), sequence));
        let bytes = serde_json::to_vec_pretty(&receipt)?;
        let write = (|| -> Result<()> {
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(&temporary)
                .with_context(|| format!("create {}", temporary.display()))?;
            file.write_all(&bytes)?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            fs::rename(&temporary, &final_path).with_context(|| {
                format!(
                    "atomically replace desired resource receipt {}",
                    final_path.display()
                )
            })?;
            File::open(&self.root)?.sync_all()?;
            Ok(())
        })();
        if write.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        write?;
        Ok(receipt)
    }

    pub fn read(&self, resource: &str) -> Result<Option<DesiredResourceStateReceipt>> {
        let path = self.path(resource);
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error).with_context(|| format!("read {}", path.display())),
        };
        let receipt: DesiredResourceStateReceipt =
            serde_json::from_slice(&bytes).with_context(|| format!("parse {}", path.display()))?;
        if receipt.schema_version != 1 || receipt.desired.id != resource {
            bail!(
                "desired resource state receipt integrity error in {}",
                path.display()
            );
        }
        receipt.desired.validate()?;
        Ok(Some(receipt))
    }

    fn path(&self, resource: &str) -> PathBuf {
        self.root
            .join(format!("{}.json", digest_bytes(resource.as_bytes())))
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DesiredResourceStateDeferralReason {
    ActivationJobSpecificationConflict,
    ActivationFailed,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DesiredResourceStateDeferral {
    pub schema_version: u32,
    pub desired: DesiredResourceState,
    pub reason: DesiredResourceStateDeferralReason,
    pub detail: String,
    pub deferred_at: Timestamp,
}

#[derive(Clone, Debug)]
pub struct DesiredResourceStateDeferralStore {
    root: PathBuf,
}

impl DesiredResourceStateDeferralStore {
    pub fn new(state_root: impl AsRef<Path>) -> Self {
        Self {
            root: state_root.as_ref().join("desired-resource-state-deferrals"),
        }
    }

    pub fn check_transition(&self, desired: &DesiredResourceState) -> Result<()> {
        let Some(existing) = self.read(&desired.id)? else {
            return Ok(());
        };
        if existing.desired.projection_id != desired.projection_id {
            return Ok(());
        }
        if existing.desired.intent_digest != desired.intent_digest {
            bail!(
                "deferred desired resource {:?} changes immutable intent within projection {:?}",
                desired.id,
                desired.projection_id
            );
        }
        if desired.generation < existing.desired.generation {
            bail!(
                "deferred desired resource {:?} projection generation regresses from {} to {}",
                desired.id,
                existing.desired.generation,
                desired.generation
            );
        }
        if desired.generation == existing.desired.generation && desired != &existing.desired {
            bail!(
                "deferred desired resource {:?} changes projection content at generation {}",
                desired.id,
                desired.generation
            );
        }
        Ok(())
    }

    pub fn record(
        &self,
        desired: &DesiredResourceState,
        reason: DesiredResourceStateDeferralReason,
        detail: impl Into<String>,
    ) -> Result<DesiredResourceStateDeferral> {
        self.check_transition(desired)?;
        let deferral = DesiredResourceStateDeferral {
            schema_version: 1,
            desired: desired.clone(),
            reason,
            detail: detail.into(),
            deferred_at: Timestamp::now()?,
        };
        create_private_dir(&self.root)?;
        let final_path = self.path(&desired.id);
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temporary = self
            .root
            .join(format!(".{}.{}.tmp", std::process::id(), sequence));
        let bytes = serde_json::to_vec_pretty(&deferral)?;
        let write = (|| -> Result<()> {
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(&temporary)
                .with_context(|| format!("create {}", temporary.display()))?;
            file.write_all(&bytes)?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            fs::rename(&temporary, &final_path).with_context(|| {
                format!(
                    "atomically replace desired resource deferral {}",
                    final_path.display()
                )
            })?;
            File::open(&self.root)?.sync_all()?;
            Ok(())
        })();
        if write.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        write?;
        Ok(deferral)
    }

    pub fn clear(&self, resource: &str) -> Result<()> {
        let path = self.path(resource);
        match fs::remove_file(&path) {
            Ok(()) => File::open(&self.root)?.sync_all().map_err(Into::into),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error).with_context(|| format!("remove {}", path.display())),
        }
    }

    /// Remove deferral evidence that is no longer named by the authoritative
    /// desired-state manifest.
    pub fn clear_absent<'a>(
        &self,
        resources: impl IntoIterator<Item = &'a str>,
    ) -> Result<Vec<String>> {
        let resources = resources.into_iter().collect::<BTreeSet<_>>();
        let mut cleared = Vec::new();
        for deferral in self.list()? {
            let resource = &deferral.desired.id;
            if resources.contains(resource.as_str()) {
                continue;
            }
            self.clear(resource)?;
            cleared.push(resource.clone());
        }
        Ok(cleared)
    }

    pub fn read(&self, resource: &str) -> Result<Option<DesiredResourceStateDeferral>> {
        let path = self.path(resource);
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error).with_context(|| format!("read {}", path.display())),
        };
        let deferral: DesiredResourceStateDeferral =
            serde_json::from_slice(&bytes).with_context(|| format!("parse {}", path.display()))?;
        if deferral.schema_version != 1 || deferral.desired.id != resource {
            bail!(
                "desired resource state deferral integrity error in {}",
                path.display()
            );
        }
        deferral.desired.validate()?;
        Ok(Some(deferral))
    }

    pub fn list(&self) -> Result<Vec<DesiredResourceStateDeferral>> {
        let entries = match fs::read_dir(&self.root) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => {
                return Err(error).with_context(|| format!("list {}", self.root.display()));
            }
        };
        let mut deferrals = entries
            .map(|entry| entry.map(|entry| entry.path()))
            .collect::<std::io::Result<Vec<_>>>()?;
        deferrals.retain(|path| {
            path.extension()
                .is_some_and(|extension| extension == "json")
        });
        deferrals.sort();
        let mut result = Vec::with_capacity(deferrals.len());
        for path in deferrals {
            let bytes = fs::read(&path).with_context(|| format!("read {}", path.display()))?;
            let deferral: DesiredResourceStateDeferral = serde_json::from_slice(&bytes)
                .with_context(|| format!("parse {}", path.display()))?;
            if deferral.schema_version != 1 || self.path(&deferral.desired.id) != path {
                bail!(
                    "desired resource state deferral integrity error in {}",
                    path.display()
                );
            }
            deferral.desired.validate()?;
            result.push(deferral);
        }
        result.sort_by(|left, right| left.desired.id.cmp(&right.desired.id));
        Ok(result)
    }

    fn path(&self, resource: &str) -> PathBuf {
        self.root
            .join(format!("{}.json", digest_bytes(resource.as_bytes())))
    }
}

fn create_private_dir(path: &Path) -> Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true).mode(0o700);
    builder
        .create(path)
        .with_context(|| format!("create desired resource state directory {}", path.display()))
}

fn validate_identifier(label: &str, value: &str) -> Result<()> {
    if value.trim().is_empty() || value.contains('\0') {
        bail!("{label} must be non-empty and cannot contain NUL");
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

#[cfg(test)]
mod tests {
    use super::*;

    fn desired(generation: u64, state: DesiredResourceStateKind) -> DesiredResourceState {
        DesiredResourceState {
            id: "service:zulip".to_owned(),
            state,
            projection_id: "move-1".to_owned(),
            intent_digest: "a".repeat(64),
            phase: "opaque-phase".to_owned(),
            projection_digest: format!("{:064x}", generation),
            generation,
            hold_epoch: Some("target-epoch".to_owned()),
            transaction_id: Some("move-1--item-001".to_owned()),
            activation_job_id: matches!(state, DesiredResourceStateKind::Active)
                .then(|| "move-1--item-001-cutover-activate-target".to_owned()),
            activation_requirement_kind: Some("opaque-proof".to_owned()),
            activation_requirement_digest: Some("b".repeat(64)),
        }
    }

    #[test]
    fn active_held_resource_requires_activation_requirement() {
        let mut desired = desired(2, DesiredResourceStateKind::Active);
        desired.activation_requirement_kind = None;
        desired.activation_requirement_digest = None;
        assert!(desired.validate().is_err());
    }

    #[test]
    fn receipt_store_rejects_regression_and_same_generation_drift() {
        let temp = tempfile::tempdir().unwrap();
        let store = DesiredResourceStateReceiptStore::new(temp.path());
        store
            .record(&desired(2, DesiredResourceStateKind::Held))
            .unwrap();
        assert!(
            store
                .check_transition(&desired(1, DesiredResourceStateKind::Held))
                .is_err()
        );
        let mut drift = desired(2, DesiredResourceStateKind::Held);
        drift.phase = "different".to_owned();
        assert!(store.check_transition(&drift).is_err());
        store
            .record(&desired(3, DesiredResourceStateKind::Active))
            .unwrap();
    }

    #[test]
    fn receipt_write_is_idempotent_for_the_exact_projection() {
        let temp = tempfile::tempdir().unwrap();
        let store = DesiredResourceStateReceiptStore::new(temp.path());
        let desired = desired(2, DesiredResourceStateKind::Held);
        let first = store.record(&desired).unwrap();
        let second = store.record(&desired).unwrap();
        assert_eq!(first, second);
        assert_eq!(store.read(&desired.id).unwrap().unwrap().desired, desired);
    }

    #[test]
    fn deferral_store_tracks_non_success_evidence_monotonically_and_clears_it() {
        let temp = tempfile::tempdir().unwrap();
        let store = DesiredResourceStateDeferralStore::new(temp.path());
        let active = desired(2, DesiredResourceStateKind::Active);
        let recorded = store
            .record(
                &active,
                DesiredResourceStateDeferralReason::ActivationFailed,
                "readiness did not converge",
            )
            .unwrap();
        assert_eq!(store.read(&active.id).unwrap().unwrap(), recorded);
        assert_eq!(store.list().unwrap(), vec![recorded]);
        assert!(
            store
                .check_transition(&desired(1, DesiredResourceStateKind::Held))
                .is_err()
        );
        let mut drift = active.clone();
        drift.phase = "different".to_owned();
        assert!(store.check_transition(&drift).is_err());
        store.clear(&active.id).unwrap();
        assert!(store.read(&active.id).unwrap().is_none());
        assert!(store.list().unwrap().is_empty());
    }

    #[test]
    fn deferral_store_clears_resources_absent_from_authority() {
        let temp = tempfile::tempdir().unwrap();
        let store = DesiredResourceStateDeferralStore::new(temp.path());
        let active = desired(2, DesiredResourceStateKind::Active);
        store
            .record(
                &active,
                DesiredResourceStateDeferralReason::ActivationFailed,
                "readiness did not converge",
            )
            .unwrap();

        assert!(store.clear_absent([active.id.as_str()]).unwrap().is_empty());
        assert!(store.read(&active.id).unwrap().is_some());
        assert_eq!(store.clear_absent([]).unwrap(), [active.id.clone()]);
        assert!(store.read(&active.id).unwrap().is_none());
    }
}
