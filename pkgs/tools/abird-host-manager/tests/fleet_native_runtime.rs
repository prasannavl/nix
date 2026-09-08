use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn run(command: &mut Command) -> String {
    let output = command.output().unwrap();
    assert!(
        output.status.success(),
        "command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

fn git(root: &Path, args: &[&str]) -> String {
    run(Command::new("git").arg("-C").arg(root).args(args))
}

#[test]
fn compatibility_build_runs_the_native_evaluate_and_build_pipeline() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let log = temporary.path().join("nix.log");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(
        repository.join("hosts.nix"),
        "{ hosts.app = { target = \"127.0.0.1\"; groups = [ \"all\" ]; }; }\n",
    )
    .unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(Command::new("git").args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "hosts.nix", "flake.nix"]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    fs::write(
        &nix,
        r#"#!/bin/sh
set -eu
printf 'argv=%s env=%s\n' "$*" "${NIX_SSHOPTS:-}" >> "$NATIVE_FLEET_NIX_LOG"
case "$*" in
  *'.#nixbot.deployDependencies') printf '{}\n' ;;
  *'--file '*'hosts.nix')
    printf '%s\n' '{"hosts":{"app":{"target":"127.0.0.1","groups":["all"]}},"config":{}}'
    ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app"]' ;;
  *'.#nixbot.plans.app.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  'build '*) printf '%s\n' '/nix/store/aaaaaaaa-system' ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&nix, fs::Permissions::from_mode(0o755)).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "build",
            "--host",
            "app",
            "--config",
            "hosts.nix",
            "--no-override",
            "--build-host",
            "local",
        ])
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_NIX_LOG", &log)
        .env("NIXBOT_RUNTIME_WORK_ROOT", temporary.path().join("runtime"))
        .env(
            "NIXBOT_RUNTIME_FALLBACK_ROOT",
            temporary.path().join("fallback"),
        )
        .env(
            "NIXBOT_DIAG_KEEP_ROOT",
            temporary.path().join("diagnostics"),
        )
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let progress = String::from_utf8_lossy(&output.stderr);
    assert!(progress.contains("● Build systems · 1 host"), "{progress}");
    assert!(progress.contains("✓ Build systems · 1 host"), "{progress}");
    assert!(progress.contains("Summary · build · success"), "{progress}");
    assert!(progress.contains("app · ok"), "{progress}");
    assert!(!progress.contains("/nix/store/aaaaaaaa-system.drv"));

    let commands = fs::read_to_string(&log).unwrap();
    assert!(commands.contains("eval --json --file"), "{commands}");
    assert!(
        commands.contains(".#nixbot.plans --apply builtins.attrNames"),
        "{commands}"
    );
    assert!(
        commands.contains(".#nixbot.plans.app.drvPath"),
        "{commands}"
    );
    assert!(commands.contains("build --print-out-paths"), "{commands}");

    let verbose = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "build",
            "--host",
            "app",
            "--config",
            "hosts.nix",
            "--no-override",
            "--build-host",
            "local",
            "--verbose",
            "--prefix-host-logs",
        ])
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_NIX_LOG", &log)
        .env(
            "NIXBOT_RUNTIME_WORK_ROOT",
            temporary.path().join("runtime-verbose"),
        )
        .env(
            "NIXBOT_RUNTIME_FALLBACK_ROOT",
            temporary.path().join("fallback-verbose"),
        )
        .env(
            "NIXBOT_DIAG_KEEP_ROOT",
            temporary.path().join("diagnostics-verbose"),
        )
        .output()
        .unwrap();
    assert!(
        verbose.status.success(),
        "{}",
        String::from_utf8_lossy(&verbose.stderr)
    );
    let verbose_log = String::from_utf8_lossy(&verbose.stderr);
    assert!(
        verbose_log.contains("[Build plan app out] /nix/store/aaaaaaaa-system.drv"),
        "{verbose_log}"
    );

    let github = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "build",
            "--host",
            "app",
            "--config",
            "hosts.nix",
            "--no-override",
            "--build-host",
            "local",
            "--log-format",
            "github-actions",
        ])
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_NIX_LOG", &log)
        .env(
            "NIXBOT_RUNTIME_WORK_ROOT",
            temporary.path().join("runtime-gh"),
        )
        .env(
            "NIXBOT_RUNTIME_FALLBACK_ROOT",
            temporary.path().join("fallback-gh"),
        )
        .env(
            "NIXBOT_DIAG_KEEP_ROOT",
            temporary.path().join("diagnostics-gh"),
        )
        .output()
        .unwrap();
    assert!(
        github.status.success(),
        "{}",
        String::from_utf8_lossy(&github.stderr)
    );
    let github_log = String::from_utf8_lossy(&github.stderr);
    assert!(
        github_log.contains("::group::Build systems · 1 host"),
        "{github_log}"
    );
    assert!(github_log.contains("::endgroup::"), "{github_log}");
}

