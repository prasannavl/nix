//! Original caller-side source lifetime; no source bytes, rediscovery or replay.

use abird_host_agent::build_executor::{
    Ownership,
    capture_role::{Begin, Phase, Status},
};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::{Child, Intent, Manifest, Run};
use crate::fleet::build_backend::agent::{
    control::transport::Transport, controller::CaptureClaim, remote_capture,
};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Source {
    ownership: Ownership,
    reserved_at: u64,
    status: Option<Status>,
    acknowledged: bool,
}

impl Source {
    pub(super) fn new(claim: &CaptureClaim) -> Self {
        Self {
            ownership: claim.ownership.clone(),
            reserved_at: claim.reserved_at,
            status: None,
            acknowledged: false,
        }
    }

    pub(super) fn claim(&self, child: &Child) -> Result<CaptureClaim> {
        let Intent::Native(request) = &child.request else {
            anyhow::bail!("remote capture lacks native intent")
        };
        Ok(CaptureClaim {
            request: (**request).clone(),
            pending: child
                .pending
                .clone()
                .context("original capture context missing")?,
            ownership: self.ownership.clone(),
            reserved_at: self.reserved_at,
        })
    }

    pub(super) fn validate(&self, child: &Child) -> Result<()> {
        ensure!(
            child.installed_remote_capture() && child.capture_claimed && child.material.is_none(),
            "remote capture is not an original installed claim"
        );
        let claim = self.claim(child)?;
        Begin {
            request: claim.request.clone(),
            pending: serde_json::to_value(claim.pending)?,
            ownership: claim.ownership,
            reserved_at: claim.reserved_at,
        }
        .validate()?;
        if let Some(super::Snapshot::Live {
            ownership: Some(owner),
            ..
        }) = &child.snapshot
        {
            ensure!(owner == &self.ownership, "remote capture owner changed");
        }
        if let Some(status) = &self.status {
            status.validate_for(&claim.request)?;
            ensure!(
                child.input_claimed == status.delivery_claim,
                "remote capture dispatch differs from its authenticated claim"
            );
            if let Some(receipt) = &status.receipt {
                ensure!(
                    child.input_received.as_ref() == Some(&receipt.material_digest),
                    "remote capture intake differs from its receipt"
                );
            }
        } else {
            ensure!(
                child.input_claimed.is_none(),
                "remote input has no capture observation"
            );
        }
        ensure!(
            !self.acknowledged || self.settled(),
            "capture ACK precedes source settlement"
        );
        Ok(())
    }

    pub(super) fn settled(&self) -> bool {
        self.status
            .as_ref()
            .is_some_and(|status| status.phase.terminal() && status.data_released)
    }

    fn received(&self) -> bool {
        self.settled()
            && self
                .status
                .as_ref()
                .is_some_and(|status| status.receipt.is_some())
    }

    fn advance(&self, new: &Status) -> Result<()> {
        let Some(old) = &self.status else {
            return Ok(());
        };
        ensure!(
            (!old.phase.terminal() || old.phase == new.phase)
                && !(old.phase == Phase::Running
                    && matches!(new.phase, Phase::Claimed | Phase::Revoked))
                && (!old.cancelled || new.cancelled)
                && (!old.data_released || new.data_released),
            "remote capture observation regressed"
        );
        if old.delivery_claim.is_some() || old.phase.terminal() {
            ensure!(
                old.delivery_claim == new.delivery_claim,
                "remote capture delivery claim changed"
            );
        }
        if let Some(receipt) = &old.receipt {
            ensure!(
                new.receipt
                    .as_ref()
                    .is_some_and(|new| new.version == receipt.version
                        && new.attempt_id == receipt.attempt_id
                        && new.request_digest == receipt.request_digest
                        && new.material_digest == receipt.material_digest),
                "remote capture receipt changed"
            );
        }
        Ok(())
    }
}

impl Child {
    pub(super) fn installed_remote_capture(&self) -> bool {
        !self.target.local
            && self
                .pending
                .as_ref()
                .is_some_and(|pending| pending.bootstrap.is_some() && pending.environment.is_some())
    }

    pub(super) fn needs_remote_capture(&self) -> bool {
        self.installed_remote_capture() && !self.capture_claimed && self.material.is_none()
    }
}

impl Run {
    pub(in crate::fleet::build_backend::agent) fn poll_captures(
        &mut self,
        transport: &mut impl Transport,
    ) -> Result<()> {
        let attempts = self.manifest.children.keys().cloned().collect::<Vec<_>>();
        for attempt in attempts {
            let child = &self.manifest.children[&attempt];
            let stop = self.cancelled()?
                || child.outcome().is_some_and(|outcome| {
                    !matches!(
                        outcome,
                        abird_host_agent::build_executor::Outcome::Succeeded { .. }
                    )
                });
            poll(self, transport, &attempt, stop)?;
        }
        Ok(())
    }

