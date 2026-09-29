//! Per-operation step vocabularies and the generic step runner.
//!
//! Each high-level host operation owns its own step type; the presentation
//! layer words them through [`StepSpec`] constructors. This module holds the
//! step types plus [`run_step`], the single place that drives a task's
//! `started`/`finished` lifecycle around a step's body.

use std::sync::Arc;
use std::time::Instant;

use anyhow::Result;

use super::signal::Interrupted;
use super::task::{StepSpec, StepSpecSource, Task, TaskOutcome, TaskScope};

/// Evaluate a plan, copy a derivation, realize it, then verify the closure.
pub enum BuildStep {
    Plan,
    Copy,
    Build,
    Realize { builder: String },
    ClosureCopy,
    ClosureVerify,
}

impl StepSpecSource for BuildStep {
    fn spec(&self, host: &str) -> StepSpec {
        match self {
            BuildStep::Plan => StepSpec::stage(format!("build-plan-{host}"), "build plan"),
            BuildStep::Copy => {
                StepSpec::stage(format!("build-{host}-copy-derivation"), "build copy")
            }
            BuildStep::Build => StepSpec::stage(format!("build-{host}"), "build"),
            BuildStep::Realize { builder } => {
                StepSpec::via(format!("build-{host}-via-{builder}"), "build", builder)
            }
            BuildStep::ClosureCopy => StepSpec::stage(
                format!("remote-build-copy-closure-local-{host}"),
                "closure copy",
            ),
            BuildStep::ClosureVerify => StepSpec::stage(
                format!("remote-build-verify-local-closure-{host}"),
                "closure verify",
            ),
        }
    }
}

/// Capture the pre-deploy generation.
pub enum SnapshotStep {
    Capture,
}

impl StepSpecSource for SnapshotStep {
    fn spec(&self, host: &str) -> StepSpec {
        match self {
            SnapshotStep::Capture => StepSpec::stage(format!("snapshot-{host}"), "snapshot"),
        }
    }
}

/// Reconcile and settle a readiness parent for a child host row.
pub enum ReadinessStep {
    Reconcile { parent: String },
    Settle { parent: String },
}

impl StepSpecSource for ReadinessStep {
    fn spec(&self, _host: &str) -> StepSpec {
        match self {
            ReadinessStep::Reconcile { parent } => StepSpec::detail(
                format!("parent-reconcile-{parent}"),
                "parent reconcile",
                parent,
            ),
            ReadinessStep::Settle { parent } => {
                StepSpec::detail(format!("parent-settle-{parent}"), "parent settle", parent)
            }
        }
    }
}

/// Transfer a closure for a target.
pub enum TransferStep {
    /// Target pulls directly from a configured cache.
    CachePull,
    /// Controller pulls from a cache into the local store (relay hop).
    RelayPull,
    /// Controller pushes a cached closure to the target (relay hop).
    RelayPush,
    /// Controller pushes an already-local closure directly to the target.
    DirectPush,
}

impl StepSpecSource for TransferStep {
    fn spec(&self, host: &str) -> StepSpec {
        match self {
            TransferStep::CachePull => {
                StepSpec::stage(format!("target-cache-pull-{host}"), "cache pull")
            }
            TransferStep::RelayPull => {
                StepSpec::stage(format!("relay-cache-to-local-{host}"), "closure relay pull")
            }
            TransferStep::RelayPush => StepSpec::stage(
                format!("relay-cache-to-target-{host}"),
                "closure relay push",
            ),
            TransferStep::DirectPush => {
                StepSpec::stage(format!("deploy-copy-closure-{host}"), "closure copy")
            }
        }
    }
}

/// Verify a closure is present and intact on a target.
pub enum VerifyStep {
    Closure,
}

impl StepSpecSource for VerifyStep {
    fn spec(&self, host: &str) -> StepSpec {
        match self {
            VerifyStep::Closure => {
                StepSpec::stage(format!("target-closure-verify-{host}"), "closure verify")
            }
        }
    }
}

/// Materialize admission state on a target before activation.
pub enum AcquireStep {
    AgeIdentityUpload,
    AgeIdentityInstall,
    CandidateLeaseAcquire,
    CandidateLeaseRelease,
    GenerationAdmission,
    PrefetchPodman,
    PrefetchModels,
}

impl StepSpecSource for AcquireStep {
    fn spec(&self, host: &str) -> StepSpec {
        match self {
            AcquireStep::AgeIdentityUpload => StepSpec::stage(
                format!("host-age-identity-upload-{host}"),
                "age identity upload",
            ),
            AcquireStep::AgeIdentityInstall => StepSpec::stage(
                format!("host-age-identity-install-{host}"),
                "age identity install",
            ),
            AcquireStep::CandidateLeaseAcquire => StepSpec::stage(
                format!("acquire-candidate-lease-{host}"),
                "candidate lease acquire",
            ),
            AcquireStep::CandidateLeaseRelease => StepSpec::stage(
                format!("release-candidate-lease-{host}"),
                "candidate lease release",
            ),
            AcquireStep::GenerationAdmission => StepSpec::stage(
                format!("generation-admission-preflight-{host}"),
                "generation admission",
            ),
            AcquireStep::PrefetchPodman => {
                StepSpec::stage(format!("prefetch-podman-image-{host}"), "prefetch podman")
            }
            AcquireStep::PrefetchModels => {
                StepSpec::stage(format!("prefetch-ai-model-{host}"), "prefetch models")
            }
        }
    }
}

