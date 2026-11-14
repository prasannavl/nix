//! Selected raw Git tree observations, not a coherent checkout/source receipt.
//! Limits bound accepted observations; capture/allocation, producer storage and
//! admission remain separate obligations of the original runner/owner.

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{Result, ensure};

use super::{CommandRunner, ObjectId, RepositoryManager, TreeKind, object};

#[derive(Clone, Copy)]
pub struct ObjectLimits {
    /// Root plus every logical directory/file/symlink occurrence.
    pub entries: u32,
    /// Encoded tree bytes plus raw blob bytes; repeated references count again.
    pub bytes: u64,
    /// Maximum number of path components; root has depth zero.
    pub depth: u16,
    /// Sum of complete relative path lengths, including directory entries.
    pub path_bytes: u64,
}
impl ObjectLimits {
    fn validate(self) -> Result<()> {
        ensure!(
            (1..=32 * 1024).contains(&self.entries)
                && self.bytes <= 64 * 1024 * 1024
                && (1..=64).contains(&self.depth)
                && self.path_bytes <= 16 * 1024 * 1024,
            "invalid native object observation limits"
        );
        Ok(())
    }
}

pub struct ObservedEntry {
    kind: TreeKind,
    object: ObjectId,
}
impl ObservedEntry {
    pub fn kind(&self) -> TreeKind {
        self.kind
    }
    pub fn object(&self) -> &ObjectId {
        &self.object
    }
}

/// Hash-linked tree/blob captures at individual read times. No Debug/serde,
/// retained payload, Git history, index/config or finished checkout proof.
pub struct TreeInventory {
    root: ObjectId,
    entries: BTreeMap<Vec<u8>, ObservedEntry>,
    bytes: u64,
}
impl TreeInventory {
    pub fn root(&self) -> &ObjectId {
        &self.root
    }
    pub fn entries(&self) -> &BTreeMap<Vec<u8>, ObservedEntry> {
        &self.entries
    }
    pub fn observed_bytes(&self) -> u64 {
        self.bytes
    }
}

impl<R: CommandRunner> RepositoryManager<R> {
    /// Same namespace/admission/immutable process-policy obligation as tree_object.
    /// Native reads can fetch promisor objects. Symlink blobs are data, never paths
    /// to follow. Later repository reads may differ; this grants no receipt.
    pub fn observe_tree(
        &mut self,
        root: &Path,
        identity: &ObjectId,
        limits: ObjectLimits,
    ) -> Result<TreeInventory> {
        limits.validate()?;
        let mut result = TreeInventory {
            root: identity.clone(),
            entries: BTreeMap::new(),
            bytes: 0,
        };
        let mut pending = vec![(Vec::new(), identity.clone(), 0u16)];
        let mut nodes = 1u32;
        let mut paths = 0u64;
        while let Some((prefix, id, depth)) = pending.pop() {
            let tree = self.tree_object(root, &id)?;
            result.bytes += tree.encoded_len() as u64;
            ensure!(
                result.bytes <= limits.bytes,
                "native object observation byte bound exceeded"
            );
            // Per-tree parser bounds make both additions non-overflowing.
            nodes += tree.entries().len() as u32;
            ensure!(
                nodes <= limits.entries,
                "native object observation entry bound exceeded"
            );
            for entry in tree.entries() {
                ensure!(
                    depth < limits.depth,
                    "native object observation depth bound exceeded"
                );
                let len = prefix.len() + usize::from(!prefix.is_empty()) + entry.name().len();
                ensure!(
                    len <= 4096,
                    "native object observation path length exceeded"
                );
                paths += len as u64;
                ensure!(
                    paths <= limits.path_bytes,
                    "native object observation path byte bound exceeded"
                );
                let mut path = Vec::with_capacity(len);
                path.extend_from_slice(&prefix);
                if !path.is_empty() {
                    path.push(b'/');
                }
                path.extend_from_slice(entry.name());
                if entry.kind() == TreeKind::Directory {
                    pending.push((path.clone(), entry.object().clone(), depth + 1));
                } else {
                    let bytes =
                        object::read(self, root, object::Kind::Blob, entry.object().as_str())?;
                    result.bytes += bytes.len() as u64;
                    ensure!(
                        result.bytes <= limits.bytes,
                        "native object observation byte bound exceeded"
                    );
                }
                ensure!(
                    result
                        .entries
                        .insert(
                            path,
                            ObservedEntry {
                                kind: entry.kind(),
                                object: entry.object().clone()
                            }
                        )
                        .is_none(),
                    "duplicate native object observation path"
                );
            }
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests;
