//! Metadata/transport regressions, not native root or power-loss qualification.
use super::*;
use crate::build_executor::ConsumerAbandonment;
use crate::build_executor::protocol::{self, Command, Reply, Response};

fn statement(receipt: &crate::build_executor::ConsumerAck) -> ConsumerAbandonment {
    ConsumerAbandonment {
        version: 1,
        ownership: receipt.ownership.clone(),
        artifacts: receipt.artifacts.clone(),
        consumer: receipt.consumer.clone(),
        store_id: receipt.store_id.clone(),
        acquisition_binding: "c".repeat(64),
    }
}

fn rejected<T>(result: Result<T>, expected: Rejection) {
    let Err(error) = result else {
        panic!("expected {expected:?}")
    };
    assert_eq!(error.downcast_ref::<Rejection>(), Some(&expected));
}

#[test]
fn abandonment_requires_exact_issuer_binding_and_positive_success_settlement() {
    for settlement in ["unsettled", "failed", "idle", "fenced"] {
        let (_directory, journal) = fixture();
        let receipt = verified(&journal);
        let statement = statement(&receipt);
        let key = &statement.ownership.attempt_id;
        match settlement {
            "failed" => {
                journal
                    .cancel("operator", key, Some(&receipt.ownership), 1000)
                    .unwrap();
                journal
                    .settle(
                        key,
                        Settlement::FencedEmpty {
                            ownership: receipt.ownership.clone(),
                        },
                        None,
                        1000,
                    )
                    .unwrap();
            }
            "idle" => journal
                .settle(
                    key,
                    Settlement::Idle {
                        handle: ExecutionHandle {
                            ownership: receipt.ownership.clone(),
                            invocation_id: "worker".into(),
                        },
                    },
                    Some(receipt.artifacts.clone()),
                    1000,
                )
                .unwrap(),
            "fenced" => journal.settle_verified(&receipt.ownership, 1000).unwrap(),
            _ => {}
        }
        let before = fs::read(journal.root.join(STATE)).unwrap();
        rejected(
            journal.abandon_consumer("other", statement.clone(), 1000),
            Rejection::NotFound,
        );
        if settlement != "fenced" {
            rejected(
                journal.abandon_consumer("operator", statement, 1000),
                Rejection::InvalidTransition,
            );
            assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
            continue;
        }
        for mutate in [
            |s: &mut ConsumerAbandonment| s.ownership.store_id = "another-store".into(),
            |s: &mut ConsumerAbandonment| {
                s.ownership.pool_epoch = std::num::NonZeroU64::new(2).unwrap()
            },
            |s: &mut ConsumerAbandonment| s.artifacts.spec_digest = "f".repeat(64),
            |s: &mut ConsumerAbandonment| s.consumer.host_id = "another-consumer".into(),
        ] {
            let mut wrong = statement.clone();
            mutate(&mut wrong);
            rejected(
                journal.abandon_consumer("operator", wrong, 1000),
                Rejection::InvalidTransition,
            );
        }
        assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
        // Expiry alone cannot release successful protection or invent an ACK.
        journal.prune(1100).unwrap();
        journal.schedule_retirement(1100).unwrap();
        assert!(!journal.retention_clear().unwrap());
        let lock = journal.lock().unwrap();
        assert_eq!(journal.read(&lock).unwrap().jobs.len(), 1);
        drop(lock);
        // Terminal abandonment does not renew or extend the original execution.
        journal
            .abandon_consumer("operator", statement.clone(), 1100)
            .unwrap();
        assert!(journal.consumer_status("operator", key).unwrap().is_none());
        rejected(
            journal.artifact_page("operator", key, &receipt.artifacts.closure_digest, 0),
            Rejection::InvalidTransition,
        );
        let mut different = statement;
        different.acquisition_binding = "d".repeat(64);
        rejected(
            journal.abandon_consumer("operator", different, 1100),
            Rejection::Conflict,
        );
    }
}

#[test]
fn lost_real_ack_cannot_be_converted_to_abandonment_and_reverse_order_rejects_ack() {
    for ack_first in [false, true] {
        let (_directory, journal) = fixture();
        let receipt = verified(&journal);
        journal.settle_verified(&receipt.ownership, 1000).unwrap();
        let statement = statement(&receipt);
        if ack_first {
            // Treat the successful ACK response as lost: authority still retains it.
            journal
                .acknowledge_consumer("operator", receipt.clone(), 1000)
                .unwrap();
        } else {
            journal
                .abandon_consumer("operator", statement.clone(), 1000)
                .unwrap();
        }
        let reopened = Journal::open(
            &journal.root,
            journal.identity.clone(),
            journal.policy.clone(),
        )
        .unwrap();
        let before = fs::read(journal.root.join(STATE)).unwrap();
        if ack_first {
            rejected(
                reopened.abandon_consumer("operator", statement, 1000),
                Rejection::Conflict,
            );
        } else {
            rejected(
                reopened.acknowledge_consumer("operator", receipt, 1000),
                Rejection::Conflict,
            );
        }
        assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
    }
}

