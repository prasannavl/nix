//! Native command admission before source capture. Resolution is a one-time
//! trusted-worker operation in the original attempt, never a replacement job.

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

use super::context::BuildAction;
use super::request::{
    AdmissionPolicy, BuildRequest, Deadlines, NixOptions, Owner, Peer, RequestId, StorageIdentity,
};
use super::{digest, identifier};
use crate::sha256::digest_bytes;

mod checkout;
pub use checkout::{Checkout, CheckoutInput};

pub const MAX_BYTES: usize = 16 * 1024;

// No Debug: normal invocation options may contain private caller credentials.

/// Fixed Git process context of the caller-UID capture/checkout helpers. A
/// caller sets the same values or leaves them unset (NOSYSTEM only with no
/// system configuration); its global profile is explicit or the discovered
/// defaults, observed in the original namespace before admission.
pub const CALLER_GIT_PROFILE: [(&str, &str); 3] = [
    ("GIT_CONFIG_NOSYSTEM", "1"),
    ("GIT_OPTIONAL_LOCKS", "0"),
    ("GIT_TERMINAL_PROMPT", "0"),
];

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u32,
    pub executor_version: u32,
    pub id: RequestId,
    pub run_id: String,
    pub issuer: String,
    pub repository_id: String,
    pub controller: Peer,
    pub builder: Peer,
    pub storage: StorageIdentity,
    pub action: BuildAction,
    /// Strict native Invocation JSON; only the installed manager interprets it.
    /// Agent performs bounds/authentication, not a second CLI parser/selector.
    pub invocation: serde_json::Value,
    pub nix: NixOptions,
    pub policy_digest: String,
    pub deadlines: Deadlines,
    pub owner: Owner,
    /// Installed same-node CI observer, not detached build/deployment ownership.
    #[serde(default)]
    pub controller_service: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bootstrap_digest: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caller_digest: Option<String>,
}

impl Request {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.version == 1 && self.executor_version == 1 && self.id.issued_at > 0,
            "unsupported native admission request"
        );
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
        ensure!(
            !self.controller_service
                || (self.controller.host_id == self.builder.host_id
                    && self.run_id.len() == 32
                    && self
                        .run_id
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))),
            "durable CI controller must be on the original builder"
        );
        if let Some(binding) = &self.bootstrap_digest {
            digest(binding)?;
        }
        if let Some(binding) = &self.caller_digest {
            digest(binding)?;
        }
        self.storage.validate()?;
        self.deadlines.validate()?;
        digest(&self.policy_digest)?;
        ensure!(
            self.builder.host_id == self.storage.builder_id
                && self.nix.max_jobs > 0
                && self.nix.cores > 0,
            "native builder/capacity differs"
        );
        let Owner::Foreground { token_digest } = &self.owner else {
            anyhow::bail!("native workflow requires renewable ownership");
        };
        digest(token_digest)?;
        ensure!(
            self.invocation.is_object() && serde_json::to_vec(self)?.len() <= MAX_BYTES,
            "native admission input exceeds bound"
        );
        Ok(())
    }

    pub fn authority(&self, identity: &StorageIdentity, policy: &AdmissionPolicy) -> Result<()> {
        self.validate()?;
        ensure!(
            &self.storage == identity
                && self.policy_digest == policy.digest()?
                && self.deadlines == policy.deadlines
                && self.nix.max_jobs <= policy.max_jobs
                && self.nix.cores <= policy.max_cores,
            super::protocol::Rejection::PolicyMismatch
        );
        Ok(())
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
        let mut bytes = b"abird-owned-native-intent-v1\n".to_vec();
        bytes.extend(serde_json::to_vec(self)?);
        Ok(digest_bytes(&bytes))
    }

    /// Header binding only. The immutable installed native helper additionally
    /// validates normal command/source/context semantics before trusted binding.
    pub fn validate_resolution(&self, request: &BuildRequest) -> Result<()> {
        self.validate()?;
        ensure!(
            request.parent.as_deref() == Some(self)
                && request.id == self.id
                && request.run_id == self.run_id
                && request.issuer == self.issuer
                && request.repository_id == self.repository_id
                && request.controller == self.controller
                && request.builder == self.builder
                && request.storage == self.storage
                && request.nix == self.nix
                && request.policy_digest == self.policy_digest
                && request.deadlines == self.deadlines
                && request.owner == self.owner
                && request.predecessor.is_none()
                && request.evaluation.action == self.action
                && request.mode == self.action.mode(),
            "resolved native admission identity/policy differs"
        );
        Ok(())
    }
}

