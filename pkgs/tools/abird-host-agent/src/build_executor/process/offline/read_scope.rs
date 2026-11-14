//! Bounded regular-inode read grants. Directory rules never grant READ_FILE:
//! a readonly live bind can still contain (or later acquire) a host FIFO.

use super::*;
use crate::build_executor::private_tree::Limits;
use std::fs;
use std::os::unix::fs::FileTypeExt;
use std::path::PathBuf;
use std::time::Instant;

/// Prepared in the final mount view by trusted setup, before caller Git. The
/// ruleset holds inode rules, not one live descriptor per source/runtime file.
/// Symlink directories are not traversed implicitly; their actual read roots
/// must be supplied. Missing roots, budget exhaustion and races fail closed.
pub struct ReadScope {
    pub(super) ruleset: OwnedFd,
}

impl ReadScope {
    pub fn capture(roots: &[&Path], limits: Limits, deadline: Instant) -> io::Result<Self> {
        limits.validate().map_err(|_| invalid())?;
        if roots.is_empty() || roots.len() > 4096 || Instant::now() >= deadline {
            return Err(invalid());
        }
        let scope = Self {
            ruleset: create(READ_FILE | REFER)?,
        };
        // REFER otherwise remains implicitly denied even by a read-only domain.
        rule(&scope.ruleset, c"/", REFER, true)?;
        let mut walk = Walk {
            scope: &scope,
            limits,
            deadline,
            entries: 0,
            names: 0,
        };
        for root in roots {
            let resolved = fs::canonicalize(root)?;
            allowed(&resolved)?;
            let name = CString::new(resolved.as_os_str().as_bytes()).map_err(|_| invalid())?;
            let pin = open(&name, false)?;
            walk.visit(pin, &resolved, 0)?;
        }
        Ok(scope)
    }

    pub(super) fn try_clone(&self) -> io::Result<Self> {
        Ok(Self {
            ruleset: self.ruleset.try_clone()?,
        })
    }

    pub(super) fn add_file(&self, path: &std::ffi::CStr) -> io::Result<()> {
        let pin = open(path, false)?;
        let mut status: libc::stat = unsafe { std::mem::zeroed() };
        check(unsafe { libc::fstat(pin.as_raw_fd(), &mut status) })?;
        if status.st_mode & libc::S_IFMT != libc::S_IFREG {
            return Err(invalid());
        }
        add(&self.ruleset, &pin, READ_FILE)
    }
}

struct Walk<'a> {
    scope: &'a ReadScope,
    limits: Limits,
    deadline: Instant,
    entries: u32,
    names: u64,
}

impl Walk<'_> {
    fn visit(&mut self, pin: OwnedFd, path: &Path, depth: u16) -> io::Result<()> {
        self.entries = self.entries.checked_add(1).ok_or_else(invalid)?;
        // Metadata accounting only; source payload bytes retain their separate
        // existing capture/seal bound. No file contents are read by this walk.
        self.names = self
            .names
            .checked_add(path.as_os_str().len() as u64)
            .ok_or_else(invalid)?;
        if Instant::now() >= self.deadline
            || self.entries > self.limits.entries
            || self.names > self.limits.bytes
            || depth > self.limits.depth
        {
            return Err(io::Error::from_raw_os_error(libc::E2BIG));
        }
        let file = File::from(pin);
        let metadata = file.metadata()?;
        if metadata.is_file() {
            return add(&self.scope.ruleset, &file, READ_FILE);
        }
        if metadata.is_symlink() {
            let resolved = match fs::canonicalize(path) {
                Ok(path) => path,
                // Unreadable/dangling links stay readable as link metadata, not
                // as file contents. Never replace them with a broader grant.
                Err(_) => return Ok(()),
            };
            if allowed(&resolved).is_err() {
                return Ok(());
            }
            let name = CString::new(resolved.as_os_str().as_bytes()).map_err(|_| invalid())?;
            let target = open(&name, false)?;
            let mut status: libc::stat = unsafe { std::mem::zeroed() };
            check(unsafe { libc::fstat(target.as_raw_fd(), &mut status) })?;
            // A symlink to a FIFO/device gets no grant. A directory symlink is
            // metadata only: following it could traverse an unbounded live tree.
            if status.st_mode & libc::S_IFMT == libc::S_IFREG {
                add(&self.scope.ruleset, &target, READ_FILE)?;
            }
            return Ok(());
        }
        if metadata.is_dir() {
            let listing = PathBuf::from(format!("/proc/self/fd/{}", file.as_raw_fd()));
            for entry in fs::read_dir(listing)? {
                let entry = entry?;
                let name = entry.file_name();
                let name_c = CString::new(name.as_bytes()).map_err(|_| invalid())?;
                let child = fd(unsafe {
                    libc::openat(
                        file.as_raw_fd(),
                        name_c.as_ptr(),
                        libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                    ) as libc::c_long
                })?;
                self.visit(
                    child,
                    &path.join(name),
                    depth.checked_add(1).ok_or_else(invalid)?,
                )?;
            }
        } else if !metadata.file_type().is_fifo()
            && !metadata.file_type().is_socket()
            && !metadata.file_type().is_char_device()
            && !metadata.file_type().is_block_device()
        {
            return Err(invalid());
        }
        // Special files never acquire READ_FILE. Replacing a granted regular
        // pathname with a FIFO also loses its old inode rule.
        Ok(())
    }
}

fn allowed(path: &Path) -> io::Result<()> {
    if !path.is_absolute()
        || path.components().count() < 2
        || path.as_os_str().len() > 4096
        || path == Path::new("/nix/store")
        || ["/proc", "/sys", "/dev"]
            .iter()
            .any(|root| path.starts_with(root))
    {
        return Err(invalid());
    }
    Ok(())
}
