//! Retire a positively settled failed, acknowledged or abandoned Build, under a separately
//! admitted maintenance lifetime. Never restart or extend the original Build.

#[cfg(test)]
mod tests;

use super::*;
use crate::build_executor::maintenance::{Operation, Request};

pub(super) const MAX_BYTES: usize = 512;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Record {
    attempt_id: String,
    pub(super) owner: Option<Ownership>,
    complete: bool,
}

impl Record {
    pub(super) fn validate(&self, job: &Job) -> Result<()> {
        super::super::digest(&self.attempt_id)?;
        if let Some(owner) = &self.owner {
            owner.validate(&self.attempt_id)?;
        }
        ensure!(
            !self.complete || self.owner.is_some(),
            "retirement completion lacks worker"
        );
        eligible(job)?;
        ensure!(
            self.attempt_id != job.acceptance.attempt_id,
            "retirement cannot be its own execution"
        );
        ensure!(
            !self.complete
                || (job.release_digest.is_some()
                    && job
                        .private_source
                        .as_ref()
                        .is_none_or(|source| source.retired)
                    && job.native_phase.as_ref().is_none_or(|phase| phase.retired)
                    && job
                        .artifact
                        .as_ref()
                        .is_none_or(|artifact| artifact.retired)
                    && controller::retired(job)),
            "retirement completion precedes cleanup"
        );
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_BYTES,
            "retirement record exceeds bound"
        );
        Ok(())
    }
}

/// Physical cleanup and the original cleanup worker's positive settlement.
/// Journal retention is independent; a completed writer is not a settled one.
pub(super) fn completed(state: &State, job: &Job) -> bool {
    let Some(record) = &job.retirement else {
        return false;
    };
    let Some(owner) = &record.owner else {
        return false;
    };
    if !record.complete {
        return false;
    }
    if let Some(work) = state
        .jobs
        .iter()
        .find(|work| work.acceptance.attempt_id == record.attempt_id)
    {
        return work.request.kind() == Kind::Retirement
            && work.settled_at.is_some()
            && matches!(
                &work.attempt.state,
                super::super::State::Finished {
                    settlement: Settlement::FencedEmpty { ownership }
                        | Settlement::Rebooted { ownership, .. },
                    ..
                } if ownership == owner
            );
    }
    // An exact maintenance tombstone retains positive settlement; absence does not.
    state
        .tombstones
        .iter()
        .any(|entry| entry.maintenance && entry.acceptance.attempt_id == record.attempt_id)
}

pub(super) fn prunable(state: &State, job: &Job) -> bool {
    job.retirement.is_none() || completed(state, job)
}

fn eligible(job: &Job) -> Result<()> {
    ensure!(
        job.request.kind() == Kind::Build
            && job.settled_at.is_some()
            && job.outcome().is_some_and(|outcome| match outcome {
                Outcome::Succeeded { .. } => {
                    job.consumer_ack.is_some() || job.consumer_abandonment.is_some()
                }
                Outcome::MaintenanceSucceeded { .. } => false,
                _ => true,
            })
            && matches!(
                job.attempt.state,
                super::super::State::Finished {
                    settlement: Settlement::FencedEmpty { .. }
                        | Settlement::Unlaunched
                        | Settlement::Rebooted { .. },
                    ..
                }
            ),
        "retirement requires positively settled failed, acknowledged or abandoned Build"
    );
    Ok(())
}

pub(super) fn release_evidence(job: &Job) -> Result<String> {
    eligible(job)?;
    let mut bytes = if let Some(ack) = &job.consumer_ack {
        let mut bytes = b"abird-owned-consumed-release-v1\n".to_vec();
        bytes.extend(serde_json::to_vec(ack)?);
        bytes
    } else if let Some(abandoned) = &job.consumer_abandonment {
        let mut bytes = b"abird-owned-abandoned-release-v1\n".to_vec();
        bytes.extend(serde_json::to_vec(abandoned)?);
        bytes
    } else {
        b"abird-owned-failed-release-v1\n".to_vec()
    };
    bytes.extend(serde_json::to_vec(&(
        &job.acceptance,
        &job.attempt,
        job.settled_at,
    ))?);
    Ok(crate::sha256::digest_bytes(&bytes))
}

#[derive(Clone)]
pub(in crate::build_executor) struct Target {
    pub attempt_id: String,
    pub owner: Option<Ownership>,
    pub evidence: String,
    pub source: bool,
    pub native_phase: bool,
    pub artifact: bool,
    pub successful: bool,
}

