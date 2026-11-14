use super::*;
use crate::build_executor::preparation::{MAX_PREPARED_BYTES, PreparedTarget};
use crate::build_executor::protocol::{
    self, Command as WireCommand, Reply, Request, Response, Snapshot,
};

fn start(journal: &Journal) -> (BuildRequest, ExecutionHandle) {
    let request = request("one");
    let key = journal
        .submit("operator", request.clone(), 1000)
        .unwrap()
        .attempt_id;
    let owner = reserve(journal, &key);
    let handle = ExecutionHandle {
        ownership: owner,
        invocation_id: "worker".into(),
    };
    journal.started(handle.clone(), 1000).unwrap();
    (request, handle)
}

fn fleet() -> BuildRequest {
    let mut request = request("fleet");
    request.source.tree_digest = None;
    request.required_hosts.clear();
    request.selection = Selection::Fleet {
        groups: vec!["fleet".into()],
        host: None,
        hosts: Some("all,-excluded*".into()),
        nix_config: None,
        control_plane_first: true,
    };
    request
}

#[test]
fn unevaluated_intent_reaches_exclusive_admission_without_store_paths() {
    let (_root, journal) = fixture();
    let request = fleet();
    let bytes = serde_json::to_vec(&request).unwrap();
    let text = std::str::from_utf8(&bytes).unwrap();
    assert!(
        !text.contains("/nix/store/")
            && !text.contains("derivation")
            && !text.contains("retained_path")
    );
    assert_eq!(BuildRequest::decode(&bytes).unwrap(), request);
    let key = journal
        .submit("operator", request.clone(), 1000)
        .unwrap()
        .attempt_id;
    let owner = reserve(&journal, &key);
    assert_eq!(owner.attempt_id, key);
    assert_eq!(live(&journal, &key).phase(), Phase::Starting);
    let mut other = request;
    other.id.nonce = "other".into();
    let other = journal.submit("operator", other, 1000).unwrap().attempt_id;
    journal.queue(&other, 1000).unwrap();
    assert!(journal.reserve_next("boot", 1000).is_err());
    assert_eq!(journal.pool().unwrap().owner, Some(owner));
}

#[test]
fn intent_is_strict_and_binds_mode_selection_and_source_without_fake_paths() {
    let original = fleet();
    let mut changed = original.clone();
    changed.mode = BuildMode::Development;
    changed.evaluation.action = BuildAction::DevBuild;
    assert_eq!(
        changed.attempt_id().unwrap(),
        original.attempt_id().unwrap()
    );
    assert_ne!(changed.digest().unwrap(), original.digest().unwrap());
    let mut value = serde_json::to_value(&original).unwrap();
    for (pointer, replacement) in [
        ("/schema_version", serde_json::json!(1)),
        ("/mode", serde_json::json!("arbitrary-command")),
        ("/selection/hosts", serde_json::json!("all\nsecond")),
        ("/selection/host", serde_json::json!("also-exact")),
        ("/selection/nix_config", serde_json::json!("unscoped")),
        ("/source/revision", serde_json::json!("main")),
    ] {
        let mut bad = value.clone();
        *bad.pointer_mut(pointer).unwrap() = replacement;
        assert!(
            BuildRequest::decode(&serde_json::to_vec(&bad).unwrap()).is_err(),
            "{pointer}"
        );
    }
    value["source"]["retained_path"] = "/nix/store/not-an-admission-input".into();
    assert!(BuildRequest::decode(&serde_json::to_vec(&value).unwrap()).is_err());
    let mut value = serde_json::to_value(&original).unwrap();
    value["selection"]["execute"] = "arbitrary-command".into();
    assert!(BuildRequest::decode(&serde_json::to_vec(&value).unwrap()).is_err());
}

