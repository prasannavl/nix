use super::*;

// CLOEXEC descriptors can remain inherited until a concurrent child execs/exits.
// Pending is not rejection; never change an assertion expecting exclusion/error.
pub(super) fn wait_ready<T>(mut probe: impl FnMut() -> anyhow::Result<Option<T>>) -> T {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        if let Some(value) = probe().unwrap() {
            return value;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "test lock remained pending"
        );
        std::thread::park_timeout(std::time::Duration::from_millis(1));
    }
}

fn attempt() -> Attempt {
    Attempt::pending("attempt-1", "a".repeat(64)).unwrap()
}

fn owner() -> Ownership {
    Ownership {
        executor_version: 1,
        builder_id: "builder-1".into(),
        store_id: "store-1".into(),
        attempt_id: "attempt-1".into(),
        pool_epoch: NonZeroU64::new(1).unwrap(),
        boot_id: "boot-1".into(),
    }
}

fn handle() -> ExecutionHandle {
    ExecutionHandle {
        ownership: owner(),
        invocation_id: "invocation-1".into(),
    }
}

fn artifacts() -> ArtifactReceipt {
    ArtifactReceipt {
        spec_digest: "a".repeat(64),
        preparation_digest: "d".repeat(64),
        closure_digest: "b".repeat(64),
        roots_digest: "c".repeat(64),
    }
}

fn running() -> Attempt {
    let mut job = attempt();
    job.mark_queued().unwrap();
    job.reserve(owner()).unwrap();
    job.started(handle()).unwrap();
    job
}

#[test]
fn success_needs_verified_artifacts_and_settlement() {
    let mut job = running();
    assert!(
        job.settle(Settlement::Idle { handle: handle() }, Some(artifacts()))
            .is_err()
    );
    job.client_exited(&handle(), ClientExit::Success).unwrap();
    assert_eq!(job.phase(), Phase::Verifying);
    let before = job.encode().unwrap();
    assert!(
        job.settle(Settlement::Idle { handle: handle() }, None)
            .is_err()
    );
    assert_eq!(job.encode().unwrap(), before);
    job.settle(Settlement::Idle { handle: handle() }, Some(artifacts()))
        .unwrap();
    assert_eq!(job.phase(), Phase::Succeeded);
}

#[test]
fn client_failure_is_not_worker_settlement() {
    let mut job = running();
    job.client_exited(&handle(), ClientExit::Failed { exit_code: 17 })
        .unwrap();
    assert_eq!(job.phase(), Phase::Stopping);
    assert!(job.outcome().is_none());
    job.settle(Settlement::FencedEmpty { ownership: owner() }, None)
        .unwrap();
    assert_eq!(
        job.outcome(),
        Some(&Outcome::Failed {
            reason: StopReason::ClientFailed {
                exit: ClientExit::Failed { exit_code: 17 }
            },
        })
    );
}

#[test]
fn cancellation_ack_does_not_release_work() {
    let mut job = running();
    assert!(
        job.request_stop(Some(&owner()), StopReason::Cancelled)
            .unwrap()
    );
    assert!(
        !job.request_stop(Some(&owner()), StopReason::Cancelled)
            .unwrap()
    );
    assert_eq!(job.phase(), Phase::Stopping);
    job.client_exited(&handle(), ClientExit::Success).unwrap();
    assert_eq!(job.phase(), Phase::Stopping);
    job.settle(Settlement::FencedEmpty { ownership: owner() }, None)
        .unwrap();
    assert_eq!(job.phase(), Phase::Cancelled);
    let status = job.status(Observation::Connected, PoolHealth::Recovering);
    assert_eq!(status.pool, PoolHealth::Recovering);
    assert!(!status.outcome_unconfirmed);
}

#[test]
fn unavailable_transport_does_not_change_execution() {
    let job = running();
    let before = job.encode().unwrap();
    for observation in [Observation::Reconnecting, Observation::Unavailable] {
        let status = job.status(observation, PoolHealth::Owned);
        assert_eq!(status.execution, Phase::Running);
        assert!(status.outcome_unconfirmed);
        assert!(status.outcome.is_none());
    }
    assert_eq!(job.encode().unwrap(), before);
}

#[test]
fn stale_cancel_and_settlement_leave_state_unchanged() {
    let mut job = running();
    let mut stale = owner();
    stale.pool_epoch = NonZeroU64::new(2).unwrap();
    let before = job.encode().unwrap();
    assert!(
        job.request_stop(Some(&stale), StopReason::Cancelled)
            .is_err()
    );
    assert!(
        job.settle(Settlement::FencedEmpty { ownership: stale }, None)
            .is_err()
    );
    assert_eq!(job.encode().unwrap(), before);
}

