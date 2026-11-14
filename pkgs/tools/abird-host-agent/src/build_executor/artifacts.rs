//! Native build receipts and non-realizing verification. No receipt here grants
//! settlement or release. The root worker seals native writers before calling
//! the verifier, then retains this manifest until authenticated handoff/cleanup.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::PathBuf;
use std::process::Command;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::journal::Journal;
use super::preparation::Preparation;
use super::request::{BuildRequest, store_path};
use super::{ExecutionHandle, Ownership, daemon, digest};
use crate::sha256::digest_bytes;

pub(super) const MAX_BYTES: usize = 16 * 1024 * 1024;
pub const PAGE_BYTES: usize = 8192;
const MAX_PATHS: usize = 32768;
const MAX_REFERENCES: usize = 131072;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Built {
    #[serde(rename = "drvPath")]
    pub derivation: String,
    pub outputs: BTreeMap<String, String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NativeBuilt {
    #[serde(rename = "drvPath")]
    derivation: String,
    outputs: BTreeMap<String, String>,
    #[serde(rename = "startTime")]
    _start_time: Option<u64>,
    #[serde(rename = "stopTime")]
    _stop_time: Option<u64>,
    #[serde(rename = "cpuUser")]
    _cpu_user: Option<f64>,
    #[serde(rename = "cpuSystem")]
    _cpu_system: Option<f64>,
}

/// Only pinned native JSON fields affecting the closure/trust witness. Native
/// metadata may contain additional informational fields; null is never a path.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(super) struct PathInfo {
    version: u32,
    #[serde(rename = "storeDir")]
    store_dir: String,
    #[serde(rename = "narHash")]
    nar_hash: String,
    #[serde(rename = "narSize")]
    nar_size: u64,
    references: BTreeSet<String>,
    signatures: BTreeSet<String>,
    ca: Option<String>,
    ultimate: bool,
}

impl PathInfo {
    fn validate(&self) -> Result<()> {
        ensure!(
            self.version == 1 && self.store_dir == "/nix/store" && self.nar_size > 0,
            "native path metadata differs"
        );
        let hash = self
            .nar_hash
            .strip_prefix("sha256-")
            .context("expected native SHA256 NAR hash")?;
        ensure!(
            hash.len() == 44
                && hash.ends_with('=')
                && hash[..43]
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"+/".contains(&byte)),
            "invalid native NAR hash"
        );
        ensure!(
            self.signatures.len() <= 64 && self.ca.as_ref().is_none_or(|value| value.len() <= 256),
            "native trust metadata exceeds bound"
        );
        for signature in &self.signatures {
            ensure!(
                !signature.is_empty()
                    && signature.len() <= 256
                    && signature.bytes().all(|byte| byte.is_ascii_graphic()),
                "invalid native signature metadata"
            );
        }
        for reference in &self.references {
            store_path(reference)?;
        }
        Ok(())
    }
}

/// Public projection of one verified artifact, excluding caller environment,
/// Git configuration and source credentials. Decoding does not acquire paths,
/// verify signatures, retain consumer roots or acknowledge delivery.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ArtifactDelivery {
    version: u32,
    pub ownership: Ownership,
    pub artifacts: super::ArtifactReceipt,
    pub prepared: super::preparation::PreparedInputs,
    built: Vec<Built>,
    paths: BTreeMap<String, PathInfo>,
}

#[derive(Serialize)]
struct DeliveryHeader<'a> {
    version: u32,
    ownership: &'a Ownership,
    artifacts: &'a super::ArtifactReceipt,
    prepared: &'a super::preparation::PreparedInputs,
}

pub(super) fn delivery_prefix(
    ownership: &Ownership,
    artifacts: &super::ArtifactReceipt,
    prepared: &super::preparation::PreparedInputs,
) -> Result<Vec<u8>> {
    let mut bytes = serde_json::to_vec(&DeliveryHeader {
        version: 1,
        ownership,
        artifacts,
        prepared,
    })?;
    ensure!(
        bytes.pop() == Some(b'}'),
        "artifact header encoding differs"
    );
    Ok(bytes)
}

impl ArtifactDelivery {
    pub fn encode(&self) -> Result<Vec<u8>> {
        let bytes = serde_json::to_vec(self)?;
        ensure!(bytes.len() <= MAX_BYTES, "artifact delivery exceeds bound");
        Ok(bytes)
    }

