#[path = "../src/fleet/deploy.rs"]
mod deploy;
#[path = "../src/test_support.rs"]
mod test_support;
#[allow(dead_code)]
#[path = "../src/fleet/transport.rs"]
mod transport;

use std::collections::VecDeque;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use deploy::{
    ActivationAdmissionMode, ActivationCommand, ActivationExecutor, ActivationGoal,
    ActivationResult, ActivationSample, ActivationStatus, BootEnvironment, CancellationAction,
    CancellationController, DeployDecision, DeployFailureAction, GenerationAdmissionPaths,
    GenerationSnapshot, LockContentionEvidence, SnapshotRequirement, SystemGeneration,
    VerificationDecision, acquire_candidate_lease_command, activation_command,
    activation_verification_command, boot_is_container_command, classify_deploy_failure,
    deploy_unit_name, generation_admission_command, generation_admission_script,
    parent_readiness_commands, pre_activation_image_pull_command,
    pre_activation_model_prefetch_command, pre_switch_preparation_command,
    release_candidate_lease_command, rollback_command, rollback_unit_name, rollback_waves,
    snapshot_command, verify_activation,
};
use test_support::write_executable;

fn generation(name: &str) -> SystemGeneration {
    SystemGeneration::parse(&format!("/nix/store/abc123-nixos-system-{name}")).unwrap()
}

fn assert_bash_syntax(script: &str) {
    let mut child = Command::new("bash")
        .arg("-n")
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(script.as_bytes())
        .unwrap();
    assert!(child.wait().unwrap().success());
}

fn executable(path: &Path, contents: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    write_executable(path, contents).unwrap();
}

fn admission_paths(root: &Path) -> GenerationAdmissionPaths {
    GenerationAdmissionPaths {
        current_system: root.join("current-system").display().to_string(),
        host_agent_config_dir: root.join("live-config").display().to_string(),
        host_agent_state_dir: root.join("live-state").display().to_string(),
        host_agent_runtime_dir: root.join("live-runtime").display().to_string(),
    }
}

fn run_admission(script: &str) -> std::process::Output {
    Command::new("bash").arg("-c").arg(script).output().unwrap()
}

fn run_admission_and_switch(script: &str, switch: &Path) -> std::process::Output {
    Command::new("bash")
        .arg("-c")
        .arg(format!(
            "{script}\nrun_admitted_target_switch \"$TEST_TARGET_SWITCH\""
        ))
        .env("TEST_TARGET_SWITCH", switch)
        .env(
            "ABIRD_HOST_AGENT_CURRENT_SYSTEM",
            "/inherited/current-system",
        )
        .output()
        .unwrap()
}

#[test]
fn snapshots_accept_exactly_one_generation_and_tolerate_warnings() {
    let snapshot = GenerationSnapshot::parse(
        "warning: remote host is busy\n/nix/store/abc123-nixos-system-abird-corp\n",
    )
    .unwrap();
    assert_eq!(
        snapshot.generation().unwrap().as_str(),
        "/nix/store/abc123-nixos-system-abird-corp"
    );

    assert!(GenerationSnapshot::parse("warning only").is_err());
    assert!(
        GenerationSnapshot::parse("/nix/store/abc-nixos-system-a\n/nix/store/def-nixos-system-b\n")
            .is_err()
    );
    assert!(SystemGeneration::parse("/tmp/not-a-generation").is_err());
    assert!(SystemGeneration::parse("/nix/store/a-nixos-system-b extra").is_err());

    assert_eq!(
        snapshot_command(),
        deploy::CommandSpec::new(
            "readlink",
            ["-f".to_owned(), "/run/current-system".to_owned()]
        )
    );
}

#[test]
fn snapshot_policy_skips_matches_and_treats_required_and_optional_missing_differently() {
    let old = generation("old");
    let desired = generation("new");

    assert_eq!(
        GenerationSnapshot::captured(desired.clone()).deploy_decision(
            SnapshotRequirement::Required,
            &desired,
            true,
        ),
        DeployDecision::SkipUnchanged
    );
    assert_eq!(
        GenerationSnapshot::captured(old.clone()).deploy_decision(
            SnapshotRequirement::Required,
            &desired,
            true,
        ),
        DeployDecision::Deploy {
            rollback_generation: Some(old)
        }
    );
    assert_eq!(
        GenerationSnapshot::missing().deploy_decision(
            SnapshotRequirement::Optional,
            &desired,
            true,
        ),
        DeployDecision::SkipOptionalMissing
    );
    assert_eq!(
        GenerationSnapshot::missing().deploy_decision(
            SnapshotRequirement::Required,
            &desired,
            true,
        ),
        DeployDecision::RefuseRequiredMissing
    );
    assert_eq!(
        GenerationSnapshot::not_requested().deploy_decision(
            SnapshotRequirement::Required,
            &desired,
            true,
        ),
        DeployDecision::Deploy {
            rollback_generation: None
        }
    );
    assert!(matches!(
        GenerationSnapshot::captured(desired.clone()).deploy_decision(
            SnapshotRequirement::Required,
            &desired,
            false,
        ),
        DeployDecision::Deploy { .. }
    ));
}

#[test]
fn activation_goals_define_profile_and_bootloader_persistence() {
    assert!(ActivationGoal::Switch.persists_profile());
    assert!(ActivationGoal::Boot.persists_profile());
    assert!(!ActivationGoal::Test.persists_profile());
    assert!(!ActivationGoal::DryActivate.persists_profile());

    assert_eq!(
        ActivationGoal::Switch.post_promote_bootloader_goal(BootEnvironment::Physical),
        Some(ActivationGoal::Boot)
    );
    assert_eq!(
        ActivationGoal::Boot.post_promote_bootloader_goal(BootEnvironment::Physical),
        Some(ActivationGoal::Boot)
    );
    assert_eq!(
        ActivationGoal::Switch.post_promote_bootloader_goal(BootEnvironment::Container),
        None
    );
    assert_eq!(
        ActivationGoal::Test.post_promote_bootloader_goal(BootEnvironment::Physical),
        None
    );
    assert_eq!(ActivationGoal::DryActivate.as_str(), "dry-activate");
}

