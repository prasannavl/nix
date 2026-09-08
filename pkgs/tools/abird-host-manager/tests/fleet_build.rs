use std::path::{Path, PathBuf};
use std::time::Duration;

use abird_host_manager::fleet::build::{
    BuildArgs, BuildBatch, BuildCacheContext, BuildCacheState, BuildHostDeployMode,
    BuildPlanAttribute, BuildSchedule, BuildStage, CacheSource, CommandAttempt, CommandExecutor,
    CommandSpec, CommandStatus, DistributionInputs, DistributionPlan, LocalBuildSpec, NixStorePath,
    RemoteBuildOutput, RemoteBuildPurpose, RemoteFailureKind, RetryDecision, RetryPolicy,
    RetryTracker, build_plan_cache_file, build_plan_evaluation_command, build_plan_probe_command,
    closure_verification_command, copy_derivation_command, development_build_command,
    effective_build_plan_jobs, execute_with_retry, local_build_command, remote_build_command,
    remote_build_stages, validate_cached_build_plan,
};

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

#[test]
fn derivation_and_closure_paths_are_single_absolute_store_paths() {
    let drv = NixStorePath::derivation("/nix/store/abc-system.drv").unwrap();
    assert_eq!(drv.as_str(), "/nix/store/abc-system.drv");
    assert_eq!(drv.output_installable(), "/nix/store/abc-system.drv^out");

    assert!(NixStorePath::derivation("/nix/store/not-a-derivation").is_err());
    assert!(NixStorePath::derivation("relative.drv").is_err());
    assert!(NixStorePath::derivation("/nix/store/a.drv\n/nix/store/b.drv").is_err());
    assert!(NixStorePath::closure_output("").is_err());
    assert!(NixStorePath::closure_output("/tmp/result").is_err());
    assert!(NixStorePath::closure_output("/nix/store/a\n/nix/store/b").is_err());
}

#[test]
fn build_plan_probe_and_evaluation_preserve_nix_arguments_and_fallback() {
    let nix_args = strings(&["--option", "eval-cache", "false"]);
    assert_eq!(
        build_plan_probe_command("nix", &nix_args),
        CommandSpec::new(
            "nix",
            strings(&[
                "eval",
                "--option",
                "eval-cache",
                "false",
                "--json",
                "--no-write-lock-file",
                ".#nixbot.plans",
                "--apply",
                "builtins.attrNames",
            ])
        )
    );

    let native =
        build_plan_evaluation_command("nix", &nix_args, BuildPlanAttribute::Native, "proxy-target");
    assert_eq!(
        native.args.last().unwrap(),
        ".#nixbot.plans.proxy-target.drvPath"
    );
    let fallback = build_plan_evaluation_command(
        "nix",
        &[],
        BuildPlanAttribute::NixosConfiguration,
        "proxy-target",
    );
    assert_eq!(
        fallback.args.last().unwrap(),
        ".#nixosConfigurations.proxy-target.config.system.build.toplevel.drvPath"
    );
}

#[test]
fn build_plan_cache_context_is_stable_and_only_allows_clean_indexed_state() {
    let context =
        BuildCacheContext::new("nix (Nix) 2.31.2", "0123456789abcdef", "fedcba9876543210").unwrap();
    assert_eq!(context.key().len(), 64);
    assert_eq!(context.key(), context.clone().key());
    assert_ne!(
        context.key(),
        BuildCacheContext::new("nix (Nix) 2.31.3", "0123456789abcdef", "fedcba9876543210")
            .unwrap()
            .key()
    );

    assert!(BuildCacheState::clean().allows_cache());
    assert!(
        !BuildCacheState {
            unstaged_changes: true,
            ..BuildCacheState::clean()
        }
        .allows_cache()
    );
    assert!(
        !BuildCacheState {
            unmerged_paths: true,
            ..BuildCacheState::clean()
        }
        .allows_cache()
    );
    assert!(
        !BuildCacheState {
            enabled: false,
            ..BuildCacheState::clean()
        }
        .allows_cache()
    );
}

