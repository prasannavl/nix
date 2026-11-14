//! A+ ownership contracts. The attempt model stays pure; `journal` owns persistence.
//!
//! Settlement is trusted executor evidence, never a caller-supplied cancellation
//! acknowledgement. Journaling and the executor must enforce that boundary.

mod artifacts;
pub use artifacts::{ArtifactDelivery, ArtifactPage};
pub mod bootstrap;
mod build_worker;
pub mod capture_role;
pub mod client;
pub mod consumer_role;
pub mod context;
pub mod control;
pub mod controller_service;
pub mod daemon;
pub mod diagnostics;
pub mod events;
pub mod journal;
pub mod launch_gate;
pub mod maintenance;
pub mod maintenance_worker;
pub mod native_intent;
pub mod native_phase;
pub mod preparation;
pub mod private_sources;
pub mod private_tree;
pub mod process;
pub mod protection;
pub mod protocol;
pub mod request;
mod retirement;
pub mod role;
pub mod source_transport;
mod stage;
mod store_binding;
pub mod store_interlock;
pub mod strategy;
pub mod supervisor;
pub mod units;
pub mod workload;

use std::num::NonZeroU64;

use anyhow::{Result, bail, ensure};
use serde::{Deserialize, Serialize};

pub const SCHEMA_VERSION: u32 = 2;
pub const MAX_RECORD_BYTES: usize = 64 * 1024;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Ownership {
    pub executor_version: u32,
    pub builder_id: String,
    pub store_id: String,
    pub attempt_id: String,
    pub pool_epoch: NonZeroU64,
    pub boot_id: String,
}

impl Ownership {
    fn validate(&self, attempt_id: &str) -> Result<()> {
        ensure!(self.executor_version == 1, "unsupported executor version");
        ensure!(
            self.attempt_id == attempt_id,
            "execution belongs to another attempt"
        );
        for value in [
            &self.builder_id,
            &self.store_id,
            &self.attempt_id,
            &self.boot_id,
        ] {
            identifier(value)?;
        }
        Ok(())
    }

    /// Deterministic before launch, including the lost start-ack window.
    pub fn unit_name(&self) -> Result<String> {
        self.validate(&self.attempt_id)?;
        Ok(format!("abird-build-client@{}.service", self.attempt_id))
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ExecutionHandle {
    pub ownership: Ownership,
    pub invocation_id: String,
}

impl ExecutionHandle {
    fn validate(&self, attempt_id: &str) -> Result<()> {
        self.ownership.validate(attempt_id)?;
        identifier(&self.invocation_id)
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ClientExit {
    Success,
    Failed { exit_code: u8 },
    Signalled { signal: u8 },
}

impl ClientExit {
    fn validate(self) -> Result<()> {
        ensure!(
            !matches!(
                self,
                Self::Failed { exit_code: 0 } | Self::Signalled { signal: 0 }
            ),
            "failure requires a nonzero exit code or signal"
        );
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum StopReason {
    Cancelled,
    OwnerExpired,
    DeadlineExpired,
    AdmissionFailed,
    ClientFailed { exit: ClientExit },
    ResourceExhausted,
    VerificationFailed,
    ExecutorLost,
}

impl StopReason {
    fn validate(self, has_execution: bool) -> Result<()> {
        match self {
            Self::ClientFailed { exit } => {
                exit.validate()?;
                ensure!(exit != ClientExit::Success, "success is not a stop failure");
                ensure!(has_execution, "client failure requires owned execution");
            }
            Self::AdmissionFailed => ensure!(!has_execution, "execution already reserved"),
            Self::ExecutorLost | Self::VerificationFailed => {
                ensure!(has_execution, "no executor was reserved")
            }
            _ => {}
        }
        Ok(())
    }

    fn outcome(self) -> Outcome {
        match self {
            Self::Cancelled | Self::OwnerExpired | Self::DeadlineExpired => {
                Outcome::Cancelled { reason: self }
            }
            Self::ExecutorLost => Outcome::Interrupted,
            _ => Outcome::Failed { reason: self },
        }
    }
}

/// References independently verified closure/root receipts; not verification itself.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ArtifactReceipt {
    pub spec_digest: String,
    pub preparation_digest: String,
    pub closure_digest: String,
    pub roots_digest: String,
}

impl ArtifactReceipt {
    fn validate(&self, spec_digest: &str) -> Result<()> {
        ensure!(
            self.spec_digest == spec_digest,
            "artifact specification mismatch"
        );
        digest(&self.spec_digest)?;
        digest(&self.preparation_digest)?;
        digest(&self.closure_digest)?;
        digest(&self.roots_digest)
    }
}

/// Authenticated consumer statement after acquisition verification and durable
/// consumer retention. Not a builder-verification, settlement or release receipt.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ConsumerAck {
    pub version: u32,
    pub ownership: Ownership,
    pub artifacts: ArtifactReceipt,
    pub consumer: request::Peer,
    pub store_id: String,
    pub acquisition_digest: String,
    pub retention_digest: String,
}

impl ConsumerAck {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.version == 1, "unsupported consumer acknowledgement");
        self.ownership.validate(&self.ownership.attempt_id)?;
        self.artifacts.validate(&self.artifacts.spec_digest)?;
        for value in [
            &self.consumer.host_id,
            &self.consumer.fabric_id,
            &self.store_id,
        ] {
            identifier(value)?;
        }
        digest(&self.acquisition_digest)?;
        digest(&self.retention_digest)?;
        ensure!(
            serde_json::to_vec(self)?.len() <= 1792,
            "consumer acknowledgement exceeds bound"
        );
        Ok(())
    }

    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        let mut bytes = b"abird-owned-consumer-ack-v1\n".to_vec();
        bytes.extend(serde_json::to_vec(self)?);
        Ok(crate::sha256::digest_bytes(&bytes))
    }
}

/// Original consumer gives up this exact successful result without asserting
/// acquisition or retention. Mutually exclusive with ConsumerAck; not release.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ConsumerAbandonment {
    pub version: u32,
    pub ownership: Ownership,
    pub artifacts: ArtifactReceipt,
    pub consumer: request::Peer,
    pub store_id: String,
    pub acquisition_binding: String,
}

