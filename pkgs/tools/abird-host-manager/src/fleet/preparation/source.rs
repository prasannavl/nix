//! Bind source artifacts and base-entry observations before native preparation.
//! Not a coherent repository, working-byte, configuration, NAR or evaluation proof.

use std::path::Path;

use abird_host_agent::build_executor::request::Source;
use anyhow::{Result, ensure};
use sha2::{Digest, Sha256};

use crate::fleet::repository::{
    CommandRunner, CommitSha, DetachedWorktree, RepositoryManager, StagedPatch, TreeInventory,
};

pub const MAX_PATCH_BYTES: usize = 4 * 1024 * 1024;

/// Immutable intent/artifact binding only. Private patch bytes are neither Debug
/// nor serialized. Caller owns authorization, registration and the original job.
pub struct SourceRecipe {
    intent: Source,
    revision: CommitSha,
    patch: Option<StagedPatch>,
}

impl SourceRecipe {
    pub fn bind(intent: &Source, patch: Option<StagedPatch>) -> Result<Self> {
        intent.validate()?;
        ensure!(
            intent.revision.len() == 40 && intent.base_revision.len() == 40,
            "native source recipe supports SHA-1 revisions only"
        );
        match (&intent.patch_digest, &patch) {
            (None, None) => {}
            (Some(expected), Some(patch)) => {
                ensure!(
                    patch.bytes.len() <= MAX_PATCH_BYTES,
                    "source patch exceeds bound"
                );
                ensure!(
                    patch.base.as_str() == intent.base_revision
                        && intent.revision == intent.base_revision,
                    "source patch base differs from selected intent"
                );
                ensure!(
                    format!("{:x}", Sha256::digest(&patch.bytes)) == *expected,
                    "source patch digest differs from intent"
                );
            }
            _ => anyhow::bail!("source patch presence differs from intent"),
        }
        Ok(Self {
            intent: intent.clone(),
            revision: CommitSha::parse(intent.revision.clone())?,
            patch,
        })
    }

    pub fn intent(&self) -> &Source {
        &self.intent
    }

    /// Same native worktree/apply operations, original captured commit/profile.
    /// The installed parent supplies the private original-path filesystem view.
    pub fn caller_checkout<R: CommandRunner>(
        &self,
        repository: &mut RepositoryManager<R>,
        source: &Path,
        target: &Path,
    ) -> Result<DetachedWorktree> {
        let view = repository.create_detached_worktree_at(source, target, &self.revision)?;
        if let Some(patch) = &self.patch {
            repository.apply_staged_patch(&view.path, patch)?;
        }
        Ok(view)
    }

    pub fn installed_checkout<R: CommandRunner>(
        &self,
        repository: &mut RepositoryManager<R>,
        parent: &Path,
        url: &str,
        before_checkout: impl FnOnce(&Path) -> Result<()>,
    ) -> Result<String> {
        let view =
            repository.create_installed_checkout(parent, url, &self.revision, before_checkout)?;
        if let Some(patch) = &self.patch {
            repository.apply_staged_patch(&view.path, patch)?;
        }
        repository.require_installed_patch(
            &view.path,
            self.patch.as_ref().map(|patch| patch.bytes.as_slice()),
        )?;
        repository.installed_source_observation(&view.path, &self.revision)
    }

    pub fn observe_installed<R: CommandRunner>(
        &self,
        repository: &mut RepositoryManager<R>,
        root: &Path,
    ) -> Result<String> {
        repository.require_installed_patch(
            root,
            self.patch.as_ref().map(|patch| patch.bytes.as_slice()),
        )?;
        repository.installed_source_observation(root, &self.revision)
    }

    /// Reuse native exact worktree/base/patch operations within the caller's
    /// admitted bounded repository scope. Failures leave tracked producer data;
    /// this result grants neither replay, cleanup nor a prepared-source receipt.
    pub fn native_worktree<R: CommandRunner>(
        &self,
        repository: &mut RepositoryManager<R>,
        source: &Path,
        target: &Path,
        observed: &TreeInventory,
    ) -> Result<DetachedWorktree> {
        // Caller observes under the same owner/deadline; no receipt authority.
        {
            let commit = repository.commit_object(source, &self.revision)?;
            let tree = commit.tree_id()?;
            ensure!(
                tree == *observed.root(),
                "observed source tree differs from intent"
            );
            repository.tree_object(source, &tree)?;
        }
        let base = self
            .patch
            .as_ref()
            .map(|patch| &patch.base)
            .unwrap_or(&self.revision);
        let resolved = repository.validate_staged_base(source, self.revision.as_str(), base)?;
        ensure!(
            resolved == self.revision,
            "resolved source base differs from intent"
        );
        let view = repository.create_detached_worktree(source, target, self.revision.as_str())?;
        ensure!(
            view.commit == self.revision,
            "resolved source revision differs from intent"
        );
        ensure!(
            repository.index_entries(target)?.matches_tree(observed),
            "native base index differs from observed tree"
        );
        if let Some(patch) = &self.patch {
            repository.apply_staged_patch(target, patch)?;
        }
        Ok(view)
    }
}

#[cfg(test)]
mod tests;
