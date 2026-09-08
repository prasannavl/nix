//! Native fleet build and deployment control plane.
//!
//! This module owns the behavior historically implemented by the repository's
//! `nixbot` shell script. Pure inventory, selection, and planning code remains
//! separate from adapters that execute Git, Nix, SSH, systemd, and OpenTofu.

pub mod bootstrap;
pub mod build;
pub mod build_lease;
pub mod build_runtime;
pub mod ci_runtime;
pub mod cli;
pub mod deploy;
pub mod engine;
pub mod environment;
pub mod forced_command;
pub mod health;
pub mod health_runtime;
pub mod host_runtime;
pub mod inventory;
pub mod maintenance;
pub mod native;
pub mod orchestration;
pub mod plan;
pub mod presentation;
pub mod repository;
pub mod run_state;
pub mod runtime;
pub mod selection;
pub mod signal;
pub mod system;
pub mod terraform;
pub mod terraform_runtime;
pub mod transport;
pub mod workspace;
