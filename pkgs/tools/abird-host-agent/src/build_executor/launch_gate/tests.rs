use super::*;
use std::io::{BufRead, BufReader};
use std::num::NonZeroU64;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Duration;

fn identity() -> StorageIdentity {
    StorageIdentity {
        authority_id: "authority".into(),
        builder_id: "builder".into(),
        store_id: "store".into(),
    }
}
fn fixture() -> (tempfile::TempDir, Gate) {
    let root = tempfile::tempdir().unwrap();
    fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let gate = Gate::initialize(&root.path().join("launch"), identity()).unwrap();
    (root, gate)
}
fn permit(gate: &Gate, epoch: u64) -> Permit {
    Permit {
        version: VERSION,
        identity: identity(),
        permission: Permission::Execution {
            ownership: Ownership {
                executor_version: 1,
                builder_id: "builder".into(),
                store_id: "store".into(),
                attempt_id: "a".repeat(64),
                pool_epoch: NonZeroU64::new(epoch).unwrap(),
                boot_id: gate.boot_id().into(),
            },
        },
    }
}
// Concurrent test-process forks can briefly inherit CLOEXEC lock descriptors.
fn wait_fence(gate: &Gate) -> Fence<'_> {
    wait_fence_result(gate).unwrap()
}
fn wait_fence_result(gate: &Gate) -> Result<Fence<'_>> {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(fence) = gate.try_fence()? {
            return Ok(fence);
        }
        assert!(
            std::time::Instant::now() < deadline,
            "fence remained pending"
        );
        std::thread::park_timeout(Duration::from_millis(1));
    }
}
fn wait_launch(gate: &Gate, permit: &Permit) -> Result<LaunchGuard> {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(launch) = gate.authorize(permit)? {
            return Ok(launch);
        }
        ensure!(
            std::time::Instant::now() < deadline,
            "launch remained pending"
        );
        std::thread::park_timeout(Duration::from_millis(1));
    }
}
fn grant(gate: &Gate, permit: &Permit) {
    wait_fence(gate).publish(permit).unwrap();
}

#[test]
fn gate_is_closed_until_explicit_durable_grant_and_never_reinitialized() {
    let (_root, gate) = fixture();
    let expected = permit(&gate, 1);
    assert!(wait_launch(&gate, &expected).is_err());
    assert!(Gate::initialize(&gate.root, identity()).is_err());
    grant(&gate, &expected);
    let launch = wait_launch(&gate, &expected).unwrap();
    let flags = unsafe { libc::fcntl(launch._directory.as_raw_fd(), libc::F_GETFD) };
    assert!(flags >= 0 && flags & libc::FD_CLOEXEC != 0);
    assert!(gate.try_fence().unwrap().is_none());
    drop(launch);
    let fence = wait_fence(&gate);
    assert!(!gate.root.join(PERMIT).exists());
    assert!(gate.authorize(&expected).unwrap().is_none());
    fence.publish(&permit(&gate, 2)).unwrap();
    assert!(wait_launch(&gate, &expected).is_err());
    assert!(wait_launch(&gate, &permit(&gate, 2)).is_ok());
}

#[test]
fn boot_storage_authority_and_permission_kind_are_fenced() {
    let (_root, gate) = fixture();
    let expected = permit(&gate, 1);
    grant(&gate, &expected);
    let bytes = fs::read(gate.root.join(PERMIT)).unwrap();
    let next_boot = Gate::at(&gate.root, identity(), "another-boot".into()).unwrap();
    assert!(next_boot.authorize(&expected).is_err());
    assert_eq!(bytes, fs::read(gate.root.join(PERMIT)).unwrap());
    for mutate in [
        |p: &mut Permit| p.version = 2,
        |p: &mut Permit| p.identity.authority_id = "other".into(),
        |p: &mut Permit| p.identity.store_id = "other".into(),
        |p: &mut Permit| {
            if let Permission::Execution { ownership } = &mut p.permission {
                ownership.boot_id = "other".into();
            }
        },
    ] {
        let mut wrong = expected.clone();
        mutate(&mut wrong);
        assert!(gate.authorize(&wrong).is_err());
    }
    let recovery = Permit {
        version: VERSION,
        identity: identity(),
        permission: Permission::Recovery {
            epoch: 1,
            boot_id: gate.boot_id().into(),
        },
    };
    grant(&gate, &recovery);
    assert!(wait_launch(&gate, &expected).is_err());
    assert!(wait_launch(&gate, &recovery).is_ok());
}

