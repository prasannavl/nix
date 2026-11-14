//! Bound preparation receipts, produced only after aggregate admission.
//!
//! Structural validation is not a NAR/source/selection/GC-root verifier. Trusted
//! adapters must independently verify those effects before journaling a receipt.

use std::collections::{BTreeMap, BTreeSet};

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

use super::request::{BuildRequest, BuildTarget, Selection, store_path};
use super::{digest, identifier};
use crate::sha256::digest_bytes;

pub mod capsule;
pub mod git_context;
pub mod git_profile;
pub mod search_path;
pub mod source;
pub mod worker;

pub const VERSION: u32 = 2;
pub const MAX_PREPARED_BYTES: usize = 64 * 1024;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PreparedTarget {
    pub target: BuildTarget,
    pub derivation: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Disposition {
    Build,
    /// Native catalog omitted a deploy=skip target; not an evaluation failure.
    NoNativePlan,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ResolvedTarget {
    pub host: String,
    pub configuration: String,
    pub disposition: Disposition,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PreparedInputs {
    pub version: u32,
    pub attempt_id: String,
    pub spec_digest: String,
    pub source_path: String,
    pub tree_digest: String,
    pub evaluation_digest: String,
    /// Exact requested snapshot NAR digest → independently verified store tree.
    pub context_sources: BTreeMap<String, String>,
    /// Captured original operator directory; covered by this preparation digest.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caller_repository: Option<super::native_intent::CallerRepository>,
    /// Native ordered selection, including explicitly justified no-build hosts.
    pub resolved: Vec<ResolvedTarget>,
    pub targets: Vec<PreparedTarget>,
    pub required_hosts: Vec<String>,
    /// Independently verified native selection against the exact source inventory.
    pub selection_digest: String,
    /// Private retained inventory/catalog/selection; never deployment authority.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub planning_digest: Option<String>,
    /// Independently verified input closure and durable protection/GC guard.
    pub protection_digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Preparation {
    pub digest: String,
    pub inputs: PreparedInputs,
}

impl Preparation {
    pub fn new(inputs: PreparedInputs, request: &BuildRequest) -> Result<Self> {
        inputs.validate(request)?;
        Ok(Self {
            digest: inputs.digest()?,
            inputs,
        })
    }

    pub fn validate(&self, request: &BuildRequest) -> Result<()> {
        self.inputs.validate(request)?;
        ensure!(
            self.digest == self.inputs.digest()?,
            "preparation digest mismatch"
        );
        Ok(())
    }
}

impl PreparedInputs {
    pub fn validate(&self, request: &BuildRequest) -> Result<()> {
        request.validate()?;
        ensure!(
            self.version == VERSION
                && self.attempt_id == request.attempt_id()?
                && self.spec_digest == request.digest()?,
            "prepared input identity mismatch"
        );
        store_path(&self.source_path)?;
        if let Some(repository) = &self.caller_repository {
            repository.validate_for(request)?;
        }
        if let Some(planning) = &self.planning_digest {
            digest(planning)?;
        }
        for value in [
            &self.tree_digest,
            &self.evaluation_digest,
            &self.selection_digest,
            &self.protection_digest,
        ] {
            digest(value)?;
        }
        ensure!(
            request
                .source
                .tree_digest
                .as_ref()
                .is_none_or(|expected| expected == &self.tree_digest),
            "prepared source witness mismatch"
        );
        ensure!(
            self.evaluation_digest == request.evaluation.digest()?,
            "prepared evaluation intent mismatch"
        );
        ensure!(
            self.context_sources
                .keys()
                .map(String::as_str)
                .collect::<BTreeSet<_>>()
                == request.evaluation.context_digests(),
            "prepared context sources mismatch"
        );
        let mut paths = BTreeSet::new();
        for (nar, path) in &self.context_sources {
            store_path(path)?;
            ensure!(
                path != &self.source_path
                    || nar == &self.tree_digest
                    || request.evaluation.git_digests().contains(nar.as_str()),
                "context/source NAR witnesses disagree"
            );
            ensure!(
                request.evaluation.git_digests().contains(nar.as_str()) || paths.insert(path),
                "different NAR digests bind the same context path"
            );
        }
        ensure!(
            !self.resolved.is_empty() && self.resolved.len() <= 64 && self.targets.len() <= 64,
            "invalid prepared target count"
        );
        let mut selected = BTreeSet::new();
        for target in &self.resolved {
            identifier(&target.host)?;
            identifier(&target.configuration)?;
            ensure!(selected.insert(&target.host), "duplicate resolved host");
            if target.disposition == Disposition::NoNativePlan {
                ensure!(
                    request.evaluation.action.permits_no_build()
                        && matches!(request.selection, Selection::Fleet { .. }),
                    "no-build disposition is not authorized by intent"
                );
            }
        }
        let mut hosts = BTreeSet::new();
        for target in &self.targets {
            target.target.validate()?;
            ensure!(hosts.insert(&target.target.host), "duplicate prepared host");
            store_path(&target.derivation)?;
            ensure!(
                target.derivation.ends_with(".drv"),
                "expected prepared derivation"
            );
        }
        ensure!(
            self.resolved
                .iter()
                .filter(|target| target.disposition == Disposition::Build)
                .map(|target| (&target.host, &target.configuration))
                .eq(self
                    .targets
                    .iter()
                    .map(|prepared| (&prepared.target.host, &prepared.target.configuration))),
            "prepared builds differ from resolved selection"
        );
        ensure!(
            self.required_hosts == request.required_hosts,
            "prepared coverage differs from requested coverage"
        );
        let mut required = BTreeSet::new();
        for host in &self.required_hosts {
            ensure!(
                selected.contains(host) && required.insert(host),
                "invalid prepared required host"
            );
        }
        if let Selection::Exact { targets } = &request.selection {
            ensure!(
                targets
                    .iter()
                    .eq(self.targets.iter().map(|prepared| &prepared.target))
                    && request.required_hosts == self.required_hosts,
                "prepared selection differs from exact intent"
            );
        }
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_PREPARED_BYTES,
            "prepared inputs exceed bound"
        );
        Ok(())
    }

    pub fn decode(bytes: &[u8], request: &BuildRequest) -> Result<Self> {
        ensure!(
            bytes.len() <= MAX_PREPARED_BYTES,
            "prepared inputs exceed bound"
        );
        let value: Self = serde_json::from_slice(bytes)?;
        value.validate(request)?;
        Ok(value)
    }

    pub fn digest(&self) -> Result<String> {
        Ok(digest_bytes(&serde_json::to_vec(self)?))
    }
}
