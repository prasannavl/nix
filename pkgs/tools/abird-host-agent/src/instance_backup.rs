use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::instance::InstanceCommandResult;
use crate::programs::incus::{Incus, IncusOutput};
use crate::sha256::digest_bytes;
use crate::sha256::digest_reader;

const ARCHIVE_FILE: &str = "instance.tar.gz";
const IDENTITY_FILE: &str = "identity.json";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum InstanceBackupAction {
    Export {
        archive_root: PathBuf,
        #[serde(default = "default_true")]
        include_snapshots: bool,
        #[serde(default)]
        optimized_storage: bool,
    },
    Verify {
        archive_root: PathBuf,
        sha256: String,
        size_bytes: u64,
    },
    Replace {
        archive_root: PathBuf,
        sha256: String,
        size_bytes: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        storage_pool: Option<String>,
    },
    DeleteArchive {
        archive_root: PathBuf,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct InstanceBackupRequest {
    pub program: PathBuf,
    #[serde(default = "default_remote")]
    pub remote: String,
    #[serde(default = "default_project")]
    pub project: String,
    pub instance: String,
    pub operation: InstanceBackupAction,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct ExportIdentity {
    schema_version: u32,
    remote: String,
    project: String,
    instance: String,
    include_snapshots: bool,
    optimized_storage: bool,
    sha256: String,
    size_bytes: u64,
}

#[derive(Debug, Serialize)]
pub struct InstanceBackupResult {
    pub operation: &'static str,
    pub remote: String,
    pub project: String,
    pub instance: String,
    pub archive_root: PathBuf,
    pub archive: PathBuf,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size_bytes: Option<u64>,
    pub changed: bool,
    pub commands: Vec<InstanceCommandResult>,
}

pub fn validate_instance_backup(
    request: &InstanceBackupRequest,
    backup_root: &Path,
    resource: &str,
) -> Result<()> {
    if !request.program.is_absolute()
        || request.program.file_name().and_then(|name| name.to_str()) != Some("incus")
    {
        bail!("instance backup program must be an absolute incus executable");
    }
    for (label, value) in [
        ("remote", request.remote.as_str()),
        ("project", request.project.as_str()),
        ("instance", request.instance.as_str()),
    ] {
        if !safe_name(value) {
            bail!("instance backup {label} is invalid");
        }
    }
    let archive_root = request.archive_root();
    let namespace = backup_root.join(digest_bytes(resource.as_bytes()));
    validate_archive_root(archive_root, &namespace)?;
    reject_symlink_components(archive_root, backup_root)?;
    match &request.operation {
        InstanceBackupAction::Verify { sha256, .. }
        | InstanceBackupAction::Replace { sha256, .. } => validate_digest(sha256)?,
        InstanceBackupAction::Export { .. } | InstanceBackupAction::DeleteArchive { .. } => {}
    }
    if let InstanceBackupAction::Replace {
        storage_pool: Some(storage_pool),
        ..
    } = &request.operation
        && !safe_name(storage_pool)
    {
        bail!("instance backup storage pool is invalid");
    }
    Ok(())
}

impl InstanceBackupRequest {
    pub fn archive_root(&self) -> &Path {
        match &self.operation {
            InstanceBackupAction::Export { archive_root, .. }
            | InstanceBackupAction::Verify { archive_root, .. }
            | InstanceBackupAction::Replace { archive_root, .. }
            | InstanceBackupAction::DeleteArchive { archive_root } => archive_root,
        }
    }
}

pub fn run_instance_backup(
    request: &InstanceBackupRequest,
    backup_root: &Path,
    resource: &str,
) -> Result<InstanceBackupResult> {
    validate_instance_backup(request, backup_root, resource)?;
    match &request.operation {
        InstanceBackupAction::Export {
            archive_root,
            include_snapshots,
            optimized_storage,
        } => export_instance(
            request,
            archive_root,
            *include_snapshots,
            *optimized_storage,
        ),
        InstanceBackupAction::Verify {
            archive_root,
            sha256,
            size_bytes,
        } => verify_instance(request, archive_root, sha256, *size_bytes),
        InstanceBackupAction::Replace {
            archive_root,
            sha256,
            size_bytes,
            storage_pool,
        } => replace_instance(
            request,
            archive_root,
            sha256,
            *size_bytes,
            storage_pool.as_deref(),
        ),
        InstanceBackupAction::DeleteArchive { archive_root } => {
            delete_archive(request, archive_root)
        }
    }
}

fn export_instance(
    request: &InstanceBackupRequest,
    archive_root: &Path,
    include_snapshots: bool,
    optimized_storage: bool,
) -> Result<InstanceBackupResult> {
    let archive = archive_root.join(ARCHIVE_FILE);
    let identity_path = archive_root.join(IDENTITY_FILE);
    if archive.exists() || identity_path.exists() {
        let identity = read_identity(&identity_path)?;
        ensure_identity_matches(request, &identity, include_snapshots, optimized_storage)?;
        let (sha256, size_bytes) = archive_integrity(&archive)?;
        if sha256 != identity.sha256 || size_bytes != identity.size_bytes {
            bail!("existing instance export differs from its durable identity");
        }
        return Ok(result(
            "export",
            request,
            archive_root,
            Some(sha256),
            Some(size_bytes),
            false,
            Vec::new(),
        ));
    }

    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(archive_root)
        .with_context(|| format!("create instance export root {}", archive_root.display()))?;
    let partial = archive_root.join(format!(".{ARCHIVE_FILE}.partial"));
    if partial.exists() {
        fs::remove_file(&partial)
            .with_context(|| format!("remove stale instance export {}", partial.display()))?;
    }
    let incus = Incus::new(&request.program)?;
    let output = incus.export(
        &request.remote,
        &request.instance,
        &request.project,
        &partial,
        include_snapshots,
        optimized_storage,
    )?;
    ensure_success("instance export", &output)?;
    File::open(&partial)?.sync_all()?;
    fs::rename(&partial, &archive)
        .with_context(|| format!("publish instance export {}", archive.display()))?;
    let (sha256, size_bytes) = archive_integrity(&archive)?;
    let identity = ExportIdentity {
        schema_version: 1,
        remote: request.remote.clone(),
        project: request.project.clone(),
        instance: request.instance.clone(),
        include_snapshots,
        optimized_storage,
        sha256: sha256.clone(),
        size_bytes,
    };
    write_identity(&identity_path, &identity)?;
    File::open(archive_root)?.sync_all()?;
    Ok(result(
        "export",
        request,
        archive_root,
        Some(sha256),
        Some(size_bytes),
        true,
        vec![record(output)],
    ))
}

fn verify_instance(
    request: &InstanceBackupRequest,
    archive_root: &Path,
    expected_sha256: &str,
    expected_size: u64,
) -> Result<InstanceBackupResult> {
    let archive = archive_root.join(ARCHIVE_FILE);
    let (sha256, size_bytes) = archive_integrity(&archive)?;
    if sha256 != expected_sha256 || size_bytes != expected_size {
        bail!(
            "instance export integrity mismatch: expected {expected_sha256}/{expected_size}, got {sha256}/{size_bytes}"
        );
    }
    Ok(result(
        "verify",
        request,
        archive_root,
        Some(sha256),
        Some(size_bytes),
        false,
        Vec::new(),
    ))
}

fn replace_instance(
    request: &InstanceBackupRequest,
    archive_root: &Path,
    expected_sha256: &str,
    expected_size: u64,
    storage_pool: Option<&str>,
) -> Result<InstanceBackupResult> {
    verify_instance(request, archive_root, expected_sha256, expected_size)?;
    let archive = archive_root.join(ARCHIVE_FILE);
    let incus = Incus::new(&request.program)?;
    let mut commands = Vec::new();
    let probe = incus.inspect_instance(&request.remote, &request.instance, &request.project)?;
    if let Some(info) = &probe.info
        && info.status.eq_ignore_ascii_case("running")
    {
        bail!("refusing to replace a running Incus instance");
    }
    let existed = probe.info.is_some();
    commands.push(record(probe.output));
    if existed {
        let output = incus.delete(&request.remote, &request.instance, &request.project)?;
        ensure_success("delete held instance before restore", &output)?;
        commands.push(record(output));
    }
    let output = incus.import(
        &request.remote,
        &archive,
        &request.instance,
        &request.project,
        storage_pool,
    )?;
    ensure_success("instance import", &output)?;
    commands.push(record(output));
    let probe = incus.inspect_instance(&request.remote, &request.instance, &request.project)?;
    let info = probe
        .info
        .as_ref()
        .context("restored Incus instance is absent after import")?;
    if info.status.eq_ignore_ascii_case("running") {
        bail!("restored Incus instance unexpectedly started");
    }
    commands.push(record(probe.output));
    Ok(result(
        "replace",
        request,
        archive_root,
        Some(expected_sha256.to_owned()),
        Some(expected_size),
        true,
        commands,
    ))
}

fn delete_archive(
    request: &InstanceBackupRequest,
    archive_root: &Path,
) -> Result<InstanceBackupResult> {
    let changed = archive_root.exists();
    if changed {
        fs::remove_dir_all(archive_root)
            .with_context(|| format!("delete instance export {}", archive_root.display()))?;
        if let Some(parent) = archive_root.parent() {
            File::open(parent)?.sync_all()?;
        }
    }
    Ok(result(
        "delete_archive",
        request,
        archive_root,
        None,
        None,
        changed,
        Vec::new(),
    ))
}

fn result(
    operation: &'static str,
    request: &InstanceBackupRequest,
    archive_root: &Path,
    sha256: Option<String>,
    size_bytes: Option<u64>,
    changed: bool,
    commands: Vec<InstanceCommandResult>,
) -> InstanceBackupResult {
    InstanceBackupResult {
        operation,
        remote: request.remote.clone(),
        project: request.project.clone(),
        instance: request.instance.clone(),
        archive_root: archive_root.to_path_buf(),
        archive: archive_root.join(ARCHIVE_FILE),
        sha256,
        size_bytes,
        changed,
        commands,
    }
}

fn archive_integrity(path: &Path) -> Result<(String, u64)> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect instance export {}", path.display()))?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        bail!("instance export must be a regular non-symlink file");
    }
    let file =
        File::open(path).with_context(|| format!("open instance export {}", path.display()))?;
    let size = file.metadata()?.len();
    let digest = digest_reader(file).context("hash instance export")?;
    Ok((digest, size))
}

fn write_identity(path: &Path, identity: &ExportIdentity) -> Result<()> {
    let temp = path.with_extension("json.partial");
    if fs::symlink_metadata(&temp).is_ok() {
        fs::remove_file(&temp)
            .with_context(|| format!("remove stale export identity {}", temp.display()))?;
    }
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&temp)
        .with_context(|| format!("create export identity {}", temp.display()))?;
    serde_json::to_writer_pretty(&mut file, identity)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    fs::rename(&temp, path).with_context(|| format!("publish export identity {}", path.display()))
}