#[test]
fn prepared_manifest_is_bounded_strict_and_bound_to_exact_intent() {
    let request = request("one");
    let valid = inputs(&request);
    assert_eq!(
        PreparedInputs::decode(&serde_json::to_vec(&valid).unwrap(), &request).unwrap(),
        valid
    );
    for mutate in [
        |p: &mut PreparedInputs| p.version = 1,
        |p: &mut PreparedInputs| p.attempt_id = "f".repeat(64),
        |p: &mut PreparedInputs| p.spec_digest = "f".repeat(64),
        |p: &mut PreparedInputs| p.tree_digest = "f".repeat(64),
        |p: &mut PreparedInputs| p.source_path += "/child",
        |p: &mut PreparedInputs| p.targets[0].derivation = "/tmp/foreign.drv".into(),
        |p: &mut PreparedInputs| p.targets[0].derivation = p.source_path.clone(),
        |p: &mut PreparedInputs| p.targets[0].target.configuration = "other".into(),
        |p: &mut PreparedInputs| p.targets[0].target.outputs = vec!["other".into()],
        |p: &mut PreparedInputs| p.targets.push(p.targets[0].clone()),
        |p: &mut PreparedInputs| p.required_hosts.clear(),
        |p: &mut PreparedInputs| p.required_hosts.push("missing".into()),
        |p: &mut PreparedInputs| p.protection_digest.clear(),
        |p: &mut PreparedInputs| p.selection_digest.clear(),
    ] {
        let mut bad = valid.clone();
        mutate(&mut bad);
        assert!(bad.validate(&request).is_err());
    }
    let mut unknown = serde_json::to_value(&valid).unwrap();
    unknown["authorized"] = true.into();
    assert!(PreparedInputs::decode(&serde_json::to_vec(&unknown).unwrap(), &request).is_err());
    assert!(PreparedInputs::decode(&vec![b' '; MAX_PREPARED_BYTES + 1], &request).is_err());
}

#[test]
fn fleet_preparation_requires_resolved_coverage_and_keeps_requested_coverage() {
    let mut request = fleet();
    let mut prepared = inputs(&super::request("one"));
    prepared.required_hosts.clear();
    prepared.attempt_id = request.attempt_id().unwrap();
    prepared.spec_digest = request.digest().unwrap();
    prepared.validate(&request).unwrap();
    request.required_hosts.push("required".into());
    prepared.spec_digest = request.digest().unwrap();
    assert!(prepared.validate(&request).is_err());
    let mut target = prepared.targets[0].clone();
    target.target.host = "required".into();
    prepared
        .resolved
        .push(crate::build_executor::preparation::ResolvedTarget {
            host: target.target.host.clone(),
            configuration: target.target.configuration.clone(),
            disposition: crate::build_executor::preparation::Disposition::Build,
        });
    prepared.targets.push(target);
    assert!(prepared.validate(&request).is_err());
    prepared.required_hosts.push("required".into());
    prepared.validate(&request).unwrap();
    prepared.required_hosts.clear();
    assert!(prepared.validate(&request).is_err());
    // Native selection verification remains a trusted adapter effect, not this parser.
}

#[test]
fn preparation_cannot_precede_worker_ownership_or_change_after_publication() {
    let (_root, journal) = fixture();
    let request = request("one");
    let key = accepted(&journal, "one").attempt_id;
    let owner = reserve(&journal, &key);
    let prepared = inputs(&request);
    assert!(
        journal
            .record_prepared(&owner, prepared.clone(), 1000)
            .is_err()
    );
    let handle = ExecutionHandle {
        ownership: owner.clone(),
        invocation_id: "worker".into(),
    };
    journal.started(handle, 1000).unwrap();
    let mut stale = owner.clone();
    stale.pool_epoch = NonZeroU64::new(2).unwrap();
    assert!(
        journal
            .record_prepared(&stale, prepared.clone(), 1000)
            .is_err()
    );
    let digest = journal
        .record_prepared(&owner, prepared.clone(), 1000)
        .unwrap();
    let count = journal.events("operator", &key, None, 32).unwrap().latest;
    assert_eq!(
        journal
            .record_prepared(&owner, prepared.clone(), 1001)
            .unwrap(),
        digest
    );
    assert_eq!(
        journal.events("operator", &key, None, 32).unwrap().latest,
        count
    );
    let mut changed = prepared;
    changed.protection_digest = "f".repeat(64);
    assert!(journal.record_prepared(&owner, changed, 1001).is_err());
    let reopened = Journal::open(&journal.root, identity(), policy()).unwrap();
    let JobStatus::Live {
        prepared: Some(receipt),
        ..
    } = reopened.status("operator", &key).unwrap()
    else {
        panic!()
    };
    assert_eq!(receipt.digest, digest);
    assert_eq!(reopened.pool().unwrap().owner, Some(owner));
}

