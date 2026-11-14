//! Offline caller boundary. Authentication/framing/transport and the supervisor
//! are deliberately absent. Never expose trusted journal effect methods here.

use std::fmt;

use anyhow::Result;
use serde::{Deserialize, Serialize};

use super::events::{
    EventCursor, EventPage, LogCursor, LogPage, MAX_EVENT_PAGE, MAX_LOG_PAGE_BYTES,
};
use super::journal::{Acceptance, JobStatus, Journal};
use super::request::{AdmissionPolicy, BuildRequest, StorageIdentity};
use super::{Outcome, Ownership, Phase, PoolHealth, digest, identifier};

pub const VERSION: u32 = 3;
pub const MAX_FRAME_BYTES: usize = 64 * 1024;

/// Rejection of this message, never proof that earlier work stopped or vanished.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Rejection {
    InvalidRequest,
    UnsupportedVersion,
    Unauthorized,
    Conflict,
    PolicyMismatch,
    ExpiredRequest,
    Capacity,
    InvalidPredecessor,
    NotFound,
    InvalidTransition,
    StaleFence,
    LeaseExpired,
    ClockRegressed,
    InvalidCursor,
    CapabilityUnavailable,
}

impl fmt::Display for Rejection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Rejection {}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Unconfirmed {
    Unavailable,
    Persistence,
}
impl fmt::Display for Unconfirmed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Unconfirmed {}

// No Debug: renew messages contain a secret capability, never diagnostic text.
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u32,
    pub command: Command,
}

#[derive(Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    /// Authenticated immutable admission metadata; never readiness or capacity.
    Describe,
    SubmitNative {
        request: Box<super::native_intent::Request>,
    },
    WithdrawNative {
        request: Box<super::native_intent::Request>,
    },
    /// Cancel this immutable intent even if its submit delivery is still in flight.
    Withdraw {
        request: Box<BuildRequest>,
    },
    Submit {
        request: Box<BuildRequest>,
    },
    Status {
        attempt_id: String,
    },
    AcknowledgeConsumer {
        receipt: Box<super::ConsumerAck>,
    },
    ConsumerStatus {
        attempt_id: String,
    },
    AbandonConsumer {
        abandonment: Box<super::ConsumerAbandonment>,
    },
    ConsumerAbandonmentStatus {
        attempt_id: String,
    },
    /// Private evaluated planning, not public closure data or phase authority.
    Planning {
        attempt_id: String,
        artifact_digest: String,
        planning_digest: String,
        offset: u64,
    },
    Artifacts {
        attempt_id: String,
        artifact_digest: String,
        offset: u64,
    },
    Cancel {
        attempt_id: String,
        expected: Option<Ownership>,
    },
    Renew {
        attempt_id: String,
        expected: Option<Ownership>,
        token: String,
    },
    Events {
        attempt_id: String,
        cursor: Option<EventCursor>,
        limit: usize,
    },
    Logs {
        attempt_id: String,
        cursor: Option<LogCursor>,
        limit: usize,
    },
}

impl Request {
    pub fn decode(bytes: &[u8]) -> std::result::Result<Self, Rejection> {
        if bytes.len() > MAX_FRAME_BYTES {
            return Err(Rejection::InvalidRequest);
        }
        let request: Self = serde_json::from_slice(bytes).map_err(|_| Rejection::InvalidRequest)?;
        if request.version != VERSION {
            return Err(Rejection::UnsupportedVersion);
        }
        request.validate().map_err(|_| Rejection::InvalidRequest)?;
        Ok(request)
    }

