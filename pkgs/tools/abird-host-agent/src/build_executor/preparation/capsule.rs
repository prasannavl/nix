//! Private checkout transport. NARs are filesystem images, never path flakes.
//! Original Git/profile paths are replayed in a private native namespace; no
//! operator account or live operator filesystem is needed on the builder.

mod checkout;
pub use checkout::CheckoutExecution;

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::git_context::GitContext;
use super::git_profile::ConfigImage;
use super::source::MAX_MATERIAL_BYTES;
use crate::build_executor::{digest, request::BuildRequest};

/// Each image has `worktree/` (including the original .git pointer if linked)
/// and `common/` (the complete native common Git directory). The original
/// common directory is mounted over worktree/.git for a standalone repository.
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct GitImage {
    pub worktree: PathBuf,
    pub common: PathBuf,
    pub revision: String,
    pub image: GitContext,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Capsule {
    pub version: u32,
    pub caller_digest: String,
    pub primary: String,
    pub roots: BTreeMap<String, GitImage>,
    pub home: PathBuf,
    pub xdg_config_home: PathBuf,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub system_configuration: bool,
    pub configuration: ConfigImage,
}

impl Capsule {
    pub fn validate(&self, request: &BuildRequest) -> Result<()> {
        ensure!(self.version == 1, "unsupported private checkout capsule");
        digest(&self.caller_digest)?;
        ensure!(
            request.parent.as_ref().is_some_and(
                |parent| parent.caller_digest.as_deref() == Some(self.caller_digest.as_str())
            ),
            "checkout capsule caller differs"
        );
        absolute(&self.home)?;
        absolute(&self.xdg_config_home)?;
        self.configuration.validate()?;
        let global = self.home.join(".gitconfig");
        ensure!(
            !self
                .roots
                .values()
                .any(|root| global.starts_with(&root.worktree) || global.starts_with(&root.common)),
            "native safe-directory profile overlaps captured Git data"
        );
        let mut expected = request.evaluation.git_digests();
        expected.insert(&self.primary);
        ensure!(
            (1..=2).contains(&self.roots.len())
                && self
                    .roots
                    .keys()
                    .map(String::as_str)
                    .collect::<BTreeSet<_>>()
                    == expected,
            "checkout capsule root coverage differs"
        );
        for (hash, root) in &self.roots {
            root.validate()?;
            ensure!(
                hash == &root.image.nar_digest && root.image.caller_digest == self.caller_digest,
                "checkout capsule image binding differs"
            );
        }
        ensure!(
            self.roots[&self.primary].revision == request.source.revision,
            "checkout capsule target revision differs"
        );
        super::source::encoding::require_size(self, MAX_MATERIAL_BYTES)?;
        Ok(())
    }

    /// Preflight total representation under the declared source budget. Data
    /// NARs are conservatively charged including framing; the fresh sealed copy
    /// remains the exact aggregate entry/byte/depth authority after restoration.
    pub fn require_limits(
        &self,
        limits: crate::build_executor::private_tree::Limits,
        snapshots: &BTreeMap<String, String>,
    ) -> Result<()> {
        limits.validate()?;
        let mut bytes = 0u64;
        let mut entries = 1usize;
        for root in self.roots.values() {
            root.image.require_limits(limits)?;
            entries = entries
                .checked_add(root.image.stamps.len())
                .context("capsule entry overflow")?;
            for stamp in root.image.stamps.values() {
                bytes = bytes
                    .checked_add(stamp.bytes)
                    .context("capsule byte overflow")?;
            }
        }
        for nar in snapshots.values() {
            bytes = bytes
                .checked_add((nar.len() / 2) as u64)
                .context("capsule data overflow")?;
        }
        for path in self.configuration.paths() {
            if !self
                .roots
                .values()
                .any(|root| path.starts_with(&root.common))
            {
                bytes = bytes
                    .checked_add(self.configuration.bytes(path)?.len() as u64)
                    .context("capsule profile overflow")?;
            }
        }
        ensure!(
            bytes <= limits.bytes && entries <= limits.entries as usize,
            "aggregate capsule exceeds declared source budget"
        );
        Ok(())
    }

    pub fn digest(&self) -> Result<String> {
        super::source::encoding::json_digest(
            b"abird-owned-checkout-capsule-v1\n",
            self,
            MAX_MATERIAL_BYTES,
        )
    }

    pub fn primary(&self) -> Result<&GitImage> {
        self.roots
            .get(&self.primary)
            .context("checkout capsule primary missing")
    }
}

impl GitImage {
    pub fn validate(&self) -> Result<()> {
        absolute(&self.worktree)?;
        absolute(&self.common)?;
        ensure!(
            self.worktree != self.common
                && !self.worktree.starts_with(&self.common)
                && self.revision.len() == 40
                && self
                    .revision
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "invalid capsule Git identity"
        );
        self.image.validate()?;
        ensure!(
            self.image.external.is_empty()
                && self.image.layout.is_none()
                && self.image.configuration.is_none()
                && self.image.search_path.is_none(),
            "capsule image contains another context/profile"
        );
        let common = super::git_context::hex(b"common");
        let worktree = super::git_context::hex(b"worktree");
        let common_child = format!("{common}2f");
        let worktree_child = format!("{worktree}2f");
        ensure!(
            [&common, &worktree].into_iter().all(|key| self
                .image
                .stamps
                .get(key)
                .is_some_and(|stamp| stamp.directory))
                && self.image.stamps.keys().all(|key| key.is_empty()
                    || key == &common
                    || key == &worktree
                    || key.starts_with(&common_child)
                    || key.starts_with(&worktree_child)),
            "capsule image layout differs"
        );
        Ok(())
    }
}

pub fn absolute(path: &Path) -> Result<()> {
    ensure!(
        path.is_absolute()
            && path.components().count() > 2
            && path.as_os_str().len() <= 4096
            && path
                .components()
                .all(|part| matches!(part, Component::RootDir | Component::Normal(_)))
            && !["/nix", "/proc", "/sys", "/run/abird"]
                .iter()
                .any(|prefix| path.starts_with(prefix))
            // Ordinary native workspaces use private /dev/shm descendants.
            // Restoration creates namespace mountpoints, never host devices.
            && (!path.starts_with("/dev")
                || (path.starts_with("/dev/shm") && path != Path::new("/dev/shm"))),
        "unsupported capsule namespace path"
    );
    Ok(())
}
