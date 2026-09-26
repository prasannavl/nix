use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::thread;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::offline_store::{OfflineHostManifest, OfflineStore};
use crate::physical::{BootMode, HardwareProjection, PhysicalLayout, PhysicalLayoutRequest};
#[cfg(test)]
use crate::programs::GIT_REPOSITORY_ENVIRONMENT;
use crate::programs::clear_git_repository_environment;
use crate::programs::disko::DiskoScript;
use crate::programs::nix::Nix;
use crate::programs::nixos_install::NixosInstall;
use crate::programs::privilege::Privilege;
use crate::projection::{ActivationRequirement, PhaseProjection, ProjectionEffect};
use crate::workflow::{MoveItem, TransactionSpec};
use crate::workflow_runtime::WorkflowStore;

const HOSTS_FILE: &str = "hosts/default.nix";
const NIXBOT_FILE: &str = "hosts/nixbot.nix";
const SECRETS_FILE: &str = "data/secrets/default.nix";
const RUNTIME_PROJECTION_CLOSEOUTS_FILE: &str = "data/phase-projection-closeouts.json";
const MARKER_NAME: &str = ".abird-host-manager.json";
const MARKER_VERSION: u32 = 2;
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ManagedHostSystem {
    None,
    Live,
    Incus,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ManagedIncus {
    pub parent: String,
    pub project: String,
    pub ipv4_address: String,
    pub start_priority: u16,
    pub nested_containers: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ManagedHost {
    pub system: ManagedHostSystem,
    pub stack: Option<String>,
    pub target: String,
    pub proxy_jump: Option<String>,
    pub groups: Vec<String>,
    pub incus: Option<ManagedIncus>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct VersionedHostMarker {
    version: u32,
    record: ManagedHost,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    physical: Option<PhysicalLayout>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(untagged)]
enum HostMarker {
    Versioned(VersionedHostMarker),
    Legacy(ManagedHost),
}

impl HostMarker {
    fn into_versioned(self) -> VersionedHostMarker {
        match self {
            Self::Versioned(marker) => marker,
            Self::Legacy(record) => VersionedHostMarker {
                version: 1,
                record,
                physical: None,
            },
        }
    }
}

#[derive(Debug, Serialize)]
pub struct RepositoryChange {
    pub host: String,
    pub files: Vec<PathBuf>,
    pub host_directory: PathBuf,
    pub changed: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ProjectionWrite {
    pub path: PathBuf,
    pub changed: bool,
    pub generation: u64,
    pub projection_sha256: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ProjectionPublication {
    pub write: ProjectionWrite,
    pub projection: PhaseProjection,
    pub branch: String,
    pub revision: String,
    pub pushed: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectionAdmission {
    pub projection: Option<PhaseProjection>,
    pub requires_existing_journal: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProjectionPublicationStage {
    Validate,
    Commit,
    RetainLocal,
    Push,
    Verify,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProjectionPublicationEvent {
    Started(ProjectionPublicationStage),
    Progress {
        stage: ProjectionPublicationStage,
        detail: String,
    },
    Completed {
        stage: ProjectionPublicationStage,
        revision: Option<String>,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct RuntimeProjectionCloseoutCatalog {
    pub schema_version: u32,
    #[serde(default)]
    pub closeouts: BTreeMap<String, CanonicalProjectionCloseout>,
    #[serde(default)]
    pub controller_reconcile_exclusions: BTreeSet<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CanonicalProjectionCloseout {
    pub affected_hosts: Vec<String>,
    #[serde(default = "default_controller_reconcile")]
    pub controller_reconcile: bool,
    pub decision: String,
    pub projection_sha256: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct NixServicePlacement {
    role: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct NixServicePlacements {
    schema_version: u32,
    #[serde(default)]
    placements: BTreeMap<String, BTreeMap<String, NixServicePlacement>>,
}

fn nix_attribute(name: &str) -> String {
    // Quoting every key is both valid Nix and avoids maintaining a second,
    // inevitably incomplete list of reserved Nix language words.
    nix_string(name)
}

fn render_nix_value(value: &serde_json::Value, indentation: usize) -> Result<String> {
    let indent = |depth: usize| "  ".repeat(depth);
    match value {
        serde_json::Value::Null => Ok("null".to_owned()),
        serde_json::Value::Bool(value) => Ok(value.to_string()),
        serde_json::Value::Number(value) => {
            if value.as_i64().is_none() {
                bail!("Nix document renderer supports only signed 64-bit integers");
            }
            Ok(value.to_string())
        }
        serde_json::Value::String(value) => Ok(nix_string(value)),
        serde_json::Value::Array(values) => {
            if values.is_empty() {
                return Ok("[]".to_owned());
            }
            let mut rendered = String::from("[\n");
            for value in values {
                rendered.push_str(&indent(indentation + 1));
                rendered.push_str(&render_nix_value(value, indentation + 1)?);
                rendered.push('\n');
            }
            rendered.push_str(&indent(indentation));
            rendered.push(']');
            Ok(rendered)
        }
        serde_json::Value::Object(values) => {
            if values.is_empty() {
                return Ok("{}".to_owned());
            }
            let ordered = values.iter().collect::<BTreeMap<_, _>>();
            let mut rendered = String::from("{\n");
            for (name, value) in ordered {
                rendered.push_str(&indent(indentation + 1));
                rendered.push_str(&nix_attribute(name));
                rendered.push_str(" = ");
                rendered.push_str(&render_nix_value(value, indentation + 1)?);
                rendered.push_str(";\n");
            }
            rendered.push_str(&indent(indentation));
            rendered.push('}');
            Ok(rendered)
        }
    }
}

fn render_nix_document(value: &serde_json::Value) -> Result<String> {
    Ok(format!("{}\n", render_nix_value(value, 0)?))
}

fn default_controller_reconcile() -> bool {
    true
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RepositoryProjectionKind {
    RuntimeOnly,
    NixNativeServiceMove,
}

pub fn repository_projection_kind_for_spec(
    spec: &TransactionSpec,
) -> Result<RepositoryProjectionKind> {
    match (&spec.declarative_scope, &spec.repository_owner) {
        (None, None) => {
            spec.validate()?;
            if spec
                .items
                .iter()
                .any(|item| matches!(item, MoveItem::Service { .. }))
            {
                bail!("logical service moves require a declarative scope and repository owner");
            }
            Ok(RepositoryProjectionKind::RuntimeOnly)
        }
        (Some(_), Some(_)) => {
            spec.validate()?;
            NixMoveIdentity::from_spec(spec)?;
            Ok(RepositoryProjectionKind::NixNativeServiceMove)
        }
        (Some(_), None) => bail!("logical service-move intent requires repository-owner identity"),
        (None, Some(_)) => {
            bail!("service-move intent has repository-owner identity without a declarative scope")
        }
    }
}

pub fn repository_projection_kind(
    projection: &PhaseProjection,
) -> Result<RepositoryProjectionKind> {
    projection.validate()?;
    transaction_spec_for_move_projection(projection)?
        .map_or(Ok(RepositoryProjectionKind::RuntimeOnly), |spec| {
            repository_projection_kind_for_spec(&spec)
        })
}

fn transaction_spec_for_move_projection(
    projection: &PhaseProjection,
) -> Result<Option<TransactionSpec>> {
    if projection.intent_kind != "move" {
        return Ok(None);
    }
    serde_json::from_value(projection.intent.clone())
        .context("move projection intent is not a transaction specification")
        .map(Some)
}

pub fn is_nix_native_service_move(projection: &PhaseProjection) -> Result<bool> {
    Ok(repository_projection_kind(projection)? == RepositoryProjectionKind::NixNativeServiceMove)
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NixMoveIdentity {
    scope: String,
    repository_owner: String,
    services: Vec<String>,
    transaction: String,
}

impl NixMoveIdentity {
    fn from_spec(spec: &TransactionSpec) -> Result<Self> {
        let scope = spec
            .declarative_scope
            .as_deref()
            .context("Nix-native service move requires one declarative scope")?;
        let repository_owner = spec
            .repository_owner
            .as_deref()
            .context("Nix-native service move requires one repository owner")?;
        let services = spec
            .items
            .iter()
            .map(|item| match item {
                MoveItem::Service { service, .. } => Ok(service.clone()),
                _ => bail!("Nix-native service moves may contain only logical services"),
            })
            .collect::<Result<Vec<_>>>()?;
        Self::new(scope, repository_owner, services, &spec.id)
    }

    fn new(
        scope: &str,
        repository_owner: &str,
        services: Vec<String>,
        transaction: &str,
    ) -> Result<Self> {
        for (label, value) in [
            ("scope", scope),
            ("repository owner", repository_owner),
            ("transaction", transaction),
        ] {
            validate_repository_component(label, value)?;
        }
        if services.is_empty() {
            bail!("Nix-native service move must own at least one logical service");
        }
        let mut unique = BTreeSet::new();
        for service in &services {
            validate_repository_component("service", service)?;
            if !unique.insert(service) {
                bail!("Nix-native service move contains duplicate service {service:?}");
            }
        }
        Ok(Self {
            scope: scope.to_owned(),
            repository_owner: repository_owner.to_owned(),
            services,
            transaction: transaction.to_owned(),
        })
    }
}

fn validate_repository_component(label: &str, value: &str) -> Result<()> {
    if value.is_empty()
        || value.len() > 64
        || matches!(value, "." | "..")
        || !value
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        bail!("{label} is not a safe repository path component");
    }
    Ok(())
}

fn nix_move_identity(projection: &PhaseProjection) -> Result<NixMoveIdentity> {
    let spec: TransactionSpec = serde_json::from_value(projection.intent.clone())
        .context("service-move projection intent is not a transaction specification")?;
    if spec.id != projection.projection_id {
        bail!("service-move projection ID does not match its transaction identity");
    }
    NixMoveIdentity::from_spec(&spec)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NixServiceRepositoryPaths {
    pub move_path: PathBuf,
    pub placement_paths: Vec<PathBuf>,
}

impl Default for RuntimeProjectionCloseoutCatalog {
    fn default() -> Self {
        Self {
            schema_version: 1,
            closeouts: BTreeMap::new(),
            controller_reconcile_exclusions: BTreeSet::new(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ProjectionCloseoutPublication {
    pub authority_paths: Vec<PathBuf>,
    pub projection_path: PathBuf,
    pub branch: String,
    pub revision: String,
    pub pushed: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProjectionCloseoutStage {
    PersistAuthority,
    RetainAdoption,
    RemoveProjection,
    ValidateAdoption,
    Validate,
    Commit,
    RetainLocal,
    Push,
    Verify,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CloseoutProjectionState {
    RuntimeOnly,
    NativeAdopted,
    NativeClean,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProjectionCleanupStage {
    RemoveAdoptedMove,
    Validate,
    Commit,
    RetainLocal,
    Push,
    Verify,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProjectionCleanupEvent {
    Started(ProjectionCleanupStage),
    Progress {
        stage: ProjectionCleanupStage,
        detail: String,
    },
    Completed {
        stage: ProjectionCleanupStage,
        revision: Option<String>,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProjectionCloseoutEvent {
    Started(ProjectionCloseoutStage),
    Progress {
        stage: ProjectionCloseoutStage,
        detail: String,
    },
    Completed {
        stage: ProjectionCloseoutStage,
        revision: Option<String>,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProjectionPublicationMode {
    Remote,
    Local,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PublicationTransportStage {
    RetainLocal,
    Push,
    Verify,
}

#[derive(Debug)]
pub struct ProjectionPublisher {
    repository: Repository,
    git: PathBuf,
    nix: PathBuf,
    branch: String,
    publish_git_ssh_command: Option<String>,
    mode: ProjectionPublicationMode,
    local_recovery_path: Option<PathBuf>,
    // Publication is serialized by the repository lease held by this object.
    // RefCell expresses the single-threaded lineage update without suggesting
    // that this field is a second concurrency boundary.
    publication_base: RefCell<String>,
    // Held across publication, deployment, verification, and cleanup. The
    // workflow journal lock is intentionally released while Nixbot runs, so a
    // distinct non-blocking lease prevents another transaction from resetting
    // or advancing the one publisher-owned checkout in that interval.
    _state_publication_lease: File,
    _repository_publication_lease: Option<File>,
}

#[derive(Clone, Debug)]
enum OwnedPathMutation {
    Write {
        path: PathBuf,
        contents: Vec<u8>,
        mode: u32,
    },
    Remove {
        path: PathBuf,
    },
}

impl OwnedPathMutation {
    fn path(&self) -> &Path {
        match self {
            Self::Write { path, .. } | Self::Remove { path } => path,
        }
    }
}

#[cfg(test)]
fn apply_owned_path_mutations(root: &Path, mutations: &[OwnedPathMutation]) -> Result<()> {
    for mutation in mutations {
        apply_owned_path_mutation(root, mutation, None)?;
    }
    Ok(())
}

fn apply_owned_path_mutation(
    root: &Path,
    mutation: &OwnedPathMutation,
    temporary: Option<&Path>,
) -> Result<()> {
    let absolute = root.join(mutation.path());
    match mutation {
        OwnedPathMutation::Write { contents, mode, .. } => {
            if let Some(parent) = absolute.parent() {
                fs::create_dir_all(parent)?;
            }
            if let Some(temporary) = temporary {
                atomic_write_with_temporary(&absolute, &root.join(temporary), contents, *mode)
            } else {
                atomic_write(&absolute, contents, *mode)
            }
        }
        OwnedPathMutation::Remove { .. } => fs::remove_file(&absolute)
            .with_context(|| format!("remove owned repository document {}", absolute.display())),
    }
}

fn owned_atomic_temporary_path(path: &Path) -> Result<PathBuf> {
    let parent = path
        .parent()
        .context("owned repository path has no parent")?;
    let name = path
        .file_name()
        .context("owned repository path has no file name")?;
    let mut temporary_name = std::ffi::OsString::from(".");
    temporary_name.push(name);
    temporary_name.push(".abird-host-manager.tmp");
    let temporary = parent.join(temporary_name);
    validate_owned_repository_path(&temporary)?;
    Ok(temporary)
}

#[derive(Clone, Copy, Debug)]
enum RepositoryProjectionAdapterKind {
    ServiceMove,
}

/// Repository-domain adapters produce exact owned-path mutations; the shared
/// publication transaction owns clean-base admission, recovery, staging,
/// commit lineage, and verification. Service moves are the first registered
/// adapter, not a special publication protocol.
impl RepositoryProjectionAdapterKind {
    fn domain(&self) -> &'static str {
        match self {
            Self::ServiceMove => "service-move",
        }
    }
}

fn repository_projection_adapter(
    projection: &PhaseProjection,
) -> Result<Option<RepositoryProjectionAdapterKind>> {
    match repository_projection_kind(projection)? {
        RepositoryProjectionKind::RuntimeOnly => Ok(None),
        RepositoryProjectionKind::NixNativeServiceMove => {
            Ok(Some(RepositoryProjectionAdapterKind::ServiceMove))
        }
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct LocalPublicationRecovery {
    schema_version: u32,
    repository: PathBuf,
    branch: String,
    base_revision: String,
    #[serde(default)]
    committed_revision: Option<String>,
    #[serde(default)]
    temporary_paths: BTreeSet<PathBuf>,
    paths: BTreeMap<PathBuf, PublicationPathRecovery>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case", tag = "state")]
enum PublicationPathState {
    Absent,
    Blob { mode: String, object: String },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct PublicationPathRecovery {
    before: PublicationPathState,
    after: Option<PublicationPathState>,
}

#[derive(Debug)]
struct LocalPublicationGuard {
    git: PathBuf,
    repository: PathBuf,
    marker: PathBuf,
    completed: bool,
}

#[derive(Debug)]
struct AtomicWriteTemporary {
    path: PathBuf,
    renamed: bool,
}

impl Drop for AtomicWriteTemporary {
    fn drop(&mut self) {
        if !self.renamed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn acquire_file_lease(path: &Path, contention: &str) -> Result<File> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create publication lock directory {}", parent.display()))?;
    }
    let lease = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("open projection publication lease {}", path.display()))?;
    match lease.try_lock() {
        Ok(()) => Ok(lease),
        Err(std::fs::TryLockError::WouldBlock) => bail!("{contention}"),
        Err(std::fs::TryLockError::Error(error)) => Err(error)
            .with_context(|| format!("acquire projection publication lease {}", path.display())),
    }
}

fn acquire_state_publication_lease(state_dir: &Path) -> Result<File> {
    fs::create_dir_all(state_dir).with_context(|| {
        format!(
            "create manager state directory for projection publication {}",
            state_dir.display()
        )
    })?;
    let path = state_dir.join("projection-publication-lock");
    acquire_file_lease(
        &path,
        "another projection publication is still active; wait for its deployment and cleanup to finish",
    )
}

fn acquire_repository_publication_lease(git: &Path, repository: &Path) -> Result<File> {
    // Unknown --git-path names resolve inside a linked worktree's private
    // Git directory. Resolve the common directory explicitly so every
    // checkout of this repository contends on the same retained lock inode.
    let common_directory = PathBuf::from(git_stdout(
        git,
        repository,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        "resolve shared repository Git directory",
    )?)
    .canonicalize()
    .context("resolve canonical shared repository Git directory")?;
    let path = common_directory.join("abird-host-manager-publication.lock");
    acquire_file_lease(
        &path,
        "another host-manager publication is mutating this Git repository; wait for it to finish",
    )
}

impl LocalPublicationGuard {
    fn record_postimages(&mut self) -> Result<()> {
        let mut recovery: LocalPublicationRecovery =
            serde_json::from_slice(&fs::read(&self.marker).with_context(|| {
                format!("read local publication marker {}", self.marker.display())
            })?)
            .context("decode local publication marker before recording postimages")?;
        if !matches!(recovery.schema_version, 2..=4) {
            bail!("unsupported local publication recovery schema");
        }
        if git_stdout(
            &self.git,
            &self.repository,
            &["rev-parse", "HEAD"],
            "verify local publication base before recording postimages",
        )? != recovery.base_revision
        {
            bail!("repository revision changed while recording local publication postimages");
        }
        for (path, path_recovery) in &mut recovery.paths {
            path_recovery.after = Some(index_path_state(&self.git, &self.repository, path)?);
        }
        atomic_write(&self.marker, &serde_json::to_vec_pretty(&recovery)?, 0o600)
    }

    fn record_committed_revision(&mut self, revision: &str) -> Result<()> {
        let mut recovery: LocalPublicationRecovery =
            serde_json::from_slice(&fs::read(&self.marker).with_context(|| {
                format!("read local publication marker {}", self.marker.display())
            })?)
            .context("decode local publication marker before recording its commit")?;
        if recovery.schema_version != 4 {
            bail!("local publication commit identity requires recovery schema 4");
        }
        if recovery.committed_revision.is_some() {
            bail!("local publication marker already records a committed revision");
        }
        if recovery.paths.values().any(|path| path.after.is_none()) {
            bail!("local publication marker has no complete planned postimage");
        }
        recovery.committed_revision = Some(revision.to_owned());
        atomic_write(&self.marker, &serde_json::to_vec_pretty(&recovery)?, 0o600)
    }

    fn complete(mut self, expected_revision: &str) -> Result<()> {
        let recovery: LocalPublicationRecovery =
            serde_json::from_slice(&fs::read(&self.marker).with_context(|| {
                format!(
                    "read completed local publication marker {}",
                    self.marker.display()
                )
            })?)
            .context("decode completed local publication marker")?;
        if recovery.committed_revision.as_deref() != Some(expected_revision) {
            bail!("completed local publication marker does not name revision {expected_revision}");
        }
        recover_local_publication(&self.git, &self.repository, &self.marker)?;
        let unrelated = dirty_repository_paths(&self.git, &self.repository)?;
        if !unrelated.is_empty() {
            eprintln!(
                "warning: local publication {expected_revision} completed with unrelated checkout changes: {}",
                unrelated
                    .iter()
                    .map(|path| path.display().to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }
        self.completed = true;
        Ok(())
    }
}

impl Drop for LocalPublicationGuard {
    fn drop(&mut self) {
        if !self.completed
            && let Err(error) = recover_local_publication(&self.git, &self.repository, &self.marker)
        {
            eprintln!("warning: local publication recovery remains pending: {error:#}");
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NixServiceMoveContract {
    schema_version: u32,
    basis_catalog: NixServiceMoveBasisCatalog,
    #[serde(default)]
    controller_reconcile_exclusions: Vec<String>,
    moves: BTreeMap<String, NixServiceMoveContractEntry>,
}

type NixServiceMoveBasisCatalog =
    BTreeMap<String, BTreeMap<String, BTreeMap<String, BTreeMap<String, String>>>>;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NixServiceMoveContractEntry {
    #[serde(rename = "affected_hosts")]
    _affected_hosts: Vec<String>,
    declaration: NixMoveDeclaration,
    #[serde(rename = "basis_sha256")]
    _basis_sha256: String,
    #[serde(rename = "semantic_sha256")]
    _semantic_sha256: String,
    projection: PhaseProjection,
    items: Vec<NixServiceMoveContractItem>,
    services: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NixServiceMoveContractItem {
    id: String,
    service: String,
    from: String,
    to: String,
    basis_sha256: String,
    #[serde(rename = "selected_role")]
    _selected_role: String,
    #[serde(rename = "stable_role")]
    _stable_role: String,
    #[serde(rename = "migration")]
    _migration: serde_json::Value,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NixProjectionSnapshot {
    schema_version: u32,
    repository: NixRepositoryLayout,
    service_moves: NixServiceMoveContract,
    service_placements: NixServicePlacements,
    runtime_plans: Vec<ProjectionRuntimePlan>,
    scope_role_endpoints: BTreeMap<String, BTreeMap<String, NixScopeRoleEndpoint>>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NixRepositoryLayout {
    schema_version: u32,
    owners: Vec<NixRepositoryOwner>,
    scopes: BTreeMap<String, NixRepositoryScope>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NixRepositoryOwner {
    domain: String,
    kind: String,
    path: PathBuf,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NixRepositoryScope {
    owner: String,
    move_directory: PathBuf,
    placement_directory: PathBuf,
}

impl NixRepositoryLayout {
    fn validate(&self) -> Result<()> {
        if self.schema_version != 1 {
            bail!(
                "unsupported projection repository layout schema {}",
                self.schema_version
            );
        }
        let mut owned_paths = BTreeSet::new();
        for owner in &self.owners {
            if owner.domain.is_empty() || owner.kind.is_empty() {
                bail!("projection repository owner has an empty domain or document kind");
            }
            validate_owned_repository_path(&owner.path)?;
            if !owned_paths.insert(owner.path.clone()) {
                bail!(
                    "projection repository path {} has multiple owners",
                    owner.path.display()
                );
            }
        }
        for (scope, layout) in &self.scopes {
            validate_repository_component("projection scope", scope)?;
            validate_repository_component("projection repository owner", &layout.owner)?;
            for directory in [&layout.move_directory, &layout.placement_directory] {
                validate_owned_repository_path(directory)?;
                if directory.extension().is_some() {
                    bail!(
                        "projection repository directory {} must not have a file extension",
                        directory.display()
                    );
                }
            }
            if layout.move_directory == layout.placement_directory {
                bail!("projection scope {scope:?} uses one directory for moves and placements");
            }
        }
        Ok(())
    }

    fn require_owner(&self, domain: &str, kind: &str, path: &Path) -> Result<()> {
        let owner = self
            .owners
            .iter()
            .find(|owner| owner.path == path)
            .with_context(|| {
                format!(
                    "evaluated projection repository contract does not own {}",
                    path.display()
                )
            })?;
        if owner.domain != domain || owner.kind != kind {
            bail!(
                "evaluated projection repository path {} is owned by domain {:?} as {:?}, expected domain {domain:?} as {kind:?}",
                path.display(),
                owner.domain,
                owner.kind
            );
        }
        Ok(())
    }

    fn require_owner_or_unowned(&self, domain: &str, kind: &str, path: &Path) -> Result<()> {
        let Some(owner) = self.owners.iter().find(|owner| owner.path == path) else {
            return Ok(());
        };
        if owner.domain != domain || owner.kind != kind {
            bail!(
                "evaluated projection repository path {} is already owned by domain {:?} as {:?}, expected domain {domain:?} as {kind:?}",
                path.display(),
                owner.domain,
                owner.kind
            );
        }
        Ok(())
    }

    fn require_unowned(&self, path: &Path) -> Result<()> {
        if self.owners.iter().any(|owner| owner.path == path) {
            bail!(
                "evaluated projection repository contract still owns removed path {}",
                path.display()
            );
        }
        Ok(())
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NixRepositoryPathResolution {
    schema_version: u32,
    mutations: Vec<NixRepositoryPathMutation>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NixRepositoryPathMutation {
    domain: String,
    kind: String,
    path: PathBuf,
    #[serde(default)]
    transaction: Option<String>,
    #[serde(default)]
    service: Option<String>,
}

fn load_nix_projection_snapshot(
    nix: &Path,
    repository_root: &Path,
) -> Result<NixProjectionSnapshot> {
    let output = repository_nix_eval_command(
        nix,
        repository_root,
        "--json",
        ".#hostManager.projectionSnapshot",
    )
    .args(["--option", "allow-import-from-derivation", "false"])
    .output()
    .context("start host-manager projection snapshot evaluation")?;
    if !output.status.success() {
        return require_command_success(output, "evaluate host-manager projection snapshot")
            .map(|()| unreachable!());
    }
    let snapshot: NixProjectionSnapshot = serde_json::from_slice(&output.stdout)
        .context("decode host-manager projection snapshot")?;
    if snapshot.schema_version != 1 {
        bail!(
            "unsupported host-manager projection snapshot schema {}",
            snapshot.schema_version
        );
    }
    snapshot.repository.validate()?;
    if snapshot.service_moves.schema_version != 2 {
        bail!(
            "unsupported Nix-native service-move contract schema {}",
            snapshot.service_moves.schema_version
        );
    }
    if snapshot.service_placements.schema_version != 3 {
        bail!(
            "unsupported Nix service-placement schema {}",
            snapshot.service_placements.schema_version
        );
    }
    Ok(snapshot)
}

pub fn evaluated_nix_service_repository_paths(
    nix: &Path,
    repository_root: &Path,
    projection: &PhaseProjection,
) -> Result<NixServiceRepositoryPaths> {
    let identity = nix_move_identity(projection)?;
    resolve_nix_service_repository_paths(nix, repository_root, &identity)
}

fn resolve_nix_service_repository_paths(
    nix: &Path,
    repository_root: &Path,
    identity: &NixMoveIdentity,
) -> Result<NixServiceRepositoryPaths> {
    let request = serde_json::json!({
        "schema_version": 1,
        "scope": identity.scope,
        "owner": identity.repository_owner,
        "transaction": identity.transaction,
        "services": identity.services,
    });
    let expression = format!("resolver: resolver {}", render_nix_value(&request, 0)?);
    let output = repository_nix_eval_command(
        nix,
        repository_root,
        "--json",
        ".#hostManager.serviceMoveRepositoryMutationsFor",
    )
    .args([
        "--apply",
        &expression,
        "--option",
        "allow-import-from-derivation",
        "false",
    ])
    .output()
    .context("start Nix service repository-path resolution")?;
    if !output.status.success() {
        return require_command_success(output, "resolve Nix service repository paths")
            .map(|()| unreachable!());
    }
    let resolved: NixRepositoryPathResolution =
        serde_json::from_slice(&output.stdout).context("decode Nix service repository paths")?;
    if resolved.schema_version != 1 {
        bail!(
            "unsupported Nix repository-path resolution schema {}",
            resolved.schema_version
        );
    }
    let expected_count = identity.services.len() + 1;
    if resolved.mutations.len() != expected_count {
        bail!(
            "Nix repository-path resolution returned {} mutations, expected {expected_count}",
            resolved.mutations.len()
        );
    }
    let mut mutations = resolved.mutations.into_iter();
    let move_mutation = mutations
        .next()
        .context("Nix repository-path resolution omitted its move declaration")?;
    if move_mutation.domain != "serviceMoves" || move_mutation.kind != "service-move" {
        bail!("Nix repository-path resolution did not begin with one service-move mutation");
    }
    if move_mutation.transaction.as_deref() != Some(identity.transaction.as_str())
        || move_mutation.service.is_some()
    {
        bail!("Nix repository-path resolution returned the wrong move transaction identity");
    }
    validate_owned_repository_path(&move_mutation.path)?;
    let mut expected_services = identity.services.clone();
    expected_services.sort();
    let placement_paths = mutations
        .zip(expected_services)
        .map(|(mutation, expected_service)| {
            if mutation.domain != "servicePlacements" || mutation.kind != "service-placement" {
                bail!("Nix repository-path resolution emitted an invalid placement mutation");
            }
            if mutation.service.as_deref() != Some(expected_service.as_str())
                || mutation.transaction.is_some()
            {
                bail!(
                    "Nix repository-path resolution returned the wrong placement service identity"
                );
            }
            validate_owned_repository_path(&mutation.path)?;
            Ok(mutation.path)
        })
        .collect::<Result<Vec<_>>>()?;
    let mut unique_paths = BTreeSet::from([move_mutation.path.clone()]);
    if placement_paths
        .iter()
        .any(|path| !unique_paths.insert(path.clone()))
    {
        bail!("Nix repository-path resolution emitted duplicate paths");
    }
    Ok(NixServiceRepositoryPaths {
        move_path: move_mutation.path,
        placement_paths,
    })
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NixScopeRoleEndpoint {
    host: String,
    host_resource: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProjectionRuntimePlan {
    schema_version: u32,
    adapter: String,
    payload: serde_json::Value,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
enum NixMoveAuthority {
    Controller,
    Local,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
enum NixMovePhase {
    Moved,
    Prepared,
    TargetActive,
    RolledBack,
    AdoptingTarget,
    AdoptingSource,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
enum NixMoveDecision {
    Complete,
    Rollback,
}

impl NixMoveDecision {
    fn parse(value: &str) -> Result<Self> {
        match value {
            "complete" => Ok(Self::Complete),
            "rollback" => Ok(Self::Rollback),
            _ => bail!("Nix service-move adoption decision is unsupported"),
        }
    }

    fn role(self, item: &NixMoveDeclarationItem) -> &str {
        match self {
            Self::Complete => &item.to,
            Self::Rollback => &item.from,
        }
    }

    fn adoption(self) -> (NixMovePhase, NixMovePhase) {
        match self {
            Self::Complete => (NixMovePhase::TargetActive, NixMovePhase::AdoptingTarget),
            Self::Rollback => (NixMovePhase::RolledBack, NixMovePhase::AdoptingSource),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct DesiredMove {
    phase: NixMovePhase,
    generation: u64,
    #[serde(rename = "activationAttempts")]
    activation_attempts: BTreeMap<String, NixMoveActivationAttempts>,
    leases: BTreeMap<String, NixMoveLease>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct NixMoveActivationAttempts {
    source: u64,
    target: u64,
}

impl DesiredMove {
    fn attempts_for(&self, item: &str) -> Result<NixMoveActivationAttempts> {
        self.activation_attempts
            .get(item)
            .cloned()
            .with_context(|| format!("Nix service move has no activation attempts for {item:?}"))
    }
}

/// Runtime retry ordinals are journal facts, not projected identities. Nix
/// consumes these numbers and remains the only code that constructs canonical
/// activation job IDs.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct NativeMovePublicationHints {
    pub activation_attempts: BTreeMap<String, NativeMoveItemActivationAttempts>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NativeMoveItemActivationAttempts {
    pub source: u64,
    pub target: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct NixMoveLease {
    source: Option<u64>,
    target: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct NixMoveDeclarationItem {
    id: String,
    service: String,
    from: String,
    to: String,
    basis_sha256: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct NixMovePrevious {
    contract_sha256: Option<String>,
    repository_revision: Option<String>,
    #[serde(default)]
    activation_requirement: Option<ActivationRequirement>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct NixMoveDeclaration {
    schema_version: u32,
    id: String,
    authority: NixMoveAuthority,
    scope: String,
    items: Vec<NixMoveDeclarationItem>,
    desired: DesiredMove,
    decision: Option<NixMoveDecision>,
    previous: NixMovePrevious,
}

impl NixMoveDeclaration {
    fn render(&self) -> Result<String> {
        render_nix_document(&serde_json::to_value(self)?)
    }
}

#[derive(Clone, Debug)]
pub struct RepositoryPrograms {
    pub nix: PathBuf,
    pub privilege: PathBuf,
    pub nixos_install: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct HostBuildArtifacts {
    pub host: String,
    pub system: PathBuf,
    pub disko_script: Option<PathBuf>,
    pub manager: Option<PathBuf>,
    pub runtime: Vec<PathBuf>,
    pub offline_manifest: Option<PathBuf>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PreparedInstall {
    pub host: String,
    pub root: PathBuf,
    pub system: PathBuf,
    pub disko_script: PathBuf,
    pub boot_mode: Option<BootMode>,
    pub offline_store: Option<PathBuf>,
}

#[derive(Debug)]
pub struct Repository {
    root: PathBuf,
}

impl Repository {
    pub fn discover(explicit: Option<PathBuf>) -> Result<Self> {
        let current = std::env::current_dir().context("resolve current directory")?;
        Self::discover_from(explicit, &current)
    }

    pub fn discover_from(explicit: Option<PathBuf>, current: &Path) -> Result<Self> {
        if let Some(root) = explicit {
            return Self::from_root(root);
        }
        let mut current = current.to_path_buf();
        loop {
            if current.join("flake.nix").is_file()
                && current.join("pkgs/manifest.nix").is_file()
                && current.join("hosts/nixbot.nix").is_file()
            {
                return Self::from_root(current);
            }
            if !current.pop() {
                bail!("could not discover repository root; pass --repo-root");
            }
        }
    }

    pub fn from_root(root: PathBuf) -> Result<Self> {
        let root = root
            .canonicalize()
            .with_context(|| format!("resolve repository root {}", root.display()))?;
        for required in [
            "flake.nix",
            "pkgs/manifest.nix",
            HOSTS_FILE,
            NIXBOT_FILE,
            SECRETS_FILE,
        ] {
            if !root.join(required).is_file() {
                bail!(
                    "{} is not an Abird-compatible repository root",
                    root.display()
                );
            }
        }
        Ok(Self { root })
    }

    /// Require a clean operator checkout whose HEAD is already published on
    /// the controller's branch. The checkout may be behind after an earlier
    /// controller publication, but may never be ahead or divergent.
    pub fn verify_projection_publication_base(&self, git: &Path, branch: &str) -> Result<String> {
        validate_git_branch(branch)?;
        let dirty = git_stdout(
            git,
            self.root(),
            &["status", "--porcelain", "--untracked-files=normal"],
            "inspect operator repository worktree",
        )?;
        if !dirty.is_empty() {
            bail!(
                "operator repository has uncommitted changes; commit or restore them before delegating projection publication"
            );
        }
        let remote_ref = format!("refs/remotes/origin/{branch}");
        let refspec = format!("+refs/heads/{branch}:{remote_ref}");
        run_git(
            git,
            self.root(),
            &["fetch", "--no-tags", "origin", &refspec],
            "refresh authoritative projection branch",
        )?;
        let ancestry = repository_git_command(git, self.root())
            .args(["merge-base", "--is-ancestor", "HEAD", &remote_ref])
            .status()
            .context("compare operator repository with authoritative projection branch")?;
        if !ancestry.success() {
            bail!(
                "operator repository HEAD is ahead of or divergent from origin/{branch}; publish or synchronize local commits before delegating projection publication"
            );
        }
        git_stdout(
            git,
            self.root(),
            &["rev-parse", &remote_ref],
            "resolve authoritative projection revision",
        )
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Resolve the checked-out revision without fetching, refreshing, or
    /// otherwise changing repository state.
    pub fn revision(&self, git: &Path) -> Result<String> {
        git_stdout(
            git,
            self.root(),
            &["rev-parse", "HEAD"],
            "resolve repository revision",
        )
    }

    pub fn nixbot_config_path(&self) -> PathBuf {
        self.root.join(NIXBOT_FILE)
    }

    pub fn runtime_projection_closeouts_path(&self) -> PathBuf {
        self.root.join(RUNTIME_PROJECTION_CLOSEOUTS_FILE)
    }

    pub fn load_phase_projection(&self, projection_id: &str) -> Result<Option<PhaseProjection>> {
        crate::workflow::validate_workflow_id(projection_id)?;
        let path = self.phase_projection_path(projection_id);
        if !path.exists() {
            return Ok(None);
        }
        let projection: PhaseProjection = serde_json::from_reader(
            File::open(&path)
                .with_context(|| format!("open move projection {}", path.display()))?,
        )
        .with_context(|| format!("parse move projection {}", path.display()))?;
        projection.validate()?;
        if projection.projection_id != projection_id {
            bail!("phase projection ID does not match its filename");
        }
        if transaction_spec_for_move_projection(&projection)?.is_some_and(|spec| {
            spec.items
                .iter()
                .any(|item| matches!(item, MoveItem::Service { .. }))
        }) {
            bail!("logical service moves must be authored through Nix, not data/phase-projections");
        }
        Ok(Some(projection))
    }

    fn plan_phase_projection(
        &self,
        projection: &PhaseProjection,
    ) -> Result<(ProjectionWrite, OwnedPathMutation)> {
        projection.validate()?;
        let relative = self.phase_projection_relative_path(&projection.projection_id);
        let path = self.phase_projection_path(&projection.projection_id);
        let mut changed = true;
        if let Some(existing) = self.load_phase_projection(&projection.projection_id)? {
            if existing.intent_kind != projection.intent_kind
                || existing.intent_sha256 != projection.intent_sha256
                || existing.intent != projection.intent
            {
                bail!("refusing to replace projection with different immutable intent");
            }
            if existing.projection_sha256 == projection.projection_sha256 {
                changed = false;
            } else {
                if projection.generation != existing.generation + 1 {
                    bail!(
                        "replacement projection generation must advance from {} to {}",
                        existing.generation,
                        existing.generation + 1
                    );
                }
                if projection.previous_projection_sha256.as_deref()
                    != Some(existing.projection_sha256.as_str())
                {
                    bail!("replacement projection does not bind the previous projection digest");
                }
            }
        } else if projection.generation != 1 || projection.previous_projection_sha256.is_some() {
            bail!(
                "the first published phase projection must be generation 1 without a predecessor"
            );
        }
        let mut bytes = serde_json::to_vec_pretty(projection)?;
        bytes.push(b'\n');
        Ok((
            ProjectionWrite {
                path,
                changed,
                generation: projection.generation,
                projection_sha256: projection.projection_sha256.clone(),
            },
            OwnedPathMutation::Write {
                path: relative,
                contents: bytes,
                mode: 0o644,
            },
        ))
    }

    fn load_runtime_projection_closeouts(&self) -> Result<RuntimeProjectionCloseoutCatalog> {
        let path = self.runtime_projection_closeouts_path();
        if !path.exists() {
            return Ok(RuntimeProjectionCloseoutCatalog::default());
        }
        let catalog: RuntimeProjectionCloseoutCatalog =
            serde_json::from_reader(File::open(&path).with_context(|| {
                format!("open runtime projection closeouts {}", path.display())
            })?)
            .with_context(|| format!("parse runtime projection closeouts {}", path.display()))?;
        if catalog.schema_version != 1 {
            bail!(
                "unsupported runtime projection closeout schema version {}",
                catalog.schema_version
            );
        }
        Ok(catalog)
    }

    pub fn load_projection_closeout(
        &self,
        projection_id: &str,
    ) -> Result<Option<CanonicalProjectionCloseout>> {
        Ok(self
            .load_runtime_projection_closeouts()?
            .closeouts
            .get(projection_id)
            .cloned())
    }

    fn plan_local_projection_authority(&self, projection_id: &str) -> Result<OwnedPathMutation> {
        let mut catalog = self.load_runtime_projection_closeouts()?;
        catalog
            .controller_reconcile_exclusions
            .insert(projection_id.to_owned());
        let mut bytes = serde_json::to_vec_pretty(&catalog)?;
        bytes.push(b'\n');
        Ok(OwnedPathMutation::Write {
            path: PathBuf::from(RUNTIME_PROJECTION_CLOSEOUTS_FILE),
            contents: bytes,
            mode: 0o644,
        })
    }

    fn plan_projection_closeout(
        &self,
        projection: &PhaseProjection,
        decision: &str,
        controller_reconcile: bool,
    ) -> Result<(PathBuf, PathBuf, Vec<OwnedPathMutation>)> {
        projection.validate()?;
        let projection_relative = self.phase_projection_relative_path(&projection.projection_id);
        let projection_path = self.phase_projection_path(&projection.projection_id);
        let published = self
            .load_phase_projection(&projection.projection_id)?
            .context("cannot close a projection that is absent from the repository")?;
        if published.projection_sha256 != projection.projection_sha256 {
            bail!("refusing to close a projection generation that is not currently published");
        }

        let closeout_path = self.runtime_projection_closeouts_path();
        let mut catalog = self.load_runtime_projection_closeouts()?;
        catalog
            .controller_reconcile_exclusions
            .remove(&projection.projection_id);
        if !matches!(decision, "complete" | "rollback") {
            bail!("projection closeout decision is unsupported");
        }
        catalog.closeouts.insert(
            projection.projection_id.clone(),
            CanonicalProjectionCloseout {
                affected_hosts: projection
                    .declarative_effect_hosts()
                    .into_iter()
                    .map(str::to_owned)
                    .collect(),
                controller_reconcile,
                decision: decision.to_owned(),
                projection_sha256: projection.projection_sha256.clone(),
            },
        );
        let mut bytes = serde_json::to_vec_pretty(&catalog)?;
        bytes.push(b'\n');
        Ok((
            closeout_path,
            projection_path,
            vec![
                OwnedPathMutation::Write {
                    path: PathBuf::from(RUNTIME_PROJECTION_CLOSEOUTS_FILE),
                    contents: bytes,
                    mode: 0o644,
                },
                OwnedPathMutation::Remove {
                    path: projection_relative,
                },
            ],
        ))
    }

    #[cfg(test)]
    fn write_projection_closeout(
        &self,
        projection: &PhaseProjection,
        decision: &str,
        controller_reconcile: bool,
    ) -> Result<(PathBuf, PathBuf)> {
        let (placement, projection, mutations) =
            self.plan_projection_closeout(projection, decision, controller_reconcile)?;
        apply_owned_path_mutations(self.root(), &mutations)?;
        Ok((placement, projection))
    }

    fn phase_projection_relative_path(&self, projection_id: &str) -> PathBuf {
        PathBuf::from("data/phase-projections").join(format!("{projection_id}.json"))
    }

    fn phase_projection_path(&self, projection_id: &str) -> PathBuf {
        self.root
            .join(self.phase_projection_relative_path(projection_id))
    }

    pub fn generate(
        &self,
        host_name: &str,
        record: ManagedHost,
        system_module: Option<&Path>,
        force: bool,
    ) -> Result<RepositoryChange> {
        let existing = self.load_optional_marker(host_name)?;
        let physical = if record.system != ManagedHostSystem::Incus && system_module.is_none() {
            existing.as_ref().and_then(|marker| marker.physical.clone())
        } else {
            None
        };
        let system_module = if record.system == ManagedHostSystem::Incus {
            if system_module.is_some() {
                bail!("Incus host generation does not accept a system module");
            }
            None
        } else if let Some(source) = system_module {
            let source = source
                .canonicalize()
                .with_context(|| format!("resolve system module {}", source.display()))?;
            Some(
                fs::read(&source)
                    .with_context(|| format!("read supplied system module {}", source.display()))?,
            )
        } else if existing
            .as_ref()
            .is_some_and(|marker| marker.record.system != ManagedHostSystem::Incus)
        {
            let current = self.root.join("hosts").join(host_name).join("sys.nix");
            Some(fs::read(&current).with_context(|| {
                format!("preserve existing system module {}", current.display())
            })?)
        } else {
            Some(minimal_system_module().as_bytes().to_vec())
        };
        self.generate_rendered(host_name, record, system_module.as_deref(), physical, force)
    }

    pub fn generate_physical(
        &self,
        host_name: &str,
        record: ManagedHost,
        request: PhysicalLayoutRequest,
        hardware: &HardwareProjection,
        fresh_storage_ids: bool,
        force: bool,
    ) -> Result<RepositoryChange> {
        if record.system == ManagedHostSystem::Incus {
            bail!("Incus hosts cannot use a physical disk layout");
        }
        if fresh_storage_ids && !force {
            bail!("--fresh-storage-ids requires an explicit forced regeneration");
        }
        let existing = self.load_optional_marker(host_name)?;
        let layout = PhysicalLayout::resolve(
            request,
            existing
                .as_ref()
                .and_then(|marker| marker.physical.as_ref()),
            fresh_storage_ids,
        )?;
        let rendered = layout.render_system_module(hardware);
        self.generate_rendered(
            host_name,
            record,
            Some(rendered.as_bytes()),
            Some(layout),
            force,
        )
    }

    fn generate_rendered(
        &self,
        host_name: &str,
        record: ManagedHost,
        system_module: Option<&[u8]>,
        physical: Option<PhysicalLayout>,
        force: bool,
    ) -> Result<RepositoryChange> {
        validate_host_name(host_name)?;
        validate_record(&record)?;
        self.require_machine_identity(host_name)?;
        let host_directory = self.root.join("hosts").join(host_name);
        if host_directory.exists() && !force {
            bail!("host directory already exists; pass --force only for a manager-owned host");
        }
        if host_directory.exists() && !host_directory.join(MARKER_NAME).is_file() {
            bail!(
                "refusing to replace non-managed host directory {}",
                host_directory.display()
            );
        }

        let mut changes = vec![
            (
                self.root.join(HOSTS_FILE),
                update_hosts_default(
                    &fs::read_to_string(self.root.join(HOSTS_FILE))?,
                    host_name,
                    &record,
                    force,
                )?,
            ),
            (
                self.root.join(NIXBOT_FILE),
                update_nixbot(
                    &fs::read_to_string(self.root.join(NIXBOT_FILE))?,
                    host_name,
                    &record,
                    force,
                )?,
            ),
            (
                self.root.join(SECRETS_FILE),
                update_secrets(
                    &fs::read_to_string(self.root.join(SECRETS_FILE))?,
                    host_name,
                    force,
                )?,
            ),
        ];
        if let Some(incus) = &record.incus {
            let parent_file = self
                .root
                .join("hosts")
                .join(&incus.parent)
                .join("incus.nix");
            if !parent_file.is_file() {
                bail!(
                    "Incus parent module does not exist: {}",
                    parent_file.display()
                );
            }
            changes.push((
                parent_file.clone(),
                update_incus_parent(&fs::read_to_string(&parent_file)?, host_name, incus, force)?,
            ));
        }

        let temporary = self.root.join("tmp").join(format!(
            "abird-host-manager-generate-{}-{}",
            std::process::id(),
            host_name
        ));
        if temporary.exists() {
            fs::remove_dir_all(&temporary)?;
        }
        fs::create_dir_all(&temporary)?;
        let marker = VersionedHostMarker {
            version: MARKER_VERSION,
            record: record.clone(),
            physical,
        };
        write_private(
            &temporary.join(MARKER_NAME),
            &serde_json::to_vec_pretty(&marker)?,
            0o600,
        )?;
        fs::write(temporary.join("default.nix"), default_module(&record))?;
        if record.system == ManagedHostSystem::Incus {
            fs::write(temporary.join("packages.nix"), "{...}: {}\n")?;
            fs::write(temporary.join("users.nix"), "{...}: {}\n")?;
        } else if let Some(source) = system_module {
            fs::write(temporary.join("sys.nix"), source)?;
        } else {
            bail!("non-Incus host generation requires a system module");
        }

        if host_directory.exists() {
            fs::remove_dir_all(&host_directory)?;
        }
        fs::rename(&temporary, &host_directory)?;
        for (path, contents) in &changes {
            atomic_write(path, contents.as_bytes(), 0o644)?;
        }
        Ok(RepositoryChange {
            host: host_name.to_owned(),
            files: changes.into_iter().map(|(path, _)| path).collect(),
            host_directory,
            changed: true,
        })
    }

    pub fn delete(&self, host_name: &str) -> Result<RepositoryChange> {
        validate_host_name(host_name)?;
        let host_directory = self.root.join("hosts").join(host_name);
        if !host_directory.join(MARKER_NAME).is_file() {
            bail!(
                "host is not owned by abird-host-manager: {}",
                host_directory.display()
            );
        }
        let mut files = Vec::new();
        for relative in [HOSTS_FILE, NIXBOT_FILE, SECRETS_FILE] {
            let path = self.root.join(relative);
            let original = fs::read_to_string(&path)?;
            let updated = remove_owned_block(&original, host_name)?;
            if updated != original {
                atomic_write(&path, updated.as_bytes(), 0o644)?;
                files.push(path);
            }
        }
        if let Ok(marker) = self.load_marker(host_name)
            && let Some(incus) = marker.record.incus
        {
            let path = self.root.join("hosts").join(incus.parent).join("incus.nix");
            let original = fs::read_to_string(&path)?;
            let updated = remove_owned_block(&original, host_name)?;
            if updated != original {
                atomic_write(&path, updated.as_bytes(), 0o644)?;
                files.push(path);
            }
        }
        fs::remove_dir_all(&host_directory)?;
        Ok(RepositoryChange {
            host: host_name.to_owned(),
            files,
            host_directory,
            changed: true,
        })
    }

    pub fn build(
        &self,
        programs: &RepositoryPrograms,
        host_name: &str,
        store: Option<&Path>,
    ) -> Result<()> {
        self.build_artifacts(programs, host_name, store)?;
        Ok(())
    }

    pub fn build_artifacts(
        &self,
        programs: &RepositoryPrograms,
        host_name: &str,
        store: Option<&Path>,
    ) -> Result<HostBuildArtifacts> {
        validate_host_name(host_name)?;
        let nix = Nix::new(&programs.nix)?;
        let Some(store) = store else {
            let system = nix.build_store_path(&self.root, &system_installable(host_name), None)?;
            return Ok(HostBuildArtifacts {
                host: host_name.to_owned(),
                system: system.as_path().to_path_buf(),
                disko_script: None,
                manager: None,
                runtime: Vec::new(),
                offline_manifest: None,
            });
        };

        let offline = OfflineStore::new(store.to_path_buf())?;
        nix.archive_flake(&self.root, offline.cache())?;
        offline.require_initialized()?;

        let system = nix.build_store_path(&self.root, &system_installable(host_name), None)?;
        let disko_script = nix.build_store_path(&self.root, &disko_installable(host_name), None)?;
        let manager = nix.build_store_path(&self.root, ".#abird-host-manager", None)?;
        let runtime = [
            format!(".#nixosConfigurations.{host_name}.pkgs.nix"),
            format!(".#nixosConfigurations.{host_name}.pkgs.nixos-install-tools"),
        ]
        .iter()
        .map(|installable| nix.build_store_path(&self.root, installable, None))
        .collect::<Result<Vec<_>>>()?;
        let mut roots = vec![system.clone(), disko_script.clone(), manager.clone()];
        roots.extend(runtime.iter().cloned());
        nix.copy_store_paths(&roots, offline.cache())?;

        let manifest =
            OfflineHostManifest::new(host_name, &system, &disko_script, &manager, &runtime);
        let manifest_path = offline.publish(&manifest)?;
        Ok(HostBuildArtifacts {
            host: host_name.to_owned(),
            system: system.as_path().to_path_buf(),
            disko_script: Some(disko_script.as_path().to_path_buf()),
            manager: Some(manager.as_path().to_path_buf()),
            runtime: runtime
                .iter()
                .map(|path| path.as_path().to_path_buf())
                .collect(),
            offline_manifest: Some(manifest_path),
        })
    }

    pub fn prepare_live_install(
        &self,
        programs: &RepositoryPrograms,
        host_name: &str,
        root: &Path,
        store: Option<&Path>,
    ) -> Result<PreparedInstall> {
        validate_host_name(host_name)?;
        let root = absolute_non_root(root, "install root")?;
        if root != Path::new("/mnt") {
            bail!(
                "live installation currently requires --root /mnt because the host disko script is compiled for /mnt"
            );
        }
        let nix = Nix::new(&programs.nix)?;
        let offline = store
            .map(|store| OfflineStore::new(store.to_path_buf()))
            .transpose()?;
        let manifest = offline
            .as_ref()
            .map(|store| store.load(host_name))
            .transpose()?;
        let cache = offline.as_ref().map(OfflineStore::cache);
        // Resolve both exact closures before any disk mutation. With a cache,
        // Nix is explicitly offline and has no fallback substituter.
        let disko_script =
            nix.build_store_path(&self.root, &disko_installable(host_name), cache)?;
        let system = nix.build_store_path(&self.root, &system_installable(host_name), cache)?;
        if let Some(manifest) = manifest {
            if manifest.disko_script != disko_script.as_path() {
                bail!("offline cache disko script does not match the current host configuration");
            }
            if manifest.system != system.as_path() {
                bail!("offline cache system does not match the current host configuration");
            }
        }
        let boot_mode = self
            .load_optional_marker(host_name)?
            .and_then(|marker| marker.physical.map(|layout| layout.boot_mode));
        if boot_mode == Some(BootMode::Efi) && !Path::new("/sys/firmware/efi/efivars").is_dir() {
            bail!("host uses EFI boot but this live environment has no EFI variables");
        }
        Ok(PreparedInstall {
            host: host_name.to_owned(),
            root: root.to_path_buf(),
            system: system.as_path().to_path_buf(),
            disko_script: disko_script.as_path().to_path_buf(),
            boot_mode,
            offline_store: store.map(Path::to_path_buf),
        })
    }

    pub fn execute_prepared_install(
        &self,
        programs: &RepositoryPrograms,
        prepared: &PreparedInstall,
        wipe_disks: bool,
    ) -> Result<()> {
        if !wipe_disks {
            bail!("live install is destructive; pass --wipe-disks with --execute");
        }
        if prepared.root != Path::new("/mnt") {
            bail!("prepared disko scripts may only install below /mnt");
        }
        let privilege = Privilege::new(&programs.privilege)?;
        DiskoScript::new(prepared.disko_script.clone())?
            .destroy_format_mount(&privilege, &self.root)?;
        NixosInstall::new(&programs.nixos_install)?.install_system(
            &privilege,
            &self.root,
            &prepared.root,
            &prepared.system,
        )
    }

    pub fn live_install_with_store(
        &self,
        programs: &RepositoryPrograms,
        host_name: &str,
        root: &Path,
        store: Option<&Path>,
        wipe_disks: bool,
    ) -> Result<()> {
        if !wipe_disks {
            bail!("live install is destructive; pass --wipe-disks with --execute");
        }
        let prepared = self.prepare_live_install(programs, host_name, root, store)?;
        self.execute_prepared_install(programs, &prepared, true)
    }

    pub fn live_install(
        &self,
        programs: &RepositoryPrograms,
        host_name: &str,
        root: &Path,
        wipe_disks: bool,
    ) -> Result<()> {
        self.live_install_with_store(programs, host_name, root, None, wipe_disks)
    }

    fn load_optional_marker(&self, host_name: &str) -> Result<Option<VersionedHostMarker>> {
        validate_host_name(host_name)?;
        let marker = self.root.join("hosts").join(host_name).join(MARKER_NAME);
        if !marker.is_file() {
            return Ok(None);
        }
        self.load_marker(host_name).map(Some)
    }

    fn load_marker(&self, host_name: &str) -> Result<VersionedHostMarker> {
        let marker = self.root.join("hosts").join(host_name).join(MARKER_NAME);
        let parsed: HostMarker = serde_json::from_reader(
            File::open(&marker)
                .with_context(|| format!("open host marker {}", marker.display()))?,
        )
        .with_context(|| format!("parse host marker {}", marker.display()))?;
        let parsed = parsed.into_versioned();
        if parsed.version == 0 || parsed.version > MARKER_VERSION {
            bail!("unsupported host marker version {}", parsed.version);
        }
        Ok(parsed)
    }

    fn require_machine_identity(&self, host_name: &str) -> Result<()> {
        let base = self
            .root
            .join("data/secrets/globals/machine")
            .join(host_name);
        let public = base.with_extension("key.pub");
        let encrypted = base.with_extension("key.age");
        if !public.is_file() || !encrypted.is_file() {
            bail!(
                "machine identity is not ready for {host_name:?}; create {} and {} with the repository age-secrets workflow first",
                public.display(),
                encrypted.display()
            );
        }
        Ok(())
    }
}

impl ProjectionPublisher {
    /// Refresh a manager-owned checkout below its durable state directory.
    /// The operator checkout is used only to discover the authoritative remote.
    pub fn prepare(
        source_repository: &Repository,
        authority: &WorkflowStore,
        state_dir: &Path,
        branch: &str,
        git: PathBuf,
        nix: PathBuf,
        publish_git_ssh_command: Option<String>,
    ) -> Result<Self> {
        validate_git_branch(branch)?;
        if authority.root().canonicalize().with_context(|| {
            format!(
                "resolve projection authority root {}",
                authority.root().display()
            )
        })? != state_dir
            .canonicalize()
            .with_context(|| format!("resolve manager state directory {}", state_dir.display()))?
        {
            bail!("projection publisher authority does not own the manager state directory");
        }
        let publication_lease = acquire_state_publication_lease(state_dir)?;
        let remote = git_stdout(
            &git,
            source_repository.root(),
            &["remote", "get-url", "origin"],
            "resolve authoritative repository remote",
        )?;
        let checkout = state_dir.join("projection-repository");
        fs::create_dir_all(state_dir)?;
        if !checkout.exists() {
            let mut command = Command::new(&git);
            clear_git_repository_environment(&mut command);
            let output = command
                .args(["clone", "--single-branch", "--branch", branch, "--"])
                .arg(&remote)
                .arg(&checkout)
                .output()
                .context("start manager projection repository clone")?;
            require_command_success(output, "clone manager projection repository")?;
        }
        let checkout = checkout
            .canonicalize()
            .context("resolve manager projection repository")?;
        let expected_parent = state_dir
            .canonicalize()
            .context("resolve manager state directory")?;
        if !checkout.starts_with(&expected_parent) || checkout == expected_parent {
            bail!("projection checkout must be owned below the manager state directory");
        }
        let checkout_remote = git_stdout(
            &git,
            &checkout,
            &["remote", "get-url", "origin"],
            "resolve projection checkout remote",
        )?;
        if checkout_remote != remote {
            bail!("manager projection checkout remote does not match authoritative repository");
        }
        let current_branch = git_stdout(
            &git,
            &checkout,
            &["branch", "--show-current"],
            "resolve projection checkout branch",
        )?;
        if current_branch != branch {
            bail!(
                "manager projection checkout is on branch {current_branch:?}, expected {branch:?}"
            );
        }
        run_git(
            &git,
            &checkout,
            &["fetch", "--prune", "origin", branch],
            "fetch authoritative projection branch",
        )?;
        // This checkout is created below the manager state directory and is
        // never exposed as an operator worktree. Reconstruct it from the
        // authoritative branch on every attempt so an interrupted write,
        // stage, commit, or non-fast-forward push is automatically recoverable.
        run_git(
            &git,
            &checkout,
            &["reset", "--hard", &format!("origin/{branch}")],
            "restore manager projection checkout",
        )?;
        run_git(
            &git,
            &checkout,
            &["clean", "-fd"],
            "remove interrupted manager projection artifacts",
        )?;
        // Master publishes the declaration before runtime effects begin. The
        // fetched authoritative branch is therefore the release drain source,
        // including when the controller journal is unavailable locally.
        let publication_base = git_stdout(
            &git,
            &checkout,
            &["rev-parse", "HEAD"],
            "resolve prepared projection publication base",
        )?;
        Ok(Self {
            repository: Repository::from_root(checkout)?,
            git,
            nix,
            branch: branch.to_owned(),
            publish_git_ssh_command,
            mode: ProjectionPublicationMode::Remote,
            local_recovery_path: None,
            publication_base: RefCell::new(publication_base),
            _state_publication_lease: publication_lease,
            _repository_publication_lease: None,
        })
    }

    /// Use the invoking clean checkout as both the source and publication
    /// repository. This mode commits locally and never contacts or updates a
    /// Git remote.
    pub fn prepare_local(
        source_repository: &Repository,
        authority: &WorkflowStore,
        state_dir: &Path,
        branch: &str,
        git: PathBuf,
        nix: PathBuf,
    ) -> Result<Self> {
        validate_git_branch(branch)?;
        if authority.root().canonicalize().with_context(|| {
            format!(
                "resolve projection authority root {}",
                authority.root().display()
            )
        })? != state_dir
            .canonicalize()
            .with_context(|| format!("resolve manager state directory {}", state_dir.display()))?
        {
            bail!("projection publisher authority does not own the manager state directory");
        }
        // The checkout lock is deliberately acquired before the state lock.
        // All local publishers use this order, preventing two state roots from
        // interleaving writes, staging, and commits in one invoking worktree.
        let repository_publication_lease =
            acquire_repository_publication_lease(&git, source_repository.root())?;
        let publication_lease = acquire_state_publication_lease(state_dir)?;
        let branch_name = git_stdout(
            &git,
            source_repository.root(),
            &["branch", "--show-current"],
            "resolve local publication branch",
        )?;
        if branch_name != branch {
            bail!("local publication checkout is on branch {branch_name:?}, expected {branch:?}");
        }
        let recovery_path = state_dir.join("local-publication-recovery.json");
        recover_local_publication(&git, source_repository.root(), &recovery_path)?;
        let dirty = git_stdout(
            &git,
            source_repository.root(),
            &["status", "--porcelain", "--untracked-files=normal"],
            "inspect local publication checkout",
        )?;
        if !dirty.is_empty() {
            bail!(
                "--local requires a clean repository checkout before host-manager creates its commit"
            );
        }
        let publication_base = git_stdout(
            &git,
            source_repository.root(),
            &["rev-parse", "HEAD"],
            "resolve prepared local publication base",
        )?;
        Ok(Self {
            repository: Repository::from_root(source_repository.root().to_path_buf())?,
            git,
            nix,
            branch: branch.to_owned(),
            publish_git_ssh_command: None,
            mode: ProjectionPublicationMode::Local,
            local_recovery_path: Some(recovery_path),
            publication_base: RefCell::new(publication_base),
            _state_publication_lease: publication_lease,
            _repository_publication_lease: Some(repository_publication_lease),
        })
    }

    pub fn repository(&self) -> &Repository {
        &self.repository
    }

    pub fn revision(&self) -> Result<String> {
        git_stdout(
            &self.git,
            self.repository.root(),
            &["rev-parse", "HEAD"],
            "resolve projection repository revision",
        )
    }

    pub fn mode(&self) -> ProjectionPublicationMode {
        self.mode
    }

    pub fn pushed(&self) -> bool {
        self.mode == ProjectionPublicationMode::Remote
    }

    fn require_exact_clean_revision(&self, expected: &str, operation: &str) -> Result<()> {
        self.require_checked_out_publication_branch(operation)?;
        let actual = self.revision()?;
        if actual != expected {
            bail!(
                "{operation} expected repository revision {expected}, but HEAD is {actual}; refusing to include unrelated commits"
            );
        }
        let dirty = git_stdout(
            &self.git,
            self.repository.root(),
            &["status", "--porcelain", "--untracked-files=normal"],
            "inspect publication repository immediately before mutation",
        )?;
        if !dirty.is_empty() {
            bail!("{operation} requires a clean repository immediately before mutation");
        }
        Ok(())
    }

    fn require_checked_out_publication_branch(&self, operation: &str) -> Result<()> {
        let expected = format!("refs/heads/{}", self.branch);
        let output = repository_git_command(&self.git, self.repository.root())
            .args(["symbolic-ref", "-q", "HEAD"])
            .output()
            .with_context(|| format!("start {operation} branch verification"))?;
        if !output.status.success() {
            bail!("{operation} requires HEAD to remain attached to {expected}");
        }
        let actual = String::from_utf8(output.stdout)
            .with_context(|| format!("decode {operation} checked-out branch"))?
            .trim()
            .to_owned();
        if actual != expected {
            bail!(
                "{operation} requires HEAD to remain attached to {expected}, but it is attached to {actual}"
            );
        }
        Ok(())
    }

    fn expected_publication_base(&self) -> String {
        self.publication_base.borrow().clone()
    }

    fn advance_publication_base(&self, expected: &str, revision: &str) -> Result<()> {
        let mut base = self.publication_base.borrow_mut();
        if base.as_str() != expected {
            bail!(
                "projection publication lineage changed from expected base {expected} to {}; refusing to advance it",
                base
            );
        }
        *base = revision.to_owned();
        Ok(())
    }

    fn stage_owned_publication_paths(
        &self,
        expected_base: &str,
        mutations: &[OwnedPathMutation],
        recovery: Option<&mut LocalPublicationGuard>,
        operation: &str,
    ) -> Result<()> {
        if mutations.is_empty() {
            bail!("{operation} has no owned repository paths");
        }
        let owned = mutations
            .iter()
            .map(|mutation| mutation.path().to_path_buf())
            .collect::<BTreeSet<_>>();
        if owned.len() != mutations.len() {
            bail!("{operation} contains duplicate owned repository paths");
        }
        let mut expected_changed = BTreeSet::new();
        for mutation in mutations {
            let path = mutation.path();
            validate_owned_repository_path(path)?;
            run_git_path(
                &self.git,
                self.repository.root(),
                &["add", "--"],
                path,
                operation,
            )?;
            let planned = planned_mutation_state(&self.git, self.repository.root(), mutation)?;
            if index_path_state(&self.git, self.repository.root(), path)? != planned {
                bail!(
                    "{operation} staged state for {} does not match its planned postimage",
                    path.display()
                );
            }
            if tree_path_state(&self.git, self.repository.root(), expected_base, path)? != planned {
                expected_changed.insert(path.to_path_buf());
            }
        }
        let staged = git_path_set(
            &self.git,
            self.repository.root(),
            &["diff", "--cached", "--name-only", "-z", "--"],
            "inspect exact staged publication paths",
        )?;
        if staged != expected_changed {
            bail!("{operation} staged paths do not exactly match the planned repository mutations");
        }
        if let Some(recovery) = recovery {
            recovery.record_postimages()?;
        }
        Ok(())
    }

    fn commit_owned_publication_paths(
        &self,
        expected_parent: &str,
        paths: &[PathBuf],
        message: &str,
        operation: &str,
    ) -> Result<String> {
        let owned = paths.iter().cloned().collect::<BTreeSet<_>>();
        if owned.is_empty() || owned.len() != paths.len() {
            bail!("{operation} requires distinct owned repository paths");
        }
        for path in &owned {
            validate_owned_repository_path(path)?;
        }
        self.require_exact_owned_revision(expected_parent, &owned, operation)?;
        let staged = git_path_set(
            &self.git,
            self.repository.root(),
            &["diff", "--cached", "--name-only", "-z", "--"],
            "inspect staged publication commit",
        )?;
        if !staged.is_subset(&owned) {
            bail!("{operation} found staged changes outside its owned repository paths");
        }
        let unstaged = git_path_set(
            &self.git,
            self.repository.root(),
            &["diff", "--name-only", "-z", "--"],
            "inspect unstaged publication commit paths",
        )?;
        if !unstaged.is_empty() {
            bail!("{operation} found repository changes after staging");
        }
        let dirty = dirty_repository_paths(&self.git, self.repository.root())?;
        if staged.is_empty() {
            if !dirty.is_empty() {
                bail!("{operation} found uncommitted owned repository changes");
            }
            return Ok(expected_parent.to_owned());
        }

        // Capture the exact staged tree before creating the commit. Updating
        // the checked-out branch with an old-value constraint makes the
        // captured parent a compare-and-swap boundary: a concurrent ref
        // advance cannot silently become part of this publication's lineage.
        let tree = git_stdout(
            &self.git,
            self.repository.root(),
            &["write-tree"],
            "write publication commit tree",
        )?;
        let changed = git_path_set(
            &self.git,
            self.repository.root(),
            &[
                "diff-tree",
                "--no-commit-id",
                "--name-only",
                "-r",
                "-z",
                expected_parent,
                &tree,
            ],
            "inspect publication commit tree",
        )?;
        if changed != staged || !changed.is_subset(&owned) {
            bail!("{operation} commit tree does not contain exactly its staged owned paths");
        }
        self.require_exact_owned_revision(expected_parent, &owned, operation)?;
        let current_tree = git_stdout(
            &self.git,
            self.repository.root(),
            &["write-tree"],
            "recheck publication commit tree",
        )?;
        if current_tree != tree {
            bail!("{operation} index changed while preparing its commit");
        }

        let mut command = repository_git_command(&self.git, self.repository.root());
        let output = command
            .args([
                "-c",
                "user.name=abird-host-manager",
                "-c",
                "user.email=host-manager@abird.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit-tree",
                &tree,
                "-p",
                expected_parent,
                "-m",
                message,
            ])
            .output()
            .with_context(|| format!("start {operation}"))?;
        if !output.status.success() {
            require_command_success(output, operation)?;
            unreachable!();
        }
        let revision = String::from_utf8(output.stdout)
            .with_context(|| format!("decode {operation} revision"))?
            .trim()
            .to_owned();
        if revision.is_empty() {
            bail!("{operation} produced no commit revision");
        }
        self.update_checked_out_branch(&revision, expected_parent, operation)?;
        self.require_exact_clean_revision(&revision, operation)?;
        Ok(revision)
    }

    fn update_checked_out_branch(
        &self,
        revision: &str,
        expected_parent: &str,
        operation: &str,
    ) -> Result<()> {
        self.update_checked_out_branch_observed(revision, expected_parent, operation, || Ok(()))
    }

    fn update_checked_out_branch_observed(
        &self,
        revision: &str,
        expected_parent: &str,
        operation: &str,
        after_update: impl FnOnce() -> Result<()>,
    ) -> Result<()> {
        self.require_checked_out_publication_branch(operation)?;
        let branch_ref = format!("refs/heads/{}", self.branch);
        let expected_head = format!("refs/heads/{}", self.branch);
        let checked_transaction = format!(
            "start\noption no-deref\nsymref-verify HEAD {expected_head}\nupdate {branch_ref} {revision} {expected_parent}\nprepare\ncommit\n"
        );
        let checked_output = run_git_reference_transaction(
            &self.git,
            self.repository.root(),
            &checked_transaction,
            operation,
        )?;
        if !checked_output.status.success() {
            let diagnostic = String::from_utf8_lossy(&checked_output.stderr);
            let unsupported_combination = diagnostic.contains("multiple updates for 'HEAD'")
                || diagnostic.contains("unknown command: symref-verify")
                || diagnostic.contains("unknown command 'symref-verify'")
                || diagnostic.contains("symref-verify: cannot operate with deref mode");
            if !unsupported_combination {
                return require_command_success(checked_output, operation);
            }
            // Git versions that reject a symbolic-HEAD verification alongside
            // an update to its referent still get the old-OID CAS. The
            // post-check below compensates by reverting that exact update if
            // HEAD moved in the intervening window.
            self.require_checked_out_publication_branch(operation)?;
            let transaction = format!(
                "start\nupdate {branch_ref} {revision} {expected_parent}\nprepare\ncommit\n"
            );
            let output = run_git_reference_transaction(
                &self.git,
                self.repository.root(),
                &transaction,
                operation,
            )?;
            require_command_success(output, operation)?;
        }
        let post_update =
            after_update().and_then(|()| self.require_checked_out_publication_branch(operation));
        if let Err(post_update_error) = post_update {
            let rollback = format!(
                "start\nupdate {branch_ref} {expected_parent} {revision}\nprepare\ncommit\n"
            );
            let rollback_output = run_git_reference_transaction(
                &self.git,
                self.repository.root(),
                &rollback,
                "revert publication branch after checkout changed",
            )?;
            require_command_success(
                rollback_output,
                "revert publication branch after checkout changed",
            )?;
            return Err(post_update_error).context(
                "publication reference update did not complete cleanly; reverted the publication branch",
            );
        }
        Ok(())
    }

    fn require_exact_owned_revision(
        &self,
        expected: &str,
        owned: &BTreeSet<PathBuf>,
        operation: &str,
    ) -> Result<()> {
        self.require_checked_out_publication_branch(operation)?;
        let actual = self.revision()?;
        if actual != expected {
            bail!(
                "{operation} expected repository revision {expected}, but HEAD is {actual}; refusing to include unrelated commits"
            );
        }
        let dirty = dirty_repository_paths(&self.git, self.repository.root())?;
        if !dirty.is_subset(owned) {
            bail!("{operation} found repository changes outside its owned paths");
        }
        Ok(())
    }

    #[cfg(test)]
    fn begin_local_publication(
        &self,
        paths: impl IntoIterator<Item = PathBuf>,
    ) -> Result<Option<LocalPublicationGuard>> {
        let expected = self.expected_publication_base();
        self.require_exact_clean_revision(&expected, "projection publication transaction")?;
        let Some(marker) = &self.local_recovery_path else {
            return Ok(None);
        };
        let paths = paths.into_iter().collect::<BTreeSet<_>>();
        if paths.is_empty() {
            bail!("local publication must own at least one repository path");
        }
        for path in &paths {
            validate_owned_repository_path(path)?;
        }
        if marker.exists() {
            bail!("a prior local publication recovery marker is still present");
        }
        let base_revision = expected;
        let paths = paths
            .into_iter()
            .map(|path| {
                let before =
                    tree_path_state(&self.git, self.repository.root(), &base_revision, &path)?;
                Ok((
                    path,
                    PublicationPathRecovery {
                        before,
                        after: None,
                    },
                ))
            })
            .collect::<Result<BTreeMap<_, _>>>()?;
        let recovery = LocalPublicationRecovery {
            schema_version: 4,
            repository: self.repository.root().canonicalize().with_context(|| {
                format!(
                    "resolve local publication repository {}",
                    self.repository.root().display()
                )
            })?,
            branch: self.branch.clone(),
            base_revision,
            committed_revision: None,
            temporary_paths: BTreeSet::new(),
            paths,
        };
        atomic_write(marker, &serde_json::to_vec_pretty(&recovery)?, 0o600)?;
        Ok(Some(LocalPublicationGuard {
            git: self.git.clone(),
            repository: self.repository.root().to_path_buf(),
            marker: marker.clone(),
            completed: false,
        }))
    }

    fn apply_owned_publication(
        &self,
        domain: &str,
        mutations: Vec<OwnedPathMutation>,
    ) -> Result<Option<LocalPublicationGuard>> {
        self.apply_owned_publication_with_observer(domain, mutations, |_| Ok(()))
    }

    fn apply_owned_publication_with_observer(
        &self,
        domain: &str,
        mutations: Vec<OwnedPathMutation>,
        mut after_mutation: impl FnMut(usize) -> Result<()>,
    ) -> Result<Option<LocalPublicationGuard>> {
        if mutations.is_empty() {
            bail!("projection domain {domain:?} produced no repository mutations");
        }
        let expected = self.expected_publication_base();
        self.require_exact_clean_revision(&expected, &format!("{domain} owned-path publication"))?;
        let paths = mutations
            .iter()
            .map(|mutation| mutation.path().to_path_buf())
            .collect::<BTreeSet<_>>();
        if paths.len() != mutations.len() {
            bail!("projection domain {domain:?} produced duplicate repository paths");
        }
        for path in &paths {
            validate_owned_repository_path(path)?;
        }
        let mut recovery = if let Some(marker) = &self.local_recovery_path {
            if marker.exists() {
                bail!("a prior local publication recovery marker is still present");
            }
            let path_states = mutations
                .iter()
                .map(|mutation| {
                    let path = mutation.path().to_path_buf();
                    let before =
                        tree_path_state(&self.git, self.repository.root(), &expected, &path)?;
                    let after = match mutation {
                        OwnedPathMutation::Write { contents, mode, .. } => {
                            PublicationPathState::Blob {
                                mode: if mode & 0o111 == 0 {
                                    "100644".to_owned()
                                } else {
                                    "100755".to_owned()
                                },
                                object: git_blob_id(&self.git, self.repository.root(), contents)?,
                            }
                        }
                        OwnedPathMutation::Remove { .. } => PublicationPathState::Absent,
                    };
                    Ok((
                        path,
                        PublicationPathRecovery {
                            before,
                            after: Some(after),
                        },
                    ))
                })
                .collect::<Result<BTreeMap<_, _>>>()?;
            let temporary_paths = mutations
                .iter()
                .filter_map(|mutation| match mutation {
                    OwnedPathMutation::Write { path, .. } => {
                        Some(owned_atomic_temporary_path(path))
                    }
                    OwnedPathMutation::Remove { .. } => None,
                })
                .collect::<Result<BTreeSet<_>>>()?;
            let marker_state = LocalPublicationRecovery {
                schema_version: 4,
                repository: self.repository.root().canonicalize().with_context(|| {
                    format!(
                        "resolve local publication repository {}",
                        self.repository.root().display()
                    )
                })?,
                branch: self.branch.clone(),
                base_revision: expected.clone(),
                committed_revision: None,
                temporary_paths,
                paths: path_states,
            };
            atomic_write(marker, &serde_json::to_vec_pretty(&marker_state)?, 0o600)?;
            Some(LocalPublicationGuard {
                git: self.git.clone(),
                repository: self.repository.root().to_path_buf(),
                marker: marker.clone(),
                completed: false,
            })
        } else {
            None
        };
        for (index, mutation) in mutations.iter().enumerate() {
            let temporary =
                if recovery.is_some() && matches!(mutation, OwnedPathMutation::Write { .. }) {
                    Some(owned_atomic_temporary_path(mutation.path())?)
                } else {
                    None
                };
            apply_owned_path_mutation(self.repository.root(), mutation, temporary.as_deref())
                .with_context(|| format!("apply {domain} repository mutation"))?;
            after_mutation(index)?;
        }
        self.stage_owned_publication_paths(
            &expected,
            &mutations,
            recovery.as_mut(),
            &format!("stage {domain} owned-path publication"),
        )?;
        Ok(recovery)
    }

    fn nix_projection_snapshot(&self) -> Result<NixProjectionSnapshot> {
        load_nix_projection_snapshot(&self.nix, self.repository.root())
    }

    fn nix_service_move_contract(&self) -> Result<NixServiceMoveContract> {
        Ok(self.nix_projection_snapshot()?.service_moves)
    }

    fn runtime_phase_projections(snapshot: &NixProjectionSnapshot) -> Result<Vec<PhaseProjection>> {
        snapshot
            .runtime_plans
            .iter()
            .cloned()
            .map(|plan| {
                if plan.adapter != "host-phase-projection" {
                    bail!(
                        "unsupported projection runtime-plan adapter {:?}",
                        plan.adapter
                    );
                }
                if plan.schema_version != 1 {
                    bail!(
                        "unsupported host phase-projection runtime plan schema {}",
                        plan.schema_version
                    );
                }
                let projection: PhaseProjection = serde_json::from_value(plan.payload)
                    .context("decode host phase-projection runtime-plan payload")?;
                projection.validate()?;
                Ok(projection)
            })
            .collect()
    }

    fn runtime_phase_projection_from(
        snapshot: &NixProjectionSnapshot,
        projection_id: &str,
    ) -> Result<Option<PhaseProjection>> {
        crate::workflow::validate_workflow_id(projection_id)?;
        let matching = Self::runtime_phase_projections(snapshot)?
            .into_iter()
            .filter(|projection| projection.projection_id == projection_id)
            .collect::<Vec<_>>();
        match matching.as_slice() {
            [] => Ok(None),
            [projection] => Ok(Some(projection.clone())),
            _ => bail!(
                "projection runtime plan {:?} was published more than once",
                projection_id
            ),
        }
    }

    fn runtime_phase_projection(&self, projection_id: &str) -> Result<Option<PhaseProjection>> {
        let snapshot = self.nix_projection_snapshot()?;
        Self::runtime_phase_projection_from(&snapshot, projection_id)
    }

    pub fn load_projection_admission(&self, projection_id: &str) -> Result<ProjectionAdmission> {
        let runtime_only = self.repository.load_phase_projection(projection_id)?;
        let snapshot = self.nix_projection_snapshot()?;
        let native_entry = snapshot.service_moves.moves.get(projection_id);
        let runtime = Self::runtime_phase_projection_from(&snapshot, projection_id)?;
        if runtime_only.is_some() && runtime.is_some() {
            bail!("projection exists in both runtime-only JSON and Nix runtime authority");
        }
        let Some(entry) = native_entry else {
            if let Some(runtime) = runtime {
                return Ok(ProjectionAdmission {
                    projection: Some(runtime),
                    requires_existing_journal: false,
                });
            }
            return Ok(ProjectionAdmission {
                projection: runtime_only,
                requires_existing_journal: false,
            });
        };
        entry.projection.validate()?;
        if entry.projection.projection_id != projection_id {
            bail!("Nix-native projection ID does not match its declaration filename");
        }
        let runtime = runtime.context(
            "Nix-native service-move contract has no generic host phase-projection runtime plan",
        )?;
        if runtime != entry.projection {
            bail!("Nix service-move contract and generic runtime plan disagree");
        }
        let requires_existing_journal = entry.declaration.decision.is_some();
        Ok(ProjectionAdmission {
            projection: Some(runtime),
            requires_existing_journal,
        })
    }

    pub fn load_projection(&self, projection_id: &str) -> Result<Option<PhaseProjection>> {
        self.load_projection_admission(projection_id)
            .map(|admission| admission.projection)
    }

    pub fn load_closeout(
        &self,
        projection_id: &str,
    ) -> Result<Option<CanonicalProjectionCloseout>> {
        self.repository.load_projection_closeout(projection_id)
    }

    fn projection_role_for(
        snapshot: &NixProjectionSnapshot,
        scope: &str,
        host_resource: &str,
    ) -> Result<String> {
        let matches = snapshot
            .scope_role_endpoints
            .get(scope)
            .with_context(|| format!("projection snapshot has no scope {scope:?}"))?
            .iter()
            .filter_map(|(role, endpoint)| {
                (endpoint.host_resource == host_resource).then_some(role.clone())
            })
            .collect::<Vec<_>>();
        match matches.as_slice() {
            [role] => Ok(role.clone()),
            [] => bail!(
                "host resource {host_resource:?} does not resolve to a role in scope {scope:?}"
            ),
            _ => bail!(
                "host resource {host_resource:?} resolves to multiple roles in scope {scope:?}"
            ),
        }
    }

    fn projection_role_for_host(
        snapshot: &NixProjectionSnapshot,
        scope: &str,
        host: &str,
    ) -> Result<String> {
        let matches = snapshot
            .scope_role_endpoints
            .get(scope)
            .with_context(|| format!("projection snapshot has no scope {scope:?}"))?
            .iter()
            .filter_map(|(role, endpoint)| (endpoint.host == host).then_some(role.clone()))
            .collect::<Vec<_>>();
        match matches.as_slice() {
            [role] => Ok(role.clone()),
            [] => bail!("host {host:?} does not resolve to a role in scope {scope:?}"),
            _ => bail!("host {host:?} resolves to multiple roles in scope {scope:?}"),
        }
    }

    fn render_nix_service_placement(role: &str) -> Result<String> {
        render_nix_document(&serde_json::json!({ "role": role }))
    }

    fn write_nix_service_adoption(
        &self,
        projection: &PhaseProjection,
        decision: &str,
    ) -> Result<(
        Vec<PathBuf>,
        PathBuf,
        PhaseProjection,
        Option<LocalPublicationGuard>,
    )> {
        let snapshot = self.nix_projection_snapshot()?;
        let entry = snapshot
            .service_moves
            .moves
            .get(&projection.projection_id)
            .context("cannot adopt an absent Nix service move")?;
        if entry.projection != *projection {
            bail!("Nix service-move adoption does not match its terminal projection");
        }
        let requested_decision = NixMoveDecision::parse(decision)?;
        let already_adopted = if let Some(existing_decision) = entry.declaration.decision {
            if existing_decision != requested_decision {
                bail!("Nix service move already retains a different terminal decision");
            }
            true
        } else {
            false
        };
        let identity = nix_move_identity(&entry.projection)?;
        let scope = identity.scope.as_str();
        let scope_placements = snapshot
            .service_placements
            .placements
            .get(scope)
            .context("Nix service move has no stable placement scope")?;
        for item in &entry.declaration.items {
            let role = requested_decision.role(item);
            let current_placement = scope_placements.get(&item.service).with_context(|| {
                format!(
                    "Nix service move has no stable placement for {:?}",
                    item.service
                )
            })?;
            if already_adopted && current_placement.role != role {
                bail!(
                    "adopted Nix service {:?} does not match stable role {role:?}",
                    item.service
                );
            }
        }
        let resolved_paths =
            resolve_nix_service_repository_paths(&self.nix, self.repository.root(), &identity)?;
        let placement_relatives = resolved_paths.placement_paths;
        let move_relative = resolved_paths.move_path;
        snapshot
            .repository
            .require_owner("serviceMoves", "service-move", &move_relative)?;
        for path in &placement_relatives {
            snapshot.repository.require_owner_or_unowned(
                "servicePlacements",
                "service-placement",
                path,
            )?;
        }
        let placement_paths = placement_relatives
            .iter()
            .map(|path| self.repository.root().join(path))
            .collect::<Vec<_>>();
        let move_path = self.repository.root().join(&move_relative);
        let mut declaration = entry.declaration.clone();
        if !already_adopted {
            let (terminal_phase, adoption_phase) = requested_decision.adoption();
            if declaration.desired.phase != terminal_phase {
                bail!("Nix service move is not in the required terminal runtime phase");
            }
            declaration.desired.phase = adoption_phase;
            declaration.decision = Some(requested_decision);
        }
        let adapter = repository_projection_adapter(projection)?
            .context("Nix service-move adoption has no repository projection adapter")?;
        let mut sorted_services = identity.services.clone();
        sorted_services.sort();
        let placement_by_service = sorted_services
            .into_iter()
            .zip(placement_relatives.iter().cloned())
            .collect::<BTreeMap<_, _>>();
        let mut mutations = entry
            .declaration
            .items
            .iter()
            .map(|item| {
                let path = placement_by_service.get(&item.service).with_context(|| {
                    format!(
                        "Nix repository-path resolution omitted service {:?}",
                        item.service
                    )
                })?;
                Ok(OwnedPathMutation::Write {
                    path: path.clone(),
                    contents: Self::render_nix_service_placement(requested_decision.role(item))?
                        .into_bytes(),
                    mode: 0o644,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        mutations.push(OwnedPathMutation::Write {
            path: move_relative.clone(),
            contents: declaration.render()?.into_bytes(),
            mode: 0o644,
        });
        let recovery = self.apply_owned_publication(adapter.domain(), mutations)?;
        let adopted_snapshot = self.nix_projection_snapshot()?;
        adopted_snapshot.repository.require_owner(
            "serviceMoves",
            "service-move",
            &move_relative,
        )?;
        for path in &placement_relatives {
            adopted_snapshot.repository.require_owner(
                "servicePlacements",
                "service-placement",
                path,
            )?;
        }
        let adopted = adopted_snapshot
            .service_moves
            .moves
            .get(&projection.projection_id)
            .context("adopted Nix service move disappeared during evaluation")?
            .projection
            .clone();
        if adopted != *projection {
            bail!("Nix service-move adoption changed the terminal runtime contract");
        }
        Ok((placement_paths, move_path, adopted, recovery))
    }

    fn write_nix_service_move(
        &self,
        requested: &PhaseProjection,
        hints: Option<&NativeMovePublicationHints>,
    ) -> Result<(
        ProjectionWrite,
        PhaseProjection,
        PathBuf,
        Option<LocalPublicationGuard>,
    )> {
        requested.validate()?;
        let spec: TransactionSpec = serde_json::from_value(requested.intent.clone())
            .context("service-move projection intent is not a transaction specification")?;
        let scope = spec
            .declarative_scope
            .as_deref()
            .context("Nix-native service move requires one declarative scope")?;
        let repository_owner = spec
            .repository_owner
            .as_deref()
            .context("Nix-native service move requires one repository owner")?;
        if !spec.consistency_groups.is_empty() || !spec.activation_waves.is_empty() {
            bail!("Nix-native service moves do not yet accept explicit groups or waves");
        }
        let snapshot = self.nix_projection_snapshot()?;
        let raw_items = spec
            .items
            .iter()
            .enumerate()
            .map(|(index, item)| {
                let MoveItem::Service {
                    id,
                    service,
                    source_resource,
                    target_resource,
                    source,
                    target,
                    data_roots,
                } = item
                else {
                    bail!("Nix-native service moves may contain only logical services");
                };
                let expected_id = format!("item-{:03}", index + 1);
                if id != &expected_id || !data_roots.is_empty() {
                    bail!(
                        "Nix-native service move item {id:?} must use canonical ID {expected_id:?} and agent-resolved data roots"
                    );
                }
                let declared_source_resource = source_resource
                    .as_deref()
                    .context("Nix-native service move item has no source writer resource")?;
                let declared_target_resource = target_resource
                    .as_deref()
                    .context("Nix-native service move item has no target writer resource")?;
                if declared_source_resource != declared_target_resource {
                    bail!(
                        "Nix-native service move item {id:?} requires one stable writer resource identity"
                    );
                }
                let source_role =
                    Self::projection_role_for_host(&snapshot, scope, &source.host)?;
                let target_role =
                    Self::projection_role_for_host(&snapshot, scope, &target.host)?;
                if source_role == target_role {
                    bail!("service-move endpoints resolve to the same role {source_role:?}");
                }
                Ok((id.clone(), service.clone(), source_role, target_role))
            })
            .collect::<Result<Vec<_>>>()?;
        let identity = NixMoveIdentity::new(
            scope,
            repository_owner,
            raw_items
                .iter()
                .map(|(_, service, _, _)| service.clone())
                .collect(),
            &requested.projection_id,
        )?;
        let relative =
            resolve_nix_service_repository_paths(&self.nix, self.repository.root(), &identity)?
                .move_path;
        snapshot
            .repository
            .require_owner_or_unowned("serviceMoves", "service-move", &relative)?;
        let path = self.repository.root().join(&relative);
        let existing_contract = snapshot.service_moves;
        let existing = existing_contract.moves.get(&requested.projection_id);
        if let Some(existing) = existing {
            let services = raw_items
                .iter()
                .map(|(_, service, _, _)| service.clone())
                .collect::<Vec<_>>();
            if existing.services != services {
                bail!("existing Nix service move changed its ordered service set");
            }
        }
        let write_items = raw_items
            .into_iter()
            .map(|(id, service, source_role, target_role)| {
                let basis_sha256 = if let Some(existing) = existing {
                    let declared = existing
                        .declaration
                        .items
                        .iter()
                        .find(|item| item.id == id)
                        .with_context(|| {
                            format!("existing Nix service move lost item {id:?}")
                        })?;
                    if declared.service != service
                        || declared.from != source_role
                        || declared.to != target_role
                    {
                        bail!("existing Nix service move item {id:?} changed immutable identity");
                    }
                    let contracted = existing
                        .items
                        .iter()
                        .find(|item| item.id == id)
                        .with_context(|| {
                            format!("existing Nix service-move contract lost item {id:?}")
                        })?;
                    if declared.basis_sha256 != contracted.basis_sha256 {
                        bail!(
                            "existing Nix service move item {id:?} basis digest is internally inconsistent"
                        );
                    }
                    if contracted.service != declared.service
                        || contracted.from != declared.from
                        || contracted.to != declared.to
                    {
                        bail!(
                            "existing Nix service move item {id:?} contract identity is internally inconsistent"
                        );
                    }
                    declared.basis_sha256.clone()
                } else {
                    existing_contract
                        .basis_catalog
                        .get(scope)
                        .and_then(|services| services.get(&service))
                        .and_then(|sources| sources.get(&source_role))
                        .and_then(|targets| targets.get(&target_role))
                        .cloned()
                        .with_context(|| {
                            format!(
                                "service {scope}:{service} has no migration basis for {source_role} -> {target_role}"
                            )
                        })?
                };
                Ok(NixMoveDeclarationItem {
                    id,
                    service,
                    from: source_role,
                    to: target_role,
                    basis_sha256,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        let desired_phase = match requested.move_phase()? {
            crate::projection::MovePhase::Seeded => NixMovePhase::Moved,
            crate::projection::MovePhase::Prepared => NixMovePhase::Prepared,
            crate::projection::MovePhase::Cutover => NixMovePhase::TargetActive,
            crate::projection::MovePhase::RolledBack => NixMovePhase::RolledBack,
        };
        let requested_attempts = write_items
            .iter()
            .map(|item| {
                let previous = existing
                    .map(|entry| entry.declaration.desired.attempts_for(&item.id))
                    .transpose()?
                    .unwrap_or(NixMoveActivationAttempts {
                        source: 1,
                        target: 1,
                    });
                let hinted = hints
                    .and_then(|hints| hints.activation_attempts.get(&item.id))
                    .map(|attempts| NixMoveActivationAttempts {
                        source: attempts.source,
                        target: attempts.target,
                    })
                    .unwrap_or_else(|| previous.clone());
                if hinted.source == 0 || hinted.target == 0 {
                    bail!("Nix service move activation attempts must be positive");
                }
                if hinted.source < previous.source || hinted.target < previous.target {
                    bail!("Nix service move activation attempts cannot regress");
                }
                Ok((item.id.clone(), hinted))
            })
            .collect::<Result<BTreeMap<_, _>>>()?;
        if let Some(existing) = existing {
            if existing.projection.intent != requested.intent
                || existing.projection.intent_sha256 != requested.intent_sha256
            {
                bail!("refusing to replace Nix service move with different immutable intent");
            }
            let existing_attempts = existing
                .declaration
                .items
                .iter()
                .map(|item| {
                    Ok((
                        item.id.clone(),
                        existing.declaration.desired.attempts_for(&item.id)?,
                    ))
                })
                .collect::<Result<BTreeMap<_, _>>>()?;
            if requested == &existing.projection
                && desired_phase == existing.declaration.desired.phase
                && requested_attempts == existing_attempts
            {
                return Ok((
                    ProjectionWrite {
                        path: path.clone(),
                        changed: false,
                        generation: existing.projection.generation,
                        projection_sha256: existing.projection.projection_sha256.clone(),
                    },
                    existing.projection.clone(),
                    path,
                    None,
                ));
            }
            if requested.generation == existing.projection.generation {
                bail!(
                    "Nix service-move generation retained different projected content or activation attempts"
                );
            }
            if requested.generation != existing.projection.generation + 1
                || requested.previous_projection_sha256.as_deref()
                    != Some(existing.projection.projection_sha256.as_str())
            {
                bail!("Nix service-move successor does not advance exact projection lineage");
            }
        } else if requested.generation != 1 || requested.previous_projection_sha256.is_some() {
            bail!("first Nix service-move generation must be 1 without a predecessor");
        }

        let previous_declaration = existing.map(|entry| &entry.declaration);
        let previous_phase = previous_declaration.map(|value| value.desired.phase);
        let leases = write_items
            .iter()
            .map(|item| {
                let previous = previous_declaration
                    .and_then(|declaration| declaration.desired.leases.get(&item.id));
                if previous_declaration.is_some() && previous.is_none() {
                    bail!(
                        "existing Nix service move lost lease for item {:?}",
                        item.id
                    );
                }
                let previous_source = previous.and_then(|lease| lease.source);
                let previous_target = previous.map(|lease| lease.target).unwrap_or(1);
                let source = if desired_phase == NixMovePhase::Moved {
                    None
                } else {
                    Some(previous_source.unwrap_or(1))
                };
                let target = if matches!(
                    desired_phase,
                    NixMovePhase::RolledBack | NixMovePhase::AdoptingSource
                ) && matches!(
                    previous_phase,
                    Some(NixMovePhase::TargetActive | NixMovePhase::AdoptingTarget)
                ) {
                    previous_target + 1
                } else {
                    previous_target
                };
                Ok((item.id.clone(), NixMoveLease { source, target }))
            })
            .collect::<Result<BTreeMap<_, _>>>()?;
        let declaration = NixMoveDeclaration {
            schema_version: 4,
            id: requested.projection_id.clone(),
            authority: match self.mode {
                ProjectionPublicationMode::Remote => NixMoveAuthority::Controller,
                ProjectionPublicationMode::Local => NixMoveAuthority::Local,
            },
            scope: scope.to_owned(),
            items: write_items,
            desired: DesiredMove {
                phase: desired_phase,
                generation: requested.generation,
                activation_attempts: requested_attempts,
                leases,
            },
            decision: None,
            previous: NixMovePrevious {
                contract_sha256: requested.previous_projection_sha256.clone(),
                repository_revision: requested.previous_repository_revision.clone(),
                activation_requirement: existing
                    .and_then(|entry| entry.projection.activation_requirement.clone()),
            },
        };
        let adapter = repository_projection_adapter(requested)?
            .context("Nix service move has no repository projection adapter")?;
        let recovery = self.apply_owned_publication(
            adapter.domain(),
            vec![OwnedPathMutation::Write {
                path: relative.clone(),
                contents: declaration.render()?.into_bytes(),
                mode: 0o644,
            }],
        )?;

        let evaluated_snapshot = self.nix_projection_snapshot()?;
        evaluated_snapshot
            .repository
            .require_owner("serviceMoves", "service-move", &relative)?;
        let evaluated = evaluated_snapshot
            .service_moves
            .moves
            .get(&requested.projection_id)
            .context("written Nix service move was not returned by evaluation")?
            .projection
            .clone();
        evaluated.validate()?;
        if evaluated.intent != requested.intent
            || evaluated.phase != requested.phase
            || evaluated.generation != requested.generation
            || evaluated.previous_projection_sha256 != requested.previous_projection_sha256
            || evaluated.previous_repository_revision != requested.previous_repository_revision
        {
            bail!("evaluated Nix service move does not match requested transition identity");
        }
        Ok((
            ProjectionWrite {
                path: path.clone(),
                changed: true,
                generation: evaluated.generation,
                projection_sha256: evaluated.projection_sha256.clone(),
            },
            evaluated,
            path,
            recovery,
        ))
    }

    /// Exercise the exact publication transport and ref update without changing
    /// the remote. Lifecycle commands run this before mutating their journal.
    pub fn verify_push_access(&self) -> Result<()> {
        if self.mode == ProjectionPublicationMode::Local {
            return Ok(());
        }
        let revision = self.expected_publication_base();
        self.run_publication_git(
            &[
                "push",
                "--dry-run",
                "origin",
                &format!("{revision}:refs/heads/{}", self.branch),
            ],
            "validate Git publication access",
        )
    }

    /// Stage, evaluate, commit, and retain exactly one projection generation.
    /// Runtime callers must wait for this method to succeed.
    pub fn publish(
        &self,
        projection: &PhaseProjection,
        controller_host: &str,
    ) -> Result<ProjectionPublication> {
        self.publish_observed_with_hints(projection, controller_host, None, |_| Ok(()))
    }

    pub fn publish_observed_with_hints(
        &self,
        projection: &PhaseProjection,
        controller_host: &str,
        hints: Option<&NativeMovePublicationHints>,
        mut observe: impl FnMut(ProjectionPublicationEvent) -> Result<()>,
    ) -> Result<ProjectionPublication> {
        let publication_base = self.expected_publication_base();
        self.require_exact_clean_revision(
            &publication_base,
            "phase-projection publication admission",
        )?;
        observe(ProjectionPublicationEvent::Started(
            ProjectionPublicationStage::Validate,
        ))?;
        let adapter = repository_projection_adapter(projection)?;
        let nix_native = adapter.is_some();
        let (write, evaluated, relative, mut recovery) = if nix_native {
            let (write, evaluated, path, native_recovery) =
                self.write_nix_service_move(projection, hints)?;
            let relative = path
                .strip_prefix(self.repository.root())
                .context("Nix service-move path is outside repository")?
                .to_path_buf();
            (write, evaluated, relative, native_recovery)
        } else {
            let (write, projection_mutation) = self.repository.plan_phase_projection(projection)?;
            let relative = projection_mutation.path().to_path_buf();
            let mut mutations = vec![projection_mutation];
            if self.mode == ProjectionPublicationMode::Local {
                mutations.push(
                    self.repository
                        .plan_local_projection_authority(&projection.projection_id)?,
                );
            }
            let recovery = self.apply_owned_publication("runtime-only projection", mutations)?;
            (write, projection.clone(), relative, recovery)
        };
        let runtime_closeouts_relative = PathBuf::from(RUNTIME_PROJECTION_CLOSEOUTS_FILE);
        run_git(
            &self.git,
            self.repository.root(),
            &["diff", "--cached", "--check"],
            "validate staged projection diff",
        )?;
        self.validate_staged_projection(&evaluated, controller_host, |detail| {
            observe(ProjectionPublicationEvent::Progress {
                stage: ProjectionPublicationStage::Validate,
                detail,
            })
        })?;
        observe(ProjectionPublicationEvent::Completed {
            stage: ProjectionPublicationStage::Validate,
            revision: None,
        })?;

        observe(ProjectionPublicationEvent::Started(
            ProjectionPublicationStage::Commit,
        ))?;
        let mut commit_paths = vec![relative.clone()];
        if self.mode == ProjectionPublicationMode::Local && !nix_native {
            commit_paths.push(runtime_closeouts_relative);
        }
        let message = format!(
            "chore(projection): project {} {:?}",
            evaluated.projection_id, evaluated.phase
        );
        let revision = self.commit_owned_publication_paths(
            &publication_base,
            &commit_paths,
            &message,
            "commit phase projection",
        )?;
        if let Some(recovery) = recovery.as_mut() {
            recovery.record_committed_revision(&revision)?;
        }
        observe(ProjectionPublicationEvent::Completed {
            stage: ProjectionPublicationStage::Commit,
            revision: Some(revision.clone()),
        })?;
        self.finish_publication_transport(
            &revision,
            "publish move projection",
            "verify published projection revision",
            "published projection revision mismatch",
            || {
                let retained = if nix_native {
                    self.nix_service_move_contract()?
                        .controller_reconcile_exclusions
                        .iter()
                        .any(|projection_id| projection_id == &evaluated.projection_id)
                } else {
                    self.repository
                        .load_runtime_projection_closeouts()?
                        .controller_reconcile_exclusions
                        .contains(&evaluated.projection_id)
                };
                if !retained {
                    bail!("local projection commit did not retain local controller authority");
                }
                Ok(())
            },
            |stage, completed| {
                let stage = match stage {
                    PublicationTransportStage::RetainLocal => {
                        ProjectionPublicationStage::RetainLocal
                    }
                    PublicationTransportStage::Push => ProjectionPublicationStage::Push,
                    PublicationTransportStage::Verify => ProjectionPublicationStage::Verify,
                };
                observe(if completed {
                    ProjectionPublicationEvent::Completed {
                        stage,
                        revision: Some(revision.clone()),
                    }
                } else {
                    ProjectionPublicationEvent::Started(stage)
                })
            },
        )?;
        let publication = ProjectionPublication {
            write,
            projection: evaluated,
            branch: self.branch.clone(),
            revision,
            pushed: self.pushed(),
        };
        if let Some(recovery) = recovery {
            recovery.complete(&publication.revision)?;
        }
        self.advance_publication_base(&publication_base, &publication.revision)?;
        Ok(publication)
    }

    pub fn cleanup_nix_service_move_observed(
        &self,
        projection: &PhaseProjection,
        decision: &str,
        controller_host: &str,
        expected_predecessor: &str,
        mut observe: impl FnMut(ProjectionCleanupEvent) -> Result<()>,
    ) -> Result<ProjectionCloseoutPublication> {
        let publication_base = self.expected_publication_base();
        if publication_base != expected_predecessor {
            bail!(
                "Nix service-move cleanup predecessor {expected_predecessor} does not match the publisher-owned lineage {publication_base}"
            );
        }
        self.require_exact_clean_revision(expected_predecessor, "Nix service-move cleanup")?;
        let snapshot = self.nix_projection_snapshot()?;
        let entry = snapshot
            .service_moves
            .moves
            .get(&projection.projection_id)
            .context("cannot clean an absent Nix service move")?;
        if entry.projection != *projection
            || entry.declaration.decision != Some(NixMoveDecision::parse(decision)?)
        {
            bail!("Nix service-move cleanup does not match its adopted terminal contract");
        }
        let identity = nix_move_identity(&entry.projection)?;
        if identity.transaction != projection.projection_id {
            bail!("Nix service-move declaration identity does not match its projection");
        }
        let resolved_paths =
            resolve_nix_service_repository_paths(&self.nix, self.repository.root(), &identity)?;
        let authority_paths = resolved_paths
            .placement_paths
            .iter()
            .map(|path| self.repository.root().join(path))
            .collect::<Vec<_>>();
        let projection_relative = resolved_paths.move_path;
        snapshot
            .repository
            .require_owner("serviceMoves", "service-move", &projection_relative)?;
        let projection_path = self.repository.root().join(&projection_relative);
        observe(ProjectionCleanupEvent::Started(
            ProjectionCleanupStage::RemoveAdoptedMove,
        ))?;
        let adapter = repository_projection_adapter(projection)?
            .context("Nix service-move cleanup has no repository projection adapter")?;
        let mut recovery = self.apply_owned_publication(
            adapter.domain(),
            vec![OwnedPathMutation::Remove {
                path: projection_relative.clone(),
            }],
        )?;
        self.nix_projection_snapshot()?
            .repository
            .require_unowned(&projection_relative)?;
        observe(ProjectionCleanupEvent::Completed {
            stage: ProjectionCleanupStage::RemoveAdoptedMove,
            revision: None,
        })?;
        observe(ProjectionCleanupEvent::Started(
            ProjectionCleanupStage::Validate,
        ))?;
        run_git(
            &self.git,
            self.repository.root(),
            &["diff", "--cached", "--check"],
            "validate staged Nix service-move cleanup diff",
        )?;
        self.validate_staged_closeout(
            projection,
            decision,
            CloseoutProjectionState::NativeClean,
            controller_host,
            |detail| {
                observe(ProjectionCleanupEvent::Progress {
                    stage: ProjectionCleanupStage::Validate,
                    detail,
                })
            },
        )?;
        observe(ProjectionCleanupEvent::Completed {
            stage: ProjectionCleanupStage::Validate,
            revision: None,
        })?;
        observe(ProjectionCleanupEvent::Started(
            ProjectionCleanupStage::Commit,
        ))?;
        let message = format!("chore(move): clean {}", projection.projection_id);
        let revision = self.commit_owned_publication_paths(
            &publication_base,
            std::slice::from_ref(&projection_relative),
            &message,
            "commit Nix service-move cleanup",
        )?;
        if let Some(recovery) = recovery.as_mut() {
            recovery.record_committed_revision(&revision)?;
        }
        observe(ProjectionCleanupEvent::Completed {
            stage: ProjectionCleanupStage::Commit,
            revision: Some(revision.clone()),
        })?;
        self.finish_publication_transport(
            &revision,
            "publish Nix service-move cleanup",
            "verify Nix service-move cleanup revision",
            "published Nix service-move cleanup revision mismatch",
            || Ok(()),
            |stage, completed| {
                let stage = match stage {
                    PublicationTransportStage::RetainLocal => ProjectionCleanupStage::RetainLocal,
                    PublicationTransportStage::Push => ProjectionCleanupStage::Push,
                    PublicationTransportStage::Verify => ProjectionCleanupStage::Verify,
                };
                observe(if completed {
                    ProjectionCleanupEvent::Completed {
                        stage,
                        revision: Some(revision.clone()),
                    }
                } else {
                    ProjectionCleanupEvent::Started(stage)
                })
            },
        )?;
        let publication = ProjectionCloseoutPublication {
            authority_paths,
            projection_path,
            branch: self.branch.clone(),
            revision,
            pushed: self.pushed(),
        };
        if let Some(recovery) = recovery {
            recovery.complete(&publication.revision)?;
        }
        self.advance_publication_base(&publication_base, &publication.revision)?;
        Ok(publication)
    }

    pub fn validate_clean_nix_service_move(
        &self,
        projection: &PhaseProjection,
        decision: &str,
        controller_host: &str,
    ) -> Result<()> {
        self.validate_staged_closeout(
            projection,
            decision,
            CloseoutProjectionState::NativeClean,
            controller_host,
            |_| Ok(()),
        )
    }

    pub fn publish_closeout_observed(
        &self,
        projection: &PhaseProjection,
        decision: &str,
        controller_host: &str,
        mut observe: impl FnMut(ProjectionCloseoutEvent) -> Result<()>,
    ) -> Result<ProjectionCloseoutPublication> {
        let publication_base = self.expected_publication_base();
        let adapter = repository_projection_adapter(projection)?;
        let nix_native = adapter.is_some();
        observe(ProjectionCloseoutEvent::Started(
            ProjectionCloseoutStage::PersistAuthority,
        ))?;
        let (authority_paths, projection_path, mut recovery) = if nix_native {
            let (placements, move_path, _, native_recovery) =
                self.write_nix_service_adoption(projection, decision)?;
            (placements, move_path, native_recovery)
        } else {
            let (closeout_path, projection_path, mutations) =
                self.repository.plan_projection_closeout(
                    projection,
                    decision,
                    self.mode == ProjectionPublicationMode::Remote,
                )?;
            let recovery =
                self.apply_owned_publication("runtime-only projection closeout", mutations)?;
            (vec![closeout_path], projection_path, recovery)
        };
        observe(ProjectionCloseoutEvent::Completed {
            stage: ProjectionCloseoutStage::PersistAuthority,
            revision: None,
        })?;
        let declaration_stage = if nix_native {
            ProjectionCloseoutStage::RetainAdoption
        } else {
            ProjectionCloseoutStage::RemoveProjection
        };
        observe(ProjectionCloseoutEvent::Started(declaration_stage))?;
        if !nix_native && projection_path.exists() {
            bail!("closed phase projection still exists after persisting closeout authority");
        }
        observe(ProjectionCloseoutEvent::Completed {
            stage: declaration_stage,
            revision: None,
        })?;
        let validation_stage = if nix_native {
            ProjectionCloseoutStage::ValidateAdoption
        } else {
            ProjectionCloseoutStage::Validate
        };
        observe(ProjectionCloseoutEvent::Started(validation_stage))?;
        let authority_relatives = authority_paths
            .iter()
            .map(|path| {
                path.strip_prefix(self.repository.root())
                    .context("closeout authority path is outside repository")
                    .map(Path::to_path_buf)
            })
            .collect::<Result<Vec<_>>>()?;
        let projection_relative = projection_path
            .strip_prefix(self.repository.root())
            .context("closeout move path is outside repository")?
            .to_path_buf();
        let mut owned_relatives = authority_relatives;
        owned_relatives.push(projection_relative);
        run_git(
            &self.git,
            self.repository.root(),
            &["diff", "--cached", "--check"],
            "validate staged projection closeout diff",
        )?;
        self.validate_staged_closeout(
            projection,
            decision,
            if nix_native {
                CloseoutProjectionState::NativeAdopted
            } else {
                CloseoutProjectionState::RuntimeOnly
            },
            controller_host,
            |detail| {
                observe(ProjectionCloseoutEvent::Progress {
                    stage: validation_stage,
                    detail,
                })
            },
        )?;
        observe(ProjectionCloseoutEvent::Completed {
            stage: validation_stage,
            revision: None,
        })?;

        observe(ProjectionCloseoutEvent::Started(
            ProjectionCloseoutStage::Commit,
        ))?;
        let message = format!("chore(projection): close {}", projection.projection_id);
        let revision = self.commit_owned_publication_paths(
            &publication_base,
            &owned_relatives,
            &message,
            "commit projection closeout",
        )?;
        if let Some(recovery) = recovery.as_mut() {
            recovery.record_committed_revision(&revision)?;
        }
        observe(ProjectionCloseoutEvent::Completed {
            stage: ProjectionCloseoutStage::Commit,
            revision: Some(revision.clone()),
        })?;
        self.finish_publication_transport(
            &revision,
            "publish projection closeout",
            "verify published projection closeout revision",
            "published projection closeout revision mismatch",
            || {
                if nix_native {
                    let contract = self.nix_service_move_contract()?;
                    let entry = contract
                        .moves
                        .get(&projection.projection_id)
                        .context("local Nix service-move adoption was not retained")?;
                    if entry.declaration.authority != NixMoveAuthority::Local {
                        bail!("local Nix service-move adoption lost local authority");
                    }
                } else {
                    let closeout = self
                        .repository
                        .load_projection_closeout(&projection.projection_id)?
                        .context("local projection closeout was not retained")?;
                    if closeout.controller_reconcile {
                        bail!(
                            "local projection closeout incorrectly retained controller authority"
                        );
                    }
                }
                Ok(())
            },
            |stage, completed| {
                let stage = match stage {
                    PublicationTransportStage::RetainLocal => ProjectionCloseoutStage::RetainLocal,
                    PublicationTransportStage::Push => ProjectionCloseoutStage::Push,
                    PublicationTransportStage::Verify => ProjectionCloseoutStage::Verify,
                };
                observe(if completed {
                    ProjectionCloseoutEvent::Completed {
                        stage,
                        revision: Some(revision.clone()),
                    }
                } else {
                    ProjectionCloseoutEvent::Started(stage)
                })
            },
        )?;
        let publication = ProjectionCloseoutPublication {
            authority_paths,
            projection_path,
            branch: self.branch.clone(),
            revision,
            pushed: self.pushed(),
        };
        if let Some(recovery) = recovery {
            recovery.complete(&publication.revision)?;
        }
        self.advance_publication_base(&publication_base, &publication.revision)?;
        Ok(publication)
    }

    fn finish_publication_transport(
        &self,
        revision: &str,
        push_label: &str,
        verify_label: &str,
        mismatch_label: &str,
        retain_local: impl FnOnce() -> Result<()>,
        mut observe: impl FnMut(PublicationTransportStage, bool) -> Result<()>,
    ) -> Result<()> {
        self.require_exact_clean_revision(revision, "publication transport")?;
        if self.mode == ProjectionPublicationMode::Remote {
            observe(PublicationTransportStage::Push, false)?;
            self.require_exact_clean_revision(revision, "publication push")?;
            self.run_publication_git(
                &[
                    "push",
                    "origin",
                    &format!("{revision}:refs/heads/{}", self.branch),
                ],
                push_label,
            )?;
            observe(PublicationTransportStage::Push, true)?;
            observe(PublicationTransportStage::Verify, false)?;
            self.require_exact_clean_revision(revision, "publication verification")?;
            let remote = self.publication_git_stdout(
                &[
                    "ls-remote",
                    "origin",
                    &format!("refs/heads/{}", self.branch),
                ],
                verify_label,
            )?;
            let remote_revision = remote
                .split_whitespace()
                .next()
                .context("published branch has no remote revision")?;
            if remote_revision != revision {
                bail!("{mismatch_label}: local {revision}, remote {remote_revision}");
            }
            observe(PublicationTransportStage::Verify, true)?;
        } else {
            observe(PublicationTransportStage::RetainLocal, false)?;
            self.require_exact_clean_revision(revision, "local publication retention")?;
            retain_local()?;
            observe(PublicationTransportStage::RetainLocal, true)?;
            observe(PublicationTransportStage::Verify, false)?;
            self.require_exact_clean_revision(revision, "local publication verification")?;
            run_git(
                &self.git,
                self.repository.root(),
                &["diff", "--quiet", "HEAD", "--"],
                "verify clean local publication commit",
            )?;
            observe(PublicationTransportStage::Verify, true)?;
        }
        self.require_exact_clean_revision(revision, "publication transport completion")?;
        Ok(())
    }

    fn publication_git_command(&self) -> Command {
        let mut command = repository_git_command(&self.git, self.repository.root());
        if let Some(ssh_command) = &self.publish_git_ssh_command {
            command.env("GIT_SSH_COMMAND", ssh_command);
        }
        command
    }

    fn run_publication_git(&self, args: &[&str], label: &str) -> Result<()> {
        let output = self
            .publication_git_command()
            .args(args)
            .output()
            .with_context(|| format!("start {label}"))?;
        require_command_success(output, label)
    }

    fn publication_git_stdout(&self, args: &[&str], label: &str) -> Result<String> {
        let output = self
            .publication_git_command()
            .args(args)
            .output()
            .with_context(|| format!("start {label}"))?;
        if !output.status.success() {
            return require_command_success(output, label).map(|()| String::new());
        }
        String::from_utf8(output.stdout)
            .with_context(|| format!("decode {label} output"))
            .map(|value| value.trim().to_owned())
    }

    fn validate_staged_projection(
        &self,
        projection: &PhaseProjection,
        controller_host: &str,
        progress: impl FnMut(String) -> Result<()>,
    ) -> Result<()> {
        if controller_host.is_empty() {
            bail!("projection publication requires a non-empty controller host");
        }
        if repository_projection_adapter(projection)?.is_some() {
            let document = self
                .runtime_phase_projection(&projection.projection_id)?
                .context("Nix-native projection has no generic runtime plan")?;
            if document != *projection {
                bail!(
                    "staged runtime plan {:?} evaluated to digest {}, expected {}",
                    projection.projection_id,
                    document.projection_sha256,
                    projection.projection_sha256
                );
            }
        } else {
            let documents_installable = nixos_config_installable(
                controller_host,
                "services.abird-host-manager.phaseProjections",
            )?;
            let documents = repository_nix_eval_command(
                &self.nix,
                self.repository.root(),
                "--json",
                &documents_installable,
            )
            .args(["--option", "allow-import-from-derivation", "false"])
            .output()
            .context("start staged runtime-only phase-projection evaluation")?;
            if !documents.status.success() {
                return require_command_success(documents, "evaluate staged phase projections");
            }
            let documents: Vec<PhaseProjection> = serde_json::from_slice(&documents.stdout)
                .context("parse staged phase projections from Nix")?;
            let matching = documents
                .iter()
                .filter(|document| document.projection_id == projection.projection_id)
                .collect::<Vec<_>>();
            match matching.as_slice() {
                [document] if *document == projection => {}
                [document] => bail!(
                    "staged projection {:?} evaluated to digest {}, expected {}",
                    projection.projection_id,
                    document.projection_sha256,
                    projection.projection_sha256
                ),
                [] => bail!(
                    "staged projection {:?} was not returned by the flake",
                    projection.projection_id
                ),
                _ => bail!(
                    "staged projection {:?} was returned more than once by the flake",
                    projection.projection_id
                ),
            }
        }

        let mut hosts = projection.declarative_effect_hosts();
        hosts.insert(controller_host);
        evaluate_affected_configurations(
            &self.nix,
            self.repository.root(),
            hosts,
            "projection",
            progress,
        )
    }

    fn validate_staged_closeout(
        &self,
        projection: &PhaseProjection,
        decision: &str,
        state: CloseoutProjectionState,
        controller_host: &str,
        progress: impl FnMut(String) -> Result<()>,
    ) -> Result<()> {
        if controller_host.is_empty() {
            bail!("projection closeout requires a non-empty controller host");
        }
        let native_snapshot = if state == CloseoutProjectionState::RuntimeOnly {
            None
        } else {
            Some(self.nix_projection_snapshot()?)
        };
        let requested_decision = NixMoveDecision::parse(decision)?;
        if let Some(snapshot) = &native_snapshot {
            let runtime = Self::runtime_phase_projection_from(snapshot, &projection.projection_id)?;
            let entry = snapshot.service_moves.moves.get(&projection.projection_id);
            match state {
                CloseoutProjectionState::NativeAdopted => {
                    match runtime {
                        Some(document) if document == *projection => {}
                        Some(document) => bail!(
                            "adopted Nix service move changed terminal projection {} to {}",
                            projection.projection_sha256,
                            document.projection_sha256
                        ),
                        None => {
                            bail!("adopted Nix service move disappeared from the runtime plan")
                        }
                    }
                    let entry =
                        entry.context("adopted Nix service move is absent from shared contract")?;
                    if entry.declaration.decision != Some(requested_decision) {
                        bail!("Nix service-move adoption did not retain its terminal decision");
                    }
                }
                CloseoutProjectionState::NativeClean => {
                    if runtime.is_some() || entry.is_some() {
                        bail!(
                            "clean Nix service-move state still contains temporary runtime authority"
                        );
                    }
                }
                CloseoutProjectionState::RuntimeOnly => unreachable!(),
            }
            let identity = nix_move_identity(projection)?;
            let scope_name = identity.scope.as_str();
            let scope = snapshot
                .service_placements
                .placements
                .get(scope_name)
                .context("Nix service move has no stable placement scope")?;
            if state == CloseoutProjectionState::NativeAdopted
                && snapshot
                    .service_moves
                    .moves
                    .get(&projection.projection_id)
                    .expect("adopted entry was checked above")
                    .declaration
                    .items
                    .len()
                    != identity.services.len()
            {
                bail!("Nix service-move placement set changed during adoption");
            }
            for (index, service) in identity.services.iter().enumerate() {
                let matching_effects = projection
                    .effects
                    .iter()
                    .filter_map(|effect| match effect {
                        ProjectionEffect::ServicePlacement {
                            scope,
                            service: effect_service,
                            host_resource,
                            ..
                        } if scope == scope_name && effect_service == service => {
                            Some(host_resource)
                        }
                        _ => None,
                    })
                    .collect::<Vec<_>>();
                let [host_resource] = matching_effects.as_slice() else {
                    bail!("Nix service move requires exactly one placement effect for {service:?}");
                };
                let expected_role = Self::projection_role_for(snapshot, scope_name, host_resource)?;
                if state == CloseoutProjectionState::NativeAdopted {
                    let item = &snapshot
                        .service_moves
                        .moves
                        .get(&projection.projection_id)
                        .expect("adopted entry was checked above")
                        .declaration
                        .items[index];
                    if item.service != *service || requested_decision.role(item) != expected_role {
                        bail!("Nix service-move adoption and placement effect disagree");
                    }
                }
                let placement = scope.get(service).with_context(|| {
                    format!("Nix service move has no stable placement for {service:?}")
                })?;
                if placement.role != expected_role {
                    bail!(
                        "canonical placement for {service:?} is {:?}, expected {expected_role:?}",
                        placement.role
                    );
                }
            }
        } else {
            let documents_installable = nixos_config_installable(
                controller_host,
                "services.abird-host-manager.phaseProjections",
            )?;
            let documents = repository_nix_eval_command(
                &self.nix,
                self.repository.root(),
                "--json",
                &documents_installable,
            )
            .args(["--option", "allow-import-from-derivation", "false"])
            .output()
            .context("start staged runtime-only projection closeout evaluation")?;
            if !documents.status.success() {
                return require_command_success(documents, "evaluate staged projection closeout");
            }
            let documents: Vec<PhaseProjection> = serde_json::from_slice(&documents.stdout)
                .context("parse staged phase projections after closeout")?;
            if documents
                .iter()
                .any(|document| document.projection_id == projection.projection_id)
            {
                bail!("closed phase projection remains visible to the flake");
            }
        }

        for effect in &projection.effects {
            if native_snapshot.is_some() {
                break;
            }
            let ProjectionEffect::ServicePlacement {
                scope,
                service,
                host_resource,
                ..
            } = effect
            else {
                continue;
            };
            let scope = serde_json::to_string(scope)?;
            let service = serde_json::to_string(service)?;
            let expression = format!(
                "stacks: let stack = builtins.getAttr {scope} stacks; spec = stack.serviceRegistry.serviceFor {service}; in stack.serviceRegistry.roles.${{spec.role}}.host"
            );
            let placement = repository_nix_eval_command(
                &self.nix,
                self.repository.root(),
                "--raw",
                ".#hostManager.scopes",
            )
            .args([
                "--apply",
                &expression,
                "--option",
                "allow-import-from-derivation",
                "false",
            ])
            .output()
            .context("start canonical service placement evaluation")?;
            if !placement.status.success() {
                return require_command_success(placement, "evaluate canonical service placement");
            }
            let evaluated = String::from_utf8(placement.stdout)
                .context("decode canonical service placement")?;
            let expected_host = host_resource
                .strip_prefix("host:")
                .context("canonical placement host resource is not canonical")?;
            if evaluated.trim() != expected_host {
                bail!(
                    "canonical placement for {scope}:{service} evaluated to {:?}, expected host resource {host_resource:?}",
                    evaluated.trim(),
                );
            }
        }

        let mut hosts = projection.declarative_effect_hosts();
        hosts.insert(controller_host);
        evaluate_affected_configurations(
            &self.nix,
            self.repository.root(),
            hosts,
            "closeout",
            progress,
        )
    }
}

const MAX_CONFIGURATION_EVALUATIONS: usize = 4;

fn evaluate_affected_configurations(
    nix: &Path,
    repository_root: &Path,
    hosts: BTreeSet<&str>,
    validation: &str,
    mut progress: impl FnMut(String) -> Result<()>,
) -> Result<()> {
    let hosts = hosts.into_iter().map(str::to_owned).collect::<Vec<_>>();
    let total = hosts.len();
    if total == 0 {
        return Ok(());
    }
    let parallelism = total.min(MAX_CONFIGURATION_EVALUATIONS);
    progress(format!(
        "Evaluating {total} affected configurations · {parallelism} in parallel"
    ))?;

    let next = AtomicUsize::new(0);
    let mut results = Vec::with_capacity(total);
    results.resize_with(total, || None);
    thread::scope(|scope| -> Result<()> {
        let (sender, receiver) = mpsc::channel();
        for _ in 0..parallelism {
            let sender = sender.clone();
            let hosts = &hosts;
            let next = &next;
            scope.spawn(move || {
                loop {
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    let Some(host) = hosts.get(index) else {
                        break;
                    };
                    let result = evaluate_configuration(nix, repository_root, host, validation);
                    if sender.send((index, result)).is_err() {
                        break;
                    }
                }
            });
        }
        drop(sender);

        for completed in 1..=total {
            let (index, result) = receiver
                .recv()
                .context("affected configuration evaluation worker stopped unexpectedly")?;
            let host = hosts[index].clone();
            results[index] = Some(result);
            progress(format!(
                "Evaluating affected configurations · {completed}/{total} · {host} finished"
            ))?;
        }
        Ok(())
    })?;

    let mut failures = Vec::new();
    for (host, result) in hosts.iter().zip(results) {
        let result = result.context("affected configuration evaluation result is absent")?;
        if let Err(error) = result {
            failures.push(format!("{host}: {error:#}"));
        }
    }
    if !failures.is_empty() {
        bail!(
            "affected {validation} configuration evaluation failed:\n  - {}",
            failures.join("\n  - ")
        );
    }
    Ok(())
}

fn evaluate_configuration(
    nix: &Path,
    repository_root: &Path,
    host: &str,
    validation: &str,
) -> Result<()> {
    let installable = nixos_config_installable(host, "system.build.toplevel.drvPath")?;
    let evaluation = repository_nix_eval_command(nix, repository_root, "--raw", &installable)
        .args(["--option", "allow-import-from-derivation", "false"])
        .output()
        .with_context(|| {
            format!("start staged {validation} configuration evaluation for {host:?}")
        })?;
    require_command_success(
        evaluation,
        &format!("evaluate staged {validation} configuration for {host:?}"),
    )
}

fn nixos_config_installable(host: &str, attribute: &str) -> Result<String> {
    let quoted_host = serde_json::to_string(host)?;
    Ok(format!(
        ".#nixosConfigurations.{quoted_host}.config.{attribute}"
    ))
}

fn validate_git_branch(branch: &str) -> Result<()> {
    if branch.is_empty()
        || branch.starts_with('-')
        || branch.contains("..")
        || branch.contains([' ', '~', '^', ':', '?', '*', '[', '\\'])
        || branch.as_bytes().iter().any(u8::is_ascii_control)
    {
        bail!("projection branch is not a safe Git branch name");
    }
    Ok(())
}

fn repository_git_command(git: &Path, root: &Path) -> Command {
    let mut command = Command::new(git);
    command.current_dir(root);
    clear_git_repository_environment(&mut command);
    command.env("GIT_LITERAL_PATHSPECS", "1");
    command
}

fn repository_nix_command(nix: &Path, root: &Path) -> Command {
    let mut command = Command::new(nix);
    command.current_dir(root);
    clear_git_repository_environment(&mut command);
    command
}

fn repository_nix_eval_command(
    nix: &Path,
    root: &Path,
    output_format: &str,
    installable: &str,
) -> Command {
    let mut command = repository_nix_command(nix, root);
    // Repository validation is a read-only interpretation of the exact
    // checkout being published. It must never rewrite flake.lock as a side
    // effect of checking a transaction.
    command.args([
        "eval",
        output_format,
        installable,
        "--no-update-lock-file",
        "--no-write-lock-file",
    ]);
    command
}

fn run_git_reference_transaction(
    git: &Path,
    root: &Path,
    transaction: &str,
    label: &str,
) -> Result<Output> {
    let mut child = repository_git_command(git, root)
        .args(["update-ref", "--stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("start {label} reference transaction"))?;
    child
        .stdin
        .take()
        .context("Git reference transaction has no standard input")?
        .write_all(transaction.as_bytes())
        .with_context(|| format!("write {label} reference transaction"))?;
    child
        .wait_with_output()
        .with_context(|| format!("wait for {label} reference transaction"))
}

fn run_git(git: &Path, root: &Path, args: &[&str], label: &str) -> Result<()> {
    let output = repository_git_command(git, root)
        .args(args)
        .output()
        .with_context(|| format!("start {label}"))?;
    require_command_success(output, label)
}

fn run_git_path(git: &Path, root: &Path, args: &[&str], path: &Path, label: &str) -> Result<()> {
    let output = repository_git_command(git, root)
        .args(args)
        .arg(path)
        .output()
        .with_context(|| format!("start {label}"))?;
    require_command_success(output, label)
}

fn git_stdout(git: &Path, root: &Path, args: &[&str], label: &str) -> Result<String> {
    let output = repository_git_command(git, root)
        .args(args)
        .output()
        .with_context(|| format!("start {label}"))?;
    if !output.status.success() {
        return require_command_success(output, label).map(|()| String::new());
    }
    String::from_utf8(output.stdout)
        .with_context(|| format!("decode {label} output"))
        .map(|value| value.trim().to_owned())
}

fn validate_owned_repository_path(path: &Path) -> Result<()> {
    if path.as_os_str().is_empty()
        || path.is_absolute()
        || path.components().any(|component| match component {
            std::path::Component::Normal(component) => {
                component.as_bytes() == b".git"
                    || component.as_bytes().iter().any(u8::is_ascii_control)
            }
            _ => true,
        })
    {
        bail!("repository publication contains an unsafe owned path");
    }
    Ok(())
}

fn git_path_set(git: &Path, root: &Path, args: &[&str], label: &str) -> Result<BTreeSet<PathBuf>> {
    let output = repository_git_command(git, root)
        .args(args)
        .output()
        .with_context(|| format!("start {label}"))?;
    if !output.status.success() {
        return require_command_success(output, label).map(|()| BTreeSet::new());
    }
    output
        .stdout
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
        .map(|path| {
            let path = std::str::from_utf8(path).with_context(|| format!("decode {label} path"))?;
            Ok(PathBuf::from(path))
        })
        .collect()
}

fn dirty_repository_paths(git: &Path, root: &Path) -> Result<BTreeSet<PathBuf>> {
    let mut paths = git_path_set(
        git,
        root,
        &["diff", "--name-only", "-z", "--"],
        "inspect unstaged local publication paths",
    )?;
    paths.extend(git_path_set(
        git,
        root,
        &["diff", "--cached", "--name-only", "-z", "--"],
        "inspect staged local publication paths",
    )?);
    paths.extend(git_path_set(
        git,
        root,
        &["ls-files", "--others", "--exclude-standard", "-z", "--"],
        "inspect untracked local publication paths",
    )?);
    Ok(paths)
}

fn single_git_path_record<'a>(output: &'a [u8], label: &str) -> Result<Option<&'a str>> {
    if output.is_empty() {
        return Ok(None);
    }
    let records = output
        .split(|byte| *byte == 0)
        .filter(|record| !record.is_empty())
        .collect::<Vec<_>>();
    let [record] = records.as_slice() else {
        bail!("{label} returned more than one path record");
    };
    Ok(Some(
        std::str::from_utf8(record).with_context(|| format!("decode {label}"))?,
    ))
}

fn regular_blob_state(mode: &str, object: &str, label: &str) -> Result<PublicationPathState> {
    if !matches!(mode, "100644" | "100755") {
        bail!("{label} is not a regular repository file (mode {mode})");
    }
    if object.is_empty() {
        bail!("{label} record has no object ID");
    }
    Ok(PublicationPathState::Blob {
        mode: mode.to_owned(),
        object: object.to_owned(),
    })
}

fn parse_tree_path_state(output: &[u8], label: &str) -> Result<PublicationPathState> {
    let Some(record) = single_git_path_record(output, label)? else {
        return Ok(PublicationPathState::Absent);
    };
    let (metadata, _) = record
        .split_once('\t')
        .context("Git tree path-state record has no path separator")?;
    let fields = metadata.split_whitespace().collect::<Vec<_>>();
    let [mode, kind, object] = fields.as_slice() else {
        bail!("Git tree path-state record has invalid metadata");
    };
    if *kind != "blob" {
        bail!("{label} is a Git {kind}, expected a regular blob");
    }
    regular_blob_state(mode, object, label)
}

fn parse_index_path_state(output: &[u8], label: &str) -> Result<PublicationPathState> {
    let Some(record) = single_git_path_record(output, label)? else {
        return Ok(PublicationPathState::Absent);
    };
    let (metadata, _) = record
        .split_once('\t')
        .context("Git index path-state record has no path separator")?;
    let fields = metadata.split_whitespace().collect::<Vec<_>>();
    let [mode, object, stage] = fields.as_slice() else {
        bail!("Git index path-state record has invalid metadata");
    };
    if *stage != "0" {
        bail!("{label} has unresolved index stage {stage}");
    }
    regular_blob_state(mode, object, label)
}

fn tree_path_state(
    git: &Path,
    root: &Path,
    revision: &str,
    path: &Path,
) -> Result<PublicationPathState> {
    let output = repository_git_command(git, root)
        .args(["ls-tree", "-z", revision, "--"])
        .arg(path)
        .output()
        .context("inspect publication path in repository tree")?;
    if !output.status.success() {
        return require_command_success(output, "inspect publication path in repository tree")
            .map(|()| PublicationPathState::Absent);
    }
    parse_tree_path_state(&output.stdout, "repository tree path state")
}

fn index_path_state(git: &Path, root: &Path, path: &Path) -> Result<PublicationPathState> {
    let output = repository_git_command(git, root)
        .args(["ls-files", "--stage", "-z", "--"])
        .arg(path)
        .output()
        .context("inspect publication path in repository index")?;
    if !output.status.success() {
        return require_command_success(output, "inspect publication path in repository index")
            .map(|()| PublicationPathState::Absent);
    }
    parse_index_path_state(&output.stdout, "repository index path state")
}

fn worktree_path_state(git: &Path, root: &Path, path: &Path) -> Result<PublicationPathState> {
    let absolute = root.join(path);
    let metadata = match fs::symlink_metadata(&absolute) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(PublicationPathState::Absent);
        }
        Err(error) => return Err(error).context("inspect publication worktree path metadata"),
    };
    if !metadata.file_type().is_file() {
        bail!("publication-owned path is not a regular file");
    }
    let output = repository_git_command(git, root)
        .args(["hash-object", "--no-filters", "--"])
        .arg(path)
        .output()
        .context("hash publication worktree path")?;
    if !output.status.success() {
        return require_command_success(output, "hash publication worktree path")
            .map(|()| PublicationPathState::Absent);
    }
    use std::os::unix::fs::PermissionsExt;
    let mode = if metadata.permissions().mode() & 0o111 == 0 {
        "100644"
    } else {
        "100755"
    };
    Ok(PublicationPathState::Blob {
        mode: mode.to_owned(),
        object: String::from_utf8(output.stdout)
            .context("decode publication worktree object")?
            .trim()
            .to_owned(),
    })
}

fn git_blob_id(git: &Path, repository: &Path, contents: &[u8]) -> Result<String> {
    let mut child = repository_git_command(git, repository)
        .args(["hash-object", "--stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .context("start Git blob hashing for planned publication content")?;
    child
        .stdin
        .take()
        .context("Git blob hashing has no standard input")?
        .write_all(contents)
        .context("write planned publication content to Git blob hashing")?;
    let output = child
        .wait_with_output()
        .context("wait for Git blob hashing")?;
    if !output.status.success() {
        return require_command_success(output, "hash planned publication content")
            .map(|()| unreachable!());
    }
    String::from_utf8(output.stdout)
        .context("decode planned publication blob ID")
        .map(|value| value.trim().to_owned())
}

fn planned_mutation_state(
    git: &Path,
    repository: &Path,
    mutation: &OwnedPathMutation,
) -> Result<PublicationPathState> {
    match mutation {
        OwnedPathMutation::Write { contents, mode, .. } => Ok(PublicationPathState::Blob {
            mode: if mode & 0o111 == 0 {
                "100644".to_owned()
            } else {
                "100755".to_owned()
            },
            object: git_blob_id(git, repository, contents)?,
        }),
        OwnedPathMutation::Remove { .. } => Ok(PublicationPathState::Absent),
    }
}

fn is_exact_local_publication_commit(
    git: &Path,
    repository: &Path,
    recovery: &LocalPublicationRecovery,
    revision: &str,
) -> Result<bool> {
    let parent = git_stdout(
        git,
        repository,
        &["rev-parse", &format!("{revision}^")],
        "resolve committed local publication predecessor",
    )?;
    if parent != recovery.base_revision {
        return Ok(false);
    }
    let committed = git_path_set(
        git,
        repository,
        &[
            "diff-tree",
            "--no-commit-id",
            "--name-only",
            "-r",
            "-z",
            revision,
        ],
        "inspect committed local publication paths",
    )?;
    let expected_changed = recovery
        .paths
        .iter()
        .map(|(path, state)| {
            let after = state
                .after
                .as_ref()
                .context("completed local publication has no recorded postimage")?;
            Ok((state.before != *after).then(|| path.clone()))
        })
        .collect::<Result<Vec<_>>>()?
        .into_iter()
        .flatten()
        .collect::<BTreeSet<_>>();
    if committed != expected_changed {
        return Ok(false);
    }
    for (path, state) in &recovery.paths {
        let after = state
            .after
            .as_ref()
            .context("completed local publication has no recorded postimage")?;
        if tree_path_state(git, repository, revision, path)? != *after {
            return Ok(false);
        }
    }
    Ok(true)
}

fn discover_exact_local_publication_commit(
    git: &Path,
    repository: &Path,
    recovery: &LocalPublicationRecovery,
    branch_revision: &str,
) -> Result<String> {
    let range = format!("{}..{branch_revision}", recovery.base_revision);
    let output = git_stdout(
        git,
        repository,
        &["rev-list", "--parents", &range],
        "inspect local publication branch lineage",
    )?;
    let mut matches = Vec::new();
    for line in output.lines() {
        let fields = line.split_whitespace().collect::<Vec<_>>();
        let [revision, parent] = fields.as_slice() else {
            continue;
        };
        if *parent == recovery.base_revision
            && is_exact_local_publication_commit(git, repository, recovery, revision)?
        {
            matches.push((*revision).to_owned());
        }
    }
    match matches.as_slice() {
        [revision] => Ok(revision.clone()),
        [] => {
            bail!("local publication recovery found no exact commit in configured branch lineage")
        }
        _ => bail!(
            "local publication recovery found multiple possible commits in configured branch lineage"
        ),
    }
}

fn recover_local_publication(git: &Path, repository: &Path, marker: &Path) -> Result<()> {
    if !marker.exists() {
        return Ok(());
    }
    let recovery: LocalPublicationRecovery =
        serde_json::from_slice(&fs::read(marker).with_context(|| {
            format!(
                "read local publication recovery marker {}",
                marker.display()
            )
        })?)
        .context("decode local publication recovery marker")?;
    if !matches!(recovery.schema_version, 2..=4) {
        bail!("unsupported local publication recovery schema");
    }
    let canonical_repository = repository
        .canonicalize()
        .with_context(|| format!("resolve local repository {}", repository.display()))?;
    let recorded_repository = recovery.repository.canonicalize().with_context(|| {
        format!(
            "resolve recorded repository {}",
            recovery.repository.display()
        )
    })?;
    if canonical_repository != recorded_repository {
        bail!("local publication recovery marker belongs to a different repository");
    }
    for path in recovery.paths.keys() {
        validate_owned_repository_path(path)?;
    }
    let branch = git_stdout(
        git,
        repository,
        &["branch", "--show-current"],
        "resolve local recovery branch",
    )?;
    if branch != recovery.branch {
        bail!(
            "local publication recovery marker belongs to branch {:?}",
            recovery.branch
        );
    }
    for temporary in &recovery.temporary_paths {
        validate_owned_repository_path(temporary)?;
        if recovery.paths.contains_key(temporary) {
            bail!("local publication temporary path overlaps an owned document");
        }
        if index_path_state(git, repository, temporary)? != PublicationPathState::Absent {
            bail!(
                "local publication temporary path {} is tracked; refusing to remove it",
                temporary.display()
            );
        }
        let absolute = repository.join(temporary);
        match fs::symlink_metadata(&absolute) {
            Ok(metadata) if metadata.file_type().is_file() => {
                fs::remove_file(&absolute).with_context(|| {
                    format!(
                        "remove interrupted local publication temporary {}",
                        absolute.display()
                    )
                })?;
            }
            Ok(_) => bail!(
                "local publication temporary path {} is not a regular file",
                temporary.display()
            ),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error).context("inspect local publication temporary path"),
        }
    }
    let revision = git_stdout(
        git,
        repository,
        &["rev-parse", "HEAD"],
        "resolve local recovery revision",
    )?;
    let dirty = dirty_repository_paths(git, repository)?;
    let owned_paths = recovery.paths.keys().cloned().collect::<BTreeSet<_>>();
    if revision == recovery.base_revision {
        if !dirty.is_subset(&owned_paths) {
            bail!("local publication recovery found unrelated repository changes");
        }
        if recovery.paths.values().any(|path| path.after.is_none()) {
            let unchanged = recovery.paths.iter().all(|(path, state)| {
                matches!(
                    (
                        index_path_state(git, repository, path),
                        worktree_path_state(git, repository, path),
                    ),
                    (Ok(index), Ok(worktree))
                        if index == state.before && worktree == state.before
                )
            });
            if unchanged {
                fs::remove_file(marker).with_context(|| {
                    format!(
                        "remove unstarted local publication marker {}",
                        marker.display()
                    )
                })?;
                return Ok(());
            }
            bail!(
                "local publication recovery has no postimage and an owned path changed; refusing to guess whether it was a concurrent edit"
            );
        }
        for (path, path_recovery) in &recovery.paths {
            let after = path_recovery.after.as_ref().context(
                "local publication recovery has no recorded postimage; refusing to overwrite possible concurrent edits",
            )?;
            let index = index_path_state(git, repository, path)?;
            let worktree = worktree_path_state(git, repository, path)?;
            let known_pair = (index == path_recovery.before
                && (worktree == path_recovery.before || worktree == *after))
                || (index == *after && worktree == *after);
            if !known_pair {
                bail!(
                    "local publication recovery found content drift at {}; refusing to overwrite it",
                    path.display()
                );
            }
            if path_recovery.before != PublicationPathState::Absent {
                let path = path
                    .to_str()
                    .context("local publication recovery path is not UTF-8")?;
                run_git(
                    git,
                    repository,
                    &[
                        "restore",
                        "--source",
                        &recovery.base_revision,
                        "--staged",
                        "--worktree",
                        "--",
                        path,
                    ],
                    "restore interrupted local publication path",
                )?;
            } else {
                let output = repository_git_command(git, repository)
                    .args(["rm", "--cached", "--ignore-unmatch", "--"])
                    .arg(path)
                    .output()
                    .context("unstage interrupted local publication path")?;
                require_command_success(output, "unstage interrupted local publication path")?;
                let absolute = repository.join(path);
                if absolute.exists() {
                    fs::remove_file(&absolute).with_context(|| {
                        format!(
                            "remove interrupted local publication path {}",
                            absolute.display()
                        )
                    })?;
                }
            }
        }
        let remaining = dirty_repository_paths(git, repository)?;
        if remaining.iter().any(|path| owned_paths.contains(path)) {
            bail!("interrupted local publication paths did not restore cleanly");
        }
    } else {
        let publication_revision = match recovery.committed_revision.as_deref() {
            Some(revision) => revision.to_owned(),
            None if recovery.schema_version == 4 => {
                discover_exact_local_publication_commit(git, repository, &recovery, &revision)?
            }
            None => revision.clone(),
        };
        if !is_exact_local_publication_commit(git, repository, &recovery, &publication_revision)? {
            bail!("local publication recovery cannot prove an exact completed commit");
        }
        if recovery.schema_version == 4 {
            let ancestry = repository_git_command(git, repository)
                .args([
                    "merge-base",
                    "--is-ancestor",
                    &publication_revision,
                    &revision,
                ])
                .status()
                .context("verify local publication commit remains in branch lineage")?;
            if !ancestry.success() {
                bail!("local publication commit is no longer in the configured branch lineage");
            }
            let descendant_changes = git_path_set(
                git,
                repository,
                &[
                    "diff",
                    "--name-only",
                    "-z",
                    &publication_revision,
                    &revision,
                    "--",
                ],
                "inspect repository changes after local publication",
            )?;
            if descendant_changes
                .iter()
                .any(|path| owned_paths.contains(path))
            {
                bail!(
                    "configured branch changed a publication-owned path after the publication commit"
                );
            }
        }
        if dirty.iter().any(|path| owned_paths.contains(path)) {
            bail!("completed local publication has post-commit drift in an owned path");
        }
    }
    fs::remove_file(marker).with_context(|| {
        format!(
            "remove recovered local publication marker {}",
            marker.display()
        )
    })?;
    Ok(())
}

fn require_command_success(output: Output, label: &str) -> Result<()> {
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let stdout = String::from_utf8_lossy(&output.stdout);
    bail!(
        "{label} failed with {}: {}{}",
        output.status,
        stdout.trim(),
        stderr.trim()
    )
}

fn update_hosts_default(
    source: &str,
    host: &str,
    record: &ManagedHost,
    force: bool,
) -> Result<String> {
    let source = prepare_for_insert(source, host, force)?;
    let profile = if record.system == ManagedHostSystem::Incus {
        "machineProfiles.incusLxc"
    } else {
        "machineProfiles.vm"
    };
    let stack = record
        .stack
        .as_ref()
        .map(|stack| format!("      stack = stacks.{};\n", nix_string(stack)))
        .unwrap_or_default();
    Ok(format!(
        "{}\n{}  // {{\n    {} = mkNixosSystem {{\n      hostName = {};\n{}      machineProfile = {};\n      modules = [./{}];\n    }};\n  }}\n{}",
        source.trim_end(),
        begin_marker(host),
        host,
        nix_string(host),
        stack,
        profile,
        host,
        end_marker(host)
    ))
}

fn update_nixbot(source: &str, host: &str, record: &ManagedHost, force: bool) -> Result<String> {
    let mut source = prepare_for_insert(source, host, force)?;
    let anchor = source
        .find("\n\n  config =")
        .context("hosts/nixbot.nix has no config anchor")?;
    let semicolon = source[..anchor]
        .rfind(';')
        .context("hosts/nixbot.nix hosts expression has no terminator")?;
    let groups = record
        .groups
        .iter()
        .map(|group| nix_string(group))
        .collect::<Vec<_>>()
        .join(" ");
    let proxy = record
        .proxy_jump
        .as_ref()
        .map_or_else(String::new, |proxy| {
            format!(
                "        proxyJump = {};\n        parent = {};\n",
                nix_string(proxy),
                nix_string(proxy)
            )
        });
    let block = format!(
        "\n{}    // {{\n      {} = {{\n        target = {};\n        ageIdentityKey = secretPaths.machine {};\n        groups = [{}];\n{}      }};\n    }}\n{}",
        begin_marker(host),
        host,
        nix_string(&record.target),
        nix_string(host),
        groups,
        proxy,
        end_marker(host)
    );
    source.insert_str(semicolon, &block);
    Ok(source)
}

fn update_secrets(source: &str, host: &str, force: bool) -> Result<String> {
    let mut source = prepare_for_insert(source, host, force)?;
    let anchor = source
        .find("    defaultAccess =")
        .context("data/secrets/default.nix has no machine identity anchor")?;
    source.insert_str(
        anchor,
        &format!(
            "{}      {} = {{}};\n{}",
            begin_marker(host),
            host,
            end_marker(host)
        ),
    );
    Ok(source)
}

fn update_incus_parent(
    source: &str,
    host: &str,
    incus: &ManagedIncus,
    force: bool,
) -> Result<String> {
    let source = prepare_for_insert(source, host, force)?;
    let final_brace = source
        .rfind('}')
        .context("Incus parent module has no final attribute-set brace")?;
    let block = format!(
        "{}  services.incus-manager.{}.instances.{} = mkLxc {{\n    name = {};\n    ipv4Address = {};\n    startPriority = {};\n    nestedContainers = {};\n  }};\n{}",
        begin_marker(host),
        nix_string(&incus.project),
        nix_string(host),
        nix_string(host),
        nix_string(&incus.ipv4_address),
        incus.start_priority,
        incus.nested_containers,
        end_marker(host)
    );
    Ok(format!(
        "{}{}{}",
        &source[..final_brace],
        block,
        &source[final_brace..]
    ))
}

fn prepare_for_insert(source: &str, host: &str, force: bool) -> Result<String> {
    let has_marker = source.contains(&begin_marker(host));
    if has_marker && !force {
        bail!("host {host:?} already has an abird-host-manager registration");
    }
    if has_marker {
        remove_owned_block(source, host)
    } else {
        Ok(source.to_owned())
    }
}

fn remove_owned_block(source: &str, host: &str) -> Result<String> {
    let begin = begin_marker(host);
    let end = end_marker(host);
    let Some(start) = source.find(&begin) else {
        return Ok(source.to_owned());
    };
    let end_start = source[start..]
        .find(&end)
        .map(|offset| start + offset)
        .context("managed registration has no closing marker")?;
    let mut end_offset = end_start + end.len();
    if source.as_bytes().get(end_offset) == Some(&b'\n') {
        end_offset += 1;
    }
    Ok(format!("{}{}", &source[..start], &source[end_offset..]))
}

fn begin_marker(host: &str) -> String {
    format!("# abird-host-manager:{host}:begin\n")
}

fn end_marker(host: &str) -> String {
    format!("# abird-host-manager:{host}:end\n")
}

fn nix_string(value: &str) -> String {
    crate::physical::nix_string(value)
}

fn validate_host_name(value: &str) -> Result<()> {
    if value.is_empty()
        || value.starts_with('-')
        || value.ends_with('-')
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        bail!("host name must contain only letters, digits, and internal hyphens");
    }
    Ok(())
}

fn validate_record(record: &ManagedHost) -> Result<()> {
    if record.target.is_empty() || record.target.contains(['\0', '\r', '\n']) {
        bail!("managed host target is invalid");
    }
    for value in record
        .groups
        .iter()
        .chain(record.stack.iter())
        .chain(record.proxy_jump.iter())
    {
        if value.contains(['\0', '\r', '\n']) {
            bail!("managed host metadata cannot contain control characters");
        }
    }
    if record.system == ManagedHostSystem::Incus && record.incus.is_none() {
        bail!("Incus hosts require Incus placement metadata");
    }
    if record.system != ManagedHostSystem::Incus && record.incus.is_some() {
        bail!("only Incus hosts may contain Incus placement metadata");
    }
    Ok(())
}

fn default_module(record: &ManagedHost) -> String {
    let local_modules = if record.system == ManagedHostSystem::Incus {
        "      ./packages.nix\n      ./users.nix"
    } else {
        "      ./sys.nix"
    };
    format!(
        r#"{{lib, stack, ...}}: let
  commonModule =
    if stack ? org
    then lib.path.append ../common "${{stack.org}}.nix"
    else null;
in {{
  imports =
    lib.optional (commonModule != null) (
      if builtins.pathExists commonModule
      then commonModule
      else throw "no common host module for stack organization ${{stack.org}}"
    )
    ++ [
{local_modules}
    ];
}}
"#
    )
}

fn minimal_system_module() -> &'static str {
    "# Minimal hardware scaffold generated by abird-host-manager.\n{lib, modulesPath, ...}: {\n  imports = [(modulesPath + \"/installer/scan/not-detected.nix\")];\n  nixpkgs.hostPlatform = lib.mkDefault \"x86_64-linux\";\n}\n"
}

fn atomic_write(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let temporary = path.with_extension(format!(
        "{}.{}.tmp",
        path.extension().and_then(|v| v.to_str()).unwrap_or("file"),
        std::process::id()
    ));
    atomic_write_with_temporary(path, &temporary, bytes, mode)
}

fn atomic_write_with_temporary(
    path: &Path,
    temporary: &Path,
    bytes: &[u8],
    mode: u32,
) -> Result<()> {
    if temporary.parent() != path.parent() {
        bail!("atomic-write temporary path must share its destination directory");
    }
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(mode)
        .open(temporary)?;
    let mut temporary_guard = AtomicWriteTemporary {
        path: temporary.to_path_buf(),
        renamed: false,
    };
    file.write_all(bytes)?;
    file.sync_all()?;
    fs::rename(temporary, path)?;
    temporary_guard.renamed = true;
    File::open(path.parent().context("managed file has no parent")?)?.sync_all()?;
    Ok(())
}

fn write_private(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(mode)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}

fn absolute_non_root<'a>(path: &'a Path, label: &str) -> Result<&'a Path> {
    if !path.is_absolute() || path == Path::new("/") {
        bail!("{label} must be an absolute non-root path");
    }
    Ok(path)
}

fn system_installable(host_name: &str) -> String {
    format!(".#nixosConfigurations.{host_name}.config.system.build.toplevel")
}

fn disko_installable(host_name: &str) -> String {
    format!(".#nixosConfigurations.{host_name}.config.system.build.diskoScript")
}

#[cfg(test)]
mod tests {
    use crate::agent_adapter::HostManagerConfig;
    use crate::physical::PartitionSize;
    use crate::projection::{MovePhase, MoveProjector, PhaseProjection, canonical_sha256};
    use crate::test_support::write_executable;
    use crate::workflow::{HostEndpoint, MoveItem, TransactionSpec};

    use super::*;

    #[test]
    fn typed_nix_renderer_is_deterministic_and_escapes_interpolation() {
        let rendered = render_nix_document(&serde_json::json!({
            "z-field": [true, "${unsafe}", null],
            "a field": {"role": "target"},
            "if": 1,
        }))
        .unwrap();

        assert_eq!(
            rendered,
            "{\n  \"a field\" = {\n    \"role\" = \"target\";\n  };\n  \"if\" = 1;\n  \"z-field\" = [\n    true\n    \"\\${unsafe}\"\n    null\n  ];\n}\n"
        );
    }

    #[test]
    fn typed_nix_renderer_rejects_floating_point_numbers() {
        let error = render_nix_document(&serde_json::json!({"unsafe": 1.5})).unwrap_err();

        assert!(
            error
                .to_string()
                .contains("supports only signed 64-bit integers")
        );
    }

    #[test]
    fn typed_nix_renderer_rejects_out_of_range_unsigned_integers() {
        let error = render_nix_document(&serde_json::json!({"unsafe": u64::MAX})).unwrap_err();

        assert!(
            error
                .to_string()
                .contains("supports only signed 64-bit integers")
        );
    }

    #[test]
    fn move_previous_serializes_the_exact_activation_requirement() {
        let rendered = render_nix_document(
            &serde_json::to_value(NixMovePrevious {
                contract_sha256: Some("a".repeat(64)),
                repository_revision: Some("revision".to_owned()),
                activation_requirement: Some(ActivationRequirement {
                    kind: "target-activation".to_owned(),
                    requirement_sha256: "b".repeat(64),
                }),
            })
            .unwrap(),
        )
        .unwrap();

        assert!(rendered.contains("\"activation_requirement\" = {"));
        assert!(rendered.contains("\"kind\" = \"target-activation\";"));
        assert!(rendered.contains(&format!("\"requirement_sha256\" = \"{}\";", "b".repeat(64))));
    }

    #[test]
    fn projection_snapshot_rejects_unsupported_runtime_adapters() {
        let snapshot: NixProjectionSnapshot = serde_json::from_value(serde_json::json!({
            "schema_version": 1,
            "repository": {
                "schema_version": 1,
                "owners": [],
                "scopes": {}
            },
            "service_moves": {
                "schema_version": 2,
                "basis_catalog": {},
                "controller_reconcile_exclusions": [],
                "moves": {}
            },
            "service_placements": {
                "schema_version": 3,
                "placements": {}
            },
            "runtime_plans": [{
                "schema_version": 1,
                "adapter": "unsupported",
                "payload": {}
            }],
            "scope_role_endpoints": {}
        }))
        .unwrap();

        let error = ProjectionPublisher::runtime_phase_projections(&snapshot).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("unsupported projection runtime-plan adapter")
        );
    }

    #[test]
    fn repository_components_reject_traversal_and_ambiguous_names() {
        for value in ["", ".", "..", "../escape", "scope/service", "unsafe name"] {
            assert!(validate_repository_component("fixture", value).is_err());
        }
        assert!(validate_repository_component("fixture", "abird-zulip_01").is_ok());
        assert!(validate_repository_component("fixture", "-abird").is_err());
        assert!(validate_repository_component("fixture", &"x".repeat(65)).is_err());
    }

    #[test]
    fn owned_repository_paths_reject_git_metadata_and_control_characters() {
        for path in [
            Path::new(".git/config"),
            Path::new("config/.git/index"),
            Path::new("config/line\nbreak.nix"),
            Path::new("config/delete\u{7f}.nix"),
        ] {
            assert!(validate_owned_repository_path(path).is_err(), "{path:?}");
        }
        assert!(validate_owned_repository_path(Path::new("config/abird/moves/demo.nix")).is_ok());
    }

    #[test]
    fn git_path_state_parsers_admit_only_regular_stage_zero_blobs() {
        assert_eq!(
            parse_tree_path_state(
                b"100644 blob 0123456789abcdef\tconfig/example.nix\0",
                "fixture tree",
            )
            .unwrap(),
            PublicationPathState::Blob {
                mode: "100644".to_owned(),
                object: "0123456789abcdef".to_owned(),
            }
        );
        assert!(
            parse_tree_path_state(b"040000 tree 0123456789abcdef\tconfig\0", "fixture tree",)
                .unwrap_err()
                .to_string()
                .contains("expected a regular blob")
        );
        assert!(
            parse_tree_path_state(
                b"120000 blob 0123456789abcdef\tconfig/link\0",
                "fixture tree",
            )
            .unwrap_err()
            .to_string()
            .contains("not a regular repository file")
        );
        assert!(
            parse_index_path_state(
                b"100644 0123456789abcdef 2\tconfig/example.nix\0",
                "fixture index",
            )
            .unwrap_err()
            .to_string()
            .contains("unresolved index stage")
        );
    }

    #[test]
    fn explicit_native_intent_never_falls_back_to_runtime_only_on_identity_errors() {
        for id in ["_move-a".to_owned(), "a".repeat(65)] {
            let mut spec = TransactionSpec::new(
                Some(&id),
                vec![MoveItem::Service {
                    id: "item-001".to_owned(),
                    service: "zulip".to_owned(),
                    source_resource: Some("service:zulip".to_owned()),
                    target_resource: Some("service:zulip".to_owned()),
                    source: HostEndpoint {
                        host: "source".to_owned(),
                        instance: None,
                    },
                    target: HostEndpoint {
                        host: "target".to_owned(),
                        instance: None,
                    },
                    data_roots: Vec::new(),
                }],
                Vec::new(),
                Vec::new(),
            )
            .unwrap();
            spec.declarative_scope = Some("abird-gondor".to_owned());
            spec.repository_owner = Some("abird".to_owned());

            assert!(
                repository_projection_kind_for_spec(&spec)
                    .unwrap_err()
                    .to_string()
                    .contains("safe repository path component")
            );
        }
    }

    #[test]
    fn logical_service_intent_requires_repository_identity() {
        let spec = TransactionSpec::new(
            Some("move-service"),
            vec![MoveItem::Service {
                id: "item-001".to_owned(),
                service: "zulip".to_owned(),
                source_resource: Some("service:zulip".to_owned()),
                target_resource: Some("service:zulip".to_owned()),
                source: HostEndpoint {
                    host: "source".to_owned(),
                    instance: None,
                },
                target: HostEndpoint {
                    host: "target".to_owned(),
                    instance: None,
                },
                data_roots: Vec::new(),
            }],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();

        assert!(
            repository_projection_kind_for_spec(&spec)
                .unwrap_err()
                .to_string()
                .contains("require a declarative scope and repository owner")
        );
    }

    #[test]
    fn runtime_only_nonservice_intent_keeps_the_broader_workflow_id_contract() {
        let spec = TransactionSpec::new(
            Some("_runtime-resource"),
            vec![MoveItem::Resource {
                id: "item-001".to_owned(),
                resource: "volume:data".to_owned(),
                source: HostEndpoint {
                    host: "source".to_owned(),
                    instance: None,
                },
                target: HostEndpoint {
                    host: "target".to_owned(),
                    instance: None,
                },
                data_roots: Vec::new(),
            }],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();

        assert_eq!(
            repository_projection_kind_for_spec(&spec).unwrap(),
            RepositoryProjectionKind::RuntimeOnly
        );
    }

    #[test]
    fn pre_owner_native_intent_is_an_explicit_upgrade_boundary() {
        let mut spec = TransactionSpec::new(
            Some("move-old-native"),
            vec![MoveItem::Service {
                id: "item-001".to_owned(),
                service: "zulip".to_owned(),
                source_resource: Some("service:zulip".to_owned()),
                target_resource: Some("service:zulip".to_owned()),
                source: HostEndpoint {
                    host: "source".to_owned(),
                    instance: None,
                },
                target: HostEndpoint {
                    host: "target".to_owned(),
                    instance: None,
                },
                data_roots: Vec::new(),
            }],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        spec.declarative_scope = Some("abird-gondor".to_owned());

        assert!(
            repository_projection_kind_for_spec(&spec)
                .unwrap_err()
                .to_string()
                .contains("requires repository-owner identity")
        );
    }

    fn fixture() -> tempfile::TempDir {
        let temp = tempfile::tempdir().unwrap();
        for directory in ["pkgs", "hosts", "data/secrets/globals/machine", "tmp"] {
            fs::create_dir_all(temp.path().join(directory)).unwrap();
        }
        fs::write(temp.path().join("flake.nix"), "{}\n").unwrap();
        fs::write(temp.path().join("pkgs/manifest.nix"), "{}\n").unwrap();
        fs::write(temp.path().join(HOSTS_FILE), "let x = 1; in {}\n").unwrap();
        fs::write(
            temp.path().join(NIXBOT_FILE),
            "let x = 1; in {\n  hosts = {};\n\n  config = {};\n}\n",
        )
        .unwrap();
        fs::write(
            temp.path().join(SECRETS_FILE),
            "let machineIdentities = {\n    machines = {\n    defaultAccess = [];\n  };\n}; in {}\n",
        )
        .unwrap();
        fs::write(
            temp.path()
                .join("data/secrets/globals/machine/demo-host.key.pub"),
            "age1demo\n",
        )
        .unwrap();
        fs::write(
            temp.path()
                .join("data/secrets/globals/machine/demo-host.key.age"),
            "encrypted\n",
        )
        .unwrap();
        temp
    }

    #[test]
    fn repository_git_commands_ignore_inherited_repository_selection() {
        let command = repository_git_command(Path::new("git"), Path::new("/tmp/repository"));
        let removed = command
            .get_envs()
            .filter(|(_, value)| value.is_none())
            .map(|(name, _)| name.to_string_lossy().into_owned())
            .collect::<BTreeSet<_>>();

        assert_eq!(
            removed,
            GIT_REPOSITORY_ENVIRONMENT
                .iter()
                .map(|variable| (*variable).to_owned())
                .collect()
        );
        assert_eq!(
            command.get_current_dir(),
            Some(Path::new("/tmp/repository"))
        );
        assert_eq!(
            command
                .get_envs()
                .find(|(name, _)| *name == "GIT_LITERAL_PATHSPECS")
                .and_then(|(_, value)| value),
            Some(std::ffi::OsStr::new("1"))
        );
    }

    #[test]
    fn repository_git_commands_treat_leading_colons_and_globs_as_literal_paths() {
        let repository = tempfile::tempdir().unwrap();
        let git = Path::new("git");
        run_git(
            git,
            repository.path(),
            &["init", "-b", "master"],
            "initialize literal-path fixture",
        )
        .unwrap();
        for path in [":literal.txt", "glob[1].txt", "glob1.txt"] {
            fs::write(repository.path().join(path), format!("{path}\n")).unwrap();
        }

        for path in [Path::new(":literal.txt"), Path::new("glob[1].txt")] {
            run_git_path(
                git,
                repository.path(),
                &["add", "--"],
                path,
                "stage literal path",
            )
            .unwrap();
        }

        assert_eq!(
            git_path_set(
                git,
                repository.path(),
                &["diff", "--cached", "--name-only", "-z", "--"],
                "list literal staged paths",
            )
            .unwrap(),
            [PathBuf::from(":literal.txt"), PathBuf::from("glob[1].txt")]
                .into_iter()
                .collect()
        );
    }

    fn record(system: ManagedHostSystem) -> ManagedHost {
        ManagedHost {
            system,
            stack: None,
            target: "demo-host".to_owned(),
            proxy_jump: None,
            groups: vec!["demo".to_owned()],
            incus: None,
        }
    }

    fn physical_request(mode: BootMode) -> PhysicalLayoutRequest {
        PhysicalLayoutRequest {
            disk: PathBuf::from("/dev/disk/by-id/demo"),
            boot_mode: mode,
            esp_size: PartitionSize::new("1G").unwrap(),
            boot_size: PartitionSize::new("2G").unwrap(),
            swap_size_mib: 8192,
        }
    }

    fn projection_config() -> HostManagerConfig {
        serde_json::from_value(serde_json::json!({
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
                "source": {"address": "127.0.0.1", "host_resource": "host:source"},
                "target": {"address": "127.0.0.2", "host_resource": "host:target"},
                "router": {"address": "127.0.0.3", "host_resource": "host:router"}
            },
            "operation_routes": {
                "deploy-cutover": {
                    "executor":"source",
                    "phase_projection": {"executor":"router","resource":"service:router"}
                },
                "deploy-rollback": {
                    "executor":"source",
                    "phase_projection": {"executor":"router","resource":"service:router"}
                }
            }
        }))
        .unwrap()
    }

    fn seeded_projection(previous_revision: String) -> PhaseProjection {
        let spec = TransactionSpec::new(
            Some("move-publisher"),
            vec![MoveItem::Resource {
                id: "item-001".to_owned(),
                resource: "volume:data".to_owned(),
                source: HostEndpoint {
                    host: "source".to_owned(),
                    instance: None,
                },
                target: HostEndpoint {
                    host: "target".to_owned(),
                    instance: None,
                },
                data_roots: Vec::new(),
            }],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        MoveProjector::derive(
            &spec,
            &projection_config(),
            MovePhase::Seeded,
            None,
            Some(previous_revision),
        )
        .unwrap()
    }

    fn seeded_service_projection(previous_revision: String) -> PhaseProjection {
        let mut spec = TransactionSpec::new(
            Some("move-publisher"),
            vec![MoveItem::Service {
                id: "item-001".to_owned(),
                service: "zulip".to_owned(),
                source_resource: Some("service:zulip".to_owned()),
                target_resource: Some("service:zulip".to_owned()),
                source: HostEndpoint {
                    host: "source".to_owned(),
                    instance: None,
                },
                target: HostEndpoint {
                    host: "target".to_owned(),
                    instance: None,
                },
                data_roots: Vec::new(),
            }],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        spec.declarative_scope = Some("abird-gondor".to_owned());
        spec.repository_owner = Some("abird".to_owned());
        MoveProjector::derive(
            &spec,
            &projection_config(),
            MovePhase::Seeded,
            None,
            Some(previous_revision),
        )
        .unwrap()
    }

    #[test]
    fn runtime_projection_directory_rejects_logical_service_moves() {
        let source = fixture();
        let repository = Repository::from_root(source.path().to_path_buf()).unwrap();
        let projection = seeded_service_projection("0".repeat(40));
        let directory = source.path().join("data/phase-projections");
        fs::create_dir_all(&directory).unwrap();
        fs::write(
            directory.join(format!("{}.json", projection.projection_id)),
            serde_json::to_vec_pretty(&projection).unwrap(),
        )
        .unwrap();

        let error = repository
            .load_phase_projection(&projection.projection_id)
            .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("logical service moves must be authored through Nix")
        );
    }

    fn seeded_multi_service_projection(previous_revision: String) -> PhaseProjection {
        let mut spec = TransactionSpec::new(
            Some("move-suite"),
            ["zulip", "zulip-worker"]
                .into_iter()
                .enumerate()
                .map(|(index, service)| MoveItem::Service {
                    id: format!("item-{:03}", index + 1),
                    service: service.to_owned(),
                    source_resource: Some(format!("service:{service}")),
                    target_resource: Some(format!("service:{service}")),
                    source: HostEndpoint {
                        host: "source".to_owned(),
                        instance: None,
                    },
                    target: HostEndpoint {
                        host: "target".to_owned(),
                        instance: None,
                    },
                    data_roots: Vec::new(),
                })
                .collect(),
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        spec.declarative_scope = Some("abird-gondor".to_owned());
        spec.repository_owner = Some("abird".to_owned());
        MoveProjector::derive(
            &spec,
            &projection_config(),
            MovePhase::Seeded,
            None,
            Some(previous_revision),
        )
        .unwrap()
    }

    #[test]
    fn multi_service_move_consumes_exact_nix_resolved_repository_paths() {
        let projection = seeded_multi_service_projection("previous".to_owned());
        let identity = nix_move_identity(&projection).unwrap();
        let temporary = tempfile::tempdir().unwrap();
        let nix = temporary.path().join("nix");
        let trace = temporary.path().join("nix-arguments");
        write_executable(
            &nix,
            &format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\nprintf '%s' '{{\"schema_version\":1,\"mutations\":[{{\"domain\":\"serviceMoves\",\"kind\":\"service-move\",\"transaction\":\"move-suite\",\"path\":\"custom/moves/move-suite.declaration\"}},{{\"domain\":\"servicePlacements\",\"kind\":\"service-placement\",\"service\":\"zulip\",\"path\":\"custom/placements/zulip.declaration\"}},{{\"domain\":\"servicePlacements\",\"kind\":\"service-placement\",\"service\":\"zulip-worker\",\"path\":\"custom/placements/zulip-worker.declaration\"}}]}}'\n",
                trace.display()
            ),
        )
        .unwrap();
        let paths =
            resolve_nix_service_repository_paths(&nix, temporary.path(), &identity).unwrap();

        assert_eq!(
            paths.move_path,
            PathBuf::from("custom/moves/move-suite.declaration")
        );
        assert_eq!(
            paths.placement_paths,
            [
                "custom/placements/zulip.declaration",
                "custom/placements/zulip-worker.declaration",
            ]
            .map(PathBuf::from)
        );
        let arguments = fs::read_to_string(trace).unwrap();
        assert!(arguments.contains(".#hostManager.serviceMoveRepositoryMutationsFor"));
        assert!(arguments.contains("\"transaction\" = \"move-suite\";"));
        assert!(!arguments.contains("\"domain\" ="));
    }

    #[test]
    fn generated_hosts_derive_common_modules_from_stack_organization() {
        let generated = default_module(&record(ManagedHostSystem::Live));

        assert!(generated.contains("lib.path.append ../common \"${stack.org}.nix\""));
        assert!(generated.contains("builtins.pathExists commonModule"));
        assert!(
            !generated
                .lines()
                .any(|line| line.trim_start().starts_with("../common/"))
        );
    }

    #[test]
    fn generation_and_deletion_edit_existing_nix_sources_only() {
        let temp = fixture();
        let repository = Repository::from_root(temp.path().to_path_buf()).unwrap();
        repository
            .generate("demo-host", record(ManagedHostSystem::None), None, false)
            .unwrap();
        assert!(
            fs::read_to_string(temp.path().join(HOSTS_FILE))
                .unwrap()
                .contains("demo-host")
        );
        assert!(
            fs::read_to_string(temp.path().join(NIXBOT_FILE))
                .unwrap()
                .contains("demo-host")
        );
        assert!(!temp.path().join("data/hosts/managed.json").exists());
        repository.delete("demo-host").unwrap();
        assert!(!temp.path().join("hosts/demo-host").exists());
        assert!(
            !fs::read_to_string(temp.path().join(NIXBOT_FILE))
                .unwrap()
                .contains("demo-host")
        );
    }

    #[test]
    fn discovery_walks_up_from_nested_repository_directories() {
        let temp = fixture();
        let nested = temp.path().join("pkgs/tools/example");
        fs::create_dir_all(&nested).unwrap();

        let repository = Repository::discover_from(None, &nested).unwrap();

        assert_eq!(repository.root(), temp.path().canonicalize().unwrap());
        assert_eq!(
            repository.nixbot_config_path(),
            temp.path().canonicalize().unwrap().join(NIXBOT_FILE)
        );
    }

    #[test]
    fn projection_publisher_uses_owned_checkout_and_verifies_remote_revision() {
        let source = fixture();
        let remote = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        let git = PathBuf::from("git");
        let nix_arguments = state.path().join("nix-arguments");
        let fake_nix = state.path().join("fake-nix");
        write_executable(
            &fake_nix,
            format!(
                "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$*\" >> '{}'\ncase \"$1 $2\" in\n  'eval --json')\n    printf '['\n    cat data/phase-projections/move-publisher.json\n    printf ']'\n    ;;\n  'eval --raw') printf '/nix/store/fake-system.drv' ;;\n  *) exit 64 ;;\nesac\n",
                nix_arguments.display()
            ),
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &["init", "-b", "master"],
            "init source",
        )
        .unwrap();
        run_git(&git, source.path(), &["add", "--", "."], "stage fixture").unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "initial",
            ],
            "commit fixture",
        )
        .unwrap();
        run_git(&git, remote.path(), &["init", "--bare"], "init remote").unwrap();
        run_git_path(
            &git,
            source.path(),
            &["remote", "add", "origin"],
            remote.path(),
            "add fixture remote",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &["push", "-u", "origin", "master"],
            "publish fixture",
        )
        .unwrap();

        let git_invocations = state.path().join("git-invocations");
        let publisher_git = state.path().join("publisher-git");
        write_executable(
            &publisher_git,
            format!(
                "#!/bin/sh\nprintf '%s|%s\\n' \"$*\" \"${{GIT_SSH_COMMAND-<unset>}}\" >> '{}'\nexec git \"$@\"\n",
                git_invocations.display()
            ),
        )
        .unwrap();

        let source_repository = Repository::from_root(source.path().to_path_buf()).unwrap();
        let authority = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let publisher = ProjectionPublisher::prepare(
            &source_repository,
            &authority,
            state.path(),
            "master",
            publisher_git.clone(),
            fake_nix.clone(),
            Some("operator-publication-ssh".to_owned()),
        )
        .unwrap();
        let initial_revision = publisher.revision().unwrap();
        publisher.verify_push_access().unwrap();
        let projection = seeded_projection(initial_revision.clone());
        let publication = publisher.publish(&projection, "controller").unwrap();
        assert!(publication.pushed);
        assert_eq!(publication.revision.len(), 40);
        let remote_document = git_stdout(
            &git,
            remote.path(),
            &[
                "show",
                "refs/heads/master:data/phase-projections/move-publisher.json",
            ],
            "read published projection",
        )
        .unwrap();
        assert!(remote_document.contains(&projection.projection_sha256));
        assert!(!source.path().join("data/phase-projections").exists());
        let git_invocations = fs::read_to_string(&git_invocations).unwrap();
        assert!(git_invocations.contains(&format!(
            "push --dry-run origin {initial_revision}:refs/heads/master|operator-publication-ssh"
        )));
        assert!(git_invocations.contains(&format!(
            "push origin {}:refs/heads/master|operator-publication-ssh",
            publication.revision
        )));
        assert!(
            git_invocations.contains("ls-remote origin refs/heads/master|operator-publication-ssh")
        );
        assert!(
            git_invocations
                .lines()
                .filter(|line| line.starts_with("clone ") || line.starts_with("fetch "))
                .all(|line| !line.ends_with("|operator-publication-ssh"))
        );
        let nix_invocations = fs::read_to_string(nix_arguments).unwrap();
        let mut nix_invocations = nix_invocations.lines();
        assert_eq!(
            nix_invocations.next(),
            Some(
                "eval --json .#nixosConfigurations.\"controller\".config.services.abird-host-manager.phaseProjections --no-update-lock-file --no-write-lock-file --option allow-import-from-derivation false"
            )
        );
        assert_eq!(
            nix_invocations.collect::<BTreeSet<_>>(),
            ["controller", "source", "target"]
                .map(|host| format!(
                    "eval --raw .#nixosConfigurations.\"{host}\".config.system.build.toplevel.drvPath --no-update-lock-file --no-write-lock-file --option allow-import-from-derivation false"
                ))
                .iter()
                .map(String::as_str)
                .collect()
        );
        drop(publisher);

        let checkout = state.path().join("projection-repository");
        fs::write(checkout.join("interrupted-untracked"), "partial write\n").unwrap();
        fs::write(checkout.join("flake.nix"), "# interrupted tracked write\n").unwrap();
        run_git(
            &git,
            &checkout,
            &["add", "--", "."],
            "stage interrupted checkout",
        )
        .unwrap();
        run_git(
            &git,
            &checkout,
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "interrupted local commit",
            ],
            "commit interrupted checkout",
        )
        .unwrap();
        let recovered = ProjectionPublisher::prepare(
            &source_repository,
            &authority,
            state.path(),
            "master",
            publisher_git,
            fake_nix,
            Some("operator-publication-ssh".to_owned()),
        )
        .unwrap();
        assert_eq!(recovered.revision().unwrap(), publication.revision);
        assert!(!checkout.join("interrupted-untracked").exists());
        assert_ne!(
            fs::read_to_string(checkout.join("flake.nix")).unwrap(),
            "# interrupted tracked write\n"
        );
    }

    #[test]
    fn local_projection_publisher_commits_in_source_without_remote_operations() {
        let source = fixture();
        let state = tempfile::tempdir().unwrap();
        let git = PathBuf::from("git");
        run_git(
            &git,
            source.path(),
            &["init", "-b", "master"],
            "init local source",
        )
        .unwrap();
        run_git(&git, source.path(), &["add", "--", "."], "stage fixture").unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "initial",
            ],
            "commit fixture",
        )
        .unwrap();

        let fake_nix = state.path().join("fake-nix");
        write_executable(
            &fake_nix,
            "#!/bin/sh\nset -eu\ncase \"$1 $2\" in\n  'eval --json') printf '['; cat data/phase-projections/move-publisher.json; printf ']' ;;\n  'eval --raw') printf '/nix/store/fake-system.drv' ;;\n  *) exit 64 ;;\nesac\n",
        )
        .unwrap();
        let invocations = state.path().join("git-invocations");
        let publisher_git = state.path().join("publisher-git");
        write_executable(
            &publisher_git,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\nexec git \"$@\"\n",
                invocations.display()
            ),
        )
        .unwrap();

        let source_repository = Repository::from_root(source.path().to_path_buf()).unwrap();
        let authority = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let publisher = ProjectionPublisher::prepare_local(
            &source_repository,
            &authority,
            state.path(),
            "master",
            publisher_git.clone(),
            fake_nix.clone(),
        )
        .unwrap();
        let concurrent_state = tempfile::tempdir().unwrap();
        let concurrent_authority =
            WorkflowStore::open(concurrent_state.path().to_path_buf()).unwrap();
        let concurrent = ProjectionPublisher::prepare_local(
            &source_repository,
            &concurrent_authority,
            concurrent_state.path(),
            "master",
            publisher_git,
            fake_nix,
        )
        .unwrap_err();
        let contention = format!("{concurrent:#}");
        assert!(
            contention.contains("another projection publication is still active")
                || contention.contains("another host-manager publication is mutating")
        );
        assert_eq!(publisher.mode(), ProjectionPublicationMode::Local);
        publisher.verify_push_access().unwrap();
        let projection = seeded_projection(publisher.revision().unwrap());
        let mut events = Vec::new();
        let publication = publisher
            .publish_observed_with_hints(&projection, "controller", None, |event| {
                events.push(event);
                Ok(())
            })
            .unwrap();

        assert!(!publication.pushed);
        assert!(source.path().join(&publication.write.path).is_file());
        assert_eq!(publisher.revision().unwrap(), publication.revision);
        assert_eq!(
            events
                .iter()
                .filter_map(|event| match event {
                    ProjectionPublicationEvent::Started(stage)
                    | ProjectionPublicationEvent::Completed { stage, .. } => Some(*stage),
                    ProjectionPublicationEvent::Progress { .. } => None,
                })
                .collect::<Vec<_>>(),
            [
                ProjectionPublicationStage::Validate,
                ProjectionPublicationStage::Validate,
                ProjectionPublicationStage::Commit,
                ProjectionPublicationStage::Commit,
                ProjectionPublicationStage::RetainLocal,
                ProjectionPublicationStage::RetainLocal,
                ProjectionPublicationStage::Verify,
                ProjectionPublicationStage::Verify,
            ]
        );
        assert!(
            source_repository
                .load_runtime_projection_closeouts()
                .unwrap()
                .controller_reconcile_exclusions
                .contains(&projection.projection_id)
        );
        source_repository
            .write_projection_closeout(&projection, "complete", false)
            .unwrap();
        assert!(
            !source_repository
                .load_runtime_projection_closeouts()
                .unwrap()
                .controller_reconcile_exclusions
                .contains(&projection.projection_id)
        );
        assert!(
            !source_repository
                .load_projection_closeout(&projection.projection_id)
                .unwrap()
                .unwrap()
                .controller_reconcile
        );
        let invocations = fs::read_to_string(invocations).unwrap();
        for forbidden in ["push", "fetch", "clone", "ls-remote"] {
            assert!(
                !invocations
                    .lines()
                    .any(|line| line.split_whitespace().next() == Some(forbidden)),
                "local publisher unexpectedly invoked {forbidden}: {invocations}"
            );
        }
    }

    #[test]
    fn failed_local_publication_restores_only_its_owned_repository_paths() {
        let source = fixture();
        let state = tempfile::tempdir().unwrap();
        let git = PathBuf::from("git");
        run_git(
            &git,
            source.path(),
            &["init", "-b", "master"],
            "init local recovery source",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &["add", "--", "."],
            "stage local recovery fixture",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "initial",
            ],
            "commit local recovery fixture",
        )
        .unwrap();

        let fake_nix = state.path().join("failing-nix");
        write_executable(&fake_nix, "#!/bin/sh\nexit 73\n").unwrap();
        let source_repository = Repository::from_root(source.path().to_path_buf()).unwrap();
        let authority = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let publisher = ProjectionPublisher::prepare_local(
            &source_repository,
            &authority,
            state.path(),
            "master",
            git.clone(),
            fake_nix,
        )
        .unwrap();
        let projection = seeded_projection(publisher.revision().unwrap());

        let error = publisher.publish(&projection, "controller").unwrap_err();
        assert!(
            error
                .to_string()
                .contains("evaluate staged phase projections")
        );
        assert!(
            !source
                .path()
                .join("data/phase-projections/move-publisher.json")
                .exists()
        );
        assert!(
            !state
                .path()
                .join("local-publication-recovery.json")
                .exists()
        );
        assert!(
            git_stdout(
                &git,
                source.path(),
                &["status", "--porcelain", "--untracked-files=normal"],
                "verify recovered local publication checkout",
            )
            .unwrap()
            .is_empty()
        );
    }

    fn recovery_publisher() -> (
        tempfile::TempDir,
        tempfile::TempDir,
        ProjectionPublisher,
        PathBuf,
    ) {
        let source = fixture();
        let state = tempfile::tempdir().unwrap();
        let git = PathBuf::from("git");
        fs::write(source.path().join("owned.nix"), "before\n").unwrap();
        run_git(
            &git,
            source.path(),
            &["init", "-b", "master"],
            "init recovery source",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &["add", "--", "."],
            "stage recovery source",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "initial",
            ],
            "commit recovery source",
        )
        .unwrap();
        let repository = Repository::from_root(source.path().to_path_buf()).unwrap();
        let authority = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let publisher = ProjectionPublisher::prepare_local(
            &repository,
            &authority,
            state.path(),
            "master",
            git.clone(),
            PathBuf::from("false"),
        )
        .unwrap();
        (source, state, publisher, git)
    }

    #[test]
    fn planned_postimages_recover_a_failure_before_staging() {
        let (source, state, publisher, git) = recovery_publisher();
        let error = publisher
            .apply_owned_publication_with_observer(
                "runtime-only projection",
                vec![
                    OwnedPathMutation::Write {
                        path: PathBuf::from("owned.nix"),
                        contents: b"after\n".to_vec(),
                        mode: 0o644,
                    },
                    OwnedPathMutation::Write {
                        path: PathBuf::from("new.nix"),
                        contents: b"new\n".to_vec(),
                        mode: 0o644,
                    },
                ],
                |index| {
                    if index == 0 {
                        bail!("injected failure before staging");
                    }
                    Ok(())
                },
            )
            .unwrap_err();

        assert!(error.to_string().contains("injected failure"));
        assert_eq!(
            fs::read_to_string(source.path().join("owned.nix")).unwrap(),
            "before\n"
        );
        assert!(!source.path().join("new.nix").exists());
        assert!(
            !state
                .path()
                .join("local-publication-recovery.json")
                .exists()
        );
        assert!(
            git_stdout(
                &git,
                source.path(),
                &["status", "--porcelain", "--untracked-files=normal"],
                "verify recovered pre-staging failure",
            )
            .unwrap()
            .is_empty()
        );
    }

    #[test]
    fn local_publication_lease_is_shared_across_linked_worktrees() {
        let (source, _source_state, source_publisher, git) = recovery_publisher();
        let linked = tempfile::tempdir().unwrap();
        run_git_path(
            &git,
            source.path(),
            &["worktree", "add", "-b", "linked"],
            linked.path(),
            "create linked publication checkout",
        )
        .unwrap();
        let linked_repository = Repository::from_root(linked.path().to_path_buf()).unwrap();
        let linked_state = tempfile::tempdir().unwrap();
        let linked_authority = WorkflowStore::open(linked_state.path().to_path_buf()).unwrap();
        let prepare_linked = || {
            ProjectionPublisher::prepare_local(
                &linked_repository,
                &linked_authority,
                linked_state.path(),
                "linked",
                git.clone(),
                PathBuf::from("false"),
            )
        };
        let prepare_after_release = |prepare: &dyn Fn() -> Result<ProjectionPublisher>| {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(1);
            loop {
                match prepare() {
                    Ok(publisher) => break publisher,
                    Err(error)
                        if error.to_string().contains("mutating this Git repository")
                            && std::time::Instant::now() < deadline =>
                    {
                        // A child forked by another parallel test can briefly
                        // inherit the close-on-exec lease descriptor. Wait for
                        // that child to exec and close it before asserting that
                        // dropping the publisher released the lease.
                        std::thread::yield_now();
                    }
                    Err(error) => panic!("publication lease was not released: {error:#}"),
                }
            }
        };
        let error = prepare_linked()
            .expect_err("linked checkout must contend with the main checkout publisher");
        assert!(error.to_string().contains("mutating this Git repository"));
        drop(source_publisher);
        let linked_publisher = prepare_after_release(&prepare_linked);

        let source_repository = Repository::from_root(source.path().to_path_buf()).unwrap();
        let other_source_state = tempfile::tempdir().unwrap();
        let other_source_authority =
            WorkflowStore::open(other_source_state.path().to_path_buf()).unwrap();
        let prepare_source = || {
            ProjectionPublisher::prepare_local(
                &source_repository,
                &other_source_authority,
                other_source_state.path(),
                "master",
                git.clone(),
                PathBuf::from("false"),
            )
        };
        let error = prepare_source()
            .expect_err("main checkout must contend with the linked checkout publisher");
        assert!(error.to_string().contains("mutating this Git repository"));
        drop(linked_publisher);
        prepare_after_release(&prepare_source);
    }

    #[test]
    fn local_recovery_refuses_same_path_content_drift() {
        let (source, state, publisher, git) = recovery_publisher();
        let path = PathBuf::from("owned.nix");
        let mut guard = publisher
            .begin_local_publication([path.clone()])
            .unwrap()
            .unwrap();
        fs::write(source.path().join(&path), "published\n").unwrap();
        run_git_path(
            &git,
            source.path(),
            &["add", "--"],
            &path,
            "stage expected recovery postimage",
        )
        .unwrap();
        guard.record_postimages().unwrap();
        fs::write(source.path().join(&path), "human edit\n").unwrap();
        std::mem::forget(guard);

        let marker = state.path().join("local-publication-recovery.json");
        let error = recover_local_publication(&git, source.path(), &marker).unwrap_err();
        assert!(error.to_string().contains("content drift"));
        assert_eq!(
            fs::read_to_string(source.path().join(path)).unwrap(),
            "human edit\n"
        );
        assert!(marker.exists());
    }

    #[test]
    fn local_recovery_checks_branch_before_removing_recorded_temporaries() {
        let (source, state, publisher, git) = recovery_publisher();
        let guard = publisher
            .apply_owned_publication(
                "test",
                vec![OwnedPathMutation::Write {
                    path: PathBuf::from("owned.nix"),
                    contents: b"published\n".to_vec(),
                    mode: 0o644,
                }],
            )
            .unwrap()
            .unwrap();
        let expected = publisher.revision().unwrap();
        run_git(
            &git,
            source.path(),
            &["branch", "other", &expected],
            "create recovery branch fixture",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &["symbolic-ref", "HEAD", "refs/heads/other"],
            "switch recovery branch fixture",
        )
        .unwrap();
        let temporary = source.path().join(".owned.nix.abird-host-manager.tmp");
        fs::write(&temporary, "other branch temporary\n").unwrap();
        std::mem::forget(guard);

        let marker = state.path().join("local-publication-recovery.json");
        let error = recover_local_publication(&git, source.path(), &marker).unwrap_err();

        assert!(error.to_string().contains("belongs to branch"));
        assert!(temporary.exists());
        run_git(
            &git,
            source.path(),
            &["symbolic-ref", "HEAD", "refs/heads/master"],
            "restore recovery branch fixture",
        )
        .unwrap();
        recover_local_publication(&git, source.path(), &marker).unwrap();
        assert!(!temporary.exists());
        assert!(!marker.exists());
    }

    #[test]
    fn local_recovery_accepts_only_the_exact_completed_commit() {
        let (source, state, publisher, git) = recovery_publisher();
        let path = PathBuf::from("owned.nix");
        let mut guard = publisher
            .begin_local_publication([path.clone()])
            .unwrap()
            .unwrap();
        fs::write(source.path().join(&path), "published\n").unwrap();
        run_git_path(
            &git,
            source.path(),
            &["add", "--"],
            &path,
            "stage exact recovery commit",
        )
        .unwrap();
        guard.record_postimages().unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "publication",
                "--",
                "owned.nix",
            ],
            "commit exact recovery publication",
        )
        .unwrap();
        std::mem::forget(guard);

        let marker = state.path().join("local-publication-recovery.json");
        recover_local_publication(&git, source.path(), &marker).unwrap();
        assert!(!marker.exists());
        assert_eq!(
            fs::read_to_string(source.path().join(path)).unwrap(),
            "published\n"
        );
    }

    #[test]
    fn local_recovery_discovers_publication_before_commit_identity_is_recorded() {
        let (source, state, publisher, git) = recovery_publisher();
        let path = PathBuf::from("owned.nix");
        let mut guard = publisher
            .begin_local_publication([path.clone()])
            .unwrap()
            .unwrap();
        fs::write(source.path().join(&path), "published\n").unwrap();
        run_git_path(
            &git,
            source.path(),
            &["add", "--"],
            &path,
            "stage publication before commit identity recording",
        )
        .unwrap();
        guard.record_postimages().unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "publication",
                "--",
                "owned.nix",
            ],
            "commit publication before identity recording",
        )
        .unwrap();
        fs::write(source.path().join("later.nix"), "later\n").unwrap();
        run_git(
            &git,
            source.path(),
            &["add", "--", "later.nix"],
            "stage descendant before recovery",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "later",
            ],
            "commit descendant before recovery",
        )
        .unwrap();
        std::mem::forget(guard);

        let marker = state.path().join("local-publication-recovery.json");
        recover_local_publication(&git, source.path(), &marker).unwrap();

        assert!(!marker.exists());
        assert_eq!(
            fs::read_to_string(source.path().join(path)).unwrap(),
            "published\n"
        );
    }

    #[test]
    fn local_recovery_rejects_a_commit_with_foreign_paths() {
        let (source, state, publisher, git) = recovery_publisher();
        let path = PathBuf::from("owned.nix");
        let mut guard = publisher
            .begin_local_publication([path.clone()])
            .unwrap()
            .unwrap();
        fs::write(source.path().join(&path), "published\n").unwrap();
        fs::write(source.path().join("foreign.nix"), "foreign\n").unwrap();
        run_git(
            &git,
            source.path(),
            &["add", "--", "owned.nix", "foreign.nix"],
            "stage publication with foreign path",
        )
        .unwrap();
        guard.record_postimages().unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "mixed publication",
            ],
            "commit publication with foreign path",
        )
        .unwrap();
        std::mem::forget(guard);

        let marker = state.path().join("local-publication-recovery.json");
        let error = recover_local_publication(&git, source.path(), &marker).unwrap_err();
        assert!(error.to_string().contains("no exact commit"));
        assert!(marker.exists());
    }

    #[test]
    fn cleanup_guard_rejects_head_and_worktree_drift() {
        let (source, _state, publisher, git) = recovery_publisher();
        let expected = publisher.revision().unwrap();
        fs::write(source.path().join("owned.nix"), "dirty\n").unwrap();
        assert!(
            publisher
                .require_exact_clean_revision(&expected, "cleanup")
                .unwrap_err()
                .to_string()
                .contains("requires a clean repository")
        );
        run_git_path(
            &git,
            source.path(),
            &["add", "--"],
            Path::new("owned.nix"),
            "stage unrelated cleanup commit",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "unrelated",
            ],
            "commit unrelated cleanup predecessor",
        )
        .unwrap();
        assert!(
            publisher
                .require_exact_clean_revision(&expected, "cleanup")
                .unwrap_err()
                .to_string()
                .contains("refusing to include unrelated commits")
        );
    }

    #[test]
    fn local_publication_rechecks_clean_base_immediately_before_mutation() {
        let (source, state, publisher, _git) = recovery_publisher();
        fs::write(source.path().join("owned.nix"), "human edit\n").unwrap();

        let error = publisher
            .begin_local_publication([PathBuf::from("owned.nix")])
            .expect_err("dirty publication must fail");
        assert!(error.to_string().contains("requires a clean repository"));
        assert_eq!(
            fs::read_to_string(source.path().join("owned.nix")).unwrap(),
            "human edit\n"
        );
        assert!(
            !state
                .path()
                .join("local-publication-recovery.json")
                .exists()
        );
    }

    #[test]
    fn local_publication_rejects_a_clean_commit_after_preparation() {
        let (source, state, publisher, git) = recovery_publisher();
        fs::write(source.path().join("unrelated.nix"), "unrelated\n").unwrap();
        run_git(
            &git,
            source.path(),
            &["add", "--", "unrelated.nix"],
            "stage unrelated local publication commit",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "unrelated",
            ],
            "commit unrelated local publication predecessor",
        )
        .unwrap();

        let error = publisher
            .begin_local_publication([PathBuf::from("owned.nix")])
            .expect_err("advanced publication base must fail");
        assert!(
            error
                .to_string()
                .contains("refusing to include unrelated commits")
        );
        assert!(
            !state
                .path()
                .join("local-publication-recovery.json")
                .exists()
        );
    }

    #[test]
    fn publication_commit_rejects_foreign_untracked_drift_after_staging() {
        let (source, state, publisher, _git) = recovery_publisher();
        let expected = publisher.revision().unwrap();
        let recovery = publisher
            .apply_owned_publication(
                "test",
                vec![OwnedPathMutation::Write {
                    path: PathBuf::from("owned.nix"),
                    contents: b"published\n".to_vec(),
                    mode: 0o644,
                }],
            )
            .unwrap();
        let foreign = source.path().join("foreign-untracked");
        fs::write(&foreign, "foreign\n").unwrap();

        let error = publisher
            .commit_owned_publication_paths(
                &expected,
                &[PathBuf::from("owned.nix")],
                "test publication",
                "commit test publication",
            )
            .unwrap_err();

        assert!(error.to_string().contains("outside its owned paths"));
        assert_eq!(publisher.revision().unwrap(), expected);
        fs::remove_file(foreign).unwrap();
        drop(recovery);
        assert!(
            !state
                .path()
                .join("local-publication-recovery.json")
                .exists()
        );
    }

    #[test]
    fn publication_commit_rejects_head_advance_after_staging() {
        let (source, state, publisher, git) = recovery_publisher();
        let expected = publisher.revision().unwrap();
        let recovery = publisher
            .apply_owned_publication(
                "test",
                vec![OwnedPathMutation::Write {
                    path: PathBuf::from("owned.nix"),
                    contents: b"published\n".to_vec(),
                    mode: 0o644,
                }],
            )
            .unwrap();
        fs::write(source.path().join("foreign-head"), "foreign\n").unwrap();
        run_git(
            &git,
            source.path(),
            &["add", "--", "foreign-head"],
            "stage concurrent foreign revision",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "--only",
                "-m",
                "foreign",
                "--",
                "foreign-head",
            ],
            "commit concurrent foreign revision",
        )
        .unwrap();

        let error = publisher
            .commit_owned_publication_paths(
                &expected,
                &[PathBuf::from("owned.nix")],
                "test publication",
                "commit test publication",
            )
            .unwrap_err();

        assert!(error.to_string().contains("expected repository revision"));
        run_git(
            &git,
            source.path(),
            &["reset", "--hard", &expected],
            "restore publication race fixture",
        )
        .unwrap();
        drop(recovery);
        assert!(
            !state
                .path()
                .join("local-publication-recovery.json")
                .exists()
        );
    }

    #[test]
    fn publication_ref_update_reverts_branch_switch_and_observer_failure() {
        let (source, _state, publisher, git) = recovery_publisher();
        let expected = publisher.revision().unwrap();
        run_git(
            &git,
            source.path(),
            &["branch", "other", &expected],
            "create competing publication branch",
        )
        .unwrap();
        let tree = git_stdout(
            &git,
            source.path(),
            &["rev-parse", &format!("{expected}^{{tree}}")],
            "resolve publication race tree",
        )
        .unwrap();
        let revision = git_stdout(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit-tree",
                &tree,
                "-p",
                &expected,
                "-m",
                "publication race",
            ],
            "create publication race commit",
        )
        .unwrap();

        let branch_switch = publisher
            .update_checked_out_branch_observed(
                &revision,
                &expected,
                "test publication branch switch",
                || {
                    run_git(
                        &git,
                        source.path(),
                        &["symbolic-ref", "HEAD", "refs/heads/other"],
                        "inject publication branch switch",
                    )
                },
            )
            .unwrap_err();
        assert!(branch_switch.to_string().contains("reverted"));
        assert_eq!(
            git_stdout(
                &git,
                source.path(),
                &["rev-parse", "refs/heads/master"],
                "verify reverted publication branch",
            )
            .unwrap(),
            expected
        );
        run_git(
            &git,
            source.path(),
            &["symbolic-ref", "HEAD", "refs/heads/master"],
            "restore publication test branch",
        )
        .unwrap();

        let observer_failure = publisher
            .update_checked_out_branch_observed(
                &revision,
                &expected,
                "test publication observer failure",
                || bail!("injected observer failure"),
            )
            .unwrap_err();
        assert!(observer_failure.to_string().contains("reverted"));
        assert_eq!(publisher.revision().unwrap(), expected);
    }

    #[test]
    fn local_publication_finalizes_despite_unrelated_post_commit_drift() {
        let (source, state, publisher, git) = recovery_publisher();
        let expected = publisher.revision().unwrap();
        let mut recovery = publisher
            .apply_owned_publication(
                "test",
                vec![OwnedPathMutation::Write {
                    path: PathBuf::from("owned.nix"),
                    contents: b"published\n".to_vec(),
                    mode: 0o644,
                }],
            )
            .unwrap()
            .unwrap();
        let revision = publisher
            .commit_owned_publication_paths(
                &expected,
                &[PathBuf::from("owned.nix")],
                "test publication",
                "commit test publication",
            )
            .unwrap();
        recovery.record_committed_revision(&revision).unwrap();
        let foreign = source.path().join("foreign-after-commit");
        fs::write(&foreign, "foreign\n").unwrap();

        recovery.complete(&revision).unwrap();

        let marker = state.path().join("local-publication-recovery.json");
        assert!(!marker.exists());
        fs::remove_file(foreign).unwrap();
        recover_local_publication(&git, source.path(), &marker).unwrap();
        assert!(!marker.exists());
    }

    #[test]
    fn local_recovery_accepts_unrelated_descendants_of_the_recorded_commit() {
        let (source, state, publisher, git) = recovery_publisher();
        let expected = publisher.revision().unwrap();
        let mut recovery = publisher
            .apply_owned_publication(
                "test",
                vec![OwnedPathMutation::Write {
                    path: PathBuf::from("owned.nix"),
                    contents: b"published\n".to_vec(),
                    mode: 0o644,
                }],
            )
            .unwrap()
            .unwrap();
        let revision = publisher
            .commit_owned_publication_paths(
                &expected,
                &[PathBuf::from("owned.nix")],
                "test publication",
                "commit test publication",
            )
            .unwrap();
        recovery.record_committed_revision(&revision).unwrap();
        fs::write(source.path().join("unrelated.nix"), "later\n").unwrap();
        run_git(
            &git,
            source.path(),
            &["add", "--", "unrelated.nix"],
            "stage unrelated descendant",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "unrelated descendant",
            ],
            "commit unrelated descendant",
        )
        .unwrap();

        recovery.complete(&revision).unwrap();

        assert!(
            !state
                .path()
                .join("local-publication-recovery.json")
                .exists()
        );
        assert_eq!(
            fs::read_to_string(source.path().join("owned.nix")).unwrap(),
            "published\n"
        );
        assert_eq!(
            fs::read_to_string(source.path().join("unrelated.nix")).unwrap(),
            "later\n"
        );
    }

    #[test]
    fn publication_transport_rejects_observer_drift_before_transport() {
        let (source, _state, publisher, _git) = recovery_publisher();
        let revision = publisher.revision().unwrap();
        let foreign = source.path().join("foreign-before-transport");

        let error = publisher
            .finish_publication_transport(
                &revision,
                "unused push",
                "unused verification",
                "unused mismatch",
                || bail!("transport must not run after repository drift"),
                |stage, completed| {
                    if stage == PublicationTransportStage::RetainLocal && !completed {
                        fs::write(&foreign, "foreign\n")?;
                    }
                    Ok(())
                },
            )
            .unwrap_err();

        assert!(error.to_string().contains("requires a clean repository"));
        fs::remove_file(foreign).unwrap();
    }

    #[test]
    fn local_service_move_publishes_nix_and_consumes_evaluated_contract() {
        let source = fixture();
        let state = tempfile::tempdir().unwrap();
        let git = PathBuf::from("git");
        fs::create_dir_all(source.path().join("config/abird/placements/abird-gondor")).unwrap();
        fs::write(
            source
                .path()
                .join("config/abird/placements/abird-gondor/zulip.nix"),
            "{ role = \"source-role\"; }\n",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &["init", "-b", "master"],
            "init local source",
        )
        .unwrap();
        run_git(&git, source.path(), &["add", "--", "."], "stage fixture").unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "initial",
            ],
            "commit fixture",
        )
        .unwrap();

        let source_repository = Repository::from_root(source.path().to_path_buf()).unwrap();
        let authority = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let revision = source_repository.revision(&git).unwrap();
        let projection = seeded_service_projection(revision);
        let basis_digest = projection.intent_sha256.clone();
        let seeded_projection_json = state.path().join("seeded-projection.json");
        let prepared_projection_json = state.path().join("prepared-projection.json");
        let cutover_projection_json = state.path().join("cutover-projection.json");
        let seeded_declaration_json = state.path().join("seeded-declaration.json");
        let prepared_declaration_json = state.path().join("prepared-declaration.json");
        let cutover_declaration_json = state.path().join("cutover-declaration.json");
        fs::write(
            &seeded_projection_json,
            serde_json::to_vec(&projection).unwrap(),
        )
        .unwrap();
        let write_declaration = |path: &Path,
                                 projection: &PhaseProjection,
                                 phase: &str,
                                 activation_attempt: u64,
                                 decision: Option<&str>| {
            fs::write(
                path,
                serde_json::to_vec(&serde_json::json!({
                    "schema_version": 4,
                    "id": "move-publisher",
                    "authority": "local",
                    "scope": "abird-gondor",
                    "items": [{
                        "id": "item-001",
                        "service": "zulip",
                        "from": "source-role",
                        "to": "target-role",
                        "basis_sha256": basis_digest.clone(),
                    }],
                    "desired": {
                        "phase": phase,
                        "generation": projection.generation,
                        "activationAttempts": {
                            "item-001": {
                                "source": activation_attempt,
                                "target": activation_attempt,
                            },
                        },
                        "leases": {
                            "item-001": {
                                "source": if phase == "moved" { serde_json::Value::Null } else { serde_json::json!(1) },
                                "target": 1,
                            },
                        },
                    },
                    "decision": decision,
                    "previous": {
                        "contract_sha256": projection.previous_projection_sha256,
                        "repository_revision": projection.previous_repository_revision,
                    },
                }))
                .unwrap(),
            )
            .unwrap();
        };
        write_declaration(&seeded_declaration_json, &projection, "moved", 1, None);
        let fake_nix = state.path().join("fake-nix");
        write_executable(
            &fake_nix,
            format!(
                r#"#!/bin/sh
set -eu
case "$1 $2 $3" in
  'eval --json .#hostManager.serviceMoveRepositoryMutationsFor')
    printf '{{"schema_version":1,"mutations":[{{"domain":"serviceMoves","kind":"service-move","transaction":"move-publisher","path":"config/abird/moves/move-publisher.nix"}},{{"domain":"servicePlacements","kind":"service-placement","service":"zulip","path":"config/abird/placements/abird-gondor/zulip.nix"}}]}}'
    ;;
  'eval --json .#hostManager.projectionSnapshot')
    basis='{}'
    role=source-role
    grep -q '"role" = "target-role"' config/abird/placements/abird-gondor/zulip.nix && role=target-role
    printf '{{"schema_version":1,"repository":{{"schema_version":1,"owners":[{{"domain":"servicePlacements","kind":"service-placement","path":"config/abird/placements/abird-gondor/zulip.nix"}}'
    if [ -f config/abird/moves/move-publisher.nix ] && git ls-files --error-unmatch -- config/abird/moves/move-publisher.nix >/dev/null 2>&1; then
      printf ',{{"domain":"serviceMoves","kind":"service-move","path":"config/abird/moves/move-publisher.nix"}}'
    fi
    printf '],"scopes":{{"abird-gondor":{{"owner":"abird","move_directory":"config/abird/moves","placement_directory":"config/abird/placements/abird-gondor"}}}}}},"service_moves":'
    if [ -f config/abird/moves/move-publisher.nix ] && git ls-files --error-unmatch -- config/abird/moves/move-publisher.nix >/dev/null 2>&1; then
      projection='{}'
      declaration='{}'
      if grep -q '"phase" = "prepared"' config/abird/moves/move-publisher.nix; then
        projection='{}'
        declaration='{}'
      elif grep -q -E '"phase" = "(target-active|adopting-target)"' config/abird/moves/move-publisher.nix; then
        projection='{}'
        declaration='{}'
      fi
      printf '{{"schema_version":2,"basis_catalog":{{"abird-gondor":{{"zulip":{{"source-role":{{"target-role":"%s"}}}}}}}},"controller_reconcile_exclusions":["move-publisher"],"moves":{{"move-publisher":{{"affected_hosts":["source","target","router"],"basis_sha256":"%s","semantic_sha256":"%s","declaration":' "$basis" "$basis" "$basis"
      if grep -q '"phase" = "adopting-target"' config/abird/moves/move-publisher.nix; then
        jq -c '.desired.phase = "adopting-target" | .decision = "complete"' "$declaration"
      else
        cat "$declaration"
      fi
      printf ',"projection":'
      cat "$projection"
      if grep -q '"phase" = "adopting-target"' config/abird/moves/move-publisher.nix; then
        selected=target-role
        stable=target-role
      else
        selected=source-role
        stable=source-role
      fi
      printf ',"items":[{{"id":"item-001","service":"zulip","from":"source-role","to":"target-role","basis_sha256":"%s","selected_role":"%s","stable_role":"%s","migration":{{}}}}],"services":["zulip"]}}}}}}' "$basis" "$selected" "$stable"
    else
      printf '{{"schema_version":2,"basis_catalog":{{"abird-gondor":{{"zulip":{{"source-role":{{"target-role":"%s"}}}}}}}},"controller_reconcile_exclusions":[],"moves":{{}}}}' "$basis"
    fi
    printf ',"service_placements":{{"schema_version":3,"placements":{{"abird-gondor":{{"zulip":{{"role":"%s"}}}}}}}},"runtime_plans":' "$role"
    if [ -f config/abird/moves/move-publisher.nix ] && git ls-files --error-unmatch -- config/abird/moves/move-publisher.nix >/dev/null 2>&1; then
      projection='{}'
      grep -q '"phase" = "prepared"' config/abird/moves/move-publisher.nix && projection='{}'
      grep -q -E '"phase" = "(target-active|adopting-target)"' config/abird/moves/move-publisher.nix && projection='{}'
      printf '[{{"schema_version":1,"adapter":"host-phase-projection","payload":'
      cat "$projection"
      printf '}}]'
    else
      printf '[]'
    fi
    printf ',"scope_role_endpoints":{{"abird-gondor":{{"source-role":{{"host":"source","host_resource":"host:source"}},"target-role":{{"host":"target","host_resource":"host:target"}}}}}}}}'
    ;;
  'eval --json .#hostManager.scopes') printf '["source-role","target-role"]' ;;
  eval\ --json\ .#nixosConfigurations.*)
    if [ -f config/abird/moves/move-publisher.nix ] && git ls-files --error-unmatch -- config/abird/moves/move-publisher.nix >/dev/null 2>&1; then
      projection='{}'
      grep -q '"phase" = "prepared"' config/abird/moves/move-publisher.nix && projection='{}'
      grep -q -E '"phase" = "(target-active|adopting-target)"' config/abird/moves/move-publisher.nix && projection='{}'
      printf '['; cat "$projection"; printf ']'
    else
      printf '[]'
    fi
    ;;
  'eval --raw .#hostManager.scopes')
    if grep -q '"role" = "target-role"' config/abird/placements/abird-gondor/zulip.nix; then printf target; else printf source; fi
    ;;
  eval\ --raw\ .#nixosConfigurations.*) printf '/nix/store/fake-system.drv' ;;
  *) exit 64 ;;
esac
"#,
                basis_digest,
                seeded_projection_json.display(),
                seeded_declaration_json.display(),
                prepared_projection_json.display(),
                prepared_declaration_json.display(),
                cutover_projection_json.display(),
                cutover_declaration_json.display(),
                seeded_projection_json.display(),
                prepared_projection_json.display(),
                cutover_projection_json.display(),
                seeded_projection_json.display(),
                prepared_projection_json.display(),
                cutover_projection_json.display(),
            ),
        )
        .unwrap();
        let publisher = ProjectionPublisher::prepare_local(
            &source_repository,
            &authority,
            state.path(),
            "master",
            git.clone(),
            fake_nix,
        )
        .unwrap();
        let publication = publisher.publish(&projection, "controller").unwrap();

        assert_eq!(publication.projection, projection);
        let idempotent = publisher.publish(&projection, "controller").unwrap();
        assert!(!idempotent.write.changed);
        assert_eq!(idempotent.projection, projection);
        let mut mismatched_projection = projection.clone();
        mismatched_projection.resources.swap(0, 1);
        let mut unsigned = serde_json::to_value(&mismatched_projection).unwrap();
        unsigned
            .as_object_mut()
            .unwrap()
            .remove("projection_sha256");
        mismatched_projection.projection_sha256 = canonical_sha256(&unsigned).unwrap();
        let drift_error = publisher
            .publish(&mismatched_projection, "controller")
            .unwrap_err();
        assert!(
            drift_error
                .to_string()
                .contains("retained different projected content")
        );
        let foreign_untracked = source.path().join("foreign-untracked");
        fs::write(&foreign_untracked, "foreign\n").unwrap();
        let dirty_error = publisher
            .publish(&mismatched_projection, "controller")
            .unwrap_err();
        assert!(
            dirty_error
                .to_string()
                .contains("requires a clean repository")
        );
        fs::remove_file(foreign_untracked).unwrap();

        let mut same_phase_successor = mismatched_projection;
        same_phase_successor.generation += 1;
        same_phase_successor.previous_projection_sha256 =
            Some(projection.projection_sha256.clone());
        same_phase_successor.previous_repository_revision = Some(publisher.revision().unwrap());
        let mut unsigned = serde_json::to_value(&same_phase_successor).unwrap();
        unsigned
            .as_object_mut()
            .unwrap()
            .remove("projection_sha256");
        same_phase_successor.projection_sha256 = canonical_sha256(&unsigned).unwrap();
        fs::write(
            &seeded_projection_json,
            serde_json::to_vec(&same_phase_successor).unwrap(),
        )
        .unwrap();
        write_declaration(
            &seeded_declaration_json,
            &same_phase_successor,
            "moved",
            1,
            None,
        );
        let successor_publication = publisher
            .publish(&same_phase_successor, "controller")
            .unwrap();
        assert_eq!(successor_publication.projection, same_phase_successor);
        let projection = same_phase_successor;
        assert_eq!(
            publisher
                .load_projection_admission("move-publisher")
                .unwrap(),
            ProjectionAdmission {
                projection: Some(projection.clone()),
                requires_existing_journal: false,
            }
        );
        assert!(
            source
                .path()
                .join("config/abird/moves/move-publisher.nix")
                .is_file()
        );
        assert!(!source.path().join("config/abird-gondor").exists());
        assert!(!source.path().join("data/phase-projections").exists());
        let declaration =
            fs::read_to_string(source.path().join("config/abird/moves/move-publisher.nix"))
                .unwrap();
        assert!(declaration.contains("\"authority\" = \"local\";"));
        assert!(declaration.contains("\"service\" = \"zulip\";"));
        assert!(declaration.contains(&format!("\"basis_sha256\" = \"{basis_digest}\";")));
        assert!(!declaration.contains("projection_sha256"));

        let spec: TransactionSpec = serde_json::from_value(projection.intent.clone()).unwrap();
        let prepared = MoveProjector::derive(
            &spec,
            &projection_config(),
            MovePhase::Prepared,
            Some(&projection),
            Some(publisher.revision().unwrap()),
        )
        .unwrap();
        fs::write(
            &prepared_projection_json,
            serde_json::to_vec(&prepared).unwrap(),
        )
        .unwrap();
        write_declaration(&prepared_declaration_json, &prepared, "prepared", 1, None);
        let prepared_publication = publisher.publish(&prepared, "controller").unwrap();
        assert_eq!(prepared_publication.projection, prepared);

        let cutover = MoveProjector::derive(
            &spec,
            &projection_config(),
            MovePhase::Cutover,
            Some(&prepared),
            Some(publisher.revision().unwrap()),
        )
        .unwrap();
        fs::write(
            &cutover_projection_json,
            serde_json::to_vec(&cutover).unwrap(),
        )
        .unwrap();
        write_declaration(
            &cutover_declaration_json,
            &cutover,
            "target-active",
            1,
            None,
        );
        let cutover_publication = publisher.publish(&cutover, "controller").unwrap();
        assert_eq!(cutover_publication.projection, cutover);

        let adoption = publisher
            .publish_closeout_observed(&cutover, "complete", "controller", |_| Ok(()))
            .unwrap();
        assert!(adoption.projection_path.is_file());
        assert!(
            fs::read_to_string(&adoption.projection_path)
                .unwrap()
                .contains("\"phase\" = \"adopting-target\";")
        );
        assert_eq!(publisher.load_closeout("move-publisher").unwrap(), None);
        assert_eq!(
            publisher
                .load_projection_admission("move-publisher")
                .unwrap(),
            ProjectionAdmission {
                projection: Some(cutover.clone()),
                requires_existing_journal: true,
            }
        );

        let cleanup = publisher
            .cleanup_nix_service_move_observed(
                &cutover,
                "complete",
                "controller",
                &adoption.revision,
                |_| Ok(()),
            )
            .unwrap();
        assert!(!cleanup.projection_path.exists());
        assert!(
            fs::read_to_string(&cleanup.authority_paths[0])
                .unwrap()
                .contains("\"role\" = \"target-role\";")
        );
        assert_eq!(publisher.load_closeout("move-publisher").unwrap(), None);
        assert_eq!(
            publisher
                .load_projection_admission("move-publisher")
                .unwrap(),
            ProjectionAdmission {
                projection: None,
                requires_existing_journal: false,
            }
        );

        fs::write(source.path().join("foreign-commit"), "foreign\n").unwrap();
        run_git(
            &git,
            source.path(),
            &["add", "--", "foreign-commit"],
            "stage foreign commit",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "foreign",
            ],
            "commit foreign revision",
        )
        .unwrap();
        let advanced_head_error = publisher.publish(&cutover, "controller").unwrap_err();
        assert!(
            advanced_head_error
                .to_string()
                .contains("expected repository revision")
        );
    }

    #[test]
    fn affected_configuration_validation_runs_hosts_in_parallel_with_live_progress() {
        let temp = tempfile::tempdir().unwrap();
        let markers = temp.path().join("markers");
        fs::create_dir(&markers).unwrap();
        let fake_nix = temp.path().join("fake-nix");
        write_executable(
            &fake_nix,
            format!(
                "#!/bin/sh\nset -eu\ntouch '{}/'\"$$\"\nfor _attempt in $(seq 1 100); do\n  count=$(find '{}' -type f | wc -l)\n  if [ \"$count\" -ge 4 ]; then\n    printf '/nix/store/fake-system.drv'\n    exit 0\n  fi\n  sleep 0.05\ndone\nexit 70\n",
                markers.display(),
                markers.display(),
            ),
        )
        .unwrap();

        let mut progress = Vec::new();
        evaluate_affected_configurations(
            &fake_nix,
            temp.path(),
            ["alpha", "beta", "gamma", "delta"].into_iter().collect(),
            "projection",
            |detail| {
                progress.push(detail);
                Ok(())
            },
        )
        .unwrap();

        assert_eq!(
            progress.first().map(String::as_str),
            Some("Evaluating 4 affected configurations · 4 in parallel")
        );
        assert_eq!(progress.len(), 5);
        for host in ["alpha", "beta", "gamma", "delta"] {
            assert!(progress.iter().any(|detail| detail.contains(host)));
        }
    }

    #[test]
    fn affected_configuration_validation_reports_failures_in_host_order() {
        let temp = tempfile::tempdir().unwrap();
        let fake_nix = temp.path().join("fake-nix");
        write_executable(
            &fake_nix,
            "#!/bin/sh\nset -eu\ncase \"$3\" in\n  *alpha*) printf 'alpha failed' >&2; exit 41 ;;\n  *zeta*) printf 'zeta failed' >&2; exit 42 ;;\n  *) printf '/nix/store/fake-system.drv' ;;\nesac\n",
        )
        .unwrap();

        let error = evaluate_affected_configurations(
            &fake_nix,
            temp.path(),
            ["zeta", "alpha"].into_iter().collect(),
            "projection",
            |_| Ok(()),
        )
        .unwrap_err();
        let error = format!("{error:#}");
        let alpha = error.find("alpha: ").unwrap();
        let zeta = error.find("zeta: ").unwrap();
        assert!(alpha < zeta, "failure order was not deterministic: {error}");
        assert!(error.contains("alpha failed"));
        assert!(error.contains("zeta failed"));
    }

    #[test]
    fn publication_base_accepts_exact_and_behind_but_rejects_unpublished_state() {
        let source = fixture();
        let remote = tempfile::tempdir().unwrap();
        let git = PathBuf::from("git");
        run_git(
            &git,
            source.path(),
            &["init", "-b", "master"],
            "init source",
        )
        .unwrap();
        run_git(&git, source.path(), &["add", "--", "."], "stage fixture").unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "initial",
            ],
            "commit fixture",
        )
        .unwrap();
        run_git(&git, remote.path(), &["init", "--bare"], "init remote").unwrap();
        run_git_path(
            &git,
            source.path(),
            &["remote", "add", "origin"],
            remote.path(),
            "add remote",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &["push", "origin", "master"],
            "push initial",
        )
        .unwrap();
        let repository = Repository::from_root(source.path().to_path_buf()).unwrap();
        let initial = repository
            .verify_projection_publication_base(&git, "master")
            .unwrap();

        fs::write(source.path().join("dirty"), "dirty\n").unwrap();
        assert!(
            repository
                .verify_projection_publication_base(&git, "master")
                .is_err()
        );
        fs::remove_file(source.path().join("dirty")).unwrap();

        fs::write(source.path().join("published"), "next\n").unwrap();
        run_git(
            &git,
            source.path(),
            &["add", "--", "published"],
            "stage next",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "next",
            ],
            "commit next",
        )
        .unwrap();
        assert!(
            repository
                .verify_projection_publication_base(&git, "master")
                .is_err()
        );
        run_git(
            &git,
            source.path(),
            &["push", "origin", "master"],
            "push next",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &["reset", "--hard", &initial],
            "rewind local",
        )
        .unwrap();
        repository
            .verify_projection_publication_base(&git, "master")
            .unwrap();

        fs::write(source.path().join("diverged"), "local\n").unwrap();
        run_git(
            &git,
            source.path(),
            &["add", "--", "diverged"],
            "stage divergent",
        )
        .unwrap();
        run_git(
            &git,
            source.path(),
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                "divergent",
            ],
            "commit divergent",
        )
        .unwrap();
        assert!(
            repository
                .verify_projection_publication_base(&git, "master")
                .is_err()
        );
    }

    #[test]
    fn physical_regeneration_preserves_ids_and_unrelated_updates_preserve_sys_nix() {
        let temp = fixture();
        let repository = Repository::from_root(temp.path().to_path_buf()).unwrap();
        repository
            .generate_physical(
                "demo-host",
                record(ManagedHostSystem::Live),
                physical_request(BootMode::Efi),
                &HardwareProjection::minimal(),
                false,
                false,
            )
            .unwrap();
        let original = repository
            .load_marker("demo-host")
            .unwrap()
            .physical
            .unwrap();

        repository
            .generate_physical(
                "demo-host",
                record(ManagedHostSystem::Live),
                physical_request(BootMode::Bios),
                &HardwareProjection::minimal(),
                false,
                true,
            )
            .unwrap();
        let updated = repository
            .load_marker("demo-host")
            .unwrap()
            .physical
            .unwrap();
        assert_eq!(updated.boot_mode, BootMode::Bios);
        assert_eq!(updated.luks_uuid, original.luks_uuid);
        assert_eq!(updated.root_partition_uuid, original.root_partition_uuid);

        let system = temp.path().join("hosts/demo-host/sys.nix");
        let customized = format!(
            "{}\n# operator customization\n",
            fs::read_to_string(&system).unwrap()
        );
        fs::write(&system, &customized).unwrap();
        repository
            .generate("demo-host", record(ManagedHostSystem::Live), None, true)
            .unwrap();
        assert_eq!(fs::read_to_string(system).unwrap(), customized);
        let preserved = repository
            .load_marker("demo-host")
            .unwrap()
            .physical
            .unwrap();
        assert_eq!(preserved.luks_uuid, original.luks_uuid);
    }

    #[test]
    fn complete_offline_build_publishes_every_required_root() {
        let temp = fixture();
        let repository = Repository::from_root(temp.path().to_path_buf()).unwrap();
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_owned());
        let nix = temp.path().join("fake-nix");
        write_executable(
            &nix,
            &format!(
                r#"#!{shell}
set -eu
case "$1" in
  flake)
    cache="${{4#file://}}"
    mkdir -p "$cache"
    printf 'StoreDir: /nix/store\n' > "$cache/nix-cache-info"
    ;;
  build)
    case "$2" in
      *diskoScript) name=disko ;;
      *abird-host-manager) name=manager ;;
      *nixos-install-tools) name=install-tools ;;
      *pkgs.nix) name=nix ;;
      *) name=system ;;
    esac
    printf '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-%s\n' "$name"
    ;;
  copy) ;;
  *) exit 64 ;;
esac
"#,
            ),
        )
        .unwrap();
        let cache = temp.path().join("offline-cache");
        let programs = RepositoryPrograms {
            nix,
            privilege: PathBuf::from("/run/wrappers/bin/sudo"),
            nixos_install: PathBuf::from("/run/current-system/sw/bin/nixos-install"),
        };

        let result = repository
            .build_artifacts(&programs, "demo-host", Some(&cache))
            .unwrap();

        assert_eq!(result.runtime.len(), 2);
        let manifest = OfflineStore::new(cache).unwrap().load("demo-host").unwrap();
        assert!(
            manifest
                .system
                .ends_with("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system")
        );
        assert!(
            manifest
                .disko_script
                .ends_with("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-disko")
        );
        assert!(
            manifest
                .manager
                .ends_with("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-manager")
        );
        assert_eq!(manifest.runtime.len(), 2);
    }
}
