#![allow(dead_code)]

mod programs {
    pub use abird_host_manager::programs::clear_git_repository_environment;
}

#[allow(clippy::all)]
#[path = "../src/fleet/bootstrap.rs"]
mod bootstrap;
#[allow(clippy::all)]
#[path = "../src/fleet/build.rs"]
mod build;
#[allow(clippy::all)]
#[path = "../src/fleet/build_lease.rs"]
mod build_lease;
#[allow(clippy::all)]
#[path = "../src/fleet/build_runtime.rs"]
mod build_runtime;
#[allow(clippy::all)]
#[path = "../src/fleet/cli.rs"]
mod cli;
#[allow(clippy::all)]
#[path = "../src/fleet/deploy.rs"]
mod deploy;
#[allow(clippy::all)]
#[path = "../src/fleet/environment.rs"]
mod environment;
#[allow(clippy::all)]
#[path = "../src/fleet/health.rs"]
mod health;
#[allow(clippy::all)]
#[path = "../src/fleet/health_runtime.rs"]
mod health_runtime;
#[deny(clippy::all)]
#[path = "../src/fleet/host_runtime.rs"]
mod host_runtime;
#[allow(clippy::all)]
#[path = "../src/fleet/inventory.rs"]
mod inventory;
#[allow(clippy::all)]
#[path = "../src/fleet/system.rs"]
mod system;
#[allow(clippy::all)]
#[path = "../src/fleet/transport.rs"]
mod transport;

use std::cell::RefCell;
use std::collections::{BTreeSet, VecDeque};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine as _;
use bootstrap::ForcedCommandPlan;
use build::{
    BuildPlanAttribute, CacheSource, CommandSpec, CommandStatus, DistributionPlan, LocalBuildSpec,
    NixStorePath, RemoteFailureKind, RetryPolicy, build_plan_evaluation_command,
    local_build_command,
};
use deploy::{
    ActivationCommand, ActivationGoal, BootEnvironment, RemoteCommand, SnapshotRequirement,
    SystemGeneration, activation_command, pre_switch_preparation_command, rollback_command,
};
use health::{HealthDecision, HealthEvidence};
use host_runtime::{
    ActivationExecution, DeployOutcome, DryRun, EffectKind, HealthEvaluator, HostExecutionTarget,
    HostRuntime, ProcessCancellation, ProcessCompletion, ProcessEventObserver, ProcessOutput,
    ProcessOutputPolicy, ProcessRequest, ProcessRunner, ProcessStream, RemoteBuildRequest,
    ReportingProcessRunner, SystemHealthProbe, SystemProcessRunner, build_ssh_request,
    build_ssh_upload_request, builder_lease_process_spec, control_master_exit_request,
};
use system::ResolvedHost;
use transport::{
    HostKeyPolicy, ProcessStatus, ProxyCommandTemplate, ProxyHop, ProxyPlan, SshEndpoint,
    SshRoutePlan, TransportRole,
};

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

fn success(stdout: &str) -> ProcessOutput {
    ProcessOutput {
        status: ProcessStatus::Code(0),
        stdout: stdout.to_owned(),
        stderr: String::new(),
        skipped: false,
    }
}

fn failure(code: i32, stderr: &str) -> ProcessOutput {
    ProcessOutput {
        status: ProcessStatus::Code(code),
        stdout: String::new(),
        stderr: stderr.to_owned(),
        skipped: false,
    }
}

#[derive(Default)]
struct FakeRunner {
    outputs: VecDeque<ProcessOutput>,
    requests: Vec<ProcessRequest>,
    waits: Vec<Duration>,
}

impl FakeRunner {
    fn with_outputs(outputs: impl IntoIterator<Item = ProcessOutput>) -> Self {
        Self {
            outputs: outputs.into_iter().collect(),
            ..Self::default()
        }
    }
}

impl ProcessRunner for FakeRunner {
    fn run(&mut self, request: &ProcessRequest) -> io::Result<ProcessOutput> {
        self.requests.push(request.clone());
        Ok(self
            .outputs
            .pop_front()
            .expect("missing fake process output"))
    }

    fn wait(&mut self, duration: Duration) {
        self.waits.push(duration);
    }
}

fn resolved_host() -> ResolvedHost {
    ResolvedHost {
        inventory_name: "gap3".into(),
        resource: "gap3-gondor".into(),
        target: "192.0.2.42".into(),
        user: "root".into(),
        port: 2222,
        identity_key: Some(PathBuf::from("/keys/deploy key")),
        known_hosts: None,
        bootstrap_key: None,
        operator_user: None,
        operator_port: 22,
        operator_key: None,
        age_identity_key: None,
        proxy_jump: None,
        proxy_command: None,
    }
}

fn target() -> HostExecutionTarget {
    let host = resolved_host();
    let endpoint = SshEndpoint::new(
        "gap3",
        host.target.clone(),
        host.user.clone(),
        host.port,
        TransportRole::Primary,
        host.identity_key.clone(),
    )
    .unwrap();
    HostExecutionTarget::from_resolved(
        &host,
        SshRoutePlan {
            endpoint,
            proxy: ProxyPlan::default(),
            proxy_command: None,
            host_key_policy: HostKeyPolicy::Strict,
        },
        Path::new("/repo"),
        Some(PathBuf::from("/tmp/known hosts")),
        false,
    )
    .unwrap()
}

fn target_as(user: &str) -> HostExecutionTarget {
    let mut host = resolved_host();
    host.user = user.to_owned();
    let endpoint = SshEndpoint::new(
        "gap3",
        host.target.clone(),
        host.user.clone(),
        host.port,
        TransportRole::Primary,
        host.identity_key.clone(),
    )
    .unwrap();
    HostExecutionTarget::from_resolved(
        &host,
        SshRoutePlan {
            endpoint,
            proxy: ProxyPlan::default(),
            proxy_command: None,
            host_key_policy: HostKeyPolicy::Strict,
        },
        Path::new("/repo"),
        Some(PathBuf::from("/tmp/known hosts")),
        false,
    )
    .unwrap()
}

fn framed_remote_argv(request: &ProcessRequest) -> Vec<String> {
    let payload = request
        .stdin
        .as_deref()
        .unwrap()
        .split("done <<'NIXBOT_ARGV'\n")
        .nth(1)
        .unwrap()
        .split("\nNIXBOT_ARGV\n")
        .next()
        .unwrap();
    payload
        .lines()
        .map(|line| {
            String::from_utf8(
                base64::engine::general_purpose::STANDARD
                    .decode(line)
                    .unwrap(),
            )
            .unwrap()
        })
        .collect()
}

fn generation(name: &str) -> SystemGeneration {
    SystemGeneration::parse(&format!("/nix/store/abc-nixos-system-{name}")).unwrap()
}

fn activation(goal: ActivationGoal) -> RemoteCommand {
    activation_command(ActivationCommand {
        run_id: "run-test".into(),
        host: "gap3".into(),
        attempt: 1,
        generation: generation("new"),
        goal,
        boot_environment: BootEnvironment::Container,
        restart_managed: false,
        runtime_max: Duration::from_secs(30),
        stop_timeout: Duration::from_secs(5),
        lock_wait: Duration::from_secs(35),
        acquire_host_lock: true,
    })
}

fn rollback() -> RemoteCommand {
    rollback_for(generation("old"))
}

fn rollback_for(generation: SystemGeneration) -> RemoteCommand {
    rollback_command(
        "run-test",
        "gap3",
        generation,
        BootEnvironment::Container,
        Duration::from_secs(30),
        Duration::from_secs(5),
        Duration::from_secs(35),
        true,
    )
}

