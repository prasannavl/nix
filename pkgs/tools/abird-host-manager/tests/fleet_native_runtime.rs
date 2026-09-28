use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use abird_host_manager::programs::clear_git_repository_environment;

#[path = "../src/test_support.rs"]
mod test_support;
use test_support::write_executable;

/// A `git` command that ignores the ambient repository environment, so a test
/// repository is never re-resolved onto the caller's checkout.
fn git_command() -> Command {
    let mut command = Command::new("git");
    clear_git_repository_environment(&mut command);
    command
}

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
    run(git_command().arg("-C").arg(root).args(args))
}

fn control_paths(log: &str) -> Vec<String> {
    log.split_whitespace()
        .filter_map(|token| {
            token
                .trim_matches(['\'', '"'])
                .strip_prefix("ControlPath=")
                .filter(|path| path.starts_with('/'))
                .map(str::to_owned)
        })
        .collect()
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
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "hosts.nix", "flake.nix"]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    write_executable(
        &nix,
        r#"#!/bin/sh
set -eu
printf 'argv=%s env=%s\n' "$*" "${NIX_SSHOPTS:-}" >> "$NATIVE_FLEET_NIX_LOG"
case "$*" in
  *'.#nixbot.deployDependencies'*) printf '{}\n' ;;
  *'--file '*'hosts.nix'*)
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
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local.lock.d"),
        )
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
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local.lock.d"),
        )
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
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local.lock.d"),
        )
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
fn deploy_skips_an_external_host_without_a_native_build_plan() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let log = temporary.path().join("nix.log");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    write_executable(
        &nix,
        r#"#!/bin/sh
set -eu
printf 'argv=%s\n' "$*" >> "$NATIVE_FLEET_NIX_LOG"
case "$*" in
  *'.#nixbot.deployDependencies'*) printf '{}\n' ;;
  *'--file '*'hosts.nix'*)
    printf '%s\n' '{"hosts":{"app":{"groups":["all"]},"external":{"groups":["all"],"deploy":"skip"}},"config":{}}'
    ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app"]' ;;
  *'.#nixbot.plans.app.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  'build --print-out-paths /nix/store/aaaaaaaa-system.drv^out') printf '%s\n' '/nix/store/aaaaaaaa-system' ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "deploy",
            "--hosts=app,external",
            "--config",
            "hosts.nix",
            "--no-override",
            "--build-host",
            "local",
            "--dry",
        ])
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local.lock.d"),
        )
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_NIX_LOG", &log)
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

    let progress = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "{progress}");
    assert!(
        progress.contains("◇ Build plan external · skipped"),
        "{progress}"
    );
    assert!(!progress.contains("✗ Build plan external"), "{progress}");
    assert!(progress.contains("external · skip"), "{progress}");
    for (phase, position) in [
        ("Build systems", "phase 1/5"),
        ("Snapshot generations", "phase 2/5"),
        ("Acquire deployment artifacts", "phase 3/5"),
        ("Deploy systems", "phase 4/5"),
        ("Verify deployment health", "phase 5/5"),
    ] {
        assert!(
            progress.contains(&format!("{phase} · 2 hosts · {position}")),
            "{progress}"
        );
    }
    assert!(progress.contains("Phases:"), "{progress}");
    assert!(
        progress.contains("Verify deployment health · ok"),
        "{progress}"
    );
    let commands = fs::read_to_string(log).unwrap();
    assert!(
        commands.contains(".#nixbot.plans.app.drvPath"),
        "{commands}"
    );
    assert!(!commands.contains("plans.external"), "{commands}");
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
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    write_executable(
        &nix,
        r#"#!/bin/sh
set -eu
printf 'cwd=%s argv=%s\n' "$PWD" "$*" >> "$NATIVE_FLEET_NIX_LOG"
case "$*" in
  *'.#nixbot.deployDependencies'*) printf '{}\n' ;;
  *'--file '*'hosts.nix'*) printf '%s\n' '{"hosts":{"app":{"groups":["all"]}},"config":{}}' ;;
  'run .#nixbot -- build '*) exit 0 ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
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
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local.lock.d"),
        )
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
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    write_executable(
        &nix,
        r#"#!/bin/sh
set -eu
case "$*" in
  *'.#nixbot.deployDependencies'*) printf '{}\n' ;;
  *'--file '*'hosts.nix'*) printf '%s\n' '{"hosts":{"app":{"groups":["all"]}},"config":{}}' ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app"]' ;;
  *'.#nixbot.plans.app.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  'build '*) sleep 30 ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
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
    std::thread::sleep(Duration::from_millis(1500));
    let signalled = Instant::now();
    // SAFETY: the child pid is live and belongs to this test.
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGINT) }, 0);
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(130), "{output:?}");
    // The first SIGINT must cancel the in-flight build promptly, not merely
    // before the overall deadline.
    assert!(
        signalled.elapsed() < Duration::from_secs(2),
        "interrupt response took {:?}",
        signalled.elapsed()
    );
    assert!(started.elapsed() < Duration::from_secs(5));
    let progress = String::from_utf8_lossy(&output.stderr);
    assert!(progress.contains("Interrupt received"), "{progress}");
    assert!(progress.contains("app · build · interrupted"), "{progress}");
    assert!(
        progress.contains("◇ Build systems · 1 host · phase 1/1 · interrupted"),
        "{progress}"
    );
    assert!(
        progress.contains("Summary · build · interrupted"),
        "{progress}"
    );
    assert!(progress.contains("app · interrupted"), "{progress}");
    assert!(!progress.contains("app · FAIL (build)"), "{progress}");
    assert!(!progress.contains("✗ "), "{progress}");
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
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "hosts.nix", "flake.nix"]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    write_executable(
        &nix,
        r#"#!/bin/sh
set -eu
case "$*" in
  *'.#nixbot.deployDependencies'*) printf '{}\n' ;;
  *'--file '*'hosts.nix'*)
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
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local.lock.d"),
        )
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
fn dry_deploy_builds_the_plan_without_contacting_deploy_targets() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let log = temporary.path().join("nix.log");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts.app = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "hosts.nix", "flake.nix"]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    write_executable(
        &nix,
        r#"#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$NATIVE_FLEET_NIX_LOG"
case "$*" in
  *'.#nixbot.deployDependencies'*) printf '{}\n' ;;
  *'--file '*'hosts.nix'*) printf '%s\n' '{"hosts":{"app":{}},"config":{}}' ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app"]' ;;
  *'.#nixbot.plans.app.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  build*'/nix/store/aaaaaaaa-system.drv^out'*) printf '%s\n' '/nix/store/bbbbbbbb-system' ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    let ssh = tools.join("ssh");
    write_executable(&ssh, "#!/bin/sh\necho unexpected-ssh >&2\nexit 99\n").unwrap();

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
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local.lock.d"),
        )
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
    assert!(commands.lines().any(|line| {
        line.starts_with("build ") && line.contains("/nix/store/aaaaaaaa-system.drv^out")
    }));
}

