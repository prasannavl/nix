//! Bounded, rehashed native tree entries. Child objects and checkout bytes are
//! not verified; no repository confinement, source receipt or cleanup authority.

use std::collections::BTreeSet;
use std::path::Path;

use anyhow::{Result, ensure};

use super::{CommandRunner, ObjectId, RepositoryManager, object};

const MAX_ENTRIES: usize = 32 * 1024;
const MAX_NAME: usize = 4096;

#[derive(Clone, Copy, Eq, PartialEq)]
pub enum TreeKind {
    Directory,
    File,
    Executable,
    Symlink,
}

pub struct TreeEntry {
    name: Vec<u8>,
    kind: TreeKind,
    object: ObjectId,
}

impl TreeEntry {
    pub fn name(&self) -> &[u8] {
        &self.name
    }
    pub fn kind(&self) -> TreeKind {
        self.kind
    }
    pub fn object(&self) -> &ObjectId {
        &self.object
    }
}

pub struct TreeObject {
    identity: ObjectId,
    entries: Vec<TreeEntry>,
    encoded_len: usize,
}

impl TreeObject {
    pub fn identity(&self) -> &ObjectId {
        &self.identity
    }
    pub fn entries(&self) -> &[TreeEntry] {
        &self.entries
    }
    pub(super) fn encoded_len(&self) -> usize {
        self.encoded_len
    }
}

impl<R: CommandRunner> RepositoryManager<R> {
    /// Positive path absence only. Object/config/transport failures remain errors;
    /// caller filesystem presence cannot stand in for a selected revision.
    pub fn tracked_regular_file(
        &mut self,
        root: &Path,
        revision: &super::CommitSha,
        path: &Path,
    ) -> Result<bool> {
        use std::os::unix::ffi::OsStrExt;
        let parts = path.components().collect::<Vec<_>>();
        ensure!(
            !parts.is_empty()
                && parts.len() <= 64
                && parts
                    .iter()
                    .all(|part| matches!(part, std::path::Component::Normal(_))),
            "invalid native inventory path"
        );
        let mut object = self.commit_object(root, revision)?.tree_id()?;
        for (index, part) in parts.iter().enumerate() {
            let tree = self.tree_object(root, &object)?;
            let Some(entry) = tree
                .entries()
                .iter()
                .find(|entry| entry.name() == part.as_os_str().as_bytes())
            else {
                return Ok(false);
            };
            ensure!(
                entry.kind() != TreeKind::Symlink,
                "symlink inventory context requires explicit binding"
            );
            if index + 1 == parts.len() {
                return Ok(matches!(
                    entry.kind(),
                    TreeKind::File | TreeKind::Executable
                ));
            }
            ensure!(
                entry.kind() == TreeKind::Directory,
                "native inventory ancestor is not a directory"
            );
            object = entry.object().clone();
        }
        unreachable!("nonempty native inventory path")
    }

    /// Same admitted/immutable process-policy obligation as commit_object.
    /// Native replacement views must hash to the requested ID; never normalize.
    pub fn tree_object(&mut self, root: &Path, identity: &ObjectId) -> Result<TreeObject> {
        let bytes = object::read(self, root, object::Kind::Tree, identity.as_str())?;
        Ok(TreeObject {
            identity: identity.clone(),
            entries: entries(&bytes)?,
            encoded_len: bytes.len(),
        })
    }
}

fn entries(bytes: &[u8]) -> Result<Vec<TreeEntry>> {
    ensure!(
        bytes.len() <= object::MAX_TREE_BYTES,
        "native tree object exceeds bound"
    );
    let mut result = Vec::new();
    let mut names = BTreeSet::new();
    let mut previous: Option<Vec<u8>> = None;
    let mut remaining = bytes;
    while !remaining.is_empty() {
        ensure!(
            result.len() < MAX_ENTRIES,
            "native tree entry count exceeds bound"
        );
        let space = remaining
            .iter()
            .position(|b| *b == b' ')
            .ok_or_else(|| anyhow::anyhow!("invalid native tree mode frame"))?;
        let kind = match &remaining[..space] {
            b"40000" => TreeKind::Directory,
            b"100644" => TreeKind::File,
            b"100755" => TreeKind::Executable,
            b"120000" => TreeKind::Symlink,
            _ => anyhow::bail!("unsupported native tree mode"),
        };
        remaining = &remaining[space + 1..];
        let nul = remaining
            .iter()
            .position(|b| *b == 0)
            .ok_or_else(|| anyhow::anyhow!("unterminated native tree name"))?;
        let name = &remaining[..nul];
        ensure!(
            !name.is_empty()
                && name.len() <= MAX_NAME
                && !name.contains(&b'/')
                && name != b"."
                && name != b".."
                && !name.eq_ignore_ascii_case(b".git"),
            "unsupported native tree name"
        );
        let rest = &remaining[nul + 1..];
        let raw = rest
            .get(..20)
            .ok_or_else(|| anyhow::anyhow!("truncated native tree object ID"))?;
        let id = ObjectId::parse(raw.iter().map(|b| format!("{b:02x}")).collect::<String>())?;
        ensure!(names.insert(name.to_vec()), "duplicate native tree name");
        // Git compares directory names as though suffixed by '/', files by NUL.
        let mut key = name.to_vec();
        key.push(if kind == TreeKind::Directory { b'/' } else { 0 });
        ensure!(
            previous.as_ref().is_none_or(|p| p < &key),
            "noncanonical native tree order"
        );
        previous = Some(key);
        result.push(TreeEntry {
            name: name.to_vec(),
            kind,
            object: id,
        });
        remaining = &rest[20..];
    }
    Ok(result)
}

#[cfg(test)]
mod tests;
