use std::fs::{self, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use abird_host_manager::fleet::forced_command::{ARGUMENT_PREFIX, encode_arguments};
use abird_host_manager::fleet::maintenance::REQUIRED_PROGRAMS;

fn executable(path: &std::path::Path, contents: &str) {
    fs::write(path, contents).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

fn fixture_repository(path: &std::path::Path) {
    fs::write(path.join("flake.nix"), "{}\n").unwrap();
    fs::create_dir(path.join(".git")).unwrap();
}

#[test]
fn both_binary_surfaces_report_the_native_fleet_version() {
    for (program, arguments) in [
        (env!("CARGO_BIN_EXE_nixbot"), vec!["version"]),
        (
            env!("CARGO_BIN_EXE_abird-host-manager"),
            vec!["fleet", "version"],
        ),
    ] {
        let output = Command::new(program).args(arguments).output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(String::from_utf8(output.stdout).unwrap(), "2026.07.23\n");
    }
}

#[test]
fn list_groups_evaluates_the_nix_inventory_and_renders_stable_members() {
    let temporary = tempfile::tempdir().unwrap();
    fixture_repository(temporary.path());
    let nix = temporary.path().join("nix");
    executable(
        &nix,
        r#"#!/bin/sh
set -eu
case "$*" in
  'eval --json --file '*'/hosts.nix')
    printf '%s\n' '{"hosts":{"app":{"target":"10.0.0.2","groups":["prod"]},"db":{"target":"10.0.0.3","groups":["prod","data"]},"ungrouped":{"target":"10.0.0.4"}},"config":{}}'
    ;;
  'eval --json --no-write-lock-file .#nixbot.deployDependencies') printf '{}\n' ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    );
    let config = temporary.path().join("hosts.nix");
    fs::write(&config, "{}\n").unwrap();

    for (program, arguments) in [
        (
            env!("CARGO_BIN_EXE_nixbot"),
            vec![
                "--list-groups".to_owned(),
                format!("--config={}", config.display()),
                "--no-override".to_owned(),
            ],
        ),
        (
            env!("CARGO_BIN_EXE_abird-host-manager"),
            vec![
                format!("--nix-program={}", nix.display()),
                "fleet".to_owned(),
                "groups".to_owned(),
                format!("--config={}", config.display()),
                "--no-override".to_owned(),
            ],
        ),
    ] {
        let output = Command::new(program)
            .args(arguments)
            .env("ABIRD_HOST_MANAGER_NIX", &nix)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            String::from_utf8(output.stdout).unwrap(),
            "Groups:\n  - data: db\n  - prod: app, db\n  - (ungrouped): ungrouped\n"
        );
    }
}

#[test]
fn list_hosts_uses_config_defaults_selection_dependencies_and_exclusions() {
    let temporary = tempfile::tempdir().unwrap();
    fixture_repository(temporary.path());
    let nix = temporary.path().join("nix");
    executable(
        &nix,
        r#"#!/bin/sh
set -eu
case "$*" in
  'eval --json --file '*'/hosts.nix')
    printf '%s\n' '{"hosts":{"parent":{"target":"10.0.0.1","groups":["prod"]},"app":{"target":"10.0.0.2","groups":["prod"],"parent":"parent"},"other":{"target":"10.0.0.3","groups":["other"]}},"config":{"defaultGroup":"prod","defaultHosts":"app"}}'
    ;;
  'eval --json --no-write-lock-file .#nixbot.deployDependencies') printf '{}\n' ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    );
    let config = temporary.path().join("hosts.nix");
    fs::write(&config, "{}\n").unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .args([
            "--list-hosts".to_owned(),
            format!("--config={}", config.display()),
            "--no-override".to_owned(),
        ])
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        "Hosts:\n  - parent: 10.0.0.1\n  - app: 10.0.0.2 (parent=parent)\n"
    );
}