#[test]
fn pending_fence_is_not_permission_validation_or_rejection() {
    let (_root, gate) = fixture();
    let expected = permit(&gate, 1);
    grant(&gate, &expected);
    let launch = wait_launch(&gate, &expected).unwrap();
    let path = gate.root.join(PERMIT);
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(gate.try_fence().unwrap().is_none());
    drop(launch);
    assert!(wait_fence_result(&gate).is_err());
    assert!(path.exists());
}

#[test]
fn malformed_oversized_and_redirected_paths_never_authorize_or_remove_foreign_files() {
    let (root, gate) = fixture();
    let expected = permit(&gate, 1);
    grant(&gate, &expected);
    let path = gate.root.join(PERMIT);
    for bytes in [
        b"invalid".to_vec(),
        vec![b' '; MAX_BYTES as usize + 1],
        b"{}".to_vec(),
    ] {
        fs::write(&path, bytes).unwrap();
        assert!(wait_launch(&gate, &expected).is_err());
    }
    grant(&gate, &expected);
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(wait_launch(&gate, &expected).is_err());
    assert!(wait_fence_result(&gate).is_err());
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    let outside = root.path().join("outside");
    fs::write(&outside, b"preserve").unwrap();
    fs::set_permissions(&outside, fs::Permissions::from_mode(0o600)).unwrap();
    fs::remove_file(&path).unwrap();
    symlink(&outside, &path).unwrap();
    assert!(wait_launch(&gate, &expected).is_err());
    assert!(wait_fence_result(&gate).is_err());
    assert_eq!(fs::read(&outside).unwrap(), b"preserve");
    fs::remove_file(&path).unwrap();
    fs::hard_link(&outside, &path).unwrap();
    assert!(wait_launch(&gate, &expected).is_err());
    assert!(wait_fence_result(&gate).is_err());
    assert_eq!(fs::read(&outside).unwrap(), b"preserve");
}

#[test]
fn directory_replacement_cannot_create_a_second_lock_lane() {
    let (root, gate) = fixture();
    let expected = permit(&gate, 1);
    grant(&gate, &expected);
    let held = wait_launch(&gate, &expected).unwrap();
    fs::rename(&gate.root, root.path().join("old")).unwrap();
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&gate.root)
        .unwrap();
    assert!(wait_launch(&gate, &expected).is_err());
    assert!(wait_fence_result(&gate).is_err());
    drop(held);
}

