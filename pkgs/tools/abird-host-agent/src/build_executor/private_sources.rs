//! Journal-backed private source allocations. Registration precedes mkdir;
//! directory removal/fsync precedes retirement and journal pruning.
//!
//! Trusted root adapter only, no caller wire verbs. These records own private
//! data namespaces, not source integrity or GC permission. Only empty allocation
//! retirement is implemented: nonempty/foreign data must remain tracked until a
//! separately qualified, accounted cleanup proves its release. No recursive rm.

use std::fs::{self, File, OpenOptions};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::Ownership;
use super::journal::Journal;
use super::launch_gate::{Gate, Permission, Permit};
use super::private_tree::Limits;

pub(super) const MAX_ALLOCATION_BYTES: usize = 8 * 1024;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct DirectoryId {
    device: u64,
    inode: u64,
}
impl DirectoryId {
    fn of(file: &File) -> Result<Self> {
        let meta = file.metadata()?;
        ensure!(meta.is_dir(), "source allocation is not a directory");
        Ok(Self {
            device: meta.dev(),
            inode: meta.ino(),
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Allocation {
    pub version: u32,
    pub data_root: PathBuf,
    pub authority: DirectoryId,
    pub source_uid: u32,
    pub reader_gid: u32,
    pub limits: Limits,
    pub directory: Option<DirectoryId>,
    pub endpoint: Option<super::source_transport::EndpointBinding>,
    pub input: Option<super::source_transport::InputState>,
    pub retired: bool,
}
impl Allocation {
    pub(super) fn validate(&self) -> Result<()> {
        ensure!(self.version == 1, "unsupported private source version");
        let path = self
            .data_root
            .to_str()
            .context("source data root must be UTF-8")?;
        ensure!(
            path.len() <= 2048
                && !path.chars().any(char::is_control)
                && self.data_root.is_absolute()
                && self
                    .data_root
                    .ends_with("abird/abird-host-agent/owned-build/sources")
                && self
                    .data_root
                    .components()
                    .all(|c| matches!(c, Component::RootDir | Component::Normal(_))),
            "invalid source data root"
        );
        ensure!(
            self.source_uid > 0
                && self.source_uid < u32::MAX
                && self.reader_gid > 0
                && self.reader_gid < u32::MAX,
            "invalid source credentials"
        );
        self.limits.validate()?;
        if let Some(input) = &self.input {
            input.validate()?;
            ensure!(self.endpoint.is_some(), "input state lacks bound endpoint");
        }
        ensure!(
            self.endpoint
                .as_ref()
                .is_none_or(|endpoint| self.directory.is_some()
                    && endpoint.inode > 0
                    && endpoint.parent_inode > 0),
            "source endpoint lacks inode/allocation binding"
        );
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_ALLOCATION_BYTES,
            "source allocation exceeds metadata bound"
        );
        Ok(())
    }
}

pub fn data_root(xdg_data_home: Option<&Path>, home: Option<&Path>) -> Result<PathBuf> {
    let base = if let Some(base) = xdg_data_home.filter(|p| !p.as_os_str().is_empty()) {
        ensure!(base.is_absolute(), "XDG_DATA_HOME must be absolute");
        base.to_owned()
    } else {
        let home = home.context("HOME required without XDG_DATA_HOME")?;
        ensure!(home.is_absolute(), "HOME must be absolute");
        home.join(".local/share")
    };
    Ok(base.join("abird/abird-host-agent/owned-build/sources"))
}

/// Root must be explicitly provisioned by the service; never initialized on open.
struct Authority {
    path: PathBuf,
    id: DirectoryId,
}
impl Authority {
    fn open(path: PathBuf) -> Result<Self> {
        let file = open_directory(&path)?;
        ensure!(
            path.is_absolute() && fs::canonicalize(&path)? == path,
            "source authority redirected"
        );
        let meta = file.metadata()?;
        ensure!(
            meta.uid() == unsafe { libc::geteuid() }
                && meta.mode() & 0o700 == 0o700
                && meta.mode() & 0o022 == 0,
            "source authority owner/permissions"
        );
        trusted_ancestry(&path)?;
        Ok(Self {
            path,
            id: DirectoryId::of(&file)?,
        })
    }
    fn for_journal(path: PathBuf, journal: &Journal) -> Result<Self> {
        let authority = Self::open(path)?;
        ensure!(
            !authority.path.starts_with(journal.authority_root())
                && !journal.authority_root().starts_with(&authority.path),
            "source and journal authorities overlap"
        );
        ensure!(
            authority.id != DirectoryId::of(&open_directory(journal.authority_root())?)?,
            "source authority aliases journal"
        );
        Ok(authority)
    }
    fn lock(&self) -> Result<File> {
        let file = open_directory(&self.path)?;
        file.lock()?;
        let current = Self::open(self.path.clone())?;
        ensure!(
            current.id == self.id && DirectoryId::of(&file)? == self.id,
            "source authority replaced"
        );
        Ok(file)
    }
}

// A protected leaf is insufficient under a user-replaceable ancestor. Sticky
// shared parents are safe only when both parent and child belong to trusted UIDs.
fn trusted_ancestry(path: &Path) -> Result<()> {
    let service = unsafe { libc::geteuid() };
    let trusted = |uid| uid == 0 || uid == service;
    let mut child = path;
    while let Some(parent) = child.parent() {
        let meta = fs::symlink_metadata(parent)?;
        ensure!(
            meta.is_dir() && trusted(meta.uid()),
            "source authority has foreign ancestor"
        );
        if meta.mode() & 0o022 != 0 {
            let entry = fs::symlink_metadata(child)?;
            ensure!(
                meta.mode() & 0o1000 != 0 && entry.is_dir() && trusted(entry.uid()),
                "source authority has writable ancestor"
            );
        }
        child = parent;
    }
    Ok(())
}

#[derive(Clone, Copy, Debug)]
enum Point {
    Registered,
    Created,
    Permissions,
    ParentSynced,
    Bound,
    Removed,
    Retired,
}

pub struct SourceSlot {
    authority: Authority,
    owner: Ownership,
}

/// Root-private parent; only a scoped producer-directory FD enters the helper.
/// Other attempts using the same source UID cannot traverse this namespace.
pub(super) struct PrivateProducer {
    parent: File,
    pub directory: File,
    pub path: PathBuf,
}
impl SourceSlot {
    /// Fixed one-shot child names under the already durably bound allocation.
    /// Errors retain all partial data; reopening a slot never authorizes rerunning
    /// these producer/copy operations.
    pub(super) fn producer(&self, journal: &Journal, now: u64) -> Result<(File, PathBuf)> {
        let parent = self.directory(journal, now)?;
        let allocation = journal.source_allocation(&self.owner)?;
        let name = std::ffi::CString::new("producer")?;
        syscall(unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) })?;
        let directory = open_child(&parent, &name)?;
        super::private_tree::clear_acl(&directory, true)?;
        syscall(unsafe {
            libc::fchown(
                directory.as_raw_fd(),
                allocation.source_uid,
                allocation.reader_gid,
            )
        })?;
        syscall(unsafe { libc::fchmod(directory.as_raw_fd(), 0o700) })?;
        directory.sync_all()?;
        parent.sync_all()?;
        Ok((
            directory,
            self.authority
                .path
                .join(&self.owner.attempt_id)
                .join("producer"),
        ))
    }

    /// Separate original local checkout stage; still inside the registered
    /// allocation. Creation is exclusive in the shared capsule checkout helper.
    pub(super) fn checkout_path(&self, journal: &Journal, now: u64) -> Result<PathBuf> {
        let _directory = self.directory(journal, now)?;
        Ok(self
            .authority
            .path
            .join(&self.owner.attempt_id)
            .join("local-checkout"))
    }

    /// Per-attempt native XDG cache (reader-owned) plus a root-owned XDG
    /// config home whose `git/config` is the installed immutable Git context.
    /// libgit2 reads `safe.directory` from there; it ignores GIT_CONFIG_GLOBAL.
    pub(super) fn cache(
        &self,
        journal: &Journal,
        uid: u32,
        git_configuration: &Path,
        now: u64,
    ) -> Result<PathBuf> {
        let parent = self.directory(journal, now)?;
        let reader = journal.source_allocation(&self.owner)?.reader_gid;
        let mut home = parent.try_clone()?;
        for name in [c"config", c"git"] {
            syscall(unsafe { libc::mkdirat(home.as_raw_fd(), name.as_ptr(), 0o750) })?;
            let child = open_child(&home, name)?;
            super::private_tree::clear_acl(&child, true)?;
            syscall(unsafe { libc::fchown(child.as_raw_fd(), 0, reader) })?;
            syscall(unsafe { libc::fchmod(child.as_raw_fd(), 0o750) })?;
            home.sync_all()?;
            home = child;
        }
        let target = std::ffi::CString::new(git_configuration.as_os_str().as_encoded_bytes())?;
        syscall(unsafe { libc::symlinkat(target.as_ptr(), home.as_raw_fd(), c"config".as_ptr()) })?;
        home.sync_all()?;
        let name = std::ffi::CString::new("cache")?;
        syscall(unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) })?;
        let directory = open_child(&parent, &name)?;
        super::private_tree::clear_acl(&directory, true)?;
        syscall(unsafe {
            libc::fchown(
                directory.as_raw_fd(),
                uid,
                journal.source_allocation(&self.owner)?.reader_gid,
            )
        })?;
        syscall(unsafe { libc::fchmod(directory.as_raw_fd(), 0o700) })?;
        directory.sync_all()?;
        parent.sync_all()?;
        Ok(self
            .authority
            .path
            .join(&self.owner.attempt_id)
            .join("cache"))
    }

    /// Caller has positively settled every original producer before this call.
    /// The source UID never sees a writable handle to the destination.
    pub(super) fn freeze(
        &self,
        journal: &Journal,
        producer: &File,
        deadline: std::time::Instant,
        now: u64,
    ) -> Result<PathBuf> {
        let gid = journal.source_allocation(&self.owner)?.reader_gid;
        self.freeze_with_gid(journal, producer, deadline, now, gid)
    }

    /// Source metadata may contain credentials. Do not expose its producer by
    /// pathname to the shared source UID; grant only a scoped directory FD.
    pub(super) fn private_producer(
        &self,
        journal: &Journal,
        gid: u32,
        now: u64,
    ) -> Result<PrivateProducer> {
        ensure!(gid > 0 && gid < u32::MAX, "invalid private caller GID");
        let allocation = journal.source_allocation(&self.owner)?;
        let parent = self.directory(journal, now)?;
        syscall(unsafe { libc::mkdirat(parent.as_raw_fd(), c"caller".as_ptr(), 0o700) })?;
        let private = open_child(&parent, c"caller")?;
        super::private_tree::clear_acl(&private, true)?;
        syscall(unsafe { libc::fchown(private.as_raw_fd(), 0, 0) })?;
        syscall(unsafe { libc::fchmod(private.as_raw_fd(), 0o700) })?;
        private.sync_all()?;
        parent.sync_all()?;
        syscall(unsafe { libc::mkdirat(private.as_raw_fd(), c"producer".as_ptr(), 0o700) })?;
        let directory = open_child(&private, c"producer")?;
        super::private_tree::clear_acl(&directory, true)?;
        syscall(unsafe { libc::fchown(directory.as_raw_fd(), allocation.source_uid, gid) })?;
        syscall(unsafe { libc::fchmod(directory.as_raw_fd(), 0o700) })?;
        directory.sync_all()?;
        private.sync_all()?;
        Ok(PrivateProducer {
            parent: private,
            directory,
            path: self
                .authority
                .path
                .join(&self.owner.attempt_id)
                .join("caller/producer"),
        })
    }

    /// Collect only the original private upper-layer worktree, after producer
    /// emptiness. The following fresh copy shares one Git+worktree copy budget.
    pub(super) fn collect_checkout(
        &self,
        journal: &Journal,
        producer: &PrivateProducer,
        workspace: &Path,
        now: u64,
    ) -> Result<()> {
        root()?;
        super::workload::require_wrapper_placement()?;
        journal.source_active(&self.owner, now)?;
        let allocation = journal.source_allocation(&self.owner)?;
        let private_path = self
            .authority
            .path
            .join(&self.owner.attempt_id)
            .join("caller");
        let relative = workspace.strip_prefix(private_path.join("runtime-upper"))?;
        ensure!(
            relative.file_name().is_some_and(|name| name == "repo")
                && relative
                    .components()
                    .all(|part| matches!(part, Component::Normal(_))),
            "checkout is outside original private runtime"
        );
        let parent = self.directory(journal, now)?;
        let private = open_child(&parent, c"caller")?;
        ensure!(
            DirectoryId::of(&private)? == DirectoryId::of(&producer.parent)?,
            "private caller directory replaced"
        );
        let mut runtime = open_child(&private, c"runtime-upper")?;
        for part in relative
            .parent()
            .context("checkout parent missing")?
            .components()
        {
            let name = std::ffi::CString::new(part.as_os_str().as_encoded_bytes())?;
            runtime = open_child(&runtime, &name)?;
        }
        let original = open_child(&runtime, c"repo")?;
        ensure!(
            original.metadata()?.uid() == allocation.source_uid,
            "checkout producer credential differs"
        );
        let destination = open_child(&private, c"producer")?;
        ensure!(
            DirectoryId::of(&destination)? == DirectoryId::of(&producer.directory)?,
            "private Git producer replaced"
        );
        syscall(unsafe {
            libc::renameat2(
                runtime.as_raw_fd(),
                c"repo".as_ptr(),
                destination.as_raw_fd(),
                c"checkout".as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        })?;
        ensure!(
            DirectoryId::of(&open_child(&destination, c"checkout")?)?
                == DirectoryId::of(&original)?,
            "collected checkout replaced"
        );
        runtime.sync_all()?;
        destination.sync_all()?;
        Ok(())
    }

    /// Positive producer settlement precedes fresh root-only inodes. This does
    /// not prove caller coherence or revoke an escaped producer FD.
    pub(super) fn freeze_private(
        &self,
        journal: &Journal,
        producer: &PrivateProducer,
        deadline: std::time::Instant,
        now: u64,
    ) -> Result<PathBuf> {
        let allocation = journal.source_allocation(&self.owner)?;
        let parent = self.directory(journal, now)?;
        let private = open_child(&parent, c"caller")?;
        let metadata = private.metadata()?;
        ensure!(
            DirectoryId::of(&private)? == DirectoryId::of(&producer.parent)?
                && metadata.uid() == 0
                && metadata.gid() == 0
                && metadata.mode() & 0o7777 == 0o700,
            "private caller directory replaced"
        );
        let original = open_child(&private, c"producer")?;
        ensure!(
            DirectoryId::of(&original)? == DirectoryId::of(&producer.directory)?,
            "private caller producer replaced"
        );
        syscall(unsafe { libc::mkdirat(private.as_raw_fd(), c"sealed".as_ptr(), 0o700) })?;
        let target = open_child(&private, c"sealed")?;
        private.sync_all()?;
        super::private_tree::copy_before(
            &producer.directory,
            &target,
            allocation.source_uid,
            0,
            allocation.limits,
            Some(deadline),
        )?;
        private.sync_all()?;
        journal.source_active(&self.owner, super::daemon::now()?)?;
        Ok(self
            .authority
            .path
            .join(&self.owner.attempt_id)
            .join("caller/sealed"))
    }

    /// After `freeze_private`: exact native-client UID read ACLs on the sealed
    /// image plus `--x` on its root-private parent. The reader group (shared
    /// with the source UID) gains nothing; no mode/owner change or write bit.
    pub(super) fn grant_private_reader(
        &self,
        journal: &Journal,
        producer: &PrivateProducer,
        uid: u32,
        deadline: std::time::Instant,
        now: u64,
    ) -> Result<()> {
        root()?;
        let allocation = journal.source_allocation(&self.owner)?;
        ensure!(
            uid != allocation.source_uid,
            "native reader must differ from the caller"
        );
        let parent = self.directory(journal, now)?;
        let private = open_child(&parent, c"caller")?;
        let metadata = private.metadata()?;
        ensure!(
            DirectoryId::of(&private)? == DirectoryId::of(&producer.parent)?
                && metadata.uid() == 0
                && metadata.gid() == 0
                && metadata.mode() & 0o7777 == 0o700,
            "private caller directory replaced"
        );
        let sealed = open_child(&private, c"sealed")?;
        super::private_tree::grant_reader(&sealed, uid, allocation.limits, deadline)?;
        super::private_tree::grant_traverse(&private, uid)?;
        journal.source_active(&self.owner, super::daemon::now()?)
    }

    fn freeze_with_gid(
        &self,
        journal: &Journal,
        producer: &File,
        deadline: std::time::Instant,
        now: u64,
        reader_gid: u32,
    ) -> Result<PathBuf> {
        root()?;
        let parent = self.directory(journal, now)?;
        let allocation = journal.source_allocation(&self.owner)?;
        let original = open_child(&parent, &std::ffi::CString::new("producer")?)?;
        ensure!(
            DirectoryId::of(&original)? == DirectoryId::of(producer)?,
            "producer directory replaced"
        );
        let name = std::ffi::CString::new("sealed")?;
        syscall(unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) })?;
        let target = open_child(&parent, &name)?;
        parent.sync_all()?;
        super::private_tree::copy_before(
            producer,
            &target,
            allocation.source_uid,
            reader_gid,
            allocation.limits,
            Some(deadline),
        )?;
        parent.sync_all()?;
        journal.source_active(&self.owner, super::daemon::now()?)?;
        Ok(self
            .authority
            .path
            .join(&self.owner.attempt_id)
            .join("sealed"))
    }
    /// One-shot allocation after worker admission. No source data may be written
    /// before the directory identity is durably bound. Existing reservations do
    /// not authorize replay, even if the directory is absent.
    pub fn allocate(
        journal: &Journal,
        gate: &Gate,
        owner: Ownership,
        source_uid: u32,
        reader_gid: u32,
        limits: Limits,
        now: u64,
    ) -> Result<Self> {
        root()?;
        super::workload::require_wrapper_placement()?;
        ensure!(
            gate.identity() == journal.identity(),
            "source gate identity mismatch"
        );
        let _launch = gate
            .authorize(&Permit {
                version: 1,
                identity: journal.identity().clone(),
                permission: Permission::Execution {
                    ownership: owner.clone(),
                },
            })?
            .context("source allocation fenced")?;
        let xdg = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from);
        let home = std::env::var_os("HOME").map(PathBuf::from);
        Self::allocate_at(
            journal,
            owner,
            data_root(xdg.as_deref(), home.as_deref())?,
            source_uid,
            reader_gid,
            limits,
            now,
            |_| Ok(()),
        )
    }
    #[allow(clippy::too_many_arguments)]
    fn allocate_at(
        journal: &Journal,
        owner: Ownership,
        path: PathBuf,
        source_uid: u32,
        reader_gid: u32,
        limits: Limits,
        now: u64,
        point: impl Fn(Point) -> Result<()>,
    ) -> Result<Self> {
        let authority = Authority::for_journal(path, journal)?;
        let parent = authority.lock()?;
        super::digest(&owner.attempt_id)?;
        let name = std::ffi::CString::new(owner.attempt_id.as_str())?;
        ensure!(missing(&parent, &name)?, "source directory already exists");
        let allocation = Allocation {
            version: 1,
            data_root: authority.path.clone(),
            authority: authority.id.clone(),
            source_uid,
            reader_gid,
            limits,
            directory: None,
            endpoint: None,
            input: None,
            retired: false,
        };
        journal.register_source(&owner, allocation, now)?;
        point(Point::Registered)?;
        syscall(unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) })?;
        point(Point::Created)?;
        let directory = open_child(&parent, &name)?;
        // Reader traversal only; child content permissions remain separately owned.
        super::private_tree::clear_acl(&directory, true)?;
        syscall(unsafe { libc::fchown(directory.as_raw_fd(), u32::MAX, reader_gid) })?;
        syscall(unsafe { libc::fchmod(directory.as_raw_fd(), 0o710) })?;
        point(Point::Permissions)?;
        directory.sync_all()?;
        parent.sync_all()?;
        point(Point::ParentSynced)?;
        journal.bind_source(&owner, DirectoryId::of(&directory)?, now)?;
        point(Point::Bound)?;
        Ok(Self { authority, owner })
    }
    /// Reopen only a bound allocation; no creating/adopting missing or foreign data.
    pub fn open(journal: &Journal, owner: Ownership) -> Result<Self> {
        root()?;
        Self::open_at(journal, owner)
    }
    fn open_at(journal: &Journal, owner: Ownership) -> Result<Self> {
        let allocation = journal.source_allocation(&owner)?;
        ensure!(
            !allocation.retired && allocation.directory.is_some(),
            "source allocation not bound"
        );
        let slot = Self {
            authority: Authority::for_journal(allocation.data_root.clone(), journal)?,
            owner,
        };
        let parent = slot.authority.lock()?;
        slot.checked(&parent, &allocation)?;
        Ok(slot)
    }
    fn checked(&self, parent: &File, allocation: &Allocation) -> Result<File> {
        ensure!(
            self.authority.id == allocation.authority,
            "source authority binding mismatch"
        );
        let directory = open_child(
            parent,
            &std::ffi::CString::new(self.owner.attempt_id.as_str())?,
        )?;
        let meta = directory.metadata()?;
        ensure!(
            allocation.directory.as_ref() == Some(&DirectoryId::of(&directory)?)
                && meta.uid() == unsafe { libc::geteuid() }
                && meta.gid() == allocation.reader_gid
                && meta.mode() & 0o7777 == 0o710,
            "source directory binding/permissions mismatch"
        );
        Ok(directory)
    }
    /// Fresh checked descriptor, not a reusable source verification token. Caller
    /// still owns placement, deadline, producer confinement and source verification.
    pub fn directory(&self, journal: &Journal, now: u64) -> Result<File> {
        root()?;
        super::workload::require_wrapper_placement()?;
        journal.source_active(&self.owner, now)?;
        let parent = self.authority.lock()?;
        self.checked(&parent, &journal.source_allocation(&self.owner)?)
    }
    /// Original source identity + independent admitted cleanup ownership. There
    /// is no source claim, producer restart or deadline extension here.
    pub(super) fn retire_settled(
        journal: &Journal,
        cleanup: &Ownership,
        target: &Ownership,
        reader_uid: u32,
        deadline: std::time::Instant,
    ) -> Result<()> {
        root()?;
        super::workload::require_wrapper_placement()?;
        journal.retirement_active(cleanup, super::daemon::now()?)?;
        let allocation = journal.source_allocation(target)?;
        let (_, settled, released) = journal.protection_context(target)?;
        ensure!(
            settled && released.is_some() && !allocation.retired,
            "source cleanup target unavailable"
        );
        super::source_transport::retire(journal, cleanup, target)?;
        if allocation.directory.is_some() {
            let slot = Self::open(journal, target.clone())?;
            let parent = slot.authority.lock()?;
            let directory = slot.checked(&parent, &allocation)?;
            cleanup::empty(
                &directory,
                [allocation.source_uid, reader_uid],
                cleanup::limits(allocation.limits)?,
                deadline,
                &mut || journal.retirement_active(cleanup, super::daemon::now()?),
            )?;
            slot.checked(&parent, &allocation)?;
        }
        journal.retirement_active(cleanup, super::daemon::now()?)?;
        Self::retire_empty(journal, target, super::daemon::now()?)
    }

    /// Metadata-only retirement. Never recursively delete contents, follow links,
    /// adopt unbound data, or infer release from directory absence alone.
    pub fn retire_empty(journal: &Journal, owner: &Ownership, now: u64) -> Result<()> {
        root()?;
        Self::retire_at(journal, owner, now, |_| Ok(()))
    }
    fn retire_at(
        journal: &Journal,
        owner: &Ownership,
        now: u64,
        point: impl Fn(Point) -> Result<()>,
    ) -> Result<()> {
        let allocation = journal.source_allocation(owner)?;
        ensure!(
            super::source_transport::absent(&owner.attempt_id)?,
            "source endpoint requires qualified retirement"
        );
        let (_, settled, released) = journal.protection_context(owner)?;
        ensure!(
            settled && released.is_some(),
            "private source not settled/released"
        );
        let authority = Authority::for_journal(allocation.data_root.clone(), journal)?;
        let parent = authority.lock()?;
        ensure!(
            authority.id == allocation.authority,
            "source authority replaced"
        );
        let name = std::ffi::CString::new(owner.attempt_id.as_str())?;
        if !missing(&parent, &name)? {
            ensure!(!allocation.retired, "retired source directory reappeared");
            let directory = open_child(&parent, &name)?;
            let meta = directory.metadata()?;
            ensure!(
                meta.uid() == unsafe { libc::geteuid() },
                "foreign source directory"
            );
            if let Some(id) = &allocation.directory {
                ensure!(
                    *id == DirectoryId::of(&directory)?
                        && meta.gid() == allocation.reader_gid
                        && meta.mode() & 0o7777 == 0o710,
                    "source directory replaced"
                );
            } else {
                // Intent was durable before mkdir; contents cannot be authorized
                // until binding. Only the empty creation gap can be retired.
                ensure!(
                    // mkdir(0700) may lose owner bits to umask and inherit setgid.
                    // No group/other access, setuid or sticky bit is allowed.
                    meta.mode() & 0o5077 == 0
                        || (meta.mode() & 0o7777 == 0o710 && meta.gid() == allocation.reader_gid),
                    "unbound source permissions"
                );
            }
            ensure!(
                super::private_tree::directory_empty(&directory)?,
                "source contents require qualified cleanup"
            );
            syscall(unsafe {
                libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR)
            })?;
        }
        parent.sync_all()?;
        point(Point::Removed)?;
        journal.retire_source(owner, now)?;
        point(Point::Retired)
    }
}

