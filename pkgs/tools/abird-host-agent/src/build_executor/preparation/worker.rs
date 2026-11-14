//! Private installed-helper protocol, not a caller/control verb. Root supplies
//! sealed, verified source mappings; the helper cannot mint admission or roots.

use std::collections::BTreeMap;
use std::path::{Component, PathBuf};

use anyhow::{Result, ensure};

mod consumed;
mod revision;
pub use consumed::{
    Consumed, Consumption, Output, Planning, Query, QueryKind, needs_activation, value_digest,
};
use revision::validate_revision;
use serde::{Deserialize, Serialize};

use super::super::digest;
use super::super::request::{BuildRequest, store_path};

pub const MAX_BYTES: usize = 128 * 1024;

/// Fixed diagnostics only; source/evaluator error text never crosses the worker boundary.
pub const FAILURE_DIAGNOSTICS: [&str; 14] = [
    "owned preparation failed (setup)",
    "owned preparation failed (inventory)",
    "owned preparation failed (dependencies)",
    "owned preparation failed (native-query)",
    "owned preparation failed (source-binding)",
    "owned preparation failed (selection)",
    "owned preparation failed (planning)",
    "owned preparation failed (result)",
    "owned preparation failed (native-init)",
    "owned preparation failed (native-lock)",
    "owned preparation failed (native-accessor)",
    "owned preparation failed (native-call)",
    "owned preparation failed (native-expression)",
    "owned preparation failed (native-value)",
];

pub fn failure_diagnostic(bytes: &[u8]) -> Option<&'static str> {
    FAILURE_DIAGNOSTICS.iter().copied().find(|message| {
        bytes
            .split(|byte| *byte == b'\n')
            .any(|line| line == message.as_bytes())
    })
}