#[test]
fn remote_build_holds_gc_lease_and_returns_verified_closure_to_local_store() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let nix_log = temporary.path().join("nix.log");
    let ssh_log = temporary.path().join("ssh.log");
    let ssh_count = temporary.path().join("ssh.count");
    let keyscan_log = temporary.path().join("ssh-keyscan.log");
    let runtime_root = temporary.path().join("dev/shm/nixbot");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "hosts.nix", "flake.nix"]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    write_executable(
        &nix,
        r#"#!/bin/sh
set -eu
printf 'argv=%s env=%s\n' "$*" "${NIX_SSHOPTS:-}" >> "$NATIVE_FLEET_NIX_LOG"
case "$*" in
  *'.#nixbot.deployDependencies'*) printf '{}\n' ;;
  *'--file '*'hosts.nix'*)
    printf '%s\n' '{"hosts":{"app":{},"edge":{"target":"z.gap3.ai","proxyCommand":"cloudflared access ssh --hostname %h"},"builder":{"target":"10.10.30.80","proxyJump":"edge"}},"config":{}}'
    ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app"]' ;;
  *'.#nixbot.plans.app.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  copy*|*'store verify'*) ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    let ssh = tools.join("ssh");
    write_executable(
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
    let ssh_keyscan = tools.join("ssh-keyscan");
    write_executable(
        &ssh_keyscan,
        "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$*\" >> \"$NATIVE_FLEET_KEYSCAN_LOG\"\nexit 93\n",
    )
    .unwrap();
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
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local.lock.d"),
        )
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_NIX_LOG", &nix_log)
        .env("NATIVE_FLEET_SSH_LOG", &ssh_log)
        .env("NATIVE_FLEET_SSH_COUNT", &ssh_count)
        .env("NATIVE_FLEET_KEYSCAN_LOG", &keyscan_log)
        .env("NIXBOT_SSH_CONNECT_TIMEOUT_SECS", "42")
        .env("NIXBOT_SSH_SERVER_ALIVE_INTERVAL_SECS", "9")
        .env("NIXBOT_SSH_SERVER_ALIVE_COUNT_MAX", "2")
        .env("NIXBOT_RUNTIME_WORK_ROOT", &runtime_root)
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
    assert!(
        !keyscan_log.exists(),
        "a ProxyCommand-routed first hop must not launch direct ssh-keyscan"
    );
    let nix_commands = fs::read_to_string(&nix_log).unwrap();
    assert!(nix_commands.contains("copy --to ssh-ng://root@10.10.30.80"));
    assert!(nix_commands.contains("copy --from ssh-ng://root@10.10.30.80"));
    assert!(nix_commands.contains("ConnectTimeout=42"));
    assert!(nix_commands.contains("ServerAliveInterval=9"));
    assert!(nix_commands.contains("ServerAliveCountMax=2"));
    assert!(nix_commands.contains("cloudflared access ssh --hostname z.gap3.ai"));
    let ssh_commands = fs::read_to_string(&ssh_log).unwrap();
    assert_eq!(ssh_commands.matches("root@10.10.30.80").count(), 2);
    assert!(ssh_commands.contains("nixbot-build-lease"));
    assert!(ssh_commands.contains("/run/current-system/sw/bin/flock"));
    assert!(ssh_commands.contains("/nix/var/nix"));
    assert!(!ssh_commands.contains("abird-nix-build-lease"));
    let paths = control_paths(&format!("{nix_commands}\n{ssh_commands}"));
    assert!(!paths.is_empty(), "no SSH ControlPath was emitted");
    for path in paths {
        assert!(
            path.len() < 108,
            "ControlPath is too long ({} bytes): {path}",
            path.len()
        );
        assert!(path.starts_with(runtime_root.to_str().unwrap()), "{path}");
        assert!(path.contains("/run-"), "{path}");
        assert!(path.contains("/t-"), "{path}");
        assert_eq!(
            Path::new(&path)
                .file_name()
                .unwrap()
                .to_string_lossy()
                .len(),
            23,
            "{path}"
        );
    }
}

