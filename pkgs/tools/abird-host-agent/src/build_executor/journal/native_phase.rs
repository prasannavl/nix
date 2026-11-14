//! Durable native producer gate intent/binding; never caller-controlled.

use super::*;

pub(super) const MAX_BYTES: usize = 512;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(in crate::build_executor) struct NativePhase {
    pub file: Option<FileId>,
    pub runtime: Option<super::super::native_phase::Runtime>,
    /// Intent precedes the monotonic byte update. Not producer settlement.
    pub sealed_at: Option<u64>,
    pub writers_settled_at: Option<u64>,
    pub retired: bool,
}

#[derive(Clone, Deserialize, Serialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
pub(in crate::build_executor) struct FileId {
    pub device: u64,
    pub inode: u64,
}

impl NativePhase {
    pub(super) fn validate(&self, job: &Job, now: u64) -> Result<()> {
        ensure!(
            job.request.kind() != Kind::Retirement,
            "retirement cannot own native phase"
        );
        ensure!(
            self.file.as_ref().is_none_or(|file| file.inode > 0),
            "invalid native file identity"
        );
        if let Some(runtime) = &self.runtime {
            runtime.validate()?;
            ensure!(
                self.file.is_some() && job.daemon_claim.is_some(),
                "native runtime without daemon claim"
            );
        }
        ensure!(
            !matches!(
                job.phase(),
                Phase::Pending | Phase::Queued | Phase::Starting
            ),
            "native phase before worker claim"
        );
        ensure!(
            job.reserved_at.is_some() && job.attempt.state.ownership().is_some(),
            "native phase without ownership"
        );
        ensure!(
            self.sealed_at.is_none_or(|time| self.file.is_some()
                && job.reserved_at.is_some_and(|reserved| reserved <= time)
                && time <= now),
            "invalid native seal intent"
        );
        ensure!(
            self.writers_settled_at
                .is_none_or(|time| self.runtime.is_some()
                    && self.sealed_at.is_some_and(|sealed| sealed <= time)
                    && time <= now),
            "native writer settlement without runtime/seal"
        );
        ensure!(
            !self.retired || (job.outcome().is_some() && job.release_digest.is_some()),
            "native phase retired before release"
        );
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_BYTES,
            "native phase exceeds reservation"
        );
        Ok(())
    }
}

impl Journal {
    pub(in crate::build_executor) fn register_native_phase(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            ensure!(
                daemon::eligible(state, now)? == owner,
                "native phase owner differs"
            );
            let job = job_mut(state, &owner.attempt_id)?;
            ensure!(
                job.phase() == Phase::Running
                    && job.native_phase.is_none()
                    && job.daemon_claim.is_none(),
                "native phase already claimed or unavailable"
            );
            job.native_phase = Some(NativePhase {
                file: None,
                runtime: None,
                sealed_at: None,
                writers_settled_at: None,
                retired: false,
            });
            Ok(())
        })
    }

    pub(in crate::build_executor) fn bind_native_phase(
        &self,
        owner: &Ownership,
        file: FileId,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            ensure!(
                daemon::eligible(state, now)? == owner,
                "native phase owner differs"
            );
            let job = job_mut(state, &owner.attempt_id)?;
            let phase = job
                .native_phase
                .as_mut()
                .context("native phase intent missing")?;
            ensure!(
                phase.file.is_none() && !phase.retired && job.daemon_claim.is_none(),
                "native phase already bound or consumed"
            );
            phase.file = Some(file);
            Ok(())
        })
    }

    pub(in crate::build_executor) fn bind_native_runtime(
        &self,
        owner: &Ownership,
        runtime: super::super::native_phase::Runtime,
        now: u64,
    ) -> Result<()> {
        runtime.validate()?;
        self.update(now, |state, now| {
            ensure!(
                daemon::eligible(state, now)? == owner,
                "native runtime owner differs"
            );
            let job = job_mut(state, &owner.attempt_id)?;
            ensure!(
                job.daemon_claim.is_some(),
                "native runtime lacks daemon claim"
            );
            let phase = job
                .native_phase
                .as_mut()
                .context("native phase intent missing")?;
            ensure!(
                phase.file.is_some()
                    && phase.runtime.is_none()
                    && phase.sealed_at.is_none()
                    && !phase.retired,
                "native runtime already bound or unavailable"
            );
            phase.runtime = Some(runtime);
            Ok(())
        })
    }

    pub(in crate::build_executor) fn native_phase(&self, owner: &Ownership) -> Result<NativePhase> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let job = state
            .jobs
            .iter()
            .find(|job| job.acceptance.attempt_id == owner.attempt_id)
            .context("native phase attempt missing")?;
        ensure!(
            job.attempt.state.ownership() == Some(owner),
            "native phase owner differs"
        );
        job.native_phase
            .clone()
            .context("native phase intent missing")
    }

    pub(in crate::build_executor) fn seal_native_phase(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            ensure!(
                daemon::eligible(state, now)? == owner,
                "native seal owner differs"
            );
            let job = job_mut(state, &owner.attempt_id)?;
            let phase = job
                .native_phase
                .as_mut()
                .context("native phase intent missing")?;
            ensure!(
                phase.file.is_some() && !phase.retired,
                "native phase unavailable"
            );
            if phase.sealed_at.is_none() {
                phase.sealed_at = Some(now);
            }
            Ok(())
        })
    }

    pub(in crate::build_executor) fn settle_native_writers(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            ensure!(
                daemon::eligible(state, now)? == owner,
                "native settlement owner differs"
            );
            let job = job_mut(state, &owner.attempt_id)?;
            let phase = job
                .native_phase
                .as_mut()
                .context("native phase intent missing")?;
            ensure!(
                phase.runtime.is_some()
                    && phase.sealed_at.is_some()
                    && phase.writers_settled_at.is_none()
                    && !phase.retired,
                "native writer settlement already consumed or unavailable"
            );
            phase.writers_settled_at = Some(now);
            Ok(())
        })
    }

    pub(in crate::build_executor) fn native_phase_releasable(
        &self,
        owner: &Ownership,
    ) -> Result<()> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let job = state
            .jobs
            .iter()
            .find(|job| job.acceptance.attempt_id == owner.attempt_id)
            .context("native phase attempt missing")?;
        ensure!(
            job.attempt.state.ownership() == Some(owner)
                && job.outcome().is_some()
                && job.release_digest.is_some(),
            "native phase not settled/released"
        );
        Ok(())
    }

    pub(in crate::build_executor) fn retire_native_phase(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            let original = state
                .jobs
                .iter()
                .find(|job| job.acceptance.attempt_id == owner.attempt_id)
                .context("native gate retirement target missing")?;
            retirement::effect_owner(state, original, now)?;
            let job = job_mut(state, &owner.attempt_id)?;
            ensure!(
                job.attempt.state.ownership() == Some(owner)
                    && job.outcome().is_some()
                    && job.release_digest.is_some(),
                "native phase not settled/released"
            );
            let phase = job
                .native_phase
                .as_mut()
                .context("native phase intent missing")?;
            ensure!(!phase.retired, "native retirement receipt already consumed");
            phase.retired = true;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests;
