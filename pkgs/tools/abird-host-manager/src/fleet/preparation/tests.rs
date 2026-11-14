use super::*;
use serde_json::json;

struct Evaluator {
    base: Value,
    merged: Value,
    overlay: Option<Value>,
    dependencies: Value,
    calls: Vec<(InventoryContext, Option<String>)>,
}

impl Evaluator {
    fn new(value: Value) -> Self {
        Self {
            base: value.clone(),
            merged: value,
            overlay: None,
            dependencies: json!({}),
            calls: Vec::new(),
        }
    }
}

impl InventoryEvaluator for Evaluator {
    fn layers(&mut self, context: &InventoryContext) -> Result<(Value, Value, Option<Value>)> {
        self.calls.push((context.clone(), None));
        Ok((self.merged.clone(), self.base.clone(), self.overlay.clone()))
    }
    fn dependencies(&mut self, context: &InventoryContext, key: &str) -> Result<Value> {
        self.calls.push((context.clone(), Some(key.into())));
        Ok(self.dependencies.clone())
    }
}

fn context() -> InventoryContext {
    InventoryContext {
        config: "/retained/inventory/hosts.nix".into(),
        overlay: Some("/retained/overlay/override.nix".into()),
        repository_config: Some("/retained/repository/config".into()),
        dependency_repository: "/retained/dependency-source".into(),
    }
}

fn fixture() -> Inventory {
    serde_json::from_value(json!({
        "config": {"defaultGroup": "apps", "defaultHosts": "app-*", "deployJobsPerDomain": 1},
        "hosts": {
            "app-a": {"groups": ["apps"], "deps": ["db"], "parent": "parent"},
            "app-b": {"groups": ["apps"], "parent": "parent"},
            "db": {}, "parent": {},
            "external": {"deploy": "skip"}, "ignored": {"skip": true}
        }
    }))
    .unwrap()
}

#[test]
fn explicit_context_preserves_every_input_and_dependency_key_without_git_discovery() {
    let mut evaluator = Evaluator::new(json!({
        "config": {"deployDepsKey": "custom.dependencies"},
        "hosts": {"app": {}, "db": {}}
    }));
    evaluator.dependencies = json!({"app": ["db"]});
    let input = context();
    let inventory = load_inventory(&mut evaluator, &input, Routes::ValidateOnly).unwrap();
    assert_eq!(inventory.hosts["app"].deps, ["db"]);
    assert_eq!(
        evaluator.calls,
        [
            (input.clone(), None),
            (input, Some("custom.dependencies".into()))
        ]
    );
    assert!(inventory.route_decision.is_none());
}

#[test]
fn absent_overlay_and_repository_config_stay_absent() {
    let mut input = context();
    input.overlay = None;
    input.repository_config = None;
    let mut evaluator = Evaluator::new(json!({"hosts": {"app": {}}}));
    load_inventory(&mut evaluator, &input, Routes::ValidateOnly).unwrap();
    assert_eq!(evaluator.calls[0], (input.clone(), None));
    assert_eq!(
        evaluator.calls[1],
        (input, Some("nixbot.deployDependencies".into()))
    );
}

#[test]
fn relative_context_is_rejected_before_effects() {
    for field in 0..4 {
        let mut input = context();
        match field {
            0 => input.config = "relative".into(),
            1 => input.overlay = Some("relative".into()),
            2 => input.repository_config = Some("relative".into()),
            _ => input.dependency_repository = "relative".into(),
        }
        let mut evaluator = Evaluator::new(json!({"hosts": {"app": {}}}));
        assert!(load_inventory(&mut evaluator, &input, Routes::ValidateOnly).is_err());
        assert!(evaluator.calls.is_empty());
    }
}

#[test]
fn invalid_dependency_key_never_reaches_evaluator() {
    for key in ["", "bad key", ".#escape", "$(anything)", "a\nb"] {
        let mut evaluator = Evaluator::new(json!({
            "config": {"deployDepsKey": key}, "hosts": {"app": {}}
        }));
        assert!(load_inventory(&mut evaluator, &context(), Routes::ValidateOnly).is_err());
        assert_eq!(evaluator.calls.len(), 1);
    }
}

#[test]
fn invalid_dependency_results_do_not_return_a_partial_inventory() {
    for dependencies in [json!([]), json!({"app": "db"}), json!({"app": ["missing"]})] {
        let mut evaluator = Evaluator::new(json!({"hosts": {"app": {}}}));
        evaluator.dependencies = dependencies;
        assert!(load_inventory(&mut evaluator, &context(), Routes::ValidateOnly).is_err());
    }
}

#[test]
fn named_routes_keep_original_layers_and_explicit_identity_context() {
    let base = json!({"hosts": {"app": {"target": "default", "routes": {"ts": "tailnet"}}}});
    let mut evaluator = Evaluator::new(base.clone());
    evaluator.overlay = Some(json!({"hosts": {"app": {"target": "override"}}}));
    evaluator.merged["hosts"]["app"]["target"] = json!("override");
    let inventory = load_inventory(
        &mut evaluator,
        &context(),
        Routes::Resolve {
            request: RouteRequest::Default,
            source: RouteSource::Cli,
            identity: None,
        },
    )
    .unwrap();
    assert_eq!(inventory.hosts["app"].target.as_deref(), Some("override"));
    assert_eq!(
        inventory.route_decision.unwrap().request,
        RouteRequest::Default
    );

    let mut evaluator = Evaluator::new(base);
    let inventory = load_inventory(
        &mut evaluator,
        &context(),
        Routes::Resolve {
            request: RouteRequest::Ts,
            source: RouteSource::Cli,
            identity: None,
        },
    )
    .unwrap();
    assert_eq!(inventory.hosts["app"].target.as_deref(), Some("tailnet"));
    select_inventory(&inventory, &Options::default()).unwrap();
}