#[test]
fn parallel_remote_builds_share_semantic_lease_authority_with_materialized_identity() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let nix_log = temporary.path().join("nix.log");
    let ssh_log = temporary.path().join("ssh.log");
    let age_log = temporary.path().join("age.log");
    let encrypted_key = repository.join("builder.key.age");
    let age_identity = temporary.path().join("age-identity");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(&encrypted_key, "ENCRYPTED-FIXTURE\n").unwrap();
    fs::write(&age_identity, "AGE-SECRET-KEY-FIXTURE\n").unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    write_executable(
        &nix,
        r#"#!/bin/sh
set -eu
printf 'argv=%s env=%s\n' "$*" "${NIX_SSHOPTS:-}" >> "$NATIVE_FLEET_NIX_LOG"
case "$*" in
  *'.#nixbot.deployDependencies'*) printf '{}\n' ;;
  *'--file '*'hosts.nix'*)
    printf '%s\n' '{"hosts":{"app-a":{"groups":["all"]},"app-b":{"groups":["all"]},"edge":{"target":"z.gap3.ai","proxyCommand":"cloudflared access ssh --hostname %h"},"builder":{"target":"10.10.30.80","key":"builder.key.age","proxyJump":"edge"}},"config":{}}'
    ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app-a","app-b"]' ;;
  *'.#nixbot.plans.app-a.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  *'.#nixbot.plans.app-b.drvPath') printf '%s\n' '/nix/store/bbbbbbbb-system.drv' ;;
  copy*|*'store verify'*) ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    let age = tools.join("age");
    write_executable(
        &age,
        r#"#!/bin/sh
set -eu
destination=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) destination=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$destination" ]
printf '%s\n' "$destination" >> "$NATIVE_FLEET_AGE_LOG"
printf '%s\n' 'PRIVATE-KEY-FIXTURE' > "$destination"
"#,
    )
    .unwrap();
    let ssh = tools.join("ssh");
    write_executable(
        &ssh,
        r#"#!/bin/sh
set -eu
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
case "$*" in
  *'-O exit'*) exit 0 ;;
  *) printf '%s\n' /nix/store/cccccccc-system ;;
