//! Offline caller helpers, not trusted network acquisition or native clients.
//! Landlock ABI9 is mandatory: ABI6 scopes do not mediate pathname Unix sockets.
//! Existing readonly mounts/private PID+IPC views remain necessary (Landlock does
//! not mediate every metadata operation). Install before caller-controlled code,
//! in the dedicated single-threaded helper/pre-exec child. Never in its controller.

use std::cell::Cell;
use std::ffi::CString;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path};

mod read_scope;
pub use read_scope::ReadScope;

thread_local! {
    // Landlock ABI9 restricts the calling thread, not preexisting siblings.
    // A process-wide success flag would authorize an unrestricted sibling.
    static READ_SCOPE_PID: Cell<u32> = const { Cell::new(0) };
}
pub(super) const REQUIRED: &str = "ABIRD_OWNED_OFFLINE_REQUIRED";

pub(super) fn require_if_requested() -> io::Result<()> {
    if std::env::var_os(REQUIRED).is_some() {
        require_read_scope()?;
    }
    Ok(())
}

/// Caller-bound Git adapters must require this before launching a command. A
/// fixed manager's trusted setup envelope is not permission to execute Git with
/// caller configuration. No environment variable can manufacture this marker.
pub fn require_read_scope() -> io::Result<()> {
    if READ_SCOPE_PID.with(Cell::get) != std::process::id() {
        return Err(io::Error::from_raw_os_error(libc::EPERM));
    }
    Ok(())
}

const EXECUTE: u64 = 1 << 0;
const WRITE_FILE: u64 = 1 << 1;
const READ_FILE: u64 = 1 << 2;
const READ_DIR: u64 = 1 << 3;
const REMOVE_DIR: u64 = 1 << 4;
const REMOVE_FILE: u64 = 1 << 5;
const MAKE_DIR: u64 = 1 << 7;
const MAKE_REG: u64 = 1 << 8;
const MAKE_SOCK: u64 = 1 << 9;
const MAKE_FIFO: u64 = 1 << 10;
const MAKE_SYM: u64 = 1 << 12;
const REFER: u64 = 1 << 13;
const TRUNCATE: u64 = 1 << 14;
const RESOLVE_UNIX: u64 = 1 << 16;
const FS_RIGHTS: u64 = (1 << 17) - 1;
const READ: u64 = EXECUTE | READ_DIR;
const WRITE: u64 = WRITE_FILE
    | REMOVE_DIR
    | REMOVE_FILE
    | MAKE_DIR
    | MAKE_REG
    | MAKE_SOCK
    | MAKE_FIFO
    | MAKE_SYM
    | REFER
    | TRUNCATE;
const SCOPES: u64 = 3; // ABSTRACT_UNIX_SOCKET | SIGNAL
const MIN_ABI: libc::c_long = 9;
const AT_RECURSIVE: u32 = 0x8000;
const READONLY: u64 = 1;
const NOSUID: u64 = 2;
const NODEV: u64 = 4;

#[repr(C)]
struct Ruleset {
    filesystem: u64,
    network: u64,
    scoped: u64,
}

#[repr(C, packed)]
struct PathRule {
    access: u64,
    parent: i32,
}

/// Prepared inside the final private mount view. The trusted caller must supply
/// exclusively fresh private directories before caller code, never a live lower
/// tree/runtime ancestor: granting WRITE_FILE there also grants writes to FIFOs.
/// File reads require an explicit bounded regular-inode scope. No broad live
/// directory READ_FILE rule, ambient read fallback or environment-derived grant.
pub struct Policy {
    writable: Vec<CString>,
    writable_pins: Option<Vec<OwnedFd>>,
    reads: Option<ReadScope>,
    private_proc: bool,
}

impl Policy {
    pub fn new(writable: &[&Path]) -> io::Result<Self> {
        let mut policy = Self::startup(writable)?;
        policy.writable_pins = Some(
            policy
                .writable
                .iter()
                .map(|path| open(path, true))
                .collect::<io::Result<_>>()?,
        );
        Ok(policy)
    }

