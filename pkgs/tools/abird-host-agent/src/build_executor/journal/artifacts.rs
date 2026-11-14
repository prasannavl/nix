//! Bounded artifact sidecar intent. Payload is outside the control-lane ledger;
//! publication, native verification, settlement and release remain distinct.

use super::*;

pub(super) const MAX_BYTES: usize = 512;
// ACK and abandonment are mutually exclusive and share this reservation.
pub(super) const ACK_BYTES: usize = 2048;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Acknowledged {
    pub(super) receipt: crate::build_executor::ConsumerAck,
    received_at: u64,
}

impl Acknowledged {
    pub(super) fn validate(&self, job: &Job, now: u64) -> Result<()> {
        self.receipt.validate()?;
        settled_consumer(
            job,
            &self.receipt.ownership,
            &self.receipt.artifacts,
            &self.receipt.consumer,
            self.received_at,
            now,
        )?;
        ensure!(
            serde_json::to_vec(self)?.len() <= ACK_BYTES,
            "consumer acknowledgement exceeds reservation"
        );
        Ok(())
    }
}

// Neither consumer decision may manufacture success or positive settlement.
pub(super) fn settled_consumer(
    job: &Job,
    owner: &Ownership,
    artifacts: &ArtifactReceipt,
    consumer: &crate::build_executor::request::Peer,
    received_at: u64,
    now: u64,
) -> Result<()> {
    ensure!(
        job.request.kind() == Kind::Build
            && job.request.build()?.controller == *consumer
            && job.attempt.state.ownership() == Some(owner)
            && job.settled_at.is_some_and(|at| at <= received_at)
            && received_at <= now
            && matches!(job.outcome(), Some(Outcome::Succeeded { artifacts: accepted })
                if accepted == *artifacts)
            && matches!(
                job.attempt.state,
                super::super::State::Finished {
                    settlement: Settlement::FencedEmpty { .. } | Settlement::Rebooted { .. },
                    ..
                }
            )
            && job
                .artifact
                .as_ref()
                .is_some_and(|publication| publication.file.is_some()
                    && publication.projection.is_some()
                    && publication.digest == artifacts.closure_digest)
            && job
                .native_phase
                .as_ref()
                .is_some_and(|phase| phase.writers_settled_at.is_some()),
        "consumer decision lacks matching verified and positively settled Build"
    );
    Ok(())
}

impl Journal {
    /// Read-only acknowledgement/release state. No renewal, acquisition,
    /// retirement dispatch or inference from missing/replaced data.
    pub fn consumer_status(
        &self,
        issuer: &str,
        key: &str,
    ) -> Result<Option<crate::build_executor::protocol::ConsumerState>> {
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
                .consumer_ack
                .as_ref()
                .map(|ack| {
                    Ok(crate::build_executor::protocol::ConsumerState {
                        receipt_digest: ack.receipt.digest()?,
                        release_digest: job.release_digest.clone(),
                        retired: retirement::completed(&state, job),
                    })
                })
                .transpose();
        }
        let tombstone = state
            .tombstones
            .iter()
            .find(|tombstone| {
                !tombstone.maintenance
                    && tombstone.issuer == issuer
                    && tombstone.acceptance.attempt_id == key
            })
            .context(Rejection::NotFound)?;
        Ok(tombstone.consumer_ack.as_ref().map(|digest| {
            crate::build_executor::protocol::ConsumerState {
                receipt_digest: digest.clone(),
                release_digest: tombstone.consumer_release.clone(),
                retired: true,
            }
        }))
    }

    /// Same authenticated issuer that owns the accepted request. The consumer
    /// first persists its signed-acquisition and retention receipts, then sends
    /// this immutable statement. It does not settle/release anything here.
    pub fn acknowledge_consumer(
        &self,
        issuer: &str,
        receipt: crate::build_executor::ConsumerAck,
        now: u64,
    ) -> Result<String> {
        receipt.validate().map_err(|_| Rejection::InvalidRequest)?;
        let key = receipt.ownership.attempt_id.clone();
        let digest = receipt.digest()?;
        self.update_when(now, |state, now| {
            let Some(job) = state
                .jobs
                .iter_mut()
                .find(|job| job.acceptance.attempt_id == key)
            else {
                let tombstone = state
                    .tombstones
                    .iter()
                    .find(|tombstone| {
                        !tombstone.maintenance
                            && tombstone.issuer == issuer
                            && tombstone.acceptance.attempt_id == key
                    })
                    .context(Rejection::NotFound)?;
                ensure!(
                    tombstone.consumer_ack.as_ref() == Some(&digest),
                    Rejection::Conflict
                );
                return Ok((digest, false));
            };
            ensure!(
                job.request.kind() == Kind::Build && job.request.issuer() == issuer,
                Rejection::NotFound
            );
            ensure!(job.consumer_abandonment.is_none(), Rejection::Conflict);
            if let Some(previous) = &job.consumer_ack {
                ensure!(previous.receipt == receipt, Rejection::Conflict);
                return Ok((digest, false));
            }
            ensure!(
                job.release_digest.is_none() && job.retirement.is_none(),
                Rejection::InvalidTransition
            );
            let ack = Acknowledged {
                receipt,
                received_at: now,
            };
            ack.validate(job, now)
                .map_err(|_| Rejection::InvalidTransition)?;
            job.events.push(
                EventKind::ConsumerAcknowledged {
                    digest: digest.clone(),
                },
                now,
            )?;
            job.consumer_ack = Some(ack);
            Ok((digest, true))
        })
    }
}

