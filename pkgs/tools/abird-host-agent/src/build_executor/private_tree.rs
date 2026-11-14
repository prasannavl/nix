//! Fresh private inodes, never chmod of producer-owned files or hardlink copies.
//!
//! Trusted worker primitive, not a source/provenance or protection receipt. Caller
//! must first admit/account the work and durably register both private directories
//! under its XDG data authority, including partial-copy recovery/retirement. Keep
//! the immutable job deadline and GC exclusion across later import/evaluation.
//! Symlinks are copied as inert bytes: confinement and Git/patch/NAR/closure
//! verification remain mandatory before evaluation. Source consistency is not
//! inferred from metadata checks. Failure leaves private, untrusted partial data.

use std::ffi::{CStr, CString};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd};
use std::ptr::NonNull;

use anyhow::{Context, Result, ensure};

const BUFFER_BYTES: usize = 64 * 1024;
const MAX_LINK_BYTES: usize = 4096;
const MAX_DEPTH: u16 = 64;

/// Explicit resource policy; no production capacity defaults. Counts include root
/// and symlink bytes, but not filesystem allocation overhead or complete storage.
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
pub struct Limits {
    pub entries: u32,
    pub bytes: u64,
    pub depth: u16,
}

impl Limits {
    pub(super) fn validate(self) -> Result<()> {
        ensure!(
            self.entries > 0 && self.depth > 0 && self.depth <= MAX_DEPTH,
            "invalid copy limits"
        );
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct CopySummary {
    pub entries: u32,
    pub bytes: u64,
    pub symlinks: u32,
}

/// Both descriptors are caller-provisioned directories, not untrusted path names.
/// Destination must be empty, private, service-owned and never exposed to the
/// producer. No writable destination descriptor may be passed to another actor.
/// Root is published read-only to `reader_gid` only after child handles close.
/// This neither initializes durable ownership nor authorizes a later Nix effect.
pub fn copy(
    source: &File,
    destination: &File,
    source_uid: u32,
    reader_gid: u32,
    limits: Limits,
) -> Result<CopySummary> {
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "private copy requires root"
    );
    super::workload::require_wrapper_placement()?;
    ensure!(
        source_uid > 0 && source_uid < u32::MAX,
        "invalid source uid"
    );
    ensure!(
        reader_gid > 0 && reader_gid < u32::MAX,
        "invalid reader gid"
    );
    copy_before(source, destination, source_uid, reader_gid, limits, None)
}

pub(super) fn copy_before(
    source: &File,
    destination: &File,
    source_uid: u32,
    reader_gid: u32,
    limits: Limits,
    deadline: Option<std::time::Instant>,
) -> Result<CopySummary> {
    let mut state = copier(source, destination, source_uid, reader_gid, limits, 0)?;
    state.deadline = deadline;
    state.directory(source, destination, 1)?;
    Ok(state.summary)
}

#[cfg(test)]
fn copy_as(
    source: &File,
    destination: &File,
    source_uid: u32,
    reader_gid: u32,
    limits: Limits,
    service_uid: u32,
) -> Result<CopySummary> {
    let mut state = copier(
        source,
        destination,
        source_uid,
        reader_gid,
        limits,
        service_uid,
    )?;
    state.directory(source, destination, 1)?;
    Ok(state.summary)
}

fn copier(
    source: &File,
    destination: &File,
    source_uid: u32,
    reader_gid: u32,
    limits: Limits,
    service_uid: u32,
) -> Result<Copier> {
    limits.validate()?;
    let source_stat = stat(source)?;
    let target_stat = stat(destination)?;
    ensure!(
        source_stat.st_mode & libc::S_IFMT == libc::S_IFDIR,
        "source is not a directory"
    );
    ensure!(
        target_stat.st_mode & libc::S_IFMT == libc::S_IFDIR
            && target_stat.st_uid == service_uid
            && target_stat.st_mode & 0o7777 == 0o700,
        "destination is not private"
    );
    ensure!(
        (source_stat.st_dev, source_stat.st_ino) != (target_stat.st_dev, target_stat.st_ino),
        "source aliases destination"
    );
    ensure!(
        Entries::new(destination)?.next()?.is_none(),
        "destination is not empty"
    );
    Ok(Copier {
        source_uid,
        reader_gid,
        source_device: source_stat.st_dev,
        limits,
        summary: CopySummary::default(),
        buffer: vec![0; BUFFER_BYTES],
        deadline: None,
    })
}

struct Copier {
    source_uid: u32,
    reader_gid: u32,
    source_device: libc::dev_t,
    limits: Limits,
    summary: CopySummary,
    buffer: Vec<u8>,
    deadline: Option<std::time::Instant>,
}

impl Copier {
    fn check_entry(&self, observed: &libc::stat) -> Result<()> {
        self.active()?;
        ensure!(
            observed.st_uid == self.source_uid && observed.st_dev == self.source_device,
            "foreign source entry"
        );
        ensure!(
            self.summary.entries < self.limits.entries,
            "source entry bound exceeded"
        );
        Ok(())
    }

