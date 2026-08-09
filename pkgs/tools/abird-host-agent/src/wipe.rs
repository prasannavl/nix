use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::Serialize;

use crate::manifest::{EntryKind, create_manifest_roots, is_exclude_protected, is_excluded};
use crate::resource::{DataRoot, validate_data_root};
use crate::transfer::{CopyEngine, TransferProgress};

#[derive(Debug, Serialize)]
pub struct WipeResult {
    pub roots: Vec<WipedRoot>,
    pub entries_removed: usize,
    pub bytes_removed: u64,
    pub verified_empty: bool,
}

#[derive(Debug, Serialize)]
pub struct WipedRoot {
    pub name: String,
    pub path: PathBuf,
    pub excludes: Vec<PathBuf>,
    pub entries_removed: usize,
    pub bytes_removed: u64,
}

#[derive(Default)]
struct RemovalCount {
    entries: usize,
    bytes: u64,
}

struct ProgressTracker<'a, F> {
    callback: &'a mut F,
    completed: RemovalCount,
    total: RemovalCount,
}

impl<F> ProgressTracker<'_, F>
where
    F: FnMut(&TransferProgress) -> Result<()>,
{
    fn report(&mut self, stage: &str, detail: &str) -> Result<()> {
        (self.callback)(&TransferProgress {
            stage: stage.to_owned(),
            engine: Some(CopyEngine::Filesystem),
            entries_completed: self.completed.entries.min(self.total.entries),
            bytes_completed: self.completed.bytes.min(self.total.bytes),
            total_entries: self.total.entries,
            total_bytes: self.total.bytes,
            detail: detail.to_owned(),
        })
    }

    fn removed(&mut self, metadata: &fs::Metadata) -> Result<()> {
        self.completed.entries = self.completed.entries.saturating_add(1);
        if metadata.is_file() {
            self.completed.bytes = self.completed.bytes.saturating_add(metadata.len());
        }
        if self.completed.entries.is_multiple_of(128)
            || self.completed.entries >= self.total.entries
        {
            self.report("wiping", "removing declared resource data")?;
        }
        Ok(())
    }
}

pub fn wipe_data_roots(
    roots: &[DataRoot],
    mut progress: impl FnMut(&TransferProgress) -> Result<()>,
) -> Result<WipeResult> {
    validate_roots(roots)?;
    let totals = roots
        .iter()
        .map(count_removals)
        .collect::<Result<Vec<_>>>()?;
    let total = RemovalCount {
        entries: totals.iter().map(|count| count.entries).sum(),
        bytes: totals.iter().map(|count| count.bytes).sum(),
    };
    let mut tracker = ProgressTracker {
        callback: &mut progress,
        completed: RemovalCount::default(),
        total,
    };
    tracker.report("wiping", "validated declared roots; beginning removal")?;

    let mut wiped = Vec::with_capacity(roots.len());
    for root in roots {
        let before_entries = tracker.completed.entries;
        let before_bytes = tracker.completed.bytes;
        wipe_root(root, &mut tracker)?;
        wiped.push(WipedRoot {
            name: root.name.clone(),
            path: root.path.clone(),
            excludes: root.excludes.clone(),
            entries_removed: tracker.completed.entries - before_entries,
            bytes_removed: tracker.completed.bytes - before_bytes,
        });
    }

    tracker.report("verifying", "verifying every owned data root is empty")?;
    verify_empty(roots)?;
    tracker.report(
        "completed",
        "data wipe and independent verification succeeded",
    )?;

    Ok(WipeResult {
        entries_removed: tracker.completed.entries,
        bytes_removed: tracker.completed.bytes,
        roots: wiped,
        verified_empty: true,
    })
}

fn validate_roots(roots: &[DataRoot]) -> Result<()> {
    if roots.is_empty() {
        bail!("data wipe requires at least one declared data root");
    }
    let mut canonical = Vec::with_capacity(roots.len());
    for root in roots {
        validate_data_root(root)?;
        let metadata = fs::symlink_metadata(&root.path)
            .with_context(|| format!("inspect data root {}", root.path.display()))?;
        if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
            bail!(
                "data root must be an existing directory, not a symlink: {}",
                root.path.display()
            );
        }
        let path = fs::canonicalize(&root.path)
            .with_context(|| format!("canonicalize data root {}", root.path.display()))?;
        if path == Path::new("/") {
            bail!("data wipe cannot target the filesystem root");
        }
        canonical.push(path);
    }
    for (index, path) in canonical.iter().enumerate() {
        for other in &canonical[index + 1..] {
            if path.starts_with(other) || other.starts_with(path) {
                bail!(
                    "data wipe roots cannot overlap: {} and {}",
                    path.display(),
                    other.display()
                );
            }
        }
    }
    Ok(())
}

fn count_removals(root: &DataRoot) -> Result<RemovalCount> {
    let mut count = RemovalCount::default();
    for entry in sorted_entries(&root.path)? {
        count_path(
            &entry.path(),
            &PathBuf::from(entry.file_name()),
            &root.excludes,
            &mut count,
        )?;
    }
    Ok(count)
}

fn count_path(
    path: &Path,
    relative: &Path,
    excludes: &[PathBuf],
    count: &mut RemovalCount,
) -> Result<()> {
    if is_excluded(relative, excludes) {
        return Ok(());
    }
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect wipe candidate {}", path.display()))?;
    if is_strict_exclude_ancestor(relative, excludes) {
        if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
            bail!(
                "data-root exclude ancestor must be a directory, not a symlink: {}",
                path.display()
            );
        }
        for entry in sorted_entries(path)? {
            count_path(
                &entry.path(),
                &relative.join(entry.file_name()),
                excludes,
                count,
            )?;
        }
        return Ok(());
    }
    count.entries = count.entries.saturating_add(1);
    if metadata.is_file() {
        count.bytes = count.bytes.saturating_add(metadata.len());
    }
    if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() {
        for entry in sorted_entries(path)? {
            count_path(
                &entry.path(),
                &relative.join(entry.file_name()),
                excludes,
                count,
            )?;
        }
    }
    Ok(())
}

