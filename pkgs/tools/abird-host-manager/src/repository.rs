use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::thread;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::offline_store::{OfflineHostManifest, OfflineStore};
use crate::physical::{BootMode, HardwareProjection, PhysicalLayout, PhysicalLayoutRequest};
use crate::programs::disko::DiskoScript;
use crate::programs::nix::Nix;
use crate::programs::nixos_install::NixosInstall;
use crate::programs::privilege::Privilege;
use crate::projection::{PhaseProjection, ProjectionEffect};
use crate::workflow_runtime::WorkflowStore;

const HOSTS_FILE: &str = "hosts/default.nix";
const NIXBOT_FILE: &str = "hosts/nixbot.nix";
const SECRETS_FILE: &str = "data/secrets/default.nix";
const MARKER_NAME: &str = ".abird-host-manager.json";
const MARKER_VERSION: u32 = 2;
const GIT_REPOSITORY_ENVIRONMENT: &[&str] = &[
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_DIR",
    "GIT_GRAFT_FILE",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_NAMESPACE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_PREFIX",
    "GIT_SHALLOW_FILE",
    "GIT_WORK_TREE",
];

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
    pub branch: String,
    pub revision: String,
    pub pushed: bool,
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
pub struct CanonicalServicePlacement {
    pub host: String,
    pub host_resource: String,
    pub transaction_id: String,
    pub projection_sha256: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CanonicalServicePlacements {
    pub schema_version: u32,
    #[serde(default)]
    pub closeouts: BTreeMap<String, CanonicalProjectionCloseout>,
    #[serde(default)]
    pub controller_reconcile_exclusions: BTreeSet<String>,
    #[serde(default)]
    pub placements: BTreeMap<String, BTreeMap<String, CanonicalServicePlacement>>,
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

fn default_controller_reconcile() -> bool {
    true
}

impl Default for CanonicalServicePlacements {
    fn default() -> Self {
        Self {
            schema_version: 1,
            closeouts: BTreeMap::new(),
            controller_reconcile_exclusions: BTreeSet::new(),
            placements: BTreeMap::new(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ProjectionCloseoutPublication {
    pub placement_path: PathBuf,
    pub projection_path: PathBuf,
    pub branch: String,
    pub revision: String,
    pub pushed: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProjectionCloseoutStage {
    FoldPlacement,
    RemoveProjection,
    Validate,
    Commit,
    RetainLocal,
    Push,
    Verify,
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

#[derive(Debug)]
pub struct ProjectionPublisher {
    repository: Repository,
    git: PathBuf,
    nix: PathBuf,
    branch: String,
    publish_git_ssh_command: Option<String>,
    mode: ProjectionPublicationMode,
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
        Ok(Some(projection))
    }

    /// Persist one validated desired-state projection without touching any
    /// other repository file. Git publication is deliberately a separate
    /// policy boundary around this semantic writer.
    pub fn write_phase_projection(&self, projection: &PhaseProjection) -> Result<ProjectionWrite> {
        projection.validate()?;
        let path = self.phase_projection_path(&projection.projection_id);
        if let Some(existing) = self.load_phase_projection(&projection.projection_id)? {
            if existing.intent_kind != projection.intent_kind
                || existing.intent_sha256 != projection.intent_sha256
                || existing.intent != projection.intent
            {
                bail!("refusing to replace projection with different immutable intent");
            }
            if existing.projection_sha256 == projection.projection_sha256 {
                return Ok(ProjectionWrite {
                    path,
                    changed: false,
                    generation: existing.generation,
                    projection_sha256: existing.projection_sha256,
                });
            }
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
        } else if projection.generation != 1 || projection.previous_projection_sha256.is_some() {
            bail!(
                "the first published phase projection must be generation 1 without a predecessor"
            );
        }
        let directory = path
            .parent()
            .context("move projection destination has no parent")?;
        fs::create_dir_all(directory)?;
        let mut bytes = serde_json::to_vec_pretty(projection)?;
        bytes.push(b'\n');
        atomic_write(&path, &bytes, 0o644)?;
        Ok(ProjectionWrite {
            path,
            changed: true,
            generation: projection.generation,
            projection_sha256: projection.projection_sha256.clone(),
        })
    }

    fn load_canonical_service_placements(&self) -> Result<CanonicalServicePlacements> {
        let path = self.root.join("data/service-placements.json");
        if !path.exists() {
            return Ok(CanonicalServicePlacements::default());
        }
        let catalog: CanonicalServicePlacements =
            serde_json::from_reader(File::open(&path).with_context(|| {
                format!("open canonical service placements {}", path.display())
            })?)
            .with_context(|| format!("parse canonical service placements {}", path.display()))?;
        if catalog.schema_version != 1 {
            bail!(
                "unsupported canonical service placement schema version {}",
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
            .load_canonical_service_placements()?
            .closeouts
            .get(projection_id)
            .cloned())
    }

    fn retain_local_projection_authority(&self, projection_id: &str) -> Result<PathBuf> {
        let placement_path = self.root.join("data/service-placements.json");
        let mut catalog = self.load_canonical_service_placements()?;
        catalog
            .controller_reconcile_exclusions
            .insert(projection_id.to_owned());
        let mut bytes = serde_json::to_vec_pretty(&catalog)?;
        bytes.push(b'\n');
        atomic_write(&placement_path, &bytes, 0o644)?;
        Ok(placement_path)
    }

    fn write_projection_closeout(
        &self,
        projection: &PhaseProjection,
        decision: &str,
        controller_reconcile: bool,
    ) -> Result<(PathBuf, PathBuf)> {
        projection.validate()?;
        let projection_path = self.phase_projection_path(&projection.projection_id);
        let published = self
            .load_phase_projection(&projection.projection_id)?
            .context("cannot close a projection that is absent from the repository")?;
        if published.projection_sha256 != projection.projection_sha256 {
            bail!("refusing to close a projection generation that is not currently published");
        }

        let placement_path = self.root.join("data/service-placements.json");
        let mut catalog = self.load_canonical_service_placements()?;
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
        for effect in &projection.effects {
            let ProjectionEffect::ServicePlacement {
                scope,
                service,
                host,
                host_resource,
            } = effect
            else {
                continue;
            };
            catalog.placements.entry(scope.clone()).or_default().insert(
                service.clone(),
                CanonicalServicePlacement {
                    host: host.clone(),
                    host_resource: host_resource.clone(),
                    transaction_id: projection.projection_id.clone(),
                    projection_sha256: projection.projection_sha256.clone(),
                },
            );
        }
        let mut bytes = serde_json::to_vec_pretty(&catalog)?;
        bytes.push(b'\n');
        atomic_write(&placement_path, &bytes, 0o644)?;
        fs::remove_file(&projection_path)
            .with_context(|| format!("remove closed projection {}", projection_path.display()))?;
        Ok((placement_path, projection_path))
    }

    fn phase_projection_path(&self, projection_id: &str) -> PathBuf {
        self.root
            .join("data/phase-projections")
            .join(format!("{projection_id}.json"))
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
        let remote = git_stdout(
            &git,
            source_repository.root(),
            &["remote", "get-url", "origin"],
            "resolve authoritative repository remote",
        )?;
        let checkout = state_dir.join("projection-repository");
        fs::create_dir_all(state_dir)?;
        if !checkout.exists() {
            let output = Command::new(&git)
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
        Ok(Self {
            repository: Repository::from_root(checkout)?,
            git,
            nix,
            branch: branch.to_owned(),
            publish_git_ssh_command,
            mode: ProjectionPublicationMode::Remote,
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
        let branch_name = git_stdout(
            &git,
            source_repository.root(),
            &["branch", "--show-current"],
            "resolve local publication branch",
        )?;
        if branch_name != branch {
            bail!("local publication checkout is on branch {branch_name:?}, expected {branch:?}");
        }
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
        Ok(Self {
            repository: Repository::from_root(source_repository.root().to_path_buf())?,
            git,
            nix,
            branch: branch.to_owned(),
            publish_git_ssh_command: None,
            mode: ProjectionPublicationMode::Local,
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

    /// Exercise the exact publication transport and ref update without changing
    /// the remote. Lifecycle commands run this before mutating their journal.
    pub fn verify_push_access(&self) -> Result<()> {
        if self.mode == ProjectionPublicationMode::Local {
            return Ok(());
        }
        self.run_publication_git(
            &[
                "push",
                "--dry-run",
                "origin",
                &format!("HEAD:refs/heads/{}", self.branch),
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
        self.publish_observed(projection, controller_host, |_| Ok(()))
    }

    pub fn publish_observed(
        &self,
        projection: &PhaseProjection,
        controller_host: &str,
        mut observe: impl FnMut(ProjectionPublicationEvent) -> Result<()>,
    ) -> Result<ProjectionPublication> {
        observe(ProjectionPublicationEvent::Started(
            ProjectionPublicationStage::Validate,
        ))?;
        let write = self.repository.write_phase_projection(projection)?;
        let relative = PathBuf::from("data/phase-projections")
            .join(format!("{}.json", projection.projection_id));
        let placement_relative = PathBuf::from("data/service-placements.json");
        run_git_path(
            &self.git,
            self.repository.root(),
            &["add", "--"],
            &relative,
            "stage phase projection",
        )?;
        if self.mode == ProjectionPublicationMode::Local {
            self.repository
                .retain_local_projection_authority(&projection.projection_id)?;
            run_git_path(
                &self.git,
                self.repository.root(),
                &["add", "--"],
                &placement_relative,
                "stage local projection authority",
            )?;
        }
        run_git(
            &self.git,
            self.repository.root(),
            &["diff", "--cached", "--check"],
            "validate staged projection diff",
        )?;
        self.validate_staged_projection(projection, controller_host, |detail| {
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
        let mut staged = repository_git_command(&self.git, self.repository.root());
        staged
            .args(["diff", "--cached", "--quiet", "--exit-code", "--"])
            .arg(&relative);
        if self.mode == ProjectionPublicationMode::Local {
            staged.arg(&placement_relative);
        }
        let staged = staged.status().context("inspect staged projection")?;
        if !staged.success() {
            let message = format!(
                "chore(projection): project {} {:?}",
                projection.projection_id, projection.phase
            );
            let mut arguments = vec![
                "-c",
                "user.name=abird-host-manager",
                "-c",
                "user.email=host-manager@abird.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                &message,
                "--",
                relative.to_str().unwrap(),
            ];
            if self.mode == ProjectionPublicationMode::Local {
                arguments.push(placement_relative.to_str().unwrap());
            }
            run_git(
                &self.git,
                self.repository.root(),
                &arguments,
                "commit phase projection",
            )?;
        }
        let revision = git_stdout(
            &self.git,
            self.repository.root(),
            &["rev-parse", "HEAD"],
            "resolve projection commit",
        )?;
        observe(ProjectionPublicationEvent::Completed {
            stage: ProjectionPublicationStage::Commit,
            revision: Some(revision.clone()),
        })?;
        if self.mode == ProjectionPublicationMode::Remote {
            observe(ProjectionPublicationEvent::Started(
                ProjectionPublicationStage::Push,
            ))?;
            self.run_publication_git(
                &[
                    "push",
                    "origin",
                    &format!("HEAD:refs/heads/{}", self.branch),
                ],
                "publish move projection",
            )?;
            observe(ProjectionPublicationEvent::Completed {
                stage: ProjectionPublicationStage::Push,
                revision: Some(revision.clone()),
            })?;
            observe(ProjectionPublicationEvent::Started(
                ProjectionPublicationStage::Verify,
            ))?;
            let remote = self.publication_git_stdout(
                &[
                    "ls-remote",
                    "origin",
                    &format!("refs/heads/{}", self.branch),
                ],
                "verify published projection revision",
            )?;
            let remote_revision = remote
                .split_whitespace()
                .next()
                .context("published branch has no remote revision")?;
            if remote_revision != revision {
                bail!(
                    "published projection revision mismatch: local {revision}, remote {remote_revision}"
                );
            }
            observe(ProjectionPublicationEvent::Completed {
                stage: ProjectionPublicationStage::Verify,
                revision: Some(revision.clone()),
            })?;
        } else {
            observe(ProjectionPublicationEvent::Started(
                ProjectionPublicationStage::RetainLocal,
            ))?;
            let retained = self
                .repository
                .load_canonical_service_placements()?
                .controller_reconcile_exclusions
                .contains(&projection.projection_id);
            if !retained {
                bail!("local projection commit did not retain local controller authority");
            }
            observe(ProjectionPublicationEvent::Completed {
                stage: ProjectionPublicationStage::RetainLocal,
                revision: Some(revision.clone()),
            })?;
            observe(ProjectionPublicationEvent::Started(
                ProjectionPublicationStage::Verify,
            ))?;
            run_git(
                &self.git,
                self.repository.root(),
                &["diff", "--quiet", "HEAD", "--"],
                "verify clean local projection commit",
            )?;
            observe(ProjectionPublicationEvent::Completed {
                stage: ProjectionPublicationStage::Verify,
                revision: Some(revision.clone()),
            })?;
        }
        Ok(ProjectionPublication {
            write,
            branch: self.branch.clone(),
            revision,
            pushed: self.pushed(),
        })
    }

    /// Atomically publish the selected service placement as canonical state
    /// and retire its temporary phase projection in the same Git commit.
    pub fn publish_closeout(
        &self,
        projection: &PhaseProjection,
        decision: &str,
        controller_host: &str,
    ) -> Result<ProjectionCloseoutPublication> {
        self.publish_closeout_observed(projection, decision, controller_host, |_| Ok(()))
    }

    pub fn publish_closeout_observed(
        &self,
        projection: &PhaseProjection,
        decision: &str,
        controller_host: &str,
        mut observe: impl FnMut(ProjectionCloseoutEvent) -> Result<()>,
    ) -> Result<ProjectionCloseoutPublication> {
        observe(ProjectionCloseoutEvent::Started(
            ProjectionCloseoutStage::FoldPlacement,
        ))?;
        let (placement_path, projection_path) = self.repository.write_projection_closeout(
            projection,
            decision,
            self.mode == ProjectionPublicationMode::Remote,
        )?;
        observe(ProjectionCloseoutEvent::Completed {
            stage: ProjectionCloseoutStage::FoldPlacement,
            revision: None,
        })?;
        observe(ProjectionCloseoutEvent::Started(
            ProjectionCloseoutStage::RemoveProjection,
        ))?;
        if projection_path.exists() {
            bail!("closed phase projection still exists after repository closeout fold");
        }
        observe(ProjectionCloseoutEvent::Completed {
            stage: ProjectionCloseoutStage::RemoveProjection,
            revision: None,
        })?;
        observe(ProjectionCloseoutEvent::Started(
            ProjectionCloseoutStage::Validate,
        ))?;
        let placement_relative = PathBuf::from("data/service-placements.json");
        let projection_relative = PathBuf::from("data/phase-projections")
            .join(format!("{}.json", projection.projection_id));
        run_git_path(
            &self.git,
            self.repository.root(),
            &["add", "--"],
            &placement_relative,
            "stage canonical service placements",
        )?;
        run_git_path(
            &self.git,
            self.repository.root(),
            &["add", "--"],
            &projection_relative,
            "stage closed projection removal",
        )?;
        run_git(
            &self.git,
            self.repository.root(),
            &["diff", "--cached", "--check"],
            "validate staged projection closeout diff",
        )?;
        self.validate_staged_closeout(projection, controller_host, |detail| {
            observe(ProjectionCloseoutEvent::Progress {
                stage: ProjectionCloseoutStage::Validate,
                detail,
            })
        })?;
        observe(ProjectionCloseoutEvent::Completed {
            stage: ProjectionCloseoutStage::Validate,
            revision: None,
        })?;

        observe(ProjectionCloseoutEvent::Started(
            ProjectionCloseoutStage::Commit,
        ))?;
        let message = format!("chore(projection): close {}", projection.projection_id);
        run_git(
            &self.git,
            self.repository.root(),
            &[
                "-c",
                "user.name=abird-host-manager",
                "-c",
                "user.email=host-manager@abird.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-m",
                &message,
                "--",
                placement_relative.to_str().unwrap(),
                projection_relative.to_str().unwrap(),
            ],
            "commit projection closeout",
        )?;
        let revision = git_stdout(
            &self.git,
            self.repository.root(),
            &["rev-parse", "HEAD"],
            "resolve projection closeout commit",
        )?;
        observe(ProjectionCloseoutEvent::Completed {
            stage: ProjectionCloseoutStage::Commit,
            revision: Some(revision.clone()),
        })?;
        if self.mode == ProjectionPublicationMode::Remote {
            observe(ProjectionCloseoutEvent::Started(
                ProjectionCloseoutStage::Push,
            ))?;
            self.run_publication_git(
                &[
                    "push",
                    "origin",
                    &format!("HEAD:refs/heads/{}", self.branch),
                ],
                "publish projection closeout",
            )?;
            observe(ProjectionCloseoutEvent::Completed {
                stage: ProjectionCloseoutStage::Push,
                revision: Some(revision.clone()),
            })?;
            observe(ProjectionCloseoutEvent::Started(
                ProjectionCloseoutStage::Verify,
            ))?;
            let remote = self.publication_git_stdout(
                &[
                    "ls-remote",
                    "origin",
                    &format!("refs/heads/{}", self.branch),
                ],
                "verify published projection closeout revision",
            )?;
            let remote_revision = remote
                .split_whitespace()
                .next()
                .context("published branch has no remote revision")?;
            if remote_revision != revision {
                bail!(
                    "published projection closeout revision mismatch: local {revision}, remote {remote_revision}"
                );
            }
            observe(ProjectionCloseoutEvent::Completed {
                stage: ProjectionCloseoutStage::Verify,
                revision: Some(revision.clone()),
            })?;
        } else {
            observe(ProjectionCloseoutEvent::Started(
                ProjectionCloseoutStage::RetainLocal,
            ))?;
            let closeout = self
                .repository
                .load_projection_closeout(&projection.projection_id)?
                .context("local projection closeout was not retained")?;
            if closeout.controller_reconcile {
                bail!("local projection closeout incorrectly retained controller authority");
            }
            observe(ProjectionCloseoutEvent::Completed {
                stage: ProjectionCloseoutStage::RetainLocal,
                revision: Some(revision.clone()),
            })?;
            observe(ProjectionCloseoutEvent::Started(
                ProjectionCloseoutStage::Verify,
            ))?;
            run_git(
                &self.git,
                self.repository.root(),
                &["diff", "--quiet", "HEAD", "--"],
                "verify clean local projection closeout commit",
            )?;
            observe(ProjectionCloseoutEvent::Completed {
                stage: ProjectionCloseoutStage::Verify,
                revision: Some(revision.clone()),
            })?;
        }
        Ok(ProjectionCloseoutPublication {
            placement_path,
            projection_path,
            branch: self.branch.clone(),
            revision,
            pushed: self.pushed(),
        })
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
        let documents_installable = nixos_config_installable(
            controller_host,
            "services.abird-host-manager.phaseProjections",
        )?;
        let documents = Command::new(&self.nix)
            .current_dir(self.repository.root())
            .args([
                "eval",
                "--json",
                &documents_installable,
                "--option",
                "allow-import-from-derivation",
                "false",
            ])
            .output()
            .context("start staged phase-projection evaluation")?;
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
        controller_host: &str,
        progress: impl FnMut(String) -> Result<()>,
    ) -> Result<()> {
        if controller_host.is_empty() {
            bail!("projection closeout requires a non-empty controller host");
        }
        let documents_installable = nixos_config_installable(
            controller_host,
            "services.abird-host-manager.phaseProjections",
        )?;
        let documents = Command::new(&self.nix)
            .current_dir(self.repository.root())
            .args([
                "eval",
                "--json",
                &documents_installable,
                "--option",
                "allow-import-from-derivation",
                "false",
            ])
            .output()
            .context("start staged projection closeout evaluation")?;
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

        for effect in &projection.effects {
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
            let placement = Command::new(&self.nix)
                .current_dir(self.repository.root())
                .args([
                    "eval",
                    "--raw",
                    ".#hostManager.stacks",
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
    let evaluation = Command::new(nix)
        .current_dir(repository_root)
        .args([
            "eval",
            "--raw",
            &installable,
            "--option",
            "allow-import-from-derivation",
            "false",
        ])
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
    {
        bail!("projection branch is not a safe Git branch name");
    }
    Ok(())
}

fn repository_git_command(git: &Path, root: &Path) -> Command {
    let mut command = Command::new(git);
    command.current_dir(root);
    for variable in GIT_REPOSITORY_ENVIRONMENT {
        command.env_remove(variable);
    }
    command
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
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(mode)
        .open(&temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    fs::rename(&temporary, path)?;
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
    use std::os::unix::fs::PermissionsExt;

    use crate::agent_adapter::HostManagerConfig;
    use crate::physical::PartitionSize;
    use crate::projection::{MovePhase, MoveProjector, PhaseProjection};
    use crate::workflow::{HostEndpoint, MoveItem, TransactionSpec};

    use super::*;

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
            .filter_map(|(name, value)| {
                value.is_none().then(|| name.to_string_lossy().into_owned())
            })
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
        let mut spec = TransactionSpec::new(
            Some("move-publisher"),
            vec![MoveItem::Service {
                id: "item-001".to_owned(),
                service: "zulip".to_owned(),
                source_resource: None,
                target_resource: None,
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
        spec.declarative_scope = Some("abird".to_owned());
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
        fs::write(
            &fake_nix,
            format!(
                "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$*\" >> '{}'\ncase \"$1 $2\" in\n  'eval --json')\n    printf '['\n    cat data/phase-projections/move-publisher.json\n    printf ']'\n    ;;\n  'eval --raw') printf '/nix/store/fake-system.drv' ;;\n  *) exit 64 ;;\nesac\n",
                nix_arguments.display()
            ),
        )
        .unwrap();
        let mut permissions = fs::metadata(&fake_nix).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&fake_nix, permissions).unwrap();
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
        fs::write(
            &publisher_git,
            format!(
                "#!/bin/sh\nprintf '%s|%s\\n' \"$*\" \"${{GIT_SSH_COMMAND-<unset>}}\" >> '{}'\nexec git \"$@\"\n",
                git_invocations.display()
            ),
        )
        .unwrap();
        let mut permissions = fs::metadata(&publisher_git).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&publisher_git, permissions).unwrap();

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
        publisher.verify_push_access().unwrap();
        let projection = seeded_projection(publisher.revision().unwrap());
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
        assert!(
            git_invocations
                .contains("push --dry-run origin HEAD:refs/heads/master|operator-publication-ssh")
        );
        assert!(
            git_invocations.contains("push origin HEAD:refs/heads/master|operator-publication-ssh")
        );
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
                "eval --json .#nixosConfigurations.\"controller\".config.services.abird-host-manager.phaseProjections --option allow-import-from-derivation false"
            )
        );
        assert_eq!(
            nix_invocations.collect::<BTreeSet<_>>(),
            ["controller", "router", "source", "target"]
                .map(|host| format!(
                    "eval --raw .#nixosConfigurations.\"{host}\".config.system.build.toplevel.drvPath --option allow-import-from-derivation false"
                ))
                .iter()
                .map(String::as_str)
                .collect()
        );

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
        fs::write(
            &fake_nix,
            "#!/bin/sh\nset -eu\ncase \"$1 $2\" in\n  'eval --json') printf '['; cat data/phase-projections/move-publisher.json; printf ']' ;;\n  'eval --raw') printf '/nix/store/fake-system.drv' ;;\n  *) exit 64 ;;\nesac\n",
        )
        .unwrap();
        fs::set_permissions(&fake_nix, fs::Permissions::from_mode(0o755)).unwrap();
        let invocations = state.path().join("git-invocations");
        let publisher_git = state.path().join("publisher-git");
        fs::write(
            &publisher_git,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\nexec git \"$@\"\n",
                invocations.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&publisher_git, fs::Permissions::from_mode(0o755)).unwrap();

        let source_repository = Repository::from_root(source.path().to_path_buf()).unwrap();
        let authority = WorkflowStore::open(state.path().to_path_buf()).unwrap();
        let publisher = ProjectionPublisher::prepare_local(
            &source_repository,
            &authority,
            state.path(),
            "master",
            publisher_git,
            fake_nix,
        )
        .unwrap();
        assert_eq!(publisher.mode(), ProjectionPublicationMode::Local);
        publisher.verify_push_access().unwrap();
        let projection = seeded_projection(publisher.revision().unwrap());
        let mut events = Vec::new();
        let publication = publisher
            .publish_observed(&projection, "controller", |event| {
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
                .load_canonical_service_placements()
                .unwrap()
                .controller_reconcile_exclusions
                .contains(&projection.projection_id)
        );
        source_repository
            .write_projection_closeout(&projection, "complete", false)
            .unwrap();
        assert!(
            !source_repository
                .load_canonical_service_placements()
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
    fn affected_configuration_validation_runs_hosts_in_parallel_with_live_progress() {
        let temp = tempfile::tempdir().unwrap();
        let markers = temp.path().join("markers");
        fs::create_dir(&markers).unwrap();
        let fake_nix = temp.path().join("fake-nix");
        fs::write(
            &fake_nix,
            format!(
                "#!/bin/sh\nset -eu\ntouch '{}/'\"$$\"\nfor _attempt in $(seq 1 100); do\n  count=$(find '{}' -type f | wc -l)\n  if [ \"$count\" -ge 4 ]; then\n    printf '/nix/store/fake-system.drv'\n    exit 0\n  fi\n  sleep 0.05\ndone\nexit 70\n",
                markers.display(),
                markers.display(),
            ),
        )
        .unwrap();
        fs::set_permissions(&fake_nix, fs::Permissions::from_mode(0o755)).unwrap();

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
        fs::write(
            &fake_nix,
            "#!/bin/sh\nset -eu\ncase \"$3\" in\n  *alpha*) printf 'alpha failed' >&2; exit 41 ;;\n  *zeta*) printf 'zeta failed' >&2; exit 42 ;;\n  *) printf '/nix/store/fake-system.drv' ;;\nesac\n",
        )
        .unwrap();
        fs::set_permissions(&fake_nix, fs::Permissions::from_mode(0o755)).unwrap();

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
        fs::write(
            &nix,
            format!(
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
        fs::set_permissions(&nix, fs::Permissions::from_mode(0o700)).unwrap();
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
