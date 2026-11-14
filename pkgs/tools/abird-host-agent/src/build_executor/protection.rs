//! Durable registration of native Nix GC roots; never realise paths to root them.
//!
//! These are root-link receipts, not store validity/NAR/closure/handoff proofs.
//! Production needs qualified GC exclusion from before preparation through root
//! publication, including controller death. `Journal::retention_clear` is only
//! one necessary veto in that authority, not standalone permission to collect.

use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, symlink};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::journal::{Journal, open_directory, private_file};
use super::launch_gate::{Gate, Permission, Permit};
use super::request::{StorageIdentity, store_path};
use super::{Ownership, digest};
use crate::sha256::digest_bytes;

const VERSION: u32 = 1;
const MAX_ROOTS: usize = 1 + 64 + 64 + 64 * 16;
const MAX_BYTES: u64 = 512 * 1024;
const REGISTRY: &str = "/nix/var/nix/gcroots";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RootSet {
    pub version: u32,
    pub storage: StorageIdentity,
    pub owner: Ownership,
    pub spec_digest: String,
    pub paths: BTreeSet<String>,
}
impl RootSet {
    fn validate(&self) -> Result<()> {
        ensure!(
            self.version == VERSION && self.paths.len() <= MAX_ROOTS,
            "invalid root-set bounds/version"
        );
        self.storage.validate()?;
        self.owner.validate(&self.owner.attempt_id)?;
        digest(&self.owner.attempt_id)?;
        digest(&self.spec_digest)?;
        ensure!(
            self.owner.builder_id == self.storage.builder_id
                && self.owner.store_id == self.storage.store_id,
            "root storage mismatch"
        );
        for path in &self.paths {
            store_path(path)?;
        }
        Ok(())
    }
    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        Ok(digest_bytes(&serde_json::to_vec(self)?))
    }
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Record {
    roots: RootSet,
    // Durable before unlink. Neither this intent nor a missing link releases the
    // journal veto; only completed release/handoff can publish that receipt.
    release_intent: Option<String>,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    checksum: String,
    record: Record,
}
#[derive(Serialize)]
struct EnvelopeRef<'a> {
    checksum: String,
    record: &'a Record,
}

struct Directory {
    path: PathBuf,
    device: u64,
    inode: u64,
}
impl Directory {
    fn open(path: PathBuf) -> Result<Self> {
        ensure!(
            path.is_absolute() && fs::canonicalize(&path)? == path,
            "root directory redirected"
        );
        let meta = open_directory(&path)?.metadata()?;
        Ok(Self {
            path,
            device: meta.dev(),
            inode: meta.ino(),
        })
    }
    fn check(&self) -> Result<File> {
        let directory = open_directory(&self.path)?;
        let meta = directory.metadata()?;
        ensure!(
            meta.dev() == self.device
                && meta.ino() == self.inode
                && fs::canonicalize(&self.path)? == self.path,
            "root directory replaced"
        );
        Ok(directory)
    }
}
fn child(parent: &Path, name: &str) -> Result<PathBuf> {
    // Nix owns the shared 0755 registry parent; our children remain 0700.
    // Do not relax the private journal/manifest checks for this integration edge.
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(parent)?;
    let metadata = directory.metadata()?;
    ensure!(
        metadata.uid() == unsafe { libc::geteuid() }
            && metadata.mode() & 0o022 == 0
            && fs::canonicalize(parent)? == parent,
        "root parent redirected or writable by another principal"
    );
    let path = parent.join(name);
    match fs::DirBuilder::new().mode(0o700).create(&path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error.into()),
    }
    open_directory(&path)?.sync_all()?;
    directory.sync_all()?;
    Ok(path)
}

#[derive(Clone, Copy, Debug)]
enum Point {
    Created,
    Written,
    FileSynced,
    Renamed,
    DirectorySynced,
    RootCreated,
    RootsSynced,
    ReleasePlanned,
    RootRemoved,
    ReleaseSynced,
    NativeRetired,
    ManifestRemoved,
    StateRetired,
}

