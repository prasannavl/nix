//! Caller dispatch over either resolved or early native intent. Same manifest,
//! controller and transport claims; no extra queue or executor.

use abird_host_agent::build_executor::{
    native_intent,
    protocol::Command,
    request::{BuildRequest, Owner, Peer},
};
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize)]
#[serde(
    tag = "kind",
    content = "request",
    rename_all = "snake_case",
    deny_unknown_fields
)]
pub(crate) enum Intent {
    Build(Box<BuildRequest>),
    Native(Box<native_intent::Request>),
}

impl Intent {
    pub fn validate(&self) -> Result<()> {
        match self {
            Self::Build(request) => {
                request.validate()?;
                ensure!(
                    request.parent.is_none(),
                    "resolved native intent cannot be resubmitted"
                );
                Ok(())
            }
            Self::Native(request) => request.validate(),
        }
    }
    pub fn digest(&self) -> Result<String> {
        match self {
            Self::Build(r) => r.digest(),
            Self::Native(r) => r.digest(),
        }
    }
    pub fn attempt_id(&self) -> Result<String> {
        match self {
            Self::Build(r) => r.attempt_id(),
            Self::Native(r) => r.attempt_id(),
        }
    }
    pub fn builder(&self) -> &Peer {
        match self {
            Self::Build(r) => &r.builder,
            Self::Native(r) => &r.builder,
        }
    }
    pub fn controller(&self) -> &Peer {
        match self {
            Self::Build(r) => &r.controller,
            Self::Native(r) => &r.controller,
        }
    }
    pub fn runtime_seconds(&self) -> u64 {
        match self {
            Self::Build(r) => r.deadlines.runtime_seconds,
            Self::Native(r) => r.deadlines.runtime_seconds,
        }
    }
    pub fn owner(&self) -> &Owner {
        match self {
            Self::Build(r) => &r.owner,
            Self::Native(r) => &r.owner,
        }
    }
    pub fn run_id(&self) -> &str {
        match self {
            Self::Build(r) => &r.run_id,
            Self::Native(r) => &r.run_id,
        }
    }
    pub fn submit(&self) -> Command {
        match self {
            Self::Build(r) => Command::Submit { request: r.clone() },
            Self::Native(r) => Command::SubmitNative { request: r.clone() },
        }
    }
    pub fn withdraw(&self) -> Command {
        match self {
            Self::Build(r) => Command::Withdraw { request: r.clone() },
            Self::Native(r) => Command::WithdrawNative { request: r.clone() },
        }
    }
    pub fn validate_resolved(&self, request: &BuildRequest) -> Result<()> {
        request.validate()?;
        ensure!(
            match self {
                Self::Build(original) => original.as_ref() == request,
                Self::Native(original) => request.parent.as_deref() == Some(original.as_ref()),
            },
            "retained resolved intent differs"
        );
        Ok(())
    }
    pub fn material(&self, bytes: &[u8]) -> Result<()> {
        match self {
            Self::Build(r) => {
                abird_host_agent::build_executor::preparation::source::Material::decode(bytes, r)?;
            }
            Self::Native(r) => {
                native_intent::Delivery::decode(bytes, r)?;
            }
        }
        Ok(())
    }
    pub fn build(&self) -> Result<&BuildRequest> {
        match self {
            Self::Build(r) => Ok(r),
            _ => anyhow::bail!("native intent has not been captured"),
        }
    }
}
