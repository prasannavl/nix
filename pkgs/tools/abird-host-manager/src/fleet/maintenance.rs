//! Dependency checks and bounded cleanup for the fleet compatibility surface.

use std::ffi::OsStr;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use anyhow::{Context, Result, bail};

pub const REQUIRED_PROGRAMS: &[&str] = &[
    "nix",
    "age",
    "cloudflared",
    "git",
    "jq",
    "nproc",
    "pgrep",
    "ssh",
    "scp",
    "ssh-keyscan",
    "ssh-keygen",
    "stty",
    "timeout",
    "tofu",
];

#[derive(Clone, Copy, Debug)]
pub enum CleanMode {
    Automatic {
        older_than: Duration,
        now: SystemTime,
    },
    All,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CleanOutcome {
    Absent,
    Retained,
    WouldRemove,
    Removed,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CleanReport {
    pub outcomes: Vec<(PathBuf, CleanOutcome)>,
    pub removed: Vec<PathBuf>,
}

pub fn missing_programs(search_paths: &[PathBuf]) -> Result<Vec<String>> {
    let mut missing = Vec::new();
    for program in REQUIRED_PROGRAMS {
        if !search_paths.iter().any(|directory| {
            let candidate = directory.join(program);
            fs::metadata(candidate).is_ok_and(|metadata| {
                metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
            })
        }) {
            missing.push((*program).to_owned());
        }
    }
    Ok(missing)
}

pub fn clean_roots<I, P>(roots: I, mode: CleanMode, dry_run: bool) -> Result<CleanReport>
where
    I: IntoIterator<Item = P>,
    P: AsRef<Path>,
{
    let mut report = CleanReport::default();
    for root in roots {
        let root = root.as_ref();
        validate_cleanup_root(root)?;
        match mode {
            CleanMode::All => clean_entire_root(root, dry_run, &mut report)?,
            CleanMode::Automatic { older_than, now } => {
                clean_old_children(root, older_than, now, dry_run, &mut report)?
            }
        }
    }
    Ok(report)
}

fn validate_cleanup_root(root: &Path) -> Result<()> {
    if !root.is_absolute() || root == Path::new("/") {
        bail!(
            "cleanup root must be an absolute non-root path: {}",
            root.display()
        );
    }
    Ok(())
}

fn clean_entire_root(root: &Path, dry_run: bool, report: &mut CleanReport) -> Result<()> {
    let metadata = match fs::symlink_metadata(root) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            report
                .outcomes
                .push((root.to_path_buf(), CleanOutcome::Absent));
            return Ok(());
        }
        Err(error) => return Err(error).with_context(|| format!("inspect {}", root.display())),
    };
    if dry_run {
        report
            .outcomes
            .push((root.to_path_buf(), CleanOutcome::WouldRemove));
        return Ok(());
    }
    remove_no_follow(root, &metadata)?;
    report
        .outcomes
        .push((root.to_path_buf(), CleanOutcome::Removed));
    report.removed.push(root.to_path_buf());
    Ok(())
}

fn clean_old_children(
    root: &Path,
    older_than: Duration,
    now: SystemTime,
    dry_run: bool,
    report: &mut CleanReport,
) -> Result<()> {
    let metadata = match fs::symlink_metadata(root) {
        Ok(metadata) if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() => {
            metadata
        }
        Ok(_) => {
            report
                .outcomes
                .push((root.to_path_buf(), CleanOutcome::Retained));
            return Ok(());
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            report
                .outcomes
                .push((root.to_path_buf(), CleanOutcome::Absent));
            return Ok(());
        }
        Err(error) => return Err(error).with_context(|| format!("inspect {}", root.display())),
    };
    let _ = metadata;

    for entry in fs::read_dir(root).with_context(|| format!("list {}", root.display()))? {
        let entry = entry.with_context(|| format!("read entry below {}", root.display()))?;
        let name = entry.file_name();
        if !owned_cleanup_name(&name) {
            continue;
        }
        let child = entry.path();
        let metadata = fs::symlink_metadata(&child)
            .with_context(|| format!("inspect cleanup candidate {}", child.display()))?;
        if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
            continue;
        }
        let modified = metadata
            .modified()
            .with_context(|| format!("read modification time for {}", child.display()))?;
        if now.duration_since(modified).unwrap_or_default() <= older_than {
            continue;
        }
        if dry_run {
            report.outcomes.push((child, CleanOutcome::WouldRemove));
        } else {
            remove_no_follow(&child, &metadata)?;
            report.outcomes.push((child.clone(), CleanOutcome::Removed));
            report.removed.push(child);
        }
    }
    Ok(())
}

fn owned_cleanup_name(name: &OsStr) -> bool {
    name.to_str()
        .is_some_and(|name| name.starts_with("run-") || name.starts_with("diag-"))
}

fn remove_no_follow(path: &Path, metadata: &fs::Metadata) -> Result<()> {
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        fs::remove_file(path).with_context(|| format!("remove {}", path.display()))
    } else {
        // The caller inspected this exact path with symlink_metadata. Rust's
        // remove_dir_all does not follow a root symlink; descendants are also
        // unlinked rather than traversed when they are symlinks.
        fs::remove_dir_all(path).with_context(|| format!("remove {}", path.display()))
    }
}
