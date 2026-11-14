//! Accounted failed/consumed/abandoned-Build cleanup, not another execution or collector.
//! The original outcome is immutable. Cleanup failure retains its one-shot claim.

pub(super) mod file;

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, ensure};

use super::daemon::{self, Authority};
use super::launch_gate::{Permission, Permit};
use super::maintenance::Operation;
use super::protection::NativeRoots;
use super::store_interlock::StoreInterlock;
use super::{ExecutionHandle, Phase, role, workload};

pub(super) fn run_installed(role: &role::Policy, attempt: &str) -> Result<()> {
    super::digest(attempt)?;
    let Authority {
        policy,
        journal,
        gate,
    } = daemon::open_authority(&role.daemon_policy, &role.control)?;
    ensure!(
        policy.containment_digest == role.digest()?,
        "retirement role binding differs"
    );
    let owner = journal.pool()?.owner.context("retirement owner missing")?;
    ensure!(owner.attempt_id == attempt, "retirement instance differs");
    workload::require_client_placement(&owner)?;
    let handle = ExecutionHandle {
        ownership: owner.clone(),
        invocation_id: std::env::var("INVOCATION_ID")
            .context("retirement invocation unavailable")?,
    };
    handle.validate(attempt)?;
    let monotonic = Instant::now();
    let wall = SystemTime::now().duration_since(UNIX_EPOCH)?;
    let status = journal.maintenance_status(attempt)?;
    ensure!(
        status.attempt.phase() == Phase::Starting
            && matches!(
                status.request.operation,
                Operation::RetireFailed { .. }
                    | Operation::RetireConsumed { .. }
                    | Operation::RetireAbandoned { .. }
            ),
        "retirement already consumed or operation differs"
    );
    let deadline = super::process::cutoff(
        status.reserved_at,
        status.request.deadlines.runtime_seconds,
        wall,
        monotonic,
    )?;
    let store = StoreInterlock::open(journal.identity().clone())?;
    let guard = loop {
        ensure!(Instant::now() < deadline, "retirement deadline expired");
        if let Some(guard) = store.try_retirement(&journal, &owner, daemon::now()?)? {
            break guard;
        }
        std::thread::park_timeout(Duration::from_millis(10));
    };
    {
        let _launch = gate
            .authorize(&Permit {
                version: 1,
                identity: journal.identity().clone(),
                permission: Permission::Execution {
                    ownership: owner.clone(),
                },
            })?
            .context("retirement launch fenced")?;
        guard.validate(&journal, daemon::now()?)?;
        // No native-phase gate, daemon claim, client/store RPC or source producer.
        journal.begin_worker(handle.clone(), daemon::now()?)?;
    }
    journal.diagnose(&handle, super::diagnostics::Activity::Retire, || {
        let target = journal.begin_retirement(&owner, daemon::now()?)?;
        let active = || -> Result<()> {
            ensure!(Instant::now() < deadline, "retirement deadline expired");
            guard.validate(&journal, daemon::now()?)
        };
        active()?;
        if let Some(original) = &target.owner {
            let retire_controller = || {
                journal.diagnose(
                    &handle,
                    super::diagnostics::Activity::RetireController,
                    || {
                        super::controller_service::retire(
                            &journal, &owner, original, role, deadline,
                        )
                    },
                )
            };
            if !target.successful {
                retire_controller()?;
                active()?;
            }
            journal.diagnose(&handle, super::diagnostics::Activity::RetireRoots, || {
                if NativeRoots::absent(&journal, original)? {
                    ensure!(!target.successful, "successful Build protection is missing");
                    journal.released(&target.attempt_id, &target.evidence, daemon::now()?)?;
                } else {
                    let roots = NativeRoots::open(&journal, original.clone())?;
                    roots.release_while(&journal, &target.evidence, || {
                        active()?;
                        daemon::now()
                    })?;
                    active()?;
                    NativeRoots::retire(&journal, original)?;
                }
                Ok(())
            })?;
            active()?;
            if target.successful {
                // Positive settlement plus an exact ACK or abandonment permits
                // root release. A live CI observer may await that receipt before
                // handoff/abandonment; never wait on it first.
                // Parent/data retirement still requires original observer Empty.
                retire_controller()?;
                active()?;
            }
            if target.artifact {
                journal.diagnose(
                    &handle,
                    super::diagnostics::Activity::RetireArtifacts,
                    || super::artifacts::retire(&journal, original, active),
                )?;
            }
            active()?;
            if target.native_phase {
                journal.diagnose(&handle, super::diagnostics::Activity::RetireNative, || {
                    super::native_phase::Gate::retire(&journal, original, active)
                })?;
            }
            active()?;
            if target.source {
                journal.diagnose(&handle, super::diagnostics::Activity::RetireSource, || {
                    super::private_sources::SourceSlot::retire_settled(
                        &journal,
                        &owner,
                        original,
                        role.build.uid,
                        deadline,
                    )
                })?;
            } else {
                ensure!(
                    super::source_transport::absent(&original.attempt_id)?,
                    "unregistered source endpoint residue"
                );
            }
        } else {
            ensure!(
                !target.source && !target.native_phase && !target.artifact,
                "unlaunched target contains execution state"
            );
            journal.released(&target.attempt_id, &target.evidence, daemon::now()?)?;
        }
        active()?;
        journal.finish_retirement(&handle, daemon::now()?)
    })
    // Worker exit is not settlement. The existing supervisor fences ingress,
    // observes the aggregate positively empty and settles this cleanup attempt.
}
