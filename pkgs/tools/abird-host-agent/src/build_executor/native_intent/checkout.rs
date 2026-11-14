//! Private original-worker checkout inputs. Paths describe the caller's native
//! view, not authority to write those host paths or create another attempt.

use super::Validation;
use crate::build_executor::preparation::source::{MAX_MATERIAL_BYTES, MAX_PATCH_BYTES, unhex};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::path::{Component, Path, PathBuf};

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Checkout {
    pub namespace_root: PathBuf,
    pub umask: u32,
}

impl Checkout {
    pub fn validate(&self) -> Result<()> {
        absolute(&self.namespace_root)?;
        ensure!(
            self.namespace_root.components().count() > 2 && self.umask <= 0o777,
            "invalid original checkout namespace/mask"
        );
        Ok(())
    }

    pub fn workspace(&self, run_id: &str) -> Result<PathBuf> {
        self.validate()?;
        ensure!(
            run_id.len() == 32
                && run_id
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "checkout requires original native run ID"
        );
        Ok(self
            .namespace_root
            .join(format!("run-{run_id}"))
            .join("repo"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn original_native_workspace_never_uses_a_new_identity_or_fallback() {
        let checkout = Checkout {
            namespace_root: "/dev/shm/nixbot".into(),
            umask: 0o027,
        };
        let run = "a".repeat(32);
        assert_eq!(
            checkout.workspace(&run).unwrap(),
            PathBuf::from(format!("/dev/shm/nixbot/run-{run}/repo"))
        );
        crate::build_executor::preparation::capsule::absolute(&checkout.workspace(&run).unwrap())
            .unwrap();
        for path in [
            "/dev",
            "/dev/shm",
            "/dev/mem",
            "/dev/shm/../mem",
            "/run/abird/input",
        ] {
            assert!(
                crate::build_executor::preparation::capsule::absolute(Path::new(path)).is_err()
            );
        }
        assert!(checkout.workspace("replacement").is_err());
        let mut invalid = checkout.clone();
        invalid.namespace_root = "/dev/shm/../other".into();
        assert!(invalid.validate().is_err());
        invalid = checkout;
        invalid.umask = 0o1000;
        assert!(invalid.validate().is_err());
    }
}

pub(super) fn absolute(path: &Path) -> Result<()> {
    ensure!(
        path.is_absolute()
            && path.as_os_str().len() <= 4096
            && path
                .components()
                .all(|part| matches!(part, Component::RootDir | Component::Normal(_))),
        "invalid original checkout path"
    );
    Ok(())
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CheckoutInput {
    pub validation: Validation,
    pub delivery_digest: String,
    pub patch: Option<String>,
    pub search_path: crate::build_executor::preparation::search_path::SearchPath,
    pub configuration: crate::build_executor::preparation::git_profile::ConfigImage,
    pub runtime_closure: PathBuf,
    pub limits: crate::build_executor::private_tree::Limits,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_layout: Option<crate::build_executor::preparation::git_context::GitLayout>,
    pub budget_millis: u64,
}

impl CheckoutInput {
    pub fn context(&self) -> Result<(PathBuf, Checkout)> {
        let root: PathBuf = serde_json::from_value(
            self.validation
                .context
                .get("source_root")
                .context("original checkout root missing")?
                .clone(),
        )?;
        let checkout: Checkout = serde_json::from_value(
            self.validation
                .context
                .get("checkout")
                .context("original checkout selection missing")?
                .clone(),
        )?;
        absolute(&root)?;
        checkout.validate()?;
        Ok((root, checkout))
    }

    pub fn common_directory(&self) -> Result<PathBuf> {
        Ok(self
            .git_layout
            .as_ref()
            .map(|layout| layout.common.clone())
            .unwrap_or(self.context()?.0.join(".git")))
    }

    pub fn validate(&self) -> Result<()> {
        self.validation.validate()?;
        self.search_path.validate()?;
        self.configuration.validate()?;
        self.limits.validate()?;
        crate::build_executor::daemon::store_path(&self.runtime_closure)?;
        let request = &self.validation.request;
        let parent = request
            .parent
            .as_ref()
            .context("checkout lacks original native admission")?;
        ensure!(
            parent.bootstrap_digest.is_some() && parent.caller_digest.is_some(),
            "checkout lacks installed caller capture"
        );
        if let Some(layout) = &self.git_layout {
            layout.validate()?;
            ensure!(
                layout.worktree == self.context()?.0,
                "checkout Git layout differs"
            );
        }
        crate::build_executor::digest(&self.delivery_digest)?;
        let (_, checkout) = self.context()?;
        checkout.workspace(&parent.run_id)?;
        match (&self.patch, &request.source.patch_digest) {
            (Some(patch), Some(digest)) => ensure!(
                crate::sha256::digest_bytes(&unhex(patch, MAX_PATCH_BYTES)?) == *digest,
                "checkout patch differs from captured intent"
            ),
            (None, None) => {}
            _ => anyhow::bail!("checkout patch presence differs"),
        }
        ensure!(
            self.budget_millis > 0
                && self.budget_millis <= request.deadlines.runtime_seconds.saturating_mul(1000)
                && serde_json::to_vec(self)?.len() <= MAX_MATERIAL_BYTES,
            "checkout input exceeds original bound"
        );
        Ok(())
    }
}
