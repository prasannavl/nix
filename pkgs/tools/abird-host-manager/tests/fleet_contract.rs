use std::collections::BTreeMap;
use std::path::Path;

use abird_host_manager::fleet::build_lease::InvocationId;
use abird_host_manager::fleet::cli::{Action, CleanMode, Invocation};
use abird_host_manager::fleet::inventory::{DeployConfig, DeployMode, Host, Inventory, Registry};
use abird_host_manager::fleet::plan::{Phase, WorkflowPlan};
use abird_host_manager::fleet::selection::{SelectionOptions, select};

fn host(groups: &[&str]) -> Host {
    Host {
        target: None,
        groups: groups.iter().map(|group| (*group).to_owned()).collect(),
        ..Host::default()
    }
}

fn inventory() -> Inventory {
    Inventory {
        hosts: BTreeMap::from([
            ("controller".to_owned(), host(&["prod"])),
            (
                "parent".to_owned(),
                Host {
                    groups: vec!["prod".to_owned()],
                    after: vec!["controller".to_owned()],
                    ..Host::default()
                },
            ),
            (
                "app-a".to_owned(),
                Host {
                    groups: vec!["prod".to_owned(), "minimal".to_owned()],
                    parent: Some("parent".to_owned()),
                    deps: vec!["excluded-dep".to_owned()],
                    ..Host::default()
                },
            ),
            (
                "excluded-dep".to_owned(),
                Host {
                    groups: vec!["prod".to_owned(), "-minimal".to_owned()],
                    ..Host::default()
                },
            ),
            (
                "app-b".to_owned(),
                Host {
                    groups: vec!["prod".to_owned(), "-minimal".to_owned()],
                    parent: Some("parent".to_owned()),
                    after: vec!["app-a".to_owned()],
                    ..Host::default()
                },
            ),
            (
                "optional".to_owned(),
                Host {
                    groups: vec!["prod".to_owned()],
                    deploy: DeployMode::Optional,
                    ..Host::default()
                },
            ),
            (
                "retired".to_owned(),
                Host {
                    groups: vec!["prod".to_owned()],
                    skip: true,
                    ..Host::default()
                },
            ),
        ]),
        config: DeployConfig::default(),
    }
}

fn control_plane_inventory() -> Inventory {
    Inventory {
        hosts: BTreeMap::from([
            (
                "app".to_owned(),
                Host {
                    parent: Some("parent".to_owned()),
                    deps: vec!["db".to_owned()],
                    ..Host::default()
                },
            ),
            ("controller".to_owned(), Host::default()),
            ("db".to_owned(), Host::default()),
            ("parent".to_owned(), Host::default()),
            ("registry".to_owned(), Host::default()),
            (
                "worker".to_owned(),
                Host {
                    after: vec!["app".to_owned()],
                    ..Host::default()
                },
            ),
        ]),
        config: DeployConfig {
            controller: Some("controller".to_owned()),
            transfer_broker: Some("controller".to_owned()),
            builders: vec!["controller".to_owned()],
            registries: BTreeMap::from([(
                "nix".to_owned(),
                Registry {
                    host: "registry".to_owned(),
                    url: "https://cache.invalid".to_owned(),
                },
            )]),
            ..DeployConfig::default()
        },
    }
}

#[test]
fn inventory_accepts_exact_health_ignores_and_deploy_key_override() {
    let inventory: Inventory = serde_json::from_value(serde_json::json!({
        "hosts": {
            "app": {
                "healthCheck": {"ignore": ["known-failure.service"]}
            }
        },
        "config": {"deployDepsKey": "custom.deployDeps"}
    }))
    .unwrap();

    inventory.validate().unwrap();
    assert_eq!(
        inventory.hosts["app"].health_check.ignore,
        ["known-failure.service"]
    );
    assert_eq!(
        inventory.config.deploy_deps_key.as_deref(),
        Some("custom.deployDeps")
    );
}

