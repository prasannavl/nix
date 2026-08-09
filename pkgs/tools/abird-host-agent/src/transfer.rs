use std::collections::{BTreeMap, BTreeSet};
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::manifest::{
    DataManifest, EntryKind, ManifestEntry, create_manifest_roots, is_exclude_protected,
    is_excluded,
};
use crate::metadata::copy_xattrs;
use crate::resource::DataRoot;
use crate::sha256::digest_bytes;

static COPY_SEQUENCE: AtomicU64 = AtomicU64::new(0);
const CAPTURE_LIMIT: usize = 256 * 1024;
const MAX_TRANSIENT_RSYNC_ATTEMPTS: usize = 3;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TransferDefinition {
    pub source: PathBuf,
    pub destination: PathBuf,
    pub rsync_program: PathBuf,
    #[serde(default)]
    pub remote_source: Option<RemoteSource>,
    #[serde(default)]
    pub remote_destination: Option<RemoteSource>,
    #[serde(default = "default_tar_program")]
    pub tar_program: PathBuf,
    #[serde(default = "default_true")]
    pub delete: bool,
    #[serde(default = "default_true")]
    pub fallback_copy: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RemoteSource {
    pub host: String,
    /// Public SSH host keys authenticated by the controller for this job.
    #[serde(default)]
    pub host_public_keys: Vec<String>,
    #[serde(default)]
    pub user: Option<String>,
    #[serde(default)]
    pub port: Option<u16>,
    #[serde(default)]
    pub identity_file: Option<PathBuf>,
    pub ssh_program: PathBuf,
    #[serde(default)]
    pub ssh_args: Vec<String>,
    #[serde(default = "default_agent_program")]
    pub agent_program: PathBuf,
    #[serde(default)]
    pub agent_prefix: Vec<String>,
    #[serde(default = "default_rsync_program")]
    pub rsync_program: PathBuf,
    #[serde(default)]
    pub rsync_prefix: Vec<String>,
    #[serde(default = "default_tar_program")]
    pub tar_program: PathBuf,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CopyEngine {
    Rsync,
    Filesystem,
    TarOverSsh,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PostCopyVerification {
    RequireMatch,
    AllowSourceDrift,
}

#[derive(Debug, Serialize)]
pub struct TransferResult {
    pub source: PathBuf,
    pub destination: PathBuf,
    pub engine: CopyEngine,
    pub source_entries: usize,
    pub source_bytes: u64,
    pub rsync_attempted: bool,
    pub rsync_attempts: usize,
    pub rsync_exit_code: Option<i32>,
    pub rsync_stdout: String,
    pub rsync_stderr: String,
    pub rsync_stdout_truncated_bytes: u64,
    pub rsync_stderr_truncated_bytes: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rsync_warning: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fallback_reason: Option<String>,
    pub source_changed_during_copy: bool,
    pub verification_deferred: bool,
    pub verification: VerificationResult,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct TransferProgress {
    pub stage: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub engine: Option<CopyEngine>,
    pub entries_completed: usize,
    pub bytes_completed: u64,
    pub total_entries: usize,
    pub total_bytes: u64,
    pub detail: String,
}

#[derive(Debug, Serialize)]
pub struct VerificationResult {
    pub matches: bool,
    pub source_digest: String,
    pub destination_digest: String,
    pub source_entries: usize,
    pub destination_entries: usize,
    pub mismatches: Vec<String>,
    pub truncated_mismatches: usize,
}

pub fn validate_transfer(transfer: &TransferDefinition) -> Result<()> {
    for (label, path) in [
        ("source", &transfer.source),
        ("destination", &transfer.destination),
        ("rsync program", &transfer.rsync_program),
    ] {
        if !path.is_absolute() {
            bail!("{label} must be absolute: {}", path.display());
        }
    }
    if transfer.source == Path::new("/") || transfer.destination == Path::new("/") {
        bail!("transfer source and destination cannot be the filesystem root");
    }
    if transfer.remote_source.is_some() && transfer.remote_destination.is_some() {
        bail!("a transfer cannot have both a remote source and remote destination");
    }
    if transfer.remote_source.is_none()
        && transfer.remote_destination.is_none()
        && (transfer.source == transfer.destination
            || transfer.source.starts_with(&transfer.destination)
            || transfer.destination.starts_with(&transfer.source))
    {
        bail!("transfer source and destination cannot overlap");
    }
    if !transfer.tar_program.is_absolute() {
        bail!("local tar program must be absolute");
    }
    for (direction, remote) in [
        ("source", transfer.remote_source.as_ref()),
        ("destination", transfer.remote_destination.as_ref()),
    ] {
        let Some(remote) = remote else { continue };
        if remote.host.trim().is_empty()
            || remote.host.starts_with('-')
            || remote.host.contains(['\0', '\r', '\n'])
        {
            bail!("remote transfer {direction} has an invalid host");
        }
        if remote.user.as_ref().is_some_and(|user| {
            user.is_empty()
                || !user
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        }) {
            bail!("remote transfer {direction} has an invalid user");
        }
        if remote.port == Some(0) {
            bail!("remote transfer {direction} port cannot be zero");
        }
        for (label, path) in [
            ("remote SSH program", &remote.ssh_program),
            ("remote agent program", &remote.agent_program),
            ("remote rsync program", &remote.rsync_program),
            ("remote tar program", &remote.tar_program),
        ] {
            if !path.is_absolute() {
                bail!("{label} must be absolute");
            }
        }
        if remote
            .identity_file
            .as_ref()
            .is_some_and(|path| !path.is_absolute())
        {
            bail!("remote transfer identity file must be absolute");
        }
        if remote
            .ssh_args
            .iter()
            .chain(&remote.agent_prefix)
            .chain(&remote.rsync_prefix)
            .any(|argument| argument.contains('\0'))
        {
            bail!("remote transfer argv cannot contain NUL");
        }
        if remote
            .host_public_keys
            .iter()
            .any(|key| key.contains(['\0', '\r', '\n']) || !key.starts_with("ssh-"))
        {
            bail!("remote transfer {direction} has an invalid public host key");
        }
    }
    Ok(())
}

pub fn transfer(transfer: &TransferDefinition) -> Result<TransferResult> {
    transfer_with_progress(transfer, |_| Ok(()))
}

pub fn transfer_with_progress(
    transfer: &TransferDefinition,
    progress: impl FnMut(&TransferProgress) -> Result<()>,
) -> Result<TransferResult> {
    transfer_with_excludes_progress(transfer, &[], progress)
}

pub fn transfer_with_excludes_progress(
    transfer: &TransferDefinition,
    excludes: &[PathBuf],
    progress: impl FnMut(&TransferProgress) -> Result<()>,
) -> Result<TransferResult> {
    transfer_with_excludes_progress_policy(
        transfer,
        excludes,
        PostCopyVerification::RequireMatch,
        progress,
    )
}

pub fn transfer_with_excludes_progress_policy(
    transfer: &TransferDefinition,
    excludes: &[PathBuf],
    verification_policy: PostCopyVerification,
    mut progress: impl FnMut(&TransferProgress) -> Result<()>,
) -> Result<TransferResult> {
    validate_transfer(transfer)?;
    if transfer.remote_source.is_none() && !transfer.source.is_dir() {
        bail!(
            "transfer source must be an existing directory: {}",
            transfer.source.display()
        );
    }
    if transfer.remote_destination.is_none() {
        fs::create_dir_all(&transfer.destination).with_context(|| {
            format!(
                "create transfer destination {}",
                transfer.destination.display()
            )
        })?;
    }
    let initial_source_manifest = source_manifest(transfer, excludes)?;
    let (source_entries, source_bytes) = manifest_stats(&initial_source_manifest)?;
    report(
        &mut progress,
        "copying",
        Some(CopyEngine::Rsync),
        0,
        0,
        source_entries,
        source_bytes,
        "starting preferred rsync engine",
    )?;

    let mut rsync_attempts = 0;
    let output = loop {
        rsync_attempts += 1;
        let output = run_rsync(
            transfer,
            excludes,
            source_entries,
            source_bytes,
            &mut progress,
        );
        let retryable = output.as_ref().is_ok_and(|output| {
            !output.success
                && is_transient_rsync_exit_code(output.exit_code)
                && rsync_attempts < MAX_TRANSIENT_RSYNC_ATTEMPTS
        });
        if !retryable {
            break output;
        }
        let output = output.expect("checked successful result");
        report(
            &mut progress,
            "copying",
            Some(CopyEngine::Rsync),
            0,
            0,
            source_entries,
            source_bytes,
            format!(
                "rsync pass {rsync_attempts} saw transient live-tree changes (exit {}); retrying an incremental pass",
                output.exit_code.expect("checked transient exit code")
            ),
        )?;
    };

    let execution = match output {
        Ok(output) if output.success => CopyExecution {
            engine: CopyEngine::Rsync,
            rsync_attempted: true,
            rsync_output: Some(output),
            rsync_warning: None,
            fallback_reason: None,
            verified_outcome: None,
        },
        Ok(output) => {
            let reason = format!(
                "rsync exited after {rsync_attempts} attempt(s) with status {:?}: {}",
                output.exit_code,
                output.stderr.trim()
            );
            report(
                &mut progress,
                "verifying",
                Some(CopyEngine::Rsync),
                source_entries,
                source_bytes,
                source_entries,
                source_bytes,
                format!("{reason}; independently verifying the rsync result before fallback"),
            )?;
            let verification = verify_copy_outcome(
                transfer,
                excludes,
                &initial_source_manifest,
                verification_policy,
            );
            match verification {
                Ok(outcome) if outcome.accepted() => CopyExecution {
                    engine: CopyEngine::Rsync,
                    rsync_attempted: true,
                    rsync_output: Some(output),
                    rsync_warning: Some(reason),
                    fallback_reason: None,
                    verified_outcome: Some(outcome),
                },
                verification => {
                    let reason = match &verification {
                        Ok(outcome) => format!(
                            "{reason}; rsync result did not verify: {}",
                            verification_summary(&outcome.verification)
                        ),
                        Err(error) => {
                            format!("{reason}; could not verify rsync result: {error:#}")
                        }
                    };
                    if !transfer.fallback_copy {
                        bail!("{reason}");
                    }
                    let engine = fallback_engine(transfer);
                    report(
                        &mut progress,
                        "copying",
                        Some(engine),
                        0,
                        0,
                        source_entries,
                        source_bytes,
                        &reason,
                    )?;
                    fallback_copy(
                        transfer,
                        excludes,
                        source_entries,
                        source_bytes,
                        &mut progress,
                    )
                    .with_context(|| format!("native fallback after {reason}"))?;
                    CopyExecution {
                        engine,
                        rsync_attempted: true,
                        rsync_output: Some(output),
                        rsync_warning: None,
                        fallback_reason: Some(reason),
                        verified_outcome: None,
                    }
                }
            }
        }
        Err(error) => {
            let reason = format!(
                "could not start rsync {}: {error}",
                transfer.rsync_program.display()
            );
            if !transfer.fallback_copy {
                return Err(error)
                    .with_context(|| format!("start rsync {}", transfer.rsync_program.display()));
            }
            let engine = fallback_engine(transfer);
            report(
                &mut progress,
                "copying",
                Some(engine),
                0,
                0,
                source_entries,
                source_bytes,
                &reason,
            )?;
            fallback_copy(
                transfer,
                excludes,
                source_entries,
                source_bytes,
                &mut progress,
            )
            .with_context(|| format!("native fallback after {reason}"))?;
            CopyExecution {
                engine,
                rsync_attempted: false,
                rsync_output: None,
                rsync_warning: None,
                fallback_reason: Some(reason),
                verified_outcome: None,
            }
        }
    };

    let engine_note = execution.engine_note();
    let outcome = if let Some(outcome) = execution.verified_outcome {
        outcome
    } else {
        report(
            &mut progress,
            "verifying",
            Some(execution.engine),
            source_entries,
            source_bytes,
            source_entries,
            source_bytes,
            format!("hashing source and destination content and metadata{engine_note}"),
        )?;
        verify_copy_outcome(
            transfer,
            excludes,
            &initial_source_manifest,
            verification_policy,
        )?
    };
    if !outcome.accepted() {
        bail!(
            "post-copy verification failed{}: {}",
            engine_note,
            verification_summary(&outcome.verification)
        );
    }
    let detail = if outcome.verification_deferred {
        format!(
            "copy completed; all mismatches were limited to paths changed at the source during the live copy; exact verification is deferred until the source is quiesced{engine_note}"
        )
    } else if outcome.source_changed_during_copy {
        format!(
            "copy and independent verification succeeded despite source changes during the copy{engine_note}"
        )
    } else {
        format!("copy and independent verification succeeded{engine_note}")
    };
    report(
        &mut progress,
        "completed",
        Some(execution.engine),
        outcome.source_entries,
        outcome.source_bytes,
        outcome.source_entries,
        outcome.source_bytes,
        detail,
    )?;
    let (
        rsync_exit_code,
        rsync_stdout,
        rsync_stderr,
        rsync_stdout_truncated_bytes,
        rsync_stderr_truncated_bytes,
    ) = execution.rsync_output.map_or_else(
        || (None, String::new(), String::new(), 0, 0),
        |output| {
            (
                output.exit_code,
                output.stdout,
                output.stderr,
                output.stdout_truncated_bytes,
                output.stderr_truncated_bytes,
            )
        },
    );
    Ok(TransferResult {
        source: transfer.source.clone(),
        destination: transfer.destination.clone(),
        engine: execution.engine,
        source_entries: outcome.source_entries,
        source_bytes: outcome.source_bytes,
        rsync_attempted: execution.rsync_attempted,
        rsync_attempts,
        rsync_exit_code,
        rsync_stdout,
        rsync_stderr,
        rsync_stdout_truncated_bytes,
        rsync_stderr_truncated_bytes,
        rsync_warning: execution.rsync_warning,
        fallback_reason: execution.fallback_reason,
        source_changed_during_copy: outcome.source_changed_during_copy,
        verification_deferred: outcome.verification_deferred,
        verification: outcome.verification,
    })
}

struct CopyExecution {
    engine: CopyEngine,
    rsync_attempted: bool,
    rsync_output: Option<RsyncOutput>,
    rsync_warning: Option<String>,
    fallback_reason: Option<String>,
    verified_outcome: Option<PostCopyOutcome>,
}

impl CopyExecution {
    fn engine_note(&self) -> String {
        if let Some(reason) = &self.fallback_reason {
            format!("; rsync fallback: {}", summarize_fallback_reason(reason))
        } else if let Some(reason) = &self.rsync_warning {
            format!(
                "; non-zero rsync result accepted by independent verification: {}",
                summarize_fallback_reason(reason)
            )
        } else {
            String::new()
        }
    }
}

struct PostCopyOutcome {
    source_entries: usize,
    source_bytes: u64,
    source_changed_during_copy: bool,
    verification_deferred: bool,
    verification: VerificationResult,
}

impl PostCopyOutcome {
    fn accepted(&self) -> bool {
        self.verification.matches || self.verification_deferred
    }
}

fn verify_copy_outcome(
    transfer: &TransferDefinition,
    excludes: &[PathBuf],
    initial_source_manifest: &DataManifest,
    verification_policy: PostCopyVerification,
) -> Result<PostCopyOutcome> {
    // Re-manifest the source after the copy. The initial manifest is only a
    // progress estimate; using it for verification would guarantee false
    // mismatches whenever an online seed legitimately changed during rsync.
    let final_source_manifest = source_manifest(transfer, excludes)?;
    let (source_entries, source_bytes) = manifest_stats(&final_source_manifest)?;
    let source_drift = compare_manifests(initial_source_manifest, &final_source_manifest)?;
    let verification = verify_with_source_manifest(transfer, excludes, final_source_manifest)?;
    let source_changed_during_copy = !source_drift.matches;
    let verification_deferred = !verification.matches
        && verification_policy == PostCopyVerification::AllowSourceDrift
        && verification_is_explained_by_source_drift(&verification, &source_drift);
    Ok(PostCopyOutcome {
        source_entries,
        source_bytes,
        source_changed_during_copy,
        verification_deferred,
        verification,
    })
}

fn is_transient_rsync_exit_code(exit_code: Option<i32>) -> bool {
    matches!(exit_code, Some(23 | 24))
}

fn verification_is_explained_by_source_drift(
    verification: &VerificationResult,
    source_drift: &VerificationResult,
) -> bool {
    if verification.truncated_mismatches != 0 || source_drift.truncated_mismatches != 0 {
        return false;
    }
    let changed_source_paths = mismatch_paths(source_drift);
    let mismatched_destination_paths = mismatch_paths(verification);
    !mismatched_destination_paths.is_empty()
        && mismatched_destination_paths.is_subset(&changed_source_paths)
}

fn mismatch_paths(verification: &VerificationResult) -> BTreeSet<&str> {
    verification
        .mismatches
        .iter()
        .filter_map(|mismatch| mismatch.split_once(": ").map(|(path, _)| path))
        .collect()
}

fn verification_summary(verification: &VerificationResult) -> String {
    let mut summary = verification.mismatches.join("; ");
    if verification.truncated_mismatches != 0 {
        summary.push_str(&format!(
            "; {} additional mismatches omitted",
            verification.truncated_mismatches
        ));
    }
    summary
}

fn summarize_fallback_reason(reason: &str) -> String {
    const LIMIT: usize = 2048;
    let normalized = reason.split_whitespace().collect::<Vec<_>>().join(" ");
    if normalized.len() <= LIMIT {
        return normalized;
    }
    let boundary = normalized
        .char_indices()
        .map(|(index, _)| index)
        .take_while(|index| *index <= LIMIT)
        .last()
        .unwrap_or(0);
    format!("{}...", &normalized[..boundary])
}

struct RsyncOutput {
    success: bool,
    exit_code: Option<i32>,
    stdout: String,
    stderr: String,
    stdout_truncated_bytes: u64,
    stderr_truncated_bytes: u64,
}

fn run_rsync(
    transfer: &TransferDefinition,
    excludes: &[PathBuf],
    total_entries: usize,
    total_bytes: u64,
    progress: &mut impl FnMut(&TransferProgress) -> Result<()>,
) -> Result<RsyncOutput> {
    let mut rsync = Command::new(&transfer.rsync_program);
    rsync
        .args([
            "--archive",
            "--hard-links",
            "--acls",
            "--xattrs",
            "--numeric-ids",
            "--partial",
            "--itemize-changes",
            "--out-format=%i|%l|%n%L",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if transfer.delete {
        // Delete first so rsync's archive pass is the last writer of directory
        // metadata. Delayed deletion can change directory mtimes after rsync
        // has restored them, causing a correct tree to fail verification.
        rsync.arg("--delete-before");
    }
    for exclude in excludes {
        rsync.arg(format!(
            "--exclude=/{}",
            escape_rsync_pattern(exclude.as_os_str().as_bytes())
        ));
    }
    let source = if let Some(remote) = &transfer.remote_source {
        rsync.arg("-e").arg(rsync_ssh_command(remote));
        let mut remote_rsync = remote.rsync_prefix.clone();
        remote_rsync.push(remote.rsync_program.to_string_lossy().into_owned());
        rsync.arg(format!("--rsync-path={}", shell_join(&remote_rsync)));
        format!(
            "{}{}:{}/",
            remote
                .user
                .as_ref()
                .map(|user| format!("{user}@"))
                .unwrap_or_default(),
            remote.host,
            transfer.source.display()
        )
    } else {
        format!("{}/", transfer.source.display())
    };
    let destination = if let Some(remote) = &transfer.remote_destination {
        rsync.arg("-e").arg(rsync_ssh_command(remote));
        let mut remote_rsync = remote.agent_prefix.clone();
        remote_rsync.push(remote.agent_program.to_string_lossy().into_owned());
        remote_rsync.extend([
            "data".to_owned(),
            "receive-rsync".to_owned(),
            "--destination".to_owned(),
            transfer.destination.to_string_lossy().into_owned(),
        ]);
        append_exclude_args(&mut remote_rsync, excludes);
        remote_rsync.push("--".to_owned());
        rsync.arg(format!("--rsync-path={}", shell_join(&remote_rsync)));
        format!(
            "{}{}:{}/",
            remote
                .user
                .as_ref()
                .map(|user| format!("{user}@"))
                .unwrap_or_default(),
            remote.host,
            transfer.destination.display()
        )
    } else {
        format!("{}/", transfer.destination.display())
    };
    let mut child = rsync.arg(source).arg(destination).spawn()?;
    let stdout = child.stdout.take().expect("piped rsync stdout");
    let stderr = child.stderr.take().expect("piped rsync stderr");
    let stderr_reader = thread::spawn(move || read_bounded(stderr));
    let mut stdout_capture = BoundedCapture::new(CAPTURE_LIMIT);
    let mut entries_completed = 0;
    let mut bytes_completed = 0_u64;
    let mut stdout = BufReader::new(stdout);
    let mut line = Vec::new();
    loop {
        line.clear();
        if stdout.read_until(b'\n', &mut line)? == 0 {
            break;
        }
        stdout_capture.push(&line);
        let mut fields = line.splitn(3, |byte| *byte == b'|');
        let itemized = fields.next().unwrap_or_default();
        let length = fields
            .next()
            .and_then(|value| std::str::from_utf8(value).ok())
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(0);
        if itemized.len() >= 11 {
            entries_completed += 1;
            bytes_completed = bytes_completed.saturating_add(length);
            if entries_completed % 128 == 0 {
                report(
                    progress,
                    "copying",
                    Some(CopyEngine::Rsync),
                    entries_completed,
                    bytes_completed,
                    total_entries,
                    total_bytes,
                    "rsync item progress",
                )?;
            }
        }
    }
    let status = child.wait()?;
    let stderr_capture = stderr_reader
        .join()
        .map_err(|_| anyhow::anyhow!("rsync stderr reader panicked"))?;
    let stderr_capture = stderr_capture?;
    Ok(RsyncOutput {
        success: status.success(),
        exit_code: status.code(),
        stdout: stdout_capture.text(),
        stderr: stderr_capture.text(),
        stdout_truncated_bytes: stdout_capture.truncated_bytes,
        stderr_truncated_bytes: stderr_capture.truncated_bytes,
    })
}

struct BoundedCapture {
    bytes: Vec<u8>,
    limit: usize,
    truncated_bytes: u64,
}

impl BoundedCapture {
    fn new(limit: usize) -> Self {
        Self {
            bytes: Vec::with_capacity(limit),
            limit,
            truncated_bytes: 0,
        }
    }

    fn push(&mut self, bytes: &[u8]) {
        let remaining = self.limit.saturating_sub(self.bytes.len());
        let retained = remaining.min(bytes.len());
        self.bytes.extend_from_slice(&bytes[..retained]);
        self.truncated_bytes += (bytes.len() - retained) as u64;
    }

    fn text(&self) -> String {
        String::from_utf8_lossy(&self.bytes).into_owned()
    }
}

fn read_bounded(mut reader: impl Read) -> io::Result<BoundedCapture> {
    let mut capture = BoundedCapture::new(CAPTURE_LIMIT);
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        capture.push(&buffer[..read]);
    }
    Ok(capture)
}

#[allow(clippy::too_many_arguments)]
fn report(
    callback: &mut impl FnMut(&TransferProgress) -> Result<()>,
    stage: &'static str,
    engine: Option<CopyEngine>,
    entries_completed: usize,
    bytes_completed: u64,
    total_entries: usize,
    total_bytes: u64,
    detail: impl Into<String>,
) -> Result<()> {
    callback(&TransferProgress {
        stage: stage.to_owned(),
        engine,
        entries_completed,
        bytes_completed,
        total_entries,
        total_bytes,
        detail: detail.into(),
    })
}

pub fn verify_transfer(transfer: &TransferDefinition) -> Result<VerificationResult> {
    verify_transfer_with_excludes(transfer, &[])
}

pub fn verify_transfer_with_excludes(
    transfer: &TransferDefinition,
    excludes: &[PathBuf],
) -> Result<VerificationResult> {
    validate_transfer(transfer)?;
    let source = source_manifest(transfer, excludes)?;
    verify_with_source_manifest(transfer, excludes, source)
}

fn verify_with_source_manifest(
    transfer: &TransferDefinition,
    excludes: &[PathBuf],
    source: DataManifest,
) -> Result<VerificationResult> {
    let destination = destination_manifest(transfer, excludes)?;
    compare_manifests(&source, &destination)
}

fn compare_manifests(
    source: &DataManifest,
    destination: &DataManifest,
) -> Result<VerificationResult> {
    let source_entries = normalized_entries(source)?;
    let destination_entries = normalized_entries(destination)?;
    let source_bytes = serde_json::to_vec(&source_entries)?;
    let destination_bytes = serde_json::to_vec(&destination_entries)?;
    let mut mismatches = Vec::new();
    let all_paths = source_entries
        .keys()
        .chain(destination_entries.keys())
        .cloned()
        .collect::<BTreeSet<_>>();
    let mut truncated_mismatches = 0;
    for path in all_paths {
        let mismatch = match (source_entries.get(&path), destination_entries.get(&path)) {
            (Some(source), Some(destination)) if source != destination => Some(format!(
                "{path}: {} differ",
                differing_fields(source, destination).join(", ")
            )),
            (Some(_), None) => Some(format!("{path}: missing from destination")),
            (None, Some(_)) => Some(format!("{path}: exists only in destination")),
            _ => None,
        };
        if let Some(mismatch) = mismatch {
            if mismatches.len() < 100 {
                mismatches.push(mismatch);
            } else {
                truncated_mismatches += 1;
            }
        }
    }
    Ok(VerificationResult {
        matches: mismatches.is_empty() && truncated_mismatches == 0,
        source_digest: digest_bytes(&source_bytes),
        destination_digest: digest_bytes(&destination_bytes),
        source_entries: source_entries.len(),
        destination_entries: destination_entries.len(),
        mismatches,
        truncated_mismatches,
    })
}

fn differing_fields(source: &NormalizedEntry, destination: &NormalizedEntry) -> Vec<&'static str> {
    let mut fields = Vec::new();
    if source.kind != destination.kind {
        fields.push("type");
    }
    if source.size != destination.size {
        fields.push("size");
    }
    if source.mode != destination.mode {
        fields.push("mode");
    }
    if source.uid != destination.uid {
        fields.push("uid");
    }
    if source.gid != destination.gid {
        fields.push("gid");
    }
    if source.rdev != destination.rdev {
        fields.push("device");
    }
    if source.modified_seconds != destination.modified_seconds {
        fields.push("mtime");
    }
    if source.xattrs_sha256 != destination.xattrs_sha256 {
        fields.push("xattrs");
    }
    if source.sha256 != destination.sha256 {
        fields.push("content");
    }
    if source.symlink_target_bytes_hex != destination.symlink_target_bytes_hex {
        fields.push("symlink target");
    }
    if source.hardlink_paths != destination.hardlink_paths {
        fields.push("hardlink topology");
    }
    fields
}

#[derive(Debug, Eq, PartialEq, Serialize)]
struct NormalizedEntry {
    kind: EntryKind,
    size: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    rdev: u64,
    modified_seconds: i64,
    xattrs_sha256: String,
    sha256: Option<String>,
    symlink_target_bytes_hex: Option<String>,
    hardlink_paths: Vec<String>,
}

fn normalized_entries(manifest: &DataManifest) -> Result<BTreeMap<String, NormalizedEntry>> {
    let root = manifest
        .roots
        .first()
        .context("verification manifest has no root")?;
    if manifest.roots.len() != 1 {
        bail!("verification requires exactly one source and destination root");
    }
    let mut hardlinks = BTreeMap::<(u64, u64), Vec<String>>::new();
    for entry in &root.entries {
        if entry.kind == EntryKind::File {
            hardlinks
                .entry((entry.device, entry.inode))
                .or_default()
                .push(entry.path_bytes_hex.clone());
        }
    }
    hardlinks.retain(|_, paths| paths.len() > 1);
    for paths in hardlinks.values_mut() {
        paths.sort();
    }
    Ok(root
        .entries
        .iter()
        .map(|entry| {
            let hardlink_paths = hardlinks
                .get(&(entry.device, entry.inode))
                .cloned()
                .unwrap_or_default();
            (
                entry.path_bytes_hex.clone(),
                normalize_entry(entry, hardlink_paths),
            )
        })
        .collect())
}

fn normalize_entry(entry: &ManifestEntry, hardlink_paths: Vec<String>) -> NormalizedEntry {
    NormalizedEntry {
        kind: entry.kind.clone(),
        size: if entry.kind == EntryKind::Directory {
            0
        } else {
            entry.size
        },
        mode: entry.mode,
        uid: entry.uid,
        gid: entry.gid,
        rdev: if matches!(
            &entry.kind,
            EntryKind::BlockDevice | EntryKind::CharacterDevice
        ) {
            entry.rdev
        } else {
            0
        },
        modified_seconds: entry.modified_seconds,
        xattrs_sha256: entry.xattrs_sha256.clone(),
        sha256: entry.sha256.clone(),
        symlink_target_bytes_hex: entry.symlink_target_bytes_hex.clone(),
        hardlink_paths,
    }
}

fn filesystem_copy(
    transfer: &TransferDefinition,
    excludes: &[PathBuf],
    total_entries: usize,
    total_bytes: u64,
    progress: &mut impl FnMut(&TransferProgress) -> Result<()>,
) -> Result<()> {
    let mut hardlinks = BTreeMap::new();
    let mut tracker = FallbackTracker {
        callback: progress,
        entries_completed: 0,
        bytes_completed: 0,
        total_entries,
        total_bytes,
    };
    copy_entry(
        &transfer.source,
        &transfer.destination,
        Path::new("."),
        excludes,
        &mut hardlinks,
        &mut tracker,
    )?;
    if transfer.delete {
        delete_extraneous(&transfer.source, &transfer.destination, excludes)?;
        let metadata = fs::symlink_metadata(&transfer.source)?;
        apply_metadata(&transfer.source, &transfer.destination, &metadata, false)?;
    }
    report(
        tracker.callback,
        "copying",
        Some(CopyEngine::Filesystem),
        total_entries,
        total_bytes,
        total_entries,
        total_bytes,
        "native filesystem copy completed",
    )?;
    Ok(())
}

fn fallback_engine(transfer: &TransferDefinition) -> CopyEngine {
    if transfer.remote_source.is_some() || transfer.remote_destination.is_some() {
        CopyEngine::TarOverSsh
    } else {
        CopyEngine::Filesystem
    }
}

fn fallback_copy(
    transfer: &TransferDefinition,
    excludes: &[PathBuf],
    total_entries: usize,
    total_bytes: u64,
    progress: &mut impl FnMut(&TransferProgress) -> Result<()>,
) -> Result<()> {
    match (&transfer.remote_source, &transfer.remote_destination) {
        (Some(remote), None) => {
            report(
                progress,
                "copying",
                Some(CopyEngine::TarOverSsh),
                0,
                0,
                total_entries,
                total_bytes,
                "streaming metadata-preserving tar over SSH",
            )?;
            remote_tar_copy(transfer, remote, excludes)?;
            report(
                progress,
                "copying",
                Some(CopyEngine::TarOverSsh),
                total_entries,
                total_bytes,
                total_entries,
                total_bytes,
                "tar-over-SSH extraction completed",
            )
        }
        (None, Some(remote)) => {
            report(
                progress,
                "copying",
                Some(CopyEngine::TarOverSsh),
                0,
                0,
                total_entries,
                total_bytes,
                "streaming metadata-preserving tar directly to the remote destination",
            )?;
            remote_tar_push(transfer, remote, excludes)?;
            report(
                progress,
                "copying",
                Some(CopyEngine::TarOverSsh),
                total_entries,
                total_bytes,
                total_entries,
                total_bytes,
                "direct tar-over-SSH extraction completed",
            )
        }
        (None, None) => filesystem_copy(transfer, excludes, total_entries, total_bytes, progress),
        (Some(_), Some(_)) => unreachable!("validated transfer direction"),
    }
}

fn source_manifest(transfer: &TransferDefinition, excludes: &[PathBuf]) -> Result<DataManifest> {
    match &transfer.remote_source {
        None => create_manifest_roots(&[DataRoot {
            name: "transfer".to_owned(),
            path: transfer.source.clone(),
            excludes: excludes.to_vec(),
        }]),
        Some(remote) => {
            let mut argv = remote.agent_prefix.clone();
            argv.push(remote.agent_program.to_string_lossy().into_owned());
            argv.extend([
                "--json".to_owned(),
                "data".to_owned(),
                "manifest".to_owned(),
                "--diagnostic-path".to_owned(),
                transfer.source.to_string_lossy().into_owned(),
            ]);
            append_exclude_args(&mut argv, excludes);
            let output = remote_output(remote, &argv)?;
            if !output.status.success() {
                bail!(
                    "remote source manifest failed with {}: {}",
                    output.status,
                    String::from_utf8_lossy(&output.stderr).trim()
                );
            }
            let value: serde_json::Value = serde_json::from_slice(&output.stdout)
                .context("parse remote source manifest response")?;
            decode_remote_manifest_response(&value, "source")
        }
    }
}

fn destination_manifest(
    transfer: &TransferDefinition,
    excludes: &[PathBuf],
) -> Result<DataManifest> {
    match &transfer.remote_destination {
        None => create_manifest_roots(&[DataRoot {
            name: "transfer".to_owned(),
            path: transfer.destination.clone(),
            excludes: excludes.to_vec(),
        }]),
        Some(remote) => remote_manifest(remote, &transfer.destination, excludes, "destination"),
    }
}

fn remote_manifest(
    remote: &RemoteSource,
    path: &Path,
    excludes: &[PathBuf],
    direction: &str,
) -> Result<DataManifest> {
    let mut argv = remote.agent_prefix.clone();
    argv.push(remote.agent_program.to_string_lossy().into_owned());
    argv.extend([
        "--json".to_owned(),
        "data".to_owned(),
        "manifest".to_owned(),
        "--diagnostic-path".to_owned(),
        path.to_string_lossy().into_owned(),
    ]);
    append_exclude_args(&mut argv, excludes);
    let output = remote_output(remote, &argv)?;
    if !output.status.success() {
        bail!(
            "remote {direction} manifest failed with {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let value: serde_json::Value = serde_json::from_slice(&output.stdout)
        .with_context(|| format!("parse remote {direction} manifest response"))?;
    decode_remote_manifest_response(&value, direction)
}

fn decode_remote_manifest_response(
    value: &serde_json::Value,
    direction: &str,
) -> Result<DataManifest> {
    let manifest = value
        .pointer("/result/manifest")
        // Agents deployed before the canonical response envelope returned the
        // DataManifest directly as `result`. Accept that shape so either peer
        // can be upgraded first without interrupting a transfer retry.
        .or_else(|| value.pointer("/result"))
        .cloned()
        .with_context(|| format!("remote {direction} response has no manifest"))?;
    serde_json::from_value(manifest).with_context(|| format!("decode remote {direction} manifest"))
}

fn remote_tar_copy(
    transfer: &TransferDefinition,
    remote: &RemoteSource,
    excludes: &[PathBuf],
) -> Result<()> {
    fs::create_dir_all(&transfer.destination)
        .with_context(|| format!("create {}", transfer.destination.display()))?;
    if transfer.delete {
        clear_directory_contents_except(&transfer.destination, excludes)?;
    }
    let mut remote_argv = remote.agent_prefix.clone();
    remote_argv.push(remote.tar_program.to_string_lossy().into_owned());
    remote_argv.extend([
        "--acls".to_owned(),
        "--xattrs".to_owned(),
        "--numeric-owner".to_owned(),
        "--same-owner".to_owned(),
        "--same-permissions".to_owned(),
        "-C".to_owned(),
        transfer.source.to_string_lossy().into_owned(),
    ]);
    append_tar_excludes(&mut remote_argv, excludes);
    remote_argv.extend(["-cpf".to_owned(), "-".to_owned(), ".".to_owned()]);
    let mut remote_child = remote_command(remote, &remote_argv)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("start remote tar fallback source")?;
    let remote_stdout = remote_child
        .stdout
        .take()
        .context("remote tar stdout was not piped")?;
    let remote_stderr = remote_child
        .stderr
        .take()
        .context("remote tar stderr was not piped")?;
    let stderr_reader = thread::spawn(move || read_bounded(remote_stderr));
    let local = Command::new(&transfer.tar_program)
        .args([
            "--acls",
            "--xattrs",
            "--numeric-owner",
            "--same-owner",
            "--same-permissions",
            "-C",
        ])
        .arg(&transfer.destination)
        .args(["-xpf", "-"])
        .stdin(Stdio::from(remote_stdout))
        .output()
        .with_context(|| format!("run local tar {}", transfer.tar_program.display()))?;
    let remote_status = remote_child.wait().context("wait for remote tar source")?;
    let remote_stderr = stderr_reader
        .join()
        .map_err(|_| anyhow::anyhow!("remote tar stderr reader panicked"))?;
    let remote_stderr = remote_stderr.context("read remote tar stderr")?;
    if !remote_status.success() || !local.status.success() {
        bail!(
            "tar fallback failed: remote={remote_status}, local={}; remote stderr: {}; local stderr: {}",
            local.status,
            remote_stderr.text().trim(),
            String::from_utf8_lossy(&local.stderr).trim()
        );
    }
    Ok(())
}

fn remote_tar_push(
    transfer: &TransferDefinition,
    remote: &RemoteSource,
    excludes: &[PathBuf],
) -> Result<()> {
    let mut remote_argv = remote.agent_prefix.clone();
    remote_argv.push(remote.agent_program.to_string_lossy().into_owned());
    remote_argv.extend([
        "data".to_owned(),
        "receive".to_owned(),
        "--destination".to_owned(),
        transfer.destination.to_string_lossy().into_owned(),
    ]);
    if transfer.delete {
        remote_argv.push("--delete".to_owned());
    }
    append_exclude_args(&mut remote_argv, excludes);
    let mut local_tar_command = Command::new(&transfer.tar_program);
    local_tar_command
        .args([
            "--acls",
            "--xattrs",
            "--numeric-owner",
            "--same-owner",
            "--same-permissions",
            "-C",
        ])
        .arg(&transfer.source);
    append_tar_excludes_command(&mut local_tar_command, excludes);
    let mut local_tar = local_tar_command
        .args(["-cpf", "-", "."])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("start local tar {}", transfer.tar_program.display()))?;
    let tar_stdout = local_tar.stdout.take().expect("piped local tar stdout");
    let mut remote_child = remote_command(remote, &remote_argv)
        .stdin(Stdio::from(tar_stdout))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("start remote tar receiver")?;
    let remote_stdout = remote_child.stdout.take().expect("piped remote stdout");
    let remote_stderr = remote_child.stderr.take().expect("piped remote stderr");
    let stdout_reader = thread::spawn(move || read_bounded(remote_stdout));
    let stderr_reader = thread::spawn(move || read_bounded(remote_stderr));
    let local_output = local_tar.wait_with_output().context("wait for local tar")?;
    let remote_status = remote_child
        .wait()
        .context("wait for remote tar receiver")?;
    let remote_stdout = stdout_reader
        .join()
        .map_err(|_| anyhow::anyhow!("remote stdout reader panicked"))??;
    let remote_stderr = stderr_reader
        .join()
        .map_err(|_| anyhow::anyhow!("remote stderr reader panicked"))??;
    if !local_output.status.success() {
        bail!(
            "local tar failed with {}: {}",
            local_output.status,
            String::from_utf8_lossy(&local_output.stderr).trim()
        );
    }
    if !remote_status.success() {
        bail!(
            "remote tar receiver failed with {remote_status}: {}{}",
            remote_stdout.text(),
            remote_stderr.text()
        );
    }
    Ok(())
}

pub(crate) fn clear_directory_contents_except(path: &Path, excludes: &[PathBuf]) -> Result<()> {
    for entry in fs::read_dir(path).with_context(|| format!("list {}", path.display()))? {
        let entry = entry?;
        let relative = PathBuf::from(entry.file_name());
        if is_exclude_protected(&relative, excludes) {
            continue;
        }
        let child = entry.path();
        let metadata = fs::symlink_metadata(&child)?;
        if metadata.is_dir() {
            fs::remove_dir_all(&child).with_context(|| format!("remove {}", child.display()))?;
        } else {
            fs::remove_file(&child).with_context(|| format!("remove {}", child.display()))?;
        }
    }
    Ok(())
}

fn remote_output(remote: &RemoteSource, argv: &[String]) -> Result<std::process::Output> {
    remote_command(remote, argv)
        .output()
        .with_context(|| format!("run SSH transfer source {}", remote.host))
}

fn remote_command(remote: &RemoteSource, argv: &[String]) -> Command {
    let mut command = Command::new(&remote.ssh_program);
    command
        .args(&remote.ssh_args)
        .arg("-o")
        .arg("BatchMode=yes");
    if let Some(port) = remote.port {
        command.arg("-p").arg(port.to_string());
    }
    if let Some(identity) = &remote.identity_file {
        command.arg("-i").arg(identity);
    }
    command.arg("--").arg(remote_destination(remote));
    command.arg(shell_join(argv));
    command
}

fn rsync_ssh_command(remote: &RemoteSource) -> String {
    let mut argv = vec![remote.ssh_program.to_string_lossy().into_owned()];
    argv.extend(remote.ssh_args.clone());
    argv.extend(["-o".to_owned(), "BatchMode=yes".to_owned()]);
    if let Some(port) = remote.port {
        argv.extend(["-p".to_owned(), port.to_string()]);
    }
    if let Some(identity) = &remote.identity_file {
        argv.extend(["-i".to_owned(), identity.to_string_lossy().into_owned()]);
    }
    shell_join(&argv)
}

fn remote_destination(remote: &RemoteSource) -> String {
    match &remote.user {
        Some(user) => format!("{user}@{}", remote.host),
        None => remote.host.clone(),
    }
}

fn shell_join(argv: &[String]) -> String {
    argv.iter()
        .map(|argument| format!("'{}'", argument.replace('\'', "'\"'\"'")))
        .collect::<Vec<_>>()
        .join(" ")
}

fn default_rsync_program() -> PathBuf {
    PathBuf::from("/run/current-system/sw/bin/rsync")
}

struct FallbackTracker<'a, F> {
    callback: &'a mut F,
    entries_completed: usize,
    bytes_completed: u64,
    total_entries: usize,
    total_bytes: u64,
}

impl<F> FallbackTracker<'_, F>
where
    F: FnMut(&TransferProgress) -> Result<()>,
{
    fn complete(&mut self, metadata: &fs::Metadata) -> Result<()> {
        self.entries_completed = self.entries_completed.saturating_add(1);
        if metadata.is_file() {
            self.bytes_completed = self.bytes_completed.saturating_add(metadata.len());
        }
        if self.entries_completed.is_multiple_of(128)
            || self.entries_completed >= self.total_entries
        {
            report(
                self.callback,
                "copying",
                Some(CopyEngine::Filesystem),
                self.entries_completed.min(self.total_entries),
                self.bytes_completed.min(self.total_bytes),
                self.total_entries,
                self.total_bytes,
                "native filesystem item progress",
            )?;
        }
        Ok(())
    }
}

fn copy_entry(
    source: &Path,
    destination: &Path,
    relative: &Path,
    excludes: &[PathBuf],
    hardlinks: &mut BTreeMap<(u64, u64), PathBuf>,
    tracker: &mut FallbackTracker<'_, impl FnMut(&TransferProgress) -> Result<()>>,
) -> Result<()> {
    if relative != Path::new(".") && is_excluded(relative, excludes) {
        return Ok(());
    }
    let metadata = fs::symlink_metadata(source)
        .with_context(|| format!("read metadata for {}", source.display()))?;
    let file_type = metadata.file_type();
    if file_type.is_dir() {
        ensure_directory(destination)?;
        let mut children = fs::read_dir(source)
            .with_context(|| format!("list {}", source.display()))?
            .collect::<io::Result<Vec<_>>>()?;
        children.sort_by_key(|entry| entry.file_name());
        for child in children {
            copy_entry(
                &child.path(),
                &destination.join(child.file_name()),
                &if relative == Path::new(".") {
                    PathBuf::from(child.file_name())
                } else {
                    relative.join(child.file_name())
                },
                excludes,
                hardlinks,
                tracker,
            )?;
        }
        apply_metadata(source, destination, &metadata, false)?;
    } else if file_type.is_file() {
        ensure_parent(destination)?;
        remove_conflicting(destination, false)?;
        let identity = (metadata.dev(), metadata.ino());
        if metadata.nlink() > 1
            && let Some(existing) = hardlinks.get(&identity)
        {
            fs::hard_link(existing, destination).with_context(|| {
                format!(
                    "create hard link {} from {}",
                    destination.display(),
                    existing.display()
                )
            })?;
        } else {
            copy_file_atomic(source, destination, &metadata)?;
            if metadata.nlink() > 1 {
                hardlinks.insert(identity, destination.to_owned());
            }
        }
    } else if file_type.is_symlink() {
        ensure_parent(destination)?;
        remove_conflicting(destination, false)?;
        let target =
            fs::read_link(source).with_context(|| format!("read symlink {}", source.display()))?;
        symlink(&target, destination)
            .with_context(|| format!("create symlink {}", destination.display()))?;
        apply_metadata(source, destination, &metadata, true)?;
    } else {
        bail!(
            "filesystem fallback does not copy special file {}",
            source.display()
        );
    }
    tracker.complete(&metadata)
}

fn copy_file_atomic(source: &Path, destination: &Path, metadata: &fs::Metadata) -> Result<()> {
    let parent = destination
        .parent()
        .context("copy destination has no parent")?;
    let sequence = COPY_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temporary = parent.join(format!(
        ".abird-copy.{}.{}.tmp",
        std::process::id(),
        sequence
    ));
    let result = (|| -> Result<()> {
        let mut input = File::open(source).with_context(|| format!("open {}", source.display()))?;
        let mut output = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(metadata.permissions().mode())
            .open(&temporary)
            .with_context(|| format!("create {}", temporary.display()))?;
        io::copy(&mut input, &mut output).with_context(|| format!("copy {}", source.display()))?;
        output
            .sync_all()
            .with_context(|| format!("sync {}", temporary.display()))?;
        apply_metadata(source, &temporary, metadata, false)?;
        fs::rename(&temporary, destination).with_context(|| {
            format!(
                "atomically replace {} from {}",
                destination.display(),
                temporary.display()
            )
        })?;
        File::open(parent)
            .with_context(|| format!("open directory {}", parent.display()))?
            .sync_all()
            .with_context(|| format!("sync directory {}", parent.display()))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn ensure_directory(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() => Ok(()),
        Ok(_) => {
            remove_conflicting(path, true)?;
            fs::create_dir(path).with_context(|| format!("create directory {}", path.display()))
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            ensure_parent(path)?;
            fs::create_dir(path).with_context(|| format!("create directory {}", path.display()))
        }
        Err(error) => Err(error).with_context(|| format!("inspect {}", path.display())),
    }
}

fn ensure_parent(path: &Path) -> Result<()> {
    let parent = path.parent().context("path has no parent")?;
    fs::create_dir_all(parent).with_context(|| format!("create directory {}", parent.display()))
}

fn remove_conflicting(path: &Path, allow_directory: bool) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() && allow_directory => {
            fs::remove_dir_all(path).with_context(|| format!("remove {}", path.display()))
        }
        Ok(metadata) if metadata.is_dir() => {
            fs::remove_dir_all(path).with_context(|| format!("remove {}", path.display()))
        }
        Ok(_) => fs::remove_file(path).with_context(|| format!("remove {}", path.display())),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| format!("inspect {}", path.display())),
    }
}

fn apply_metadata(
    source: &Path,
    destination: &Path,
    metadata: &fs::Metadata,
    symlink: bool,
) -> Result<()> {
    if !symlink {
        fs::set_permissions(
            destination,
            fs::Permissions::from_mode(metadata.permissions().mode()),
        )
        .with_context(|| format!("set permissions on {}", destination.display()))?;
    }
    copy_owner(destination, metadata.uid(), metadata.gid(), symlink)?;
    copy_xattrs(source, destination)?;
    copy_times(
        destination,
        metadata.atime(),
        metadata.atime_nsec(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        symlink,
    )
}

fn copy_owner(path: &Path, uid: u32, gid: u32, symlink: bool) -> Result<()> {
    let path = c_path(path)?;
    // SAFETY: path is a valid NUL-terminated path. lchown deliberately does
    // not follow symlinks; chown is used for regular files/directories.
    let result = unsafe {
        if symlink {
            libc::lchown(path.as_ptr(), uid, gid)
        } else {
            libc::chown(path.as_ptr(), uid, gid)
        }
    };
    if result != 0 {
        return Err(io::Error::last_os_error()).context("preserve file owner");
    }
    Ok(())
}

fn copy_times(
    path: &Path,
    atime: i64,
    atime_nsec: i64,
    mtime: i64,
    mtime_nsec: i64,
    symlink: bool,
) -> Result<()> {
    let path = c_path(path)?;
    let times = [
        libc::timespec {
            tv_sec: atime,
            tv_nsec: atime_nsec,
        },
        libc::timespec {
            tv_sec: mtime,
            tv_nsec: mtime_nsec,
        },
    ];
    let flags = if symlink {
        libc::AT_SYMLINK_NOFOLLOW
    } else {
        0
    };
    // SAFETY: path and times point to valid values for the duration of the call.
    let result = unsafe { libc::utimensat(libc::AT_FDCWD, path.as_ptr(), times.as_ptr(), flags) };
    if result != 0 {
        return Err(io::Error::last_os_error()).context("preserve timestamps");
    }
    Ok(())
}

fn delete_extraneous(source: &Path, destination: &Path, excludes: &[PathBuf]) -> Result<()> {
    let source_paths = relative_paths(source)?;
    let mut destination_paths = relative_paths(destination)?;
    destination_paths.sort_by_key(|path| std::cmp::Reverse(path.components().count()));
    for relative in destination_paths {
        if relative.as_os_str().is_empty()
            || source_paths.contains(&relative)
            || is_exclude_protected(&relative, excludes)
        {
            continue;
        }
        let path = destination.join(relative);
        let metadata =
            fs::symlink_metadata(&path).with_context(|| format!("inspect {}", path.display()))?;
        if metadata.is_dir() {
            fs::remove_dir_all(&path).with_context(|| format!("remove {}", path.display()))?;
        } else {
            fs::remove_file(&path).with_context(|| format!("remove {}", path.display()))?;
        }
    }
    Ok(())
}

fn append_exclude_args(argv: &mut Vec<String>, excludes: &[PathBuf]) {
    for exclude in excludes {
        argv.extend([
            "--exclude".to_owned(),
            exclude.to_string_lossy().into_owned(),
        ]);
    }
}

fn append_tar_excludes(argv: &mut Vec<String>, excludes: &[PathBuf]) {
    if !excludes.is_empty() {
        argv.push("--no-wildcards".to_owned());
    }
    for exclude in excludes {
        argv.push(format!("--exclude=./{}", exclude.display()));
    }
}

fn append_tar_excludes_command(command: &mut Command, excludes: &[PathBuf]) {
    if !excludes.is_empty() {
        command.arg("--no-wildcards");
    }
    for exclude in excludes {
        command.arg(format!("--exclude=./{}", exclude.display()));
    }
}

fn escape_rsync_pattern(path: &[u8]) -> String {
    let mut escaped = String::new();
    for byte in path {
        let character = *byte as char;
        if matches!(character, '*' | '?' | '[' | '\\') {
            escaped.push('\\');
        }
        escaped.push(character);
    }
    escaped
}

fn relative_paths(root: &Path) -> Result<Vec<PathBuf>> {
    fn visit(root: &Path, relative: &Path, paths: &mut Vec<PathBuf>) -> Result<()> {
        paths.push(relative.to_owned());
        let absolute = root.join(relative);
        if fs::symlink_metadata(&absolute)?.is_dir() {
            for entry in fs::read_dir(&absolute)? {
                let entry = entry?;
                let child = if relative.as_os_str().is_empty() {
                    PathBuf::from(entry.file_name())
                } else {
                    relative.join(entry.file_name())
                };
                visit(root, &child, paths)?;
            }
        }
        Ok(())
    }
    let mut paths = Vec::new();
    visit(root, Path::new(""), &mut paths)?;
    Ok(paths)
}

fn manifest_stats(manifest: &DataManifest) -> Result<(usize, u64)> {
    let root = manifest
        .roots
        .first()
        .context("transfer source manifest has no root")?;
    if manifest.roots.len() != 1 {
        bail!("transfer source manifest must contain exactly one root");
    }
    let entries = &root.entries;
    Ok((
        entries.len(),
        entries
            .iter()
            .filter(|entry| entry.kind == EntryKind::File)
            .map(|entry| entry.size)
            .sum(),
    ))
}

fn c_path(path: &Path) -> Result<CString> {
    CString::new(path.as_os_str().as_bytes())
        .with_context(|| format!("path contains NUL: {}", path.display()))
}

fn default_true() -> bool {
    true
}

fn default_agent_program() -> PathBuf {
    PathBuf::from("/run/current-system/sw/bin/abird-host-agent")
}

fn default_tar_program() -> PathBuf {
    PathBuf::from("/run/current-system/sw/bin/tar")
}

#[cfg(test)]
mod tests {
    use std::fs::hard_link;
    use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};

    use super::*;
    use crate::manifest::create_manifest;

    fn executable_in_path(name: &str) -> PathBuf {
        std::env::split_paths(&std::env::var_os("PATH").expect("test PATH"))
            .map(|directory| directory.join(name))
            .find(|candidate| candidate.is_file())
            .unwrap_or_else(|| panic!("{name} is not available in the test PATH"))
    }

    #[test]
    fn filesystem_fallback_copies_deletes_and_verifies() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        let destination = temp.path().join("destination");
        fs::create_dir_all(source.join("nested")).unwrap();
        fs::create_dir_all(&destination).unwrap();
        fs::write(source.join("nested/data"), b"zulip").unwrap();
        fs::set_permissions(
            source.join("nested/data"),
            fs::Permissions::from_mode(0o640),
        )
        .unwrap();
        symlink("nested/data", source.join("link")).unwrap();
        fs::write(destination.join("stale"), b"old").unwrap();
        let definition = TransferDefinition {
            source,
            destination: destination.clone(),
            rsync_program: temp.path().join("missing-rsync"),
            remote_source: None,
            remote_destination: None,
            tar_program: PathBuf::from("/bin/tar"),
            delete: true,
            fallback_copy: true,
        };

        let mut progress = Vec::new();
        let result = transfer_with_progress(&definition, |status| {
            progress.push(status.clone());
            Ok(())
        })
        .unwrap();
        assert_eq!(result.engine, CopyEngine::Filesystem);
        assert!(result.verification.matches);
        assert!(progress.iter().any(|status| {
            status.engine == Some(CopyEngine::Filesystem)
                && status.entries_completed == status.total_entries
        }));
        assert!(!destination.join("stale").exists());
        assert_eq!(fs::read(destination.join("nested/data")).unwrap(), b"zulip");
        assert_eq!(
            fs::symlink_metadata(destination.join("nested/data"))
                .unwrap()
                .mode()
                & 0o777,
            0o640
        );
    }

    #[test]
    fn excluded_subtrees_are_neither_copied_deleted_nor_verified() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        let destination = temp.path().join("destination");
        fs::create_dir_all(source.join("runtime/cache")).unwrap();
        fs::create_dir_all(destination.join("runtime/cache")).unwrap();
        fs::write(source.join("kept"), b"new").unwrap();
        fs::write(source.join("runtime/cache/source"), b"ignore").unwrap();
        fs::write(destination.join("runtime/cache/target"), b"survive").unwrap();
        fs::write(destination.join("stale"), b"remove").unwrap();
        let definition = TransferDefinition {
            source,
            destination: destination.clone(),
            rsync_program: temp.path().join("missing-rsync"),
            remote_source: None,
            remote_destination: None,
            tar_program: PathBuf::from("/bin/tar"),
            delete: true,
            fallback_copy: true,
        };

        let result =
            transfer_with_excludes_progress(&definition, &[PathBuf::from("runtime/cache")], |_| {
                Ok(())
            })
            .unwrap();
        assert!(result.verification.matches);
        assert_eq!(fs::read(destination.join("kept")).unwrap(), b"new");
        assert_eq!(
            fs::read(destination.join("runtime/cache/target")).unwrap(),
            b"survive"
        );
        assert!(!destination.join("runtime/cache/source").exists());
        assert!(!destination.join("stale").exists());
    }

    #[test]
    fn verification_reports_content_differences() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        let destination = temp.path().join("destination");
        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(&destination).unwrap();
        fs::write(source.join("data"), b"a").unwrap();
        fs::write(destination.join("data"), b"b").unwrap();
        let definition = TransferDefinition {
            source,
            destination,
            rsync_program: executable_in_path("false"),
            remote_source: None,
            remote_destination: None,
            tar_program: PathBuf::from("/bin/tar"),
            delete: true,
            fallback_copy: false,
        };
        let result = verify_transfer(&definition).unwrap();
        assert!(!result.matches);
        assert!(!result.mismatches.is_empty());
    }

    #[test]
    fn independently_verified_rsync_result_outweighs_its_exit_status() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        let destination = temp.path().join("destination");
        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(&destination).unwrap();
        fs::write(source.join("data"), b"already copied").unwrap();
        fs::copy(source.join("data"), destination.join("data")).unwrap();
        for relative in [Path::new(""), Path::new("data")] {
            let metadata = fs::metadata(source.join(relative)).unwrap();
            copy_times(
                &destination.join(relative),
                metadata.atime(),
                metadata.atime_nsec(),
                metadata.mtime(),
                metadata.mtime_nsec(),
                false,
            )
            .unwrap();
        }
        let definition = TransferDefinition {
            source,
            destination,
            rsync_program: executable_in_path("false"),
            remote_source: None,
            remote_destination: None,
            tar_program: PathBuf::from("/bin/tar"),
            delete: true,
            fallback_copy: false,
        };

        let result = transfer_with_progress(&definition, |_| Ok(())).unwrap();

        assert_eq!(result.engine, CopyEngine::Rsync);
        assert_eq!(result.rsync_exit_code, Some(1));
        assert!(result.rsync_warning.is_some());
        assert!(result.fallback_reason.is_none());
        assert!(result.verification.matches);
    }

    #[test]
    fn unverified_rsync_result_uses_the_declared_fallback() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        let destination = temp.path().join("destination");
        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(&destination).unwrap();
        fs::write(source.join("data"), b"new").unwrap();
        fs::write(destination.join("data"), b"stale").unwrap();
        let definition = TransferDefinition {
            source,
            destination,
            rsync_program: executable_in_path("false"),
            remote_source: None,
            remote_destination: None,
            tar_program: PathBuf::from("/bin/tar"),
            delete: true,
            fallback_copy: true,
        };

        let result = transfer_with_progress(&definition, |_| Ok(())).unwrap();

        assert_eq!(result.engine, CopyEngine::Filesystem);
        assert_eq!(result.rsync_exit_code, Some(1));
        assert!(result.rsync_warning.is_none());
        assert!(result.fallback_reason.is_some());
        assert!(result.verification.matches);
    }

    #[test]
    fn live_copy_defers_only_mismatches_explained_by_source_drift() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        let destination = temp.path().join("destination");
        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(&destination).unwrap();
        fs::write(source.join("data"), b"before").unwrap();
        let definition = TransferDefinition {
            source: source.clone(),
            destination,
            rsync_program: temp.path().join("missing-rsync"),
            remote_source: None,
            remote_destination: None,
            tar_program: PathBuf::from("/bin/tar"),
            delete: true,
            fallback_copy: true,
        };

        let mut changed = false;
        let result = transfer_with_excludes_progress_policy(
            &definition,
            &[],
            PostCopyVerification::AllowSourceDrift,
            |progress| {
                if progress.stage == "verifying" && !changed {
                    fs::write(source.join("data"), b"after").unwrap();
                    changed = true;
                }
                Ok(())
            },
        )
        .unwrap();

        assert!(result.source_changed_during_copy);
        assert!(result.verification_deferred);
        assert!(!result.verification.matches);
    }

    #[test]
    fn live_copy_rejects_destination_damage_not_explained_by_source_drift() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        let destination = temp.path().join("destination");
        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(&destination).unwrap();
        fs::write(source.join("data"), b"stable").unwrap();
        let definition = TransferDefinition {
            source,
            destination: destination.clone(),
            rsync_program: temp.path().join("missing-rsync"),
            remote_source: None,
            remote_destination: None,
            tar_program: PathBuf::from("/bin/tar"),
            delete: true,
            fallback_copy: true,
        };

        let mut damaged = false;
        let error = transfer_with_excludes_progress_policy(
            &definition,
            &[],
            PostCopyVerification::AllowSourceDrift,
            |progress| {
                if progress.stage == "verifying" && !damaged {
                    fs::write(destination.join("data"), b"damaged").unwrap();
                    damaged = true;
                }
                Ok(())
            },
        )
        .unwrap_err();

        assert!(error.to_string().contains("post-copy verification failed"));
    }

    #[test]
    fn normalized_manifests_preserve_hardlink_topology() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        let destination = temp.path().join("destination");
        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(&destination).unwrap();
        fs::write(source.join("a"), b"same").unwrap();
        hard_link(source.join("a"), source.join("b")).unwrap();
        fs::write(destination.join("a"), b"same").unwrap();
        fs::write(destination.join("b"), b"same").unwrap();

        let source = create_manifest(&[source]).unwrap();
        let destination = create_manifest(&[destination]).unwrap();
        let source = normalized_entries(&source).unwrap();
        let destination = normalized_entries(&destination).unwrap();
        assert_eq!(source["61"].hardlink_paths, ["61", "62"]);
        assert!(destination["61"].hardlink_paths.is_empty());
    }

    #[test]
    fn remote_manifest_decoder_accepts_canonical_and_legacy_envelopes() {
        let manifest = serde_json::json!({
            "schema_version": 1,
            "hash_algorithm": "sha256",
            "roots": [],
        });
        for response in [
            serde_json::json!({ "result": { "manifest": manifest.clone() } }),
            serde_json::json!({ "result": manifest.clone() }),
        ] {
            let decoded = decode_remote_manifest_response(&response, "destination").unwrap();
            assert_eq!(decoded.schema_version, 1);
            assert_eq!(decoded.hash_algorithm, "sha256");
            assert!(decoded.roots.is_empty());
        }
    }

    #[test]
    fn bounded_capture_drains_without_growing_the_record() {
        let mut capture = BoundedCapture::new(4);
        capture.push(b"abcdef");
        capture.push(b"gh");
        assert_eq!(capture.bytes, b"abcd");
        assert_eq!(capture.truncated_bytes, 4);
    }

    #[test]
    fn only_partial_and_vanished_file_rsync_results_are_retried() {
        assert!(is_transient_rsync_exit_code(Some(23)));
        assert!(is_transient_rsync_exit_code(Some(24)));
        assert!(!is_transient_rsync_exit_code(Some(12)));
        assert!(!is_transient_rsync_exit_code(Some(255)));
        assert!(!is_transient_rsync_exit_code(None));
    }
}
