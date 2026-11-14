//! Explicit privileged qualification: the actual production capture entry,
//! without a synthetic cgroup/admission receipt. Main runs this in the VM.

use super::*;
use crate::build_executor::process::{ChildScope, Limits, Runner, child_scope_entry};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

#[test]
#[ignore = "requires root CAP_SYS_ADMIN; explicitly run in installed VM, never count as qualification when ignored"]
fn production_capture_entry_drops_inherited_authority_and_hides_host_proc() {
    assert_eq!(
        unsafe { libc::geteuid() },
        0,
        "privileged qualification requires root"
    );
    let root = tempfile::Builder::new()
        .prefix("owned-entry-")
        .tempdir()
        .unwrap()
        .keep();
    let scratch = root.join("scratch");
    fs::create_dir(&scratch).unwrap();
    let directory = File::open(&scratch).unwrap();
    assert_eq!(
        unsafe { libc::fchown(directory.as_raw_fd(), 1000, 1000) },
        0
    );
    fs::set_permissions(&scratch, fs::Permissions::from_mode(0o700)).unwrap();
    let scope = ChildScope::Capture(CaptureView::prepare(&directory).unwrap());
    let mut strict = Policy::new(&[
        Path::new("/tmp"),
        Path::new("/var/tmp"),
        Path::new("/dev/shm"),
    ])
    .unwrap()
    .with_private_proc()
    .with_read_scope(read_scope(&runtime_reads()))
    .unwrap();
    let sentinel = root.join("sentinel");
    fs::write(&sentinel, b"unchanged").unwrap();
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(&sentinel)
        .unwrap();
    let file =
        fd(unsafe { libc::fcntl(file.as_raw_fd(), libc::F_DUPFD, 200) } as libc::c_long).unwrap();
    let (socket, mut peer) = UnixStream::pair().unwrap();
    let socket =
        fd(unsafe { libc::fcntl(socket.as_raw_fd(), libc::F_DUPFD, 201) } as libc::c_long).unwrap();
    peer.set_nonblocking(true).unwrap();
    for descriptor in [&file, &socket] {
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
            file.as_raw_fd(),
            0,
        )
    };
    assert_ne!(mapping, libc::MAP_FAILED);
    // The original test executable may live under /tmp, which the real entry
    // replaces. Pin only its ELF for exec; the entry must close even this FD on
    // success, just like every unrelated inherited descriptor.
    let executable = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_PATH | libc::O_CLOEXEC)
        .open(std::env::current_exe().unwrap())
        .unwrap();
    let mut command = Command::new(format!("/proc/self/fd/{}", executable.as_raw_fd()));
    command
        .args([
            "--exact",
            "build_executor::process::offline::tests::namespace::namespace_child",
            "--nocapture",
        ])
        .env_clear()
        .env("OB_ENTRY_PARENT", std::process::id().to_string())
        .env("OB_ENTRY_FILE", file.as_raw_fd().to_string())
        .env("OB_ENTRY_SOCKET", socket.as_raw_fd().to_string())
        .env("OB_ENTRY_SENTINEL", &sentinel)
        .env(
            "OB_ENTRY_PID_NS",
            fs::read_link("/proc/self/ns/pid").unwrap(),
        )
        .env(
            "OB_ENTRY_NET_NS",
            fs::read_link("/proc/self/ns/net").unwrap(),
        );
    unsafe {
        command.pre_exec(move || {
            // Exactly Runner's production entry after producer placement. No
            // fake namespace/FD code in the fixture. Production prepares its
            // Policy inside the fixed manager after exec. Here the immutable
            // ELF inventory was prepared in the parent; repin the three fresh
            // scratch directories after real entry, without allocating in this
            // multithreaded test harness's pre_exec child.
            child_scope_entry(&scope, 1000, 1000, &[])?;
            for (pin, path) in strict
                .writable_pins
                .as_mut()
                .unwrap()
                .iter_mut()
                .zip(&strict.writable)
            {
                *pin = open(path, true)?;
            }
            strict.enter()
        });
    }
    let mut runner = Runner::new(
        1000,
        Limits {
            stdin: 1,
            stdout: 65536,
            stderr: 65536,
        },
        Instant::now() + Duration::from_secs(20),
    )
    .unwrap();
    let output = runner.execute(&mut command, &[]).unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("OFFLINE_PRODUCTION_ENTRY=ok"));
    assert_eq!(fs::read(&sentinel).unwrap(), b"unchanged");
    assert_eq!(fs::read(scratch.join("positive")).unwrap(), b"private");
    assert_eq!(
        peer.read(&mut [0]).unwrap_err().kind(),
        io::ErrorKind::WouldBlock
    );
    assert_eq!(
        unsafe { std::ptr::read_volatile(mapping.cast::<u8>()) },
        b'u'
    );
    assert_eq!(unsafe { libc::munmap(mapping, 4096) }, 0);
    // Parent still owns its original capabilities/namespace; only fixture data
    // is removed, by exact names, after child exit. No recursive cleanup.
    assert_eq!(
        unsafe { libc::write(file.as_raw_fd(), b"u".as_ptr().cast(), 1) },
        1
    );
    drop(command);
    fs::remove_file(scratch.join("positive")).unwrap();
    fs::remove_file(&sentinel).unwrap();
    fs::remove_dir(scratch.join("var-tmp")).unwrap();
    fs::remove_dir(scratch.join("shm")).unwrap();
    fs::remove_dir(&scratch).unwrap();
    fs::remove_dir(&root).unwrap();
}

