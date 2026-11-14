use super::*;
use crate::build_executor::journal::tests::{fixture, identity, policy, request};
use crate::build_executor::maintenance::{self, Operation};
use crate::build_executor::request::RequestId;
use crate::build_executor::store_interlock::StoreInterlock;

fn intent(nonce: &str) -> Request {
    Request {
        version: maintenance::VERSION,
        id: RequestId {
            issued_at: 1000,
            nonce: nonce.into(),
        },
        storage: identity(),
        policy_digest: policy().digest().unwrap(),
        deadlines: policy().deadlines,
        operation: Operation::CollectGarbage,
    }
}
fn queued(journal: &Journal, nonce: &str) -> Acceptance {
    let accepted = journal.submit_maintenance(intent(nonce), 1000).unwrap();
    journal.queue(&accepted.attempt_id, 1000).unwrap();
    accepted
}
fn reserve(journal: &Journal) -> Ownership {
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    journal
        .reserve_next_kind("boot", 1000, Some(Kind::Maintenance))
        .unwrap()
        .unwrap()
}
fn handle(owner: &Ownership) -> ExecutionHandle {
    ExecutionHandle {
        ownership: owner.clone(),
        invocation_id: "invocation".into(),
    }
}

#[test]
fn stale_capture_cannot_keep_expired_maintenance_active() {
    for captured in [999, 1000, 1001] {
        let (_root, mut journal) = fixture();
        queued(&journal, "expired-maintenance");
        let owner = reserve(&journal);
        journal.maintenance_active(&owner, 1000).unwrap();
        let before = fs::read(journal.root.join(STATE)).unwrap();
        journal.clock = Some(|_| Ok(1060));
        assert!(journal.maintenance_active(&owner, captured).is_err());
        assert!(journal.daemon_owner(captured).is_err());
        assert!(journal.work_kind(&owner, captured).is_err());
        assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
    }
}

#[test]
fn intent_is_not_a_build_and_identity_policy_replay_are_immutable() {
    let (dir, journal) = fixture();
    let original = intent("one");
    let key = original.attempt_id().unwrap();
    assert_ne!(key, request("one").attempt_id().unwrap());
    let bytes = serde_json::to_vec(&original).unwrap();
    let decoded: Request = serde_json::from_slice(&bytes).unwrap();
    assert!(decoded == original);
    let value = serde_json::to_value(&original).unwrap();
    for forbidden in ["source", "targets", "argv", "store", "owner", "nix"] {
        assert!(value.get(forbidden).is_none());
        let mut extra = value.clone();
        extra[forbidden] = serde_json::json!("injected");
        assert!(serde_json::from_value::<Request>(extra).is_err());
    }
    let first = journal.submit_maintenance(original.clone(), 1000).unwrap();
    assert_eq!(
        journal.submit_maintenance(original.clone(), 1001).unwrap(),
        first
    );
    let mut changed = original.clone();
    changed.deadlines.runtime_seconds += 1;
    assert_eq!(changed.attempt_id().unwrap(), key);
    assert!(journal.submit_maintenance(changed, 1001).is_err());
    for mutate in [
        |r: &mut Request| r.policy_digest = "f".repeat(64),
        |r: &mut Request| r.storage.store_id = "other".into(),
        |r: &mut Request| r.deadlines.runtime_seconds += 1,
        |r: &mut Request| r.version += 1,
        |r: &mut Request| r.id.issued_at = 1,
        |r: &mut Request| r.id.nonce = "../bad".into(),
    ] {
        let mut bad = intent("different");
        mutate(&mut bad);
        assert!(journal.submit_maintenance(bad, 1001).is_err());
    }
    let reopened = Journal::open(&dir.path().join("authority"), identity(), policy()).unwrap();
    assert_eq!(reopened.maintenance_status(&key).unwrap().acceptance, first);
    assert!(reopened.maintenance_status(&key).unwrap().request == original);
}