fn read_identity(path: &Path) -> Result<ExportIdentity> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect export identity {}", path.display()))?;
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        bail!("instance export identity must be a regular non-symlink file");
    }
    let file =
        File::open(path).with_context(|| format!("open export identity {}", path.display()))?;
    let identity: ExportIdentity =
        serde_json::from_reader(file).context("parse export identity")?;
    if identity.schema_version != 1 {
        bail!("unsupported instance export identity schema");
    }
    Ok(identity)
}

fn ensure_identity_matches(
    request: &InstanceBackupRequest,
    identity: &ExportIdentity,
    include_snapshots: bool,
    optimized_storage: bool,
) -> Result<()> {
    if identity.remote != request.remote
        || identity.project != request.project
        || identity.instance != request.instance
        || identity.include_snapshots != include_snapshots
        || identity.optimized_storage != optimized_storage
    {
        bail!("existing instance export belongs to different immutable backup intent");
    }
    Ok(())
}

fn validate_archive_root(path: &Path, backup_root: &Path) -> Result<()> {
    if !path.is_absolute()
        || path == Path::new("/")
        || path
            .components()
            .any(|component| matches!(component, Component::ParentDir))
        || !path.starts_with(backup_root)
        || path == backup_root
    {
        bail!("instance export root must be a strict descendant of the configured backup root");
    }
    Ok(())
}