#[test]
fn boot_container_probe_is_a_strict_read_only_flake_evaluation() {
    let command = boot_is_container_command(
        "nix",
        &["--option".into(), "eval-cache".into(), "false".into()],
        "proxy-target",
    );
    assert_eq!(command.program, "nix");
    assert_eq!(command.args[0], "eval");
    assert!(
        command
            .args
            .windows(2)
            .any(|pair| pair == ["--json", "--no-write-lock-file"])
    );
    assert_eq!(
        command.args.last().unwrap(),
        ".#nixosConfigurations.proxy-target.config.boot.isContainer"
    );
    assert_eq!(
        BootEnvironment::parse_nix_json("true\n").unwrap(),
        BootEnvironment::Container
    );
    assert_eq!(
        BootEnvironment::parse_nix_json("false").unwrap(),
        BootEnvironment::Physical
    );
    assert!(BootEnvironment::parse_nix_json("null").is_err());
}

#[test]
fn unit_names_are_stable_sanitized_and_attempt_scoped() {
    assert_eq!(
        deploy_unit_name("/tmp/run-2026_09.05 bad", "root@gap3", 1),
        "nixbot-switch-to-configuration-2026_09.05-bad-f82ddb6430d35e3d"
    );
    assert_eq!(
        deploy_unit_name("/tmp/run-2026_09.05 bad", "root@gap3", 3),
        "nixbot-switch-to-configuration-2026_09.05-bad-f82ddb6430d35e3d-retry3"
    );
    assert_eq!(
        rollback_unit_name("/tmp/run-2026_09.05 bad", "root@gap3"),
        "nixbot-rollback-to-configuration-2026_09.05-bad-f82ddb6430d35e3d"
    );
}

#[test]
fn pre_switch_preparation_resets_failed_state_repairs_user_managers_and_reports_failures() {
    let command = pre_switch_preparation_command();
    assert_eq!(command.program, "/run/current-system/sw/bin/bash");
    assert!(command.script.contains("systemctl reset-failed"));
    assert!(command.script.contains("loginctl list-users"));
    assert!(command.script.contains("systemctl --user show-environment"));
    assert!(
        command
            .script
            .contains("systemctl --user list-units --failed")
    );
    assert!(command.script.contains("Pre-switch checks failed"));
    assert_bash_syntax(&command.script);
}

#[test]
fn activation_is_a_supervised_detached_attempt_with_an_authoritative_marker() {
    let command = activation_command(ActivationCommand {
        run_id: "run-42".into(),
        host: "gap3".into(),
        attempt: 2,
        generation: generation("new"),
        goal: ActivationGoal::Switch,
        boot_environment: BootEnvironment::Physical,
        restart_managed: true,
        runtime_max: Duration::from_secs(1800),
        stop_timeout: Duration::from_secs(120),
        lock_wait: Duration::from_secs(900),
        acquire_host_lock: true,
    });

    assert_eq!(command.program, "systemd-run");
    assert_eq!(
        command.unit,
        "nixbot-switch-to-configuration-42-c16fc90f3a2862ea-retry2"
    );
    for expected in [
        "--no-block",
        "--collect",
        "--no-ask-password",
        "--service-type=exec",
        "--property=RuntimeMaxSec=1800s",
        "--property=TimeoutStopSec=120s",
        "--property=KillMode=control-group",
        "--property=CollectMode=inactive-or-failed",
    ] {
        assert!(
            command.args.iter().any(|arg| arg == expected),
            "missing {expected}"
        );
    }
    assert!(command.script.contains("Result=running"));
    assert!(command.script.contains("OutcomeSource=marker"));
    assert!(command.script.contains("NIXOS_INSTALL_BOOTLOADER=0"));
    assert!(command.script.contains(
        "NIXOS_INSTALL_BOOTLOADER=0 run_admitted_target_switch /nix/store/abc123-nixos-system-new/bin/switch-to-configuration switch"
    ));
    assert!(!command.script.contains("run_admitted_target_switch env "));
    assert!(command.script.contains("switch-to-configuration switch"));
    assert!(command.script.contains("/nix/var/nix/profiles/system"));
    assert!(command.script.contains("NIXOS_INSTALL_BOOTLOADER=1"));
    assert!(command.script.contains("switch-to-configuration boot"));
    assert!(command.script.contains("podman-composectl"));
    assert!(command.script.contains("restart-managed"));
    assert!(command.script.contains("admission_mode=normal"));
    assert!(
        command
            .script
            .contains("abird-host-agent-generation-preflight")
    );
    assert!(command.script.contains("flock -w 900"));
    assert!(command.script.contains("/dev/shm/nixbot-host-local.lock.d"));
    assert!(command.script.contains("/run/current-system/sw/bin/bash"));
    assert_eq!(
        command.environment,
        vec![("NIXOS_INSTALL_BOOTLOADER".into(), "0".into())]
    );
    let observer = command.observer_script.as_deref().unwrap();
    assert!(observer.contains("activation-results"));
    assert!(observer.contains("ExecMainStatus"));
    assert!(observer.contains("--pid=\"$main_pid\" --lines=+1 --follow=name"));
    assert!(observer.contains("while [ ! -e \"$log_file\" ]"));
    assert!(observer.contains("A log follower is observational, never activation authority"));
    assert!(observer.contains("Catch the PID-exit/log-flush race"));
    assert!(
        observer.find("--follow=name").unwrap() < observer.rfind("read_result || true").unwrap()
    );
    assert_bash_syntax(&command.script);
    assert_bash_syntax(observer);
}

#[test]
fn activation_observer_streams_log_before_the_authoritative_result_is_terminal() {
    let command = activation_command(ActivationCommand {
        run_id: "live-output".into(),
        host: "gap3".into(),
        attempt: 1,
        generation: generation("new"),
        goal: ActivationGoal::Switch,
        boot_environment: BootEnvironment::Physical,
        restart_managed: false,
        runtime_max: Duration::from_secs(5),
        stop_timeout: Duration::from_secs(1),
        lock_wait: Duration::from_secs(1),
        acquire_host_lock: true,
    });
    let temporary = tempfile::tempdir().unwrap();
    let result = temporary.path().join("activation.result");
    let log = temporary.path().join("activation.log");
    fs::write(
        &result,
        "OutcomeSource=marker\nResult=running\nExecMainStatus=255\nAdmitted=1\n",
    )
    .unwrap();
    fs::write(&log, "first-line\n").unwrap();

    let fake_systemctl = temporary.path().join("systemctl");
    executable(
        &fake_systemctl,
        r#"#!/bin/sh
case "$*" in
  *--property=MainPID*) printf '%s\n' "$TEST_MAIN_PID" ;;
  *--property=Job*) printf '\n' ;;
  *--property=LoadState*) printf 'loaded\n' ;;
  *--property=ActiveState*) printf 'active\n' ;;