#[test]
fn every_execution_identity_component_is_fenced() {
    for field in 0..6 {
        let mut job = running();
        let mut wrong = handle();
        match field {
            0 => wrong.ownership.builder_id = "other-builder".into(),
            1 => wrong.ownership.store_id = "other-store".into(),
            2 => wrong.ownership.attempt_id = "other-attempt".into(),
            3 => wrong.ownership.pool_epoch = NonZeroU64::new(2).unwrap(),
            4 => wrong.ownership.boot_id = "other-boot".into(),
            5 => wrong.invocation_id = "other-invocation".into(),
            _ => unreachable!(),
        }
        let before = job.encode().unwrap();
        assert!(job.client_exited(&wrong, ClientExit::Success).is_err());
        assert_eq!(job.encode().unwrap(), before);
    }
}

#[test]
fn queued_cancel_requires_unlaunched_receipt_and_cannot_start() {
    let mut job = attempt();
    job.mark_queued().unwrap();
    job.request_stop(None, StopReason::Cancelled).unwrap();
    assert_eq!(job.phase(), Phase::Stopping);
    assert!(job.reserve(owner()).is_err());
    assert!(
        job.settle(Settlement::FencedEmpty { ownership: owner() }, None)
            .is_err()
    );
    job.settle(Settlement::Unlaunched, None).unwrap();
    assert_eq!(job.phase(), Phase::Cancelled);
}

#[test]
fn cancel_during_start_preserves_fence_and_late_invocation() {
    let mut job = attempt();
    job.mark_queued().unwrap();
    job.reserve(owner()).unwrap();
    job.request_stop(Some(&owner()), StopReason::Cancelled)
        .unwrap();
    job.started(handle()).unwrap();
    assert_eq!(job.phase(), Phase::Stopping);
    assert!(job.settle(Settlement::Unlaunched, None).is_err());
    job.settle(Settlement::FencedEmpty { ownership: owner() }, None)
        .unwrap();
    assert_eq!(job.phase(), Phase::Cancelled);
}

#[test]
fn lost_start_ack_does_not_authorize_reexecution() {
    let mut job = attempt();
    assert_eq!(job.recovery_action(), RecoveryAction::ValidateSubmission);
    job.mark_queued().unwrap();
    assert_eq!(job.recovery_action(), RecoveryAction::AwaitAdmission);
    job.reserve(owner()).unwrap();
    let restored = Attempt::decode(&job.encode().unwrap()).unwrap();
    assert_eq!(restored.phase(), Phase::Starting);
    assert_eq!(
        restored.recovery_action(),
        RecoveryAction::ReconcileExecution
    );
}

#[test]
fn reboot_is_interruption_not_build_failure_or_automatic_retry() {
    let mut job = running();
    assert!(
        job.settle(
            Settlement::Rebooted {
                ownership: owner(),
                new_boot_id: "boot-1".into(),
            },
            None
        )
        .is_err()
    );
    job.settle(
        Settlement::Rebooted {
            ownership: owner(),
            new_boot_id: "boot-2".into(),
        },
        None,
    )
    .unwrap();
    assert_eq!(job.phase(), Phase::Interrupted);
    assert_eq!(job.recovery_action(), RecoveryAction::RetainTerminal);
    assert!(job.started(handle()).is_err());
}

#[test]
fn terminal_receipts_are_immutable_and_survive_observation_loss() {
    let mut job = running();
    job.request_stop(Some(&owner()), StopReason::Cancelled)
        .unwrap();
    let receipt = Settlement::FencedEmpty { ownership: owner() };
    job.settle(receipt.clone(), None).unwrap();
    let before = job.encode().unwrap();
    assert!(!job.settle(receipt, None).unwrap());
    assert!(
        !job.request_stop(Some(&owner()), StopReason::Cancelled)
            .unwrap()
    );
    assert!(
        job.settle(Settlement::Idle { handle: handle() }, Some(artifacts()))
            .is_err()
    );
    assert!(
        !job.status(Observation::Unavailable, PoolHealth::Quarantined)
            .outcome_unconfirmed
    );
    assert_eq!(job.encode().unwrap(), before);
}

