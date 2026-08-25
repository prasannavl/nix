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
    pub(crate) fn now() -> Result<Self> {
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
    /// Immutable projection lineage when this hold is owned by the shared
    /// phase-projection protocol. Legacy runtime-only holds leave this empty.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub projection: Option<ActivationReleaseEvidence>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub projection: Option<ActivationReleaseEvidence>,
    pub released_at: Timestamp,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ActivationReleaseEvidence {
    pub intent_digest: String,
    pub projection_digest: String,
    pub generation: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub activation_requirement_digest: Option<String>,
}

impl ActivationReleaseEvidence {
    fn validate(&self) -> Result<()> {
        validate_sha256("release intent digest", &self.intent_digest)?;
        validate_sha256("release projection digest", &self.projection_digest)?;
        if self.generation == 0 {
            bail!("release projection generation must be greater than zero");
        }
        if let Some(digest) = &self.activation_requirement_digest {
            validate_sha256("release activation requirement digest", digest)?;
        }
        Ok(())
    }
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

    /// Stable per-resource start capability. Its content remains bound to the
    /// exact projection evidence, while the stable path lets an already
    /// deployed unit admit an authorized runtime activation without requiring
    /// a new Nix generation first. Acquiring a new hold clears it.
    pub fn activation_authorization_path(&self, resource: &str) -> PathBuf {
        self.root
            .join("activation-authorizations")
            .join(format!("{}.json", digest_bytes(resource.as_bytes())))
    }

    pub fn declaration_release(
        &self,
        resource: &str,
        declaration_id: &str,
    ) -> Result<Option<DeclarationRelease>> {
        validate_identifier("resource", resource)?;
        validate_identifier("declaration ID", declaration_id)?;
        self.with_lock(|| self.read_declaration_release_unlocked(resource, declaration_id))
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
                    if existing.projection.is_some() {
                        bail!(
                            "resource {resource:?} is projection-owned; use an exact projected hold operation"
                        );
                    }
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
                        projection: None,
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
                    if existing.projection.is_some() {
                        bail!(
                            "resource {resource:?} is projection-owned; use an exact projected hold operation"
                        );
                    }
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
                        projection: None,
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

    /// Acquire a transaction-owned hold and bind it to one declarative epoch
    /// without an unheld or unenforced intermediate state.
    pub fn acquire_declared_and_apply<F>(
        &self,
        resource: &str,
        transaction_id: &str,
        declaration_id: &str,
        services: Vec<ServiceTarget>,
        apply: F,
    ) -> Result<AcquireOutcome>
    where
        F: FnOnce(&HoldRecord) -> Result<()>,
    {
        self.acquire_declared_with_projection_and_apply(
            resource,
            transaction_id,
            declaration_id,
            services,
            None,
            apply,
        )
    }

    /// Acquire the exact hold represented by one immutable projection. The
    /// retained lineage prevents legacy runtime commands from consuming a
    /// projection-owned capability and permits only monotonic phase updates.
    pub fn acquire_projected_and_apply<F>(
        &self,
        resource: &str,
        projection_id: &str,
        declaration_id: &str,
        services: Vec<ServiceTarget>,
        evidence: ActivationReleaseEvidence,
        apply: F,
    ) -> Result<AcquireOutcome>
    where
        F: FnOnce(&HoldRecord) -> Result<()>,
    {
        evidence.validate()?;
        self.acquire_declared_with_projection_and_apply(
            resource,
            projection_id,
            declaration_id,
            services,
            Some(evidence),
            apply,
        )
    }

    fn acquire_declared_with_projection_and_apply<F>(
        &self,
        resource: &str,
        transaction_id: &str,
        declaration_id: &str,
        services: Vec<ServiceTarget>,
        projection: Option<ActivationReleaseEvidence>,
        apply: F,
    ) -> Result<AcquireOutcome>
    where
        F: FnOnce(&HoldRecord) -> Result<()>,
    {
        validate_identifier("resource", resource)?;
        validate_identifier("transaction ID", transaction_id)?;
        validate_identifier("declaration ID", declaration_id)?;
        reject_duplicate_services(&services)?;

        self.with_lock(|| {
            if self
                .declaration_release_path(resource, declaration_id)
                .try_exists()
                .with_context(|| format!("inspect declaration release for {resource:?}"))?
            {
                bail!(
                    "declaration {declaration_id:?} for resource {resource:?} was already released"
                );
            }
            let existing = self.read_hold_unlocked(resource)?;
            let (changed, hold) = match existing {
                Some(mut existing) => {
                    let mut changed = false;
                    match (&existing.projection, &projection) {
                        (Some(existing), Some(requested)) => {
                            validate_projection_successor(existing, requested)?;
                        }
                        (Some(_), None) => bail!(
                            "resource {resource:?} is projection-owned; use an exact projected hold operation"
                        ),
                        _ => {}
                    }
                    let existing_declaration_id = existing.declaration_id.clone();
                    let declaration_owned = existing_declaration_id.as_deref().is_some_and(|id| {
                        existing.transaction_id == declaration_owner(id)
                    });

                    match existing_declaration_id.as_deref() {
                        Some(existing_id) if existing_id != declaration_id => {
                            if !declaration_owned {
                                bail!(
                                    "resource {resource:?} is associated with declaration {existing_id:?}, not {declaration_id:?}, and is no longer declaration-owned"
                                );
                            }
                            if self
                                .read_declaration_release_unlocked(resource, existing_id)?
                                .is_some()
                            {
                                bail!(
                                    "refusing to replace released declaration {existing_id:?} for resource {resource:?}"
                                );
                            }

                            // Rebind the legacy declarative latch to the projection epoch in
                            // one durable hold replacement. The resource is never unheld, and
                            // all validation below completes before this record is written.
                            existing.transaction_id = transaction_id.to_owned();
                            existing.declaration_id = Some(declaration_id.to_owned());
                            changed = true;
                        }
                        Some(_) => {
                            if existing.transaction_id != transaction_id {
                                if !declaration_owned {
                                    bail!(
                                        "resource {resource:?} is held by transaction {:?}, not {:?}",
                                        existing.transaction_id,
                                        transaction_id
                                    );
                                }
                                existing.transaction_id = transaction_id.to_owned();
                                changed = true;
                            }
                        }
                        None => {
                            if existing.transaction_id != transaction_id {
                                bail!(
                                    "resource {resource:?} is held by transaction {:?}, not {:?}",
                                    existing.transaction_id,
                                    transaction_id
                                );
                            }
                            existing.declaration_id = Some(declaration_id.to_owned());
                            changed = true;
                        }
                    }
                    if existing.services != services {
                        if services.is_empty() {
                            // A reservation must not erase targets learned after deploy.
                        } else if existing.services.is_empty() {
                            existing.services = services;
                            changed = true;
                        } else {
                            bail!(
                                "resource {resource:?} already has different service targets for transaction {transaction_id:?}"
                            );
                        }
                    }
                    if existing.projection != projection {
                        existing.projection = projection;
                        changed = true;
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
                        declaration_id: Some(declaration_id.to_owned()),
                        services,
                        instance_gate: None,
                        projection,
                        acquired_at: Timestamp::now()?,
                    };
                    self.write_hold_unlocked(&hold)?;
                    (true, hold)
                }
            };
            apply(&hold)?;
            Ok(AcquireOutcome { changed, hold })
        })
    }

    /// Activate only the exact projection-owned hold epoch and persist its
    /// release marker as the cold-start authority.
    pub fn activate_declared_and_apply<T, F>(
        &self,
        resource: &str,
        transaction_id: &str,
        declaration_id: &str,
        services: &[ServiceTarget],
        apply: F,
    ) -> Result<(ReleaseOutcome, T)>
    where
        F: FnOnce() -> Result<T>,
    {
        self.activate_declared_with_evidence(
            resource,
            transaction_id,
            declaration_id,
            services,
            None,
            apply,
        )
    }

    pub fn activate_projected_and_apply<T, F>(
        &self,
        resource: &str,
        projection_id: &str,
        declaration_id: &str,
        services: &[ServiceTarget],
        evidence: ActivationReleaseEvidence,
        apply: F,
    ) -> Result<(ReleaseOutcome, T)>
    where
        F: FnOnce() -> Result<T>,
    {
        evidence.validate()?;
        self.activate_declared_with_evidence(
            resource,
            projection_id,
            declaration_id,
            services,
            Some(evidence),
            apply,
        )
    }

    fn activate_declared_with_evidence<T, F>(
        &self,
        resource: &str,
        transaction_id: &str,
        declaration_id: &str,
        services: &[ServiceTarget],
        evidence: Option<ActivationReleaseEvidence>,
        apply: F,
    ) -> Result<(ReleaseOutcome, T)>
    where
        F: FnOnce() -> Result<T>,
    {
        validate_identifier("resource", resource)?;
        validate_identifier("transaction ID", transaction_id)?;
        validate_identifier("declaration ID", declaration_id)?;
        reject_duplicate_services(services)?;

        self.with_lock(|| {
            let Some(hold) = self.read_hold_unlocked(resource)? else {
                let release = self
                    .read_declaration_release_unlocked(resource, declaration_id)?
                    .with_context(|| {
                        format!(
                            "resource {resource:?} has neither its exact hold nor release evidence"
                        )
                    })?;
                if release.transaction_id != transaction_id || release.projection != evidence {
                    bail!(
                        "resource {resource:?} release does not match the exact activation job"
                    );
                }
                if let Some(evidence) = &evidence {
                    self.write_activation_authorization_unlocked(resource, evidence)?;
                }
                let result = match apply() {
                    Ok(result) => result,
                    Err(error) => {
                        if evidence.is_some() {
                            self.remove_activation_authorization_unlocked(resource)?;
                        }
                        return Err(error);
                    }
                };
                return Ok((
                    ReleaseOutcome {
                        changed: false,
                        resource: resource.to_owned(),
                        transaction_id: transaction_id.to_owned(),
                        held: false,
                        services_started: true,
                    },
                    result,
                ));
            };
            if hold.transaction_id != transaction_id {
                bail!(
                    "refusing to activate resource {resource:?}: held by transaction {:?}, not {:?}",
                    hold.transaction_id,
                    transaction_id
                );
            }
            if hold.declaration_id.as_deref() != Some(declaration_id) {
                bail!(
                    "resource {resource:?} is associated with declaration {:?}, not {declaration_id:?}",
                    hold.declaration_id
                );
            }
            if hold.services != services {
                bail!(
                    "resource {resource:?} has different service targets for transaction {transaction_id:?}"
                );
            }
            match (&hold.projection, &evidence) {
                (Some(held), Some(requested)) => {
                    validate_projection_successor(held, requested)?;
                }
                (Some(_), None) => bail!(
                    "resource {resource:?} is projection-owned; use an exact projected activation"
                ),
                (None, Some(_)) => bail!(
                    "resource {resource:?} is not bound to the requested projection activation"
                ),
                (None, None) => {}
            }

            self.write_declaration_release_unlocked(
                resource,
                declaration_id,
                transaction_id,
                evidence.clone(),
            )?;
            if let Some(evidence) = &evidence {
                self.write_activation_authorization_unlocked(resource, evidence)?;
            }
            // A host aggregate is also the regular, global safety condition on
            // each child unit. Systemd cannot express `(resource unheld OR
            // resource authorized) AND (host unheld OR host authorized)` with
            // trigger conditions. Release the exact host hold after persisting
            // its capability, before starting children, and restore it if the
            // start attempt fails. Service/resource holds keep their narrower
            // authorization-gated start-before-release behavior.
            let release_before_apply = resource.starts_with("host:");
            if release_before_apply {
                fs::remove_file(self.hold_path(resource))
                    .with_context(|| format!("release host hold for {resource:?}"))?;
                sync_directory(&self.holds_dir())?;
            }
            let result = match apply() {
                Ok(result) => result,
                Err(error) => {
                    if release_before_apply {
                        self.write_hold_unlocked(&hold)?;
                    }
                    if evidence.is_some() {
                        self.remove_activation_authorization_unlocked(resource)?;
                    }
                    self.remove_declaration_release_unlocked(resource, declaration_id)?;
                    return Err(error);
                }
            };
            if !release_before_apply {
                fs::remove_file(self.hold_path(resource))
                    .with_context(|| format!("release hold for {resource:?}"))?;
                sync_directory(&self.holds_dir())?;
            }
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
                if hold.projection.is_some() {
                    bail!(
                        "resource {resource:?} is projection-owned; use an exact projected activation"
                    );
                }
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
                        None,
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
            if hold.projection.is_some() {
                bail!(
                    "resource {resource:?} is projection-owned; use an exact projected activation"
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
                    None,
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
            if hold.projection.is_some() {
                bail!("resource {resource:?} is projection-owned; use an exact projected release");
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

    /// Release one exact projection-owned hold epoch without activating the
    /// resource. The retained evidence makes the operation idempotent across
    /// agent and deploy reconciliation and prevents a stale unhold projection
    /// from releasing a later hold epoch.
    pub fn release_projected(
        &self,
        resource: &str,
        projection_id: &str,
        declaration_id: &str,
        evidence: ActivationReleaseEvidence,
    ) -> Result<ReleaseOutcome> {
        validate_identifier("resource", resource)?;
        validate_identifier("projection ID", projection_id)?;
        validate_identifier("declaration ID", declaration_id)?;
        evidence.validate()?;

        self.with_lock(|| {
            let Some(hold) = self.read_hold_unlocked(resource)? else {
                let release = self
                    .read_declaration_release_unlocked(resource, declaration_id)?
                    .with_context(|| {
                        format!(
                            "resource {resource:?} has neither its exact hold nor release evidence"
                        )
                    })?;
                if release.transaction_id != projection_id
                    || release.projection.as_ref() != Some(&evidence)
                {
                    bail!(
                        "resource {resource:?} release does not match the exact unhold projection"
                    );
                }
                return Ok(ReleaseOutcome {
                    changed: false,
                    resource: resource.to_owned(),
                    transaction_id: projection_id.to_owned(),
                    held: false,
                    services_started: false,
                });
            };
            if hold.transaction_id != projection_id {
                bail!(
                    "refusing to release resource {resource:?}: held by transaction {:?}, not {:?}",
                    hold.transaction_id,
                    projection_id
                );
            }
            if hold.declaration_id.as_deref() != Some(declaration_id) {
                bail!(
                    "resource {resource:?} is associated with declaration {:?}, not {declaration_id:?}",
                    hold.declaration_id
                );
            }
            let held_projection = hold.projection.as_ref().with_context(|| {
                format!("resource {resource:?} is not bound to a projection hold")
            })?;
            validate_projection_successor(held_projection, &evidence)?;
            self.write_declaration_release_unlocked(
                resource,
                declaration_id,
                projection_id,
                Some(evidence),
            )?;
            fs::remove_file(self.hold_path(resource))
                .with_context(|| format!("release hold for {resource:?}"))?;
            sync_directory(&self.holds_dir())?;
            Ok(ReleaseOutcome {
                changed: true,
                resource: resource.to_owned(),
                transaction_id: projection_id.to_owned(),
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
        if let Some(projection) = &hold.projection {
            projection.validate()?;
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
            if let Some(projection) = &hold.projection {
                projection.validate()?;
            }
            holds.push(hold);
        }
        holds.sort_by(|left, right| left.resource.cmp(&right.resource));
        Ok(holds)
    }

    fn write_hold_unlocked(&self, hold: &HoldRecord) -> Result<()> {
        // A capability authorizes only the hold epoch it released. Clear it
        // before persisting a new or refreshed hold so it cannot bypass a
        // later transaction.
        self.remove_activation_authorization_unlocked(&hold.resource)?;
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
        projection: Option<ActivationReleaseEvidence>,
    ) -> Result<()> {
        let final_path = self.declaration_release_path(resource, declaration_id);
        if let Some(release) = self.read_declaration_release_unlocked(resource, declaration_id)? {
            if release.transaction_id != transaction_id || release.projection != projection {
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
            projection,
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

    fn read_declaration_release_unlocked(
        &self,
        resource: &str,
        declaration_id: &str,
    ) -> Result<Option<DeclarationRelease>> {
        let path = self.declaration_release_path(resource, declaration_id);
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error).with_context(|| format!("read {}", path.display())),
        };
        let release: DeclarationRelease =
            serde_json::from_slice(&bytes).with_context(|| format!("parse {}", path.display()))?;
        if release.schema_version != 1
            || release.resource != resource
            || release.declaration_id != declaration_id
        {
            bail!(
                "declaration release state integrity error in {}",
                path.display()
            );
        }
        Ok(Some(release))
    }

    fn write_activation_authorization_unlocked(
        &self,
        resource: &str,
        evidence: &ActivationReleaseEvidence,
    ) -> Result<()> {
        evidence.validate()?;
        let final_path = self.activation_authorization_path(resource);
        let directory = final_path
            .parent()
            .context("activation authorization path has no parent")?;
        create_private_dir(directory)?;
        let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp_path = directory.join(format!(".{}.{}.tmp", std::process::id(), sequence));
        let mut bytes = serde_json::to_vec_pretty(evidence)?;
        bytes.push(b'\n');
        let write_result = (|| -> Result<()> {
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(&temp_path)
                .with_context(|| format!("create {}", temp_path.display()))?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            fs::rename(&temp_path, &final_path)?;
            sync_directory(directory)
        })();
        if write_result.is_err() {
            let _ = fs::remove_file(&temp_path);
        }
        write_result
    }

    fn remove_activation_authorization_unlocked(&self, resource: &str) -> Result<()> {
        let path = self.activation_authorization_path(resource);
        match fs::remove_file(&path) {
            Ok(()) => sync_directory(
                path.parent()
                    .context("activation authorization path has no parent")?,
            ),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error).with_context(|| format!("remove {}", path.display())),
        }
    }

    fn remove_declaration_release_unlocked(
        &self,
        resource: &str,
        declaration_id: &str,
    ) -> Result<()> {
        let path = self.declaration_release_path(resource, declaration_id);
        match fs::remove_file(&path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => {
                return Err(error).with_context(|| format!("remove {}", path.display()));
            }
        }
        sync_directory(
            path.parent()
                .context("declaration release path has no parent")?,
        )
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

fn validate_sha256(label: &str, value: &str) -> Result<()> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
    {
        bail!("{label} must be a lowercase SHA-256 digest");
    }
    Ok(())
}

fn validate_projection_successor(
    existing: &ActivationReleaseEvidence,
    requested: &ActivationReleaseEvidence,
) -> Result<()> {
    if existing.intent_digest != requested.intent_digest {
        bail!("projection hold intent digest changed across one hold epoch");
    }
    if requested.generation < existing.generation {
        bail!(
            "projection hold generation regressed from {} to {}",
            existing.generation,
            requested.generation
        );
    }
    if requested.generation == existing.generation && requested != existing {
        bail!(
            "projection hold evidence drifted within generation {}",
            requested.generation
        );
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
    fn legacy_bootstrap_latch_hands_off_atomically_to_projection_epoch() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let resource = "service:zulip";
        let bootstrap = "zulip-target-bootstrap-v1";
        let projection = "move-1:target:seeded";
        let services = vec![ServiceTarget::system("zulip.service")];

        store
            .declare_and_apply(resource, bootstrap, services.clone(), |_| Ok(()))
            .unwrap();
        let bootstrap_hold = store.status(resource).unwrap().hold.unwrap();
        assert_eq!(bootstrap_hold.transaction_id, declaration_owner(bootstrap));
        assert_eq!(bootstrap_hold.declaration_id.as_deref(), Some(bootstrap));

        let handed_off = store
            .acquire_declared_and_apply(
                resource,
                "move-1",
                projection,
                services.clone(),
                |enforced| {
                    let durable = store.read_hold_unlocked(resource)?.unwrap();
                    assert_eq!(durable, *enforced);
                    assert_eq!(durable.transaction_id, "move-1");
                    assert_eq!(durable.declaration_id.as_deref(), Some(projection));
                    assert_eq!(durable.services, services);
                    Ok(())
                },
            )
            .unwrap();

        assert!(handed_off.changed);
        assert_eq!(handed_off.hold.transaction_id, "move-1");
        assert_eq!(handed_off.hold.declaration_id.as_deref(), Some(projection));
        assert!(store.status(resource).unwrap().held);
        assert!(
            store
                .declaration_release(resource, bootstrap)
                .unwrap()
                .is_none()
        );
        assert!(
            store
                .declaration_release(resource, projection)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn old_bootstrap_marker_replay_cannot_reclaim_projection_hold_after_reboot() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let resource = "service:zulip";
        let bootstrap = "zulip-target-bootstrap-v1";
        let projection = "move-1:target:seeded";
        let services = vec![ServiceTarget::system("zulip.service")];

        store
            .declare_and_apply(resource, bootstrap, services.clone(), |_| Ok(()))
            .unwrap();
        store
            .acquire_declared_and_apply(
                resource,
                "move-1",
                projection,
                services.clone(),
                |_| Ok(()),
            )
            .unwrap();

        drop(store);
        let rebooted = StateStore::new(temp.path());
        let error = rebooted
            .declare_and_apply(resource, bootstrap, services, |_| {
                bail!("stale bootstrap marker must never be enforced")
            })
            .unwrap_err();
        assert!(error.to_string().contains("associated with declaration"));
        let hold = rebooted.status(resource).unwrap().hold.unwrap();
        assert_eq!(hold.transaction_id, "move-1");
        assert_eq!(hold.declaration_id.as_deref(), Some(projection));
        assert!(
            rebooted
                .declaration_release(resource, bootstrap)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn released_bootstrap_declaration_cannot_hand_off_its_remaining_hold() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let resource = "service:zulip";
        let bootstrap = "zulip-target-bootstrap-v1";
        let services = vec![ServiceTarget::system("zulip.service")];

        store
            .declare_and_apply(resource, bootstrap, services.clone(), |_| Ok(()))
            .unwrap();
        store
            .with_lock(|| {
                store.write_declaration_release_unlocked(
                    resource,
                    bootstrap,
                    &declaration_owner(bootstrap),
                    None,
                )
            })
            .unwrap();

        let error = store
            .acquire_declared_and_apply(
                resource,
                "move-1",
                "move-1:target:seeded",
                services,
                |_| Ok(()),
            )
            .unwrap_err();
        assert!(error.to_string().contains("refusing to replace released"));
        let hold = store.status(resource).unwrap().hold.unwrap();
        assert_eq!(hold.transaction_id, declaration_owner(bootstrap));
        assert_eq!(hold.declaration_id.as_deref(), Some(bootstrap));
    }

    #[test]
    fn transaction_owned_projection_declaration_cannot_be_replaced() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let resource = "service:zulip";
        let services = vec![ServiceTarget::system("zulip.service")];
        let first = "move-1:target:seeded";

        store
            .acquire_declared_and_apply(resource, "move-1", first, services.clone(), |_| Ok(()))
            .unwrap();
        let error = store
            .acquire_declared_and_apply(
                resource,
                "move-1",
                "move-1:target:prepared",
                services,
                |_| Ok(()),
            )
            .unwrap_err();

        assert!(error.to_string().contains("no longer declaration-owned"));
        let hold = store.status(resource).unwrap().hold.unwrap();
        assert_eq!(hold.transaction_id, "move-1");
        assert_eq!(hold.declaration_id.as_deref(), Some(first));
    }

    #[test]
    fn projection_hold_activation_persists_the_exact_epoch_release() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let services = vec![ServiceTarget::system("zulip.service")];
        let declaration = "tx-1:target:g3";
        let evidence = ActivationReleaseEvidence {
            intent_digest: "a".repeat(64),
            projection_digest: "b".repeat(64),
            generation: 3,
            activation_requirement_digest: Some("c".repeat(64)),
        };
        store
            .acquire_projected_and_apply(
                "service:zulip",
                "tx-1",
                declaration,
                services.clone(),
                evidence.clone(),
                |_| Ok(()),
            )
            .unwrap();

        assert!(
            store
                .activate_declared_and_apply(
                    "service:zulip",
                    "tx-1",
                    "tx-1:target:g2",
                    &services,
                    || Ok(())
                )
                .is_err()
        );
        store
            .activate_projected_and_apply(
                "service:zulip",
                "tx-1",
                declaration,
                &services,
                evidence.clone(),
                || Ok(()),
            )
            .unwrap();
        assert!(
            store
                .declaration_release_path("service:zulip", declaration)
                .exists()
        );
        assert!(
            store
                .activation_authorization_path("service:zulip")
                .exists()
        );
        assert!(!store.status("service:zulip").unwrap().held);
        store
            .acquire_declared_and_apply("service:zulip", "tx-1", "tx-1:target:g4", services, |_| {
                Ok(())
            })
            .unwrap();
        assert!(
            !store
                .activation_authorization_path("service:zulip")
                .exists()
        );
    }

    #[test]
    fn legacy_commands_cannot_consume_a_projection_owned_hold() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let resource = "service:zulip";
        let projection = "move-zulip";
        let declaration = "move-zulip:target:g1";
        let services = vec![ServiceTarget::system("zulip.service")];
        let evidence = ActivationReleaseEvidence {
            intent_digest: "a".repeat(64),
            projection_digest: "b".repeat(64),
            generation: 1,
            activation_requirement_digest: None,
        };
        store
            .acquire_projected_and_apply(
                resource,
                projection,
                declaration,
                services.clone(),
                evidence,
                |_| Ok(()),
            )
            .unwrap();

        assert!(store.release(resource, projection).is_err());
        assert!(
            store
                .activate_and_apply(resource, projection, &services, || Ok(()))
                .is_err()
        );
        assert!(
            store
                .activate_after_apply(resource, projection, &services, || Ok(()))
                .is_err()
        );
        assert!(
            store
                .acquire_and_apply(resource, projection, services, |_| Ok(()))
                .is_err()
        );
        assert!(store.status(resource).unwrap().held);
    }

    #[test]
    fn projection_unhold_releases_only_the_exact_epoch_without_activation() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let resource = "service:zulip";
        let projection = "hold-zulip";
        let declaration = "hold-zulip:hold-v1";
        let services = vec![ServiceTarget::system("zulip.service")];
        let evidence = ActivationReleaseEvidence {
            intent_digest: "a".repeat(64),
            projection_digest: "b".repeat(64),
            generation: 2,
            activation_requirement_digest: None,
        };
        let held_evidence = ActivationReleaseEvidence {
            intent_digest: evidence.intent_digest.clone(),
            projection_digest: "d".repeat(64),
            generation: 1,
            activation_requirement_digest: None,
        };
        store
            .acquire_projected_and_apply(
                resource,
                projection,
                declaration,
                services.clone(),
                held_evidence,
                |_| Ok(()),
            )
            .unwrap();

        let released = store
            .release_projected(resource, projection, declaration, evidence.clone())
            .unwrap();
        assert!(released.changed);
        assert!(!released.services_started);
        assert!(!store.status(resource).unwrap().held);
        assert_eq!(
            store
                .declaration_release(resource, declaration)
                .unwrap()
                .unwrap()
                .projection,
            Some(evidence.clone())
        );
        assert!(
            !store
                .activation_authorization_path(resource)
                .try_exists()
                .unwrap()
        );

        assert!(
            !store
                .release_projected(resource, projection, declaration, evidence.clone())
                .unwrap()
                .changed
        );
        assert!(
            store
                .release_projected(
                    resource,
                    projection,
                    declaration,
                    ActivationReleaseEvidence {
                        intent_digest: "a".repeat(64),
                        projection_digest: "c".repeat(64),
                        generation: 3,
                        activation_requirement_digest: None,
                    },
                )
                .is_err()
        );
        let next_declaration = "hold-zulip:hold-v3";
        store
            .acquire_declared_and_apply(
                resource,
                projection,
                next_declaration,
                services,
                |_| Ok(()),
            )
            .unwrap();
        assert!(
            store
                .release_projected(resource, projection, declaration, evidence)
                .is_err()
        );
        assert_eq!(
            store
                .status(resource)
                .unwrap()
                .hold
                .unwrap()
                .declaration_id
                .as_deref(),
            Some(next_declaration)
        );
    }

    #[test]
    fn projected_host_activation_releases_global_gate_before_start_and_restores_on_failure() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let resource = "host:target";
        let transaction = "move-host";
        let declaration = "move-host:cutover";
        let services = vec![ServiceTarget::system("target.service")];
        let evidence = ActivationReleaseEvidence {
            intent_digest: "a".repeat(64),
            projection_digest: "b".repeat(64),
            generation: 3,
            activation_requirement_digest: Some("c".repeat(64)),
        };
        store
            .acquire_projected_and_apply(
                resource,
                transaction,
                declaration,
                services.clone(),
                evidence.clone(),
                |_| Ok(()),
            )
            .unwrap();

        let failed = store.activate_projected_and_apply(
            resource,
            transaction,
            declaration,
            &services,
            evidence.clone(),
            || -> Result<()> {
                assert!(!store.hold_path(resource).exists());
                anyhow::bail!("injected host start failure")
            },
        );
        assert!(failed.is_err());
        assert!(store.status(resource).unwrap().held);

        store
            .activate_projected_and_apply(
                resource,
                transaction,
                declaration,
                &services,
                evidence,
                || {
                    assert!(!store.hold_path(resource).exists());
                    Ok(())
                },
            )
            .unwrap();
        assert!(!store.status(resource).unwrap().held);
    }

    #[test]
    fn rollback_epoch_reacquires_despite_the_prior_cutover_release() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let services = vec![ServiceTarget::system("zulip.service")];
        let cutover = "tx-1:target:g3";
        let rollback = "tx-1:source:g4";
        store
            .acquire_declared_and_apply("service:zulip", "tx-1", cutover, services.clone(), |_| {
                Ok(())
            })
            .unwrap();
        store
            .activate_declared_and_apply("service:zulip", "tx-1", cutover, &services, || Ok(()))
            .unwrap();

        let reacquired = store
            .acquire_declared_and_apply("service:zulip", "tx-1", rollback, services, |_| Ok(()))
            .unwrap();
        assert_eq!(reacquired.hold.declaration_id.as_deref(), Some(rollback));
        assert!(
            store
                .declaration_release_path("service:zulip", cutover)
                .exists()
        );
        assert!(
            !store
                .declaration_release_path("service:zulip", rollback)
                .exists()
        );
    }

    #[test]
    fn failed_projection_activation_removes_release_and_retains_hold() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::new(temp.path());
        let services = vec![ServiceTarget::system("zulip.service")];
        let declaration = "tx-1:target:g3";
        let evidence = ActivationReleaseEvidence {
            intent_digest: "a".repeat(64),
            projection_digest: "b".repeat(64),
            generation: 3,
            activation_requirement_digest: Some("c".repeat(64)),
        };
        store
            .acquire_projected_and_apply(
                "service:zulip",
                "tx-1",
                declaration,
                services.clone(),
                evidence.clone(),
                |_| Ok(()),
            )
            .unwrap();

        assert!(
            store
                .activate_projected_and_apply(
                    "service:zulip",
                    "tx-1",
                    declaration,
                    &services,
                    evidence.clone(),
                    || -> Result<()> { bail!("injected start failure") }
                )
                .is_err()
        );
        assert!(store.status("service:zulip").unwrap().held);
        assert!(
            !store
                .declaration_release_path("service:zulip", declaration)
                .exists()
        );
        assert!(
            !store
                .activation_authorization_path("service:zulip")
                .exists()
        );
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
