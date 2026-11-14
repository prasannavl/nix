//! Bounded native index-entry observations, not verified source or index files.

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{Result, ensure};

use super::{CommandRunner, RepositoryManager, TreeInventory, TreeKind};

const MAX_BYTES: usize = 4 * 1024 * 1024;
const MAX_ENTRIES: usize = 32 * 1024;
const MAX_PATH: usize = 4096;

/// Comparable native entries. Paths/object IDs stay private and are not Debug
/// or serialized. Equality is not provenance or working-tree verification.
#[derive(Eq, PartialEq)]
pub struct IndexEntries(BTreeMap<Vec<u8>, Entry>);

#[derive(Eq, PartialEq)]
struct Entry {
    mode: &'static str,
    object: [u8; 40],
}

impl IndexEntries {
    pub fn regular_file(&self, path: &[u8]) -> Result<bool> {
        for (index, byte) in path.iter().enumerate() {
            ensure!(
                *byte != b'/' || !self.0.contains_key(&path[..index]),
                "indexed inventory ancestor is not a directory"
            );
        }
        let Some(entry) = self.0.get(path) else {
            return Ok(false);
        };
        ensure!(
            entry.mode != "120000",
            "symlink inventory context requires explicit binding"
        );
        Ok(true)
    }

    /// Exact projected leaves only. Directories have no index entries; this does
    /// not verify full index state, working bytes, configuration or provenance.
    pub fn matches_tree(&self, tree: &TreeInventory) -> bool {
        let mut leaves = tree
            .entries()
            .iter()
            .filter(|(_, entry)| entry.kind() != TreeKind::Directory);
        if self.0.len() != leaves.clone().count() {
            return false;
        }
        leaves.all(|(path, expected)| {
            let mode = match expected.kind() {
                TreeKind::File => "100644",
                TreeKind::Executable => "100755",
                TreeKind::Symlink => "120000",
                TreeKind::Directory => unreachable!("filtered directories"),
            };
            self.0.get(path).is_some_and(|actual| {
                actual.mode == mode
                    && actual.object.as_slice() == expected.object().as_str().as_bytes()
            })
        })
    }
}

impl<R: CommandRunner> RepositoryManager<R> {
    /// Reject visible assume-unchanged/skip-worktree/fsmonitor flags, unmerged
    /// stages and gitlinks. Does not audit config, extensions or intent-to-add.
    /// Caller provides immutable source/process policy and bounded admission.
    pub fn index_entries(&mut self, root: &Path) -> Result<IndexEntries> {
        let output = self.run_git(
            root,
            [
                "ls-files",
                "--cached",
                "--stage",
                "-v",
                "-f",
                "--full-name",
                "-z",
                "--",
            ],
            None,
        )?;
        ensure!(output.status == 0, "read native index entries failed");
        entries(&output.stdout)
    }
}

fn entries(bytes: &[u8]) -> Result<IndexEntries> {
    ensure!(
        bytes.len() <= MAX_BYTES,
        "native index listing exceeds bound"
    );
    let mut entries = BTreeMap::new();
    if bytes.is_empty() {
        return Ok(IndexEntries(entries));
    }
    let records = bytes
        .strip_suffix(&[0])
        .ok_or_else(|| anyhow::anyhow!("unterminated native index listing"))?;
    for (count, record) in records.split(|b| *b == 0).enumerate() {
        ensure!(
            count < MAX_ENTRIES,
            "native index entry count exceeds bound"
        );
        let tab = record
            .iter()
            .position(|b| *b == b'\t')
            .ok_or_else(|| anyhow::anyhow!("invalid native index frame"))?;
        let mut fields = record[..tab].split(|b| *b == b' ');
        let [Some(flag), Some(mode), Some(object), Some(stage)] =
            std::array::from_fn(|_| fields.next())
        else {
            anyhow::bail!("invalid native index fields")
        };
        ensure!(fields.next().is_none(), "invalid native index fields");
        ensure!(flag == b"H", "unsupported native index entry flags");
        ensure!(stage == b"0", "unmerged native index entry");
        let mode = match mode {
            b"100644" => "100644",
            b"100755" => "100755",
            b"120000" => "120000",
            _ => anyhow::bail!("unsupported native index entry mode"),
        };
        ensure!(
            object.len() == 40
                && object.iter().any(|b| *b != b'0')
                && object
                    .iter()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b)),
            "unsupported native index object ID"
        );
        let object = object.try_into().expect("checked object length");
        let path = &record[tab + 1..];
        ensure!(
            !path.is_empty() && path.len() <= MAX_PATH,
            "invalid native index path length"
        );
        ensure!(
            path.split(|b| *b == b'/').all(|part| !part.is_empty()
                && part != b"."
                && part != b".."
                && !part.eq_ignore_ascii_case(b".git")),
            "unsupported native index path"
        );
        ensure!(
            entries
                .insert(path.to_vec(), Entry { mode, object })
                .is_none(),
            "duplicate native index path"
        );
    }
    Ok(IndexEntries(entries))
}

#[cfg(test)]
mod tests;
