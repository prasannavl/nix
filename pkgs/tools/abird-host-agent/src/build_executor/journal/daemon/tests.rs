use super::*;
use crate::build_executor::journal::tests::{fixture, identity, inputs, policy, request};
use crate::build_executor::maintenance::{Operation, Request};
use std::sync::Arc;

fn reserved(journal: &Journal, maintenance: bool) -> ExecutionHandle {
    let build = request("daemon-claim");
    let acceptance = if maintenance {
        journal
            .submit_maintenance(
                Request {
                    version: crate::build_executor::maintenance::VERSION,
                    id: build.id,
                    storage: identity(),
                    policy_digest: policy().digest().unwrap(),
                    deadlines: policy().deadlines,
                    operation: Operation::CollectGarbage,
                },
                1000,
            )
            .unwrap()
    } else {
        journal.submit("operator", build, 1000).unwrap()
    };
    journal.queue(&acceptance.attempt_id, 1000).unwrap();
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    let ownership = journal.reserve_next("boot", 1000).unwrap().unwrap();
    start_worker_and_gate(journal, &ownership, 1000);
    ExecutionHandle {
        ownership,
        invocation_id: "native-daemon".into(),
    }
}

// Journal model only: installed gate creation/identity is a separate VM gate.
fn start_worker_and_gate(journal: &Journal, owner: &Ownership, now: u64) {
    journal
        .begin_worker(
            ExecutionHandle {
                ownership: owner.clone(),
                invocation_id: "client-worker".into(),
            },
            now,
        )
        .unwrap();
    journal.register_native_phase(owner, now).unwrap();
    journal
        .bind_native_phase(
            owner,
            super::super::native_phase::FileId {
                device: 1,
                inode: owner.pool_epoch.get() + 1,
            },
            now,
        )
        .unwrap();
}

#[test]
fn claim_is_one_shot_without_replacing_original_worker_or_extending_deadlines() {
    for maintenance in [false, true] {
        let (_root, journal) = fixture();
        let handle = reserved(&journal, maintenance);
        let kind = journal.begin_daemon(handle.clone(), 1001).unwrap();
        assert!(
            kind == if maintenance {
                work::Kind::Maintenance
            } else {
                work::Kind::Build
            }
        );
        {
            let directory = journal.lock().unwrap();
            let state = journal.read(&directory).unwrap();
            let job = &state.jobs[0];
            assert_eq!(job.reserved_at, Some(1000));
            assert_eq!(job.renewed_at, 1000);
            assert_eq!(job.phase(), Phase::Running);
            let claim = job.daemon_claim.as_ref().unwrap();
            assert_eq!(claim.handle, handle);
            assert_eq!(claim.claimed_at, 1001);
        }
        let reopened = Journal::open(&journal.root, identity(), policy()).unwrap();
        let before = fs::read(journal.root.join(STATE)).unwrap();
        assert!(reopened.begin_daemon(handle.clone(), 1002).is_err());
        let mut different = handle.clone();
        different.invocation_id = "replacement-daemon".into();
        assert!(reopened.begin_daemon(different, 1002).is_err());
        assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
        assert_eq!(journal.daemon_owner(1001).unwrap(), handle.ownership);
        assert!(!journal.retention_clear().unwrap());
        let mut worker = handle;
        worker.invocation_id = "client-worker".into();
        assert!(journal.begin_worker(worker.clone(), 1002).is_err());
        assert_eq!(
            journal.supervision().unwrap().active.unwrap().handle,
            Some(worker)
        );
    }
}

#[test]
fn claim_rejects_foreign_invalid_stale_expired_stopped_and_quarantined_without_writes() {
    for case in 0..8 {
        let (_root, journal) = fixture();
        let mut handle = reserved(&journal, false);
        let mut now = 1001;
        match case {
            0 => handle.ownership.boot_id = "other-boot".into(),
            1 => handle.invocation_id = "../PRIVATE-INVOCATION".into(),
            2 => now = 999,
            3 => now = 1006,
            4 => now = 1060,
            5 => journal
                .stop(&handle.ownership, StopReason::Cancelled, 1001)
                .unwrap(),
            6 => journal.quarantine(1001).unwrap(),
            7 => handle.ownership.attempt_id = "other-attempt".into(),
            _ => unreachable!(),
        }
        let before = fs::read(journal.root.join(STATE)).unwrap();
        let Err(error) = journal.begin_daemon(handle, now) else {
            panic!("invalid claim accepted");
        };
        assert!(!format!("{error:#}").contains("PRIVATE-INVOCATION"));
        assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
    }
}

#[test]
fn verifying_can_claim_native_daemon_but_does_not_gain_success_or_new_runtime() {
    let (_root, journal) = fixture();
    let handle = reserved(&journal, false);
    let mut worker = handle.clone();
    worker.invocation_id = "client-worker".into();
    journal
        .record_prepared(&handle.ownership, inputs(&request("daemon-claim")), 1001)
        .unwrap();
    journal
        .client_exited(&worker, ClientExit::Success, 1002)
        .unwrap();
    journal.begin_daemon(handle.clone(), 1003).unwrap();
    let active = journal.supervision().unwrap().active.unwrap();
    assert_eq!(active.phase, Phase::Verifying);
    assert_eq!(active.handle, Some(worker));
    assert!(journal.daemon_owner(1060).is_err());
    assert!(!journal.retention_clear().unwrap());
}

