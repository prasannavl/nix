use super::*;

#[test]
fn scoped_directory_reserves_its_own_cloexec_descriptor_before_spawn() {
    use std::os::unix::fs::MetadataExt;
    let directory = tempfile::tempdir().unwrap();
    let original = std::fs::File::open(directory.path()).unwrap();
    let unrelated = tempfile::tempfile().unwrap();
    let unrelated_before = unrelated.metadata().unwrap();
    let scope = DirectoryFd::new(&original).unwrap();
    let fd = scope.0.as_raw_fd();
    assert!(fd >= 6 && fd != original.as_raw_fd() && fd != unrelated.as_raw_fd());
    assert_ne!(
        unsafe { libc::fcntl(fd, libc::F_GETFD) } & libc::FD_CLOEXEC,
        0
    );
    let scoped = std::fs::metadata(scope.path()).unwrap();
    let source = original.metadata().unwrap();
    assert_eq!((scoped.dev(), scoped.ino()), (source.dev(), source.ino()));
    let unrelated_after = unrelated.metadata().unwrap();
    assert_eq!(
        (unrelated_before.dev(), unrelated_before.ino()),
        (unrelated_after.dev(), unrelated_after.ino())
    );
    // Only the installed child hook clears CLOEXEC, after FD-table unshare.
    // This test grants no root/placement/settlement exemption.
}

#[test]
fn large_source_representation_requires_an_explicit_bounded_worker_constructor() {
    let deadline = Instant::now() + Duration::from_secs(5);
    let source = Limits {
        stdin: MAX_SOURCE_BYTES,
        stdout: MAX_SOURCE_BYTES,
        stderr: 4096,
    };
    assert!(Runner::new(1000, source, deadline).is_err());
    assert!(Runner::new_source(1000, source, deadline, MAX_SOURCE_BYTES).is_ok());
    for ceiling in [0, MAX_BYTES, MAX_SOURCE_BYTES + 1] {
        assert!(Runner::new_source(1000, source, deadline, ceiling).is_err());
    }
    assert!(
        Runner::new_source(
            1000,
            Limits {
                stderr: MAX_BYTES + 1,
                ..source
            },
            deadline,
            MAX_SOURCE_BYTES
        )
        .is_err()
    );
    // Constructors validate bounds without allocating payload-sized buffers.
}

fn limits() -> Limits {
    Limits {
        stdin: 1024 * 1024,
        stdout: 1024 * 1024,
        stderr: 1024 * 1024,
    }
}
fn runner(duration: Duration) -> Runner {
    Runner::new(1000, limits(), Instant::now() + duration).unwrap()
}
fn command(case: &str) -> Command {
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--exact",
            "build_executor::process::tests::worker",
            "--nocapture",
        ])
        .env_clear()
        .env("OB_PROCESS_CASE", case);
    command
}

#[test]
fn live_veto_poisoning_has_no_spawn_retry_or_settlement_shortcut() {
    let mut before = runner(Duration::from_secs(5));
    assert!(
        before
            .execute_while(&mut command("silent"), &[], &mut || anyhow::bail!("veto"))
            .is_err()
    );
    assert!(before.poisoned && before.child.is_none());
    assert!(before.execute(&mut command("empty"), &[]).is_err());

    let mut running = runner(Duration::from_secs(5));
    let mut checks = 0;
    let result = running.execute_while(&mut command("silent"), &[], &mut || {
        checks += 1;
        ensure!(checks < 2, "live veto");
        Ok(())
    });
    assert!(result.is_err() && running.poisoned && checks == 2);
    // Join only this test child; it is not a production descendant proof.
    if let Some(child) = &mut running.child {
        child.wait().unwrap();
    }
    running.child = None;
    assert!(running.execute(&mut command("empty"), &[]).is_err());
}

