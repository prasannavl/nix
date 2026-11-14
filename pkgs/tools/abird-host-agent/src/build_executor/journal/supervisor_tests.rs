use super::*;
use crate::build_executor::launch_gate::Gate;
use crate::build_executor::supervisor::{Active, Ingress, Progress, Supervisor};
use crate::build_executor::tests::wait_ready;

#[test]
fn stop_timing_survives_reopen_replay_late_start_and_deadline_escalation() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "stop-timing").attempt_id;
    let owner = reserve(&journal, &key);
    journal.stop(&owner, StopReason::Cancelled, 1001).unwrap();
    journal
        .advance_stop(&owner, StopStage::Terminating, 1002)
        .unwrap();
    let journal = Journal::open(&journal.root, identity(), policy()).unwrap();
    journal
        .stop(&owner, StopReason::ExecutorLost, 1003)
        .unwrap();
    journal
        .advance_stop(&owner, StopStage::Terminating, 1003)
        .unwrap();
    let active = journal.supervision().unwrap().active.unwrap();
    let progress = active.stop.unwrap();
    assert_eq!(progress.requested_at, 1001);
    assert_eq!(progress.advanced_at, 1002);
    assert_eq!(progress.due(&active.deadlines, 1004), StopStage::Killing);
    assert!(
        journal
            .advance_stop(&owner, StopStage::Killing, 1003)
            .is_err()
    );
    journal
        .started(
            ExecutionHandle {
                ownership: owner.clone(),
                invocation_id: "late".into(),
            },
            1003,
        )
        .unwrap();
    journal
        .advance_stop(&owner, StopStage::Killing, 1004)
        .unwrap();
    assert!(
        journal
            .advance_stop(&owner, StopStage::Terminating, 1005)
            .is_err()
    );
    let mut stale = owner.clone();
    stale.pool_epoch = NonZeroU64::new(2).unwrap();
    assert!(
        journal
            .advance_stop(&stale, StopStage::Killing, 1005)
            .is_err()
    );
    journal.quarantine(1012).unwrap();
    journal
        .settle(
            &key,
            Settlement::FencedEmpty { ownership: owner },
            None,
            1012,
        )
        .unwrap();
    assert_eq!(journal.pool().unwrap().health, PoolHealth::Quarantined);
    assert!(matches!(
        live(&journal, &key).outcome(),
        Some(Outcome::Cancelled {
            reason: StopReason::Cancelled
        })
    ));
}

#[test]
fn expiry_and_observed_failure_share_the_same_durable_stop_clock() {
    for fail_client in [false, true] {
        let (_root, journal) = fixture();
        let key = accepted(&journal, "stop-clock").attempt_id;
        let owner = reserve(&journal, &key);
        if fail_client {
            let handle = ExecutionHandle {
                ownership: owner,
                invocation_id: "worker".into(),
            };
            journal.started(handle.clone(), 1000).unwrap();
            journal
                .client_exited(&handle, ClientExit::Failed { exit_code: 1 }, 1001)
                .unwrap();
        } else {
            journal.expire(1012).unwrap();
        }
        let first = journal.supervision().unwrap().active.unwrap().stop.unwrap();
        journal.expire(1020).unwrap();
        assert_eq!(
            journal.supervision().unwrap().active.unwrap().stop.unwrap(),
            first
        );
        assert_eq!(first.requested_at, if fail_client { 1001 } else { 1012 });
    }
}

struct Foreign;
impl Ingress for Foreign {
    fn observe_client(
        &mut self,
        _: &Active,
    ) -> Result<crate::build_executor::supervisor::ClientObservation> {
        panic!("stopping/old-boot work does not need a client probe")
    }
    fn owns_ingress(&mut self, _: &Active) -> Result<bool> {
        Ok(false)
    }
    fn request_stop(&mut self, _: &Active) -> Result<()> {
        panic!("foreign work must not be stopped")
    }
    fn quiescent(&mut self, _: &Active) -> Result<bool> {
        panic!("foreign work must not be settled")
    }
}

