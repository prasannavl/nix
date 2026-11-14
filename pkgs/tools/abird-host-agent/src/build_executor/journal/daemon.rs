//! Native daemon launch intent, separate from the client worker's Started grant.
//! A retained claim forbids re-exec; it is not ingress/stop/settlement authority.

use super::*;

pub(super) const MAX_CLAIM_BYTES: usize = 2048;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Claim {
    handle: ExecutionHandle,
    claimed_at: u64,
}

impl Claim {
    pub(super) fn validate(&self, job: &Job, last_time: u64) -> Result<()> {
        self.handle.validate(&job.acceptance.attempt_id)?;
        ensure!(
            job.native_phase
                .as_ref()
                .is_some_and(|phase| phase.file.is_some()
                    && phase.sealed_at.is_none_or(|time| self.claimed_at <= time)),
            "daemon claim lacks its original native gate"
        );
        ensure!(
            job.attempt.state.ownership() == Some(&self.handle.ownership)
                && job.reserved_at.is_some_and(|time| time <= self.claimed_at)
                && self.claimed_at <= last_time
                && job.settled_at.is_none_or(|time| self.claimed_at <= time),
            "invalid daemon claim"
        );
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_CLAIM_BYTES,
            "daemon claim exceeds metadata reservation"
        );
        Ok(())
    }
}

pub(super) fn eligible(state: &State, now: u64) -> Result<&Ownership> {
    ensure!(now >= state.last_time, Rejection::ClockRegressed);
    ensure!(
        state.pool.health == PoolHealth::Owned,
        "daemon pool unavailable"
    );
    let owner = state.pool.owner.as_ref().context("daemon owner missing")?;
    let job = state
        .jobs
        .iter()
        .find(|job| job.acceptance.attempt_id == owner.attempt_id)
        .context("daemon attempt missing")?;
    ensure!(
        job.request.kind() != Kind::Retirement
            && job.attempt.state.ownership() == Some(owner)
            && matches!(
                job.phase(),
                Phase::Starting | Phase::Running | Phase::Verifying
            )
            && job.release_digest.is_none()
            && !job_deadline_expired(job, now)
            && (!job.request.foreground()
                || now.saturating_sub(job.renewed_at) < job.request.deadlines().stale_seconds),
        "daemon owner unavailable/expired"
    );
    Ok(owner)
}

impl Journal {
    /// Read-only startup veto; not the one-shot launch claim or ingress authority.
    pub(in crate::build_executor) fn daemon_owner(&self, now: u64) -> Result<Ownership> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let now = self.effective_time(now, state.last_time)?;
        Ok(eligible(&state, now)?.clone())
    }

    /// Trusted supervisor observation, including stopping owners. No new grant.
    pub(in crate::build_executor) fn claimed_daemon(
        &self,
        owner: &Ownership,
    ) -> Result<Option<ExecutionHandle>> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        ensure!(
            state.pool.owner.as_ref() == Some(owner),
            "daemon observation owner changed"
        );
        let job = state
            .jobs
            .iter()
            .find(|job| job.acceptance.attempt_id == owner.attempt_id)
            .context("daemon observation attempt missing")?;
        Ok(job.daemon_claim.as_ref().map(|claim| claim.handle.clone()))
    }

    /// Installed wrapper only, after exact placement, activation and launch guard.
    /// Persist before native exec. Even identical replay rejects; uncertain write
    /// or failed exec never clears the claim or grants a new daemon lifetime.
    pub(in crate::build_executor) fn begin_daemon(
        &self,
        handle: ExecutionHandle,
        now: u64,
    ) -> Result<work::Kind> {
        handle.validate(&handle.ownership.attempt_id)?;
        self.update(now, |state, now| {
            ensure!(
                eligible(state, now)? == &handle.ownership,
                "daemon ownership differs"
            );
            let job = job_mut(state, &handle.ownership.attempt_id)?;
            ensure!(
                job.daemon_claim.is_none(),
                "daemon invocation already claimed"
            );
            ensure!(
                job.native_phase
                    .as_ref()
                    .is_some_and(|phase| phase.file.is_some()
                        && phase.sealed_at.is_none()
                        && !phase.retired),
                "native producer gate unavailable"
            );
            let claim = Claim {
                handle,
                claimed_at: now,
            };
            claim.validate(job, now)?;
            job.daemon_claim = Some(claim);
            Ok(job.request.kind())
        })
    }
}

#[cfg(test)]
mod tests;
