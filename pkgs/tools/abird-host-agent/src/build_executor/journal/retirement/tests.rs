use super::*;
use crate::build_executor::journal::tests::{fixture, request};
use crate::build_executor::{ClientExit, request::Owner};

#[path = "abandonment_tests.rs"]
mod abandonment_tests;

fn cancelled(journal: &Journal, launched: bool) -> Acceptance {
    let mut input = request("retirement-target");
    input.owner = Owner::Detached;
    let acceptance = journal.submit("operator", input, 1000).unwrap();
    if launched {
        journal.queue(&acceptance.attempt_id, 1000).unwrap();
        journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
        let owner = journal.reserve_next("boot", 1000).unwrap().unwrap();
        journal
            .cancel("operator", &acceptance.attempt_id, Some(&owner), 1000)
            .unwrap();
        journal
            .settle(
                &acceptance.attempt_id,
                Settlement::FencedEmpty { ownership: owner },
                None,
                1000,
            )
            .unwrap();
        journal.recovered(1, "boot", &"d".repeat(64), 1000).unwrap();
    } else {
        journal
            .cancel("operator", &acceptance.attempt_id, None, 1000)
            .unwrap();
        journal.settle_unlaunched(1000).unwrap();
        journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    }
    acceptance
}

fn start(journal: &Journal) -> ExecutionHandle {
    journal.schedule_retirement(1000).unwrap();
    journal.queue_pending(1000).unwrap();
    let owner = journal
        .reserve_next_kind("boot", 1000, Some(Kind::Retirement))
        .unwrap()
        .unwrap();
    let handle = ExecutionHandle {
        ownership: owner,
        invocation_id: "retirement-invocation".into(),
    };
    journal.begin_worker(handle.clone(), 1000).unwrap();
    handle
}

// Transition fixture only: no native acquisition, signature or OS proof.
fn verified(journal: &Journal) -> crate::build_executor::ConsumerAck {
    let mut request = request("consumed-retirement");
    request.owner = Owner::Detached;
    let accepted = journal.submit("operator", request.clone(), 1000).unwrap();
    journal.queue(&accepted.attempt_id, 1000).unwrap();
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    let owner = journal.reserve_next("boot", 1000).unwrap().unwrap();
    let handle = ExecutionHandle {
        ownership: owner.clone(),
        invocation_id: "worker".into(),
    };
    journal.begin_worker(handle.clone(), 1000).unwrap();
    journal.register_native_phase(&owner, 1000).unwrap();
    journal
        .bind_native_phase(
            &owner,
            native_phase::FileId {
                device: 1,
                inode: 5,
            },
            1000,
        )
        .unwrap();
    journal
        .begin_daemon(
            ExecutionHandle {
                ownership: owner.clone(),
                invocation_id: "daemon".into(),
            },
            1000,
        )
        .unwrap();
    journal
        .bind_native_runtime(
            &owner,
            serde_json::from_value(serde_json::json!({
                "unit": {"device": 1, "inode": 2}, "producer": {"device": 1, "inode": 3},
                "listener": {"device": 1, "inode": 4}, "socket": {"device": 2, "inode": 6},
                "process": {"pid": 100, "start": 200}
            }))
            .unwrap(),
            1000,
        )
        .unwrap();
    let prepared = journal
        .record_prepared(
            &owner,
            crate::build_executor::journal::tests::inputs(&request),
            1000,
        )
        .unwrap();
    journal.seal_native_phase(&owner, 1000).unwrap();
    journal.settle_native_writers(&owner, 1000).unwrap();
    journal
        .begin_artifact(&owner, &"e".repeat(64), 100, 1000)
        .unwrap();
    journal.bind_artifact(&owner, 1, 7, 1000).unwrap();
    let artifacts = ArtifactReceipt {
        spec_digest: request.digest().unwrap(),
        preparation_digest: prepared,
        closure_digest: "e".repeat(64),
        roots_digest: "f".repeat(64),
    };
    journal
        .bind_artifact_projection(
            &owner,
            super::super::artifacts::Projection {
                digest: "a".repeat(64),
                offset: 1,
                bytes: 2000,
                planning: None,
            },
            1000,
        )
        .unwrap();
    journal
        .record_verified(
            &handle,
            Outcome::Succeeded {
                artifacts: artifacts.clone(),
            },
            1000,
        )
        .unwrap();
    journal
        .client_exited(&handle, ClientExit::Success, 1000)
        .unwrap();
    crate::build_executor::ConsumerAck {
        version: 1,
        ownership: owner,
        artifacts,
        consumer: request.controller,
        store_id: "consumer-store".into(),
        acquisition_digest: "a".repeat(64),
        retention_digest: "b".repeat(64),
    }
}