#[test]
fn use_repo_script_reexecutes_the_rust_app_from_the_exact_worktree() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let log = temporary.path().join("nix.log");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts.app = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(Command::new("git").args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    fs::write(
        &nix,
        r#"#!/bin/sh
set -eu
printf 'cwd=%s argv=%s\n' "$PWD" "$*" >> "$NATIVE_FLEET_NIX_LOG"
case "$*" in
  *'.#nixbot.deployDependencies') printf '{}\n' ;;
  *'--file '*'hosts.nix') printf '%s\n' '{"hosts":{"app":{"groups":["all"]}},"config":{}}' ;;
  'run .#nixbot -- build '*) exit 0 ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&nix, fs::Permissions::from_mode(0o755)).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "build",
            "--host",
            "app",
            "--config",
            "hosts.nix",
            "--no-override",
            "--use-repo-script",
        ])
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_NIX_LOG", &log)
        .env("NIXBOT_RUNTIME_WORK_ROOT", temporary.path().join("runtime"))
        .env(
            "NIXBOT_RUNTIME_FALLBACK_ROOT",
            temporary.path().join("fallback"),
        )
        .env(
            "NIXBOT_DIAG_KEEP_ROOT",
            temporary.path().join("diagnostics"),
        )
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let commands = fs::read_to_string(log).unwrap();
    let reexec = commands
        .lines()
        .find(|line| line.contains("argv=run .#nixbot -- build"))
        .unwrap();
    assert!(reexec.contains("/repo"), "{reexec}");
    assert!(reexec.contains("--use-repo-script"), "{reexec}");
}