    // Root's fixed startup only, before the final mounts exist. Never exposed
    // as a caller-Git policy: enter() requires pinned private directories.
    fn startup(writable: &[&Path]) -> io::Result<Self> {
        if writable.len() > 16 {
            return Err(invalid());
        }
        let writable = writable
            .iter()
            .map(|path| {
                if !path.is_absolute()
                    || path.components().count() < 2
                    || path.as_os_str().len() > 4096
                    || !path
                        .components()
                        .all(|part| matches!(part, Component::RootDir | Component::Normal(_)))
                {
                    return Err(invalid());
                }
                CString::new(path.as_os_str().as_bytes()).map_err(|_| invalid())
            })
            .collect::<io::Result<_>>()?;
        Ok(Self {
            writable,
            writable_pins: None,
            reads: None,
            private_proc: false,
        })
    }

    /// Cache a complete policy in the same final view. Reuses the bounded inode
    /// inventory, but never re-resolves helper-mutable writable path names.
    /// Original read-window checks and the original Runner deadline still apply.
    pub fn try_clone(&self) -> io::Result<Self> {
        Ok(Self {
            writable: self.writable.clone(),
            writable_pins: self
                .writable_pins
                .as_ref()
                .map(|pins| {
                    pins.iter()
                        .map(OwnedFd::try_clone)
                        .collect::<io::Result<Vec<_>>>()
                })
                .transpose()?,
            reads: self.reads.as_ref().map(ReadScope::try_clone).transpose()?,
            private_proc: self.private_proc,
        })
    }

    pub fn with_read_scope(mut self, reads: ReadScope) -> io::Result<Self> {
        if self.reads.is_some() {
            return Err(invalid());
        }
        self.reads = Some(reads);
        Ok(self)
    }

    /// Only for the root wrapper's fresh PID/proc view, never a live host proc.
    /// Descendant helpers need their own /proc/self files, not just the fixed
    /// manager's inode. This is an isolated-view grant, not a live-tree grant.
    pub fn with_private_proc(mut self) -> Self {
        self.private_proc = true;
        self
    }

    /// No allocation here. Capture ReadScope beforehand in the final namespace.
    /// Missing read scope is failure, including for an otherwise readonly helper.
    pub fn enter(&self) -> io::Result<()> {
        let reads = self.reads.as_ref().ok_or_else(invalid)?;
        for pin in self.writable_pins.as_ref().ok_or_else(invalid)? {
            add(&reads.ruleset, pin, READ_FILE)?;
        }
        if self.private_proc {
            let proc = open(c"/proc", true)?;
            let mut fs: libc::statfs = unsafe { std::mem::zeroed() };
            check(unsafe { libc::fstatfs(proc.as_raw_fd(), &mut fs) })?;
            let mut name = [0u8; 32];
            let size = unsafe {
                libc::readlinkat(
                    proc.as_raw_fd(),
                    c"self".as_ptr(),
                    name.as_mut_ptr().cast(),
                    name.len(),
                )
            };
            if size < 1 || size as usize >= name.len() || fs.f_type != libc::PROC_SUPER_MAGIC {
                return Err(invalid());
            }
            let pid = name[..size as usize].iter().try_fold(0u32, |pid, byte| {
                if !byte.is_ascii_digit() {
                    return None;
                }
                pid.checked_mul(10)?.checked_add((byte - b'0') as u32)
            });
            if pid != Some(std::process::id()) {
                return Err(invalid());
            }
            add(&reads.ruleset, &proc, READ_FILE)?;
        } else {
            // Component tests pin their own files without claiming a private
            // namespace. Production explicitly selects its fresh proc view.
            for path in [
                c"/proc/self/cgroup",
                c"/proc/self/status",
                c"/proc/self/maps",
            ] {
                reads.add_file(path)?;
            }
        }
        for (path, minor) in [
            (c"/dev/null", 3),
            (c"/dev/zero", 5),
            (c"/dev/full", 7),
            (c"/dev/random", 8),
            (c"/dev/urandom", 9),
        ] {
            add(&reads.ruleset, &device(path, minor)?, READ_FILE)?;
        }
        self.enter_trusted()?;
        check(unsafe {
            libc::syscall(
                libc::SYS_landlock_restrict_self,
                reads.ruleset.as_raw_fd(),
                0u32,
            ) as i32
        })?;
        READ_SCOPE_PID.with(|pid| pid.set(std::process::id()));
        Ok(())
    }

