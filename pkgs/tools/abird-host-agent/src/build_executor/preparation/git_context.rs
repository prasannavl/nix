//! Private Git-directory intake, not a repository snapshot/coherence receipt.
//! NAR bytes never enter the shared store. Native NARs omit timestamps, so retain
//! those separately. Metadata comparisons are vetoes, not proof against writers.

pub mod window;

use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::fs::{File, OpenOptions};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::ptr::NonNull;
use std::time::Instant;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::source::{MAX_MATERIAL_BYTES, unhex};
use crate::build_executor::private_tree::Limits;
use crate::sha256::digest_bytes;

pub const MAX_NAR_BYTES: usize = MAX_MATERIAL_BYTES / 2;
const MAX_ENTRIES: usize = 262144;
const MAX_PATH_BYTES: usize = 4096;

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Stamp {
    pub(in crate::build_executor::preparation) directory: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    symlink: bool,
    executable: bool,
    pub(in crate::build_executor::preparation) bytes: u64,
    seconds: i64,
    nanoseconds: u32,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct GitLayout {
    pub worktree: std::path::PathBuf,
    pub common: std::path::PathBuf,
    pub git_dir: std::path::PathBuf,
}

impl GitLayout {
    pub fn validate(&self) -> Result<()> {
        for path in [&self.worktree, &self.common, &self.git_dir] {
            super::capsule::absolute(path)?;
        }
        ensure!(
            self.git_dir == self.common || self.git_dir.starts_with(self.common.join("worktrees")),
            "Git administration outside common directory"
        );
        Ok(())
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct GitContext {
    pub version: u32,
    pub caller_digest: String,
    pub nar_digest: String,
    pub nar: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout: Option<GitLayout>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub external: BTreeMap<String, super::capsule::GitImage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub search_path: Option<super::search_path::SearchPath>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub configuration: Option<super::git_profile::ConfigImage>,
    // Raw relative Unix paths, lower-case hex; empty names the root. Only the
    // preparation contracts may inspect this manifest for layout/budget checks.
    pub(in crate::build_executor::preparation) stamps: BTreeMap<String, Stamp>,
}

impl GitContext {
    pub fn new(caller_digest: String, nar: &[u8], observed: Observation) -> Result<Self> {
        ensure!(
            !nar.is_empty() && nar.len() <= MAX_NAR_BYTES,
            "captured Git NAR exceeds bound"
        );
        let value = Self {
            version: 2,
            caller_digest,
            nar_digest: digest_bytes(nar),
            nar: hex(nar),
            layout: None,
            external: BTreeMap::new(),
            search_path: None,
            configuration: None,
            stamps: observed.stamps,
        };
        value.validate()?;
        Ok(value)
    }

    pub fn validate(&self) -> Result<()> {
        ensure!(
            matches!(self.version, 1 | 2),
            "unsupported captured Git context"
        );
        ensure!(
            self.external.len() <= 1,
            "too many independent native roots"
        );
        for (hash, root) in &self.external {
            ensure!(
                root.image.external.is_empty() && hash == &root.image.nar_digest,
                "recursive or incorrectly bound native root"
            );
            root.validate()?;
        }
        if let Some(layout) = &self.layout {
            layout.validate()?;
        }
        if let Some(search_path) = &self.search_path {
            search_path.validate()?;
        }
        if let Some(configuration) = &self.configuration {
            configuration.validate()?;
        }
        ensure!(
            !self.nar.is_empty() && self.nar.len() <= MAX_NAR_BYTES * 2,
            "captured Git NAR exceeds bound"
        );
        crate::build_executor::digest(&self.caller_digest)?;
        crate::build_executor::digest(&self.nar_digest)?;
        ensure!(
            !self.stamps.is_empty()
                && self.stamps.len() <= MAX_ENTRIES
                && self.stamps.get("").is_some_and(|stamp| stamp.directory),
            "invalid captured Git root"
        );
        let mut bytes = 0u64;
        for (name, stamp) in &self.stamps {
            let path = relative(name)?;
            if !path.is_empty() {
                let parent = path
                    .iter()
                    .rposition(|byte| *byte == b'/')
                    .map_or(&b""[..], |at| &path[..at]);
                ensure!(
                    self.stamps
                        .get(&hex(parent))
                        .is_some_and(|stamp| stamp.directory),
                    "captured Git parent missing"
                );
            }
            ensure!(
                stamp.nanoseconds < 1_000_000_000
                    && (!stamp.symlink || (!stamp.directory && !stamp.executable))
                    && (!stamp.directory || (stamp.bytes == 0 && !stamp.executable)),
                "invalid captured Git timestamp/type"
            );
            bytes = bytes
                .checked_add(stamp.bytes)
                .context("captured Git size overflow")?;
            ensure!(
                bytes <= MAX_NAR_BYTES as u64,
                "captured Git data exceeds bound"
            );
        }
        super::source::encoding::require_size(self, MAX_MATERIAL_BYTES)?;
        ensure!(
            super::source::encoding::hex_digest(&self.nar, MAX_NAR_BYTES)? == self.nar_digest,
            "captured Git NAR differs"
        );
        Ok(())
    }

    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        if self.version == 2 {
            return super::source::encoding::json_digest(
                b"abird-owned-private-git-v2\n",
                self,
                MAX_MATERIAL_BYTES,
            );
        }
        let mut bytes = b"abird-owned-private-git-v1\n".to_vec();
        bytes.extend(serde_json::to_vec(&serde_json::to_value(self)?)?);
        Ok(digest_bytes(&bytes))
    }

    pub fn require_limits(&self, limits: Limits) -> Result<()> {
        limits.validate()?;
        let bytes = self.stamps.values().try_fold(0u64, |total, stamp| {
            total
                .checked_add(stamp.bytes)
                .context("private image size overflow")
        })?;
        ensure!(
            self.stamps.len() <= limits.entries as usize && bytes <= limits.bytes,
            "private image exceeds declared source limits"
        );
        for name in self.stamps.keys() {
            let path = relative(name)?;
            ensure!(
                path.split(|byte| *byte == b'/').count() <= usize::from(limits.depth),
                "private image exceeds declared source depth"
            );
        }
        Ok(())
    }

    pub fn archive(&self) -> Result<Vec<u8>> {
        unhex(&self.nar, MAX_NAR_BYTES)
    }

    /// Original root worker only, after positive restore-producer settlement.
    /// Open descriptor-relative; no caller path/UID, redirects or symlink times.
    pub fn restore_times(
        &self,
        root: &Path,
        uid: u32,
        limits: Limits,
        deadline: Instant,
    ) -> Result<()> {
        self.validate()?;
        ensure!(
            unsafe { libc::geteuid() } == 0 || unsafe { libc::geteuid() } == uid,
            "Git timestamp restoration requires the original actor or root"
        );
        crate::build_executor::workload::require_wrapper_placement()?;
        let root = directory(root)?;
        let mut observed = Observation::empty(&root, uid, limits, deadline)?;
        observed.walk(&root, Vec::new(), 1, Some(&self.stamps))?;
        ensure!(
            observed.stamps == self.stamps,
            "restored Git timestamp coverage differs"
        );
        Ok(())
    }
}

/// Before/after filesystem observations include inode/ctime identity, not only
/// NAR-preserved fields. They never establish an atomic source or stop authority.
#[derive(Eq, PartialEq)]
pub struct Observation {
    stamps: BTreeMap<String, Stamp>,
    identities: BTreeMap<String, (u64, u64, u64, u64, i64, i64)>,
    uid: u32,
    device: u64,
    bytes: u64,
    limits: Limits,
    deadline: Instant,
}

impl Observation {
    pub fn read(root: &Path, uid: u32, limits: Limits, deadline: Instant) -> Result<Self> {
        let root = directory(root)?;
        let mut value = Self::empty(&root, uid, limits, deadline)?;
        value.walk(&root, Vec::new(), 1, None)?;
        Ok(value)
    }

    fn empty(root: &File, uid: u32, limits: Limits, deadline: Instant) -> Result<Self> {
        limits.validate()?;
        ensure!(uid > 0 && uid < u32::MAX, "invalid captured Git owner");
        Ok(Self {
            stamps: BTreeMap::new(),
            identities: BTreeMap::new(),
            uid,
            device: root.metadata()?.dev(),
            bytes: 0,
            limits,
            deadline,
        })
    }

    fn walk(
        &mut self,
        file: &File,
        path: Vec<u8>,
        depth: u16,
        restore: Option<&BTreeMap<String, Stamp>>,
    ) -> Result<()> {
        ensure!(
            Instant::now() < self.deadline
                && depth <= self.limits.depth
                && self.stamps.len() < (self.limits.entries as usize).min(MAX_ENTRIES),
            "Git intake deadline/entry bound exceeded"
        );
        ensure!(
            path.len() <= MAX_PATH_BYTES,
            "captured Git path exceeds bound"
        );
        let name = hex(&path);
        relative(&name)?;
        let metadata = file.metadata()?;
        let directory = metadata.is_dir();
        ensure!(
            metadata.uid() == self.uid
                && metadata.dev() == self.device
                && (directory || (metadata.is_file() && metadata.nlink() == 1)),
            "foreign or unsupported Git entry"
        );
        let mut stamp = Stamp {
            directory,
            symlink: false,
            executable: !directory && metadata.mode() & 0o100 != 0,
            bytes: if directory { 0 } else { metadata.len() },
            seconds: metadata.mtime(),
            nanoseconds: metadata.mtime_nsec().try_into()?,
        };
        self.bytes = self
            .bytes
            .checked_add(stamp.bytes)
            .context("captured Git size overflow")?;
        ensure!(
            self.bytes <= self.limits.bytes.min(MAX_NAR_BYTES as u64),
            "Git intake byte bound exceeded"
        );
        if let Some(stamps) = restore {
            let expected = stamps.get(&name).context("unexpected restored Git entry")?;
            ensure!(
                stamp.directory == expected.directory
                    && stamp.symlink == expected.symlink
                    && stamp.executable == expected.executable
                    && stamp.bytes == expected.bytes,
                "restored Git entry differs"
            );
            stamp = expected.clone();
        }
        ensure!(
            self.stamps.insert(name.clone(), stamp.clone()).is_none(),
            "duplicate captured Git path"
        );
        self.identities.insert(
            name,
            (
                metadata.dev(),
                metadata.ino(),
                metadata.mode().into(),
                metadata.gid().into(),
                metadata.ctime(),
                metadata.ctime_nsec(),
            ),
        );
        if directory {
            let mut entries = Entries::new(file)?;
            while let Some(entry) = entries.next()? {
                let mut child_path = path.clone();
                if !child_path.is_empty() {
                    child_path.push(b'/');
                }
                child_path.extend(entry.to_bytes());
                // Pin without opening device/FIFO payloads, then reopen exactly
                // that inode. A namespace replacement cannot change its type.
                let pin = open(file, &entry, libc::O_PATH)?;
                let pinned = pin.metadata()?;
                ensure!(
                    pinned.uid() == self.uid
                        && pinned.dev() == self.device
                        && (pinned.is_dir()
                            || ((pinned.is_file() || pinned.is_symlink()) && pinned.nlink() == 1)),
                    "foreign or unsupported Git entry"
                );
                if pinned.is_symlink() {
                    let key = hex(&child_path);
                    let mut stamp = Stamp {
                        directory: false,
                        symlink: true,
                        executable: false,
                        bytes: pinned.len(),
                        seconds: pinned.mtime(),
                        nanoseconds: pinned.mtime_nsec().try_into()?,
                    };
                    self.bytes = self
                        .bytes
                        .checked_add(stamp.bytes)
                        .context("private image size overflow")?;
                    ensure!(
                        self.bytes <= self.limits.bytes.min(MAX_NAR_BYTES as u64)
                            && self.stamps.len() < (self.limits.entries as usize).min(MAX_ENTRIES)
                            && depth < self.limits.depth
                            && Instant::now() < self.deadline,
                        "private image symlink exceeds bound"
                    );
                    if let Some(stamps) = restore {
                        let expected = stamps.get(&key).context("unexpected restored symlink")?;
                        ensure!(
                            expected.symlink && expected.bytes == stamp.bytes,
                            "restored symlink differs"
                        );
                        stamp = expected.clone();
                        let times = [
                            libc::timespec {
                                tv_sec: 0,
                                tv_nsec: libc::UTIME_OMIT,
                            },
                            libc::timespec {
                                tv_sec: stamp.seconds,
                                tv_nsec: stamp.nanoseconds.into(),
                            },
                        ];
                        syscall(unsafe {
                            libc::utimensat(
                                file.as_raw_fd(),
                                entry.as_ptr(),
                                times.as_ptr(),
                                libc::AT_SYMLINK_NOFOLLOW,
                            )
                        })?;
                    }
                    ensure!(
                        self.stamps.insert(key.clone(), stamp).is_none(),
                        "duplicate private image path"
                    );
                    self.identities.insert(
                        key,
                        (
                            pinned.dev(),
                            pinned.ino(),
                            pinned.mode().into(),
                            pinned.gid().into(),
                            pinned.ctime(),
                            pinned.ctime_nsec(),
                        ),
                    );
                    continue;
                }
                let child = OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
                    .open(format!("/proc/self/fd/{}", pin.as_raw_fd()))?;
                let reopened = child.metadata()?;
                ensure!(
                    pinned.dev() == reopened.dev() && pinned.ino() == reopened.ino(),
                    "Git entry pin differs"
                );
                self.walk(
                    &child,
                    child_path,
                    depth.checked_add(1).context("Git depth overflow")?,
                    restore,
                )?;
            }
        }
        if restore.is_some() {
            ensure!(
                Instant::now() < self.deadline,
                "Git timestamp restoration deadline expired"
            );
            let times = [
                libc::timespec {
                    tv_sec: 0,
                    tv_nsec: libc::UTIME_OMIT,
                },
                libc::timespec {
                    tv_sec: stamp.seconds,
                    tv_nsec: stamp.nanoseconds.into(),
                },
            ];
            syscall(unsafe { libc::futimens(file.as_raw_fd(), times.as_ptr()) })?;
            file.sync_all()?;
        } else {
            let after = file.metadata()?;
            ensure!(
                metadata.dev() == after.dev()
                    && metadata.ino() == after.ino()
                    && metadata.mode() == after.mode()
                    && metadata.uid() == after.uid()
                    && metadata.gid() == after.gid()
                    && metadata.nlink() == after.nlink()
                    && metadata.len() == after.len()
                    && metadata.mtime() == after.mtime()
                    && metadata.mtime_nsec() == after.mtime_nsec()
                    && metadata.ctime() == after.ctime()
                    && metadata.ctime_nsec() == after.ctime_nsec(),
                "Git entry changed during intake"
            );
        }
        Ok(())
    }
}

fn relative(name: &str) -> Result<Vec<u8>> {
    let path = unhex(name, MAX_PATH_BYTES)?;
    ensure!(
        path.is_empty()
            || path
                .split(|byte| *byte == b'/')
                .all(|component| !component.is_empty()
                    && component != b"."
                    && component != b".."
                    && !component.contains(&0)),
        "invalid captured Git path"
    );
    Ok(path)
}

pub fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut value = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        value.push(DIGITS[(byte >> 4) as usize] as char);
        value.push(DIGITS[(byte & 15) as usize] as char);
    }
    value
}

fn directory(path: &Path) -> Result<File> {
    Ok(OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?)
}
fn open(parent: &File, name: &CStr, flags: i32) -> Result<File> {
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    ensure!(
        fd >= 0,
        "open captured Git entry: {}",
        std::io::Error::last_os_error()
    );
    Ok(unsafe { File::from_raw_fd(fd) })
}
fn syscall(result: i32) -> Result<()> {
    if result < 0 {
        Err(std::io::Error::last_os_error().into())
    } else {
        Ok(())
    }
}
struct Entries(NonNull<libc::DIR>);
impl Entries {
    fn new(directory: &File) -> Result<Self> {
        let fd = open(directory, c".", libc::O_RDONLY | libc::O_DIRECTORY)?.into_raw_fd();
        match NonNull::new(unsafe { libc::fdopendir(fd) }) {
            Some(directory) => Ok(Self(directory)),
            None => {
                let error = std::io::Error::last_os_error();
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
                let error = std::io::Error::last_os_error();
                ensure!(
                    error.raw_os_error() == Some(0),
                    "read captured Git directory: {error}"
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