fn reject_symlink_components(path: &Path, backup_root: &Path) -> Result<()> {
    for component in path
        .ancestors()
        .take_while(|path| path.starts_with(backup_root))
    {
        match fs::symlink_metadata(component) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                bail!(
                    "instance export path contains symlink component {}",
                    component.display()
                )
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("inspect export path {}", component.display()));
            }
        }
    }
    Ok(())
}

fn validate_digest(value: &str) -> Result<()> {
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("instance export SHA-256 is invalid");
    }
    Ok(())
}

fn safe_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 255
        && !value.starts_with('-')
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

fn ensure_success(label: &str, output: &IncusOutput) -> Result<()> {
    if output.result.success {
        Ok(())
    } else {
        bail!(
            "{label} failed with {:?}: {}",
            output.result.exit_code,
            output.result.stderr
        )
    }
}

fn record(output: IncusOutput) -> InstanceCommandResult {
    InstanceCommandResult {
        arguments: output.arguments,
        success: output.result.success,
        exit_code: output.result.exit_code,
        stdout: output.result.stdout,
        stderr: output.result.stderr,
    }
}

fn default_remote() -> String {
    "local".to_owned()
}

fn default_project() -> String {
    "default".to_owned()
}

fn default_true() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::fs::symlink;

    fn request(program: PathBuf, operation: InstanceBackupAction) -> InstanceBackupRequest {
        InstanceBackupRequest {
            program,
            remote: "local".to_owned(),
            project: "default".to_owned(),
            instance: "demo".to_owned(),
            operation,
        }
    }

    #[test]
    fn archive_roots_must_stay_below_backup_root() {
        let root = Path::new("/var/lib/abird-host-agent/backups");
        assert!(validate_archive_root(&root.join("instance/demo"), root).is_ok());
        assert!(validate_archive_root(root, root).is_err());
        assert!(validate_archive_root(&root.join("../escape"), root).is_err());
    }

    #[test]
    fn request_rejects_untrusted_program_and_digest() {
        let root = Path::new("/backup");
        let resource = "instance:demo";
        let mut request = InstanceBackupRequest {
            program: PathBuf::from("incus"),
            remote: "local".to_owned(),
            project: "default".to_owned(),
            instance: "demo".to_owned(),
            operation: InstanceBackupAction::Verify {
                archive_root: root.join(digest_bytes(resource.as_bytes())).join("item"),
                sha256: "0".repeat(64),
                size_bytes: 1,
            },
        };
        assert!(validate_instance_backup(&request, root, resource).is_err());
        request.program = PathBuf::from("/run/current-system/sw/bin/incus");
        assert!(validate_instance_backup(&request, root, resource).is_ok());
        if let InstanceBackupAction::Verify { sha256, .. } = &mut request.operation {
            *sha256 = "bad".to_owned();
        }
        assert!(validate_instance_backup(&request, root, resource).is_err());
    }

    #[test]
    fn export_is_idempotent_verified_and_deletable() {
        let temp = tempfile::tempdir().unwrap();
        let program = temp.path().join("incus");
        fs::write(
            &program,
            "#!/bin/sh\nif [ \"$1\" = export ]; then printf 'portable-backup' > \"$3\"; fi\n",
        )
        .unwrap();
        fs::set_permissions(&program, fs::Permissions::from_mode(0o700)).unwrap();
        let backup_root = temp.path().join("backups");
        let resource = "instance:demo";
        let archive_root = backup_root
            .join(digest_bytes(resource.as_bytes()))
            .join("snapshot");
        let export = request(
            program.clone(),
            InstanceBackupAction::Export {
                archive_root: archive_root.clone(),
                include_snapshots: true,
                optimized_storage: false,
            },
        );
        let first = run_instance_backup(&export, &backup_root, resource).unwrap();
        assert!(first.changed);
        let second = run_instance_backup(&export, &backup_root, resource).unwrap();
        assert!(!second.changed);
        run_instance_backup(
            &request(
                program.clone(),
                InstanceBackupAction::Verify {
                    archive_root: archive_root.clone(),
                    sha256: first.sha256.unwrap(),
                    size_bytes: first.size_bytes.unwrap(),
                },
            ),
            &backup_root,
            resource,
        )
        .unwrap();
        run_instance_backup(
            &request(
                program,
                InstanceBackupAction::DeleteArchive {
                    archive_root: archive_root.clone(),
                },
            ),
            &backup_root,
            resource,
        )
        .unwrap();
        assert!(!archive_root.exists());
    }

    #[test]
    fn archive_validation_rejects_symlinked_namespaces() {
        let temp = tempfile::tempdir().unwrap();
        let backup_root = temp.path().join("backups");
        let outside = temp.path().join("outside");
        fs::create_dir_all(&backup_root).unwrap();
        fs::create_dir_all(&outside).unwrap();
        let resource = "instance:demo";
        symlink(
            &outside,
            backup_root.join(digest_bytes(resource.as_bytes())),
        )
        .unwrap();
        let request = request(
            "/run/current-system/sw/bin/incus".into(),
            InstanceBackupAction::DeleteArchive {
                archive_root: backup_root
                    .join(digest_bytes(resource.as_bytes()))
                    .join("backup-1"),
            },
        );
        assert!(validate_instance_backup(&request, &backup_root, resource).is_err());
    }
}
