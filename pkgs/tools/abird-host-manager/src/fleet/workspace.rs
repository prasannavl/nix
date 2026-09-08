//! Isolated Git worktrees used as fleet execution authority.

use std::fs;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};

use super::repository::{
    CommandRunner, CommitSha, ManagedRepository, RepositoryManager, StagedPatch,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionWorkspaceRequest {
    pub source_root: PathBuf,
    pub execution_root: PathBuf,
    pub target: Option<String>,
    pub managed: Option<ManagedRepository>,
    pub allow_dirty: bool,
    pub staged_patch: Option<StagedPatch>,
    /// The caller already entered an isolated worktree created by its parent.
    pub inherited: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionWorkspace {
    pub source_root: PathBuf,
    pub root: PathBuf,
    pub commit: CommitSha,
    pub owned: bool,
}

pub fn prepare_execution_workspace<R: CommandRunner>(
    manager: &mut RepositoryManager<R>,
    request: &ExecutionWorkspaceRequest,
) -> Result<ExecutionWorkspace> {
    if request.inherited {
        if !request.execution_root.is_dir() {
            bail!(
                "inherited execution worktree does not exist: {}",
                request.execution_root.display()
            );
        }
        let commit = request
            .target
            .clone()
            .context("inherited execution worktree requires its resolved commit")
            .and_then(CommitSha::parse)?;
        return Ok(ExecutionWorkspace {
            source_root: request.source_root.clone(),
            root: request.execution_root.clone(),
            commit,
            owned: false,
        });
    }

    let default_target = if let Some(managed) = &request.managed {
        if managed.root != request.source_root {
            bail!("managed repository root must equal the selected source root");
        }
        manager.prepare_managed(managed)?.head.as_str().to_owned()
    } else {
        manager.ensure_clean(&request.source_root, request.allow_dirty)?;
        "HEAD".to_owned()
    };
    let target = request.target.as_deref().unwrap_or(&default_target);

    if let Some(patch) = &request.staged_patch
        && let Ok(target_sha) = CommitSha::parse(target)
        && !same_revision(&target_sha, &patch.base)
    {
        bail!(
            "staged patch base {} does not match requested target {}",
            patch.base.as_str(),
            target_sha.as_str()
        );
    }
    if let Some(parent) = request.execution_root.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create execution worktree parent {}", parent.display()))?;
    }
    let detached =
        manager.create_detached_worktree(&request.source_root, &request.execution_root, target)?;

    let apply = (|| -> Result<()> {
        if let Some(patch) = &request.staged_patch {
            manager.validate_staged_base(&request.source_root, target, &patch.base)?;
            manager.apply_staged_patch(&detached.path, patch)?;
        }
        Ok(())
    })();
    if let Err(action_error) = apply {
        let cleanup = manager.remove_worktree(&request.source_root, &detached.path);
        return match cleanup {
            Ok(()) => Err(action_error),
            Err(cleanup_error) => Err(anyhow::anyhow!(
                "{action_error:#}; execution worktree cleanup also failed: {cleanup_error:#}"
            )),
        };
    }

    Ok(ExecutionWorkspace {
        source_root: request.source_root.clone(),
        root: detached.path,
        commit: detached.commit,
        owned: true,
    })
}

pub fn cleanup_execution_workspace<R: CommandRunner>(
    manager: &mut RepositoryManager<R>,
    workspace: &ExecutionWorkspace,
) -> Result<()> {
    if workspace.owned {
        manager.remove_worktree(&workspace.source_root, &workspace.root)?;
    }
    Ok(())
}

fn same_revision(left: &CommitSha, right: &CommitSha) -> bool {
    left.as_str().starts_with(right.as_str()) || right.as_str().starts_with(left.as_str())
}