#[test]
fn compatibility_binary_rejects_unknown_actions_without_running_tools() {
    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .arg("destroy-everything")
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("unknown nixbot action"),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn compatibility_binary_hydrates_forced_command_arguments_without_a_shell() {
    let encoded = encode_arguments(&["version"]).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .env(
            "SSH_ORIGINAL_COMMAND",
            format!("{ARGUMENT_PREFIX} {encoded}"),
        )
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(String::from_utf8(output.stdout).unwrap(), "2026.07.23\n");
}

#[test]
fn dependency_actions_check_the_packaged_runtime_path() {
    let temporary = tempfile::tempdir().unwrap();
    for program in REQUIRED_PROGRAMS {
        executable(&temporary.path().join(program), "#!/bin/sh\nexit 0\n");
    }
    for action in ["deps", "check-deps"] {
        let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
            .arg(action)
            .env("PATH", temporary.path())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let progress = String::from_utf8_lossy(&output.stderr);
        assert!(
            progress.contains("● Check runtime dependencies"),
            "{progress}"
        );
        assert!(
            progress.contains("✓ Check runtime dependencies"),
            "{progress}"
        );
    }

    fs::remove_file(temporary.path().join("tofu")).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .arg("check-deps")
        .env("PATH", temporary.path())
        .output()
        .unwrap();
    assert!(!output.status.success());
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(error.contains("tofu"));
    assert!(error.contains("✗ Check runtime dependencies"), "{error}");
    assert!(!error.contains("Command stopped"), "{error}");
}

#[test]
fn compatibility_clean_action_is_bounded_to_configured_roots() {
    let temporary = tempfile::tempdir().unwrap();
    let runtime = temporary.path().join("runtime");
    let fallback = temporary.path().join("fallback");
    let diagnostic = temporary.path().join("diagnostic");
    fs::create_dir_all(runtime.join("run-current")).unwrap();
    fs::create_dir_all(fallback.join("run-current")).unwrap();
    fs::create_dir_all(diagnostic.join("diag-current")).unwrap();

    let dry = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .args(["clean", "all", "--dry"])
        .env("NIXBOT_RUNTIME_WORK_ROOT", &runtime)
        .env("NIXBOT_RUNTIME_FALLBACK_ROOT", &fallback)
        .env("NIXBOT_DIAG_KEEP_ROOT", &diagnostic)
        .output()
        .unwrap();
    assert!(dry.status.success());
    let dry_progress = String::from_utf8_lossy(&dry.stderr);
    assert!(
        dry_progress.contains("● Clean runtime state"),
        "{dry_progress}"
    );
    assert!(
        dry_progress.contains("✓ Clean runtime state"),
        "{dry_progress}"
    );
    assert!(runtime.exists() && fallback.exists() && diagnostic.exists());
    assert_eq!(
        String::from_utf8(dry.stdout).unwrap(),
        format!(
            "would remove {}\nwould remove {}\nwould remove {}\n",
            runtime.display(),
            fallback.display(),
            diagnostic.display()
        )
    );

    let applied = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .args(["clean", "all"])
        .env("NIXBOT_RUNTIME_WORK_ROOT", &runtime)
        .env("NIXBOT_RUNTIME_FALLBACK_ROOT", &fallback)
        .env("NIXBOT_DIAG_KEEP_ROOT", &diagnostic)
        .output()
        .unwrap();
    assert!(applied.status.success());
    let applied_progress = String::from_utf8_lossy(&applied.stderr);
    assert!(
        applied_progress.contains("✓ Clean runtime state"),
        "{applied_progress}"
    );
    assert!(!runtime.exists() && !fallback.exists() && !diagnostic.exists());
}

#[test]
fn host_local_lock_wait_is_visible_and_interruptible() {
    let temporary = tempfile::tempdir().unwrap();
    let lock = temporary.path().join("host-local-lock");
    fs::create_dir(&lock).unwrap();
    let holder = OpenOptions::new().read(true).open(&lock).unwrap();
    // SAFETY: `holder` is an open descriptor owned by this test.
    assert_eq!(unsafe { libc::flock(holder.as_raw_fd(), libc::LOCK_EX) }, 0);

    let spawn_waiter = || {
        Command::new(env!("CARGO_BIN_EXE_nixbot"))
            .args(["clean", "all", "--dry"])
            .env("NIXBOT_HOST_LOCAL_LOCK_PATH", &lock)
            .env("NIXBOT_RUNTIME_WORK_ROOT", temporary.path().join("runtime"))
            .env(
                "NIXBOT_RUNTIME_FALLBACK_ROOT",
                temporary.path().join("fallback"),
            )
            .env("NIXBOT_DIAG_KEEP_ROOT", temporary.path().join("diagnostic"))
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    };

    let waiter = spawn_waiter();
    std::thread::sleep(Duration::from_millis(250));
    // SAFETY: `holder` remains open and locked by this test.
    assert_eq!(unsafe { libc::flock(holder.as_raw_fd(), libc::LOCK_UN) }, 0);
    let output = waiter.wait_with_output().unwrap();
    assert!(output.status.success());
    let progress = String::from_utf8_lossy(&output.stderr);
    assert!(
        progress.contains("● Waiting for host-local action lock · clean"),
        "{progress}"
    );
    assert!(
        progress.contains("✓ Host-local action lock · clean"),
        "{progress}"
    );

    // SAFETY: the same descriptor remains open and can be locked again.
    assert_eq!(unsafe { libc::flock(holder.as_raw_fd(), libc::LOCK_EX) }, 0);
    let started = Instant::now();
    let interrupted = spawn_waiter();
    std::thread::sleep(Duration::from_millis(250));
    // SAFETY: the child pid is live and belongs to this test.
    assert_eq!(
        unsafe { libc::kill(interrupted.id() as i32, libc::SIGINT) },
        0
    );
    let output = interrupted.wait_with_output().unwrap();
    // SAFETY: `holder` remains open and locked by this test.
    let _ = unsafe { libc::flock(holder.as_raw_fd(), libc::LOCK_UN) };
    assert_eq!(output.status.code(), Some(130), "{output:?}");
    assert!(started.elapsed() < Duration::from_secs(2));
    let progress = String::from_utf8_lossy(&output.stderr);
    assert!(progress.contains("Interrupt received"), "{progress}");
}

#[test]
fn local_tofu_wrapper_executes_directly_without_a_shell() {
    let temporary = tempfile::tempdir().unwrap();
    let tofu = temporary.path().join("tofu");
    let argv = temporary.path().join("argv");
    executable(
        &tofu,
        &format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\n", argv.display()),
    );
    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .args(["tofu", "version", "-json"])
        .env("PATH", temporary.path())
        .current_dir(temporary.path())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let progress = String::from_utf8_lossy(&output.stderr);
    assert!(
        progress.contains("● Run infrastructure command"),
        "{progress}"
    );
    assert!(
        progress.contains("✓ Run infrastructure command"),
        "{progress}"
    );
    assert_eq!(fs::read_to_string(argv).unwrap(), "version\n-json\n");
}

#[test]
fn project_tofu_wrapper_materializes_encrypted_environment_and_redacts_output() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repo");
    let tools = temporary.path().join("tools");
    let project = repository.join("tf/cloudflare-dns");
    let secret_root = repository.join("data/secrets/globals/cloudflare");
    fs::create_dir_all(&project).unwrap();
    fs::create_dir_all(&secret_root).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(repository.join("flake.nix"), "{}\n").unwrap();

    for (name, value) in [
        ("r2-account-id.key.age", "account"),
        ("r2-state-bucket.key.age", "bucket"),
        ("r2-access-key-id.key.age", "access"),
        ("r2-secret-access-key.key.age", "backend-secret-value"),
        ("api-token.key.age", "provider-token-value"),
    ] {
        fs::write(secret_root.join(name), format!("{value}\n")).unwrap();
    }
    let identity = temporary.path().join("identity");
    fs::write(&identity, "test identity\n").unwrap();

    executable(
        &tools.join("age"),
        "#!/bin/sh\nset -eu\nout=\nsource=\nwhile [ \"$#\" -gt 0 ]; do\n  case \"$1\" in\n    -o) shift; out=$1 ;;\n    --decrypt|-i) if [ \"$1\" = -i ]; then shift; fi ;;\n    *) source=$1 ;;\n  esac\n  shift\ndone\nIFS= read -r value < \"$source\"\nprintf '%s\\n' \"$value\" > \"$out\"\n",
    );
    let argv = temporary.path().join("tofu-argv");
    executable(
        &tools.join("tofu"),
        &format!(
            "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$*\" > '{}'\nprintf '%s %s\\n' \"$R2_SECRET_ACCESS_KEY\" \"$CLOUDFLARE_API_TOKEN\"\n",
            argv.display()
        ),
    );

    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .args(["tofu", "-chdir=tf/cloudflare-dns", "init"])
        .env("PATH", &tools)
        .env("AGE_KEY_FILE", &identity)
        .current_dir(&repository)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let visible = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!visible.contains("backend-secret-value"));
    assert!(!visible.contains("provider-token-value"));
    assert!(visible.contains("<redacted>"));
    let arguments = fs::read_to_string(argv).unwrap();
    assert!(arguments.contains("-chdir=tf/cloudflare-dns init"));
    assert!(arguments.contains("-backend-config=bucket=bucket"));
}
