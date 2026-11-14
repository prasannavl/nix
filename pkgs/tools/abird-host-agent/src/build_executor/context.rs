//! Evaluation intent contains no caller filesystem paths or pre-admission Nix
//! results. Snapshot digests bind supplied NAR bytes, not their verification.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::digest;
use super::request::BuildMode;
use crate::sha256::digest_bytes;

pub const VERSION: u32 = 1;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BuildAction {
    Run,
    Deploy,
    Build,
    DevBuild,
}

impl BuildAction {
    pub fn mode(self) -> BuildMode {
        match self {
            Self::DevBuild => BuildMode::Development,
            _ => BuildMode::System,
        }
    }

    pub fn permits_no_build(self) -> bool {
        matches!(self, Self::Run | Self::Deploy)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum InputTree {
    Source,
    /// Private native Git image identity; never a path-flake substitution.
    Git {
        context_digest: String,
    },
    /// SHA-256 of the exact directory NAR; never a fetch URL or local path.
    Snapshot {
        nar_digest: String,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct InputLocation {
    pub tree: InputTree,
    /// Empty denotes the tree root; allowed only for directory inputs.
    pub relative: String,
}

impl InputLocation {
    pub fn source(relative: impl Into<String>) -> Self {
        Self {
            tree: InputTree::Source,
            relative: relative.into(),
        }
    }

    /// Metadata-only join. A trusted verifier must reject symlink escapes and
    /// verify each NAR/store object before this mapping is used for effects.
    pub fn resolve(&self, source: &str, snapshots: &BTreeMap<String, String>) -> Result<PathBuf> {
        self.validate(true)?;
        let root = match &self.tree {
            InputTree::Source => source,
            InputTree::Git {
                context_digest: nar_digest,
            }
            | InputTree::Snapshot { nar_digest } => snapshots
                .get(nar_digest)
                .context("missing retained context snapshot")?,
        };
        super::request::store_path(root)?;
        Ok(PathBuf::from(root).join(&self.relative))
    }

    fn validate(&self, directory: bool) -> Result<()> {
        match &self.tree {
            InputTree::Snapshot { nar_digest } => digest(nar_digest)?,
            InputTree::Git { context_digest } => digest(context_digest)?,
            InputTree::Source => {}
        }
        let value = &self.relative;
        ensure!(
            value.len() <= 4096 && !value.chars().any(char::is_control),
            "invalid evaluation input path"
        );
        ensure!(
            (directory && value.is_empty())
                || (!value.is_empty()
                    && value.split('/').all(|part| !part.is_empty()
                        && part != "."
                        && part != ".."
                        && part.len() <= 255)),
            "evaluation input path must be normalized and relative"
        );
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum PlanJobs {
    Auto,
    Count { jobs: u16 },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct EvaluationIntent {
    pub version: u32,
    pub action: BuildAction,
    pub build_flake: InputLocation,
    pub inventory: InputLocation,
    /// None freezes absence; never discover a sibling after admission.
    pub overlay: Option<InputLocation>,
    pub repository_config: Option<InputLocation>,
    pub dependency_flake: InputLocation,
    pub plan_jobs: PlanJobs,
    /// None preserves the inventory/default policy; Some is an explicit override.
    pub deploy_jobs_per_domain: Option<u16>,
}

impl EvaluationIntent {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.version == VERSION,
            "unsupported evaluation intent version"
        );
        self.build_flake.validate(true)?;
        self.inventory.validate(false)?;
        if let Some(overlay) = &self.overlay {
            overlay.validate(false)?;
        }
        if let Some(config) = &self.repository_config {
            config.validate(true)?;
        }
        self.dependency_flake.validate(true)?;
        if let PlanJobs::Count { jobs } = self.plan_jobs {
            ensure!((1..=64).contains(&jobs), "invalid evaluation concurrency");
        }
        if let Some(jobs) = self.deploy_jobs_per_domain {
            ensure!(jobs > 0, "invalid deployment wave capacity");
        }
        Ok(())
    }

    pub fn snapshot_digests(&self) -> BTreeSet<&str> {
        [
            Some(&self.build_flake),
            Some(&self.inventory),
            self.overlay.as_ref(),
            self.repository_config.as_ref(),
            Some(&self.dependency_flake),
        ]
        .into_iter()
        .flatten()
        .filter_map(|input| match &input.tree {
            InputTree::Source | InputTree::Git { .. } => None,
            InputTree::Snapshot { nar_digest } => Some(nar_digest.as_str()),
        })
        .collect()
    }

    pub fn git_digests(&self) -> BTreeSet<&str> {
        [&self.build_flake, &self.dependency_flake]
            .into_iter()
            .filter_map(|location| match &location.tree {
                InputTree::Git { context_digest } => Some(context_digest.as_str()),
                _ => None,
            })
            .collect()
    }

    pub fn context_digests(&self) -> BTreeSet<&str> {
        self.snapshot_digests()
            .union(&self.git_digests())
            .copied()
            .collect()
    }

    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        Ok(digest_bytes(&serde_json::to_vec(self)?))
    }
}

#[cfg(test)]
mod tests;
