use super::*;
use std::collections::BTreeMap;
use std::process::Stdio;

fn owner() -> super::super::Ownership {
    super::super::Ownership {
        executor_version: 1,
        builder_id: "builder".into(),
        store_id: "store".into(),
        attempt_id: "a".repeat(64),
        pool_epoch: std::num::NonZeroU64::new(1).unwrap(),
        boot_id: "boot".into(),
    }
}

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
        clients: vec![Client {
            uid: 1000,
            user: "builder".into(),
        }],
    }
}

#[test]
fn binding_includes_program_launcher_search_path_and_separate_containment() {
    let original = policy();
    let digest = original.digest().unwrap();
    for mutate in [
        |p: &mut Policy| p.containment_digest = "b".repeat(64),
        |p: &mut Policy| p.role_policy = "/etc/other/role.json".into(),
        |p: &mut Policy| p.system = "aarch64-linux".into(),
        |p: &mut Policy| {
            p.evaluation_library = p
                .evaluation_library
                .to_str()
                .unwrap()
                .replace("installed", "other")
                .into()
        },
        |p: &mut Policy| {
            p.program = p
                .program
                .to_str()
                .unwrap()
                .replace("installed", "other")
                .into()
        },
        |p: &mut Policy| {
            p.launcher = p
                .launcher
                .to_str()
                .unwrap()
                .replace("installed", "other")
                .into()
        },
        |p: &mut Policy| p.search_path.push_str("/extra"),
        |p: &mut Policy| p.configuration_directory.push("other"),
        |p: &mut Policy| p.certificate_bundle.set_file_name("other.pem"),
        |p: &mut Policy| p.clients[0].uid = 1001,
        |p: &mut Policy| p.clients[0].user = "other".into(),
    ] {
        let mut changed = original.clone();
        mutate(&mut changed);
        assert_ne!(digest, changed.digest().unwrap());
    }
    let encoded = serde_json::to_vec(&original).unwrap();
    assert_eq!(
        serde_json::from_slice::<Policy>(&encoded)
            .unwrap()
            .digest()
            .unwrap(),
        digest
    );
    let mut value = serde_json::to_value(original).unwrap();
    value["argv"] = serde_json::json!(["--store", "local"]);
    assert!(serde_json::from_value::<Policy>(value).is_err());
}

#[test]
fn policy_rejects_paths_versions_unbounded_or_ambient_search() {
    for value in [
        "relative",
        "/run/current-system/sw/bin/nix-daemon",
        "/nix/store/pkg/bin/nix-daemon",
        "/nix/store/00000000000000000000000000000000-pkg/../bin/nix-daemon",
        "/nix/store/00000000000000000000000000000000-pkg/./bin/nix-daemon",
        "/nix/store/00000000000000000000000000000000-pkg//bin/nix-daemon",
        "/nix/store/00000000000000000000000000000000-pkg/bin/nix\0-daemon",
    ] {
        let mut p = policy();
        p.program = value.into();
        assert!(p.validate().is_err(), "{value:?}");
    }
    for mutate in [
        |p: &mut Policy| p.version = 1,
        |p: &mut Policy| p.version = 2,
        |p: &mut Policy| p.version = 3,
        |p: &mut Policy| p.version = 4,
        |p: &mut Policy| p.version = 5,
        |p: &mut Policy| p.version = 6,
        |p: &mut Policy| p.evaluation_library.set_file_name("libnixflakec.so"),
        |p: &mut Policy| p.evaluation_library.set_file_name("libother.so"),
        |p: &mut Policy| p.containment_digest.clear(),
        |p: &mut Policy| p.program.set_file_name("nix-store"),
        |p: &mut Policy| p.launcher.set_file_name("sh"),
        |p: &mut Policy| p.search_path.clear(),
        |p: &mut Policy| p.search_path.push(':'),
        |p: &mut Policy| p.search_path.push_str(":/bin"),
        |p: &mut Policy| p.search_path = vec![p.search_path.clone(); 65].join(":"),
    ] {
        let mut p = policy();
        mutate(&mut p);
        assert!(p.validate().is_err());
    }
}

#[test]
fn store_declarations_accept_root_objects_without_relaxing_executable_paths() {
    let root = "/nix/store/00000000000000000000000000000000-declaration";
    store_path(Path::new(root)).unwrap();
    store_path(&Path::new(root).join("etc/nix.conf")).unwrap();
    let mut p = policy();
    p.configuration_directory = root.into();
    p.certificate_bundle = root.into();
    p.validate().unwrap();
    p.program = root.into();
    assert!(p.validate().is_err());
    for invalid in [
        "/nix/store",
        "/nix/store/",
        "/nix/store/00000000000000000000000000000000-",
        "/nix/store/00000000000000000000000000000000-invalid name",
        "/nix/store/00000000000000000000000000000000-declaration/",
        "/nix/store/00000000000000000000000000000000-declaration/../other",
        "/nix/store/00000000000000000000000000000000-declaration//child",
    ] {
        assert!(store_path(Path::new(invalid)).is_err(), "{invalid:?}");
    }
}