esac
"#,
    )
    .unwrap();
    let path = format!(
        "{}:{}",
        tools.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args([
            "build",
            "--hosts=app-a,app-b",
            "--config",
            "hosts.nix",
            "--no-override",
            "--build-host=builder",
            "--build-jobs=2",
            "--age-key-file",
            age_identity.to_str().unwrap(),
        ])
        .env("PATH", path)
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local.lock.d"),
        )
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_NIX_LOG", &nix_log)
        .env("NATIVE_FLEET_SSH_LOG", &ssh_log)
        .env("NATIVE_FLEET_AGE_LOG", &age_log)
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
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "{stderr}");
    assert!(
        !stderr.contains("builder lease authority changed"),
        "{stderr}"
    );
    let ssh_commands = fs::read_to_string(&ssh_log).unwrap();
    assert_eq!(ssh_commands.matches("nixbot-build-lease").count(), 1);
    assert_eq!(
        ssh_commands
            .lines()
            .filter(|line| line.contains("nixbot-build-lease") && line.contains("hold"))
            .count(),
        1,
        "{ssh_commands}"
    );
    let materialized = fs::read_to_string(&age_log).unwrap();
    assert_eq!(materialized.lines().count(), 4, "{materialized}");
    assert!(
        materialized.lines().all(|path| {
            path.contains("/t-")
                && (path.ends_with("/key-builder-primary")
                    || path.ends_with("/key-builder-proxy-primary"))
        }),
        "{materialized}"
    );
}