struct Worker {
    child: Child,
    lines: Receiver<String>,
}
impl Worker {
    fn start(gate: &Gate, mode: &str, permit: &Permit) -> Self {
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "build_executor::launch_gate::tests::worker",
                "--nocapture",
            ])
            .env("ABIRD_TEST_LAUNCH_ROOT", &gate.root)
            .env("ABIRD_TEST_LAUNCH_MODE", mode)
            .env(
                "ABIRD_TEST_LAUNCH_PERMIT",
                serde_json::to_string(permit).unwrap(),
            )
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let output = child.stdout.take().unwrap();
        let (sender, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(output).lines() {
                let Ok(line) = line else { break };
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        Self { child, lines }
    }
    fn expect(&self, marker: &str) {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            let line = self
                .lines
                .recv_timeout(deadline.saturating_duration_since(std::time::Instant::now()))
                .unwrap();
            if line == marker {
                return;
            }
        }
    }
    fn next(&mut self) {
        self.child.stdin.as_mut().unwrap().write_all(b"x").unwrap();
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
fn mark(value: &str) {
    println!("{value}");
    std::io::stdout().flush().unwrap();
}
fn wait_byte() {
    std::io::stdin().read_exact(&mut [0]).unwrap();
}

#[test]
fn worker() {
    let Ok(root) = std::env::var("ABIRD_TEST_LAUNCH_ROOT") else {
        return;
    };
    let gate = Gate::open(Path::new(&root), identity()).unwrap();
    let permit: Permit =
        serde_json::from_str(&std::env::var("ABIRD_TEST_LAUNCH_PERMIT").unwrap()).unwrap();
    match std::env::var("ABIRD_TEST_LAUNCH_MODE").unwrap().as_str() {
        "exec" => {
            let _launch = wait_launch(&gate, &permit).unwrap();
            mark("AUTHORIZED");
            wait_byte();
            let error = Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "build_executor::launch_gate::tests::worker",
                    "--nocapture",
                ])
                .env("ABIRD_TEST_LAUNCH_MODE", "after-exec")
                .exec();
            panic!("exec failed: {error}");
        }
        "after-exec" => {
            mark("EXECUTED");
            wait_byte();
        }
        "pending" => {
            assert!(gate.authorize(&permit).unwrap().is_none());
            mark("PENDING");
            wait_byte();
            assert!(wait_launch(&gate, &permit).is_err());
            mark("DENIED");
        }
        "fence" => {
            let _fence = wait_fence(&gate);
            mark("FENCED");
            wait_byte();
        }
        "forked-controller" => {
            let controller = crate::build_executor::tests::wait_ready(|| gate.try_controller());
            let (mut sender, receiver) = std::os::unix::net::UnixStream::pair().unwrap();
            receiver
                .set_read_timeout(Some(Duration::from_secs(10)))
                .unwrap();
            // This worker execed first; no parallel harness locks are inherited.
            let pid = unsafe { libc::fork() };
            assert!(pid >= 0);
            if pid == 0 {
                drop(sender);
                let mut byte = 0u8;
                let count =
                    unsafe { libc::read(receiver.as_raw_fd(), (&mut byte as *mut u8).cast(), 1) };
                unsafe {
                    libc::_exit(if count == 1 { 79 } else { 80 });
                }
            }
            drop(receiver);
            drop(controller);
            assert!(gate.try_controller().unwrap().is_none());
            mark("INHERITED");
            wait_byte();
            sender.write_all(b"x").unwrap();
            let mut status = 0;
            assert_eq!(unsafe { libc::waitpid(pid, &mut status, 0) }, pid);
            assert!(libc::WIFEXITED(status));
            assert_eq!(libc::WEXITSTATUS(status), 79);
            drop(crate::build_executor::tests::wait_ready(|| {
                gate.try_controller()
            }));
            mark("RELEASED");
            wait_byte();
        }
        _ => panic!("unknown test worker"),
    }
}

#[test]
fn exec_releases_the_interlock_while_the_launched_process_remains_alive() {
    let (_root, gate) = fixture();
    let expected = permit(&gate, 1);
    grant(&gate, &expected);
    let mut worker = Worker::start(&gate, "exec", &expected);
    worker.expect("AUTHORIZED");
    assert!(gate.try_fence().unwrap().is_none());
    worker.next();
    worker.expect("EXECUTED");
    let _fence = wait_fence(&gate);
    assert!(worker.child.try_wait().unwrap().is_none());
    worker.next();
    assert!(worker.child.wait().unwrap().success());
}

#[test]
fn pending_old_launches_reject_after_close_or_regrant() {
    for regrant in [false, true] {
        let (_root, gate) = fixture();
        let expected = permit(&gate, 1);
        grant(&gate, &expected);
        let fence = wait_fence(&gate);
        let mut worker = Worker::start(&gate, "pending", &expected);
        worker.expect("PENDING");
        if regrant {
            fence.publish(&permit(&gate, 2)).unwrap();
        } else {
            drop(fence);
        }
        worker.next();
        worker.expect("DENIED");
        assert!(worker.child.wait().unwrap().success());
    }
}

#[test]
fn killed_fencer_leaves_ingress_durably_closed() {
    let (_root, gate) = fixture();
    let expected = permit(&gate, 1);
    grant(&gate, &expected);
    let mut worker = Worker::start(&gate, "fence", &expected);
    worker.expect("FENCED");
    worker.child.kill().unwrap();
    worker.child.wait().unwrap();
    let reopened = Gate::open(&gate.root, identity()).unwrap();
    assert!(reopened.authorize(&expected).is_err());
    drop(wait_fence(&reopened));
}

#[test]
fn fork_inherited_controller_stays_pending_after_parent_drop_until_child_exit() {
    let (_root, gate) = fixture();
    let mut worker = Worker::start(&gate, "forked-controller", &permit(&gate, 1));
    worker.expect("INHERITED");
    assert!(gate.try_controller().unwrap().is_none());
    worker.next();
    worker.expect("RELEASED");
    drop(crate::build_executor::tests::wait_ready(|| {
        gate.try_controller()
    }));
    worker.next();
    assert!(worker.child.wait().unwrap().success());
}
