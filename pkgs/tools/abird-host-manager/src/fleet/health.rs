//! Pure health classification and host-agent response validation.
//!
//! This module deliberately does no I/O. Callers collect systemd, Podman, and
//! host-agent observations, then use these types to make a deterministic
//! deployment-health decision.

use std::collections::BTreeSet;
use std::error::Error;
use std::fmt;

use serde::{Deserialize, Serialize};

/// The systemd properties needed by the health classifier.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UnitSnapshot {
    pub name: String,
    pub load_state: String,
    pub active_state: String,
    pub sub_state: String,
    pub needs_daemon_reload: bool,
}

/// A pending or running systemd job.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SystemdJob {
    pub id: u64,
    pub unit: String,
    pub kind: String,
    pub state: String,
}

impl SystemdJob {
    fn is_live_start_for(&self, unit: &str) -> bool {
        self.unit == unit
            && matches!(
                self.kind.as_str(),
                "start" | "restart" | "try-restart" | "reload-or-start"
            )
            && matches!(self.state.as_str(), "waiting" | "running")
    }
}

/// Evidence retained while individual checks are folded into one verdict.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HealthEvidence {
    UnitSettling {
        unit: String,
        active_state: String,
        sub_state: String,
    },
    ExpectedUnitStopped {
        unit: String,
        active_state: String,
        sub_state: String,
    },
    HeldUnitRunning {
        unit: String,
        active_state: String,
        sub_state: String,
    },
    InvalidUnitContract {
        unit: String,
        load_state: String,
        needs_daemon_reload: bool,
    },
    IgnoredBaselineTimer {
        unit: String,
    },
    PodmanStarting {
        container: String,
        status: String,
    },
    PodmanUnhealthy {
        container: String,
        status: String,
    },
    RootlessMutation {
        service: String,
        pid: u32,
    },
    DeploymentWorkSettling,
    ReportedFailure {
        scope: String,
        detail: String,
    },
    StructuralIssue {
        scope: String,
        detail: String,
    },
}

/// Deployment health, ordered from least to most severe.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HealthDecision {
    Healthy { evidence: Vec<HealthEvidence> },
    Settling { evidence: Vec<HealthEvidence> },
    ServiceFailure { evidence: Vec<HealthEvidence> },
    StructuralFailure { evidence: Vec<HealthEvidence> },
}

impl HealthDecision {
    pub fn healthy() -> Self {
        Self::Healthy {
            evidence: Vec::new(),
        }
    }

    /// Merge independent observations using fail-closed precedence while
    /// retaining evidence in observation order.
    pub fn merge(self, other: Self) -> Self {
        let severity = self.severity().max(other.severity());
        let mut evidence = self.into_evidence();
        evidence.extend(other.into_evidence());
        Self::with_severity(severity, evidence)
    }

    fn severity(&self) -> u8 {
        match self {
            Self::Healthy { .. } => 0,
            Self::Settling { .. } => 1,
            Self::ServiceFailure { .. } => 2,
            Self::StructuralFailure { .. } => 3,
        }
    }

    fn into_evidence(self) -> Vec<HealthEvidence> {
        match self {
            Self::Healthy { evidence }
            | Self::Settling { evidence }
            | Self::ServiceFailure { evidence }
            | Self::StructuralFailure { evidence } => evidence,
        }
    }

    fn with_severity(severity: u8, evidence: Vec<HealthEvidence>) -> Self {
        match severity {
            0 => Self::Healthy { evidence },
            1 => Self::Settling { evidence },
            2 => Self::ServiceFailure { evidence },
            _ => Self::StructuralFailure { evidence },
        }
    }
}

fn invalid_unit_contract(unit: &UnitSnapshot) -> Option<HealthDecision> {
    (unit.load_state != "loaded" || unit.needs_daemon_reload).then(|| {
        HealthDecision::StructuralFailure {
            evidence: vec![HealthEvidence::InvalidUnitContract {
                unit: unit.name.clone(),
                load_state: unit.load_state.clone(),
                needs_daemon_reload: unit.needs_daemon_reload,
            }],
        }
    })
}

fn unit_is_transitional(unit: &UnitSnapshot) -> bool {
    matches!(
        unit.active_state.as_str(),
        "activating" | "deactivating" | "reloading"
    )
}

fn settling_unit(unit: &UnitSnapshot) -> HealthDecision {
    HealthDecision::Settling {
        evidence: vec![HealthEvidence::UnitSettling {
            unit: unit.name.clone(),
            active_state: unit.active_state.clone(),
            sub_state: unit.sub_state.clone(),
        }],
    }
}