    fn entry(&mut self, observed: &libc::stat) -> Result<()> {
        self.check_entry(observed)?;
        self.summary.entries += 1;
        Ok(())
    }

    fn active(&self) -> Result<()> {
        ensure!(
            self.deadline
                .is_none_or(|deadline| std::time::Instant::now() < deadline),
            "private copy deadline expired"
        );
        Ok(())
    }

    fn bytes(&mut self, count: usize) -> Result<()> {
        self.active()?;
        ensure!(
            count as u64 <= self.limits.bytes - self.summary.bytes,
            "source byte bound exceeded"
        );
        self.summary.bytes += count as u64;
        Ok(())
    }

    fn directory(&mut self, source: &File, destination: &File, depth: u16) -> Result<()> {
        ensure!(depth <= self.limits.depth, "source depth bound exceeded");
        let before = stat(source)?;
        self.entry(&before)?;
        // Remove inherited ACLs before creating children or granting group access.
        clear_acl(destination, true)?;
        let mut entries = Entries::new(source)?;
        while let Some(name) = entries.next()? {
            let observed = stat_at(source, &name)?;
            match observed.st_mode & libc::S_IFMT {
                libc::S_IFDIR => {
                    self.check_entry(&observed)?;
                    ensure!(depth < self.limits.depth, "source depth bound exceeded");
                    let child = open_at(source, &name, libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
                    ensure!(same(&observed, &stat(&child)?), "source directory replaced");
                    syscall(unsafe {
                        libc::mkdirat(destination.as_raw_fd(), name.as_ptr(), 0o700)
                    })?;
                    let target =
                        open_at(destination, &name, libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
                    self.directory(&child, &target, depth + 1)?;
                }
                libc::S_IFREG => {
                    self.entry(&observed)?;
                    ensure!(observed.st_nlink == 1, "source hardlinks are unsupported");
                    let mut child = open_at(source, &name, libc::O_RDONLY | libc::O_NONBLOCK, 0)?;
                    ensure!(same(&observed, &stat(&child)?), "source file replaced");
                    let mut target = open_at(
                        destination,
                        &name,
                        libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
                        0o600,
                    )?;
                    loop {
                        let count = child.read(&mut self.buffer)?;
                        if count == 0 {
                            break;
                        }
                        self.bytes(count)?;
                        target.write_all(&self.buffer[..count])?;
                    }
                    ensure!(same(&observed, &stat(&child)?), "source file changed");
                    clear_acl(&target, false)?;
                    // NAR/Git executable semantics use the owner-execute bit.
                    self.read_only(
                        &target,
                        if observed.st_mode & 0o100 != 0 {
                            0o550
                        } else {
                            0o440
                        },
                        &observed,
                    )?;
                }
                libc::S_IFLNK => {
                    self.entry(&observed)?;
                    ensure!(observed.st_nlink == 1, "source hardlinks are unsupported");
                    let mut link = [0u8; MAX_LINK_BYTES + 1];
                    let count = unsafe {
                        libc::readlinkat(
                            source.as_raw_fd(),
                            name.as_ptr(),
                            link.as_mut_ptr().cast(),
                            link.len(),
                        )
                    };
                    ensure!(
                        count >= 0,
                        "read source link: {}",
                        io::Error::last_os_error()
                    );
                    ensure!(
                        count as usize <= MAX_LINK_BYTES,
                        "source link bound exceeded"
                    );
                    self.bytes(count as usize)?;
                    let link = CString::new(&link[..count as usize])?;
                    ensure!(
                        same(&observed, &stat_at(source, &name)?),
                        "source link changed"
                    );
                    syscall(unsafe {
                        libc::symlinkat(link.as_ptr(), destination.as_raw_fd(), name.as_ptr())
                    })?;
                    syscall(unsafe {
                        libc::fchownat(
                            destination.as_raw_fd(),
                            name.as_ptr(),
                            u32::MAX,
                            self.reader_gid,
                            libc::AT_SYMLINK_NOFOLLOW,
                        )
                    })?;
                    let times = times(&observed);
                    syscall(unsafe {
                        libc::utimensat(
                            destination.as_raw_fd(),
                            name.as_ptr(),
                            times.as_ptr(),
                            libc::AT_SYMLINK_NOFOLLOW,
                        )
                    })?;
                    self.summary.symlinks += 1;
                }
                _ => anyhow::bail!("unsupported source entry type"),
            }
        }
        ensure!(same(&before, &stat(source)?), "source directory changed");
        self.read_only(destination, 0o550, &before)
    }

    fn read_only(&self, file: &File, mode: libc::mode_t, source: &libc::stat) -> Result<()> {
        syscall(unsafe { libc::fchown(file.as_raw_fd(), u32::MAX, self.reader_gid) })?;
        syscall(unsafe { libc::fchmod(file.as_raw_fd(), mode) })?;
        // Native dirty-Git lastModified must not become the copy's wall time.
        let times = times(source);
        syscall(unsafe { libc::futimens(file.as_raw_fd(), times.as_ptr()) })?;
        file.sync_all().context("sync private tree")
    }
}

fn times(source: &libc::stat) -> [libc::timespec; 2] {
    [
        libc::timespec {
            tv_sec: source.st_atime,
            tv_nsec: source.st_atime_nsec,
        },
        libc::timespec {
            tv_sec: source.st_mtime,
            tv_nsec: source.st_mtime_nsec,
        },
    ]
}

pub(super) fn clear_acl(file: &File, directory: bool) -> Result<()> {
    for name in [c"system.posix_acl_access"]
        .into_iter()
        .chain(directory.then_some(c"system.posix_acl_default"))
    {
        let result = unsafe { libc::fremovexattr(file.as_raw_fd(), name.as_ptr()) };
        if result == -1 {
            let error = io::Error::last_os_error();
            ensure!(
                matches!(error.raw_os_error(), Some(libc::ENODATA | libc::EOPNOTSUPP)),
                "remove inherited ACL: {error}"
            );
        }
    }
    Ok(())
}

/// Exact-UID read access to an already sealed, root-owned tree via POSIX ACLs.
/// Owner/group/other permission bits are preserved (group class is masked to
/// at most their prior value); no chmod/chown, no group grant, no write bit.
/// Symlinks carry no ACL and are never followed.
pub(super) fn grant_reader(
    root: &File,
    uid: u32,
    limits: Limits,
    deadline: std::time::Instant,
) -> Result<u32> {
    limits.validate()?;
    ensure!(uid > 0 && uid < u32::MAX, "invalid reader uid");
    let mut entries = 0u32;
    let mut pending = vec![(
        open_at(root, c".", libc::O_RDONLY | libc::O_DIRECTORY, 0)?,
        1u16,
    )];
    while let Some((directory, depth)) = pending.pop() {
        ensure!(
            std::time::Instant::now() < deadline && depth <= limits.depth,
            "private reader grant exceeds bound"
        );
        let observed = stat(&directory)?;
        ensure!(
            observed.st_uid == 0,
            "reader grant requires a root-owned tree"
        );
        allow_user(&directory, &observed, uid, true)?;
        let mut names = Entries::new(&directory)?;
        while let Some(name) = names.next()? {
            entries += 1;
            ensure!(
                entries <= limits.entries && std::time::Instant::now() < deadline,
                "private reader grant exceeds bound"
            );
            let child = stat_at(&directory, &name)?;
            match child.st_mode & libc::S_IFMT {
                libc::S_IFDIR => pending.push((
                    open_at(&directory, &name, libc::O_RDONLY | libc::O_DIRECTORY, 0)?,
                    depth + 1,
                )),
                libc::S_IFREG => {
                    let file = open_at(&directory, &name, libc::O_RDONLY | libc::O_NONBLOCK, 0)?;
                    let opened = stat(&file)?;
                    ensure!(
                        same(&child, &opened) && opened.st_uid == 0 && opened.st_nlink == 1,
                        "private tree entry replaced"
                    );
                    allow_user(&file, &opened, uid, opened.st_mode & 0o100 != 0)?;
                }
                libc::S_IFLNK => {}
                _ => anyhow::bail!("unsupported private tree entry"),
            }
        }
    }
    Ok(entries)
}

/// Parent traversal only (`--x`) for the exact reader; listing stays denied.
pub(super) fn grant_traverse(directory: &File, uid: u32) -> Result<()> {
    let observed = stat(directory)?;
    ensure!(
        observed.st_uid == 0 && observed.st_mode & libc::S_IFMT == libc::S_IFDIR,
        "reader traversal requires a root-owned directory"
    );
    set_acl(directory, &observed, uid, 0o1)
}

fn allow_user(file: &File, observed: &libc::stat, uid: u32, execute: bool) -> Result<()> {
    set_acl(file, observed, uid, if execute { 0o5 } else { 0o4 })
}

fn set_acl(file: &File, observed: &libc::stat, uid: u32, perm: u16) -> Result<()> {
    const VERSION: u32 = 2;
    const UNDEFINED: u32 = u32::MAX;
    let mode = observed.st_mode;
    let owner = ((mode >> 6) & 0o7) as u16;
    let group = ((mode >> 3) & 0o7) as u16;
    // Mask bounds the named user and owning group; never widen the group.
    let mask = perm | group;
    let mut bytes = VERSION.to_le_bytes().to_vec();
    for (tag, perm, id) in [
        (0x01u16, owner, UNDEFINED),
        (0x02, perm, uid),
        (0x04, group, UNDEFINED),
        (0x10, mask, UNDEFINED),
        (0x20, (mode & 0o7) as u16, UNDEFINED),
    ] {
        bytes.extend(tag.to_le_bytes());
        bytes.extend(perm.to_le_bytes());
        bytes.extend(id.to_le_bytes());
    }
    syscall(unsafe {
        libc::fsetxattr(
            file.as_raw_fd(),
            c"system.posix_acl_access".as_ptr(),
            bytes.as_ptr().cast(),
            bytes.len(),
            0,
        )
    })
    .context("grant exact private reader")?;
    file.sync_all().context("sync private reader grant")
}

fn same(a: &libc::stat, b: &libc::stat) -> bool {
    (
        a.st_dev,
        a.st_ino,
        a.st_uid,
        a.st_gid,
        a.st_mode,
        a.st_nlink,
        a.st_size,
        a.st_mtime,
        a.st_mtime_nsec,
        a.st_ctime,
        a.st_ctime_nsec,
    ) == (
        b.st_dev,
        b.st_ino,
        b.st_uid,
        b.st_gid,
        b.st_mode,
        b.st_nlink,
        b.st_size,
        b.st_mtime,
        b.st_mtime_nsec,
        b.st_ctime,
        b.st_ctime_nsec,
    )
}

fn stat(file: &File) -> Result<libc::stat> {
    let mut value = std::mem::MaybeUninit::uninit();
    syscall(unsafe { libc::fstat(file.as_raw_fd(), value.as_mut_ptr()) })?;
    Ok(unsafe { value.assume_init() })
}

fn stat_at(directory: &File, name: &CStr) -> Result<libc::stat> {
    let mut value = std::mem::MaybeUninit::uninit();
    syscall(unsafe {
        libc::fstatat(
            directory.as_raw_fd(),
            name.as_ptr(),
            value.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    })?;
    Ok(unsafe { value.assume_init() })
}

fn open_at(directory: &File, name: &CStr, flags: i32, mode: libc::mode_t) -> Result<File> {
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            mode,
        )
    };
    ensure!(
        fd >= 0,
        "open private tree entry: {}",
        io::Error::last_os_error()
    );
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn syscall(result: i32) -> Result<()> {
    if result < 0 {
        Err(io::Error::last_os_error().into())
    } else {
        Ok(())
    }
}

pub(super) fn directory_empty(directory: &File) -> Result<bool> {
    Ok(Entries::new(directory)?.next()?.is_none())
}

struct Entries(NonNull<libc::DIR>);

impl Entries {
    fn new(directory: &File) -> Result<Self> {
        // A dup shares directory offsets; a new description is required.
        let fd = open_at(directory, c".", libc::O_RDONLY | libc::O_DIRECTORY, 0)?.into_raw_fd();
        match NonNull::new(unsafe { libc::fdopendir(fd) }) {
            Some(dir) => Ok(Self(dir)),
            None => {
                let error = io::Error::last_os_error();
                drop(unsafe { File::from_raw_fd(fd) });
                Err(error.into())
            }
        }
    }

    fn next(&mut self) -> Result<Option<CString>> {
        loop {
            unsafe {
                *libc::__errno_location() = 0;
            }
            let entry = unsafe { libc::readdir(self.0.as_ptr()) };
            if entry.is_null() {
                let error = io::Error::last_os_error();
                ensure!(
                    error.raw_os_error() == Some(0),
                    "read private tree directory: {error}"
                );
                return Ok(None);
            }
            let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
            if name != c"." && name != c".." {
                return Ok(Some(name.to_owned()));
            }
        }
    }
}

impl Drop for Entries {
    fn drop(&mut self) {
        unsafe {
            libc::closedir(self.0.as_ptr());
        }
    }
}

#[cfg(test)]
mod tests;
