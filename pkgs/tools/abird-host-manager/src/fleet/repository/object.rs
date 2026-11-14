//! Private native object capture/rehash; not repository or closure authority.

use std::path::Path;

use anyhow::{Result, ensure};

use super::{CommandRunner, RepositoryManager};

pub(super) const MAX_COMMIT_BYTES: usize = 1024 * 1024;
pub(super) const MAX_TREE_BYTES: usize = 4 * 1024 * 1024;
pub(super) const MAX_BLOB_BYTES: usize = 16 * 1024 * 1024;

/// Exact SHA-1 object name only; construction does not verify object existence.
#[derive(Clone, Eq, PartialEq)]
pub struct ObjectId(String);

impl ObjectId {
    pub fn parse(value: impl Into<String>) -> Result<Self> {
        let value = value.into();
        ensure!(
            value.len() == 40
                && value
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                && value.bytes().any(|b| b != b'0'),
            "unsupported native object ID"
        );
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

pub(super) enum Kind {
    Commit,
    Tree,
    Blob,
}

pub(super) fn read<R: CommandRunner>(
    manager: &mut RepositoryManager<R>,
    root: &Path,
    kind: Kind,
    expected: &str,
) -> Result<Vec<u8>> {
    let (kind, max, empty) = match kind {
        Kind::Commit => ("commit", MAX_COMMIT_BYTES, false),
        Kind::Tree => ("tree", MAX_TREE_BYTES, true),
        Kind::Blob => ("blob", MAX_BLOB_BYTES, true),
    };
    let object = manager.run_git(root, ["cat-file", kind, expected], None)?;
    ensure!(object.status == 0, "read native {kind} object failed");
    ensure!(
        (empty || !object.stdout.is_empty()) && object.stdout.len() <= max,
        "native {kind} object size outside bound"
    );
    // No -w, filters, text conversion or revision re-resolution.
    let hashed = manager.run_git(
        root,
        ["hash-object", "--no-filters", "-t", kind, "--stdin"],
        Some(object.stdout.clone()),
    )?;
    ensure!(hashed.status == 0, "hash native {kind} object failed");
    ensure!(
        hashed.stdout.strip_suffix(b"\n") == Some(expected.as_bytes()),
        "native {kind} content differs from requested identity"
    );
    Ok(object.stdout)
}
