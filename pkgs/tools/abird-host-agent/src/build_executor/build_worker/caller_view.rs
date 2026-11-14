//! Child-only original-path view. Writable Git/runtime layers live exclusively
//! in the registered source slot. The private PID namespace excludes host proc
//! aliases; namespace isolation alone is not complete FD/delegated-effect closure.

use crate::build_executor::{controller_service::Account, native_intent::CheckoutInput};
use anyhow::{Context, Result, ensure};
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Instant;

const READONLY: u64 = 1;
const NOSUID: u64 = 2;
const NODEV: u64 = 4;
const NOEXEC: u64 = 8;
const FILESYSTEM: u64 = READONLY | NOSUID | NODEV;
// Only these kernel memory devices, not host disks, terminals or IPC endpoints.
const DEVICES: [(&str, u64); 5] = [
    ("null", 3),
    ("zero", 5),
    ("full", 7),
    ("random", 8),
    ("urandom", 9),
];

/// A pinned binding cloned as a detached mount tree before the child unshares
/// its mount namespace: a bind from an old-namespace FD is refused (EINVAL),
/// while attaching a detached clone preserves the pinned identity.
struct Bind {
    original: PathBuf,
    tree: OwnedFd,
    target: CString,
    _pin: File,
}
/// Layers are named by absolute path in the child's copied namespace (overlay
/// clones layer mounts, so old-namespace FDs are refused); each path's pinned
/// (dev, ino) is rechecked immediately before the mount.
struct Overlay {
    target: CString,
    options: CString,
    readonly: bool,
    layers: Vec<(CString, u64, u64)>,
    _pins: Vec<File>,
}

pub(in crate::build_executor) struct View {
    root: CString,
    proc: CString,
    binds: Vec<Bind>,
    devices: Vec<Bind>,
    configuration: Vec<Bind>,
    overlays: Vec<Overlay>,
    pub workspace: PathBuf,
}