#[test]
fn stale_capture_cannot_keep_expired_retirement_active() {
    for captured in [999, 1000, 1001] {
        let (_root, mut journal) = fixture();
        cancelled(&journal, false);
        let handle = start(&journal);
        journal.retirement_active(&handle.ownership, 1000).unwrap();
        let before = fs::read(journal.root.join(STATE)).unwrap();
        journal.clock = Some(|_| Ok(1060));
        assert!(
            journal
                .retirement_active(&handle.ownership, captured)
                .is_err()
        );
        assert!(
            journal
                .begin_retirement(&handle.ownership, captured)
                .is_err()
        );
        assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
    }
}

#[test]
fn consumer_ack_requires_original_verified_settlement_and_authenticated_consumer() {
    for cancel in [false, true] {
        let (_directory, journal) = fixture();
        let receipt = verified(&journal);
        assert!(
            journal
                .acknowledge_consumer("operator", receipt.clone(), 1000)
                .is_err()
        );
        if cancel {
            journal
                .cancel(
                    "operator",
                    &receipt.ownership.attempt_id,
                    Some(&receipt.ownership),
                    1000,
                )
                .unwrap();
            assert!(journal.settle_verified(&receipt.ownership, 1000).is_err());
            journal
                .settle(
                    &receipt.ownership.attempt_id,
                    Settlement::FencedEmpty {
                        ownership: receipt.ownership.clone(),
                    },
                    None,
                    1000,
                )
                .unwrap();
            assert!(
                journal
                    .acknowledge_consumer("operator", receipt, 1000)
                    .is_err()
            );
            continue;
        }
        journal.settle_verified(&receipt.ownership, 1000).unwrap();
        assert!(
            journal
                .acknowledge_consumer("other", receipt.clone(), 1000)
                .is_err()
        );
        for which in 0..3 {
            let mut changed = receipt.clone();
            match which {
                0 => changed.consumer.host_id = "other".into(),
                1 => changed.artifacts.roots_digest = "c".repeat(64),
                _ => changed.ownership.boot_id = "other-boot".into(),
            }
            assert!(
                journal
                    .acknowledge_consumer("operator", changed, 1000)
                    .is_err()
            );
        }
        journal.schedule_retirement(1000).unwrap();
        let lock = journal.lock().unwrap();
        assert_eq!(journal.read(&lock).unwrap().jobs.len(), 1);
        drop(lock);
        let digest = journal
            .acknowledge_consumer("operator", receipt.clone(), 1000)
            .unwrap();
        assert_eq!(digest, receipt.digest().unwrap());
        let lock = journal.lock().unwrap();
        let before = journal.read(&lock).unwrap();
        assert!(before.jobs[0].release_digest.is_none());
        assert!(before.jobs[0].retirement.is_none());
        drop(lock);
        assert_eq!(
            journal
                .acknowledge_consumer("operator", receipt.clone(), 1000)
                .unwrap(),
            digest
        );
        let lock = journal.lock().unwrap();
        assert_eq!(journal.read(&lock).unwrap().revision, before.revision);
        drop(lock);
        let mut changed = receipt;
        changed.retention_digest = "c".repeat(64);
        assert!(
            journal
                .acknowledge_consumer("operator", changed, 1000)
                .is_err()
        );
    }
}