#[test]
fn caller_surface_cannot_read_cancel_renew_or_submit_maintenance() {
    let (_dir, journal) = fixture();
    let accepted = queued(&journal, "one");
    let key = &accepted.attempt_id;
    for issuer in ["operator", "owned-maintenance"] {
        assert!(journal.status(issuer, key).is_err());
        assert!(journal.cancel(issuer, key, None, 1000).is_err());
        assert!(journal.renew(issuer, key, None, b"token", 1000).is_err());
        assert!(journal.events(issuer, key, None, 1).is_err());
    }
    for command in [
        serde_json::json!({"kind":"maintenance", "request": intent("wire")}),
        serde_json::json!({"kind":"submit", "request": intent("wire")}),
    ] {
        let bytes = serde_json::to_vec(&serde_json::json!({"version": super::super::super::protocol::VERSION, "command": command})).unwrap();
        assert!(crate::build_executor::protocol::Request::decode(&bytes).is_err());
    }
    journal.expire(1030).unwrap();
    journal.settle_unlaunched(1030).unwrap();
    journal.released(key, &"e".repeat(64), 1030).unwrap();
    journal.prune(1050).unwrap();
    for issuer in ["operator", "owned-maintenance"] {
        assert!(journal.status(issuer, key).is_err());
        assert!(journal.events(issuer, key, None, 1).is_err());
    }
    assert_eq!(
        journal.submit_maintenance(intent("one"), 1050).unwrap(),
        accepted
    );
}

#[test]
fn shared_queue_epoch_and_deadlines_do_not_admit_around_retained_builds() {
    let (_dir, journal) = fixture();
    let mut build = request("first");
    build.owner = Owner::Detached;
    let build = journal.submit("operator", build, 1000).unwrap();
    journal.queue(&build.attempt_id, 1000).unwrap();
    let maintenance = queued(&journal, "second");
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    assert!(
        journal
            .reserve_next_kind("boot", 1000, Some(Kind::Maintenance))
            .unwrap()
            .is_none()
    );
    let owner = journal
        .reserve_next_kind("boot", 1000, Some(Kind::Build))
        .unwrap()
        .unwrap();
    assert_eq!(owner.attempt_id, build.attempt_id);
    journal
        .cancel("operator", &build.attempt_id, Some(&owner), 1001)
        .unwrap();
    journal
        .settle(
            &build.attempt_id,
            Settlement::FencedEmpty { ownership: owner },
            None,
            1001,
        )
        .unwrap();
    journal.recovered(1, "boot", &"d".repeat(64), 1001).unwrap();
    assert!(journal.reserve_next("boot", 1001).unwrap().is_none());
    assert_eq!(journal.pool().unwrap().epoch, 1);
    journal
        .released(&build.attempt_id, &"e".repeat(64), 1002)
        .unwrap();
    let owner = journal
        .reserve_next_kind("boot", 1002, Some(Kind::Maintenance))
        .unwrap()
        .unwrap();
    assert_eq!(owner.attempt_id, maintenance.attempt_id);
    assert_eq!(owner.pool_epoch.get(), 2);
    journal.begin_worker(handle(&owner), 1002).unwrap();
    assert!(journal.begin_worker(handle(&owner), 1002).is_err());
    journal.expire(1062).unwrap();
    let snapshot = journal.supervision().unwrap().active.unwrap();
    assert_eq!(snapshot.phase, Phase::Stopping);
    assert_eq!(snapshot.stop.unwrap().requested_at, 1062);
    assert!(!journal.retention_clear().unwrap());
}

#[test]
fn maintenance_cannot_publish_build_protection_or_invent_success_from_zero_exit() {
    let (_dir, journal) = fixture();
    let accepted = queued(&journal, "one");
    let owner = reserve(&journal);
    journal.begin_worker(handle(&owner), 1000).unwrap();
    assert!(journal.source_active(&owner, 1000).is_err());
    assert!(
        journal
            .record_prepared(
                &owner,
                crate::build_executor::journal::tests::inputs(&request("one")),
                1000
            )
            .is_err()
    );
    assert!(journal.protection_context(&owner).is_err());
    journal
        .client_exited(&handle(&owner), ClientExit::Success, 1001)
        .unwrap();
    assert_eq!(
        journal
            .maintenance_status(&accepted.attempt_id)
            .unwrap()
            .attempt
            .phase(),
        Phase::Stopping
    );
    assert!(journal.maintenance_active(&owner, 1001).is_err());
    journal
        .settle(
            &accepted.attempt_id,
            Settlement::FencedEmpty { ownership: owner },
            None,
            1002,
        )
        .unwrap();
    let status = journal.maintenance_status(&accepted.attempt_id).unwrap();
    assert_eq!(
        status.attempt.outcome(),
        Some(&Outcome::Failed {
            reason: StopReason::VerificationFailed
        })
    );
    assert!(!journal.retention_clear().unwrap());
    journal
        .released(&accepted.attempt_id, &"e".repeat(64), 1002)
        .unwrap();
    assert!(journal.retention_clear().unwrap());
}

