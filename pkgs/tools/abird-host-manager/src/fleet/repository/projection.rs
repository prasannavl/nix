//! Mode-aware native checkout observations, not working-file or source proofs.

use std::ffi::OsString;
use std::os::unix::ffi::OsStringExt;
use std::path::Path;

use anyhow::{Context, Result, ensure};

use super::object::{self, Kind, MAX_BLOB_BYTES};
use super::{CommandRunner, ObjectId, RepositoryManager, TreeInventory, TreeKind};

/// Requested leaf and captured bytes. Native filters may execute configured
/// programs; this value grants no admission, confinement or logging permission.
pub struct CheckoutProjection {
    path: Vec<u8>,
    object: ObjectId,
    kind: TreeKind,
    bytes: Vec<u8>,
}

impl CheckoutProjection {
    pub fn path(&self) -> &[u8] {
        &self.path
    }
    pub fn object(&self) -> &ObjectId {
        &self.object
    }
    /// Logical Git kind, not the working filesystem type (`core.symlinks`).
    pub fn kind(&self) -> TreeKind {
        self.kind
    }
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
}

impl<R: CommandRunner> RepositoryManager<R> {
    /// Caller supplies the effective native checkout context under its original
    /// admission/deadline and installed policy. Filters/config can cause effects.
    /// A preceding raw rehash does not prove what a later filter call consumed,
    /// freeze attributes/configuration, or establish actual working bytes.
    pub fn checkout_projection(
        &mut self,
        root: &Path,
        tree: &TreeInventory,
        path: &[u8],
    ) -> Result<CheckoutProjection> {
        let entry = tree
            .entries()
            .get(path)
            .context("native checkout projection path not observed")?;
        ensure!(
            entry.kind() != TreeKind::Directory,
            "native checkout projection requires a leaf"
        );
        let raw = object::read(self, root, Kind::Blob, entry.object().as_str())?;
        let bytes = if entry.kind() == TreeKind::Symlink {
            // Git never smudges symlink payloads, even with core.symlinks=false.
            // Observe data only; neither follow nor certify its target.
            raw
        } else {
            drop(raw);
            let path = OsString::from_vec([b"--path=", path].concat());
            let output = self.run_git(
                root,
                [
                    OsString::from("cat-file"),
                    OsString::from("--filters"),
                    path,
                    OsString::from(entry.object().as_str()),
                ],
                None,
            )?;
            ensure!(output.status == 0, "native checkout projection failed");
            // Post-capture ceiling, not a transport, allocation or fetch quota.
            ensure!(
                output.stdout.len() <= MAX_BLOB_BYTES,
                "native checkout projection exceeds bound"
            );
            output.stdout
        };
        Ok(CheckoutProjection {
            path: path.to_vec(),
            object: entry.object().clone(),
            kind: entry.kind(),
            bytes,
        })
    }
}

#[cfg(test)]
mod tests;
