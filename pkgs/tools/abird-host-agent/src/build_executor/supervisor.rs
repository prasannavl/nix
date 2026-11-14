//! Single-controller launch/observation/stop reconciliation, independent of callers.
//!
//! Qualified role adapters are mandatory; a gate alone is not kill authorization.
//! No recovery grant, artifact verification/release or realization retry here.

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::journal::{Journal, Pool};
use super::launch_gate::{Controller, Fence, Permission, Permit};
use super::request::Deadlines;
use super::workload::{FencedWorkload, Population};
use super::{ClientExit, ExecutionHandle, Ownership, Phase, PoolHealth, Settlement, StopReason};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StopStage {
    Requested,
    Terminating,
    Killing,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct StopProgress {
    pub requested_at: u64,
    pub stage: StopStage,
    pub advanced_at: u64,
}

impl StopProgress {
    pub(super) fn validate(&self, now: u64) -> Result<()> {
        ensure!(
            self.requested_at <= self.advanced_at && self.advanced_at <= now,
            "invalid stop timestamps"
        );
        ensure!(
            self.stage != StopStage::Requested || self.requested_at == self.advanced_at,
            "unstarted stop changed its timestamp"
        );
        Ok(())
    }

    /// Restart never resets either deadline. Saturation avoids deadline overflow.
    pub fn due(&self, deadlines: &Deadlines, now: u64) -> StopStage {
        if self.stage == StopStage::Killing
            || now.saturating_sub(self.requested_at) >= deadlines.stop_grace_seconds
        {
            StopStage::Killing
        } else {
            StopStage::Terminating
        }
    }
}

#[derive(Debug)]
pub struct Active {
    pub owner: Ownership,
    pub handle: Option<ExecutionHandle>,
    pub phase: Phase,
    pub stop: Option<StopProgress>,
    pub deadlines: Deadlines,
}

#[derive(Debug)]
pub struct Snapshot {
    pub pool: Pool,
    pub active: Option<Active>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ClientObservation {
    Pending,
    Exited {
        handle: ExecutionHandle,
        exit: ClientExit,
    },
    Lost,
    Foreign,
}

/// Trusted role proof: fixed gated units, closed ingress and actual aggregate
/// emptiness under this fence. Neither a journal flag nor a unit name suffices.
pub trait Launcher {
    fn ready(&mut self, fence: &Fence<'_>, pool: &Pool) -> Result<bool>;
    fn start_once(&mut self, owner: &Ownership) -> Result<()>;
}

/// Trusted, role-specific ingress adapter. Each operation must be bounded.
/// `owns_ingress` must check the actual admitted role, not infer it from a PID,
/// unit name, permit or journal owner. Unknown/foreign work must return false.
pub trait Ingress {
    fn observe_client(&mut self, active: &Active) -> Result<ClientObservation>;
    fn owns_ingress(&mut self, active: &Active) -> Result<bool>;
    /// Disable restart/socket/start sources and request orderly unit stop.
    /// Idempotent delivery is permitted; ACK is not quiescence or settlement.
    fn request_stop(&mut self, active: &Active) -> Result<()>;
    /// All supported ingress and pending systemd jobs positively quiesced.
    fn quiescent(&mut self, active: &Active) -> Result<bool>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Progress {
    Idle,
    Observing,
    Verifying,
    FencePending,
    Draining,
    Quarantined,
    Settled,
    Interrupted,
}

pub struct Supervisor<'a> {
    journal: &'a Journal,
    controller: Controller<'a>,
}

impl<'a> Supervisor<'a> {
    pub fn new(journal: &'a Journal, controller: Controller<'a>) -> Result<Self> {
        ensure!(
            journal.identity() == controller.gate().identity(),
            "supervisor authority mismatch"
        );
        Ok(Self {
            journal,
            controller,
        })
    }

    /// The fresh reservation is the one-shot dispatch claim. Existing reservations
    /// are never dispatched, including after controller death or an uncertain ACK.
    /// Crashing before delivery may interrupt an attempt; it cannot replay Nix.
    pub fn launch_next(
        &mut self,
        store: &super::store_interlock::StoreInterlock,
        launcher: &mut impl Launcher,
        now: u64,
    ) -> Result<Option<Ownership>> {
        self.controller.validate()?;
        self.journal.expire(now)?;
        self.journal.settle_unlaunched(now)?;
        self.journal.queue_pending(now)?;
        let pool = self.journal.pool()?;
        if pool.owner.is_some() {
            return Ok(None);
        }
        let gate = self.controller.gate();
        ensure!(
            pool.health == PoolHealth::Available
                && pool.verified_boot.as_deref() == Some(gate.boot_id()),
            "pool is not reconciled/available"
        );
        let Some(kind) = self.journal.next_kind()? else {
            return Ok(None);
        };
        // Lock mode and reserved work must agree even if cancellation races us.
        // Maintenance uses exclusive; neither lock is execution permission.
        let Some(_store) = store.try_dispatch(self.journal, kind)? else {
            return Ok(None);
        };
        let fence = gate.try_fence()?.context("launch fence pending")?;
        match launcher.ready(&fence, &pool) {
            Ok(true) => {}
            result => {
                self.journal.quarantine(now)?;
                ensure!(result?, "launch role is not ready");
            }
        }
        let Some(owner) = self
            .journal
            .reserve_next_kind(gate.boot_id(), now, Some(kind))?
        else {
            return Ok(None);
        };
        fence.publish(&Permit {
            version: 1,
            identity: gate.identity().clone(),
            permission: Permission::Execution {
                ownership: owner.clone(),
            },
        })?;
        // Publication consumes/releases the fence before the gated wrapper starts.
        launcher.start_once(&owner)?;
        Ok(Some(owner))
    }

    /// Installed supervisor only. Verification is recorded by the in-slice role;
    /// success still waits for closed ingress and positive aggregate emptiness.
    pub(super) fn finish_verified(
        &mut self,
        ingress: &mut impl Ingress,
        now: u64,
    ) -> Result<Progress> {
        self.controller.validate()?;
        self.journal.expire(now)?;
        let Some(active) = self.journal.supervision()?.active else {
            return Ok(Progress::Idle);
        };
        if active.phase != Phase::Verifying {
            return Ok(Progress::Observing);
        }
        ensure!(
            active.owner.boot_id == self.controller.gate().boot_id(),
            "verification boot differs"
        );
        let Some(verified) = self.journal.verified(&active.owner)? else {
            self.journal
                .stop(&active.owner, StopReason::VerificationFailed, now)?;
            return Ok(Progress::Draining);
        };
        ensure!(
            active.handle.as_ref() == Some(&verified.handle),
            "verifier invocation differs"
        );
        let Some(fence) = self.controller.gate().try_fence()? else {
            return Ok(Progress::FencePending);
        };
        match ingress.owns_ingress(&active) {
            Ok(true) => {}
            Ok(false) => {
                self.journal.quarantine(now)?;
                return Ok(Progress::Quarantined);
            }
            Err(error) => {
                self.journal.quarantine(now)?;
                return Err(error);
            }
        }
        // The persisted verifier time and Verifying transition are the immutable
        // successful-drain intent. Reconnection cannot restart this grace period.
        let elapsed = now.saturating_sub(verified.completed_at);
        if elapsed >= active.deadlines.stop_limit_seconds {
            self.journal.quarantine(now)?;
        }
        ingress.request_stop(&active)?;
        if !ingress.quiescent(&active)? {
            return Ok(Progress::Draining);
        }
        let workload = FencedWorkload::new(&fence)?;
        if elapsed >= active.deadlines.stop_grace_seconds {
            workload.kill()?;
        }
        if workload.population()? != Population::Empty {
            return Ok(Progress::Draining);
        }
        // A cancellation that raced observation is never overwritten by success.
        if self.journal.supervision()?.active.is_some_and(|current| {
            current.owner == active.owner && current.phase == Phase::Verifying
        }) {
            self.journal.settle_verified(&active.owner, now)?;
            Ok(Progress::Settled)
        } else {
            Ok(Progress::Draining)
        }
    }

    /// One bounded poll. Hold controller exclusion across polls, never the journal
    /// lock across effects. Errors retain ownership; the independent caller/status
    /// lane remains usable. A later poll can retry stop delivery, never realization.
    pub fn poll(&mut self, ingress: &mut impl Ingress, now: u64) -> Result<Progress> {
        self.controller.validate()?;
        self.journal.expire(now)?;
        self.journal.settle_unlaunched(now)?;
        let snapshot = self.journal.supervision()?;
        let Some(mut active) = snapshot.active else {
            return Ok(Progress::Idle);
        };
        let gate = self.controller.gate();
        if active.owner.boot_id != gate.boot_id() {
            // New boot proves absence of old work, not safety of current ingress.
            self.journal.quarantine(now)?;
            let Some(_fence) = gate.try_fence()? else {
                return Ok(Progress::FencePending);
            };
            self.journal.settle(
                &active.owner.attempt_id,
                Settlement::Rebooted {
                    ownership: active.owner.clone(),
                    new_boot_id: gate.boot_id().to_owned(),
                },
                None,
                now,
            )?;
            return Ok(Progress::Interrupted);
        }
        if matches!(active.phase, Phase::Starting | Phase::Running) {
            let observation = ingress.observe_client(&active)?;
            let current = self
                .journal
                .supervision()?
                .active
                .context("observation lost owner")?;
            ensure!(current.owner == active.owner, "observation owner changed");
            if current.handle != active.handle {
                // The launch wrapper can publish Started while systemctl observes
                // a very fast exit. Retry observation with the durable handle.
                return Ok(Progress::Observing);
            }
            match observation {
                ClientObservation::Pending => return Ok(Progress::Observing),
                ClientObservation::Exited { handle, exit } => {
                    ensure!(
                        active.handle.as_ref() == Some(&handle),
                        "observation handle mismatch"
                    );
                    self.journal.client_exited(&handle, exit, now)?;
                }
                ClientObservation::Lost => {
                    self.journal
                        .stop(&active.owner, StopReason::ExecutorLost, now)?
                }
                ClientObservation::Foreign => {
                    self.journal.quarantine(now)?;
                    self.journal
                        .stop(&active.owner, StopReason::ExecutorLost, now)?;
                    // Close permission when possible, but never stop/kill a foreign unit.
                    let _fence = gate.try_fence()?;
                    return Ok(Progress::Quarantined);
                }
            }
            active = self
                .journal
                .supervision()?
                .active
                .context("observation lost owner")?;
        }
        if active.phase == Phase::Verifying {
            return Ok(Progress::Verifying);
        }
        if active.phase != Phase::Stopping {
            return Ok(Progress::Observing);
        }
        let stop = active
            .stop
            .as_ref()
            .context("stopping without durable deadline")?;
        let overdue = now.saturating_sub(stop.requested_at) >= active.deadlines.stop_limit_seconds;
        if overdue {
            self.journal.quarantine(now)?;
        }
        let Some(fence) = gate.try_fence()? else {
            return Ok(Progress::FencePending);
        };
        match ingress.owns_ingress(&active) {
            Ok(true) => {}
            Ok(false) => {
                self.journal.quarantine(now)?;
                return Ok(Progress::Quarantined);
            }
            Err(error) => {
                self.journal.quarantine(now)?;
                return Err(error);
            }
        }
        let stage = stop.due(&active.deadlines, now);
        // Commit intent before any stop/kill effect. Failure must not run it.
        self.journal.advance_stop(&active.owner, stage, now)?;
        ingress.request_stop(&active)?;
        if !ingress.quiescent(&active)? {
            return Ok(if overdue {
                Progress::Quarantined
            } else {
                Progress::Draining
            });
        }
        let workload = FencedWorkload::new(&fence)?;
        if stage == StopStage::Killing {
            workload.kill()?;
        }
        match workload.population() {
            Ok(Population::Empty) => {
                self.journal.settle(
                    &active.owner.attempt_id,
                    Settlement::FencedEmpty {
                        ownership: active.owner.clone(),
                    },
                    None,
                    now,
                )?;
                Ok(Progress::Settled)
            }
            Ok(Population::Populated) => Ok(if overdue {
                Progress::Quarantined
            } else {
                Progress::Draining
            }),
            Err(error) => {
                self.journal.quarantine(now)?;
                Err(error)
            }
        }
    }
}