#[test]
fn interrupt_stops_a_running_build_process_group_and_preserves_exit_status() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts.app = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(Command::new("git").args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    fs::write(
        &nix,
        r#"#!/bin/sh
set -eu
case "$*" in
  *'.#nixbot.deployDependencies') printf '{}\n' ;;
  *'--file '*'hosts.nix') printf '%s\n' '{"hosts":{"app":{"groups":["all"]}},"config":{}}' ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app"]' ;;
  *'.#nixbot.plans.app.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  'build '*) sleep 30 ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&nix, fs::Permissions::from_mode(0o755)).unwrap();
    let started = Instant::now();
    let child = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "build",
            "--host",
            "app",
            "--config",
            "hosts.nix",
            "--no-override",
            "--build-host",
            "local",
        ])
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NIXBOT_RUNTIME_WORK_ROOT", temporary.path().join("runtime"))
        .env(
            "NIXBOT_RUNTIME_FALLBACK_ROOT",
            temporary.path().join("fallback"),
        )
        .env(
            "NIXBOT_DIAG_KEEP_ROOT",
            temporary.path().join("diagnostics"),
        )
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local-lock"),
        )
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_millis(500));
    // SAFETY: the child pid is live and belongs to this test.
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGINT) }, 0);
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(130), "{output:?}");
    assert!(started.elapsed() < Duration::from_secs(4));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("Interrupt received"),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn parallel_build_failure_keeps_the_host_label() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(Command::new("git").args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "hosts.nix", "flake.nix"]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    fs::write(
        &nix,
        r#"#!/bin/sh
set -eu
case "$*" in
  *'.#nixbot.deployDependencies') printf '{}\n' ;;
  *'--file '*'hosts.nix')
    printf '%s\n' '{"hosts":{"app":{"groups":["all"]},"db":{"groups":["all"]}},"config":{}}'
    ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app","db"]' ;;
  *'.#nixbot.plans.app.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  *'.#nixbot.plans.db.drvPath') printf '%s\n' '/nix/store/bbbbbbbb-system.drv' ;;
  *'/nix/store/aaaaaaaa-system.drv'*) printf '%s\n' '/nix/store/aaaaaaaa-system' ;;
  *'/nix/store/bbbbbbbb-system.drv'*) echo 'synthetic db build failure' >&2; exit 42 ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&nix, fs::Permissions::from_mode(0o755)).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "build",
            "--hosts=all",
            "--config",
            "hosts.nix",
            "--no-override",
            "--build-host=local",
            "--build-jobs=2",
        ])
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NIXBOT_BUILD_PLAN_CACHE", "0")
        .env("NIXBOT_RUNTIME_WORK_ROOT", temporary.path().join("runtime"))
        .env(
            "NIXBOT_RUNTIME_FALLBACK_ROOT",
            temporary.path().join("fallback"),
        )
        .env(
            "NIXBOT_DIAG_KEEP_ROOT",
            temporary.path().join("diagnostics"),
        )
        .output()
        .unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("build db"), "{stderr}");
    assert!(stderr.contains("synthetic db build failure"), "{stderr}");
    assert_eq!(stderr.matches("✗ Build systems").count(), 1, "{stderr}");
    assert!(!stderr.contains("Command stopped"), "{stderr}");
}

#[test]
fn dry_deploy_evaluates_the_plan_without_building_or_contacting_hosts() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let log = temporary.path().join("nix.log");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts.app = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(Command::new("git").args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "hosts.nix", "flake.nix"]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    fs::write(
        &nix,
        r#"#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$NATIVE_FLEET_NIX_LOG"
case "$*" in
  *'.#nixbot.deployDependencies') printf '{}\n' ;;
  *'--file '*'hosts.nix') printf '%s\n' '{"hosts":{"app":{}},"config":{}}' ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app"]' ;;
  *'.#nixbot.plans.app.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&nix, fs::Permissions::from_mode(0o755)).unwrap();
    let ssh = tools.join("ssh");
    fs::write(&ssh, "#!/bin/sh\necho unexpected-ssh >&2\nexit 99\n").unwrap();
    fs::set_permissions(&ssh, fs::Permissions::from_mode(0o755)).unwrap();

    let path = format!(
        "{}:{}",
        tools.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "deploy",
            "--host",
            "app",
            "--config",
            "hosts.nix",
            "--no-override",
            "--dry",
        ])
        .env("PATH", path)
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_NIX_LOG", &log)
        .env("NIXBOT_RUNTIME_WORK_ROOT", temporary.path().join("runtime"))
        .env(
            "NIXBOT_RUNTIME_FALLBACK_ROOT",
            temporary.path().join("fallback"),
        )
        .env(
            "NIXBOT_DIAG_KEEP_ROOT",
            temporary.path().join("diagnostics"),
        )
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let commands = fs::read_to_string(log).unwrap();
    assert!(!commands.lines().any(|line| line.starts_with("build ")));
}