esac
"#,
    );

    let mut writer = Command::new("bash")
        .arg("-c")
        .arg(format!(
            "sleep 0.5; printf 'final-line\\n' >> '{}'; printf 'OutcomeSource=marker\\nResult=success\\nExecMainStatus=0\\nAdmitted=1\\n' > '{}'",
            log.display(),
            result.display()
        ))
        .spawn()
        .unwrap();

    let tool = |name: &str| {
        String::from_utf8(
            Command::new("sh")
                .args(["-c", &format!("command -v {name}")])
                .output()
                .unwrap()
                .stdout,
        )
        .unwrap()
        .trim()
        .to_owned()
    };
    let observer = command
        .observer_script
        .unwrap()
        .replace(
            &format!("/var/lib/nixbot/activation-results/{}.result", command.unit),
            &result.display().to_string(),
        )
        .replace(
            &format!("/var/lib/nixbot/activation-results/{}.log", command.unit),
            &log.display().to_string(),
        )
        .replace(
            "/run/current-system/sw/bin/systemctl",
            &fake_systemctl.display().to_string(),
        )
        .replace("/run/current-system/sw/bin/tail", &tool("tail"))
        .replace("/run/current-system/sw/bin/sleep", &tool("sleep"))
        .replace("/run/current-system/sw/bin/cat", &tool("cat"));
    let mut observer = Command::new("bash")
        .arg("-c")
        .arg(observer)
        .env("TEST_MAIN_PID", writer.id().to_string())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stdout = observer.stdout.take().unwrap();
    let (sender, receiver) = std::sync::mpsc::channel();
    let reader = std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            sender.send(line.unwrap()).unwrap();
        }
    });

    assert_eq!(
        receiver.recv_timeout(Duration::from_secs(2)).unwrap(),
        "first-line"
    );
    assert!(observer.try_wait().unwrap().is_none());
    assert!(writer.wait().unwrap().success());
    assert_eq!(
        receiver.recv_timeout(Duration::from_secs(3)).unwrap(),
        "final-line"
    );
    let status = observer.wait().unwrap();
    reader.join().unwrap();
    let mut stderr = String::new();
    observer
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut stderr)
        .unwrap();
    assert!(status.success(), "{stderr}");
    assert!(stderr.contains("Result=success"));
    assert!(stderr.contains("ExecMainStatus=0"));
}

#[test]
fn activation_observer_keeps_polling_when_the_log_follower_fails() {
    let command = activation_command(ActivationCommand {
        run_id: "failed-log-follower".into(),
        host: "gap3".into(),
        attempt: 1,
        generation: generation("new"),
        goal: ActivationGoal::Switch,
        boot_environment: BootEnvironment::Physical,
        restart_managed: false,
        runtime_max: Duration::from_secs(5),
        stop_timeout: Duration::from_secs(1),
        lock_wait: Duration::from_secs(1),
        acquire_host_lock: true,
    });
    let temporary = tempfile::tempdir().unwrap();
    let result = temporary.path().join("activation.result");
    let log = temporary.path().join("activation.log");
    fs::write(
        &result,
        "OutcomeSource=marker\nResult=running\nExecMainStatus=255\nAdmitted=1\n",
    )
    .unwrap();
    fs::write(&log, "first-line\n").unwrap();

    let fake_systemctl = temporary.path().join("systemctl");
    executable(
        &fake_systemctl,
        r#"#!/bin/sh
case "$*" in
  *--property=MainPID*) printf '%s\n' "$TEST_MAIN_PID" ;;
  *--property=Job*) printf '\n' ;;
  *--property=LoadState*) printf 'loaded\n' ;;
  *--property=ActiveState*) printf 'active\n' ;;
esac
"#,
    );
    let fake_tail = temporary.path().join("tail");
    executable(&fake_tail, "#!/bin/sh\nexit 42\n");

    let mut writer = Command::new("bash")
        .arg("-c")
        .arg(format!(
            "sleep 0.5; printf 'final-line\\n' >> '{}'; printf 'OutcomeSource=marker\\nResult=success\\nExecMainStatus=0\\nAdmitted=1\\n' > '{}'",
            log.display(),
            result.display()
        ))
        .spawn()
        .unwrap();
    let sleep = String::from_utf8(
        Command::new("sh")
            .args(["-c", "command -v sleep"])
            .output()
            .unwrap()
            .stdout,
    )
    .unwrap();
    let observer_script = command
        .observer_script
        .unwrap()
        .replace(
            &format!("/var/lib/nixbot/activation-results/{}.result", command.unit),
            &result.display().to_string(),
        )
        .replace(
            &format!("/var/lib/nixbot/activation-results/{}.log", command.unit),
            &log.display().to_string(),
        )
        .replace(
            "/run/current-system/sw/bin/systemctl",
            &fake_systemctl.display().to_string(),
        )
        .replace(
            "/run/current-system/sw/bin/tail",
            &fake_tail.display().to_string(),
        )
        .replace("/run/current-system/sw/bin/sleep", sleep.trim());
    let mut observer = Command::new("bash")
        .arg("-c")
        .arg(observer_script)
        .env("TEST_MAIN_PID", writer.id().to_string())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    std::thread::sleep(Duration::from_millis(150));
    assert!(observer.try_wait().unwrap().is_none());
    assert!(writer.wait().unwrap().success());
    let output = observer.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .collect::<Vec<_>>(),
        vec!["first-line", "final-line"]
    );
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("Result=success"));
    assert!(stderr.contains("ExecMainStatus=0"));
}

#[test]
fn self_target_activation_reuses_the_controller_action_mutex() {
    let command = activation_command(ActivationCommand {
        run_id: "run-self".into(),
        host: "pvl-l5".into(),
        attempt: 1,
        generation: generation("new"),
        goal: ActivationGoal::Switch,
        boot_environment: BootEnvironment::Physical,
        restart_managed: false,
        runtime_max: Duration::from_secs(60),
        stop_timeout: Duration::from_secs(10),
        lock_wait: Duration::from_secs(30),
        acquire_host_lock: false,
    });

    assert!(!command.script.contains("flock -w"));
    assert!(command.script.contains("Admitted=0"));
    assert!(command.script.contains("Admitted=1"));
    assert!(command.script.contains("switch-to-configuration switch"));
    assert_bash_syntax(&command.script);
}