    fn validate(&self) -> Result<()> {
        match &self.command {
            Command::Describe => Ok(()),
            Command::SubmitNative { request } | Command::WithdrawNative { request } => {
                request.validate()
            }
            Command::Submit { request } | Command::Withdraw { request } => request.validate(),
            Command::Status { attempt_id }
            | Command::ConsumerStatus { attempt_id }
            | Command::ConsumerAbandonmentStatus { attempt_id } => digest(attempt_id),
            Command::AcknowledgeConsumer { receipt } => receipt.validate(),
            Command::AbandonConsumer { abandonment } => abandonment.validate(),
            Command::Planning {
                attempt_id,
                artifact_digest,
                planning_digest,
                offset,
            } => {
                digest(attempt_id)?;
                digest(artifact_digest)?;
                digest(planning_digest)?;
                anyhow::ensure!(
                    *offset < super::preparation::MAX_PREPARED_BYTES as u64,
                    "planning offset exceeds bound"
                );
                Ok(())
            }
            Command::Artifacts {
                attempt_id,
                artifact_digest,
                offset,
            } => {
                digest(attempt_id)?;
                digest(artifact_digest)?;
                anyhow::ensure!(
                    *offset < super::artifacts::MAX_BYTES as u64,
                    "artifact offset exceeds bound"
                );
                Ok(())
            }
            Command::Cancel {
                attempt_id,
                expected,
            }
            | Command::Renew {
                attempt_id,
                expected,
                ..
            } => {
                digest(attempt_id)?;
                if let Some(owner) = expected {
                    owner.validate(attempt_id)?;
                }
                if let Command::Renew { token, .. } = &self.command {
                    anyhow::ensure!(
                        !token.is_empty()
                            && token.len() <= 128
                            && token.bytes().all(|b| b.is_ascii_graphic()),
                        "invalid owner token"
                    );
                }
                Ok(())
            }
            Command::Events {
                attempt_id,
                cursor,
                limit,
            } => {
                digest(attempt_id)?;
                anyhow::ensure!((1..=MAX_EVENT_PAGE).contains(limit), "invalid event limit");
                if let Some(cursor) = cursor {
                    anyhow::ensure!(cursor.attempt_id == *attempt_id, "cursor identity mismatch");
                }
                Ok(())
            }
            Command::Logs {
                attempt_id,
                cursor,
                limit,
            } => {
                digest(attempt_id)?;
                anyhow::ensure!(
                    (1..=MAX_LOG_PAGE_BYTES).contains(limit),
                    "invalid log limit"
                );
                if let Some(cursor) = cursor {
                    anyhow::ensure!(cursor.attempt_id == *attempt_id, "cursor identity mismatch");
                    identifier(&cursor.generation)?;
                }
                Ok(())
            }
        }
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
#[expect(
    clippy::large_enum_variant,
    reason = "Small bounded wire metadata; avoid a per-status ownership allocation."
)]
pub enum Snapshot {
    Live {
        pool: PoolHealth,
        acceptance: Acceptance,
        phase: Phase,
        prepared_digest: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        input: Option<super::source_transport::InputState>,
        outcome: Option<Outcome>,
        ownership: Option<Ownership>,
        accepted_at: u64,
        renewed_at: u64,
        reserved_at: Option<u64>,
        settled_at: Option<u64>,
    },
    Retired {
        pool: PoolHealth,
        acceptance: Acceptance,
        outcome: Outcome,
    },
}

fn validate_acceptance(acceptance: &Acceptance) -> Result<()> {
    digest(&acceptance.attempt_id)?;
    digest(&acceptance.spec_digest)?;
    anyhow::ensure!(acceptance.sequence > 0, "invalid acceptance sequence");
    Ok(())
}