#[test]
fn transport_disconnect_retains_the_received_reply_without_another_request() {
    use crate::build_executor::protocol::{self, Reply, Request};
    let key = "a".repeat(64);
    let request = Request {
        version: protocol::VERSION,
        command: protocol::Command::Status { attempt_id: key },
    };
    let bytes = serde_json::to_vec(&request).unwrap();
    let directory = tempfile::tempdir().unwrap();
    let marker = directory.path().join("received");
    let mut child = command("transport-receipt");
    child.env("OB_PROCESS_MARKER", &marker);
    let observed = transport::exchange_while(
        &mut child,
        &bytes,
        limits(),
        Instant::now() + Duration::from_secs(5),
        || {
            ensure!(!marker.exists(), "fixture disconnected");
            Ok(())
        },
    )
    .unwrap();
    assert!(!observed.complete);
    // The test harness has its own stdout; only this fixture line is a receipt.
    let stdout = String::from_utf8(observed.stdout).unwrap();
    let receipt = stdout
        .lines()
        .find_map(|line| line.strip_prefix("TRANSPORT_RECEIPT="))
        .unwrap();
    let response = protocol::Response::decode(receipt.as_bytes()).unwrap();
    response.validate_for(&request).unwrap();
    assert!(matches!(response.reply, Reply::Status { .. }));
    let received: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&marker).unwrap()).unwrap();
    assert_eq!(received["request"], serde_json::to_value(&request).unwrap());
    let pid = i32::try_from(received["pid"].as_u64().unwrap()).unwrap();
    let waited = unsafe { libc::waitpid(pid, std::ptr::null_mut(), 0) };
    assert!(
        waited == pid
            || (waited == -1
                && std::io::Error::last_os_error().raw_os_error() == Some(libc::ECHILD))
    );

    // An already disconnected caller never spawns even its transport helper.
    let mut invalid = Command::new("/nonexistent-owned-transport-fixture");
    let error = transport::exchange_while(
        &mut invalid,
        &[],
        limits(),
        Instant::now() + Duration::from_secs(5),
        || anyhow::bail!("fixture disconnected"),
    )
    .err()
    .unwrap();
    assert_eq!(error.to_string(), "fixture disconnected");
    // Only an authenticated source scope may use an admitted longer lifetime.
    let error = transport::exchange(
        &mut invalid,
        &[],
        limits(),
        Instant::now() + Duration::from_secs(31),
    )
    .err()
    .unwrap();
    assert_eq!(error.to_string(), "invalid caller transport bound");
    // Synthetic peer data tests transport retention, not descendant settlement.
}

#[test]
fn helper_umask_changes_only_the_child_context() {
    let mask = || {
        std::fs::read_to_string("/proc/self/status")
            .unwrap()
            .lines()
            .find_map(|line| {
                line.strip_prefix("Umask:")
                    .map(str::trim)
                    .map(str::to_owned)
            })
            .unwrap()
    };
    let before = mask();
    let mut runner = runner(Duration::from_secs(5)).with_umask(0o027).unwrap();
    let output = runner.execute(&mut command("umask"), &[]).unwrap();
    assert!(output.status.success());
    assert!(
        String::from_utf8(output.stdout)
            .unwrap()
            .contains("CHILD_UMASK=0027")
    );
    assert_eq!(mask(), before);
    assert!(
        Runner::new(1000, limits(), Instant::now() + Duration::from_secs(5))
            .unwrap()
            .with_umask(0o1000)
            .is_err()
    );
}

#[test]
fn evaluator_exec_denial_covers_existing_threads_and_does_not_change_the_caller() {
    let state = || {
        std::fs::read_to_string("/proc/thread-self/status")
            .unwrap()
            .lines()
            .filter(|line| line.starts_with("Seccomp") || line.starts_with("NoNewPrivs:"))
            .map(str::to_owned)
            .collect::<Vec<_>>()
    };
    let before = state();
    let mut runner = runner(Duration::from_secs(10));
    let output = runner.execute(&mut command("exec-closed"), &[]).unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(state(), before);
}

