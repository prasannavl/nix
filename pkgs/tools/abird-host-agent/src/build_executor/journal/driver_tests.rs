use super::*;
use crate::build_executor::launch_gate::{Fence, Gate, Permission, Permit};
use crate::build_executor::supervisor::{
    Active, ClientObservation, Ingress, Launcher, Progress, Supervisor,
};

pub(super) struct Dispatch<'a> {
    pub journal: &'a Journal,
    pub calls: usize,
    pub ready: bool,
    pub uncertain: bool,
    pub crash: &'a str,
}
impl Launcher for Dispatch<'_> {
    fn ready(&mut self, _: &Fence<'_>, pool: &Pool) -> Result<bool> {
        assert!(pool.owner.is_none());
        assert!(!self.journal.root.join("launch/permit.json").exists());
        Ok(self.ready)
    }
    fn start_once(&mut self, owner: &Ownership) -> Result<()> {
        assert_eq!(self.journal.pool()?.owner.as_ref(), Some(owner));
        assert_eq!(
            self.journal
                .supervision()?
                .active
                .context("missing dispatch owner")?
                .phase,
            Phase::Starting
        );
        let permit: Permit =
            serde_json::from_slice(&fs::read(self.journal.root.join("launch/permit.json"))?)?;
        assert_eq!(
            permit.permission,
            Permission::Execution {
                ownership: owner.clone()
            }
        );
        if self.crash == "before" {
            std::process::exit(78);
        }
        self.calls += 1;
        println!("DISPATCH_EFFECT");
        if self.crash == "after" {
            std::process::exit(79);
        }
        ensure!(!self.uncertain, "delivery acknowledgement lost");
        Ok(())
    }
}
fn ready(journal: &Journal) -> (Gate, String) {
    ready_kind(journal, false)
}
fn ready_kind(journal: &Journal, maintenance: bool) -> (Gate, String) {
    fs::create_dir(journal.root.join("test-store")).unwrap();
    let gate = Gate::initialize(&journal.root.join("launch"), identity()).unwrap();
    let key = if maintenance {
        journal
            .submit_maintenance(
                crate::build_executor::maintenance::Request {
                    version: 1,
                    id: RequestId {
                        issued_at: 1000,
                        nonce: "one".into(),
                    },
                    storage: identity(),
                    policy_digest: policy().digest().unwrap(),
                    deadlines: policy().deadlines,
                    operation: crate::build_executor::maintenance::Operation::CollectGarbage,
                },
                1000,
            )
            .unwrap()
            .attempt_id
    } else {
        accepted(journal, "one").attempt_id
    };
    journal.queue(&key, 1000).unwrap();
    journal
        .recovered(0, gate.boot_id(), &"d".repeat(64), 1000)
        .unwrap();
    (gate, key)
}
pub(super) fn store(journal: &Journal) -> crate::build_executor::store_interlock::StoreInterlock {
    crate::build_executor::store_interlock::StoreInterlock::test_at(
        &journal.root.join("test-store"),
        identity(),
    )
    .unwrap()
}
fn dispatch(journal: &Journal) -> Dispatch<'_> {
    Dispatch {
        journal,
        calls: 0,
        ready: true,
        uncertain: false,
        crash: "",
    }
}

#[test]
fn one_reservation_allows_one_dispatch_not_one_per_reconnect_or_restart() {
    for uncertain in [false, true] {
        let (_root, journal) = fixture();
        let (gate, key) = ready(&journal);
        let mut delivery = dispatch(&journal);
        delivery.uncertain = uncertain;
        let mut supervisor = Supervisor::new(
            &journal,
            crate::build_executor::tests::wait_ready(|| gate.try_controller()),
        )
        .unwrap();
        assert_eq!(
            supervisor
                .launch_next(&store(&journal), &mut delivery, 1000)
                .is_err(),
            uncertain
        );
        assert_eq!(delivery.calls, 1);
        assert_eq!(live(&journal, &key).phase(), Phase::Starting);
        assert!(
            supervisor
                .launch_next(&store(&journal), &mut delivery, 1000)
                .unwrap()
                .is_none()
        );
        drop(supervisor);
        let mut supervisor = Supervisor::new(
            &journal,
            crate::build_executor::tests::wait_ready(|| gate.try_controller()),
        )
        .unwrap();
        assert!(
            supervisor
                .launch_next(&store(&journal), &mut delivery, 1001)
                .unwrap()
                .is_none()
        );
        assert_eq!(delivery.calls, 1);
        assert_eq!(journal.pool().unwrap().epoch, 1);
    }
}