/// Bootstrap transport key installation on the operator route.
pub enum BootstrapStep {
    PrivateKeyUpload,
    PublicKeyUpload,
    Install,
}

impl StepSpecSource for BootstrapStep {
    fn spec(&self, host: &str) -> StepSpec {
        match self {
            BootstrapStep::PrivateKeyUpload => StepSpec::stage(
                format!("bootstrap-private-key-upload-{host}"),
                "bootstrap private key upload",
            ),
            BootstrapStep::PublicKeyUpload => StepSpec::stage(
                format!("bootstrap-public-key-upload-{host}"),
                "bootstrap public key upload",
            ),
            BootstrapStep::Install => StepSpec::stage(
                format!("bootstrap-key-install-{host}"),
                "bootstrap key install",
            ),
        }
    }
}

/// Apply the prepared system generation on a target.
pub enum DeployStep {
    PreSwitch,
    Activation,
    Rollback,
}

impl StepSpecSource for DeployStep {
    fn spec(&self, host: &str) -> StepSpec {
        match self {
            DeployStep::PreSwitch => StepSpec::stage(
                format!("pre-switch-preparation-{host}"),
                "pre-switch prepare",
            ),
            DeployStep::Activation => {
                StepSpec::finalizing(format!("activation-{host}"), "activation")
            }
            DeployStep::Rollback => StepSpec::finalizing(format!("rollback-{host}"), "rollback"),
        }
    }
}

/// Verify a deployed host's managed health.
pub enum HealthStep {
    Check,
}

impl StepSpecSource for HealthStep {
    fn spec(&self, host: &str) -> StepSpec {
        match self {
            HealthStep::Check => StepSpec::stage(format!("health-check-{host}"), "health check"),
        }
    }
}

/// Phase-level (non-host) operations.
pub enum PhaseStep {
    BuildPlanProbe,
}

impl StepSpecSource for PhaseStep {
    fn spec(&self, _host: &str) -> StepSpec {
        match self {
            PhaseStep::BuildPlanProbe => {
                StepSpec::stage("build-plan-probe".to_owned(), "build plan probe")
            }
        }
    }
}

/// Run one step under its progress task: mint the task from the step scope,
/// drive `started`/`finished`, and hand the task to the body so every process
/// it runs reports into the same row.
///
/// A step's row outcome is `Succeeded` when the body returns `Ok` and no
/// process was cancelled. Use [`run_step_with`] when the body's value carries
/// its own failure signal (a command status or a typed execution outcome).
/// Steps whose return value only reports a probe result (for example a snapshot
/// with no previous generation) stay `Succeeded`; the host-level policy decides
/// whether that is a failure. Interruption overrides every outcome; see
/// [`run_step_with`].
pub fn run_step<T>(
    scope: &Arc<dyn TaskScope>,
    step: impl StepSpecSource,
    body: impl FnOnce(Arc<dyn Task>) -> Result<T>,
) -> Result<T> {
    run_step_with(scope, step, body, |_| TaskOutcome::Succeeded)
}

/// Like [`run_step`], but derives the row outcome from the returned value.
///
/// Interruption always wins. A cancelled process marks the task (covering
/// bodies that swallow the failure into a value), a typed interruption error is
/// honored directly, and a failure observed while cancellation is requested is
/// attributed to the interruption.
pub fn run_step_with<T>(
    scope: &Arc<dyn TaskScope>,
    step: impl StepSpecSource,
    body: impl FnOnce(Arc<dyn Task>) -> Result<T>,
    outcome: impl FnOnce(&T) -> TaskOutcome,
) -> Result<T> {
    let task = scope.step(&step);
    task.started();
    let started = Instant::now();
    let result = body(Arc::clone(&task));
    let outcome = if task.was_interrupted() {
        TaskOutcome::Interrupted
    } else {
        let mapped = match &result {
            Ok(value) => outcome(value),
            Err(error) if error.downcast_ref::<Interrupted>().is_some() => TaskOutcome::Interrupted,
            Err(_) => TaskOutcome::Failed,
        };
        if mapped == TaskOutcome::Failed && cancellation_requested() {
            TaskOutcome::Interrupted
        } else {
            mapped
        }
    };
    task.finished(started.elapsed(), outcome);
    result
}

/// The fleet signal coordinator has requested cancellation. A failure observed
/// while a cancelled process is still settling is attributed to the
/// interruption rather than the host.
fn cancellation_requested() -> bool {
    super::signal::runtime()
        .and_then(|runtime| runtime.interruption())
        .is_some()
}