/// Data-lane frame. The original source delivery claim covers both metadata and
/// bytes. Metadata validation is not caller-context equivalence or settlement.
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Material {
    pub version: u32,
    pub request: BuildRequest,
    pub context: serde_json::Value,
    pub source: super::preparation::source::Material,
}

impl Material {
    pub fn decode(bytes: &[u8], intent: &Request) -> Result<Self> {
        ensure!(
            bytes.len() <= super::preparation::source::MAX_MATERIAL_BYTES,
            "native material exceeds bound"
        );
        let value: Self = serde_json::from_slice(bytes)
            .map_err(|_| anyhow::anyhow!("invalid native material"))?;
        value.validate(intent)?;
        Ok(value)
    }

    pub fn validate(&self, intent: &Request) -> Result<()> {
        ensure!(
            self.version == 1
                && self.context.is_object()
                && serde_json::to_vec(&self.context)?.len() <= 64 * 1024,
            "invalid native capture context"
        );
        self.request.validate()?;
        intent.validate_resolution(&self.request)?;
        self.source.validate(&self.request)?;
        if let Some(capsule) = &self.source.capsule {
            ensure!(
                self.context
                    .get("git_context_digest")
                    .and_then(serde_json::Value::as_str)
                    == Some(capsule.digest()?.as_str()),
                "native checkout capsule differs"
            );
        } else if let Some(git) = &self.source.git_context {
            ensure!(
                self.context
                    .get("git_context_digest")
                    .and_then(serde_json::Value::as_str)
                    == Some(git.digest()?.as_str()),
                "native capture Git context differs"
            );
        } else {
            ensure!(
                self.context
                    .get("git_context_digest")
                    .is_none_or(serde_json::Value::is_null),
                "native capture Git context missing"
            );
        }
        super::preparation::source::encoding::require_size(
            self,
            super::preparation::source::MAX_MATERIAL_BYTES,
        )?;
        Ok(())
    }
}

/// Same data lane, but no caller-side source effects. The original worker reads
/// the existing private parent as its authenticated local principal after admission.
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Capture {
    pub version: u32,
    pub capture: bool,
    pub request_digest: String,
}

impl Capture {
    pub fn validate(&self, intent: &Request) -> Result<()> {
        intent.validate()?;
        ensure!(
            self.version == 1
                && self.capture
                && self.request_digest == intent.digest()?
                && intent.bootstrap_digest.is_some()
                && intent.caller_digest.is_some()
                && intent.controller == intent.builder
                && intent.run_id.len() == 32
                && intent
                    .run_id
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
            "local capture requires the original same-node bootstrap admission"
        );
        Ok(())
    }
}

#[derive(Deserialize, Serialize)]
#[serde(untagged)]
pub enum Delivery {
    Captured(Box<Material>),
    /// Distinct installed remote data lane. Structural decoding is not sender
    /// authorization: receiver must independently match the dedicated input UID.
    RemoteCaptured {
        remote: Box<Material>,
    },
    LocalCapture(Capture),
    /// Configured repository + exact revision + optional staged patch. No caller
    /// filesystem/profile image; checkout and resolution stay in this worker.
    Repository {
        recipe: RepositoryRecipe,
    },
}

impl Delivery {
    pub fn decode(bytes: &[u8], intent: &Request) -> Result<Self> {
        ensure!(
            bytes.len() <= super::preparation::source::MAX_MATERIAL_BYTES,
            "native delivery exceeds bound"
        );
        let value: Self = serde_json::from_slice(bytes)
            .map_err(|_| anyhow::anyhow!("invalid native delivery"))?;
        match &value {
            Self::Captured(value) => {
                ensure!(
                    intent.bootstrap_digest.is_none(),
                    "installed native capture cannot be replaced by supplied material"
                );
                value.validate(intent)?;
            }
            Self::RemoteCaptured { remote } => {
                ensure!(
                    intent.bootstrap_digest.is_some()
                        && intent.caller_digest.is_some()
                        && intent.controller != intent.builder
                        && remote.source.capsule.is_some(),
                    "remote capture requires an installed independent caller capsule"
                );
                remote.validate(intent)?;
            }
            Self::LocalCapture(value) => value.validate(intent)?,
            Self::Repository { recipe } => recipe.validate(intent)?,
        }
        Ok(value)
    }
}

/// Ordinary CI source contract. `source_root` is a logical base for CLI paths,
/// never a path the builder may read from the caller's filesystem.
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RepositoryRecipe {
    pub request_digest: String,
    pub source_root: std::path::PathBuf,
    pub source: super::request::Source,
    pub patch: Option<String>,
}

