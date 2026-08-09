use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::offline_store::{OfflineHostManifest, OfflineStore};
use crate::physical::{BootMode, HardwareProjection, PhysicalLayout, PhysicalLayoutRequest};
use crate::programs::disko::DiskoScript;
use crate::programs::nix::Nix;
use crate::programs::nixos_install::NixosInstall;
use crate::programs::privilege::Privilege;

const HOSTS_FILE: &str = "hosts/default.nix";
const NIXBOT_FILE: &str = "hosts/nixbot.nix";
const SECRETS_FILE: &str = "data/secrets/default.nix";
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

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn nixbot_config_path(&self) -> PathBuf {
        self.root.join(NIXBOT_FILE)
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
    let common = match record.stack.as_deref() {
        Some("gap3") => Some("../common/gap3.nix"),
        Some("pvl") => Some("../common/pvl.nix"),
        Some(stack) if stack.starts_with("abird") => Some("../common/abird.nix"),
        _ => None,
    };
    let local_modules = if record.system == ManagedHostSystem::Incus {
        "./packages.nix\n    ./users.nix"
    } else {
        "./sys.nix"
    };
    let common = common
        .map(|module| format!("    {module}\n"))
        .unwrap_or_default();
    format!("{{...}}: {{\n  imports = [\n{common}    {local_modules}\n  ];\n}}\n")
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

    use crate::physical::PartitionSize;

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

    #[test]
    fn pvl_hosts_import_the_pvl_common_module() {
        let mut host = record(ManagedHostSystem::Live);
        host.stack = Some("pvl".to_owned());

        assert!(default_module(&host).contains("../common/pvl.nix"));
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