#[test]
fn inventory_rejects_invalid_health_ignores_and_legacy_key() {
    for ignore in [
        serde_json::json!([""]),
        serde_json::json!(["unit with whitespace.service"]),
        serde_json::json!(["duplicate.service", "duplicate.service"]),
    ] {
        let inventory: Inventory = serde_json::from_value(serde_json::json!({
            "hosts": {"app": {"healthCheck": {"ignore": ignore}}}
        }))
        .unwrap();
        assert!(inventory.validate().is_err());
    }

    let legacy = serde_json::from_value::<Inventory>(serde_json::json!({
        "hosts": {
            "app": {
                "healthCheck": {"ignoredFailedSystemUnits": []}
            }
        }
    }));
    assert!(legacy.is_err());
}

#[test]
fn legacy_cli_covers_every_current_action_and_alias() {
    let cases = [
        (vec!["nixbot", "--help"], Action::Help),
        (vec!["nixbot", "deps"], Action::Deps),
        (vec!["nixbot", "check-deps"], Action::CheckDeps),
        (vec!["nixbot", "version"], Action::Version),
        (vec!["nixbot", "repo", "sync"], Action::RepoSync),
        (vec!["nixbot", "--list-hosts"], Action::ListHosts),
        (vec!["nixbot", "--list-groups"], Action::ListGroups),
        (vec!["nixbot", "run"], Action::Run),
        (vec!["nixbot", "deploy"], Action::Deploy),
        (vec!["nixbot", "build"], Action::Build),
        (vec!["nixbot", "dev-build"], Action::DevBuild),
        (vec!["nixbot", "tf"], Action::TerraformAll),
        (vec!["nixbot", "tf-dns"], Action::TerraformDns),
        (vec!["nixbot", "tf-platform"], Action::TerraformPlatform),
        (vec!["nixbot", "tf-apps"], Action::TerraformApps),
        (
            vec!["nixbot", "tf/cloudflare-dns"],
            Action::TerraformProject("cloudflare-dns".to_owned()),
        ),
        (vec!["nixbot", "check-bootstrap"], Action::CheckBootstrap),
        (vec!["nixbot", "clean"], Action::Clean(CleanMode::Auto)),
        (vec!["nixbot", "--clean=all"], Action::Clean(CleanMode::All)),
        (
            vec!["nixbot", "tofu", "-chdir=tf/example", "plan"],
            Action::Tofu(vec!["-chdir=tf/example".into(), "plan".into()]),
        ),
    ];

    for (arguments, expected) in cases {
        let invocation = Invocation::parse_legacy(arguments).unwrap();
        assert_eq!(invocation.action, expected);
    }
}

#[test]
fn empty_legacy_invocation_is_successful_help_for_compatibility() {
    assert_eq!(
        Invocation::parse_legacy(Vec::<String>::new())
            .unwrap()
            .action,
        Action::Help
    );
    assert_eq!(
        Invocation::parse_legacy(["deps", "--help"]).unwrap().action,
        Action::Help
    );
    assert_eq!(
        Invocation::parse_legacy(["deploy", "--help"])
            .unwrap()
            .action,
        Action::Help
    );
    assert_eq!(
        Invocation::parse_canonical(["fleet", "terraform", "dns", "--help"])
            .unwrap()
            .action,
        Action::Help
    );
}

