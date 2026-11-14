//! Source material is data, never a caller-selected command/path/credential.
//! Root validates it only inside the original admitted worker lifetime.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

use super::super::request::{BuildRequest, Source};
use crate::sha256::digest_bytes;

pub mod encoding;
#[cfg(test)]
mod tests;

pub const MAX_PATCH_BYTES: usize = 4 * 1024 * 1024;
// Representation bound only. Capture/restore also enforce the installed source
// byte/entry/depth limits; this does not increase any role resource allowance.
pub const MAX_MATERIAL_BYTES: usize = 512 * 1024 * 1024;

/// Maximum encoded material for the declared source budget, not the global
/// protocol ceiling. NAR framing and timestamp/path records have finite overhead.
pub fn material_limit(limits: super::super::private_tree::Limits) -> Result<usize> {
    limits.validate()?;
    ensure!(
        limits.bytes > 0,
        "source representation requires a positive byte budget"
    );
    let limit = limits
        .bytes
        .saturating_mul(2)
        .saturating_add(u64::from(limits.entries).saturating_mul(768))
        .saturating_add((2 * MAX_PATCH_BYTES + 256 * 1024) as u64);
    Ok(usize::try_from(limit)
        .unwrap_or(usize::MAX)
        .min(MAX_MATERIAL_BYTES))
}

/// Encode protocol metadata as an object. Nix's generic JSON coercion would
/// otherwise replace the entire object with its outPath.
pub const NATIVE_METADATA_JSON: &str = r#"
encode: info:
"{" + builtins.concatStringsSep "," (map (name:
  builtins.toJSON name + ":" + encode (builtins.getAttr name info)
) (builtins.attrNames info)) + "}"
"#;

/// Hex keeps opaque Git patches/NARs lossless without UTF-8 or JSON-number-array
/// expansion. Bound the encoded message before parsing, and each decoded input.
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Material {
    pub version: u32,
    pub request_digest: String,
    pub patch: Option<String>,
    pub snapshots: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_context: Option<super::git_context::GitContext>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capsule: Option<super::capsule::Capsule>,
}

impl Material {
    pub fn decode(bytes: &[u8], request: &BuildRequest) -> Result<Self> {
        ensure!(
            bytes.len() <= MAX_MATERIAL_BYTES,
            "source material exceeds bound"
        );
        let value: Self = serde_json::from_slice(bytes)
            .map_err(|_| anyhow::anyhow!("invalid source material"))?;
        value.validate(request)?;
        Ok(value)
    }

    pub fn validate(&self, request: &BuildRequest) -> Result<()> {
        request.validate()?;
        ensure!(
            self.version == (if self.capsule.is_some() { 2 } else { 1 })
                && self.request_digest == request.digest()?,
            "source material intent differs"
        );
        encoding::require_size(self, MAX_MATERIAL_BYTES)?;
        match (&self.patch, &request.source.patch_digest) {
            (Some(bytes), Some(hash)) => ensure!(
                digest_bytes(&unhex(bytes, MAX_PATCH_BYTES)?) == *hash,
                "source patch differs"
            ),
            (None, None) => {}
            _ => anyhow::bail!("source patch presence differs"),
        }
        ensure!(
            self.snapshots
                .keys()
                .map(String::as_str)
                .collect::<BTreeSet<_>>()
                == request.evaluation.snapshot_digests(),
            "source context coverage differs"
        );
        if let Some(capsule) = &self.capsule {
            ensure!(
                self.git_context.is_none(),
                "capsule and legacy Git material overlap"
            );
            capsule.validate(request)?;
        } else {
            let captured = self
                .git_context
                .as_ref()
                .map(|git| {
                    git.external
                        .keys()
                        .map(String::as_str)
                        .collect::<BTreeSet<_>>()
                })
                .unwrap_or_default();
            ensure!(
                captured == request.evaluation.git_digests(),
                "independent native root material coverage differs"
            );
        }
        if let Some(git) = &self.git_context {
            git.validate()?;
            ensure!(
                request
                    .parent
                    .as_ref()
                    .is_some_and(|parent| parent.bootstrap_digest.is_some()
                        && parent.caller_digest.as_deref() == Some(git.caller_digest.as_str())),
                "captured Git context lacks original caller binding"
            );
        }
        for (hash, bytes) in &self.snapshots {
            ensure!(
                encoding::hex_digest(bytes, MAX_MATERIAL_BYTES / 2)? == *hash,
                "context NAR differs"
            );
        }
        Ok(())
    }
}

/// Private root-to-source-helper message. No journal/launch capability in it.
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProducerInput {
    pub version: u32,
    pub source: Source,
    pub url: String,
    pub directory: PathBuf,
    pub patch: Option<String>,
    pub budget_millis: u64,
    pub runtime_closure: PathBuf,
    pub limits: super::super::private_tree::Limits,
}

impl ProducerInput {
    pub fn validate(&self) -> Result<()> {
        self.source.validate()?;
        self.limits.validate()?;
        super::super::daemon::store_path(&self.runtime_closure)?;
        ensure!(
            self.version == 1 && self.budget_millis > 0 && self.directory.is_absolute(),
            "invalid source helper input"
        );
        repository_url(&self.url)?;
        if let Some(patch) = &self.patch {
            unhex(patch, MAX_PATCH_BYTES)?;
        }
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_MATERIAL_BYTES,
            "source helper input exceeds bound"
        );
        Ok(())
    }
}

/// Existing source producer plus the admitted native command. The configured
/// URL, directory, tools and budget come from the worker, not the sender.
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RepositoryInput {
    pub producer: ProducerInput,
    pub intent: super::super::native_intent::Request,
    pub source_root: PathBuf,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RepositoryOutput {
    pub observation: String,
    pub material: super::super::native_intent::Material,
}

impl RepositoryInput {
    pub fn validate(&self) -> Result<()> {
        self.producer.validate()?;
        self.intent.validate()?;
        ensure!(
            self.source_root.is_absolute()
                && self.source_root.as_os_str().len() <= 4096
                && self.source_root.components().all(|part| matches!(
                    part,
                    std::path::Component::RootDir | std::path::Component::Normal(_)
                )),
            "invalid logical source root"
        );
        Ok(())
    }
}

pub fn repository_url(value: &str) -> Result<()> {
    ensure!(
        value.len() <= 4096
            && !value.chars().any(char::is_control)
            && ["https://", "ssh://", "file:///"]
                .iter()
                .any(|prefix| value.starts_with(prefix)),
        "unsupported installed repository URL"
    );
    Ok(())
}

pub fn unhex(value: &str, limit: usize) -> Result<Vec<u8>> {
    ensure!(
        value.len().is_multiple_of(2) && value.len() / 2 <= limit,
        "source encoding exceeds bound"
    );
    value
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let nibble = |byte: u8| -> Result<u8> {
                match byte {
                    b'0'..=b'9' => Ok(byte - b'0'),
                    b'a'..=b'f' => Ok(byte - b'a' + 10),
                    _ => anyhow::bail!("invalid source encoding"),
                }
            };
            Ok(nibble(pair[0])? * 16 + nibble(pair[1])?)
        })
        .collect()
}
