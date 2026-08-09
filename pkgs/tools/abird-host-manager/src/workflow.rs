use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use abird_host_agent::instance::{
    IncusCopyMode, InstanceMigrationPolicy, RuntimeStateMode, SeedConsistency,
};
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const TRANSACTION_SPEC_SCHEMA_VERSION: u32 = 1;
pub const BACKUP_SPEC_SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(deny_unknown_fields)]
pub struct InstanceEndpoint {
    pub controller: String,
    #[serde(default = "default_incus_remote")]
    pub remote: String,
    #[serde(default = "default_incus_project")]
    pub project: String,
    pub instance: String,
}

impl InstanceEndpoint {
    pub fn validate(&self) -> Result<()> {
        validate_name("Incus controller", &self.controller)?;
        validate_incus_name("Incus remote", &self.remote)?;
        validate_incus_name("Incus project", &self.project)?;
        validate_incus_name("Incus instance", &self.instance)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostEndpoint {
    pub host: String,
    /// The infrastructure instance containing this inventory host, when known.
    /// This makes whole-instance and in-instance resource ownership comparable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub instance: Option<InstanceEndpoint>,
}

impl HostEndpoint {
    pub fn validate(&self) -> Result<()> {
        validate_name("inventory host", &self.host)?;
        if let Some(instance) = &self.instance {
            instance.validate()?;
        }
        Ok(())
    }

    pub fn authority_container(&self) -> AuthorityContainer {
        self.instance.clone().map_or_else(
            || AuthorityContainer::Host {
                host: self.host.clone(),
            },
            |endpoint| AuthorityContainer::Instance { endpoint },
        )
    }
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum AuthorityContainer {
    Host { host: String },
    Instance { endpoint: InstanceEndpoint },
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum AuthoritySubject {
    Whole,
    Service { name: String },
    Resource { id: String },
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AuthorityKey {
    pub container: AuthorityContainer,
    pub subject: AuthoritySubject,
}

impl AuthorityKey {
    pub fn overlaps(&self, other: &Self) -> bool {
        self.container == other.container
            && (self.subject == AuthoritySubject::Whole
                || other.subject == AuthoritySubject::Whole
                || self.subject == other.subject)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DataRootMapping {
    pub name: String,
    pub source: PathBuf,
    pub target: PathBuf,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub excludes: Vec<PathBuf>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct InstanceMovePolicy {
    /// Inventory host whose durable agent executes every Incus operation.
    /// Both endpoint remote names are interpreted in this controller's Incus
    /// client configuration.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub executor_controller: Option<String>,
    #[serde(default = "default_incus_program")]
    pub program: PathBuf,
    #[serde(default)]
    pub copy_mode: IncusCopyMode,
    /// Permit the first seed to adopt an existing target whose ownership
    /// markers do not identify this source. False by default.
    #[serde(default)]
    pub adopt_existing_target: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_storage_pool: Option<String>,
    /// Required for rollback when the forward target uses a different pool.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rollback_storage_pool: Option<String>,
    #[serde(default = "default_instance_stop_timeout_seconds")]
    pub stop_timeout_seconds: u64,
    #[serde(default)]
    pub force_after_timeout: bool,
    #[serde(default)]
    pub seed_consistency: SeedConsistency,
    #[serde(default)]
    pub runtime_state: RuntimeStateMode,
}

impl Default for InstanceMovePolicy {
    fn default() -> Self {
        Self {
            executor_controller: None,
            program: default_incus_program(),
            copy_mode: IncusCopyMode::Pull,
            adopt_existing_target: false,
            target_storage_pool: None,
            rollback_storage_pool: None,
            stop_timeout_seconds: default_instance_stop_timeout_seconds(),
            force_after_timeout: false,
            seed_consistency: SeedConsistency::AllowInconsistent,
            runtime_state: RuntimeStateMode::Discard,
        }
    }
}

impl InstanceMovePolicy {
    pub fn executor<'a>(&'a self, source: &'a InstanceEndpoint) -> &'a str {
        self.executor_controller
            .as_deref()
            .unwrap_or(&source.controller)
    }

    pub fn migration_policy(&self, reverse: bool) -> InstanceMigrationPolicy {
        InstanceMigrationPolicy {
            copy_mode: self.copy_mode,
            target_storage_pool: if reverse {
                self.rollback_storage_pool.clone()
            } else {
                self.target_storage_pool.clone()
            },
            stop_timeout_seconds: self.stop_timeout_seconds,
            force_after_timeout: self.force_after_timeout,
            seed_consistency: self.seed_consistency,
            runtime_state: self.runtime_state,
        }
    }

    fn validate(&self, source: &InstanceEndpoint) -> Result<()> {
        if let Some(executor) = &self.executor_controller {
            validate_name("Incus executor controller", executor)?;
        }
        if !self.program.is_absolute()
            || self.program.file_name().and_then(|name| name.to_str()) != Some("incus")
        {
            bail!("instance move program must be an absolute incus executable");
        }
        for (label, pool) in [
            ("target storage pool", &self.target_storage_pool),
            ("rollback storage pool", &self.rollback_storage_pool),
        ] {
            if let Some(pool) = pool {
                validate_incus_name(label, pool)?;
            }
        }
        if self.target_storage_pool.is_some() && self.rollback_storage_pool.is_none() {
            bail!(
                "instance moves with an explicit target storage pool require rollback_storage_pool"
            );
        }
        if !(1..=86_400).contains(&self.stop_timeout_seconds) {
            bail!("instance stop timeout must be between 1 and 86400 seconds");
        }
        if self.runtime_state == RuntimeStateMode::Preserve {
            bail!(
                "orchestrated instance moves require discarded runtime state so prepare can stop and verify both endpoints before final copy"
            );
        }
        validate_name("Incus executor controller", self.executor(source))
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct InstanceBackupPolicy {
    /// Inventory host whose durable agent executes Incus and owns staging.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub executor_controller: Option<String>,
    #[serde(default = "default_incus_program")]
    pub program: PathBuf,
    #[serde(default = "default_instance_stop_timeout_seconds")]
    pub stop_timeout_seconds: u64,
    #[serde(default)]
    pub force_after_timeout: bool,
    #[serde(default = "default_true")]
    pub include_snapshots: bool,
    #[serde(default)]
    pub optimized_storage: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restore_storage_pool: Option<String>,
}

impl Default for InstanceBackupPolicy {
    fn default() -> Self {
        Self {
            executor_controller: None,
            program: default_incus_program(),
            stop_timeout_seconds: default_instance_stop_timeout_seconds(),
            force_after_timeout: false,
            include_snapshots: true,
            optimized_storage: false,
            restore_storage_pool: None,
        }
    }
}

impl InstanceBackupPolicy {
    pub fn executor<'a>(&'a self, source: &'a InstanceEndpoint) -> &'a str {
        self.executor_controller
            .as_deref()
            .unwrap_or(&source.controller)
    }

    fn validate(&self, source: &InstanceEndpoint) -> Result<()> {
        if let Some(executor) = &self.executor_controller {
            validate_name("Incus backup executor", executor)?;
        }
        if !self.program.is_absolute()
            || self.program.file_name().and_then(|name| name.to_str()) != Some("incus")
        {
            bail!("instance backup program must be an absolute incus executable");
        }
        if !(1..=86_400).contains(&self.stop_timeout_seconds) {
            bail!("instance backup stop timeout must be between 1 and 86400 seconds");
        }
        if let Some(pool) = &self.restore_storage_pool {
            validate_incus_name("instance backup restore storage pool", pool)?;
        }
        validate_name("Incus backup executor", self.executor(source))
    }
}

impl DataRootMapping {
    fn validate(&self) -> Result<()> {
        validate_name("data-root name", &self.name)?;
        validate_absolute_data_root("source data root", &self.source)?;
        validate_absolute_data_root("target data root", &self.target)?;
        validate_excludes(&self.excludes)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DeclaredDataRoot {
    pub name: String,
    pub path: PathBuf,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub excludes: Vec<PathBuf>,
}

impl DeclaredDataRoot {
    fn validate(&self) -> Result<()> {
        validate_name("data-root name", &self.name)?;
        validate_absolute_data_root("data root", &self.path)?;
        validate_excludes(&self.excludes)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum MoveItem {
    Host {
        id: String,
        source: HostEndpoint,
        target: HostEndpoint,
        #[serde(default)]
        data_roots: Vec<DataRootMapping>,
    },
    Service {
        id: String,
        service: String,
        source: HostEndpoint,
        target: HostEndpoint,
        #[serde(default)]
        data_roots: Vec<DataRootMapping>,
    },
    Resource {
        id: String,
        resource: String,
        source: HostEndpoint,
        target: HostEndpoint,
        #[serde(default)]
        data_roots: Vec<DataRootMapping>,
    },
    Instance {
        id: String,
        source: InstanceEndpoint,
        target: InstanceEndpoint,
        #[serde(default)]
        policy: InstanceMovePolicy,
    },
}

impl MoveItem {
    pub fn id(&self) -> &str {
        match self {
            Self::Host { id, .. }
            | Self::Service { id, .. }
            | Self::Resource { id, .. }
            | Self::Instance { id, .. } => id,
        }
    }

    pub fn source_authority(&self) -> AuthorityKey {
        self.authority(true)
    }

    pub fn target_authority(&self) -> AuthorityKey {
        self.authority(false)
    }

    fn host_endpoints(&self) -> Vec<&HostEndpoint> {
        match self {
            Self::Host { source, target, .. }
            | Self::Service { source, target, .. }
            | Self::Resource { source, target, .. } => vec![source, target],
            Self::Instance { .. } => Vec::new(),
        }
    }

    fn authority(&self, source_side: bool) -> AuthorityKey {
        match self {
            Self::Host { source, target, .. } => AuthorityKey {
                container: select_host_endpoint(source_side, source, target).authority_container(),
                subject: AuthoritySubject::Whole,
            },
            Self::Service {
                service,
                source,
                target,
                ..
            } => AuthorityKey {
                container: select_host_endpoint(source_side, source, target).authority_container(),
                subject: AuthoritySubject::Service {
                    name: service.clone(),
                },
            },
            Self::Resource {
                resource,
                source,
                target,
                ..
            } => AuthorityKey {
                container: select_host_endpoint(source_side, source, target).authority_container(),
                subject: resource_subject(resource),
            },
            Self::Instance { source, target, .. } => AuthorityKey {
                container: AuthorityContainer::Instance {
                    endpoint: if source_side {
                        source.clone()
                    } else {
                        target.clone()
                    },
                },
                subject: AuthoritySubject::Whole,
            },
        }
    }

    fn validate(&self) -> Result<()> {
        validate_name("move-item ID", self.id())?;
        match self {
            Self::Host {
                source,
                target,
                data_roots,
                ..
            } => {
                validate_host_move_endpoints(source, target)?;
                validate_mapped_roots(data_roots)
            }
            Self::Service {
                service,
                source,
                target,
                data_roots,
                ..
            } => {
                validate_name("service name", service)?;
                validate_host_move_endpoints(source, target)?;
                validate_mapped_roots(data_roots)
            }
            Self::Resource {
                resource,
                source,
                target,
                data_roots,
                ..
            } => {
                validate_resource_id(resource)?;
                validate_host_move_endpoints(source, target)?;
                validate_mapped_roots(data_roots)
            }
            Self::Instance {
                source,
                target,
                policy,
                ..
            } => {
                source.validate()?;
                target.validate()?;
                if source == target {
                    bail!("instance move source and target must differ");
                }
                policy.validate(source)
            }
        }
    }

    fn root_claims(&self) -> Vec<RootClaim> {
        match self {
            Self::Host {
                id,
                source,
                target,
                data_roots,
            }
            | Self::Service {
                id,
                source,
                target,
                data_roots,
                ..
            }
            | Self::Resource {
                id,
                source,
                target,
                data_roots,
                ..
            } => data_roots
                .iter()
                .flat_map(|root| {
                    [
                        RootClaim {
                            item: id.clone(),
                            root: root.name.clone(),
                            container: source.authority_container(),
                            path: root.source.clone(),
                        },
                        RootClaim {
                            item: id.clone(),
                            root: root.name.clone(),
                            container: target.authority_container(),
                            path: root.target.clone(),
                        },
                    ]
                })
                .collect(),
            Self::Instance { .. } => Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ConsistencyGroup {
    pub id: String,
    pub items: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ActivationWave {
    pub id: String,
    pub items: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TransactionSpec {
    pub schema_version: u32,
    pub id: String,
    pub items: Vec<MoveItem>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub consistency_groups: Vec<ConsistencyGroup>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub activation_waves: Vec<ActivationWave>,
}

impl TransactionSpec {
    pub fn new(
        caller_id: Option<&str>,
        items: Vec<MoveItem>,
        consistency_groups: Vec<ConsistencyGroup>,
        activation_waves: Vec<ActivationWave>,
    ) -> Result<Self> {
        let spec = Self {
            schema_version: TRANSACTION_SPEC_SCHEMA_VERSION,
            id: transaction_id(caller_id)?,
            items,
            consistency_groups,
            activation_waves,
        };
        spec.validate()?;
        Ok(spec)
    }

    pub fn validate(&self) -> Result<()> {
        if self.schema_version != TRANSACTION_SPEC_SCHEMA_VERSION {
            bail!(
                "unsupported transaction-spec schema version {}",
                self.schema_version
            );
        }
        validate_workflow_id(&self.id)?;
        if self.items.is_empty() {
            bail!("transaction spec must contain at least one move item");
        }

        let item_ids = validate_items(
            "move",
            self.items.iter().map(|item| (item.id(), item.validate())),
        )?;
        validate_host_endpoint_bindings(self.items.iter().flat_map(MoveItem::host_endpoints))?;
        validate_authorities(
            "source",
            self.items
                .iter()
                .map(|item| (item.id(), item.source_authority())),
        )?;
        validate_authorities(
            "target",
            self.items
                .iter()
                .map(|item| (item.id(), item.target_authority())),
        )?;
        validate_root_claims(self.items.iter().flat_map(MoveItem::root_claims))?;

        validate_consistency_groups(&self.consistency_groups, &item_ids)?;
        validate_activation_waves(&self.activation_waves, &item_ids, &self.consistency_groups)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum BackupItem {
    Host {
        id: String,
        source: HostEndpoint,
        #[serde(default)]
        data_roots: Vec<DeclaredDataRoot>,
    },
    Service {
        id: String,
        service: String,
        source: HostEndpoint,
        #[serde(default)]
        data_roots: Vec<DeclaredDataRoot>,
    },
    Resource {
        id: String,
        resource: String,
        source: HostEndpoint,
        #[serde(default)]
        data_roots: Vec<DeclaredDataRoot>,
    },
    Instance {
        id: String,
        source: InstanceEndpoint,
        #[serde(default)]
        policy: InstanceBackupPolicy,
    },
}

impl BackupItem {
    pub fn id(&self) -> &str {
        match self {
            Self::Host { id, .. }
            | Self::Service { id, .. }
            | Self::Resource { id, .. }
            | Self::Instance { id, .. } => id,
        }
    }

    pub fn authority(&self) -> AuthorityKey {
        match self {
            Self::Host { source, .. } => AuthorityKey {
                container: source.authority_container(),
                subject: AuthoritySubject::Whole,
            },
            Self::Service {
                service, source, ..
            } => AuthorityKey {
                container: source.authority_container(),
                subject: AuthoritySubject::Service {
                    name: service.clone(),
                },
            },
            Self::Resource {
                resource, source, ..
            } => AuthorityKey {
                container: source.authority_container(),
                subject: resource_subject(resource),
            },
            Self::Instance { source, .. } => AuthorityKey {
                container: AuthorityContainer::Instance {
                    endpoint: source.clone(),
                },
                subject: AuthoritySubject::Whole,
            },
        }
    }

    fn host_endpoints(&self) -> Vec<&HostEndpoint> {
        match self {
            Self::Host { source, .. }
            | Self::Service { source, .. }
            | Self::Resource { source, .. } => vec![source],
            Self::Instance { .. } => Vec::new(),
        }
    }

    fn validate(&self) -> Result<()> {
        validate_name("backup-item ID", self.id())?;
        match self {
            Self::Host {
                source, data_roots, ..
            } => {
                source.validate()?;
                validate_declared_roots(data_roots)
            }
            Self::Service {
                service,
                source,
                data_roots,
                ..
            } => {
                validate_name("service name", service)?;
                source.validate()?;
                validate_declared_roots(data_roots)
            }
            Self::Resource {
                resource,
                source,
                data_roots,
                ..
            } => {
                validate_resource_id(resource)?;
                source.validate()?;
                validate_declared_roots(data_roots)
            }
            Self::Instance { source, policy, .. } => {
                source.validate()?;
                policy.validate(source)
            }
        }
    }

    fn root_claims(&self) -> Vec<RootClaim> {
        let (id, source, data_roots) = match self {
            Self::Host {
                id,
                source,
                data_roots,
            }
            | Self::Service {
                id,
                source,
                data_roots,
                ..
            }
            | Self::Resource {
                id,
                source,
                data_roots,
                ..
            } => (id, source, data_roots),
            Self::Instance { .. } => return Vec::new(),
        };
        data_roots
            .iter()
            .map(|root| RootClaim {
                item: id.clone(),
                root: root.name.clone(),
                container: source.authority_container(),
                path: root.path.clone(),
            })
            .collect()
    }
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum BackupDestination {
    Host { endpoint: HostEndpoint },
    ControllerDirectory { path: PathBuf },
}

impl BackupDestination {
    fn validate(&self) -> Result<()> {
        match self {
            Self::Host { endpoint } => endpoint.validate(),
            Self::ControllerDirectory { path } => {
                validate_absolute_data_root("controller backup directory", path)
            }
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BackupSpec {
    pub schema_version: u32,
    pub id: String,
    pub items: Vec<BackupItem>,
    pub destinations: Vec<BackupDestination>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub consistency_groups: Vec<ConsistencyGroup>,
}

impl BackupSpec {
    pub fn new(
        caller_id: Option<&str>,
        items: Vec<BackupItem>,
        destinations: Vec<BackupDestination>,
        consistency_groups: Vec<ConsistencyGroup>,
    ) -> Result<Self> {
        let spec = Self {
            schema_version: BACKUP_SPEC_SCHEMA_VERSION,
            id: backup_id(caller_id)?,
            items,
            destinations,
            consistency_groups,
        };
        spec.validate()?;
        Ok(spec)
    }

    pub fn validate(&self) -> Result<()> {
        if self.schema_version != BACKUP_SPEC_SCHEMA_VERSION {
            bail!(
                "unsupported backup-spec schema version {}",
                self.schema_version
            );
        }
        validate_workflow_id(&self.id)?;
        if self.items.is_empty() {
            bail!("backup spec must contain at least one backup item");
        }
        if self.destinations.is_empty() {
            bail!("backup spec must contain at least one destination");
        }
        for destination in &self.destinations {
            destination.validate()?;
        }
        let destination_count = self.destinations.iter().collect::<BTreeSet<_>>().len();
        if destination_count != self.destinations.len() {
            bail!("backup spec contains duplicate destinations");
        }

        let item_ids = validate_items(
            "backup",
            self.items.iter().map(|item| (item.id(), item.validate())),
        )?;
        let mut host_endpoints = self
            .items
            .iter()
            .flat_map(BackupItem::host_endpoints)
            .collect::<Vec<_>>();
        for destination in &self.destinations {
            if let BackupDestination::Host { endpoint } = destination {
                host_endpoints.push(endpoint);
            }
        }
        validate_host_endpoint_bindings(host_endpoints)?;
        validate_authorities(
            "backup",
            self.items.iter().map(|item| (item.id(), item.authority())),
        )?;
        validate_root_claims(self.items.iter().flat_map(BackupItem::root_claims))?;
        validate_consistency_groups(&self.consistency_groups, &item_ids)?;
        Ok(())
    }
}

pub fn transaction_id(caller_id: Option<&str>) -> Result<String> {
    workflow_id("move", caller_id)
}

pub fn backup_id(caller_id: Option<&str>) -> Result<String> {
    workflow_id("backup", caller_id)
}

pub fn validate_workflow_id(id: &str) -> Result<()> {
    if id.is_empty()
        || id.len() > 128
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        bail!("workflow ID must be 1..=128 ASCII alphanumeric, hyphen, or underscore characters");
    }
    Ok(())
}

fn workflow_id(prefix: &str, caller_id: Option<&str>) -> Result<String> {
    if let Some(id) = caller_id {
        validate_workflow_id(id)?;
        return Ok(id.to_owned());
    }
    let unix_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before Unix epoch")?
        .as_millis();
    Ok(generated_id(prefix, unix_ms, Uuid::new_v4()))
}

fn generated_id(prefix: &str, unix_ms: u128, uuid: Uuid) -> String {
    format!("{prefix}-{unix_ms:013}-{}", uuid.simple())
}

fn select_host_endpoint<'a>(
    source_side: bool,
    source: &'a HostEndpoint,
    target: &'a HostEndpoint,
) -> &'a HostEndpoint {
    if source_side { source } else { target }
}

fn resource_subject(resource: &str) -> AuthoritySubject {
    resource.strip_prefix("service:").map_or_else(
        || AuthoritySubject::Resource {
            id: resource.to_owned(),
        },
        |name| AuthoritySubject::Service {
            name: name.to_owned(),
        },
    )
}

fn validate_host_move_endpoints(source: &HostEndpoint, target: &HostEndpoint) -> Result<()> {
    source.validate()?;
    target.validate()?;
    if source.authority_container() == target.authority_container() {
        bail!("host-backed move source and target authority containers must differ");
    }
    Ok(())
}

fn validate_items<'a>(
    kind: &str,
    items: impl IntoIterator<Item = (&'a str, Result<()>)>,
) -> Result<BTreeSet<String>> {
    let mut ids = BTreeSet::new();
    for (id, validation) in items {
        validation.with_context(|| format!("invalid {kind} item {id:?}"))?;
        if !ids.insert(id.to_owned()) {
            bail!("duplicate {kind} item ID {id:?}");
        }
    }
    Ok(ids)
}

fn validate_authorities<'a>(
    side: &str,
    authorities: impl IntoIterator<Item = (&'a str, AuthorityKey)>,
) -> Result<()> {
    let mut seen: Vec<(String, AuthorityKey)> = Vec::new();
    for (item, authority) in authorities {
        if let Some((other, other_authority)) = seen
            .iter()
            .find(|(_, other_authority)| authority.overlaps(other_authority))
        {
            bail!(
                "overlapping {side} authority for items {other:?} and {item:?}: {other_authority:?} conflicts with {authority:?}"
            );
        }
        seen.push((item.to_owned(), authority));
    }
    Ok(())
}

fn validate_host_endpoint_bindings<'a>(
    endpoints: impl IntoIterator<Item = &'a HostEndpoint>,
) -> Result<()> {
    let mut bindings: BTreeMap<&str, &Option<InstanceEndpoint>> = BTreeMap::new();
    for endpoint in endpoints {
        if let Some(existing) = bindings.insert(&endpoint.host, &endpoint.instance)
            && existing != &endpoint.instance
        {
            bail!(
                "inventory host {:?} has conflicting infrastructure-instance containment",
                endpoint.host
            );
        }
    }
    Ok(())
}

fn validate_mapped_roots(roots: &[DataRootMapping]) -> Result<()> {
    let mut names = BTreeSet::new();
    for root in roots {
        root.validate()?;
        if !names.insert(&root.name) {
            bail!("duplicate data-root name {:?}", root.name);
        }
    }
    Ok(())
}

fn validate_declared_roots(roots: &[DeclaredDataRoot]) -> Result<()> {
    let mut names = BTreeSet::new();
    for root in roots {
        root.validate()?;
        if !names.insert(&root.name) {
            bail!("duplicate data-root name {:?}", root.name);
        }
    }
    Ok(())
}

#[derive(Debug)]
struct RootClaim {
    item: String,
    root: String,
    container: AuthorityContainer,
    path: PathBuf,
}

fn validate_root_claims(claims: impl IntoIterator<Item = RootClaim>) -> Result<()> {
    let mut seen: Vec<RootClaim> = Vec::new();
    for claim in claims {
        if let Some(other) = seen.iter().find(|other| {
            claim.container == other.container && paths_overlap(&claim.path, &other.path)
        }) {
            bail!(
                "overlapping declared data roots {}:{:?} and {}:{:?} in {:?}: {} conflicts with {}",
                other.item,
                other.root,
                claim.item,
                claim.root,
                claim.container,
                other.path.display(),
                claim.path.display()
            );
        }
        seen.push(claim);
    }
    Ok(())
}

fn validate_consistency_groups(
    groups: &[ConsistencyGroup],
    item_ids: &BTreeSet<String>,
) -> Result<()> {
    let mut group_ids = BTreeSet::new();
    let mut membership = BTreeMap::new();
    for group in groups {
        validate_name("consistency-group ID", &group.id)?;
        if !group_ids.insert(&group.id) {
            bail!("duplicate consistency-group ID {:?}", group.id);
        }
        if group.items.is_empty() {
            bail!(
                "consistency group {:?} must contain at least one item",
                group.id
            );
        }
        let mut local = BTreeSet::new();
        for item in &group.items {
            if !local.insert(item) {
                bail!(
                    "consistency group {:?} contains duplicate item {:?}",
                    group.id,
                    item
                );
            }
            if !item_ids.contains(item) {
                bail!(
                    "consistency group {:?} references unknown item {:?}",
                    group.id,
                    item
                );
            }
            if let Some(other) = membership.insert(item.clone(), group.id.clone()) {
                bail!(
                    "item {item:?} belongs to multiple consistency groups {other:?} and {:?}",
                    group.id
                );
            }
        }
    }
    Ok(())
}

fn validate_activation_waves(
    waves: &[ActivationWave],
    item_ids: &BTreeSet<String>,
    groups: &[ConsistencyGroup],
) -> Result<()> {
    if waves.is_empty() {
        return Ok(());
    }

    let mut wave_ids = BTreeSet::new();
    let mut membership = BTreeMap::new();
    for wave in waves {
        validate_name("activation-wave ID", &wave.id)?;
        if !wave_ids.insert(&wave.id) {
            bail!("duplicate activation-wave ID {:?}", wave.id);
        }
        if wave.items.is_empty() {
            bail!(
                "activation wave {:?} must contain at least one item",
                wave.id
            );
        }
        let mut local = BTreeSet::new();
        for item in &wave.items {
            if !local.insert(item) {
                bail!(
                    "activation wave {:?} contains duplicate item {:?}",
                    wave.id,
                    item
                );
            }
            if !item_ids.contains(item) {
                bail!(
                    "activation wave {:?} references unknown item {:?}",
                    wave.id,
                    item
                );
            }
            if let Some(other) = membership.insert(item.clone(), wave.id.clone()) {
                bail!(
                    "item {item:?} belongs to multiple activation waves {other:?} and {:?}",
                    wave.id
                );
            }
        }
    }

    if let Some(missing) = item_ids.iter().find(|item| !membership.contains_key(*item)) {
        bail!("activation waves do not include item {missing:?}");
    }

    for group in groups {
        let Some(first_item) = group.items.first() else {
            continue;
        };
        let expected_wave = membership
            .get(first_item)
            .expect("all validated items have an activation wave");
        if let Some(item) = group
            .items
            .iter()
            .find(|item| membership.get(*item) != Some(expected_wave))
        {
            let actual_wave = membership
                .get(item)
                .expect("all validated items have an activation wave");
            bail!(
                "consistency group {:?} is split across activation waves {:?} and {:?}",
                group.id,
                expected_wave,
                actual_wave
            );
        }
    }
    Ok(())
}

fn validate_absolute_data_root(label: &str, path: &Path) -> Result<()> {
    if !path.is_absolute() || path == Path::new("/") || !is_lexically_normal(path) {
        bail!("{label} must be an absolute, normalized, non-root path");
    }
    Ok(())
}

fn validate_excludes(excludes: &[PathBuf]) -> Result<()> {
    let mut unique = BTreeSet::new();
    for exclude in excludes {
        if exclude.as_os_str().is_empty() || exclude.is_absolute() || !is_lexically_normal(exclude)
        {
            bail!("data-root excludes must be normalized relative paths");
        }
        if !unique.insert(exclude) {
            bail!("duplicate data-root exclude {}", exclude.display());
        }
    }
    Ok(())
}

fn is_lexically_normal(path: &Path) -> bool {
    path.components()
        .all(|component| !matches!(component, Component::CurDir | Component::ParentDir))
}

fn paths_overlap(left: &Path, right: &Path) -> bool {
    left == right || left.starts_with(right) || right.starts_with(left)
}

fn validate_resource_id(resource: &str) -> Result<()> {
    validate_name("resource ID", resource)?;
    if resource.starts_with("host:") || resource.starts_with("instance:") {
        bail!("host:* and instance:* resources require their typed move item");
    }
    if resource == "service:" {
        bail!("service resource ID must include a name");
    }
    Ok(())
}

fn validate_name(label: &str, value: &str) -> Result<()> {
    if value.trim().is_empty()
        || value != value.trim()
        || value.contains('\0')
        || value.chars().any(char::is_control)
    {
        bail!("{label} must be a non-empty, trimmed value without control characters");
    }
    Ok(())
}

fn validate_incus_name(label: &str, value: &str) -> Result<()> {
    if value.is_empty()
        || value.starts_with('-')
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    {
        bail!("{label} is invalid");
    }
    Ok(())
}

fn default_incus_remote() -> String {
    "local".to_owned()
}

fn default_incus_project() -> String {
    "default".to_owned()
}

fn default_true() -> bool {
    true
}

fn default_incus_program() -> PathBuf {
    "/run/current-system/sw/bin/incus".into()
}

fn default_instance_stop_timeout_seconds() -> u64 {
    60
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(name: &str) -> HostEndpoint {
        HostEndpoint {
            host: name.to_owned(),
            instance: None,
        }
    }

    fn instance(controller: &str, remote: &str, project: &str, name: &str) -> InstanceEndpoint {
        InstanceEndpoint {
            controller: controller.to_owned(),
            remote: remote.to_owned(),
            project: project.to_owned(),
            instance: name.to_owned(),
        }
    }

    fn instance_host(host: &str, endpoint: InstanceEndpoint) -> HostEndpoint {
        HostEndpoint {
            host: host.to_owned(),
            instance: Some(endpoint),
        }
    }

    fn mapping(name: &str, source: &str, target: &str) -> DataRootMapping {
        DataRootMapping {
            name: name.to_owned(),
            source: source.into(),
            target: target.into(),
            excludes: Vec::new(),
        }
    }

    fn root(name: &str, path: &str) -> DeclaredDataRoot {
        DeclaredDataRoot {
            name: name.to_owned(),
            path: path.into(),
            excludes: Vec::new(),
        }
    }

    fn service_move(id: &str, service: &str, source: &str, target: &str) -> MoveItem {
        MoveItem::Service {
            id: id.to_owned(),
            service: service.to_owned(),
            source: host(source),
            target: host(target),
            data_roots: vec![mapping(
                "data",
                &format!("/srv/{service}"),
                &format!("/srv/{service}"),
            )],
        }
    }

    fn transaction(items: Vec<MoveItem>) -> TransactionSpec {
        TransactionSpec {
            schema_version: TRANSACTION_SPEC_SCHEMA_VERSION,
            id: "move-test".to_owned(),
            items,
            consistency_groups: Vec::new(),
            activation_waves: Vec::new(),
        }
    }

    #[test]
    fn accepts_heterogeneous_hosts_controllers_remotes_projects_groups_and_waves() {
        let items = vec![
            service_move("zulip", "zulip", "corp", "zulip-new"),
            MoveItem::Resource {
                id: "mail-data".to_owned(),
                resource: "group:mail-data".to_owned(),
                source: host("corp"),
                target: host("mail-new"),
                data_roots: vec![mapping("mail", "/srv/mail", "/data/mail")],
            },
            MoveItem::Instance {
                id: "database-instance".to_owned(),
                source: instance("gondor", "prod", "abird", "database-old"),
                target: instance("nest", "recovery", "abird-next", "database-new"),
                policy: InstanceMovePolicy::default(),
            },
        ];
        let spec = TransactionSpec::new(
            Some("move-heterogeneous"),
            items,
            vec![ConsistencyGroup {
                id: "application-state".to_owned(),
                items: vec!["zulip".to_owned(), "mail-data".to_owned()],
            }],
            vec![
                ActivationWave {
                    id: "applications".to_owned(),
                    items: vec!["zulip".to_owned(), "mail-data".to_owned()],
                },
                ActivationWave {
                    id: "database".to_owned(),
                    items: vec!["database-instance".to_owned()],
                },
            ],
        )
        .unwrap();

        assert_eq!(spec.id, "move-heterogeneous");
        assert_eq!(spec.items.len(), 3);
        assert_eq!(spec.activation_waves.len(), 2);

        let encoded = serde_json::to_string(&spec).unwrap();
        assert_eq!(
            serde_json::from_str::<TransactionSpec>(&encoded).unwrap(),
            spec
        );

        let mut value = serde_json::to_value(&spec).unwrap();
        value
            .as_object_mut()
            .unwrap()
            .insert("unknown".to_owned(), serde_json::Value::Bool(true));
        assert!(serde_json::from_value::<TransactionSpec>(value).is_err());
    }

    #[test]
    fn generated_ids_are_prefixed_and_time_sortable_and_override_is_preserved() {
        let early = generated_id("move", 1, Uuid::from_u128(2));
        let late = generated_id("move", 2, Uuid::from_u128(1));
        assert!(early < late);
        assert!(transaction_id(None).unwrap().starts_with("move-"));
        assert!(backup_id(None).unwrap().starts_with("backup-"));
        assert_eq!(
            transaction_id(Some("operator_retry_1")).unwrap(),
            "operator_retry_1"
        );
        assert!(transaction_id(Some("bad/id")).is_err());
    }

    #[test]
    fn rejects_wrong_version_empty_items_and_duplicate_item_ids() {
        let mut spec = transaction(vec![service_move("zulip", "zulip", "a", "b")]);
        spec.schema_version = 99;
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("schema version")
        );

        let spec = transaction(Vec::new());
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("at least one")
        );

        let spec = transaction(vec![
            service_move("same", "zulip", "a", "b"),
            service_move("same", "mail", "c", "d"),
        ]);
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("duplicate move item")
        );
    }

    #[test]
    fn rejects_unknown_and_duplicate_consistency_group_membership() {
        let mut spec = transaction(vec![
            service_move("zulip", "zulip", "a", "b"),
            service_move("mail", "mail", "c", "d"),
        ]);
        spec.consistency_groups = vec![ConsistencyGroup {
            id: "apps".to_owned(),
            items: vec!["missing".to_owned()],
        }];
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("unknown item")
        );

        spec.consistency_groups = vec![ConsistencyGroup {
            id: "apps".to_owned(),
            items: vec!["zulip".to_owned(), "zulip".to_owned()],
        }];
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("duplicate item")
        );

        spec.consistency_groups = vec![
            ConsistencyGroup {
                id: "apps-a".to_owned(),
                items: vec!["zulip".to_owned()],
            },
            ConsistencyGroup {
                id: "apps-b".to_owned(),
                items: vec!["zulip".to_owned()],
            },
        ];
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("multiple consistency")
        );

        spec.consistency_groups = vec![
            ConsistencyGroup {
                id: "duplicate".to_owned(),
                items: vec!["zulip".to_owned()],
            },
            ConsistencyGroup {
                id: "duplicate".to_owned(),
                items: vec!["mail".to_owned()],
            },
        ];
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("duplicate consistency-group ID")
        );

        spec.consistency_groups = vec![ConsistencyGroup {
            id: "empty".to_owned(),
            items: Vec::new(),
        }];
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("at least one item")
        );
    }

    #[test]
    fn rejects_unknown_duplicate_missing_and_split_activation_wave_items() {
        let mut spec = transaction(vec![
            service_move("zulip", "zulip", "a", "b"),
            service_move("mail", "mail", "c", "d"),
        ]);
        spec.activation_waves = vec![ActivationWave {
            id: "wave".to_owned(),
            items: vec!["missing".to_owned()],
        }];
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("unknown item")
        );

        spec.activation_waves = vec![ActivationWave {
            id: "wave".to_owned(),
            items: vec!["zulip".to_owned(), "zulip".to_owned()],
        }];
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("duplicate item")
        );

        spec.activation_waves = vec![ActivationWave {
            id: "wave".to_owned(),
            items: vec!["zulip".to_owned()],
        }];
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("do not include")
        );

        spec.consistency_groups = vec![ConsistencyGroup {
            id: "apps".to_owned(),
            items: vec!["zulip".to_owned(), "mail".to_owned()],
        }];
        spec.activation_waves = vec![
            ActivationWave {
                id: "one".to_owned(),
                items: vec!["zulip".to_owned()],
            },
            ActivationWave {
                id: "two".to_owned(),
                items: vec!["mail".to_owned()],
            },
        ];
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("split across")
        );

        spec.consistency_groups.clear();
        spec.activation_waves = vec![
            ActivationWave {
                id: "duplicate".to_owned(),
                items: vec!["zulip".to_owned()],
            },
            ActivationWave {
                id: "duplicate".to_owned(),
                items: vec!["mail".to_owned()],
            },
        ];
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("duplicate activation-wave ID")
        );

        spec.activation_waves = vec![ActivationWave {
            id: "empty".to_owned(),
            items: Vec::new(),
        }];
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("at least one item")
        );

        spec.activation_waves = vec![
            ActivationWave {
                id: "one".to_owned(),
                items: vec!["zulip".to_owned()],
            },
            ActivationWave {
                id: "two".to_owned(),
                items: vec!["zulip".to_owned(), "mail".to_owned()],
            },
        ];
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("multiple activation waves")
        );
    }

    #[test]
    fn rejects_conflicting_host_instance_containment() {
        let container = instance("controller", "prod", "abird", "corp");
        let first = MoveItem::Service {
            id: "zulip".to_owned(),
            service: "zulip".to_owned(),
            source: instance_host("corp", container),
            target: host("zulip-new"),
            data_roots: Vec::new(),
        };
        let second = MoveItem::Service {
            id: "mail".to_owned(),
            service: "mail".to_owned(),
            source: host("corp"),
            target: host("mail-new"),
            data_roots: Vec::new(),
        };
        assert!(
            transaction(vec![first, second])
                .validate()
                .unwrap_err()
                .to_string()
                .contains("conflicting infrastructure-instance containment")
        );
    }

    #[test]
    fn rejects_host_aggregate_with_child_service_or_resource() {
        let host_item = MoveItem::Host {
            id: "whole".to_owned(),
            source: host("source"),
            target: host("target"),
            data_roots: Vec::new(),
        };
        let service = service_move("service", "zulip", "source", "service-target");
        assert!(
            transaction(vec![host_item.clone(), service])
                .validate()
                .unwrap_err()
                .to_string()
                .contains("overlapping source authority")
        );

        let resource = MoveItem::Resource {
            id: "resource".to_owned(),
            resource: "group:state".to_owned(),
            source: host("source"),
            target: host("resource-target"),
            data_roots: Vec::new(),
        };
        assert!(
            transaction(vec![host_item, resource])
                .validate()
                .unwrap_err()
                .to_string()
                .contains("overlapping source authority")
        );
    }

    #[test]
    fn rejects_whole_instance_with_represented_in_instance_child() {
        let source_instance = instance("controller", "prod", "abird", "corp");
        let target_instance = instance("controller", "prod", "abird", "corp-new");
        let whole = MoveItem::Instance {
            id: "whole".to_owned(),
            source: source_instance.clone(),
            target: target_instance,
            policy: InstanceMovePolicy::default(),
        };
        let child = MoveItem::Service {
            id: "zulip".to_owned(),
            service: "zulip".to_owned(),
            source: instance_host("corp", source_instance),
            target: host("zulip-new"),
            data_roots: Vec::new(),
        };
        assert!(
            transaction(vec![whole, child])
                .validate()
                .unwrap_err()
                .to_string()
                .contains("overlapping source authority")
        );
    }

    #[test]
    fn service_item_and_service_resource_share_one_authority_key() {
        let service = service_move("typed", "zulip", "source", "target-a");
        let resource = MoveItem::Resource {
            id: "generic".to_owned(),
            resource: "service:zulip".to_owned(),
            source: host("source"),
            target: host("target-b"),
            data_roots: Vec::new(),
        };
        assert!(
            transaction(vec![service, resource])
                .validate()
                .unwrap_err()
                .to_string()
                .contains("overlapping source authority")
        );
    }

    #[test]
    fn rejects_duplicate_names_and_overlapping_declared_data_roots() {
        let duplicate_names = MoveItem::Service {
            id: "zulip".to_owned(),
            service: "zulip".to_owned(),
            source: host("source"),
            target: host("target"),
            data_roots: vec![
                mapping("data", "/srv/zulip", "/srv/zulip"),
                mapping("data", "/srv/other", "/srv/other"),
            ],
        };
        let error = transaction(vec![duplicate_names]).validate().unwrap_err();
        assert!(format!("{error:#}").contains("duplicate data-root name"));

        let first = service_move("zulip", "zulip", "source", "target-a");
        let second = MoveItem::Service {
            id: "mail".to_owned(),
            service: "mail".to_owned(),
            source: host("source"),
            target: host("target-b"),
            data_roots: vec![mapping("queue", "/srv/zulip/queue", "/srv/mail")],
        };
        assert!(
            transaction(vec![first, second])
                .validate()
                .unwrap_err()
                .to_string()
                .contains("overlapping declared data roots")
        );
    }

    #[test]
    fn accepts_backup_items_destination_and_groups() {
        let spec = BackupSpec::new(
            Some("backup-nightly"),
            vec![
                BackupItem::Service {
                    id: "zulip".to_owned(),
                    service: "zulip".to_owned(),
                    source: host("corp"),
                    data_roots: vec![root("data", "/srv/zulip")],
                },
                BackupItem::Instance {
                    id: "database".to_owned(),
                    source: instance("gondor", "prod", "abird", "database"),
                    policy: InstanceBackupPolicy::default(),
                },
            ],
            vec![BackupDestination::ControllerDirectory {
                path: "/srv/backups/abird".into(),
            }],
            vec![ConsistencyGroup {
                id: "application".to_owned(),
                items: vec!["zulip".to_owned(), "database".to_owned()],
            }],
        )
        .unwrap();
        assert_eq!(spec.id, "backup-nightly");
    }

    #[test]
    fn rejects_backup_authority_and_data_root_overlap() {
        let whole = BackupItem::Host {
            id: "whole".to_owned(),
            source: host("corp"),
            data_roots: Vec::new(),
        };
        let child = BackupItem::Service {
            id: "zulip".to_owned(),
            service: "zulip".to_owned(),
            source: host("corp"),
            data_roots: vec![root("data", "/srv/zulip")],
        };
        let mut spec = BackupSpec::new(
            Some("backup-test"),
            vec![whole],
            vec![BackupDestination::Host {
                endpoint: host("backup"),
            }],
            Vec::new(),
        )
        .unwrap();
        spec.items.push(child);
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("overlapping backup authority")
        );

        spec.items = vec![
            BackupItem::Service {
                id: "zulip".to_owned(),
                service: "zulip".to_owned(),
                source: host("corp"),
                data_roots: vec![root("data", "/srv/zulip")],
            },
            BackupItem::Service {
                id: "mail".to_owned(),
                service: "mail".to_owned(),
                source: host("corp"),
                data_roots: vec![root("queue", "/srv/zulip/queue")],
            },
        ];
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("overlapping declared")
        );
    }

    #[test]
    fn rejects_invalid_backup_destination_and_group_reference() {
        let mut spec = BackupSpec {
            schema_version: BACKUP_SPEC_SCHEMA_VERSION,
            id: "backup-test".to_owned(),
            items: vec![BackupItem::Service {
                id: "zulip".to_owned(),
                service: "zulip".to_owned(),
                source: host("corp"),
                data_roots: vec![root("data", "/srv/zulip")],
            }],
            destinations: vec![BackupDestination::ControllerDirectory {
                path: "relative".into(),
            }],
            consistency_groups: Vec::new(),
        };
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("absolute")
        );

        spec.destinations = vec![BackupDestination::Host {
            endpoint: host("backup"),
        }];
        spec.consistency_groups = vec![ConsistencyGroup {
            id: "bad".to_owned(),
            items: vec!["missing".to_owned()],
        }];
        assert!(
            spec.validate()
                .unwrap_err()
                .to_string()
                .contains("unknown item")
        );
    }
}
