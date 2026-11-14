use std::ffi::CString;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::{MAX_BYTES, MAX_CHILDREN, Manifest, MaterialRef, hash, root, valid_digest, valid_run};

const MANIFEST: &str = "manifest.json";
const NEXT: &str = "manifest.next";
const LOCK: &str = "controller.lock";

fn read_data_at(
    directory: &File,
    kind: &str,
    attempt: &str,
    binding: &MaterialRef,
) -> Result<Vec<u8>> {
    ensure!(
        valid_digest(attempt)
            && binding.bytes
                <= abird_host_agent::build_executor::preparation::source::MAX_MATERIAL_BYTES as u64,
        "invalid retained source binding"
    );
    let file = read_at(directory, &format!("{kind}-{attempt}.json"))?;
    private_file(&file)?;
    ensure!(
        identity(&file)? == (binding.device, binding.inode)
            && file.metadata()?.len() == binding.bytes,
        "retained source replaced or resized"
    );
    let mut bytes = Vec::new();
    (&file).take(binding.bytes + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 == binding.bytes && hash(&bytes) == binding.digest,
        "retained source content differs"
    );
    let current = read_at(directory, &format!("{kind}-{attempt}.json"))?;
    private_file(&current)?;
    ensure!(
        identity(&current)? == (binding.device, binding.inode),
        "retained source replaced during read"
    );
    Ok(bytes)
}

pub(super) fn inspect_material(run: &str, attempt: &str, binding: &MaterialRef) -> Result<Vec<u8>> {
    ensure!(valid_run(run), "invalid durable run ID");
    let path = root()?.join(run);
    let directory = open_directory(&path, false)?;
    private_directory(&directory)?;
    let bytes = read_data_at(&directory, "inputs", attempt, binding)?;
    let current = open_directory(&path, false)?;
    private_directory(&current)?;
    ensure!(
        identity(&current)? == identity(&directory)?,
        "durable parent directory replaced"
    );
    Ok(bytes)
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    checksum: String,
    manifest: Manifest,
}

pub(crate) struct CancellationProbe {
    directory: File,
    digest: String,
}

impl CancellationProbe {
    pub(crate) fn check(&self) -> Result<()> {
        ensure!(
            !cancelled_digest(&self.directory, &self.digest)?,
            "durable parent is cancelling"
        );
        Ok(())
    }
}

pub(super) struct Directory {
    path: PathBuf,
    directory: File,
    lock: File,
    manifest_id: Option<(u64, u64)>,
}

impl Directory {
    pub fn create(id: &str) -> Result<Self> {
        ensure!(valid_run(id), "invalid durable run ID");
        let root = root()?;
        let namespace = open_directory(&root, true)?;
        private_directory(&namespace)?;
        let allocation = match file_at(&namespace, "allocation.lock", true) {
            Ok(file) => {
                file.sync_all()?;
                namespace.sync_all()?;
                file
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                file_at(&namespace, "allocation.lock", false)?
            }
            Err(error) => return Err(error.into()),
        };
        private_file(&allocation)?;
        exclusive(&allocation)?;
        sweep_retired(&root)?;
        // Unsettled and partial parents both consume slots; never expire them.
        ensure!(
            fs::read_dir(format!("/proc/self/fd/{}", namespace.as_raw_fd()))?
                .take(130)
                .collect::<std::io::Result<Vec<_>>>()?
                .len()
                < 129,
            "durable parent capacity exhausted"
        );
        mkdir(&namespace, id)?;
        namespace.sync_all()?;
        let directory = directory_at(&namespace, id)?;
        private_directory(&directory)?;
        let lock = file_at(&directory, LOCK, true)?;
        lock.sync_all()?;
        directory.sync_all()?;
        exclusive(&lock)?;
        Ok(Self {
            path: root.join(id),
            directory,
            lock,
            manifest_id: None,
        })
    }

    pub fn open(id: &str) -> Result<Self> {
        Self::try_open(id)?.context("durable caller already active or exclusion unavailable")
    }