#[test]
fn worker() {
    let Ok(case) = std::env::var("OB_PROCESS_CASE") else {
        return;
    };
    match case.as_str() {
        "exec-closed" => {
            use std::os::fd::AsRawFd;
            use std::os::unix::ffi::OsStrExt;
            let executable = std::env::current_exe().unwrap();
            let file = std::fs::File::open(&executable).unwrap();
            let program = std::ffi::CString::new(executable.as_os_str().as_bytes()).unwrap();
            let argv = [program.as_ptr(), std::ptr::null()];
            let envp: [*const libc::c_char; 1] = [std::ptr::null()];
            let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
            let thread_barrier = barrier.clone();
            let thread = std::thread::spawn(move || {
                thread_barrier.wait();
                assert_eq!(
                    command("empty").spawn().unwrap_err().raw_os_error(),
                    Some(libc::EPERM)
                );
            });
            restrict_worker_exec().unwrap();
            barrier.wait();
            thread.join().unwrap();
            assert_eq!(
                command("empty").spawn().unwrap_err().raw_os_error(),
                Some(libc::EPERM)
            );
            assert_eq!(
                unsafe {
                    libc::syscall(
                        libc::SYS_execveat,
                        file.as_raw_fd(),
                        c"".as_ptr(),
                        argv.as_ptr(),
                        envp.as_ptr(),
                        libc::AT_EMPTY_PATH,
                    )
                },
                -1
            );
            assert_eq!(
                std::io::Error::last_os_error().raw_os_error(),
                Some(libc::EPERM)
            );
            #[cfg(target_arch = "x86_64")]
            {
                assert_eq!(
                    unsafe {
                        libc::syscall(
                            libc::SYS_execve | 0x4000_0000,
                            program.as_ptr(),
                            argv.as_ptr(),
                            envp.as_ptr(),
                        )
                    },
                    -1
                );
                assert_eq!(
                    std::io::Error::last_os_error().raw_os_error(),
                    Some(libc::EPERM)
                );
            }
        }
        "privileges" => {
            assert_eq!(
                unsafe { libc::prctl(libc::PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) },
                1
            );
            let status = std::fs::read_to_string("/proc/thread-self/status").unwrap();
            for name in ["CapInh:", "CapPrm:", "CapEff:", "CapAmb:"] {
                let line = status.lines().find(|line| line.starts_with(name)).unwrap();
                assert_eq!(
                    u64::from_str_radix(line.split_whitespace().nth(1).unwrap(), 16).unwrap(),
                    0
                );
            }
            protect_worker_memory().unwrap();
            assert_eq!(unsafe { libc::prctl(libc::PR_GET_DUMPABLE, 0, 0, 0, 0) }, 0);
            let mut probe = command("protected-probe");
            probe.env("OB_PROTECTED_PID", std::process::id().to_string());
            assert!(probe.status().unwrap().success());
        }
        "protected-probe" => {
            let parent = std::env::var("OB_PROTECTED_PID").unwrap();
            assert!(std::fs::File::open(format!("/proc/{parent}/mem")).is_err());
            assert!(std::fs::read_link(format!("/proc/{parent}/fd/1")).is_err());
        }
        "duplex" => {
            std::io::stdout()
                .write_all(&vec![b'o'; 128 * 1024])
                .unwrap();
            std::io::stderr()
                .write_all(&vec![b'e'; 128 * 1024])
                .unwrap();
            let mut input = Vec::new();
            std::io::stdin().read_to_end(&mut input).unwrap();
            assert_eq!(input, vec![b'i'; 256 * 1024]);
            println!("DELIVERED_AND_EOF");
        }
        "transport-receipt" => {
            let mut input = Vec::new();
            std::io::stdin().read_to_end(&mut input).unwrap();
            let request: serde_json::Value = serde_json::from_slice(&input).unwrap();
            assert_eq!(request["command"]["kind"], "status");
            let response = serde_json::json!({"version": 3, "reply": {"kind": "status", "snapshot": {
                "kind": "retired", "pool": "available", "acceptance": {
                    "attempt_id": request["command"]["attempt_id"], "spec_digest": "b".repeat(64), "sequence": 1
                }, "outcome": {"kind": "cancelled", "reason": {"kind": "cancelled"}}
            }}});
            println!("TRANSPORT_RECEIPT={response}");
            std::io::stdout().flush().unwrap();
            let marker = std::path::PathBuf::from(std::env::var_os("OB_PROCESS_MARKER").unwrap());
            let next = marker.with_extension("next");
            std::fs::write(
                &next,
                serde_json::to_vec(
                    &serde_json::json!({"pid": std::process::id(), "request": request}),
                )
                .unwrap(),
            )
            .unwrap();
            std::fs::rename(next, marker).unwrap();
            let (_peer, mut blocked) = std::os::unix::net::UnixStream::pair().unwrap();
            blocked
                .set_read_timeout(Some(Duration::from_secs(10)))
                .unwrap();
            let _ = blocked.read(&mut [0]);
            panic!("transport fixture was not disconnected");
        }
        "umask" => {
            let status = std::fs::read_to_string("/proc/self/status").unwrap();
            let mask = status
                .lines()
                .find_map(|line| line.strip_prefix("Umask:"))
                .unwrap()
                .trim();
            println!("CHILD_UMASK={mask}");
        }
        "empty" => {
            let mut input = Vec::new();
            std::io::stdin().read_to_end(&mut input).unwrap();
            assert!(input.is_empty());
        }
        "killed" => unsafe {
            libc::raise(libc::SIGKILL);
            libc::_exit(125);
        },
        "fail" => {
            println!("private-stdout");
            eprintln!("private-stderr");
            unsafe {
                libc::_exit(7);
            }
        }
        "flood-out" | "flood-err" => {
            let mut stream: Box<dyn Write> = if case == "flood-out" {
                Box::new(std::io::stdout())
            } else {
                Box::new(std::io::stderr())
            };
            loop {
                if stream.write_all(&[b'x'; 4096]).is_err() {
                    break;
                }
            }
        }
        "silent" => loop {
            std::thread::park_timeout(Duration::from_secs(1));
        },
        "early-exit" => unsafe {
            libc::_exit(0);
        },
        "pipe-policy" => {
            unsafe {
                libc::signal(libc::SIGPIPE, libc::SIG_DFL);
            }
            let mut runner = runner(Duration::from_secs(5));
            assert!(
                runner
                    .execute(&mut command("early-exit"), &vec![b'x'; 512 * 1024])
                    .is_err()
            );
            assert!(runner.poisoned);
            let mut action = unsafe { std::mem::zeroed() };
            assert_eq!(
                unsafe { libc::sigaction(libc::SIGPIPE, std::ptr::null(), &mut action) },
                0
            );
            assert_eq!(action.sa_sigaction, libc::SIG_DFL);
            let mut mask = unsafe { std::mem::zeroed() };
            assert_eq!(
                unsafe { libc::pthread_sigmask(libc::SIG_BLOCK, std::ptr::null(), &mut mask) },
                0
            );
            assert_eq!(unsafe { libc::sigismember(&mask, libc::SIGPIPE) }, 0);
        }
        "pipe-pending" => {
            use std::os::fd::FromRawFd;
            unsafe {
                libc::signal(libc::SIGPIPE, libc::SIG_DFL);
            }
            let guard = PipeSignal::block().unwrap();
            assert_eq!(unsafe { libc::raise(libc::SIGPIPE) }, 0);
            let mut fds = [0; 2];
            assert_eq!(unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) }, 0);
            let reader = unsafe { std::fs::File::from_raw_fd(fds[0]) };
            let mut writer = unsafe { std::fs::File::from_raw_fd(fds[1]) };
            drop(reader);
            assert_eq!(
                write_input(&mut writer, b"x").unwrap_err().raw_os_error(),
                Some(libc::EPIPE)
            );
            let mut pending = unsafe { std::mem::zeroed() };
            assert_eq!(unsafe { libc::sigpending(&mut pending) }, 0);
            assert_eq!(unsafe { libc::sigismember(&pending, libc::SIGPIPE) }, 1);
            guard.consume_generated().unwrap(); // Consume this fixture's own raise.
            drop(guard);
        }
        "orphan" => {
            let pid = unsafe { libc::fork() };
            assert!(pid >= 0);
            if pid == 0 {
                std::thread::park_timeout(Duration::from_secs(3));
                std::fs::write(std::env::var_os("OB_PROCESS_MARKER").unwrap(), b"survived")
                    .unwrap();
            }
            unsafe {
                libc::_exit(0);
            }
        }
        _ => panic!("unknown process fixture"),
    }
}

