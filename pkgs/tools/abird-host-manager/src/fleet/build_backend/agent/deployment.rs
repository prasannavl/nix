//! Deployment of one settled, consumed and released owned attempt through the
//! ordinary fleet phases (snapshot, acquire, deploy, health, rollback). Inputs
//! are retained evaluated planning only: layers/dependencies with caller-side
//! route resolution, selection, activation facts, consumer-rooted closures and
//! the exact evaluated source tree. No flake/source re-evaluation, realization
//! or builder access; target-local activation/rollback authority is unchanged.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{Context, Result, ensure};

use super::controller::Controller;
use crate::fleet::build::NixStorePath;
use crate::fleet::cli::Action;
use crate::fleet::deploy::BootEnvironment;
use crate::fleet::inventory_routing::{RouteRequest, SelfIdentity};
use crate::fleet::native::{ForwardWorkGuard, NativeFleetEffects, OwnedHandoff};
use crate::fleet::preparation::{Routes, select_inventory};
use crate::fleet::presentation::FleetProgress;

/// Proof that the caller holds the ordinary host-local action lock, which
/// target activation relies on when the controller is also a target.
pub struct ActionLock(pub Option<crate::fleet::run_state::ActionMutex>);

pub fn deploy(parent: &Controller, attempt: &str, nix: &Path, _lock: &ActionLock) -> Result<()> {
    check_interrupted(parent)?;
    let invocation = parent.original_invocation(attempt)?;
    ensure!(
        matches!(invocation.action, Action::Deploy),
        "retained deployment requires the original Deploy action"
    );
    ensure!(
        parent.source_release(attempt)?.is_some(),
        "deployment follows observed source-protection release"
    );
    let restored = parent.restored_planning(attempt)?;
    let delivery = parent.retained(attempt)?;
    let options = &invocation.options;
    let identity = (options.route == RouteRequest::Auto)
        .then(SelfIdentity::detect)
        .transpose()?;
    let inventory = restored.inventory_with(Routes::Resolve {
        request: options.route,
        source: options.route_source,
        identity: identity.as_ref(),
    })?;
    let selection = select_inventory(&inventory, options)?;
    ensure!(
        serde_json::to_string(&selection)? == serde_json::to_string(&restored.selection)?,
        "deployment selection differs from retained planning"
    );
    let cache = super::controller::acquisition_source(Some(options), Some(&restored.inventory))?;
    // The ordinary short-lived run state (runtime roots, SSH control paths,
    // diagnostics retention and cleanup) shared with nix-managed runs.
    let state = crate::fleet::runtime::allocate_run_state(
        &crate::fleet::runtime::RuntimeConfig::from_environment(),
    )?;
    let handoff = handoff(
        &delivery,
        &restored.activation,
        state.layout().run_dir.clone(),
        parent.builder(attempt)?.host_id.clone(),
        crate::fleet::build::CacheSource::new(cache, Vec::<String>::new())?,
    )?;
    // Consumer-rooted exact evaluated tree: declared keys/identities are read
    // from the built source, never from a mutable checkout.
    let tree = PathBuf::from(&delivery.prepared.source_path);
    ensure!(
        std::fs::symlink_metadata(&tree).is_ok_and(|metadata| metadata.is_dir()),
        "evaluated source tree is not retained locally"
    );
    let source_identity = parent.source_identity(attempt)?;
    FleetProgress::begin_command(options);
    crate::fleet::runtime::announce_execution_metadata(
        &invocation,
        source_identity.display(),
        Some(abird_host_agent::build_executor::strategy::ExecutionStrategy::Agent),
    );
    let diagnostics = state.layout().diagnostic_dir.clone();
    let result = (|| {
        let durable_check = || {
            ensure!(!parent.cancelled()?, "durable parent is cancelling");
            Ok(())
        };
        let forward_work = ForwardWorkGuard::new(&durable_check);
        let mut effects = NativeFleetEffects::with_owned_handoff(
            &invocation,
            nix,
            &tree,
            &inventory,
            &selection,
            handoff,
            &diagnostics,
        )?
        .with_forward_work(forward_work)?;
        let started = Instant::now();
        let result = effects.execute();
        let _ = source_identity.record(&diagnostics);
        effects.report_summary(&result, started.elapsed());
        result
    })();
    crate::fleet::runtime::finish_run_state(state, result)
}

/// Forward-work veto, not a process signal: active effects must settle and the
/// ordinary rollback adapter must remain usable while the marker is present.
pub(super) fn check_interrupted(parent: &Controller) -> Result<()> {
    crate::fleet::signal::check_interrupted()?;
    ensure!(!parent.cancelled()?, "durable parent is cancelling");
    Ok(())
}

#[cfg(test)]
mod cancellation_tests;

fn handoff(
    delivery: &abird_host_agent::build_executor::ArtifactDelivery,
    activation: &BTreeMap<String, bool>,
    runtime: PathBuf,
    builder: String,
    cache: crate::fleet::build::CacheSource,
) -> Result<OwnedHandoff> {
    let mut closures = BTreeMap::new();
    let mut boot = BTreeMap::new();
    for target in &delivery.prepared.targets {
        let host = &target.target.host;
        let output = delivery
            .host_outputs(host)?
            .remove("out")
            .context("system output missing")?;
        closures.insert(host.clone(), NixStorePath::closure_output(&output)?);
        let container = activation
            .get(host)
            .with_context(|| format!("retained activation fact missing for {host}"))?;
        boot.insert(
            host.clone(),
            if *container {
                BootEnvironment::Container
            } else {
                BootEnvironment::Physical
            },
        );
    }
    ensure!(
        activation.len() == closures.len(),
        "retained activation facts exceed prepared targets"
    );
    Ok(OwnedHandoff {
        closures,
        boot,
        builder,
        cache,
        runtime,
    })
}