/// Classify a service that the desired generation expects to be active.
pub fn classify_expected_unit(unit: &UnitSnapshot, jobs: &[SystemdJob]) -> HealthDecision {
    if let Some(invalid) = invalid_unit_contract(unit) {
        return invalid;
    }

    if unit.active_state == "active" {
        return HealthDecision::healthy();
    }
    if unit_is_transitional(unit) || jobs.iter().any(|job| job.is_live_start_for(&unit.name)) {
        return settling_unit(unit);
    }

    HealthDecision::ServiceFailure {
        evidence: vec![HealthEvidence::ExpectedUnitStopped {
            unit: unit.name.clone(),
            active_state: unit.active_state.clone(),
            sub_state: unit.sub_state.clone(),
        }],
    }
}

/// Classify a unit held inactive by the durable host-agent hold protocol.
pub fn classify_held_unit(unit: &UnitSnapshot) -> HealthDecision {
    if let Some(invalid) = invalid_unit_contract(unit) {
        return invalid;
    }

    if unit.active_state == "inactive" {
        HealthDecision::healthy()
    } else if unit.active_state == "deactivating" {
        settling_unit(unit)
    } else {
        HealthDecision::ServiceFailure {
            evidence: vec![HealthEvidence::HeldUnitRunning {
                unit: unit.name.clone(),
                active_state: unit.active_state.clone(),
                sub_state: unit.sub_state.clone(),
            }],
        }
    }
}

/// Set of timer-triggered units that were already transitioning before the
/// deployment began. Their transition is recorded without prolonging health
/// convergence.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BaselineTimerUnits(BTreeSet<String>);

impl BaselineTimerUnits {
    pub fn from_names<I, S>(units: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        Self(
            units
                .into_iter()
                .map(|unit| unit.as_ref().to_owned())
                .collect(),
        )
    }

    pub fn as_set(&self) -> &BTreeSet<String> {
        &self.0
    }
}