impl RepositoryRecipe {
    pub fn validate(&self, intent: &Request) -> Result<()> {
        intent.validate()?;
        self.source.validate()?;
        ensure!(
            self.request_digest == intent.digest()?
                && intent.bootstrap_digest.is_none()
                && intent.caller_digest.is_some()
                && matches!(intent.action, BuildAction::Build | BuildAction::Deploy)
                && self.source.base_revision == self.source.revision
                && self.source.tree_digest.is_none(),
            "configured source recipe differs from native admission"
        );
        ensure!(
            self.source_root.is_absolute()
                && self.source_root.as_os_str().len() <= 4096
                && self.source_root.components().all(|part| matches!(
                    part,
                    std::path::Component::RootDir | std::path::Component::Normal(_)
                )),
            "invalid logical source root"
        );
        match (&self.patch, &self.source.patch_digest) {
            (Some(bytes), Some(hash)) => ensure!(
                digest_bytes(&super::preparation::source::unhex(
                    bytes,
                    super::preparation::source::MAX_PATCH_BYTES
                )?) == *hash,
                "configured source patch differs"
            ),
            (None, None) => {}
            _ => anyhow::bail!("configured source patch presence differs"),
        }
        Ok(())
    }
}

/// Original caller directory identity, not a source-discovery instruction. It
/// is captured in the operator view and may be projected only with the bound
/// preparation/artifact for DevBuild result rooting.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CallerRepository {
    pub path: std::path::PathBuf,
    pub device: u64,
    pub inode: u64,
}

impl CallerRepository {
    pub fn validate(&self) -> Result<()> {
        super::preparation::capsule::absolute(&self.path)?;
        ensure!(self.inode != 0, "invalid captured repository identity");
        Ok(())
    }

    pub fn validate_for(&self, request: &BuildRequest) -> Result<()> {
        self.validate()?;
        ensure!(
            request.evaluation.action == BuildAction::DevBuild
                && request
                    .parent
                    .as_ref()
                    .is_some_and(|parent| parent.bootstrap_digest.is_some()
                        && parent.caller_digest.is_some()),
            "repository destination lacks original DevBuild admission"
        );
        Ok(())
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureInput {
    pub intent: Request,
    pub delivery_digest: String,
    pub budget_millis: u64,
    pub roots: Vec<std::path::PathBuf>,
    pub limits: super::private_tree::Limits,
    pub nar_configuration: std::path::PathBuf,
    pub runtime_closure: std::path::PathBuf,
}

impl CaptureInput {
    pub fn validate(&self) -> Result<()> {
        self.intent.validate()?;
        self.limits.validate()?;
        super::daemon::store_path(&self.nar_configuration)?;
        super::daemon::store_path(&self.runtime_closure)?;
        digest(&self.delivery_digest)?;
        ensure!(
            !self.roots.is_empty()
                && self.roots.len() <= 16
                && self.roots.iter().all(|path| path.is_absolute()
                    && path.components().count() > 2
                    && path.components().all(|part| matches!(
                        part,
                        std::path::Component::RootDir | std::path::Component::Normal(_)
                    ))),
            "invalid installed capture roots"
        );
        ensure!(
            self.budget_millis > 0
                && self.budget_millis <= self.intent.deadlines.runtime_seconds.saturating_mul(1000)
                && serde_json::to_vec(self)?.len() <= 32 * 1024,
            "invalid capture helper budget/input"
        );
        if self.intent.controller == self.intent.builder {
            Capture {
                version: 1,
                capture: true,
                request_digest: self.intent.digest()?,
            }
            .validate(&self.intent)
        } else {
            ensure!(
                self.intent.bootstrap_digest.is_some() && self.intent.caller_digest.is_some(),
                "remote capture lacks installed caller binding"
            );
            Ok(())
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Validation {
    pub request: BuildRequest,
    pub context: serde_json::Value,
}

impl Validation {
    /// Narrow projection of already-captured metadata. The artifact producer
    /// still binds this validation to its request and prepared-input digest.
    pub fn caller_repository(&self) -> Result<Option<CallerRepository>> {
        self.validate()?;
        let repository: Option<CallerRepository> = self
            .context
            .get("caller_repository")
            .cloned()
            .map(serde_json::from_value)
            .transpose()?
            .flatten();
        if let Some(repository) = &repository {
            repository.validate_for(&self.request)?;
            ensure!(
                repository.path.to_str()
                    == self
                        .context
                        .get("source_root")
                        .and_then(serde_json::Value::as_str),
                "captured repository path differs"
            );
        }
        Ok(repository)
    }

    pub fn validate(&self) -> Result<()> {
        self.request.validate()?;
        ensure!(
            self.request.parent.is_some()
                && self.context.is_object()
                && serde_json::to_vec(self)?.len() <= 128 * 1024,
            "invalid native resolution validation"
        );
        Ok(())
    }
}
