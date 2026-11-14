//! One bounded Linux read window for private Git metadata and configuration.
//! Not a caller-profile, checkout, containment or evaluation receipt. Unsupported
//! leases, watch loss and breaks reject. Writable-mapping exclusion is an explicit
//! OS qualification obligation, not inferred from metadata or this constructor.

use std::collections::BTreeMap;
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::marker::PhantomData;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::rc::Rc;
use std::time::Instant;

use anyhow::{Context, Result, ensure};

use super::{Entries, Limits, MAX_ENTRIES, MAX_NAR_BYTES, directory, open, syscall};

const WATCH: u32 = libc::IN_MODIFY
    | libc::IN_ATTRIB
    | libc::IN_MOVE_SELF
    | libc::IN_DELETE_SELF
    | libc::IN_CREATE
    | libc::IN_DELETE
    | libc::IN_MOVED_FROM
    | libc::IN_MOVED_TO
    | libc::IN_UNMOUNT;

/// Masks that request events about a directory's entries, not only itself.
/// IN_ATTRIB alone is requested for self-attribute changes.
const CHILD_EVENTS: u32 =
    libc::IN_MODIFY | libc::IN_CREATE | libc::IN_DELETE | libc::IN_MOVED_FROM | libc::IN_MOVED_TO;

struct HeldFile {
    file: File,
    immutable: bool,
}

pub struct ReadWindow {
    signal: Signal,
    events: File,
    root: Option<(PathBuf, File)>,
    leases: Vec<HeldFile>,
    held_files: BTreeMap<(u64, u64, u32), bool>,
    /// Watch → whether any registration on it asked for child events.
    watches: BTreeMap<i32, bool>,
    descriptor_limit: usize,
    uid: u32,
    bytes: u64,
    entries: u32,
    limits: Limits,
    deadline: Instant,
    poisoned: std::cell::Cell<bool>,
}

impl ReadWindow {
    pub fn open(path: &Path, uid: u32, limits: Limits, deadline: Instant) -> Result<Self> {
        crate::build_executor::workload::require_wrapper_placement()?;
        Self::open_at(path, uid, limits, deadline)
    }

    fn open_at(path: &Path, uid: u32, limits: Limits, deadline: Instant) -> Result<Self> {
        let mut window = Self::begin_at(uid, limits, deadline)?;
        window.bind_git(path)?;
        Ok(window)
    }

    /// Start before decoding global configuration or discovering the Git root.
    /// The same thread, signal and deadline cover the later metadata capture.
    pub fn begin(uid: u32, limits: Limits, deadline: Instant) -> Result<Self> {
        crate::build_executor::workload::require_wrapper_placement()?;
        Self::begin_at(uid, limits, deadline)
    }

