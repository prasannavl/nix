//! Durable start/fence interlock, separate from journal/controller locks.
//!
//! Trusted unit wrappers must already be in the accounted workload cgroup. Hold
//! `LaunchGuard` until exec (CLOEXEC releases it atomically); never drop it before
//! launching. Hold `Fence` across ingress stop, cgroup settlement and journaling.
//! This interlock neither kills workers nor proves settlement or global ingress.

use std::fs::{self, File, OpenOptions, TryLockError};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::journal::{open_directory, private_file};
use super::request::StorageIdentity;
use super::{Ownership, digest, identifier};

const VERSION: u32 = 1;
const MAX_BYTES: u64 = 4096;
const PERMIT: &str = "permit.json";
const PENDING: &str = ".pending";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Permission {
    /// Trusted daemon/readiness work only; never a build-client permission.
    Recovery {
        epoch: u64,
        boot_id: String,
    },
    Execution {
        ownership: Ownership,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Permit {
    pub version: u32,
    pub identity: StorageIdentity,
    pub permission: Permission,
}

impl Permit {
    fn validate(&self, identity: &StorageIdentity, boot: &str) -> Result<()> {
        ensure!(
            self.version == VERSION && self.identity == *identity,
            "launch authority mismatch"
        );
        self.identity.validate()?;
        let observed_boot = match &self.permission {
            Permission::Recovery { boot_id, .. } => boot_id,
            Permission::Execution { ownership } => {
                digest(&ownership.attempt_id)?;
                ownership.validate(&ownership.attempt_id)?;
                ensure!(
                    ownership.builder_id == identity.builder_id
                        && ownership.store_id == identity.store_id,
                    "launch storage mismatch"
                );
                &ownership.boot_id
            }
        };
        identifier(observed_boot)?;
        ensure!(observed_boot == boot, "launch belongs to another boot");
        Ok(())
    }
}

pub struct Gate {
    root: PathBuf,
    device: u64,
    inode: u64,
    identity: StorageIdentity,
    boot: String,
    controller_inode: u64,
    controller_device: u64,
}

#[must_use = "hold until exec; dropping early removes launch serialization"]
pub struct LaunchGuard {
    _directory: File,
}

#[must_use = "hold across ingress stop and settlement; publish only after recovery"]
pub struct Fence<'a> {
    gate: &'a Gate,
    directory: File,
}

impl Gate {
    /// Explicit provisioning under the private XDG authority; never reinitialize.
    pub fn initialize(root: &Path, identity: StorageIdentity) -> Result<Self> {
        ensure!(root.is_absolute(), "launch gate must be absolute");
        let parent = root.parent().context("launch gate has no parent")?;
        ensure!(
            fs::canonicalize(parent)? == parent,
            "launch parent redirected"
        );
        let parent = open_directory(parent)?;
        identity.validate()?;
        fs::DirBuilder::new().mode(0o700).create(root)?;
        fs::DirBuilder::new()
            .mode(0o700)
            .create(root.join("controller"))?;
        open_directory(root)?.sync_all()?;
        parent.sync_all()?;
        Self::open(root, identity)
    }

    pub fn open(root: &Path, identity: StorageIdentity) -> Result<Self> {
        let boot = fs::read_to_string("/proc/sys/kernel/random/boot_id")?;
        Self::at(root, identity, boot.trim().to_owned())
    }

    fn at(root: &Path, identity: StorageIdentity, boot: String) -> Result<Self> {
        identity.validate()?;
        identifier(&boot)?;
        ensure!(
            root.is_absolute() && fs::canonicalize(root)? == root,
            "launch gate redirected"
        );
        let directory = open_directory(root)?;
        let metadata = directory.metadata()?;
        let controller = open_directory(&root.join("controller"))?.metadata()?;
        Ok(Self {
            root: root.to_owned(),
            device: metadata.dev(),
            inode: metadata.ino(),
            identity,
            boot,
            controller_inode: controller.ino(),
            controller_device: controller.dev(),
        })
    }

    pub(super) fn identity(&self) -> &StorageIdentity {
        &self.identity
    }

    /// Single independent controller, not the short-lived metadata transaction lock.
    /// All production launch/recovery/stop effects must share this exclusion.
    pub fn try_controller(&self) -> Result<Option<Controller<'_>>> {
        let directory = open_directory(&self.root.join("controller"))?;
        let controller = Controller {
            gate: self,
            _directory: directory,
        };
        controller.validate()?;
        match controller._directory.try_lock() {
            Ok(()) => Ok(Some(controller)),
            Err(TryLockError::WouldBlock) => Ok(None),
            Err(TryLockError::Error(error)) => Err(error.into()),
        }
    }

    pub fn boot_id(&self) -> &str {
        &self.boot
    }

    fn directory(&self) -> Result<File> {
        let directory = open_directory(&self.root)?;
        let metadata = directory.metadata()?;
        ensure!(
            metadata.dev() == self.device
                && metadata.ino() == self.inode
                && fs::canonicalize(&self.root)? == self.root,
            "launch gate replaced"
        );
        Ok(directory)
    }

    /// Nonblocking: contention is pending, not permission and not worker failure.
    pub fn authorize(&self, expected: &Permit) -> Result<Option<LaunchGuard>> {
        expected.validate(&self.identity, &self.boot)?;
        let directory = self.directory()?;
        match directory.try_lock_shared() {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => return Ok(None),
            Err(TryLockError::Error(error)) => return Err(error.into()),
        }
        let mut file = private_file(&self.root.join(PERMIT))?;
        let mut bytes = Vec::new();
        (&mut file).take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() as u64 <= MAX_BYTES,
            "launch permit exceeds bound"
        );
        let permit: Permit = serde_json::from_slice(&bytes)?;
        permit.validate(&self.identity, &self.boot)?;
        ensure!(
            permit == *expected && serde_json::to_vec(&permit)? == bytes,
            "launch permit mismatch"
        );
        // A previously unconfirmed publish must become durable before any exec.
        file.sync_all()?;
        directory.sync_all()?;
        Ok(Some(LaunchGuard {
            _directory: directory,
        }))
    }

    /// Persist closed ingress before returning the exclusive interlock.
    /// Failure gives no fencing/settlement proof; never proceed to kill on error.
    pub fn try_fence(&self) -> Result<Option<Fence<'_>>> {
        let directory = self.directory()?;
        match directory.try_lock() {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => return Ok(None),
            Err(TryLockError::Error(error)) => return Err(error.into()),
        }
        remove_private(&self.root.join(PERMIT))?;
        directory.sync_all()?;
        Ok(Some(Fence {
            gate: self,
            directory,
        }))
    }
}