#[test]
fn independent_controller_fences_foreign_work_without_killing_or_blocking_metadata() {
    let (_root, journal) = fixture();
    let gate = Gate::initialize(&journal.root.join("launch"), identity()).unwrap();
    let key = accepted(&journal, "foreign").attempt_id;
    journal.queue(&key, 1000).unwrap();
    journal
        .recovered(0, gate.boot_id(), &"d".repeat(64), 1000)
        .unwrap();
    let owner = journal.reserve_next(gate.boot_id(), 1000).unwrap().unwrap();
    let control = wait_ready(|| gate.try_controller());
    assert!(gate.try_controller().unwrap().is_none());
    let mut supervisor = Supervisor::new(&journal, control).unwrap();
    journal.stop(&owner, StopReason::Cancelled, 1001).unwrap();
    assert_eq!(
        supervisor.poll(&mut Foreign, 1001).unwrap(),
        Progress::Quarantined
    );
    assert_eq!(journal.pool().unwrap().owner, Some(owner));
    assert_eq!(live(&journal, &key).phase(), Phase::Stopping);
    assert!(!journal.root.join("launch/permit.json").exists());
    drop(supervisor);
    drop(wait_ready(|| gate.try_controller()));
}

#[test]
fn new_boot_settles_old_execution_as_interrupted_but_does_not_recover_ingress() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "reboot").attempt_id;
    reserve(&journal, &key);
    let gate = Gate::initialize(&journal.root.join("launch"), identity()).unwrap();
    let mut supervisor = Supervisor::new(&journal, wait_ready(|| gate.try_controller())).unwrap();
    assert_eq!(
        supervisor.poll(&mut Foreign, 1001).unwrap(),
        Progress::Interrupted
    );
    assert_eq!(live(&journal, &key).outcome(), Some(&Outcome::Interrupted));
    assert_eq!(journal.pool().unwrap().health, PoolHealth::Quarantined);
    assert!(journal.reserve_next(gate.boot_id(), 1002).is_err());
}

#[test]
fn controller_directory_replacement_cannot_create_a_second_supervisor_lane() {
    let (_root, journal) = fixture();
    let gate = Gate::initialize(&journal.root.join("launch"), identity()).unwrap();
    let controller = wait_ready(|| gate.try_controller());
    let old = journal.root.join("launch/controller");
    fs::rename(&old, journal.root.join("launch/replaced-controller")).unwrap();
    fs::DirBuilder::new().mode(0o700).create(&old).unwrap();
    assert!(controller.validate().is_err());
    assert!(gate.try_controller().is_err());
}

#[test]
fn escalation_process_death_never_refreshes_grace_or_acknowledges_an_uncommitted_effect() {
    for point in [
        "Created",
        "Written",
        "FileSynced",
        "Renamed",
        "DirectorySynced",
    ] {
        let (_root, journal) = fixture();
        let key = accepted(&journal, "one").attempt_id;
        let owner = reserve(&journal, &key);
        journal.stop(&owner, StopReason::Cancelled, 1001).unwrap();
        let output = child(&journal.root, "crash-escalate", point)
            .output()
            .unwrap();
        assert_eq!(
            output.status.code(),
            Some(77),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(!String::from_utf8_lossy(&output.stdout).contains("EFFECT_ALLOWED"));
        let reopened = Journal::open(&journal.root, identity(), policy()).unwrap();
        let active = reopened.supervision().unwrap().active.unwrap();
        let stop = active.stop.unwrap();
        assert_eq!(stop.requested_at, 1001);
        assert_eq!(
            stop.stage,
            if matches!(point, "Renamed" | "DirectorySynced") {
                StopStage::Killing
            } else {
                StopStage::Requested
            }
        );
        assert_eq!(active.owner, owner);
        assert_eq!(live(&reopened, &key).phase(), Phase::Stopping);
    }
}

#[test]
fn unchanged_supervisor_polls_do_not_rewrite_or_refresh_durable_state() {
    let (_root, mut journal) = fixture();
    let key = accepted(&journal, "poll").attempt_id;
    let owner = reserve(&journal, &key);
    let before = fs::read(journal.root.join(STATE)).unwrap();
    journal.fault = Some(|_| bail!("no-op must not write"));
    journal.expire(1001).unwrap();
    assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
    assert!(journal.expire(999).is_err());
    journal.fault = None;
    journal.stop(&owner, StopReason::Cancelled, 1001).unwrap();
    journal
        .advance_stop(&owner, StopStage::Terminating, 1002)
        .unwrap();
    journal.quarantine(1002).unwrap();
    let before = fs::read(journal.root.join(STATE)).unwrap();
    journal.fault = Some(|_| bail!("no-op must not write"));
    journal.expire(1012).unwrap();
    journal
        .advance_stop(&owner, StopStage::Terminating, 1012)
        .unwrap();
    journal.quarantine(1012).unwrap();
    assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
    assert_eq!(
        journal
            .supervision()
            .unwrap()
            .active
            .unwrap()
            .stop
            .unwrap()
            .requested_at,
        1001
    );
}