#[test]
fn concurrent_ack_and_abandonment_commit_only_one_consumer_decision() {
    let (_directory, journal) = fixture();
    let receipt = verified(&journal);
    journal.settle_verified(&receipt.ownership, 1000).unwrap();
    let statement = statement(&receipt);
    let barrier = std::sync::Barrier::new(2);
    let (ack, abandoned) = std::thread::scope(|scope| {
        let ack = scope.spawn(|| {
            barrier.wait();
            journal.acknowledge_consumer("operator", receipt, 1000)
        });
        let abandoned = scope.spawn(|| {
            barrier.wait();
            journal.abandon_consumer("operator", statement, 1000)
        });
        (ack.join().unwrap(), abandoned.join().unwrap())
    });
    assert_ne!(ack.is_ok(), abandoned.is_ok());
    rejected(
        if ack.is_err() { ack } else { abandoned },
        Rejection::Conflict,
    );
    let lock = journal.lock().unwrap();
    let state = journal.read(&lock).unwrap();
    assert_ne!(
        state.jobs[0].consumer_ack.is_some(),
        state.jobs[0].consumer_abandonment.is_some()
    );
    assert!(state.jobs[0].release_digest.is_none());
}

#[test]
fn lost_abandonment_response_replays_through_cleanup_and_reclaims_builder_capacity() {
    let (_directory, mut journal) = fixture();
    let receipt = verified(&journal);
    let statement = statement(&receipt);
    let key = &statement.ownership.attempt_id;
    journal.settle_verified(&receipt.ownership, 1000).unwrap();
    journal.fault = Some(|point| {
        if point == CommitPoint::Renamed {
            bail!("lost abandonment durability response")
        }
        Ok(())
    });
    let error = journal
        .abandon_consumer("operator", statement.clone(), 1000)
        .unwrap_err();
    assert_eq!(
        error.downcast_ref::<Unconfirmed>(),
        Some(&Unconfirmed::Persistence)
    );
    let journal = Journal::open(
        &journal.root,
        journal.identity.clone(),
        journal.policy.clone(),
    )
    .unwrap();
    let before = fs::read(journal.root.join(STATE)).unwrap();
    let digest = journal
        .abandon_consumer("operator", statement.clone(), 1000)
        .unwrap();
    assert_eq!(digest, statement.digest().unwrap());
    assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
    let observed = journal
        .consumer_abandonment_status("operator", key)
        .unwrap()
        .unwrap();
    assert_eq!(observed.abandonment_digest, digest);
    assert!(observed.release_digest.is_none() && !observed.retired);
    assert!(!journal.retention_clear().unwrap());
    assert!(journal.released(key, &"e".repeat(64), 1000).is_err());
    journal.recovered(1, "boot", &"d".repeat(64), 1000).unwrap();
    let cleanup = start(&journal);
    let status = journal
        .maintenance_status(&cleanup.ownership.attempt_id)
        .unwrap();
    assert!(
        matches!(status.request.operation, Operation::RetireAbandoned { abandonment, .. } if abandonment == digest)
    );
    assert_eq!(status.request.deadlines, journal.policy.deadlines);
    let target = journal.begin_retirement(&cleanup.ownership, 1000).unwrap();
    assert!(target.successful);
    assert!(journal.daemon_owner(1000).is_err());
    rejected(
        journal.acknowledge_consumer("operator", receipt.clone(), 1000),
        Rejection::Conflict,
    );
    assert!(journal.finish_retirement(&cleanup, 1000).is_err());
    // Trusted adapter receipts only; no real roots exist in this metadata fixture.
    journal.released(key, &target.evidence, 1000).unwrap();
    journal.retire_artifact(&receipt.ownership, 1000).unwrap();
    journal
        .retire_native_phase(&receipt.ownership, 1000)
        .unwrap();
    journal.finish_retirement(&cleanup, 1000).unwrap();
    assert!(
        !journal
            .consumer_abandonment_status("operator", key)
            .unwrap()
            .unwrap()
            .retired
    );
    journal
        .client_exited(&cleanup, ClientExit::Success, 1000)
        .unwrap();
    assert!(
        !journal
            .consumer_abandonment_status("operator", key)
            .unwrap()
            .unwrap()
            .retired
    );
    journal.settle_verified(&cleanup.ownership, 1000).unwrap();
    journal.release_settled_maintenance(1000).unwrap();
    assert!(journal.retention_clear().unwrap());
    journal.prune(1019).unwrap();
    assert!(journal.status("operator", key).is_ok());
    assert!(
        journal
            .consumer_abandonment_status("operator", key)
            .unwrap()
            .unwrap()
            .retired
    );
    journal.prune(1020).unwrap();
    let observed = journal
        .consumer_abandonment_status("operator", key)
        .unwrap()
        .unwrap();
    assert!(observed.retired);
    assert_eq!(observed.release_digest, Some(target.evidence));
    assert_eq!(
        journal
            .abandon_consumer("operator", statement.clone(), 1020)
            .unwrap(),
        digest
    );
    rejected(
        journal.acknowledge_consumer("operator", receipt, 1020),
        Rejection::Conflict,
    );
    rejected(
        journal.abandon_consumer("other", statement.clone(), 1020),
        Rejection::NotFound,
    );
    let mut changed = statement.clone();
    changed.store_id = "changed-destination".into();
    rejected(
        journal.abandon_consumer("operator", changed, 1020),
        Rejection::Conflict,
    );
    assert!(journal.consumer_status("operator", key).unwrap().is_none());
    let lock = journal.lock().unwrap();
    let mut state = journal.read(&lock).unwrap();
    assert!(state.jobs.is_empty());
    let abandoned = state
        .tombstones
        .iter_mut()
        .find(|entry| entry.consumer_abandonment.is_some())
        .unwrap();
    abandoned.issuer = "i".repeat(128);
    abandoned.issued_at = u64::MAX;
    abandoned.acceptance.sequence = u64::MAX;
    abandoned.last_event = u64::MAX;
    assert!(
        state
            .tombstones
            .iter()
            .all(|entry| serde_json::to_vec(entry).unwrap().len() <= TOMBSTONE_RESERVATION)
    );
    drop(lock);
    journal.recovered(2, "boot", &"d".repeat(64), 1020).unwrap();
    let mut next = request("after-abandonment");
    next.id.issued_at = 1020;
    let next = journal.submit("operator", next, 1020).unwrap();
    journal.queue(&next.attempt_id, 1020).unwrap();
    assert_eq!(
        journal
            .reserve_next("boot", 1020)
            .unwrap()
            .unwrap()
            .attempt_id,
        next.attempt_id
    );
    // The original replay horizon remains closed; absence is not abandonment proof.
    journal.prune(1120).unwrap();
    rejected(
        journal.abandon_consumer("operator", statement, 1120),
        Rejection::NotFound,
    );
}

