use super::*;

#[test]
fn stat_binding_preserves_comm_parentheses_and_rejects_missing_or_foreign_identity() {
    let fields = std::iter::repeat_n("0", 18).collect::<Vec<_>>().join(" ");
    let value = format!("123 (native (listener)) S {fields} 456 0\n");
    assert_eq!(start_ticks(123, &value).unwrap(), 456);
    assert!(start_ticks(124, &value).is_err());
    assert!(start_ticks(123, "123 (native) S 0\n").is_err());
    assert!(start_ticks(123, &value.replace("456", "0")).is_err());
}

#[test]
fn upstream_classic_and_delegated_listener_locations_never_adopt_another_subtree() {
    for location in ["producer", "producer/nix-daemon"] {
        let value = format!("0::{}/nix-daemon.service/{location}\n", workload::RELATIVE);
        assert_eq!(producer_location(&value).unwrap(), location);
    }
    for location in [
        "listener",
        "producer/other",
        "producer/nix-daemon/child",
        "producer/../listener",
    ] {
        let value = format!("0::{}/nix-daemon.service/{location}\n", workload::RELATIVE);
        assert!(producer_location(&value).is_err());
    }
    assert!(producer_location("0::/other/producer\n").is_err());
    assert!(
        producer_location(&format!(
            "0::{}/nix-daemon.service/producer",
            workload::RELATIVE
        ))
        .is_err()
    );
}

#[test]
fn runtime_and_positive_writer_receipt_fit_the_existing_phase_reservation() {
    let id = |inode| FileId {
        device: u64::MAX,
        inode,
    };
    let runtime = Runtime {
        unit: id(u64::MAX),
        producer: id(u64::MAX - 1),
        listener: id(u64::MAX - 2),
        socket: id(u64::MAX - 4),
        process: Process {
            pid: i32::MAX as u32,
            start_ticks: u64::MAX,
        },
    };
    runtime.validate().unwrap();
    let phase = NativePhase {
        file: Some(id(u64::MAX - 3)),
        runtime: Some(runtime.clone()),
        sealed_at: Some(u64::MAX),
        writers_settled_at: Some(u64::MAX),
        retired: false,
    };
    assert!(serde_json::to_vec(&phase).unwrap().len() <= 512);
    let mut changed = runtime;
    changed.listener = changed.producer.clone();
    assert!(changed.validate().is_err());
    changed.listener.inode = 0;
    assert!(changed.validate().is_err());
}

#[test]
fn native_pidfd_binding_vetoes_changed_start_time() {
    let pid = std::process::id();
    let ticks = start_ticks(pid, &bounded_proc(pid, "stat").unwrap()).unwrap();
    let process = LiveProcess::open(Process {
        pid,
        start_ticks: ticks,
    })
    .unwrap();
    process.alive().unwrap();
    assert!(
        LiveProcess::open(Process {
            pid,
            start_ticks: ticks + 1
        })
        .is_err()
    );
}

#[test]
fn pidfd_child() {
    if std::env::var_os("ABIRD_NATIVE_PHASE_CHILD").is_none() {
        return;
    }
    use std::io::Write;
    println!("NATIVE_PHASE_CHILD_READY");
    std::io::stdout().flush().unwrap();
    let mut byte = [0];
    assert_eq!(std::io::stdin().read(&mut byte).unwrap(), 0);
}

#[test]
fn listener_exit_is_not_an_empty_producer_receipt() {
    use std::process::{Command, Stdio};
    struct Child(std::process::Child);
    impl Drop for Child {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.try_wait();
        }
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut child = Child(
        Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "build_executor::native_phase::tests::pidfd_child",
                "--nocapture",
            ])
            .env_clear()
            .env("ABIRD_NATIVE_PHASE_CHILD", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let mut output = child.0.stdout.take().unwrap();
    let fd = output.as_raw_fd();
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    assert!(flags >= 0);
    assert_eq!(
        unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) },
        0
    );
    let mut bytes = Vec::new();
    while !bytes
        .windows(b"NATIVE_PHASE_CHILD_READY".len())
        .any(|part| part == b"NATIVE_PHASE_CHILD_READY")
    {
        assert!(Instant::now() < deadline && bytes.len() < 4096);
        let mut chunk = [0; 256];
        match output.read(&mut chunk) {
            Ok(0) => panic!("native process fixture exited before readiness"),
            Ok(count) => bytes.extend_from_slice(&chunk[..count]),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
                ) => {}
            Err(error) => panic!("native process fixture read: {error}"),
        }
        std::thread::park_timeout(Duration::from_millis(2));
    }
    let pid = child.0.id();
    let process = LiveProcess::open(Process {
        pid,
        start_ticks: start_ticks(pid, &bounded_proc(pid, "stat").unwrap()).unwrap(),
    })
    .unwrap();
    process.alive().unwrap();
    drop(child.0.stdin.take());
    loop {
        assert!(Instant::now() < deadline);
        if let Some(exit) = child.0.try_wait().unwrap() {
            assert!(exit.success());
            break;
        }
        std::thread::park_timeout(Duration::from_millis(2));
    }
    assert!(process.alive().is_err());
}
