use std::fs::{self, File, Metadata};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::metadata::xattrs_digest;
use crate::resource::{DataRoot, validate_data_root};
use crate::sha256::{digest_reader, to_hex};

#[derive(Debug, Deserialize, Serialize)]
pub struct DataManifest {
    pub schema_version: u32,
    pub hash_algorithm: String,
    pub roots: Vec<ManifestRoot>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct ManifestRoot {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub name: String,
    pub declared_path: String,
    pub declared_path_bytes_hex: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub excludes: Vec<PathBuf>,
    pub entries: Vec<ManifestEntry>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ManifestEntry {
    pub path: String,
    pub path_bytes_hex: String,
    pub kind: EntryKind,
    pub size: u64,
    pub mode: u32,
    pub uid: u32,
    pub gid: u32,
    pub device: u64,
    pub inode: u64,
    #[serde(default)]
    pub rdev: u64,
    pub modified_seconds: i64,
    pub modified_nanoseconds: i64,
    pub xattrs_sha256: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub symlink_target: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub symlink_target_bytes_hex: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    File,
    Directory,
    Symlink,
    BlockDevice,
    CharacterDevice,
    Fifo,
    Socket,
    Other,
}

pub fn create_manifest(paths: &[PathBuf]) -> Result<DataManifest> {
    if paths.is_empty() {
        bail!("at least one --path is required");
    }

    let roots = paths
        .iter()
        .enumerate()
        .map(|(index, path)| DataRoot {
            name: format!("diagnostic-{index}"),
            path: path.clone(),
            excludes: Vec::new(),
        })
        .collect::<Vec<_>>();
    create_manifest_roots(&roots)
}

pub fn create_manifest_roots(data_roots: &[DataRoot]) -> Result<DataManifest> {
    if data_roots.is_empty() {
        bail!("at least one data root is required");
    }

    let mut roots = Vec::with_capacity(data_roots.len());
    for root in data_roots {
        validate_data_root(root)?;
        let mut entries = Vec::new();
        visit(&root.path, Path::new("."), &root.excludes, &mut entries)
            .with_context(|| format!("manifest declared path {}", root.path.display()))?;
        roots.push(ManifestRoot {
            name: root.name.clone(),
            declared_path: root.path.as_os_str().to_string_lossy().into_owned(),
            declared_path_bytes_hex: to_hex(root.path.as_os_str().as_bytes()),
            excludes: root.excludes.clone(),
            entries,
        });
    }

    Ok(DataManifest {
        schema_version: 1,
        hash_algorithm: "sha256".to_owned(),
        roots,
    })
}

fn visit(
    absolute: &Path,
    relative: &Path,
    excludes: &[PathBuf],
    entries: &mut Vec<ManifestEntry>,
) -> Result<()> {
    if relative != Path::new(".") && is_excluded(relative, excludes) {
        return Ok(());
    }
    let metadata = fs::symlink_metadata(absolute)
        .with_context(|| format!("read metadata for {}", absolute.display()))?;
    let file_type = metadata.file_type();
    let kind = entry_kind(&file_type);

    let (sha256, symlink_target, symlink_target_bytes_hex) = if file_type.is_file() {
        let file = File::open(absolute)
            .with_context(|| format!("open {} for read-only hashing", absolute.display()))?;
        let hash = digest_reader(file)
            .with_context(|| format!("calculate SHA-256 for {}", absolute.display()))?;
        let after = fs::symlink_metadata(absolute)
            .with_context(|| format!("re-read metadata for {}", absolute.display()))?;
        if file_identity_changed(&metadata, &after) {
            bail!("file changed while being hashed: {}", absolute.display());
        }
        (Some(hash), None, None)
    } else if file_type.is_symlink() {
        let target = fs::read_link(absolute)
            .with_context(|| format!("read symlink {}", absolute.display()))?;
        (
            None,
            Some(target.as_os_str().to_string_lossy().into_owned()),
            Some(to_hex(target.as_os_str().as_bytes())),
        )
    } else {
        (None, None, None)
    };

    entries.push(ManifestEntry {
        path: relative.as_os_str().to_string_lossy().into_owned(),
        path_bytes_hex: to_hex(relative.as_os_str().as_bytes()),
        kind,
        size: metadata.len(),
        mode: metadata.mode(),
        uid: metadata.uid(),
        gid: metadata.gid(),
        device: metadata.dev(),
        inode: metadata.ino(),
        rdev: metadata.rdev(),
        modified_seconds: metadata.mtime(),
        modified_nanoseconds: metadata.mtime_nsec(),
        xattrs_sha256: xattrs_digest(absolute)
            .with_context(|| format!("hash extended attributes for {}", absolute.display()))?,
        sha256,
        symlink_target,
        symlink_target_bytes_hex,
    });

    if file_type.is_dir() {
        let mut children = fs::read_dir(absolute)
            .with_context(|| format!("list directory {}", absolute.display()))?
            .collect::<std::io::Result<Vec<_>>>()?;
        children.sort_by(|left, right| {
            left.file_name()
                .as_bytes()
                .cmp(right.file_name().as_bytes())
        });
        for child in children {
            let child_relative = if relative == Path::new(".") {
                PathBuf::from(child.file_name())
            } else {
                relative.join(child.file_name())
            };
            visit(&child.path(), &child_relative, excludes, entries)?;
        }
    }
    Ok(())
}

pub(crate) fn is_excluded(relative: &Path, excludes: &[PathBuf]) -> bool {
    excludes
        .iter()
        .any(|exclude| relative == exclude || relative.starts_with(exclude))
}

pub(crate) fn is_exclude_protected(relative: &Path, excludes: &[PathBuf]) -> bool {
    is_excluded(relative, excludes)
        || excludes
            .iter()
            .any(|exclude| exclude.starts_with(relative) && relative != Path::new("."))
}

fn entry_kind(file_type: &fs::FileType) -> EntryKind {
    if file_type.is_file() {
        EntryKind::File
    } else if file_type.is_dir() {
        EntryKind::Directory
    } else if file_type.is_symlink() {
        EntryKind::Symlink
    } else if file_type.is_block_device() {
        EntryKind::BlockDevice
    } else if file_type.is_char_device() {
        EntryKind::CharacterDevice
    } else if file_type.is_fifo() {
        EntryKind::Fifo
    } else if file_type.is_socket() {
        EntryKind::Socket
    } else {
        EntryKind::Other
    }
}

fn file_identity_changed(before: &Metadata, after: &Metadata) -> bool {
    before.file_type().is_file() != after.file_type().is_file()
        || before.dev() != after.dev()
        || before.ino() != after.ino()
        || before.len() != after.len()
        || before.mtime() != after.mtime()
        || before.mtime_nsec() != after.mtime_nsec()
        || before.ctime() != after.ctime()
        || before.ctime_nsec() != after.ctime_nsec()
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::symlink;

    use super::*;

    #[test]
    fn creates_sorted_read_only_manifest_without_following_symlinks() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("b.txt"), b"abc").unwrap();
        fs::create_dir(temp.path().join("a")).unwrap();
        symlink("b.txt", temp.path().join("link")).unwrap();

        let manifest = create_manifest(&[temp.path().to_path_buf()]).unwrap();
        let entries = &manifest.roots[0].entries;
        assert_eq!(
            entries
                .iter()
                .map(|entry| entry.path.as_str())
                .collect::<Vec<_>>(),
            [".", "a", "b.txt", "link"]
        );
        assert_eq!(
            entries[2].sha256.as_deref(),
            Some("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        );
        assert_eq!(entries[3].symlink_target.as_deref(), Some("b.txt"));
        assert!(entries[3].sha256.is_none());
    }

    #[test]
    fn excludes_only_the_exact_relative_subtree() {
        let temp = tempfile::tempdir().unwrap();
        fs::create_dir_all(temp.path().join("cache/nested")).unwrap();
        fs::create_dir_all(temp.path().join("cache-other")).unwrap();
        fs::write(temp.path().join("cache/nested/ignored"), b"x").unwrap();
        fs::write(temp.path().join("cache-other/kept"), b"y").unwrap();
        let manifest = create_manifest_roots(&[DataRoot {
            name: "app".to_owned(),
            path: temp.path().to_path_buf(),
            excludes: vec![PathBuf::from("cache")],
        }])
        .unwrap();
        let paths = manifest.roots[0]
            .entries
            .iter()
            .map(|entry| entry.path.as_str())
            .collect::<Vec<_>>();
        assert!(!paths.iter().any(|path| path.starts_with("cache/")));
        assert!(paths.contains(&"cache-other/kept"));
    }
}