#[test]
fn build_plan_cache_file_separates_context_host_and_configuration() {
    let root = Path::new("/cache/nixbot/build-plans/v1");
    let context = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    assert_eq!(
        build_plan_cache_file(root, context, "proxy", "proxy-target").unwrap(),
        PathBuf::from(format!(
            "/cache/nixbot/build-plans/v1/{context}/proxy--proxy-target.drv-path"
        ))
    );
    assert_eq!(
        build_plan_cache_file(root, context, "bad/host", "target name").unwrap(),
        PathBuf::from(format!(
            "/cache/nixbot/build-plans/v1/{context}/bad_host--target_name.drv-path"
        ))
    );
    assert!(build_plan_cache_file(root, "../escape", "host", "config").is_err());
}

#[test]
fn cached_plan_requires_a_valid_present_derivation() {
    assert_eq!(
        validate_cached_build_plan("/nix/store/abc-system.drv\n", true)
            .unwrap()
            .as_str(),
        "/nix/store/abc-system.drv"
    );
    assert!(validate_cached_build_plan("/nix/store/abc-system.drv", false).is_err());
    assert!(validate_cached_build_plan("/nix/store/not-drv", true).is_err());
    assert_eq!(effective_build_plan_jobs(8, 3).unwrap(), 3);
    assert_eq!(effective_build_plan_jobs(8, 0).unwrap(), 0);
    assert!(effective_build_plan_jobs(0, 3).is_err());
}

#[test]
fn local_and_development_build_commands_preserve_extra_args_logs_and_links() {
    let drv = NixStorePath::derivation("/nix/store/abc-system.drv").unwrap();
    let args = BuildArgs::for_concurrency(4, true).unwrap();
    assert_eq!(args.nix_args, strings(&["--option", "eval-cache", "false"]));

    let local = local_build_command(
        "nix",
        &drv,
        &args,
        LocalBuildSpec {
            result_link: Some(PathBuf::from("result/app")),
        },
    );
    assert_eq!(
        local.args,
        strings(&[
            "build",
            "--option",
            "eval-cache",
            "false",
            "--print-out-paths",
            "-L",
            "-o",
            "result/app",
            "/nix/store/abc-system.drv^out",
        ])
    );

    let development = development_build_command("nix", "app", &drv, &args).unwrap();
    assert_eq!(
        development.args,
        strings(&[
            "build",
            "--option",
            "eval-cache",
            "false",
            "--print-out-paths",
            "-o",
            "result-dev/app",
            "-L",
            "/nix/store/abc-system.drv^out",
        ])
    );
    assert!(development_build_command("nix", "../escape", &drv, &args).is_err());
}

#[test]
fn remote_build_is_unrooted_and_preserves_build_arguments() {
    let drv = NixStorePath::derivation("/nix/store/abc-system.drv").unwrap();
    let args = BuildArgs::for_concurrency(2, true).unwrap();
    let command = remote_build_command("nix", &drv, &args);
    assert_eq!(command.args[0], "build");
    assert!(
        command
            .args
            .windows(3)
            .any(|args| args == ["--option", "eval-cache", "false"])
    );
    assert!(command.args.contains(&"-L".to_owned()));
    assert_eq!(
        command.args.last().unwrap(),
        "/nix/store/abc-system.drv^out"
    );
    assert!(command.args.contains(&"--no-link".to_owned()));
    assert!(!command.args.contains(&"-o".to_owned()));
}

#[test]
fn remote_build_output_is_exactly_one_store_path() {
    let output = RemoteBuildOutput::validate("/nix/store/abc-system\n").unwrap();
    assert_eq!(output.path.as_str(), "/nix/store/abc-system");
    assert!(RemoteBuildOutput::validate("/nix/store/a\n/nix/store/b").is_err());
}

#[test]
fn remote_build_stages_protect_output_before_deploy_cache_validation() {
    assert_eq!(
        remote_build_stages(RemoteBuildPurpose::Deployment),
        [
            BuildStage::CopyDerivation,
            BuildStage::BuildUnderGcLease,
            BuildStage::ValidateDeploymentCache,
        ]
    );
    assert_eq!(
        remote_build_stages(RemoteBuildPurpose::BuildOnly),
        [
            BuildStage::CopyDerivation,
            BuildStage::BuildUnderGcLease,
            BuildStage::CopyClosureToLocal,
        ]
    );
}