#[test]
fn remote_build_holds_gc_lease_and_returns_verified_closure_to_local_store() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let nix_log = temporary.path().join("nix.log");
    let ssh_log = temporary.path().join("ssh.log");
    let ssh_count = temporary.path().join("ssh.count");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(Command::new("git").args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "hosts.nix", "flake.nix"]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    fs::write(
        &nix,
        r#"#!/bin/sh
set -eu
printf 'argv=%s env=%s\n' "$*" "${NIX_SSHOPTS:-}" >> "$NATIVE_FLEET_NIX_LOG"
case "$*" in
  *'.#nixbot.deployDependencies') printf '{}\n' ;;
  *'--file '*'hosts.nix')
    printf '%s\n' '{"hosts":{"app":{},"builder":{"target":"builder.invalid","knownHosts":"builder.invalid ssh-ed25519 AAAA"}},"config":{}}'
    ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app"]' ;;
  *'.#nixbot.plans.app.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  copy*|*'store verify'*) ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&nix, fs::Permissions::from_mode(0o755)).unwrap();
    let ssh = tools.join("ssh");
    fs::write(
        &ssh,
        r#"#!/bin/sh
set -eu
count=0
[ ! -f "$NATIVE_FLEET_SSH_COUNT" ] || count=$(cat "$NATIVE_FLEET_SSH_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$NATIVE_FLEET_SSH_COUNT"
printf '%s\n' "$*" >> "$NATIVE_FLEET_SSH_LOG"
case "$*" in
  *nixbot-build-lease*hold*)
    printf '%s\n' READY
    while read -r command; do
      [ "$command" = PING ] || exit 2
      printf 'PONG\n'
    done
    exit 0
    ;;
esac
cat >/dev/null
case "$count" in
  2) printf '%s\n' /nix/store/bbbbbbbb-system ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&ssh, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        tools.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "build",
            "--host",
            "app",
            "--config",
            "hosts.nix",
            "--no-override",
            "--build-host",
            "builder",
        ])
        .env("PATH", &path)
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_NIX_LOG", &nix_log)
        .env("NATIVE_FLEET_SSH_LOG", &ssh_log)
        .env("NATIVE_FLEET_SSH_COUNT", &ssh_count)
        .env("NIXBOT_SSH_CONNECT_TIMEOUT_SECS", "42")
        .env("NIXBOT_SSH_SERVER_ALIVE_INTERVAL_SECS", "9")
        .env("NIXBOT_SSH_SERVER_ALIVE_COUNT_MAX", "2")
        .env("NIXBOT_RUNTIME_WORK_ROOT", temporary.path().join("runtime"))
        .env(
            "NIXBOT_RUNTIME_FALLBACK_ROOT",
            temporary.path().join("fallback"),
        )
        .env(
            "NIXBOT_DIAG_KEEP_ROOT",
            temporary.path().join("diagnostics"),
        )
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(fs::read_to_string(&ssh_count).unwrap().trim(), "2");
    let nix_commands = fs::read_to_string(&nix_log).unwrap();
    assert!(nix_commands.contains("copy --to ssh-ng://root@builder.invalid"));
    assert!(nix_commands.contains("copy --from ssh-ng://root@builder.invalid"));
    assert!(nix_commands.contains("ConnectTimeout=42"));
    assert!(nix_commands.contains("ServerAliveInterval=9"));
    assert!(nix_commands.contains("ServerAliveCountMax=2"));
    let ssh_commands = fs::read_to_string(&ssh_log).unwrap();
    assert_eq!(ssh_commands.matches("root@builder.invalid").count(), 2);
    assert!(ssh_commands.contains("nixbot-build-lease"));
    assert!(ssh_commands.contains("/run/current-system/sw/bin/flock"));
    assert!(ssh_commands.contains("/nix/var/nix"));
    assert!(!ssh_commands.contains("abird-nix-build-lease"));
}

