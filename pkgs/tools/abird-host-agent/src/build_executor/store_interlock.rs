//! Serialize fresh reservation with the durable retention veto on the existing
//! Nix state-directory flock. Neither guard grants GC/maintenance authority.
//!
//! All GC/admission ingress must participate. Maintenance still needs its own
//! admitted lifetime, placement and settlement: process-held locks alone cannot
//! account for surviving GC workers. No store deletion, migration or creation.
//! Runtime lock order: controller → store → launch fence → short journal lock.
//! The current legacy GC scripts do not yet participate in this durable veto.

use std::fs::{self, File, OpenOptions, TryLockError};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use anyhow::{Result, ensure};

use super::journal::Journal;
use super::journal::work::Kind;
use super::request::StorageIdentity;
use super::{Ownership, PoolHealth};

const STORE_STATE: &str = "/nix/var/nix";

pub struct StoreInterlock {
    root: PathBuf,
    device: u64,
    inode: u64,
    identity: StorageIdentity,
    _anchor: File,
}

/// Hold through durable reservation and delivery. Later protection comes from
/// the journal veto, not this descriptor or the controller's continued life.
#[must_use]
pub(super) struct AdmissionGuard {
    _directory: File,
}

/// Necessary serialization/retention check only, NEVER permission to execute GC.
/// Dropping/exec/death releases this lock, not any surviving maintenance work.
#[must_use]
pub struct RetentionCheck {
    _directory: File,
}

/// Hold across the admitted maintenance worker's entire operation, not merely
/// a check before exec. This necessary guard does not confer launch/GC authority.
#[must_use]
pub struct MaintenanceGuard<'a> {
    _directory: File,
    store: &'a StoreInterlock,
    owner: Ownership,
}

#[must_use]
pub(super) struct BuildGuard<'a> {
    _directory: File,
    store: &'a StoreInterlock,
    owner: Ownership,
}

#[must_use]
pub(super) struct RetirementGuard<'a> {
    _guard: AdmissionGuard,
    store: &'a StoreInterlock,
    owner: Ownership,
}

impl RetirementGuard<'_> {
    pub(super) fn validate(&self, journal: &Journal, now: u64) -> Result<()> {
        self.store.directory(journal)?;
        journal.retirement_active(&self.owner, now)
    }
}

impl BuildGuard<'_> {
    pub(super) fn validate(&self, journal: &Journal, now: u64) -> Result<()> {
        self.store.directory(journal)?;
        journal.build_active(&self.owner, now)
    }
}

impl MaintenanceGuard<'_> {
    /// Revalidate before each effect; holding a descriptor does not renew work.
    pub fn validate(&self, journal: &Journal, now: u64) -> Result<()> {
        self.store.directory(journal)?;
        journal.maintenance_active(&self.owner, now)
    }
}

impl StoreInterlock {
    /// Existing native lock inode only. Trusted role must independently bind the
    /// actual store/database and immutable namespace; identity labels cannot.
    pub fn open(identity: StorageIdentity) -> Result<Self> {
        Self::at(Path::new(STORE_STATE), identity)
    }

    fn at(root: &Path, identity: StorageIdentity) -> Result<Self> {
        identity.validate()?;
        let directory = open(root)?;
        let meta = directory.metadata()?;
        Ok(Self {
            root: root.to_owned(),
            device: meta.dev(),
            inode: meta.ino(),
            identity,
            _anchor: directory,
        })
    }

    fn directory(&self, journal: &Journal) -> Result<File> {
        ensure!(
            journal.identity() == &self.identity,
            "store interlock authority mismatch"
        );
        let directory = open(&self.root)?;
        let meta = directory.metadata()?;
        ensure!(
            meta.dev() == self.device && meta.ino() == self.inode,
            "store interlock replaced"
        );
        let authority = fs::symlink_metadata(journal.authority_root())?;
        ensure!(
            meta.dev() != authority.dev() || meta.ino() != authority.ino(),
            "store interlock aliases journal"
        );
        Ok(directory)
    }

    #[cfg(test)]
    pub(super) fn try_admission(&self, journal: &Journal) -> Result<Option<AdmissionGuard>> {
        self.try_dispatch(journal, Kind::Build)
    }