    pub fn try_open(id: &str) -> Result<Option<Self>> {
        let path = root()?.join(id);
        let directory = open_directory(&path, false)?;
        private_directory(&directory)?;
        let lock = file_at(&directory, LOCK, false)?;
        private_file(&lock)?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::WouldBlock {
                return Ok(None);
            }
            return Err(error.into());
        }
        Ok(Some(Self {
            path,
            directory,
            lock,
            manifest_id: None,
        }))
    }

    pub fn retain_material(&self, attempt: &str, bytes: &[u8]) -> Result<MaterialRef> {
        self.retain_data("inputs", attempt, bytes)
    }

    pub fn retain_artifact(&self, attempt: &str, bytes: &[u8]) -> Result<MaterialRef> {
        self.retain_data("artifacts", attempt, bytes)
    }

    pub fn retain_planning(&self, attempt: &str, bytes: &[u8]) -> Result<MaterialRef> {
        self.retain_data("planning", attempt, bytes)
    }

    pub fn read_planning(&self, attempt: &str, binding: &MaterialRef) -> Result<Vec<u8>> {
        self.bound()?;
        let bytes = read_data_at(&self.directory, "planning", attempt, binding)?;
        self.bound()?;
        Ok(bytes)
    }

    fn retain_data(&self, kind: &str, attempt: &str, bytes: &[u8]) -> Result<MaterialRef> {
        use abird_host_agent::build_executor::preparation::source::MAX_MATERIAL_BYTES;
        ensure!(
            valid_digest(attempt) && !bytes.is_empty() && bytes.len() <= MAX_MATERIAL_BYTES,
            "invalid retained source bounds"
        );
        self.bound()?;
        let mut file = file_at(&self.directory, &format!("{kind}-{attempt}.json"), true)?;
        self.directory.sync_all()?;
        file.write_all(bytes)?;
        file.sync_all()?;
        self.directory.sync_all()?;
        private_file(&file)?;
        let (device, inode) = identity(&file)?;
        let binding = MaterialRef {
            digest: hash(bytes),
            bytes: bytes.len() as u64,
            device,
            inode,
        };
        read_data_at(&self.directory, kind, attempt, &binding)?;
        self.bound()?;
        Ok(binding)
    }

    pub fn read_material(&self, attempt: &str, binding: &MaterialRef) -> Result<Vec<u8>> {
        ensure!(valid_digest(attempt), "invalid retained source attempt");
        self.bound()?;
        let bytes = read_data_at(&self.directory, "inputs", attempt, binding)?;
        self.bound()?;
        Ok(bytes)
    }

    pub fn read_artifact(&self, attempt: &str, binding: &MaterialRef) -> Result<Vec<u8>> {
        self.bound()?;
        let bytes = read_data_at(&self.directory, "artifacts", attempt, binding)?;
        self.bound()?;
        Ok(bytes)
    }

    pub fn pin_known_hosts(&self, attempt: &str, source: &Path) -> Result<PathBuf> {
        use std::os::unix::fs::OpenOptionsExt;
        self.bound()?;
        // NixOS publishes system SSH trust as /etc → /etc/static → store links.
        // Follow only a fully root-controlled chain, then open no-follow.
        let source = if fs::symlink_metadata(source)?.file_type().is_symlink() {
            abird_host_agent::build_executor::daemon::trusted_path(source)?;
            let resolved = fs::canonicalize(source)?;
            abird_host_agent::build_executor::daemon::trusted_path(&resolved)?;
            resolved
        } else {
            source.to_owned()
        };
        let input = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(&source)?;
        let metadata = input.metadata()?;
        ensure!(
            metadata.is_file()
                && metadata.len() <= 64 * 1024
                && (metadata.uid() == 0 || metadata.uid() == unsafe { libc::geteuid() })
                && metadata.mode() & 0o022 == 0,
            "unbounded or mutable foreign SSH trust file"
        );
        let mut bytes = Vec::new();
        input.take(64 * 1024 + 1).read_to_end(&mut bytes)?;
        ensure!(bytes.len() <= 64 * 1024, "SSH trust file exceeds bound");
        let name = format!("known-hosts-{attempt}");
        let mut output = file_at(&self.directory, &name, true)?;
        self.directory.sync_all()?;
        output.write_all(&bytes)?;
        output.sync_all()?;
        self.directory.sync_all()?;
        Ok(self.path.join(name))
    }

    pub fn cancelled(&self, manifest: &Manifest) -> Result<bool> {
        self.bound()?;
        cancelled_at(&self.directory, manifest)
    }

    pub fn cancellation_probe(&self, manifest: &Manifest) -> Result<CancellationProbe> {
        self.bound()?;
        Ok(CancellationProbe {
            directory: self.directory.try_clone()?,
            digest: intent_digest(manifest)?,
        })
    }

    pub fn inherited_lock(&self) -> Result<File> {
        self.bound()?;
        Ok(self.lock.try_clone()?)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Caller-checked eligible parent only. One atomic rename to a tombstone
    /// name removes it from every lookup; data removal may finish later via
    /// the creation sweep. Holds this parent's exclusion throughout.
    pub fn retire(self, id: &str) -> Result<()> {
        self.bound()?;
        let root = root()?;
        ensure!(
            self.path == root.join(id),
            "durable parent identity differs"
        );
        fs::rename(&self.path, root.join(format!(".retired-{id}")))
            .context("retire durable parent")?;
        File::open(&root)?.sync_all()?;
        // Retired once the rename is durable; residue is swept again on creation.
        let _ = sweep_retired(&root);
        Ok(())
    }

    fn bound(&self) -> Result<()> {
        let current = open_directory(&self.path, false)?;
        private_directory(&current)?;
        ensure!(
            identity(&current)? == identity(&self.directory)?,
            "durable parent directory replaced"
        );
        let lock = file_at(&self.directory, LOCK, false)?;
        private_file(&lock)?;
        ensure!(
            identity(&lock)? == identity(&self.lock)?,
            "durable caller exclusion replaced"
        );
        match (self.manifest_id, file_at(&self.directory, MANIFEST, false)) {
            (Some(expected), Ok(file)) => {
                private_file(&file)?;
                ensure!(identity(&file)? == expected, "durable manifest replaced");
            }
            (None, Err(error)) if error.kind() == std::io::ErrorKind::NotFound => {}
            _ => anyhow::bail!("durable manifest presence differs"),
        }
        Ok(())
    }

    pub fn load(&mut self) -> Result<Manifest> {
        let file = file_at(&self.directory, MANIFEST, false)?;
        private_file(&file)?;
        self.manifest_id = Some(identity(&file)?);
        let mut bytes = Vec::new();
        file.take((MAX_BYTES + 1025) as u64)
            .read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() <= MAX_BYTES + 1024,
            "durable manifest exceeds bound"
        );
        let envelope: Envelope =
            serde_json::from_slice(&bytes).context("invalid durable manifest")?;
        ensure!(
            hash(&serde_json::to_vec(&envelope.manifest)?) == envelope.checksum,
            "durable manifest checksum differs"
        );
        envelope.manifest.validate()?;
        self.bound()?;
        Ok(envelope.manifest)
    }

    pub fn save(&mut self, manifest: &Manifest) -> Result<()> {
        self.bound()?;
        let body = serde_json::to_vec(manifest)?;
        ensure!(body.len() <= MAX_BYTES, "durable manifest exceeds bound");
        let bytes = serde_json::to_vec(
            &serde_json::json!({"checksum": hash(&body), "manifest": manifest}),
        )?;
        // Held exclusion: any staged file is a dead holder's unpublished
        // residue (e.g. SIGKILL mid-save). Discard, never adopt; only the
        // renamed manifest is durable and effects follow publication.
        unlink_absent_ok(&self.directory, NEXT)?;
        let mut next = file_at(&self.directory, NEXT, true)?;
        self.directory.sync_all()?;
        next.write_all(&bytes)?;
        next.sync_all()?;
        self.bound()?;
        let old = CString::new(NEXT)?;
        let new = CString::new(MANIFEST)?;
        ensure!(
            unsafe {
                libc::renameat(
                    self.directory.as_raw_fd(),
                    old.as_ptr(),
                    self.directory.as_raw_fd(),
                    new.as_ptr(),
                )
            } == 0,
            "durable manifest publication failed"
        );
        self.manifest_id = Some(identity(&next)?);
        self.directory.sync_all()?;
        self.bound()
    }
}