fn target<'a>(state: &'a State, owner: &Ownership, now: u64) -> Result<&'a Job> {
    ensure!(
        now >= state.last_time
            && state.pool.health == PoolHealth::Owned
            && state.pool.owner.as_ref() == Some(owner),
        "retirement pool ownership differs"
    );
    let work = state
        .jobs
        .iter()
        .find(|job| job.acceptance.attempt_id == owner.attempt_id)
        .context("retirement job missing")?;
    ensure!(
        work.request.kind() == Kind::Retirement
            && work.attempt.state.ownership() == Some(owner)
            && matches!(work.phase(), Phase::Starting | Phase::Running)
            && !job_deadline_expired(work, now),
        "retirement unavailable or expired"
    );
    let Work::Maintenance(request) = &work.request else {
        bail!("retirement intent differs")
    };
    let (attempt_id, spec_digest, acknowledgement, abandonment) = match &request.operation {
        Operation::RetireFailed {
            attempt_id,
            spec_digest,
        } => (attempt_id, spec_digest, None, None),
        Operation::RetireConsumed {
            attempt_id,
            spec_digest,
            acknowledgement,
        } => (attempt_id, spec_digest, Some(acknowledgement), None),
        Operation::RetireAbandoned {
            attempt_id,
            spec_digest,
            abandonment,
        } => (attempt_id, spec_digest, None, Some(abandonment)),
        Operation::CollectGarbage => bail!("retirement operation differs"),
    };
    let target = state
        .jobs
        .iter()
        .find(|job| job.acceptance.attempt_id == *attempt_id)
        .context("retirement target missing")?;
    eligible(target)?;
    match target.outcome() {
        Some(Outcome::Succeeded { .. }) => ensure!(
            match (&target.consumer_ack, &target.consumer_abandonment) {
                (Some(ack), None) => {
                    Some(ack.receipt.digest()?).as_ref() == acknowledgement && abandonment.is_none()
                }
                (None, Some(abandoned)) => {
                    Some(abandoned.statement.digest()?).as_ref() == abandonment
                        && acknowledgement.is_none()
                }
                _ => false,
            },
            "retirement consumer decision differs"
        ),
        _ => ensure!(
            acknowledgement.is_none() && abandonment.is_none(),
            "failed retirement carries a consumer decision"
        ),
    }
    ensure!(
        target.acceptance.spec_digest == *spec_digest
            && target
                .retirement
                .as_ref()
                .is_some_and(|record| record.attempt_id == owner.attempt_id
                    && record.owner.as_ref().is_none_or(|old| old == owner)
                    && !record.complete),
        "retirement target claimed or changed"
    );
    Ok(target)
}

/// Recheck the cleanup owner atomically with each effect receipt. A stale
/// pre-I/O timestamp or a lost/cancelled cleanup cannot publish retirement.
pub(super) fn effect_owner(state: &State, job: &Job, now: u64) -> Result<()> {
    if job.request.kind() == Kind::Build {
        let owner = job
            .retirement
            .as_ref()
            .and_then(|record| record.owner.as_ref())
            .context("Build retirement lacks admitted cleanup owner")?;
        let original = target(state, owner, now)?;
        ensure!(
            original.acceptance == job.acceptance
                && state
                    .jobs
                    .iter()
                    .any(|work| work.acceptance.attempt_id == owner.attempt_id
                        && work.phase() == Phase::Running),
            "retirement effect owner differs"
        );
    } else {
        ensure!(
            job.request.kind() == Kind::Maintenance && state.pool.owner.is_none(),
            "maintenance gate retirement while pool owned"
        );
    }
    Ok(())
}

