//! Trusted in-slice verifier receipt. Persist before worker exit; neither the
//! receipt nor exit0 settles descendants or releases protection.

use super::*;

pub(super) const MAX_BYTES: usize = 2048;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(in crate::build_executor) struct Verified {
    pub handle: ExecutionHandle,
    pub outcome: Outcome,
    pub completed_at: u64,
}

impl Verified {
    pub(super) fn validate(&self, job: &Job, last_time: u64) -> Result<()> {
        self.handle.validate(&job.acceptance.attempt_id)?;
        ensure!(
            job.attempt.state.ownership() == Some(&self.handle.ownership)
                && job
                    .reserved_at
                    .is_some_and(|time| time <= self.completed_at)
                && self.completed_at <= last_time,
            "verification ownership or time differs"
        );
        self.outcome.validate(&job.acceptance.spec_digest)?;
        if job.request.kind() == Kind::Retirement {
            ensure!(
                job.native_phase.is_none() && job.daemon_claim.is_none(),
                "retirement acquired native authority"
            );
        } else {
            ensure!(
                job.native_phase
                    .as_ref()
                    .is_some_and(|phase| phase.writers_settled_at.is_some()),
                "verification before native writer settlement"
            );
        }
        match (&self.outcome, job.request.kind()) {
            (Outcome::Succeeded { artifacts }, Kind::Build) => {
                ensure!(
                    job.artifact
                        .as_ref()
                        .is_some_and(|record| record.file.is_some()
                            && record.digest == artifacts.closure_digest),
                    "verification artifact publication differs"
                );
                ensure!(
                    job.prepared
                        .as_ref()
                        .is_some_and(|prepared| prepared.digest == artifacts.preparation_digest),
                    "verification preparation differs"
                );
            }
            (Outcome::MaintenanceSucceeded { .. }, Kind::Maintenance | Kind::Retirement) => {
                ensure!(
                    job.prepared.is_none() && job.private_source.is_none(),
                    "maintenance verification contains build inputs"
                );
            }
            _ => bail!("verification work kind differs"),
        }
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_BYTES,
            "verification exceeds reservation"
        );
        Ok(())
    }
}

impl Journal {
    /// Only the installed verifier calls this after checking actual native work,
    /// complete artifacts and protection. Never a public control verb.
    pub(in crate::build_executor) fn record_verified(
        &self,
        handle: &ExecutionHandle,
        outcome: Outcome,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            ensure!(
                state.pool.health == PoolHealth::Owned
                    && state.pool.owner.as_ref() == Some(&handle.ownership),
                "verification pool differs"
            );
            let job = job_mut(state, &handle.ownership.attempt_id)?;
            ensure!(
                job.request.kind() != Kind::Retirement,
                "retirement requires complete cleanup verification"
            );
            ensure!(
                job.attempt.state.execution()
                    == Some(super::super::Execution::Started {
                        handle: handle.clone()
                    })
                    && job.phase() == Phase::Running
                    && !job_deadline_expired(job, now)
                    && (!job.request.foreground()
                        || now.saturating_sub(job.renewed_at)
                            < job.request.deadlines().stale_seconds)
                    && job.verified.is_none(),
                "verification owner unavailable or already recorded"
            );
            let verified = Verified {
                handle: handle.clone(),
                outcome,
                completed_at: now,
            };
            verified.validate(job, now)?;
            job.verified = Some(verified);
            Ok(())
        })
    }

    pub(in crate::build_executor) fn verified(
        &self,
        owner: &Ownership,
    ) -> Result<Option<Verified>> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        ensure!(
            state.pool.owner.as_ref() == Some(owner),
            "verification owner changed"
        );
        let job = state
            .jobs
            .iter()
            .find(|job| job.acceptance.attempt_id == owner.attempt_id)
            .context("verification attempt missing")?;
        Ok(job.verified.clone())
    }

    /// Same journal transition as failure settlement; cancellation racing this
    /// transaction wins rather than being overwritten by successful verification.
    pub(in crate::build_executor) fn settle_verified(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            ensure!(
                state.pool.owner.as_ref() == Some(owner),
                "verified settlement owner changed"
            );
            let job = job_mut(state, &owner.attempt_id)?;
            ensure!(
                job.phase() == Phase::Verifying,
                "verified settlement no longer applicable"
            );
            let verified = job
                .verified
                .as_ref()
                .context("verified result missing")?
                .clone();
            verified.validate(job, now)?;
            let evidence = Settlement::FencedEmpty {
                ownership: owner.clone(),
            };
            job.apply(EventKind::Settled, now, |attempt| {
                match &verified.outcome {
                    Outcome::Succeeded { artifacts } => {
                        attempt.settle(evidence, Some(artifacts.clone()))?;
                    }
                    Outcome::MaintenanceSucceeded {
                        verification_digest,
                    } => {
                        attempt.settle_maintenance(evidence, verification_digest)?;
                    }
                    _ => bail!("invalid verified result"),
                }
                Ok(())
            })?;
            job.settled_at = Some(now);
            state.pool.owner = None;
            if state.pool.health != PoolHealth::Quarantined {
                state.pool.health = PoolHealth::Recovering;
            }
            state.pool.recovery_digest = None;
            Ok(())
        })
    }
}