pub struct NativeRoots {
    state: Directory,
    native: Directory,
    owner: Ownership,
    storage: StorageIdentity,
    require_placement: bool,
    #[cfg(test)]
    fault: Option<fn(Point) -> Result<()>>,
}
impl NativeRoots {
    /// Explicit per-attempt provisioning, only after admission. Native registration
    /// lives in Nix's registry; the sole metadata authority remains under XDG state.
    pub fn initialize(journal: &Journal, gate: &Gate, owner: Ownership) -> Result<Self> {
        ensure!(
            unsafe { libc::geteuid() } == 0,
            "native root registration requires the trusted root adapter"
        );
        super::workload::require_wrapper_placement()?;
        ensure!(
            gate.identity() == journal.identity(),
            "root gate identity mismatch"
        );
        let _launch = gate
            .authorize(&Permit {
                version: 1,
                identity: journal.identity().clone(),
                permission: Permission::Execution {
                    ownership: owner.clone(),
                },
            })?
            .context("root initialization fenced")?;
        Self::at(journal, owner, Path::new(REGISTRY), true, true)
    }
    /// Both namespaces must positively lack this registration. An incomplete
    /// registration is not absence and is never reconstructed by cleanup.
    pub(super) fn absent(journal: &Journal, owner: &Ownership) -> Result<bool> {
        digest(&owner.attempt_id)?;
        let namespace = digest_bytes(&serde_json::to_vec(journal.identity())?);
        for path in [
            journal
                .authority_root()
                .join("roots")
                .join(&owner.attempt_id),
            Path::new(REGISTRY)
                .join("abird-host-agent-owned")
                .join(namespace)
                .join(&owner.attempt_id),
        ] {
            match fs::symlink_metadata(path) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Ok(_) => return Ok(false),
                Err(error) => return Err(error.into()),
            }
        }
        Ok(true)
    }

    /// Missing/corrupt authorities never reinitialize on open.
    pub fn open(journal: &Journal, owner: Ownership) -> Result<Self> {
        ensure!(
            unsafe { libc::geteuid() } == 0,
            "native root registration requires the trusted root adapter"
        );
        Self::at(journal, owner, Path::new(REGISTRY), false, true)
    }
    fn at(
        journal: &Journal,
        owner: Ownership,
        registry: &Path,
        initialize: bool,
        require_placement: bool,
    ) -> Result<Self> {
        digest(&owner.attempt_id)?;
        let (spec_digest, settled, released) = journal.protection_context(&owner)?;
        let storage = journal.identity().clone();
        let namespace = digest_bytes(&serde_json::to_vec(&storage)?);
        let state_path = journal
            .authority_root()
            .join("roots")
            .join(&owner.attempt_id);
        let native_path = registry
            .join("abird-host-agent-owned")
            .join(&namespace)
            .join(&owner.attempt_id);
        if initialize {
            ensure!(
                !settled && released.is_none(),
                "cannot initialize settled protection"
            );
            child(
                &child(journal.authority_root(), "roots")?,
                &owner.attempt_id,
            )?;
            child(
                &child(&child(registry, "abird-host-agent-owned")?, &namespace)?,
                &owner.attempt_id,
            )?;
        }
        let roots = Self {
            state: Directory::open(state_path)?,
            native: Directory::open(native_path)?,
            owner,
            storage,
            require_placement,
            #[cfg(test)]
            fault: None,
        };
        let lock = roots.lock()?;
        if initialize {
            match fs::symlink_metadata(roots.state.path.join("roots.json")) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                _ => anyhow::bail!("protection already initialized or inaccessible"),
            }
            for entry in fs::read_dir(&roots.state.path)? {
                ensure!(
                    entry?.file_name() == "roots.pending",
                    "unrecorded protection metadata"
                );
            }
            ensure!(
                fs::read_dir(&roots.native.path)?.next().is_none(),
                "unrecorded native roots"
            );
            roots.write(
                &lock,
                &Record {
                    roots: RootSet {
                        version: VERSION,
                        storage: roots.storage.clone(),
                        owner: roots.owner.clone(),
                        spec_digest,
                        paths: BTreeSet::new(),
                    },
                    release_intent: None,
                },
            )?;
        } else {
            roots.read(&lock, journal)?;
        }
        Ok(roots)
    }
    fn lock(&self) -> Result<File> {
        let directory = self.state.check()?;
        directory.lock()?;
        self.state.check()?;
        self.native.check()?;
        Ok(directory)
    }
    fn read(&self, directory: &File, journal: &Journal) -> Result<Record> {
        read_record(&self.state, directory, journal, &self.owner, &self.storage)
    }
    fn point(&self, point: Point) -> Result<()> {
        #[cfg(test)]
        if let Some(fault) = self.fault {
            fault(point)?;
        }
        let _ = point;
        Ok(())
    }
    fn write(&self, directory: &File, record: &Record) -> Result<()> {
        record.roots.validate()?;
        let bytes = serde_json::to_vec(&EnvelopeRef {
            checksum: digest_bytes(&serde_json::to_vec(record)?),
            record,
        })?;
        ensure!(
            bytes.len() as u64 <= MAX_BYTES,
            "root metadata exceeds bound"
        );
        let pending = self.state.path.join("roots.pending");
        match private_file(&pending) {
            Ok(_) => {
                fs::remove_file(&pending)?;
                directory.sync_all()?;
            }
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) => {}
            Err(error) => return Err(error),
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&pending)?;
        self.point(Point::Created)?;
        file.write_all(&bytes)?;
        self.point(Point::Written)?;
        file.sync_all()?;
        self.point(Point::FileSynced)?;
        self.state.check()?;
        fs::rename(&pending, self.state.path.join("roots.json"))?;
        self.point(Point::Renamed)?;
        directory.sync_all()?;
        self.point(Point::DirectorySynced)
    }
    fn native_path(&self, path: &str) -> PathBuf {
        self.native.path.join(digest_bytes(path.as_bytes()))
    }
    fn check_entries(&self, roots: &RootSet) -> Result<()> {
        let expected: BTreeSet<_> = roots
            .paths
            .iter()
            .map(|path| digest_bytes(path.as_bytes()))
            .collect();
        for (index, entry) in fs::read_dir(&self.native.path)?.enumerate() {
            ensure!(
                index < MAX_ROOTS
                    && expected.contains(&entry?.file_name().to_string_lossy().into_owned()),
                "unrecorded native root entry"
            );
        }
        Ok(())
    }
    fn link(&self, path: &str) -> Result<bool> {
        match fs::symlink_metadata(self.native_path(path)) {
            Ok(meta) => {
                ensure!(
                    meta.file_type().is_symlink()
                        && meta.uid() == unsafe { libc::geteuid() }
                        && meta.nlink() == 1
                        && fs::read_link(self.native_path(path))? == Path::new(path),
                    "native root replaced"
                );
                Ok(true)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error.into()),
        }
    }
    /// Additive/idempotent only. Caller must hold qualified GC exclusion; no Nix
    /// evaluation/build is executed here, including for `.drv` paths.
    pub fn retain(&self, journal: &Journal, gate: &Gate, paths: &[String]) -> Result<RootSet> {
        ensure!(
            !paths.is_empty() && paths.len() <= MAX_ROOTS,
            "invalid root count"
        );
        for path in paths {
            store_path(path)?;
        }
        ensure!(
            gate.identity() == &self.storage,
            "root gate identity mismatch"
        );
        if self.require_placement {
            super::workload::require_wrapper_placement()?;
        }
        let _launch = gate
            .authorize(&Permit {
                version: 1,
                identity: self.storage.clone(),
                permission: Permission::Execution {
                    ownership: self.owner.clone(),
                },
            })?
            .context("root publication fenced")?;
        let directory = self.lock()?;
        let mut record = self.read(&directory, journal)?;
        let (_, settled, released) = journal.protection_context(&self.owner)?;
        ensure!(
            !settled && released.is_none() && record.release_intent.is_none(),
            "cannot extend released/settled protection"
        );
        self.check_entries(&record.roots)?;
        for path in &record.roots.paths {
            self.link(path)?;
        }
        let before = record.roots.paths.len();
        record.roots.paths.extend(paths.iter().cloned());
        record.roots.validate()?;
        if record.roots.paths.len() != before {
            self.write(&directory, &record)?;
        }
        for path in &record.roots.paths {
            self.native.check()?;
            if !self.link(path)? {
                symlink(path, self.native_path(path))?;
                self.point(Point::RootCreated)?;
            }
        }
        self.native.check()?.sync_all()?;
        self.point(Point::RootsSynced)?;
        self.verify_locked(&record)?;
        Ok(record.roots)
    }
    fn verify_locked(&self, record: &Record) -> Result<()> {
        ensure!(
            record.release_intent.is_none() && !record.roots.paths.is_empty(),
            "root set empty or release already planned"
        );
        self.check_entries(&record.roots)?;
        for path in &record.roots.paths {
            ensure!(self.link(path)?, "native root missing");
        }
        self.native.check()?.sync_all()?;
        Ok(())
    }
    /// Verify exact native links, not store contents or whether every GC entrypoint
    /// participates in the role. An expired worker never makes missing roots safe.
    pub fn verify(&self, journal: &Journal) -> Result<RootSet> {
        let directory = self.lock()?;
        let record = self.read(&directory, journal)?;
        self.verify_locked(&record)?;
        Ok(record.roots)
    }
    /// Remove only released, empty registrations/metadata before journal pruning.
    /// Reentrant after partial cleanup; no initialization or store-path deletion.
    pub fn retire(journal: &Journal, owner: &Ownership) -> Result<()> {
        ensure!(
            unsafe { libc::geteuid() } == 0,
            "root retirement requires the trusted root adapter"
        );
        Self::retire_at(journal, owner, Path::new(REGISTRY), |_| Ok(()))
    }
    fn retire_at(
        journal: &Journal,
        owner: &Ownership,
        registry: &Path,
        point: impl Fn(Point) -> Result<()>,
    ) -> Result<()> {
        let (_, settled, released) = journal.protection_context(owner)?;
        let evidence = released.context("protection not released")?;
        ensure!(settled, "protection not settled");
        let state_parent = journal.authority_root().join("roots");
        let state_path = state_parent.join(&owner.attempt_id);
        let namespace = digest_bytes(&serde_json::to_vec(journal.identity())?);
        let native_parent = registry.join("abird-host-agent-owned").join(namespace);
        let native_path = native_parent.join(&owner.attempt_id);
        let state_parent_fd = open_directory(&state_parent)?;
        let native_parent_fd = open_directory(&native_parent)?;
        ensure!(
            fs::canonicalize(&state_parent)? == state_parent
                && fs::canonicalize(&native_parent)? == native_parent,
            "retirement parent redirected"
        );
        let state = match fs::symlink_metadata(&state_path) {
            Ok(_) => Some(Directory::open(state_path.clone())?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(error.into()),
        };
        let lock = if let Some(state) = &state {
            let directory = state.check()?;
            directory.lock()?;
            state.check()?;
            for entry in fs::read_dir(&state.path)? {
                let name = entry?.file_name();
                ensure!(
                    name == "roots.json" || name == "roots.pending",
                    "unrecorded protection metadata"
                );
            }
            match private_file(&state.path.join("roots.json")) {
                Ok(_) => {
                    let record =
                        read_record(state, &directory, journal, owner, journal.identity())?;
                    ensure!(
                        record.release_intent.as_ref() == Some(&evidence),
                        "release receipt mismatch"
                    );
                }
                Err(error)
                    if error
                        .downcast_ref::<std::io::Error>()
                        .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) => {}
                Err(error) => return Err(error),
            }
            Some(directory)
        } else {
            None
        };
        match fs::symlink_metadata(&native_path) {
            Ok(_) => {
                let directory = Directory::open(native_path.clone())?;
                directory.check()?;
                ensure!(
                    state.is_some() && fs::read_dir(&native_path)?.next().is_none(),
                    "native roots remain or metadata missing"
                );
                fs::remove_dir(&native_path)?;
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        native_parent_fd.sync_all()?;
        point(Point::NativeRetired)?;
        if let Some(state) = state {
            for name in ["roots.pending", "roots.json"] {
                let path = state.path.join(name);
                match private_file(&path) {
                    Ok(_) => {
                        fs::remove_file(&path)?;
                    }
                    Err(error)
                        if error
                            .downcast_ref::<std::io::Error>()
                            .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) => {}
                    Err(error) => return Err(error),
                }
            }
            lock.as_ref()
                .context("retirement lock missing")?
                .sync_all()?;
            point(Point::ManifestRemoved)?;
            state.check()?;
            fs::remove_dir(&state.path)?;
        }
        state_parent_fd.sync_all()?;
        point(Point::StateRetired)
    }

    /// Trusted verifier supplies settled retention/handoff evidence. Persist intent
    /// before unlink, then confirm native directory durability before journal release.
    /// Never delete a store object or an unknown/replaced root to recover capacity.
    pub fn release(&self, journal: &Journal, evidence: &str, now: u64) -> Result<()> {
        self.release_while(journal, evidence, || Ok(now))
    }

    pub(super) fn release_while(
        &self,
        journal: &Journal,
        evidence: &str,
        mut active: impl FnMut() -> Result<u64>,
    ) -> Result<()> {
        active()?;
        digest(evidence)?;
        let directory = self.lock()?;
        let mut record = self.read(&directory, journal)?;
        let (_, settled, released) = journal.protection_context(&self.owner)?;
        ensure!(
            settled && released.as_deref().is_none_or(|old| old == evidence),
            "unsettled/conflicting protection release"
        );
        ensure!(
            record
                .release_intent
                .as_deref()
                .is_none_or(|old| old == evidence),
            "release intent conflict"
        );
        self.check_entries(&record.roots)?;
        for path in &record.roots.paths {
            active()?;
            self.link(path)?;
        }
        active()?;
        if record.release_intent.is_none() {
            record.release_intent = Some(evidence.to_owned());
            self.write(&directory, &record)?;
        }
        self.point(Point::ReleasePlanned)?;
        for path in &record.roots.paths {
            active()?;
            self.native.check()?;
            if self.link(path)? {
                active()?;
                fs::remove_file(self.native_path(path))?;
                self.point(Point::RootRemoved)?;
            }
        }
        self.native.check()?.sync_all()?;
        self.point(Point::ReleaseSynced)?;
        journal.released(&self.owner.attempt_id, evidence, active()?)
    }
}

fn read_record(
    state: &Directory,
    directory: &File,
    journal: &Journal,
    owner: &Ownership,
    storage: &StorageIdentity,
) -> Result<Record> {
    let mut file = private_file(&state.path.join("roots.json"))?;
    let mut bytes = Vec::new();
    (&mut file).take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= MAX_BYTES,
        "root metadata exceeds bound"
    );
    let envelope: Envelope = serde_json::from_slice(&bytes)?;
    let record = envelope.record;
    record.roots.validate()?;
    let (spec, _, _) = journal.protection_context(owner)?;
    ensure!(
        record.roots.owner == *owner
            && record.roots.storage == *storage
            && record.roots.spec_digest == spec
            && envelope.checksum == digest_bytes(&serde_json::to_vec(&record)?),
        "root metadata identity/checksum mismatch"
    );
    if let Some(evidence) = &record.release_intent {
        digest(evidence)?;
    }
    file.sync_all()?;
    directory.sync_all()?;
    state.check()?;
    Ok(record)
}

#[cfg(test)]
mod tests;