impl View {
    /// Trusted exec-closed native client, not an offline caller helper. The
    /// corresponding Runner scope must retain admitted daemon access. No live
    /// caller directories/account are consulted: every non-system read binding
    /// is a sealed capsule/profile image, and only the per-attempt cache writes.
    pub(super) fn prepare_native(
        root: &Path,
        bindings: &[(PathBuf, PathBuf)],
        profiles: &[(PathBuf, PathBuf)],
        cache: &Path,
        deadline: Instant,
    ) -> Result<Self> {
        ensure!(
            unsafe { libc::geteuid() } == 0 && Instant::now() < deadline,
            "native view requires original root lifetime"
        );
        directory(root, 0, 0, 0o755)?;
        let mut view = Self {
            root: path(root)?,
            proc: path(&mountpoint(root, Path::new("/proc"), true)?)?,
            binds: Vec::new(),
            devices: Vec::new(),
            configuration: Vec::new(),
            overlays: Vec::new(),
            workspace: PathBuf::new(),
        };
        for original in ["/nix/store", "/etc", "/nix/var/nix/daemon-socket"] {
            let original = Path::new(original);
            view.native_bind(root, original, original, FILESYSTEM, false)?;
        }
        // Parent before child: a linked common Git directory can be nested
        // beneath another captured worktree. Never let a prefix hide its image.
        let mut bindings = bindings.to_vec();
        bindings.sort_by(|a, b| a.0.cmp(&b.0));
        ensure!(
            bindings.len() <= 8 && profiles.len() <= 68,
            "native view binding count exceeds bound"
        );
        for (original, sealed) in &bindings {
            ensure!(Instant::now() < deadline, "native view deadline expired");
            view.native_bind(root, original, sealed, FILESYSTEM, false)?;
        }
        // Captured system/store-backed profile paths need not exist on the
        // builder. Supply private overlay mountpoints, never create files in
        // the live /etc or /nix/store merely to replay a caller profile.
        for (index, prefix) in [Path::new("/etc"), Path::new("/nix/store")]
            .into_iter()
            .enumerate()
        {
            let covered = profiles
                .iter()
                .filter_map(|(original, _)| original.strip_prefix(prefix).ok())
                .collect::<Vec<_>>();
            if covered.is_empty() {
                continue;
            }
            let parent = root.parent().context("native view parent missing")?;
            let name = root
                .file_name()
                .context("native view name missing")?
                .to_string_lossy();
            let upper = parent.join(format!("{name}-profile-upper-{index}"));
            let work = parent.join(format!("{name}-profile-work-{index}"));
            directory(&upper, 0, 0, 0o755)?;
            directory(&work, 0, 0, 0o700)?;
            for relative in covered {
                let target = upper.join(relative);
                skeleton(
                    &upper,
                    target.parent().context("profile mount parent missing")?,
                )?;
                OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o444)
                    .open(target)?;
            }
            view.overlay(root, prefix, &upper, &work, true)?;
        }
        for (original, sealed) in profiles {
            view.native_bind(root, original, sealed, FILESYSTEM, true)?;
        }
        view.native_bind(root, cache, cache, NOSUID | NODEV, false)?;
        view.native_bind(root, Path::new("/tmp"), cache, NOSUID | NODEV, false)?;
        view.install_devices(root, deadline)?;
        skeleton(root, &root.join("var/empty"))?;
        File::open(root)?.sync_all()?;
        Ok(view)
    }

    fn native_bind(
        &mut self,
        root: &Path,
        original: &Path,
        sealed: &Path,
        attributes: u64,
        profile: bool,
    ) -> Result<()> {
        let pinned = pin(sealed)?;
        let target = mountpoint(root, original, pinned.metadata()?.is_dir())?;
        let bind = Bind {
            original: original.to_owned(),
            tree: detached(&pinned, attributes)?,
            target: path(&target)?,
            _pin: pinned,
        };
        if profile {
            self.configuration.push(bind);
        } else {
            self.binds.push(bind);
        }
        Ok(())
    }

    /// Caller has validated the original actor/allocation and source binding.
    /// All created paths are below its exclusive root-private caller directory.
    pub(in crate::build_executor) fn prepare(
        parent: &Path,
        producer: &Path,
        input: &CheckoutInput,
        account: &Account,
        deadline: Instant,
    ) -> Result<Self> {
        input.validate()?;
        let (source, checkout) = input.context()?;
        let source = source.as_path();
        let run = &input.validation.request.run_id;
        ensure!(
            unsafe { libc::geteuid() } == 0 && Instant::now() < deadline,
            "caller view requires original root lifetime"
        );
        crate::build_executor::workload::require_wrapper_placement()?;
        checkout.validate()?;
        ensure!(
            account
                .capture_roots
                .iter()
                .any(|root| source.starts_with(root))
                && fs::canonicalize(source)? == source
                && source.components().count() > 2,
            "caller view source outside original capture roots"
        );
        // Keep the selected namespace. If absent, overlay its existing ancestor
        // so native initialization creates it privately, never on the host.
        let runtime_root = runtime_parent(&checkout.namespace_root)?;
        let runtime = runtime_root.as_path();
        ensure!(
            !account.home.starts_with(runtime)
                && !account.state_home.starts_with(runtime)
                && !parent.starts_with(runtime)
                && !["/nix", "/etc", "/proc", "/sys", "/run/abird"]
                    .iter()
                    .any(|path| runtime.starts_with(path)),
            "runtime view overlaps private or authority roots"
        );
        ensure!(
            !source.starts_with(runtime) && !runtime.starts_with(source),
            "caller view roots overlap"
        );
        for reserved in ["/nix", "/etc", "/proc", "/dev"] {
            ensure!(
                !source.starts_with(reserved),
                "caller source overlaps installed context"
            );
        }
        let root = parent.join("view");
        directory(&root, 0, 0, 0o755)?;
        let mut view = Self {
            root: path(&root)?,
            proc: path(&mountpoint(&root, Path::new("/proc"), true)?)?,
            binds: Vec::new(),
            devices: Vec::new(),
            configuration: Vec::new(),
            overlays: Vec::new(),
            workspace: PathBuf::new(),
        };
        // No host proc/dev tree, device files or set-ID execution through a
        // recursive read bind. Socket/delegated effects remain separate gates.
        let mut reads = vec![PathBuf::from("/nix/store"), PathBuf::from("/etc")];
        reads.extend(account.capture_roots.iter().cloned());
        reads.push(
            account
                .state_home
                .join("abird/abird-host-manager/fleet-owned"),
        );
        reads.sort();
        reads.dedup();
        ensure!(reads.len() <= 23, "caller view binding count exceeds bound");
        for original in reads {
            ordinary_root(&original)?;
            ensure!(Instant::now() < deadline, "caller view deadline expired");
            let pin = pin(&original)?;
            let target = mountpoint(&root, &original, pin.metadata()?.is_dir())?;
            view.binds.push(Bind {
                tree: detached(&pin, FILESYSTEM)?,
                original,
                target: path(&target)?,
                _pin: pin,
            });
        }
        view.install_devices(&root, deadline)?;
        skeleton(&root, &root.join("var/empty"))?;
        skeleton(&root, &root.join(account.home.strip_prefix("/")?))?;
        view.install_aliases(&root, parent, source, runtime, input, deadline)?;
        // The captured .git is a complete upper directory: newly appearing
        // lower refs/config must not merge into the admitted image.
        let metadata = fs::symlink_metadata(producer.join(".git"))?;
        ensure!(
            metadata.is_dir() && metadata.uid() == account.uid,
            "caller Git producer credential differs"
        );
        let git = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(producer.join(".git"))?;
        syscall(unsafe {
            libc::fsetxattr(
                git.as_raw_fd(),
                c"trusted.overlay.opaque".as_ptr(),
                b"y".as_ptr().cast(),
                1,
                libc::XATTR_CREATE,
            )
        })?;
        let source_meta = fs::symlink_metadata(source)?;
        ensure!(
            source_meta.uid() == account.uid,
            "caller source root owner differs"
        );
        fs::set_permissions(
            producer,
            fs::Permissions::from_mode(source_meta.mode() & 0o777),
        )?;
        let source_work = parent.join("git-overlay-work");
        directory(&source_work, 0, 0, 0o700)?;
        let common = input.common_directory()?;
        if common == source.join(".git") {
            view.overlay(&root, source, producer, &source_work, false)?;
        } else {
            // Linked source: preserve its .git pointer and native common/admin
            // layout, but only the fresh private common image is writable.
            ensure!(
                account
                    .capture_roots
                    .iter()
                    .any(|root| common.starts_with(root)),
                "linked Git common directory outside captured roots"
            );
            view.native_bind(
                &root,
                &common,
                &producer.join(".git"),
                NOSUID | NODEV,
                false,
            )?;
        }
        let runtime_upper = parent.join("runtime-upper");
        let runtime_meta = fs::symlink_metadata(runtime)?;
        ensure!(
            runtime_meta.is_dir() && [0, account.uid].contains(&runtime_meta.uid()),
            "native runtime namespace owner differs"
        );
        directory(
            &runtime_upper,
            runtime_meta.uid(),
            runtime_meta.gid(),
            runtime_meta.mode() & 0o7777,
        )?;
        let runtime_work = parent.join("runtime-overlay-work");
        directory(&runtime_work, 0, 0, 0o700)?;
        view.overlay(&root, runtime, &runtime_upper, &runtime_work, false)?;
        view.workspace = runtime_upper.join(checkout.workspace(run)?.strip_prefix(runtime)?);
        let files = input.configuration.install(
            &parent.join("configuration"),
            &common,
            &producer.join(".git"),
            account.uid,
            deadline,
        )?;
        for (original, file) in files {
            ensure!(
                !original.starts_with(runtime)
                    && !["/proc", "/sys", "/dev", "/run/abird"]
                        .iter()
                        .any(|root| original.starts_with(root)),
                "private configuration overlaps runtime authority"
            );
            let target = mountpoint(&root, &original, false)?;
            view.configuration.push(Bind {
                tree: detached(&file, FILESYSTEM)?,
                original,
                target: path(&target)?,
                _pin: file,
            });
        }
        for (name, original) in [("checkout-tmp", "/tmp"), ("checkout-var-tmp", "/var/tmp")] {
            ensure!(
                !source.starts_with(original) && !runtime.starts_with(original),
                "checkout scratch overlaps original source/runtime"
            );
            let scratch = parent.join(name);
            directory(&scratch, account.uid, account.gid, 0o700)?;
            view.native_bind(&root, Path::new(original), &scratch, NOSUID | NODEV, false)?;
        }
        // Conventional hook/filter shebangs are part of the original host's
        // trusted immutable interpreter view, not a shell command override.
        let shell = fs::canonicalize("/bin/sh")?;
        ensure!(
            shell.starts_with("/nix/store"),
            "caller /bin/sh is not immutable"
        );
        crate::build_executor::daemon::executable(&shell)?;
        let logical_shell = root.join("bin/sh");
        if fs::symlink_metadata(&logical_shell).is_ok() {
            ensure!(
                fs::canonicalize(&logical_shell)? == shell,
                "captured /bin/sh alias differs"
            );
        } else {
            view.native_bind(&root, Path::new("/bin/sh"), &shell, FILESYSTEM, false)?;
        }
        File::open(parent)?.sync_all()?;
        ensure!(
            Instant::now() < deadline,
            "caller view setup exceeded original deadline"
        );
        Ok(view)
    }

    fn install_devices(&mut self, root: &Path, deadline: Instant) -> Result<()> {
        skeleton(root, &root.join("dev"))?;
        for (name, minor) in DEVICES {
            ensure!(Instant::now() < deadline, "caller device setup expired");
            let original = Path::new("/dev").join(name);
            let pin = pin(&original)?;
            memory_device(&pin.metadata()?, minor)?;
            let target = mountpoint(root, &original, false)?;
            self.devices.push(Bind {
                tree: detached(&pin, READONLY | NOSUID | NOEXEC)?,
                original,
                target: path(&target)?,
                _pin: pin,
            });
        }
        for (name, target) in [
            ("fd", "/proc/self/fd"),
            ("stdin", "/proc/self/fd/0"),
            ("stdout", "/proc/self/fd/1"),
            ("stderr", "/proc/self/fd/2"),
        ] {
            std::os::unix::fs::symlink(target, root.join("dev").join(name))?;
        }
        Ok(())
    }

    fn install_aliases(
        &mut self,
        root: &Path,
        parent: &Path,
        source: &Path,
        runtime: &Path,
        input: &CheckoutInput,
        deadline: Instant,
    ) -> Result<()> {
        input.search_path.validate()?;
        input.configuration.validate()?;
        let mut aliases = std::collections::BTreeMap::new();
        for link in input
            .search_path
            .links()
            .iter()
            .chain(input.configuration.links())
        {
            if let Some(previous) = aliases.insert(&link.path, link) {
                ensure!(previous == link, "caller profile alias bindings differ");
            }
        }
        let mut covered = std::collections::BTreeMap::<PathBuf, Vec<_>>::new();
        for link in aliases.into_values() {
            ensure!(
                Instant::now() < deadline
                    && !link.path.starts_with(source)
                    && !link.path.starts_with(runtime)
                    && !["/proc", "/sys", "/dev", "/run/abird"]
                        .iter()
                        .any(|path| link.path.starts_with(path))
                    && (!link.path.starts_with("/nix")
                        || link.path.starts_with("/nix/var/nix/profiles")),
                "caller PATH alias overlaps execution roots"
            );
            let binding = self
                .binds
                .iter()
                .filter(|bind| link.path.starts_with(&bind.original))
                .max_by_key(|bind| bind.original.components().count());
            if let Some(binding) = binding {
                ensure!(
                    binding._pin.metadata()?.is_dir() && link.path != binding.original,
                    "caller PATH alias replaces a bound root"
                );
                covered
                    .entry(binding.original.clone())
                    .or_default()
                    .push(link);
            } else {
                let target = root.join(link.path.strip_prefix("/")?);
                skeleton(root, target.parent().context("caller PATH parent missing")?)?;
                std::os::unix::fs::symlink(&link.target, target)?;
            }
        }
        // PATH/config aliases must survive the read-only /etc bind together.
        // Overlay captured links only; never bind all of /run or HOME.
        for (index, (original, links)) in covered.into_iter().enumerate() {
            ensure!(Instant::now() < deadline, "caller PATH mount setup expired");
            let upper = parent.join(format!("path-upper-{index}"));
            let work = parent.join(format!("path-work-{index}"));
            directory(&upper, 0, 0, 0o755)?;
            directory(&work, 0, 0, 0o700)?;
            for link in links {
                let target = upper.join(link.path.strip_prefix(&original)?);
                skeleton(
                    &upper,
                    target
                        .parent()
                        .context("caller PATH overlay parent missing")?,
                )?;
                std::os::unix::fs::symlink(&link.target, target)?;
            }
            self.overlay(root, &original, &upper, &work, true)?;
        }
        Ok(())
    }

    fn overlay(
        &mut self,
        root: &Path,
        original: &Path,
        upper: &Path,
        work: &Path,
        readonly: bool,
    ) -> Result<()> {
        let pins = vec![pin(original)?, pin(upper)?, pin(work)?];
        ensure!(
            pins[1].metadata()?.dev() == pins[2].metadata()?.dev(),
            "caller overlay filesystems differ"
        );
        let mut layers = Vec::new();
        for (layer, pin) in [original, upper, work].into_iter().zip(&pins) {
            let text = layer.to_str().context("non-UTF8 caller overlay layer")?;
            // Overlay option syntax has no escaping here; reject separators.
            ensure!(
                !text.contains([',', ':', '\\', '=']),
                "caller overlay layer path is not representable"
            );
            let metadata = pin.metadata()?;
            layers.push((path(layer)?, metadata.dev(), metadata.ino()));
        }
        // Git observation requires one device identity, not backing-layer IDs.
        let options = CString::new(format!(
            "lowerdir={},upperdir={},workdir={},index=off,redirect_dir=off,metacopy=off,xino=on",
            original.display(),
            upper.display(),
            work.display()
        ))?;
        self.overlays.push(Overlay {
            target: path(&mountpoint(root, original, true)?)?,
            options,
            readonly,
            layers,
            _pins: pins,
        });
        Ok(())
    }

    /// Pre-exec only, after joining the original producer cgroup. The retained
    /// spawn child waits for its namespace init; only that init continues setup.
    /// No allocations or parent-process namespace/credential/signal changes.
    pub(in crate::build_executor) fn enter(&self, offline: bool) -> std::io::Result<()> {
        syscall(unsafe {
            libc::unshare(
                libc::CLONE_NEWNS
                    | libc::CLONE_NEWPID
                    | libc::CLONE_NEWIPC
                    // Private abstract-socket namespace for caller helpers; the
                    // trusted native view retains its admitted network access.
                    | if offline { libc::CLONE_NEWNET } else { 0 },
            )
        })?;
        crate::build_executor::process::namespace_child()?;
        syscall(unsafe {
            libc::mount(
                std::ptr::null(),
                c"/".as_ptr(),
                std::ptr::null(),
                libc::MS_REC | libc::MS_PRIVATE,
                std::ptr::null(),
            )
        })?;
        for bind in self.binds.iter().chain(&self.devices) {
            bind.enter()?;
        }
        for overlay in &self.overlays {
            for (layer, device, inode) in &overlay.layers {
                let mut status: libc::stat = unsafe { std::mem::zeroed() };
                syscall(unsafe { libc::lstat(layer.as_ptr(), &mut status) })?;
                if status.st_dev != *device || status.st_ino != *inode {
                    return Err(std::io::Error::from_raw_os_error(libc::ESTALE));
                }
            }
            syscall(unsafe {
                libc::mount(
                    c"overlay".as_ptr(),
                    overlay.target.as_ptr(),
                    c"overlay".as_ptr(),
                    libc::MS_NOSUID
                        | libc::MS_NODEV
                        | if overlay.readonly { libc::MS_RDONLY } else { 0 },
                    overlay.options.as_ptr().cast(),
                )
            })?;
        }
        // Config files override live lower files only after source/PATH overlays.
        // Local Git config remains in the original writable private Git image.
        for bind in &self.configuration {
            bind.enter()?;
        }
        // Mount after fork: unshare(CLONE_NEWPID) affects only future children.
        // Untrusted code sees only this fresh proc instance.
        syscall(unsafe {
            libc::mount(
                c"proc".as_ptr(),
                self.proc.as_ptr(),
                c"proc".as_ptr(),
                libc::MS_RDONLY | libc::MS_NOSUID | libc::MS_NODEV | libc::MS_NOEXEC,
                std::ptr::null(),
            )
        })?;
        syscall(unsafe { libc::chroot(self.root.as_ptr()) })?;
        syscall(unsafe { libc::chdir(c"/var/empty".as_ptr()) })
    }
}

