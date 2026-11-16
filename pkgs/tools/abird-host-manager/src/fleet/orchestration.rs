//! Pure state and decisions for fleet deployment orchestration.
//!
//! This module deliberately does not install signal handlers, spawn jobs, or
//! perform remote operations. Runtime adapters observe those events and apply
//! the decisions returned here. Keeping the safety policy pure makes the
//! activation admission boundary and cancellation behavior independently
//! testable.

use std::collections::BTreeSet;
use std::time::Duration;

use anyhow::{Context, Result, bail};

/// Convert a wall-clock readiness budget into the number of immediate-plus-
/// interval attempts used by parented host operations.
pub fn readiness_attempts(timeout_seconds: u64, interval_seconds: u64) -> Result<usize> {
    if timeout_seconds == 0 || interval_seconds == 0 {
        bail!("readiness timeout and interval must be positive");
    }
    let attempts = timeout_seconds
        .saturating_sub(1)
        .checked_div(interval_seconds)
        .and_then(|value| value.checked_add(1))
        .context("readiness attempt count overflow")?;
    usize::try_from(attempts).context("readiness attempt count does not fit usize")
}

/// State of one host's deploy attempt around the activation admission boundary.
///
/// Passing admission is not itself rollback eligibility. A rollback becomes
/// necessary only after activation has started, matching nixbot's durable
/// activation marker semantics.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum HostAttemptState {
    #[default]
    Queued,
    Preparing,
    AdmissionRejected,
    Admitted,
    Activating,
    Succeeded,
    Skipped,
    FailedBeforeAdmission,
    FailedAfterAdmission,
    FailedAfterActivation,
    CancelledBeforeActivation,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HostAttemptEvent {
    Start,
    Skip,
    AdmissionAccepted,
    AdmissionRejected,
    ActivationStarted,
    Succeeded,
    Failed,
    CancelBeforeActivation,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AttemptCancellation {
    /// Do not admit a queued host after another required host has failed.
    DoNotStart,
    /// Stop the local job; no remote activation has started.
    CancelLocal,
    /// Leave the admitted remote activation to settle before classifying it.
    WaitForCompletion,
    /// The attempt is terminal and needs no fail-fast action.
    None,
}

impl HostAttemptState {
    pub fn transition(&mut self, event: HostAttemptEvent) -> Result<()> {
        let next = match (*self, event) {
            (Self::Queued, HostAttemptEvent::Start) => Self::Preparing,
            (Self::Queued, HostAttemptEvent::Skip) => Self::Skipped,

            (Self::Preparing, HostAttemptEvent::AdmissionAccepted) => Self::Admitted,
            (Self::Preparing, HostAttemptEvent::AdmissionRejected) => Self::AdmissionRejected,
            (Self::Preparing, HostAttemptEvent::Failed) => Self::FailedBeforeAdmission,
            (Self::Preparing, HostAttemptEvent::CancelBeforeActivation) => {
                Self::CancelledBeforeActivation
            }

            (Self::Admitted, HostAttemptEvent::ActivationStarted) => Self::Activating,
            (Self::Admitted, HostAttemptEvent::Failed) => Self::FailedAfterAdmission,
            (Self::Admitted, HostAttemptEvent::CancelBeforeActivation) => {
                Self::CancelledBeforeActivation
            }

            (Self::Activating, HostAttemptEvent::Succeeded) => Self::Succeeded,
            (Self::Activating, HostAttemptEvent::Failed) => Self::FailedAfterActivation,

            (state, event) => bail!("invalid host attempt transition: {state:?} -> {event:?}"),
        };
        *self = next;
        Ok(())
    }

    pub fn admission_accepted(self) -> bool {
        matches!(
            self,
            Self::Admitted
                | Self::Activating
                | Self::Succeeded
                | Self::FailedAfterAdmission
                | Self::FailedAfterActivation
        )
    }

    pub fn activation_started(self) -> bool {
        matches!(
            self,
            Self::Activating | Self::Succeeded | Self::FailedAfterActivation
        )
    }

    pub fn rollback_eligible(self) -> bool {
        self.activation_started()
    }

    pub fn fail_fast_cancellation(self) -> AttemptCancellation {
        match self {
            Self::Queued => AttemptCancellation::DoNotStart,
            Self::Preparing | Self::Admitted => AttemptCancellation::CancelLocal,
            Self::Activating => AttemptCancellation::WaitForCompletion,
            Self::AdmissionRejected
            | Self::Succeeded
            | Self::Skipped
            | Self::FailedBeforeAdmission
            | Self::FailedAfterAdmission
            | Self::FailedAfterActivation
            | Self::CancelledBeforeActivation => AttemptCancellation::None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostAttempt {
    pub host: String,
    pub state: HostAttemptState,
}

impl HostAttempt {
    pub fn new(host: impl Into<String>, state: HostAttemptState) -> Self {
        Self {
            host: host.into(),
            state,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FailFastPlan {
    pub trigger: String,
    pub do_not_start: Vec<String>,
    pub cancel_before_activation: Vec<String>,
    pub wait_for_completion: Vec<String>,
}

impl FailFastPlan {
    /// Classify remaining attempts after a completed required deploy failure.
    ///
    /// Terminal attempts are intentionally absent from the returned plan.
    pub fn after_required_failure(trigger: impl Into<String>, attempts: &[HostAttempt]) -> Self {
        let mut plan = Self {
            trigger: trigger.into(),
            do_not_start: Vec::new(),
            cancel_before_activation: Vec::new(),
            wait_for_completion: Vec::new(),
        };
        for attempt in attempts {
            match attempt.state.fail_fast_cancellation() {
                AttemptCancellation::DoNotStart => plan.do_not_start.push(attempt.host.clone()),
                AttemptCancellation::CancelLocal => {
                    plan.cancel_before_activation.push(attempt.host.clone());
                }
                AttemptCancellation::WaitForCompletion => {
                    plan.wait_for_completion.push(attempt.host.clone());
                }
                AttemptCancellation::None => {}
            }
        }
        plan
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeployRequirement {
    Required,
    Optional,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SnapshotOutcome {
    /// Snapshots were disabled, for example by dry-run or no-rollback mode.
    NotRequested,
    Captured {
        generation: String,
    },
    Missing,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SnapshotEligibility {
    Deploy { rollback_generation: Option<String> },
    SkipUnchanged,
    SkipOptionalMissing,
    RefuseMissing,
}

impl SnapshotOutcome {
    pub fn eligibility(
        &self,
        requirement: DeployRequirement,
        desired_generation: &str,
    ) -> SnapshotEligibility {
        match self {
            Self::NotRequested => SnapshotEligibility::Deploy {
                rollback_generation: None,
            },
            Self::Captured { generation } if generation == desired_generation => {
                SnapshotEligibility::SkipUnchanged
            }
            Self::Captured { generation } => SnapshotEligibility::Deploy {
                rollback_generation: Some(generation.clone()),
            },
            Self::Missing if requirement == DeployRequirement::Optional => {
                SnapshotEligibility::SkipOptionalMissing
            }
            Self::Missing => SnapshotEligibility::RefuseMissing,
        }
    }
}

/// Adapter-neutral observation of a completed deploy worker.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeployObservation {
    Exit(i32),
    Skipped,
    Signal(i32),
    /// The worker exited without publishing its status. Nixbot treats this as
    /// a required failure even for an optional host because its result cannot
    /// be classified safely.
    MissingStatus,
    /// A sibling's required failure cancelled this job before activation.
    FailFastCancelled,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeployClassification {
    Succeeded,
    Skipped,
    OptionalFailure { status: Option<i32> },
    RequiredFailure { status: Option<i32> },
    Interrupted { status: i32 },
    FailFastCancelled,
}

impl DeployClassification {
    pub fn triggers_fail_fast(self) -> bool {
        matches!(self, Self::RequiredFailure { .. })
    }
}

pub fn classify_deploy(
    requirement: DeployRequirement,
    observation: DeployObservation,
) -> DeployClassification {
    match observation {
        DeployObservation::Exit(0) => DeployClassification::Succeeded,
        DeployObservation::Skipped => DeployClassification::Skipped,
        DeployObservation::Signal(status) => DeployClassification::Interrupted { status },
        DeployObservation::MissingStatus => DeployClassification::RequiredFailure { status: None },
        DeployObservation::FailFastCancelled => DeployClassification::FailFastCancelled,
        DeployObservation::Exit(status) if requirement == DeployRequirement::Optional => {
            DeployClassification::OptionalFailure {
                status: Some(status),
            }
        }
        DeployObservation::Exit(status) => DeployClassification::RequiredFailure {
            status: Some(status),
        },
    }
}

/// Return rollback work in reverse dependency-level order.
///
/// Host order inside a level is preserved so runtime logs remain deterministic;
/// empty levels caused by eligibility filtering are removed.
pub fn rollback_waves(
    deployment_levels: &[Vec<String>],
    eligible: &BTreeSet<String>,
) -> Vec<Vec<String>> {
    deployment_levels
        .iter()
        .rev()
        .filter_map(|level| {
            let wave = level
                .iter()
                .filter(|host| eligible.contains(*host))
                .cloned()
                .collect::<Vec<_>>();
            (!wave.is_empty()).then_some(wave)
        })
        .collect()
}

/// Terminal phase result; a missing result means the phase did not run.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PhaseResultKind {
    Succeeded,
    Warning,
    Failed,
    Interrupted,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PhaseResult {
    pub kind: PhaseResultKind,
    pub elapsed: Duration,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PhaseStatus {
    Pending,
    Running,
    Succeeded,
    Skipped,
    Failed,
    Cancelled,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PhaseOutcome {
    Succeeded,
    Skipped,
    /// Record failure but allow a cleanup or verification phase to run.
    FailedContinue,
    FailedAbort,
    Cancelled,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ActionStatus {
    Ready,
    Running,
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PhaseExecution<P> {
    pub phase: P,
    pub status: PhaseStatus,
}

/// Ordered action-phase execution with explicit terminal behavior.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActionExecution<P> {
    phases: Vec<PhaseExecution<P>>,
    current: usize,
    status: ActionStatus,
    saw_failure: bool,
}

impl<P> ActionExecution<P>
where
    P: Clone,
{
    pub fn new(phases: impl IntoIterator<Item = P>) -> Self {
        let phases = phases
            .into_iter()
            .map(|phase| PhaseExecution {
                phase,
                status: PhaseStatus::Pending,
            })
            .collect::<Vec<_>>();
        let status = if phases.is_empty() {
            ActionStatus::Succeeded
        } else {
            ActionStatus::Ready
        };
        Self {
            phases,
            current: 0,
            status,
            saw_failure: false,
        }
    }

    pub fn status(&self) -> ActionStatus {
        self.status
    }

    pub fn phases(&self) -> &[PhaseExecution<P>] {
        &self.phases
    }

    pub fn current_phase(&self) -> Option<&P> {
        (self.status == ActionStatus::Running).then(|| &self.phases[self.current].phase)
    }

    pub fn start_next(&mut self) -> Result<Option<P>> {
        match self.status {
            ActionStatus::Succeeded => return Ok(None),
            ActionStatus::Ready => {}
            ActionStatus::Running => bail!("an action phase is already running"),
            ActionStatus::Failed | ActionStatus::Cancelled => {
                bail!("cannot start a phase after the action became terminal")
            }
        }
        let Some(execution) = self.phases.get_mut(self.current) else {
            self.status = if self.saw_failure {
                ActionStatus::Failed
            } else {
                ActionStatus::Succeeded
            };
            return Ok(None);
        };
        execution.status = PhaseStatus::Running;
        self.status = ActionStatus::Running;
        Ok(Some(execution.phase.clone()))
    }

    pub fn finish_current(&mut self, outcome: PhaseOutcome) -> Result<()> {
        if self.status != ActionStatus::Running {
            bail!("cannot finish an action phase that is not running");
        }
        let execution = &mut self.phases[self.current];
        match outcome {
            PhaseOutcome::Succeeded => execution.status = PhaseStatus::Succeeded,
            PhaseOutcome::Skipped => execution.status = PhaseStatus::Skipped,
            PhaseOutcome::FailedContinue | PhaseOutcome::FailedAbort => {
                execution.status = PhaseStatus::Failed;
                self.saw_failure = true;
            }
            PhaseOutcome::Cancelled => execution.status = PhaseStatus::Cancelled,
        }

        self.current += 1;
        self.status = match outcome {
            PhaseOutcome::FailedAbort => ActionStatus::Failed,
            PhaseOutcome::Cancelled => ActionStatus::Cancelled,
            PhaseOutcome::Succeeded | PhaseOutcome::Skipped | PhaseOutcome::FailedContinue
                if self.current < self.phases.len() =>
            {
                ActionStatus::Ready
            }
            PhaseOutcome::Succeeded | PhaseOutcome::Skipped | PhaseOutcome::FailedContinue
                if self.saw_failure =>
            {
                ActionStatus::Failed
            }
            PhaseOutcome::Succeeded | PhaseOutcome::Skipped | PhaseOutcome::FailedContinue => {
                ActionStatus::Succeeded
            }
        };
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminationSignal {
    Hangup,
    Interrupt,
    Terminate,
}

impl TerminationSignal {
    pub fn exit_status(self) -> i32 {
        match self {
            Self::Hangup => 129,
            Self::Interrupt => 130,
            Self::Terminate => 143,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct DeployActivity {
    pub jobs_started: bool,
    pub active_deploy_jobs: bool,
}

impl DeployActivity {
    pub fn idle() -> Self {
        Self::default()
    }

    pub fn active() -> Self {
        Self {
            jobs_started: true,
            active_deploy_jobs: true,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CancellationDecision {
    HangupExit {
        status: i32,
    },
    /// First interrupt when confirmation is required: arm a confirmable cancel.
    /// Nothing is stopped yet, and the request expires if no second interrupt
    /// arrives inside the window.
    PendingCancel {
        status: i32,
    },
    /// Confirmed cancel while a deploy/activation is still in flight: wait for
    /// it to finish, then release local cancellation.
    WaitForActiveDeploys {
        status: i32,
    },
    /// Cancel with nothing in flight: stop local work now.
    CancelLocalAndExit {
        status: i32,
    },
    /// Interrupt counted toward the force threshold with no action of its own
    /// (the unconfirmed second press).
    AwaitEscalation {
        status: i32,
        received: u32,
        remaining: u32,
    },
    /// Force threshold reached: force remote cancellation and exit.
    ForceCancelRemoteAndExit {
        status: i32,
    },
}

/// Pure escalation policy for HUP, INT, and TERM.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CancellationController {
    force_signal_count: u32,
    escalation_window: Duration,
    requested: u32,
    last_request_at: Option<Duration>,
}

impl Default for CancellationController {
    fn default() -> Self {
        Self::new(3, Duration::from_secs(3)).expect("default cancellation policy is valid")
    }
}

impl CancellationController {
    pub fn new(force_signal_count: u32, escalation_window: Duration) -> Result<Self> {
        if force_signal_count == 0 {
            bail!("force cancellation signal count must be positive");
        }
        Ok(Self {
            force_signal_count,
            escalation_window,
            requested: 0,
            last_request_at: None,
        })
    }

    pub fn requested_count(&self) -> u32 {
        self.requested
    }

    pub fn force_requested(&self) -> bool {
        self.requested >= self.force_signal_count
    }

    pub fn receive(
        &mut self,
        signal: TerminationSignal,
        now: Duration,
        activity: DeployActivity,
        confirm: bool,
    ) -> CancellationDecision {
        let status = signal.exit_status();
        if signal == TerminationSignal::Hangup {
            return CancellationDecision::HangupExit { status };
        }

        let inside_window = self.last_request_at.is_some_and(|last| {
            now.checked_sub(last)
                .is_some_and(|elapsed| elapsed <= self.escalation_window)
        });
        self.requested = if inside_window {
            self.requested.saturating_add(1)
        } else {
            1
        };
        self.last_request_at = Some(now);

        if self.force_requested() {
            return CancellationDecision::ForceCancelRemoteAndExit { status };
        }
        // With confirmation the first interrupt only arms the cancel and the
        // second performs it; without it the first interrupt cancels and the
        // second is a countdown toward force.
        let cancel_at = if confirm { 2 } else { 1 };
        if self.requested < cancel_at {
            return CancellationDecision::PendingCancel { status };
        }
        if self.requested == cancel_at {
            return if activity.active_deploy_jobs {
                CancellationDecision::WaitForActiveDeploys { status }
            } else {
                CancellationDecision::CancelLocalAndExit { status }
            };
        }
        CancellationDecision::AwaitEscalation {
            status,
            received: self.requested,
            remaining: self.force_signal_count.saturating_sub(self.requested),
        }
    }

    /// Whether the last interrupt is now outside the confirmation window, so a
    /// pending cancel should expire.
    pub fn confirmation_window_elapsed(&self, now: Duration) -> bool {
        self.last_request_at.is_none_or(|last| {
            now.checked_sub(last)
                .is_none_or(|elapsed| elapsed > self.escalation_window)
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SummaryMode {
    BuildLike,
    Deployment,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct HostSummaryFacts {
    pub build_unconfirmed: bool,
    pub build_not_started: bool,
    pub build_succeeded: bool,
    pub build_failed: bool,
    pub interrupted: bool,
    pub fully_skipped: bool,
    pub snapshot_failed: bool,
    pub deploy_succeeded: bool,
    pub deploy_skipped: bool,
    pub deploy_failed: bool,
    pub optional_snapshot_skipped: bool,
    pub optional_rollback_succeeded: bool,
    pub optional_rollback_failed: bool,
    pub rollback_succeeded: bool,
    pub rollback_failed: bool,
    pub deploy_rollback_succeeded: bool,
    pub deploy_rollback_failed: bool,
    pub health_failed: bool,
    pub health_rollback_succeeded: bool,
    pub health_rollback_failed: bool,
}

impl HostSummaryFacts {
    /// Resolve overlapping observations using the legacy summary precedence.
    pub fn final_state(self, mode: SummaryMode) -> FinalHostState {
        if self.build_unconfirmed {
            return FinalHostState::new(
                HostMilestone::None,
                HostQualifier::Unconfirmed(HostStage::Build),
            );
        }
        if self.build_not_started {
            return FinalHostState::new(
                HostMilestone::None,
                HostQualifier::NotStarted(HostStage::Build),
            );
        }
        if self.build_failed {
            return FinalHostState::failed(HostMilestone::None, HostStage::Build);
        }
        if self.fully_skipped {
            return if self.build_succeeded {
                FinalHostState::skipped(HostMilestone::Built, Some(HostStage::Deploy))
            } else {
                FinalHostState::skipped(HostMilestone::None, None)
            };
        }
        if mode == SummaryMode::BuildLike {
            return if self.interrupted {
                FinalHostState::new(
                    if self.build_succeeded {
                        HostMilestone::Built
                    } else {
                        HostMilestone::None
                    },
                    HostQualifier::Interrupted,
                )
            } else if self.build_succeeded {
                FinalHostState::ok(HostMilestone::Built)
            } else {
                FinalHostState::new(HostMilestone::None, HostQualifier::Failed(None))
            };
        }
        if self.optional_rollback_failed {
            FinalHostState::new(
                HostMilestone::Acquired,
                HostQualifier::RollbackFailed {
                    failed: Some(HostStage::Deploy),
                    optional: true,
                },
            )
        } else if self.optional_snapshot_skipped {
            FinalHostState::new(
                HostMilestone::Built,
                HostQualifier::OptionalSkipped(HostStage::Snapshot),
            )
        } else if self.optional_rollback_succeeded {
            FinalHostState::new(
                HostMilestone::Acquired,
                HostQualifier::RolledBack {
                    failed: Some(HostStage::Deploy),
                    optional: true,
                },
            )
        } else if self.rollback_failed {
            FinalHostState::new(
                HostMilestone::Acquired,
                HostQualifier::RollbackFailed {
                    failed: None,
                    optional: false,
                },
            )
        } else if self.health_rollback_failed {
            FinalHostState::new(
                HostMilestone::Deployed,
                HostQualifier::RollbackFailed {
                    failed: Some(HostStage::Health),
                    optional: false,
                },
            )
        } else if self.health_rollback_succeeded {
            FinalHostState::new(
                HostMilestone::Deployed,
                HostQualifier::RolledBack {
                    failed: Some(HostStage::Health),
                    optional: false,
                },
            )
        } else if self.health_failed {
            FinalHostState::failed(HostMilestone::Deployed, HostStage::Health)
        } else if self.deploy_rollback_failed {
            FinalHostState::new(
                HostMilestone::Acquired,
                HostQualifier::RollbackFailed {
                    failed: Some(HostStage::Deploy),
                    optional: false,
                },
            )
        } else if self.snapshot_failed {
            FinalHostState::failed(HostMilestone::Built, HostStage::Snapshot)
        } else if self.deploy_rollback_succeeded {
            FinalHostState::new(
                HostMilestone::Acquired,
                HostQualifier::RolledBack {
                    failed: Some(HostStage::Deploy),
                    optional: false,
                },
            )
        } else if self.deploy_failed {
            FinalHostState::failed(HostMilestone::Acquired, HostStage::Deploy)
        } else if self.rollback_succeeded {
            FinalHostState::new(
                HostMilestone::Acquired,
                HostQualifier::RolledBack {
                    failed: None,
                    optional: false,
                },
            )
        } else if self.deploy_skipped {
            FinalHostState::skipped(HostMilestone::Built, Some(HostStage::Deploy))
        } else if self.deploy_succeeded {
            FinalHostState::ok(HostMilestone::Deployed)
        } else if self.interrupted {
            FinalHostState::new(
                if self.build_succeeded {
                    HostMilestone::Built
                } else {
                    HostMilestone::None
                },
                HostQualifier::Interrupted,
            )
        } else if self.build_succeeded {
            FinalHostState::ok(HostMilestone::Built)
        } else {
            FinalHostState::new(HostMilestone::None, HostQualifier::Failed(None))
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HostMilestone {
    None,
    Built,
    Acquired,
    Deployed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HostStage {
    Build,
    Snapshot,
    Acquire,
    Deploy,
    Health,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HostQualifier {
    Ok,
    Skipped(Option<HostStage>),
    Deferred(HostStage),
    OptionalFailed(HostStage),
    Failed(Option<HostStage>),
    DryRun,
    Incomplete(HostStage),
    Unconfirmed(HostStage),
    NotStarted(HostStage),
    Interrupted,
    OptionalSkipped(HostStage),
    RolledBack {
        failed: Option<HostStage>,
        optional: bool,
    },
    RollbackFailed {
        failed: Option<HostStage>,
        optional: bool,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FinalHostState {
    pub milestone: HostMilestone,
    pub qualifier: HostQualifier,
}

impl FinalHostState {
    pub const fn new(milestone: HostMilestone, qualifier: HostQualifier) -> Self {
        Self {
            milestone,
            qualifier,
        }
    }

    pub const fn ok(milestone: HostMilestone) -> Self {
        Self::new(milestone, HostQualifier::Ok)
    }

    pub const fn failed(milestone: HostMilestone, stage: HostStage) -> Self {
        Self::new(milestone, HostQualifier::Failed(Some(stage)))
    }

    pub const fn skipped(milestone: HostMilestone, stage: Option<HostStage>) -> Self {
        Self::new(milestone, HostQualifier::Skipped(stage))
    }
}