#[test]
fn exclusive_retention_check_defers_dispatch_before_reservation_or_launch_fencing() {
    let (_root, journal) = fixture();
    let (gate, key) = ready(&journal);
    let store = store(&journal);
    let permission = Permit {
        version: 1,
        identity: identity(),
        permission: Permission::Recovery {
            epoch: 0,
            boot_id: gate.boot_id().to_owned(),
        },
    };
    gate.try_fence()
        .unwrap()
        .unwrap()
        .publish(&permission)
        .unwrap();
    let original = fs::read(journal.root.join("launch/permit.json")).unwrap();
    let checked = store.try_retention_check(&journal).unwrap().unwrap();
    let mut delivery = dispatch(&journal);
    let mut supervisor = Supervisor::new(
        &journal,
        crate::build_executor::tests::wait_ready(|| gate.try_controller()),
    )
    .unwrap();
    assert!(
        supervisor
            .launch_next(&store, &mut delivery, 1000)
            .unwrap()
            .is_none()
    );
    assert_eq!(delivery.calls, 0);
    assert_eq!(journal.pool().unwrap().epoch, 0);
    assert_eq!(live(&journal, &key).phase(), Phase::Queued);
    assert_eq!(
        fs::read(journal.root.join("launch/permit.json")).unwrap(),
        original
    );
    drop(checked);
    assert!(
        supervisor
            .launch_next(&store, &mut delivery, 1000)
            .unwrap()
            .is_some()
    );
    assert_eq!(delivery.calls, 1);
    assert!(store.try_retention_check(&journal).unwrap().is_none());
}

#[test]
fn unqualified_launch_quarantines_without_reservation_or_effect() {
    let (_root, journal) = fixture();
    let (gate, _) = ready(&journal);
    let mut delivery = dispatch(&journal);
    delivery.ready = false;
    let mut supervisor = Supervisor::new(
        &journal,
        crate::build_executor::tests::wait_ready(|| gate.try_controller()),
    )
    .unwrap();
    assert!(
        supervisor
            .launch_next(&store(&journal), &mut delivery, 1000)
            .is_err()
    );
    assert_eq!(delivery.calls, 0);
    assert_eq!(journal.pool().unwrap().epoch, 0);
    assert_eq!(journal.pool().unwrap().health, PoolHealth::Quarantined);
    assert!(!journal.root.join("launch/permit.json").exists());
}