fn intent_digest(manifest: &Manifest) -> Result<String> {
    let intents = manifest
        .children
        .values()
        .map(|child| child.request.digest())
        .collect::<Result<Vec<_>>>()?;
    Ok(hash(&serde_json::to_vec(&(&manifest.run_id, intents))?))
}

fn cancelled_at(directory: &File, manifest: &Manifest) -> Result<bool> {
    cancelled_digest(directory, &intent_digest(manifest)?)
}

fn cancelled_digest(directory: &File, digest: &str) -> Result<bool> {
    let file = match file_at(directory, "cancel.intent", false) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.into()),
    };
    private_file(&file)?;
    let mut bytes = Vec::new();
    file.take(65).read_to_end(&mut bytes)?;
    ensure!(
        bytes == digest.as_bytes(),
        "durable cancellation intent differs"
    );
    Ok(true)
}

/// Flat, bounded cleanup of tombstoned records, never recursive path deletion.
fn sweep_retired(root: &Path) -> Result<()> {
    let namespace = open_directory(root, false)?;
    private_directory(&namespace)?;
    for entry in fs::read_dir(root)?.take(256) {
        let entry = entry?;
        let name = entry.file_name();
        let Some(id) = name
            .to_str()
            .and_then(|name| name.strip_prefix(".retired-"))
        else {
            continue;
        };
        ensure!(valid_run(id), "unexpected retired parent name");
        let metadata = match fs::symlink_metadata(entry.path()) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            metadata => metadata?,
        };
        ensure!(
            metadata.is_dir() && metadata.uid() == unsafe { libc::geteuid() },
            "retired parent is not private"
        );
        let name = name.to_str().context("invalid retired parent name")?;
        let directory = directory_at(&namespace, name)?;
        private_directory(&directory)?;
        let entries = fs::read_dir(format!("/proc/self/fd/{}", directory.as_raw_fd()))?
            .take(MAX_CHILDREN * 4 + 5)
            .collect::<std::io::Result<Vec<_>>>()?;
        ensure!(
            entries.len() <= MAX_CHILDREN * 4 + 4,
            "retired parent exceeds bound"
        );
        let mut names = Vec::new();
        for entry in entries {
            let entry = entry.file_name();
            let entry = entry.to_str().context("invalid retired file name")?;
            ensure!(retired_file(entry), "unexpected retired caller entry");
            private_file(&read_at(&directory, entry)?)?;
            names.push(entry.to_owned());
        }
        for entry in names {
            unlink_absent_ok(&directory, &entry)?;
        }
        directory.sync_all()?;
        ensure!(
            identity(&directory_at(&namespace, name)?)? == identity(&directory)?,
            "retired parent replaced"
        );
        let name = CString::new(name)?;
        ensure!(
            unsafe { libc::unlinkat(namespace.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) }
                == 0,
            "remove retired durable parent failed"
        );
        namespace.sync_all()?;
    }
    Ok(())
}

