use std::collections::BTreeSet;

use abird_host_manager::fleet::health::{
    AgentStatusResponse, AgentStatusResult, BaselineTimerUnits, DeferredResource,
    DeferredResourceSet, DurableHold, DurableHoldResponse, DurableHoldResult, DurableUserHold,
    HealthDecision, HealthEvidence, HealthValidationError, HeldService, PodmanContainer,
    PodmanHealth, ReadinessBudget, RootlessMutation, SystemdJob, UnitSnapshot,
    classify_expected_unit, classify_held_unit, classify_podman_runtime,
    classify_transitional_unit, derive_readiness_budget, validate_deferred_resources,
    validate_durable_holds,
};

fn unit(active: &str) -> UnitSnapshot {
    UnitSnapshot {
        name: "abird-zulip.service".to_owned(),
        load_state: "loaded".to_owned(),
        active_state: active.to_owned(),
        sub_state: if active == "active" {
            "running".to_owned()
        } else {
            "dead".to_owned()
        },
        needs_daemon_reload: false,
    }
}

#[test]
fn expected_active_unit_is_healthy() {
    assert_eq!(
        classify_expected_unit(&unit("active"), &[]),
        HealthDecision::healthy()
    );
}

#[test]
fn expected_transitional_unit_is_settling() {
    let mut snapshot = unit("activating");
    snapshot.sub_state = "start".to_owned();

    assert!(matches!(
        classify_expected_unit(&snapshot, &[]),
        HealthDecision::Settling { .. }
    ));
}

#[test]
fn inactive_expected_unit_settles_only_for_its_exact_start_job() {
    let snapshot = unit("inactive");
    let exact = SystemdJob {
        id: 42,
        unit: snapshot.name.clone(),
        kind: "start".to_owned(),
        state: "waiting".to_owned(),
    };
    assert!(matches!(
        classify_expected_unit(&snapshot, &[exact]),
        HealthDecision::Settling { .. }
    ));

    let unrelated = SystemdJob {
        id: 43,
        unit: "abird-novu.service".to_owned(),
        kind: "start".to_owned(),
        state: "running".to_owned(),
    };
    assert!(matches!(
        classify_expected_unit(&snapshot, &[unrelated]),
        HealthDecision::ServiceFailure { .. }
    ));

    let completed = SystemdJob {
        id: 44,
        unit: snapshot.name.clone(),
        kind: "start".to_owned(),
        state: "done".to_owned(),
    };
    assert!(matches!(
        classify_expected_unit(&snapshot, &[completed]),
        HealthDecision::ServiceFailure { .. }
    ));
}

#[test]
fn expected_unit_accepts_every_legacy_start_like_job_kind() {
    let snapshot = unit("inactive");
    for kind in ["start", "restart", "try-restart", "reload-or-start"] {
        let job = SystemdJob {
            id: 1,
            unit: snapshot.name.clone(),
            kind: kind.to_owned(),
            state: "running".to_owned(),
        };
        assert!(
            matches!(
                classify_expected_unit(&snapshot, &[job]),
                HealthDecision::Settling { .. }
            ),
            "job kind {kind} must be treated as live convergence"
        );
    }
}

#[test]
fn stale_expected_or_held_unit_is_a_structural_failure() {
    let mut snapshot = unit("active");
    snapshot.needs_daemon_reload = true;
    assert!(matches!(
        classify_expected_unit(&snapshot, &[]),
        HealthDecision::StructuralFailure { .. }
    ));

    snapshot.needs_daemon_reload = false;
    snapshot.load_state = "not-found".to_owned();
    assert!(matches!(
        classify_held_unit(&snapshot),
        HealthDecision::StructuralFailure { .. }
    ));
}

#[test]
fn held_unit_must_be_stopped() {
    assert_eq!(
        classify_held_unit(&unit("inactive")),
        HealthDecision::healthy()
    );
    assert!(matches!(
        classify_held_unit(&unit("deactivating")),
        HealthDecision::Settling { .. }
    ));
    assert!(matches!(
        classify_held_unit(&unit("active")),
        HealthDecision::ServiceFailure { .. }
    ));
}