#[test]
fn canonical_cli_uses_one_fleet_namespace_without_losing_actions() {
    let cases = [
        (vec!["fleet", "hosts"], Action::ListHosts),
        (vec!["fleet", "groups"], Action::ListGroups),
        (vec!["fleet", "run"], Action::Run),
        (vec!["fleet", "deploy"], Action::Deploy),
        (vec!["fleet", "build"], Action::Build),
        (vec!["fleet", "dev-build"], Action::DevBuild),
        (vec!["fleet", "terraform", "all"], Action::TerraformAll),
        (vec!["fleet", "terraform", "dns"], Action::TerraformDns),
        (
            vec!["fleet", "terraform", "project", "cloudflare-dns"],
            Action::TerraformProject("cloudflare-dns".to_owned()),
        ),
        (vec!["fleet", "check-bootstrap"], Action::CheckBootstrap),
        (vec!["fleet", "clean", "all"], Action::Clean(CleanMode::All)),
        (vec!["fleet", "repo", "sync"], Action::RepoSync),
    ];

    for (arguments, expected) in cases {
        let invocation = Invocation::parse_canonical(arguments).unwrap();
        assert_eq!(invocation.action, expected);
    }
}

#[test]
fn legacy_options_preserve_selection_build_deploy_and_repository_contracts() {
    let invocation = Invocation::parse_legacy([
        "nixbot",
        "deploy",
        "--group=prod,minimal",
        "--hosts=app-a,-app-b",
        "--nix-config=app-system",
        "--goal=test",
        "--build-host=builder",
        "--build-host-deploy-mode=local-copy",
        "--build-plan-jobs=3",
        "--build-jobs=2",
        "--deploy-jobs=5",
        "--deploy-jobs-per-domain=2",
        "--verify-jobs=7",
        "--build-logs",
        "--force",
        "--restart-managed",
        "--bootstrap",
        "--control-plane-first",
        "--skip-global-lock",
        "--dirty-staged",
        "--dry",
        "--no-override",
        "--no-rollback",
        "--no-verify",
        "--prefix-host-logs",
        "--repo-url=ssh://git@example/z",
        "--repo-path=/var/lib/nixbot/z",
    ])
    .unwrap();

    assert_eq!(invocation.options.groups, ["prod", "minimal"]);
    assert_eq!(invocation.options.hosts.as_deref(), Some("app-a,-app-b"));
    assert_eq!(invocation.options.nix_config.as_deref(), Some("app-system"));
    assert_eq!(invocation.options.build_jobs, 2);
    assert_eq!(invocation.options.deploy_jobs, 5);
    assert_eq!(invocation.options.deploy_jobs_per_domain, 2);
    assert_eq!(invocation.options.verify_jobs, 7);
    assert!(invocation.options.control_plane_first);
    assert!(invocation.options.dry_run);
    assert!(invocation.options.dirty_staged);
    assert_eq!(
        invocation.options.repo_path.as_deref(),
        Some(Path::new("/var/lib/nixbot/z"))
    );
}

#[test]
fn singular_host_is_exact_and_overrides_environment_selection() {
    let environment = abird_host_manager::fleet::environment::Environment::from_map(
        [("NIXBOT_HOSTS".to_owned(), "old-a,old-b".to_owned())]
            .into_iter()
            .collect(),
    );
    let invocation =
        Invocation::parse_legacy_with_environment(["deploy", "--host", "app-a"], &environment)
            .unwrap();
    assert_eq!(invocation.options.host.as_deref(), Some("app-a"));
    assert_eq!(invocation.options.hosts, None);
}

#[test]
fn legacy_cli_rejects_ambiguous_or_unsafe_shapes() {
    for arguments in [
        vec!["nixbot", "deploy", "--host=app-a", "--hosts=all"],
        vec!["nixbot", "deploy", "--host=app*"],
        vec!["nixbot", "deploy", "--build-jobs=0"],
        vec!["nixbot", "deploy", "--goal=destroy"],
        vec!["nixbot", "build", "--restart-managed"],
        vec!["nixbot", "deploy", "--restart-managed", "--goal=boot"],
        vec!["nixbot", "dev-build", "--sha=abc123"],
        vec!["nixbot", "clean", "--sha=abc123"],
    ] {
        assert!(
            Invocation::parse_legacy(arguments.clone()).is_err(),
            "unexpectedly accepted {arguments:?}"
        );
    }

    assert!(Invocation::parse_legacy(["deploy", "--ci-first"]).is_err());
}