    fn begin_at(uid: u32, limits: Limits, deadline: Instant) -> Result<Self> {
        ensure!(
            uid > 0 && uid == unsafe { libc::geteuid() },
            "Git read window credential differs"
        );
        limits.validate()?;
        let mut limit = std::mem::MaybeUninit::<libc::rlimit>::uninit();
        syscall(unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, limit.as_mut_ptr()) })?;
        let limit = unsafe { limit.assume_init() }.rlim_cur.saturating_sub(64);
        let descriptor_limit = usize::try_from(limit)
            .unwrap_or(usize::MAX)
            .min(MAX_ENTRIES);
        ensure!(
            descriptor_limit > 0,
            "Git read window has no descriptor headroom"
        );
        let signal = Signal::new()?;
        let fd = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
        ensure!(fd >= 0, "Git namespace watch unavailable");
        let events = unsafe { File::from_raw_fd(fd) };
        let window = Self {
            signal,
            events,
            root: None,
            leases: Vec::new(),
            held_files: BTreeMap::new(),
            watches: BTreeMap::new(),
            descriptor_limit,
            uid,
            bytes: 0,
            entries: 0,
            limits,
            deadline,
            poisoned: std::cell::Cell::new(false),
        };
        window.check()?;
        Ok(window)
    }

    pub fn bind_git(&mut self, path: &Path) -> Result<()> {
        let result = (|| {
            self.check()?;
            ensure!(self.root.is_none(), "Git read window root already bound");
            self.watch_ancestors(path)?;
            let root = directory(path)?;
            let device = root.metadata()?.dev();
            self.root = Some((path.to_owned(), root.try_clone()?));
            self.check()?;
            self.walk(root, device, 1)?;
            self.check()
        })();
        if result.is_err() {
            self.poisoned.set(true);
        }
        result
    }

    pub fn extend_git(&mut self, path: &Path) -> Result<()> {
        let result = (|| {
            self.check()?;
            self.watch_ancestors(path)?;
            let root = directory(path)?;
            let device = root.metadata()?.dev();
            self.walk(root, device, 1)?;
            self.check()
        })();
        if result.is_err() {
            self.poisoned.set(true);
        }
        result
    }

    /// Pin/watch a profile namespace component before its type/link is inspected.
    /// Resolved parents are walked in order; immutable store contents need no
    /// executable-directory snapshot. Ancestor replacement remains a sticky veto.
    pub(in crate::build_executor::preparation) fn hold_path_component(
        &mut self,
        path: &Path,
    ) -> Result<()> {
        let result = (|| {
            self.check()?;
            ensure!(
                path.is_absolute()
                    && path.as_os_str().len() <= 4096
                    && path.components().all(|part| matches!(
                        part,
                        std::path::Component::RootDir | std::path::Component::Normal(_)
                    )),
                "invalid executable namespace component"
            );
            if let Some(parent) = path.parent() {
                ensure!(
                    std::fs::canonicalize(parent)? == parent,
                    "executable namespace parent redirected"
                );
            }
            let open = || {
                OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC)
                    .open(path)
            };
            let pin = open()?;
            let before = pin.metadata()?;
            ensure!(
                before.is_dir() || before.is_symlink() || before.is_file(),
                "unsupported executable namespace component"
            );
            let mask = if before.is_dir() {
                libc::IN_ONLYDIR
                    | libc::IN_ATTRIB
                    | libc::IN_MOVE_SELF
                    | libc::IN_DELETE_SELF
                    | libc::IN_UNMOUNT
            } else {
                WATCH
            };
            self.watch_mask(&pin, mask)?;
            let after = open()?.metadata()?;
            // Directory ctime moves with every entry created inside it (e.g. a
            // busy /nix/store or /tmp ancestor); its self-watch deliberately
            // ignores content. Replacement/permission identity is what matters.
            let identity = |metadata: &std::fs::Metadata| {
                let ctime = if metadata.is_dir() {
                    (0, 0)
                } else {
                    (metadata.ctime(), metadata.ctime_nsec())
                };
                (
                    metadata.dev(),
                    metadata.ino(),
                    metadata.mode(),
                    metadata.uid(),
                    metadata.gid(),
                    ctime,
                )
            };
            ensure!(
                identity(&before) == identity(&after),
                "executable namespace changed while pinning"
            );
            self.check()
        })();
        if result.is_err() {
            self.poisoned.set(true);
        }
        result
    }

    /// Freeze source membership (including a currently absent tracked file)
    /// before listing/copying it. Unrelated ancestor membership remains live.
    pub fn hold_source_directory(&mut self, path: &Path) -> Result<()> {
        let result = (|| {
            self.check()?;
            let mut anchor = path;
            loop {
                match std::fs::symlink_metadata(anchor) {
                    Ok(_) => break,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                        anchor = anchor.parent().context("source absence has no parent")?;
                    }
                    Err(error) => return Err(error.into()),
                }
            }
            self.watch_ancestors(anchor)?;
            let directory = directory(anchor)?;
            self.watch_mask(&directory, WATCH | libc::IN_ONLYDIR)?;
            self.check()
        })();
        if result.is_err() {
            self.poisoned.set(true);
        }
        result
    }

    pub fn hold_source_link(&mut self, path: &Path) -> Result<()> {
        self.hold_path_component(path)
    }

    /// Same original read window for explicit source-data contexts. Never used
    /// for key material; the context selector rejects it before this call.
    pub fn hold_source_file(&mut self, path: &Path) -> Result<()> {
        self.hold_configuration(path, self.uid)
    }

    /// Acquire before reading bytes. Local files may already be held by the Git
    /// walk; repeated references reuse that lease rather than opening a new one.
    pub(in crate::build_executor::preparation) fn hold_configuration(
        &mut self,
        path: &Path,
        uid: u32,
    ) -> Result<()> {
        let result = (|| {
            self.check()?;
            ensure!(uid == self.uid, "configuration read window actor differs");
            self.watch_ancestors(path)?;
            let pin = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(path)?;
            let metadata = pin.metadata()?;
            let immutable = metadata.uid() == 0
                && metadata.mode() & 0o222 == 0
                && path.starts_with("/nix/store");
            ensure!(
                metadata.is_file()
                    && ((metadata.uid() == self.uid && metadata.nlink() == 1) || immutable),
                "unsupported configuration read window inode"
            );
            if immutable {
                crate::build_executor::daemon::trusted_path(path)?;
            }
            let file = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
                .open(format!("/proc/self/fd/{}", pin.as_raw_fd()))?;
            ensure!(
                identity(&pin)? == identity(&file)?,
                "configuration pin differs"
            );
            self.hold(file, immutable)?;
            self.check()
        })();
        if result.is_err() {
            self.poisoned.set(true);
        }
        result
    }

    fn watch_ancestors(&mut self, path: &Path) -> Result<()> {
        ensure!(
            path.is_absolute()
                && path.as_os_str().len() <= 4096
                && std::fs::canonicalize(path)? == path,
            "Git read window redirected"
        );
        // Directory replacement must veto even if restored before a later stat.
        // Ignore unrelated child activity outside the selected Git tree.
        let ancestors: Vec<_> = path.ancestors().skip(1).collect();
        for ancestor in ancestors.into_iter().rev() {
            self.ready()?;
            self.watch_mask(
                &directory(ancestor)?,
                libc::IN_ONLYDIR
                    | libc::IN_ATTRIB
                    | libc::IN_MOVE_SELF
                    | libc::IN_DELETE_SELF
                    | libc::IN_UNMOUNT,
            )?;
        }
        self.ready()
    }

    fn ready(&self) -> Result<()> {
        ensure!(
            !self.poisoned.get() && Instant::now() < self.deadline,
            "Git read window expired or poisoned"
        );
        self.signal.thread()?;
        self.signal.quiet()?;
        // Bounded drain; only kernel batching, never a retried decision.
        for _ in 0..64 {
            let mut bytes = [0u8; 4096];
            match (&self.events).read(&mut bytes) {
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => return Ok(()),
                Ok(count) => {
                    // Directory-self watches (ancestors, PATH components) get
                    // IN_ATTRIB for every entry too, e.g. a busy /nix/store or
                    // /tmp. Only those named child events are unrelated; self,
                    // overflow, ignored and any Git-tree child event veto.
                    ensure!(
                        events(&bytes[..count])?
                            .into_iter()
                            .all(|(wd, named)| named && self.watches.get(&wd) == Some(&false)),
                        "Git namespace/metadata watch changed or closed"
                    );
                }
                Err(_) => anyhow::bail!("Git namespace watch unavailable"),
            }
        }
        anyhow::bail!("Git namespace watch event flood")
    }

    fn watch(&mut self, file: &File, is_directory: bool) -> Result<()> {
        self.watch_mask(
            file,
            WATCH | if is_directory { libc::IN_ONLYDIR } else { 0 },
        )
    }

    fn watch_mask(&mut self, file: &File, mask: u32) -> Result<()> {
        // Follow only our pinned /proc FD. Shared ancestors/local configuration
        // reuse a watch; adding a narrower mask must never weaken an earlier one.
        let path = std::ffi::CString::new(format!("/proc/self/fd/{}", file.as_raw_fd()))?;
        let id = unsafe {
            libc::inotify_add_watch(
                self.events.as_raw_fd(),
                path.as_ptr(),
                mask | libc::IN_MASK_ADD,
            )
        };
        ensure!(id >= 0, "Git namespace watch unavailable");
        *self.watches.entry(id).or_insert(false) |= mask & CHILD_EVENTS != 0;
        ensure!(
            self.watches.len() <= self.limits.entries as usize && self.watches.len() <= MAX_ENTRIES,
            "Git namespace watch bound exceeded"
        );
        Ok(())
    }

    fn hold(&mut self, file: File, immutable: bool) -> Result<()> {
        self.watch(&file, false)?;
        let current = identity(&file)?;
        if let Some(previous) = self.held_files.get(&current) {
            ensure!(*previous == immutable, "Git file authority changed");
            return self.ready();
        }
        self.bytes = self
            .bytes
            .checked_add(file.metadata()?.len())
            .context("Git window byte overflow")?;
        ensure!(
            self.bytes <= self.limits.bytes.min(MAX_NAR_BYTES as u64)
                && self.leases.len() < self.descriptor_limit,
            "Git read window resource bound exceeded"
        );
        if !immutable {
            self.signal.lease(&file)?;
        }
        self.leases.push(HeldFile { file, immutable });
        self.held_files.insert(current, immutable);
        self.ready()
    }

    fn walk(&mut self, file: File, device: u64, depth: u16) -> Result<()> {
        self.ready()?;
        self.entries = self
            .entries
            .checked_add(1)
            .context("Git window entry overflow")?;
        ensure!(
            depth <= self.limits.depth
                && self.entries <= self.limits.entries
                && self.entries as usize <= MAX_ENTRIES,
            "Git read window entry/depth bound exceeded"
        );
        let metadata = file.metadata()?;
        let is_directory = metadata.is_dir();
        ensure!(
            metadata.uid() == self.uid
                && metadata.dev() == device
                && (is_directory || (metadata.is_file() && metadata.nlink() == 1)),
            "unsupported Git window inode"
        );
        if is_directory {
            self.watch(&file, true)?;
            // Register the directory before enumerating names. Once all leases
            // are held, every subsequent Git read and dump uses this same window.
            let mut entries = Entries::new(&file)?;
            while let Some(name) = entries.next()? {
                self.ready()?;
                let pin = open(&file, &name, libc::O_PATH)?;
                let metadata = pin.metadata()?;
                ensure!(
                    metadata.uid() == self.uid
                        && metadata.dev() == device
                        && (metadata.is_dir() || (metadata.is_file() && metadata.nlink() == 1)),
                    "unsupported Git window entry"
                );
                let child = OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_CLOEXEC | libc::O_NONBLOCK)
                    .open(format!("/proc/self/fd/{}", pin.as_raw_fd()))?;
                ensure!(
                    identity(&pin)? == identity(&child)?,
                    "Git window entry replaced"
                );
                self.walk(
                    child,
                    device,
                    depth.checked_add(1).context("Git window depth overflow")?,
                )?;
            }
        } else {
            self.hold(file, false)?;
        }
        self.ready()
    }

    pub fn require_path(&self, path: &Path) -> Result<()> {
        let matches = self.root.as_ref().is_some_and(|(root, _)| root == path);
        if !matches {
            self.poisoned.set(true);
        }
        ensure!(matches, "Git read window path differs");
        self.check()
    }

    /// Cheap break/event veto for Runner's existing I/O loop. Full lease/root
    /// revalidation still occurs around commands and before returning material.
    pub fn poll(&self) -> Result<()> {
        let result = self.ready();
        if result.is_err() {
            self.poisoned.set(true);
        }
        result
    }

    pub fn check(&self) -> Result<()> {
        let result = self.check_inner();
        if result.is_err() {
            self.poisoned.set(true);
        }
        result
    }

    fn check_inner(&self) -> Result<()> {
        self.ready()?;
        if let Some((path, file)) = &self.root {
            ensure!(
                identity(&directory(path)?)? == identity(file)?,
                "Git window root replaced"
            );
        }
        for held in &self.leases {
            ensure!(
                Instant::now() < self.deadline,
                "Git read window deadline expired"
            );
            let metadata = held.file.metadata()?;
            if held.immutable {
                ensure!(
                    metadata.uid() == 0 && metadata.mode() & 0o222 == 0,
                    "immutable configuration inode changed"
                );
            } else {
                ensure!(
                    unsafe { libc::fcntl(held.file.as_raw_fd(), libc::F_GETLEASE) }
                        == libc::F_RDLCK,
                    "Git read lease broken or unavailable"
                );
                ensure!(
                    metadata.uid() == self.uid && metadata.nlink() == 1,
                    "Git read lease inode changed"
                );
            }
        }
        self.ready()
    }

    /// Lease notification masking is private to this helper thread. Native
    /// children keep the pre-window mask, including SIGPIPE; lease FDs are CLOEXEC.
    pub fn prepare_command(&self, command: &mut Command) -> Result<()> {
        self.check()?;
        let original = self.signal.original;
        unsafe {
            command.pre_exec(move || {
                let result =
                    libc::pthread_sigmask(libc::SIG_SETMASK, &original, std::ptr::null_mut());
                if result == 0 {
                    Ok(())
                } else {
                    Err(std::io::Error::from_raw_os_error(result))
                }
            });
        }
        Ok(())
    }

    pub fn finish(mut self) -> Result<()> {
        self.check()?;
        self.leases.clear();
        self.signal.quiet()?;
        self.signal.restore()
    }
}

