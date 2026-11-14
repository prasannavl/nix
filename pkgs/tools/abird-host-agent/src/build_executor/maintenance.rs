//! Trusted maintenance intent, not a public caller command or execution grant.
//! Uses the same journal, admission pool, deadlines and settlement as builds.
//! No synthetic source/target, arbitrary argv, alternate store or capacity policy.

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

use super::request::{Deadlines, RequestId, StorageIdentity};
use super::{digest, identifier};
use crate::sha256::digest_bytes;

pub const VERSION: u32 = 1;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    CollectGarbage,
    /// Private, positively settled failed Build only. No native daemon/GC RPC.
    RetireFailed {
        attempt_id: String,
        spec_digest: String,
    },
    /// Verified, positively settled Build with the original consumer ACK.
    RetireConsumed {
        attempt_id: String,
        spec_digest: String,
        acknowledgement: String,
    },
    /// Verified, positively settled Build explicitly abandoned without an ACK.
    RetireAbandoned {
        attempt_id: String,
        spec_digest: String,
        abandonment: String,
    },
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u32,
    pub id: RequestId,
    pub storage: StorageIdentity,
    pub policy_digest: String,
    pub deadlines: Deadlines,
    pub operation: Operation,
}

impl Request {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.version == VERSION,
            "unsupported maintenance request version"
        );
        ensure!(self.id.issued_at > 0, "maintenance ID needs creation time");
        identifier(&self.id.nonce)?;
        self.storage.validate()?;
        digest(&self.policy_digest)?;
        self.deadlines.validate()?;
        match &self.operation {
            Operation::CollectGarbage => {}
            Operation::RetireFailed {
                attempt_id,
                spec_digest,
            } => {
                digest(attempt_id)?;
                digest(spec_digest)?;
            }
            Operation::RetireConsumed {
                attempt_id,
                spec_digest,
                acknowledgement,
            } => {
                digest(attempt_id)?;
                digest(spec_digest)?;
                digest(acknowledgement)?;
            }
            Operation::RetireAbandoned {
                attempt_id,
                spec_digest,
                abandonment,
            } => {
                digest(attempt_id)?;
                digest(spec_digest)?;
                digest(abandonment)?;
            }
        }
        Ok(())
    }

    pub fn attempt_id(&self) -> Result<String> {
        self.validate()?;
        Ok(digest_bytes(&serde_json::to_vec(&(
            "owned-maintenance-v1",
            &self.storage,
            &self.id,
        ))?))
    }

    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        Ok(digest_bytes(&serde_json::to_vec(&(
            "owned-maintenance-v1",
            self,
        ))?))
    }
}

/// Trusted-adapter observation only; never exposed through caller status/events.
/// A completed helper still needs verified effects and actual settlement.
pub struct Status {
    pub request: Request,
    pub acceptance: super::journal::Acceptance,
    pub attempt: super::Attempt,
    pub pool: super::PoolHealth,
    pub reserved_at: Option<u64>,
    pub settled_at: Option<u64>,
}
