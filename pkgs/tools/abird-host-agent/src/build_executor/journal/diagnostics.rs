use super::*;
use crate::build_executor::diagnostics::{Diagnostic, Observation};
use crate::build_executor::events::{LogCursor, LogPage, LogWindow};

#[cfg(test)]
mod tests;

impl Journal {
    pub(in crate::build_executor) fn record_diagnostic(
        &self,
        handle: &ExecutionHandle,
        diagnostic: Diagnostic,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            ensure!(
                state.pool.owner.as_ref() == Some(&handle.ownership),
                "diagnostic owner differs"
            );
            let health = state.pool.health;
            let job = job_mut(state, &handle.ownership.attempt_id)?;
            ensure!(
                job.attempt.state.execution()
                    == Some(super::super::Execution::Started {
                        handle: handle.clone()
                    })
                    && job.outcome().is_none(),
                "diagnostic execution differs"
            );
            if diagnostic.observation == Observation::Entered {
                ensure!(
                    health == PoolHealth::Owned
                        && job.phase() == Phase::Running
                        && !job_deadline_expired(job, now)
                        && (!job.request.foreground()
                            || now.saturating_sub(job.renewed_at)
                                < job.request.deadlines().owner_seconds),
                    "diagnostic activity is outside original lifetime"
                );
            }
            // Returns/errors may race cancellation or expiry. Recording them is
            // observation only: no renewal, execution grant or outcome change.
            job.events.push(EventKind::Diagnostic { diagnostic }, now)
        })
    }

    pub fn logs(
        &self,
        issuer: &str,
        key: &str,
        cursor: Option<&LogCursor>,
        limit: usize,
    ) -> Result<LogPage> {
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
            return job.events.logs(key, cursor, limit, job.outcome().is_some());
        }
        let retired = state
            .tombstones
            .iter()
            .find(|row| {
                !row.maintenance && row.acceptance.attempt_id == key && row.issuer == issuer
            })
            .ok_or(Rejection::NotFound)?;
        // Pruning explicitly drops the retained history. Keep the byte tail so
        // reconnect reports a gap rather than inventing an empty successful log.
        LogWindow {
            attempt_id: key,
            generation: super::super::events::LOG_GENERATION,
            base: retired
                .last_event
                .checked_mul(super::super::events::LOG_RECORD_BYTES as u64)
                .ok_or(Rejection::InvalidCursor)?,
            bytes: &[],
            sealed: true,
        }
        .page(cursor, limit)
    }
}
