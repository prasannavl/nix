use super::*;
use crate::build_executor::preparation::worker::Snapshot;
use crate::build_executor::preparation::{PreparedTarget, ResolvedTarget};
use crate::build_executor::request::Selection;
use serde_json::json;
use std::collections::BTreeMap;

fn binding(input: &Input, relative: &str) -> Value {
    let mut info = input.native_info.clone();
    info["accessor"] = json!("upstream-produced");
    info["type"] = json!("git");
    info["url"] = json!(format!("file://{}", input.native_source.display()));
    info["dir"] = json!(relative);
    info["lock"] = json!("e".repeat(64));
    info
}

#[test]
fn independent_dirty_git_root_uses_its_own_revision_and_accessor_evidence() {
    use crate::build_executor::preparation::worker::NativeRoot;
    let (mut input, _) = fixture();
    let hash = "a".repeat(64);
    let location = InputLocation {
        tree: InputTree::Git {
            context_digest: hash.clone(),
        },
        relative: String::new(),
    };
    let path = format!("/nix/store/{}-source", "1".repeat(32));
    let revision = "f".repeat(40);
    let mut info = input.native_info.clone();
    info["outPath"] = json!(path);
    info.as_object_mut().unwrap().remove("rev");
    info["dirtyRev"] = json!(format!("{revision}-dirty"));
    input.version = 4;
    input.request.evaluation.dependency_flake = location.clone();
    input.native_roots.insert(
        hash,
        NativeRoot {
            source: Snapshot {
                path,
                nar_digest: input.source.nar_digest.clone(),
            },
            native_source: "/private/sealed/independent".into(),
            native_info: info.clone(),
            revision,
        },
    );
    input.validate().unwrap();
    info["accessor"] = json!("upstream-produced");
    info["type"] = json!("git");
    info["url"] = json!("file:///private/sealed/independent");
    info["dir"] = json!("");
    info["lock"] = json!("e".repeat(64));
    let mut consumed = Consumed {
        location,
        source_info: info,
    };
    consumed.validate(&input).unwrap();
    consumed.source_info = binding(&input, "");
    assert!(
        consumed.validate(&input).is_err(),
        "primary evidence cannot cover another root"
    );
    consumed.source_info["url"] = json!("file:///private/sealed/independent");
    assert!(
        consumed.validate(&input).is_err(),
        "renaming primary evidence cannot forge its revision"
    );
    input.native_roots.clear();
    assert!(
        input.validate().is_err(),
        "external native coverage is exact"
    );
}

fn fixture() -> (Input, Output) {
    let request = crate::build_executor::journal::tests::request("consumed");
    let Selection::Exact { targets } = &request.selection else {
        panic!()
    };
    let path = format!("/nix/store/{}-source", "0".repeat(32));
    let prepared = PreparedInputs {
        version: crate::build_executor::preparation::VERSION,
        attempt_id: request.attempt_id().unwrap(),
        spec_digest: request.digest().unwrap(),
        source_path: path.clone(),
        tree_digest: "b".repeat(64),
        evaluation_digest: request.evaluation.digest().unwrap(),
        context_sources: BTreeMap::new(),
        caller_repository: None,
        resolved: vec![ResolvedTarget {
            host: "app".into(),
            configuration: "app".into(),
            disposition: Disposition::Build,
        }],
        targets: vec![PreparedTarget {
            target: targets[0].clone(),
            derivation: format!("/nix/store/{}-system.drv", "0".repeat(32)),
        }],
        required_hosts: request.required_hosts.clone(),
        selection_digest: "c".repeat(64),
        planning_digest: None,
        protection_digest: "d".repeat(64),
    };
    let input = Input {
        version: 3,
        native_system: "x86_64-linux".into(),
        native_info: json!({"outPath": path, "narHash": "sha256-u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u7u4=",
            "rev": request.source.revision, "revCount": 3, "lastModified": 100}),
        request,
        source: Snapshot {
            path,
            nar_digest: "b".repeat(64),
        },
        protection_digest: "d".repeat(64),
        snapshots: BTreeMap::new(),
        native_roots: BTreeMap::new(),
        caller_repository: None,
        native_source: "/private/sealed/repository".into(),
        budget_millis: 1000,
    };
    let mut consumed = Consumption::default();
    for (kind, attribute, value) in [
        (
            QueryKind::Dependencies,
            "nixbot.deployDependencies",
            json!({"app": []}),
        ),
        (QueryKind::Catalog, "nixbot.plans", json!(["app"])),
        (
            QueryKind::Derivation { host: "app".into() },
            "nixbot.plans.app.drvPath",
            json!(prepared.targets[0].derivation),
        ),
    ] {
        consumed
            .observe(
                &input,
                Consumed {
                    location: InputLocation::source(""),
                    source_info: binding(&input, ""),
                },
                Query {
                    kind,
                    location: InputLocation::source(""),
                    attribute: Some(attribute.into()),
                    result_digest: value_digest(&value).unwrap(),
                    inputs: vec!["nixpkgs".into()],
                },
            )
            .unwrap();
    }
    let output = Output {
        version: 3,
        prepared,
        consumed,
        planning: None,
    };
    output.validate(&input).unwrap();
    (input, output)
}