fn retired_file(name: &str) -> bool {
    matches!(name, MANIFEST | NEXT | LOCK | "cancel.intent")
        || name.strip_prefix("known-hosts-").is_some_and(valid_digest)
        || ["inputs-", "artifacts-", "planning-"].iter().any(|prefix| {
            name.strip_prefix(*prefix)
                .and_then(|name| name.strip_suffix(".json"))
                .is_some_and(valid_digest)
        })
}

pub(super) fn cancel(run_id: &str, manifest: &Manifest) -> Result<()> {
    ensure!(
        valid_run(run_id) && manifest.run_id == run_id,
        "invalid durable cancellation identity"
    );
    let directory = open_directory(&root()?.join(run_id), false)?;
    private_directory(&directory)?;
    if cancelled_at(&directory, manifest)? {
        return Ok(());
    }
    let mut file = match file_at(&directory, "cancel.intent", true) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            ensure!(
                cancelled_at(&directory, manifest)?,
                "cancellation intent vanished"
            );
            return Ok(());
        }
        Err(error) => return Err(error.into()),
    };
    directory.sync_all()?;
    file.write_all(intent_digest(manifest)?.as_bytes())?;
    file.sync_all()?;
    directory.sync_all()?;
    Ok(())
}

pub(super) fn inspect(run_id: &str) -> Result<Manifest> {
    ensure!(valid_run(run_id), "invalid durable run ID");
    let directory = open_directory(&root()?.join(run_id), false)?;
    private_directory(&directory)?;
    let file = read_at(&directory, MANIFEST)?;
    private_file(&file)?;
    let mut bytes = Vec::new();
    file.take((MAX_BYTES + 1025) as u64)
        .read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= MAX_BYTES + 1024,
        "durable manifest exceeds bound"
    );
    let envelope: Envelope = serde_json::from_slice(&bytes).context("invalid durable manifest")?;
    ensure!(
        hash(&serde_json::to_vec(&envelope.manifest)?) == envelope.checksum
            && envelope.manifest.run_id == run_id,
        "durable manifest checksum/identity differs"
    );
    envelope.manifest.validate()?;
    Ok(envelope.manifest)
}

fn identity(file: &File) -> Result<(u64, u64)> {
    let metadata = file.metadata()?;
    Ok((metadata.dev(), metadata.ino()))
}

fn exclusive(file: &File) -> Result<()> {
    ensure!(
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
        "durable caller already active or exclusion unavailable"
    );
    Ok(())
}

fn private_file(file: &File) -> Result<()> {
    let meta = file.metadata()?;
    ensure!(
        meta.is_file()
            && meta.uid() == unsafe { libc::geteuid() }
            && meta.nlink() == 1
            && meta.mode() & 0o7777 == 0o600,
        "invalid durable caller file"
    );
    Ok(())
}