#[test]
fn daemon_disconnect_and_transport_loss_are_retryable_with_retained_evidence() {
    let mut tracker = RetryTracker::new(RetryPolicy::new(3, Duration::from_secs(2)).unwrap());
    let first = CommandAttempt::failure(
        1,
        "",
        "error: Nix daemon disconnected unexpectedly; retrying is safe",
    );
    let decision = tracker.observe(first);
    assert!(matches!(
        decision,
        RetryDecision::Retry {
            next_attempt: 2,
            delay,
            kind: RemoteFailureKind::DaemonDisconnect,
        } if delay == Duration::from_secs(2)
    ));
    assert_eq!(tracker.failures().len(), 1);
    assert!(tracker.failures()[0].stderr.contains("daemon disconnected"));

    let second = CommandAttempt::failure(255, "", "client_loop: send disconnect: Broken pipe");
    assert!(matches!(
        tracker.observe(second),
        RetryDecision::Retry {
            next_attempt: 3,
            delay,
            kind: RemoteFailureKind::TransportLoss,
        } if delay == Duration::from_secs(4)
    ));
    assert_eq!(
        tracker.observe(CommandAttempt::success("/nix/store/result\n")),
        RetryDecision::Complete
    );
}

#[derive(Default)]
struct FakeExecutor {
    attempts: std::collections::VecDeque<CommandAttempt>,
    commands: Vec<CommandSpec>,
    delays: Vec<Duration>,
}

impl CommandExecutor for FakeExecutor {
    fn execute(&mut self, command: &CommandSpec) -> CommandAttempt {
        self.commands.push(command.clone());
        self.attempts.pop_front().unwrap()
    }

    fn wait_before_retry(&mut self, delay: Duration) {
        self.delays.push(delay);
    }
}

#[test]
fn retry_execution_replays_exact_command_and_returns_all_failure_evidence() {
    let command = CommandSpec::new("nix", strings(&["copy", "--to", "ssh-ng://builder"]));
    let mut executor = FakeExecutor {
        attempts: [
            CommandAttempt::failure(1, "partial", "Nix daemon disconnected unexpectedly"),
            CommandAttempt::success("/nix/store/result\n"),
        ]
        .into(),
        ..FakeExecutor::default()
    };
    let report = execute_with_retry(&mut executor, &command, RetryPolicy::default());
    assert_eq!(report.attempt.status, CommandStatus::Success);
    assert_eq!(report.failures.len(), 1);
    assert_eq!(report.failures[0].stdout, "partial");
    assert_eq!(executor.commands, [command.clone(), command]);
    assert_eq!(executor.delays, [Duration::from_secs(2)]);
}

#[test]
fn host_key_signal_and_ordinary_failures_never_retry() {
    let mut host_key = RetryTracker::new(RetryPolicy::default());
    assert!(matches!(
        host_key.observe(CommandAttempt::failure(
            255,
            "",
            "Host key verification failed"
        )),
        RetryDecision::Stop {
            kind: RemoteFailureKind::HostKeyVerification,
            status: 255,
        }
    ));

    let mut signal = RetryTracker::new(RetryPolicy::default());
    assert!(matches!(
        signal.observe(CommandAttempt {
            status: CommandStatus::Signal(130),
            stdout: String::new(),
            stderr: "interrupted".to_owned(),
        }),
        RetryDecision::Stop {
            kind: RemoteFailureKind::Signal,
            status: 130,
        }
    ));

    let mut ordinary = RetryTracker::new(RetryPolicy::default());
    assert!(matches!(
        ordinary.observe(CommandAttempt::failure(1, "", "evaluation failed")),
        RetryDecision::Stop {
            kind: RemoteFailureKind::CommandFailure,
            status: 1,
        }
    ));
}