#[test]
fn stale_expired_stopping_and_quarantined_jobs_cannot_advance_preparation() {
    for scenario in ["stale", "deadline", "cancel", "quarantine"] {
        let (_root, journal) = fixture();
        let (request, handle) = start(&journal);
        let now = match scenario {
            "stale" => 1006,
            "deadline" => 1060,
            "cancel" => {
                journal
                    .cancel(
                        "operator",
                        &handle.ownership.attempt_id,
                        Some(&handle.ownership),
                        1000,
                    )
                    .unwrap();
                1000
            }
            "quarantine" => {
                journal.quarantine(1000).unwrap();
                1000
            }
            _ => unreachable!(),
        };
        let before = fs::read(journal.root.join(STATE)).unwrap();
        assert!(
            journal
                .record_prepared(&handle.ownership, inputs(&request), now)
                .is_err()
        );
        assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
        assert_eq!(journal.pool().unwrap().owner, Some(handle.ownership));
    }
}

#[test]
fn zero_exit_without_preparation_is_unsettled_verification_failure_not_success() {
    let (_root, journal) = fixture();
    let (_request, handle) = start(&journal);
    journal
        .client_exited(&handle, ClientExit::Success, 1000)
        .unwrap();
    let key = &handle.ownership.attempt_id;
    assert_eq!(live(&journal, key).phase(), Phase::Stopping);
    assert!(live(&journal, key).outcome().is_none());
    assert_eq!(
        journal.pool().unwrap().owner,
        Some(handle.ownership.clone())
    );
    journal
        .settle(
            key,
            Settlement::FencedEmpty {
                ownership: handle.ownership.clone(),
            },
            None,
            1001,
        )
        .unwrap();
    assert_eq!(
        live(&journal, key).outcome(),
        Some(&Outcome::Failed {
            reason: StopReason::VerificationFailed
        })
    );
}

#[test]
fn success_receipt_and_wire_snapshot_must_reference_the_persisted_preparation() {
    let (_root, journal) = fixture();
    let (request, handle) = start(&journal);
    let preparation_digest = journal
        .record_prepared(&handle.ownership, inputs(&request), 1000)
        .unwrap();
    journal
        .client_exited(&handle, ClientExit::Success, 1000)
        .unwrap();
    let key = &handle.ownership.attempt_id;
    let mut artifacts = ArtifactReceipt {
        spec_digest: request.digest().unwrap(),
        preparation_digest: "f".repeat(64),
        closure_digest: "e".repeat(64),
        roots_digest: "d".repeat(64),
    };
    assert!(
        journal
            .settle(
                key,
                Settlement::Idle {
                    handle: handle.clone()
                },
                Some(artifacts.clone()),
                1001
            )
            .is_err()
    );
    artifacts.preparation_digest = preparation_digest.clone();
    journal
        .settle(
            key,
            Settlement::Idle {
                handle: handle.clone(),
            },
            Some(artifacts),
            1001,
        )
        .unwrap();
    let snapshot = Snapshot::from(journal.status("operator", key).unwrap());
    let response = Response {
        version: protocol::VERSION,
        reply: Reply::Status {
            snapshot: Box::new(snapshot),
        },
    };
    Response::decode(&response.encode().unwrap()).unwrap();
    let mut corrupted = serde_json::to_value(&response).unwrap();
    corrupted["reply"]["snapshot"]["prepared_digest"] = "f".repeat(64).into();
    assert!(Response::decode(&serde_json::to_vec(&corrupted).unwrap()).is_err());
    journal.released(key, &"a".repeat(64), 1001).unwrap();
    journal.prune(1021).unwrap();
    let JobStatus::Retired {
        outcome: Outcome::Succeeded { artifacts },
        ..
    } = journal.status("operator", key).unwrap()
    else {
        panic!()
    };
    assert_eq!(artifacts.preparation_digest, preparation_digest);
}

