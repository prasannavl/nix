use super::*;
use crate::build_executor::events::*;
use crate::build_executor::protocol::{
    self, Command as WireCommand, Reply, Request, Response, Snapshot,
};

fn call(journal: &Journal, issuer: &str, command: WireCommand, now: u64) -> Reply {
    let bytes = serde_json::to_vec(&Request {
        version: protocol::VERSION,
        command,
    })
    .unwrap();
    let response = journal.handle(issuer, &bytes, now);
    Response::decode(&response.encode().unwrap()).unwrap().reply
}
fn submit(journal: &Journal, request: BuildRequest) -> Reply {
    call(
        journal,
        "operator",
        WireCommand::Submit {
            request: Box::new(request),
        },
        1000,
    )
}
fn rejected(reply: Reply, expected: Rejection) {
    assert!(
        matches!(reply, Reply::Rejected { code } if code == expected),
        "{reply:?}"
    );
}

#[test]
fn withdrawal_before_lost_submit_fences_execution_without_claiming_settlement() {
    let (_root, journal) = fixture();
    let request = request("withdraw-first");
    let Reply::Accepted { acceptance } = call(
        &journal,
        "operator",
        WireCommand::Withdraw {
            request: Box::new(request.clone()),
        },
        1000,
    ) else {
        panic!("withdrawal must bind the intent");
    };
    assert_eq!(
        live(&journal, &acceptance.attempt_id).phase(),
        Phase::Stopping
    );
    assert!(live(&journal, &acceptance.attempt_id).outcome().is_none());
    let Reply::Accepted {
        acceptance: delayed,
    } = submit(&journal, request)
    else {
        panic!();
    };
    assert_eq!(delayed, acceptance);
    assert!(journal.queue(&acceptance.attempt_id, 1000).is_err());
    assert_eq!(journal.settle_unlaunched(1001).unwrap(), 1);
    assert!(matches!(
        live(&journal, &acceptance.attempt_id).outcome(),
        Some(Outcome::Cancelled { .. })
    ));
    let state = journal.read(&journal.lock().unwrap()).unwrap();
    assert_eq!(state.jobs.len(), 1);
    assert!(state.jobs[0].reserved_at.is_none());
    assert!(state.jobs[0].daemon_claim.is_none());
}

#[test]
fn repeated_withdrawal_preserves_original_owner_and_drain_grace() {
    let (_root, journal) = fixture();
    let intent = request("withdraw-running");
    let acceptance = journal.submit("operator", intent.clone(), 1000).unwrap();
    let owner = reserve(&journal, &acceptance.attempt_id);
    journal.withdraw("operator", intent.clone(), 1001).unwrap();
    journal.withdraw("operator", intent, 1002).unwrap();
    let state = journal.read(&journal.lock().unwrap()).unwrap();
    assert_eq!(state.pool.owner.as_ref(), Some(&owner));
    assert_eq!(state.pool.health, PoolHealth::Draining);
    assert_eq!(state.jobs[0].stop.as_ref().unwrap().requested_at, 1001);
    assert!(state.jobs[0].outcome().is_none());
    assert_eq!(state.jobs[0].phase(), Phase::Stopping);
}

#[test]
fn withdrawal_never_changes_issuer_or_conflicting_source_authority() {
    let (_root, journal) = fixture();
    let intent = request("withdraw-authority");
    let acceptance = journal.submit("operator", intent.clone(), 1000).unwrap();
    let before = fs::read(journal.root.join(STATE)).unwrap();
    rejected(
        call(
            &journal,
            "foreign",
            WireCommand::Withdraw {
                request: Box::new(intent.clone()),
            },
            1000,
        ),
        Rejection::Unauthorized,
    );
    let mut changed = intent;
    changed.source.tree_digest = Some("e".repeat(64));
    rejected(
        call(
            &journal,
            "operator",
            WireCommand::Withdraw {
                request: Box::new(changed),
            },
            1000,
        ),
        Rejection::Conflict,
    );
    assert_eq!(before, fs::read(journal.root.join(STATE)).unwrap());
    assert_eq!(
        live(&journal, &acceptance.attempt_id).phase(),
        Phase::Pending
    );
}

