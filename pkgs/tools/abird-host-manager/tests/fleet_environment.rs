use std::collections::BTreeMap;

use abird_host_manager::fleet::cli::{
    ActivationGoal, BuildHostDeployMode, DiscoverKeys, Invocation, JobCount, LogFormat,
};
use abird_host_manager::fleet::environment::{Environment, LocalSelfTarget};

fn environment(values: &[(&str, &str)]) -> Environment {
    Environment::from_map(
        values
            .iter()
            .map(|(name, value)| ((*name).to_owned(), (*value).to_owned()))
            .collect::<BTreeMap<_, _>>(),
    )
}

#[test]
fn environment_populates_public_workflow_options() {
    let env = environment(&[
        ("NIXBOT_HOSTS", "web-a"),
        ("NIXBOT_GROUPS", "prod,data"),
        ("NIXBOT_NIX_CONFIG", "web-a"),
        ("NIXBOT_SHA", "deadbeef"),
        ("NIXBOT_GOAL", "test"),
        ("NIXBOT_BUILD_HOST", "builder"),
        ("NIXBOT_BUILD_HOST_DEPLOY_MODE", "local-copy"),
        ("NIXBOT_BUILD_CACHE_URL", "https://cache.invalid"),
        ("NIXBOT_BUILD_CACHE_HOST", "cache"),
        ("NIXBOT_BUILD_PLAN_JOBS", "7"),
        ("NIXBOT_BUILD_JOBS", "3"),
        ("NIXBOT_BUILD_LOGS", "yes"),
        ("NIXBOT_JOBS", "5"),
        ("NIXBOT_VERIFY_JOBS", "9"),
        ("NIXBOT_FORCE", "true"),
        ("NIXBOT_RESTART_MANAGED", "1"),
        ("NIXBOT_BOOTSTRAP", "on"),
        ("NIXBOT_CONTROL_PLANE_FIRST", "yes"),
        ("NIXBOT_SKIP_GLOBAL_LOCK", "true"),
        ("NIXBOT_DIRTY_STAGED", "1"),
        ("NIXBOT_DRY", "true"),
        ("NIXBOT_NO_ROLLBACK", "yes"),
        ("NIXBOT_NO_VERIFY", "on"),
        ("NIXBOT_PREFIX_HOST_LOGS", "1"),
        ("NIXBOT_VERBOSE", "1"),
        ("NIXBOT_LOG_FORMAT", "gh"),
        ("NIXBOT_DISCOVER_KEYS", "off"),
        ("NIXBOT_LOCAL_SELF_TARGET", "on"),
        ("NIXBOT_SSH_CONNECT_TIMEOUT_SECS", "42"),
        ("NIXBOT_SSH_SERVER_ALIVE_INTERVAL_SECS", "9"),
        ("NIXBOT_SSH_SERVER_ALIVE_COUNT_MAX", "2"),
        ("NIXBOT_CONTROL_PERSIST_SECS", "77"),
    ]);

    let invocation = Invocation::parse_legacy_with_environment(["deploy"], &env).unwrap();
    let options = invocation.options;
    assert_eq!(options.hosts.as_deref(), Some("web-a"));
    assert_eq!(options.groups, ["prod", "data"]);
    assert_eq!(options.nix_config.as_deref(), Some("web-a"));
    assert_eq!(options.sha.as_deref(), Some("deadbeef"));
    assert_eq!(options.goal, ActivationGoal::Test);
    assert_eq!(options.build_host.as_deref(), Some("builder"));
    assert_eq!(
        options.build_host_deploy_mode,
        BuildHostDeployMode::LocalCopy
    );
    assert_eq!(options.build_plan_jobs, JobCount::Count(7));
    assert_eq!(options.build_jobs, 3);
    assert_eq!(options.deploy_jobs, 5);
    assert_eq!(options.deploy_jobs_per_domain, 5);
    assert_eq!(options.verify_jobs, 9);
    assert!(options.build_logs && options.force && options.restart_managed);
    assert!(options.bootstrap && options.control_plane_first && options.skip_global_lock);
    assert!(options.dirty && options.dirty_staged && options.dry_run);
    assert!(options.no_rollback && options.no_verify && options.prefix_host_logs);
    assert!(options.verbose);
    assert_eq!(options.log_format, LogFormat::GithubActions);
    assert_eq!(options.discover_keys, DiscoverKeys::Off);
    let settings = env.settings().unwrap();
    assert_eq!(settings.local_self_target, LocalSelfTarget::On);
    assert_eq!(settings.ssh_connect_timeout_seconds, 42);
    assert_eq!(settings.ssh_server_alive_interval_seconds, 9);
    assert_eq!(settings.ssh_server_alive_count_max, 2);
    assert_eq!(settings.ssh_control_persist_seconds, 77);
}