const AT_RECURSIVE: u32 = 0x8000;
const OPEN_TREE_CLONE: u32 = 1;
const MOVE_MOUNT_F_EMPTY_PATH: u32 = 4;

impl Bind {
    /// Pre-exec, inside the new mount namespace: attach the detached clone.
    fn enter(&self) -> std::io::Result<()> {
        syscall(unsafe {
            libc::syscall(
                libc::SYS_move_mount,
                self.tree.as_raw_fd(),
                c"".as_ptr(),
                libc::AT_FDCWD,
                self.target.as_ptr(),
                MOVE_MOUNT_F_EMPTY_PATH,
            ) as i32
        })
    }
}

/// Recursive detached clone of the pinned object with its final attributes.
fn detached(pin: &File, attributes: u64) -> Result<OwnedFd> {
    let fd = unsafe {
        libc::syscall(
            libc::SYS_open_tree,
            pin.as_raw_fd(),
            c"".as_ptr(),
            OPEN_TREE_CLONE | libc::O_CLOEXEC as u32 | libc::AT_EMPTY_PATH as u32 | AT_RECURSIVE,
        )
    } as i32;
    ensure!(
        fd >= 0,
        "clone caller view binding: {}",
        std::io::Error::last_os_error()
    );
    let tree = unsafe { OwnedFd::from_raw_fd(fd) };
    let attributes = MountAttributes {
        set: attributes,
        clear: 0,
        propagation: 0,
        userns: 0,
    };
    syscall(unsafe {
        libc::syscall(
            libc::SYS_mount_setattr,
            tree.as_raw_fd(),
            c"".as_ptr(),
            libc::AT_EMPTY_PATH as u32 | AT_RECURSIVE,
            &attributes,
            std::mem::size_of::<MountAttributes>(),
        ) as i32
    })
    .context("restrict caller view binding")?;
    Ok(tree)
}