#[test]
fn dispatch_crashes_before_receipt_and_around_delivery_never_replay_reserved_work() {
    for maintenance in [false, true] {
        for (operation, point, exit) in [
            ("crash-dispatch", "Created", 77),
            ("crash-dispatch", "Written", 77),
            ("crash-dispatch", "FileSynced", 77),
            ("crash-dispatch", "Renamed", 77),
            ("crash-dispatch", "DirectorySynced", 77),
            ("dispatch-before", "", 78),
            ("dispatch-after", "", 79),
        ] {
            let (_root, journal) = fixture();
            let (gate, _) = ready_kind(&journal, maintenance);
            let output = child(&journal.root, operation, point).output().unwrap();
            assert_eq!(
                output.status.code(),
                Some(exit),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            assert_eq!(
                String::from_utf8_lossy(&output.stdout).contains("DISPATCH_EFFECT"),
                exit == 79
            );
            let committed = matches!(point, "Renamed" | "DirectorySynced") || exit != 77;
            let reopened = Journal::open(&journal.root, identity(), policy()).unwrap();
            assert_eq!(reopened.pool().unwrap().owner.is_some(), committed);
            let native_lock = File::open(journal.root.join("test-store")).unwrap();
            native_lock.try_lock().unwrap();
            drop(native_lock);
            assert_eq!(
                store(&journal)
                    .try_retention_check(&reopened)
                    .unwrap()
                    .is_none(),
                committed
            );
            let mut delivery = dispatch(&reopened);
            let mut supervisor = Supervisor::new(
                &reopened,
                crate::build_executor::tests::wait_ready(|| gate.try_controller()),
            )
            .unwrap();
            assert_eq!(
                supervisor
                    .launch_next(&store(&journal), &mut delivery, 1000)
                    .unwrap()
                    .is_some(),
                !committed
            );
            assert_eq!(delivery.calls, usize::from(!committed));
            assert_eq!(reopened.pool().unwrap().epoch, 1);
        }
    }
}

#[test]
fn wrapper_exec_grant_is_single_use_and_rejects_stale_stopped_or_expired_work() {
    for case in [
        "duplicate",
        "invocation",
        "epoch",
        "boot",
        "attempt",
        "cancelled",
        "quarantined",
        "stale",
        "runtime",
    ] {
        let (_root, journal) = fixture();
        let mut request = request("one");
        if case == "runtime" {
            request.owner = Owner::Detached;
        }
        let key = journal
            .submit("operator", request, 1000)
            .unwrap()
            .attempt_id;
        let owner = reserve(&journal, &key);
        let mut handle = ExecutionHandle {
            ownership: owner.clone(),
            invocation_id: "a".repeat(32),
        };
        match case {
            "duplicate" | "invocation" => {
                journal.begin_worker(handle.clone(), 1000).unwrap();
                if case == "invocation" {
                    handle.invocation_id = "b".repeat(32);
                }
            }
            "epoch" => handle.ownership.pool_epoch = NonZeroU64::new(2).unwrap(),
            "boot" => handle.ownership.boot_id = "other".into(),
            "attempt" => handle.ownership.attempt_id = "b".repeat(64),
            "cancelled" => journal.stop(&owner, StopReason::Cancelled, 1000).unwrap(),
            "quarantined" => journal.quarantine(1000).unwrap(),
            _ => {}
        }
        let now = match case {
            "stale" => 1006,
            "runtime" => 1060,
            _ => 1000,
        };
        assert!(journal.begin_worker(handle, now).is_err(), "{case}");
    }
}

#[test]
fn only_never_reserved_stops_can_settle_without_execution_evidence() {
    let (_root, journal) = fixture();
    let active = accepted(&journal, "active").attempt_id;
    let owner = reserve(&journal, &active);
    journal.stop(&owner, StopReason::Cancelled, 1000).unwrap();
    journal.quarantine(1000).unwrap();
    for nonce in ["pending", "queued"] {
        let key = accepted(&journal, nonce).attempt_id;
        if nonce == "queued" {
            journal.queue(&key, 1000).unwrap();
        }
        journal.cancel("operator", &key, None, 1000).unwrap();
    }
    assert_eq!(journal.settle_unlaunched(1001).unwrap(), 2);
    assert_eq!(live(&journal, &active).phase(), Phase::Stopping);
    assert_eq!(journal.pool().unwrap().owner, Some(owner));
    assert_eq!(journal.pool().unwrap().health, PoolHealth::Quarantined);
    let before = fs::read(journal.root.join(STATE)).unwrap();
    assert_eq!(journal.settle_unlaunched(1001).unwrap(), 0);
    assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
}

struct Observe<'a> {
    journal: &'a Journal,
    observation: Option<ClientObservation>,
    racing_start: Option<ExecutionHandle>,
}
impl Ingress for Observe<'_> {
    fn observe_client(&mut self, _: &Active) -> Result<ClientObservation> {
        if let Some(handle) = self.racing_start.take() {
            self.journal.begin_worker(handle, 1000)?;
        }
        self.observation.clone().context("observation unavailable")
    }
    fn owns_ingress(&mut self, _: &Active) -> Result<bool> {
        Ok(false)
    }
    fn request_stop(&mut self, _: &Active) -> Result<()> {
        panic!("no qualified stop authority")
    }
    fn quiescent(&mut self, _: &Active) -> Result<bool> {
        panic!("no qualified settlement authority")
    }
}