#[test]
fn namespace_child() {
    let Ok(parent) = std::env::var("OB_ENTRY_PARENT") else {
        return;
    };
    assert_eq!(unsafe { libc::geteuid() }, 1000);
    assert_eq!(std::process::id(), 1);
    for (name, key) in [("pid", "OB_ENTRY_PID_NS"), ("net", "OB_ENTRY_NET_NS")] {
        assert_ne!(
            fs::read_link(format!("/proc/self/ns/{name}")).unwrap(),
            std::path::PathBuf::from(std::env::var_os(key).unwrap())
        );
    }
    assert!(!Path::new(&format!("/proc/{parent}")).exists());
    assert_eq!(
        unsafe { libc::kill(parent.parse().unwrap(), libc::SIGCONT) },
        -1
    );
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    for key in ["OB_ENTRY_FILE", "OB_ENTRY_SOCKET"] {
        let descriptor: i32 = std::env::var(key).unwrap().parse().unwrap();
        assert_eq!(unsafe { libc::fcntl(descriptor, libc::F_GETFD) }, -1);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EBADF));
        assert!(!Path::new(&format!("/proc/{parent}/fd/{descriptor}")).exists());
    }
    let sentinel = std::env::var("OB_ENTRY_SENTINEL").unwrap();
    assert!(
        !fs::read_to_string("/proc/self/maps")
            .unwrap()
            .lines()
            .any(|line| line.ends_with(&sentinel))
    );
    assert!(
        OpenOptions::new()
            .write(true)
            .open(format!("/proc/{parent}/root{sentinel}"))
            .is_err()
    );
    assert_eq!(
        unsafe { libc::syscall(libc::SYS_pidfd_getfd, -1, 200, 0) },
        -1
    );
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EPERM));
    // A descendant needs its own proc inode, not the namespace init's pinned
    // /proc/self/cgroup. The granted directory is this fresh private proc view.
    assert!(
        Command::new("/bin/sh")
            .args(["-c", "read -r cg < /proc/self/cgroup; test -n \"$cg\""])
            .status()
            .unwrap()
            .success()
    );
    fs::write("/tmp/positive", b"private").unwrap();
    println!("OFFLINE_PRODUCTION_ENTRY=ok");
}