    /// Fixed installed manager startup only: it must discover/capture its read
    /// scope and call enter() before caller Git. This preserves safe trusted
    /// configuration discovery without allocating inside root pre_exec or
    /// granting every special file in a live host subtree to arbitrary helpers.
    fn enter_trusted(&self) -> io::Result<()> {
        let ruleset = create(FS_RIGHTS & !READ_FILE)?;
        rule(&ruleset, c"/", READ, true)?;
        if let Some(pins) = &self.writable_pins {
            for pin in pins {
                add(&ruleset, pin, WRITE)?;
            }
        } else {
            for path in &self.writable {
                rule(&ruleset, path, WRITE, true)?;
            }
        }
        // Shell redirection uses O_TRUNC even on /dev/null.
        add(&ruleset, &device(c"/dev/null", 3)?, WRITE_FILE | TRUNCATE)?;
        enforce(&ruleset)
    }
}

fn device(path: &std::ffi::CStr, minor: u32) -> io::Result<OwnedFd> {
    let pin = open(path, false)?;
    let mut status: libc::stat = unsafe { std::mem::zeroed() };
    check(unsafe { libc::fstat(pin.as_raw_fd(), &mut status) })?;
    if status.st_mode & libc::S_IFMT != libc::S_IFCHR
        || status.st_uid != 0
        || status.st_rdev != libc::makedev(1, minor)
    {
        return Err(invalid());
    }
    Ok(pin)
}

/// Initial checkout envelope, before the trusted manager creates fresh runtime
/// children. It MUST subsequently call Policy::enter before the first Git helper.
/// REFER is explicitly handled/granted: Landlock otherwise denies it implicitly,
/// and a later more restrictive domain could not restore ordinary Git renames.
pub fn restrict_ipc() -> io::Result<()> {
    let ruleset = create(RESOLVE_UNIX | REFER)?;
    rule(&ruleset, c"/", REFER, true)?;
    enforce(&ruleset)
}

fn create(filesystem: u64) -> io::Result<OwnedFd> {
    // These architectures share the generic Landlock syscall ABI.
    architecture()?;
    let abi = unsafe { libc::syscall(libc::SYS_landlock_create_ruleset, 0usize, 0usize, 1u32) };
    if abi < 0 {
        return Err(io::Error::last_os_error());
    }
    if abi < MIN_ABI {
        return Err(io::Error::from_raw_os_error(libc::EOPNOTSUPP));
    }
    let attributes = Ruleset {
        filesystem,
        network: 0,
        scoped: SCOPES,
    };
    fd(unsafe {
        libc::syscall(
            libc::SYS_landlock_create_ruleset,
            &attributes,
            std::mem::size_of::<Ruleset>(),
            0u32,
        )
    })
}

fn open(path: &std::ffi::CStr, directory: bool) -> io::Result<OwnedFd> {
    fd(unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_PATH
                | libc::O_NOFOLLOW
                | libc::O_CLOEXEC
                | if directory { libc::O_DIRECTORY } else { 0 },
        ) as libc::c_long
    })
}

fn rule(ruleset: &OwnedFd, path: &std::ffi::CStr, access: u64, directory: bool) -> io::Result<()> {
    add(ruleset, &open(path, directory)?, access)
}

fn add(ruleset: &OwnedFd, parent: &impl AsRawFd, access: u64) -> io::Result<()> {
    let rule = PathRule {
        access,
        parent: parent.as_raw_fd(),
    };
    check(unsafe {
        libc::syscall(
            libc::SYS_landlock_add_rule,
            ruleset.as_raw_fd(),
            1u32, // LANDLOCK_RULE_PATH_BENEATH
            &rule,
            0u32,
        ) as i32
    })
}

fn enforce(ruleset: &OwnedFd) -> io::Result<()> {
    super::restrict_privileges()?;
    check(unsafe {
        libc::syscall(libc::SYS_landlock_restrict_self, ruleset.as_raw_fd(), 0u32) as i32
    })?;
    restrict_sockets()
}

fn architecture() -> io::Result<u32> {
    #[cfg(target_arch = "x86_64")]
    let architecture = Some(0xc000_003e);
    #[cfg(target_arch = "aarch64")]
    let architecture = Some(0xc000_00b7);
    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    let architecture: Option<u32> = None;
    architecture.ok_or_else(|| io::Error::from_raw_os_error(libc::EOPNOTSUPP))
}

