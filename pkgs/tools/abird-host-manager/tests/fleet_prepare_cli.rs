use std::collections::BTreeMap;

use abird_host_agent::build_executor::strategy::{ExecutionStrategy, Strategy};
use abird_host_manager::fleet::cli::{Action, Invocation, Options};
use abird_host_manager::fleet::environment::Environment;
use abird_host_manager::fleet::plan::{Phase, WorkflowPlan};

#[test]
fn prepare_is_a_build_strategy_action_on_both_surfaces() {
    let canonical = Invocation::parse_canonical(["fleet", "prepare", "--host=app"]).unwrap();
    let legacy = Invocation::parse_legacy(["nixbot", "prepare", "--host=app"]).unwrap();
    assert_eq!(canonical, legacy);
    assert_eq!(canonical.action, Action::Prepare);
    assert!(canonical.action.uses_build_strategy());
    assert_eq!(
        canonical.resolve_build_strategy().unwrap(),
        Some(ExecutionStrategy::Nix)
    );
    assert_eq!(
        WorkflowPlan::for_action(&canonical.action).phases,
        [Phase::Build, Phase::Acquire]
    );
    canonical.validate_execution_support().unwrap();
}

#[test]
fn job_aliases_preserve_option_order_and_validate_the_final_initial_limit() {
    for canonical_surface in [true, false] {
        let parse = |arguments: Vec<&str>| {
            if canonical_surface {
                Invocation::parse_canonical(arguments)
            } else {
                Invocation::parse_legacy(arguments)
            }
        };
        let aliases = parse(vec![
            "prepare",
            "--jobs=10",
            "--jobs-per-domain=2",
            "--jobs-per-domain-max=6",
        ])
        .unwrap();
        let canonical = parse(vec![
            "prepare",
            "--deploy-jobs=10",
            "--deploy-jobs-per-domain=2",
            "--deploy-jobs-per-domain-max=6",
        ])
        .unwrap();
        assert_eq!(aliases, canonical);
        assert_eq!(aliases.options.deploy_jobs, 10);
        assert_eq!(aliases.options.deploy_jobs_per_domain, 2);
        assert_eq!(aliases.options.deploy_jobs_per_domain_max, Some(6));
        let ordered = parse(vec![
            "prepare",
            "--jobs-per-domain-max=4",
            "--jobs-per-domain=2",
            "--jobs=3",
        ])
        .unwrap();
        assert_eq!(ordered.options.deploy_jobs_per_domain, 2);
        assert!(
            parse(vec![
                "prepare",
                "--jobs-per-domain=3",
                "--jobs-per-domain-max=2"
            ])
            .is_err()
        );
        // Inventory may supply a smaller initial domain allowance than --jobs.
        assert!(parse(vec!["prepare", "--jobs=8", "--jobs-per-domain-max=4"]).is_ok());
        for invalid in ["0", "-1", "no", "1.5", ""] {
            let flag = format!("--jobs-per-domain-max={invalid}");
            assert!(parse(vec!["prepare", &flag]).is_err());
        }
    }
}

#[test]
fn environment_maximum_is_optional_and_cli_wins() {
    let environment = Environment::from_map(BTreeMap::from([
        ("NIXBOT_JOBS".into(), "12".into()),
        ("NIXBOT_JOBS_PER_DOMAIN".into(), "3".into()),
        ("NIXBOT_JOBS_PER_DOMAIN_MAX".into(), "7".into()),
    ]));
    let inherited = Invocation::parse_legacy_with_environment(["prepare"], &environment).unwrap();
    assert_eq!(inherited.options.deploy_jobs_per_domain_max, Some(7));
    let overridden = Invocation::parse_canonical_with_environment(
        ["prepare", "--jobs-per-domain-max=4"],
        &environment,
    )
    .unwrap();
    assert_eq!(overridden.options.deploy_jobs_per_domain_max, Some(4));
    assert!(
        Invocation::parse_legacy_with_environment(["prepare", "--jobs-per-domain=8"], &environment)
            .is_err()
    );
    let invalid = Environment::from_map(BTreeMap::from([(
        "NIXBOT_JOBS_PER_DOMAIN_MAX".into(),
        "0".into(),
    )]));
    assert!(Invocation::parse_legacy_with_environment(["prepare"], &invalid).is_err());
    assert_eq!(Options::default().deploy_jobs_per_domain_max, None);
}

#[test]
fn retained_options_without_maximum_keep_their_encoding() {
    let original = Invocation::parse_legacy(["deploy", "--strategy=agent"]).unwrap();
    let old = serde_json::to_value(&original).unwrap();
    assert!(old["options"].get("deploy_jobs_per_domain_max").is_none());
    assert_eq!(old["options"]["strategy"], "owned");
    let decoded: Invocation = serde_json::from_value(old.clone()).unwrap();
    assert_eq!(decoded.options.deploy_jobs_per_domain_max, None);
    assert_eq!(serde_json::to_value(decoded).unwrap(), old);
    let mut with_max = original;
    with_max.options.deploy_jobs_per_domain_max = Some(16);
    assert_eq!(
        serde_json::from_value::<Invocation>(serde_json::to_value(&with_max).unwrap()).unwrap(),
        with_max
    );
}

#[test]
fn unsupported_prepare_is_rejected_at_execution_before_any_runtime_effects() {
    for arguments in [
        vec!["prepare", "--strategy=agent"],
        vec!["prepare", "--strategy=owned"],
        vec!["prepare", "--ci-trigger"],
        vec!["prepare", "--strategy=agent", "--ci-trigger"],
    ] {
        let invocation = Invocation::parse_legacy(arguments).unwrap();
        let temporary = tempfile::tempdir().unwrap();
        let runtime = abird_host_manager::fleet::runtime::RuntimeConfig {
            nix_program: temporary.path().join("must-not-run-nix"),
            git_program: temporary.path().join("must-not-run-git"),
            runtime_root: temporary.path().join("primary"),
            runtime_fallback_root: temporary.path().join("fallback"),
            diagnostic_root: temporary.path().join("diagnostics"),
            ..abird_host_manager::fleet::runtime::RuntimeConfig::from_environment()
        };
        let error = abird_host_manager::fleet::runtime::run(invocation, runtime).unwrap_err();
        assert!(
            error.to_string().contains("prepare is not supported"),
            "{error:#}"
        );
        assert_eq!(std::fs::read_dir(temporary.path()).unwrap().count(), 0);
    }
    let invocation = Invocation {
        action: Action::Prepare,
        options: Options {
            strategy: Strategy::Nix,
            ..Options::default()
        },
    };
    invocation.validate_execution_support().unwrap();
}

#[test]
fn prepare_does_not_allow_deployment_only_restart_control() {
    assert!(Invocation::parse_legacy(["prepare", "--restart-managed"]).is_err());
}