#[test]
fn test_activation_does_not_persist_or_touch_the_bootloader_or_managed_services() {
    let command = activation_command(ActivationCommand {
        run_id: "r".into(),
        host: "h".into(),
        attempt: 1,
        generation: generation("test"),
        goal: ActivationGoal::Test,
        boot_environment: BootEnvironment::Physical,
        restart_managed: false,
        runtime_max: Duration::from_secs(10),
        stop_timeout: Duration::from_secs(2),
        lock_wait: Duration::from_secs(3),
        acquire_host_lock: true,
    });
    assert!(command.script.contains("switch-to-configuration test"));
    assert!(!command.script.contains("nix-env"));
    assert!(!command.script.contains("NIXOS_INSTALL_BOOTLOADER=1"));
    assert!(!command.script.contains("restart-managed"));
}

#[test]
fn rollback_is_switch_activation_with_projection_admission_and_profile_persistence() {
    let command = rollback_command(
        "run-42",
        "gap3",
        generation("old"),
        BootEnvironment::Container,
        Duration::from_secs(90),
        Duration::from_secs(10),
        Duration::from_secs(30),
        true,
    );
    assert_eq!(command.program, "systemd-run");
    assert!(
        command
            .unit
            .starts_with("nixbot-rollback-to-configuration-")
    );
    assert!(
        command
            .script
            .contains("abird-host-agent-generation-preflight")
    );
    assert!(command.script.contains("admission_mode=rollback"));
    assert!(command.script.contains(" rollback"));
    assert!(command.script.contains("switch-to-configuration switch"));
    assert!(command.script.contains(
        "NIXOS_INSTALL_BOOTLOADER=0 run_admitted_target_switch /nix/store/abc123-nixos-system-old/bin/switch-to-configuration switch"
    ));
    assert!(!command.script.contains("run_admitted_target_switch env "));
    assert!(command.script.contains("/nix/var/nix/profiles/system"));
    assert!(!command.script.contains("NIXOS_INSTALL_BOOTLOADER=1"));
    assert!(!command.script.contains("restart-managed"));
    assert_bash_syntax(&command.script);
}

#[test]
fn generation_dispatcher_owns_normal_and_rollback_admission() {
    for mode in [
        ActivationAdmissionMode::Normal,
        ActivationAdmissionMode::Rollback,
    ] {
        for status in [0, 23, 255] {
            let temporary = tempfile::tempdir().unwrap();
            let paths = admission_paths(temporary.path());
            let current = PathBuf::from(&paths.current_system);
            let target = temporary.path().join("target-system");
            let calls = temporary.path().join("calls");
            fs::create_dir_all(&current).unwrap();
            executable(
                &current.join("sw/bin/abird-host-agent-generation-preflight"),
                &format!(
                    "#!/bin/sh\nprintf '{{\"ok\":true}}\\n'\nprintf '%s|%s\\n' \"${{ABIRD_HOST_AGENT_GENERATION_PREFLIGHT_OUTPUT-<unset>}}\" \"$*\" > {}\nexit {status}\n",
                    calls.display()
                ),
            );
            let script = generation_admission_script(
                &target.display().to_string(),
                ActivationGoal::Switch,
                mode,
                &paths,
            );
            let output = run_admission(&script);
            assert_eq!(output.status.code(), Some(status));
            assert_eq!(
                fs::read_to_string(&calls).unwrap(),
                format!(
                    "quiet|{} switch {}\n",
                    target.display(),
                    match mode {
                        ActivationAdmissionMode::Normal => "normal",
                        ActivationAdmissionMode::Rollback => "rollback",
                    }
                )
            );
            if status == 0 {
                assert!(output.stdout.is_empty());
                assert!(String::from_utf8_lossy(&output.stderr).contains(&format!(
                    "[generation-admission] mode={} admitted {}",
                    match mode {
                        ActivationAdmissionMode::Normal => "normal",
                        ActivationAdmissionMode::Rollback => "rollback",
                    },
                    target.display()
                )));
                assert!(!String::from_utf8_lossy(&output.stderr).contains("{\"ok\":true}"));
                assert!(
                    !String::from_utf8_lossy(&output.stderr).contains("rejected-before-switch")
                );
            } else {
                assert!(output.stdout.is_empty());
                assert!(String::from_utf8_lossy(&output.stderr).contains("{\"ok\":true}"));
                assert!(
                    String::from_utf8_lossy(&output.stderr)
                        .contains("[generation-admission] rejected-before-switch")
                );
            }
        }
    }
}

