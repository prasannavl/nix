use super::*;
use crate::build_executor::maintenance::{Request, Status};

impl Journal {
    /// Trusted installed scheduler only, never a caller/wire verb. No effects,
    /// capacity increase, source/build target or implicit queue/dispatch here.
    pub fn submit_maintenance(&self, request: Request, now: u64) -> Result<Acceptance> {
        ensure!(
            request.operation == crate::build_executor::maintenance::Operation::CollectGarbage,
            "retirement must atomically bind its original target"
        );
        self.submit_work(Work::Maintenance(Box::new(request)), now)
    }

    pub fn maintenance_status(&self, key: &str) -> Result<Status> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let job = state
            .jobs
            .into_iter()
            .find(|job| job.acceptance.attempt_id == key)
            .context(Rejection::NotFound)?;
        let Work::Maintenance(request) = job.request else {
            return Err(Rejection::NotFound.into());
        };
        Ok(Status {
            request: *request,
            acceptance: job.acceptance,
            attempt: Attempt(job.attempt),
            pool: state.pool.health,
            reserved_at: job.reserved_at,
            settled_at: job.settled_at,
        })
    }

    /// Installed supervisor only, under its closed fence and positive empty
    /// aggregate proof. Maintenance owns no Build source/artifact handoff.
    /// Failure is not relabeled success; it merely stops retaining an empty job.
    pub(in crate::build_executor) fn release_settled_maintenance(
        &self,
        now: u64,
    ) -> Result<Vec<Ownership>> {
        self.update_when(now, |state, now| {
            ensure!(
                state.pool.owner.is_none(),
                "maintenance release while pool owned"
            );
            let mut changed = false;
            let mut retire = Vec::new();
            for job in &mut state.jobs {
                if job.request.kind() == Kind::Build || job.outcome().is_none() {
                    continue;
                }
                ensure!(
                    job.prepared.is_none()
                        && job.private_source.is_none()
                        && self.protection_retired(&job.acceptance.attempt_id)?,
                    "maintenance has unexplained retained data"
                );
                ensure!(
                    matches!(
                        job.attempt.state,
                        super::super::State::Finished {
                            settlement: Settlement::FencedEmpty { .. } | Settlement::Unlaunched,
                            ..
                        }
                    ),
                    "maintenance lacks positive settlement"
                );
                if job.release_digest.is_none() {
                    let mut bytes = b"abird-owned-maintenance-release-v1\n".to_vec();
                    bytes.extend(serde_json::to_vec(&(
                        &job.acceptance,
                        job.settled_at,
                        &job.attempt,
                    ))?);
                    job.release_digest = Some(crate::sha256::digest_bytes(&bytes));
                    job.events.push(EventKind::ProtectionReleased, now)?;
                    changed = true;
                }
                if job
                    .native_phase
                    .as_ref()
                    .is_some_and(|phase| !phase.retired)
                {
                    retire.push(
                        job.attempt
                            .state
                            .ownership()
                            .context("native phase lacks owner")?
                            .clone(),
                    );
                }
            }
            Ok((retire, changed))
        })
    }

    pub(in crate::build_executor) fn next_kind(&self) -> Result<Option<Kind>> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        Ok(state
            .jobs
            .iter()
            .filter(|job| {
                job.outcome().is_none()
                    && (job.request.kind() != Kind::Maintenance || retention_clear(&state, None))
            })
            .min_by_key(|job| {
                (
                    job.request.kind() != Kind::Retirement,
                    job.acceptance.sequence,
                )
            })
            .map(|job| job.request.kind()))
    }

    /// Necessary worker veto while the native exclusive lock is held. Not proof
    /// of installed policy, launch permission, placement, global ingress or exit.
    pub(in crate::build_executor) fn maintenance_active(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<()> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let now = self.effective_time(now, state.last_time)?;
        ensure!(
            state.pool.owner.as_ref() == Some(owner) && state.pool.health == PoolHealth::Owned,
            "maintenance ownership unavailable"
        );
        let job = state
            .jobs
            .iter()
            .find(|job| job.acceptance.attempt_id == owner.attempt_id)
            .context("maintenance attempt missing")?;
        ensure!(
            job.request.kind() == Kind::Maintenance
                && job.attempt.state.ownership() == Some(owner)
                && matches!(job.phase(), Phase::Starting | Phase::Running)
                && !job_deadline_expired(job, now),
            "maintenance worker unavailable/expired"
        );
        ensure!(
            retention_clear(&state, Some(&owner.attempt_id)),
            "maintenance retention veto"
        );
        Ok(())
    }
}

#[cfg(test)]
mod tests;