#[test]
fn expired_submission_can_only_be_recorded_as_withdrawn_not_started() {
    let (_root, journal) = fixture();
    let intent = request("withdraw-expired-delivery");
    let acceptance = journal.withdraw("operator", intent.clone(), 1100).unwrap();
    assert_eq!(
        live(&journal, &acceptance.attempt_id).phase(),
        Phase::Stopping
    );
    rejected(
        call(
            &journal,
            "operator",
            WireCommand::Submit {
                request: Box::new(intent.clone()),
            },
            1000,
        ),
        Rejection::ClockRegressed,
    );
    assert_eq!(
        journal.submit("operator", intent, 1101).unwrap(),
        acceptance
    );
    assert!(journal.queue(&acceptance.attempt_id, 1101).is_err());
}

#[test]
fn wire_acceptance_replay_and_conflict_preserve_one_acceptance_event() {
    let (_root, journal) = fixture();
    let request = request("wire");
    let Reply::Accepted { acceptance } = submit(&journal, request.clone()) else {
        panic!()
    };
    let Reply::Accepted { acceptance: replay } = submit(&journal, request.clone()) else {
        panic!()
    };
    assert_eq!(acceptance, replay);
    let mut changed = request;
    changed.source.tree_digest = Some("f".repeat(64));
    rejected(submit(&journal, changed), Rejection::Conflict);
    let events = journal
        .events("operator", &acceptance.attempt_id, None, MAX_EVENT_PAGE)
        .unwrap();
    assert_eq!(events.latest, 1);
    assert_eq!(events.events[0].detail, EventKind::Accepted);
    assert_eq!(
        live(&journal, &acceptance.attempt_id).phase(),
        Phase::Pending
    );
}

#[test]
fn wire_policy_identity_time_and_capacity_failures_are_typed() {
    let (_root, journal) = fixture();
    let mut changed = request("policy");
    changed.nix.cores = 3;
    rejected(submit(&journal, changed), Rejection::PolicyMismatch);
    let mut changed = request("expired");
    changed.id.issued_at = 900;
    rejected(submit(&journal, changed), Rejection::ExpiredRequest);
    let mut changed = request("issuer");
    changed.issuer = "foreign".into();
    rejected(submit(&journal, changed), Rejection::Unauthorized);
    let mut changed = request("predecessor");
    changed.predecessor = Some("f".repeat(64));
    rejected(submit(&journal, changed), Rejection::NotFound);
    let accepted = accepted(&journal, "clock");
    rejected(
        call(
            &journal,
            "operator",
            WireCommand::Cancel {
                attempt_id: accepted.attempt_id,
                expected: None,
            },
            999,
        ),
        Rejection::ClockRegressed,
    );
    journal
        .update(1000, |state, _| {
            state.revision = u64::MAX;
            Ok(())
        })
        .unwrap_err();
    // Counter exhaustion is not a serialization or transport error.
    let directory = journal.lock().unwrap();
    let mut state = journal.read(&directory).unwrap();
    state.revision = u64::MAX;
    journal.write(&directory, &state).unwrap();
    drop(directory);
    rejected(submit(&journal, request("overflow")), Rejection::Capacity);
}

#[test]
fn wire_rejects_unknown_privileged_and_oversized_messages_before_effects() {
    let (_root, journal) = fixture();
    let before = fs::read(journal.root.join(STATE)).unwrap();
    for bytes in [
        br#"{"version":3,"command":{"kind":"settle","attempt_id":"ignored"}}"#.to_vec(),
        br#"{"version":3,"command":{"kind":"recovered"}}"#.to_vec(),
        br#"{"version":3,"unknown":true,"command":{"kind":"status","attempt_id":"bad"}}"#.to_vec(),
        vec![b' '; protocol::MAX_FRAME_BYTES + 1],
    ] {
        rejected(
            journal.handle("operator", &bytes, 1000).reply,
            Rejection::InvalidRequest,
        );
    }
    let mut bytes = serde_json::to_value(Request {
        version: 1,
        command: WireCommand::Status {
            attempt_id: "f".repeat(64),
        },
    })
    .unwrap();
    rejected(
        journal
            .handle("operator", &serde_json::to_vec(&bytes).unwrap(), 1000)
            .reply,
        Rejection::UnsupportedVersion,
    );
    bytes["version"] = protocol::VERSION.into();
    bytes["command"]["extra"] = "ignored".into();
    rejected(
        journal
            .handle("operator", &serde_json::to_vec(&bytes).unwrap(), 1000)
            .reply,
        Rejection::InvalidRequest,
    );
    assert_eq!(before, fs::read(journal.root.join(STATE)).unwrap());
}

