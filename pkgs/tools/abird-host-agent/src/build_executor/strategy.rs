//! Build-backend selection shared by fleet and the executor protocol.
//!
//! `auto` retains Nix management until a separately reviewed cutover. Public
//! names do not migrate durable encodings or advertise executor capability.
//! Explicit `agent` is experimental: installed caller/builder profiles
//! (default off, `acceptSubmissions`) remain its availability gate.

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};

pub const AGENT_EXPERIMENTAL: &str = "warning: --strategy=agent is experimental; installed \
caller/builder profiles are required; production rollout requires separate approval";

/// Independent observer handoff is separate from foreground CI execution.
pub const AGENT_CI_DEFERRED: &str = "independent agent CI observer ownership is not available \
yet; use a foreground controller profile or --strategy=nix";

/// Internal guard: the agent backend never enters the nix pipeline/engine.
pub const AGENT_BACKEND_ONLY: &str = "agent build strategy runs only through its own backend";

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Strategy {
    #[default]
    Auto,
    // Retained invocation/request bytes are a separate migration boundary.
    #[serde(rename = "legacy")]
    Nix,
    #[serde(rename = "owned")]
    Agent,
}

/// Only implemented execution paths belong here; additions require dispatch changes.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionStrategy {
    Nix,
    /// Experimental; dispatched before any nix-pipeline effect.
    Agent,
}

impl ExecutionStrategy {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Nix => "nix",
            Self::Agent => "agent",
        }
    }
}

impl Strategy {
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "auto" => Ok(Self::Auto),
            "nix" | "legacy" => Ok(Self::Nix),
            "agent" | "owned" => Ok(Self::Agent),
            _ => bail!("unsupported build strategy {value:?}; expected auto|nix|agent"),
        }
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Nix => "nix",
            Self::Agent => "agent",
        }
    }

    /// Existing CI/re-exec peers still understand these transport spellings.
    pub const fn wire_name(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Nix => "legacy",
            Self::Agent => "owned",
        }
    }

    pub fn resolve(self) -> Result<ExecutionStrategy> {
        match self {
            Self::Auto | Self::Nix => Ok(ExecutionStrategy::Nix),
            Self::Agent => Ok(ExecutionStrategy::Agent),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requested_and_executable_strategies_are_distinct() {
        for requested in [Strategy::Auto, Strategy::Nix] {
            assert_eq!(requested.resolve().unwrap(), ExecutionStrategy::Nix);
        }
        for name in ["agent", "owned"] {
            assert_eq!(Strategy::parse(name).unwrap(), Strategy::Agent);
        }
        for name in ["nix", "legacy"] {
            assert_eq!(Strategy::parse(name).unwrap(), Strategy::Nix);
        }
        // Explicit only: auto never selects the experimental backend.
        assert_eq!(Strategy::Agent.resolve().unwrap(), ExecutionStrategy::Agent);
    }

    #[test]
    fn public_names_change_without_rewriting_retained_wire_bytes() {
        for (strategy, wire) in [
            (Strategy::Auto, "auto"),
            (Strategy::Nix, "legacy"),
            (Strategy::Agent, "owned"),
        ] {
            assert_eq!(Strategy::parse(strategy.as_str()).unwrap(), strategy);
            assert_eq!(strategy.wire_name(), wire);
            assert_eq!(serde_json::to_value(strategy).unwrap(), wire);
            assert_eq!(
                serde_json::from_value::<Strategy>(wire.into()).unwrap(),
                strategy
            );
        }
        for invalid in ["", "AUTO", "a+", " nix", "agent ", "agent;exit", "default"] {
            assert!(Strategy::parse(invalid).is_err());
            assert!(serde_json::from_value::<Strategy>(invalid.into()).is_err());
        }
        // New CLI names must not silently widen the existing wire schema.
        for name in ["nix", "agent"] {
            assert!(serde_json::from_value::<Strategy>(name.into()).is_err());
        }
    }
}