impl Drop for ReadWindow {
    fn drop(&mut self) {
        // Close leases before restoring notification delivery, including failures
        // during acquisition. No attempt to recreate a broken capture window.
        self.leases.clear();
    }
}

fn identity(file: &File) -> Result<(u64, u64, u32)> {
    let metadata = file.metadata()?;
    Ok((
        metadata.dev(),
        metadata.ino(),
        metadata.mode() & libc::S_IFMT,
    ))
}

struct Signal {
    number: i32,
    tid: libc::pid_t,
    original: libc::sigset_t,
    fd: File,
    restored: bool,
    _thread_bound: PhantomData<Rc<()>>,
}

impl Signal {
    fn new() -> Result<Self> {
        // No process-wide handler. F_OWNER_TID and !Send bind every notification
        // to this thread; never borrow an existing handler or pending signal.
        let number = libc::SIGRTMAX();
        let mut action = std::mem::MaybeUninit::<libc::sigaction>::uninit();
        syscall(unsafe { libc::sigaction(number, std::ptr::null(), action.as_mut_ptr()) })?;
        ensure!(
            unsafe { action.assume_init() }.sa_sigaction == libc::SIG_DFL,
            "Git lease signal is already owned"
        );
        let mut pending = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
        syscall(unsafe { libc::sigpending(pending.as_mut_ptr()) })?;
        ensure!(
            unsafe { libc::sigismember(&pending.assume_init(), number) } == 0,
            "Git lease signal already pending"
        );
        let mut set = unsafe { std::mem::zeroed::<libc::sigset_t>() };
        syscall(unsafe { libc::sigemptyset(&mut set) })?;
        syscall(unsafe { libc::sigaddset(&mut set, number) })?;
        let mut original = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
        let result = unsafe { libc::pthread_sigmask(libc::SIG_BLOCK, &set, original.as_mut_ptr()) };
        ensure!(result == 0, "Git lease signal mask unavailable");
        let original = unsafe { original.assume_init() };
        let fd = unsafe { libc::signalfd(-1, &set, libc::SFD_CLOEXEC | libc::SFD_NONBLOCK) };
        if fd < 0 {
            unsafe {
                libc::pthread_sigmask(libc::SIG_SETMASK, &original, std::ptr::null_mut());
            }
            anyhow::bail!("Git lease notification unavailable");
        }
        Ok(Self {
            number,
            tid: unsafe { libc::syscall(libc::SYS_gettid) as libc::pid_t },
            original,
            fd: unsafe { File::from_raw_fd(fd) },
            restored: false,
            _thread_bound: PhantomData,
        })
    }

