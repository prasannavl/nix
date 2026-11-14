use super::*;
use abird_host_agent::build_executor::context::{InputTree, PlanJobs};
use abird_host_agent::build_executor::request::*;
use serde_json::json;

fn request() -> BuildRequest {
    serde_json::from_value(json!({
        "schema_version": REQUEST_VERSION, "executor_version": 1,
        "id": {"issued_at": 1000, "nonce": "native"}, "run_id": "run", "issuer": "operator",
        "repository_id": "repo", "source": {"revision": "a".repeat(40),
            "base_revision": "a".repeat(40), "tree_digest": "b".repeat(64), "patch_digest": null},
        "controller": {"host_id": "controller", "fabric_id": "fleet"},
        "builder": {"host_id": "ci", "fabric_id": "fleet"},
        "storage": {"authority_id": "authority", "builder_id": "ci", "store_id": "store"},
        "mode": "system", "evaluation": {"version": 1, "action": "build",
            "build_flake": {"tree": {"kind": "source"}, "relative": ""},
            "inventory": {"tree": {"kind": "source"}, "relative": "hosts/nixbot.nix"},
            "overlay": null, "repository_config": {"tree": {"kind": "source"}, "relative": "config"},
            "dependency_flake": {"tree": {"kind": "source"}, "relative": "fallback"},
            "plan_jobs": {"kind": "auto"}, "deploy_jobs_per_domain": null},
        "selection": {"kind": "fleet", "groups": [], "host": "app", "hosts": null,
            "nix_config": null, "control_plane_first": false}, "required_hosts": ["app"],
        "nix": {"max_jobs": 1, "cores": 2, "substitute": true}, "policy_digest": "c".repeat(64),
        "deadlines": {"heartbeat_seconds": 2, "stale_seconds": 6, "owner_seconds": 12,
            "queue_seconds": 30, "runtime_seconds": 60, "stop_grace_seconds": 3,
            "stop_limit_seconds": 10, "retention_seconds": 20},
        "owner": {"kind": "foreground", "token_digest": "d".repeat(64)}, "predecessor": null,
    })).unwrap()
}

fn trees() -> RetainedTrees {
    RetainedTrees {
        source: format!("/nix/store/{}-source", "0".repeat(32)),
        snapshots: BTreeMap::new(),
    }
}
fn inventory() -> Inventory {
    serde_json::from_value(json!({"hosts": {
        "app": {"deps": ["db"]}, "db": {}, "external": {"deploy": "skip"}
    }}))
    .unwrap()
}
fn witnesses() -> InputWitnesses {
    InputWitnesses {
        tree_digest: "b".repeat(64),
        protection_digest: "d".repeat(64),
        caller_repository: None,
    }
}
fn derivations() -> BTreeMap<String, NixStorePath> {
    ["app", "db"]
        .into_iter()
        .map(|host| {
            (
                host.into(),
                NixStorePath::derivation(&format!("/nix/store/{}-{host}.drv", "0".repeat(32)))
                    .unwrap(),
            )
        })
        .collect()
}

#[test]
fn bound_context_preserves_all_native_paths_options_and_no_ambient_discovery() {
    let mut request = request();
    request.evaluation.overlay = Some(InputLocation {
        tree: InputTree::Snapshot {
            nar_digest: "e".repeat(64),
        },
        relative: "overlay.nix".into(),
    });
    request.evaluation.plan_jobs = PlanJobs::Count { jobs: 3 };
    request.evaluation.deploy_jobs_per_domain = Some(2);
    let mut retained = trees();
    retained.snapshots.insert(
        "e".repeat(64),
        format!("/nix/store/{}-context", "1".repeat(32)),
    );
    let bound = BoundPreparation::new(request.clone(), retained).unwrap();
    assert!(bound.context().config.ends_with("hosts/nixbot.nix"));
    assert!(
        bound
            .context()
            .repository_config
            .as_ref()
            .unwrap()
            .ends_with("config")
    );
    assert!(bound.context().dependency_repository.ends_with("fallback"));
    assert_eq!(
        bound.context().overlay.as_ref().unwrap().to_str().unwrap(),
        format!("/nix/store/{}-context/overlay.nix", "1".repeat(32))
    );
    assert_eq!(bound.options().build_plan_jobs, JobCount::Count(3));
    assert_eq!(bound.options().deploy_jobs_per_domain, 2);
    assert!(bound.options().deploy_jobs_per_domain_explicit);
    assert_eq!(bound.action(), &Action::Build);
    assert_eq!(
        bound.options().forwarded_strategy(),
        Some(abird_host_agent::build_executor::strategy::Strategy::Agent)
    );
    let prepared = bound
        .candidate(
            &inventory(),
            &PlanCatalog::NixosConfiguration,
            &derivations(),
            witnesses(),
        )
        .unwrap();
    prepared.validate(&request).unwrap();
    assert_eq!(prepared.context_sources.len(), 1);
    assert_eq!(
        prepared
            .resolved
            .iter()
            .map(|t| t.host.as_str())
            .collect::<Vec<_>>(),
        ["db", "app"]
    );
}

