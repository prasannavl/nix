use super::*;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::linux::net::SocketAddrExt;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{SocketAddr, UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::process::Command;
use std::time::{Duration, Instant};

mod namespace;

#[test]
fn missing_read_scope_is_not_an_ambient_file_read_fallback() {
    assert_eq!(
        Policy::new(&[])
            .unwrap()
            .enter()
            .unwrap_err()
            .raw_os_error(),
        Some(libc::EINVAL)
    );
    assert!(require_read_scope().is_err());
    assert!(
        ReadScope::capture(&[], read_limits(), Instant::now() + Duration::from_secs(1)).is_err()
    );
    for root in ["/", "/nix/store", "/proc", "/dev", "/sys"] {
        assert!(
            ReadScope::capture(
                &[Path::new(root)],
                read_limits(),
                Instant::now() + Duration::from_secs(1)
            )
            .is_err()
        );
    }
}

#[test]
fn scope_success_marker_does_not_authorize_a_sibling_thread() {
    // Guard bookkeeping only; this does not pretend to install kernel policy.
    READ_SCOPE_PID.with(|pid| pid.set(std::process::id()));
    let sibling = std::thread::spawn(|| require_read_scope().is_err()).join();
    READ_SCOPE_PID.with(|pid| pid.set(0));
    assert!(sibling.unwrap());
}

fn denied<T: std::fmt::Debug>(result: io::Result<T>) {
    let error = result.unwrap_err();
    assert!(
        matches!(error.raw_os_error(), Some(libc::EACCES | libc::EPERM)),
        "expected kernel denial, got {error}"
    );
}

fn abstract_address(name: &str) -> SocketAddr {
    SocketAddr::from_abstract_name(name.as_bytes()).unwrap()
}

fn read_limits() -> crate::build_executor::private_tree::Limits {
    crate::build_executor::private_tree::Limits {
        entries: 32768,
        bytes: 16 * 1024 * 1024,
        depth: 64,
    }
}

// Test fixture's exact ELF runtime, not a product fallback or host-store scan.
fn runtime_reads() -> Vec<std::path::PathBuf> {
    let mut roots = vec![
        std::env::current_exe().unwrap(),
        fs::canonicalize("/bin/sh").unwrap(),
    ];
    for executable in roots.clone() {
        let output = Command::new("ldd").arg(executable).output().unwrap();
        assert!(output.status.success(), "fixture requires native ldd");
        for path in String::from_utf8(output.stdout)
            .unwrap()
            .split_whitespace()
            .filter(|word| word.starts_with('/'))
        {
            roots.push(fs::canonicalize(path).unwrap());
        }
    }
    roots.sort();
    roots.dedup();
    roots
}

fn read_scope(roots: &[std::path::PathBuf]) -> ReadScope {
    ReadScope::capture(
        &roots.iter().map(|path| path.as_path()).collect::<Vec<_>>(),
        read_limits(),
        Instant::now() + Duration::from_secs(15),
    )
    .unwrap()
}

#[test]
fn offline_kernel_fork_exec_closes_external_effects_but_keeps_private_helpers() {
    // Keep failure evidence; cleanup below unlinks only exact fixture entries,
    // never recursively removes a computed directory (including on Drop).
    let root = tempfile::Builder::new()
        .prefix("owned-offline-")
        .tempdir()
        .unwrap()
        .keep();
    let private = root.join("private");
    fs::create_dir(&private).unwrap();
    fs::create_dir(private.join("branch")).unwrap();
    let nested_private = private.join("branch/leaf");
    fs::create_dir(&nested_private).unwrap();
    let outside = root.join("outside");
    fs::create_dir(&outside).unwrap();
    fs::create_dir(outside.join("leaf")).unwrap();
    let redirected_fifo = outside.join("leaf/fifo");
    let name = CString::new(redirected_fifo.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let mut redirected_control = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(&redirected_fifo)
        .unwrap();
    redirected_control.write_all(b"d").unwrap();
    let sentinel = root.join("sentinel");
    fs::write(&sentinel, b"unchanged").unwrap();
    let replaced = root.join("replaced");
    fs::write(&replaced, b"was-regular").unwrap();
    let fifo = root.join("outside.fifo");
    let fifo_name = CString::new(fifo.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo_name.as_ptr(), 0o600) }, 0);
    let mut fifo_control = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(&fifo)
        .unwrap();
    fifo_control.write_all(b"f").unwrap();
    let mut one = [0];
    fifo_control.read_exact(&mut one).unwrap();
    assert_eq!(one, *b"f");
    // Leave data queued throughout restricted execution: readonly mounts do not
    // stop a FIFO read from consuming a host writer's data.
    fifo_control.write_all(b"q").unwrap();
    // Reproduce the reviewed gap with the actual old read grant, even with all
    // filesystem writes denied and IPC/seccomp installed. Then requeue the same
    // byte for the corrected policy: this is not a drained-FIFO false positive.
    let mut old = Command::new(std::env::current_exe().unwrap());
    old.args([
        "--exact",
        "build_executor::process::offline::tests::old_read_rule_child",
        "--nocapture",
    ])
    .env_clear()
    .env("OB_OFFLINE_OLD_FIFO", &fifo);
    unsafe {
        old.pre_exec(|| {
            super::super::child_descriptor_policy(None)?;
            restrict_ipc()?;
            let old = create(FS_RIGHTS)?;
            rule(&old, c"/", READ | READ_FILE, true)?;
            enforce(&old)
        });
    }
    let mut control_runner = super::super::Runner::new(
        1000,
        super::super::Limits {
            stdin: 1,
            stdout: 65536,
            stderr: 65536,
        },
        Instant::now() + Duration::from_secs(15),
    )
    .unwrap();
    let control = control_runner.execute(&mut old, &[]).unwrap();
    assert!(
        control.status.success(),
        "{}",
        String::from_utf8_lossy(&control.stderr)
    );
    assert!(String::from_utf8_lossy(&control.stdout).contains("OLD_READ_FILE_CONSUMED=q"));
    assert_eq!(
        fifo_control.read(&mut one).unwrap_err().kind(),
        io::ErrorKind::WouldBlock
    );
    fifo_control.write_all(b"q").unwrap();
    let pathname = root.join("outside.sock");
    let external = UnixListener::bind(&pathname).unwrap();
    let name = root.file_name().unwrap().to_str().unwrap().to_owned();
    let address = abstract_address(&name);
    let abstract_listener = UnixListener::bind_addr(&address).unwrap();
    // Actual parent positive controls, not an assumed accessible endpoint.
    for (mut connected, listener) in [
        (UnixStream::connect(&pathname).unwrap(), &external),
        (
            UnixStream::connect_addr(&address).unwrap(),
            &abstract_listener,
        ),
    ] {
        connected.write_all(b"c").unwrap();
        let (mut accepted, _) = listener.accept().unwrap();
        accepted.read_exact(&mut one).unwrap();
        assert_eq!(one, *b"c");
        listener.set_nonblocking(true).unwrap();
    }
    for family in [libc::AF_INET, libc::AF_INET6] {
        let socket = fd(
            unsafe { libc::socket(family, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) }
                as libc::c_long,
        )
        .unwrap();
        drop(socket);
    }
    assert_eq!(unsafe { libc::kill(libc::getpid(), libc::SIGCONT) }, 0);
    let before = fs::read_to_string("/proc/thread-self/status").unwrap();
    // Intentionally non-CLOEXEC capabilities and MAP_SHARED authority existed
    // before entry. The production FD function + exec must remove them, not
    // merely constrain new open()/socket() calls.
    let (inherited, mut outside_peer) = UnixStream::pair().unwrap();
    outside_peer.set_nonblocking(true).unwrap();
    let inherited =
        fd(unsafe { libc::fcntl(inherited.as_raw_fd(), libc::F_DUPFD, 200) } as libc::c_long)
            .unwrap();
    let outside_file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(&sentinel)
        .unwrap();
    let outside_file =
        fd(unsafe { libc::fcntl(outside_file.as_raw_fd(), libc::F_DUPFD, 201) } as libc::c_long)
            .unwrap();
    for descriptor in [&inherited, &outside_file] {
        assert_eq!(
            unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC,
            0
        );
    }
    let mapping = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            4096,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            outside_file.as_raw_fd(),
            0,
        )
    };
    assert_ne!(mapping, libc::MAP_FAILED);
    unsafe {
        std::ptr::write_volatile(mapping.cast::<u8>(), b'u');
    }
    assert_eq!(unsafe { libc::msync(mapping, 4096, libc::MS_SYNC) }, 0);
    let mut reads = runtime_reads();
    reads.push(root.clone());
    let cached = Policy::new(&[&private, &nested_private])
        .unwrap()
        .with_read_scope(read_scope(&reads))
        .unwrap();
    // An earlier helper could redirect a mutable ancestor within private tmp.
    // Reused policies must retain their original private inodes, not resolve a
    // new live host directory and accidentally grant all its FIFO reads.
    fs::rename(private.join("branch"), private.join("saved-branch")).unwrap();
    std::os::unix::fs::symlink(&outside, private.join("branch")).unwrap();
    let policy = cached.try_clone().unwrap();
    fs::remove_file(&replaced).unwrap();
    let name_c = CString::new(replaced.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name_c.as_ptr(), 0o600) }, 0);
    let mut replaced_control = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(&replaced)
        .unwrap();
    replaced_control.write_all(b"r").unwrap();
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--exact",
            "build_executor::process::offline::tests::kernel_child",
            "--nocapture",
        ])
        .env_clear()
        .env("OB_OFFLINE_ROOT", &root)
        .env("OB_OFFLINE_ABSTRACT", &name)
        .env("OB_OFFLINE_PARENT", std::process::id().to_string())
        .env("OB_OFFLINE_SOCKET_FD", inherited.as_raw_fd().to_string())
        .env("OB_OFFLINE_FILE_FD", outside_file.as_raw_fd().to_string());
    unsafe {
        command.pre_exec(move || {
            // Same production inheritance hygiene, then two-stage tightening as
            // checkout uses. The second domain must not lose REFER permissions.
            super::super::child_descriptor_policy(None)?;
            restrict_ipc()?;
            policy.enter()
        });
    }
    let mut runner = super::super::Runner::new(
        1000,
        super::super::Limits {
            stdin: 1,
            stdout: 64 * 1024,
            stderr: 64 * 1024,
        },
        Instant::now() + Duration::from_secs(15),
    )
    .unwrap();
    // execute is the existing component-test seam, not an installed placement
    // exemption. Command spawns/execs a genuinely kernel-restricted child.
    let output = runner.execute(&mut command, &[]).unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("OFFLINE_KERNEL_PROBE=ok"));
    assert_eq!(fs::read(&sentinel).unwrap(), b"unchanged");
    assert_eq!(fs::read(private.join("positive")).unwrap(), b"private");
    for listener in [&external, &abstract_listener] {
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
    }
    fifo_control.read_exact(&mut one).unwrap();
    assert_eq!(one, *b"q", "restricted read consumed the host FIFO byte");
    redirected_control.read_exact(&mut one).unwrap();
    assert_eq!(
        one, *b"d",
        "redirected writable path granted a host FIFO read"
    );
    replaced_control.read_exact(&mut one).unwrap();
    assert_eq!(
        one, *b"r",
        "pathname replacement inherited a regular-file grant"
    );
    assert_eq!(
        fifo_control.read(&mut one).unwrap_err().kind(),
        io::ErrorKind::WouldBlock
    );
    assert_eq!(
        outside_peer.read(&mut one).unwrap_err().kind(),
        io::ErrorKind::WouldBlock
    );
    assert_eq!(
        unsafe { std::ptr::read_volatile(mapping.cast::<u8>()) },
        b'u'
    );
    assert_eq!(unsafe { libc::munmap(mapping, 4096) }, 0);
    let after = fs::read_to_string("/proc/thread-self/status").unwrap();
    for key in ["NoNewPrivs:", "Seccomp:", "Seccomp_filters:"] {
        assert_eq!(
            before.lines().find(|line| line.starts_with(key)),
            after.lines().find(|line| line.starts_with(key))
        );
    }
    // Parent remains unrestricted after the child: policy is not installed in
    // the controller, and retained parent listener descriptors still function.
    fs::write(&sentinel, b"parent-control").unwrap();
    UnixStream::connect(&pathname).unwrap();
    external.accept().unwrap();
    drop((
        external,
        abstract_listener,
        fifo_control,
        replaced_control,
        redirected_control,
    ));
    for file in [
        &redirected_fifo,
        &private.join("branch"),
        &sentinel,
        &fifo,
        &replaced,
        &pathname,
        &private.join("positive"),
        &private.join("shell-helper"),
    ] {
        fs::remove_file(file).unwrap();
    }
    fs::remove_dir(private.join("to")).unwrap();
    fs::remove_dir(private.join("from")).unwrap();
    fs::remove_dir(private.join("saved-branch/leaf")).unwrap();
    fs::remove_dir(private.join("saved-branch")).unwrap();
    fs::remove_dir(outside.join("leaf")).unwrap();
    fs::remove_dir(&outside).unwrap();
    fs::remove_dir(&private).unwrap();
    fs::remove_dir(&root).unwrap();
}