#[test]
fn forced_bootstrap_streams_keys_and_keeps_deploy_on_the_operator_route() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let ssh_log = temporary.path().join("ssh.log");
    let ssh_count = temporary.path().join("ssh.count");
    let bootstrap = temporary.path().join("bootstrap.key");
    let operator = temporary.path().join("operator.key");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(&bootstrap, "PRIVATE-BOOTSTRAP-FIXTURE\n").unwrap();
    fs::write(&operator, "OPERATOR-FIXTURE\n").unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts.app = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(Command::new("git").args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    fs::write(
        &nix,
        r#"#!/bin/sh
set -eu
case "$*" in
  *'.#nixbot.deployDependencies') printf '{}\n' ;;
  *'--file '*'hosts.nix')
    printf '%s\n' '{"hosts":{"app":{"target":"host.invalid","knownHosts":"host.invalid ssh-ed25519 AAAA"}},"config":{}}'
    ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app"]' ;;
  *'.#nixbot.plans.app.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  'build '*) printf '%s\n' '/nix/store/aaaaaaaa-system' ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&nix, fs::Permissions::from_mode(0o755)).unwrap();
    let ssh_keygen = tools.join("ssh-keygen");
    fs::write(
        &ssh_keygen,
        "#!/bin/sh\nset -eu\nprintf '%s\\n' 'ssh-ed25519 PUBLIC-FIXTURE'\n",
    )
    .unwrap();
    fs::set_permissions(&ssh_keygen, fs::Permissions::from_mode(0o755)).unwrap();
    let ssh = tools.join("ssh");
    fs::write(
        &ssh,
        r#"#!/bin/sh
set -eu
count=0
[ ! -f "$NATIVE_FLEET_SSH_COUNT" ] || count=$(cat "$NATIVE_FLEET_SSH_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$NATIVE_FLEET_SSH_COUNT"
printf '%s\n' "$*" >> "$NATIVE_FLEET_SSH_LOG"
cat >/dev/null
if [ "$count" -eq 4 ]; then
  exit 1
fi
"#,
    )
    .unwrap();
    fs::set_permissions(&ssh, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        tools.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "deploy",
            "--host",
            "app",
            "--config",
            "hosts.nix",
            "--no-override",
            "--bootstrap",
            "--bootstrap-key",
            bootstrap.to_str().unwrap(),
            "--operator-user",
            "operator",
            "--operator-key",
            operator.to_str().unwrap(),
        ])
        .env("PATH", path)
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_SSH_LOG", &ssh_log)
        .env("NATIVE_FLEET_SSH_COUNT", &ssh_count)
        .env("NIXBOT_RUNTIME_WORK_ROOT", temporary.path().join("runtime"))
        .env(
            "NIXBOT_RUNTIME_FALLBACK_ROOT",
            temporary.path().join("fallback"),
        )
        .env(
            "NIXBOT_DIAG_KEEP_ROOT",
            temporary.path().join("diagnostics"),
        )
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert_eq!(fs::read_to_string(ssh_count).unwrap().trim(), "5");
    let commands = fs::read_to_string(ssh_log).unwrap();
    assert_eq!(
        commands
            .lines()
            .filter(|line| line.contains("operator@host.invalid"))
            .count(),
        5
    );
    assert_eq!(
        commands
            .lines()
            .filter(|line| line.contains("-O exit"))
            .count(),
        1
    );
    assert!(!commands.contains("root@host.invalid"));
    assert!(!commands.contains("PRIVATE-BOOTSTRAP-FIXTURE"));
    assert!(!commands.contains("PUBLIC-FIXTURE"));
}

