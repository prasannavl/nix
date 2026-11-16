use std::collections::BTreeSet;
use std::time::Duration;

use abird_host_manager::fleet::orchestration::{
    ActionExecution, ActionStatus, AttemptCancellation, CancellationController,
    CancellationDecision, DeployActivity, DeployClassification, DeployObservation,
    DeployRequirement, FailFastPlan, FinalHostState, HostAttempt, HostAttemptEvent,
    HostAttemptState, HostMilestone, HostQualifier, HostStage, HostSummaryFacts, PhaseOutcome,
    PhaseStatus, SnapshotEligibility, SnapshotOutcome, SummaryMode, TerminationSignal,
    classify_deploy, readiness_attempts, rollback_waves,
};

#[test]
fn remote_uncertainty_and_unadmitted_hosts_never_render_as_terminal_build_failure() {
    for mode in [SummaryMode::BuildLike, SummaryMode::Deployment] {
        let uncertain = HostSummaryFacts {
            build_unconfirmed: true,
            build_failed: true,
            interrupted: true,
            ..Default::default()
        }
        .final_state(mode);
        assert_eq!(
            uncertain,
            FinalHostState::new(
                HostMilestone::None,
                HostQualifier::Unconfirmed(HostStage::Build)
            )
        );

        let queued = HostSummaryFacts {
            build_not_started: true,
            build_failed: true,
            ..Default::default()
        }
        .final_state(mode);
        assert_eq!(
            queued,
            FinalHostState::new(
                HostMilestone::None,
                HostQualifier::NotStarted(HostStage::Build)
            )
        );
    }
}

#[test]
fn readiness_retry_budget_rounds_up_without_zero_attempts() {
    assert_eq!(readiness_attempts(5, 2).unwrap(), 3);
    assert_eq!(readiness_attempts(3, 2).unwrap(), 2);
    assert_eq!(readiness_attempts(1, 5).unwrap(), 1);
    assert!(readiness_attempts(0, 2).is_err());
    assert!(readiness_attempts(2, 0).is_err());
}

#[test]
fn host_attempt_tracks_the_activation_admission_boundary() {
    let mut attempt = HostAttemptState::Queued;
    attempt.transition(HostAttemptEvent::Start).unwrap();
    assert_eq!(attempt, HostAttemptState::Preparing);
    assert_eq!(
        attempt.fail_fast_cancellation(),
        AttemptCancellation::CancelLocal
    );
    assert!(!attempt.rollback_eligible());

    attempt
        .transition(HostAttemptEvent::AdmissionAccepted)
        .unwrap();
    assert_eq!(attempt, HostAttemptState::Admitted);
    assert!(attempt.admission_accepted());
    assert_eq!(
        attempt.fail_fast_cancellation(),
        AttemptCancellation::CancelLocal
    );
    assert!(!attempt.rollback_eligible());

    attempt
        .transition(HostAttemptEvent::ActivationStarted)
        .unwrap();
    assert_eq!(attempt, HostAttemptState::Activating);
    assert_eq!(
        attempt.fail_fast_cancellation(),
        AttemptCancellation::WaitForCompletion
    );
    assert!(attempt.rollback_eligible());

    attempt.transition(HostAttemptEvent::Succeeded).unwrap();
    assert_eq!(attempt, HostAttemptState::Succeeded);
    assert!(attempt.rollback_eligible());

    let mut failed_activation = HostAttemptState::Activating;
    failed_activation
        .transition(HostAttemptEvent::Failed)
        .unwrap();
    assert_eq!(failed_activation, HostAttemptState::FailedAfterActivation);
    assert!(failed_activation.rollback_eligible());

    let mut skipped = HostAttemptState::Queued;
    skipped.transition(HostAttemptEvent::Skip).unwrap();
    assert_eq!(skipped, HostAttemptState::Skipped);
}