#[test]
fn abandonment_cleanup_preserves_retirement_fence_and_deadline() {
    for cancel in [false, true] {
        let (_directory, journal) = fixture();
        let receipt = verified(&journal);
        journal.settle_verified(&receipt.ownership, 1000).unwrap();
        journal
            .abandon_consumer("operator", statement(&receipt), 1000)
            .unwrap();
        journal.recovered(1, "boot", &"d".repeat(64), 1000).unwrap();
        let cleanup = start(&journal);
        let target = journal.begin_retirement(&cleanup.ownership, 1000).unwrap();
        assert!(
            journal
                .released(&target.attempt_id, &"d".repeat(64), 1000)
                .is_err()
        );
        if cancel {
            journal
                .stop(&cleanup.ownership, StopReason::Cancelled, 1001)
                .unwrap();
        }
        let now = if cancel { 1001 } else { 1060 };
        assert!(
            journal
                .released(&target.attempt_id, &target.evidence, now)
                .is_err()
        );
        assert!(journal.retire_artifact(&receipt.ownership, now).is_err());
        assert!(!journal.retention_clear().unwrap());
    }
}

#[test]
fn abandonment_wire_binds_exact_decision_and_keeps_ack_and_release_distinct() {
    let (_directory, journal) = fixture();
    let receipt = verified(&journal);
    journal.settle_verified(&receipt.ownership, 1000).unwrap();
    let statement = statement(&receipt);
    let key = statement.ownership.attempt_id.clone();
    let request = protocol::Request {
        version: protocol::VERSION,
        command: Command::AbandonConsumer {
            abandonment: Box::new(statement.clone()),
        },
    };
    let response = journal.handle("operator", &serde_json::to_vec(&request).unwrap(), 1000);
    response.validate_for(&request).unwrap();
    assert!(matches!(response.reply, Reply::ConsumerAbandoned { .. }));
    let wrong = Response {
        version: protocol::VERSION,
        reply: Reply::ConsumerAbandoned {
            attempt_id: key.clone(),
            abandonment_digest: "f".repeat(64),
        },
    };
    assert!(wrong.validate_for(&request).is_err());
    let ack = Response {
        version: protocol::VERSION,
        reply: Reply::ConsumerAcknowledged {
            attempt_id: key.clone(),
            receipt_digest: statement.digest().unwrap(),
        },
    };
    assert!(ack.validate_for(&request).is_err());
    let request = protocol::Request {
        version: protocol::VERSION,
        command: Command::ConsumerAbandonmentStatus { attempt_id: key },
    };
    let response = journal.handle("operator", &serde_json::to_vec(&request).unwrap(), 1000);
    response.validate_for(&request).unwrap();
    assert!(
        matches!(response.reply, Reply::ConsumerAbandonmentStatus { state: Some(state), .. }
        if state.abandonment_digest == statement.digest().unwrap() && state.release_digest.is_none() && !state.retired)
    );
}