impl Snapshot {
    fn validate(&self) -> Result<()> {
        match self {
            Self::Retired {
                acceptance,
                outcome,
                ..
            } => {
                validate_acceptance(acceptance)?;
                outcome.validate(&acceptance.spec_digest)?;
                anyhow::ensure!(
                    !matches!(outcome, Outcome::MaintenanceSucceeded { .. }),
                    "maintenance outcome on build response"
                );
            }
            Self::Live {
                pool,
                acceptance,
                phase,
                prepared_digest,
                input,
                outcome,
                ownership,
                accepted_at,
                renewed_at,
                reserved_at,
                settled_at,
            } => {
                validate_acceptance(acceptance)?;
                if let Some(input) = input {
                    input.validate()?;
                    anyhow::ensure!(
                        ownership.is_some()
                            && !matches!(phase, Phase::Pending | Phase::Queued | Phase::Starting),
                        "input state without admitted worker"
                    );
                }
                if let Some(prepared) = prepared_digest {
                    digest(prepared)?;
                    anyhow::ensure!(
                        ownership.is_some()
                            && !matches!(phase, Phase::Pending | Phase::Queued | Phase::Starting),
                        "preparation without admitted worker"
                    );
                }
                if let Some(owner) = ownership {
                    owner.validate(&acceptance.attempt_id)?;
                }
                anyhow::ensure!(
                    accepted_at <= renewed_at
                        && reserved_at.is_none_or(|t| *accepted_at <= t)
                        && settled_at
                            .is_none_or(|t| *renewed_at <= t && reserved_at.is_none_or(|r| r <= t))
                        && settled_at.is_some() == outcome.is_some(),
                    "invalid status timestamps"
                );
                if outcome.is_none() && ownership.is_some() {
                    anyhow::ensure!(
                        matches!(
                            pool,
                            PoolHealth::Owned | PoolHealth::Draining | PoolHealth::Quarantined
                        ),
                        "active owner in idle pool"
                    );
                }
                let expected = match outcome {
                    Some(outcome) => {
                        outcome.validate(&acceptance.spec_digest)?;
                        match outcome {
                            Outcome::Succeeded { artifacts } => {
                                anyhow::ensure!(
                                    prepared_digest.as_ref() == Some(&artifacts.preparation_digest),
                                    "success preparation mismatch"
                                );
                                anyhow::ensure!(ownership.is_some(), "success without execution");
                                Phase::Succeeded
                            }
                            Outcome::MaintenanceSucceeded { .. } => {
                                anyhow::bail!("maintenance outcome on build response")
                            }
                            Outcome::Interrupted => {
                                anyhow::ensure!(
                                    ownership.is_some(),
                                    "interruption without execution"
                                );
                                Phase::Interrupted
                            }
                            Outcome::Failed { reason } => {
                                reason.validate(ownership.is_some())?;
                                Phase::Failed
                            }
                            Outcome::Cancelled { .. } => Phase::Cancelled,
                        }
                    }
                    None => {
                        anyhow::ensure!(
                            matches!(
                                phase,
                                Phase::Pending
                                    | Phase::Queued
                                    | Phase::Starting
                                    | Phase::Running
                                    | Phase::Verifying
                                    | Phase::Stopping
                            ),
                            "terminal status without outcome"
                        );
                        if matches!(phase, Phase::Pending | Phase::Queued) {
                            anyhow::ensure!(ownership.is_none(), "early execution ownership");
                        }
                        if *phase == Phase::Verifying {
                            anyhow::ensure!(
                                prepared_digest.is_some(),
                                "verification without prepared inputs"
                            );
                        }
                        if matches!(phase, Phase::Starting | Phase::Running | Phase::Verifying) {
                            anyhow::ensure!(ownership.is_some(), "missing execution ownership");
                        }
                        *phase
                    }
                };
                anyhow::ensure!(
                    *phase == expected && ownership.is_some() == reserved_at.is_some(),
                    "status lifecycle mismatch"
                );
            }
        }
        Ok(())
    }
}

impl From<JobStatus> for Snapshot {
    fn from(status: JobStatus) -> Self {
        match status {
            JobStatus::Live {
                pool,
                attempt,
                prepared,
                input,
                acceptance,
                accepted_at,
                renewed_at,
                reserved_at,
                settled_at,
                ..
            } => Self::Live {
                pool,
                phase: attempt.phase(),
                prepared_digest: prepared.map(|value| value.digest),
                input,
                outcome: attempt.outcome().cloned(),
                ownership: attempt.0.state.ownership().cloned(),
                acceptance,
                accepted_at,
                renewed_at,
                reserved_at,
                settled_at,
            },
            JobStatus::Retired {
                pool,
                acceptance,
                outcome,
            } => Self::Retired {
                pool,
                acceptance,
                outcome,
            },
        }
    }
}

/// A service-authenticated declaration, not a grant or settlement receipt.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Description {
    pub identity: StorageIdentity,
    pub policy: AdmissionPolicy,
    pub issuer: String,
}

impl Description {
    pub fn validate(&self) -> Result<()> {
        self.identity.validate()?;
        self.policy.validate()?;
        identifier(&self.issuer)
    }
}

/// Distinct consumer, release and cleanup observations. Not build settlement.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ConsumerState {
    pub receipt_digest: String,
    pub release_digest: Option<String>,
    /// Physical cleanup + positive cleanup-worker settlement, not metadata expiry.
    pub retired: bool,
}

impl ConsumerState {
    fn validate(&self) -> Result<()> {
        digest(&self.receipt_digest)?;
        if let Some(release) = &self.release_digest {
            digest(release)?;
        }
        anyhow::ensure!(
            !self.retired || self.release_digest.is_some(),
            "consumer retirement precedes release"
        );
        Ok(())
    }
}