impl Journal {
    /// Same queue, no fabricated Build inputs. One automatic cleanup intent per
    /// target; an uncertain/failed cleanup is retained, never blindly resubmitted.
    pub(in crate::build_executor) fn schedule_retirement(&self, now: u64) -> Result<()> {
        self.update_when(now, |state, now| {
            if !metadata_room(state.jobs.len().saturating_add(1), state.tombstones.len()) { return Ok(((), false)); }
            let candidate = state.jobs.iter().find(|job| eligible(job).is_ok() && job.retirement.is_none()
                && job.release_digest.is_none()
                && !state.jobs.iter().any(|other| matches!(&other.request, Work::Maintenance(request)
                    if matches!(&request.operation, Operation::RetireFailed { attempt_id, .. }
                        | Operation::RetireConsumed { attempt_id, .. }
                        | Operation::RetireAbandoned { attempt_id, .. } if *attempt_id == job.acceptance.attempt_id))));
            let Some(job) = candidate else { return Ok(((), false)); };
            let target_id = job.acceptance.attempt_id.clone();
            let operation = match (&job.consumer_ack, &job.consumer_abandonment) {
                (Some(ack), None) => Operation::RetireConsumed { attempt_id: target_id.clone(),
                    spec_digest: job.acceptance.spec_digest.clone(), acknowledgement: ack.receipt.digest()? },
                (None, Some(abandoned)) => Operation::RetireAbandoned { attempt_id: target_id.clone(),
                    spec_digest: job.acceptance.spec_digest.clone(), abandonment: abandoned.statement.digest()? },
                (None, None) => Operation::RetireFailed { attempt_id: target_id.clone(), spec_digest: job.acceptance.spec_digest.clone() },
                _ => bail!("conflicting consumer decisions"),
            };
            let nonce = crate::sha256::digest_bytes(&serde_json::to_vec(&(b"owned-retirement-v1", &job.acceptance))?);
            let request = Request { version: super::super::maintenance::VERSION,
                id: super::super::request::RequestId { issued_at: now, nonce }, storage: state.identity.clone(),
                policy_digest: state.policy.digest()?, deadlines: state.policy.deadlines.clone(), operation };
            // accept_work performs the same authority, conflict and capacity checks.
            let acceptance = accept_work(state, Work::Maintenance(Box::new(request)), now, false)?;
            job_mut(state, &target_id)?.retirement = Some(Record { attempt_id: acceptance.attempt_id, owner: None, complete: false });
            Ok(((), true))
        })
    }

    pub(in crate::build_executor) fn retirement_active(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<()> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let now = self.effective_time(now, state.last_time)?;
        target(&state, owner, now)?;
        Ok(())
    }

    pub(in crate::build_executor) fn begin_retirement(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<Target> {
        self.update(now, |state, now| {
            let job = target(state, owner, now)?;
            ensure!(
                job.retirement
                    .as_ref()
                    .is_some_and(|record| record.owner.is_none()),
                "retirement dispatch already consumed"
            );
            let evidence = release_evidence(job)?;
            let value = Target {
                attempt_id: job.acceptance.attempt_id.clone(),
                owner: job.attempt.state.ownership().cloned(),
                evidence,
                source: job.private_source.is_some(),
                native_phase: job.native_phase.is_some(),
                artifact: job.artifact.is_some(),
                successful: matches!(job.outcome(), Some(Outcome::Succeeded { .. })),
            };
            job_mut(state, &value.attempt_id)?
                .retirement
                .as_mut()
                .context("retirement intent missing")?
                .owner = Some(owner.clone());
            Ok(value)
        })
    }

    pub(in crate::build_executor) fn finish_retirement(
        &self,
        handle: &ExecutionHandle,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            let job = target(state, &handle.ownership, now)?;
            ensure!(
                job.release_digest.is_some()
                    && controller::retired(job)
                    && job
                        .private_source
                        .as_ref()
                        .is_none_or(|source| source.retired)
                    && job.native_phase.as_ref().is_none_or(|phase| phase.retired)
                    && job
                        .artifact
                        .as_ref()
                        .is_none_or(|artifact| artifact.retired)
                    && self.protection_retired(&job.acceptance.attempt_id)?,
                "retirement effects incomplete"
            );
            let key = job.acceptance.attempt_id.clone();
            let mut bytes = b"abird-owned-retirement-verification-v1\n".to_vec();
            bytes.extend(serde_json::to_vec(&(
                &job.acceptance,
                &job.retirement,
                &job.release_digest,
                handle,
            ))?);
            let verification_digest = crate::sha256::digest_bytes(&bytes);
            job_mut(state, &key)?
                .retirement
                .as_mut()
                .context("retirement claim missing")?
                .complete = true;
            let work = job_mut(state, &handle.ownership.attempt_id)?;
            ensure!(
                work.phase() == Phase::Running
                    && work.verified.is_none()
                    && work.attempt.state.execution()
                        == Some(super::super::Execution::Started {
                            handle: handle.clone()
                        }),
                "retirement verifier owner differs"
            );
            let verified = verification::Verified {
                handle: handle.clone(),
                outcome: Outcome::MaintenanceSucceeded {
                    verification_digest,
                },
                completed_at: now,
            };
            verified.validate(work, now)?;
            work.verified = Some(verified);
            Ok(())
        })
    }
}