    fn thread(&self) -> Result<()> {
        ensure!(
            !self.restored && self.tid == unsafe { libc::syscall(libc::SYS_gettid) as libc::pid_t },
            "Git lease thread differs"
        );
        Ok(())
    }

    fn quiet(&self) -> Result<()> {
        self.thread()?;
        let mut bytes = [0u8; 128];
        match (&self.fd).read(&mut bytes) {
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => Ok(()),
            Ok(_) => anyhow::bail!("Git lease break notification"),
            Err(_) => anyhow::bail!("Git lease notification unavailable"),
        }
    }

    fn lease(&self, file: &File) -> Result<()> {
        self.thread()?;
        // Linux fcntl ABI; libc lacks F_SETSIG. Only this thread gets breaks.
        const F_SETOWN_EX: libc::c_int = 15;
        const F_SETSIG: libc::c_int = 10;
        #[repr(C)]
        struct Owner {
            kind: libc::c_int,
            pid: libc::pid_t,
        }
        let owner = Owner {
            kind: 0,
            pid: self.tid,
        };
        ensure!(
            unsafe { libc::fcntl(file.as_raw_fd(), F_SETOWN_EX, &owner) } == 0
                && unsafe { libc::fcntl(file.as_raw_fd(), F_SETSIG, self.number) } == 0,
            "Git lease notification binding failed"
        );
        ensure!(
            unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETLEASE, libc::F_RDLCK) } == 0,
            "Git read lease unavailable; capture was not retried"
        );
        Ok(())
    }

    fn restore(&mut self) -> Result<()> {
        self.thread()?;
        let result = unsafe {
            libc::pthread_sigmask(libc::SIG_SETMASK, &self.original, std::ptr::null_mut())
        };
        ensure!(result == 0, "Git lease signal restoration failed");
        self.restored = true;
        Ok(())
    }
}

impl Drop for Signal {
    fn drop(&mut self) {
        if !self.restored {
            // Consume only this newly reserved notification signal, with a bound.
            // A late/persisting break may terminate the helper on unmask: failure,
            // not a successful captured-source receipt.
            let mut bytes = [0u8; 128];
            for _ in 0..64 {
                if (&self.fd).read(&mut bytes).is_err() {
                    break;
                }
            }
            let _ = self.restore();
        }
    }
}

/// Decode one inotify read into (watch, has-name) pairs; malformed is a veto.
fn events(bytes: &[u8]) -> Result<Vec<(i32, bool)>> {
    let mut decoded = Vec::new();
    let mut offset = 0usize;
    while offset < bytes.len() {
        let header = bytes
            .get(offset..offset + 16)
            .context("truncated Git namespace event")?;
        let wd = i32::from_ne_bytes(header[0..4].try_into()?);
        let length = usize::try_from(u32::from_ne_bytes(header[12..16].try_into()?))?;
        offset = offset
            .checked_add(16 + length)
            .filter(|end| *end <= bytes.len())
            .context("truncated Git namespace event")?;
        decoded.push((wd, length > 0));
    }
    Ok(decoded)
}

#[cfg(test)]
mod tests;
