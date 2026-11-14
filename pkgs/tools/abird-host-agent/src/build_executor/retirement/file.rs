//! Exact bound sidecar removal. Metadata only; unbound residue and unexpected
//! absence retain uncertainty. Callers supply settled/released root authority.

use std::ffi::{CStr, CString};
use std::fs::File;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

use anyhow::{Context, Result, ensure};

use crate::build_executor::journal::{native_phase::FileId, open_directory};

fn binding(expected: Option<&FileId>, observed: Option<&FileId>) -> Result<bool> {
    match (expected, observed) {
        (None, None) => Ok(false),
        (Some(expected), Some(observed)) if expected == observed => Ok(true),
        (None, Some(_)) => anyhow::bail!("unbound retirement residue"),
        (Some(_), None) => anyhow::bail!("bound retirement file missing"),
        _ => anyhow::bail!("retirement file replaced"),
    }
}

fn pin(directory: &File, name: &CStr) -> Result<Option<File>> {
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd >= 0 {
        return Ok(Some(unsafe { File::from_raw_fd(fd) }));
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::NotFound {
        Ok(None)
    } else {
        Err(error.into())
    }
}

fn identity(file: &File, bytes: u64) -> Result<FileId> {
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file()
            && metadata.uid() == 0
            && metadata.nlink() == 1
            && metadata.mode() & 0o7777 == 0o600
            && metadata.len() == bytes,
        "retirement file metadata differs"
    );
    Ok(FileId {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

pub(in crate::build_executor) fn remove(
    path: &Path,
    expected: Option<&FileId>,
    bytes: u64,
    active: &mut impl FnMut() -> Result<()>,
) -> Result<()> {
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "sidecar retirement requires root"
    );
    active()?;
    let parent = path.parent().context("retirement parent missing")?;
    let directory = open_directory(parent)?;
    let name = CString::new(
        path.file_name()
            .context("retirement filename missing")?
            .as_bytes(),
    )?;
    let pinned = pin(&directory, &name)?;
    let observed = pinned
        .as_ref()
        .map(|file| identity(file, bytes))
        .transpose()?;
    if binding(expected, observed.as_ref())? {
        // No payload read, even for native gate bytes or a partial artifact.
        let current = pin(&directory, &name)?.context("bound retirement file vanished")?;
        ensure!(
            Some(identity(&current, bytes)?) == observed,
            "retirement file changed before removal"
        );
        let parent_now = open_directory(parent)?.metadata()?;
        let parent_bound = directory.metadata()?;
        ensure!(
            (parent_now.dev(), parent_now.ino()) == (parent_bound.dev(), parent_bound.ino()),
            "retirement parent replaced"
        );
        active()?;
        ensure!(
            unsafe { libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), 0) } == 0,
            std::io::Error::last_os_error()
        );
    }
    directory.sync_all()?;
    let parent_now = open_directory(parent)?.metadata()?;
    let parent_bound = directory.metadata()?;
    ensure!(
        (parent_now.dev(), parent_now.ino()) == (parent_bound.dev(), parent_bound.ino()),
        "retirement parent changed during removal"
    );
    ensure!(
        pin(&directory, &name)?.is_none(),
        "retirement removal unconfirmed"
    );
    active()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleanup_requires_original_identity_not_same_name_or_observed_absence() {
        let first = FileId {
            device: 1,
            inode: 2,
        };
        let replaced = FileId {
            device: 1,
            inode: 3,
        };
        let other_mount = FileId {
            device: 2,
            inode: 2,
        };
        assert!(!binding(None, None).unwrap());
        assert!(binding(Some(&first), Some(&first)).unwrap());
        assert!(binding(None, Some(&first)).is_err());
        assert!(binding(Some(&first), None).is_err());
        assert!(binding(Some(&first), Some(&replaced)).is_err());
        assert!(binding(Some(&first), Some(&other_mount)).is_err());
    }
}
