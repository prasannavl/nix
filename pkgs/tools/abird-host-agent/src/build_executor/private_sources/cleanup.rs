//! Descriptor-relative namespace retirement. No store paths, link following,
//! shell, payload reads or recursive remove_dir_all. This is not a quota receipt.

use std::ffi::{CStr, CString};
use std::fs::{File, Metadata, OpenOptions};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::time::Instant;

use anyhow::{Context, Result, ensure};

use super::Limits;

/// Retirement inventories the whole allocation, not one source tree: producer,
/// sealed copy, checkout/runtime and cache, plus encoded delivery and metadata.
pub(super) fn limits(source: Limits) -> Result<Limits> {
    source.validate()?;
    let material = crate::build_executor::preparation::source::material_limit(source)? as u64;
    Ok(Limits {
        entries: source
            .entries
            .checked_mul(4)
            .and_then(|n| n.checked_add(4096))
            .context("source cleanup entry budget overflow")?,
        bytes: source
            .bytes
            .checked_mul(4)
            .and_then(|n| n.checked_add(material))
            .and_then(|n| n.checked_add(16 * 1024 * 1024))
            .context("source cleanup byte budget overflow")?,
        depth: source.depth.saturating_add(8).min(64),
    })
}

struct Entry {
    name: CString,
    identity: (u64, u64, u32),
    children: Option<Vec<Entry>>,
}
struct Budget {
    entries: u32,
    bytes: u64,
    device: u64,
    /// Actors that write into a slot: the source producer and the native
    /// reader (its per-attempt cache). Root creates the scaffolding.
    owners: [u32; 2],
    limits: Limits,
    deadline: Instant,
}

impl Budget {
    fn ready(&self, active: &mut impl FnMut() -> Result<()>) -> Result<()> {
        ensure!(
            Instant::now() < self.deadline,
            "source cleanup deadline expired"
        );
        active()
    }

    fn admit(&mut self, metadata: &Metadata, depth: u16) -> Result<()> {
        self.entries = self
            .entries
            .checked_add(1)
            .context("source cleanup entry overflow")?;
        ensure!(
            depth <= self.limits.depth
                && self.entries <= self.limits.entries
                && metadata.dev() == self.device
                && (metadata.uid() == 0 || self.owners.contains(&metadata.uid())),
            "source cleanup identity/bound differs"
        );
        if !metadata.is_dir() {
            ensure!(
                (metadata.is_file() || metadata.file_type().is_symlink()) && metadata.nlink() == 1,
                "source cleanup refuses links/special files"
            );
            self.bytes = self
                .bytes
                .checked_add(metadata.len())
                .context("source cleanup byte overflow")?;
            ensure!(
                self.bytes <= self.limits.bytes,
                "source cleanup byte bound exceeded"
            );
        }
        Ok(())
    }
}

struct Directory(*mut libc::DIR);
impl Drop for Directory {
    fn drop(&mut self) {
        unsafe {
            libc::closedir(self.0);
        }
    }
}

fn names(
    directory: &File,
    budget: &Budget,
    active: &mut impl FnMut() -> Result<()>,
) -> Result<Vec<CString>> {
    budget.ready(active)?;
    // Independent open-file description: do not inherit a previous readdir offset.
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            c".".as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    ensure!(fd >= 0, std::io::Error::last_os_error());
    let raw = unsafe { libc::fdopendir(fd) };
    if raw.is_null() {
        unsafe {
            libc::close(fd);
        }
        return Err(std::io::Error::last_os_error().into());
    }
    let stream = Directory(raw);
    let mut names = Vec::new();
    loop {
        budget.ready(active)?;
        unsafe {
            *libc::__errno_location() = 0;
        }
        let entry = unsafe { libc::readdir(stream.0) };
        if entry.is_null() {
            ensure!(
                unsafe { *libc::__errno_location() } == 0,
                std::io::Error::last_os_error()
            );
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
        if matches!(name.to_bytes(), b"." | b"..") {
            continue;
        }
        ensure!(
            !name.to_bytes().is_empty()
                && !name.to_bytes().contains(&b'/')
                && names.len() < usize::try_from(budget.limits.entries)?,
            "source cleanup directory exceeds bound"
        );
        names.push(name.to_owned());
    }
    names.sort();
    ensure!(
        names.windows(2).all(|pair| pair[0] != pair[1]),
        "duplicate source cleanup entry"
    );
    Ok(names)
}

fn pin(parent: &File, name: &CStr) -> Result<File> {
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    ensure!(fd >= 0, std::io::Error::last_os_error());
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn directory(pin: &File) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC)
        .open(format!("/proc/self/fd/{}", pin.as_raw_fd()))?;
    same(pin, &file)?;
    Ok(file)
}