fn restrict_sockets() -> io::Result<()> {
    let statement = |code: u32, k: u32| libc::sock_filter {
        code: code as u16,
        jt: 0,
        jf: 0,
        k,
    };
    let jump = |code: u32, k: u32, jt: u8| libc::sock_filter {
        code: code as u16,
        jt,
        jf: 0,
        k,
    };
    let deny = libc::SECCOMP_RET_ERRNO | libc::EPERM as u32;
    let filter = [
        statement(libc::BPF_LD | libc::BPF_W | libc::BPF_ABS, 4),
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            architecture()?,
            1,
        ),
        statement(libc::BPF_RET | libc::BPF_K, deny),
        statement(libc::BPF_LD | libc::BPF_W | libc::BPF_ABS, 0),
        // Foreign ABI/socketcall and x32 cannot bypass native syscall checks.
        jump(
            libc::BPF_JMP | libc::BPF_JSET | libc::BPF_K,
            0x4000_0000,
            17,
        ),
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::SYS_io_uring_setup as u32,
            16,
        ),
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::SYS_io_uring_enter as u32,
            15,
        ),
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::SYS_io_uring_register as u32,
            14,
        ),
        // No outside descriptor theft, process mutation or host keyring channel.
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::SYS_ptrace as u32,
            13,
        ),
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::SYS_process_vm_readv as u32,
            12,
        ),
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::SYS_process_vm_writev as u32,
            11,
        ),
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::SYS_pidfd_getfd as u32,
            10,
        ),
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::SYS_add_key as u32,
            9,
        ),
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::SYS_request_key as u32,
            8,
        ),
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::SYS_keyctl as u32,
            7,
        ),
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::SYS_socket as u32,
            2,
        ),
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::SYS_socketpair as u32,
            1,
        ),
        statement(libc::BPF_RET | libc::BPF_K, libc::SECCOMP_RET_ALLOW),
        statement(libc::BPF_LD | libc::BPF_W | libc::BPF_ABS, 16), // args[0]: family
        jump(
            libc::BPF_JMP | libc::BPF_JEQ | libc::BPF_K,
            libc::AF_UNIX as u32,
            1,
        ),
        statement(libc::BPF_RET | libc::BPF_K, deny),
        statement(libc::BPF_RET | libc::BPF_K, libc::SECCOMP_RET_ALLOW),
        statement(libc::BPF_RET | libc::BPF_K, deny),
    ];
    let program = libc::sock_fprog {
        len: filter.len() as u16,
        filter: filter.as_ptr().cast_mut(),
    };
    let result = unsafe {
        libc::syscall(
            libc::SYS_seccomp,
            libc::SECCOMP_SET_MODE_FILTER,
            libc::SECCOMP_FILTER_FLAG_TSYNC,
            &program,
        )
    };
    if result < 0 {
        return Err(io::Error::last_os_error());
    }
    if result != 0 {
        return Err(io::Error::from_raw_os_error(libc::EBUSY));
    }
    Ok(())
}

#[repr(C)]
struct MountAttributes {
    set: u64,
    clear: u64,
    propagation: u64,
    userns: u64,
}

/// Root-prepared private scratch, inside the existing registered source slot.
/// Detached clones cross namespace entry without reopening a host writable path.
/// No cleanup/replay: settlement/retirement remain the original owner's job.
pub struct CaptureView {
    pub(super) uid: u32,
    scratch: [OwnedFd; 3],
    policy: Policy,
}

