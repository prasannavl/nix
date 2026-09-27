//! Effect-neutral phase engine for native fleet workflows.

use std::error::Error;
use std::fmt;

use anyhow::{Result, anyhow};

use super::cli::Invocation;
use super::orchestration::{ActionExecution, PhaseOutcome, PhaseStatus};
use super::plan::{Phase, WorkflowPlan};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PhaseFailure {
    pub phase: Phase,
    pub message: String,
    continue_through: Option<Phase>,
}

impl PhaseFailure {
    pub fn new(phase: Phase, message: impl Into<String>) -> Self {
        Self {
            phase,
            message: message.into(),
            continue_through: None,
        }
    }

    pub fn continuing_through(
        phase: Phase,
        message: impl Into<String>,
        continue_through: Phase,
    ) -> Self {
        Self {
            phase,
            message: message.into(),
            continue_through: Some(continue_through),
        }
    }

    pub fn continue_through(&self) -> Option<Phase> {
        self.continue_through
    }
}

impl fmt::Display for PhaseFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "fleet phase {:?} failed: {}",
            self.phase, self.message
        )
    }
}

impl Error for PhaseFailure {}

pub trait FleetEffects {
    fn run_phase(&mut self, phase: Phase) -> std::result::Result<(), PhaseFailure>;
    fn rollback(&mut self, failed_phase: Phase) -> Result<()>;
}

pub fn execute(invocation: &Invocation, effects: &mut impl FleetEffects) -> Result<()> {
    let mut execution = ActionExecution::new(WorkflowPlan::for_action(&invocation.action).phases);
    let mut deferred_failure: Option<(PhaseFailure, Phase)> = None;

    while let Some(phase) = execution.start_next()? {
        super::signal::check_interrupted()?;
        if let Err(failure) = effects.run_phase(phase) {
            super::signal::check_interrupted()?;
            let rollback_eligible = matches!(failure.phase, Phase::Deploy | Phase::Health);
            if rollback_eligible
                && !invocation.options.no_rollback
                && let Err(rollback) = effects.rollback(failure.phase)
            {
                execution.finish_current(PhaseOutcome::FailedAbort)?;
                let rollback_failure = anyhow!("{failure}; rollback also failed: {rollback:#}");
                return if let Some((earlier, _)) = deferred_failure {
                    Err(anyhow!("{earlier}; subsequent {rollback_failure}"))
                } else {
                    Err(rollback_failure)
                };
            }

            if let Some(continue_through) = failure.continue_through() {
                execution.finish_current(PhaseOutcome::FailedContinue)?;
                let target_is_pending = execution.phases().iter().any(|execution| {
                    execution.phase == continue_through && execution.status == PhaseStatus::Pending
                });
                if !target_is_pending {
                    return Err(anyhow!(
                        "{failure}; continuation phase {continue_through:?} is not pending"
                    ));
                }
                if let Some((earlier, _)) = &deferred_failure {
                    return Err(anyhow!("{earlier}; subsequent deferred {failure}"));
                }
                deferred_failure = Some((failure, continue_through));
                continue;
            }

            execution.finish_current(PhaseOutcome::FailedAbort)?;
            return if let Some((earlier, _)) = deferred_failure {
                Err(anyhow!("{earlier}; subsequent {failure}"))
            } else {
                Err(failure.into())
            };
        }
        execution.finish_current(PhaseOutcome::Succeeded)?;

        if deferred_failure
            .as_ref()
            .is_some_and(|(_, continue_through)| *continue_through == phase)
        {
            let (failure, _) = deferred_failure
                .take()
                .expect("checked deferred phase failure");
            return Err(failure.into());
        }
        super::signal::check_interrupted()?;
    }

    if let Some((failure, continue_through)) = deferred_failure {
        Err(anyhow!(
            "{failure}; continuation phase {continue_through:?} was not executed"
        ))
    } else {
        Ok(())
    }
}