/// Called under the short journal lock; never take the data-authority lock here.
/// Reappeared data or lost/replaced authority vetoes pruning, even after retirement.
pub(super) fn retired(allocation: &Allocation, key: &str) -> Result<bool> {
    if !allocation.retired || !super::source_transport::absent(key)? {
        return Ok(false);
    }
    let authority = Authority::open(allocation.data_root.clone())?;
    ensure!(
        authority.id == allocation.authority,
        "source authority replaced"
    );
    let parent = open_directory(&authority.path)?;
    ensure!(
        DirectoryId::of(&parent)? == authority.id,
        "source authority changed"
    );
    let absent = missing(&parent, &std::ffi::CString::new(key)?)?;
    if absent {
        parent.sync_all()?;
    }
    Ok(absent)
}

fn root() -> Result<()> {
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "private sources require trusted root adapter"
    );
    Ok(())
}
fn syscall(result: i32) -> Result<()> {
    if result < 0 {
        Err(std::io::Error::last_os_error().into())
    } else {
        Ok(())
    }
}
fn open_directory(path: &Path) -> Result<File> {
    Ok(OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?)
}
fn open_child(parent: &File, name: &std::ffi::CStr) -> Result<File> {
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_RDONLY | libc::O_CLOEXEC,
        )
    };
    ensure!(
        fd >= 0,
        "open source allocation: {}",
        std::io::Error::last_os_error()
    );
    Ok(unsafe { File::from_raw_fd(fd) })
}
fn missing(parent: &File, name: &std::ffi::CStr) -> Result<bool> {
    let mut meta = std::mem::MaybeUninit::<libc::stat>::uninit();
    let result = unsafe {
        libc::fstatat(
            parent.as_raw_fd(),
            name.as_ptr(),
            meta.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if result == 0 {
        return Ok(false);
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::NotFound {
        Ok(true)
    } else {
        Err(error.into())
    }
}

mod cleanup;

#[cfg(test)]
mod tests;