#[test]
fn remote_builder_derivation_copy_failure_keeps_the_raw_evidence() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let ssh_log = temporary.path().join("ssh.log");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    write_executable(
        &nix,
        r#"#!/bin/sh
set -eu
case "$*" in
  *'.#nixbot.deployDependencies'*) printf '{}\n' ;;
  *'--file '*'hosts.nix'*)
    printf '%s\n' '{"hosts":{"app":{"groups":["all"]},"builder":{"target":"10.10.30.80"}},"config":{}}'
    ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '["app"]\n' ;;
  *'.#nixbot.plans.app.drvPath') printf '/nix/store/aaaaaaaa-system.drv\n' ;;
  copy*)
    echo "ControlPath too long ('/very/long/control/socket' >= 108 bytes)" >&2
    exit 1
    ;;
  'build '*|*'store verify'*) ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    let ssh = tools.join("ssh");
    write_executable(
        &ssh,
        r#"#!/bin/sh
set -eu
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
exit 0
"#,
    )
    .unwrap();
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
            "--build-host=builder",
        ])
        .env("PATH", path)
        .env("ABIRD_HOST_MANAGER_NIX", &nix)
        .env("NATIVE_FLEET_SSH_LOG", &ssh_log)
        .env("NIXBOT_BUILD_PLAN_CACHE", "0")
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local.lock.d"),
        )
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
    assert!(
        stderr.contains("remote build derivation copy failed"),
        "{stderr}"
    );
    assert!(stderr.contains("ControlPath too long"), "{stderr}");
    assert!(stderr.contains("108 bytes"), "{stderr}");
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
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    write_executable(
        &nix,
        r#"#!/bin/sh
set -eu
case "$*" in
  *'.#nixbot.deployDependencies'*) printf '{}\n' ;;
  *'--file '*'hosts.nix'*)
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
    let ssh_keygen = tools.join("ssh-keygen");
    write_executable(
        &ssh_keygen,
        "#!/bin/sh\nset -eu\nprintf '%s\\n' 'ssh-ed25519 PUBLIC-FIXTURE'\n",
    )
    .unwrap();
    let ssh = tools.join("ssh");
    write_executable(
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
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local.lock.d"),
        )
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
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    write_executable(
        &nix,
        r#"#!/bin/sh
set -eu
case "$*" in
  *'.#nixbot.deployDependencies'*) printf '{}\n' ;;
  *'--file '*'hosts.nix'*)
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
    let ssh = tools.join("ssh");
    write_executable(
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
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local.lock.d"),
        )
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
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let current_user = run(Command::new("id").arg("-un"));
    // Keep the fixture hermetic: the packaged Nix test environment does not
    // include the `hostname` executable, while localhost is always part of the
    // manager's self-target evidence.
    let current_host = "localhost";
    let inventory = format!(
        r#"{{"hosts":{{"relay":{{"target":"{current_host}","user":"{current_user}","knownHosts":"{current_host} ssh-ed25519 AAAA"}},"app":{{"target":"app.invalid","user":"root","proxyJump":"relay","knownHosts":"app.invalid ssh-ed25519 AAAA","groups":["all"]}}}},"config":{{}}}}"#
    );
    let nix = tools.join("nix");
    write_executable(
        &nix,
        format!(
            r#"#!/bin/sh
set -eu
case "$*" in
  *'.#nixbot.deployDependencies'*) printf '{{}}\n' ;;
  *'--file '*'hosts.nix'*) printf '%s\n' '{}';;
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
    let ssh = tools.join("ssh");
    write_executable(
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
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local.lock.d"),
        )
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
    assert!(operational[1].contains(&current_host), "{commands}");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("Logs kept at:"), "{stderr}");
    let retained = fs::read_dir(temporary.path().join("diagnostics"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let commands_dir = retained.join("commands");
    let entries = fs::read_dir(&commands_dir)
        .map(|dir| {
            dir.filter_map(|entry| entry.ok())
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let probe_name = entries
        .iter()
        .find(|name| {
            name.starts_with("primary-connectivity-probe") && name.ends_with(".stderr.log")
        })
        .cloned()
        .unwrap_or_else(|| {
            panic!(
                "no probe diagnostics in {}: {entries:?}",
                commands_dir.display()
            )
        });
    let probe_error = fs::read_to_string(commands_dir.join(probe_name)).unwrap();
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
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    write_executable(
        &nix,
        r#"#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$NATIVE_FLEET_NIX_LOG"
case "$*" in
  *'.#nixbot.deployDependencies'*) printf '{}\n' ;;
  *'--file '*'hosts.nix'*)
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
    let ssh = tools.join("ssh");
    write_executable(
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
    // Snapshot probing may use the operator fallback, but distribution and
    // admission must both stay on the primary target.
    assert_eq!(
        operational
            .iter()
            .filter(|line| line.contains("root@app.invalid"))
            .count(),
        3,
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
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);

    let nix = tools.join("nix");
    write_executable(
        &nix,
        r#"#!/bin/sh
set -eu
case "$*" in
  *'.#nixbot.deployDependencies'*) printf '{}\n' ;;
  *'--file '*'hosts.nix'*) printf '%s\n' '{"hosts":{"app":{}},"config":{}}' ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
    )
    .unwrap();
    let tofu = tools.join("tofu");
    write_executable(
        &tofu,
        "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$*\" >> \"$NATIVE_FLEET_TOFU_LOG\"\n",
    )
    .unwrap();
    let path = format!(
        "{}:{}",
        tools.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
        .current_dir(&repository)
        .args(["tf-dns", "--config", "hosts.nix", "--no-override", "--dry"])
        .env("PATH", path)
        .env(
            "NIXBOT_HOST_LOCAL_LOCK_PATH",
            temporary.path().join("host-local.lock.d"),
        )
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

#[test]
fn required_host_coverage_is_checked_before_native_build_or_host_effects() {
    let temporary = tempfile::tempdir().unwrap();
    let repository = temporary.path().join("repository");
    let tools = temporary.path().join("tools");
    let log = temporary.path().join("effects.log");
    fs::create_dir_all(&repository).unwrap();
    fs::create_dir_all(&tools).unwrap();
    fs::write(repository.join("hosts.nix"), "{ hosts = {}; }\n").unwrap();
    fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
    run(git_command().args(["init", "-q"]).arg(&repository));
    git(&repository, &["config", "user.name", "Fleet Test"]);
    git(
        &repository,
        &["config", "user.email", "fleet@example.invalid"],
    );
    git(&repository, &["config", "commit.gpgsign", "false"]);
    git(&repository, &["add", "."]);
    git(&repository, &["commit", "-qm", "fixture"]);
    let nix = tools.join("nix");
    write_executable(&nix, r#"#!/bin/sh
set -eu
printf 'nix:%s\n' "$*" >> "$NATIVE_FLEET_EFFECTS_LOG"
case "$*" in
  *'.#custom.deployDependencies'*) printf '%s\n' '{"app":["db"]}' ;;
  *'--file '*'hosts.nix'*) printf '%s\n' '{"hosts":{"app":{},"db":{},"worker":{}},"config":{"deployDepsKey":"custom.deployDependencies"}}' ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '%s\n' '["app","db","worker"]' ;;
  *'.#nixbot.plans.app.drvPath'|*'.#nixbot.plans.db.drvPath') printf '%s\n' '/nix/store/aaaaaaaa-system.drv' ;;
  'build --print-out-paths /nix/store/aaaaaaaa-system.drv^out') printf '%s\n' '/nix/store/bbbbbbbb-system' ;;
  *) echo "unexpected effect: $*" >&2; exit 91 ;;
