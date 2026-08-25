use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::command::CommandSpec;
use crate::service::ServiceTarget;
use crate::sha256::digest_bytes;

static STATE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct FileStateDefinition {
    pub path: PathBuf,
    pub content: String,
    #[serde(default = "default_mode")]
    pub mode: u32,
    #[serde(default)]
    pub reload_services: Vec<ServiceTarget>,
    /// Compare-and-swap guard for a transactional file-state update.
    ///
    /// Legacy declarations omit this field and retain last-writer-wins
    /// behavior. When present, the current file must exist and match exactly.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_previous_sha256: Option<String>,
    /// Allowlist form of the compare-and-swap guard for state machines with
    /// more than two valid states. This is mutually exclusive with the legacy
    /// single-digest field.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub accepted_previous_sha256: Vec<String>,
    /// Fixed validator argv. The temporary candidate path is appended as its
    /// final argument; no shell parsing or expansion is performed.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub validation_argv: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FileStateResult {
    pub path: PathBuf,
    pub changed: bool,
    pub previous_sha256: Option<String>,
    pub current_sha256: String,
    pub restored: bool,
}

#[derive(Debug)]
pub struct FileStateApplyResult<T> {
    pub file_state: FileStateResult,
    pub reloads: Vec<T>,
    pub rollback_reloads: Vec<T>,
    pub error: Option<String>,
}

pub fn validate_file_state(state: &FileStateDefinition) -> Result<()> {
    if !state.path.is_absolute() || state.path == Path::new("/") {
        bail!("file-state path must be absolute and cannot be /");
    }
    if state.content.contains('\0') {
        bail!("file-state content cannot contain NUL");
    }
    if state.mode == 0 || state.mode & !0o7777 != 0 {
        bail!("file-state mode must be between 0001 and 7777");
    }
    if let Some(digest) = &state.expected_previous_sha256 {
        validate_sha256("expected previous file-state digest", digest)?;
    }
    if state.expected_previous_sha256.is_some() && !state.accepted_previous_sha256.is_empty() {
        bail!(
            "file-state expected_previous_sha256 and accepted_previous_sha256 are mutually exclusive"
        );
    }
    let mut accepted = std::collections::BTreeSet::new();
    for digest in &state.accepted_previous_sha256 {
        validate_sha256("accepted previous file-state digest", digest)?;
        if !accepted.insert(digest) {
            bail!("file-state accepted previous digests must be unique");
        }
    }
    if let Some(executable) = state.validation_argv.first() {
        if !Path::new(executable).is_absolute() {
            bail!("file-state validator executable must be absolute");
        }
        if state
            .validation_argv
            .iter()
            .any(|argument| argument.contains('\0'))
        {
            bail!("file-state validator argv cannot contain NUL");
        }
    }
    for service in &state.reload_services {
        service.validate()?;
    }
    Ok(())
}

/// Apply file bytes without reloading consumers.
///
/// This preserves the original API for callers with no reload boundary. Jobs
/// should use [`apply_file_state_with_reload`] so replacement and reload share
/// one recoverable transaction.
pub fn apply_file_state(state: &FileStateDefinition) -> Result<FileStateResult> {
    let prepared = prepare_file_state(state)?;
    Ok(prepared.result)
}

/// Apply a file state and reload every declared consumer as one transaction.
///
/// A reload failure is represented in the returned value rather than as an
/// `Err`, allowing the durable job result to retain the digest receipt. The
/// previous file bytes and mode (or previous absence) are restored before the
/// controlled failure is returned.
pub fn apply_file_state_with_reload<T>(
    state: &FileStateDefinition,
    mut reload: impl FnMut(&ServiceTarget) -> Result<T>,
) -> Result<FileStateApplyResult<T>> {
    let mut prepared = prepare_file_state(state)?;
    let mut reloads = Vec::with_capacity(state.reload_services.len());
    for service in &state.reload_services {
        match reload(service) {
            Ok(result) => reloads.push(result),
            Err(error) => {
                let reload_error = format!("{error:#}");
                let restore_error = if prepared.result.changed {
                    restore_previous(
                        &state.path,
                        prepared.previous.take(),
                        prepared.previous_mode,
                    )
                    .err()
                    .map(|error| format!("{error:#}"))
                } else {
                    None
                };
                prepared.result.restored = prepared.result.changed && restore_error.is_none();
                let mut rollback_reloads = Vec::new();
                let mut rollback_reload_errors = Vec::new();
                if prepared.result.restored {
                    for service in &state.reload_services {
                        match reload(service) {
                            Ok(result) => rollback_reloads.push(result),
                            Err(error) => {
                                rollback_reload_errors.push(format!("{service}: {error:#}"))
                            }
                        }
                    }
                }
                let mut error = match restore_error {
                    Some(restore_error) => format!(
                        "file-state reload failed: {reload_error}; restoring previous state failed: {restore_error}"
                    ),
                    None => {
                        format!("file-state reload failed; previous state restored: {reload_error}")
                    }
                };
                if !rollback_reload_errors.is_empty() {
                    error.push_str(&format!(
                        "; reloading restored state failed: {}",
                        rollback_reload_errors.join("; ")
                    ));
                }
                return Ok(FileStateApplyResult {
                    file_state: prepared.result,
                    reloads,
                    rollback_reloads,
                    error: Some(error),
                });
            }
        }
    }
    Ok(FileStateApplyResult {
        file_state: prepared.result,
        reloads,
        rollback_reloads: Vec::new(),
        error: None,
    })
}

