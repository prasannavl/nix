use super::*;

// Exercise both the old stale-capture branch and its captured >= last bypass.
const CAPTURES: [u64; 3] = [999, 1000, 1001];

fn rejected<T>(result: Result<T>, expected: Rejection) {
    let Err(error) = result else {
        panic!("expected {expected:?}");
    };
    assert_eq!(error.downcast_ref::<Rejection>(), Some(&expected));
}

#[test]
fn production_clock_ignores_captures_on_both_sides_of_last_commit() {
    let (_root, mut journal) = fixture();
    journal.clock = None;
    for captured in [0, 1000, u64::MAX] {
        let before = journal.sample_time(captured).unwrap();
        let sampled = journal.update(captured, |_, now| Ok(now)).unwrap();
        let after = journal.sample_time(captured).unwrap();
        assert!((before..=after).contains(&sampled));
        let directory = journal.lock().unwrap();
        assert_eq!(journal.read(&directory).unwrap().last_time, sampled);
    }
}

#[test]
fn stale_capture_cannot_renew_expired_owner() {
    for captured in CAPTURES {
        let (_root, mut journal) = fixture();
        let key = accepted(&journal, "expired-owner").attempt_id;
        let before = fs::read(journal.root.join(STATE)).unwrap();
        journal.clock = Some(|_| Ok(1012));
        rejected(
            journal.renew("operator", &key, None, b"synthetic-token", captured),
            Rejection::LeaseExpired,
        );
        assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
    }
}

#[test]
fn stale_capture_cannot_admit_expired_requests_or_queued_work() {
    for captured in CAPTURES {
        let (_root, mut journal) = fixture();
        let mut intent = request("expired-queue");
        intent.owner = Owner::Detached;
        let key = journal.submit("operator", intent, 1000).unwrap().attempt_id;
        journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
        journal.clock = Some(|_| Ok(1061));
        let before = fs::read(journal.root.join(STATE)).unwrap();
        rejected(
            journal.submit("operator", request("expired-submission"), captured),
            Rejection::ExpiredRequest,
        );
        assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);

        journal.clock = Some(|_| Ok(1030));
        let before = fs::read(journal.root.join(STATE)).unwrap();
        journal.queue_pending(captured).unwrap();
        assert_eq!(live(&journal, &key).phase(), Phase::Pending);
        assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
        // Even an already queued job cannot reserve after its queue deadline.
        journal.clock = Some(Ok);
        journal.queue(&key, 1000).unwrap();
        journal.clock = Some(|_| Ok(1030));
        assert!(journal.reserve_next("boot", captured).unwrap().is_none());
        assert_eq!(live(&journal, &key).phase(), Phase::Stopping);
        assert!(journal.pool().unwrap().owner.is_none());
        let directory = journal.lock().unwrap();
        let state = journal.read(&directory).unwrap();
        assert_eq!(state.last_time, 1030);
        assert_eq!(state.jobs[0].stop.as_ref().unwrap().requested_at, 1030);
    }
}

#[test]
fn stale_capture_cannot_start_or_continue_expired_build_work() {
    for captured in CAPTURES {
        for running in [false, true] {
            let (_root, mut journal) = fixture();
            let mut intent = request("expired-work");
            intent.owner = Owner::Detached;
            let key = journal
                .submit("operator", intent.clone(), 1000)
                .unwrap()
                .attempt_id;
            let owner = reserve(&journal, &key);
            let handle = ExecutionHandle {
                ownership: owner.clone(),
                invocation_id: "worker".into(),
            };
            if running {
                journal.begin_worker(handle.clone(), 1000).unwrap();
                journal.source_active(&owner, 1000).unwrap();
            } else {
                assert!(journal.work_kind(&owner, 1000).is_ok());
                assert!(journal.build_worker_input(&owner, 1000).is_ok());
            }
            journal.build_active(&owner, 1000).unwrap();
            assert_eq!(journal.daemon_owner(1000).unwrap(), owner);
            let before = fs::read(journal.root.join(STATE)).unwrap();
            journal.clock = Some(|_| Ok(1060));
            assert!(journal.build_active(&owner, captured).is_err());
            assert!(journal.daemon_owner(captured).is_err());
            if running {
                assert!(journal.source_active(&owner, captured).is_err());
                rejected(
                    journal.record_prepared(&owner, inputs(&intent), captured),
                    Rejection::LeaseExpired,
                );
            } else {
                assert!(journal.work_kind(&owner, captured).is_err());
                assert!(journal.build_worker_input(&owner, captured).is_err());
                rejected(
                    journal.begin_worker(handle, captured),
                    Rejection::LeaseExpired,
                );
            }
            assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
        }
    }
}

#[test]
fn sampled_clock_regression_rejects_newer_captures_without_mutation() {
    let (_root, mut journal) = fixture();
    let key = accepted(&journal, "clock-regression").attempt_id;
    let owner = reserve(&journal, &key);
    let before = fs::read(journal.root.join(STATE)).unwrap();
    journal.clock = Some(|_| Ok(999));
    for captured in [1000, 1001, u64::MAX] {
        rejected(
            journal.renew("operator", &key, Some(&owner), b"synthetic-token", captured),
            Rejection::ClockRegressed,
        );
        rejected(journal.expire(captured), Rejection::ClockRegressed);
        rejected(
            journal.work_kind(&owner, captured),
            Rejection::ClockRegressed,
        );
        rejected(journal.daemon_owner(captured), Rejection::ClockRegressed);
        rejected(
            journal.build_active(&owner, captured),
            Rejection::ClockRegressed,
        );
    }
    assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
}

#[test]
fn injected_clock_near_wall_time_still_rejects_regression() {
    let (_root, journal) = fixture();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    assert_eq!(journal.update(now, |_, time| Ok(time)).unwrap(), now);
    rejected(journal.expire(now - 1), Rejection::ClockRegressed);
}