#[test]
fn artifact_receipts_are_bound_to_the_exact_specification() {
    let mut job = running();
    job.client_exited(&handle(), ClientExit::Success).unwrap();
    let mut wrong = artifacts();
    wrong.spec_digest = "d".repeat(64);
    assert!(
        job.settle(Settlement::Idle { handle: handle() }, Some(wrong))
            .is_err()
    );
    assert_eq!(job.phase(), Phase::Verifying);
}

#[test]
fn decoding_is_versioned_bounded_and_strict() {
    let bytes = running().encode().unwrap();
    assert_eq!(Attempt::decode(&bytes).unwrap().encode().unwrap(), bytes);
    assert!(Attempt::decode(&vec![b' '; MAX_RECORD_BYTES + 1]).is_err());
    for change in ["version", "unknown", "identity", "epoch", "executor"] {
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        match change {
            "version" => value["schema_version"] = 1.into(),
            "unknown" => value["extra"] = true.into(),
            "identity" => value["state"]["handle"]["ownership"]["attempt_id"] = "other".into(),
            "epoch" => value["state"]["handle"]["ownership"]["pool_epoch"] = 0.into(),
            "executor" => value["state"]["handle"]["ownership"]["executor_version"] = 2.into(),
            _ => unreachable!(),
        }
        assert!(
            Attempt::decode(&serde_json::to_vec(&value).unwrap()).is_err(),
            "{change}"
        );
    }
}

#[test]
fn unsafe_identifiers_and_false_failure_exit_are_rejected() {
    for id in ["", "../job", "job\n", "job/child", "job@foreign"] {
        assert!(Attempt::pending(id, "a".repeat(64)).is_err());
    }
    assert!(Attempt::pending("job", "not-a-digest").is_err());
    let mut job = running();
    assert!(
        job.client_exited(&handle(), ClientExit::Failed { exit_code: 0 })
            .is_err()
    );
    assert!(
        job.client_exited(&handle(), ClientExit::Signalled { signal: 0 })
            .is_err()
    );
}

#[test]
fn all_stop_reasons_preserve_settlement_requirements() {
    for reason in [
        StopReason::Cancelled,
        StopReason::OwnerExpired,
        StopReason::DeadlineExpired,
        StopReason::ResourceExhausted,
        StopReason::VerificationFailed,
        StopReason::ExecutorLost,
    ] {
        let mut job = running();
        job.request_stop(Some(&owner()), reason).unwrap();
        assert_eq!(job.phase(), Phase::Stopping);
        assert_eq!(job.recovery_action(), RecoveryAction::ReconcileExecution);
        assert!(job.outcome().is_none());
        job.settle(Settlement::FencedEmpty { ownership: owner() }, None)
            .unwrap();
        assert_eq!(job.outcome(), Some(&reason.outcome()));
        let restored = Attempt::decode(&job.encode().unwrap()).unwrap();
        assert_eq!(restored.outcome(), job.outcome());
    }
}

#[test]
fn admission_failure_requires_unlaunched_settlement() {
    let mut job = attempt();
    job.request_stop(None, StopReason::AdmissionFailed).unwrap();
    assert_eq!(job.phase(), Phase::Stopping);
    job.settle(Settlement::Unlaunched, None).unwrap();
    assert_eq!(job.phase(), Phase::Failed);
    assert!(Attempt::decode(&job.encode().unwrap()).is_ok());
}

#[test]
fn no_failure_receipt_without_an_observed_client_invocation() {
    let mut job = attempt();
    job.mark_queued().unwrap();
    job.reserve(owner()).unwrap();
    assert!(
        job.request_stop(
            Some(&owner()),
            StopReason::ClientFailed {
                exit: ClientExit::Failed { exit_code: 1 },
            }
        )
        .is_err()
    );
    assert_eq!(job.phase(), Phase::Starting);
    job.request_stop(Some(&owner()), StopReason::Cancelled)
        .unwrap();
    let mut value: serde_json::Value = serde_json::from_slice(&job.encode().unwrap()).unwrap();
    value["state"]["reason"] = serde_json::json!({
        "kind": "client_failed", "exit": {"kind": "failed", "exit_code": 1}
    });
    assert!(Attempt::decode(&serde_json::to_vec(&value).unwrap()).is_err());
}

#[test]
fn unit_identity_is_deterministic_before_launch() {
    assert_eq!(
        owner().unit_name().unwrap(),
        "abird-build-client@attempt-1.service"
    );
    let mut invalid = owner();
    invalid.attempt_id = "../foreign".into();
    assert!(invalid.unit_name().is_err());
}