#[test]
fn combined_health_decision_uses_fail_closed_precedence_and_keeps_evidence() {
    let healthy = HealthDecision::Healthy {
        evidence: vec![HealthEvidence::IgnoredBaselineTimer {
            unit: "fstrim.service".to_owned(),
        }],
    };
    let settling = HealthDecision::Settling {
        evidence: vec![HealthEvidence::RootlessMutation {
            service: "abird-zulip".to_owned(),
            pid: 10,
        }],
    };
    let service = HealthDecision::ServiceFailure {
        evidence: vec![HealthEvidence::PodmanUnhealthy {
            container: "zulip".to_owned(),
            status: "Up (unhealthy)".to_owned(),
        }],
    };
    let structural = HealthDecision::StructuralFailure {
        evidence: vec![HealthEvidence::InvalidUnitContract {
            unit: "abird-zulip.service".to_owned(),
            load_state: "loaded".to_owned(),
            needs_daemon_reload: true,
        }],
    };

    let combined = healthy.merge(settling).merge(service).merge(structural);
    match combined {
        HealthDecision::StructuralFailure { evidence } => assert_eq!(evidence.len(), 4),
        other => panic!("unexpected aggregate verdict: {other:?}"),
    }
}

#[test]
fn missing_host_agent_has_no_durable_holds() {
    assert_eq!(validate_durable_holds(None).unwrap(), Vec::new());
}

#[test]
fn durable_user_holds_are_validated_deduplicated_and_sorted() {
    let response = DurableHoldResponse {
        ok: true,
        operation: "hold_list".to_owned(),
        result: DurableHoldResult {
            holds: vec![
                DurableHold {
                    resource: "service:zulip".to_owned(),
                    services: vec![
                        HeldService {
                            scope: "user".to_owned(),
                            user: Some("abird".to_owned()),
                            unit: Some("abird-zulip.service".to_owned()),
                        },
                        HeldService {
                            scope: "system".to_owned(),
                            user: None,
                            unit: Some("postgresql.service".to_owned()),
                        },
                    ],
                },
                DurableHold {
                    resource: "service:duplicate".to_owned(),
                    services: vec![HeldService {
                        scope: "user".to_owned(),
                        user: Some("abird".to_owned()),
                        unit: Some("abird-zulip.service".to_owned()),
                    }],
                },
            ],
        },
    };

    assert_eq!(
        validate_durable_holds(Some(&response)).unwrap(),
        vec![DurableUserHold {
            user: "abird".to_owned(),
            unit: "abird-zulip.service".to_owned(),
        }]
    );
}

#[test]
fn malformed_durable_hold_response_fails_closed() {
    let response = DurableHoldResponse {
        ok: false,
        operation: "hold_list".to_owned(),
        result: DurableHoldResult { holds: vec![] },
    };
    assert_eq!(
        validate_durable_holds(Some(&response)),
        Err(HealthValidationError::InvalidDurableHoldResponse)
    );

    let malformed_user = DurableHoldResponse {
        ok: true,
        operation: "hold_list".to_owned(),
        result: DurableHoldResult {
            holds: vec![DurableHold {
                resource: "service:zulip".to_owned(),
                services: vec![HeldService {
                    scope: "user".to_owned(),
                    user: None,
                    unit: Some("abird-zulip.service".to_owned()),
                }],
            }],
        },
    };
    assert_eq!(
        validate_durable_holds(Some(&malformed_user)),
        Err(HealthValidationError::InvalidDurableHoldResponse)
    );
}

#[test]
fn legacy_agent_without_deferral_schema_is_accepted() {
    let response = AgentStatusResponse {
        ok: true,
        operation: "agent_status".to_owned(),
        result: AgentStatusResult {
            status_schema_version: None,
            configuration_revision: None,
            deferred_resources: None,
        },
    };
    assert_eq!(validate_deferred_resources(None).unwrap(), Vec::new());
    assert_eq!(
        validate_deferred_resources(Some(&response)).unwrap(),
        Vec::new()
    );
}

#[test]
fn host_agent_wire_responses_deserialize_into_validation_types() {
    let holds: DurableHoldResponse = serde_json::from_str(
        r#"{
            "ok": true,
            "operation": "hold_list",
            "result": {
                "holds": [{
                    "resource": "service:zulip",
                    "services": [{
                        "scope": "user",
                        "user": "abird",
                        "unit": "abird-zulip.service"
                    }]
                }]
            }
        }"#,
    )
    .unwrap();
    assert_eq!(validate_durable_holds(Some(&holds)).unwrap().len(), 1);

    let status: AgentStatusResponse = serde_json::from_str(
        r#"{
            "ok": true,
            "operation": "agent_status",
            "result": {
                "status_schema_version": 2,
                "deferred_resources": {
                    "count": 1,
                    "resources": [{
                        "resource": "service:zulip",
                        "reason": "activation_job_specification_conflict",
                        "generation": 3,
                        "isolated": true
                    }]
                }
            }
        }"#,
    )
    .unwrap();
    assert_eq!(validate_deferred_resources(Some(&status)).unwrap().len(), 1);
}