#[test]
fn typed_inventory_validates_capability_and_graph_references() {
    let mut inventory = inventory();
    inventory.config = DeployConfig {
        controller: Some("controller".to_owned()),
        transfer_broker: Some("controller".to_owned()),
        builders: vec!["controller".to_owned()],
        registries: BTreeMap::from([(
            "nix".to_owned(),
            Registry {
                host: "controller".to_owned(),
                url: "http://cache.internal:5000".to_owned(),
            },
        )]),
        ..DeployConfig::default()
    };
    inventory.validate().unwrap();

    inventory.hosts.get_mut("app-a").unwrap().deps = vec!["missing".to_owned()];
    assert!(
        inventory
            .validate()
            .unwrap_err()
            .to_string()
            .contains("missing")
    );
}

#[test]
fn evaluated_deploy_dependencies_merge_deterministically_and_fail_closed() {
    let mut merged = inventory();
    merged
        .apply_deploy_dependencies(BTreeMap::from([(
            "app-b".to_owned(),
            vec!["controller".to_owned(), "controller".to_owned()],
        )]))
        .unwrap();
    assert_eq!(merged.hosts["app-b"].deps, ["controller"]);

    let mut unknown_target = inventory();
    assert!(
        unknown_target
            .apply_deploy_dependencies(BTreeMap::from([(
                "missing".to_owned(),
                vec!["controller".to_owned()],
            )]))
            .is_err()
    );
    let mut unknown_predecessor = inventory();
    assert!(
        unknown_predecessor
            .apply_deploy_dependencies(BTreeMap::from([(
                "app-a".to_owned(),
                vec!["missing".to_owned()],
            )]))
            .is_err()
    );
}

#[test]
fn group_selection_expands_dependencies_and_respects_negative_membership() {
    let selected = select(
        &inventory(),
        &SelectionOptions {
            groups: vec!["minimal".to_owned()],
            hosts: Some("app-a".to_owned()),
            ..SelectionOptions::default()
        },
    )
    .unwrap();

    assert_eq!(selected.direct, ["app-a"]);
    assert_eq!(selected.ordered, ["parent", "app-a"]);
    assert_eq!(selected.dependency_excluded, ["app-b", "excluded-dep"]);
}

#[test]
fn selector_supports_globs_exclusions_and_implicit_all() {
    let selected = select(
        &inventory(),
        &SelectionOptions {
            groups: vec!["prod".to_owned()],
            hosts: Some("controller,app-*,-app-b".to_owned()),
            ..SelectionOptions::default()
        },
    )
    .unwrap();
    assert_eq!(
        selected.ordered,
        ["controller", "excluded-dep", "parent", "app-a"]
    );

    let implicit = select(
        &inventory(),
        &SelectionOptions {
            groups: vec!["prod".to_owned()],
            hosts: Some("-optional,-retired".to_owned()),
            ..SelectionOptions::default()
        },
    )
    .unwrap();
    assert!(implicit.ordered.contains(&"app-a".to_owned()));
    assert!(!implicit.ordered.contains(&"optional".to_owned()));

    let bracket_class = select(
        &inventory(),
        &SelectionOptions {
            groups: vec!["prod".to_owned()],
            hosts: Some("app-[ab],-app-[!a]".to_owned()),
            ..SelectionOptions::default()
        },
    )
    .unwrap();
    assert_eq!(bracket_class.direct, ["app-a"]);
}