    pub(super) fn try_dispatch(
        &self,
        journal: &Journal,
        kind: Kind,
    ) -> Result<Option<AdmissionGuard>> {
        let directory = self.directory(journal)?;
        let locked = match kind {
            Kind::Build => directory.try_lock_shared(),
            Kind::Maintenance | Kind::Retirement => directory.try_lock(),
        };
        match locked {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => return Ok(None),
            Err(TryLockError::Error(error)) => return Err(error.into()),
        }
        self.directory(journal)?;
        if kind == Kind::Maintenance && !journal.retention_clear()? {
            return Ok(None);
        }
        Ok(Some(AdmissionGuard {
            _directory: directory,
        }))
    }

    pub(super) fn try_build(
        &self,
        journal: &Journal,
        owner: &Ownership,
        now: u64,
    ) -> Result<Option<BuildGuard<'_>>> {
        journal.build_active(owner, now)?;
        let directory = self.directory(journal)?;
        match directory.try_lock_shared() {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => return Ok(None),
            Err(TryLockError::Error(error)) => return Err(error.into()),
        }
        self.directory(journal)?;
        journal.build_active(owner, now)?;
        Ok(Some(BuildGuard {
            _directory: directory,
            store: self,
            owner: owner.clone(),
        }))
    }

    /// Worker order: store → launch authorization → one-shot begin_worker.
    /// Busy is pending; stale/expired/foreign/retained state is an error. Validate
    /// the original deadline on every attempt; never start a new lifetime.
    pub fn try_maintenance(
        &self,
        journal: &Journal,
        owner: &Ownership,
        now: u64,
    ) -> Result<Option<MaintenanceGuard<'_>>> {
        journal.maintenance_active(owner, now)?;
        let directory = self.directory(journal)?;
        match directory.try_lock() {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => return Ok(None),
            Err(TryLockError::Error(error)) => return Err(error.into()),
        }
        self.directory(journal)?;
        journal.maintenance_active(owner, now)?;
        Ok(Some(MaintenanceGuard {
            _directory: directory,
            store: self,
            owner: owner.clone(),
        }))
    }

    /// Cleanup holds EX but never gains collector authority. Retained Build
    /// roots may exist; only the exact settled target is authorized by its intent.
    pub(super) fn try_retirement(
        &self,
        journal: &Journal,
        owner: &Ownership,
        now: u64,
    ) -> Result<Option<RetirementGuard<'_>>> {
        journal.retirement_active(owner, now)?;
        let guard = self.try_dispatch(journal, Kind::Retirement)?;
        journal.retirement_active(owner, now)?;
        Ok(guard.map(|guard| RetirementGuard {
            _guard: guard,
            store: self,
            owner: owner.clone(),
        }))
    }

    /// Acquire exclusive BEFORE reading the veto. Both contention and retained
    /// work remain blocked; errors are not absence. No journal lock spans effects.
    /// Pool availability is an additional veto, not a global ingress proof.
    pub fn try_retention_check(&self, journal: &Journal) -> Result<Option<RetentionCheck>> {
        let directory = self.directory(journal)?;
        match directory.try_lock() {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => return Ok(None),
            Err(TryLockError::Error(error)) => return Err(error.into()),
        }
        self.directory(journal)?;
        if !journal.retention_clear()? {
            return Ok(None);
        }
        let pool = journal.pool()?;
        if pool.owner.is_some() || pool.health != PoolHealth::Available {
            return Ok(None);
        }
        Ok(Some(RetentionCheck {
            _directory: directory,
        }))
    }

    #[cfg(test)]
    pub(super) fn test_at(root: &Path, identity: StorageIdentity) -> Result<Self> {
        Self::at(root, identity)
    }
}

fn open(root: &Path) -> Result<File> {
    ensure!(
        root.is_absolute() && fs::canonicalize(root)? == root,
        "store interlock redirected"
    );
    let service = unsafe { libc::geteuid() };
    let trusted = |uid| uid == 0 || uid == service;
    let mut child = root;
    while let Some(parent) = child.parent() {
        let meta = fs::symlink_metadata(parent)?;
        ensure!(
            meta.is_dir() && trusted(meta.uid()),
            "store interlock foreign ancestor"
        );
        if meta.mode() & 0o022 != 0 {
            let entry = fs::symlink_metadata(child)?;
            ensure!(
                meta.mode() & 0o1000 != 0 && entry.is_dir() && trusted(entry.uid()),
                "store interlock writable ancestor"
            );
        }
        child = parent;
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(root)?;
    let meta = file.metadata()?;
    ensure!(
        trusted(meta.uid()) && meta.mode() & 0o022 == 0,
        "store interlock owner/permissions"
    );
    Ok(file)
}

#[cfg(test)]
mod tests;