    pub fn decode(
        bytes: &[u8],
        ownership: &Ownership,
        artifacts: &super::ArtifactReceipt,
    ) -> Result<Self> {
        ensure!(bytes.len() <= MAX_BYTES, "artifact delivery exceeds bound");
        let result: Self = serde_json::from_slice(bytes)?;
        ensure!(
            serde_json::to_vec(&result)? == bytes,
            "noncanonical artifact delivery"
        );
        ownership.validate(&ownership.attempt_id)?;
        artifacts.validate(&artifacts.spec_digest)?;
        ensure!(
            result.version == 1
                && result.ownership == *ownership
                && result.artifacts == *artifacts
                && result.prepared.attempt_id == ownership.attempt_id
                && result.prepared.spec_digest == artifacts.spec_digest
                && result.prepared.digest()? == artifacts.preparation_digest,
            "artifact delivery binding differs"
        );
        validate_built(
            &result.built,
            &Preparation {
                digest: artifacts.preparation_digest.clone(),
                inputs: result.prepared.clone(),
            },
        )?;
        validate_paths(&result.paths)?;
        complete_closure(&result.outputs(), &result.paths)?;
        Ok(result)
    }

    pub fn outputs(&self) -> Vec<String> {
        outputs(&self.built)
    }

    pub fn host_outputs(&self, host: &str) -> Result<BTreeMap<String, String>> {
        let target = self
            .prepared
            .targets
            .iter()
            .find(|target| target.target.host == host)
            .context("host has no prepared build")?;
        let built = self
            .built
            .iter()
            .find(|built| built.derivation == target.derivation)
            .context("host build receipt missing")?;
        target
            .target
            .outputs
            .iter()
            .map(|output| {
                Ok((
                    output.clone(),
                    built
                        .outputs
                        .get(output)
                        .context("host output missing")?
                        .clone(),
                ))
            })
            .collect()
    }

    /// Content/closure comparison after independent native signature and NAR
    /// verification. Signature sets and ultimate flags may differ by store;
    /// neither is evidence that this method itself performed verification.
    pub fn compare_acquired(&self, bytes: &[u8]) -> Result<String> {
        let observed = decode_paths(bytes)?;
        ensure!(
            observed.keys().eq(self.paths.keys()),
            "acquired closure coverage differs"
        );
        for (path, expected) in &self.paths {
            let actual = &observed[path];
            ensure!(
                actual.nar_hash == expected.nar_hash
                    && actual.nar_size == expected.nar_size
                    && actual.references == expected.references
                    && actual.ca == expected.ca,
                "acquired closure content differs"
            );
        }
        let mut witness = b"abird-owned-consumer-content-v1\n".to_vec();
        witness.extend(serde_json::to_vec(&self.artifacts)?);
        witness.extend(serde_json::to_vec(&observed)?);
        Ok(digest_bytes(&witness))
    }
}

/// One bounded page from the original artifact inode, not a recreated export.
#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ArtifactPage {
    pub attempt_id: String,
    pub artifact_digest: String,
    pub projection_digest: String,
    pub offset: u64,
    pub total: u64,
    pub bytes: Vec<u8>,
}

impl std::fmt::Debug for ArtifactPage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ArtifactPage")
            .field("attempt_id", &self.attempt_id)
            .field("offset", &self.offset)
            .field("total", &self.total)
            .field("bytes", &self.bytes.len())
            .finish_non_exhaustive()
    }
}

