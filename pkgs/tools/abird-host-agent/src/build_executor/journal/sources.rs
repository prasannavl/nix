use super::*;
use crate::build_executor::private_sources::{Allocation, DirectoryId};

#[cfg(test)]
mod tests;

pub(super) fn active<'a>(state: &'a State, owner: &Ownership, now: u64) -> Result<&'a Job> {
    owned(state, owner, now, false)
}

fn owned<'a>(state: &'a State, owner: &Ownership, now: u64, starting: bool) -> Result<&'a Job> {
    ensure!(now >= state.last_time, "source clock regressed");
    ensure!(
        state.pool.health == PoolHealth::Owned && state.pool.owner.as_ref() == Some(owner),
        "source pool ownership unavailable"
    );
    let job = state
        .jobs
        .iter()
        .find(|job| job.acceptance.attempt_id == owner.attempt_id)
        .context("source attempt missing")?;
    ensure!(
        job.attempt.state.ownership() == Some(owner)
            && (job.phase() == Phase::Running || (starting && job.phase() == Phase::Starting))
            && job.release_digest.is_none()
            && !job_deadline_expired(job, now)
            && !(job.request.foreground()
                && now.saturating_sub(job.renewed_at) >= job.request.deadlines().owner_seconds),
        "source worker unavailable/expired"
    );
    ensure!(
        job.request.kind() == Kind::Build,
        "source work kind differs"
    );
    Ok(job)
}

impl Journal {
    pub(in crate::build_executor) fn bind_source_endpoint(
        &self,
        owner: &Ownership,
        endpoint: super::super::source_transport::EndpointBinding,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            active(state, owner, now)?;
            let allocation = job_mut(state, &owner.attempt_id)?
                .private_source
                .as_mut()
                .context("source allocation missing")?;
            ensure!(
                allocation.directory.is_some()
                    && allocation.endpoint.is_none()
                    && !allocation.retired,
                "source endpoint already bound or unavailable"
            );
            allocation.endpoint = Some(endpoint);
            Ok(())
        })
    }

    pub(in crate::build_executor) fn input_event(
        &self,
        owner: &Ownership,
        received: Option<String>,
        now: u64,
    ) -> Result<()> {
        if let Some(digest) = &received {
            crate::build_executor::digest(digest)?;
        }
        self.update(now, |state, now| {
            let job = active(state, owner, now)?;
            ensure!(
                job.private_source
                    .as_ref()
                    .is_some_and(|source| source.directory.is_some())
                    && job.prepared.is_none(),
                "source input phase differs"
            );
            use super::super::source_transport::InputState;
            let job = job_mut(state, &owner.attempt_id)?;
            let source = job
                .private_source
                .as_mut()
                .context("source allocation missing")?;
            ensure!(
                source.endpoint.is_some(),
                "input state lacks bound endpoint"
            );
            let (input, kind) = match (&source.input, received) {
                (None, None) => (InputState::Ready, EventKind::InputReady),
                (Some(InputState::Ready), Some(digest)) => (
                    InputState::Received {
                        digest: digest.clone(),
                    },
                    EventKind::InputsReceived { digest },
                ),
                _ => bail!("input transition already consumed or differs"),
            };
            source.input = Some(input);
            job.events.push(kind, now)
        })
    }
    pub(in crate::build_executor) fn build_worker_input(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<(Work, u64)> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let now = self.effective_time(now, state.last_time)?;
        let job = owned(&state, owner, now, true)?;
        ensure!(
            job.phase() == Phase::Starting && job.prepared.is_none(),
            "build worker already started or stopped"
        );
        Ok((
            job.request.clone(),
            job.reserved_at.context("build reservation missing")?,
        ))
    }

    pub(in crate::build_executor) fn build_active(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<()> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let now = self.effective_time(now, state.last_time)?;
        owned(&state, owner, now, true)?;
        Ok(())
    }

    pub(in crate::build_executor) fn source_active(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<()> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let now = self.effective_time(now, state.last_time)?;
        active(&state, owner, now)?;
        Ok(())
    }

    pub(in crate::build_executor) fn register_source(
        &self,
        owner: &Ownership,
        allocation: Allocation,
        now: u64,
    ) -> Result<()> {
        allocation.validate()?;
        ensure!(
            allocation.directory.is_none() && !allocation.retired,
            "source allocation is not fresh"
        );
        self.update(now, |state, now| {
            ensure!(
                active(state, owner, now)?.private_source.is_none(),
                "source allocation already reserved"
            );
            job_mut(state, &owner.attempt_id)?.private_source = Some(allocation);
            Ok(())
        })
    }

    pub(in crate::build_executor) fn bind_source(
        &self,
        owner: &Ownership,
        identity: DirectoryId,
        now: u64,
    ) -> Result<()> {
        self.update_when(now, |state, now| {
            active(state, owner, now)?;
            let source = job_mut(state, &owner.attempt_id)?
                .private_source
                .as_mut()
                .context("source allocation missing")?;
            ensure!(!source.retired, "source allocation retired");
            if let Some(old) = &source.directory {
                ensure!(*old == identity, "source binding is immutable");
                return Ok(((), false));
            }
            source.directory = Some(identity);
            Ok(((), true))
        })
    }

    pub(in crate::build_executor) fn source_allocation(
        &self,
        owner: &Ownership,
    ) -> Result<Allocation> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let job = state
            .jobs
            .iter()
            .find(|job| job.acceptance.attempt_id == owner.attempt_id)
            .context("source attempt missing")?;
        ensure!(
            job.attempt.state.ownership() == Some(owner),
            "source ownership mismatch"
        );
        job.private_source
            .clone()
            .context("source allocation missing")
    }

    // Only the trusted filesystem adapter calls this after removal + parent fsync.
    pub(in crate::build_executor) fn retire_source(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<()> {
        self.update_when(now, |state, _| {
            let job = job_mut(state, &owner.attempt_id)?;
            ensure!(
                job.attempt.state.ownership() == Some(owner)
                    && job.outcome().is_some()
                    && job.release_digest.is_some(),
                "source not settled/released"
            );
            let source = job
                .private_source
                .as_mut()
                .context("source allocation missing")?;
            let changed = !source.retired;
            source.retired = true;
            Ok(((), changed))
        })
    }
}