#[test]
fn invalid_child_credentials_reject_before_any_credential_change() {
    let ids = || unsafe {
        (
            libc::getuid(),
            libc::geteuid(),
            libc::getgid(),
            libc::getegid(),
        )
    };
    let before = ids();
    for (uid, gid, groups) in [
        (0, 1000, vec![]),
        (1000, 0, vec![]),
        (u32::MAX, 1000, vec![]),
        (1000, u32::MAX, vec![]),
        (1000, 1000, vec![0]),
        (1000, 1000, vec![u32::MAX]),
        (1000, 1000, vec![1000; 65]),
    ] {
        assert_eq!(
            child_credentials(uid, gid, &groups)
                .unwrap_err()
                .raw_os_error(),
            Some(libc::EINVAL)
        );
        assert_eq!(ids(), before);
    }
}

#[test]
fn child_privilege_and_memory_restrictions_do_not_change_the_caller() {
    use std::os::unix::process::CommandExt;
    let snapshot = || {
        let status = std::fs::read_to_string("/proc/thread-self/status").unwrap();
        let fields = status
            .lines()
            .filter(|line| {
                ["CapInh:", "CapPrm:", "CapEff:", "CapAmb:", "NoNewPrivs:"]
                    .iter()
                    .any(|name| line.starts_with(name))
            })
            .map(str::to_owned)
            .collect::<Vec<_>>();
        (fields, unsafe {
            libc::prctl(libc::PR_GET_DUMPABLE, 0, 0, 0, 0)
        })
    };
    let before = snapshot();
    for namespace in [false, true] {
        let mut command = command("privileges");
        unsafe {
            if namespace {
                command.pre_exec(namespace_child);
            }
            command.pre_exec(restrict_privileges);
        }
        let result = runner(Duration::from_secs(10))
            .execute(&mut command, &[])
            .unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        assert_eq!(snapshot(), before);
    }
}

