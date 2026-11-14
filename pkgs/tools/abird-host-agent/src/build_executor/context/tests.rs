use super::*;
use crate::build_executor::journal::tests::request;
use crate::build_executor::request::{BuildRequest, Owner, REQUEST_VERSION};

#[test]
fn context_is_bound_without_materialization_and_replay_keeps_the_same_identity() {
    let original = request("context");
    let id = original.attempt_id().unwrap();
    let spec = original.digest().unwrap();
    for mutate in [
        |value: &mut EvaluationIntent| value.build_flake.relative = "subdir".into(),
        |value: &mut EvaluationIntent| value.inventory.relative = "other.nix".into(),
        |value: &mut EvaluationIntent| value.overlay = Some(InputLocation::source("override.nix")),
        |value: &mut EvaluationIntent| {
            value.repository_config = Some(InputLocation::source("config"))
        },
        |value: &mut EvaluationIntent| value.dependency_flake.relative = "nested".into(),
        |value: &mut EvaluationIntent| value.action = BuildAction::Deploy,
        |value: &mut EvaluationIntent| value.plan_jobs = PlanJobs::Count { jobs: 1 },
        |value: &mut EvaluationIntent| value.deploy_jobs_per_domain = Some(8),
        |value: &mut EvaluationIntent| {
            value.inventory.tree = InputTree::Snapshot {
                nar_digest: "b".repeat(64),
            }
        },
    ] {
        let mut changed = original.clone();
        mutate(&mut changed.evaluation);
        assert_eq!(changed.attempt_id().unwrap(), id);
        assert_ne!(changed.digest().unwrap(), spec);
        let bytes = serde_json::to_vec(&changed).unwrap();
        assert!(!std::str::from_utf8(&bytes).unwrap().contains("/nix/store/"));
        assert_eq!(BuildRequest::decode(&bytes).unwrap(), changed);
    }
}

#[test]
fn input_locations_reject_escape_aliases_controls_and_oversize() {
    for path in [
        "/absolute",
        "..",
        "a/../b",
        ".",
        "a/./b",
        "a//b",
        "a/",
        "a\0b",
        "a\nb",
        "",
    ] {
        let mut value = request("context").evaluation;
        value.inventory.relative = path.into();
        assert!(value.validate().is_err(), "{path:?}");
    }
    for path in ["a".repeat(256), ("a/".repeat(2049)) + "b"] {
        let mut value = request("context").evaluation;
        value.inventory.relative = path;
        assert!(value.validate().is_err());
    }
    let mut value = request("context").evaluation;
    value.inventory.relative = "inputs with spaces/配置.nix".into();
    value.repository_config = Some(InputLocation::source(""));
    value.validate().unwrap();
    value.overlay = Some(InputLocation::source(""));
    assert!(value.validate().is_err());
}

#[test]
fn explicit_snapshot_set_is_deduplicated_and_digests_are_strict() {
    let mut value = request("context").evaluation;
    let tree = InputTree::Snapshot {
        nar_digest: "a".repeat(64),
    };
    value.overlay = Some(InputLocation {
        tree: tree.clone(),
        relative: "overlay.nix".into(),
    });
    value.dependency_flake.tree = tree;
    value.validate().unwrap();
    assert_eq!(
        value.snapshot_digests(),
        BTreeSet::from(["a".repeat(64).as_str()])
    );
    value.dependency_flake.tree = InputTree::Snapshot {
        nar_digest: "/tmp/not-a-witness".into(),
    };
    assert!(value.validate().is_err());
}

#[test]
fn mode_detachment_versions_and_capacity_are_not_inferred() {
    let mut value = request("context");
    value.mode = BuildMode::Development;
    assert!(value.validate().is_err());
    value.evaluation.action = BuildAction::DevBuild;
    value.validate().unwrap();
    value.mode = BuildMode::System;
    value.evaluation.action = BuildAction::Deploy;
    value.owner = Owner::Detached;
    assert!(value.validate().is_err());
    value.evaluation.action = BuildAction::Build;
    value.validate().unwrap();
    for version in [1, 2, REQUEST_VERSION + 1] {
        let mut old = value.clone();
        old.schema_version = version;
        assert!(old.validate().is_err());
    }
    value.evaluation.version += 1;
    assert!(value.validate().is_err());
    value.evaluation.version = VERSION;
    for jobs in [0, 65, u16::MAX] {
        value.evaluation.plan_jobs = PlanJobs::Count { jobs };
        assert!(value.validate().is_err());
    }
    value.evaluation.plan_jobs = PlanJobs::Auto;
    value.evaluation.deploy_jobs_per_domain = Some(0);
    assert!(value.validate().is_err());
}

#[test]
fn missing_context_or_unknown_effect_options_never_acquire_defaults() {
    let original = serde_json::to_value(request("context")).unwrap();
    for field in [
        "action",
        "build_flake",
        "inventory",
        "dependency_flake",
        "plan_jobs",
        "version",
    ] {
        let mut value = original.clone();
        value["evaluation"].as_object_mut().unwrap().remove(field);
        assert!(BuildRequest::decode(&serde_json::to_vec(&value).unwrap()).is_err());
    }
    for (field, inserted) in [
        ("command", serde_json::json!("sh")),
        ("store", serde_json::json!("local")),
        ("environment", serde_json::json!({"NIX_REMOTE":"local"})),
    ] {
        let mut value = original.clone();
        value["evaluation"][field] = inserted;
        assert!(BuildRequest::decode(&serde_json::to_vec(&value).unwrap()).is_err());
    }
}