#[test]
fn rollback_uses_target_as_legacy_current_only_after_current_dispatcher_accepts_it() {
    let temporary = tempfile::tempdir().unwrap();
    let paths = admission_paths(temporary.path());
    let current = PathBuf::from(&paths.current_system);
    let target = temporary.path().join("target-system");
    let observed = temporary.path().join("observed-current-system");
    let switch = temporary.path().join("switch-to-configuration");
    executable(
        &current.join("sw/bin/abird-host-agent-generation-preflight"),
        "#!/bin/sh\nexit 0\n",
    );
    executable(
        &switch,
        &format!(
            "#!/bin/sh\nprintf '%s\\n' \"${{ABIRD_HOST_AGENT_CURRENT_SYSTEM-<unset>}}\" > {}\n",
            observed.display()
        ),
    );

    let rollback = generation_admission_script(
        &target.display().to_string(),
        ActivationGoal::Switch,
        ActivationAdmissionMode::Rollback,
        &paths,
    );
    assert!(
        run_admission_and_switch(&rollback, &switch)
            .status
            .success()
    );
    assert_eq!(
        fs::read_to_string(&observed).unwrap(),
        format!("{}\n", target.display())
    );

    let normal = generation_admission_script(
        &target.display().to_string(),
        ActivationGoal::Switch,
        ActivationAdmissionMode::Normal,
        &paths,
    );
    assert!(run_admission_and_switch(&normal, &switch).status.success());
    assert_eq!(fs::read_to_string(&observed).unwrap(), "<unset>\n");

    for (interface_index, relative) in [
        "sw/bin/abird-host-agent-generation-preflight",
        "etc/abird-host-agent/generation-admission-registry.json",
    ]
    .into_iter()
    .enumerate()
    {
        for evidence_kind in ["file", "directory", "dangling-symlink"] {
            let modern_target = temporary
                .path()
                .join(format!("modern-target-{interface_index}-{evidence_kind}"));
            let evidence = modern_target.join(relative);
            fs::create_dir_all(evidence.parent().unwrap()).unwrap();
            match evidence_kind {
                "file" => fs::write(&evidence, "interface evidence\n").unwrap(),
                "directory" => fs::create_dir(&evidence).unwrap(),
                "dangling-symlink" => {
                    std::os::unix::fs::symlink(
                        temporary.path().join("missing-interface"),
                        &evidence,
                    )
                    .unwrap();
                }
                _ => unreachable!(),
            }
            let modern_rollback = generation_admission_script(
                &modern_target.display().to_string(),
                ActivationGoal::Switch,
                ActivationAdmissionMode::Rollback,
                &paths,
            );
            assert!(
                run_admission_and_switch(&modern_rollback, &switch)
                    .status
                    .success(),
                "{relative} represented by {evidence_kind}"
            );
            assert_eq!(
                fs::read_to_string(&observed).unwrap(),
                "<unset>\n",
                "{relative} represented by {evidence_kind}"
            );
        }
    }
}

#[test]
fn admitted_switch_does_not_require_path_to_export_activation_environment() {
    let temporary = tempfile::tempdir().unwrap();
    let paths = admission_paths(temporary.path());
    let current = PathBuf::from(&paths.current_system);
    let target = temporary.path().join("target-system");
    let observed = temporary.path().join("activation-environment");
    let switch = temporary.path().join("switch-to-configuration");
    executable(
        &current.join("sw/bin/abird-host-agent-generation-preflight"),
        "#!/bin/sh\nexit 0\n",
    );
    executable(
        &switch,
        &format!(
            "#!/bin/sh\nprintf '%s|%s\\n' \"${{NIXOS_INSTALL_BOOTLOADER-<unset>}}\" \"${{ABIRD_HOST_AGENT_CURRENT_SYSTEM-<unset>}}\" > {}\n",
            observed.display()
        ),
    );
    let bash = String::from_utf8(
        Command::new("sh")
            .args(["-c", "command -v bash"])
            .output()
            .unwrap()
            .stdout,
    )
    .unwrap();

    for (mode, expected_current) in [
        (ActivationAdmissionMode::Normal, "<unset>".to_owned()),
        (
            ActivationAdmissionMode::Rollback,
            target.display().to_string(),
        ),
    ] {
        let script = format!(
            "{}\nNIXOS_INSTALL_BOOTLOADER=0 run_admitted_target_switch \"$TEST_TARGET_SWITCH\" switch",
            generation_admission_script(
                &target.display().to_string(),
                ActivationGoal::Switch,
                mode,
                &paths,
            )
        );
        let output = Command::new(bash.trim())
            .arg("-c")
            .arg(script)
            .env("PATH", "/path/that/does/not/exist")
            .env("TEST_TARGET_SWITCH", &switch)
            .env(
                "ABIRD_HOST_AGENT_CURRENT_SYSTEM",
                "/inherited/current-system",
            )
            .output()
            .unwrap();
        assert!(output.status.success(), "mode={mode:?}: {output:?}");
        assert_eq!(
            fs::read_to_string(&observed).unwrap(),
            format!("0|{expected_current}\n")
        );
    }
}

#[test]
fn rejected_current_dispatcher_never_runs_the_target_switch() {
    let temporary = tempfile::tempdir().unwrap();
    let paths = admission_paths(temporary.path());
    let current = PathBuf::from(&paths.current_system);
    let target = temporary.path().join("target-system");
    let switched = temporary.path().join("switched");
    let switch = temporary.path().join("switch-to-configuration");
    executable(
        &current.join("sw/bin/abird-host-agent-generation-preflight"),
        "#!/bin/sh\nexit 23\n",
    );
    executable(
        &switch,
        &format!("#!/bin/sh\ntouch {}\n", switched.display()),
    );
    let rollback = generation_admission_script(
        &target.display().to_string(),
        ActivationGoal::Switch,
        ActivationAdmissionMode::Rollback,
        &paths,
    );
    let output = run_admission_and_switch(&rollback, &switch);
    assert_eq!(output.status.code(), Some(23));
    assert!(!switched.exists());
    assert!(String::from_utf8_lossy(&output.stderr).contains("rejected-before-switch"));
}

#[test]
fn legacy_current_validators_do_not_enable_the_legacy_target_override() {
    let temporary = tempfile::tempdir().unwrap();
    let paths = admission_paths(temporary.path());
    let current = PathBuf::from(&paths.current_system);
    let target = temporary.path().join("target-system");
    let observed = temporary.path().join("observed-current-system");
    let switch = temporary.path().join("switch-to-configuration");
    executable(
        &current.join("sw/bin/abird-host-agent-service-placement-preflight"),
        "#!/bin/sh\nexit 0\n",
    );
    executable(
        &current.join("sw/bin/abird-host-agent-projection-preflight"),
        "#!/bin/sh\nexit 0\n",
    );
    executable(
        &switch,
        &format!(
            "#!/bin/sh\nprintf '%s\\n' \"${{ABIRD_HOST_AGENT_CURRENT_SYSTEM-<unset>}}\" > {}\n",
            observed.display()
        ),
    );
    let rollback = generation_admission_script(
        &target.display().to_string(),
        ActivationGoal::Switch,
        ActivationAdmissionMode::Rollback,
        &paths,
    );
    assert!(
        run_admission_and_switch(&rollback, &switch)
            .status
            .success()
    );
    assert_eq!(fs::read_to_string(observed).unwrap(), "<unset>\n");
}

