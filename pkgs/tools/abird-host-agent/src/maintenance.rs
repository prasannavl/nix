use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::Serialize;

use crate::programs::podman::Podman;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CleanKind {
    Deploy,
    Podman,
    Nixbot,
}

#[derive(Debug, Serialize)]
pub struct CleanResult {
    pub removed: Vec<PathBuf>,
    pub held: Vec<HeldPath>,
    pub removed_volumes: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct HeldPath {
    pub path: PathBuf,
    pub holders: Vec<PathBuf>,
}

pub fn clean(kind: CleanKind, force_held: bool, podman: &Path) -> Result<CleanResult> {
    let mut candidates = Vec::new();
    if matches!(kind, CleanKind::Deploy | CleanKind::Nixbot) {
        for root in [
            Path::new("/dev/shm/nixbot"),
            Path::new("/tmp/nixbot"),
            Path::new("/var/lib/nixbot"),
        ] {
            collect_matching(root, root, &mut candidates, &is_nixbot_lock)?;
        }
    }
    if matches!(kind, CleanKind::Deploy | CleanKind::Podman) {
        for root in [Path::new("/run/user"), Path::new("/var/lib")] {
            collect_matching(root, root, &mut candidates, &is_podman_lock)?;
        }
    }
    candidates.sort();
    candidates.dedup();

    let mut removed = Vec::new();
    let mut held = Vec::new();
    for path in candidates {
        let holders = lock_holders(&path)?;
        if !holders.is_empty() && !force_held {
            held.push(HeldPath { path, holders });
            continue;
        }
        remove_exact(&path)?;
        removed.push(path);
    }
    let removed_volumes = if matches!(kind, CleanKind::Deploy | CleanKind::Podman) {
        clean_unused_anonymous_volumes(podman)?
    } else {
        Vec::new()
    };
    Ok(CleanResult {
        removed,
        held,
        removed_volumes,
    })
}

fn collect_matching(
    root: &Path,
    path: &Path,
    output: &mut Vec<PathBuf>,
    predicate: &impl Fn(&Path) -> bool,
) -> Result<()> {
    let Ok(root_metadata) = fs::metadata(root) else {
        return Ok(());
    };
    let root_device = root_metadata.dev();
    collect_matching_device(path, root_device, output, predicate)
}

fn collect_matching_device(
    path: &Path,
    root_device: u64,
    output: &mut Vec<PathBuf>,
    predicate: &impl Fn(&Path) -> bool,
) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error).with_context(|| format!("inspect {}", path.display())),
    };
    if metadata.dev() != root_device {
        return Ok(());
    }
    if predicate(path) {
        output.push(path.to_path_buf());
        return Ok(());
    }
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Ok(());
    }
    for entry in fs::read_dir(path).with_context(|| format!("read {}", path.display()))? {
        let entry = entry?;
        collect_matching_device(&entry.path(), root_device, output, predicate)?;
    }
    Ok(())
}

fn is_nixbot_lock(path: &Path) -> bool {
    let name = path.file_name().and_then(|name| name.to_str());
    matches!(
        name,
        Some("ssh-tty.lock" | "nixbot-worktree.lock" | ".nixbot-worktree.lock")
    ) || (name.is_some_and(|name| name.ends_with(".lock"))
        && path
            .parent()
            .and_then(Path::file_name)
            .and_then(|name| name.to_str())
            == Some("state-locks"))
}

fn is_podman_lock(path: &Path) -> bool {
    matches!(
        path.file_name().and_then(|name| name.to_str()),
        Some("rootless-lifecycle-v1.lock")
    ) || (path.file_name().and_then(|name| name.to_str()) == Some("lifecycle.lock")
        && path
            .parent()
            .and_then(Path::file_name)
            .and_then(|name| name.to_str())
            == Some(".podman-compose"))
}

fn lock_holders(path: &Path) -> Result<Vec<PathBuf>> {
    let mut holders = Vec::new();
    let proc = Path::new("/proc");
    for process in fs::read_dir(proc).context("read /proc")? {
        let process = process?;
        if !process
            .file_name()
            .to_string_lossy()
            .bytes()
            .all(|byte| byte.is_ascii_digit())
        {
            continue;
        }
        let fd_root = process.path().join("fd");
        let Ok(entries) = fs::read_dir(&fd_root) else {
            continue;
        };
        for entry in entries.flatten() {
            let Ok(target) = fs::read_link(entry.path()) else {
                continue;
            };
            if target == path || target.to_string_lossy() == format!("{} (deleted)", path.display())
            {
                holders.push(entry.path());
            }
        }
    }
    Ok(holders)
}

fn remove_exact(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect cleanup path {}", path.display()))?;
    if metadata.is_dir() && !metadata.file_type().is_symlink() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
    .with_context(|| format!("remove cleanup path {}", path.display()))
}

fn clean_unused_anonymous_volumes(program: &Path) -> Result<Vec<String>> {
    let podman = Podman::new(program)?;
    let listed = podman.volume_names()?;
    if !listed.success {
        return Ok(Vec::new());
    }
    let mut removed = Vec::new();
    for volume in listed
        .stdout
        .lines()
        .filter(|volume| volume.len() == 64 && volume.bytes().all(|byte| byte.is_ascii_hexdigit()))
    {
        let used = podman.containers_using_volume(volume)?;
        if !used.success || !used.stdout.trim().is_empty() {
            continue;
        }
        let result = podman.remove_volume(volume)?;
        if result.success {
            removed.push(volume.to_owned());
        }
    }
    Ok(removed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_only_owned_lock_names() {
        assert!(is_nixbot_lock(Path::new("/tmp/nixbot/state-locks/a.lock")));
        assert!(is_podman_lock(Path::new(
            "/var/lib/a/.podman-compose/lifecycle.lock"
        )));
        assert!(!is_nixbot_lock(Path::new("/tmp/unrelated.lock")));
        assert!(!is_podman_lock(Path::new("/var/lib/a/lifecycle.lock")));
    }
}