#[test]
fn complete_result_retains_actual_queries_not_an_independent_anchor() {
    let (mut input, output) = fixture();
    let bytes = serde_json::to_vec(&output).unwrap();
    let restored = Output::decode(&bytes, &input).unwrap();
    // Stock Nix 2.34: fetchTree omits the count, lockedRef retains it.
    input
        .native_info
        .as_object_mut()
        .unwrap()
        .remove("revCount");
    Output::decode(&bytes, &input).unwrap();
    input.native_info["revCount"] = json!(4);
    assert!(Output::decode(&bytes, &input).is_err());
    input.native_info["revCount"] = json!(3);
    assert_eq!(restored.consumed.flakes.len(), 1);
    assert_eq!(restored.consumed.queries.len(), 3);
    assert!(
        !serde_json::to_value(&input)
            .unwrap()
            .as_object()
            .unwrap()
            .contains_key("native_flakes")
    );
    // A pre-v2 bare PreparedInputs cannot supply the actual-query observations.
    assert!(Output::decode(&serde_json::to_vec(&output.prepared).unwrap(), &input).is_err());
}

#[test]
fn new_fleet_preparation_cannot_omit_planning_even_when_the_digest_is_absent() {
    let (mut input, mut output) = fixture();
    input.request.selection = Selection::Fleet {
        groups: vec![],
        host: Some("app".into()),
        hosts: None,
        nix_config: None,
        control_plane_first: false,
    };
    output.prepared.attempt_id = input.request.attempt_id().unwrap();
    output.prepared.spec_digest = input.request.digest().unwrap();
    output.consumed.validate(&input, &output.prepared).unwrap();
    assert!(
        output
            .validate(&input)
            .unwrap_err()
            .to_string()
            .contains("fleet preparation lacks retained planning")
    );
}

#[test]
fn private_planning_binds_actual_catalog_and_shares_the_complete_result_bound() {
    let (input, mut output) = fixture();
    let old = serde_json::to_value(&output).unwrap();
    assert!(old.get("planning").is_none());
    assert!(old["prepared"].get("planning_digest").is_none());

    let planning = Planning {
        version: 1,
        request: input.request.clone(),
        inventory: json!({"hosts": {"app": {}}}),
        catalog: json!(["app"]),
        selection: r#"{"ordered":["app"]}"#.into(),
        activation: Default::default(),
        layers: json!({"base": {"hosts": {"app": {}}}, "overlay": null,
            "dependencies": {"app": []}}),
    };
    output.prepared.selection_digest = digest_bytes(planning.selection.as_bytes());
    output.prepared.planning_digest = Some(planning.digest().unwrap());
    output.planning = Some(planning.clone());
    let decoded = Output::decode(&serde_json::to_vec(&output).unwrap(), &input).unwrap();
    assert_eq!(decoded.planning.unwrap().inventory, planning.inventory);

    output.planning.as_mut().unwrap().inventory["hosts"]["foreign"] = json!({});
    assert!(output.validate(&input).is_err());
    output.planning = Some(planning.clone());
    output.planning.as_mut().unwrap().catalog = json!(["foreign"]);
    output.prepared.planning_digest = Some(output.planning.as_ref().unwrap().digest().unwrap());
    assert!(output.validate(&input).is_err()); // A self-hash cannot replace the actual query.
    output.planning = Some(planning);
    let bytes = serde_json::to_vec(output.planning.as_ref().unwrap())
        .unwrap()
        .len();
    output.planning.as_mut().unwrap().inventory["padding"] =
        json!("p".repeat(MAX_PREPARED_BYTES - bytes - 30));
    output.prepared.planning_digest = Some(output.planning.as_ref().unwrap().digest().unwrap());
    assert!(output.validate(&input).is_err()); // No second preparation-output allowance.
    output.planning = None;
    assert!(output.validate(&input).is_err()); // Missing data cannot be reconstructed later.
}

