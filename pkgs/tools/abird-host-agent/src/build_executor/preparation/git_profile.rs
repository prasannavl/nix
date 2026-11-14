//! Private Git configuration bytes, not flattened settings or a coherence receipt.
//! Only the original source actor reads them; only their enclosing Git digest is
//! retained in public preparation context. No Debug/raw diagnostic representation.

use super::{
    search_path::{self, Link},
    source::unhex,
};
use crate::sha256::digest_bytes;
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};
use std::time::Instant;

pub const MAX_FILES: usize = 64;
pub const MAX_BYTES: usize = 64 * 1024;

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct ConfigFile {
    path: PathBuf,
    bytes: String,
    digest: String,
    uid: u32,
    gid: u32,
    mode: u32,
    modified: (i64, i64),
    #[serde(default, skip_serializing_if = "Option::is_none")]
    location: Option<Location>,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct Location {
    expanded: PathBuf,
    resolved: PathBuf,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ConfigImage {
    uid: u32,
    files: Vec<ConfigFile>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    links: Vec<Link>,
}

impl ConfigImage {
    pub fn new(uid: u32) -> Result<Self> {
        ensure!(
            uid > 0 && uid < u32::MAX,
            "invalid private configuration actor"
        );
        Ok(Self {
            uid,
            files: Vec::new(),
            links: Vec::new(),
        })
    }

    /// Replay raw profile files at their original logical paths for libgit2.
    /// Native readers get read-only private files, not caller ownership. Local
    /// Git config is supplied by the captured common directories, not replayed
    /// over a post-checkout image. Only safe.directory is extended for the
    /// executor UID's necessarily different filesystem ownership.
    pub(in crate::build_executor) fn install_native(
        &self,
        backend: &Path,
        home: &Path,
        xdg_config_home: &Path,
        roots: &[(PathBuf, PathBuf)],
        uid: u32,
        deadline: Instant,
    ) -> Result<Vec<(PathBuf, PathBuf)>> {
        ensure!(
            unsafe { libc::geteuid() } == 0 && uid > 0,
            "native profile installation requires root"
        );
        self.validate()?;
        fs::create_dir(backend)?;
        fs::set_permissions(backend, std::os::unix::fs::PermissionsExt::from_mode(0o700))?;
        let global = home.join(".gitconfig");
        let mut files = BTreeMap::new();
        for file in &self.files {
            if roots
                .iter()
                .any(|(_, common)| file.path.starts_with(common))
            {
                continue;
            }
            files.insert(file.path.clone(), unhex(&file.bytes, MAX_BYTES)?);
        }
        // Missing caller defaults must not reveal a builder's unrelated XDG
        // profile when that namespace is backed by a trusted system tree.
        for name in ["config", "attributes", "ignore"] {
            let xdg = xdg_config_home.join("git").join(name);
            if !roots.iter().any(|(_, common)| xdg.starts_with(common)) {
                files.entry(xdg).or_default();
            }
        }
        let global_bytes = files.entry(global).or_default();
        global_bytes.extend_from_slice(b"\n[safe]\n");
        for (worktree, _) in roots {
            let text = worktree
                .to_str()
                .context("non-UTF8 native safe directory")?;
            ensure!(
                !text.contains(['\n', '\r']),
                "invalid native safe directory"
            );
            // Git quoted-string syntax, not shell or flattened caller settings.
            global_bytes.extend_from_slice(
                format!(
                    "\tdirectory = \"{}\"\n",
                    text.replace('\\', "\\\\").replace('"', "\\\"")
                )
                .as_bytes(),
            );
        }
        let mut mounted = Vec::new();
        for (index, (original, bytes)) in files.into_iter().enumerate() {
            ensure!(
                Instant::now() < deadline,
                "native profile installation expired"
            );
            let path = backend.join(index.to_string());
            let original_file = self.files.iter().find(|file| file.path == original);
            let mut file = OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .mode(
                    if original_file.is_some_and(|file| file.mode & 0o100 != 0) {
                        0o500
                    } else {
                        0o400
                    },
                )
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&path)?;
            file.write_all(&bytes)?;
            if let Some(original_file) = original_file {
                let times = [
                    libc::timespec {
                        tv_sec: 0,
                        tv_nsec: libc::UTIME_OMIT,
                    },
                    libc::timespec {
                        tv_sec: original_file.modified.0,
                        tv_nsec: original_file.modified.1,
                    },
                ];
                syscall(unsafe { libc::futimens(file.as_raw_fd(), times.as_ptr()) })?;
            }
            file.sync_all()?;
            mounted.push((original, path));
        }
        let directory = File::open(backend)?;
        super::super::private_tree::grant_reader(
            &directory,
            uid,
            super::super::private_tree::Limits {
                entries: (MAX_FILES + 5) as u32,
                bytes: (MAX_BYTES + 16384) as u64,
                depth: 2,
            },
            deadline,
        )?;
        directory.sync_all()?;
        Ok(mounted)
    }

    pub fn links(&self) -> &[Link] {
        &self.links
    }

    pub fn contains(&self, path: &Path) -> bool {
        self.files.iter().any(|file| file.path == path)
    }
    pub fn paths(&self) -> impl Iterator<Item = &Path> {
        self.files.iter().map(|file| file.path.as_path())
    }
    pub fn bytes(&self, path: &Path) -> Result<Vec<u8>> {
        let file = self
            .files
            .iter()
            .find(|file| file.path == path)
            .context("private configuration missing")?;
        unhex(&file.bytes, MAX_BYTES)
    }

    /// Capture once, after admission. Missing/inaccessible files are errors, not
    /// absence evidence: a service-masked namespace cannot justify omission.
    pub fn capture(
        &mut self,
        path: &Path,
        window: &mut super::git_context::window::ReadWindow,
        deadline: Instant,
    ) -> Result<()> {
        crate::build_executor::workload::require_wrapper_placement()?;
        ensure!(
            unsafe { libc::geteuid() } == self.uid,
            "private configuration credential differs"
        );
        let uid = self.uid;
        self.capture_watched(path, deadline, |component, content| {
            if content {
                window.hold_configuration(component, uid)
            } else {
                window.hold_path_component(component)
            }
        })?;
        window.check()
    }

    #[cfg(test)]
    fn capture_at(&mut self, path: &Path, deadline: Instant) -> Result<()> {
        self.capture_watched(path, deadline, |_, _| Ok(()))
    }

    pub(in crate::build_executor::preparation) fn capture_watched(
        &mut self,
        path: &Path,
        deadline: Instant,
        mut hold: impl FnMut(&Path, bool) -> Result<()>,
    ) -> Result<()> {
        ensure!(
            Instant::now() < deadline && self.files.len() < MAX_FILES && !self.contains(path),
            "private configuration capture expired, repeated or exceeds bound"
        );
        allowed_path(path)?;
        let mut links = self
            .links
            .iter()
            .map(|link| (link.path.clone(), link.clone()))
            .collect();
        let expanded = search_path::resolve(path, &mut links, deadline, &mut |component| {
            allowed_path(component)?;
            hold(component, false)
        })?;
        allowed_path(&expanded)?;
        let resolved = if search_path::in_store(&expanded) {
            search_path::immutable_resolution(&expanded, deadline)?
        } else {
            fs::canonicalize(&expanded)?
        };
        allowed_path(&resolved)?;
        hold(&resolved, true)?;
        let mut file = capture_file(&resolved, self.uid, deadline)?;
        if resolved != path {
            file.path = path.to_owned();
            file.location = Some(Location { expanded, resolved });
        }
        let size = self
            .files
            .iter()
            .map(|file| file.bytes.len() / 2)
            .sum::<usize>();
        ensure!(
            size + file.bytes.len() / 2 <= MAX_BYTES,
            "private configuration bytes exceed bound"
        );
        // Validate the complete candidate before changing the original image.
        let mut candidate = self.clone();
        candidate.files.push(file);
        candidate.files.sort_by(|a, b| a.path.cmp(&b.path));
        candidate.links = links.into_values().collect();
        candidate.validate()?;
        candidate.check_live(deadline)?;
        *self = candidate;
        Ok(())
    }

    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.uid > 0
                && self.uid < u32::MAX
                && self.files.len() <= MAX_FILES
                && self.links.len() <= 128
                && self
                    .links
                    .windows(2)
                    .all(|pair| pair[0].path < pair[1].path)
                && self
                    .files
                    .windows(2)
                    .all(|pair| pair[0].path < pair[1].path),
            "invalid private configuration image"
        );
        for link in &self.links {
            link.validate()?;
            allowed_path(&link.path)?;
            allowed_path(&search_path::destination(
                &link.path,
                &link.target,
                Path::new(""),
            )?)?;
        }
        let links: BTreeMap<_, _> = self
            .links
            .iter()
            .map(|link| (link.path.as_path(), link.target.as_path()))
            .collect();
        let mut used = BTreeSet::new();
        let mut total = 0usize;
        for file in &self.files {
            allowed_path(&file.path)?;
            let expanded = search_path::expand(&file.path, &links, &mut used)?;
            if let Some(location) = &file.location {
                allowed_path(&location.expanded)?;
                allowed_path(&location.resolved)?;
                ensure!(
                    location.resolved != file.path
                        && expanded == location.expanded
                        && (location.expanded == location.resolved
                            || (search_path::in_store(&location.expanded)
                                && search_path::in_store(&location.resolved))),
                    "private configuration alias binding differs"
                );
            } else {
                ensure!(
                    expanded == file.path,
                    "private configuration alias lacks binding"
                );
            }
            let bytes = unhex(&file.bytes, MAX_BYTES)?;
            total = total
                .checked_add(bytes.len())
                .context("private configuration size overflow")?;
            ensure!(
                total <= MAX_BYTES
                    && digest_bytes(&bytes) == file.digest
                    && [0, self.uid].contains(&file.uid)
                    && file.mode <= 0o777
                    && (0..1_000_000_000).contains(&file.modified.1),
                "private configuration data differs"
            );
        }
        ensure!(
            used.len() == links.len() && serde_json::to_vec(self)?.len() <= 256 * 1024,
            "private configuration encoding exceeds bound"
        );
        Ok(())
    }

    /// Byte/metadata veto, not proof against transient writes or a changed
    /// namespace. Local Git files may change only in the later private checkout.
    pub fn check_live(&self, deadline: Instant) -> Result<()> {
        self.validate()?;
        for link in &self.links {
            ensure!(
                Instant::now() < deadline && search_path::observe(&link.path)? == *link,
                "private configuration alias changed"
            );
        }
        for expected in &self.files {
            ensure!(
                capture_expected(expected, self.uid, deadline)? == *expected,
                "private configuration changed during capture"
            );
        }
        Ok(())
    }

    pub fn check_view(&self, git: &Path, after_checkout: bool, deadline: Instant) -> Result<()> {
        self.validate()?;
        for link in &self.links {
            ensure!(
                Instant::now() < deadline && fs::read_link(&link.path)? == link.target,
                "private configuration alias differs"
            );
        }
        for expected in &self.files {
            if after_checkout && expected.path.starts_with(git) {
                ensure!(
                    expected.location.is_none(),
                    "aliased local configuration is not mutable"
                );
                continue;
            }
            ensure!(
                capture_expected(expected, self.uid, deadline)? == *expected,
                "private checkout configuration differs"
            );
        }
        Ok(())
    }

    /// Root installs fresh per-file inodes below its exclusive caller directory.
    /// Local Git files already came from the NAR; compare rather than replace them.
    pub(in crate::build_executor) fn install(
        &self,
        backend: &Path,
        original_git: &Path,
        restored_git: &Path,
        uid: u32,
        deadline: Instant,
    ) -> Result<Vec<(PathBuf, File)>> {
        ensure!(
            unsafe { libc::geteuid() } == 0 && uid == self.uid,
            "private configuration installer differs"
        );
        crate::build_executor::workload::require_wrapper_placement()?;
        self.validate()?;
        fs::create_dir(backend)?;
        let directory = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(backend)?;
        super::super::private_tree::clear_acl(&directory, true)?;
        syscall(unsafe { libc::fchown(directory.as_raw_fd(), 0, 0) })?;
        syscall(unsafe { libc::fchmod(directory.as_raw_fd(), 0o700) })?;
        let mut mounts = Vec::new();
        let mut destinations = BTreeMap::new();
        for (index, config) in self.files.iter().enumerate() {
            ensure!(
                Instant::now() < deadline,
                "private configuration installation expired"
            );
            let bytes = unhex(&config.bytes, MAX_BYTES)?;
            if let Ok(relative) = config.path.strip_prefix(original_git) {
                ensure!(
                    config.location.is_none(),
                    "aliased local configuration is not mutable"
                );
                let restored = capture_file(&restored_git.join(relative), uid, deadline)?;
                ensure!(
                    restored.bytes == config.bytes
                        && restored.mode == config.mode
                        && restored.modified == config.modified,
                    "restored local Git configuration differs"
                );
                continue;
            }
            let destination = config
                .location
                .as_ref()
                .map_or(&config.path, |location| &location.resolved);
            if let Some(previous) = destinations.insert(destination.clone(), index) {
                let previous = &self.files[previous];
                ensure!(
                    previous.bytes == config.bytes
                        && previous.uid == config.uid
                        && previous.gid == config.gid
                        && previous.mode == config.mode
                        && previous.modified == config.modified,
                    "shared configuration destination differs"
                );
                continue;
            }
            let mut file = OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(backend.join(index.to_string()))?;
            super::super::private_tree::clear_acl(&file, false)?;
            file.write_all(&bytes)?;
            syscall(unsafe { libc::fchown(file.as_raw_fd(), config.uid, config.gid) })?;
            syscall(unsafe { libc::fchmod(file.as_raw_fd(), config.mode) })?;
            let times = [
                libc::timespec {
                    tv_sec: 0,
                    tv_nsec: libc::UTIME_OMIT,
                },
                libc::timespec {
                    tv_sec: config.modified.0,
                    tv_nsec: config.modified.1,
                },
            ];
            syscall(unsafe { libc::futimens(file.as_raw_fd(), times.as_ptr()) })?;
            file.sync_all()?;
            mounts.push((destination.clone(), file));
        }
        directory.sync_all()?;
        File::open(backend.parent().context("configuration parent missing")?)?.sync_all()?;
        Ok(mounts)
    }
}

