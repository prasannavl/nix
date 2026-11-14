use super::*;
use crate::build_executor::journal::tests::{fixture, request};
use crate::build_executor::native_phase::Runtime;

// Synthetic journal bindings only; kernel/installed acceptance remains separate.
fn runtime() -> Runtime {
    serde_json::from_value(serde_json::json!({
        "unit": {"device": 1, "inode": 2},
        "producer": {"device": 1, "inode": 3},
        "listener": {"device": 1, "inode": 4},
        "socket": {"device": 2, "inode": 6},
        "process": {"pid": 100, "start": 200}
    }))
    .unwrap()
}

fn running(journal: &Journal) -> Ownership {
    let accepted = journal
        .submit("operator", request("upstream-native-phase"), 1000)
        .unwrap();
    journal.queue(&accepted.attempt_id, 1000).unwrap();
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    let owner = journal.reserve_next("boot", 1000).unwrap().unwrap();
    journal
        .begin_worker(
            ExecutionHandle {
                ownership: owner.clone(),
                invocation_id: "worker".into(),
            },
            1000,
        )
        .unwrap();
    journal.register_native_phase(&owner, 1000).unwrap();
    journal
        .bind_native_phase(
            &owner,
            FileId {
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
    owner
}

#[test]
fn runtime_binding_and_writer_settlement_are_distinct_one_shot_transitions() {
    let (_root, journal) = fixture();
    let owner = running(&journal);
    assert!(journal.settle_native_writers(&owner, 1000).is_err());
    journal
        .bind_native_runtime(&owner, runtime(), 1000)
        .unwrap();
    assert!(
        journal
            .bind_native_runtime(&owner, runtime(), 1000)
            .is_err()
    );
    assert!(journal.settle_native_writers(&owner, 1000).is_err());
    journal.seal_native_phase(&owner, 1000).unwrap();
    assert!(
        journal
            .native_phase(&owner)
            .unwrap()
            .writers_settled_at
            .is_none()
    );
    journal.settle_native_writers(&owner, 1001).unwrap();
    assert_eq!(
        journal.native_phase(&owner).unwrap().writers_settled_at,
        Some(1001)
    );
    assert!(journal.settle_native_writers(&owner, 1001).is_err());
    let state = journal.supervision().unwrap().active.unwrap();
    assert_eq!(state.phase, Phase::Running);
    assert!(!journal.retention_clear().unwrap());
}

#[test]
fn cancellation_or_expiry_cannot_publish_late_native_writer_settlement() {
    for cancel in [true, false] {
        let (_root, journal) = fixture();
        let owner = running(&journal);
        journal
            .bind_native_runtime(&owner, runtime(), 1000)
            .unwrap();
        journal.seal_native_phase(&owner, 1000).unwrap();
        let now = if cancel {
            journal.stop(&owner, StopReason::Cancelled, 1001).unwrap();
            1001
        } else {
            1060
        };
        assert!(journal.settle_native_writers(&owner, now).is_err());
        assert!(
            journal
                .native_phase(&owner)
                .unwrap()
                .writers_settled_at
                .is_none()
        );
        assert!(!journal.retention_clear().unwrap());
    }
}

#[test]
fn invalid_native_runtime_cannot_replace_or_complete_an_unbound_claim() {
    let (_root, journal) = fixture();
    let owner = running(&journal);
    let mut value = serde_json::to_value(runtime()).unwrap();
    value["listener"] = value["producer"].clone();
    let invalid = serde_json::from_value(value).unwrap();
    assert!(journal.bind_native_runtime(&owner, invalid, 1000).is_err());
    assert!(journal.native_phase(&owner).unwrap().runtime.is_none());
    journal.seal_native_phase(&owner, 1000).unwrap();
    assert!(
        journal
            .bind_native_runtime(&owner, runtime(), 1000)
            .is_err()
    );
    assert!(journal.settle_native_writers(&owner, 1000).is_err());
}

#[test]
fn native_retirement_receipt_requires_the_still_active_separate_cleanup_owner() {
    // Journal transitions only; no assertion about real filesystem removal.
    for interruption in [
        None,
        Some(StopReason::Cancelled),
        Some(StopReason::DeadlineExpired),
    ] {
        let (_root, journal) = fixture();
        let original = running(&journal);
        journal
            .stop(&original, StopReason::Cancelled, 1001)
            .unwrap();
        journal
            .settle(
                &original.attempt_id,
                Settlement::FencedEmpty {
                    ownership: original.clone(),
                },
                None,
                1001,
            )
            .unwrap();
        assert!(journal.retire_native_phase(&original, 1001).is_err());
        journal
            .recovered(original.pool_epoch.get(), "boot", &"d".repeat(64), 1001)
            .unwrap();
        journal.schedule_retirement(1001).unwrap();
        journal.queue_pending(1001).unwrap();
        let cleanup = journal
            .reserve_next_kind("boot", 1001, Some(Kind::Retirement))
            .unwrap()
            .unwrap();
        journal
            .begin_worker(
                ExecutionHandle {
                    ownership: cleanup.clone(),
                    invocation_id: "cleanup".into(),
                },
                1001,
            )
            .unwrap();
        let target = journal.begin_retirement(&cleanup, 1001).unwrap();
        journal
            .released(&original.attempt_id, &target.evidence, 1001)
            .unwrap();
        let now = match interruption {
            Some(StopReason::Cancelled) => {
                journal.stop(&cleanup, StopReason::Cancelled, 1002).unwrap();
                1002
            }
            Some(_) => 1061,
            None => 1002,
        };
        let result = journal.retire_native_phase(&original, now);
        assert_eq!(result.is_ok(), interruption.is_none());
        assert_eq!(
            journal.native_phase(&original).unwrap().retired,
            interruption.is_none()
        );
        assert!(!journal.retention_clear().unwrap());
    }
}