#[test]
fn command_has_only_fixed_daemon_arguments_and_declared_environment() {
    let p = policy();
    let command = p.command(Kind::Build, &owner()).unwrap();
    assert_eq!(command.get_program(), p.program.as_os_str());
    assert_eq!(
        command.get_args().collect::<Vec<_>>(),
        [
            "--daemon",
            "--option",
            "allowed-users",
            "builder",
            "--option",
            "trusted-users",
            "root",
            "--option",
            "min-free",
            "0",
            "--option",
            "system",
            "x86_64-linux",
        ]
    );
    let environment: BTreeMap<_, _> = command
        .get_envs()
        .map(|(k, v)| (k.to_str().unwrap(), v.unwrap().to_str().unwrap()))
        .collect();
    assert_eq!(
        environment,
        BTreeMap::from([
            ("HOME", "/var/empty"),
            ("LC_ALL", "C"),
            ("PATH", p.search_path.as_str()),
            ("NIX_CONF_DIR", p.configuration_directory.to_str().unwrap()),
            ("NIX_SSL_CERT_FILE", p.certificate_bundle.to_str().unwrap()),
            ("LISTEN_PID", std::process::id().to_string().as_str()),
            ("LISTEN_FDS", "1"),
        ])
    );
}

#[test]
fn upstream_maintenance_uses_the_same_untrusted_executor_not_a_root_or_mode_exception() {
    let p = policy();
    let command = p.command(Kind::Maintenance, &owner()).unwrap();
    let build = p.command(Kind::Build, &owner()).unwrap();
    assert_eq!(
        command.get_args().collect::<Vec<_>>(),
        build.get_args().collect::<Vec<_>>()
    );
    assert_eq!(command.get_program(), p.program.as_os_str());
    assert!(p.command(Kind::Retirement, &owner()).is_err());
}

#[test]
fn native_socket_dac_is_exclusive_even_when_source_shares_the_reader_group() {
    socket_access(1000, libc::S_IFSOCK | 0o600, 1000).unwrap();
    for (uid, mode) in [
        (1000, 0o660),
        (1000, 0o666),
        (1000, 0o1600),
        (1001, 0o600),
        (0, 0o600),
    ] {
        assert!(socket_access(uid, libc::S_IFSOCK | mode, 1000).is_err());
    }
    let mut p = policy();
    p.clients.push(Client {
        uid: 1001,
        user: "second".into(),
    });
    assert!(p.validate().is_err());
    assert!(p.command(Kind::Retirement, &owner()).is_err());
}

#[test]
fn activation_requires_exact_current_pid_and_single_descriptor() {
    let pid = std::process::id().to_string();
    for (p, count) in [
        (None, None),
        (Some("0"), Some("1")),
        (Some(pid.as_str()), None),
        (Some(pid.as_str()), Some("0")),
        (Some(pid.as_str()), Some("2")),
        (Some(pid.as_str()), Some("01")),
    ] {
        assert!(activation(p, count).is_err());
    }
}

#[test]
fn declaration_and_service_refuse_nonroot_or_missing_authority_without_creation() {
    let root = tempfile::tempdir().unwrap();
    let missing = root.path().join("missing");
    assert!(Policy::load(&missing).is_err());
    assert!(!missing.exists());
    let file = root.path().join("policy");
    fs::write(&file, b"PRIVATE-MALFORMED-DECLARATION").unwrap();
    let error = Policy::load(&file).err().unwrap().to_string();
    assert!(!error.contains("PRIVATE"));
    assert!(run_service(&file, &missing).is_err());
    assert!(!missing.exists());
}

#[test]
fn fresh_exec_closes_unrelated_fd_retains_listener_and_preserves_ignored_sigpipe() {
    let root = tempfile::tempdir().unwrap();
    let status = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "build_executor::daemon::tests::worker",
            "--nocapture",
        ])
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap())
        .env("OB_DAEMON_TEST", "handoff")
        .env("OB_DAEMON_DIR", root.path())
        .stdin(Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
}

#[test]
fn worker() {
    if std::env::var("OB_DAEMON_TEST").as_deref() != Ok("handoff") {
        return;
    }
    let root = PathBuf::from(std::env::var_os("OB_DAEMON_DIR").unwrap());
    let socket = UnixListener::bind(root.join("socket")).unwrap();
    let file = fs::File::open("/dev/null").unwrap();
    assert!(unsafe { libc::dup2(file.as_raw_fd(), 190) } == 190);
    assert!(unsafe { libc::dup2(socket.as_raw_fd(), 3) } == 3);
    let listener = activation(Some(&std::process::id().to_string()), Some("1")).unwrap();
    assert_eq!(
        listener.local_addr().unwrap().as_pathname(),
        Some(root.join("socket").as_path())
    );
    assert!(unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) } != libc::SIG_ERR);
    let shell = std::env::split_paths(&std::env::var_os("PATH").unwrap())
        .map(|dir| dir.join("sh"))
        .find(|path| path.is_file())
        .unwrap();
    let mut command = Command::new(shell);
    command.env_clear().env("PATH", std::env::var_os("PATH").unwrap()).args([
        "-c", "kill -s PIPE $$; test -S /proc/self/fd/3 && test ! -e /proc/self/fd/190 && test -z \"${OB_DAEMON_TEST-}\"",
    ]);
    let error = handoff(&mut command, &listener).unwrap_err();
    panic!("handoff failed: {error}");
}