#[test]
fn rollback_admission_allows_only_truly_unmanaged_hosts_without_a_dispatcher() {
    let temporary = tempfile::tempdir().unwrap();
    let paths = admission_paths(temporary.path());
    let current = PathBuf::from(&paths.current_system);
    let target = temporary.path().join("target-system");
    fs::create_dir_all(&current).unwrap();
    let script = generation_admission_script(
        &target.display().to_string(),
        ActivationGoal::Switch,
        ActivationAdmissionMode::Rollback,
        &paths,
    );
    let unmanaged = run_admission(&script);
    assert!(unmanaged.status.success());
    assert!(
        String::from_utf8_lossy(&unmanaged.stderr).contains("no host-agent authority or state")
    );
    assert!(!String::from_utf8_lossy(&unmanaged.stderr).contains(" admitted "));

    fs::remove_dir(&current).unwrap();
    let missing_current = run_admission(&script);
    assert!(!missing_current.status.success());
    assert!(
        String::from_utf8_lossy(&missing_current.stderr)
            .contains("current generation is unavailable")
    );

    fs::create_dir_all(&current).unwrap();
    let evidence = target.join("sw/bin/abird-host-agent-projection-preflight");
    fs::create_dir_all(evidence.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(temporary.path().join("missing"), &evidence).unwrap();
    let retained = run_admission(&script);
    assert!(!retained.status.success());
    assert!(String::from_utf8_lossy(&retained.stderr).contains("rejected-before-switch"));
}

#[test]
fn rollback_never_uses_the_target_generation_dispatcher() {
    let temporary = tempfile::tempdir().unwrap();
    let paths = admission_paths(temporary.path());
    let current = PathBuf::from(&paths.current_system);
    let target = temporary.path().join("target-system");
    let marker = temporary.path().join("target-dispatcher-ran");
    fs::create_dir_all(&current).unwrap();
    executable(
        &target.join("sw/bin/abird-host-agent-generation-preflight"),
        &format!("#!/bin/sh\ntouch {}\n", marker.display()),
    );
    let script = generation_admission_script(
        &target.display().to_string(),
        ActivationGoal::Switch,
        ActivationAdmissionMode::Rollback,
        &paths,
    );
    let output = run_admission(&script);
    assert!(!output.status.success());
    assert!(!marker.exists());
    assert!(String::from_utf8_lossy(&output.stderr).contains("current dispatcher is unavailable"));
}

#[test]
fn legacy_rollback_fails_closed_when_placement_evidence_lacks_a_validator() {
    let temporary = tempfile::tempdir().unwrap();
    let paths = admission_paths(temporary.path());
    let current = PathBuf::from(&paths.current_system);
    let target = temporary.path().join("target-system");
    let marker = temporary.path().join("projection-ran");
    fs::create_dir_all(&current).unwrap();
    executable(
        &current.join("sw/bin/abird-host-agent-projection-preflight"),
        &format!("#!/bin/sh\ntouch {}\n", marker.display()),
    );
    let placement_contract =
        PathBuf::from(&paths.host_agent_config_dir).join("service-placement-contract.json");
    fs::create_dir_all(placement_contract.parent().unwrap()).unwrap();
    fs::write(&placement_contract, "{}\n").unwrap();
    let script = generation_admission_script(
        &target.display().to_string(),
        ActivationGoal::Switch,
        ActivationAdmissionMode::Rollback,
        &paths,
    );
    let output = run_admission(&script);
    assert!(!output.status.success());
    assert!(!marker.exists());
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("current placement validator is unavailable")
    );
}

#[test]
fn legacy_rollback_admission_preserves_current_authority_and_rejects_broken_interfaces() {
    let temporary = tempfile::tempdir().unwrap();
    let paths = admission_paths(temporary.path());
    let current = PathBuf::from(&paths.current_system);
    let target = temporary.path().join("target-system");
    let calls = temporary.path().join("calls");
    fs::create_dir_all(&current).unwrap();
    executable(
        &current.join("sw/bin/abird-host-agent-service-placement-preflight"),
        &format!(
            "#!/bin/sh\nprintf 'placement:%s\\n' \"$*\" >> {}\n",
            calls.display()
        ),
    );
    executable(
        &current.join("sw/bin/abird-host-agent-projection-preflight"),
        &format!(
            "#!/bin/sh\nprintf 'projection:%s\\n' \"$*\" >> {}\n",
            calls.display()
        ),
    );
    let rollback = generation_admission_script(
        &target.display().to_string(),
        ActivationGoal::Switch,
        ActivationAdmissionMode::Rollback,
        &paths,
    );
    assert!(run_admission(&rollback).status.success());
    assert_eq!(
        fs::read_to_string(&calls).unwrap(),
        format!(
            "placement:{} switch rollback\nprojection:{} switch rollback\n",
            target.display(),
            target.display()
        )
    );

    let normal_target = temporary.path().join("new-target");
    fs::create_dir_all(normal_target.join("etc/abird-host-agent")).unwrap();
    fs::write(
        normal_target.join("etc/abird-host-agent/generation-admission-registry.json"),
        "{}\n",
    )
    .unwrap();
    let normal = generation_admission_script(
        &normal_target.display().to_string(),
        ActivationGoal::Switch,
        ActivationAdmissionMode::Normal,
        &paths,
    );
    assert!(run_admission(&normal).status.success());

    fs::create_dir_all(current.join("etc/abird-host-agent")).unwrap();
    fs::write(
        current.join("etc/abird-host-agent/generation-admission-registry.json"),
        "{}\n",
    )
    .unwrap();
    let broken = run_admission(&normal);
    assert!(!broken.status.success());
    assert!(String::from_utf8_lossy(&broken.stderr).contains("rejected-before-switch"));
}

#[test]
fn rollback_reverses_dependency_waves_but_preserves_order_within_each_wave() {
    let levels = vec![
        vec!["parent-a".to_owned(), "parent-b".to_owned()],
        vec!["child-a".to_owned(), "child-b".to_owned()],
    ];
    assert_eq!(
        rollback_waves(&levels),
        vec![levels[1].clone(), levels[0].clone()]
    );
}

fn sample(text: &str) -> ActivationSample {
    ActivationSample::parse(text).unwrap()
}

