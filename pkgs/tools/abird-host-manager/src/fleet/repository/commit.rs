//! Native commit bytes checked against the requested object ID. Not source,
//! history/tree closure, repository confinement or evaluation verification.

use std::path::Path;

use anyhow::{Result, ensure};

use super::{CommandRunner, CommitSha, ObjectId, RepositoryManager, object};

/// Private immutable observation; no Debug/serde or authority to prepare/build.
/// Native Git rehashing binds these bytes, not other repository state.
pub struct CommitObject {
    revision: CommitSha,
    bytes: Vec<u8>,
}

impl CommitObject {
    pub fn revision(&self) -> &CommitSha {
        &self.revision
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    /// Only the first, exact native tree header. No parent/history verification.
    pub fn tree_id(&self) -> Result<ObjectId> {
        let newline = self
            .bytes
            .iter()
            .position(|b| *b == b'\n')
            .ok_or_else(|| anyhow::anyhow!("unterminated native commit tree header"))?;
        let first = &self.bytes[..newline];
        let tree = first
            .strip_prefix(b"tree ")
            .filter(|id| id.len() == 40)
            .ok_or_else(|| anyhow::anyhow!("invalid native commit tree header"))?;
        let tree = std::str::from_utf8(tree)
            .map_err(|_| anyhow::anyhow!("invalid native commit tree header"))?;
        ObjectId::parse(tree)
    }
}

impl<R: CommandRunner> RepositoryManager<R> {
    /// Caller provides admitted bounded capture and immutable executable policy.
    /// Keep native replacement semantics: reject differing bytes rather than
    /// silently disabling replacements or normalizing the execution checkout.
    pub fn commit_object(&mut self, root: &Path, revision: &CommitSha) -> Result<CommitObject> {
        ensure!(
            revision.as_str().len() == 40,
            "full native commit ID required"
        );
        let bytes = object::read(self, root, object::Kind::Commit, revision.as_str())?;
        Ok(CommitObject {
            revision: revision.clone(),
            bytes,
        })
    }
}

#[cfg(test)]
mod tests;