fn ordinary_root(root: &Path) -> Result<()> {
    for special in ["/dev", "/proc", "/sys", "/run/abird", "/nix/var/nix"] {
        let special = Path::new(special);
        ensure!(
            !root.starts_with(special) && !special.starts_with(root),
            "caller read binding overlaps authority or special filesystem"
        );
    }
    Ok(())
}

fn memory_device(metadata: &fs::Metadata, minor: u64) -> Result<()> {
    ensure!(
        metadata.file_type().is_char_device()
            && metadata.uid() == 0
            && metadata.rdev() == libc::makedev(1, minor as u32),
        "caller memory device differs"
    );
    Ok(())
}

fn runtime_parent(namespace: &Path) -> Result<PathBuf> {
    let mut path = namespace;
    loop {
        match fs::symlink_metadata(path) {
            Ok(metadata) => {
                ensure!(
                    metadata.is_dir()
                        && fs::canonicalize(path)? == path
                        && path.components().count() > 2,
                    "original runtime ancestor differs or is too broad"
                );
                return Ok(path.to_path_buf());
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                path = path.parent().context("original runtime ancestor missing")?;
            }
            Err(error) => return Err(error.into()),
        }
    }
}

#[repr(C)]
struct MountAttributes {
    set: u64,
    clear: u64,
    propagation: u64,
    userns: u64,
}