#[test]
fn transport_verification_requires_authority_target_state_and_profile_when_persistent() {
    let target = generation("new");
    let success = sample(
        "OutcomeSource=marker\nResult=success\nExecMainStatus=0\nCurrentSystemPath=/nix/store/abc123-nixos-system-new\nSystemProfilePath=/nix/store/abc123-nixos-system-new\n",
    );
    assert_eq!(
        verify_activation(&success, &target, ActivationGoal::Switch),
        VerificationDecision::Succeeded
    );

    let wrong_profile = sample(
        "OutcomeSource=marker\nResult=success\nExecMainStatus=0\nCurrentSystemPath=/nix/store/abc123-nixos-system-new\nSystemProfilePath=/nix/store/abc123-nixos-system-old\n",
    );
    assert!(matches!(
        verify_activation(&wrong_profile, &target, ActivationGoal::Switch),
        VerificationDecision::Failed(_)
    ));
    assert_eq!(
        verify_activation(&wrong_profile, &target, ActivationGoal::Test),
        VerificationDecision::Succeeded
    );

    let running = sample(
        "OutcomeSource=marker\nResult=running\nExecMainStatus=255\nCurrentSystemPath=/nix/store/abc123-nixos-system-new\n",
    );
    assert_eq!(
        verify_activation(&running, &target, ActivationGoal::Switch),
        VerificationDecision::Pending
    );

    let unauthoritative = sample(
        "ActiveState=inactive\nResult=success\nExecMainStatus=0\nCurrentSystemPath=/nix/store/abc123-nixos-system-new\nSystemProfilePath=/nix/store/abc123-nixos-system-new\n",
    );
    assert_eq!(
        verify_activation(&unauthoritative, &target, ActivationGoal::Switch),
        VerificationDecision::Pending
    );

    let probe = activation_verification_command("nixbot-switch-to-configuration-run-host");
    assert!(probe.script.contains("/run/current-system"));
    assert!(probe.script.contains("/nix/var/nix/profiles/system"));
    assert!(probe.script.contains("/var/lib/nixbot/activation-results"));
    assert!(probe.script.contains("systemctl show"));
}

#[test]
fn settled_failed_activation_never_becomes_success_just_because_current_system_changed() {
    let failed = sample(
        "OutcomeSource=marker\nResult=exit-code\nExecMainStatus=1\nCurrentSystemPath=/nix/store/abc123-nixos-system-new\nSystemProfilePath=/nix/store/abc123-nixos-system-new\n",
    );
    assert!(matches!(
        verify_activation(&failed, &generation("new"), ActivationGoal::Switch),
        VerificationDecision::Failed(_)
    ));
}

#[test]
fn activation_samples_reject_duplicate_or_malformed_authoritative_fields() {
    assert!(ActivationSample::parse("Result=success\nResult=exit-code\n").is_err());
    assert!(ActivationSample::parse("OutcomeSource=marker\nExecMainStatus=nope\n").is_err());
    assert!(ActivationSample::parse("OutcomeSource=other\n").is_err());
    assert!(ActivationSample::parse("Admitted=maybe\n").is_err());
    assert_eq!(
        ActivationSample::parse("OutcomeSource=marker\nAdmitted=0\n")
            .unwrap()
            .admitted,
        Some(false)
    );
}

#[test]
fn activation_observer_marker_is_framed_complete_and_uses_the_last_frame() {
    let sample = ActivationSample::parse_observer_marker(
        "Admitted=0\n--- abird-activation-result begin ---\nOutcomeSource=marker\nResult=exit-code\nExecMainStatus=1\nAdmitted=1\n--- abird-activation-result end ---\n",
    )
    .unwrap();
    assert_eq!(sample.admitted, Some(true));
    assert!(ActivationSample::parse_observer_marker("Admitted=0\n").is_err());
    assert!(ActivationSample::parse_observer_marker(
        "--- abird-activation-result begin ---\nOutcomeSource=marker\nAdmitted=0\n--- abird-activation-result end ---\n"
    )
    .is_err());
}

#[test]
fn deploy_failure_interpretation_preserves_signals_and_activation_boundaries() {
    assert_eq!(
        classify_deploy_failure(130, "", false, 1, 3),
        DeployFailureAction::ReturnSignal(130)
    );
    assert_eq!(
        classify_deploy_failure(1, "Pre-switch checks failed: projection", false, 1, 3),
        DeployFailureAction::RejectBeforeSwitch
    );
    assert_eq!(
        classify_deploy_failure(
            23,
            "[generation-admission] rejected-before-switch",
            true,
            1,
            3
        ),
        DeployFailureAction::RejectBeforeSwitch
    );
    assert_eq!(
        classify_deploy_failure(
            255,
            "ssh: connect to host h port 22: Connection refused",
            false,
            1,
            3
        ),
        DeployFailureAction::RetryBeforeAdmission { next_attempt: 2 }
    );
    assert_eq!(
        classify_deploy_failure(
            255,
            "ssh: connect to host h port 22: Connection refused",
            false,
            3,
            3
        ),
        DeployFailureAction::Fail(255)
    );
    assert_eq!(
        classify_deploy_failure(255, "Connection reset by peer", true, 1, 3),
        DeployFailureAction::VerifyTarget
    );
    assert_eq!(
        classify_deploy_failure(
            1,
            "Offending configuration option ignored\nssh: connect to host h port 22: Connection refused",
            false,
            1,
            3
        ),
        DeployFailureAction::RetryBeforeAdmission { next_attempt: 2 }
    );
    assert_eq!(
        classify_deploy_failure(1, "Connection closed by z.gap3.ai port 22", true, 1, 3),
        DeployFailureAction::VerifyTarget
    );
    assert_eq!(
        classify_deploy_failure(124, "", true, 1, 3),
        DeployFailureAction::VerifyTarget
    );
    assert_eq!(
        classify_deploy_failure(1, "switch failed", true, 1, 3),
        DeployFailureAction::Fail(1)
    );
}

#[test]
fn lock_contention_evidence_combines_direct_output_and_retained_journal() {
    let direct = LockContentionEvidence::inspect(
        "Could not acquire lock /run/nixos/switch-to-configuration.lock",
        "",
    );
    assert!(direct.detected());
    assert!(direct.force_report());

    let journal = LockContentionEvidence::inspect(
        "activation failed",
        "Creating lock file /run/nixos/switch-to-configuration.lock",
    );
    assert!(journal.detected());
    assert!(!journal.force_report());
    assert!(!LockContentionEvidence::inspect("activation failed", "unrelated").detected());
}