#[test]
fn namespace_waiter_releases_pipe_copies_before_bounded_duplex_io() {
    use std::os::unix::process::CommandExt;
    let mut command = command("duplex");
    unsafe {
        command.pre_exec(namespace_child);
    }
    let mut runner = runner(Duration::from_secs(10));
    let deadline = runner.deadline;
    let result = runner
        .execute(&mut command, &vec![b'i'; 256 * 1024])
        .unwrap();
    assert!(result.status.success());
    assert!(String::from_utf8_lossy(&result.stdout).contains("DELIVERED_AND_EOF"));
    assert_eq!(result.stderr.len(), 128 * 1024);
    assert!(runner.child.is_none() && !runner.poisoned);
    assert_eq!(runner.deadline, deadline);
    // Direct-child/pipe mechanics only; not namespace or settlement acceptance.
}

#[test]
fn namespace_waiter_preserves_exec_errors_exit_codes_and_signals() {
    use std::os::unix::process::{CommandExt, ExitStatusExt};
    for (case, code, signal) in [
        ("empty", Some(0), None),
        ("fail", Some(7), None),
        ("killed", None, Some(libc::SIGKILL)),
    ] {
        let mut command = command(case);
        unsafe {
            command.pre_exec(namespace_child);
        }
        let result = runner(Duration::from_secs(5))
            .execute(&mut command, &[])
            .unwrap();
        assert_eq!(result.status.code(), code);
        assert_eq!(result.status.signal(), signal);
    }
    let mut missing = Command::new("/nonexistent-owned-namespace-fixture");
    unsafe {
        missing.pre_exec(namespace_child);
    }
    assert_eq!(
        missing.spawn().unwrap_err().raw_os_error(),
        Some(libc::ENOENT)
    );
}

#[test]
fn full_duplex_input_and_both_output_streams_are_bounded_without_deadlock() {
    let mut runner = runner(Duration::from_secs(10));
    let deadline = runner.deadline;
    let result = runner
        .execute(&mut command("duplex"), &vec![b'i'; 256 * 1024])
        .unwrap();
    assert!(result.status.success());
    assert!(String::from_utf8_lossy(&result.stdout).contains("DELIVERED_AND_EOF"));
    assert_eq!(result.stderr.len(), 128 * 1024);
    assert!(runner.child.is_none());
    assert_eq!(runner.deadline, deadline);
    assert!(
        runner
            .execute(&mut command("empty"), &[])
            .unwrap()
            .status
            .success()
    );
}

#[test]
fn observed_nonzero_exit_is_data_not_transport_loss_and_debug_redacts_bytes() {
    let result = runner(Duration::from_secs(5))
        .execute(&mut command("fail"), &[])
        .unwrap();
    assert_eq!(result.status.code(), Some(7));
    assert!(String::from_utf8_lossy(&result.stderr).contains("private-stderr"));
    let debug = format!("{result:?}");
    assert!(debug.contains("stderr_bytes"));
    assert!(!debug.contains("private-"));
}

