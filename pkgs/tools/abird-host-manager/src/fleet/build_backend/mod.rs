//! Build-lifecycle backends. Shared planning and deployment remain in fleet.

pub mod agent;
pub mod nix;

use abird_host_agent::build_executor::strategy::Strategy;
use anyhow::Result;

use super::cli::Invocation;
use super::runtime::RuntimeConfig;

pub(crate) fn run(invocation: Invocation, runtime: RuntimeConfig) -> Result<()> {
    // CI's ordinary caller resolves/forwards SHA and patch. The receiving
    // controller owns checkout, evaluation and realization after admission.
    if invocation.options.strategy == Strategy::Agent
        && invocation.action.uses_build_strategy()
        && !invocation.options.ci_trigger
    {
        eprintln!(
            "{}",
            abird_host_agent::build_executor::strategy::AGENT_EXPERIMENTAL
        );
        return agent::controller::run_installed(invocation);
    }
    nix::run(invocation, runtime)
}