/// Bounded public suffix of the existing private artifact file. Its prefix is
/// derived only from the immutable owner, preparation and verified receipt.
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(in crate::build_executor) struct Projection {
    pub digest: String,
    pub offset: u64,
    pub bytes: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub planning: Option<PlanningRange>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(in crate::build_executor) struct PlanningRange {
    pub offset: u64,
    pub bytes: u64,
}

impl Projection {
    pub(in crate::build_executor) fn validate(&self, file_bytes: u64) -> Result<()> {
        digest(&self.digest)?;
        if let Some(planning) = &self.planning {
            ensure!(
                planning.offset > 0
                    && planning.bytes > 0
                    && planning.bytes <= super::super::preparation::MAX_PREPARED_BYTES as u64
                    && planning
                        .offset
                        .checked_add(planning.bytes)
                        .is_some_and(|end| end < self.offset),
                "private planning range differs"
            );
        }
        ensure!(
            self.offset > 0
                && self.offset < file_bytes
                && self.bytes > file_bytes - self.offset
                && self.bytes <= super::super::artifacts::MAX_BYTES as u64
                && self.bytes - (file_bytes - self.offset)
                    <= (super::super::preparation::MAX_PREPARED_BYTES + 2048) as u64,
            "invalid artifact projection"
        );
        Ok(())
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(in crate::build_executor) struct Publication {
    pub digest: String,
    pub bytes: u64,
    pub file: Option<native_phase::FileId>,
    pub retired: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub projection: Option<Projection>,
}

impl Publication {
    pub(super) fn validate(&self, job: &Job) -> Result<()> {
        digest(&self.digest)?;
        if let Some(projection) = &self.projection {
            ensure!(
                self.file.is_some(),
                "artifact projection precedes publication"
            );
            projection.validate(self.bytes)?;
            ensure!(
                projection.planning.is_some()
                    == job
                        .prepared
                        .as_ref()
                        .is_some_and(|prepared| prepared.inputs.planning_digest.is_some()),
                "private planning projection differs"
            );
        }
        ensure!(
            self.bytes > 0
                && self.bytes <= super::super::artifacts::MAX_BYTES as u64
                && self.file.as_ref().is_none_or(|id| id.inode > 0),
            "invalid artifact publication"
        );
        ensure!(
            job.request.kind() == Kind::Build
                && job.prepared.is_some()
                && job
                    .native_phase
                    .as_ref()
                    .is_some_and(|phase| phase.writers_settled_at.is_some())
                && job.attempt.state.ownership().is_some(),
            "artifact publication before verified inputs/seal"
        );
        ensure!(
            !self.retired || (job.outcome().is_some() && job.release_digest.is_some()),
            "artifact retirement before settled release"
        );
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_BYTES,
            "artifact intent exceeds reservation"
        );
        Ok(())
    }
}

impl Journal {
    pub(in crate::build_executor) fn begin_artifact(
        &self,
        owner: &Ownership,
        hash: &str,
        bytes: u64,
        now: u64,
    ) -> Result<()> {
        digest(hash)?;
        self.update(now, |state, now| {
            ensure!(
                daemon::eligible(state, now)? == owner,
                "artifact owner differs"
            );
            let job = job_mut(state, &owner.attempt_id)?;
            ensure!(
                job.phase() == Phase::Running && job.artifact.is_none() && job.verified.is_none(),
                "artifact publication already claimed or unavailable"
            );
            let artifact = Publication {
                digest: hash.to_owned(),
                bytes,
                file: None,
                retired: false,
                projection: None,
            };
            artifact.validate(job)?;
            job.artifact = Some(artifact);
            Ok(())
        })
    }

    pub(in crate::build_executor) fn bind_artifact(
        &self,
        owner: &Ownership,
        device: u64,
        inode: u64,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            ensure!(
                daemon::eligible(state, now)? == owner,
                "artifact owner differs"
            );
            let job = job_mut(state, &owner.attempt_id)?;
            ensure!(
                job.phase() == Phase::Running && job.verified.is_none(),
                "artifact owner no longer running"
            );
            let record = job.artifact.as_mut().context("artifact intent missing")?;
            ensure!(
                record.file.is_none() && !record.retired,
                "artifact already bound or retired"
            );
            record.file = Some(native_phase::FileId { device, inode });
            Ok(())
        })
    }

    pub(in crate::build_executor) fn bind_artifact_projection(
        &self,
        owner: &Ownership,
        projection: Projection,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            ensure!(
                daemon::eligible(state, now)? == owner,
                "artifact owner differs"
            );
            let job = job_mut(state, &owner.attempt_id)?;
            ensure!(
                job.phase() == Phase::Running && job.verified.is_none(),
                "artifact owner no longer running"
            );
            let record = job.artifact.as_mut().context("artifact intent missing")?;
            ensure!(
                record.file.is_some() && record.projection.is_none() && !record.retired,
                "artifact projection already claimed or unavailable"
            );
            projection.validate(record.bytes)?;
            record.projection = Some(projection);
            Ok(())
        })
    }

    pub fn artifact_page(
        &self,
        issuer: &str,
        key: &str,
        artifact_digest: &str,
        offset: u64,
    ) -> Result<super::super::ArtifactPage> {
        self.delivery_page(
            issuer,
            key,
            artifact_digest,
            super::super::artifacts::Delivery::Public(offset),
        )
    }

    /// Private evaluated metadata, only for the original authenticated issuer.
    /// Never part of the public closure projection or deployment authorization.
    pub fn planning_page(
        &self,
        issuer: &str,
        key: &str,
        artifact_digest: &str,
        planning_digest: &str,
        offset: u64,
    ) -> Result<super::super::ArtifactPage> {
        let page = self.delivery_page(
            issuer,
            key,
            artifact_digest,
            super::super::artifacts::Delivery::Planning(offset),
        )?;
        ensure!(
            page.projection_digest == planning_digest,
            Rejection::Conflict
        );
        Ok(page)
    }

    fn delivery_page(
        &self,
        issuer: &str,
        key: &str,
        artifact_digest: &str,
        delivery: super::super::artifacts::Delivery,
    ) -> Result<super::super::ArtifactPage> {
        digest(key)?;
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let job = state
            .jobs
            .iter()
            .find(|job| job.acceptance.attempt_id == key)
            .context(Rejection::NotFound)?;
        ensure!(
            job.request.kind() == Kind::Build && job.request.issuer() == issuer,
            Rejection::NotFound
        );
        ensure!(
            job.settled_at.is_some()
                && job.release_digest.is_none()
                && job.retirement.is_none()
                && job.consumer_abandonment.is_none(),
            Rejection::InvalidTransition
        );
        let Some(Outcome::Succeeded { artifacts }) = job.outcome() else {
            bail!(Rejection::InvalidTransition);
        };
        ensure!(
            artifacts.closure_digest == artifact_digest,
            Rejection::Conflict
        );
        let owner = job
            .attempt
            .state
            .ownership()
            .context("artifact owner missing")?;
        let publication = job
            .artifact
            .as_ref()
            .context("artifact publication missing")?;
        let prepared = job
            .prepared
            .as_ref()
            .context("artifact preparation missing")?;
        let page = super::super::artifacts::read_page(
            &directory,
            owner,
            &artifacts,
            &prepared.inputs,
            publication,
            delivery,
        )?;
        let current = open_directory(&self.root)?.metadata()?;
        ensure!(
            current.dev() == self.device
                && current.ino() == self.inode
                && fs::canonicalize(&self.root)? == self.root,
            "artifact authority replaced"
        );
        Ok(page)
    }

    pub(in crate::build_executor) fn artifact(&self, owner: &Ownership) -> Result<Publication> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let job = state
            .jobs
            .iter()
            .find(|job| job.acceptance.attempt_id == owner.attempt_id)
            .context("artifact attempt missing")?;
        ensure!(
            job.attempt.state.ownership() == Some(owner),
            "artifact owner differs"
        );
        job.artifact.clone().context("artifact publication missing")
    }

    pub(in crate::build_executor) fn artifact_releasable(&self, owner: &Ownership) -> Result<()> {
        // Build-only root/handoff context; public status/exit0 is not release.
        let (_, settled, released) = self.protection_context(owner)?;
        ensure!(
            settled && released.is_some(),
            "artifact not settled/released"
        );
        Ok(())
    }

    pub(in crate::build_executor) fn retire_artifact(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            let original = state
                .jobs
                .iter()
                .find(|job| job.acceptance.attempt_id == owner.attempt_id)
                .context("artifact retirement target missing")?;
            retirement::effect_owner(state, original, now)?;
            let job = job_mut(state, &owner.attempt_id)?;
            ensure!(
                job.attempt.state.ownership() == Some(owner)
                    && job.outcome().is_some()
                    && job.release_digest.is_some(),
                "artifact not settled/released"
            );
            let artifact = job.artifact.as_mut().context("artifact intent missing")?;
            ensure!(
                !artifact.retired,
                "artifact retirement receipt already consumed"
            );
            artifact.retired = true;
            Ok(())
        })
    }
}
