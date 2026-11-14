//! Nix-managed backend: retain the existing native fleet pipeline.

use anyhow::Result;

use crate::fleet::cli::Invocation;
use crate::fleet::runtime::RuntimeConfig;

pub(super) fn run(invocation: Invocation, runtime: RuntimeConfig) -> Result<()> {
    crate::fleet::runtime::run_nix(invocation, runtime)
}