#[test]
fn caller_cannot_queue_prepare_or_supply_internal_stop_evidence() {
    let (_root, journal) = fixture();
    let before = fs::read(journal.root.join(STATE)).unwrap();
    for verb in ["queue", "record_prepared", "stop"] {
        let bytes = serde_json::to_vec(
            &serde_json::json!({"version": protocol::VERSION, "command": {"kind": verb}}),
        )
        .unwrap();
        assert!(matches!(
            journal.handle("operator", &bytes, 1000).reply,
            Reply::Rejected {
                code: Rejection::InvalidRequest
            }
        ));
    }
    let request = Request {
        version: 1,
        command: WireCommand::Submit {
            request: Box::new(fleet()),
        },
    };
    assert!(matches!(
        journal
            .handle("operator", &serde_json::to_vec(&request).unwrap(), 1000)
            .reply,
        Reply::Rejected {
            code: Rejection::UnsupportedVersion
        }
    ));
    assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
}

#[test]
fn prepared_manifest_and_event_survive_process_death_as_one_commit() {
    for point in [
        "Created",
        "Written",
        "FileSynced",
        "Renamed",
        "DirectorySynced",
    ] {
        let (_root, journal) = fixture();
        let (request, handle) = start(&journal);
        let key = &handle.ownership.attempt_id;
        let count = journal.events("operator", key, None, 32).unwrap().latest;
        let output = child(&journal.root, "crash-prepare", point)
            .output()
            .unwrap();
        assert_eq!(
            output.status.code(),
            Some(77),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let reopened = Journal::open(&journal.root, identity(), policy()).unwrap();
        let committed = matches!(point, "Renamed" | "DirectorySynced");
        let JobStatus::Live { prepared, .. } = reopened.status("operator", key).unwrap() else {
            panic!()
        };
        assert_eq!(prepared.is_some(), committed);
        let page = reopened.events("operator", key, None, 32).unwrap();
        assert_eq!(page.latest, count + u64::from(committed));
        if committed {
            assert_eq!(
                page.events.last().unwrap().detail,
                EventKind::InputsPrepared {
                    digest: inputs(&request).digest().unwrap()
                }
            );
        }
        assert_eq!(reopened.pool().unwrap().owner, Some(handle.ownership));
    }
}

#[test]
fn metadata_admission_reserves_future_preparation_events_and_stop_receipts() {
    assert!(metadata_room(119, 0));
    assert!(!metadata_room(120, 0));
    assert!(!metadata_room(MAX_JOBS, 0));
    assert!(!metadata_room(MAX_JOBS, MAX_TOMBSTONES));
    assert!(!metadata_room(usize::MAX, 0));
    assert!(!metadata_room(0, usize::MAX));
    let capacity = (0..=MAX_JOBS)
        .filter(|n| metadata_room(*n, MAX_TOMBSTONES))
        .max()
        .unwrap();
    assert_eq!(capacity, 89);
    assert!(metadata_room(capacity - 1, MAX_TOMBSTONES));
    assert!(!metadata_room(capacity + 1, MAX_TOMBSTONES));
}

#[test]
fn corrupted_preparation_receipt_is_not_accepted_even_with_a_recomputed_envelope() {
    let (_root, journal) = fixture();
    let (request, handle) = start(&journal);
    journal
        .record_prepared(&handle.ownership, inputs(&request), 1000)
        .unwrap();
    let directory = journal.lock().unwrap();
    let mut state = journal.read(&directory).unwrap();
    state.jobs[0]
        .prepared
        .as_mut()
        .unwrap()
        .inputs
        .protection_digest = "f".repeat(64);
    let checksum = digest_bytes(&serde_json::to_vec(&state).unwrap());
    fs::write(
        journal.root.join(STATE),
        serde_json::to_vec(&Envelope { checksum, state }).unwrap(),
    )
    .unwrap();
    drop(directory);
    let before = fs::read(journal.root.join(STATE)).unwrap();
    assert!(Journal::open(&journal.root, identity(), policy()).is_err());
    assert_eq!(before, fs::read(journal.root.join(STATE)).unwrap());
}

#[test]
fn old_snapshot_never_resets_or_publishes() {
    let (_root, journal) = fixture();
    let (_request, _handle) = start(&journal);
    let directory = journal.lock().unwrap();
    let mut state = journal.read(&directory).unwrap();
    state.version = 2;
    let checksum = digest_bytes(&serde_json::to_vec(&state).unwrap());
    fs::write(
        journal.root.join(STATE),
        serde_json::to_vec(&Envelope { checksum, state }).unwrap(),
    )
    .unwrap();
    drop(directory);
    let before = fs::read(journal.root.join(STATE)).unwrap();
    assert!(Journal::open(&journal.root, identity(), policy()).is_err());
    assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
}

#[test]
fn prepared_size_limit_applies_to_typed_effect_calls_too() {
    let mut request = fleet();
    let mut prepared = inputs(&super::request("one"));
    prepared.targets.clear();
    for n in 0..64 {
        prepared.targets.push(PreparedTarget {
            target: BuildTarget {
                host: format!("host-{n}"),
                configuration: "a".repeat(128),
                outputs: (0..16)
                    .map(|i| format!("{i:02}{}", "x".repeat(126)))
                    .collect(),
            },
            derivation: format!("/nix/store/{}-system.drv", "0".repeat(32)),
        });
    }
    prepared.resolved = prepared
        .targets
        .iter()
        .map(
            |target| crate::build_executor::preparation::ResolvedTarget {
                host: target.target.host.clone(),
                configuration: target.target.configuration.clone(),
                disposition: crate::build_executor::preparation::Disposition::Build,
            },
        )
        .collect();
    prepared.required_hosts = vec!["host-0".into()];
    request.required_hosts = prepared.required_hosts.clone();
    prepared.attempt_id = request.attempt_id().unwrap();
    prepared.spec_digest = request.digest().unwrap();
    assert!(serde_json::to_vec(&prepared).unwrap().len() > MAX_PREPARED_BYTES);
    assert!(prepared.validate(&request).is_err());
}

#[test]
fn detached_preparation_still_obeys_the_original_runtime_deadline() {
    let (_root, journal) = fixture();
    let mut request = request("one");
    request.owner = Owner::Detached;
    let key = journal
        .submit("operator", request.clone(), 1000)
        .unwrap()
        .attempt_id;
    let owner = reserve(&journal, &key);
    journal
        .started(
            ExecutionHandle {
                ownership: owner.clone(),
                invocation_id: "worker".into(),
            },
            1000,
        )
        .unwrap();
    let error = journal
        .record_prepared(&owner, inputs(&request), 1060)
        .unwrap_err();
    assert_eq!(
        error.downcast_ref::<Rejection>(),
        Some(&Rejection::LeaseExpired)
    );
    assert_eq!(journal.pool().unwrap().owner, Some(owner));
}

#[test]
fn supervisor_stop_is_epoch_fenced_preserves_quarantine_and_waits_for_settlement() {
    let (_root, journal) = fixture();
    let (_request, handle) = start(&journal);
    let mut stale = handle.ownership.clone();
    stale.pool_epoch = NonZeroU64::new(2).unwrap();
    let before = fs::read(journal.root.join(STATE)).unwrap();
    assert!(
        journal
            .stop(&stale, StopReason::VerificationFailed, 1000)
            .is_err()
    );
    assert_eq!(before, fs::read(journal.root.join(STATE)).unwrap());
    journal.quarantine(1000).unwrap();
    journal
        .stop(&handle.ownership, StopReason::VerificationFailed, 1000)
        .unwrap();
    assert!(
        live(&journal, &handle.ownership.attempt_id)
            .outcome()
            .is_none()
    );
    assert_eq!(journal.pool().unwrap().health, PoolHealth::Quarantined);
    journal
        .settle(
            &handle.ownership.attempt_id,
            Settlement::FencedEmpty {
                ownership: handle.ownership.clone(),
            },
            None,
            1001,
        )
        .unwrap();
    assert_eq!(journal.pool().unwrap().health, PoolHealth::Quarantined);
    assert_eq!(
        live(&journal, &handle.ownership.attempt_id).outcome(),
        Some(&Outcome::Failed {
            reason: StopReason::VerificationFailed
        })
    );
}
