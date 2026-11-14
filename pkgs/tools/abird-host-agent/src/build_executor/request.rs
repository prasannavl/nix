//! Immutable, bounded builder requests. Authentication and artifact verification
//! belong to adapters; hashes here bind evidence, not prove its truth.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::{digest, identifier};
use crate::sha256::digest_bytes;

pub const REQUEST_VERSION: u32 = 3;
pub const MAX_REQUEST_BYTES: usize = 32 * 1024;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct StorageIdentity {
    pub authority_id: String,
    pub builder_id: String,
    pub store_id: String,
}

impl StorageIdentity {
    pub(super) fn validate(&self) -> Result<()> {
        for value in [&self.authority_id, &self.builder_id, &self.store_id] {
            identifier(value)?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Deadlines {
    pub heartbeat_seconds: u64,
    pub stale_seconds: u64,
    pub owner_seconds: u64,
    pub queue_seconds: u64,
    pub runtime_seconds: u64,
    pub stop_grace_seconds: u64,
    pub stop_limit_seconds: u64,
    pub retention_seconds: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AdmissionPolicy {
    /// Digest of separately approved containment/capacity configuration.
    pub capacity_digest: String,
    pub deadlines: Deadlines,
    pub max_jobs: u16,
    pub max_cores: u16,
    pub submission_age_seconds: u64,
    pub future_skew_seconds: u64,
    pub replay_seconds: u64,
}

impl Deadlines {
    pub fn validate(&self) -> Result<()> {
        let d = self;
        ensure!(
            0 < d.heartbeat_seconds
                && d.heartbeat_seconds < d.stale_seconds
                && d.stale_seconds < d.owner_seconds,
            "invalid owner deadlines"
        );
        ensure!(
            0 < d.stop_grace_seconds && d.stop_grace_seconds < d.stop_limit_seconds,
            "invalid stop deadlines"
        );
        for value in [
            d.owner_seconds,
            d.queue_seconds,
            d.runtime_seconds,
            d.retention_seconds,
            d.stop_limit_seconds,
        ] {
            ensure!(
                value > 0 && value <= 366 * 24 * 3600,
                "deadline outside supported range"
            );
        }
        Ok(())
    }
}

impl AdmissionPolicy {
    pub fn validate(&self) -> Result<()> {
        digest(&self.capacity_digest)?;
        self.deadlines.validate()?;
        ensure!(
            self.submission_age_seconds > 0 && self.replay_seconds <= 366 * 24 * 3600,
            "invalid submission/replay horizon"
        );
        ensure!(
            self.future_skew_seconds <= self.submission_age_seconds
                && self.replay_seconds >= self.submission_age_seconds,
            "invalid replay horizon"
        );
        ensure!(
            self.max_jobs > 0 && self.max_cores > 0,
            "unbounded Nix capacity"
        );
        Ok(())
    }

    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        Ok(digest_bytes(&serde_json::to_vec(self)?))
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RequestId {
    /// Unix seconds, part of identity; cannot be refreshed on retry.
    pub issued_at: u64,
    pub nonce: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Source {
    pub revision: String,
    pub base_revision: String,
    /// Optional source-tree NAR SHA-256; no store materialization at admission.
    pub tree_digest: Option<String>,
    pub patch_digest: Option<String>,
}

impl Source {
    /// Metadata shape only; no artifact, Git or selected-byte verification.
    pub fn validate(&self) -> Result<()> {
        for value in [&self.revision, &self.base_revision] {
            ensure!(
                [40, 64].contains(&value.len())
                    && value
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
                "expected exact Git revision"
            );
        }
        if let Some(tree) = &self.tree_digest {
            digest(tree)?;
        }
        if let Some(patch) = &self.patch_digest {
            digest(patch)?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Peer {
    pub host_id: String,
    pub fabric_id: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BuildTarget {
    pub host: String,
    pub configuration: String,
    pub outputs: Vec<String>,
}

/// Selection syntax belongs to the existing native fleet engine. This boundary
/// validates bounds only; it must not evaluate inventory before pool admission.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Selection {
    Exact {
        targets: Vec<BuildTarget>,
    },
    Fleet {
        groups: Vec<String>,
        host: Option<String>,
        hosts: Option<String>,
        nix_config: Option<String>,
        control_plane_first: bool,
    },
}

impl BuildTarget {
    pub(super) fn validate(&self) -> Result<()> {
        identifier(&self.host)?;
        identifier(&self.configuration)?;
        ensure!(
            !self.outputs.is_empty() && self.outputs.len() <= 16,
            "invalid output count"
        );
        let mut outputs = BTreeSet::new();
        for output in &self.outputs {
            identifier(output)?;
            ensure!(outputs.insert(output), "duplicate output");
        }
        Ok(())
    }
}

impl Selection {
    fn validate(&self) -> Result<()> {
        match self {
            Self::Exact { targets } => {
                ensure!(
                    !targets.is_empty() && targets.len() <= 64,
                    "invalid target count"
                );
                let mut hosts = BTreeSet::new();
                for target in targets {
                    target.validate()?;
                    ensure!(hosts.insert(&target.host), "duplicate target host");
                }
            }
            Self::Fleet {
                groups,
                host,
                hosts,
                nix_config,
                ..
            } => {
                ensure!(
                    groups.len() <= 64 && (host.is_none() || hosts.is_none()),
                    "invalid fleet selection"
                );
                for group in groups {
                    ensure!(
                        !group.is_empty()
                            && group.len() <= 128
                            && group.bytes().all(|b| b.is_ascii_graphic()),
                        "invalid group selector"
                    );
                }
                if let Some(host) = host {
                    identifier(host)?;
                }
                if let Some(configuration) = nix_config {
                    ensure!(host.is_some(), "configuration override requires exact host");
                    identifier(configuration)?;
                }
                if let Some(hosts) = hosts {
                    ensure!(
                        !hosts.is_empty()
                            && hosts.len() <= 8192
                            && hosts.bytes().all(|b| b.is_ascii_graphic() || b == b' '),
                        "invalid host selectors"
                    );
                }
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct NixOptions {
    pub max_jobs: u16,
    pub cores: u16,
    pub substitute: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Owner {
    Foreground {
        token_digest: String,
    },
    /// Standalone build only; never implies detached deployment ownership.
    Detached,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BuildMode {
    System,
    Development,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BuildRequest {
    /// Only the trusted worker may bind this after native admission. Public
    /// resolved submission rejects it; its original intent digest never changes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<Box<super::native_intent::Request>>,
    pub schema_version: u32,
    pub executor_version: u32,
    pub id: RequestId,
    pub run_id: String,
    pub issuer: String,
    pub repository_id: String,
    pub source: Source,
    pub controller: Peer,
    pub builder: Peer,
    pub storage: StorageIdentity,
    pub mode: BuildMode,
    pub evaluation: super::context::EvaluationIntent,
    pub selection: Selection,
    pub required_hosts: Vec<String>,
    pub nix: NixOptions,
    pub policy_digest: String,
    pub deadlines: Deadlines,
    pub owner: Owner,
    pub predecessor: Option<String>,
}

impl BuildRequest {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.schema_version == REQUEST_VERSION && self.executor_version == 1,
            "unsupported build request version"
        );
        ensure!(self.id.issued_at > 0, "request ID needs creation time");
        for value in [
            &self.id.nonce,
            &self.run_id,
            &self.issuer,
            &self.repository_id,
            &self.controller.host_id,
            &self.controller.fabric_id,
            &self.builder.host_id,
            &self.builder.fabric_id,
        ] {
            identifier(value)?;
        }
        self.storage.validate()?;
        self.deadlines.validate()?;
        ensure!(
            self.builder.host_id == self.storage.builder_id,
            "builder/storage mismatch"
        );
        self.source.validate()?;
        digest(&self.policy_digest)?;
        if let Owner::Foreground { token_digest } = &self.owner {
            digest(token_digest)?;
        }
        if let Some(predecessor) = &self.predecessor {
            digest(predecessor)?;
        }
        self.evaluation.validate()?;
        ensure!(
            self.mode == self.evaluation.action.mode(),
            "action/build mode mismatch"
        );
        ensure!(
            !matches!(self.owner, Owner::Detached) || !self.evaluation.action.permits_no_build(),
            "detached deployment requires a durable deployment controller"
        );
        self.selection.validate()?;
        ensure!(
            self.required_hosts.len() <= 64,
            "required host coverage oversized"
        );
        let mut required = BTreeSet::new();
        for host in &self.required_hosts {
            identifier(host)?;
            ensure!(required.insert(host), "duplicate required host");
        }
        if let Selection::Exact { targets } = &self.selection {
            ensure!(
                !required.is_empty()
                    && required
                        .iter()
                        .all(|host| targets.iter().any(|target| &target.host == *host)),
                "invalid required host coverage"
            );
        }
        ensure!(
            self.nix.max_jobs > 0 && self.nix.cores > 0,
            "unbounded Nix options"
        );
        if let Some(parent) = &self.parent {
            parent.validate_resolution(self)?;
        }
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_REQUEST_BYTES,
            "request too large"
        );
        Ok(())
    }

    pub fn decode(bytes: &[u8]) -> Result<Self> {
        ensure!(bytes.len() <= MAX_REQUEST_BYTES, "request too large");
        let request: Self = serde_json::from_slice(bytes)?;
        request.validate()?;
        Ok(request)
    }

    pub fn attempt_id(&self) -> Result<String> {
        self.validate()?;
        Ok(digest_bytes(&serde_json::to_vec(&(
            &self.storage,
            &self.issuer,
            &self.id,
        ))?))
    }

    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        match &self.parent {
            Some(parent) => parent.digest(),
            None => self.binding_digest(),
        }
    }

    /// Full resolved content, distinct from a native attempt's immutable intent.
    pub fn binding_digest(&self) -> Result<String> {
        self.validate()?;
        Ok(digest_bytes(&serde_json::to_vec(self)?))
    }
}

impl std::fmt::Debug for BuildRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BuildRequest")
            .field("id", &self.id)
            .field("run_id", &self.run_id)
            .field("builder", &self.builder)
            .field("source", &self.source)
            .field("native_parent", &self.parent.is_some())
            .finish_non_exhaustive()
    }
}

pub(super) fn store_path(value: &str) -> Result<()> {
    let name = value
        .strip_prefix("/nix/store/")
        .context("expected Nix store path")?;
    let (hash, name) = name.split_once('-').context("invalid Nix store path")?;
    ensure!(
        hash.len() == 32
            && hash
                .bytes()
                .all(|b| b"0123456789abcdfghijklmnpqrsvwxyz".contains(&b))
            && !name.is_empty()
            && name.len() <= 211
            && name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"+-._?=".contains(&b)),
        "invalid Nix store path"
    );
    Ok(())
}

pub fn state_root(xdg_state_home: Option<&Path>, home: Option<&Path>) -> Result<PathBuf> {
    let base = if let Some(base) = xdg_state_home.filter(|p| !p.as_os_str().is_empty()) {
        ensure!(base.is_absolute(), "XDG_STATE_HOME must be absolute");
        base.to_owned()
    } else {
        let home = home.context("HOME required without XDG_STATE_HOME")?;
        ensure!(home.is_absolute(), "HOME must be absolute");
        home.join(".local/state")
    };
    Ok(base.join("abird/abird-host-agent/owned-build"))
}
