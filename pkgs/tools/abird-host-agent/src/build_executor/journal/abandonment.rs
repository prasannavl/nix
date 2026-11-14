//! Authenticated decision to forgo an unconsumed success. Never a consumer ACK,
//! immediate root release or settlement. Cleanup uses the existing admitted lane.

use super::*;
use crate::build_executor::ConsumerAbandonment;
use crate::build_executor::protocol::AbandonmentState;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Abandoned {
    pub(super) statement: ConsumerAbandonment,
    received_at: u64,
}

impl Abandoned {
    pub(super) fn validate(&self, job: &Job, now: u64) -> Result<()> {
        self.statement.validate()?;
        artifacts::settled_consumer(
            job,
            &self.statement.ownership,
            &self.statement.artifacts,
            &self.statement.consumer,
            self.received_at,
            now,
        )?;
        ensure!(
            serde_json::to_vec(self)?.len() <= artifacts::ACK_BYTES,
            "consumer abandonment exceeds reservation"
        );
        Ok(())
    }
}

impl Journal {
    /// Original issuer only. Atomically excludes every ACK, including one whose
    /// reply was lost. Caller must persist this exact decision before sending and
    /// confirm it before discarding local roots. No retry with another binding.
    pub fn abandon_consumer(
        &self,
        issuer: &str,
        statement: ConsumerAbandonment,
        now: u64,
    ) -> Result<String> {
        statement
            .validate()
            .map_err(|_| Rejection::InvalidRequest)?;
        let key = statement.ownership.attempt_id.clone();
        let digest = statement.digest()?;
        self.update_when(now, |state, now| {
            let Some(job) = state
                .jobs
                .iter_mut()
                .find(|job| job.acceptance.attempt_id == key)
            else {
                let tombstone = state
                    .tombstones
                    .iter()
                    .find(|entry| {
                        !entry.maintenance
                            && entry.issuer == issuer
                            && entry.acceptance.attempt_id == key
                    })
                    .context(Rejection::NotFound)?;
                ensure!(
                    tombstone.consumer_abandonment.as_ref() == Some(&digest),
                    Rejection::Conflict
                );
                return Ok((digest, false));
            };
            ensure!(
                job.request.kind() == Kind::Build && job.request.issuer() == issuer,
                Rejection::NotFound
            );
            ensure!(job.consumer_ack.is_none(), Rejection::Conflict);
            if let Some(previous) = &job.consumer_abandonment {
                ensure!(previous.statement == statement, Rejection::Conflict);
                return Ok((digest, false));
            }
            ensure!(
                job.release_digest.is_none() && job.retirement.is_none(),
                Rejection::InvalidTransition
            );
            let abandoned = Abandoned {
                statement,
                received_at: now,
            };
            abandoned
                .validate(job, now)
                .map_err(|_| Rejection::InvalidTransition)?;
            job.events.push(
                EventKind::ConsumerAbandoned {
                    digest: digest.clone(),
                },
                now,
            )?;
            job.consumer_abandonment = Some(abandoned);
            Ok((digest, true))
        })
    }

    /// Distinct from ACK status: abandonment never asserts consumer protection.
    pub fn consumer_abandonment_status(
        &self,
        issuer: &str,
        key: &str,
    ) -> Result<Option<AbandonmentState>> {
        digest(key)?;
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        if let Some(job) = state
            .jobs
            .iter()
            .find(|job| job.acceptance.attempt_id == key)
        {
            ensure!(
                job.request.kind() == Kind::Build && job.request.issuer() == issuer,
                Rejection::NotFound
            );
            return job
                .consumer_abandonment
                .as_ref()
                .map(|abandoned| {
                    Ok(AbandonmentState {
                        abandonment_digest: abandoned.statement.digest()?,
                        release_digest: job.release_digest.clone(),
                        retired: retirement::completed(&state, job),
                    })
                })
                .transpose();
        }
        let tombstone = state
            .tombstones
            .iter()
            .find(|entry| {
                !entry.maintenance && entry.issuer == issuer && entry.acceptance.attempt_id == key
            })
            .context(Rejection::NotFound)?;
        Ok(tombstone
            .consumer_abandonment
            .as_ref()
            .map(|digest| AbandonmentState {
                abandonment_digest: digest.clone(),
                release_digest: tombstone.consumer_release.clone(),
                retired: true,
            }))
    }
}