#[test]
fn invalid_policy_input_and_expired_deadline_reject_before_spawn() {
    for limits in [
        Limits {
            stdin: MAX_BYTES + 1,
            ..limits()
        },
        Limits {
            stdout: 0,
            ..limits()
        },
        Limits {
            stderr: MAX_BYTES + 1,
            ..limits()
        },
    ] {
        assert!(Runner::new(1000, limits, Instant::now() + Duration::from_secs(1)).is_err());
    }
    assert!(Runner::new(0, limits(), Instant::now() + Duration::from_secs(1)).is_err());
    let mut runner = runner(Duration::from_secs(1));
    runner.limits.stdin = 0;
    assert!(runner.execute(&mut command("silent"), b"x").is_err());
    assert!(runner.child.is_none());
    runner.deadline = Instant::now();
    assert!(runner.execute(&mut command("silent"), &[]).is_err());
    assert!(runner.child.is_none());
}

#[test]
fn stdout_and_stderr_overflow_poison_without_disclosing_captured_bytes() {
    for case in ["flood-out", "flood-err"] {
        let mut runner = runner(Duration::from_secs(5));
        runner.limits.stdout = 16384;
        runner.limits.stderr = 16384;
        let error = runner.execute(&mut command(case), &[]).unwrap_err();
        assert_eq!(error.to_string(), "helper output exceeds bound");
        assert!(runner.poisoned);
        assert!(
            runner
                .execute(&mut command("empty"), &[])
                .unwrap_err()
                .to_string()
                .contains("unresolved")
        );
    }
}

#[test]
fn silent_helper_and_unconsumed_input_cannot_succeed_or_refresh_the_deadline() {
    let mut silent = runner(Duration::from_millis(150));
    let start = Instant::now();
    assert!(silent.execute(&mut command("silent"), &[]).is_err());
    assert!(start.elapsed() < Duration::from_secs(3));
    assert!(silent.poisoned);
    let mut early = runner(Duration::from_secs(5));
    assert!(
        early
            .execute(&mut command("early-exit"), &vec![b'x'; 512 * 1024])
            .is_err()
    );
    assert!(early.poisoned);
}

#[test]
fn exited_parent_with_inherited_pipe_is_not_complete_and_descendant_is_not_signalled() {
    let temp = tempfile::tempdir().unwrap();
    let marker = temp.path().join("holder");
    let mut command = command("orphan");
    command.env("OB_PROCESS_MARKER", &marker);
    let mut runner = runner(Duration::from_secs(2));
    assert!(runner.execute(&mut command, &[]).is_err());
    assert!(runner.poisoned);
    let until = Instant::now() + Duration::from_secs(8);
    while !std::fs::read(&marker).is_ok_and(|bytes| bytes == b"survived") {
        assert!(Instant::now() < until);
        std::thread::park_timeout(Duration::from_millis(1));
    }
}

#[test]
fn spawn_uncertainty_is_not_permission_for_another_helper() {
    let mut runner = runner(Duration::from_secs(5));
    assert!(
        runner
            .execute(&mut Command::new("/not-an-owned-helper"), &[])
            .is_err()
    );
    assert!(runner.poisoned);
    assert!(runner.execute(&mut command("empty"), &[]).is_err());
}

#[test]
fn public_entry_requires_placed_unprivileged_identity() {
    let mut runner = runner(Duration::from_secs(5));
    assert!(runner.run(&mut command("silent"), &[]).is_err());
    assert!(runner.child.is_none());
}

#[test]
fn closed_stdin_does_not_kill_a_caller_with_default_sigpipe_policy() {
    assert!(command("pipe-policy").status().unwrap().success());
}

#[test]
fn closed_stdin_preserves_an_already_pending_sigpipe() {
    assert!(command("pipe-pending").status().unwrap().success());
}

#[test]
fn readiness_rejects_uncertainty_even_without_another_command() {
    let mut runner = runner(Duration::from_secs(5));
    assert!(runner.ready().is_ok());
    assert!(
        runner
            .execute(&mut command("empty"), &[])
            .unwrap()
            .status
            .success()
    );
    assert!(runner.ready().is_ok());
    runner.deadline = Instant::now();
    assert!(runner.ready().is_err());
    runner.deadline = Instant::now() + Duration::from_secs(5);
    assert!(
        runner
            .execute(&mut Command::new("/not-an-owned-helper"), &[])
            .is_err()
    );
    assert!(runner.child.is_none());
    assert!(runner.ready().is_err());
}