fn allowed_path(path: &Path) -> Result<()> {
    ensure!(
        path.is_absolute()
            && path.as_os_str().len() <= 4096
            && !path.as_os_str().as_bytes().contains(&0)
            && path
                .components()
                .all(|part| matches!(part, Component::RootDir | Component::Normal(_))),
        "invalid private configuration path"
    );
    ensure!(
        path.extension().is_none_or(|extension| extension != "key")
            && !path
                .components()
                .any(|part| matches!(part, Component::Normal(name) if name == ".ssh")),
        "private configuration path enters credential storage"
    );
    Ok(())
}

fn capture_expected(expected: &ConfigFile, uid: u32, deadline: Instant) -> Result<ConfigFile> {
    let path = expected
        .location
        .as_ref()
        .map_or(&expected.path, |location| &location.resolved);
    ensure!(
        fs::canonicalize(&expected.path)? == *path,
        "private configuration resolution differs"
    );
    let expanded = expected
        .location
        .as_ref()
        .map_or(&expected.path, |location| &location.expanded);
    if search_path::in_store(expanded) {
        ensure!(
            search_path::immutable_resolution(expanded, deadline)? == *path,
            "private immutable configuration resolution differs"
        );
    }
    let mut file = capture_file(path, uid, deadline)?;
    file.path = expected.path.clone();
    file.location = expected.location.clone();
    Ok(file)
}

