//! CI observer launch claim. This confers no preparation, realization, release
//! or deployment permission. No restart/adoption after an uncertain dispatch.

use super::*;
use crate::build_executor::native_intent::Request;

pub(super) const MAX_BYTES: usize = 1024;

#[cfg(test)]
mod tests;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(in crate::build_executor) struct Claim {
    ownership: Ownership,
    pub(in crate::build_executor) invocation: Option<String>,
    pub(in crate::build_executor) group: Option<super::super::controller_service::Group>,
    retired: bool,
}

pub(super) fn validate(job: &Job) -> Result<()> {
    if let Some(claim) = &job.controller {
        ensure!(
            job.request
                .native()
                .is_some_and(|request| request.controller_service)
                && job.attempt.state.ownership() == Some(&claim.ownership)
                && job.reserved_at.is_some(),
            "CI controller lacks original service ownership"
        );
        if let Some(invocation) = &claim.invocation {
            ExecutionHandle {
                ownership: claim.ownership.clone(),
                invocation_id: invocation.clone(),
            }
            .validate(&job.acceptance.attempt_id)?;
        }
        ensure!(
            !claim.retired || job.outcome().is_some(),
            "controller retired before original settlement"
        );
        ensure!(
            claim.group.is_none() || claim.invocation.is_some(),
            "controller group lacks invocation"
        );
        if let Some(group) = &claim.group {
            group.validate()?;
        }
        ensure!(
            serde_json::to_vec(claim)?.len() <= MAX_BYTES,
            "CI controller claim exceeds reservation"
        );
    }
    Ok(())
}

pub(super) fn retired(job: &Job) -> bool {
    job.controller.as_ref().is_none_or(|claim| claim.retired)
}

impl Journal {
    pub(in crate::build_executor) fn bind_controller_group(
        &self,
        owner: &Ownership,
        invocation: &str,
        group: super::super::controller_service::Group,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            let job = sources::active(state, owner, now).or_else(|_| {
                let job = state
                    .jobs
                    .iter()
                    .find(|job| job.acceptance.attempt_id == owner.attempt_id)
                    .context("controller job missing")?;
                ensure!(
                    state.pool.owner.as_ref() == Some(owner)
                        && state.pool.health == PoolHealth::Owned
                        && job.phase() == Phase::Starting
                        && !job_deadline_expired(job, now),
                    "controller binding expired"
                );
                Ok::<_, anyhow::Error>(job)
            })?;
            let claim = job
                .controller
                .as_ref()
                .context("controller claim missing")?;
            ensure!(
                claim.invocation.as_deref() == Some(invocation)
                    && claim.group.is_none()
                    && !claim.retired,
                "controller group already bound or changed"
            );
            job_mut(state, &owner.attempt_id)?
                .controller
                .as_mut()
                .context("controller claim missing")?
                .group = Some(group);
            Ok(())
        })
    }

    pub(in crate::build_executor) fn controller_retirement(
        &self,
        target: &Ownership,
    ) -> Result<Option<Claim>> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let job = state
            .jobs
            .iter()
            .find(|job| job.acceptance.attempt_id == target.attempt_id)
            .context("controller target missing")?;
        ensure!(
            job.attempt.state.ownership() == Some(target) && job.outcome().is_some(),
            "controller target unsettled"
        );
        Ok(job
            .controller
            .as_ref()
            .filter(|claim| !claim.retired)
            .cloned())
    }

    pub(in crate::build_executor) fn retire_controller(
        &self,
        cleanup: &Ownership,
        target: &Ownership,
        now: u64,
    ) -> Result<()> {
        self.retirement_active(cleanup, now)?;
        self.update(now, |state, _| {
            let job = job_mut(state, &target.attempt_id)?;
            ensure!(
                job.attempt.state.ownership() == Some(target)
                    && job.outcome().is_some()
                    && job
                        .retirement
                        .as_ref()
                        .is_some_and(|record| record.owner.as_ref() == Some(cleanup)),
                "controller retirement authority differs"
            );
            job.controller
                .as_mut()
                .context("controller claim missing")?
                .retired = true;
            Ok(())
        })
    }

    pub(in crate::build_executor) fn claim_controller(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<Option<Request>> {
        self.update(now, |state, now| {
            ensure!(
                state.pool.owner.as_ref() == Some(owner) && state.pool.health == PoolHealth::Owned,
                "CI controller pool differs"
            );
            let job = job_mut(state, &owner.attempt_id)?;
            let Some(request) = job
                .request
                .native()
                .filter(|request| request.controller_service)
                .cloned()
            else {
                return Ok(None);
            };
            ensure!(
                job.phase() == Phase::Starting
                    && job.attempt.state.ownership() == Some(owner)
                    && !job_deadline_expired(job, now)
                    && now.saturating_sub(job.renewed_at) < request.deadlines.owner_seconds
                    && job.controller.is_none(),
                "CI controller already dispatched or expired"
            );
            job.controller = Some(Claim {
                ownership: owner.clone(),
                invocation: None,
                group: None,
                retired: false,
            });
            Ok(Some(request))
        })
    }

    pub(in crate::build_executor) fn begin_controller(
        &self,
        attempt: &str,
        invocation: &str,
        now: u64,
    ) -> Result<(Request, Ownership, u64)> {
        self.update(now, |state, now| {
            let owner = state
                .pool
                .owner
                .clone()
                .context("CI controller owner missing")?;
            ensure!(
                owner.attempt_id == attempt && state.pool.health == PoolHealth::Owned,
                "CI controller owner differs"
            );
            let job = job_mut(state, attempt)?;
            ensure!(
                matches!(job.phase(), Phase::Starting | Phase::Running)
                    && !job_deadline_expired(job, now),
                "CI controller is no longer live"
            );
            let request = job
                .request
                .native()
                .filter(|request| request.controller_service)
                .context("CI observer not requested")?
                .clone();
            let claim = job
                .controller
                .as_mut()
                .context("CI controller was not dispatched")?;
            ensure!(
                claim.ownership == owner && claim.invocation.is_none(),
                "CI controller invocation already consumed"
            );
            ensure!(
                now.saturating_sub(job.renewed_at) < request.deadlines.owner_seconds,
                "CI observer owner expired"
            );
            ExecutionHandle {
                ownership: owner.clone(),
                invocation_id: invocation.to_owned(),
            }
            .validate(attempt)?;
            claim.invocation = Some(invocation.to_owned());
            Ok((
                request,
                owner,
                job.reserved_at
                    .context("CI controller reservation missing")?,
            ))
        })
    }
}