esac
"#).unwrap();
    let ssh = tools.join("ssh");
    write_executable(
        &ssh,
        "#!/bin/sh\nprintf 'ssh:%s\\n' \"$*\" >> \"$NATIVE_FLEET_EFFECTS_LOG\"\nexit 99\n",
    )
    .unwrap();
    let path = format!(
        "{}:{}",
        tools.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    for (selectors, required, dry, succeeds) in [
        ("app", "app,db", true, true),
        ("app,-db", "app,db", false, false),
        ("app", "worker", false, false),
        ("app", "missing", false, false),
    ] {
        fs::write(&log, "").unwrap();
        let mut command = Command::new(env!("CARGO_BIN_EXE_nixbot"));
        command.current_dir(&repository).args([
            "deploy",
            "--hosts",
            selectors,
            "--require-hosts",
            required,
            "--config",
            "hosts.nix",
            "--no-override",
        ]);
        if dry {
            command.arg("--dry");
        }
        let output = command
            .env("PATH", &path)
            .env(
                "NIXBOT_HOST_LOCAL_LOCK_PATH",
                temporary.path().join("host-local.lock.d"),
            )
            .env("ABIRD_HOST_MANAGER_NIX", &nix)
            .env("NATIVE_FLEET_EFFECTS_LOG", &log)
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
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.success(),
            succeeds,
            "{selectors}, {required}: {stderr}"
        );
        let effects = fs::read_to_string(&log).unwrap();
        assert!(effects.contains(".#custom.deployDependencies"), "{effects}");
        assert!(
            !effects.contains(".#nixbot.deployDependencies"),
            "{effects}"
        );
        assert!(!effects.contains("ssh:"), "{effects}");
        if !succeeds {
            assert!(
                !effects.lines().any(|line| line.starts_with("nix:build ")),
                "{effects}"
            );
            assert!(!effects.contains("nixbot.plans"), "{effects}");
            assert!(
                stderr.contains("required") || stderr.contains("Required"),
                "{stderr}"
            );
        } else {
            assert!(
                effects.lines().any(|line| line.starts_with("nix:build ")),
                "{effects}"
            );
            assert!(stderr.contains("2 hosts"), "{stderr}");
        }
    }
}

