//! Metadata reducer tests, not service/cgroup or public workflow qualification.

use super::*;
use crate::build_executor::journal::tests::{fixture, request};

fn intent() -> Request {
    let resolved = request("ci-controller");
    Request {
        version: 1,
        executor_version: 1,
        id: resolved.id,
        run_id: "1".repeat(32),
        issuer: resolved.issuer,
        repository_id: resolved.repository_id,
        controller: resolved.builder.clone(),
        builder: resolved.builder,
        storage: resolved.storage,
        action: resolved.evaluation.action,
        invocation: serde_json::json!({"action":"build", "options":{}}),
        nix: resolved.nix,
        policy_digest: resolved.policy_digest,
        deadlines: resolved.deadlines,
        owner: resolved.owner,
        controller_service: true,
        bootstrap_digest: None,
        caller_digest: None,
    }
}

fn reserve(journal: &Journal) -> Ownership {
    let accepted = journal.submit_native("operator", intent(), 1000).unwrap();
    journal.queue_pending(1000).unwrap();
    assert!(
        matches!(journal.status("operator", &accepted.attempt_id).unwrap(), JobStatus::Live { attempt, .. } if attempt.phase() == Phase::Queued)
    );
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    journal.reserve_next("boot", 1000).unwrap().unwrap()
}

#[test]
fn ci_observer_dispatch_and_invocation_are_independently_one_shot() {
    let (_directory, journal) = fixture();
    let owner = reserve(&journal);
    let original = journal.claim_controller(&owner, 1000).unwrap().unwrap();
    assert_eq!(original.digest().unwrap(), intent().digest().unwrap());
    assert!(journal.claim_controller(&owner, 1000).is_err());
    let (_, bound, reserved) = journal
        .begin_controller(&owner.attempt_id, &"1".repeat(32), 1001)
        .unwrap();
    assert_eq!(bound, owner);
    assert_eq!(reserved, 1000);
    assert!(
        journal
            .begin_controller(&owner.attempt_id, &"1".repeat(32), 1001)
            .is_err()
    );
    assert!(
        journal
            .begin_controller(&owner.attempt_id, &"2".repeat(32), 1001)
            .is_err()
    );
    assert!(matches!(
        journal.status("operator", &owner.attempt_id).unwrap(),
        JobStatus::Live {
            request: None,
            prepared: None,
            settled_at: None,
            ..
        }
    ));
}

#[test]
fn cancelled_or_expired_controller_start_cannot_regrant_child_ownership() {
    for cancelled in [false, true] {
        let (_directory, journal) = fixture();
        let owner = reserve(&journal);
        journal.claim_controller(&owner, 1000).unwrap();
        if cancelled {
            journal.withdraw_native("operator", intent(), 1001).unwrap();
        }
        assert!(
            journal
                .begin_controller(
                    &owner.attempt_id,
                    &"1".repeat(32),
                    if cancelled { 1001 } else { 1012 }
                )
                .is_err()
        );
        assert!(
            journal
                .begin_controller(&owner.attempt_id, &"2".repeat(32), 1012)
                .is_err()
        );
    }
}

#[test]
fn a_ci_observer_is_neither_a_remote_owner_nor_a_detached_owner() {
    let mut request = intent();
    request.controller.host_id = "another-node".into();
    assert!(request.validate().is_err());
    request = intent();
    request.owner = Owner::Detached;
    assert!(request.validate().is_err());
}