impl ArtifactPage {
    pub fn validate(&self) -> Result<()> {
        digest(&self.attempt_id)?;
        digest(&self.artifact_digest)?;
        digest(&self.projection_digest)?;
        ensure!(
            self.total > 0
                && self.total <= MAX_BYTES as u64
                && self.offset < self.total
                && self.bytes.len() as u64 == (self.total - self.offset).min(PAGE_BYTES as u64),
            "invalid artifact page"
        );
        Ok(())
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct SourceContext {
    pub input: super::preparation::worker::Input,
    pub consumed: super::preparation::worker::Consumption,
    pub observation: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub native_capture: Option<super::native_intent::Validation>,
    // Last field: private planning span ends immediately before the public suffix.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub planning: Option<super::preparation::worker::Planning>,
}

impl SourceContext {
    fn digest(&self) -> Result<String> {
        self.input.validate()?;
        digest(&self.observation)?;
        match (&self.input.request.parent, &self.native_capture) {
            (Some(_), Some(capture)) => {
                capture.validate()?;
                ensure!(
                    capture.request == self.input.request
                        && capture.caller_repository()? == self.input.caller_repository,
                    "native capture differs from consumed request/destination"
                );
            }
            (None, None) => {}
            _ => anyhow::bail!("native capture context missing or unexpected"),
        }
        let mut bytes = b"abird-owned-native-context-v5\n".to_vec();
        bytes.extend(serde_json::to_vec(self)?);
        Ok(digest_bytes(&bytes))
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Manifest {
    version: u32,
    handle: ExecutionHandle,
    native: ExecutionHandle,
    spec_digest: String,
    preparation_digest: String,
    source_context_digest: String,
    source_context: SourceContext,
    built: Vec<Built>,
    paths: BTreeMap<String, PathInfo>,
}

fn expected(prepared: &Preparation) -> BTreeMap<String, BTreeSet<String>> {
    let mut expected: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for target in &prepared.inputs.targets {
        expected
            .entry(target.derivation.clone())
            .or_default()
            .extend(target.target.outputs.iter().cloned());
    }
    expected
}

pub(super) fn installables(prepared: &Preparation) -> Vec<String> {
    expected(prepared)
        .into_iter()
        .map(|(derivation, outputs)| {
            format!(
                "{derivation}^{}",
                outputs.into_iter().collect::<Vec<_>>().join(",")
            )
        })
        .collect()
}

pub(super) fn decode_built(bytes: &[u8], prepared: &Preparation) -> Result<Vec<Built>> {
    ensure!(
        bytes.len() <= 1024 * 1024,
        "native build receipt exceeds bound"
    );
    let native: Vec<NativeBuilt> =
        serde_json::from_slice(bytes).context("invalid native build receipt")?;
    let built: Vec<Built> = native
        .into_iter()
        .map(|value| Built {
            derivation: value.derivation,
            outputs: value.outputs,
        })
        .collect();
    validate_built(&built, prepared)?;
    Ok(built)
}

fn validate_built(built: &[Built], prepared: &Preparation) -> Result<()> {
    let expected = expected(prepared);
    ensure!(
        built.len() == expected.len(),
        "native build receipt coverage differs"
    );
    let mut seen = BTreeSet::new();
    for result in built {
        ensure!(
            seen.insert(&result.derivation),
            "duplicate native build receipt"
        );
        let outputs = expected
            .get(&result.derivation)
            .context("unrequested native derivation")?;
        ensure!(
            result.outputs.keys().eq(outputs.iter()),
            "native output coverage differs"
        );
        for path in result.outputs.values() {
            store_path(path)?;
        }
    }
    Ok(())
}

pub(super) fn outputs(built: &[Built]) -> Vec<String> {
    built
        .iter()
        .flat_map(|item| item.outputs.values().cloned())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn decode_paths(bytes: &[u8]) -> Result<BTreeMap<String, PathInfo>> {
    ensure!(
        bytes.len() <= MAX_BYTES,
        "native closure metadata exceeds bound"
    );
    // Typed values reject null even when path-info exits0 for an unknown path.
    let paths: BTreeMap<String, PathInfo> =
        serde_json::from_slice(bytes).context("invalid native closure metadata")?;
    validate_paths(&paths)?;
    Ok(paths)
}

fn validate_paths(paths: &BTreeMap<String, PathInfo>) -> Result<()> {
    ensure!(
        paths.len() <= MAX_PATHS,
        "native closure path count exceeds bound"
    );
    let mut references = 0usize;
    for (path, info) in paths {
        store_path(path)?;
        info.validate()?;
        references = references
            .checked_add(info.references.len())
            .context("native closure size overflow")?;
        ensure!(
            references <= MAX_REFERENCES,
            "native closure references exceed bound"
        );
    }
    Ok(())
}

fn complete_closure(roots: &[String], paths: &BTreeMap<String, PathInfo>) -> Result<()> {
    let mut pending: Vec<&str> = roots.iter().map(String::as_str).collect();
    let mut seen = BTreeSet::new();
    while let Some(path) = pending.pop() {
        if !seen.insert(path) {
            continue;
        }
        let info = paths.get(path).context("native closure is incomplete")?;
        pending.extend(info.references.iter().map(String::as_str));
    }
    ensure!(
        seen.len() == paths.len(),
        "native closure contains unrelated paths"
    );
    Ok(())
}

impl Manifest {
    pub(super) fn validate(&self, request: &BuildRequest, prepared: &Preparation) -> Result<()> {
        prepared.validate(request)?;
        self.handle.validate(&request.attempt_id()?)?;
        self.native.validate(&request.attempt_id()?)?;
        ensure!(
            self.version == 3
                && self.native.ownership == self.handle.ownership
                && self.spec_digest == request.digest()?
                && self.preparation_digest == prepared.digest,
            "artifact manifest binding differs"
        );
        ensure!(
            self.source_context_digest == self.source_context.digest()?
                && self.source_context.input.request == *request
                && self.source_context.input.source.path == prepared.inputs.source_path
                && self.source_context.input.source.nar_digest == prepared.inputs.tree_digest
                && self.source_context.input.context_sources() == prepared.inputs.context_sources,
            "artifact source context differs"
        );
        self.source_context
            .consumed
            .validate(&self.source_context.input, &prepared.inputs)?;
        ensure!(
            self.source_context.planning.is_some() == prepared.inputs.planning_digest.is_some(),
            "artifact planning presence differs"
        );
        if let Some(planning) = &self.source_context.planning {
            ensure!(
                &planning.request == request,
                "artifact resolved request differs"
            );
            planning.validate_consumption(&prepared.inputs, &self.source_context.consumed)?;
        }
        validate_built(&self.built, prepared)?;
        ensure!(
            self.paths.len() <= MAX_PATHS,
            "artifact closure exceeds bound"
        );
        let mut references = 0usize;
        for (path, info) in &self.paths {
            store_path(path)?;
            info.validate()?;
            references = references
                .checked_add(info.references.len())
                .context("artifact reference overflow")?;
            ensure!(
                references <= MAX_REFERENCES,
                "artifact references exceed bound"
            );
        }
        complete_closure(&outputs(&self.built), &self.paths)?;
        Ok(())
    }

    pub(super) fn encode(&self) -> Result<Vec<u8>> {
        let bytes = serde_json::to_vec(self)?;
        ensure!(
            bytes.len() <= MAX_BYTES,
            "artifact manifest exceeds reservation"
        );
        Ok(bytes)
    }
}

pub(super) struct Unverified {
    pub native: ExecutionHandle,
    pub built: Vec<Built>,
    pub source_context: SourceContext,
}

/// Only fixed native commands; the caller supplies the admitted credentialed
/// runner and original deadline. Every callback must settle its producer stage.
/// No eval/build/repair/substitution fallback is used to resolve a missing output.
pub(super) fn verify(
    policy: &daemon::Policy,
    request: &BuildRequest,
    prepared: &Preparation,
    handle: &ExecutionHandle,
    candidate: Unverified,
    mut execute: impl FnMut(&mut Command) -> Result<Vec<u8>>,
) -> Result<Manifest> {
    let Unverified {
        native,
        built,
        source_context,
    } = candidate;
    prepared.validate(request)?;
    source_context
        .consumed
        .validate(&source_context.input, &prepared.inputs)?;
    validate_built(&built, prepared)?;
    for result in &built {
        for (output, expected) in &result.outputs {
            let mut command = policy.native_client()?;
            command
                .args(["path-info", "--json", "--json-format", "1", "--"])
                .arg(format!("{}^{output}", result.derivation));
            let paths = decode_paths(&execute(&mut command)?)?;
            ensure!(
                paths.len() == 1 && paths.contains_key(expected),
                "native derivation/output mapping differs"
            );
        }
    }
    let roots = outputs(&built);
    // An all-skipped native plan must not accidentally turn an empty CLI argv
    // into the current flake/default installable or a whole-store operation.
    let paths = if roots.is_empty() {
        BTreeMap::new()
    } else {
        let query = || -> Result<Command> {
            let mut command = policy.native_client()?;
            command
                .args([
                    "path-info",
                    "--recursive",
                    "--json",
                    "--json-format",
                    "1",
                    "--",
                ])
                .args(&roots);
            Ok(command)
        };
        let before = decode_paths(&execute(&mut query()?)?)?;
        complete_closure(&roots, &before)?;
        let mut verify = policy.native_client()?;
        verify
            .args(["store", "verify", "--recursive", "--sigs-needed", "1", "--"])
            .args(&roots);
        // Native verification reads actual NARs and requires ordinary trusted
        // signatures (or upstream content-addressed proof), not local ultimate.
        // Hash/metadata equality by itself does not replace this successful call.
        execute(&mut verify)?;
        let after = decode_paths(&execute(&mut query()?)?)?;
        ensure!(
            before == after,
            "native metadata changed during verification"
        );
        after
    };
    let source_context_digest = source_context.digest()?;
    let result = Manifest {
        version: 3,
        handle: handle.clone(),
        native,
        spec_digest: request.digest()?,
        preparation_digest: prepared.digest.clone(),
        source_context_digest,
        source_context,
        built,
        paths,
    };
    result.validate(request, prepared)?;
    Ok(result)
}

fn path(journal: &Journal, owner: &Ownership) -> Result<PathBuf> {
    digest(&owner.attempt_id)?;
    Ok(journal
        .authority_root()
        .join(format!("artifacts-{}.json", owner.attempt_id)))
}

/// Durable intent precedes exclusive publication. Uncertain creation is never
/// retried or recreated; the original row and partial data remain cleanup-owned.
pub(super) fn publish(
    journal: &Journal,
    owner: &Ownership,
    manifest: &Manifest,
    prepared: &Preparation,
    roots_digest: &str,
) -> Result<super::ArtifactReceipt> {
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "artifact publication requires root"
    );
    super::workload::require_client_placement(owner)?;
    ensure!(
        &manifest.handle.ownership == owner,
        "artifact publication ownership differs"
    );
    let bytes = manifest.encode()?;
    let hash = digest_bytes(&bytes);
    let receipt = super::ArtifactReceipt {
        spec_digest: manifest.spec_digest.clone(),
        preparation_digest: manifest.preparation_digest.clone(),
        closure_digest: hash.clone(),
        roots_digest: roots_digest.to_owned(),
    };
    receipt.validate(&prepared.inputs.spec_digest)?;
    ensure!(
        prepared.digest == receipt.preparation_digest,
        "artifact preparation differs"
    );
    // The final two fields are already in the original private manifest. Record
    // their exact byte range, never export source_context or materialize a copy.
    let mut suffix = b",\"built\":".to_vec();
    suffix.extend(serde_json::to_vec(&manifest.built)?);
    suffix.extend(b",\"paths\":");
    suffix.extend(serde_json::to_vec(&manifest.paths)?);
    suffix.push(b'}');
    ensure!(
        bytes.ends_with(&suffix),
        "artifact projection layout differs"
    );
    let prefix = delivery_prefix(owner, &receipt, &prepared.inputs)?;
    let projection = super::journal::artifacts::Projection {
        digest: crate::sha256::digest_reader(prefix.as_slice().chain(suffix.as_slice()))?,
        offset: (bytes.len() - suffix.len()) as u64,
        bytes: (prefix.len() + suffix.len()) as u64,
        planning: planning_range(
            &bytes,
            bytes.len() - suffix.len(),
            manifest.source_context.planning.as_ref(),
        )?,
    };
    projection.validate(bytes.len() as u64)?;
    journal.begin_artifact(owner, &hash, bytes.len() as u64, daemon::now()?)?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path(journal, owner)?)?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    File::open(journal.authority_root())?.sync_all()?;
    let meta = file.metadata()?;
    journal.bind_artifact(owner, meta.dev(), meta.ino(), daemon::now()?)?;
    journal.bind_artifact_projection(owner, projection, daemon::now()?)?;
    Ok(receipt)
}

pub(super) fn read(journal: &Journal, owner: &Ownership) -> Result<Vec<u8>> {
    let record = journal.artifact(owner)?;
    ensure!(!record.retired, "artifact data retired");
    let expected = record
        .file
        .as_ref()
        .context("artifact publication unconfirmed")?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path(journal, owner)?)?;
    let meta = file.metadata()?;
    ensure!(
        meta.is_file()
            && meta.uid() == 0
            && meta.mode() & 0o7777 == 0o600
            && meta.nlink() == 1
            && meta.dev() == expected.device
            && meta.ino() == expected.inode
            && meta.len() == record.bytes,
        "artifact publication replaced"
    );
    let mut bytes = Vec::new();
    file.take(MAX_BYTES as u64 + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 == record.bytes && digest_bytes(&bytes) == record.digest,
        "artifact publication damaged"
    );
    Ok(bytes)
}

fn planning_range(
    bytes: &[u8],
    public_offset: usize,
    planning: Option<&super::preparation::worker::Planning>,
) -> Result<Option<super::journal::artifacts::PlanningRange>> {
    let Some(planning) = planning else {
        return Ok(None);
    };
    let encoded = serde_json::to_vec(planning)?;
    ensure!(
        encoded.len() <= super::preparation::MAX_PREPARED_BYTES,
        "private planning exceeds bound"
    );
    let offset = public_offset
        .checked_sub(encoded.len() + 1)
        .context("planning range underflow")?;
    let field = b",\"planning\":";
    let start = offset
        .checked_sub(field.len())
        .context("planning field missing")?;
    ensure!(
        bytes.get(start..offset) == Some(field.as_slice())
            && bytes.get(offset..public_offset - 1) == Some(encoded.as_slice())
            && bytes.get(public_offset - 1) == Some(&b'}'),
        "private planning layout differs"
    );
    Ok(Some(super::journal::artifacts::PlanningRange {
        offset: offset as u64,
        bytes: encoded.len() as u64,
    }))
}

pub(in crate::build_executor) enum Delivery {
    Public(u64),
    Planning(u64),
}

pub(super) fn read_page(
    directory: &File,
    owner: &Ownership,
    receipt: &super::ArtifactReceipt,
    prepared: &super::preparation::PreparedInputs,
    record: &super::journal::artifacts::Publication,
    delivery: Delivery,
) -> Result<ArtifactPage> {
    ensure!(
        !record.retired && record.digest == receipt.closure_digest,
        "artifact data unavailable"
    );
    let expected = record
        .file
        .as_ref()
        .context("artifact publication unconfirmed")?;
    let projection = record
        .projection
        .as_ref()
        .context("artifact projection unavailable")?;
    projection.validate(record.bytes)?;
    let (prefix, source_offset, total, projection_digest, offset) = match delivery {
        Delivery::Public(offset) => {
            let prefix = delivery_prefix(owner, receipt, prepared)?;
            ensure!(
                projection.bytes == prefix.len() as u64 + record.bytes - projection.offset,
                "artifact projection range differs"
            );
            (
                prefix,
                projection.offset,
                projection.bytes,
                projection.digest.clone(),
                offset,
            )
        }
        Delivery::Planning(offset) => {
            let range = projection
                .planning
                .as_ref()
                .context("private planning range missing")?;
            let digest = prepared
                .planning_digest
                .clone()
                .context("private planning binding missing")?;
            (Vec::new(), range.offset, range.bytes, digest, offset)
        }
    };
    digest(&owner.attempt_id)?;
    let name = std::ffi::CString::new(format!("artifacts-{}.json", owner.attempt_id))?;
    let open = |flags| -> Result<File> {
        let fd = unsafe {
            libc::openat(
                directory.as_raw_fd(),
                name.as_ptr(),
                flags | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    };
    let check = |meta: &fs::Metadata| -> Result<()> {
        ensure!(
            meta.is_file()
                && meta.uid() == 0
                && meta.mode() & 0o7777 == 0o600
                && meta.nlink() == 1
                && meta.dev() == expected.device
                && meta.ino() == expected.inode
                && meta.len() == record.bytes,
            "artifact publication replaced"
        );
        Ok(())
    };
    let file = open(libc::O_RDONLY)?;
    let before = file.metadata()?;
    check(&before)?;
    let bytes = range_page(&file, &prefix, source_offset, total, offset)?;
    let after = open(libc::O_PATH)?.metadata()?;
    check(&after)?;
    ensure!(
        (
            before.ctime(),
            before.ctime_nsec(),
            before.mtime(),
            before.mtime_nsec()
        ) == (
            after.ctime(),
            after.ctime_nsec(),
            after.mtime(),
            after.mtime_nsec()
        ),
        "artifact changed during delivery"
    );
    let result = ArtifactPage {
        attempt_id: owner.attempt_id.clone(),
        artifact_digest: receipt.closure_digest.clone(),
        projection_digest,
        offset,
        total,
        bytes,
    };
    result.validate()?;
    Ok(result)
}

fn range_page(
    file: &File,
    prefix: &[u8],
    source_offset: u64,
    total: u64,
    offset: u64,
) -> Result<Vec<u8>> {
    ensure!(
        offset < total && prefix.len() as u64 <= total,
        "artifact page outside projection"
    );
    let count = (total - offset).min(PAGE_BYTES as u64) as usize;
    let mut bytes = Vec::with_capacity(count);
    if offset < prefix.len() as u64 {
        let start = offset as usize;
        let end = (start + count).min(prefix.len());
        bytes.extend_from_slice(&prefix[start..end]);
    }
    let copied = bytes.len();
    if copied < count {
        bytes.resize(count, 0);
        let start = offset.max(prefix.len() as u64) - prefix.len() as u64;
        file.read_exact_at(
            &mut bytes[copied..],
            source_offset
                .checked_add(start)
                .context("page offset overflow")?,
        )?;
    }
    Ok(bytes)
}

pub(super) fn retire(
    journal: &Journal,
    owner: &Ownership,
    mut active: impl FnMut() -> Result<()>,
) -> Result<()> {
    journal.artifact_releasable(owner)?;
    let record = journal.artifact(owner)?;
    ensure!(!record.retired, "artifact retirement already consumed");
    super::retirement::file::remove(
        &path(journal, owner)?,
        record.file.as_ref(),
        record.bytes,
        &mut active,
    )?;
    journal.retire_artifact(owner, daemon::now()?)
}

pub(super) fn retired(
    journal: &Journal,
    owner: &Ownership,
    record: &super::journal::artifacts::Publication,
) -> Result<bool> {
    if !record.retired {
        return Ok(false);
    }
    match fs::symlink_metadata(path(journal, owner)?) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
        Ok(_) => anyhow::bail!("retired artifact data reappeared"),
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn delivery() -> ArtifactDelivery {
        let request = crate::build_executor::journal::tests::request("delivery");
        let prepared = crate::build_executor::journal::tests::inputs(&request);
        let output = format!("/nix/store/{}-output", "0".repeat(32));
        let dependency = format!("/nix/store/{}-dependency", "1".repeat(32));
        let info = PathInfo {
            version: 1,
            store_dir: "/nix/store".into(),
            nar_hash: format!("sha256-{}=", "A".repeat(43)),
            nar_size: 123,
            references: BTreeSet::new(),
            signatures: BTreeSet::new(),
            ca: None,
            ultimate: true,
        };
        let mut root = info.clone();
        root.references.insert(dependency.clone());
        ArtifactDelivery {
            version: 1,
            ownership: Ownership {
                executor_version: 1,
                builder_id: "ci".into(),
                store_id: "ci-store".into(),
                attempt_id: request.attempt_id().unwrap(),
                pool_epoch: 1.try_into().unwrap(),
                boot_id: "boot".into(),
            },
            artifacts: super::super::ArtifactReceipt {
                spec_digest: request.digest().unwrap(),
                preparation_digest: prepared.digest().unwrap(),
                closure_digest: "e".repeat(64),
                roots_digest: "f".repeat(64),
            },
            built: vec![Built {
                derivation: prepared.targets[0].derivation.clone(),
                outputs: BTreeMap::from([("out".into(), output.clone())]),
            }],
            prepared,
            paths: BTreeMap::from([(output, root), (dependency, info)]),
        }
    }

    #[test]
    fn artifact_projection_never_reads_private_prefix_and_pages_cross_the_header() {
        // Byte-range mechanics only; no native verification/root-ownership claim.
        let mut value = delivery();
        for info in value.paths.values_mut() {
            info.signatures = (0..64)
                .map(|index| format!("key-{index}:{}", "A".repeat(180)))
                .collect();
        }
        let prefix = delivery_prefix(&value.ownership, &value.artifacts, &value.prepared).unwrap();
        let encoded = serde_json::to_vec(&value).unwrap();
        assert!(encoded.len() > PAGE_BYTES * 2);
        assert!(encoded.starts_with(&prefix));
        let suffix = &encoded[prefix.len()..];
        let private = b"private-caller-credential-not-for-delivery".repeat(400);
        let mut file = tempfile::tempfile().unwrap();
        file.write_all(&private).unwrap();
        file.write_all(suffix).unwrap();
        let projection = super::super::journal::artifacts::Projection {
            digest: digest_bytes(&encoded),
            offset: private.len() as u64,
            bytes: encoded.len() as u64,
            planning: None,
        };
        projection.validate(file.metadata().unwrap().len()).unwrap();
        for start in [0, 1, prefix.len() - 1, prefix.len(), encoded.len() - 1] {
            let page = range_page(
                &file,
                &prefix,
                projection.offset,
                projection.bytes,
                start as u64,
            )
            .unwrap();
            assert_eq!(
                page,
                encoded[start..(start + PAGE_BYTES).min(encoded.len())]
            );
        }
        let mut assembled = Vec::new();
        while assembled.len() < encoded.len() {
            assembled.extend(
                range_page(
                    &file,
                    &prefix,
                    projection.offset,
                    projection.bytes,
                    assembled.len() as u64,
                )
                .unwrap(),
            );
        }
        assert_eq!(assembled, encoded);
        ArtifactDelivery::decode(&assembled, &value.ownership, &value.artifacts).unwrap();
        assert!(
            range_page(
                &file,
                &prefix,
                projection.offset,
                projection.bytes,
                projection.bytes
            )
            .is_err()
        );
        file.set_len(file.metadata().unwrap().len() - 1).unwrap();
        assert!(
            range_page(
                &file,
                &prefix,
                projection.offset,
                projection.bytes,
                projection.bytes - 1
            )
            .is_err()
        );
    }

    #[test]
    fn private_planning_range_excludes_the_rest_of_the_source_context_and_redacts_debug() {
        use super::super::preparation::worker::{Consumption, Input, Planning, Snapshot};
        let request = super::super::journal::tests::request("private-planning");
        let prepared = super::super::journal::tests::inputs(&request);
        let planning = Planning {
            version: 1,
            request: request.clone(),
            inventory: serde_json::json!({"hosts": {"app": {}}}),
            catalog: serde_json::json!(["app"]),
            selection: "{}".into(),
            activation: Default::default(),
            layers: serde_json::Value::Null,
        };
        let context = SourceContext {
            input: Input {
                version: 3,
                request,
                source: Snapshot {
                    path: prepared.source_path.clone(),
                    nar_digest: prepared.tree_digest.clone(),
                },
                protection_digest: prepared.protection_digest.clone(),
                snapshots: Default::default(),
                native_source: "/private/source".into(),
                native_info: serde_json::json!({"private": "PRIVATE-CONTEXT-MARKER"}),
                native_roots: Default::default(),
                caller_repository: None,
                native_system: "x86_64-linux".into(),
                budget_millis: 1000,
            },
            consumed: Consumption::default(),
            observation: "a".repeat(64),
            native_capture: None,
            planning: Some(planning),
        };
        let mut bytes = br#"{"source_context":"#.to_vec();
        bytes.extend(serde_json::to_vec(&context).unwrap());
        let public_offset = bytes.len();
        bytes.extend(br#","built":[],"paths":{}}"#);
        let range = planning_range(&bytes, public_offset, context.planning.as_ref())
            .unwrap()
            .unwrap();
        let encoded = serde_json::to_vec(context.planning.as_ref().unwrap()).unwrap();
        let mut file = tempfile::tempfile().unwrap();
        file.write_all(&bytes).unwrap();
        let received = range_page(&file, &[], range.offset, range.bytes, 0).unwrap();
        assert_eq!(received, encoded);
        assert!(!String::from_utf8_lossy(&received).contains("PRIVATE-CONTEXT-MARKER"));
        let page = ArtifactPage {
            attempt_id: "a".repeat(64),
            artifact_digest: "b".repeat(64),
            projection_digest: "c".repeat(64),
            offset: 0,
            total: received.len() as u64,
            bytes: received,
        };
        assert!(!format!("{page:?}").contains('['));
        let mut changed = bytes;
        changed[public_offset - 1] = b' ';
        assert!(planning_range(&changed, public_offset, context.planning.as_ref()).is_err());
    }

    #[test]
    fn acquired_metadata_must_match_every_transitive_path_not_only_the_output() {
        // Hash/metadata comparison, deliberately not a signature-verifier fixture.
        let value = delivery();
        let bytes = serde_json::to_vec(&value).unwrap();
        let accepted =
            ArtifactDelivery::decode(&bytes, &value.ownership, &value.artifacts).unwrap();
        let mut observed = value.paths.clone();
        for path in observed.values_mut() {
            path.ultimate = false;
            path.signatures.insert("new-signature".into());
        }
        accepted
            .compare_acquired(&serde_json::to_vec(&observed).unwrap())
            .unwrap();
        let dependency = observed
            .keys()
            .find(|path| path.ends_with("-dependency"))
            .unwrap()
            .clone();
        observed.get_mut(&dependency).unwrap().nar_hash = format!("sha256-{}=", "B".repeat(43));
        assert!(
            accepted
                .compare_acquired(&serde_json::to_vec(&observed).unwrap())
                .is_err()
        );
        observed.remove(&dependency);
        assert!(
            accepted
                .compare_acquired(&serde_json::to_vec(&observed).unwrap())
                .is_err()
        );
        let mut wrong = value.artifacts.clone();
        wrong.closure_digest = "c".repeat(64);
        assert!(ArtifactDelivery::decode(&bytes, &value.ownership, &wrong).is_err());
        assert!(accepted.host_outputs("missing").is_err());
        assert_eq!(accepted.host_outputs("app").unwrap().len(), 1);
    }

    #[test]
    fn artifact_pages_are_bounded_and_bound_to_the_exact_requested_receipt_and_offset() {
        use super::super::protocol::{self, Command, Reply, Request, Response};
        let page = ArtifactPage {
            attempt_id: "a".repeat(64),
            artifact_digest: "b".repeat(64),
            projection_digest: "c".repeat(64),
            offset: 0,
            total: PAGE_BYTES as u64,
            bytes: vec![255; PAGE_BYTES],
        };
        let request = Request {
            version: protocol::VERSION,
            command: Command::Artifacts {
                attempt_id: page.attempt_id.clone(),
                artifact_digest: page.artifact_digest.clone(),
                offset: 0,
            },
        };
        let response = Response {
            version: protocol::VERSION,
            reply: Reply::Artifacts { page: page.clone() },
        };
        assert!(response.encode().unwrap().len() < protocol::MAX_FRAME_BYTES);
        response.validate_for(&request).unwrap();
        for (offset, digest) in [(1, "b".repeat(64)), (0, "d".repeat(64))] {
            let wrong = Request {
                version: protocol::VERSION,
                command: Command::Artifacts {
                    attempt_id: page.attempt_id.clone(),
                    artifact_digest: digest,
                    offset,
                },
            };
            assert!(response.validate_for(&wrong).is_err());
        }
        let planning = Request {
            version: protocol::VERSION,
            command: Command::Planning {
                attempt_id: page.attempt_id.clone(),
                artifact_digest: page.artifact_digest.clone(),
                planning_digest: page.projection_digest.clone(),
                offset: 0,
            },
        };
        let private = Response {
            version: protocol::VERSION,
            reply: Reply::Planning { page: page.clone() },
        };
        private.validate_for(&planning).unwrap();
        assert!(private.validate_for(&request).is_err());
        assert!(response.validate_for(&planning).is_err());
        let wrong = Request {
            version: protocol::VERSION,
            command: Command::Planning {
                attempt_id: page.attempt_id.clone(),
                artifact_digest: page.artifact_digest.clone(),
                planning_digest: "d".repeat(64),
                offset: 0,
            },
        };
        assert!(private.validate_for(&wrong).is_err());
        let oversized = Response {
            version: protocol::VERSION,
            reply: Reply::Planning {
                page: ArtifactPage {
                    total: super::super::preparation::MAX_PREPARED_BYTES as u64 + 1,
                    ..page.clone()
                },
            },
        };
        assert!(oversized.encode().is_err());
        let mut partial = page;
        partial.bytes.pop();
        assert!(partial.validate().is_err());
    }
}