#[test]
fn independent_exit_observation_requires_preparation_and_never_invents_settlement() {
    for prepared in [false, true] {
        let (_root, journal) = fixture();
        let (gate, key) = ready(&journal);
        let owner = journal.reserve_next(gate.boot_id(), 1000).unwrap().unwrap();
        let handle = ExecutionHandle {
            ownership: owner,
            invocation_id: "a".repeat(32),
        };
        journal.begin_worker(handle.clone(), 1000).unwrap();
        if prepared {
            journal
                .record_prepared(&handle.ownership, inputs(&request("one")), 1000)
                .unwrap();
        }
        let mut observe = Observe {
            journal: &journal,
            observation: Some(ClientObservation::Exited {
                handle,
                exit: ClientExit::Success,
            }),
            racing_start: None,
        };
        let mut supervisor = Supervisor::new(
            &journal,
            crate::build_executor::tests::wait_ready(|| gate.try_controller()),
        )
        .unwrap();
        assert_eq!(
            supervisor.poll(&mut observe, 1001).unwrap(),
            if prepared {
                Progress::Verifying
            } else {
                Progress::Quarantined
            }
        );
        let attempt = live(&journal, &key);
        assert!(attempt.outcome().is_none());
        assert_eq!(
            attempt.phase(),
            if prepared {
                Phase::Verifying
            } else {
                Phase::Stopping
            }
        );
        if !prepared {
            assert!(matches!(
                attempt.0.state,
                crate::build_executor::State::Stopping {
                    reason: StopReason::VerificationFailed,
                    ..
                }
            ));
        }
    }
}

#[test]
fn unavailable_foreign_and_lost_observations_are_not_compiler_failures() {
    for observation in [
        None,
        Some(ClientObservation::Foreign),
        Some(ClientObservation::Lost),
    ] {
        let (_root, journal) = fixture();
        let (gate, key) = ready(&journal);
        let owner = journal.reserve_next(gate.boot_id(), 1000).unwrap().unwrap();
        journal
            .begin_worker(
                ExecutionHandle {
                    ownership: owner,
                    invocation_id: "a".repeat(32),
                },
                1000,
            )
            .unwrap();
        let mut observe = Observe {
            journal: &journal,
            observation: observation.clone(),
            racing_start: None,
        };
        let mut supervisor = Supervisor::new(
            &journal,
            crate::build_executor::tests::wait_ready(|| gate.try_controller()),
        )
        .unwrap();
        assert_eq!(
            supervisor.poll(&mut observe, 1001).is_err(),
            observation.is_none()
        );
        let attempt = live(&journal, &key);
        assert!(attempt.outcome().is_none());
        if observation.is_none() {
            assert_eq!(attempt.phase(), Phase::Running);
        } else {
            assert!(matches!(
                attempt.0.state,
                crate::build_executor::State::Stopping {
                    reason: StopReason::ExecutorLost,
                    ..
                }
            ));
        }
    }
}

#[test]
fn fast_client_exit_racing_start_publication_is_reobserved_with_the_durable_handle() {
    let (_root, journal) = fixture();
    let (gate, key) = ready(&journal);
    let owner = journal.reserve_next(gate.boot_id(), 1000).unwrap().unwrap();
    let mut observe = Observe {
        journal: &journal,
        observation: Some(ClientObservation::Lost),
        racing_start: Some(ExecutionHandle {
            ownership: owner,
            invocation_id: "a".repeat(32),
        }),
    };
    let mut supervisor = Supervisor::new(
        &journal,
        crate::build_executor::tests::wait_ready(|| gate.try_controller()),
    )
    .unwrap();
    assert_eq!(
        supervisor.poll(&mut observe, 1000).unwrap(),
        Progress::Observing
    );
    assert_eq!(live(&journal, &key).phase(), Phase::Running);
}