/// Fixed native evaluator profile; shared by the original parent and worker.
pub fn evaluation_configuration(system: &str) -> Result<String> {
    Input::validate_system(system)?;
    Ok(format!(
        "pure-eval = true\neval-cache = false\nallow-import-from-derivation = false\naccept-flake-config = false\nallow-unsafe-native-code-during-evaluation = false\nsystem = {system}\n"
    ))
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub path: String,
    pub nar_digest: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct NativeRoot {
    pub source: Snapshot,
    pub native_source: PathBuf,
    pub native_info: serde_json::Value,
    pub revision: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Input {
    pub version: u32,
    pub request: BuildRequest,
    pub source: Snapshot,
    pub protection_digest: String,
    pub snapshots: BTreeMap<String, String>,
    /// The private sealed Git repository, preserving native revision/dirty/time/
    /// count semantics. This is deliberately not replaced by the NAR store path.
    pub native_source: PathBuf,
    /// Import metadata only, not a receipt for a later flake evaluation. Actual
    /// actual-root observations return in Output, never from a separate probe.
    pub native_info: serde_json::Value,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub native_roots: BTreeMap<String, NativeRoot>,
    /// Original operator directory identity, retained only for DevBuild rooting.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caller_repository: Option<super::super::native_intent::CallerRepository>,
    /// Immutable native policy's system, also pinned in the actual query argv.
    pub native_system: String,
    /// Remaining monotonic budget; the parent also enforces its original cap.
    pub budget_millis: u64,
}

impl Input {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            matches!(self.version, 3 | 4) && (self.version == 4 || self.native_roots.is_empty()),
            "unsupported preparation helper protocol"
        );
        Self::validate_system(&self.native_system)?;
        self.request.validate()?;
        if let Some(repository) = &self.caller_repository {
            repository.validate_for(&self.request)?;
            ensure!(
                self.version == 4 && repository.path == self.native_source,
                "captured DevBuild destination differs from native source"
            );
        }
        store_path(&self.source.path)?;
        digest(&self.source.nar_digest)?;
        digest(&self.protection_digest)?;
        ensure!(
            self.request
                .source
                .tree_digest
                .as_ref()
                .is_none_or(|hash| hash == &self.source.nar_digest),
            "helper source witness differs"
        );
        ensure!(
            self.snapshots
                .keys()
                .map(String::as_str)
                .collect::<std::collections::BTreeSet<_>>()
                == self.request.evaluation.snapshot_digests(),
            "helper context coverage differs"
        );
        for path in self.snapshots.values() {
            store_path(path)?;
        }
        ensure!(
            self.native_roots
                .keys()
                .map(String::as_str)
                .collect::<std::collections::BTreeSet<_>>()
                == self.request.evaluation.git_digests(),
            "native root coverage differs"
        );
        ensure!(
            [
                &self.request.evaluation.build_flake,
                &self.request.evaluation.dependency_flake,
            ]
            .into_iter()
            .all(|location| !matches!(
                location.tree,
                super::super::context::InputTree::Snapshot { .. }
            )),
            "snapshot cannot replace a native Git flake"
        );
        for (hash, root) in &self.native_roots {
            digest(hash)?;
            store_path(&root.source.path)?;
            digest(&root.source.nar_digest)?;
            ensure!(
                root.native_source.is_absolute()
                    && root
                        .native_source
                        .components()
                        .all(|part| matches!(part, Component::RootDir | Component::Normal(_)))
                    && root
                        .native_info
                        .get("outPath")
                        .and_then(serde_json::Value::as_str)
                        == Some(root.source.path.as_str()),
                "invalid independent native root"
            );
            validate_revision(&root.native_info, &root.revision)?;
        }
        ensure!(
            self.native_info.is_object()
                && self
                    .native_info
                    .get("outPath")
                    .and_then(serde_json::Value::as_str)
                    == Some(self.source.path.as_str())
                && serde_json::to_vec(&self.native_info)?.len() <= 16 * 1024,
            "invalid native source metadata"
        );
        self.validate_revision(&self.native_info)?;
        ensure!(
            self.native_source.is_absolute()
                && self.native_source.as_os_str().len() <= 4096
                && self
                    .native_source
                    .components()
                    .all(|part| matches!(part, Component::RootDir | Component::Normal(_)))
                && self.budget_millis > 0
                && self.budget_millis <= self.request.deadlines.runtime_seconds * 1000,
            "invalid preparation helper context"
        );
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_BYTES,
            "preparation helper input exceeds bound"
        );
        Ok(())
    }

    pub fn validate_system(system: &str) -> Result<()> {
        super::super::identifier(system)
    }

    fn validate_revision(&self, info: &serde_json::Value) -> Result<()> {
        validate_revision(info, &self.request.source.revision)
    }

    pub fn native_root(
        &self,
        location: &super::super::context::InputLocation,
    ) -> Result<(&std::path::Path, &serde_json::Value, &str)> {
        match &location.tree {
            super::super::context::InputTree::Source => Ok((
                &self.native_source,
                &self.native_info,
                &self.request.source.revision,
            )),
            super::super::context::InputTree::Git { context_digest } => {
                let root = self
                    .native_roots
                    .get(context_digest)
                    .ok_or_else(|| anyhow::anyhow!("missing independent native root"))?;
                Ok((&root.native_source, &root.native_info, &root.revision))
            }
            _ => anyhow::bail!("snapshot cannot replace a native Git flake"),
        }
    }

    pub fn context_sources(&self) -> BTreeMap<String, String> {
        let mut trees = self.snapshots.clone();
        trees.extend(
            self.native_roots
                .iter()
                .map(|(hash, root)| (hash.clone(), root.source.path.clone())),
        );
        trees
    }

    pub fn decode(bytes: &[u8]) -> Result<Self> {
        ensure!(
            bytes.len() <= MAX_BYTES,
            "preparation helper input exceeds bound"
        );
        let input: Self = serde_json::from_slice(bytes)?;
        input.validate()?;
        Ok(input)
    }
}