impl CaptureView {
    pub fn prepare(directory: &File) -> io::Result<Self> {
        if unsafe { libc::geteuid() } != 0 {
            return Err(io::Error::from_raw_os_error(libc::EPERM));
        }
        let metadata = directory.metadata()?;
        if !metadata.is_dir() || metadata.uid() == 0 || metadata.mode() & 0o7777 != 0o700 {
            return Err(invalid());
        }
        let child = |name: &std::ffi::CStr| -> io::Result<OwnedFd> {
            check(unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) })?;
            let pin = fd(unsafe {
                libc::openat(
                    directory.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                ) as libc::c_long
            })?;
            check(unsafe { libc::fchown(pin.as_raw_fd(), metadata.uid(), metadata.gid()) })?;
            check(unsafe { libc::fsync(pin.as_raw_fd()) })?;
            clone_mount(pin.as_raw_fd())
        };
        let var_tmp = child(c"var-tmp")?;
        let shm = child(c"shm")?;
        directory.sync_all()?;
        Ok(Self {
            uid: metadata.uid(),
            scratch: [clone_mount(directory.as_raw_fd())?, var_tmp, shm],
            policy: Policy::startup(&[
                Path::new("/tmp"),
                Path::new("/var/tmp"),
                Path::new("/dev/shm"),
            ])?,
        })
    }

    /// Source/profile names beneath these targets would be hidden. Reject before
    /// entry, never silently capture a different repository or default profile.
    pub fn preserves(&self, paths: &[std::path::PathBuf]) -> bool {
        paths.iter().all(|path| {
            ["/tmp", "/var/tmp", "/dev/shm"]
                .iter()
                .all(|scratch| !path.starts_with(scratch) && !Path::new(scratch).starts_with(path))
        })
    }

    pub(super) fn enter(&self) -> io::Result<()> {
        check(unsafe {
            libc::unshare(
                libc::CLONE_NEWNS | libc::CLONE_NEWPID | libc::CLONE_NEWIPC | libc::CLONE_NEWNET,
            )
        })?;
        super::namespace_child()?;
        check(unsafe {
            libc::mount(
                std::ptr::null(),
                c"/".as_ptr(),
                std::ptr::null(),
                libc::MS_REC | libc::MS_PRIVATE,
                std::ptr::null(),
            )
        })?;
        check(unsafe {
            libc::mount(
                c"proc".as_ptr(),
                c"/proc".as_ptr(),
                c"proc".as_ptr(),
                libc::MS_RDONLY | libc::MS_NOSUID | libc::MS_NODEV | libc::MS_NOEXEC,
                std::ptr::null(),
            )
        })?;
        // No /proc/<host-pid>/root alias can recover the old writable mounts.
        attributes(libc::AT_FDCWD, c"/", AT_RECURSIVE, READONLY | NOSUID)?;
        for (mount, target) in self.scratch.iter().zip([c"/tmp", c"/var/tmp", c"/dev/shm"]) {
            check(unsafe {
                libc::syscall(
                    libc::SYS_move_mount,
                    mount.as_raw_fd(),
                    c"".as_ptr(),
                    libc::AT_FDCWD,
                    target.as_ptr(),
                    4u32,
                ) as i32
            })?;
        }
        check(unsafe { libc::chdir(c"/var/empty".as_ptr()) })
    }

    pub(super) fn restrict(&self) -> io::Result<()> {
        self.policy.enter_trusted()
    }
}

fn clone_mount(pin: i32) -> io::Result<OwnedFd> {
    let tree = fd(unsafe {
        libc::syscall(
            libc::SYS_open_tree,
            pin,
            c"".as_ptr(),
            1u32 | libc::O_CLOEXEC as u32 | libc::AT_EMPTY_PATH as u32 | AT_RECURSIVE,
        )
    })?;
    attributes(
        tree.as_raw_fd(),
        c"",
        libc::AT_EMPTY_PATH as u32 | AT_RECURSIVE,
        NOSUID | NODEV,
    )?;
    Ok(tree)
}

fn attributes(dirfd: i32, path: &std::ffi::CStr, flags: u32, set: u64) -> io::Result<()> {
    let attributes = MountAttributes {
        set,
        clear: 0,
        propagation: 0,
        userns: 0,
    };
    check(unsafe {
        libc::syscall(
            libc::SYS_mount_setattr,
            dirfd,
            path.as_ptr(),
            flags,
            &attributes,
            std::mem::size_of::<MountAttributes>(),
        ) as i32
    })
}

fn fd(value: libc::c_long) -> io::Result<OwnedFd> {
    if value < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(unsafe { OwnedFd::from_raw_fd(value as i32) })
    }
}

fn check(value: i32) -> io::Result<()> {
    if value == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn invalid() -> io::Error {
    io::Error::from_raw_os_error(libc::EINVAL)
}

#[cfg(test)]
mod tests;