#[test]
fn schema_two_deferred_resources_require_exact_count_and_isolation() {
    let resource = DeferredResource {
        resource: "service:zulip".to_owned(),
        state: None,
        transaction_id: None,
        projection_id: None,
        reason: "activation_job_specification_conflict".to_owned(),
        detail: Some("retained diagnostic context".to_owned()),
        generation: 3,
        isolated: true,
    };
    let response = AgentStatusResponse {
        ok: true,
        operation: "agent_status".to_owned(),
        result: AgentStatusResult {
            status_schema_version: Some(2),
            configuration_revision: None,
            deferred_resources: Some(DeferredResourceSet {
                count: 1,
                resources: vec![resource.clone()],
            }),
        },
    };
    assert_eq!(
        validate_deferred_resources(Some(&response)).unwrap(),
        vec![resource]
    );

    let mut mismatched = response.clone();
    mismatched.result.deferred_resources.as_mut().unwrap().count = 2;
    assert_eq!(
        validate_deferred_resources(Some(&mismatched)),
        Err(HealthValidationError::InvalidDeferredResourceResponse)
    );

    let mut unsafe_response = response;
    unsafe_response
        .result
        .deferred_resources
        .as_mut()
        .unwrap()
        .resources[0]
        .isolated = false;
    assert_eq!(
        validate_deferred_resources(Some(&unsafe_response)),
        Err(HealthValidationError::UnsafeDeferredResource)
    );
}

fn schema_three_status() -> serde_json::Value {
    serde_json::json!({
        "ok": true,
        "operation": "agent_status",
        "result": {
            "status_schema_version": 3,
            "configuration_revision": "0123456789abcdef",
            "deferred_resources": {
                "count": 1,
                "resources": [{
                    "resource": "service:zulip",
                    "state": "active",
                    "transaction_id": "zulip-tearoff--item-001",
                    "projection_id": "zulip-tearoff",
                    "generation": 3,
                    "reason": "activation_job_specification_conflict",
                    "isolated": true
                }]
            }
        }
    })
}

#[test]
fn schema_three_accepts_bound_status_with_and_without_deferrals() {
    let wire = schema_three_status();
    let response: AgentStatusResponse = serde_json::from_value(wire.clone()).unwrap();
    let validated = validate_deferred_resources(Some(&response)).unwrap();
    assert_eq!(validated.len(), 1);
    assert_eq!(
        validated[0].transaction_id.as_deref(),
        Some("zulip-tearoff--item-001")
    );
    assert_eq!(validated[0].projection_id.as_deref(), Some("zulip-tearoff"));
    assert_eq!(validated[0].state.as_deref(), Some("active"));

    let mut empty = wire;
    empty["result"]["deferred_resources"] = serde_json::json!({"count":0,"resources":[]});
    let response = serde_json::from_value(empty).unwrap();
    assert!(
        validate_deferred_resources(Some(&response))
            .unwrap()
            .is_empty()
    );
}

#[test]
fn schema_three_rejects_duplicate_resource_evidence() {
    let mut wire = schema_three_status();
    let duplicate = wire["result"]["deferred_resources"]["resources"][0].clone();
    wire["result"]["deferred_resources"]["resources"] =
        serde_json::json!([duplicate.clone(), duplicate]);
    wire["result"]["deferred_resources"]["count"] = serde_json::json!(2);
    let response = serde_json::from_value(wire).unwrap();
    assert_eq!(
        validate_deferred_resources(Some(&response)),
        Err(HealthValidationError::InvalidDeferredResourceResponse)
    );
}

#[test]
fn schema_three_requires_revision_and_each_deferral_identity() {
    for field in [
        "configuration_revision",
        "transaction_id",
        "projection_id",
        "state",
    ] {
        for value in [
            None,
            Some(serde_json::Value::Null),
            Some(serde_json::json!("")),
        ] {
            // State is an existing string field, not an immutable identity.
            if field == "state" && value == Some(serde_json::json!("")) {
                continue;
            }
            let mut wire = schema_three_status();
            let object = if field == "configuration_revision" {
                wire["result"].as_object_mut().unwrap()
            } else {
                wire["result"]["deferred_resources"]["resources"][0]
                    .as_object_mut()
                    .unwrap()
            };
            if let Some(value) = value {
                object.insert(field.to_owned(), value);
            } else {
                object.remove(field);
            }
            let response = serde_json::from_value(wire).unwrap();
            assert_eq!(
                validate_deferred_resources(Some(&response)),
                Err(HealthValidationError::InvalidDeferredResourceResponse),
                "{field}"
            );
        }
    }
}