#[test]
fn worker_exclusive_lock_and_durable_reservation_are_independent_vetoes() {
    let (dir, journal) = fixture();
    let lock = dir.path().join("store");
    fs::create_dir(&lock).unwrap();
    let store = StoreInterlock::test_at(&lock, identity()).unwrap();
    queued(&journal, "one");
    let owner = reserve(&journal);
    let build_lock = store.try_admission(&journal).unwrap().unwrap();
    assert!(
        store
            .try_maintenance(&journal, &owner, 1000)
            .unwrap()
            .is_none()
    );
    drop(build_lock);
    let worker = store
        .try_maintenance(&journal, &owner, 1000)
        .unwrap()
        .unwrap();
    assert!(store.try_admission(&journal).unwrap().is_none());
    assert!(store.try_retention_check(&journal).unwrap().is_none());
    drop(worker);
    let native = File::open(&lock).unwrap();
    native.try_lock().unwrap();
    drop(native);
    let reopened = Journal::open(&dir.path().join("authority"), identity(), policy()).unwrap();
    assert!(!reopened.retention_clear().unwrap());
    assert!(store.try_retention_check(&reopened).unwrap().is_none());
    let mut foreign = owner.clone();
    foreign.boot_id = "other".into();
    assert!(store.try_maintenance(&journal, &foreign, 1000).is_err());
    assert!(store.try_maintenance(&journal, &owner, 999).is_err());
    assert!(store.try_maintenance(&journal, &owner, 1060).is_err());
    let guard = store
        .try_maintenance(&journal, &owner, 1000)
        .unwrap()
        .unwrap();
    guard.validate(&journal, 1000).unwrap();
    journal.stop(&owner, StopReason::Cancelled, 1001).unwrap();
    assert!(guard.validate(&journal, 1001).is_err());
    assert!(store.try_admission(&journal).unwrap().is_none());
    assert!(store.try_maintenance(&journal, &owner, 1001).is_err());
}

#[test]
fn old_journal_shape_is_rejected_without_reset_or_migration() {
    let (dir, journal) = fixture();
    queued(&journal, "one");
    let path = dir.path().join("authority/state.json");
    let directory = journal.lock().unwrap();
    let mut state = journal.read(&directory).unwrap();
    state.version = 7;
    let bytes = serde_json::to_vec(&EnvelopeRef {
        checksum: digest_bytes(&serde_json::to_vec(&state).unwrap()),
        state: &state,
    })
    .unwrap();
    fs::write(&path, bytes).unwrap();
    drop(directory);
    let before = fs::read(&path).unwrap();
    let error = Journal::open(&dir.path().join("authority"), identity(), policy())
        .err()
        .unwrap();
    assert!(
        error
            .to_string()
            .contains("journal version/storage/policy mismatch")
    );
    assert_eq!(fs::read(&path).unwrap(), before);
}

#[test]
fn stored_work_authority_failure_is_unconfirmed_not_a_caller_rejection() {
    use crate::build_executor::protocol::{Command, Reply, Request as WireRequest, Unconfirmed};
    let (dir, journal) = fixture();
    let accepted = journal.submit("operator", request("build"), 1000).unwrap();
    let directory = journal.lock().unwrap();
    let mut state = journal.read(&directory).unwrap();
    let Work::Build(build) = &mut state.jobs[0].request else {
        panic!()
    };
    build.policy_digest = "f".repeat(64);
    let bytes = serde_json::to_vec(&EnvelopeRef {
        checksum: digest_bytes(&serde_json::to_vec(&state).unwrap()),
        state: &state,
    })
    .unwrap();
    let path = dir.path().join("authority/state.json");
    fs::write(&path, &bytes).unwrap();
    drop(directory);
    let wire = serde_json::to_vec(&WireRequest {
        version: crate::build_executor::protocol::VERSION,
        command: Command::Status {
            attempt_id: accepted.attempt_id,
        },
    })
    .unwrap();
    assert!(matches!(
        journal.handle("operator", &wire, 1000).reply,
        Reply::Unconfirmed {
            code: Unconfirmed::Unavailable
        }
    ));
    assert_eq!(fs::read(path).unwrap(), bytes);
}
