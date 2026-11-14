use super::*;
use crate::build_executor::native_intent::Request;

pub(super) const MAX_BYTES: usize = 512;

#[cfg(test)]
mod tests;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Resolution {
    request_digest: String,
    material_digest: String,
}

pub(super) fn validate(job: &Job) -> Result<()> {
    match (&job.request, &job.native_resolution) {
        (Work::Build(request), Some(binding)) => {
            ensure!(
                request.parent.is_some()
                    && binding.request_digest == request.binding_digest()?
                    && job.reserved_at.is_some()
                    && job
                        .private_source
                        .as_ref()
                        .is_some_and(|source| source.directory.is_some()),
                "native resolution lacks original admission/source binding"
            );
            digest(&binding.material_digest)?;
            ensure!(
                serde_json::to_vec(binding)?.len() <= MAX_BYTES,
                "native resolution exceeds reservation"
            );
        }
        (Work::Build(request), None) => ensure!(
            request.parent.is_none(),
            "native resolution receipt missing"
        ),
        (Work::Native(_), None) => ensure!(
            job.prepared.is_none() && job.verified.is_none() && job.artifact.is_none(),
            "unresolved native work has prepared artifacts"
        ),
        (Work::Maintenance(_), None) => {}
        _ => bail!("native resolution kind differs"),
    }
    Ok(())
}

impl Journal {
    pub fn submit_native(&self, issuer: &str, request: Request, now: u64) -> Result<Acceptance> {
        request.validate().context(Rejection::InvalidRequest)?;
        ensure!(request.issuer == issuer, Rejection::Unauthorized);
        self.submit_work(Work::Native(Box::new(request)), now)
    }

    pub fn withdraw_native(&self, issuer: &str, request: Request, now: u64) -> Result<Acceptance> {
        request.validate().context(Rejection::InvalidRequest)?;
        ensure!(request.issuer == issuer, Rejection::Unauthorized);
        self.withdraw_work(Work::Native(Box::new(request)), now)
    }

    /// Only after the fixed installed helper validates native capture semantics.
    /// No public bind RPC. No new owner, acceptance, deadline, permit or dispatch.
    pub(in crate::build_executor) fn bind_native(
        &self,
        owner: &Ownership,
        request: BuildRequest,
        material_digest: String,
        now: u64,
    ) -> Result<()> {
        request.validate()?;
        digest(&material_digest)?;
        let binding = Resolution {
            request_digest: request.binding_digest()?,
            material_digest,
        };
        ensure!(
            serde_json::to_vec(&binding)?.len() <= MAX_BYTES,
            "native resolution exceeds reservation"
        );
        self.update(now, |state, now| {
            let job = sources::active(state, owner, now)?;
            let Work::Native(original) = &job.request else {
                bail!("native resolution already consumed or unavailable");
            };
            original.validate_resolution(&request)?;
            ensure!(
                job.native_resolution.is_none()
                    && job.prepared.is_none()
                    && job
                        .private_source
                        .as_ref()
                        .is_some_and(|source| source.directory.is_some())
                    && job
                        .native_phase
                        .as_ref()
                        .is_some_and(|phase| phase.file.is_some()
                            && phase.sealed_at.is_none()
                            && !phase.retired),
                "native resolution outside original source phase"
            );
            let job = job_mut(state, &owner.attempt_id)?;
            job.request = Work::Build(Box::new(request));
            job.native_resolution = Some(binding);
            Ok(())
        })
    }
}