#[test]
fn host_target_rejects_route_drift_and_relative_working_directory() {
    let host = resolved_host();
    let wrong = SshEndpoint::new(
        "gap3",
        "different.example",
        "root",
        2222,
        TransportRole::Primary,
        host.identity_key.clone(),
    )
    .unwrap();
    assert!(
        HostExecutionTarget::from_resolved(
            &host,
            SshRoutePlan::direct(wrong),
            Path::new("/repo"),
            None,
            false,
        )
        .is_err()
    );
    let correct = SshEndpoint::new(
        "gap3",
        host.target.clone(),
        host.user.clone(),
        host.port,
        TransportRole::Primary,
        host.identity_key.clone(),
    )
    .unwrap();
    assert!(
        HostExecutionTarget::from_resolved(
            &host,
            SshRoutePlan::direct(correct),
            Path::new("relative"),
            None,
            false,
        )
        .is_err()
    );
}

#[test]
fn control_master_is_scoped_and_has_an_explicit_retirement_command() {
    let target = target()
        .with_control_master(PathBuf::from("/tmp/fleet/cm-gap3-primary"), 120)
        .unwrap();
    let request = build_ssh_request(
        &target,
        &strings(&["true"]),
        &[],
        EffectKind::ReadOnly,
        "probe",
    )
    .unwrap();
    assert!(request.args.iter().any(|arg| arg == "ControlMaster=auto"));
    assert!(
        request
            .args
            .iter()
            .any(|arg| arg == "ControlPath=/tmp/fleet/cm-gap3-primary")
    );
    assert!(request.args.iter().any(|arg| arg == "ControlPersist=120"));

    let exit = control_master_exit_request(&target).unwrap().unwrap();
    assert!(exit.args.windows(2).any(|args| args == ["-O", "exit"]));
    assert!(
        exit.args
            .windows(2)
            .any(|args| args == ["-S", "/tmp/fleet/cm-gap3-primary"])
    );
    assert!(!exit.args.iter().any(|arg| arg == "ControlMaster=auto"));
    assert!(!exit.args.iter().any(|arg| arg == "ControlPath=none"));
}

#[test]
fn control_master_rejects_unix_socket_paths_at_the_platform_limit() {
    let accepted = PathBuf::from(format!("/{}", "a".repeat(106)));
    assert_eq!(accepted.as_os_str().as_encoded_bytes().len(), 107);
    assert!(target().with_control_master(accepted, 120).is_ok());

    let rejected = PathBuf::from(format!("/{}", "a".repeat(107)));
    assert_eq!(rejected.as_os_str().as_encoded_bytes().len(), 108);
    let error = target().with_control_master(rejected, 120).unwrap_err();
    assert!(error.to_string().contains("108 bytes"));
    assert!(error.to_string().contains("shorter runtime directory"));
}

#[test]
fn ssh_request_keeps_local_arguments_separate_and_encodes_remote_argv() {
    let target = target().with_ssh_liveness(42, 9, 2).unwrap();
    let request = build_ssh_request(
        &target,
        &[
            "tool".into(),
            "value; touch /tmp/pwned".into(),
            "two words".into(),
        ],
        &[("SAFE_NAME".into(), "value $(false)".into())],
        EffectKind::Mutation,
        "test",
    )
    .unwrap();

    assert_eq!(request.program, "ssh");
    assert!(
        request
            .args
            .windows(2)
            .any(|args| args == ["-i", "/keys/deploy key"])
    );
    assert!(request.args.windows(2).any(|args| args == ["-p", "2222"]));
    for expected in [
        "ConnectTimeout=42",
        "ConnectionAttempts=1",
        "ServerAliveInterval=9",
        "ServerAliveCountMax=2",
        "LogLevel=ERROR",
    ] {
        assert!(request.args.iter().any(|argument| argument == expected));
    }
    assert!(
        request
            .args
            .iter()
            .any(|arg| arg == "UserKnownHostsFile=/tmp/known hosts")
    );
    assert_eq!(
        &request.args[request.args.len() - 4..],
        [
            "--",
            "root@192.0.2.42",
            "/run/current-system/sw/bin/bash",
            "-s"
        ]
    );
    let stdin = request.stdin.as_deref().unwrap();
    assert!(!stdin.contains("touch /tmp/pwned"));
    assert!(!stdin.contains("$(false)"));
    assert!(stdin.contains("base64 -d"));
    assert_eq!(request.cwd, PathBuf::from("/repo"));
}

#[test]
fn ssh_upload_keeps_secret_bytes_out_of_process_arguments() {
    let target = target();
    let request = build_ssh_upload_request(
        &target,
        "private fixture bytes".to_owned(),
        Path::new("/tmp/nixbot-bootstrap-key.run-1"),
        "bootstrap-copy",
    )
    .unwrap();
    assert_eq!(request.program, "ssh");
    assert_eq!(request.effect, EffectKind::Mutation);
    assert_eq!(request.label, "bootstrap-copy");
    assert!(request.args.windows(2).any(|pair| pair == ["-p", "2222"]));
    assert!(
        !request
            .args
            .iter()
            .any(|arg| arg.contains("private fixture"))
    );
    assert_eq!(request.stdin.as_deref(), Some("private fixture bytes"));
    assert_eq!(
        &request.args[request.args.len() - 3..],
        [
            "--",
            "root@192.0.2.42",
            "'/run/current-system/sw/bin/bash' '-c' 'set -Eeuo pipefail; umask 077; cat > /tmp/nixbot-bootstrap-key.run-1'"
        ]
    );
    assert!(!request.args.iter().any(|arg| arg == "-c"));
    assert!(
        build_ssh_upload_request(&target, String::new(), Path::new("/tmp/key;bad"), "copy")
            .is_err()
    );
}

#[test]
fn ssh_request_preserves_keyed_proxy_hops_in_a_nested_proxy_command() {
    let mut target = target().with_ssh_liveness(17, 8, 4).unwrap();
    target.route.proxy.hops.push(ProxyHop {
        node: "jump".into(),
        endpoint: SshEndpoint::new(
            "jump",
            "jump.example",
            "operator",
            22,
            TransportRole::Operator,
            Some(PathBuf::from("/keys/jump")),
        )
        .unwrap(),
        proxy_command: None,
        local: false,
    });
    let request = build_ssh_request(
        &target,
        &["true".into()],
        &[],
        EffectKind::ReadOnly,
        "probe",
    )
    .unwrap();
    let proxy = request
        .args
        .iter()
        .find(|argument| argument.starts_with("ProxyCommand="))
        .unwrap();
    assert!(proxy.contains("/keys/jump"));
    assert!(proxy.contains("operator@jump.example"));
    assert!(proxy.contains("UserKnownHostsFile=/tmp/known hosts"));
    assert!(proxy.contains("ConnectTimeout=17"));
    assert!(proxy.contains("ServerAliveInterval=8"));
    assert!(proxy.contains("ServerAliveCountMax=4"));
}