struct PreparedFileState {
    result: FileStateResult,
    previous: Option<Vec<u8>>,
    previous_mode: Option<u32>,
}

fn prepare_file_state(state: &FileStateDefinition) -> Result<PreparedFileState> {
    validate_file_state(state)?;
    let bytes = state.content.as_bytes();
    let previous = match fs::read(&state.path) {
        Ok(previous) => Some(previous),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => {
            return Err(error).with_context(|| format!("read {}", state.path.display()));
        }
    };
    let previous_mode = match fs::metadata(&state.path) {
        Ok(metadata) => Some(metadata.permissions().mode() & 0o7777),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => {
            return Err(error).with_context(|| format!("inspect {}", state.path.display()));
        }
    };
    let previous_sha256 = previous.as_deref().map(digest_bytes);
    let current_sha256 = digest_bytes(bytes);
    let mode_matches = previous_mode == Some(state.mode);
    // A lost acknowledgement may replay the same transaction after the new
    // bytes were already installed. Treat the exact desired bytes and mode as
    // success before evaluating the old-state compare-and-swap guard.
    if previous.as_deref() == Some(bytes) && mode_matches {
        return Ok(PreparedFileState {
            result: FileStateResult {
                path: state.path.clone(),
                changed: false,
                previous_sha256,
                current_sha256,
                restored: false,
            },
            previous,
            previous_mode,
        });
    }
    ensure_expected_previous(state, previous_sha256.as_deref(), "compare-and-swap failed")?;

    let parent = state
        .path
        .parent()
        .context("file-state path has no parent")?;
    fs::create_dir_all(parent)
        .with_context(|| format!("create file-state directory {}", parent.display()))?;
    let temporary = write_candidate(&state.path, bytes, state.mode)?;
    let replace = (|| -> Result<()> {
        validate_candidate(state, &temporary)?;
        recheck_expected_previous(state)?;
        fs::rename(&temporary, &state.path).with_context(|| {
            format!(
                "atomically replace {} from {}",
                state.path.display(),
                temporary.display()
            )
        })?;
        sync_directory(parent)
    })();
    if replace.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    replace?;
    Ok(PreparedFileState {
        result: FileStateResult {
            path: state.path.clone(),
            changed: true,
            previous_sha256,
            current_sha256,
            restored: false,
        },
        previous,
        previous_mode,
    })
}

