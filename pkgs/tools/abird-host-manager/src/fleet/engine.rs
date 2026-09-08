//! Effect-neutral phase engine for native fleet workflows.

use std::error::Error;
use std::fmt;

use anyhow::{Result, anyhow};

use super::cli::Invocation;
use super::plan::{Phase, WorkflowPlan};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PhaseFailure {
    pub phase: Phase,
    pub message: String,
}

impl PhaseFailure {
    pub fn new(phase: Phase, message: impl Into<String>) -> Self {
        Self {
            phase,
            message: message.into(),
        }
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
    for phase in WorkflowPlan::for_action(&invocation.action).phases {
        super::signal::check_interrupted()?;
        if let Err(failure) = effects.run_phase(phase) {
            super::signal::check_interrupted()?;
            let rollback_eligible = matches!(failure.phase, Phase::Deploy | Phase::Health);
            if rollback_eligible
                && !invocation.options.no_rollback
                && let Err(rollback) = effects.rollback(failure.phase)
            {
                return Err(anyhow!("{failure}; rollback also failed: {rollback:#}"));
            }
            return Err(failure.into());
        }
        super::signal::check_interrupted()?;
    }
    Ok(())
}