#[test]
fn schema_three_preserves_exact_count_isolation_and_unknown_schema_refusal() {
    for (field, value, expected) in [
        (
            "count",
            serde_json::json!(2),
            HealthValidationError::InvalidDeferredResourceResponse,
        ),
        (
            "isolated",
            serde_json::json!(false),
            HealthValidationError::UnsafeDeferredResource,
        ),
        (
            "version",
            serde_json::json!(4),
            HealthValidationError::InvalidDeferredResourceResponse,
        ),
    ] {
        let mut wire = schema_three_status();
        match field {
            "count" => wire["result"]["deferred_resources"]["count"] = value,
            "isolated" => wire["result"]["deferred_resources"]["resources"][0]["isolated"] = value,
            _ => wire["result"]["status_schema_version"] = value,
        }
        let response = serde_json::from_value(wire).unwrap();
        assert_eq!(validate_deferred_resources(Some(&response)), Err(expected));
    }
}

#[test]
fn baseline_timer_transition_is_logged_but_does_not_settle_health() {
    let baseline = BaselineTimerUnits::from_names(["fstrim.service"]);
    let mut fstrim = unit("activating");
    fstrim.name = "fstrim.service".to_owned();

    assert!(matches!(
        classify_transitional_unit(&fstrim, &baseline),
        HealthDecision::Healthy { evidence }
            if evidence == vec![HealthEvidence::IgnoredBaselineTimer {
                unit: "fstrim.service".to_owned()
            }]
    ));

    let later = UnitSnapshot {
        name: "nix-gc.service".to_owned(),
        ..fstrim
    };
    assert!(matches!(
        classify_transitional_unit(&later, &baseline),
        HealthDecision::Settling { .. }
    ));
}

#[test]
fn unhealthy_podman_is_failure_only_when_no_deployment_work_is_settling() {
    let unhealthy = PodmanContainer {
        name: "zulip".to_owned(),
        health: PodmanHealth::Unhealthy,
        status: "Up 3 minutes (unhealthy)".to_owned(),
    };
    assert!(matches!(
        classify_podman_runtime(std::slice::from_ref(&unhealthy), &[], false),
        HealthDecision::ServiceFailure { .. }
    ));
    assert!(matches!(
        classify_podman_runtime(std::slice::from_ref(&unhealthy), &[], true),
        HealthDecision::Settling { .. }
    ));

    let mutation = RootlessMutation {
        service: "abird-zulip".to_owned(),
        pid: 123,
        reason: "compose up".to_owned(),
        started_at: "456".to_owned(),
        live: true,
    };
    assert!(matches!(
        classify_podman_runtime(&[unhealthy], &[mutation], false),
        HealthDecision::Settling { .. }
    ));
}

#[test]
fn starting_container_settles_and_dead_mutation_is_ignored() {
    let healthy = PodmanContainer {
        name: "postgres".to_owned(),
        health: PodmanHealth::Healthy,
        status: "Up 4 minutes (healthy)".to_owned(),
    };
    assert_eq!(
        classify_podman_runtime(&[healthy], &[], false),
        HealthDecision::healthy()
    );

    let starting = PodmanContainer {
        name: "postgres".to_owned(),
        health: PodmanHealth::Starting,
        status: "Up 4 seconds (starting)".to_owned(),
    };
    assert!(matches!(
        classify_podman_runtime(&[starting], &[], false),
        HealthDecision::Settling { .. }
    ));

    let dead = RootlessMutation {
        service: "abird-zulip".to_owned(),
        pid: 123,
        reason: "compose up".to_owned(),
        started_at: "456".to_owned(),
        live: false,
    };
    assert_eq!(
        classify_podman_runtime(&[], &[dead], false),
        HealthDecision::healthy()
    );
}

#[test]
fn readiness_budget_uses_maximum_plus_thirty_seconds_per_extra_annotation() {
    assert_eq!(
        derive_readiness_budget(&[], &[45, 120, 30]).unwrap(),
        Some(ReadinessBudget {
            timeout_seconds: 180,
            annotated_unit_count: 3,
        })
    );
    assert_eq!(
        derive_readiness_budget(&[3600], &[]).unwrap(),
        Some(ReadinessBudget {
            timeout_seconds: 3600,
            annotated_unit_count: 1,
        })
    );
    assert_eq!(derive_readiness_budget(&[0], &[0]).unwrap(), None);
}

#[test]
fn readiness_budget_rejects_overflow() {
    assert_eq!(
        derive_readiness_budget(&[u64::MAX], &[1]),
        Err(HealthValidationError::ReadinessBudgetOverflow)
    );
}

#[test]
fn baseline_set_constructor_is_deterministic() {
    let baseline =
        BaselineTimerUnits::from_names(["fstrim.service", "fstrim.service", "nix-gc.service"]);
    assert_eq!(
        baseline.as_set(),
        &BTreeSet::from(["fstrim.service".to_owned(), "nix-gc.service".to_owned(),])
    );
}