fn recheck_expected_previous(state: &FileStateDefinition) -> Result<()> {
    if state.expected_previous_sha256.is_none() && state.accepted_previous_sha256.is_empty() {
        return Ok(());
    }
    let observed = match fs::read(&state.path) {
        Ok(bytes) => Some(digest_bytes(&bytes)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => {
            return Err(error).with_context(|| {
                format!(
                    "recheck file-state compare-and-swap {}",
                    state.path.display()
                )
            });
        }
    };
    ensure_expected_previous(state, observed.as_deref(), "changed while validating")
}

fn ensure_expected_previous(
    state: &FileStateDefinition,
    observed: Option<&str>,
    context: &str,
) -> Result<()> {
    let accepted = state
        .expected_previous_sha256
        .iter()
        .chain(state.accepted_previous_sha256.iter())
        .any(|expected| Some(expected.as_str()) == observed);
    if state.expected_previous_sha256.is_none() && state.accepted_previous_sha256.is_empty() {
        return Ok(());
    }
    if !accepted {
        let expected = state
            .expected_previous_sha256
            .iter()
            .chain(state.accepted_previous_sha256.iter())
            .cloned()
            .collect::<Vec<_>>()
            .join(", ");
        bail!(
            "file-state {context} for {}: expected previous sha256 in [{}], found {}",
            state.path.display(),
            expected,
            observed.unwrap_or("absent")
        );
    }
    Ok(())
}

fn validate_candidate(state: &FileStateDefinition, candidate: &Path) -> Result<()> {
    let Some(executable) = state.validation_argv.first() else {
        return Ok(());
    };
    let output = CommandSpec::new(executable)
        .args(&state.validation_argv[1..])
        .arg(candidate)
        .output()
        .with_context(|| format!("validate file-state candidate {}", candidate.display()))?;
    if !output.success {
        bail!(
            "file-state candidate validator exited with status {:?}: {}",
            output.exit_code,
            output.stderr
        );
    }
    Ok(())
}

fn restore_previous(
    path: &Path,
    previous: Option<Vec<u8>>,
    previous_mode: Option<u32>,
) -> Result<()> {
    let parent = path.parent().context("file-state path has no parent")?;
    match (previous, previous_mode) {
        (Some(bytes), Some(mode)) => {
            let temporary = write_candidate(path, &bytes, mode)?;
            let restore = fs::rename(&temporary, path)
                .with_context(|| format!("restore previous file state {}", path.display()));
            if restore.is_err() {
                let _ = fs::remove_file(&temporary);
            }
            restore?;
        }
        (None, None) => match fs::remove_file(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("remove rolled-back {}", path.display()));
            }
        },
        _ => bail!(
            "previous file-state bytes and mode disagree for {}",
            path.display()
        ),
    }
    sync_directory(parent)
}

fn write_candidate(path: &Path, bytes: &[u8], mode: u32) -> Result<PathBuf> {
    let parent = path.parent().context("file-state path has no parent")?;
    let sequence = STATE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temporary = parent.join(format!(
        ".abird-file-state.{}.{}.tmp",
        std::process::id(),
        sequence
    ));
    let write = (|| -> Result<()> {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(mode)
            .open(&temporary)
            .with_context(|| format!("create {}", temporary.display()))?;
        file.write_all(bytes)
            .with_context(|| format!("write {}", temporary.display()))?;
        file.sync_all()
            .with_context(|| format!("sync {}", temporary.display()))?;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(mode))
            .with_context(|| format!("set mode on {}", temporary.display()))
    })();
    if write.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    write?;
    Ok(temporary)
}

fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)
        .with_context(|| format!("open directory {}", path.display()))?
        .sync_all()
        .with_context(|| format!("sync directory {}", path.display()))
}

fn validate_sha256(label: &str, value: &str) -> Result<()> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
    {
        bail!("{label} must be a lowercase SHA-256 digest");
    }
    Ok(())
}