#[test]
fn every_publication_boundary_returns_unconfirmed_and_can_be_observed_safely() {
    for point in [
        CommitPoint::Created,
        CommitPoint::Written,
        CommitPoint::FileSynced,
        CommitPoint::Renamed,
        CommitPoint::DirectorySynced,
    ] {
        let (_root, mut journal) = fixture();
        // Existing fault hook is a function pointer; one function per boundary.
        journal.fault = Some(match point {
            CommitPoint::Created => |p| {
                if p == CommitPoint::Created {
                    bail!("private failure detail")
                }
                Ok(())
            },
            CommitPoint::Written => |p| {
                if p == CommitPoint::Written {
                    bail!("private failure detail")
                }
                Ok(())
            },
            CommitPoint::FileSynced => |p| {
                if p == CommitPoint::FileSynced {
                    bail!("private failure detail")
                }
                Ok(())
            },
            CommitPoint::Renamed => |p| {
                if p == CommitPoint::Renamed {
                    bail!("private failure detail")
                }
                Ok(())
            },
            CommitPoint::DirectorySynced => |p| {
                if p == CommitPoint::DirectorySynced {
                    bail!("private failure detail")
                }
                Ok(())
            },
        });
        let request = request("uncertain");
        let key = request.attempt_id().unwrap();
        let reply = submit(&journal, request.clone());
        assert!(matches!(
            reply,
            Reply::Unconfirmed {
                code: Unconfirmed::Persistence
            }
        ));
        assert!(
            !serde_json::to_string(&reply)
                .unwrap()
                .contains("private failure")
        );
        journal.fault = None;
        let persisted = journal.status("operator", &key).is_ok();
        assert_eq!(
            persisted,
            matches!(point, CommitPoint::Renamed | CommitPoint::DirectorySynced)
        );
        assert!(matches!(submit(&journal, request), Reply::Accepted { .. }));
        assert_eq!(
            journal.events("operator", &key, None, 32).unwrap().latest,
            1
        );
        assert!(journal.pool().unwrap().owner.is_none());
    }
}

#[test]
fn corrupt_missing_or_old_version_authority_is_unconfirmed_not_a_reset() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "broken").attempt_id;
    let path = journal.root.join(STATE);
    let original = fs::read(&path).unwrap();
    let mut state: Envelope = serde_json::from_slice(&original).unwrap();
    state.state.version = 1;
    state.checksum = digest_bytes(&serde_json::to_vec(&state.state).unwrap());
    for bytes in [
        b"corrupt private content".to_vec(),
        serde_json::to_vec(&state).unwrap(),
    ] {
        fs::write(&path, &bytes).unwrap();
        assert!(matches!(
            call(
                &journal,
                "operator",
                WireCommand::Status {
                    attempt_id: key.clone()
                },
                1000
            ),
            Reply::Unconfirmed {
                code: Unconfirmed::Unavailable
            }
        ));
        assert_eq!(fs::read(&path).unwrap(), bytes);
    }
    fs::remove_file(&path).unwrap();
    assert!(matches!(
        submit(&journal, request("broken")),
        Reply::Unconfirmed { .. }
    ));
    assert!(!path.exists());
}

#[test]
fn caller_cannot_read_foreign_events_or_forge_supervisor_receipts() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "private").attempt_id;
    for command in [
        WireCommand::Status {
            attempt_id: key.clone(),
        },
        WireCommand::Events {
            attempt_id: key.clone(),
            cursor: None,
            limit: 32,
        },
        WireCommand::Cancel {
            attempt_id: key.clone(),
            expected: None,
        },
    ] {
        rejected(
            call(&journal, "foreign", command, 1000),
            Rejection::NotFound,
        );
    }
    assert_eq!(
        journal.events("operator", &key, None, 32).unwrap().latest,
        1
    );
    let Reply::Logs { page } = call(
        &journal,
        "operator",
        WireCommand::Logs {
            attempt_id: key.clone(),
            cursor: None,
            limit: 4096,
        },
        1000,
    ) else {
        panic!("authenticated diagnostics missing");
    };
    assert!(!page.sealed && !page.more && !page.gap);
    assert_eq!(
        page.bytes.len(),
        crate::build_executor::events::LOG_RECORD_BYTES
    );
    let Reply::Status { snapshot } = call(
        &journal,
        "operator",
        WireCommand::Status { attempt_id: key },
        1000,
    ) else {
        panic!()
    };
    assert!(matches!(
        *snapshot,
        Snapshot::Live {
            phase: Phase::Pending,
            outcome: None,
            ..
        }
    ));
    assert!(!serde_json::to_string(&snapshot).unwrap().contains("token"));
}