#[test]
fn matching_root_metadata_cannot_replace_missing_reordered_or_foreign_results() {
    let (input, mut output) = fixture();
    let query = output.consumed.queries.pop().unwrap();
    assert!(output.validate(&input).is_err());
    output.consumed.queries.push(query);
    output.consumed.queries.swap(0, 1);
    assert!(output.validate(&input).is_err());
    output.consumed.queries.swap(0, 1);
    output.consumed.queries[2].result_digest =
        value_digest(&json!("/nix/store/foreign.drv")).unwrap();
    assert!(output.validate(&input).is_err());
}

#[test]
fn native_absence_is_catalog_only_and_requires_null_not_a_failed_probe() {
    let (input, mut output) = fixture();
    output.consumed.queries[1].attribute = None;
    assert!(output.validate(&input).is_err());
    output.consumed.queries[1].result_digest = value_digest(&Value::Null).unwrap();
    output.validate(&input).unwrap();
    output.consumed.queries[0].attribute = None;
    output.consumed.queries[0].result_digest = value_digest(&Value::Null).unwrap();
    assert!(output.validate(&input).is_err());
}

#[test]
fn each_native_flake_location_requires_its_actual_consumption() {
    let (mut input, mut output) = fixture();
    input.request.evaluation.dependency_flake = InputLocation::source("dependency");
    output.prepared.attempt_id = input.request.attempt_id().unwrap();
    output.prepared.spec_digest = input.request.digest().unwrap();
    output.prepared.evaluation_digest = input.request.evaluation.digest().unwrap();
    assert!(output.validate(&input).is_err());
    output.consumed.queries[0].location = input.request.evaluation.dependency_flake.clone();
    output.consumed.flakes.push(Consumed {
        location: input.request.evaluation.dependency_flake.clone(),
        source_info: binding(&input, "dependency"),
    });
    output.validate(&input).unwrap();
    output.consumed.flakes[1].source_info["rev"] = json!("c".repeat(40));
    assert!(output.validate(&input).is_err());
}

#[test]
fn changed_actual_context_does_not_append_a_replacement_receipt() {
    let (input, mut output) = fixture();
    let before = serde_json::to_vec(&output.consumed).unwrap();
    let mut changed = binding(&input, "");
    changed["lock"] = json!("f".repeat(64));
    let query = output.consumed.queries[2].clone();
    assert!(
        output
            .consumed
            .observe(
                &input,
                Consumed {
                    location: query.location.clone(),
                    source_info: changed
                },
                query
            )
            .is_err()
    );
    assert_eq!(serde_json::to_vec(&output.consumed).unwrap(), before);
}

#[test]
fn source_context_cannot_smuggle_snapshot_flakes_or_an_old_probe_map() {
    let (mut input, _) = fixture();
    let mut value = serde_json::to_value(&input).unwrap();
    value["native_flakes"] = json!({"": input.native_info});
    assert!(Input::decode(&serde_json::to_vec(&value).unwrap()).is_err());
    input.request.evaluation.dependency_flake = InputLocation {
        tree: InputTree::Snapshot {
            nar_digest: "f".repeat(64),
        },
        relative: String::new(),
    };
    input.snapshots.insert(
        "f".repeat(64),
        format!("/nix/store/{}-external", "1".repeat(32)),
    );
    assert!(input.validate().is_err());
}