fn wipe_root(
    root: &DataRoot,
    tracker: &mut ProgressTracker<'_, impl FnMut(&TransferProgress) -> Result<()>>,
) -> Result<()> {
    for entry in sorted_entries(&root.path)? {
        wipe_path(
            &entry.path(),
            &PathBuf::from(entry.file_name()),
            &root.excludes,
            tracker,
        )?;
    }
    Ok(())
}

fn wipe_path(
    path: &Path,
    relative: &Path,
    excludes: &[PathBuf],
    tracker: &mut ProgressTracker<'_, impl FnMut(&TransferProgress) -> Result<()>>,
) -> Result<()> {
    if is_excluded(relative, excludes) {
        return Ok(());
    }
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect wipe candidate {}", path.display()))?;
    if is_strict_exclude_ancestor(relative, excludes) {
        if !metadata.file_type().is_dir() || metadata.file_type().is_symlink() {
            bail!(
                "data-root exclude ancestor must remain a directory: {}",
                path.display()
            );
        }
        for entry in sorted_entries(path)? {
            wipe_path(
                &entry.path(),
                &relative.join(entry.file_name()),
                excludes,
                tracker,
            )?;
        }
        return Ok(());
    }
    if metadata.file_type().is_dir() && !metadata.file_type().is_symlink() {
        for entry in sorted_entries(path)? {
            wipe_path(
                &entry.path(),
                &relative.join(entry.file_name()),
                excludes,
                tracker,
            )?;
        }
        fs::remove_dir(path).with_context(|| format!("remove directory {}", path.display()))?;
    } else {
        fs::remove_file(path).with_context(|| format!("remove data entry {}", path.display()))?;
    }
    tracker.removed(&metadata)
}

fn verify_empty(roots: &[DataRoot]) -> Result<()> {
    let manifest = create_manifest_roots(roots)?;
    for root in &manifest.roots {
        for entry in &root.entries {
            let relative = Path::new(&entry.path);
            if relative == Path::new(".") {
                continue;
            }
            if is_exclude_protected(relative, &root.excludes) && entry.kind == EntryKind::Directory
            {
                continue;
            }
            bail!(
                "data wipe verification found owned entry {:?} below {}",
                entry.path,
                root.declared_path
            );
        }
    }
    Ok(())
}

fn is_strict_exclude_ancestor(relative: &Path, excludes: &[PathBuf]) -> bool {
    excludes
        .iter()
        .any(|exclude| exclude.starts_with(relative) && exclude != relative)
}

fn sorted_entries(path: &Path) -> Result<Vec<fs::DirEntry>> {
    let mut entries = fs::read_dir(path)
        .with_context(|| format!("list directory {}", path.display()))?
        .collect::<std::io::Result<Vec<_>>>()?;
    entries.sort_by_key(|entry| entry.file_name());
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::symlink;

    use super::*;

    fn root(path: PathBuf, excludes: Vec<PathBuf>) -> DataRoot {
        DataRoot {
            name: "data".to_owned(),
            path,
            excludes,
        }
    }

    #[test]
    fn wipe_preserves_root_and_removes_owned_contents() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("data");
        fs::create_dir_all(path.join("nested")).unwrap();
        fs::write(path.join("nested/value"), b"zulip").unwrap();
        symlink("nested/value", path.join("link")).unwrap();

        let mut progress = Vec::new();
        let result = wipe_data_roots(&[root(path.clone(), Vec::new())], |event| {
            progress.push(event.clone());
            Ok(())
        })
        .unwrap();

        assert!(path.is_dir());
        assert_eq!(fs::read_dir(&path).unwrap().count(), 0);
        assert_eq!(result.entries_removed, 3);
        assert_eq!(result.bytes_removed, 5);
        assert!(result.verified_empty);
        assert_eq!(progress.last().unwrap().stage, "completed");
    }

    #[test]
    fn nested_exclude_preserves_only_its_subtree_and_ancestors() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("data");
        fs::create_dir_all(path.join("runtime/cache")).unwrap();
        fs::write(path.join("runtime/cache/keep"), b"keep").unwrap();
        fs::write(path.join("runtime/remove"), b"remove").unwrap();
        fs::write(path.join("stale"), b"stale").unwrap();

        let result = wipe_data_roots(
            &[root(path.clone(), vec![PathBuf::from("runtime/cache")])],
            |_| Ok(()),
        )
        .unwrap();

        assert_eq!(fs::read(path.join("runtime/cache/keep")).unwrap(), b"keep");
        assert!(!path.join("runtime/remove").exists());
        assert!(!path.join("stale").exists());
        assert_eq!(result.entries_removed, 2);
    }

    #[test]
    fn wipe_rejects_symlink_roots_and_overlapping_roots_before_deletion() {
        let temp = tempfile::tempdir().unwrap();
        let first = temp.path().join("first");
        let nested = first.join("nested");
        fs::create_dir_all(&nested).unwrap();
        fs::write(first.join("keep"), b"keep").unwrap();
        let link = temp.path().join("link");
        symlink(&first, &link).unwrap();

        assert!(wipe_data_roots(&[root(link, Vec::new())], |_| Ok(())).is_err());
        assert!(
            wipe_data_roots(
                &[root(first.clone(), Vec::new()), root(nested, Vec::new())],
                |_| Ok(())
            )
            .is_err()
        );
        assert_eq!(fs::read(first.join("keep")).unwrap(), b"keep");
    }
}