#[test]
fn admission_rejection_and_pre_activation_failure_never_trigger_rollback() {
    let mut rejected = HostAttemptState::Preparing;
    rejected
        .transition(HostAttemptEvent::AdmissionRejected)
        .unwrap();
    assert_eq!(rejected, HostAttemptState::AdmissionRejected);
    assert!(!rejected.rollback_eligible());
    assert_eq!(rejected.fail_fast_cancellation(), AttemptCancellation::None);

    let mut failed = HostAttemptState::Admitted;
    failed.transition(HostAttemptEvent::Failed).unwrap();
    assert_eq!(failed, HostAttemptState::FailedAfterAdmission);
    assert!(!failed.rollback_eligible());

    let mut cancelled = HostAttemptState::Preparing;
    cancelled
        .transition(HostAttemptEvent::CancelBeforeActivation)
        .unwrap();
    assert_eq!(cancelled, HostAttemptState::CancelledBeforeActivation);
    assert!(!cancelled.rollback_eligible());
}

#[test]
fn host_attempt_rejects_impossible_or_destructive_transitions() {
    let mut queued = HostAttemptState::Queued;
    assert!(
        queued
            .transition(HostAttemptEvent::ActivationStarted)
            .is_err()
    );

    let mut activating = HostAttemptState::Activating;
    assert!(
        activating
            .transition(HostAttemptEvent::CancelBeforeActivation)
            .is_err()
    );

    let mut terminal = HostAttemptState::Succeeded;
    assert!(terminal.transition(HostAttemptEvent::Failed).is_err());
}

#[test]
fn snapshot_outcomes_fail_closed_for_required_hosts_and_skip_optional_hosts() {
    assert_eq!(
        SnapshotOutcome::Missing.eligibility(DeployRequirement::Required, "/nix/store/new"),
        SnapshotEligibility::RefuseMissing
    );
    assert_eq!(
        SnapshotOutcome::Missing.eligibility(DeployRequirement::Optional, "/nix/store/new"),
        SnapshotEligibility::SkipOptionalMissing
    );
    assert_eq!(
        SnapshotOutcome::NotRequested.eligibility(DeployRequirement::Required, "/nix/store/new"),
        SnapshotEligibility::Deploy {
            rollback_generation: None
        }
    );
}

#[test]
fn captured_snapshot_controls_unchanged_skip_and_rollback_eligibility() {
    let captured = SnapshotOutcome::Captured {
        generation: "/nix/store/old".to_owned(),
    };
    assert_eq!(
        captured.eligibility(DeployRequirement::Required, "/nix/store/old"),
        SnapshotEligibility::SkipUnchanged
    );
    assert_eq!(
        captured.eligibility(DeployRequirement::Required, "/nix/store/new"),
        SnapshotEligibility::Deploy {
            rollback_generation: Some("/nix/store/old".to_owned())
        }
    );
}

#[test]
fn deploy_results_distinguish_required_optional_signal_and_missing_status() {
    assert_eq!(
        classify_deploy(DeployRequirement::Required, DeployObservation::Exit(0)),
        DeployClassification::Succeeded
    );
    assert_eq!(
        classify_deploy(DeployRequirement::Required, DeployObservation::Skipped),
        DeployClassification::Skipped
    );
    assert_eq!(
        classify_deploy(DeployRequirement::Optional, DeployObservation::Exit(1)),
        DeployClassification::OptionalFailure { status: Some(1) }
    );
    assert_eq!(
        classify_deploy(DeployRequirement::Required, DeployObservation::Exit(1)),
        DeployClassification::RequiredFailure { status: Some(1) }
    );
    assert_eq!(
        classify_deploy(
            DeployRequirement::Optional,
            DeployObservation::MissingStatus
        ),
        DeployClassification::RequiredFailure { status: None }
    );
    assert_eq!(
        classify_deploy(DeployRequirement::Required, DeployObservation::Signal(130)),
        DeployClassification::Interrupted { status: 130 }
    );
    assert_eq!(
        classify_deploy(
            DeployRequirement::Required,
            DeployObservation::FailFastCancelled
        ),
        DeployClassification::FailFastCancelled
    );
    assert!(
        classify_deploy(DeployRequirement::Required, DeployObservation::Exit(1))
            .triggers_fail_fast()
    );
    assert!(
        !classify_deploy(DeployRequirement::Optional, DeployObservation::Exit(1))
            .triggers_fail_fast()
    );
}