impl Fence<'_> {
    /// Caller must already have durable matching journal ownership/recovery.
    /// An error is unconfirmed publication: keep ownership and reconcile.
    pub fn publish(self, permit: &Permit) -> Result<()> {
        permit.validate(&self.gate.identity, &self.gate.boot)?;
        let bytes = serde_json::to_vec(permit)?;
        ensure!(
            bytes.len() as u64 <= MAX_BYTES,
            "launch permit exceeds bound"
        );
        let pending = self.gate.root.join(PENDING);
        remove_private(&pending)?;
        self.directory.sync_all()?;
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&pending)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(&pending, self.gate.root.join(PERMIT))?;
        self.directory.sync_all()?;
        Ok(())
    }
}

fn remove_private(path: &Path) -> Result<()> {
    match private_file(path) {
        Ok(_) => Ok(fs::remove_file(path)?),
        Err(error)
            if error
                .downcast_ref::<std::io::Error>()
                .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
        {
            Ok(())
        }
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests;

/// Hold for the supervisor lifetime; neither inherited by exec nor shared by status.
pub struct Controller<'a> {
    gate: &'a Gate,
    _directory: File,
}

impl Controller<'_> {
    pub(super) fn gate(&self) -> &Gate {
        self.gate
    }

    pub(super) fn validate(&self) -> Result<()> {
        self.gate.directory()?;
        let metadata = open_directory(&self.gate.root.join("controller"))?.metadata()?;
        ensure!(
            metadata.ino() == self.gate.controller_inode
                && metadata.dev() == self.gate.controller_device,
            "controller directory replaced"
        );
        Ok(())
    }
}
