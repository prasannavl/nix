use std::collections::BTreeMap;
use std::process::Command;

use abird_host_agent::build_executor::strategy::{
    AGENT_BACKEND_ONLY, AGENT_CI_DEFERRED, AGENT_EXPERIMENTAL, Strategy,
};
use abird_host_manager::fleet::cli::Invocation;
use abird_host_manager::fleet::engine::{self, FleetEffects, PhaseFailure};
use abird_host_manager::fleet::environment::Environment;
use abird_host_manager::fleet::plan::Phase;
use anyhow::Result;
use serde::Deserialize;

#[derive(Deserialize)]
struct Contract {
    agent_ci_deferred: String,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    environment: Option<String>,
    args: Vec<String>,
    #[serde(default)]
    parse_error: bool,
    requested: Option<String>,
    forwarded: Option<String>,
    effective: Option<String>,
}

#[test]
fn shared_bash_and_native_strategy_contract() {
    let contract: Contract =
        serde_json::from_str(include_str!("fixtures/build-strategies.json")).unwrap();
    assert_eq!(contract.agent_ci_deferred, AGENT_CI_DEFERRED);
    for case in contract.cases {
        let environment = Environment::from_map(
            case.environment
                .clone()
                .map(|value| ("NIXBOT_STRATEGY".to_owned(), value))
                .into_iter()
                .collect::<BTreeMap<_, _>>(),
        );
        let arguments = std::iter::once("build".to_owned())
            .chain(case.args)
            .collect::<Vec<_>>();
        for parsed in [
            Invocation::parse_legacy_with_environment(arguments.clone(), &environment),
            Invocation::parse_canonical_with_environment(
                std::iter::once("fleet".to_owned()).chain(arguments.clone()),
                &environment,
            ),
        ] {
            if case.parse_error {
                assert!(parsed.is_err(), "{}", case.name);
                continue;
            }
            let invocation = parsed.unwrap_or_else(|error| panic!("{}: {error}", case.name));
            assert_eq!(
                Some(invocation.options.strategy.as_str()),
                case.requested.as_deref(),
                "{}",
                case.name
            );
            assert_eq!(
                invocation
                    .options
                    .forwarded_strategy()
                    .map(Strategy::wire_name),
                case.forwarded.as_deref(),
                "{}",
                case.name
            );
            assert_eq!(
                invocation
                    .resolve_build_strategy()
                    .unwrap()
                    .map(|strategy| strategy.as_str()),
                case.effective.as_deref(),
                "{}",
                case.name
            );
        }
    }
}

struct NoEffects;

impl FleetEffects for NoEffects {
    fn run_phase(&mut self, _phase: Phase) -> std::result::Result<(), PhaseFailure> {
        panic!("agent strategy must never enter the nix phase engine")
    }

    fn rollback(&mut self, _failed_phase: Phase) -> Result<()> {
        panic!("rejected strategy must not roll back targets")
    }
}

#[test]
fn owned_cannot_enter_the_phase_engine_including_dry_and_forwarding_options() {
    for action in ["run", "deploy", "build", "dev-build"] {
        for dry in [false, true] {
            let mut invocation = Invocation::parse_legacy([action, "--strategy=agent"]).unwrap();
            invocation.options.dry_run = dry;
            for ci_trigger in [false, true] {
                invocation.options.ci_trigger = ci_trigger;
                assert_eq!(
                    engine::execute(&invocation, &mut NoEffects)
                        .unwrap_err()
                        .to_string(),
                    AGENT_BACKEND_ONLY
                );
            }
        }
    }
}

#[test]
fn build_strategy_does_not_gate_unrelated_actions() {
    for action in [
        "help",
        "version",
        "deps",
        "check-deps",
        "repo",
        "--list-hosts",
        "--list-groups",
        "tf",
        "tf-dns",
        "tf-platform",
        "tf-apps",
        "tf/custom",
        "clean",
        "check-bootstrap",
    ] {
        let mut arguments = vec![action];
        if action == "repo" {
            arguments.push("sync");
        }
        arguments.push("--strategy=agent");
        let invocation = Invocation::parse_legacy(arguments).unwrap();
        assert_eq!(
            invocation.resolve_build_strategy().unwrap(),
            None,
            "{action}"
        );
    }
}

#[test]
fn real_forced_command_entrypoint_preserves_owned_selection() {
    use abird_host_manager::fleet::repository::encode_argv;

    let root = tempfile::tempdir().unwrap();
    let arguments = ["build", "--strategy=agent", "--dry"].map(str::to_owned);
    for original in [
        format!("__nixbot_argv64 {}", encode_argv(&arguments)),
        "build --strategy=agent --dry".to_owned(),
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_nixbot"))
            .env_clear()
            .env("PATH", "/no-external-programs")
            .env("HOME", root.path())
            .env("SSH_ORIGINAL_COMMAND", original)
            .env(
                "NIXBOT_HOST_LOCAL_LOCK_PATH",
                root.path().join("action-lock"),
            )
            .env("NIXBOT_RUNTIME_WORK_ROOT", root.path().join("runtime"))
            .env("NIXBOT_RUNTIME_FALLBACK_ROOT", root.path().join("fallback"))
            .env("NIXBOT_DIAG_KEEP_ROOT", root.path().join("diagnostics"))
            .current_dir(root.path())
            .output()
            .unwrap();
        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("compatible installed native consumer adapter"),
            "{stderr}"
        );
        assert_eq!(root.path().read_dir().unwrap().count(), 0);
    }
}

#[test]
fn real_entrypoints_without_native_consumer_reject_agent_before_effects() {
    let root = tempfile::tempdir().unwrap();
    for (program, prefix) in [
        (env!("CARGO_BIN_EXE_nixbot"), [].as_slice()),
        (
            env!("CARGO_BIN_EXE_abird-host-manager"),
            ["fleet"].as_slice(),
        ),
    ] {
        for action in ["run", "deploy", "build", "dev-build"] {
            for flags in [
                vec!["--strategy=agent"],
                vec!["--strategy=agent", "--dry"],
                vec![],
            ] {
                let output = Command::new(program)
                    .env_clear()
                    .env("PATH", "/no-external-programs")
                    .env("HOME", root.path())
                    .env("NIXBOT_STRATEGY", "agent")
                    .env(
                        "NIXBOT_HOST_LOCAL_LOCK_PATH",
                        root.path().join("action-lock"),
                    )
                    .env("NIXBOT_RUNTIME_WORK_ROOT", root.path().join("runtime"))
                    .env("NIXBOT_RUNTIME_FALLBACK_ROOT", root.path().join("fallback"))
                    .env("NIXBOT_DIAG_KEEP_ROOT", root.path().join("diagnostics"))
                    .current_dir(root.path())
                    .args(prefix)
                    .arg(action)
                    .args(flags)
                    .output()
                    .unwrap();
                assert!(!output.status.success());
                let stderr = String::from_utf8_lossy(&output.stderr);
                // Explicit experimental backend; without the installed profile
                // it fails closed (Run first, as no handoff exists for it).
                assert!(
                    stderr.contains(AGENT_EXPERIMENTAL)
                        && if action == "run" {
                            stderr.contains("run Terraform separately")
                        } else {
                            stderr.contains("compatible installed native consumer adapter")
                        },
                    "{action}: {stderr}"
                );
                assert_eq!(
                    root.path().read_dir().unwrap().count(),
                    0,
                    "no allocated state before rejection"
                );
            }
        }
    }
}
