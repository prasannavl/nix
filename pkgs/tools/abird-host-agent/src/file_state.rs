use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

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
}

#[derive(Debug, Serialize)]
pub struct FileStateResult {
    pub path: PathBuf,
    pub changed: bool,
    pub previous_sha256: Option<String>,
    pub current_sha256: String,
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
    Ok(())
}

pub fn apply_file_state(state: &FileStateDefinition) -> Result<FileStateResult> {
    validate_file_state(state)?;
    let bytes = state.content.as_bytes();
    let previous = match fs::read(&state.path) {
        Ok(previous) => Some(previous),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => {
            return Err(error).with_context(|| format!("read {}", state.path.display()));
        }
    };
    let previous_sha256 = previous.as_deref().map(digest_bytes);
    let current_sha256 = digest_bytes(bytes);
    let mode_matches = fs::metadata(&state.path)
        .map(|metadata| metadata.permissions().mode() & 0o7777 == state.mode)
        .unwrap_or(false);
    if previous.as_deref() == Some(bytes) && mode_matches {
        return Ok(FileStateResult {
            path: state.path.clone(),
            changed: false,
            previous_sha256,
            current_sha256,
        });
    }

    let parent = state
        .path
        .parent()
        .context("file-state path has no parent")?;
    fs::create_dir_all(parent)
        .with_context(|| format!("create file-state directory {}", parent.display()))?;
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
            .mode(state.mode)
            .open(&temporary)
            .with_context(|| format!("create {}", temporary.display()))?;
        file.write_all(bytes)
            .with_context(|| format!("write {}", temporary.display()))?;
        file.sync_all()
            .with_context(|| format!("sync {}", temporary.display()))?;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(state.mode))
            .with_context(|| format!("set mode on {}", temporary.display()))?;
        fs::rename(&temporary, &state.path).with_context(|| {
            format!(
                "atomically replace {} from {}",
                state.path.display(),
                temporary.display()
            )
        })?;
        File::open(parent)
            .with_context(|| format!("open directory {}", parent.display()))?
            .sync_all()
            .with_context(|| format!("sync directory {}", parent.display()))
    })();
    if write.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    write?;
    Ok(FileStateResult {
        path: state.path.clone(),
        changed: true,
        previous_sha256,
        current_sha256,
    })
}

fn default_mode() -> u32 {
    0o644
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn atomically_applies_idempotent_file_state() {
        let temp = tempfile::tempdir().unwrap();
        let state = FileStateDefinition {
            path: temp.path().join("route"),
            content: "target\n".to_owned(),
            mode: 0o640,
            reload_services: Vec::new(),
        };
        assert!(apply_file_state(&state).unwrap().changed);
        assert!(!apply_file_state(&state).unwrap().changed);
        assert_eq!(fs::read_to_string(&state.path).unwrap(), "target\n");
        assert_eq!(
            fs::metadata(&state.path).unwrap().permissions().mode() & 0o7777,
            0o640
        );
    }
}