#[test]
fn automatic_transport_uses_forced_command_evidence_before_operator_fallback() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let ssh_log = temporary.path().join("ssh.log");
    let bootstrap = temporary.path().join("bootstrap.key");
    let operator = temporary.path().join("operator.key");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(&bootstrap, "UNUSED-BOOTSTRAP-FIXTURE\n").unwrap();
    fs::write(&operator, "OPERATOR-FIXTURE\n").unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts.app = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(Command::new("git").args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    fs::write(
        &nix,
        r#"#!/bin/sh
set -eu
case "$*" in
  *'.#nixbot.deployDependencies') printf '{}\n' ;;
  *'--file '*'hosts.nix')
    printf '%s\n' '{"hosts":{"app":{"target":"host.invalid","knownHosts":"host.invalid ssh-ed25519 AAAA"}},"config":{}}'
    ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app"]' ;;
  *'.#nixbot.plans.app.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  'build '*) printf '%s\n' '/nix/store/aaaaaaaa-system' ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&nix, fs::Permissions::from_mode(0o755)).unwrap();
    let ssh = tools.join("ssh");
    fs::write(
        &ssh,
        r#"#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$NATIVE_FLEET_SSH_LOG"
case "$*" in
  *'/run/current-system/sw/bin/nixbot check-bootstrap'*) exit 0 ;;
  *'root@host.invalid'*) echo 'Permission denied (publickey).' >&2; exit 255 ;;
  *'operator@host.invalid'*) cat >/dev/null; exit 1 ;;
  *) exit 92 ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&ssh, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        tools.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "deploy",
            "--host",
            "app",
            "--config",
            "hosts.nix",
            "--no-override",
            "--bootstrap-key",
            bootstrap.to_str().unwrap(),
            "--operator-user",
            "operator",
            "--operator-key",
            operator.to_str().unwrap(),
        ])
        .env("PATH", path)
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_SSH_LOG", &ssh_log)
        .env("NIXBOT_TRANSPORT_RETRY_ATTEMPTS", "1")
        .env("NIXBOT_RUNTIME_WORK_ROOT", temporary.path().join("runtime"))
        .env(
            "NIXBOT_RUNTIME_FALLBACK_ROOT",
            temporary.path().join("fallback"),
        )
        .env(
            "NIXBOT_DIAG_KEEP_ROOT",
            temporary.path().join("diagnostics"),
        )
        .output()
        .unwrap();
    assert!(!output.status.success());
    let commands = fs::read_to_string(ssh_log).unwrap();
    let operational = commands
        .lines()
        .filter(|line| !line.contains("-O exit"))
        .collect::<Vec<_>>();
    assert_eq!(operational.len(), 3, "{commands}");
    assert!(
        commands
            .lines()
            .next()
            .unwrap()
            .contains("root@host.invalid")
    );
    assert!(commands.contains("/run/current-system/sw/bin/nixbot check-bootstrap"));
    assert!(
        commands
            .lines()
            .rev()
            .find(|line| !line.contains("-O exit"))
            .unwrap()
            .contains("operator@host.invalid")
    );
    assert!(!commands.contains("UNUSED-BOOTSTRAP-FIXTURE"));
}

#[test]
fn failed_trimmed_route_retries_the_complete_configured_proxy_chain() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let ssh_log = temporary.path().join("ssh.log");
    let ssh_count = temporary.path().join("ssh.count");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(Command::new("git").args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let current_user = run(Command::new("id").arg("-un"));
    let inventory = format!(
        r#"{{"hosts":{{"relay":{{"target":"relay.invalid","user":"{current_user}","knownHosts":"relay.invalid ssh-ed25519 AAAA"}},"app":{{"target":"app.invalid","user":"root","proxyJump":"relay","knownHosts":"app.invalid ssh-ed25519 AAAA","groups":["all"]}}}},"config":{{}}}}"#
    );
    let nix = tools.join("nix");
    fs::write(
        &nix,
        format!(
            r#"#!/bin/sh
set -eu
case "$*" in
  *'.#nixbot.deployDependencies') printf '{{}}\n' ;;
  *'--file '*'hosts.nix') printf '%s\n' '{}';;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app","relay"]' ;;
  *'.#nixbot.plans.app.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  'build '*) printf '%s\n' '/nix/store/aaaaaaaa-system' ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
            inventory
        ),
    )
    .unwrap();
    fs::set_permissions(&nix, fs::Permissions::from_mode(0o755)).unwrap();
    let ssh = tools.join("ssh");
    fs::write(
        &ssh,
        r#"#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$NATIVE_FLEET_SSH_LOG"
case "$*" in *'-O exit'*) exit 0;; esac
count=0
[ ! -f "$NATIVE_FLEET_SSH_COUNT" ] || count=$(cat "$NATIVE_FLEET_SSH_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$NATIVE_FLEET_SSH_COUNT"
cat >/dev/null
if [ "$count" -eq 1 ]; then
  echo 'Connection refused' >&2
  exit 255
fi
if [ "$count" -eq 2 ]; then
  case "$*" in *'ProxyCommand='*) exit 0;; esac