#[test]
fn stop_ack_and_observed_client_exit_do_not_imply_terminal_outcome() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "stop").attempt_id;
    let owner = reserve(&journal, &key);
    let mut stale = owner.clone();
    stale.pool_epoch = NonZeroU64::new(2).unwrap();
    rejected(
        call(
            &journal,
            "operator",
            WireCommand::Cancel {
                attempt_id: key.clone(),
                expected: Some(stale),
            },
            1000,
        ),
        Rejection::StaleFence,
    );
    for _ in 0..2 {
        assert!(matches!(
            call(
                &journal,
                "operator",
                WireCommand::Cancel {
                    attempt_id: key.clone(),
                    expected: Some(owner.clone())
                },
                1000
            ),
            Reply::StopRequested { .. }
        ));
    }
    let handle = ExecutionHandle {
        ownership: owner.clone(),
        invocation_id: "invocation".into(),
    };
    journal.started(handle.clone(), 1000).unwrap();
    journal
        .client_exited(&handle, ClientExit::Failed { exit_code: 1 }, 1000)
        .unwrap();
    let Reply::Status { snapshot } = call(
        &journal,
        "operator",
        WireCommand::Status {
            attempt_id: key.clone(),
        },
        1000,
    ) else {
        panic!()
    };
    assert!(matches!(
        *snapshot,
        Snapshot::Live {
            phase: Phase::Stopping,
            outcome: None,
            ..
        }
    ));
    assert_eq!(journal.pool().unwrap().owner, Some(owner.clone()));
    journal
        .settle(
            &key,
            Settlement::FencedEmpty { ownership: owner },
            None,
            1000,
        )
        .unwrap();
    let events = journal.events("operator", &key, None, 32).unwrap();
    assert_eq!(
        events
            .events
            .iter()
            .filter(|e| matches!(e.detail, EventKind::StopRequested { .. }))
            .count(),
        1
    );
    assert_eq!(events.events.last().unwrap().detail, EventKind::Settled);
    assert!(live(&journal, &key).outcome().is_some());
    journal.quarantine(1000).unwrap();
    let Reply::Status { snapshot } = call(
        &journal,
        "operator",
        WireCommand::Status { attempt_id: key },
        1000,
    ) else {
        panic!()
    };
    assert!(matches!(
        *snapshot,
        Snapshot::Live {
            phase: Phase::Cancelled,
            pool: PoolHealth::Quarantined,
            outcome: Some(_),
            ..
        }
    ));
}

#[test]
fn renew_rejections_do_not_echo_tokens_or_extend_deadlines() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "lease").attempt_id;
    for (token, now, expected) in [
        ("private-wrong-token", 1000, Rejection::Unauthorized),
        ("synthetic-token", 1012, Rejection::LeaseExpired),
    ] {
        let reply = call(
            &journal,
            "operator",
            WireCommand::Renew {
                attempt_id: key.clone(),
                expected: None,
                token: token.into(),
            },
            now,
        );
        assert!(!serde_json::to_string(&reply).unwrap().contains(token));
        rejected(reply, expected);
    }
    assert_eq!(
        journal.events("operator", &key, None, 32).unwrap().latest,
        1
    );
}