#[test]
fn queued_expiry_is_reconciled_without_probing_or_claiming_an_executor() {
    let (_root, journal) = fixture();
    let (gate, key) = ready(&journal);
    let mut observe = Observe {
        journal: &journal,
        observation: None,
        racing_start: None,
    };
    let mut supervisor = Supervisor::new(
        &journal,
        crate::build_executor::tests::wait_ready(|| gate.try_controller()),
    )
    .unwrap();
    assert_eq!(supervisor.poll(&mut observe, 1012).unwrap(), Progress::Idle);
    assert!(matches!(
        live(&journal, &key).outcome(),
        Some(Outcome::Cancelled {
            reason: StopReason::OwnerExpired
        })
    ));
    assert_eq!(journal.pool().unwrap().epoch, 0);
}

#[test]
fn maintenance_dispatch_waits_for_shared_store_users_without_erasing_launch_permission() {
    let (_root, journal) = fixture();
    let (gate, key) = ready_kind(&journal, true);
    let store = store(&journal);
    let permission = Permit {
        version: 1,
        identity: identity(),
        permission: Permission::Recovery {
            epoch: 0,
            boot_id: gate.boot_id().to_owned(),
        },
    };
    gate.try_fence()
        .unwrap()
        .unwrap()
        .publish(&permission)
        .unwrap();
    let original = fs::read(journal.root.join("launch/permit.json")).unwrap();
    let shared = store.try_admission(&journal).unwrap().unwrap();
    let mut delivery = dispatch(&journal);
    let mut supervisor = Supervisor::new(
        &journal,
        crate::build_executor::tests::wait_ready(|| gate.try_controller()),
    )
    .unwrap();
    assert!(
        supervisor
            .launch_next(&store, &mut delivery, 1000)
            .unwrap()
            .is_none()
    );
    assert_eq!(delivery.calls, 0);
    assert_eq!(journal.pool().unwrap().epoch, 0);
    assert_eq!(
        journal.maintenance_status(&key).unwrap().attempt.phase(),
        Phase::Queued
    );
    assert_eq!(
        fs::read(journal.root.join("launch/permit.json")).unwrap(),
        original
    );
    drop(shared);
    assert!(
        supervisor
            .launch_next(&store, &mut delivery, 1000)
            .unwrap()
            .is_some()
    );
    assert!(
        supervisor
            .launch_next(&store, &mut delivery, 1001)
            .unwrap()
            .is_none()
    );
    assert_eq!(delivery.calls, 1);
}

#[test]
fn cancelling_selected_build_cannot_reserve_maintenance_under_a_shared_guard() {
    struct Race<'a>(&'a Journal, String);
    impl Launcher for Race<'_> {
        fn ready(&mut self, _: &Fence<'_>, _: &Pool) -> Result<bool> {
            self.0.cancel("operator", &self.1, None, 1000)?;
            self.0.settle_unlaunched(1000)?;
            Ok(true)
        }
        fn start_once(&mut self, _: &Ownership) -> Result<()> {
            panic!("wrong lock mode dispatch")
        }
    }
    let (_root, journal) = fixture();
    let (gate, key) = ready(&journal);
    let request = crate::build_executor::maintenance::Request {
        version: 1,
        id: RequestId {
            issued_at: 1000,
            nonce: "maintenance".into(),
        },
        storage: identity(),
        policy_digest: policy().digest().unwrap(),
        deadlines: policy().deadlines,
        operation: crate::build_executor::maintenance::Operation::CollectGarbage,
    };
    let next = journal.submit_maintenance(request, 1000).unwrap();
    journal.queue(&next.attempt_id, 1000).unwrap();
    let mut supervisor = Supervisor::new(
        &journal,
        crate::build_executor::tests::wait_ready(|| gate.try_controller()),
    )
    .unwrap();
    assert!(
        supervisor
            .launch_next(&store(&journal), &mut Race(&journal, key), 1000)
            .unwrap()
            .is_none()
    );
    assert_eq!(journal.pool().unwrap().epoch, 0);
    assert_eq!(
        journal
            .maintenance_status(&next.attempt_id)
            .unwrap()
            .attempt
            .phase(),
        Phase::Queued
    );
    assert!(!journal.root.join("launch/permit.json").exists());
    let mut delivery = dispatch(&journal);
    assert!(
        supervisor
            .launch_next(&store(&journal), &mut delivery, 1000)
            .unwrap()
            .is_some()
    );
    assert_eq!(delivery.calls, 1);
}