#[test]
fn successful_retirement_binds_the_ack_and_rechecks_its_admitted_owner_on_release() {
    let (_directory, journal) = fixture();
    let receipt = verified(&journal);
    journal.settle_verified(&receipt.ownership, 1000).unwrap();
    journal
        .acknowledge_consumer("operator", receipt.clone(), 1000)
        .unwrap();
    journal.recovered(1, "boot", &"d".repeat(64), 1000).unwrap();
    let cleanup = start(&journal);
    let status = journal
        .maintenance_status(&cleanup.ownership.attempt_id)
        .unwrap();
    assert!(
        matches!(status.request.operation, Operation::RetireConsumed { acknowledgement, .. }
        if acknowledgement == receipt.digest().unwrap())
    );
    let target = journal.begin_retirement(&cleanup.ownership, 1000).unwrap();
    assert!(target.successful && target.artifact && target.native_phase);
    assert!(journal.daemon_owner(1000).is_err());
    assert!(
        journal
            .register_native_phase(&cleanup.ownership, 1000)
            .is_err()
    );
    assert!(
        journal
            .released(&target.attempt_id, &"c".repeat(64), 1000)
            .is_err()
    );
    journal
        .stop(&cleanup.ownership, StopReason::Cancelled, 1001)
        .unwrap();
    assert!(
        journal
            .released(&target.attempt_id, &target.evidence, 1001)
            .is_err()
    );
    let lock = journal.lock().unwrap();
    let state = journal.read(&lock).unwrap();
    let original = state
        .jobs
        .iter()
        .find(|job| job.acceptance.attempt_id == target.attempt_id)
        .unwrap();
    assert!(original.release_digest.is_none());
    assert!(
        matches!(original.outcome(), Some(Outcome::Succeeded { artifacts }) if artifacts == receipt.artifacts)
    );
}

#[test]
fn consumer_release_observation_and_lost_ack_survive_metadata_retirement() {
    let (_directory, journal) = fixture();
    let receipt = verified(&journal);
    let key = &receipt.ownership.attempt_id;
    assert!(journal.consumer_status("operator", key).unwrap().is_none());
    journal.settle_verified(&receipt.ownership, 1000).unwrap();
    let digest = journal
        .acknowledge_consumer("operator", receipt.clone(), 1000)
        .unwrap();
    let observed = journal.consumer_status("operator", key).unwrap().unwrap();
    assert_eq!(observed.receipt_digest, digest);
    assert!(observed.release_digest.is_none() && !observed.retired);
    journal.recovered(1, "boot", &"d".repeat(64), 1000).unwrap();
    let cleanup = start(&journal);
    let target = journal.begin_retirement(&cleanup.ownership, 1000).unwrap();
    // Trusted metadata adapters only; this fixture does not remove real roots.
    journal.released(key, &target.evidence, 1000).unwrap();
    let observed = journal.consumer_status("operator", key).unwrap().unwrap();
    assert_eq!(observed.release_digest, Some(target.evidence.clone()));
    assert!(!observed.retired);
    journal.retire_artifact(&receipt.ownership, 1000).unwrap();
    journal
        .retire_native_phase(&receipt.ownership, 1000)
        .unwrap();
    journal.finish_retirement(&cleanup, 1000).unwrap();
    assert!(
        !journal
            .consumer_status("operator", key)
            .unwrap()
            .unwrap()
            .retired
    );
    journal
        .client_exited(&cleanup, ClientExit::Success, 1000)
        .unwrap();
    // Even expired metadata cannot bypass the original cleanup writer's settlement.
    journal.prune(1020).unwrap();
    assert!(
        !journal
            .consumer_status("operator", key)
            .unwrap()
            .unwrap()
            .retired
    );
    assert!(journal.status("operator", key).is_ok());
    journal.settle_verified(&cleanup.ownership, 1020).unwrap();
    let observed = journal.consumer_status("operator", key).unwrap().unwrap();
    assert!(observed.retired);
    assert!(journal.status("operator", key).is_ok()); // Cleanup ≠ metadata expiry.
    journal.release_settled_maintenance(1020).unwrap();
    journal.prune(1020).unwrap();
    let observed = journal.consumer_status("operator", key).unwrap().unwrap();
    assert!(observed.retired);
    assert_eq!(observed.release_digest, Some(target.evidence));
    assert_eq!(
        journal
            .acknowledge_consumer("operator", receipt.clone(), 1020)
            .unwrap(),
        digest
    );
    assert!(journal.consumer_status("other", key).is_err());
    assert!(
        journal
            .acknowledge_consumer("other", receipt.clone(), 1020)
            .is_err()
    );
    let mut different = receipt;
    different.retention_digest = "d".repeat(64);
    assert!(
        journal
            .acknowledge_consumer("operator", different, 1020)
            .is_err()
    );
    let lock = journal.lock().unwrap();
    let mut state = journal.read(&lock).unwrap();
    let tombstone = state
        .tombstones
        .iter_mut()
        .find(|entry| entry.consumer_ack.is_some())
        .unwrap();
    tombstone.issuer = "i".repeat(128);
    tombstone.issued_at = u64::MAX;
    tombstone.acceptance.sequence = u64::MAX;
    tombstone.last_event = u64::MAX;
    assert!(serde_json::to_vec(tombstone).unwrap().len() <= TOMBSTONE_RESERVATION);
}