impl ConsumerAbandonment {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.version == 1, "unsupported consumer abandonment");
        self.ownership.validate(&self.ownership.attempt_id)?;
        self.artifacts.validate(&self.artifacts.spec_digest)?;
        for value in [
            &self.consumer.host_id,
            &self.consumer.fabric_id,
            &self.store_id,
        ] {
            identifier(value)?;
        }
        digest(&self.acquisition_binding)?;
        ensure!(
            serde_json::to_vec(self)?.len() <= 1792,
            "consumer abandonment exceeds bound"
        );
        Ok(())
    }

    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        let mut bytes = b"abird-owned-consumer-abandonment-v1\n".to_vec();
        bytes.extend(serde_json::to_vec(self)?);
        Ok(crate::sha256::digest_bytes(&bytes))
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Settlement {
    /// No launch reserved; metadata-only admission performed no Nix/store effects.
    Unlaunched,
    /// Client and admitted workers settled; the accounted idle daemon may remain.
    Idle { handle: ExecutionHandle },
    /// Ingress fenced and the entire accounted workload subtree proved empty.
    FencedEmpty { ownership: Ownership },
    /// Same authenticated builder/store, with the old boot proved absent.
    Rebooted {
        ownership: Ownership,
        new_boot_id: String,
    },
}

impl Settlement {
    fn ownership(&self) -> Option<&Ownership> {
        match self {
            Self::Unlaunched => None,
            Self::Idle { handle } => Some(&handle.ownership),
            Self::FencedEmpty { ownership } | Self::Rebooted { ownership, .. } => Some(ownership),
        }
    }