fn default_mode() -> u32 {
    0o644
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(path: PathBuf, content: &str) -> FileStateDefinition {
        FileStateDefinition {
            path,
            content: content.to_owned(),
            mode: 0o640,
            reload_services: Vec::new(),
            expected_previous_sha256: None,
            accepted_previous_sha256: Vec::new(),
            validation_argv: Vec::new(),
        }
    }

    #[test]
    fn atomically_applies_idempotent_file_state() {
        let temp = tempfile::tempdir().unwrap();
        let state = state(temp.path().join("route"), "target\n");
        assert!(apply_file_state(&state).unwrap().changed);
        assert!(!apply_file_state(&state).unwrap().changed);
        assert_eq!(fs::read_to_string(&state.path).unwrap(), "target\n");
        assert_eq!(
            fs::metadata(&state.path).unwrap().permissions().mode() & 0o7777,
            0o640
        );
    }

    #[test]
    fn compare_and_swap_rejects_drift_before_replacement() {
        let temp = tempfile::tempdir().unwrap();
        let mut state = state(temp.path().join("route"), "target\n");
        fs::write(&state.path, "source\n").unwrap();
        state.expected_previous_sha256 = Some(digest_bytes(b"unexpected\n"));
        let error = apply_file_state(&state).unwrap_err();
        assert!(error.to_string().contains("compare-and-swap failed"));
        assert_eq!(fs::read_to_string(&state.path).unwrap(), "source\n");
    }

    #[test]
    fn compare_and_swap_replay_accepts_the_already_installed_state() {
        let temp = tempfile::tempdir().unwrap();
        let mut state = state(temp.path().join("route"), "target\n");
        fs::write(&state.path, "source\n").unwrap();
        fs::set_permissions(&state.path, fs::Permissions::from_mode(0o640)).unwrap();
        state.expected_previous_sha256 = Some(digest_bytes(b"source\n"));
        assert!(apply_file_state(&state).unwrap().changed);
        assert!(!apply_file_state(&state).unwrap().changed);
    }

    #[test]
    fn allowlisted_compare_and_swap_accepts_any_declared_profile_only() {
        let temp = tempfile::tempdir().unwrap();
        let mut state = state(temp.path().join("route"), "third\n");
        fs::write(&state.path, "second\n").unwrap();
        state.accepted_previous_sha256 = vec![digest_bytes(b"first\n"), digest_bytes(b"second\n")];
        assert!(apply_file_state(&state).unwrap().changed);

        fs::write(&state.path, "drift\n").unwrap();
        let error = apply_file_state(&state).unwrap_err();
        assert!(error.to_string().contains("compare-and-swap failed"));
    }

    #[test]
    fn compare_and_swap_guard_forms_are_mutually_exclusive() {
        let temp = tempfile::tempdir().unwrap();
        let mut state = state(temp.path().join("route"), "target\n");
        state.expected_previous_sha256 = Some(digest_bytes(b"source\n"));
        state.accepted_previous_sha256 = vec![digest_bytes(b"other\n")];
        let error = validate_file_state(&state).unwrap_err();
        assert!(error.to_string().contains("mutually exclusive"));
    }

    fn executable(name: &str) -> String {
        std::env::split_paths(&std::env::var_os("PATH").unwrap())
            .map(|directory| directory.join(name))
            .find(|path| path.is_file())
            .unwrap()
            .to_string_lossy()
            .into_owned()
    }

    #[test]
    fn validator_rejects_before_replacement() {
        let temp = tempfile::tempdir().unwrap();
        let mut state = state(temp.path().join("route"), "target\n");
        fs::write(&state.path, "source\n").unwrap();
        state.validation_argv = vec![executable("true")];
        apply_file_state(&state).unwrap();

        state.content = String::new();
        state.validation_argv = vec![executable("false")];
        assert!(apply_file_state(&state).is_err());
        assert_eq!(fs::read_to_string(&state.path).unwrap(), "target\n");
    }

    #[test]
    fn reload_failure_restores_previous_bytes_and_mode_with_receipt() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("route");
        fs::write(&path, "source\n").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let mut state = state(path.clone(), "target\n");
        state.reload_services = vec![ServiceTarget::system("nginx.service")];

        let result = apply_file_state_with_reload(&state, |_| -> Result<()> {
            bail!("injected reload failure")
        })
        .unwrap();
        assert!(result.error.unwrap().contains("previous state restored"));
        assert!(result.file_state.changed);
        assert!(result.file_state.restored);
        assert_eq!(
            result.file_state.previous_sha256,
            Some(digest_bytes(b"source\n"))
        );
        assert_eq!(result.file_state.current_sha256, digest_bytes(b"target\n"));
        assert_eq!(fs::read_to_string(path).unwrap(), "source\n");
        assert_eq!(
            fs::metadata(&state.path).unwrap().permissions().mode() & 0o7777,
            0o600
        );
    }

    #[test]
    fn reload_failure_restores_previous_absence() {
        let temp = tempfile::tempdir().unwrap();
        let mut state = state(temp.path().join("route"), "target\n");
        state.reload_services = vec![ServiceTarget::system("nginx.service")];

        let result = apply_file_state_with_reload(&state, |_| -> Result<()> {
            bail!("injected reload failure")
        })
        .unwrap();
        assert!(result.file_state.restored);
        assert!(!state.path.exists());
    }

    #[test]
    fn restored_state_is_reloaded_after_a_partial_reload() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("route");
        fs::write(&path, "source\n").unwrap();
        let mut state = state(path.clone(), "target\n");
        state.reload_services = vec![
            ServiceTarget::system("first.service"),
            ServiceTarget::system("second.service"),
        ];
        let mut attempts = 0;

        let result = apply_file_state_with_reload(&state, |_| {
            attempts += 1;
            if attempts == 2 {
                bail!("injected second reload failure");
            }
            Ok(attempts)
        })
        .unwrap();
        assert_eq!(result.reloads, vec![1]);
        assert_eq!(result.rollback_reloads, vec![3, 4]);
        assert!(result.file_state.restored);
        assert_eq!(fs::read_to_string(path).unwrap(), "source\n");
    }

    #[test]
    fn legacy_definition_deserializes_without_transaction_fields() {
        let state: FileStateDefinition = serde_json::from_value(serde_json::json!({
            "path": "/etc/nginx/route.conf",
            "content": "source\n"
        }))
        .unwrap();
        assert_eq!(state.mode, 0o644);
        assert!(state.expected_previous_sha256.is_none());
        assert!(state.validation_argv.is_empty());
    }
}