#[test]
fn consumer_ack_reserves_every_admitted_identifier_at_its_maximum() {
    let (_directory, journal) = fixture();
    let mut receipt = verified(&journal);
    receipt.ownership.builder_id = "b".repeat(128);
    receipt.ownership.store_id = "s".repeat(128);
    receipt.ownership.boot_id = "b".repeat(128);
    receipt.ownership.pool_epoch = std::num::NonZeroU64::new(u64::MAX).unwrap();
    receipt.consumer.host_id = "h".repeat(128);
    receipt.consumer.fabric_id = "f".repeat(128);
    receipt.store_id = "s".repeat(128);
    receipt.validate().unwrap();
    assert!(serde_json::to_vec(&receipt).unwrap().len() < artifacts::ACK_BYTES - 256);
}

#[test]
fn consumer_wire_ack_is_bound_to_the_exact_statement_not_just_the_attempt() {
    use crate::build_executor::protocol::{self, Command, Reply, Response};
    let (_directory, journal) = fixture();
    let receipt = verified(&journal);
    journal.settle_verified(&receipt.ownership, 1000).unwrap();
    let request = protocol::Request {
        version: protocol::VERSION,
        command: Command::AcknowledgeConsumer {
            receipt: Box::new(receipt.clone()),
        },
    };
    let reply = journal.handle("operator", &serde_json::to_vec(&request).unwrap(), 1000);
    reply.validate_for(&request).unwrap();
    assert!(matches!(reply.reply, Reply::ConsumerAcknowledged { .. }));
    let wrong = Response {
        version: protocol::VERSION,
        reply: Reply::ConsumerAcknowledged {
            attempt_id: receipt.ownership.attempt_id,
            receipt_digest: "d".repeat(64),
        },
    };
    assert!(wrong.validate_for(&request).is_err());
}

#[test]
fn retirement_uses_existing_queue_but_never_native_source_or_daemon_authority() {
    let (_directory, journal) = fixture();
    let original = cancelled(&journal, true);
    let policy = journal.admission_policy();
    journal
        .submit_maintenance(
            Request {
                version: crate::build_executor::maintenance::VERSION,
                id: crate::build_executor::request::RequestId {
                    issued_at: 1000,
                    nonce: "gc-ahead".into(),
                },
                storage: journal.identity().clone(),
                policy_digest: policy.digest().unwrap(),
                deadlines: policy.deadlines.clone(),
                operation: Operation::CollectGarbage,
            },
            1000,
        )
        .unwrap();
    let mut next = request("next-build");
    next.owner = Owner::Detached;
    journal.submit("operator", next, 1000).unwrap();
    // Retained GC and queued Builds cannot starve bounded retirement.
    let handle = start(&journal);
    let owner = &handle.ownership;
    let target = journal.begin_retirement(owner, 1000).unwrap();
    assert_eq!(target.attempt_id, original.attempt_id);
    assert_ne!(owner.attempt_id, target.attempt_id);
    assert!(journal.begin_retirement(owner, 1000).is_err());
    assert!(journal.daemon_owner(1000).is_err());
    assert!(journal.register_native_phase(owner, 1000).is_err());
    assert!(journal.source_active(owner, 1000).is_err());
    assert!(journal.maintenance_active(owner, 1000).is_err());
    assert!(journal.status("operator", &owner.attempt_id).is_err());
    assert!(
        journal
            .cancel("operator", &owner.attempt_id, Some(owner), 1000)
            .is_err()
    );
    assert!(!journal.retention_clear().unwrap());
}