#[test]
fn native_health_uses_inventory_policy_instead_of_ssh_alias() {
    use base64::Engine as _;

    let system_failures = [
        "first.service loaded failed failed first system failure",
        "second.service loaded failed failed second system failure",
    ];
    for (policy_present, user_failure, expected_success) in [
        (true, false, true),
        (false, false, false),
        (true, true, false),
    ] {
        let temporary = tempfile::tempdir().unwrap();
        let repository = temporary.path().join("repository");
        let tools = temporary.path().join("tools");
        let log = temporary.path().join("effects.log");
        let health = temporary.path().join("health.records");
        fs::create_dir_all(&repository).unwrap();
        fs::create_dir_all(&tools).unwrap();
        fs::write(repository.join("hosts.nix"), "{ hosts = {}; }\n").unwrap();
        fs::write(repository.join("flake.nix"), "{ outputs = _: {}; }\n").unwrap();
        run(git_command().args(["init", "-q"]).arg(&repository));
        git(&repository, &["config", "user.name", "Fleet Test"]);
        git(
            &repository,
            &["config", "user.email", "fleet@example.invalid"],
        );
        git(&repository, &["config", "commit.gpgsign", "false"]);
        git(&repository, &["add", "."]);
        git(&repository, &["commit", "-qm", "fixture"]);

        let mut inventory = serde_json::json!({
            "hosts": {"app": {
                "target": "ssh-alias.invalid",
                "knownHosts": "ssh-alias.invalid ssh-ed25519 AAAA",
                "groups": ["all"]
            }},
            "config": {}
        });
        if policy_present {
            inventory["hosts"]["app"]["healthCheck"] = serde_json::json!({
                "ignore": ["first.service", "second.service"]
            });
        }
        // Only the inventory key owns policy. No host entry matches the SSH
        // hostname, so alias lookup/defaulting cannot satisfy the healthy case.
        let inventory_file = temporary.path().join("inventory.json");
        fs::write(&inventory_file, inventory.to_string()).unwrap();
        let emit =
            |kind: &str, fields: &[&str]| {
                format!(
                    "{}\n",
                    std::iter::once(kind.to_owned())
                        .chain(fields.iter().map(|field| {
                            base64::engine::general_purpose::STANDARD.encode(field)
                        }))
                        .collect::<Vec<_>>()
                        .join("\t")
                )
            };
        let mut records = emit("hold-absent", &[]) + &emit("status-absent", &[]);
        for failure in &system_failures {
            records.push_str(&emit("system-failed", &[failure]));
        }
        if user_failure {
            records.push_str(&emit("user", &["app", "1000", "active", "ok", "ok"]));
            records.push_str(&emit(
                "user-failed",
                &[
                    "app",
                    "first.service loaded failed failed same-name user failure",
                ],
            ));
        }
        fs::write(&health, records).unwrap();

        let scripts = [
            (
                "nix",
                r#"#!/bin/sh
set -eu
printf 'nix:%s\n' "$*" >> "$NATIVE_HEALTH_LOG"
case "$*" in
  '--version') printf 'nix (Nix) fixture\n' ;;
  *'.#nixbot.deployDependencies'*) printf '{}\n' ;;
  *'--file '*'hosts.nix'*) cat "$NATIVE_HEALTH_INVENTORY" ;;
  *'.#nixbot.plans --apply builtins.attrNames') printf '["app"]\n' ;;
  *'.#nixbot.plans.app.drvPath') printf '/nix/store/aaaaaaaa-nixos-system-app.drv\n' ;;
  *'.#nixosConfigurations.app.config.boot.isContainer') printf 'true\n' ;;
  'build '*) printf '/nix/store/aaaaaaaa-nixos-system-app\n' ;;
  'copy '*) exit 0 ;;
  *) echo "unexpected nix argv: $*" >&2; exit 91 ;;