fi
exit 1
"#,
    )
    .unwrap();
    fs::set_permissions(&ssh, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        tools.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "deploy",
            "--host",
            "app",
            "--config",
            "hosts.nix",
            "--no-override",
            "--build-host",
            "local",
        ])
        .env("PATH", path)
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_SSH_LOG", &ssh_log)
        .env("NATIVE_FLEET_SSH_COUNT", &ssh_count)
        .env("NIXBOT_LOCAL_SELF_TARGET", "on")
        .env("NIXBOT_TRANSPORT_RETRY_ATTEMPTS", "1")
        .env("NIXBOT_RUNTIME_WORK_ROOT", temporary.path().join("runtime"))
        .env(
            "NIXBOT_RUNTIME_FALLBACK_ROOT",
            temporary.path().join("fallback"),
        )
        .env(
            "NIXBOT_DIAG_KEEP_ROOT",
            temporary.path().join("diagnostics"),
        )
        .output()
        .unwrap();
    assert!(!output.status.success());
    let commands = fs::read_to_string(ssh_log).unwrap();
    let operational = commands
        .lines()
        .filter(|line| !line.contains("-O exit"))
        .collect::<Vec<_>>();
    assert!(operational.len() >= 3, "{commands}");
    assert!(!operational[0].contains("ProxyCommand="), "{commands}");
    assert!(operational[1].contains("ProxyCommand="), "{commands}");
    assert!(operational[1].contains("relay.invalid"), "{commands}");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("Logs kept at:"), "{stderr}");
    let retained = fs::read_dir(temporary.path().join("diagnostics"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let probe_error = fs::read_to_string(
        retained
            .join("commands")
            .join("primary-connectivity-probe-app.stderr.log"),
    )
    .unwrap();
    assert_eq!(probe_error, "Connection refused\n");
}

#[test]
fn local_relay_preserves_primary_target_failure_instead_of_using_operator_fallback() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let nix_log = temporary.path().join("nix.log");
    let ssh_log = temporary.path().join("ssh.log");
    let builder_count = temporary.path().join("builder.count");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(Command::new("git").args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    fs::write(
        &nix,
        r#"#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$NATIVE_FLEET_NIX_LOG"
case "$*" in
  *'.#nixbot.deployDependencies') printf '{}\n' ;;
  *'--file '*'hosts.nix')
    printf '%s\n' '{"hosts":{"app":{"target":"app.invalid","user":"root","operatorUser":"operator","knownHosts":"app.invalid ssh-ed25519 AAAA","groups":["all"]},"builder":{"target":"builder.invalid","knownHosts":"builder.invalid ssh-ed25519 AAAA"}},"config":{}}'
    ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app"]' ;;
  *'.#nixbot.plans.app.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  copy*) exit 0 ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&nix, fs::Permissions::from_mode(0o755)).unwrap();
    let ssh = tools.join("ssh");
    fs::write(
        &ssh,
        r#"#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$NATIVE_FLEET_SSH_LOG"
case "$*" in
  *'-O exit'*) exit 0 ;;
  *'builder.invalid'*nixbot-build-lease*hold*)
    printf '%s\n' READY
    while read -r command; do
      [ "$command" = PING ] || exit 2
      printf 'PONG\n'
    done
    ;;
  *'builder.invalid'*)
    count=0
    [ ! -f "$NATIVE_FLEET_BUILDER_COUNT" ] || count=$(cat "$NATIVE_FLEET_BUILDER_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$NATIVE_FLEET_BUILDER_COUNT"
    cat >/dev/null
    case "$count" in
      1) printf '%s\n' /nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-app ;;
    esac
    ;;
  *'root@app.invalid'*) cat >/dev/null; echo 'Permission denied (publickey).' >&2; exit 255 ;;
  *'operator@app.invalid'*) cat >/dev/null; printf '%s\n' /nix/store/cccccccccccccccccccccccccccccccc-nixos-system-app ;;
  *) exit 92 ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&ssh, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        tools.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "deploy",
            "--host",
            "app",
            "--config",
            "hosts.nix",
            "--no-override",
            "--build-host",
            "builder",
            "--build-host-deploy-mode",
            "local-copy",
            "--build-cache-url",
            "http://cache.invalid",
        ])
        .env("PATH", path)
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_NIX_LOG", &nix_log)
        .env("NATIVE_FLEET_SSH_LOG", &ssh_log)
        .env("NATIVE_FLEET_BUILDER_COUNT", &builder_count)
        .env("NIXBOT_TRANSPORT_RETRY_ATTEMPTS", "1")
        .env("NIXBOT_RUNTIME_WORK_ROOT", temporary.path().join("runtime"))
        .env(
            "NIXBOT_RUNTIME_FALLBACK_ROOT",
            temporary.path().join("fallback"),
        )
        .env(
            "NIXBOT_DIAG_KEEP_ROOT",
            temporary.path().join("diagnostics"),
        )
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local-lock"),
        )
        .output()
        .unwrap();
    assert!(!output.status.success());
    let ssh_commands = fs::read_to_string(ssh_log).unwrap();
    let operational = ssh_commands
        .lines()
        .filter(|line| !line.contains("-O exit"))
        .collect::<Vec<_>>();
    assert_eq!(
        operational
            .iter()
            .filter(|line| line.contains("root@app.invalid"))
            .count(),
        2,
        "{}\n{}",
        ssh_commands,
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        operational
            .iter()
            .filter(|line| line.contains("operator@app.invalid"))
            .count(),
        1,
        "{ssh_commands}"
    );
    let nix_commands = fs::read_to_string(nix_log).unwrap();
    assert!(!nix_commands.contains("--from http://cache.invalid"));
    assert!(!nix_commands.contains("--to ssh-ng://root@app.invalid"));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("primary deploy target app is unavailable"),
        "{stderr}"
    );
}