#[test]
fn nested_proxy_commands_freeze_each_hops_forward_destination() {
    let mut target = target();
    target.route.proxy.hops.extend([
        ProxyHop {
            node: "outer".into(),
            endpoint: SshEndpoint::new(
                "outer",
                "192.0.2.10",
                "nixbot",
                22,
                TransportRole::Primary,
                None,
            )
            .unwrap(),
            proxy_command: None,
            local: false,
        },
        ProxyHop {
            node: "inner".into(),
            endpoint: SshEndpoint::new(
                "inner",
                "2001:db8::20",
                "nixbot",
                2202,
                TransportRole::Primary,
                None,
            )
            .unwrap(),
            proxy_command: None,
            local: false,
        },
    ]);

    let request = build_ssh_request(
        &target,
        &["true".into()],
        &[],
        EffectKind::ReadOnly,
        "probe",
    )
    .unwrap();
    let proxy = request
        .args
        .iter()
        .find(|argument| argument.starts_with("ProxyCommand="))
        .unwrap();

    assert!(proxy.contains("[2001:db8::20]:2202"), "{proxy}");
    assert!(proxy.contains("192.0.2.42:2222"), "{proxy}");
    assert!(!proxy.contains("%h"), "{proxy}");
    assert!(!proxy.contains("%p"), "{proxy}");
}

#[test]
fn runtime_rejects_target_with_different_working_directory_authority() {
    let runner = FakeRunner::with_outputs([]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/different"), DryRun::No).unwrap();
    let error = runtime
        .execute_remote_command(
            &target(),
            &CommandSpec::new("true", Vec::<String>::new()),
            EffectKind::ReadOnly,
            "probe",
        )
        .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("does not match runtime authority")
    );
    assert!(runtime.into_runner().requests.is_empty());
}