#[test]
fn build_schedule_places_control_plane_hosts_behind_serial_barriers() {
    let schedule = BuildSchedule::new(
        strings(&["app-a", "app-b", "controller", "registry"]),
        3,
        &strings(&["controller", "registry"]),
    )
    .unwrap()
    .with_build_logs(true);
    assert_eq!(schedule.max_in_flight, 3);
    assert_eq!(
        schedule.batches,
        [
            BuildBatch::Parallel(strings(&["app-a", "app-b"])),
            BuildBatch::Serial("controller".to_owned()),
            BuildBatch::Serial("registry".to_owned()),
        ]
    );
    assert_eq!(
        schedule.build_args().nix_args,
        strings(&["--option", "eval-cache", "false"])
    );
    assert!(schedule.build_args().build_logs);

    let serial = BuildSchedule::new(
        strings(&["controller", "registry", "app"]),
        1,
        &strings(&["controller", "registry"]),
    )
    .unwrap();
    assert_eq!(
        serial.batches,
        [BuildBatch::Parallel(strings(&[
            "controller",
            "registry",
            "app"
        ]))]
    );
    assert!(serial.build_args().nix_args.is_empty());
    assert!(BuildSchedule::new(strings(&["app"]), 0, &[]).is_err());
}

#[test]
fn derivation_copy_and_same_store_closure_validation_are_explicit_commands() {
    let drv = NixStorePath::derivation("/nix/store/abc-system.drv").unwrap();
    assert_eq!(
        copy_derivation_command("nix", "ssh-ng://builder", &drv),
        CommandSpec::new(
            "nix",
            strings(&[
                "copy",
                "--to",
                "ssh-ng://builder",
                "/nix/store/abc-system.drv",
            ])
        )
    );
    let closure = NixStorePath::closure_output("/nix/store/abc-system").unwrap();
    assert_eq!(
        closure_verification_command("nix", &closure),
        CommandSpec::new(
            "nix",
            strings(&[
                "--offline",
                "--quiet",
                "store",
                "verify",
                "--no-contents",
                "--no-trust",
                "--recursive",
                "/nix/store/abc-system",
            ])
        )
    );
}

#[test]
fn distribution_uses_canonical_store_identity_and_explicit_mode() {
    let cache = CacheSource::new("http://cache.internal:5000", ["cache-key"]).unwrap();
    let closure = NixStorePath::closure_output("/nix/store/abc-system").unwrap();

    assert_eq!(
        DistributionInputs {
            build_resource: "builder".to_owned(),
            target_resource: "builder".to_owned(),
            configured_mode: BuildHostDeployMode::Auto,
            build_host_is_cache_host: true,
            target_is_local: false,
            cache: Some(cache.clone()),
        }
        .plan(&closure)
        .unwrap(),
        DistributionPlan::VerifyExisting {
            closure: closure.clone()
        }
    );

    assert!(matches!(
        DistributionInputs {
            build_resource: "builder".to_owned(),
            target_resource: "app".to_owned(),
            configured_mode: BuildHostDeployMode::Auto,
            build_host_is_cache_host: true,
            target_is_local: false,
            cache: Some(cache.clone()),
        }
        .plan(&closure)
        .unwrap(),
        DistributionPlan::TryTargetCacheThenRelay { .. }
    ));

    assert!(matches!(
        DistributionInputs {
            build_resource: "builder".to_owned(),
            target_resource: "app".to_owned(),
            configured_mode: BuildHostDeployMode::LocalCopy,
            build_host_is_cache_host: true,
            target_is_local: false,
            cache: Some(cache.clone()),
        }
        .plan(&closure)
        .unwrap(),
        DistributionPlan::RelayThroughLocal { .. }
    ));

    assert!(matches!(
        DistributionInputs {
            build_resource: "builder".to_owned(),
            target_resource: "app".to_owned(),
            configured_mode: BuildHostDeployMode::Cache,
            build_host_is_cache_host: true,
            target_is_local: false,
            cache: Some(cache),
        }
        .plan(&closure)
        .unwrap(),
        DistributionPlan::TargetCachePull { retry: true, .. }
    ));
}

#[test]
fn remote_deploy_requires_cache_configuration_even_for_same_store_target() {
    let closure = NixStorePath::closure_output("/nix/store/abc-system").unwrap();
    let inputs = DistributionInputs {
        build_resource: "builder".to_owned(),
        target_resource: "builder".to_owned(),
        configured_mode: BuildHostDeployMode::Auto,
        build_host_is_cache_host: true,
        target_is_local: false,
        cache: None,
    };
    assert!(inputs.plan(&closure).is_err());
}