    fn validate(&self, attempt_id: &str) -> Result<()> {
        if let Some(owner) = self.ownership() {
            owner.validate(attempt_id)?;
        }
        match self {
            Self::Idle { handle } => handle.validate(attempt_id)?,
            Self::Rebooted {
                ownership,
                new_boot_id,
            } => {
                identifier(new_boot_id)?;
                ensure!(
                    new_boot_id != &ownership.boot_id,
                    "old boot is still current"
                );
            }
            _ => {}
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Outcome {
    Succeeded { artifacts: ArtifactReceipt },
    MaintenanceSucceeded { verification_digest: String },
    Failed { reason: StopReason },
    Cancelled { reason: StopReason },
    Interrupted,
}

impl Outcome {
    fn validate(&self, spec_digest: &str) -> Result<()> {
        match self {
            Self::Succeeded { artifacts } => artifacts.validate(spec_digest)?,
            Self::MaintenanceSucceeded {
                verification_digest,
            } => digest(verification_digest)?,
            Self::Failed { reason } | Self::Cancelled { reason } => {
                reason.validate(!matches!(reason, StopReason::AdmissionFailed))?;
                ensure!(&reason.outcome() == self, "terminal reason mismatch");
            }
            Self::Interrupted => {}
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    Pending,
    Queued,
    Starting,
    Running,
    Verifying,
    Stopping,
    Succeeded,
    Failed,
    Cancelled,
    Interrupted,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Observation {
    Connected,
    Reconnecting,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PoolHealth {
    Available,
    Owned,
    Draining,
    Recovering,
    Quarantined,
}

#[derive(Debug, Serialize)]
pub struct Status<'a> {
    pub execution: Phase,
    pub observation: Observation,
    pub pool: PoolHealth,
    pub outcome: Option<&'a Outcome>,
    pub outcome_unconfirmed: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryAction {
    ValidateSubmission,
    AwaitAdmission,
    ReconcileExecution,
    RetainTerminal,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Execution {
    Reserved { ownership: Ownership },
    Started { handle: ExecutionHandle },
}

impl Execution {
    fn ownership(&self) -> &Ownership {
        match self {
            Self::Reserved { ownership } => ownership,
            Self::Started { handle } => &handle.ownership,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum State {
    Pending,
    Queued,
    Starting {
        ownership: Ownership,
    },
    Running {
        handle: ExecutionHandle,
    },
    Verifying {
        handle: ExecutionHandle,
    },
    Stopping {
        execution: Option<Execution>,
        reason: StopReason,
    },
    Finished {
        outcome: Outcome,
        settlement: Settlement,
    },
}

impl State {
    fn execution(&self) -> Option<Execution> {
        match self {
            Self::Starting { ownership } => Some(Execution::Reserved {
                ownership: ownership.clone(),
            }),
            Self::Running { handle } | Self::Verifying { handle } => Some(Execution::Started {
                handle: handle.clone(),
            }),
            Self::Stopping { execution, .. } => execution.clone(),
            _ => None,
        }
    }

    fn ownership(&self) -> Option<&Ownership> {
        match self {
            Self::Starting { ownership } => Some(ownership),
            Self::Running { handle } | Self::Verifying { handle } => Some(&handle.ownership),
            Self::Stopping { execution, .. } => execution.as_ref().map(Execution::ownership),
            Self::Finished { settlement, .. } => settlement.ownership(),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct Record {
    schema_version: u32,
    attempt_id: String,
    spec_digest: String,
    state: State,
}

/// In-memory transitions only. Persist a successful transition before any effect/ACK.
#[derive(Debug)]
pub struct Attempt(Record);

impl Attempt {
    /// In-memory submission metadata, not a durable acceptance or permission to work.
    pub fn pending(attempt_id: impl Into<String>, spec_digest: impl Into<String>) -> Result<Self> {
        let attempt = Self(Record {
            schema_version: SCHEMA_VERSION,
            attempt_id: attempt_id.into(),
            spec_digest: spec_digest.into(),
            state: State::Pending,
        });
        attempt.validate()?;
        Ok(attempt)
    }

    pub fn encode(&self) -> Result<Vec<u8>> {
        let bytes = serde_json::to_vec(&self.0)?;
        ensure!(
            bytes.len() <= MAX_RECORD_BYTES,
            "owned-build record too large"
        );
        Ok(bytes)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self> {
        ensure!(
            bytes.len() <= MAX_RECORD_BYTES,
            "owned-build record too large"
        );
        let attempt = Self(serde_json::from_slice(bytes)?);
        attempt.validate()?;
        Ok(attempt)
    }

    pub fn phase(&self) -> Phase {
        match &self.0.state {
            State::Pending => Phase::Pending,
            State::Queued => Phase::Queued,
            State::Starting { .. } => Phase::Starting,
            State::Running { .. } => Phase::Running,
            State::Verifying { .. } => Phase::Verifying,
            State::Stopping { .. } => Phase::Stopping,
            State::Finished { outcome, .. } => match outcome {
                Outcome::Succeeded { .. } | Outcome::MaintenanceSucceeded { .. } => {
                    Phase::Succeeded
                }
                Outcome::Failed { .. } => Phase::Failed,
                Outcome::Cancelled { .. } => Phase::Cancelled,
                Outcome::Interrupted => Phase::Interrupted,
            },
        }
    }

    pub fn outcome(&self) -> Option<&Outcome> {
        match &self.0.state {
            State::Finished { outcome, .. } => Some(outcome),
            _ => None,
        }
    }

    pub fn status(&self, observation: Observation, pool: PoolHealth) -> Status<'_> {
        Status {
            execution: self.phase(),
            observation,
            pool,
            outcome: self.outcome(),
            outcome_unconfirmed: observation != Observation::Connected && self.outcome().is_none(),
        }
    }

    pub fn recovery_action(&self) -> RecoveryAction {
        match self.0.state {
            State::Pending => RecoveryAction::ValidateSubmission,
            State::Queued => RecoveryAction::AwaitAdmission,
            State::Finished { .. } => RecoveryAction::RetainTerminal,
            _ => RecoveryAction::ReconcileExecution,
        }
    }

    /// Metadata validation only. Nix/source effects require reserved ownership.
    pub fn mark_queued(&mut self) -> Result<()> {
        ensure!(
            matches!(self.0.state, State::Pending | State::Queued),
            "cannot queue active attempt"
        );
        self.0.state = State::Queued;
        Ok(())
    }

    pub fn reserve(&mut self, ownership: Ownership) -> Result<()> {
        ownership.validate(&self.0.attempt_id)?;
        ensure!(self.0.state == State::Queued, "attempt is not queued");
        self.0.state = State::Starting { ownership };
        Ok(())
    }

    pub fn started(&mut self, handle: ExecutionHandle) -> Result<()> {
        handle.validate(&self.0.attempt_id)?;
        self.check_owner(Some(&handle.ownership))?;
        match &mut self.0.state {
            State::Starting { .. } => self.0.state = State::Running { handle },
            State::Running { handle: current } if current == &handle => {}
            State::Stopping { execution, .. } => match execution {
                Some(Execution::Reserved { .. }) => {
                    *execution = Some(Execution::Started { handle })
                }
                Some(Execution::Started { handle: current }) if current == &handle => {}
                _ => bail!("start acknowledgement does not match stopping execution"),
            },
            _ => bail!("attempt cannot accept a start acknowledgement"),
        }
        Ok(())
    }

    pub fn client_exited(&mut self, handle: &ExecutionHandle, exit: ClientExit) -> Result<()> {
        handle.validate(&self.0.attempt_id)?;
        exit.validate()?;
        let expected = Some(Execution::Started {
            handle: handle.clone(),
        });
        ensure!(
            self.0.state.execution() == expected,
            "client execution identity mismatch"
        );
        match self.0.state {
            State::Running { .. } => {
                self.0.state = if exit == ClientExit::Success {
                    State::Verifying {
                        handle: handle.clone(),
                    }
                } else {
                    State::Stopping {
                        execution: expected,
                        reason: StopReason::ClientFailed { exit },
                    }
                };
            }
            State::Stopping { .. } => {}
            State::Verifying { .. } if exit == ClientExit::Success => {}
            _ => bail!("attempt cannot accept a client exit"),
        }
        Ok(())
    }

    pub fn request_stop(
        &mut self,
        expected: Option<&Ownership>,
        reason: StopReason,
    ) -> Result<bool> {
        self.check_owner(expected)?;
        if matches!(
            self.0.state,
            State::Stopping { .. } | State::Finished { .. }
        ) {
            return Ok(false);
        }
        ensure!(
            !matches!(reason, StopReason::ClientFailed { .. }),
            "record client failures through client_exited"
        );
        let execution = self.0.state.execution();
        reason.validate(execution.is_some())?;
        self.0.state = State::Stopping { execution, reason };
        Ok(true)
    }

    pub fn settle(
        &mut self,
        settlement: Settlement,
        artifacts: Option<ArtifactReceipt>,
    ) -> Result<bool> {
        settlement.validate(&self.0.attempt_id)?;
        if let State::Finished {
            outcome,
            settlement: existing,
        } = &self.0.state
        {
            let existing_artifacts = match outcome {
                Outcome::Succeeded { artifacts } => Some(artifacts),
                _ => None,
            };
            ensure!(
                existing == &settlement && existing_artifacts == artifacts.as_ref(),
                "terminal receipt is immutable"
            );
            return Ok(false);
        }
        self.check_owner(settlement.ownership())?;
        if let Settlement::Idle { handle } = &settlement {
            ensure!(
                self.0.state.execution()
                    == Some(Execution::Started {
                        handle: handle.clone()
                    }),
                "settlement invocation mismatch"
            );
        }
        let outcome = if matches!(settlement, Settlement::Rebooted { .. }) {
            ensure!(
                artifacts.is_none(),
                "reboot settlement cannot publish artifacts"
            );
            Outcome::Interrupted
        } else {
            match &self.0.state {
                State::Verifying { .. } => {
                    let artifacts = artifacts
                        .ok_or_else(|| anyhow::anyhow!("verified artifact receipt required"))?;
                    artifacts.validate(&self.0.spec_digest)?;
                    Outcome::Succeeded { artifacts }
                }
                State::Stopping { reason, .. } => {
                    ensure!(
                        artifacts.is_none(),
                        "stopping attempt cannot publish success"
                    );
                    reason.outcome()
                }
                _ => bail!("attempt is not ready for settlement"),
            }
        };
        self.0.state = State::Finished {
            outcome,
            settlement,
        };
        Ok(true)
    }

    /// Genuine Maintenance only; the journal checks work kind and the installed
    /// verifier's receipt. No fabricated Build preparation/artifact fields.
    fn settle_maintenance(
        &mut self,
        settlement: Settlement,
        verification_digest: &str,
    ) -> Result<()> {
        digest(verification_digest)?;
        settlement.validate(&self.0.attempt_id)?;
        self.check_owner(settlement.ownership())?;
        ensure!(
            matches!(&self.0.state, State::Verifying { .. })
                && matches!(&settlement, Settlement::FencedEmpty { .. }),
            "maintenance requires verified, fenced settlement"
        );
        self.0.state = State::Finished {
            outcome: Outcome::MaintenanceSucceeded {
                verification_digest: verification_digest.to_owned(),
            },
            settlement,
        };
        Ok(())
    }

    fn check_owner(&self, expected: Option<&Ownership>) -> Result<()> {
        ensure!(
            self.0.state.ownership() == expected,
            "ownership fence mismatch"
        );
        Ok(())
    }

    fn validate(&self) -> Result<()> {
        ensure!(
            self.0.schema_version == SCHEMA_VERSION,
            "unsupported owned-build record version"
        );
        identifier(&self.0.attempt_id)?;
        digest(&self.0.spec_digest)?;
        if let Some(owner) = self.0.state.ownership() {
            owner.validate(&self.0.attempt_id)?;
        }
        if let Some(Execution::Started { handle }) = self.0.state.execution() {
            handle.validate(&self.0.attempt_id)?;
        }
        match &self.0.state {
            State::Stopping { execution, reason } => {
                reason.validate(execution.is_some())?;
                if matches!(reason, StopReason::ClientFailed { .. }) {
                    ensure!(
                        matches!(execution, Some(Execution::Started { .. })),
                        "client failure requires an observed invocation"
                    );
                }
            }
            State::Finished {
                outcome,
                settlement,
            } => {
                settlement.validate(&self.0.attempt_id)?;
                outcome.validate(&self.0.spec_digest)?;
                match outcome {
                    Outcome::Succeeded { .. } | Outcome::MaintenanceSucceeded { .. } => {
                        ensure!(
                            matches!(
                                settlement,
                                Settlement::Idle { .. } | Settlement::FencedEmpty { .. }
                            ),
                            "success requires execution settlement"
                        );
                    }
                    Outcome::Failed { reason } | Outcome::Cancelled { reason } => {
                        reason.validate(settlement.ownership().is_some())?;
                        ensure!(
                            !matches!(settlement, Settlement::Rebooted { .. }),
                            "reboot is interruption"
                        );
                    }
                    Outcome::Interrupted => ensure!(
                        settlement.ownership().is_some(),
                        "interruption requires owned execution"
                    ),
                }
            }
            _ => {}
        }
        Ok(())
    }
}

fn identifier(value: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && value.len() <= 128
            && value != "."
            && value != ".."
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte)),
        "invalid owned-build identifier"
    );
    Ok(())
}

fn digest(value: &str) -> Result<()> {
    ensure!(
        value.len() == 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
        "expected lowercase SHA-256 digest"
    );
    Ok(())
}

#[cfg(test)]
mod tests;