fn same(first: &File, second: &File) -> Result<()> {
    let first = first.metadata()?;
    let second = second.metadata()?;
    ensure!(
        (first.dev(), first.ino(), first.mode() & libc::S_IFMT)
            == (second.dev(), second.ino(), second.mode() & libc::S_IFMT),
        "source cleanup entry replaced"
    );
    Ok(())
}

fn claim(directory: &File) -> Result<()> {
    // Permission is checked even through escaped directory FDs. This fences
    // namespace writers, not writable file FDs or their physical allocation.
    super::super::private_tree::clear_acl(directory, true)?;
    super::syscall(unsafe { libc::fchown(directory.as_raw_fd(), 0, 0) })?;
    super::syscall(unsafe { libc::fchmod(directory.as_raw_fd(), 0o700) })?;
    directory.sync_all().map_err(Into::into)
}

fn inventory(
    parent: &File,
    budget: &mut Budget,
    depth: u16,
    active: &mut impl FnMut() -> Result<()>,
) -> Result<Vec<Entry>> {
    budget.ready(active)?;
    if depth > 1 {
        claim(parent)?;
    }
    let initial = names(parent, budget, active)?;
    let mut entries = Vec::new();
    for name in &initial {
        budget.ready(active)?;
        let pinned = pin(parent, name)?;
        let metadata = pinned.metadata()?;
        budget.admit(&metadata, depth)?;
        let children = if metadata.is_dir() {
            let child = directory(&pinned)?;
            Some(inventory(
                &child,
                budget,
                depth
                    .checked_add(1)
                    .context("source cleanup depth overflow")?,
                active,
            )?)
        } else {
            None
        };
        same(&pinned, &pin(parent, name)?)?;
        entries.push(Entry {
            name: name.clone(),
            identity: (
                metadata.dev(),
                metadata.ino(),
                metadata.mode() & libc::S_IFMT,
            ),
            children,
        });
    }
    ensure!(
        initial == names(parent, budget, active)?,
        "source cleanup directory changed"
    );
    Ok(entries)
}

fn remove(
    parent: &File,
    entries: &[Entry],
    budget: &Budget,
    active: &mut impl FnMut() -> Result<()>,
) -> Result<()> {
    for entry in entries {
        budget.ready(active)?;
        let pinned = pin(parent, &entry.name)?;
        let metadata = pinned.metadata()?;
        ensure!(
            (
                metadata.dev(),
                metadata.ino(),
                metadata.mode() & libc::S_IFMT
            ) == entry.identity
                && (metadata.is_dir() || metadata.nlink() == 1),
            "source cleanup entry changed"
        );
        let flags = if let Some(children) = &entry.children {
            let child = directory(&pinned)?;
            remove(&child, children, budget, active)?;
            ensure!(
                names(&child, budget, active)?.is_empty(),
                "source cleanup directory not empty"
            );
            libc::AT_REMOVEDIR
        } else {
            0
        };
        same(&pinned, &pin(parent, &entry.name)?)?;
        budget.ready(active)?;
        super::syscall(unsafe { libc::unlinkat(parent.as_raw_fd(), entry.name.as_ptr(), flags) })?;
        parent.sync_all()?;
    }
    Ok(())
}

pub(super) fn empty(
    directory: &File,
    owners: [u32; 2],
    limits: Limits,
    deadline: Instant,
    active: &mut impl FnMut() -> Result<()>,
) -> Result<()> {
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "source cleanup requires root"
    );
    limits.validate()?;
    let metadata = directory.metadata()?;
    ensure!(
        metadata.is_dir() && metadata.uid() == 0 && metadata.mode() & 0o022 == 0,
        "source cleanup root differs"
    );
    let mut budget = Budget {
        entries: 0,
        bytes: 0,
        device: metadata.dev(),
        owners,
        limits,
        deadline,
    };
    budget.admit(&metadata, 0)?;
    let entries = inventory(directory, &mut budget, 1, active)?;
    remove(directory, &entries, &budget, active)?;
    ensure!(
        names(directory, &budget, active)?.is_empty(),
        "source cleanup not complete"
    );
    budget.ready(active)
}