#[test]
fn retained_planning_restores_native_data_without_querying_source_or_flakes() {
    use abird_host_agent::build_executor::preparation::worker::Planning;
    let bound = BoundPreparation::new(request(), trees()).unwrap();
    let inventory = inventory();
    let selection = select_inventory(&inventory, bound.options()).unwrap();
    for probe in [json!(["app", "db"]), serde_json::Value::Null] {
        let catalog = PlanCatalog::from_probe(!probe.is_null(), &probe.to_string()).unwrap();
        let mut prepared = bound
            .candidate(&inventory, &catalog, &derivations(), witnesses())
            .unwrap();
        let mut planning = Planning {
            version: 1,
            request: bound.request.clone(),
            inventory: serde_json::to_value(&inventory).unwrap(),
            catalog: probe,
            selection: serde_json::to_string(&selection).unwrap(),
            activation: Default::default(),
            layers: serde_json::Value::Null,
        };
        prepared.planning_digest = Some(planning.digest().unwrap());
        let super::Restored {
            inventory: restored,
            catalog: restored_catalog,
            ..
        } = bound.restore_planning(&planning, &prepared).unwrap();
        assert_eq!(restored, inventory);
        assert_eq!(restored_catalog, catalog);

        planning.inventory["hosts"]["app"]["wait"] = json!(999);
        assert!(bound.restore_planning(&planning, &prepared).is_err());
        planning.inventory = serde_json::to_value(&inventory).unwrap();
        planning.selection = "{}".into();
        prepared.planning_digest = Some(planning.digest().unwrap());
        prepared.selection_digest = digest_bytes(planning.selection.as_bytes());
        assert!(bound.restore_planning(&planning, &prepared).is_err());
    }
}

#[test]
fn development_planning_retains_the_original_destination_witness() {
    use abird_host_agent::build_executor::{
        context::BuildAction,
        native_intent::{CallerRepository, Request},
        preparation::worker::Planning,
    };
    let mut request = request();
    request.evaluation.action = BuildAction::DevBuild;
    request.mode = BuildMode::Development;
    request.parent = Some(Box::new(Request {
        version: 1,
        executor_version: request.executor_version,
        id: request.id.clone(),
        run_id: request.run_id.clone(),
        issuer: request.issuer.clone(),
        repository_id: request.repository_id.clone(),
        controller: request.controller.clone(),
        builder: request.builder.clone(),
        storage: request.storage.clone(),
        action: BuildAction::DevBuild,
        invocation: json!({}),
        nix: request.nix.clone(),
        policy_digest: request.policy_digest.clone(),
        deadlines: request.deadlines.clone(),
        owner: request.owner.clone(),
        controller_service: false,
        bootstrap_digest: Some("a".repeat(64)),
        caller_digest: Some("b".repeat(64)),
    }));
    let bound = BoundPreparation::new(request, trees()).unwrap();
    let inventory = inventory();
    let original = CallerRepository {
        path: "/home/operator/original".into(),
        device: 7,
        inode: 42,
    };
    let mut input = witnesses();
    input.caller_repository = Some(original.clone());
    let mut prepared = bound
        .candidate(
            &inventory,
            &PlanCatalog::NixosConfiguration,
            &derivations(),
            input,
        )
        .unwrap();
    let planning = Planning {
        version: 1,
        request: bound.request.clone(),
        inventory: serde_json::to_value(&inventory).unwrap(),
        catalog: serde_json::Value::Null,
        selection: serde_json::to_string(&select_inventory(&inventory, bound.options()).unwrap())
            .unwrap(),
        activation: Default::default(),
        layers: serde_json::Value::Null,
    };
    prepared.planning_digest = Some(planning.digest().unwrap());
    assert_eq!(prepared.caller_repository, Some(original));
    bound.restore_planning(&planning, &prepared).unwrap();
    let digest = prepared.digest().unwrap();
    prepared.caller_repository.as_mut().unwrap().inode += 1;
    assert_ne!(prepared.digest().unwrap(), digest);
}

#[test]
fn missing_foreign_or_unsafe_context_mapping_is_not_used() {
    let mut request = request();
    request.evaluation.overlay = Some(InputLocation {
        tree: InputTree::Snapshot {
            nar_digest: "e".repeat(64),
        },
        relative: "overlay.nix".into(),
    });
    assert!(BoundPreparation::new(request.clone(), trees()).is_err());
    let mut retained = trees();
    retained
        .snapshots
        .insert("e".repeat(64), "/tmp/foreign".into());
    assert!(BoundPreparation::new(request.clone(), retained).is_err());
    let mut retained = trees();
    retained.snapshots.insert(
        "e".repeat(64),
        format!("/nix/store/{}-context", "1".repeat(32)),
    );
    retained.snapshots.insert(
        "f".repeat(64),
        format!("/nix/store/{}-foreign", "2".repeat(32)),
    );
    assert!(BoundPreparation::new(request, retained).is_err());
    let mut request = super::tests::request();
    request.selection = IntentSelection::Exact {
        targets: vec![BuildTarget {
            host: "app".into(),
            configuration: "app".into(),
            outputs: vec!["out".into()],
        }],
    };
    assert!(BoundPreparation::new(request, trees()).is_err());
}