fn private_directory(file: &File) -> Result<()> {
    let meta = file.metadata()?;
    ensure!(
        meta.is_dir() && meta.uid() == unsafe { libc::geteuid() } && meta.mode() & 0o7777 == 0o700,
        "invalid durable caller directory"
    );
    Ok(())
}

fn open_directory(path: &Path, create: bool) -> Result<File> {
    ensure!(
        path.is_absolute(),
        "durable caller directory must be absolute"
    );
    let mut directory = File::open("/")?;
    for component in path.components() {
        let Component::Normal(name) = component else {
            ensure!(
                matches!(component, Component::RootDir),
                "noncanonical durable caller directory"
            );
            continue;
        };
        let name = CString::new(name.as_bytes())?;
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_DIRECTORY,
            )
        };
        let next = if fd >= 0 {
            unsafe { File::from_raw_fd(fd) }
        } else {
            let error = std::io::Error::last_os_error();
            ensure!(
                create && error.kind() == std::io::ErrorKind::NotFound,
                "durable caller ancestor unavailable"
            );
            let created = unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) };
            if created != 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            directory.sync_all()?;
            let fd = unsafe {
                libc::openat(
                    directory.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_DIRECTORY,
                )
            };
            ensure!(fd >= 0, "new durable caller ancestor unavailable");
            unsafe { File::from_raw_fd(fd) }
        };
        let meta = next.metadata()?;
        ensure!(
            meta.uid() == 0 || meta.uid() == unsafe { libc::geteuid() },
            "foreign durable caller ancestor"
        );
        ensure!(
            meta.mode() & 0o022 == 0 || (meta.uid() == 0 && meta.mode() & libc::S_ISVTX != 0),
            "writable durable caller ancestor"
        );
        directory = next;
    }
    Ok(directory)
}

fn read_at(directory: &File, name: &str) -> std::io::Result<File> {
    open_file_at(directory, name, libc::O_RDONLY)
}

fn file_at(directory: &File, name: &str, create: bool) -> std::io::Result<File> {
    open_file_at(
        directory,
        name,
        libc::O_RDWR
            | if create {
                libc::O_CREAT | libc::O_EXCL
            } else {
                0
            },
    )
}

fn open_file_at(directory: &File, name: &str, access: libc::c_int) -> std::io::Result<File> {
    let name = CString::new(name)?;
    let flags = access | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
    let fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags, 0o600) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn unlink_absent_ok(directory: &File, name: &str) -> Result<()> {
    let name = CString::new(name)?;
    if unsafe { libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), 0) } != 0 {
        let error = std::io::Error::last_os_error();
        ensure!(
            error.kind() == std::io::ErrorKind::NotFound,
            "staged manifest residue removal failed: {error}"
        );
    }
    Ok(())
}

fn mkdir(directory: &File, name: &str) -> Result<()> {
    let name = CString::new(name)?;
    if unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}

fn directory_at(directory: &File, name: &str) -> Result<File> {
    let name = CString::new(name)?;
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_DIRECTORY,
        )
    };
    ensure!(fd >= 0, "durable caller directory unavailable");
    Ok(unsafe { File::from_raw_fd(fd) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};

    #[test]
    fn retired_cleanup_rejects_foreign_entries_and_never_recurses() {
        let root = tempfile::tempdir().unwrap();
        fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let retired = root.path().join(format!(".retired-{}", "a".repeat(32)));
        fs::DirBuilder::new().mode(0o700).create(&retired).unwrap();
        let directory = open_directory(&retired, false).unwrap();
        file_at(&directory, MANIFEST, true).unwrap();
        fs::create_dir(retired.join("foreign")).unwrap();
        assert!(sweep_retired(root.path()).is_err());
        assert!(retired.join(MANIFEST).exists());
        assert!(retired.join("foreign").is_dir());
        fs::remove_dir(retired.join("foreign")).unwrap();
        std::os::unix::fs::symlink(root.path(), retired.join("inputs-foreign.json")).unwrap();
        assert!(sweep_retired(root.path()).is_err());
        assert!(retired.join(MANIFEST).exists());
        fs::remove_file(retired.join("inputs-foreign.json")).unwrap();
        // A prior cleanup may already have removed other known files.
        sweep_retired(root.path()).unwrap();
        assert!(!retired.exists());
        sweep_retired(root.path()).unwrap();
    }
}