#[test]
fn event_rotation_pagination_retirement_and_pruning_are_explicit() {
    let root = tempfile::tempdir().unwrap();
    let mut policy = policy();
    policy.deadlines.queue_seconds = 1000;
    let journal = Journal::initialize(
        &root.path().join("authority"),
        identity(),
        policy.clone(),
        1000,
    )
    .unwrap();
    let mut request = request("rotation");
    request.deadlines = policy.deadlines.clone();
    request.policy_digest = policy.digest().unwrap();
    let key = journal
        .submit("operator", request, 1000)
        .unwrap()
        .attempt_id;
    for now in 1001..=1080 {
        journal
            .renew("operator", &key, None, b"synthetic-token", now)
            .unwrap();
    }
    let before = fs::read(journal.root.join(STATE)).unwrap();
    let mut page = journal.events("operator", &key, None, 7).unwrap();
    assert_eq!(page.oldest, Some(18));
    assert_eq!(page.latest, 81);
    assert!(page.gap);
    let mut sequences = page.events.iter().map(|e| e.sequence).collect::<Vec<_>>();
    while page.more {
        page = journal
            .events("operator", &key, Some(&page.next), 7)
            .unwrap();
        assert!(!page.gap);
        sequences.extend(page.events.iter().map(|e| e.sequence));
    }
    assert_eq!(sequences, (18..=81).collect::<Vec<_>>());
    assert!(
        journal
            .events(
                "operator",
                &key,
                Some(&EventCursor {
                    attempt_id: key.clone(),
                    after: 82
                }),
                1
            )
            .is_err()
    );
    assert!(
        journal
            .events(
                "operator",
                &key,
                Some(&EventCursor {
                    attempt_id: "f".repeat(64),
                    after: 0
                }),
                1
            )
            .is_err()
    );
    assert!(journal.events("operator", &key, None, 0).is_err());
    assert!(
        journal
            .events("operator", &key, None, MAX_EVENT_PAGE + 1)
            .is_err()
    );
    assert_eq!(before, fs::read(journal.root.join(STATE)).unwrap());
    cancel_settle(&journal, &key, None, 1081);
    journal.released(&key, &"d".repeat(64), 1081).unwrap();
    let last = journal.events("operator", &key, None, 32).unwrap().latest;
    journal.prune(1101).unwrap();
    let retired = journal.events("operator", &key, None, 32).unwrap();
    assert!(retired.retired && retired.gap && retired.events.is_empty() && !retired.more);
    assert_eq!(retired.oldest, None);
    assert_eq!(retired.latest, last);
    assert!(
        !journal
            .events("operator", &key, Some(&retired.next), 32)
            .unwrap()
            .gap
    );
    journal.prune(1120).unwrap();
    rejected(
        call(
            &journal,
            "operator",
            WireCommand::Events {
                attempt_id: key,
                cursor: None,
                limit: 32,
            },
            1120,
        ),
        Rejection::NotFound,
    );
}

#[test]
fn cursor_sequence_exhaustion_and_corruption_cannot_publish_partial_transitions() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "overflow").attempt_id;
    let directory = journal.lock().unwrap();
    let mut state = journal.read(&directory).unwrap();
    let mut value = serde_json::to_value(&state.jobs[0].events).unwrap();
    // The next event must also fit the fixed-width diagnostic byte cursor.
    let maximum = u64::MAX / crate::build_executor::events::LOG_RECORD_BYTES as u64;
    value["last"] = maximum.into();
    value["entries"][0]["sequence"] = maximum.into();
    state.jobs[0].events = serde_json::from_value(value).unwrap();
    journal.write(&directory, &state).unwrap();
    drop(directory);
    let before = fs::read(journal.root.join(STATE)).unwrap();
    let error = journal.queue(&key, 1000).unwrap_err();
    assert_eq!(
        error.downcast_ref::<Rejection>(),
        Some(&Rejection::Capacity)
    );
    assert_eq!(before, fs::read(journal.root.join(STATE)).unwrap());
    assert_eq!(live(&journal, &key).phase(), Phase::Pending);
}

#[test]
fn caller_receipts_bind_exact_attempt_specification_and_operation() {
    let (_root, journal) = fixture();
    let build = request("receipt");
    let wire = Request {
        version: protocol::VERSION,
        command: WireCommand::Submit {
            request: Box::new(build.clone()),
        },
    };
    let response = journal.handle("operator", &serde_json::to_vec(&wire).unwrap(), 1000);
    response.validate_for(&wire).unwrap();
    let mut changed = build.clone();
    changed.source.tree_digest = Some("e".repeat(64));
    assert!(
        response
            .validate_for(&Request {
                version: protocol::VERSION,
                command: WireCommand::Submit {
                    request: Box::new(changed)
                },
            })
            .is_err()
    );
    let key = build.attempt_id().unwrap();
    let status = Request {
        version: protocol::VERSION,
        command: WireCommand::Status {
            attempt_id: key.clone(),
        },
    };
    assert!(response.validate_for(&status).is_err());
    let response = journal.handle("operator", &serde_json::to_vec(&status).unwrap(), 1000);
    response.validate_for(&status).unwrap();
    assert!(
        response
            .validate_for(&Request {
                version: protocol::VERSION,
                command: WireCommand::Status {
                    attempt_id: "f".repeat(64)
                },
            })
            .is_err()
    );
    let cancel = Request {
        version: protocol::VERSION,
        command: WireCommand::Cancel {
            attempt_id: key.clone(),
            expected: None,
        },
    };
    let ack = journal.handle("operator", &serde_json::to_vec(&cancel).unwrap(), 1001);
    ack.validate_for(&cancel).unwrap();
    assert!(ack.validate_for(&status).is_err());
    let renew = Request {
        version: protocol::VERSION,
        command: WireCommand::Renew {
            attempt_id: key,
            expected: None,
            token: "PRIVATE-CALLER-TOKEN".into(),
        },
    };
    let error = ack.validate_for(&renew).unwrap_err();
    assert!(!format!("{error:#}").contains("PRIVATE-CALLER-TOKEN"));
}