    pub(super) fn observe_capture(&mut self, attempt: &str, status: Status) -> Result<()> {
        let child = self.child_mut(attempt)?;
        let source = child
            .remote_capture
            .as_ref()
            .context("remote capture was not claimed")?;
        let Intent::Native(request) = &child.request else {
            anyhow::bail!("remote capture lacks native intent")
        };
        status.validate_for(request)?;
        source.advance(&status)?;
        if let Some(old) = &child.input_claimed {
            ensure!(
                status.delivery_claim.as_ref() == Some(old),
                "source claim changed"
            );
        }
        if let (
            Some(claim),
            Some(super::Snapshot::Live {
                input:
                    Some(abird_host_agent::build_executor::source_transport::InputState::Received {
                        digest,
                    }),
                ..
            }),
        ) = (&status.delivery_claim, &child.snapshot)
        {
            ensure!(
                claim == digest,
                "builder intake differs from the original root source claim"
            );
            child.input_received = Some(digest.clone());
        }
        if let Some(receipt) = &status.receipt {
            ensure!(
                child
                    .input_received
                    .as_ref()
                    .is_none_or(|old| old == &receipt.material_digest),
                "source receipt changed"
            );
            child.input_received = Some(receipt.material_digest.clone());
        }
        child.input_claimed = status.delivery_claim.clone();
        child.remote_capture.as_mut().unwrap().status = Some(status);
        self.save()
    }

    pub(in crate::fleet::build_backend::agent) fn captures_settled(&self) -> bool {
        self.manifest
            .children
            .values()
            .all(|child| child.remote_capture.as_ref().is_none_or(Source::settled))
    }

    pub(in crate::fleet::build_backend::agent) fn require_capture_success(&self) -> Result<()> {
        ensure!(
            self.manifest
                .children
                .values()
                .all(|child| !child.installed_remote_capture()
                    || child.remote_capture.as_ref().is_some_and(Source::received)),
            "original source capture/intake remains unconfirmed"
        );
        Ok(())
    }

    pub(in crate::fleet::build_backend::agent) fn require_capture_retirement(&self) -> Result<()> {
        ensure!(
            self.manifest.children.values().all(|child| child
                .remote_capture
                .as_ref()
                .is_none_or(|source| source.settled() && source.acknowledged)),
            "original source settlement/retention acknowledgement remains unconfirmed"
        );
        Ok(())
    }
}

/// Concurrent observation/cancellation cannot ACK or mutate caller state. Once
/// its writer is inactive, the caller must inspect a fresh manifest before using
/// this result, closing a claim that raced the initial cancellation marker.
pub(super) fn observed(
    manifest: &Manifest,
    transport: &mut impl Transport,
    cancel: bool,
) -> Result<bool> {
    manifest.validate()?;
    let mut settled = true;
    for child in manifest.children.values() {
        let Some(source) = &child.remote_capture else {
            continue;
        };
        if source.settled() {
            continue;
        }
        let claim = source.claim(child)?;
        let status = if cancel {
            remote_capture::cancel(transport, &claim)?
        } else {
            remote_capture::status(transport, &claim.request)?
        };
        if let Some(status) = status {
            source.advance(&status)?;
            settled &= status.phase.terminal() && status.data_released;
        } else {
            settled = false;
        }
    }
    Ok(settled)
}

/// Called even after the builder settled. Root ACK follows the caller's durable
/// positive observation; unavailable control never becomes source settlement.
pub(super) fn poll(
    run: &mut Run,
    transport: &mut impl Transport,
    attempt: &str,
    stop: bool,
) -> Result<()> {
    let child = &run.manifest.children[attempt];
    let Some(source) = &child.remote_capture else {
        return Ok(());
    };
    let claim = source.claim(child)?;
    if !source.settled() {
        let status = if stop {
            remote_capture::cancel(transport, &claim)?
        } else {
            remote_capture::status(transport, &claim.request)?
        };
        if let Some(status) = status {
            run.observe_capture(attempt, status)?;
        }
    }
    let source = run.manifest.children[attempt]
        .remote_capture
        .as_ref()
        .unwrap();
    if source.status.as_ref().is_some_and(|status| {
        status.phase.terminal() && status.receipt.is_none() && status.delivery_claim.is_none()
    }) {
        // Failed/no-launch capture cannot leave a healthy owner renewing a
        // builder that will never receive input. This is intent, not settlement.
        Run::request_cancel(&run.manifest.run_id)?;
    }
    if source.settled() && !source.acknowledged {
        match remote_capture::acknowledge(transport, &claim.request)? {
            remote_capture::Retention::Unconfirmed => return Ok(()),
            remote_capture::Retention::Acknowledged(status) => {
                run.observe_capture(attempt, status)?
            }
            // Prior positive source proof is already durable. The root service
            // separately proved absence plus its permanent replay floor.
            remote_capture::Retention::Closed => {}
        }
        let source = run.child_mut(attempt)?.remote_capture.as_mut().unwrap();
        ensure!(
            source.settled(),
            "capture retention ACK lacks source settlement"
        );
        source.acknowledged = true;
        run.save()?;
    }
    Ok(())
}
