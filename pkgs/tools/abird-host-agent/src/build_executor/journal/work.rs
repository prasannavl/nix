//! One queue/owner/reducer. Native commands resolve within their original Build
//! lifetime; Maintenance is never represented by fabricated build inputs.

use super::*;
use crate::build_executor::maintenance;
use crate::build_executor::request::{Deadlines, RequestId};

#[derive(Clone, Copy, Eq, PartialEq)]
pub(in crate::build_executor) enum Kind {
    Build,
    Maintenance,
    Retirement,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(
    tag = "kind",
    content = "request",
    rename_all = "snake_case",
    deny_unknown_fields
)]
pub(in crate::build_executor) enum Work {
    Native(Box<crate::build_executor::native_intent::Request>),
    Build(Box<BuildRequest>),
    Maintenance(Box<maintenance::Request>),
}

impl Journal {
    /// Observation only; valid during drain as well as launch.
    pub(in crate::build_executor) fn retirement_operation(
        &self,
        owner: &Ownership,
    ) -> Result<bool> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        ensure!(
            state.pool.owner.as_ref() == Some(owner),
            "retirement observation owner differs"
        );
        let job = state
            .jobs
            .iter()
            .find(|job| job.acceptance.attempt_id == owner.attempt_id)
            .context("retirement observation missing")?;
        Ok(job.request.kind() == Kind::Retirement)
    }

    pub(in crate::build_executor) fn work_kind(&self, owner: &Ownership, now: u64) -> Result<Kind> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let now = self.effective_time(now, state.last_time)?;
        ensure!(
            state.pool.health == PoolHealth::Owned && state.pool.owner.as_ref() == Some(owner),
            "worker ownership differs"
        );
        let job = state
            .jobs
            .iter()
            .find(|job| job.acceptance.attempt_id == owner.attempt_id)
            .context("worker attempt missing")?;
        ensure!(
            job.phase() == Phase::Starting
                && job.attempt.state.ownership() == Some(owner)
                && !job_deadline_expired(job, now),
            "worker already started or expired"
        );
        Ok(job.request.kind())
    }
}

impl Work {
    pub(in crate::build_executor) fn kind(&self) -> Kind {
        match self {
            Self::Build(_) | Self::Native(_) => Kind::Build,
            Self::Maintenance(request) => match request.operation {
                maintenance::Operation::CollectGarbage => Kind::Maintenance,
                maintenance::Operation::RetireFailed { .. }
                | maintenance::Operation::RetireConsumed { .. }
                | maintenance::Operation::RetireAbandoned { .. } => Kind::Retirement,
            },
        }
    }

    pub(super) fn native(&self) -> Option<&crate::build_executor::native_intent::Request> {
        match self {
            Self::Native(request) => Some(request),
            Self::Build(request) => request.parent.as_deref(),
            Self::Maintenance(_) => None,
        }
    }

    pub(in crate::build_executor) fn build(&self) -> Result<&BuildRequest> {
        match self {
            Self::Build(request) => Ok(request),
            _ => Err(Rejection::NotFound.into()),
        }
    }

    pub(super) fn into_build(self) -> Result<Option<Box<BuildRequest>>> {
        match self {
            Self::Build(request) => Ok(Some(request)),
            Self::Native(_) => Ok(None),
            Self::Maintenance(_) => Err(Rejection::NotFound.into()),
        }
    }

    pub(in crate::build_executor) fn issuer(&self) -> &str {
        match self {
            Self::Build(request) => &request.issuer,
            Self::Native(request) => &request.issuer,
            Self::Maintenance(_) => "owned-maintenance",
        }
    }

    pub(super) fn id(&self) -> &RequestId {
        match self {
            Self::Build(request) => &request.id,
            Self::Native(request) => &request.id,
            Self::Maintenance(request) => &request.id,
        }
    }

    pub(in crate::build_executor) fn deadlines(&self) -> &Deadlines {
        match self {
            Self::Build(request) => &request.deadlines,
            Self::Native(request) => &request.deadlines,
            Self::Maintenance(request) => &request.deadlines,
        }
    }

    pub(super) fn foreground(&self) -> bool {
        self.owner()
            .is_ok_and(|owner| matches!(owner, Owner::Foreground { .. }))
    }

    pub(super) fn owner(&self) -> Result<&Owner> {
        match self {
            Self::Build(request) => Ok(&request.owner),
            Self::Native(request) => Ok(&request.owner),
            Self::Maintenance(_) => Err(Rejection::NotFound.into()),
        }
    }

    pub(in crate::build_executor) fn repository_id(&self) -> Result<&str> {
        match self {
            Self::Build(request) => Ok(&request.repository_id),
            Self::Native(request) => Ok(&request.repository_id),
            Self::Maintenance(_) => Err(Rejection::NotFound.into()),
        }
    }

    pub(super) fn validate(&self) -> Result<()> {
        match self {
            Self::Build(request) => request.validate(),
            Self::Native(request) => request.validate(),
            Self::Maintenance(request) => request.validate(),
        }
    }

    pub(super) fn authority(
        &self,
        identity: &StorageIdentity,
        policy: &AdmissionPolicy,
    ) -> Result<()> {
        let (storage, policy_digest) = match self {
            Self::Native(request) => return request.authority(identity, policy),
            Self::Build(request) => {
                ensure!(
                    request.nix.max_jobs <= policy.max_jobs
                        && request.nix.cores <= policy.max_cores,
                    Rejection::PolicyMismatch
                );
                (&request.storage, &request.policy_digest)
            }
            Self::Maintenance(request) => (&request.storage, &request.policy_digest),
        };
        ensure!(
            storage == identity
                && *policy_digest == policy.digest()?
                && self.deadlines() == &policy.deadlines,
            Rejection::PolicyMismatch
        );
        Ok(())
    }

    pub(in crate::build_executor) fn attempt_id(&self) -> Result<String> {
        match self {
            Self::Build(request) => request.attempt_id(),
            Self::Native(request) => request.attempt_id(),
            Self::Maintenance(request) => request.attempt_id(),
        }
    }

    pub(in crate::build_executor) fn digest(&self) -> Result<String> {
        match self {
            Self::Build(request) => request.digest(),
            Self::Native(request) => request.digest(),
            Self::Maintenance(request) => request.digest(),
        }
    }
}