#[test]
fn caller_event_receipts_cannot_exceed_requested_page_or_rewind_cursor() {
    let (_root, journal) = fixture();
    let accepted = accepted(&journal, "page-receipt");
    journal.queue(&accepted.attempt_id, 1001).unwrap();
    let response = Response {
        version: protocol::VERSION,
        reply: Reply::Events {
            page: journal
                .events("operator", &accepted.attempt_id, None, MAX_EVENT_PAGE)
                .unwrap(),
        },
    };
    let request = |limit, after| Request {
        version: protocol::VERSION,
        command: WireCommand::Events {
            attempt_id: accepted.attempt_id.clone(),
            cursor: Some(EventCursor {
                attempt_id: accepted.attempt_id.clone(),
                after,
            }),
            limit,
        },
    };
    response.validate_for(&request(MAX_EVENT_PAGE, 0)).unwrap();
    assert!(response.validate_for(&request(1, 0)).is_err());
    assert!(response.validate_for(&request(MAX_EVENT_PAGE, 1)).is_err());
}

#[test]
fn response_decoding_rejects_false_terminal_status_and_malformed_cursors() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "responses").attempt_id;
    let status = Response {
        version: protocol::VERSION,
        reply: call(
            &journal,
            "operator",
            WireCommand::Status {
                attempt_id: key.clone(),
            },
            1000,
        ),
    };
    let original = serde_json::to_value(status).unwrap();
    for mutate in [
        |v: &mut serde_json::Value| v["version"] = 1.into(),
        |v: &mut serde_json::Value| v["reply"]["unknown"] = true.into(),
        |v: &mut serde_json::Value| v["reply"]["snapshot"]["phase"] = "succeeded".into(),
        |v: &mut serde_json::Value| v["reply"]["snapshot"]["renewed_at"] = 999.into(),
        |v: &mut serde_json::Value| v["reply"]["snapshot"]["acceptance"]["sequence"] = 0.into(),
        |v: &mut serde_json::Value| {
            v["reply"]["snapshot"]["acceptance"]["attempt_id"] = "bad".into()
        },
    ] {
        let mut value = original.clone();
        mutate(&mut value);
        assert!(Response::decode(&serde_json::to_vec(&value).unwrap()).is_err());
    }
    let page = journal.events("operator", &key, None, 32).unwrap();
    let original = serde_json::to_value(Response {
        version: protocol::VERSION,
        reply: Reply::Events { page },
    })
    .unwrap();
    for mutate in [
        |v: &mut serde_json::Value| v["reply"]["page"]["next"]["after"] = 2.into(),
        |v: &mut serde_json::Value| v["reply"]["page"]["more"] = true.into(),
        |v: &mut serde_json::Value| v["reply"]["page"]["retired"] = true.into(),
        |v: &mut serde_json::Value| v["reply"]["page"]["events"][0]["sequence"] = 0.into(),
    ] {
        let mut value = original.clone();
        mutate(&mut value);
        assert!(Response::decode(&serde_json::to_vec(&value).unwrap()).is_err());
    }
    let page = LogPage {
        next: LogCursor {
            attempt_id: key,
            generation: "one".into(),
            offset: (MAX_LOG_PAGE_BYTES + 1) as u64,
        },
        gap: false,
        more: false,
        sealed: false,
        bytes: vec![0; MAX_LOG_PAGE_BYTES + 1],
    };
    let response = Response {
        version: protocol::VERSION,
        reply: Reply::Logs { page },
    };
    assert!(response.encode().is_err());
    assert!(Response::decode(&serde_json::to_vec(&response).unwrap()).is_err());
    assert!(Response::decode(&vec![b' '; protocol::MAX_FRAME_BYTES + 1]).is_err());
}