/// Classify a transitional unit discovered during the deployment health scan.
pub fn classify_transitional_unit(
    unit: &UnitSnapshot,
    baseline_timers: &BaselineTimerUnits,
) -> HealthDecision {
    if !unit_is_transitional(unit) {
        return HealthDecision::healthy();
    }
    if baseline_timers.0.contains(&unit.name) {
        HealthDecision::Healthy {
            evidence: vec![HealthEvidence::IgnoredBaselineTimer {
                unit: unit.name.clone(),
            }],
        }
    } else {
        settling_unit(unit)
    }
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct DurableUserHold {
    pub user: String,
    pub unit: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct HeldService {
    pub scope: String,
    pub user: Option<String>,
    pub unit: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DurableHold {
    pub resource: String,
    pub services: Vec<HeldService>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DurableHoldResult {
    pub holds: Vec<DurableHold>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DurableHoldResponse {
    pub ok: bool,
    pub operation: String,
    pub result: DurableHoldResult,
}

/// Validate the host-agent durable-hold response. A missing agent is the
/// supported legacy case and therefore has no durable holds.
pub fn validate_durable_holds(
    response: Option<&DurableHoldResponse>,
) -> Result<Vec<DurableUserHold>, HealthValidationError> {
    let Some(response) = response else {
        return Ok(Vec::new());
    };
    if !response.ok || response.operation != "hold_list" {
        return Err(HealthValidationError::InvalidDurableHoldResponse);
    }

    let mut holds = BTreeSet::new();
    for hold in &response.result.holds {
        for service in &hold.services {
            if service.scope != "user" {
                continue;
            }
            let (Some(user), Some(unit)) = (&service.user, &service.unit) else {
                return Err(HealthValidationError::InvalidDurableHoldResponse);
            };
            if user.is_empty() || unit.is_empty() {
                return Err(HealthValidationError::InvalidDurableHoldResponse);
            }
            holds.insert(DurableUserHold {
                user: user.clone(),
                unit: unit.clone(),
            });
        }
    }
    Ok(holds.into_iter().collect())
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DeferredResource {
    pub resource: String,
    pub reason: String,
    pub generation: u64,
    pub isolated: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DeferredResourceSet {
    pub count: usize,
    pub resources: Vec<DeferredResource>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentStatusResult {
    pub status_schema_version: Option<u32>,
    pub deferred_resources: Option<DeferredResourceSet>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentStatusResponse {
    pub ok: bool,
    pub operation: String,
    pub result: AgentStatusResult,
}

/// Validate and normalize schema-v2 deferred resources. Missing agents and
/// pre-schema responses are compatible legacy states.
pub fn validate_deferred_resources(
    response: Option<&AgentStatusResponse>,
) -> Result<Vec<DeferredResource>, HealthValidationError> {
    let Some(response) = response else {
        return Ok(Vec::new());
    };
    if !response.ok || response.operation != "agent_status" {
        return Err(HealthValidationError::InvalidDeferredResourceResponse);
    }

    let Some(version) = response.result.status_schema_version else {
        return Ok(Vec::new());
    };
    if version != 2 {
        return Err(HealthValidationError::InvalidDeferredResourceResponse);
    }
    let Some(resources) = &response.result.deferred_resources else {
        return Err(HealthValidationError::InvalidDeferredResourceResponse);
    };
    if resources.count != resources.resources.len() {
        return Err(HealthValidationError::InvalidDeferredResourceResponse);
    }
    if resources
        .resources
        .iter()
        .any(|resource| !resource.isolated)
    {
        return Err(HealthValidationError::UnsafeDeferredResource);
    }

    let mut resources = resources.resources.clone();
    resources.sort_by(|left, right| {
        (&left.resource, &left.reason, left.generation).cmp(&(
            &right.resource,
            &right.reason,
            right.generation,
        ))
    });
    resources.dedup();
    Ok(resources)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PodmanHealth {
    Healthy,
    Starting,
    Unhealthy,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PodmanContainer {
    pub name: String,
    pub health: PodmanHealth,
    pub status: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RootlessMutation {
    pub service: String,
    pub pid: u32,
    pub reason: String,
    pub started_at: String,
    pub live: bool,
}

/// Fold container health and active rootless mutations into a runtime verdict.
/// Unhealthy containers are allowed to settle only while deployment work is
/// demonstrably active.
pub fn classify_podman_runtime(
    containers: &[PodmanContainer],
    mutations: &[RootlessMutation],
    deployment_work_settling: bool,
) -> HealthDecision {
    let mut evidence = Vec::new();
    let mut has_unhealthy = false;
    let mut is_settling = deployment_work_settling;

    if deployment_work_settling {
        evidence.push(HealthEvidence::DeploymentWorkSettling);
    }
    for container in containers {
        match container.health {
            PodmanHealth::Healthy => {}
            PodmanHealth::Starting => {
                is_settling = true;
                evidence.push(HealthEvidence::PodmanStarting {
                    container: container.name.clone(),
                    status: container.status.clone(),
                });
            }
            PodmanHealth::Unhealthy => {
                has_unhealthy = true;
                evidence.push(HealthEvidence::PodmanUnhealthy {
                    container: container.name.clone(),
                    status: container.status.clone(),
                });
            }
        }
    }
    for mutation in mutations.iter().filter(|mutation| mutation.live) {
        is_settling = true;
        evidence.push(HealthEvidence::RootlessMutation {
            service: mutation.service.clone(),
            pid: mutation.pid,
        });
    }

    if is_settling {
        HealthDecision::Settling { evidence }
    } else if has_unhealthy {
        HealthDecision::ServiceFailure { evidence }
    } else {
        HealthDecision::Healthy { evidence }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReadinessBudget {
    pub timeout_seconds: u64,
    pub annotated_unit_count: usize,
}

/// Derive the host readiness deadline from observed and registry annotations.
/// The largest requested timeout is the base, with thirty seconds of
/// scheduling allowance for every additional annotated unit.
pub fn derive_readiness_budget(
    observed_timeouts: &[u64],
    registry_timeouts: &[u64],
) -> Result<Option<ReadinessBudget>, HealthValidationError> {
    let mut positive = observed_timeouts
        .iter()
        .chain(registry_timeouts)
        .copied()
        .filter(|timeout| *timeout > 0);
    let Some(first) = positive.next() else {
        return Ok(None);
    };

    let mut maximum = first;
    let mut count = 1usize;
    for timeout in positive {
        maximum = maximum.max(timeout);
        count = count
            .checked_add(1)
            .ok_or(HealthValidationError::ReadinessBudgetOverflow)?;
    }
    let extra_units =
        u64::try_from(count - 1).map_err(|_| HealthValidationError::ReadinessBudgetOverflow)?;
    let allowance = extra_units
        .checked_mul(30)
        .ok_or(HealthValidationError::ReadinessBudgetOverflow)?;
    let timeout_seconds = maximum
        .checked_add(allowance)
        .ok_or(HealthValidationError::ReadinessBudgetOverflow)?;

    Ok(Some(ReadinessBudget {
        timeout_seconds,
        annotated_unit_count: count,
    }))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HealthValidationError {
    InvalidDurableHoldResponse,
    InvalidDeferredResourceResponse,
    UnsafeDeferredResource,
    ReadinessBudgetOverflow,
}

impl fmt::Display for HealthValidationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidDurableHoldResponse => "invalid durable hold response",
            Self::InvalidDeferredResourceResponse => "invalid deferred resource response",
            Self::UnsafeDeferredResource => "deferred resource is not isolated",
            Self::ReadinessBudgetOverflow => "readiness budget overflow",
        };
        formatter.write_str(message)
    }
}

impl Error for HealthValidationError {}