#[test]
fn old_read_rule_child() {
    let Some(fifo) = std::env::var_os("OB_OFFLINE_OLD_FIFO") else {
        return;
    };
    let mut byte = [0];
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(fifo)
        .unwrap()
        .read_exact(&mut byte)
        .unwrap();
    assert_eq!(byte, *b"q");
    println!("OLD_READ_FILE_CONSUMED=q");
}

#[test]
fn kernel_child() {
    let Some(root) = std::env::var_os("OB_OFFLINE_ROOT") else {
        return;
    };
    let root = std::path::PathBuf::from(root);
    let private = root.join("private");
    let sentinel = root.join("sentinel");
    assert_eq!(fs::read(&sentinel).unwrap(), b"unchanged");
    for key in ["OB_OFFLINE_SOCKET_FD", "OB_OFFLINE_FILE_FD"] {
        let descriptor: i32 = std::env::var(key).unwrap().parse().unwrap();
        assert_eq!(unsafe { libc::fcntl(descriptor, libc::F_GETFD) }, -1);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EBADF));
    }
    let maps = fs::read_to_string("/proc/self/maps").unwrap();
    assert!(
        !maps
            .lines()
            .any(|line| line.ends_with(sentinel.to_str().unwrap())),
        "outside writable mmap survived exec"
    );
    let readonly = File::open(&sentinel).unwrap();
    assert_eq!(
        unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                4096,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                readonly.as_raw_fd(),
                0,
            )
        },
        libc::MAP_FAILED
    );
    assert_eq!(
        io::Error::last_os_error().raw_os_error(),
        Some(libc::EACCES)
    );
    denied(OpenOptions::new().write(true).open(&sentinel));
    denied(fs::write(&sentinel, b"escaped"));
    denied(fs::remove_file(&sentinel));
    denied(fs::rename(&sentinel, private.join("stolen")));
    denied(
        OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(root.join("outside.fifo")),
    );
    for path in ["outside.fifo", "replaced", "private/branch/leaf/fifo"] {
        denied(
            OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NONBLOCK)
                .open(root.join(path)),
        );
    }
    denied(UnixStream::connect(root.join("outside.sock")));
    let outside = std::env::var("OB_OFFLINE_ABSTRACT").unwrap();
    denied(UnixStream::connect_addr(&abstract_address(&outside)));
    for family in [libc::AF_INET, libc::AF_INET6, libc::AF_NETLINK] {
        denied(fd(
            unsafe { libc::socket(family, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) }
                as libc::c_long,
        ));
    }
    assert_eq!(
        unsafe { libc::syscall(libc::SYS_io_uring_setup, 1u32, 0usize) },
        -1
    );
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EPERM));
    let parent: libc::pid_t = std::env::var("OB_OFFLINE_PARENT").unwrap().parse().unwrap();
    assert_eq!(unsafe { libc::kill(parent, libc::SIGCONT) }, -1);
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EPERM));
    assert_eq!(unsafe { libc::kill(libc::getpid(), libc::SIGCONT) }, 0);
    #[cfg(target_arch = "x86_64")]
    {
        assert_eq!(
            unsafe {
                libc::syscall(
                    libc::SYS_socket | 0x4000_0000,
                    libc::AF_UNIX,
                    libc::SOCK_STREAM,
                    0,
                )
            },
            -1
        );
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EPERM));
        // Actual compat ABI, not another native syscall number. Restore RBX;
        // int80's architecture check must reject even this AF_UNIX operation.
        let result: i32;
        unsafe {
            std::arch::asm!(
                "push rbx", "mov ebx, 1", "mov ecx, 1", "xor edx, edx", "int 0x80", "pop rbx",
                inlateout("eax") 359i32 => result,
                lateout("ecx") _, lateout("edx") _,
                lateout("r8") _, lateout("r9") _, lateout("r10") _, lateout("r11") _,
            );
        }
        assert_eq!(result, -libc::EPERM);
    }
    fs::create_dir(private.join("from")).unwrap();
    fs::create_dir(private.join("to")).unwrap();
    fs::write(private.join("from/file"), b"private").unwrap();
    fs::rename(private.join("from/file"), private.join("to/file")).unwrap();
    fs::rename(private.join("to/file"), private.join("positive")).unwrap();
    let (mut left, mut right) = UnixStream::pair().unwrap();
    left.write_all(b"p").unwrap();
    let mut one = [0];
    right.read_exact(&mut one).unwrap();
    assert_eq!(one, *b"p");
    // Ordinary helpers may create their own Unix servers inside the domain.
    let path = private.join("internal.sock");
    let internal = UnixListener::bind(&path).unwrap();
    UnixStream::connect(&path).unwrap();
    internal.accept().unwrap();
    drop(internal);
    fs::remove_file(path).unwrap();
    let address = abstract_address(&format!("{outside}-inside"));
    let internal = UnixListener::bind_addr(&address).unwrap();
    UnixStream::connect_addr(&address).unwrap();
    internal.accept().unwrap();
    let script = private.join("shell-helper");
    fs::write(
        &script,
        b"#!/bin/sh\nprintf sink > /dev/null\nprintf PRIVATE_SHELL_OK\n",
    )
    .unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
    assert!(Command::new(&script).status().unwrap().success());
    File::options()
        .write(true)
        .truncate(true)
        .open("/dev/null")
        .unwrap()
        .write_all(b"sink")
        .unwrap();
    println!("OFFLINE_KERNEL_PROBE=ok");
}