#[test]
fn terraform_phase_uses_native_secret_safe_planner_and_executor() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let tofu_log = temporary.path().join("tofu.log");
    fs::create_dir_all(repository.join("tf/cloudflare-dns")).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts.app = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    fs::write(
        repository.join("tf/cloudflare-dns/main.tf"),
        "terraform { backend \"s3\" {} }\n",
    )
    .unwrap();
    run(Command::new("git").args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    fs::write(
        &nix,
        r#"#!/bin/sh
set -eu
case "$*" in
  *'.#nixbot.deployDependencies') printf '{}\n' ;;
  *'--file '*'hosts.nix') printf '%s\n' '{"hosts":{"app":{}},"config":{}}' ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    fs::set_permissions(&nix, fs::Permissions::from_mode(0o755)).unwrap();
    let tofu = tools.join("tofu");
    fs::write(
        &tofu,
        "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$*\" >> \"$NATIVE_FLEET_TOFU_LOG\"\n",
    )
    .unwrap();
    fs::set_permissions(&tofu, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!(
        "{}:{}",
        tools.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "tf-dns",
            "--config",
            "hosts.nix",
            "--no-override",
            "--dry",
            "--skip-global-lock",
        ])
        .env("PATH", path)
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_TOFU_LOG", &tofu_log)
        .env("R2_ACCOUNT_ID", "account")
        .env("R2_STATE_BUCKET", "bucket")
        .env("R2_ACCESS_KEY_ID", "access")
        .env("R2_SECRET_ACCESS_KEY", "backend-secret-value")
        .env("CLOUDFLARE_API_TOKEN", "provider-token-value")
        .env("NIXBOT_RUNTIME_WORK_ROOT", temporary.path().join("runtime"))
        .env(
            "NIXBOT_RUNTIME_FALLBACK_ROOT",
            temporary.path().join("fallback"),
        )
        .env(
            "NIXBOT_DIAG_KEEP_ROOT",
            temporary.path().join("diagnostics"),
        )
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let commands = fs::read_to_string(tofu_log).unwrap();
    assert!(commands.lines().any(|line| line.contains(" init ")));
    assert!(commands.lines().any(|line| line.contains(" plan ")));
    assert!(!commands.lines().any(|line| line.contains(" apply ")));
    let visible_output = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!visible_output.contains("backend-secret-value"));
    assert!(!visible_output.contains("provider-token-value"));
}