#[test]
fn root_execution_elevates_non_root_targets_and_keeps_root_targets_direct() {
    let command = CommandSpec::new(
        "/run/current-system/sw/bin/incus-machines-settlement",
        strings(&["--timeout", "42", "--machine", "abird-data"]),
    );

    let runner = FakeRunner::with_outputs([success("")]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    runtime
        .execute_remote_root_command(
            &target_as("nixbot"),
            &command,
            EffectKind::ReadOnly,
            "parent-settle",
        )
        .unwrap();
    assert_eq!(
        framed_remote_argv(&runtime.into_runner().requests[0]),
        vec![
            "/run/wrappers/bin/sudo",
            "-n",
            "--",
            "/run/current-system/sw/bin/env",
            "--",
            "PATH=/run/wrappers/bin:/run/current-system/sw/bin",
            "/run/current-system/sw/bin/incus-machines-settlement",
            "--timeout",
            "42",
            "--machine",
            "abird-data",
        ]
    );

    let runner = FakeRunner::with_outputs([success("")]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    runtime
        .execute_remote_root_command(&target(), &command, EffectKind::ReadOnly, "parent-settle")
        .unwrap();
    assert_eq!(
        framed_remote_argv(&runtime.into_runner().requests[0]),
        vec![
            "/run/current-system/sw/bin/env",
            "--",
            "PATH=/run/wrappers/bin:/run/current-system/sw/bin",
            "/run/current-system/sw/bin/incus-machines-settlement",
            "--timeout",
            "42",
            "--machine",
            "abird-data",
        ]
    );
}

#[test]
fn build_plan_then_local_build_preserves_order_cwd_and_parsing() {
    let drv = "/nix/store/abc-system.drv";
    let closure = "/nix/store/def-nixos-system-new";
    let runner = FakeRunner::with_outputs([success(drv), success(closure)]);
    let mut runtime =
        HostRuntime::new(runner, PathBuf::from("/repo/worktree"), DryRun::No).unwrap();

    let eval = build_plan_evaluation_command("nix", &[], BuildPlanAttribute::Native, "gap3");
    let evaluated = runtime
        .evaluate_build_plan(&eval)
        .unwrap()
        .executed()
        .unwrap();
    let build = local_build_command(
        "nix",
        &evaluated,
        &build::BuildArgs::new(Vec::new(), true),
        LocalBuildSpec { result_link: None },
    );
    let built = runtime.local_build(&build).unwrap().executed().unwrap();
    assert_eq!(built.as_str(), closure);

    let runner = runtime.into_runner();
    assert_eq!(runner.requests.len(), 2);
    assert_eq!(runner.requests[0].effect, EffectKind::ReadOnly);
    assert_eq!(runner.requests[1].effect, EffectKind::Build);
    assert_eq!(runner.requests[0].cwd, PathBuf::from("/repo/worktree"));
    assert_eq!(
        runner.requests[0].args.last().unwrap(),
        ".#nixbot.plans.gap3.drvPath"
    );
    assert_eq!(
        runner.requests[1].args.last().unwrap(),
        "/nix/store/abc-system.drv^out"
    );
}

#[test]
fn remote_build_retries_daemon_disconnect_and_validates_exact_output() {
    let runner = FakeRunner::with_outputs([
        success(""),
        failure(1, "Nix daemon disconnected unexpectedly"),
        success("/nix/store/def-nixos-system-new\n"),
    ]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let result = runtime
        .remote_build(RemoteBuildRequest {
            subject: "app".to_owned(),
            target: target(),
            copy_derivation: CommandSpec::new(
                "nix",
                strings(&["copy", "--to", "ssh-ng://builder", "/nix/store/abc.drv"]),
            ),
            build: CommandSpec::new(
                "nix",
                strings(&["build", "--no-link", "--print-out-paths", "drv^out"]),
            ),
            retry: RetryPolicy::new(3, Duration::from_secs(2)).unwrap(),
        })
        .unwrap();
    assert_eq!(
        result.output.unwrap().path.as_str(),
        "/nix/store/def-nixos-system-new"
    );
    assert_eq!(result.failures.len(), 1);
    assert_eq!(result.failures[0].kind, RemoteFailureKind::DaemonDisconnect);
    assert_eq!(result.status, CommandStatus::Success);

    let runner = runtime.into_runner();
    assert_eq!(runner.requests.len(), 3);
    assert_eq!(runner.waits, vec![Duration::from_secs(2)]);
    assert!(runner.requests[0].label.contains("copy-derivation"));
    assert!(runner.requests[0].label.contains("app"));
    assert!(runner.requests[1].label.contains("via"));
    assert!(runner.requests[1].label.contains("app"));
    assert!(
        runner.requests[1]
            .stdin
            .as_ref()
            .unwrap()
            .contains("base64 -d")
    );
}

#[test]
fn remote_build_reports_action_failure_without_cleanup_side_effects() {
    let runner = FakeRunner::with_outputs([success(""), failure(7, "build failed")]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let result = runtime
        .remote_build(RemoteBuildRequest {
            subject: "app".to_owned(),
            target: target(),
            copy_derivation: CommandSpec::new(
                "nix",
                strings(&["copy", "--to", "ssh-ng://builder", "/nix/store/abc.drv"]),
            ),
            build: CommandSpec::new("nix", strings(&["build", "drv^out"])),
            retry: RetryPolicy::new(1, Duration::ZERO).unwrap(),
        })
        .unwrap();
    assert_eq!(result.status, CommandStatus::Exit(7));
    assert_eq!(runtime.into_runner().requests.len(), 2);
}

#[test]
fn remote_build_preserves_derivation_copy_failure_output() {
    let runner = FakeRunner::with_outputs([failure(
        1,
        "ControlPath too long ('/very/long/control/socket' >= 108 bytes)",
    )]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let error = runtime
        .remote_build(RemoteBuildRequest {
            subject: "app".to_owned(),
            target: target(),
            copy_derivation: CommandSpec::new(
                "nix",
                strings(&["copy", "--to", "ssh-ng://builder", "/nix/store/abc.drv"]),
            ),
            build: CommandSpec::new("nix", strings(&["build", "drv^out"])),
            retry: RetryPolicy::new(3, Duration::from_secs(2)).unwrap(),
        })
        .unwrap_err();

    let message = error.to_string();
    assert!(message.contains("remote build derivation copy failed"));
    assert!(message.contains("ControlPath too long"));
    assert!(message.contains("108 bytes"));

    let runner = runtime.into_runner();
    assert_eq!(runner.requests.len(), 1);
    assert!(runner.requests[0].label.contains("copy-derivation"));
    assert!(runner.waits.is_empty());
}

#[test]
fn dry_run_executes_remote_builder_store_effects() {
    let runner =
        FakeRunner::with_outputs([success(""), success("/nix/store/def-nixos-system-new\n")]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::Yes).unwrap();
    let result = runtime
        .remote_build(RemoteBuildRequest {
            subject: "app".to_owned(),
            target: target(),
            copy_derivation: CommandSpec::new(
                "nix",
                strings(&["copy", "--to", "ssh-ng://builder", "/nix/store/abc.drv"]),
            ),
            build: CommandSpec::new(
                "nix",
                strings(&["build", "--no-link", "--print-out-paths", "drv^out"]),
            ),
            retry: RetryPolicy::new(1, Duration::ZERO).unwrap(),
        })
        .unwrap();
    assert_eq!(result.status, CommandStatus::Success);
    assert_eq!(
        result.output.unwrap().path.as_str(),
        "/nix/store/def-nixos-system-new"
    );
    let requests = runtime.into_runner().requests;
    assert_eq!(requests.len(), 2);
    assert!(
        requests
            .iter()
            .all(|request| request.effect == EffectKind::Build)
    );
}

#[test]
fn builder_lease_ssh_is_dedicated_and_generation_independent() {
    let mut target = target();
    target = target
        .with_control_master(PathBuf::from("/tmp/control"), 120)
        .unwrap();
    let tools = build_runtime::RemoteBuildTools::new(
        "/run/current-system/sw/bin/nix",
        "/run/current-system/sw/bin/bash",
        "/run/current-system/sw/bin/flock",
        "/nix/var/nix",
    )
    .unwrap();
    let spec = builder_lease_process_spec(&target, &tools).unwrap();
    assert_eq!(spec.program, "ssh");
    assert!(spec.args.contains(&"ControlMaster=no".to_owned()));
    assert!(spec.args.contains(&"ControlPath=none".to_owned()));
    assert!(!spec.args.iter().any(|arg| arg.contains("/tmp/control")));
    let remote = spec.args.last().unwrap();
    assert!(remote.contains("/run/current-system/sw/bin/bash"));
    assert!(remote.contains("/run/current-system/sw/bin/flock"));
    assert!(remote.contains("/nix/var/nix"));
    assert!(remote.contains("hold"));
    assert!(!remote.contains("abird-nix-build-lease"));
}

#[test]
fn builder_lease_authority_is_semantic_and_ignores_materialized_key_paths() {
    let tools = build_runtime::RemoteBuildTools::new(
        "/run/current-system/sw/bin/nix",
        "/run/current-system/sw/bin/bash",
        "/run/current-system/sw/bin/flock",
        "/nix/var/nix",
    )
    .unwrap();
    let mut first = target();
    first.route.endpoint.identity = Some(PathBuf::from("/tmp/worker-a/builder-key"));
    first.route.proxy.hops.push(ProxyHop {
        node: "jump".into(),
        endpoint: SshEndpoint::new(
            "jump",
            "jump.example",
            "operator",
            2200,
            TransportRole::Operator,
            Some(PathBuf::from("/tmp/worker-a/proxy-key")),
        )
        .unwrap(),
        proxy_command: None,
        local: false,
    });
    first.route.host_key_policy = HostKeyPolicy::AcceptNew;

    let mut rematerialized = first.clone();
    rematerialized.route.endpoint.identity = Some(PathBuf::from("/tmp/worker-b/builder-key"));
    rematerialized.route.proxy.hops[0].endpoint.identity =
        Some(PathBuf::from("/tmp/worker-b/proxy-key"));
    assert_eq!(
        builder_lease_process_spec(&first, &tools)
            .unwrap()
            .authority,
        builder_lease_process_spec(&rematerialized, &tools)
            .unwrap()
            .authority
    );

    let baseline = builder_lease_process_spec(&first, &tools)
        .unwrap()
        .authority;
    let mut changed_routes = Vec::new();
    let mut changed = first.clone();
    changed.route.endpoint.node = "other-builder".into();
    changed_routes.push(changed);
    let mut changed = first.clone();
    changed.route.endpoint.host = "builder.example".into();
    changed_routes.push(changed);
    let mut changed = first.clone();
    changed.route.endpoint.user = "other-user".into();
    changed_routes.push(changed);
    let mut changed = first.clone();
    changed.route.endpoint.port = 22;
    changed_routes.push(changed);
    let mut changed = first.clone();
    changed.route.endpoint.role = TransportRole::Operator;
    changed_routes.push(changed);
    let mut changed = first.clone();
    changed.route.endpoint.identity = None;
    changed_routes.push(changed);
    let mut changed = first.clone();
    changed.route.proxy.hops[0].endpoint.host = "other-jump.example".into();
    changed_routes.push(changed);
    let mut changed = first.clone();
    changed.route.proxy.hops[0].node = "other-jump".into();
    changed_routes.push(changed);
    let mut changed = first.clone();
    changed.route.proxy.hops[0].endpoint.user = "other-operator".into();
    changed_routes.push(changed);
    let mut changed = first.clone();
    changed.route.proxy.hops[0].endpoint.port = 22;
    changed_routes.push(changed);
    let mut changed = first.clone();
    changed.route.proxy.hops[0].proxy_command =
        Some(ProxyCommandTemplate::new("relay --host %h --port %p").unwrap());
    changed_routes.push(changed);
    let mut changed = first.clone();
    changed.route.proxy_command = Some(ProxyCommandTemplate::new("direct-relay %h %p").unwrap());
    changed_routes.push(changed);
    let mut changed = first.clone();
    changed.route.proxy.hops[0].local = true;
    changed_routes.push(changed);
    let mut changed = first.clone();
    let extra_hop = changed.route.proxy.hops[0].clone();
    changed.route.proxy.hops.push(extra_hop);
    changed_routes.push(changed);
    let mut changed = first.clone();
    changed.route.host_key_policy = HostKeyPolicy::Strict;
    changed_routes.push(changed);

    for changed in changed_routes {
        assert_ne!(
            baseline,
            builder_lease_process_spec(&changed, &tools)
                .unwrap()
                .authority
        );
    }
}

#[test]
fn target_cache_distribution_copies_then_verifies_the_exact_closure() {
    let runner = FakeRunner::with_outputs([success("copied"), success("")]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let closure = NixStorePath::closure_output("/nix/store/def-nixos-system-new").unwrap();
    let cache = CacheSource::new("https://cache.example", ["cache.example-1:key"]).unwrap();
    let result = runtime
        .distribute_closure(
            &target(),
            &DistributionPlan::TargetCachePull {
                closure,
                cache,
                retry: true,
            },
            RetryPolicy::new(3, Duration::from_secs(2)).unwrap(),
        )
        .unwrap();
    assert_eq!(result, host_runtime::DistributionExecution::Complete);
    let runner = runtime.into_runner();
    assert_eq!(runner.requests.len(), 2);
    assert!(runner.requests[0].label.contains("cache-pull"));
    assert!(runner.requests[1].label.contains("closure-verify"));
    assert!(
        !runner.requests[0]
            .stdin
            .as_ref()
            .unwrap()
            .contains("cache.example-1:key")
    );
}

#[test]
fn target_cache_failure_relays_through_the_configured_proxy_chain() {
    let runner = FakeRunner::with_outputs([
        failure(1, "cache DNS failed"),
        success("relayed"),
        success(""),
    ]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let closure = NixStorePath::closure_output("/nix/store/def-nixos-system-new").unwrap();
    let cache = CacheSource::new("https://cache.example", ["cache.example-1:key"]).unwrap();
    let mut proxied = target()
        .with_control_master(PathBuf::from("/tmp/fleet/cm-target"), 120)
        .unwrap();
    proxied.route.proxy.hops.push(ProxyHop {
        node: "jump".into(),
        endpoint: SshEndpoint::new(
            "jump",
            "jump.example",
            "operator",
            2200,
            TransportRole::Operator,
            Some(PathBuf::from("/keys/jump key")),
        )
        .unwrap(),
        proxy_command: None,
        local: false,
    });

    let result = runtime
        .distribute_closure(
            &proxied,
            &DistributionPlan::TryTargetCacheThenRelay {
                closure: closure.clone(),
                cache,
            },
            RetryPolicy::new(3, Duration::from_secs(2)).unwrap(),
        )
        .unwrap();

    assert_eq!(result, host_runtime::DistributionExecution::Complete);
    let runner = runtime.into_runner();
    assert_eq!(runner.requests.len(), 3);
    let relay = &runner.requests[1];
    assert_eq!(relay.program, "nix");
    assert_eq!(relay.label, "relay-cache-to-target-gap3");
    assert!(
        relay
            .args
            .windows(2)
            .any(|pair| pair == ["--from", "https://cache.example"])
    );
    assert!(
        relay
            .args
            .windows(2)
            .any(|pair| pair == ["--to", "ssh-ng://root@192.0.2.42"])
    );
    assert!(
        relay
            .args
            .iter()
            .any(|argument| argument == closure.as_str())
    );
    assert!(
        relay
            .args
            .iter()
            .any(|argument| argument == "cache.example-1:key")
    );
    let options = relay
        .environment
        .iter()
        .find_map(|(name, value)| (name == "NIX_SSHOPTS").then_some(value))
        .unwrap();
    assert!(options.contains("ProxyCommand="), "{options}");
    assert!(options.contains("operator@jump.example"), "{options}");
    assert!(options.contains("/keys/jump key"), "{options}");
    assert!(options.contains("ControlMaster=no"), "{options}");
    assert!(options.contains("ControlPath=none"), "{options}");
    assert!(!options.contains("/tmp/fleet/cm-target"), "{options}");
    assert!(runner.requests[2].label.contains("closure-verify"));
}

#[test]
fn explicit_proxy_command_is_preserved_for_local_cache_relay() {
    let runner = FakeRunner::with_outputs([success("relayed"), success("")]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let closure = NixStorePath::closure_output("/nix/store/def-nixos-system-new").unwrap();
    let cache = CacheSource::new("https://cache.example", std::iter::empty::<String>()).unwrap();
    let mut proxied = target();
    proxied.route.proxy_command =
        Some(ProxyCommandTemplate::new("relay-tool --host %h --port %p").unwrap());

    let result = runtime
        .distribute_closure(
            &proxied,
            &DistributionPlan::RelayThroughLocal { closure, cache },
            RetryPolicy::new(1, Duration::ZERO).unwrap(),
        )
        .unwrap();

    assert_eq!(result, host_runtime::DistributionExecution::Complete);
    let requests = runtime.into_runner().requests;
    let options = requests[0]
        .environment
        .iter()
        .find_map(|(name, value)| (name == "NIX_SSHOPTS").then_some(value))
        .unwrap();
    assert!(
        options.contains("ProxyCommand=relay-tool --host 192.0.2.42 --port 2222"),
        "{options}"
    );
    assert!(requests[1].label.contains("closure-verify"));
}

#[test]
fn cache_relay_retries_only_transport_loss() {
    let runner = FakeRunner::with_outputs([
        failure(255, "Connection reset by peer"),
        success("relayed"),
        success(""),
    ]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let closure = NixStorePath::closure_output("/nix/store/def-nixos-system-new").unwrap();
    let cache = CacheSource::new("https://cache.example", std::iter::empty::<String>()).unwrap();

    let result = runtime
        .distribute_closure(
            &target(),
            &DistributionPlan::RelayThroughLocal { closure, cache },
            RetryPolicy::new(3, Duration::from_secs(2)).unwrap(),
        )
        .unwrap();

    assert_eq!(result, host_runtime::DistributionExecution::Complete);
    let runner = runtime.into_runner();
    assert_eq!(runner.waits, vec![Duration::from_secs(2)]);
    assert_eq!(
        runner
            .requests
            .iter()
            .filter(|request| request.label == "relay-cache-to-target-gap3")
            .count(),
        2
    );
}

#[test]
fn snapshot_admission_activation_observer_and_health_are_ordered() {
    let runner = FakeRunner::with_outputs([
        success("/nix/store/abc-nixos-system-old\n"),
        success(""),
        success(""),
        success(""),
        success("healthy"),
    ]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let mut health = AlwaysHealthy;
    let rollback_factory = |snapshot: &SystemGeneration| rollback_for(snapshot.clone());
    let result = runtime
        .deploy_host(
            &target(),
            &generation("new"),
            SnapshotRequirement::Required,
            true,
            &pre_switch_preparation_command(),
            &activation(ActivationGoal::Switch),
            ActivationGoal::Switch,
            Some(&rollback_factory),
            &[CommandSpec::new("health-probe", Vec::<String>::new())],
            &mut health,
        )
        .unwrap();
    assert_eq!(result, DeployOutcome::Succeeded);

    let runner = runtime.into_runner();
    assert_eq!(runner.requests.len(), 5);
    assert!(runner.requests[0].label.contains("snapshot"));
    assert_eq!(runner.requests[0].program, "timeout");
    assert!(
        runner.requests[0]
            .args
            .iter()
            .any(|argument| argument == "20s")
    );
    assert!(
        runner.requests[0]
            .args
            .iter()
            .any(|argument| argument == "ssh")
    );
    assert!(runner.requests[1].label.contains("pre-switch"));
    assert!(runner.requests[2].label.contains("activation-submit"));
    assert!(runner.requests[3].label.contains("activation-observe"));
    assert!(runner.requests[4].label.contains("health"));
    assert_eq!(
        runner
            .requests
            .iter()
            .map(|request| request.output_policy)
            .collect::<Vec<_>>(),
        vec![
            ProcessOutputPolicy::Curated,
            ProcessOutputPolicy::Curated,
            ProcessOutputPolicy::HiddenProtocol,
            ProcessOutputPolicy::Activation,
            ProcessOutputPolicy::HiddenProtocol,
        ]
    );
}

#[test]
fn pre_switch_failure_does_not_cross_rollback_boundary() {
    let runner = FakeRunner::with_outputs([
        success("/nix/store/abc-nixos-system-old\n"),
        failure(1, "pre-switch failed"),
    ]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let mut health = AlwaysHealthy;
    let rollback_factory = |snapshot: &SystemGeneration| rollback_for(snapshot.clone());
    let result = runtime
        .deploy_host(
            &target(),
            &generation("new"),
            SnapshotRequirement::Required,
            true,
            &pre_switch_preparation_command(),
            &activation(ActivationGoal::Switch),
            ActivationGoal::Switch,
            Some(&rollback_factory),
            &[],
            &mut health,
        )
        .unwrap();
    assert_eq!(
        result,
        DeployOutcome::FailedBeforeActivation(CommandStatus::Exit(1))
    );
    assert_eq!(runtime.into_runner().requests.len(), 2);
}

#[test]
fn generation_admission_rejection_does_not_cross_rollback_boundary() {
    let runner = FakeRunner::with_outputs([
        success("/nix/store/abc-nixos-system-old\n"),
        success(""),
        success(""),
        failure(23, "[generation-admission] rejected-before-switch"),
    ]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let mut health = AlwaysHealthy;
    let rollback_factory = |snapshot: &SystemGeneration| rollback_for(snapshot.clone());
    let result = runtime
        .deploy_host(
            &target(),
            &generation("new"),
            SnapshotRequirement::Required,
            true,
            &pre_switch_preparation_command(),
            &activation(ActivationGoal::Switch),
            ActivationGoal::Switch,
            Some(&rollback_factory),
            &[],
            &mut health,
        )
        .unwrap();
    assert_eq!(
        result,
        DeployOutcome::FailedBeforeActivation(CommandStatus::Exit(23))
    );
    let requests = runtime.into_runner().requests;
    assert_eq!(requests.len(), 4);
    assert!(
        !requests
            .iter()
            .any(|request| request.label.contains("rollback"))
    );
}

#[test]
fn failure_after_activation_admission_runs_rollback_submit_and_observer() {
    let runner = FakeRunner::with_outputs([
        success("/nix/store/abc-nixos-system-old\n"),
        success(""),
        success(""),
        failure(1, "activation failed"),
        success(""),
        success(""),
    ]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let mut health = AlwaysHealthy;
    let rollback_generations = RefCell::new(Vec::new());
    let rollback_factory = |snapshot: &SystemGeneration| {
        rollback_generations
            .borrow_mut()
            .push(snapshot.as_str().to_owned());
        rollback_for(snapshot.clone())
    };
    let result = runtime
        .deploy_host(
            &target(),
            &generation("new"),
            SnapshotRequirement::Required,
            true,
            &pre_switch_preparation_command(),
            &activation(ActivationGoal::Switch),
            ActivationGoal::Switch,
            Some(&rollback_factory),
            &[],
            &mut health,
        )
        .unwrap();
    assert_eq!(
        result,
        DeployOutcome::RolledBack {
            activation: CommandStatus::Exit(1),
            rollback: CommandStatus::Success,
        }
    );
    let labels = runtime
        .into_runner()
        .requests
        .into_iter()
        .map(|request| request.label)
        .collect::<Vec<_>>();
    assert!(labels[4].contains("rollback-submit"));
    assert!(labels[5].contains("rollback-observe"));
    assert_eq!(
        rollback_generations.into_inner(),
        vec!["/nix/store/abc-nixos-system-old"]
    );
}

#[test]
fn explicit_pre_admission_failure_does_not_trigger_verification_or_rollback() {
    let runner = FakeRunner::with_outputs([
        success(""),
        failure(
            1,
            "--- abird-activation-result begin ---\nOutcomeSource=marker\nResult=exit-code\nExecMainStatus=1\nAdmitted=0\n--- abird-activation-result end ---\n",
        ),
    ]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();

    assert_eq!(
        runtime
            .activate(
                &target(),
                &activation(ActivationGoal::Switch),
                &generation("new"),
                ActivationGoal::Switch,
                "activation",
            )
            .unwrap(),
        ActivationExecution::Failed {
            status: CommandStatus::Exit(1),
            admitted: false,
        }
    );
    let requests = runtime.into_runner().requests;
    assert_eq!(requests.len(), 2);
    assert!(
        !requests
            .iter()
            .any(|request| request.label.contains("verify"))
    );
    assert!(
        !requests
            .iter()
            .any(|request| request.label.contains("rollback"))
    );
}

#[test]
fn transport_loss_after_submission_can_be_recovered_by_authoritative_verification() {
    let marker = "OutcomeSource=marker\nResult=success\nExecMainStatus=0\nCurrentSystemPath=/nix/store/abc-nixos-system-new\nSystemProfilePath=/nix/store/abc-nixos-system-new\n";
    let runner = FakeRunner::with_outputs([
        success(""),
        failure(255, "Connection reset by peer"),
        success(marker),
    ]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    assert_eq!(
        runtime
            .activate(
                &target(),
                &activation(ActivationGoal::Switch),
                &generation("new"),
                ActivationGoal::Switch,
                "activation",
            )
            .unwrap(),
        ActivationExecution::SucceededAfterVerification
    );
    let runner = runtime.into_runner();
    assert_eq!(runner.requests[2].program, "timeout");
    assert!(
        runner.requests[2]
            .args
            .iter()
            .any(|argument| argument == "20s")
    );
}

#[test]
fn dry_run_executes_evaluation_and_build_but_no_target_mutation() {
    let runner = FakeRunner::with_outputs([
        success("/nix/store/abc-system.drv"),
        success("/nix/store/abc-system"),
    ]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::Yes).unwrap();
    let eval = build_plan_evaluation_command("nix", &[], BuildPlanAttribute::Native, "gap3");
    assert!(
        runtime
            .evaluate_build_plan(&eval)
            .unwrap()
            .executed()
            .is_some()
    );

    let build = CommandSpec::new("nix", strings(&["build", "drv^out"]));
    assert_eq!(
        runtime.local_build(&build).unwrap().executed().unwrap(),
        NixStorePath::closure_output("/nix/store/abc-system").unwrap()
    );
    assert!(
        runtime
            .prepare_switch(&target(), &pre_switch_preparation_command())
            .unwrap()
            .skipped
    );
    assert_eq!(
        runtime
            .activate(
                &target(),
                &activation(ActivationGoal::Switch),
                &generation("new"),
                ActivationGoal::Switch,
                "activation",
            )
            .unwrap(),
        ActivationExecution::DryRun
    );
    let requests = runtime.into_runner().requests;
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].effect, EffectKind::ReadOnly);
    assert_eq!(requests[1].effect, EffectKind::Build);
}

#[test]
fn forced_command_check_rejects_shell_metacharacters_and_preserves_safe_arguments() {
    let runner = FakeRunner::with_outputs([success("ready")]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let safe = ForcedCommandPlan {
        ssh_target: "nixbot@host".into(),
        ssh_args: strings(&["-F", "/dev/null"]),
        remote_command: strings(&[
            "/run/current-system/sw/bin/nixbot",
            "check-bootstrap",
            "--hosts",
            "gap3",
        ]),
    };
    assert!(runtime.check_bootstrap(&safe).unwrap().succeeded());
    let request = &runtime.runner().requests[0];
    assert_eq!(request.args.last().unwrap(), "gap3");

    let unsafe_plan = ForcedCommandPlan {
        remote_command: strings(&["nixbot", "check-bootstrap", "--hosts", "gap3;reboot"]),
        ..safe
    };
    assert!(runtime.check_bootstrap(&unsafe_plan).is_err());
    assert_eq!(runtime.into_runner().requests.len(), 1);
}

struct AlwaysHealthy;

impl HealthEvaluator for AlwaysHealthy {
    fn evaluate(&mut self, _samples: &[ProcessOutput]) -> anyhow::Result<HealthDecision> {
        Ok(HealthDecision::Healthy {
            evidence: Vec::new(),
        })
    }
}

struct Unhealthy;

impl HealthEvaluator for Unhealthy {
    fn evaluate(&mut self, _samples: &[ProcessOutput]) -> anyhow::Result<HealthDecision> {
        Ok(HealthDecision::ServiceFailure {
            evidence: vec![HealthEvidence::DeploymentWorkSettling],
        })
    }
}

#[test]
fn post_switch_health_runs_remote_probes_then_uses_pure_health_decision() {
    let runner = FakeRunner::with_outputs([success("unit data"), success("podman data")]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let commands = vec![
        CommandSpec::new("systemctl", strings(&["show", "app.service"])),
        CommandSpec::new("podman", strings(&["ps", "--format", "json"])),
    ];
    let result = runtime
        .post_switch_health(&target(), &commands, &mut Unhealthy)
        .unwrap();
    assert!(matches!(result, HealthDecision::ServiceFailure { .. }));
    assert_eq!(runtime.into_runner().requests.len(), 2);
}

#[test]
fn deploy_control_and_health_commands_use_root_execution_on_non_root_targets() {
    let runner = FakeRunner::with_outputs([success(""), success("unit data")]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let target = target_as("nixbot");
    runtime
        .prepare_switch(&target, &pre_switch_preparation_command())
        .unwrap();
    runtime
        .post_switch_health(
            &target,
            &[CommandSpec::new(
                "systemctl",
                strings(&["show", "app.service"]),
            )],
            &mut AlwaysHealthy,
        )
        .unwrap();

    let requests = runtime.into_runner().requests;
    assert_eq!(requests.len(), 2);
    for request in &requests {
        let argv = framed_remote_argv(request);
        assert_eq!(argv[0], "/run/wrappers/bin/sudo");
        assert_eq!(argv[1], "-n");
        assert_eq!(argv[3], "/run/current-system/sw/bin/env");
        assert_eq!(argv[5], "PATH=/run/wrappers/bin:/run/current-system/sw/bin");
    }
}

#[test]
fn concrete_health_probe_validates_systemd_agent_and_podman_evidence() {
    let mut probe = SystemHealthProbe::new(
        ["app.service".to_owned()],
        ["held.service".to_owned()],
        true,
        true,
    )
    .unwrap();
    let commands = probe.commands();
    assert_eq!(commands.len(), 6);
    assert_eq!(commands[0].program, "systemctl");
    assert_eq!(
        commands[2].program,
        "/run/current-system/sw/bin/abird-host-agent"
    );
    assert_eq!(commands[4].program, "podman");

    let samples = vec![
        success(
            "Id=app.service\nLoadState=loaded\nActiveState=active\nSubState=running\nNeedDaemonReload=no\n\nId=held.service\nLoadState=loaded\nActiveState=inactive\nSubState=dead\nNeedDaemonReload=no\n",
        ),
        success(""),
        success(r#"{"ok":true,"operation":"hold_list","result":{"holds":[]}}"#),
        success(
            r#"{"ok":true,"operation":"agent_status","result":{"status_schema_version":2,"deferred_resources":{"count":0,"resources":[]}}}"#,
        ),
        success(""),
        success(""),
    ];
    assert!(matches!(
        probe.evaluate(&samples).unwrap(),
        HealthDecision::Healthy { .. }
    ));
}

#[test]
fn concrete_health_probe_fails_closed_on_missing_required_evidence() {
    let mut probe = SystemHealthProbe::new(
        ["app.service".to_owned()],
        Vec::<String>::new(),
        false,
        false,
    )
    .unwrap();
    let malformed = vec![
        success("Id=app.service\nLoadState=loaded\nSubState=running\nNeedDaemonReload=no\n"),
        success(""),
    ];
    assert!(probe.evaluate(&malformed).is_err());
    assert!(
        probe
            .evaluate(&[failure(1, "systemctl failed"), success("")])
            .is_err()
    );
}

#[test]
fn optional_host_agent_probe_accepts_absence_but_not_partial_or_invalid_evidence() {
    let mut probe =
        SystemHealthProbe::new(Vec::<String>::new(), Vec::<String>::new(), false, false)
            .unwrap()
            .with_optional_host_agent();
    let commands = probe.commands();
    assert_eq!(commands.len(), 3);
    assert_eq!(commands[1].program, "/run/current-system/sw/bin/bash");
    assert!(commands[1].args[1].contains("abird-host-agent"));
    assert!(matches!(
        probe
            .evaluate(&[
                success(""),
                success("__ABIRD_HOST_AGENT_ABSENT__\n"),
                success("__ABIRD_HOST_AGENT_ABSENT__\n"),
            ])
            .unwrap(),
        HealthDecision::Healthy { .. }
    ));
    assert!(
        probe
            .evaluate(&[
                success(""),
                success("__ABIRD_HOST_AGENT_ABSENT__\n"),
                success(r#"{"ok":true}"#),
            ])
            .is_err()
    );
}

fn health_record(kind: &str, fields: &[&str]) -> String {
    let suffix = fields
        .iter()
        .map(|field| base64::engine::general_purpose::STANDARD.encode(field))
        .collect::<Vec<_>>()
        .join("\t");
    if suffix.is_empty() {
        format!("{kind}\n")
    } else {
        format!("{kind}\t{suffix}\n")
    }
}

#[test]
fn managed_health_runtime_retries_settling_units_then_converges() {
    let settling = [
        health_record("hold-absent", &[]),
        health_record("status-absent", &[]),
        health_record("user", &["app", "1000", "active", "ok", "ok"]),
        health_record("expected-unit", &["app", "app.service"]),
        health_record(
            "unit",
            &[
                "app",
                "expected",
                "app.service",
                "loaded",
                "activating",
                "start",
                "no",
                "30",
            ],
        ),
    ]
    .concat();
    let healthy = [
        health_record("hold-absent", &[]),
        health_record("status-absent", &[]),
        health_record("user", &["app", "1000", "active", "ok", "ok"]),
        health_record("expected-unit", &["app", "app.service"]),
        health_record(
            "unit",
            &[
                "app",
                "expected",
                "app.service",
                "loaded",
                "active",
                "running",
                "no",
                "30",
            ],
        ),
    ]
    .concat();
    let runner = FakeRunner::with_outputs([success(&settling), success(&healthy)]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let report = health_runtime::check_managed_health(&mut runtime, &target()).unwrap();
    assert!(matches!(report.decision, HealthDecision::Healthy { .. }));
    assert_eq!(report.attempts, 2);
    let runner = runtime.into_runner();
    assert_eq!(runner.waits, [Duration::from_secs(5)]);
    assert_eq!(runner.requests.len(), 2);
    assert_eq!(runner.requests[0].program, "timeout");
    assert!(runner.requests[0].args.iter().any(|arg| arg == "20s"));
}

#[test]
fn managed_health_runtime_preserves_ignored_system_failure_with_healthy_verdict() {
    let ignored_unit = "systemd-backlight@backlight:nvidia_wmi_ec_backlight.service";
    let ignored_failure = format!("{ignored_unit} loaded failed failed NVIDIA WMI backlight");
    let healthy = [
        health_record("hold-absent", &[]),
        health_record("status-absent", &[]),
        health_record("system-failed", &[&ignored_failure]),
    ]
    .concat();
    let runner = FakeRunner::with_outputs([success(&healthy)]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let report = health_runtime::check_managed_health_with_ignored_system_units(
        &mut runtime,
        &target(),
        &BTreeSet::from([ignored_unit.to_owned()]),
    )
    .unwrap();

    assert!(matches!(report.decision, HealthDecision::Healthy { .. }));
    assert_eq!(report.ignored_system_failures, [ignored_failure]);
}

#[test]
fn managed_health_runtime_turns_expired_settling_into_service_failure() {
    let settling = [
        health_record("hold-absent", &[]),
        health_record("status-absent", &[]),
        health_record("user", &["app", "1000", "active", "ok", "ok"]),
        health_record(
            "user-transition",
            &["app", "app.service", "activating/start", ""],
        ),
        health_record("timeout", &["1"]),
    ]
    .concat();
    let runner = FakeRunner::with_outputs([success(&settling), success(&settling)]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let report = health_runtime::check_managed_health(&mut runtime, &target()).unwrap();
    assert!(matches!(
        report.decision,
        HealthDecision::ServiceFailure { .. }
    ));
    assert_eq!(report.attempts, 2);
    assert_eq!(report.readiness_budget.unwrap().timeout_seconds, 1);
}

#[derive(Default)]
struct RecordingObserver {
    events: Mutex<Vec<String>>,
}

impl ProcessEventObserver for RecordingObserver {
    fn started(&self, request: &ProcessRequest) {
        self.events
            .lock()
            .unwrap()
            .push(format!("start:{}", request.label));
    }

    fn output(&self, request: &ProcessRequest, stream: ProcessStream, chunk: &str) {
        self.events.lock().unwrap().push(format!(
            "output:{}:{stream:?}:{}",
            request.label,
            chunk.trim_end()
        ));
    }

    fn finished(
        &self,
        request: &ProcessRequest,
        _elapsed: Duration,
        completion: ProcessCompletion,
    ) {
        self.events
            .lock()
            .unwrap()
            .push(format!("finish:{}:{completion:?}", request.label));
    }

    fn heartbeat_interval(&self, request: &ProcessRequest) -> Option<Duration> {
        (request.label == "heartbeat").then(|| Duration::from_millis(20))
    }

    fn heartbeat(&self, request: &ProcessRequest, _elapsed: Duration) {
        self.events
            .lock()
            .unwrap()
            .push(format!("heartbeat:{}", request.label));
    }
}

#[test]
fn reporting_process_runner_streams_both_channels_and_retains_exact_output() {
    let observer = Arc::new(RecordingObserver::default());
    let mut runner = ReportingProcessRunner::new(observer.clone());
    let output = runner
        .run(&ProcessRequest {
            program: "/bin/sh".to_owned(),
            args: strings(&["-c", "printf 'one\\ntwo'; printf 'bad\\n' >&2"]),
            environment: Vec::new(),
            clear_git_repository_environment: false,
            cwd: PathBuf::from("/"),
            stdin: None,
            effect: EffectKind::ReadOnly,
            output_policy: ProcessOutputPolicy::Curated,
            label: "probe alpha".to_owned(),
            host: None,
        })
        .unwrap();

    assert!(output.succeeded());
    assert_eq!(output.stdout, "one\ntwo");
    assert_eq!(output.stderr, "bad\n");
    let events = observer.events.lock().unwrap();
    assert_eq!(events.first().unwrap(), "start:probe alpha");
    assert!(events.contains(&"output:probe alpha:Stdout:one".to_owned()));
    assert!(events.contains(&"output:probe alpha:Stdout:two".to_owned()));
    assert!(events.contains(&"output:probe alpha:Stderr:bad".to_owned()));
    assert_eq!(events.last().unwrap(), "finish:probe alpha:Succeeded");
}

fn git_environment_request(clear_git_repository_environment: bool) -> ProcessRequest {
    ProcessRequest {
        program: "env".to_owned(),
        args: Vec::new(),
        environment: vec![
            ("GIT_DIR".to_owned(), "/incorrect/repository".to_owned()),
            ("GIT_WORK_TREE".to_owned(), "/incorrect/worktree".to_owned()),
        ],
        clear_git_repository_environment,
        cwd: PathBuf::from("/"),
        stdin: None,
        effect: EffectKind::ReadOnly,
        output_policy: ProcessOutputPolicy::Curated,
        label: "repository-environment".to_owned(),
        host: None,
    }
}

fn assert_no_git_checkout_selectors(output: &ProcessOutput) {
    assert!(output.succeeded());
    for selector in ["GIT_DIR", "GIT_WORK_TREE"] {
        assert!(
            !output
                .stdout
                .lines()
                .any(|line| line.starts_with(&format!("{selector}="))),
            "{selector} reached the child process"
        );
    }
}

#[test]
fn local_repository_processes_clear_git_selectors_after_request_environment() {
    let request = git_environment_request(true);
    assert_no_git_checkout_selectors(&SystemProcessRunner.run(&request).unwrap());

    let observer = Arc::new(RecordingObserver::default());
    let mut reporting = ReportingProcessRunner::new(observer);
    assert_no_git_checkout_selectors(&reporting.run(&request).unwrap());

    let inherited = SystemProcessRunner
        .run(&git_environment_request(false))
        .unwrap();
    assert!(inherited.stdout.contains("GIT_DIR=/incorrect/repository\n"));
    assert!(
        inherited
            .stdout
            .contains("GIT_WORK_TREE=/incorrect/worktree\n")
    );
}

#[test]
fn reporting_process_runner_emits_configured_heartbeats_for_quiet_commands() {
    let observer = Arc::new(RecordingObserver::default());
    let mut runner = ReportingProcessRunner::new(observer.clone());
    let output = runner
        .run(&ProcessRequest {
            program: "/bin/sh".to_owned(),
            args: strings(&["-c", "sleep 0.12"]),
            environment: Vec::new(),
            clear_git_repository_environment: false,
            cwd: PathBuf::from("/"),
            stdin: None,
            effect: EffectKind::ReadOnly,
            output_policy: ProcessOutputPolicy::Curated,
            label: "heartbeat".to_owned(),
            host: None,
        })
        .unwrap();
    assert!(output.succeeded());
    assert!(
        observer
            .events
            .lock()
            .unwrap()
            .contains(&"heartbeat:heartbeat".to_owned())
    );
}

struct TimedCancellation {
    started: Instant,
    delay: Duration,
    activations: AtomicUsize,
    force: AtomicBool,
}

impl ProcessCancellation for TimedCancellation {
    fn activation_started(&self) {
        self.activations.fetch_add(1, Ordering::Relaxed);
    }

    fn activation_finished(&self) {
        self.activations.fetch_sub(1, Ordering::Relaxed);
    }

    fn cancel_local(&self) -> bool {
        self.started.elapsed() >= self.delay
    }

    fn force_remote(&self) -> bool {
        self.force.load(Ordering::Relaxed)
    }
}

#[test]
fn reporting_process_runner_terminates_the_complete_child_process_group() {
    let observer = Arc::new(RecordingObserver::default());
    let cancellation = Arc::new(TimedCancellation {
        started: Instant::now(),
        delay: Duration::from_millis(50),
        activations: AtomicUsize::new(0),
        force: AtomicBool::new(false),
    });
    let mut runner = ReportingProcessRunner::new(observer).with_cancellation(cancellation);
    let started = Instant::now();
    let output = runner
        .run(&ProcessRequest {
            program: "/bin/sh".to_owned(),
            args: strings(&["-c", "sleep 30 & wait"]),
            environment: Vec::new(),
            clear_git_repository_environment: false,
            cwd: PathBuf::from("/"),
            stdin: None,
            effect: EffectKind::ReadOnly,
            output_policy: ProcessOutputPolicy::Curated,
            label: "long probe".to_owned(),
            host: None,
        })
        .unwrap();
    assert!(started.elapsed() < Duration::from_secs(3));
    assert!(matches!(output.status, ProcessStatus::Signal(_)));
}