#[test]
fn success_cannot_be_forged_with_a_never_started_receipt() {
    let mut job = running();
    job.client_exited(&handle(), ClientExit::Success).unwrap();
    job.settle(Settlement::Idle { handle: handle() }, Some(artifacts()))
        .unwrap();
    let mut value: serde_json::Value = serde_json::from_slice(&job.encode().unwrap()).unwrap();
    value["state"]["settlement"] = serde_json::json!({"kind":"preparation_settled"});
    assert!(Attempt::decode(&serde_json::to_vec(&value).unwrap()).is_err());
}

#[test]
fn every_lifecycle_state_checks_all_transition_families() {
    let fenced = Settlement::FencedEmpty { ownership: owner() };
    let idle = Settlement::Idle { handle: handle() };
    let reboot = Settlement::Rebooted {
        ownership: owner(),
        new_boot_id: "boot-2".into(),
    };
    let cases = [
        (State::Pending, vec![0, 5]),
        (State::Queued, vec![0, 1, 5]),
        (State::Starting { ownership: owner() }, vec![2, 5, 9]),
        (State::Running { handle: handle() }, vec![2, 3, 4, 5, 9]),
        (State::Verifying { handle: handle() }, vec![3, 5, 6, 9]),
        (
            State::Stopping {
                execution: None,
                reason: StopReason::Cancelled,
            },
            vec![5, 8],
        ),
        (
            State::Stopping {
                execution: Some(Execution::Reserved { ownership: owner() }),
                reason: StopReason::Cancelled,
            },
            vec![2, 5, 7, 9],
        ),
        (
            State::Stopping {
                execution: Some(Execution::Started { handle: handle() }),
                reason: StopReason::Cancelled,
            },
            vec![2, 3, 4, 5, 7, 9],
        ),
        (
            State::Finished {
                outcome: Outcome::Succeeded {
                    artifacts: artifacts(),
                },
                settlement: idle.clone(),
            },
            vec![5, 6],
        ),
        (
            State::Finished {
                outcome: Outcome::Failed {
                    reason: StopReason::ClientFailed {
                        exit: ClientExit::Failed { exit_code: 1 },
                    },
                },
                settlement: fenced.clone(),
            },
            vec![5, 7],
        ),
        (
            State::Finished {
                outcome: Outcome::Cancelled {
                    reason: StopReason::Cancelled,
                },
                settlement: fenced.clone(),
            },
            vec![5, 7],
        ),
        (
            State::Finished {
                outcome: Outcome::Cancelled {
                    reason: StopReason::Cancelled,
                },
                settlement: Settlement::Unlaunched,
            },
            vec![5, 8],
        ),
        (
            State::Finished {
                outcome: Outcome::Failed {
                    reason: StopReason::AdmissionFailed,
                },
                settlement: Settlement::Unlaunched,
            },
            vec![5, 8],
        ),
        (
            State::Finished {
                outcome: Outcome::Interrupted,
                settlement: reboot.clone(),
            },
            vec![5, 9],
        ),
    ];
    for (state, allowed) in cases {
        let mut initial = attempt();
        initial.0.state = state;
        let before = initial.encode().unwrap();
        for operation in 0..10 {
            let mut job = Attempt::decode(&before).unwrap();
            let expected = job.0.state.ownership().cloned();
            let result = match operation {
                0 => job.mark_queued(),
                1 => job.reserve(owner()),
                2 => job.started(handle()),
                3 => job.client_exited(&handle(), ClientExit::Success),
                4 => job.client_exited(&handle(), ClientExit::Failed { exit_code: 1 }),
                5 => job
                    .request_stop(expected.as_ref(), StopReason::Cancelled)
                    .map(|_| ()),
                6 => job.settle(idle.clone(), Some(artifacts())).map(|_| ()),
                7 => job.settle(fenced.clone(), None).map(|_| ()),
                8 => job.settle(Settlement::Unlaunched, None).map(|_| ()),
                9 => job.settle(reboot.clone(), None).map(|_| ()),
                _ => unreachable!(),
            };
            assert_eq!(
                result.is_ok(),
                allowed.contains(&operation),
                "state {:?}, operation {operation}: {result:?}",
                initial.0.state
            );
            let after = job.encode().unwrap();
            Attempt::decode(&after).unwrap();
            if result.is_err() || initial.outcome().is_some() {
                assert_eq!(before, after);
            }
        }
    }
}
