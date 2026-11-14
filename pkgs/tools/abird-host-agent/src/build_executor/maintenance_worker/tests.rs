use super::*;
use std::collections::BTreeMap;
use std::os::fd::AsRawFd;

fn policy() -> Policy {
    let package = format!("/nix/store/{}-installed", "0".repeat(32));
    Policy {
        version: 7,
        containment_digest: "a".repeat(64),
        control_digest: "c".repeat(64),
        role_policy: "/etc/abird-owned-build/role.json".into(),
        launcher: format!("{package}/bin/abird-host-agent").into(),
        program: format!("{package}/bin/nix-daemon").into(),
        evaluation_library: format!("{package}/libexec/libabird-owned-nix.so").into(),
        system: "x86_64-linux".into(),
        search_path: format!("{package}/bin"),
        configuration_directory: format!("{package}/etc/nix").into(),
        certificate_bundle: format!("{package}/etc/ca.pem").into(),
        clients: vec![super::super::daemon::Client {
            uid: 1000,
            user: "builder".into(),
        }],
    }
}

#[test]
fn collector_is_fixed_daemon_store_and_package_sibling_with_no_ambient_environment() {
    let policy = policy();
    policy.validate().unwrap();
    let c = command(&policy);
    assert_eq!(c.get_program(), policy.program.with_file_name("nix-store"));
    assert_eq!(
        c.get_args().collect::<Vec<_>>(),
        ["--store", "daemon", "--gc"]
    );
    assert_eq!(c.get_current_dir(), Some(Path::new("/var/empty")));
    let environment: BTreeMap<_, _> = c
        .get_envs()
        .map(|(k, v)| (k.to_str().unwrap(), v.unwrap().to_str().unwrap()))
        .collect();
    assert_eq!(
        environment,
        BTreeMap::from([
            ("HOME", "/var/empty"),
            ("LC_ALL", "C"),
            ("PATH", policy.search_path.as_str()),
            (
                "NIX_CONF_DIR",
                policy.configuration_directory.to_str().unwrap()
            ),
            (
                "NIX_SSL_CERT_FILE",
                policy.certificate_bundle.to_str().unwrap()
            ),
        ])
    );
}

#[test]
fn original_runtime_cutoff_counts_subseconds_without_resetting_reservation() {
    let start = Instant::now();
    let end = cutoff(Some(10), 5, Duration::from_millis(14_800), start).unwrap();
    assert_eq!(end.duration_since(start), Duration::from_millis(200));
    for (reserved, runtime, wall) in [
        (None, 5, Duration::from_secs(10)),
        (Some(10), 5, Duration::from_secs(15)),
        (Some(10), 5, Duration::from_secs(16)),
        (Some(u64::MAX), 1, Duration::ZERO),
    ] {
        assert!(cutoff(reserved, runtime, wall, start).is_err());
    }
    assert!(before(start - Duration::from_secs(1)).is_err());
}

#[test]
fn worker_cannot_create_missing_authority_or_disclose_malformed_declarations() {
    let root = tempfile::tempdir().unwrap();
    let policy = root.path().join("policy");
    let control = root.path().join("missing");
    std::fs::write(&policy, b"PRIVATE-MALFORMED-DECLARATION").unwrap();
    let error = run_service(&policy, &control, "attempt")
        .unwrap_err()
        .to_string();
    assert!(!error.contains("PRIVATE"));
    assert!(!control.exists());
    assert!(run_service(&policy, &control, "../other").is_err());
}

#[test]
fn collector_rejects_root_and_unbound_credentials_before_child_effects() {
    let before = unsafe {
        (
            libc::getuid(),
            libc::geteuid(),
            libc::getgid(),
            libc::getegid(),
        )
    };
    for credentials in [(0, 1000), (1000, 0), (u32::MAX, 1000), (1000, u32::MAX)] {
        assert_eq!(
            collector_child(credentials).unwrap_err().raw_os_error(),
            Some(libc::EINVAL)
        );
    }
    assert_eq!(
        unsafe {
            (
                libc::getuid(),
                libc::geteuid(),
                libc::getgid(),
                libc::getegid(),
            )
        },
        before
    );
}

#[test]
fn collector_child_closes_inherited_descriptors_without_mutating_parent() {
    let status = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "build_executor::maintenance_worker::tests::worker",
            "--nocapture",
        ])
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap())
        .env("OB_MAINTENANCE_TEST", "fds")
        .stdin(Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
}

#[test]
fn worker() {
    if std::env::var("OB_MAINTENANCE_TEST").as_deref() != Ok("fds") {
        return;
    }
    let f = std::fs::File::open("/dev/null").unwrap();
    assert_eq!(unsafe { libc::dup2(f.as_raw_fd(), 190) }, 190);
    assert!(unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) } != libc::SIG_ERR);
    let shell = std::env::split_paths(&std::env::var_os("PATH").unwrap())
        .map(|p| p.join("sh"))
        .find(|p| p.is_file())
        .unwrap();
    let mut child = Command::new(shell);
    child
        .env_clear()
        .args([
            "-c",
            "test ! -e /proc/self/fd/190 && test -z \"${OB_MAINTENANCE_TEST-}\"",
        ])
        .stdin(Stdio::null());
    unsafe {
        child.pre_exec(close_descriptors);
    }
    assert!(child.status().unwrap().success());
    assert!(unsafe { libc::fcntl(190, libc::F_GETFD) } >= 0);
    let mut signal: libc::sigaction = unsafe { std::mem::zeroed() };
    assert_eq!(
        unsafe { libc::sigaction(libc::SIGPIPE, std::ptr::null(), &mut signal) },
        0
    );
    assert_eq!(signal.sa_sigaction, libc::SIG_IGN);
}