esac
"#,
            ),
            (
                "ssh",
                r#"#!/bin/sh
set -eu
printf 'ssh:%s\n' "$*" >> "$NATIVE_HEALTH_LOG"
payload=$(cat)
decoded=$(printf '%s\n' "$payload" | {
  framed=0
  while IFS= read -r line; do
    case "$line" in
      "done <<'NIXBOT_ARGV'") framed=1 ;;
      NIXBOT_ARGV) framed=0 ;;
      *)
        if [ "$framed" = 1 ]; then
          printf '%s' "$line" | base64 -d
          printf '\n'
        fi
        ;;
    esac
  done
})
case "$* $decoded" in
  *'healthcheck_unit()'*)
    printf 'health-collected\n' >> "$NATIVE_HEALTH_LOG"
    cat "$NATIVE_HEALTH_RECORDS"
    ;;
  *) exit 0 ;;
esac
"#,
            ),
        ];
        for (name, script) in scripts {
            let path = tools.join(name);
            let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
            write_executable(
                &path,
                script.replacen("#!/bin/sh", &format!("#!{shell}"), 1),
            )
            .unwrap();
        }
        let path = format!(
            "{}:{}",
            tools.display(),
            std::env::var("PATH").unwrap_or_default()
        );
        let output = Command::new(env!("CARGO_BIN_EXE_abird-host-manager"))
            .current_dir(&repository)
            .args([
                "fleet",
                "deploy",
                "--host",
                "app",
                "--config",
                "hosts.nix",
                "--no-override",
                "--build-host",
                "local",
                "--no-rollback",
                "--force",
                "--verbose",
            ])
            .env("PATH", path)
            .env("ABIRD_HOST_MANAGER_NIX", tools.join("nix"))
            .env("NATIVE_HEALTH_LOG", &log)
            .env("NATIVE_HEALTH_INVENTORY", &inventory_file)
            .env("NATIVE_HEALTH_RECORDS", &health)
            .env("NIXBOT_BUILD_PLAN_CACHE", "0")
            .env("NIXBOT_LOCAL_SELF_TARGET", "off")
            .env(
                "NIXBOT_HOST_LOCAL_LOCK_PATH",
                temporary.path().join("host-local.lock.d"),
            )
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
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.success(),
            expected_success,
            "policy={policy_present} user_failure={user_failure}: {stderr}"
        );
        let effects = fs::read_to_string(&log).unwrap();
        assert_eq!(
            effects
                .lines()
                .filter(|line| *line == "health-collected")
                .count(),
            1,
            "{effects}"
        );
        assert!(effects.contains("root@ssh-alias.invalid"), "{effects}");
        if !policy_present {
            for failure in &system_failures {
                assert!(stderr.contains(failure), "{stderr}");
            }
        }
        if user_failure {
            assert!(stderr.contains("same-name user failure"), "{stderr}");
            assert!(
                stderr.contains("post-switch service health failed"),
                "{stderr}"
            );
        }
    }
}