#[test]
fn control_plane_is_last_by_default_and_first_when_requested() {
    let inventory = control_plane_inventory();
    let last = select(&inventory, &SelectionOptions::default()).unwrap();
    assert_eq!(
        last.ordered,
        ["db", "parent", "app", "worker", "controller", "registry"]
    );
    assert_eq!(
        last.levels,
        [
            vec!["db".to_owned(), "parent".to_owned()],
            vec!["app".to_owned()],
            vec!["worker".to_owned()],
            vec!["controller".to_owned()],
            vec!["registry".to_owned()],
        ]
    );

    let first = select(
        &inventory,
        &SelectionOptions {
            control_plane_first: true,
            ..SelectionOptions::default()
        },
    )
    .unwrap();
    assert_eq!(
        first.ordered,
        ["controller", "registry", "db", "parent", "app", "worker"]
    );
    assert_eq!(
        first.levels,
        [
            vec!["controller".to_owned()],
            vec!["registry".to_owned()],
            vec!["db".to_owned(), "parent".to_owned()],
            vec!["app".to_owned()],
            vec!["worker".to_owned()],
        ]
    );
}

#[test]
fn control_plane_first_keeps_hard_controller_dependencies() {
    let mut inventory = control_plane_inventory();
    inventory.hosts.get_mut("controller").unwrap().deps = vec!["parent".to_owned()];
    let selected = select(
        &inventory,
        &SelectionOptions {
            control_plane_first: true,
            ..SelectionOptions::default()
        },
    )
    .unwrap();

    assert!(
        selected.ordered.iter().position(|host| host == "parent")
            < selected
                .ordered
                .iter()
                .position(|host| host == "controller")
    );
    assert!(
        selected
            .ordered
            .iter()
            .position(|host| host == "controller")
            < selected.ordered.iter().position(|host| host == "registry")
    );
}

#[test]
fn selection_rejects_cycles_unknowns_and_non_strict_dependencies() {
    let mut unknown = inventory();
    unknown.hosts.get_mut("app-a").unwrap().deps = vec!["missing".to_owned()];
    assert!(select(&unknown, &SelectionOptions::default()).is_err());

    let mut cycle = inventory();
    cycle.hosts.get_mut("controller").unwrap().after = vec!["app-b".to_owned()];
    assert!(select(&cycle, &SelectionOptions::default()).is_err());

    let mut optional_dependency = inventory();
    optional_dependency.hosts.get_mut("app-a").unwrap().deps = vec!["optional".to_owned()];
    assert!(select(&optional_dependency, &SelectionOptions::default()).is_err());
}

#[test]
fn levels_and_domain_capacity_are_deterministic() {
    let selected = select(
        &inventory(),
        &SelectionOptions {
            groups: vec!["prod".to_owned()],
            hosts: Some("controller,parent,app-a,app-b,-excluded-dep".to_owned()),
            deploy_jobs_per_domain: 1,
            ..SelectionOptions::default()
        },
    )
    .unwrap();

    assert_eq!(
        selected.levels,
        vec![
            vec!["controller".to_owned()],
            vec!["parent".to_owned()],
            vec!["app-a".to_owned()],
            vec!["app-b".to_owned()],
        ]
    );
    assert_eq!(selected.waves, selected.levels);
}

#[test]
fn workflow_plans_preserve_nixbot_phase_order() {
    assert_eq!(
        WorkflowPlan::for_action(&Action::Run).phases,
        [
            Phase::TerraformDns,
            Phase::TerraformPlatform,
            Phase::Build,
            Phase::Snapshot,
            Phase::Deploy,
            Phase::Health,
            Phase::TerraformApps,
        ]
    );
    assert_eq!(
        WorkflowPlan::for_action(&Action::Deploy).phases,
        [Phase::Build, Phase::Snapshot, Phase::Deploy, Phase::Health]
    );
    assert_eq!(
        WorkflowPlan::for_action(&Action::Build).phases,
        [Phase::Build]
    );
}

#[test]
fn invocation_identity_is_stable_without_creating_builder_paths() {
    let first = InvocationId::derive("run", 1234, 42);
    let second = InvocationId::derive("run", 1234, 42);
    assert_eq!(first, second);
    assert_eq!(first.to_string().len(), 32);
    assert_ne!(first, InvocationId::derive("run", 1234, 43));
}
