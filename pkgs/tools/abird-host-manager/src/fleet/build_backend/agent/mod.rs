//! Agent-managed build backend. Caller/controller code owns orchestration;
//! the host agent's build executor owns admission, supervision and settlement.
//! Existing private commands and durable namespaces remain wire-compatible.

pub mod acquisition;
pub mod bootstrap;
pub mod capture;
pub mod commands;
pub mod control;
pub mod controller;
pub mod deployment;
pub mod entry;
pub mod remote_capture;
pub(crate) mod run;
pub mod service;
