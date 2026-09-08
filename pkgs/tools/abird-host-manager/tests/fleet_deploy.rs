#[path = "../src/fleet/deploy.rs"]
mod deploy;

use std::collections::VecDeque;
use std::io::Write;
use std::process::{Command, Stdio};
use std::time::Duration;

use deploy::{
    ActivationCommand, ActivationExecutor, ActivationGoal, ActivationResult, ActivationSample,
    ActivationStatus, BootEnvironment, CancellationAction, CancellationController, DeployDecision,
    DeployFailureAction, GenerationSnapshot, LockContentionEvidence, SnapshotRequirement,
    SystemGeneration, VerificationDecision, activation_command, activation_verification_command,
    boot_is_container_command, classify_deploy_failure, deploy_unit_name,
    parent_readiness_commands, pre_activation_image_pull_command, pre_switch_admission_command,
    rollback_command, rollback_unit_name, rollback_waves, snapshot_command, verify_activation,
};

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
fn pre_switch_admission_resets_failed_state_repairs_user_managers_and_reports_failures() {
    let command = pre_switch_admission_command();
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
    assert!(command.script.contains("switch-to-configuration switch"));
    assert!(command.script.contains("/nix/var/nix/profiles/system"));
    assert!(command.script.contains("NIXOS_INSTALL_BOOTLOADER=1"));
    assert!(command.script.contains("switch-to-configuration boot"));
    assert!(command.script.contains("podman-composectl"));
    assert!(command.script.contains("restart-managed"));
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
    assert!(observer.contains("for ((polls = 0; polls < 19300; polls++))"));
    assert_bash_syntax(&command.script);
    assert_bash_syntax(observer);
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
            .contains("abird-host-agent-projection-preflight")
    );
    assert!(command.script.contains(" rollback"));
    assert!(command.script.contains("switch-to-configuration switch"));
    assert!(command.script.contains("/nix/var/nix/profiles/system"));
    assert!(!command.script.contains("NIXOS_INSTALL_BOOTLOADER=1"));
    assert!(!command.script.contains("restart-managed"));
    assert_bash_syntax(&command.script);
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
        "OutcomeSource=marker\nActiveState=inactive\nResult=success\nExecMainStatus=0\nCurrentSystemPath=/nix/store/abc123-nixos-system-new\nSystemProfilePath=/nix/store/abc123-nixos-system-new\n",
    );
    assert_eq!(
        verify_activation(&success, &target, ActivationGoal::Switch),
        VerificationDecision::Succeeded
    );

    let wrong_profile = sample(
        "OutcomeSource=marker\nActiveState=inactive\nResult=success\nExecMainStatus=0\nCurrentSystemPath=/nix/store/abc123-nixos-system-new\nSystemProfilePath=/nix/store/abc123-nixos-system-old\n",
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
        "OutcomeSource=marker\nActiveState=active\nResult=running\nExecMainStatus=255\nCurrentSystemPath=/nix/store/abc123-nixos-system-new\n",
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
        "OutcomeSource=marker\nActiveState=failed\nResult=exit-code\nExecMainStatus=1\nCurrentSystemPath=/nix/store/abc123-nixos-system-new\nSystemProfilePath=/nix/store/abc123-nixos-system-new\n",
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
    assert_bash_syntax(&command.args[1]);
}