#[test]
fn native_defaults_dependencies_order_and_capacity_are_reused() {
    let inventory = fixture();
    let actual = select_inventory(&inventory, &Options::default()).unwrap();
    let expected = select(
        &inventory,
        &SelectionOptions {
            groups: vec!["apps".into()],
            hosts: Some("app-*".into()),
            deploy_jobs_per_domain: 1,
            ..SelectionOptions::default()
        },
    )
    .unwrap();
    assert_eq!(actual, expected);
    assert!(
        actual.ordered.iter().position(|host| host == "db")
            < actual.ordered.iter().position(|host| host == "app-a")
    );
    let options = Options {
        deploy_jobs_per_domain: 2,
        deploy_jobs_per_domain_explicit: true,
        ..Options::default()
    };
    let wider = select_inventory(&inventory, &options).unwrap();
    assert_eq!(actual.ordered, wider.ordered);
    assert!(actual.waves.len() > wider.waves.len());
}

#[test]
fn explicit_hosts_override_defaults_but_not_required_coverage_or_skips() {
    let inventory = fixture();
    let mut options = Options {
        hosts: Some("db,ignored".into()),
        ..Options::default()
    };
    let selected = select_inventory(&inventory, &options).unwrap();
    assert_eq!(selected.ordered, ["db"]);
    assert_eq!(selected.skipped, ["ignored"]);
    options.required_hosts = vec!["ignored".into()];
    assert!(select_inventory(&inventory, &options).is_err());
    options.required_hosts = vec!["app-a".into()];
    assert!(select_inventory(&inventory, &options).is_err());
    options.required_hosts.clear();
    options.hosts = Some("app-*,-app-b".into());
    let selected = select_inventory(&inventory, &options).unwrap();
    assert_eq!(selected.excluded, ["app-b"]);
    assert!(!selected.ordered.contains(&"app-b".into()));
    options.hosts = Some("ignored".into());
    assert!(select_inventory(&inventory, &options).is_err());
}

#[test]
fn only_missing_native_deploy_skip_targets_are_no_work() {
    let inventory = fixture();
    let options = Options {
        hosts: Some("db,external".into()),
        ..Options::default()
    };
    let selection = select_inventory(&inventory, &options).unwrap();
    for action in [Action::Run, Action::Deploy, Action::Build, Action::DevBuild] {
        for catalog in [
            PlanCatalog::NixosConfiguration,
            PlanCatalog::Native(BTreeSet::new()),
            PlanCatalog::Native(BTreeSet::from(["external".into()])),
        ] {
            let targets =
                plan_targets(&inventory, &selection, &action, &options, &catalog).unwrap();
            assert_eq!(
                targets
                    .iter()
                    .map(|target| &target.host)
                    .collect::<Vec<_>>(),
                selection.ordered.iter().collect::<Vec<_>>()
            );
            assert!(
                !targets
                    .iter()
                    .find(|target| target.host == "db")
                    .unwrap()
                    .skipped
            );
            assert_eq!(
                targets
                    .iter()
                    .find(|target| target.host == "external")
                    .unwrap()
                    .skipped,
                matches!(action, Action::Run | Action::Deploy)
                    && matches!(&catalog, PlanCatalog::Native(plans) if !plans.contains("external"))
            );
        }
    }
    let options = Options {
        host: Some("external".into()),
        ..Options::default()
    };
    let selection = select_inventory(&inventory, &options).unwrap();
    let targets = plan_targets(
        &inventory,
        &selection,
        &Action::Deploy,
        &options,
        &PlanCatalog::Native(BTreeSet::new()),
    )
    .unwrap();
    assert_eq!(targets.len(), 1);
    assert!(targets[0].skipped);
}

#[test]
fn configuration_override_only_applies_to_the_exact_host_not_dependencies() {
    let inventory = fixture();
    let options = Options {
        host: Some("app-a".into()),
        nix_config: Some("alternate".into()),
        ..Options::default()
    };
    let selection = select_inventory(&inventory, &options).unwrap();
    let targets = plan_targets(
        &inventory,
        &selection,
        &Action::Build,
        &options,
        &PlanCatalog::NixosConfiguration,
    )
    .unwrap();
    for target in targets {
        assert_eq!(
            target.configuration,
            if target.host == "app-a" {
                "alternate"
            } else {
                &target.host
            }
        );
    }
    let options = Options {
        hosts: Some("app-a".into()),
        nix_config: Some("unused".into()),
        ..Options::default()
    };
    let targets = plan_targets(
        &inventory,
        &selection,
        &Action::DevBuild,
        &options,
        &PlanCatalog::NixosConfiguration,
    )
    .unwrap();
    assert!(
        targets
            .iter()
            .all(|target| target.host == target.configuration)
    );
    assert!(
        plan_targets(
            &inventory,
            &selection,
            &Action::ListHosts,
            &options,
            &PlanCatalog::NixosConfiguration
        )
        .is_err()
    );
}

#[test]
fn malformed_successful_probe_never_becomes_compatibility_fallback() {
    assert_eq!(
        PlanCatalog::from_probe(false, "not JSON").unwrap(),
        PlanCatalog::NixosConfiguration
    );
    assert_eq!(
        PlanCatalog::from_probe(true, "[]").unwrap(),
        PlanCatalog::Native(BTreeSet::new())
    );
    for output in ["not JSON", "{}", "null", "[1]", "[\"app\"] trailing"] {
        assert!(PlanCatalog::from_probe(true, output).is_err());
    }
}