#[test]
fn forced_cancellation_stops_waits_only_to_deadline_then_kills_running_units() {
    let mut cancellation = CancellationController::new(Duration::from_secs(3));
    assert_eq!(
        cancellation.next_action(Duration::ZERO, true),
        CancellationAction::Stop
    );
    assert_eq!(
        cancellation.next_action(Duration::from_secs(1), true),
        CancellationAction::Wait(Duration::from_secs(1))
    );
    assert_eq!(
        cancellation.next_action(Duration::from_secs(3), true),
        CancellationAction::Kill
    );
    assert_eq!(
        cancellation.next_action(Duration::from_secs(4), true),
        CancellationAction::Complete
    );

    let mut settled = CancellationController::new(Duration::from_secs(10));
    assert_eq!(
        settled.next_action(Duration::ZERO, true),
        CancellationAction::Stop
    );
    assert_eq!(
        settled.next_action(Duration::from_secs(1), false),
        CancellationAction::Complete
    );
}

#[derive(Default)]
struct FakeExecutor {
    results: VecDeque<ActivationResult>,
    units: Vec<String>,
}

impl ActivationExecutor for FakeExecutor {
    fn execute(&mut self, command: &deploy::RemoteCommand) -> ActivationResult {
        self.units.push(command.unit.clone());
        self.results.pop_front().unwrap()
    }
}

#[test]
fn activation_execution_is_injectable_and_does_not_hide_status() {
    let command = activation_command(ActivationCommand {
        run_id: "run-x".into(),
        host: "h".into(),
        attempt: 1,
        generation: generation("new"),
        goal: ActivationGoal::DryActivate,
        boot_environment: BootEnvironment::Container,
        restart_managed: false,
        runtime_max: Duration::from_secs(10),
        stop_timeout: Duration::from_secs(2),
        lock_wait: Duration::from_secs(3),
        acquire_host_lock: true,
    });
    let mut executor = FakeExecutor {
        results: VecDeque::from([ActivationResult {
            status: ActivationStatus::Exited(7),
            output: "failure".into(),
        }]),
        ..FakeExecutor::default()
    };
    assert_eq!(
        executor.execute(&command).status,
        ActivationStatus::Exited(7)
    );
    assert_eq!(executor.units, vec![command.unit]);
    assert_eq!(
        ActivationStatus::Signalled(15),
        ActivationStatus::Signalled(15)
    );
}

#[test]
fn parent_readiness_defaults_and_templates_are_argv_safe() {
    let commands = parent_readiness_commands(
        "machine with ' quote",
        None,
        Some("settle {resource} {timeout}"),
        Duration::from_secs(42),
    )
    .unwrap();
    assert_eq!(
        commands.reconcile.program,
        "/run/current-system/sw/bin/bash"
    );
    assert!(commands.reconcile.args[1].contains("incus-machines-reconciler"));
    assert!(commands.reconcile.args[1].contains("--machine 'machine with '\\'' quote'"));
    assert_eq!(
        commands.settle.args[1],
        "settle 'machine with '\\'' quote' 42"
    );
    assert!(
        parent_readiness_commands(
            "machine",
            Some("command {unknown}"),
            None,
            Duration::from_secs(1)
        )
        .is_ok()
    );
    assert!(
        parent_readiness_commands(
            "machine",
            Some("command {resourceArgs"),
            None,
            Duration::from_secs(1)
        )
        .is_err()
    );
}

#[test]
fn pre_activation_image_pull_uses_the_built_generation_plan() {
    let generation = generation("app");
    let command = pre_activation_image_pull_command(&generation);
    assert_eq!(command.program, "/run/current-system/sw/bin/bash");
    assert_eq!(command.args.last().unwrap(), generation.as_str());
    assert!(command.args[1].contains("share/podman-compose/image-pulls.json"));
    assert!(command.args[1].contains("podman-compose-image-pull-all"));
    assert!(command.args[1].contains("[prefetch-podman-image] start"));
    assert_bash_syntax(&command.args[1]);
}

#[test]
fn pre_activation_model_prefetch_uses_the_built_generation_runner() {
    let generation = generation("app");
    let command = pre_activation_model_prefetch_command(&generation);
    assert_eq!(command.program, "/run/current-system/sw/bin/bash");
    assert_eq!(command.args.last().unwrap(), generation.as_str());
    assert!(command.args[1].contains("ai-model-prefetch-all"));
    assert!(!command.args[1].contains("AI_MODEL_PREFETCH_PLAN"));
    assert!(!command.args[1].contains("caching declared AI models with"));
    assert_bash_syntax(&command.args[1]);
}

#[test]
fn candidate_lease_commands_are_run_scoped_candidate_bound_and_syntax_valid() {
    let generation = generation("app");
    let acquire = acquire_candidate_lease_command("run-42", "app.example", &generation);
    let release = release_candidate_lease_command("run-42", "app.example", &generation);
    let other_host = acquire_candidate_lease_command("run-42", "db.example", &generation);
    let other_run = acquire_candidate_lease_command("run-43", "app.example", &generation);

    for command in [&acquire, &release] {
        assert_eq!(command.program, "/run/current-system/sw/bin/bash");
        assert_eq!(command.args[3], generation.as_str());
        assert_eq!(command.args[4].len(), 64);
        assert!(
            command.args[4]
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        );
        assert!(command.args[1].contains("/run/nixbot/acquired-candidates"));
        assert!(command.args[1].contains("readlink"));
        assert_bash_syntax(&command.args[1]);
    }
    assert_eq!(acquire.args[4], release.args[4]);
    assert_ne!(acquire.args[4], other_host.args[4]);
    assert_ne!(acquire.args[4], other_run.args[4]);
    assert!(acquire.args[1].contains("nix-store"));
    assert!(release.args[1].contains("rm -f"));
}

#[test]
fn candidate_generation_admission_uses_the_current_dispatcher_without_switching() {
    let generation = generation("app");
    let command = generation_admission_command(&generation, ActivationGoal::Switch);

    assert_eq!(command.program, "/run/current-system/sw/bin/bash");
    assert_eq!(command.args, ["-s"]);
    assert!(command.script.contains(generation.as_str()));
    assert!(
        command
            .script
            .contains("abird-host-agent-generation-preflight")
    );
    assert!(!command.script.contains("switch-to-configuration"));
    assert!(
        command
            .script
            .contains("nixbot-candidate-acquisition=deferred")
    );
    assert_bash_syntax(&command.script);
}