#[test]
fn evaluated_source_metadata_cannot_stand_in_for_the_upstream_accessor_binding() {
    let (input, output) = fixture();
    let query = output.consumed.queries[0].clone();
    let observe = |source_info: Value, query: Query| {
        Consumption::default().observe(
            &input,
            Consumed {
                location: InputLocation::source(""),
                source_info,
            },
            query,
        )
    };
    // Matching outPath/narHash/rev from an evaluated sourceInfo is not provenance.
    assert!(observe(input.native_info.clone(), query.clone()).is_err());
    let mut foreign = binding(&input, "");
    foreign["url"] = json!("file:///caller/other");
    assert!(observe(foreign, query.clone()).is_err());
    let mut substituted = binding(&input, "");
    substituted["type"] = json!("path");
    assert!(observe(substituted, query.clone()).is_err());
    let mut unsorted = query.clone();
    unsorted.inputs = vec!["b".into(), "a".into()];
    assert!(observe(binding(&input, ""), unsorted).is_err());
    observe(binding(&input, ""), query).unwrap();
}

#[test]
fn mounted_external_inputs_only_accumulate_within_one_evaluator() {
    let (input, mut output) = fixture();
    let mut query = output.consumed.queries[2].clone();
    query.inputs.clear();
    assert!(
        output
            .consumed
            .observe(
                &input,
                Consumed {
                    location: query.location.clone(),
                    source_info: binding(&input, ""),
                },
                query
            )
            .is_err()
    );
}

#[test]
fn retained_layers_and_activation_facts_bind_the_actual_queries() {
    let (input, mut output) = fixture();
    let planning = Planning {
        version: 1,
        request: input.request.clone(),
        inventory: json!({"hosts": {"app": {}}}),
        catalog: json!(["app"]),
        selection: r#"{"ordered":["app"]}"#.into(),
        activation: Default::default(),
        layers: json!({"base": {"hosts": {}}, "overlay": null, "dependencies": {"app": ["x"]}}),
    };
    output.prepared.selection_digest = digest_bytes(planning.selection.as_bytes());
    output.prepared.planning_digest = Some(planning.digest().unwrap());
    output.planning = Some(planning.clone());
    // Dependencies differ from the value the actual first query returned.
    assert!(output.validate(&input).is_err());
    let mut fixed = planning.clone();
    fixed.layers["dependencies"] = json!({"app": []});
    output.prepared.planning_digest = Some(fixed.digest().unwrap());
    output.planning = Some(fixed.clone());
    output.validate(&input).unwrap();
    // A fact without its actual Activation query cannot be retained.
    let mut forged = fixed.clone();
    forged.activation.insert("app".into(), true);
    output.prepared.planning_digest = Some(forged.digest().unwrap());
    output.planning = Some(forged);
    assert!(output.validate(&input).is_err());
    // New fleet outputs cannot omit the layers.
    let mut missing = fixed;
    missing.layers = Value::Null;
    output.prepared.planning_digest = Some(missing.digest().unwrap());
    output.planning = Some(missing);
    assert!(output.validate(&input).is_err());
}

#[test]
fn deployment_requires_one_activation_query_per_target_after_derivations() {
    let (mut input, mut output) = fixture();
    input.request.evaluation.action = crate::build_executor::context::BuildAction::Deploy;
    input.request.selection = Selection::Fleet {
        groups: vec![],
        host: Some("app".into()),
        hosts: None,
        nix_config: None,
        control_plane_first: false,
    };
    output.prepared.attempt_id = input.request.attempt_id().unwrap();
    output.prepared.spec_digest = input.request.digest().unwrap();
    output.prepared.evaluation_digest = input.request.evaluation.digest().unwrap();
    assert!(output.consumed.validate(&input, &output.prepared).is_err());
    let mut activation = output.consumed.queries[2].clone();
    activation.kind = QueryKind::Activation { host: "app".into() };
    activation.attribute = Some("nixosConfigurations.app.config.boot.isContainer".into());
    activation.result_digest = value_digest(&json!(false)).unwrap();
    output.consumed.queries.push(activation.clone());
    output.consumed.validate(&input, &output.prepared).unwrap();
    output.consumed.queries.last_mut().unwrap().result_digest =
        value_digest(&json!("/nix/store/x")).unwrap();
    assert!(output.consumed.validate(&input, &output.prepared).is_err());
    *output.consumed.queries.last_mut().unwrap() = activation;
    output.consumed.queries.swap(2, 3);
    assert!(output.consumed.validate(&input, &output.prepared).is_err());
}