fn syscall(value: i32) -> std::io::Result<()> {
    if value == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}
fn path(value: &Path) -> Result<CString> {
    Ok(CString::new(value.as_os_str().as_bytes())?)
}
fn pin(value: &Path) -> Result<File> {
    ensure!(
        fs::canonicalize(value)? == value,
        "caller view binding redirected"
    );
    Ok(OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(value)?)
}
fn directory(value: &Path, uid: u32, gid: u32, mode: u32) -> Result<()> {
    fs::create_dir(value)?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(value)?;
    crate::build_executor::private_tree::clear_acl(&file, true)?;
    syscall(unsafe { libc::fchown(file.as_raw_fd(), uid, gid) })?;
    syscall(unsafe { libc::fchmod(file.as_raw_fd(), mode) })?;
    file.sync_all()?;
    Ok(())
}
fn mountpoint(root: &Path, original: &Path, directory: bool) -> Result<PathBuf> {
    ensure!(
        original.is_absolute()
            && original.components().all(|part| matches!(
                part,
                std::path::Component::RootDir | std::path::Component::Normal(_)
            )),
        "invalid caller view destination"
    );
    let target = root.join(original.strip_prefix("/")?);
    if directory {
        skeleton(root, &target)?;
    } else {
        skeleton(root, target.parent().context("caller view parent missing")?)?;
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&target)?;
    }
    Ok(target)
}