#[test]
fn verbose_and_quiet_flags_override_environment_presentation_detail() {
    let env = environment(&[("NIXBOT_VERBOSE", "true")]);
    let quiet = Invocation::parse_legacy_with_environment(["build", "--quiet"], &env).unwrap();
    assert!(!quiet.options.verbose);
    let verbose =
        Invocation::parse_legacy_with_environment(["build", "--quiet", "--verbose"], &env).unwrap();
    assert!(verbose.options.verbose);
}

#[test]
fn explicit_group_flags_replace_environment_groups_and_accumulate() {
    let env = environment(&[("NIXBOT_GROUPS", "old-a,old-b")]);
    let invocation = Invocation::parse_legacy_with_environment(
        ["build", "--group", "new-a,new-b", "--group", "new-c"],
        &env,
    )
    .unwrap();
    assert_eq!(invocation.options.groups, ["new-a", "new-b", "new-c"]);
}

#[test]
fn flags_override_normal_environment_defaults() {
    let env = environment(&[
        ("NIXBOT_HOSTS", "old"),
        ("NIXBOT_GOAL", "boot"),
        ("NIXBOT_JOBS", "2"),
        ("NIXBOT_JOBS_PER_DOMAIN", "1"),
    ]);
    let invocation = Invocation::parse_legacy_with_environment(
        [
            "deploy",
            "--hosts",
            "new",
            "--goal",
            "test",
            "--deploy-jobs",
            "6",
        ],
        &env,
    )
    .unwrap();
    assert_eq!(invocation.options.hosts.as_deref(), Some("new"));
    assert_eq!(invocation.options.goal, ActivationGoal::Test);
    assert_eq!(invocation.options.deploy_jobs, 6);
    assert_eq!(invocation.options.deploy_jobs_per_domain, 1);
}

#[test]
fn canonical_tofu_preserves_environment_identity_options() {
    let env = environment(&[("AGE_KEY_FILE", "/run/keys/tofu.age")]);
    let invocation = Invocation::parse_canonical_with_environment(
        ["fleet", "tofu", "-chdir=tf/example", "plan"],
        &env,
    )
    .unwrap();

    assert_eq!(
        invocation.options.age_key_file.as_deref(),
        Some(std::path::Path::new("/run/keys/tofu.age"))
    );
    assert_eq!(
        invocation.action,
        abird_host_manager::fleet::cli::Action::Tofu(vec![
            "-chdir=tf/example".to_owned(),
            "plan".to_owned(),
        ])
    );
}

#[test]
fn conflicting_identity_flag_and_environment_override_is_rejected() {
    let env = environment(&[("NIXBOT_USER", "nixbot")]);
    let error =
        Invocation::parse_legacy_with_environment(["deploy", "--user", "root"], &env).unwrap_err();
    assert!(error.to_string().contains("conflicting user overrides"));
}

#[test]
fn malformed_booleans_and_operational_numbers_are_rejected() {
    let invalid_bool = environment(&[("NIXBOT_FORCE", "sometimes")]);
    assert!(
        Invocation::parse_legacy_with_environment(["build"], &invalid_bool)
            .unwrap_err()
            .to_string()
            .contains("NIXBOT_FORCE")
    );

    let invalid_timeout = environment(&[("NIXBOT_TRANSPORT_RETRY_ATTEMPTS", "0")]);
    assert!(
        Invocation::parse_legacy_with_environment(["build"], &invalid_timeout)
            .unwrap_err()
            .to_string()
            .contains("NIXBOT_TRANSPORT_RETRY_ATTEMPTS")
    );
}