#[test]
fn cleanup_receipt_is_not_original_success_or_descendant_settlement() {
    let (_directory, journal) = fixture();
    let original = cancelled(&journal, false);
    let before = journal.status("operator", &original.attempt_id).unwrap();
    let handle = start(&journal);
    let target = journal.begin_retirement(&handle.ownership, 1000).unwrap();
    assert!(journal.finish_retirement(&handle, 1000).is_err());
    assert!(
        journal
            .record_verified(
                &handle,
                Outcome::MaintenanceSucceeded {
                    verification_digest: "e".repeat(64)
                },
                1000
            )
            .is_err()
    );
    journal
        .released(&original.attempt_id, &target.evidence, 1000)
        .unwrap();
    journal.finish_retirement(&handle, 1000).unwrap();
    assert!(journal.finish_retirement(&handle, 1000).is_err());
    let cleanup = journal
        .maintenance_status(&handle.ownership.attempt_id)
        .unwrap();
    assert_eq!(cleanup.attempt.phase(), Phase::Running);
    assert!(cleanup.settled_at.is_none());
    // These are metadata transition fixtures, not an OS settlement observation.
    journal
        .client_exited(&handle, ClientExit::Success, 1000)
        .unwrap();
    journal.settle_verified(&handle.ownership, 1000).unwrap();
    let after = journal.status("operator", &original.attempt_id).unwrap();
    let JobStatus::Live {
        attempt: before,
        acceptance: before_acceptance,
        settled_at: before_time,
        ..
    } = before
    else {
        panic!("original should be retained")
    };
    let JobStatus::Live {
        attempt: after,
        acceptance: after_acceptance,
        settled_at: after_time,
        ..
    } = after
    else {
        panic!("original should be retained")
    };
    assert_eq!(before.outcome(), after.outcome());
    assert_eq!(before_acceptance, after_acceptance);
    assert_eq!(before_time, after_time);
}

#[test]
fn expired_undispatched_cleanup_intent_cannot_be_recreated_after_pruning() {
    let (_directory, journal) = fixture();
    cancelled(&journal, false);
    journal.schedule_retirement(1000).unwrap();
    journal.schedule_retirement(1000).unwrap();
    let count = {
        let lock = journal.lock().unwrap();
        journal.read(&lock).unwrap().jobs.len()
    };
    assert_eq!(count, 2);
    journal.expire(1030).unwrap();
    journal.settle_unlaunched(1030).unwrap();
    journal.release_settled_maintenance(1030).unwrap();
    journal.prune(1050).unwrap();
    journal.schedule_retirement(1050).unwrap();
    let lock = journal.lock().unwrap();
    let state = journal.read(&lock).unwrap();
    assert_eq!(state.jobs.len(), 1);
    assert!(state.jobs[0].retirement.is_some());
    assert!(!prunable(&state, &state.jobs[0]));
}

#[test]
fn generic_maintenance_submission_cannot_invent_a_retirement_binding() {
    let (_directory, journal) = fixture();
    let target = cancelled(&journal, false);
    let policy = journal.admission_policy();
    let intent = Request {
        version: crate::build_executor::maintenance::VERSION,
        id: crate::build_executor::request::RequestId {
            issued_at: 1000,
            nonce: "forged-cleanup".into(),
        },
        storage: journal.identity().clone(),
        policy_digest: policy.digest().unwrap(),
        deadlines: policy.deadlines.clone(),
        operation: Operation::RetireFailed {
            attempt_id: target.attempt_id.clone(),
            spec_digest: target.spec_digest.clone(),
        },
    };
    assert!(journal.submit_maintenance(intent.clone(), 1000).is_err());
    let mut abandoned = intent;
    abandoned.operation = Operation::RetireAbandoned {
        attempt_id: target.attempt_id,
        spec_digest: target.spec_digest,
        abandonment: "a".repeat(64),
    };
    assert!(journal.submit_maintenance(abandoned, 1000).is_err());
}