fn skeleton(root: &Path, target: &Path) -> Result<()> {
    let relative = target.strip_prefix(root)?;
    let mut current = root.to_path_buf();
    for part in relative.components() {
        ensure!(
            matches!(part, std::path::Component::Normal(_)),
            "invalid caller view ancestor"
        );
        current.push(part.as_os_str());
        match fs::create_dir(&current) {
            Ok(()) => fs::set_permissions(&current, fs::Permissions::from_mode(0o755))?,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                let metadata = fs::symlink_metadata(&current)?;
                ensure!(
                    metadata.is_dir() && metadata.uid() == 0 && metadata.mode() & 0o022 == 0,
                    "caller view ancestor replaced"
                );
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn caller_read_roots_cannot_reintroduce_host_devices_proc_or_native_authority() {
        for root in [
            "/",
            "/dev",
            "/dev/pts",
            "/proc/1/root",
            "/sys/fs",
            "/run/abird",
            "/run/abird/owned-input",
            "/nix",
            "/nix/var",
            "/nix/var/nix/db",
        ] {
            assert!(ordinary_root(Path::new(root)).is_err(), "{root}");
        }
        for root in [
            "/nix/store",
            "/etc",
            "/home/caller/src",
            "/home/caller/.local/state/abird",
        ] {
            ordinary_root(Path::new(root)).unwrap();
        }
        assert_eq!(
            FILESYSTEM & (READONLY | NOSUID | NODEV),
            READONLY | NOSUID | NODEV
        );
        assert_eq!(FILESYSTEM & NOEXEC, 0); // Original PATH executables remain executable.
    }

    #[test]
    fn caller_devices_are_exact_kernel_memory_nodes_not_regular_files_or_other_devices() {
        for (name, minor) in DEVICES {
            let device = pin(&Path::new("/dev").join(name)).unwrap();
            memory_device(&device.metadata().unwrap(), minor).unwrap();
            assert!(memory_device(&device.metadata().unwrap(), minor + 1).is_err());
        }
        let file = tempfile::tempfile().unwrap();
        assert!(memory_device(&file.metadata().unwrap(), 3).is_err());
        let directory = tempfile::tempdir().unwrap();
        assert!(memory_device(&fs::metadata(directory.path()).unwrap(), 3).is_err());
        // Metadata/allowlist evidence, not a privileged bind-mount qualification.
    }

    #[test]
    fn runtime_view_keeps_selected_namespace_and_only_uses_its_existing_ancestor() {
        let directory = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(directory.path()).unwrap();
        let selected = root.join("native/custom");
        assert_eq!(runtime_parent(&selected).unwrap(), root);
        assert!(!selected.exists()); // Selection does not create host runtime data.
        fs::create_dir(root.join("native")).unwrap();
        assert_eq!(runtime_parent(&selected).unwrap(), root.join("native"));
        std::os::unix::fs::symlink("native", root.join("redirect")).unwrap();
        assert!(runtime_parent(&root.join("redirect")).is_err());
        assert!(runtime_parent(Path::new("/")).is_err());
    }
}
