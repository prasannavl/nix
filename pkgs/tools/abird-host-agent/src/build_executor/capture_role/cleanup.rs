//! Descriptor-relative retirement of positively settled private caller data.
//! No following links, payload reads, store deletion, or absent-worker adoption.

use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::time::Instant;

use anyhow::{Result, ensure};

pub(super) fn remove_data(
    path: &Path,
    uid: u32,
    entries: u64,
    depth: u16,
    deadline: Instant,
    preserve_record: bool,
) -> Result<()> {
    let root = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = root.metadata()?;
    ensure!(
        metadata.uid() == 0 && metadata.mode() & 0o077 == 0,
        "capture cleanup root differs"
    );
    let mut budget = Budget {
        uid,
        device: metadata.dev(),
        left: entries,
        depth,
        deadline,
    };
    walk(&root, &mut budget, 0, preserve_record)?;
    for entry in fs::read_dir(format!("/proc/self/fd/{}", root.as_raw_fd()))? {
        let name = entry?.file_name();
        ensure!(
            preserve_record && (name == "record" || name == "record.next"),
            "capture cleanup has remaining private data"
        );
    }
    root.sync_all()?;
    Ok(())
}

struct Budget {
    uid: u32,
    device: u64,
    left: u64,
    depth: u16,
    deadline: Instant,
}

fn walk(parent: &File, budget: &mut Budget, depth: u16, preserve_record: bool) -> Result<()> {
    ensure!(
        depth <= budget.depth && Instant::now() < budget.deadline,
        "capture cleanup bound exceeded"
    );
    // The proc alias names our retained directory FD, not an input pathname.
    // Every child open/unlink below is relative to that same descriptor.
    for entry in fs::read_dir(format!("/proc/self/fd/{}", parent.as_raw_fd()))? {
        let entry = entry?;
        let name = entry.file_name();
        if preserve_record && (name == "record" || name == "record.next") {
            continue;
        }
        ensure!(
            budget.left > 0 && Instant::now() < budget.deadline,
            "capture cleanup bound exceeded"
        );
        budget.left -= 1;
        let name = CString::new(name.as_bytes())?;
        let mut metadata = std::mem::MaybeUninit::<libc::stat>::uninit();
        ensure!(
            unsafe {
                libc::fstatat(
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    metadata.as_mut_ptr(),
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            } == 0,
            std::io::Error::last_os_error()
        );
        let metadata = unsafe { metadata.assume_init() };
        ensure!(
            metadata.st_dev == budget.device && [0, budget.uid].contains(&metadata.st_uid),
            "foreign capture cleanup entry"
        );
        let directory = metadata.st_mode & libc::S_IFMT == libc::S_IFDIR;
        if directory {
            let fd = unsafe {
                libc::openat(
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            ensure!(fd >= 0, std::io::Error::last_os_error());
            let child = unsafe { File::from_raw_fd(fd) };
            let current = child.metadata()?;
            ensure!(
                current.dev() == metadata.st_dev && current.ino() == metadata.st_ino,
                "capture cleanup entry replaced"
            );
            walk(&child, budget, depth + 1, false)?;
        }
        ensure!(
            unsafe {
                libc::unlinkat(
                    parent.as_raw_fd(),
                    name.as_ptr(),
                    if directory { libc::AT_REMOVEDIR } else { 0 },
                )
            } == 0,
            std::io::Error::last_os_error()
        );
    }
    parent.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::time::Duration;

    #[test]
    fn cleanup_does_not_follow_a_private_tree_symlink() {
        // Kernel root-owned policy entry is exercised in the installed VM.
        // Test the same descriptor walker under this process's actual UID.
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        fs::write(outside.path().join("keep"), b"keep").unwrap();
        fs::write(root.path().join("record"), b"metadata").unwrap();
        fs::create_dir(root.path().join("image")).unwrap();
        fs::set_permissions(root.path().join("image"), fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(root.path().join("image/data"), b"private").unwrap();
        std::os::unix::fs::symlink(outside.path(), root.path().join("alias")).unwrap();
        let directory = File::open(root.path()).unwrap();
        let mut budget = Budget {
            uid: unsafe { libc::geteuid() },
            device: directory.metadata().unwrap().dev(),
            left: 1,
            depth: 8,
            deadline: Instant::now() + Duration::from_secs(2),
        };
        assert!(walk(&directory, &mut budget, 0, true).is_err());
        budget.left = 16;
        walk(&directory, &mut budget, 0, true).unwrap();
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
        assert_eq!(fs::read(outside.path().join("keep")).unwrap(), b"keep");
    }
}