fn capture_file(path: &Path, uid: u32, deadline: Instant) -> Result<ConfigFile> {
    ensure!(
        Instant::now() < deadline,
        "private configuration intake expired"
    );
    allowed_path(path)?;
    ensure!(
        fs::canonicalize(path)? == path,
        "private configuration alias requires its own binding"
    );
    let pin = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let before = pin.metadata()?;
    ensure!(
        before.is_file()
            && [0, uid].contains(&before.uid())
            && before.mode() & 0o7000 == 0
            && (before.nlink() == 1 || (before.uid() == 0 && path.starts_with("/nix/store")))
            && before.len() <= MAX_BYTES as u64,
        "unsupported private configuration inode"
    );
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(format!("/proc/self/fd/{}", pin.as_raw_fd()))?;
    let identity = |m: &fs::Metadata| {
        (
            m.dev(),
            m.ino(),
            m.uid(),
            m.gid(),
            m.mode(),
            m.len(),
            m.mtime(),
            m.mtime_nsec(),
            m.ctime(),
            m.ctime_nsec(),
        )
    };
    ensure!(
        identity(&before) == identity(&file.metadata()?),
        "private configuration pin differs"
    );
    let mut bytes = Vec::new();
    (&mut file)
        .take(MAX_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    ensure!(
        Instant::now() < deadline
            && bytes.len() == before.len() as usize
            && identity(&before) == identity(&file.metadata()?)
            && identity(&before) == identity(&fs::symlink_metadata(path)?),
        "private configuration changed during intake"
    );
    Ok(ConfigFile {
        path: path.to_owned(),
        bytes: super::git_context::hex(&bytes),
        digest: digest_bytes(&bytes),
        uid: before.uid(),
        gid: before.gid(),
        mode: before.mode() & 0o777,
        modified: (before.mtime(), before.mtime_nsec()),
        location: None,
    })
}

fn syscall(result: i32) -> Result<()> {
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error().into())
    }
}

#[cfg(test)]
mod tests;