#[test]
fn native_no_work_has_coverage_without_fake_derivations() {
    let mut request = request();
    request.evaluation.action = BuildAction::Deploy;
    let IntentSelection::Fleet { host, .. } = &mut request.selection else {
        panic!()
    };
    *host = Some("external".into());
    request.required_hosts = vec!["external".into()];
    let bound = BoundPreparation::new(request.clone(), trees()).unwrap();
    let inputs = bound
        .candidate(
            &inventory(),
            &PlanCatalog::Native(BTreeSet::new()),
            &BTreeMap::new(),
            witnesses(),
        )
        .unwrap();
    inputs.validate(&request).unwrap();
    assert!(inputs.targets.is_empty());
    assert_eq!(inputs.required_hosts, ["external"]);
    assert_eq!(inputs.resolved[0].disposition, Disposition::NoNativePlan);
    // A compatibility probe failure does not grant the external exemption.
    assert!(
        bound
            .candidate(
                &inventory(),
                &PlanCatalog::NixosConfiguration,
                &BTreeMap::new(),
                witnesses()
            )
            .is_err()
    );
    request.evaluation.action = BuildAction::Build;
    assert!(
        BoundPreparation::new(request, trees())
            .unwrap()
            .candidate(
                &inventory(),
                &PlanCatalog::Native(BTreeSet::new()),
                &BTreeMap::new(),
                witnesses()
            )
            .is_err()
    );
}

#[test]
fn candidate_rejects_partial_foreign_and_missing_required_results() {
    let bound = BoundPreparation::new(request(), trees()).unwrap();
    let mut partial = derivations();
    partial.remove("app");
    assert!(
        bound
            .candidate(
                &inventory(),
                &PlanCatalog::NixosConfiguration,
                &partial,
                witnesses()
            )
            .is_err()
    );
    assert_eq!(partial.len(), 1);
    let mut foreign = derivations();
    foreign.insert("foreign".into(), partial["db"].clone());
    assert!(
        bound
            .candidate(
                &inventory(),
                &PlanCatalog::NixosConfiguration,
                &foreign,
                witnesses()
            )
            .is_err()
    );
    let mut request = request();
    request.required_hosts.push("external".into());
    assert!(
        BoundPreparation::new(request, trees())
            .unwrap()
            .candidate(
                &inventory(),
                &PlanCatalog::NixosConfiguration,
                &derivations(),
                witnesses()
            )
            .is_err()
    );
}

#[test]
fn retained_layers_resolve_caller_routes_and_must_reproduce_the_evaluated_inventory() {
    use crate::fleet::inventory_routing::{RouteRequest, RouteSource};
    use abird_host_agent::build_executor::preparation::worker::Planning;
    let bound = BoundPreparation::new(request(), trees()).unwrap();
    let layers = json!({
        "base": {"hosts": {
            "app": {"target": "10.0.0.1", "routes": {"cf": {"target": "app.example"}}},
            "db": {"target": "10.0.0.2"},
        }},
        "overlay": null,
        "dependencies": {"app": ["db"]},
    });
    // Same loader the live worker uses, over the retained values.
    let inventory = load_inventory(
        &mut RetainedLayers(&layers),
        bound.context(),
        Routes::ValidateOnly,
    )
    .unwrap();
    let selection = select_inventory(&inventory, bound.options()).unwrap();
    let catalog = PlanCatalog::NixosConfiguration;
    let mut prepared = bound
        .candidate(&inventory, &catalog, &derivations(), witnesses())
        .unwrap();
    let mut planning = Planning {
        version: 1,
        request: bound.request.clone(),
        inventory: serde_json::to_value(&inventory).unwrap(),
        catalog: serde_json::Value::Null,
        selection: serde_json::to_string(&selection).unwrap(),
        activation: Default::default(),
        layers: layers.clone(),
    };
    prepared.planning_digest = Some(planning.digest().unwrap());
    let restored = bound.restore_planning(&planning, &prepared).unwrap();
    assert_eq!(
        restored.inventory.hosts["app"].target.as_deref(),
        Some("10.0.0.1")
    );
    let routed = restored
        .inventory_with(Routes::Resolve {
            request: RouteRequest::Cf,
            source: RouteSource::Cli,
            identity: None,
        })
        .unwrap();
    assert_eq!(routed.hosts["app"].target.as_deref(), Some("app.example"));
    assert_eq!(routed.hosts["app"].deps, ["db"]);
    assert!(routed.route_decision.is_some());
    // Layers that would evaluate differently cannot be retained.
    planning.layers["base"]["hosts"]["app"]["target"] = json!("10.9.9.9");
    prepared.planning_digest = Some(planning.digest().unwrap());
    assert!(bound.restore_planning(&planning, &prepared).is_err());
}