#[test]
fn fail_fast_stops_queued_hosts_and_only_cancels_pre_activation_attempts() {
    let attempts = vec![
        HostAttempt::new("queued", HostAttemptState::Queued),
        HostAttempt::new("preparing", HostAttemptState::Preparing),
        HostAttempt::new("admitted", HostAttemptState::Admitted),
        HostAttempt::new("activating", HostAttemptState::Activating),
        HostAttempt::new("done", HostAttemptState::Succeeded),
    ];
    let plan = FailFastPlan::after_required_failure("failed", &attempts);

    assert_eq!(plan.trigger, "failed");
    assert_eq!(plan.do_not_start, ["queued"]);
    assert_eq!(plan.cancel_before_activation, ["preparing", "admitted"]);
    assert_eq!(plan.wait_for_completion, ["activating"]);
}

#[test]
fn rollback_runs_dependents_before_dependencies_and_preserves_wave_order() {
    let levels = vec![
        vec!["controller".to_owned()],
        vec!["parent".to_owned()],
        vec!["app-a".to_owned(), "app-b".to_owned()],
    ];
    let eligible = BTreeSet::from([
        "controller".to_owned(),
        "app-a".to_owned(),
        "app-b".to_owned(),
    ]);

    assert_eq!(
        rollback_waves(&levels, &eligible),
        vec![
            vec!["app-a".to_owned(), "app-b".to_owned()],
            vec!["controller".to_owned()],
        ]
    );
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TestPhase {
    Dns,
    Platform,
    Build,
    Snapshot,
    Deploy,
    Health,
    Apps,
}

#[test]
fn action_execution_advances_every_phase_in_order() {
    let phases = [
        TestPhase::Dns,
        TestPhase::Platform,
        TestPhase::Build,
        TestPhase::Snapshot,
        TestPhase::Deploy,
        TestPhase::Health,
        TestPhase::Apps,
    ];
    let mut action = ActionExecution::new(phases);
    assert_eq!(action.status(), ActionStatus::Ready);

    for (index, phase) in phases.into_iter().enumerate() {
        assert_eq!(action.start_next().unwrap(), Some(phase));
        assert_eq!(action.current_phase(), Some(&phase));
        let outcome = if phase == TestPhase::Snapshot {
            PhaseOutcome::Skipped
        } else {
            PhaseOutcome::Succeeded
        };
        action.finish_current(outcome).unwrap();
        assert_eq!(
            action.phases()[index].status,
            if phase == TestPhase::Snapshot {
                PhaseStatus::Skipped
            } else {
                PhaseStatus::Succeeded
            }
        );
    }

    assert_eq!(action.status(), ActionStatus::Succeeded);
    assert_eq!(action.start_next().unwrap(), None);
}

#[test]
fn action_execution_supports_partial_failure_cleanup_but_blocks_after_abort() {
    let mut partial = ActionExecution::new([TestPhase::Deploy, TestPhase::Health]);
    partial.start_next().unwrap();
    partial
        .finish_current(PhaseOutcome::FailedContinue)
        .unwrap();
    assert_eq!(partial.status(), ActionStatus::Ready);
    assert_eq!(partial.start_next().unwrap(), Some(TestPhase::Health));
    partial.finish_current(PhaseOutcome::Succeeded).unwrap();
    assert_eq!(partial.status(), ActionStatus::Failed);

    let mut aborted = ActionExecution::new([TestPhase::Build, TestPhase::Deploy]);
    aborted.start_next().unwrap();
    aborted.finish_current(PhaseOutcome::FailedAbort).unwrap();
    assert_eq!(aborted.status(), ActionStatus::Failed);
    assert!(aborted.start_next().is_err());
    assert_eq!(aborted.phases()[1].status, PhaseStatus::Pending);
}

#[test]
fn action_execution_rejects_finish_without_start_and_records_cancellation() {
    let mut action = ActionExecution::new([TestPhase::Build]);
    assert!(action.finish_current(PhaseOutcome::Succeeded).is_err());
    action.start_next().unwrap();
    action.finish_current(PhaseOutcome::Cancelled).unwrap();
    assert_eq!(action.status(), ActionStatus::Cancelled);
    assert_eq!(action.phases()[0].status, PhaseStatus::Cancelled);
}

#[test]
fn hangup_is_immediate_local_cleanup_without_remote_cancellation() {
    let mut controller = CancellationController::new(3, Duration::from_secs(3)).unwrap();
    assert_eq!(
        controller.receive(
            TerminationSignal::Hangup,
            Duration::from_secs(10),
            DeployActivity::active(),
            true
        ),
        CancellationDecision::HangupExit { status: 129 }
    );
    assert_eq!(controller.requested_count(), 0);
}

#[test]
fn first_interrupt_arms_and_second_interrupt_decides_the_cancel() {
    let mut waiting = CancellationController::default();
    assert_eq!(
        waiting.receive(
            TerminationSignal::Interrupt,
            Duration::from_secs(10),
            DeployActivity::active(),
            true
        ),
        CancellationDecision::PendingCancel { status: 130 }
    );
    assert_eq!(
        waiting.receive(
            TerminationSignal::Interrupt,
            Duration::from_secs(11),
            DeployActivity::active(),
            true
        ),
        CancellationDecision::WaitForActiveDeploys { status: 130 }
    );

    let mut idle = CancellationController::default();
    idle.receive(
        TerminationSignal::Terminate,
        Duration::from_secs(10),
        DeployActivity::idle(),
        true,
    );
    assert_eq!(
        idle.receive(
            TerminationSignal::Terminate,
            Duration::from_secs(11),
            DeployActivity::idle(),
            true
        ),
        CancellationDecision::CancelLocalAndExit { status: 143 }
    );
}

#[test]
fn confirmed_interrupts_escalate_within_window_and_reset_after_window() {
    let mut controller = CancellationController::default();
    assert!(matches!(
        controller.receive(
            TerminationSignal::Interrupt,
            Duration::from_secs(10),
            DeployActivity::active(),
            true
        ),
        CancellationDecision::PendingCancel { .. }
    ));
    assert_eq!(
        controller.receive(
            TerminationSignal::Terminate,
            Duration::from_secs(12),
            DeployActivity::active(),
            true
        ),
        CancellationDecision::WaitForActiveDeploys { status: 143 }
    );
    assert_eq!(
        controller.receive(
            TerminationSignal::Interrupt,
            Duration::from_secs(13),
            DeployActivity::active(),
            true
        ),
        CancellationDecision::ForceCancelRemoteAndExit { status: 130 }
    );
    assert!(controller.force_requested());

    let mut reset = CancellationController::default();
    reset.receive(
        TerminationSignal::Interrupt,
        Duration::from_secs(1),
        DeployActivity::active(),
        true,
    );
    assert!(matches!(
        reset.receive(
            TerminationSignal::Interrupt,
            Duration::from_secs(5),
            DeployActivity::active(),
            true
        ),
        CancellationDecision::PendingCancel { .. }
    ));
    assert_eq!(reset.requested_count(), 1);
}

#[test]
fn cancellation_configuration_rejects_zero_and_honors_immediate_threshold() {
    assert!(CancellationController::new(0, Duration::from_secs(3)).is_err());

    let mut immediate = CancellationController::new(1, Duration::from_secs(3)).unwrap();
    assert_eq!(
        immediate.receive(
            TerminationSignal::Interrupt,
            Duration::from_secs(1),
            DeployActivity::active(),
            true
        ),
        CancellationDecision::ForceCancelRemoteAndExit { status: 130 }
    );
}

#[test]
fn final_host_state_preserves_precedence_with_composable_milestone_and_qualifier() {
    let facts = HostSummaryFacts {
        build_failed: true,
        fully_skipped: true,
        optional_rollback_failed: true,
        health_rollback_failed: true,
        deploy_rollback_failed: true,
        ..HostSummaryFacts::default()
    };
    assert_eq!(
        facts.final_state(SummaryMode::Deployment),
        FinalHostState::failed(HostMilestone::None, HostStage::Build)
    );

    let skipped = HostSummaryFacts {
        fully_skipped: true,
        optional_rollback_failed: true,
        ..HostSummaryFacts::default()
    };
    assert_eq!(
        skipped.final_state(SummaryMode::Deployment),
        FinalHostState::skipped(HostMilestone::None, None)
    );
    assert_eq!(
        HostSummaryFacts {
            build_succeeded: true,
            fully_skipped: true,
            ..HostSummaryFacts::default()
        }
        .final_state(SummaryMode::Deployment),
        FinalHostState::skipped(HostMilestone::Built, Some(HostStage::Deploy))
    );

    let optional = HostSummaryFacts {
        optional_rollback_failed: true,
        optional_snapshot_skipped: true,
        optional_rollback_succeeded: true,
        ..HostSummaryFacts::default()
    };
    assert_eq!(
        optional.final_state(SummaryMode::Deployment),
        FinalHostState::new(
            HostMilestone::Acquired,
            HostQualifier::RollbackFailed {
                failed: Some(HostStage::Deploy),
                optional: true,
            }
        )
    );

    let health = HostSummaryFacts {
        health_failed: true,
        health_rollback_succeeded: true,
        deploy_rollback_failed: true,
        ..HostSummaryFacts::default()
    };
    assert_eq!(
        health.final_state(SummaryMode::Deployment),
        FinalHostState::new(
            HostMilestone::Deployed,
            HostQualifier::RolledBack {
                failed: Some(HostStage::Health),
                optional: false,
            }
        )
    );

    let deploy = HostSummaryFacts {
        snapshot_failed: true,
        deploy_rollback_succeeded: true,
        deploy_failed: true,
        ..HostSummaryFacts::default()
    };
    assert_eq!(
        deploy.final_state(SummaryMode::Deployment),
        FinalHostState::failed(HostMilestone::Built, HostStage::Snapshot)
    );
}

#[test]
fn final_host_state_handles_build_like_actions_and_fallbacks() {
    assert_eq!(
        HostSummaryFacts {
            build_succeeded: true,
            ..HostSummaryFacts::default()
        }
        .final_state(SummaryMode::BuildLike),
        FinalHostState::ok(HostMilestone::Built)
    );
    assert_eq!(
        HostSummaryFacts::default().final_state(SummaryMode::BuildLike),
        FinalHostState::new(HostMilestone::None, HostQualifier::Failed(None))
    );
    assert_eq!(
        HostSummaryFacts {
            build_succeeded: true,
            ..HostSummaryFacts::default()
        }
        .final_state(SummaryMode::Deployment),
        FinalHostState::ok(HostMilestone::Built)
    );
}

#[test]
fn interruption_is_distinct_from_failure_but_preserves_completed_work() {
    assert_eq!(
        HostSummaryFacts {
            interrupted: true,
            ..HostSummaryFacts::default()
        }
        .final_state(SummaryMode::Deployment),
        FinalHostState::new(HostMilestone::None, HostQualifier::Interrupted)
    );

    assert_eq!(
        HostSummaryFacts {
            interrupted: true,
            build_succeeded: true,
            ..HostSummaryFacts::default()
        }
        .final_state(SummaryMode::Deployment),
        FinalHostState::new(HostMilestone::Built, HostQualifier::Interrupted)
    );
    assert_eq!(
        HostSummaryFacts {
            interrupted: true,
            fully_skipped: true,
            ..HostSummaryFacts::default()
        }
        .final_state(SummaryMode::Deployment),
        FinalHostState::skipped(HostMilestone::None, None)
    );
}