/// Abandonment is not a consumer receipt. Release/retirement follow separately.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AbandonmentState {
    pub abandonment_digest: String,
    pub release_digest: Option<String>,
    /// Same cleanup proof as ConsumerState; never an acknowledgement.
    pub retired: bool,
}

impl AbandonmentState {
    fn validate(&self) -> Result<()> {
        digest(&self.abandonment_digest)?;
        if let Some(release) = &self.release_digest {
            digest(release)?;
        }
        anyhow::ensure!(
            !self.retired || self.release_digest.is_some(),
            "abandonment retirement precedes release"
        );
        Ok(())
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Reply {
    Description {
        declaration: Description,
    },
    Accepted {
        acceptance: Acceptance,
    },
    Status {
        snapshot: Box<Snapshot>,
    },
    /// An idempotent stop request ACK, not a terminal cancellation receipt.
    StopRequested {
        attempt_id: String,
    },
    Renewed {
        attempt_id: String,
    },
    ConsumerAcknowledged {
        attempt_id: String,
        receipt_digest: String,
    },
    ConsumerStatus {
        attempt_id: String,
        state: Option<ConsumerState>,
    },
    /// Durable abandonment intent, not completed builder cleanup.
    ConsumerAbandoned {
        attempt_id: String,
        abandonment_digest: String,
    },
    ConsumerAbandonmentStatus {
        attempt_id: String,
        state: Option<AbandonmentState>,
    },
    Artifacts {
        page: super::ArtifactPage,
    },
    Planning {
        page: super::ArtifactPage,
    },
    Events {
        page: EventPage,
    },
    Logs {
        page: LogPage,
    },
    Rejected {
        code: Rejection,
    },
    /// Observe/resubmit the SAME identity. Never replay a realization command.
    Unconfirmed {
        code: Unconfirmed,
    },
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Response {
    pub version: u32,
    pub reply: Reply,
}

impl Response {
    fn validate(&self) -> Result<()> {
        anyhow::ensure!(self.version == VERSION, "unsupported response version");
        match &self.reply {
            Reply::Description { declaration } => declaration.validate()?,
            Reply::Accepted { acceptance } => validate_acceptance(acceptance)?,
            Reply::Status { snapshot } => snapshot.validate()?,
            Reply::StopRequested { attempt_id } | Reply::Renewed { attempt_id } => {
                digest(attempt_id)?
            }
            Reply::ConsumerAcknowledged {
                attempt_id,
                receipt_digest,
            } => {
                digest(attempt_id)?;
                digest(receipt_digest)?;
            }
            Reply::ConsumerAbandoned {
                attempt_id,
                abandonment_digest,
            } => {
                digest(attempt_id)?;
                digest(abandonment_digest)?;
            }
            Reply::ConsumerAbandonmentStatus { attempt_id, state } => {
                digest(attempt_id)?;
                if let Some(state) = state {
                    state.validate()?;
                }
            }
            Reply::ConsumerStatus { attempt_id, state } => {
                digest(attempt_id)?;
                if let Some(state) = state {
                    state.validate()?;
                }
            }
            Reply::Artifacts { page } => page.validate()?,
            Reply::Planning { page } => {
                page.validate()?;
                anyhow::ensure!(
                    page.total <= super::preparation::MAX_PREPARED_BYTES as u64,
                    "private planning exceeds bound"
                );
            }
            Reply::Events { page } => page.validate()?,
            Reply::Logs { page } => page.validate()?,
            Reply::Rejected { .. } | Reply::Unconfirmed { .. } => {}
        }
        Ok(())
    }

    /// Bind a structurally valid receipt to this exact caller operation. A valid
    /// frame for another attempt/verb is not evidence for the requested work.
    pub fn validate_for(&self, request: &Request) -> Result<()> {
        self.validate()?;
        anyhow::ensure!(request.version == VERSION, "unsupported request version");
        request.validate()?;
        let matches = match (&request.command, &self.reply) {
            (_, Reply::Rejected { .. } | Reply::Unconfirmed { .. }) => true,
            (Command::Describe, Reply::Description { .. }) => true,
            (
                Command::Planning {
                    attempt_id,
                    artifact_digest,
                    planning_digest,
                    offset,
                },
                Reply::Planning { page },
            ) => {
                attempt_id == &page.attempt_id
                    && artifact_digest == &page.artifact_digest
                    && planning_digest == &page.projection_digest
                    && *offset == page.offset
            }
            (
                Command::Artifacts {
                    attempt_id,
                    artifact_digest,
                    offset,
                },
                Reply::Artifacts { page },
            ) => {
                attempt_id == &page.attempt_id
                    && artifact_digest == &page.artifact_digest
                    && *offset == page.offset
            }
            (
                Command::ConsumerStatus { attempt_id },
                Reply::ConsumerStatus {
                    attempt_id: received,
                    ..
                },
            ) => attempt_id == received,
            (
                Command::ConsumerAbandonmentStatus { attempt_id },
                Reply::ConsumerAbandonmentStatus {
                    attempt_id: received,
                    ..
                },
            ) => attempt_id == received,
            (
                Command::AbandonConsumer { abandonment },
                Reply::ConsumerAbandoned {
                    attempt_id,
                    abandonment_digest,
                },
            ) => {
                *attempt_id == abandonment.ownership.attempt_id
                    && *abandonment_digest == abandonment.digest()?
            }
            (
                Command::AcknowledgeConsumer { receipt },
                Reply::ConsumerAcknowledged {
                    attempt_id,
                    receipt_digest,
                },
            ) => {
                *attempt_id == receipt.ownership.attempt_id
                    && *receipt_digest == receipt.digest()?
            }
            (
                Command::SubmitNative { request } | Command::WithdrawNative { request },
                Reply::Accepted { acceptance },
            ) => {
                acceptance.attempt_id == request.attempt_id()?
                    && acceptance.spec_digest == request.digest()?
            }
            (
                Command::Submit { request } | Command::Withdraw { request },
                Reply::Accepted { acceptance },
            ) => {
                acceptance.attempt_id == request.attempt_id()?
                    && acceptance.spec_digest == request.digest()?
            }
            (Command::Status { attempt_id }, Reply::Status { snapshot }) => {
                let acceptance = match snapshot.as_ref() {
                    Snapshot::Live { acceptance, .. } | Snapshot::Retired { acceptance, .. } => {
                        acceptance
                    }
                };
                acceptance.attempt_id == *attempt_id
            }
            (
                Command::Cancel { attempt_id, .. },
                Reply::StopRequested {
                    attempt_id: received,
                },
            )
            | (
                Command::Renew { attempt_id, .. },
                Reply::Renewed {
                    attempt_id: received,
                },
            ) => attempt_id == received,
            (
                Command::Events {
                    attempt_id,
                    cursor,
                    limit,
                },
                Reply::Events { page },
            ) => {
                let after = cursor.as_ref().map_or(0, |cursor| cursor.after);
                page.next.attempt_id == *attempt_id
                    && page.events.len() <= *limit
                    && page.next.after >= after
                    && page
                        .events
                        .first()
                        .is_none_or(|event| event.sequence > after)
            }
            (
                Command::Logs {
                    attempt_id,
                    cursor,
                    limit,
                },
                Reply::Logs { page },
            ) => {
                page.next.attempt_id == *attempt_id
                    && page.bytes.len() <= *limit
                    && cursor.as_ref().is_none_or(|cursor| {
                        page.gap
                            || (page.next.generation == cursor.generation
                                && cursor.offset.checked_add(page.bytes.len() as u64)
                                    == Some(page.next.offset))
                    })
            }
            _ => false,
        };
        anyhow::ensure!(matches, "control receipt does not match request");
        Ok(())
    }

    pub fn encode(&self) -> Result<Vec<u8>> {
        self.validate()?;
        let bytes = serde_json::to_vec(self)?;
        anyhow::ensure!(
            bytes.len() <= MAX_FRAME_BYTES,
            "response exceeds frame bound"
        );
        Ok(bytes)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self> {
        anyhow::ensure!(
            bytes.len() <= MAX_FRAME_BYTES,
            "response exceeds frame bound"
        );
        let response: Self = serde_json::from_slice(bytes)?;
        response.validate()?;
        Ok(response)
    }
}

impl Journal {
    /// Only for an already authenticated issuer. `now` comes from the service.
    /// No registration as a CLI/forced command or executor capability is implied.
    pub fn handle(&self, issuer: &str, bytes: &[u8], now: u64) -> Response {
        let result = Request::decode(bytes)
            .map_err(anyhow::Error::from)
            .and_then(|request| {
                identifier(issuer).map_err(|_| Rejection::Unauthorized)?;
                match request.command {
                    Command::Describe => Ok(Reply::Description {
                        declaration: Description {
                            identity: self.identity().clone(),
                            policy: self.admission_policy().clone(),
                            issuer: issuer.to_owned(),
                        },
                    }),
                    Command::SubmitNative { request } => self
                        .submit_native(issuer, *request, now)
                        .map(|acceptance| Reply::Accepted { acceptance }),
                    Command::WithdrawNative { request } => self
                        .withdraw_native(issuer, *request, now)
                        .map(|acceptance| Reply::Accepted { acceptance }),
                    Command::Withdraw { request } => self
                        .withdraw(issuer, *request, now)
                        .map(|acceptance| Reply::Accepted { acceptance }),
                    Command::Submit { request } => self
                        .submit(issuer, *request, now)
                        .map(|acceptance| Reply::Accepted { acceptance }),
                    Command::ConsumerStatus { attempt_id } => self
                        .consumer_status(issuer, &attempt_id)
                        .map(|state| Reply::ConsumerStatus { attempt_id, state }),
                    Command::Artifacts {
                        attempt_id,
                        artifact_digest,
                        offset,
                    } => self
                        .artifact_page(issuer, &attempt_id, &artifact_digest, offset)
                        .map(|page| Reply::Artifacts { page }),
                    Command::Planning {
                        attempt_id,
                        artifact_digest,
                        planning_digest,
                        offset,
                    } => self
                        .planning_page(
                            issuer,
                            &attempt_id,
                            &artifact_digest,
                            &planning_digest,
                            offset,
                        )
                        .map(|page| Reply::Planning { page }),
                    Command::ConsumerAbandonmentStatus { attempt_id } => self
                        .consumer_abandonment_status(issuer, &attempt_id)
                        .map(|state| Reply::ConsumerAbandonmentStatus { attempt_id, state }),
                    Command::AbandonConsumer { abandonment } => {
                        let attempt_id = abandonment.ownership.attempt_id.clone();
                        self.abandon_consumer(issuer, *abandonment, now)
                            .map(|abandonment_digest| Reply::ConsumerAbandoned {
                                attempt_id,
                                abandonment_digest,
                            })
                    }
                    Command::AcknowledgeConsumer { receipt } => {
                        let attempt_id = receipt.ownership.attempt_id.clone();
                        self.acknowledge_consumer(issuer, *receipt, now)
                            .map(|receipt_digest| Reply::ConsumerAcknowledged {
                                attempt_id,
                                receipt_digest,
                            })
                    }
                    Command::Status { attempt_id } => {
                        self.status(issuer, &attempt_id)
                            .map(|status| Reply::Status {
                                snapshot: Box::new(status.into()),
                            })
                    }
                    Command::Cancel {
                        attempt_id,
                        expected,
                    } => self
                        .cancel(issuer, &attempt_id, expected.as_ref(), now)
                        .map(|()| Reply::StopRequested { attempt_id }),
                    Command::Renew {
                        attempt_id,
                        expected,
                        token,
                    } => self
                        .renew(
                            issuer,
                            &attempt_id,
                            expected.as_ref(),
                            token.as_bytes(),
                            now,
                        )
                        .map(|()| Reply::Renewed { attempt_id }),
                    Command::Events {
                        attempt_id,
                        cursor,
                        limit,
                    } => self
                        .events(issuer, &attempt_id, cursor.as_ref(), limit)
                        .map(|page| Reply::Events { page }),
                    Command::Logs {
                        attempt_id,
                        cursor,
                        limit,
                    } => self
                        .logs(issuer, &attempt_id, cursor.as_ref(), limit)
                        .map(|page| Reply::Logs { page }),
                }
            });
        let reply = result.unwrap_or_else(|error| {
            // Persistence context wins: never turn uncertain publication into rejection.
            if let Some(code) = error.downcast_ref::<Unconfirmed>() {
                Reply::Unconfirmed { code: *code }
            } else if let Some(code) = error.downcast_ref::<Rejection>() {
                Reply::Rejected { code: *code }
            } else {
                Reply::Unconfirmed {
                    code: Unconfirmed::Unavailable,
                }
            }
        });
        Response {
            version: VERSION,
            reply,
        }
    }
}