#[test]
fn malformed_stored_claim_is_unconfirmed_and_never_recreated() {
    for case in 0..4 {
        let (_root, journal) = fixture();
        let handle = reserved(&journal, true);
        journal.begin_daemon(handle, 1001).unwrap();
        let directory = journal.lock().unwrap();
        let mut state = journal.read(&directory).unwrap();
        let claim = state.jobs[0].daemon_claim.as_mut().unwrap();
        match case {
            0 => claim.handle.ownership.boot_id = "foreign".into(),
            1 => claim.claimed_at = 999,
            2 => claim.claimed_at = 1002,
            3 => claim.handle.invocation_id = "../PRIVATE-STORED".into(),
            _ => unreachable!(),
        }
        let bytes = serde_json::to_vec(&EnvelopeRef {
            checksum: digest_bytes(&serde_json::to_vec(&state).unwrap()),
            state: &state,
        })
        .unwrap();
        fs::write(journal.root.join(STATE), &bytes).unwrap();
        drop(directory);
        let error = Journal::open(&journal.root, identity(), policy())
            .err()
            .unwrap();
        assert!(!format!("{error:#}").contains("PRIVATE-STORED"));
        assert!(error.downcast_ref::<Rejection>().is_none());
        assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), bytes);
    }
}

#[test]
fn uncertain_publication_keeps_visible_claim_and_never_regrants_it() {
    for (visible, fault) in [
        (
            false,
            (|p| {
                ensure!(p != CommitPoint::Created, "fault");
                Ok(())
            }) as fn(CommitPoint) -> Result<()>,
        ),
        (
            false,
            (|p| {
                ensure!(p != CommitPoint::Written, "fault");
                Ok(())
            }) as fn(CommitPoint) -> Result<()>,
        ),
        (
            false,
            (|p| {
                ensure!(p != CommitPoint::FileSynced, "fault");
                Ok(())
            }) as fn(CommitPoint) -> Result<()>,
        ),
        (
            true,
            (|p| {
                ensure!(p != CommitPoint::Renamed, "fault");
                Ok(())
            }) as fn(CommitPoint) -> Result<()>,
        ),
        (
            true,
            (|p| {
                ensure!(p != CommitPoint::DirectorySynced, "fault");
                Ok(())
            }) as fn(CommitPoint) -> Result<()>,
        ),
    ] {
        let (_root, mut journal) = fixture();
        let handle = reserved(&journal, true);
        journal.fault = Some(fault);
        assert!(journal.begin_daemon(handle.clone(), 1001).is_err());
        let reopened = Journal::open(&journal.root, identity(), policy()).unwrap();
        let directory = reopened.lock().unwrap();
        let state = reopened.read(&directory).unwrap();
        assert_eq!(state.jobs[0].daemon_claim.is_some(), visible);
        drop(directory);
        if visible {
            let before = fs::read(journal.root.join(STATE)).unwrap();
            assert!(reopened.begin_daemon(handle, 1002).is_err());
            assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
        }
        // Failed publication returns before exec; invisible intent is not a
        // claim that any native process ran, and this model does not retry it.
        assert!(!reopened.retention_clear().unwrap());
    }
}

#[test]
fn concurrent_claims_admit_exactly_one_invocation() {
    let (_root, journal) = fixture();
    let handle = reserved(&journal, true);
    let journal = Arc::new(journal);
    let threads: Vec<_> = (0..2)
        .map(|i| {
            let journal = Arc::clone(&journal);
            let mut handle = handle.clone();
            handle.invocation_id = format!("daemon-{i}");
            std::thread::spawn(move || journal.begin_daemon(handle, 1001).is_ok())
        })
        .collect();
    assert_eq!(
        threads
            .into_iter()
            .filter_map(|t| t.join().unwrap().then_some(()))
            .count(),
        1
    );
}

#[test]
fn claim_retains_accountability_until_explicit_settlement_release_and_retirement() {
    let (_root, journal) = fixture();
    let handle = reserved(&journal, true);
    let key = &handle.ownership.attempt_id;
    journal.begin_daemon(handle.clone(), 1001).unwrap();
    assert!(journal.released(key, &"e".repeat(64), 1001).is_err());
    journal
        .stop(&handle.ownership, StopReason::Cancelled, 1002)
        .unwrap();
    journal
        .settle(
            key,
            Settlement::FencedEmpty {
                ownership: handle.ownership.clone(),
            },
            None,
            1003,
        )
        .unwrap();
    journal.prune(1024).unwrap();
    {
        let directory = journal.lock().unwrap();
        let state = journal.read(&directory).unwrap();
        assert_eq!(state.jobs[0].daemon_claim.as_ref().unwrap().handle, handle);
        assert!(state.jobs[0].release_digest.is_none());
    }
    assert!(!journal.retention_clear().unwrap());
    assert!(journal.begin_daemon(handle.clone(), 1024).is_err());
    journal.released(key, &"e".repeat(64), 1024).unwrap();
    journal
        .retire_native_phase(&handle.ownership, 1024)
        .unwrap();
    journal.prune(1024).unwrap();
    assert!(journal.retention_clear().unwrap());
    assert!(journal.begin_daemon(handle.clone(), 1024).is_err());
    let next = journal.submit("operator", request("next"), 1025).unwrap();
    journal.queue(&next.attempt_id, 1025).unwrap();
    journal.recovered(1, "boot", &"d".repeat(64), 1025).unwrap();
    let owner = journal.reserve_next("boot", 1025).unwrap().unwrap();
    assert_ne!(owner, handle.ownership);
    assert!(journal.begin_daemon(handle, 1025).is_err());
    start_worker_and_gate(&journal, &owner, 1025);
    journal
        .begin_daemon(
            ExecutionHandle {
                ownership: owner,
                invocation_id: "new-owner-daemon".into(),
            },
            1025,
        )
        .unwrap();
}
