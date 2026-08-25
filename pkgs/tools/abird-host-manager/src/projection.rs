use std::collections::{BTreeMap, BTreeSet};

use abird_host_agent::sha256::digest_bytes;
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::agent_adapter::HostManagerConfig;
use crate::workflow::{MoveItem, TransactionSpec, validate_workflow_id};

pub use abird_host_agent::job::JobProjectionBinding;

pub const PHASE_PROJECTION_SCHEMA_VERSION: u32 = 1;

/// Generic desired-state document consumed by repository and runtime
/// reconcilers. Producer-specific transition policy lives outside this type.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PhaseProjection {
    pub schema_version: u32,
    pub projection_id: String,
    pub intent_kind: String,
    pub phase: String,
    pub generation: u64,
    pub intent: Value,
    pub intent_sha256: String,
    pub resources: Vec<ProjectedResource>,
    pub effects: Vec<ProjectionEffect>,
    pub activation_requirement: Option<ActivationRequirement>,
    pub previous_projection_sha256: Option<String>,
    pub previous_repository_revision: Option<String>,
    pub projection_sha256: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProjectedResource {
    pub id: String,
    pub role: String,
    pub kind: ProjectionResourceKind,
    pub name: String,
    pub endpoint: ProjectedEndpoint,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProjectionResourceKind {
    Host,
    Service,
    Resource,
    Instance,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProjectedEndpoint {
    pub host: String,
    pub host_resource: String,
    pub resource: String,
    pub hold_epoch: Option<String>,
    pub transaction_id: Option<String>,
    pub activation_job_id: Option<String>,
    pub desired_state: DesiredResourceState,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DesiredResourceState {
    Held,
    Active,
    Inactive,
    Unheld,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ProjectionEffect {
    ServicePlacement {
        scope: String,
        service: String,
        host: String,
        host_resource: String,
    },
    RouteProfile {
        scope: String,
        service: String,
        profile: String,
        baseline_profile: String,
        executor_host: String,
        executor_host_resource: String,
        executor_resource: String,
        profiles: Vec<ProjectedRouteProfile>,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProjectedRouteProfile {
    pub profile: String,
    pub endpoint_host: String,
    pub endpoint_host_resource: String,
    pub resource: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ActivationRequirement {
    pub kind: String,
    pub requirement_sha256: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ActivationReceipt {
    pub schema_version: u32,
    pub projection_id: String,
    pub intent_digest: String,
    pub requirement_digest: String,
    pub evidence_sha256: String,
    pub receipt_sha256: String,
}

#[derive(Serialize)]
struct UnsignedActivationReceipt<'a> {
    schema_version: u32,
    projection_id: &'a str,
    intent_digest: &'a str,
    requirement_digest: &'a str,
    evidence_sha256: &'a str,
}

impl ActivationReceipt {
    pub fn derive<T: Serialize + ?Sized>(
        projection: &PhaseProjection,
        evidence: &T,
    ) -> Result<Self> {
        let requirement = projection
            .activation_requirement
            .as_ref()
            .context("phase projection has no activation requirement")?;
        let evidence_sha256 = canonical_sha256(evidence)?;
        let mut receipt = Self {
            schema_version: PHASE_PROJECTION_SCHEMA_VERSION,
            projection_id: projection.projection_id.clone(),
            intent_digest: projection.intent_sha256.clone(),
            requirement_digest: requirement.requirement_sha256.clone(),
            evidence_sha256,
            receipt_sha256: String::new(),
        };
        receipt.receipt_sha256 = canonical_sha256(&UnsignedActivationReceipt {
            schema_version: receipt.schema_version,
            projection_id: &receipt.projection_id,
            intent_digest: &receipt.intent_digest,
            requirement_digest: &receipt.requirement_digest,
            evidence_sha256: &receipt.evidence_sha256,
        })?;
        receipt.validate_for(projection)?;
        Ok(receipt)
    }

    pub fn validate_for(&self, projection: &PhaseProjection) -> Result<()> {
        self.validate_identity(&projection.projection_id, &projection.intent_sha256)?;
        let requirement = projection
            .activation_requirement
            .as_ref()
            .context("phase projection has no activation requirement")?;
        if self.requirement_digest != requirement.requirement_sha256 {
            bail!("activation receipt does not satisfy projection requirement");
        }
        Ok(())
    }

    pub fn validate_identity(&self, projection_id: &str, intent_digest: &str) -> Result<()> {
        if self.schema_version != PHASE_PROJECTION_SCHEMA_VERSION
            || self.projection_id != projection_id
            || self.intent_digest != intent_digest
        {
            bail!("activation receipt does not match projection identity");
        }
        validate_digest(&self.requirement_digest, "activation requirement")?;
        validate_digest(&self.evidence_sha256, "activation evidence")?;
        validate_digest(&self.receipt_sha256, "activation receipt")?;
        let expected = canonical_sha256(&UnsignedActivationReceipt {
            schema_version: self.schema_version,
            projection_id: &self.projection_id,
            intent_digest: &self.intent_digest,
            requirement_digest: &self.requirement_digest,
            evidence_sha256: &self.evidence_sha256,
        })?;
        if expected != self.receipt_sha256 {
            bail!("activation receipt digest does not match retained evidence binding");
        }
        Ok(())
    }
}

#[derive(Serialize)]
struct UnsignedPhaseProjection<'a> {
    schema_version: u32,
    projection_id: &'a str,
    intent_kind: &'a str,
    phase: &'a str,
    generation: u64,
    intent: &'a Value,
    intent_sha256: &'a str,
    resources: &'a [ProjectedResource],
    effects: &'a [ProjectionEffect],
    activation_requirement: &'a Option<ActivationRequirement>,
    previous_projection_sha256: &'a Option<String>,
    previous_repository_revision: &'a Option<String>,
}

impl PhaseProjection {
    pub fn validate(&self) -> Result<()> {
        if self.schema_version != PHASE_PROJECTION_SCHEMA_VERSION {
            bail!(
                "unsupported phase-projection schema version {}",
                self.schema_version
            );
        }
        validate_workflow_id(&self.projection_id)?;
        for (label, value) in [
            ("intent kind", self.intent_kind.as_str()),
            ("phase", self.phase.as_str()),
        ] {
            if value.is_empty() {
                bail!("phase projection {label} must not be empty");
            }
        }
        if self.generation == 0 {
            bail!("phase projection generation must be greater than zero");
        }
        validate_digest(&self.intent_sha256, "intent")?;
        validate_digest(&self.projection_sha256, "projection")?;
        validate_optional_digest(
            self.previous_projection_sha256.as_deref(),
            "previous projection",
        )?;
        if self
            .previous_repository_revision
            .as_deref()
            .is_some_and(str::is_empty)
        {
            bail!("previous repository revision must be null or non-empty");
        }
        if canonical_sha256(&self.intent)? != self.intent_sha256 {
            bail!("phase projection intent digest does not match its content");
        }
        let mut resource_ids = BTreeSet::new();
        let mut endpoint_ids = BTreeSet::new();
        for resource in &self.resources {
            if resource.id.is_empty() || resource.role.is_empty() || resource.name.is_empty() {
                bail!("phase projection resource identity fields must not be empty");
            }
            if !resource_ids.insert(&resource.id) {
                bail!("duplicate phase projection resource ID {:?}", resource.id);
            }
            if resource.endpoint.host.is_empty()
                || resource.endpoint.host_resource.is_empty()
                || resource.endpoint.resource.is_empty()
            {
                bail!("phase projection endpoint identity fields must not be empty");
            }
            if !canonical_host_resource(&resource.endpoint.host_resource) {
                bail!("phase projection endpoint host_resource must be canonical");
            }
            if !matches!(
                resource.endpoint.desired_state,
                DesiredResourceState::Active
            ) && resource.endpoint.hold_epoch.is_none()
            {
                bail!("held, inactive, and unheld projected resources require a hold epoch");
            }
            if resource.endpoint.hold_epoch.is_some() != resource.endpoint.transaction_id.is_some()
            {
                bail!("projected hold epoch and transaction identity must be declared together");
            }
            if let Some(transaction_id) = &resource.endpoint.transaction_id {
                validate_workflow_id(transaction_id)?;
            }
            let activation_job_required = resource.endpoint.desired_state
                == DesiredResourceState::Active
                && resource.endpoint.hold_epoch.is_some();
            if activation_job_required != resource.endpoint.activation_job_id.is_some() {
                bail!("exactly active held projected resources require an activation job identity");
            }
            if let Some(job_id) = &resource.endpoint.activation_job_id {
                validate_workflow_id(job_id)?;
            }
            if !endpoint_ids.insert((
                resource.endpoint.host.as_str(),
                resource.endpoint.resource.as_str(),
            )) {
                bail!("phase projection contains a duplicate host/resource endpoint");
            }
        }
        if let Some(requirement) = &self.activation_requirement {
            if requirement.kind.is_empty() {
                bail!("activation requirement kind must not be empty");
            }
            validate_digest(&requirement.requirement_sha256, "activation requirement")?;
        }
        self.validate_effects()?;
        if self.expected_projection_sha256()? != self.projection_sha256 {
            bail!("phase projection digest does not match its canonical content");
        }
        Ok(())
    }

    fn validate_effects(&self) -> Result<()> {
        let mut placements = BTreeMap::new();
        for effect in &self.effects {
            let ProjectionEffect::ServicePlacement {
                scope,
                service,
                host,
                host_resource,
            } = effect
            else {
                continue;
            };
            if [scope, service, host, host_resource]
                .iter()
                .any(|value| value.is_empty())
                || !canonical_host_resource(host_resource)
            {
                bail!("service placement effect has invalid identity fields");
            }
            let matches = self
                .resources
                .iter()
                .filter(|resource| {
                    resource.kind == ProjectionResourceKind::Service
                        && resource.name == *service
                        && resource.endpoint.host == *host
                        && resource.endpoint.host_resource == *host_resource
                })
                .count();
            if matches != 1 {
                bail!(
                    "service placement effect must select exactly one projected service endpoint"
                );
            }
            if placements
                .insert((scope.as_str(), service.as_str()), (host, host_resource))
                .is_some()
            {
                bail!("phase projection has duplicate service placement effects");
            }
        }

        let mut routes = BTreeSet::new();
        for effect in &self.effects {
            match effect {
                ProjectionEffect::ServicePlacement { .. } => {}
                ProjectionEffect::RouteProfile {
                    scope,
                    service,
                    profile,
                    baseline_profile,
                    executor_host,
                    executor_host_resource,
                    executor_resource,
                    profiles,
                } => {
                    if [
                        scope,
                        service,
                        profile,
                        baseline_profile,
                        executor_host,
                        executor_host_resource,
                        executor_resource,
                    ]
                    .iter()
                    .any(|value| value.is_empty())
                        || !canonical_host_resource(executor_host_resource)
                    {
                        bail!("route profile effect has invalid identity fields");
                    }
                    if profiles.is_empty() {
                        bail!("route profile effect must declare at least one allowed profile");
                    }
                    let mut profile_names = BTreeSet::new();
                    for route_profile in profiles {
                        if [
                            &route_profile.profile,
                            &route_profile.endpoint_host,
                            &route_profile.endpoint_host_resource,
                            &route_profile.resource,
                        ]
                        .iter()
                        .any(|value| value.is_empty())
                            || !canonical_host_resource(&route_profile.endpoint_host_resource)
                        {
                            bail!("route profile effect has an invalid allowed profile");
                        }
                        if !profile_names.insert(route_profile.profile.as_str()) {
                            bail!("route profile effect has duplicate allowed profile names");
                        }
                        let endpoint_matches = self.resources.iter().filter(|projected| {
                            projected.kind == ProjectionResourceKind::Service
                                && projected.name == *service
                                && projected.endpoint.host == route_profile.endpoint_host
                                && projected.endpoint.host_resource
                                    == route_profile.endpoint_host_resource
                                && projected.endpoint.resource == route_profile.resource
                        });
                        if endpoint_matches.count() != 1 {
                            bail!(
                                "each allowed route profile must select exactly one projected service endpoint"
                            );
                        }
                    }
                    if !profile_names.contains(profile.as_str())
                        || !profile_names.contains(baseline_profile.as_str())
                    {
                        bail!(
                            "selected and baseline route profiles must belong to the allowed profile set"
                        );
                    }
                    let selected = profiles
                        .iter()
                        .find(|route_profile| route_profile.profile == *profile)
                        .context("validated route profile has no selected endpoint")?;
                    match placements.get(&(scope.as_str(), service.as_str())) {
                        Some((host, host_resource))
                            if host.as_str() == selected.endpoint_host.as_str()
                                && host_resource.as_str()
                                    == selected.endpoint_host_resource.as_str() => {}
                        _ => bail!(
                            "route profile endpoint must match its projected service placement"
                        ),
                    }
                    if !routes.insert((scope.as_str(), service.as_str())) {
                        bail!("phase projection has duplicate route profile effects");
                    }
                }
            }
        }
        Ok(())
    }

    /// NixOS configurations whose declarative state can change when this
    /// projection is consumed. The controller configuration is deliberately
    /// supplied by the publisher because it is repository inventory, not part
    /// of the generic projection document.
    pub fn declarative_effect_hosts(&self) -> BTreeSet<&str> {
        let mut hosts = self
            .resources
            .iter()
            .map(|resource| resource.endpoint.host.as_str())
            .collect::<BTreeSet<_>>();
        for effect in &self.effects {
            match effect {
                ProjectionEffect::ServicePlacement { host, .. } => {
                    hosts.insert(host);
                }
                ProjectionEffect::RouteProfile {
                    executor_host,
                    profiles,
                    ..
                } => {
                    hosts.insert(executor_host);
                    hosts.extend(
                        profiles
                            .iter()
                            .map(|profile| profile.endpoint_host.as_str()),
                    );
                }
            }
        }
        hosts
    }

    pub fn job_binding(&self, hold_epoch: Option<String>) -> JobProjectionBinding {
        JobProjectionBinding {
            intent_digest: self.intent_sha256.clone(),
            projection_digest: self.projection_sha256.clone(),
            generation: self.generation,
            hold_epoch,
            activation_requirement_digest: self
                .activation_requirement
                .as_ref()
                .map(|requirement| requirement.requirement_sha256.clone()),
        }
    }

    pub fn hold_epoch_for_execution(
        &self,
        execution_host: &str,
        resource: &str,
    ) -> Result<Option<String>> {
        let exact = self
            .resources
            .iter()
            .filter(|projected| {
                projected.endpoint.host == execution_host && projected.endpoint.resource == resource
            })
            .collect::<Vec<_>>();
        match exact.as_slice() {
            [projected] => return Ok(projected.endpoint.hold_epoch.clone()),
            [] => {}
            _ => bail!(
                "phase projection maps host {execution_host:?} resource {resource:?} to multiple endpoints"
            ),
        }
        let by_resource = self
            .resources
            .iter()
            .filter(|projected| projected.endpoint.resource == resource)
            .collect::<Vec<_>>();
        Ok(match by_resource.as_slice() {
            [projected] => projected.endpoint.hold_epoch.clone(),
            _ => None,
        })
    }

    pub fn move_phase(&self) -> Result<MovePhase> {
        if self.intent_kind != "move" {
            bail!("phase projection intent kind is not move");
        }
        parse_move_phase(&self.phase)
    }

    pub fn resource_hold_phase(&self) -> Result<ResourceHoldPhase> {
        if self.intent_kind != "resource_hold" {
            bail!("phase projection intent kind is not resource_hold");
        }
        parse_resource_hold_phase(&self.phase)
    }

    fn expected_projection_sha256(&self) -> Result<String> {
        canonical_sha256(&UnsignedPhaseProjection {
            schema_version: self.schema_version,
            projection_id: &self.projection_id,
            intent_kind: &self.intent_kind,
            phase: &self.phase,
            generation: self.generation,
            intent: &self.intent,
            intent_sha256: &self.intent_sha256,
            resources: &self.resources,
            effects: &self.effects,
            activation_requirement: &self.activation_requirement,
            previous_projection_sha256: &self.previous_projection_sha256,
            previous_repository_revision: &self.previous_repository_revision,
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ResourceHoldIntent {
    pub projection_id: String,
    pub host: String,
    pub host_resource: String,
    pub resource: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ResourceHoldPhase {
    Held,
    Unheld,
}

impl ResourceHoldPhase {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Held => "held",
            Self::Unheld => "unheld",
        }
    }

    pub fn can_follow(self, previous: Self) -> bool {
        self == previous
            || matches!(
                (previous, self),
                (Self::Held, Self::Unheld) | (Self::Unheld, Self::Held)
            )
    }
}

pub struct ResourceHoldProjector;

impl ResourceHoldProjector {
    pub fn derive(
        intent: &ResourceHoldIntent,
        phase: ResourceHoldPhase,
        previous: Option<&PhaseProjection>,
        previous_repository_revision: Option<String>,
    ) -> Result<PhaseProjection> {
        validate_workflow_id(&intent.projection_id)?;
        if intent.host.is_empty() || intent.resource.is_empty() {
            bail!("resource-hold host and resource must not be empty");
        }
        if !canonical_host_resource(&intent.host_resource) {
            bail!("resource-hold host_resource must be canonical");
        }
        let intent_value = serde_json::to_value(intent)?;
        let intent_sha256 = canonical_sha256(&intent_value)?;
        if let Some(previous) = previous {
            previous.validate()?;
            if previous.intent_kind != "resource_hold"
                || previous.projection_id != intent.projection_id
                || previous.intent_sha256 != intent_sha256
            {
                bail!("previous projection does not match immutable resource-hold intent");
            }
            let previous_phase = previous.resource_hold_phase()?;
            if !phase.can_follow(previous_phase) {
                bail!("resource-hold phase {phase:?} cannot follow {previous_phase:?}");
            }
            if phase == previous_phase {
                return Ok(previous.clone());
            }
        } else if phase != ResourceHoldPhase::Held {
            bail!("the first resource-hold projection must select held desired state");
        }

        let kind = projection_resource_kind(&intent.resource);
        let name = intent
            .resource
            .split_once(':')
            .map_or(intent.resource.as_str(), |(_, name)| name)
            .to_owned();
        let generation = previous.map_or(1, |projection| projection.generation + 1);
        let previous_epoch = previous
            .and_then(|projection| projection.resources.first())
            .and_then(|resource| resource.endpoint.hold_epoch.clone());
        let previous_phase = previous
            .map(PhaseProjection::resource_hold_phase)
            .transpose()?;
        let hold_epoch = match (phase, previous_phase) {
            (ResourceHoldPhase::Held, Some(ResourceHoldPhase::Unheld)) => {
                format!("hold-v{generation}")
            }
            (ResourceHoldPhase::Unheld, _) => {
                previous_epoch.context("resource-hold unheld phase has no prior hold epoch")?
            }
            (ResourceHoldPhase::Held, _) => previous_epoch.unwrap_or_else(|| "hold-v1".to_owned()),
        };
        let mut projection = PhaseProjection {
            schema_version: PHASE_PROJECTION_SCHEMA_VERSION,
            projection_id: intent.projection_id.clone(),
            intent_kind: "resource_hold".to_owned(),
            phase: phase.as_str().to_owned(),
            generation,
            intent: intent_value,
            intent_sha256,
            resources: vec![ProjectedResource {
                id: "resource".to_owned(),
                role: "subject".to_owned(),
                kind,
                name,
                endpoint: ProjectedEndpoint {
                    host: intent.host.clone(),
                    host_resource: intent.host_resource.clone(),
                    resource: intent.resource.clone(),
                    hold_epoch: Some(hold_epoch),
                    transaction_id: Some(intent.projection_id.clone()),
                    activation_job_id: None,
                    desired_state: match phase {
                        ResourceHoldPhase::Held => DesiredResourceState::Held,
                        ResourceHoldPhase::Unheld => DesiredResourceState::Unheld,
                    },
                },
            }],
            effects: Vec::new(),
            activation_requirement: None,
            previous_projection_sha256: previous
                .map(|projection| projection.projection_sha256.clone()),
            previous_repository_revision,
            projection_sha256: String::new(),
        };
        projection.projection_sha256 = projection.expected_projection_sha256()?;
        projection.validate()?;
        Ok(projection)
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MovePhase {
    Seeded,
    Prepared,
    Cutover,
    RolledBack,
}

impl MovePhase {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Seeded => "seeded",
            Self::Prepared => "prepared",
            Self::Cutover => "cutover",
            Self::RolledBack => "rolled_back",
        }
    }

    pub fn can_follow(self, previous: Self) -> bool {
        self == previous
            || matches!(
                (previous, self),
                (Self::Seeded, Self::Prepared | Self::RolledBack)
                    | (Self::Prepared, Self::Cutover | Self::RolledBack)
                    | (Self::Cutover, Self::RolledBack)
            )
    }
}

pub struct MoveProjector;

/// Host-local facts that affect how a move can safely converge without
/// changing the human-selected desired phase.
///
/// Desired state alone cannot answer whether rollback needs a new target hold
/// epoch or whether the source must remain held behind a compensation barrier.
/// Those answers come from the controller journal, never from the previous Git
/// phase.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct MoveItemObservation {
    pub source_held: bool,
    pub target_ever_started: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct MoveProjectionObservation {
    items: BTreeMap<String, MoveItemObservation>,
}

impl MoveProjectionObservation {
    pub fn insert(&mut self, item_id: impl Into<String>, observation: MoveItemObservation) {
        self.items.insert(item_id.into(), observation);
    }

    fn item(&self, item_id: &str) -> MoveItemObservation {
        self.items.get(item_id).copied().unwrap_or_default()
    }

    fn rollback_requires_barrier(&self) -> bool {
        self.items
            .values()
            .any(|item| item.source_held || item.target_ever_started)
    }
}

impl MoveProjector {
    pub fn ensure_runtime_equivalence(spec: &TransactionSpec) -> Result<()> {
        if spec
            .items
            .iter()
            .any(|item| matches!(item, MoveItem::Instance { .. }))
        {
            bail!(
                "repository-backed instance moves are unsupported until a typed declarative instance adapter maps the exact Incus endpoint and job identity; use the legacy transaction workflow instead"
            );
        }
        Ok(())
    }

    pub fn derive(
        spec: &TransactionSpec,
        config: &HostManagerConfig,
        phase: MovePhase,
        previous: Option<&PhaseProjection>,
        previous_repository_revision: Option<String>,
    ) -> Result<PhaseProjection> {
        Self::derive_with_observation(
            spec,
            config,
            phase,
            previous,
            previous_repository_revision,
            &MoveProjectionObservation::default(),
        )
    }

    pub fn derive_with_observation(
        spec: &TransactionSpec,
        config: &HostManagerConfig,
        phase: MovePhase,
        previous: Option<&PhaseProjection>,
        previous_repository_revision: Option<String>,
        observation: &MoveProjectionObservation,
    ) -> Result<PhaseProjection> {
        spec.validate()?;
        Self::ensure_runtime_equivalence(spec)?;
        let intent = serde_json::to_value(spec)?;
        let intent_sha256 = canonical_sha256(&intent)?;
        let previous_phase = previous.map(PhaseProjection::move_phase).transpose()?;
        let activation_kind = match phase {
            MovePhase::Seeded => None,
            MovePhase::Prepared | MovePhase::Cutover => Some("prepared_receipt"),
            MovePhase::RolledBack if observation.rollback_requires_barrier() => {
                Some("rollback_receipt")
            }
            MovePhase::RolledBack => match previous_phase {
                Some(MovePhase::RolledBack) => previous
                    .and_then(|projection| projection.activation_requirement.as_ref())
                    .map(|requirement| requirement.kind.as_str()),
                _ => None,
            },
        };
        if let Some(previous) = previous {
            previous.validate()?;
            if previous.intent_kind != "move"
                || previous.projection_id != spec.id
                || previous.intent_sha256 != intent_sha256
            {
                bail!("previous projection does not match immutable move intent");
            }
            let previous_phase = parse_move_phase(&previous.phase)?;
            if !phase.can_follow(previous_phase) {
                bail!("move phase {phase:?} cannot follow {previous_phase:?}");
            }
            let same_requirement = previous
                .activation_requirement
                .as_ref()
                .map(|requirement| requirement.kind.as_str())
                == activation_kind;
            if previous.phase == phase.as_str() && same_requirement {
                return Ok(previous.clone());
            }
        } else if phase != MovePhase::Seeded {
            bail!("the first move projection must select seeded desired state");
        }

        // Exact idempotent retries returned above. Every projection that reaches
        // this point is a new durable document and therefore advances both
        // generation and lineage.
        let generation = previous.map_or(1, |previous| previous.generation + 1);
        let mut resources = Vec::with_capacity(spec.items.len() * 2);
        let mut effects = Vec::new();
        for item in &spec.items {
            let context = MoveItemProjectionContext {
                config,
                projection_id: &spec.id,
                declarative_scope: spec.declarative_scope.as_deref(),
                phase,
                observation: observation.item(item.id()),
            };
            project_move_item(item, context, &mut resources, &mut effects)?;
        }
        let activation_requirement = match activation_kind {
            Some(kind) => Some(ActivationRequirement {
                kind: kind.to_owned(),
                requirement_sha256: activation_requirement(&spec.id, &intent_sha256, kind)?,
            }),
            None => None,
        };
        let mut projection = PhaseProjection {
            schema_version: PHASE_PROJECTION_SCHEMA_VERSION,
            projection_id: spec.id.clone(),
            intent_kind: "move".to_owned(),
            phase: phase.as_str().to_owned(),
            generation,
            intent,
            intent_sha256,
            resources,
            effects,
            activation_requirement,
            previous_projection_sha256: previous.map(|previous| previous.projection_sha256.clone()),
            previous_repository_revision,
            projection_sha256: String::new(),
        };
        projection.projection_sha256 = projection.expected_projection_sha256()?;
        projection.validate()?;
        Ok(projection)
    }

    pub fn derive_activation_receipt(
        projection: &PhaseProjection,
        evidence: &[Value],
    ) -> Result<ActivationReceipt> {
        if !matches!(
            projection.move_phase()?,
            MovePhase::Prepared | MovePhase::Cutover
        ) {
            bail!("move activation receipt requires a prepared or cutover projection");
        }
        let spec: TransactionSpec = serde_json::from_value(projection.intent.clone())
            .context("move projection intent is not a transaction specification")?;
        let expected = spec
            .items
            .iter()
            .map(|item| item.id().to_owned())
            .collect::<BTreeSet<_>>();
        let mut actual = BTreeSet::new();
        for value in evidence {
            let item: MoveActivationEvidence = serde_json::from_value(value.clone())
                .context("invalid retained move activation evidence")?;
            let expected_operations = [
                "hold-source",
                "hold-target",
                "assert-source-stopped",
                "assert-target-stopped",
                "verify-final",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect::<BTreeSet<_>>();
            let mut operations = BTreeSet::new();
            for job in item.jobs {
                for (label, digest) in [
                    ("result", job.result_sha256.as_str()),
                    ("spec", job.spec_sha256.as_str()),
                ] {
                    validate_digest(digest, &format!("move activation evidence {label}"))?;
                }
                if job.host.is_empty() || job.job_id.is_empty() || !operations.insert(job.operation)
                {
                    bail!("move activation evidence has an empty or duplicate job identity");
                }
            }
            if operations != expected_operations {
                bail!("move activation evidence lacks an exact prepared safety job set");
            }
            if !actual.insert(item.item_id) {
                bail!("move activation evidence has an empty or duplicate identity");
            }
        }
        if actual != expected {
            bail!("move activation evidence does not cover every immutable move item exactly once");
        }
        ActivationReceipt::derive(projection, evidence)
    }

    pub fn derive_rollback_receipt(
        projection: &PhaseProjection,
        evidence: &[Value],
    ) -> Result<ActivationReceipt> {
        if projection.move_phase()? != MovePhase::RolledBack
            || projection
                .activation_requirement
                .as_ref()
                .map(|requirement| requirement.kind.as_str())
                != Some("rollback_receipt")
        {
            bail!("rollback activation receipt requires a rolled-back projection latch");
        }
        let spec: TransactionSpec = serde_json::from_value(projection.intent.clone())
            .context("move projection intent is not a transaction specification")?;
        let expected_items = spec
            .items
            .iter()
            .map(|item| item.id().to_owned())
            .collect::<BTreeSet<_>>();
        let mut actual_items = BTreeSet::new();
        for value in evidence {
            let item: MoveActivationEvidence = serde_json::from_value(value.clone())
                .context("invalid retained move rollback evidence")?;
            let expected_operations = if item.target_started {
                [
                    "hold-target",
                    "assert-target-stopped",
                    "reverse-transfer",
                    "verify-reverse",
                ]
                .as_slice()
            } else {
                ["hold-target", "assert-target-stopped"].as_slice()
            }
            .iter()
            .map(|operation| (*operation).to_owned())
            .collect::<BTreeSet<_>>();
            let mut operations = BTreeSet::new();
            for job in item.jobs {
                validate_digest(&job.result_sha256, "move rollback evidence result")?;
                validate_digest(&job.spec_sha256, "move rollback evidence spec")?;
                if job.host.is_empty() || job.job_id.is_empty() || !operations.insert(job.operation)
                {
                    bail!("move rollback evidence has an empty or duplicate job identity");
                }
            }
            if operations != expected_operations || !actual_items.insert(item.item_id) {
                bail!("move rollback evidence lacks its exact safety job set");
            }
        }
        if actual_items != expected_items {
            bail!("move rollback evidence does not cover every immutable move item exactly once");
        }
        ActivationReceipt::derive(projection, evidence)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MoveActivationEvidence {
    item_id: String,
    #[serde(default)]
    target_started: bool,
    jobs: Vec<MoveActivationJobEvidence>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MoveActivationJobEvidence {
    host: String,
    job_id: String,
    operation: String,
    result_sha256: String,
    spec_sha256: String,
}

struct MoveItemProjectionContext<'a> {
    config: &'a HostManagerConfig,
    projection_id: &'a str,
    declarative_scope: Option<&'a str>,
    phase: MovePhase,
    observation: MoveItemObservation,
}

fn project_move_item(
    item: &MoveItem,
    context: MoveItemProjectionContext<'_>,
    resources: &mut Vec<ProjectedResource>,
    effects: &mut Vec<ProjectionEffect>,
) -> Result<()> {
    let MoveItemProjectionContext {
        config,
        projection_id,
        declarative_scope,
        phase,
        observation,
    } = context;
    let (kind, name, source_host, target_host, source_resource, target_resource, service) =
        match item {
            MoveItem::Host { source, target, .. } => (
                ProjectionResourceKind::Host,
                source.host.clone(),
                source.host.as_str(),
                target.host.as_str(),
                config.host_resource(&source.host)?,
                config.host_resource(&target.host)?,
                None,
            ),
            MoveItem::Service {
                service,
                source_resource,
                target_resource,
                source,
                target,
                ..
            } => (
                ProjectionResourceKind::Service,
                service.clone(),
                source.host.as_str(),
                target.host.as_str(),
                source_resource
                    .clone()
                    .unwrap_or_else(|| format!("service:{service}")),
                target_resource
                    .clone()
                    .unwrap_or_else(|| format!("service:{service}")),
                Some(service.as_str()),
            ),
            MoveItem::Resource {
                resource,
                source,
                target,
                ..
            } => (
                ProjectionResourceKind::Resource,
                resource.clone(),
                source.host.as_str(),
                target.host.as_str(),
                resource.clone(),
                resource.clone(),
                None,
            ),
            MoveItem::Instance { source, target, .. } => (
                ProjectionResourceKind::Instance,
                source.instance.clone(),
                source.controller.as_str(),
                target.controller.as_str(),
                format!(
                    "instance:{}:{}:{}",
                    source.remote, source.project, source.instance
                ),
                format!(
                    "instance:{}:{}:{}",
                    target.remote, target.project, target.instance
                ),
                None,
            ),
        };
    let source_selected = phase != MovePhase::Cutover;
    let (source_state, target_state) = match phase {
        MovePhase::Seeded => (DesiredResourceState::Active, DesiredResourceState::Held),
        MovePhase::RolledBack => (DesiredResourceState::Active, DesiredResourceState::Held),
        MovePhase::Prepared => (DesiredResourceState::Held, DesiredResourceState::Held),
        MovePhase::Cutover => (DesiredResourceState::Held, DesiredResourceState::Active),
    };
    let source_hold = match phase {
        MovePhase::Seeded => None,
        MovePhase::RolledBack if !observation.source_held => None,
        _ => Some(format!("{}:source-prepared", item.id())),
    };
    let target_hold = Some(format!(
        "{}:{}",
        item.id(),
        if phase == MovePhase::RolledBack && observation.target_ever_started {
            "target-rollback"
        } else {
            "target-pre-cutover"
        }
    ));
    let transaction_id = format!("{projection_id}--{}", item.id());
    let activation_job_id = |role: &str| {
        let operation = if role == "source" {
            "rollback-activate-source"
        } else {
            "cutover-activate-target"
        };
        format!("{transaction_id}-{operation}")
    };
    let source_activation = (source_state == DesiredResourceState::Active && source_hold.is_some())
        .then(|| activation_job_id("source"));
    let target_activation =
        (target_state == DesiredResourceState::Active).then(|| activation_job_id("target"));
    resources.push(ProjectedResource {
        id: format!("{}:source", item.id()),
        role: "source".to_owned(),
        kind,
        name: name.clone(),
        endpoint: ProjectedEndpoint {
            host: source_host.to_owned(),
            host_resource: config.host_resource(source_host)?,
            resource: source_resource.clone(),
            transaction_id: source_hold.as_ref().map(|_| transaction_id.clone()),
            hold_epoch: source_hold,
            activation_job_id: source_activation,
            desired_state: source_state,
        },
    });
    resources.push(ProjectedResource {
        id: format!("{}:target", item.id()),
        role: "target".to_owned(),
        kind,
        name,
        endpoint: ProjectedEndpoint {
            host: target_host.to_owned(),
            host_resource: config.host_resource(target_host)?,
            resource: target_resource.clone(),
            transaction_id: target_hold.as_ref().map(|_| transaction_id),
            hold_epoch: target_hold,
            activation_job_id: target_activation,
            desired_state: target_state,
        },
    });
    if let Some(service) = service {
        let endpoint_host = if source_selected {
            source_host
        } else {
            target_host
        };
        let scope = declarative_scope
            .context("service move projection requires a declarative stack scope")?
            .to_owned();
        let endpoint_host_resource = config.host_resource(endpoint_host)?;
        let route_operation = if source_selected {
            "deploy-rollback"
        } else {
            "deploy-cutover"
        };
        let (executor_host, executor_resource) =
            config.projected_operation_owner(route_operation, source_host, target_host)?;
        let executor_host_resource = config.host_resource(&executor_host)?;
        let source_host_resource = config.host_resource(source_host)?;
        let target_host_resource = config.host_resource(target_host)?;
        let source_profile = format!("{service}@{source_host_resource}");
        let target_profile = format!("{service}@{target_host_resource}");
        effects.push(ProjectionEffect::ServicePlacement {
            scope: scope.clone(),
            service: service.to_owned(),
            host: endpoint_host.to_owned(),
            host_resource: endpoint_host_resource.clone(),
        });
        effects.push(ProjectionEffect::RouteProfile {
            scope,
            service: service.to_owned(),
            profile: if source_selected {
                source_profile.clone()
            } else {
                target_profile.clone()
            },
            baseline_profile: source_profile.clone(),
            executor_host,
            executor_host_resource,
            executor_resource,
            profiles: vec![
                ProjectedRouteProfile {
                    profile: source_profile,
                    endpoint_host: source_host.to_owned(),
                    endpoint_host_resource: source_host_resource,
                    resource: source_resource,
                },
                ProjectedRouteProfile {
                    profile: target_profile,
                    endpoint_host: target_host.to_owned(),
                    endpoint_host_resource: target_host_resource,
                    resource: target_resource,
                },
            ],
        });
    }
    Ok(())
}

fn parse_move_phase(value: &str) -> Result<MovePhase> {
    match value {
        "seeded" => Ok(MovePhase::Seeded),
        "prepared" => Ok(MovePhase::Prepared),
        "cutover" => Ok(MovePhase::Cutover),
        "rolled_back" => Ok(MovePhase::RolledBack),
        value => bail!("unknown move phase {value:?}"),
    }
}

fn parse_resource_hold_phase(value: &str) -> Result<ResourceHoldPhase> {
    match value {
        "held" => Ok(ResourceHoldPhase::Held),
        "unheld" => Ok(ResourceHoldPhase::Unheld),
        value => bail!("unknown resource-hold phase {value:?}"),
    }
}

fn projection_resource_kind(resource: &str) -> ProjectionResourceKind {
    match resource.split_once(':').map(|(kind, _)| kind) {
        Some("host") => ProjectionResourceKind::Host,
        Some("service") => ProjectionResourceKind::Service,
        Some("instance") => ProjectionResourceKind::Instance,
        _ => ProjectionResourceKind::Resource,
    }
}

fn activation_requirement(
    transaction_id: &str,
    intent_sha256: &str,
    purpose: &str,
) -> Result<String> {
    canonical_sha256(&json!({
        "intent_sha256": intent_sha256,
        "purpose": purpose,
        "projection_kind": "move",
        "schema_version": PHASE_PROJECTION_SCHEMA_VERSION,
        "transaction_id": transaction_id,
    }))
}

pub fn canonical_sha256(value: &(impl Serialize + ?Sized)) -> Result<String> {
    let value = serde_json::to_value(value).context("serialize canonical projection value")?;
    reject_non_canonical_numbers(&value)?;
    Ok(digest_bytes(&serde_json::to_vec(&value)?))
}

fn reject_non_canonical_numbers(value: &Value) -> Result<()> {
    match value {
        Value::Number(number) if number.is_f64() => {
            bail!("projection canonical JSON does not permit floating-point numbers")
        }
        Value::Array(values) => {
            for value in values {
                reject_non_canonical_numbers(value)?;
            }
        }
        Value::Object(values) => {
            for value in values.values() {
                reject_non_canonical_numbers(value)?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn validate_optional_digest(value: Option<&str>, label: &str) -> Result<()> {
    if let Some(value) = value {
        validate_digest(value, label)?;
    }
    Ok(())
}

fn canonical_host_resource(value: &str) -> bool {
    value
        .strip_prefix("host:")
        .is_some_and(|name| !name.is_empty())
}

fn validate_digest(value: &str, label: &str) -> Result<()> {
    if value.len() != 64
        || !value
            .as_bytes()
            .iter()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        bail!("{label} SHA-256 digest must be 64 lowercase hexadecimal characters");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::workflow::{HostEndpoint, InstanceEndpoint, InstanceMovePolicy};

    use super::*;

    fn config() -> HostManagerConfig {
        serde_json::from_value(json!({
            "schema_version": 1,
            "ssh": {"program":"/bin/false","connect_timeout_seconds":1,"agent_poll_interval_ms":1,"job_timeout_seconds":1,"rsync_program":"/bin/false","tar_program":"/bin/false"},
            "hosts": {
                "source": {"address":"127.0.0.1","host_resource":"host:source-system"},
                "target": {"address":"127.0.0.2","host_resource":"host:target-system"}
            },
            "operation_routes": {
                "deploy-cutover": {
                    "executor":"source",
                    "phase_projection": {"executor":"source","resource":"service:router"}
                },
                "deploy-rollback": {
                    "executor":"source",
                    "phase_projection": {"executor":"source","resource":"service:router"}
                }
            }
        }))
        .unwrap()
    }

    fn spec() -> TransactionSpec {
        let mut spec = TransactionSpec::new(
            Some("move-zulip"),
            vec![MoveItem::Service {
                id: "item-001".to_owned(),
                service: "zulip".to_owned(),
                source_resource: Some("service:abird-zulip".to_owned()),
                target_resource: Some("service:abird-zulip".to_owned()),
                source: HostEndpoint {
                    host: "source".to_owned(),
                    instance: None,
                },
                target: HostEndpoint {
                    host: "target".to_owned(),
                    instance: None,
                },
                data_roots: Vec::new(),
            }],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        spec.declarative_scope = Some("abird".to_owned());
        spec
    }

    #[test]
    fn generic_envelope_contains_move_projector_output() {
        let projection = MoveProjector::derive(
            &spec(),
            &config(),
            MovePhase::Seeded,
            None,
            Some("rev-1".to_owned()),
        )
        .unwrap();
        assert_eq!(projection.intent_kind, "move");
        assert_eq!(projection.phase, "seeded");
        assert_eq!(projection.resources.len(), 2);
        assert_eq!(projection.resources[0].role, "source");
        assert_eq!(
            projection.resources[0].endpoint.resource,
            "service:abird-zulip"
        );
        assert_eq!(projection.resources[0].endpoint.hold_epoch, None);
        assert_eq!(
            projection.resources[1].endpoint.hold_epoch.as_deref(),
            Some("item-001:target-pre-cutover")
        );
        assert_eq!(
            projection
                .hold_epoch_for_execution("source", "service:abird-zulip")
                .unwrap(),
            None
        );
        assert_eq!(
            projection
                .hold_epoch_for_execution("target", "service:abird-zulip")
                .unwrap()
                .as_deref(),
            Some("item-001:target-pre-cutover")
        );
        assert_eq!(
            projection
                .hold_epoch_for_execution("broker", "service:abird-zulip")
                .unwrap(),
            None
        );
        assert!(matches!(
            &projection.effects[0],
            ProjectionEffect::ServicePlacement { scope, host_resource, .. }
                if scope == "abird" && host_resource == "host:source-system"
        ));
        assert!(matches!(
            &projection.effects[1],
            ProjectionEffect::RouteProfile { executor_host, executor_resource, .. }
                if executor_host == "source" && executor_resource == "service:router"
        ));
        assert!(matches!(
            &projection.effects[1],
            ProjectionEffect::RouteProfile { profile, baseline_profile, profiles, .. }
                if profile == "zulip@host:source-system"
                    && baseline_profile == "zulip@host:source-system"
                    && profiles.iter().any(|candidate| {
                        candidate.profile == "zulip@host:source-system"
                            && candidate.resource == "service:abird-zulip"
                    })
        ));
        let binding = projection.job_binding(Some("item-001:target-pre-cutover".to_owned()));
        assert_eq!(binding.intent_digest, projection.intent_sha256);
        assert_eq!(
            binding.hold_epoch.as_deref(),
            Some("item-001:target-pre-cutover")
        );
        projection.validate().unwrap();
    }

    #[test]
    fn generic_validation_is_order_independent_and_rejects_ambiguous_endpoints() {
        let mut projection =
            MoveProjector::derive(&spec(), &config(), MovePhase::Seeded, None, None).unwrap();
        projection.effects.reverse();
        projection.projection_sha256 = projection.expected_projection_sha256().unwrap();
        projection.validate().unwrap();

        let mut duplicate = projection.resources[0].clone();
        duplicate.id = "item-duplicate:source".to_owned();
        projection.resources.push(duplicate);
        projection.projection_sha256 = projection.expected_projection_sha256().unwrap();
        let error = projection.validate().unwrap_err();
        assert!(format!("{error:#}").contains("duplicate host/resource endpoint"));
    }

    #[test]
    fn canonical_projection_values_reject_floats_and_empty_repository_revisions() {
        let error = canonical_sha256(&json!({"unsafe": 1.5})).unwrap_err();
        assert!(format!("{error:#}").contains("floating-point"));

        let mut projection =
            MoveProjector::derive(&spec(), &config(), MovePhase::Seeded, None, None).unwrap();
        projection.previous_repository_revision = Some(String::new());
        projection.projection_sha256 = projection.expected_projection_sha256().unwrap();
        let error = projection.validate().unwrap_err();
        assert!(format!("{error:#}").contains("previous repository revision"));
    }

    #[test]
    fn move_projector_enforces_transition_and_generation() {
        let seeded =
            MoveProjector::derive(&spec(), &config(), MovePhase::Seeded, None, None).unwrap();
        assert!(
            MoveProjector::derive(&spec(), &config(), MovePhase::Cutover, Some(&seeded), None,)
                .is_err()
        );
        let prepared =
            MoveProjector::derive(&spec(), &config(), MovePhase::Prepared, Some(&seeded), None)
                .unwrap();
        let repeated = MoveProjector::derive(
            &spec(),
            &config(),
            MovePhase::Prepared,
            Some(&prepared),
            Some("newer-repository-revision".to_owned()),
        )
        .unwrap();
        assert_eq!(repeated, prepared);
        let cutover = MoveProjector::derive(
            &spec(),
            &config(),
            MovePhase::Cutover,
            Some(&prepared),
            None,
        )
        .unwrap();
        assert_eq!(cutover.generation, 3);
        assert!(matches!(
            &cutover.effects[1],
            ProjectionEffect::RouteProfile { profile, .. }
                if profile == "zulip@host:target-system"
        ));
        assert_eq!(
            cutover.resources[1].endpoint.desired_state,
            DesiredResourceState::Active
        );
    }

    #[test]
    fn instance_projection_fails_before_claiming_false_runtime_equivalence() {
        let spec = TransactionSpec::new(
            Some("move-instance"),
            vec![MoveItem::Instance {
                id: "instance-001".to_owned(),
                source: InstanceEndpoint {
                    controller: "source".to_owned(),
                    remote: "local".to_owned(),
                    project: "default".to_owned(),
                    instance: "demo".to_owned(),
                },
                target: InstanceEndpoint {
                    controller: "target".to_owned(),
                    remote: "local".to_owned(),
                    project: "default".to_owned(),
                    instance: "demo".to_owned(),
                },
                policy: InstanceMovePolicy::default(),
            }],
            Vec::new(),
            Vec::new(),
        )
        .unwrap();
        let error =
            MoveProjector::derive(&spec, &config(), MovePhase::Seeded, None, None).unwrap_err();
        assert!(format!("{error:#}").contains("typed declarative instance adapter"));
    }

    #[test]
    fn generic_digest_detects_tampering() {
        let mut projection =
            MoveProjector::derive(&spec(), &config(), MovePhase::Seeded, None, None).unwrap();
        projection.phase = "other".to_owned();
        assert!(
            projection
                .validate()
                .unwrap_err()
                .to_string()
                .contains("canonical content")
        );
    }

    #[test]
    fn resource_hold_rotates_its_epoch_after_each_unhold() {
        let intent = ResourceHoldIntent {
            projection_id: "hold-zulip".to_owned(),
            host: "target".to_owned(),
            host_resource: "host:target-system".to_owned(),
            resource: "service:zulip".to_owned(),
        };
        let held = ResourceHoldProjector::derive(
            &intent,
            ResourceHoldPhase::Held,
            None,
            Some("rev-1".to_owned()),
        )
        .unwrap();
        assert_eq!(held.intent_kind, "resource_hold");
        assert_eq!(held.resources.len(), 1);
        assert_eq!(
            held.resources[0].endpoint.desired_state,
            DesiredResourceState::Held
        );
        assert_eq!(
            held.resources[0].endpoint.hold_epoch.as_deref(),
            Some("hold-v1")
        );
        assert!(held.activation_requirement.is_none());

        let unheld = ResourceHoldProjector::derive(
            &intent,
            ResourceHoldPhase::Unheld,
            Some(&held),
            Some("rev-2".to_owned()),
        )
        .unwrap();
        assert_eq!(unheld.generation, 2);
        assert_eq!(
            unheld.resources[0].endpoint.desired_state,
            DesiredResourceState::Unheld
        );
        assert_eq!(
            unheld.resources[0].endpoint.hold_epoch,
            held.resources[0].endpoint.hold_epoch
        );
        assert_eq!(unheld.intent_sha256, held.intent_sha256);
        let reheld = ResourceHoldProjector::derive(
            &intent,
            ResourceHoldPhase::Held,
            Some(&unheld),
            Some("rev-3".to_owned()),
        )
        .unwrap();
        assert_eq!(reheld.generation, 3);
        assert_eq!(
            reheld.resources[0].endpoint.hold_epoch.as_deref(),
            Some("hold-v3")
        );
        assert_ne!(
            reheld.resources[0].endpoint.hold_epoch,
            unheld.resources[0].endpoint.hold_epoch
        );
    }

    #[test]
    fn rollback_activation_uses_phase_specific_evidence() {
        let seeded =
            MoveProjector::derive(&spec(), &config(), MovePhase::Seeded, None, None).unwrap();
        let seeded_rollback = MoveProjector::derive(
            &spec(),
            &config(),
            MovePhase::RolledBack,
            Some(&seeded),
            None,
        )
        .unwrap();
        assert!(seeded_rollback.activation_requirement.is_none());
        assert_eq!(
            seeded_rollback.resources[0].endpoint.desired_state,
            DesiredResourceState::Active
        );

        let prepared =
            MoveProjector::derive(&spec(), &config(), MovePhase::Prepared, Some(&seeded), None)
                .unwrap();
        let mut prepared_observation = MoveProjectionObservation::default();
        prepared_observation.insert(
            "item-001",
            MoveItemObservation {
                source_held: true,
                target_ever_started: false,
            },
        );
        let prepared_rollback = MoveProjector::derive_with_observation(
            &spec(),
            &config(),
            MovePhase::RolledBack,
            Some(&prepared),
            None,
            &prepared_observation,
        )
        .unwrap();
        assert_eq!(
            prepared_rollback
                .activation_requirement
                .as_ref()
                .unwrap()
                .kind,
            "rollback_receipt"
        );
        assert_eq!(
            prepared_rollback.resources[0].endpoint.desired_state,
            DesiredResourceState::Active
        );
        assert_eq!(
            prepared_rollback.resources[1]
                .endpoint
                .hold_epoch
                .as_deref(),
            Some("item-001:target-pre-cutover")
        );
        assert_eq!(
            prepared_rollback.resources[0]
                .endpoint
                .transaction_id
                .as_deref(),
            Some("move-zulip--item-001")
        );

        let cutover = MoveProjector::derive(
            &spec(),
            &config(),
            MovePhase::Cutover,
            Some(&prepared),
            None,
        )
        .unwrap();
        assert_eq!(
            cutover.resources[1].endpoint.activation_job_id.as_deref(),
            Some("move-zulip--item-001-cutover-activate-target")
        );
        assert_eq!(
            cutover.resources[1].endpoint.transaction_id.as_deref(),
            Some("move-zulip--item-001")
        );
        let mut cutover_observation = MoveProjectionObservation::default();
        cutover_observation.insert(
            "item-001",
            MoveItemObservation {
                source_held: true,
                target_ever_started: true,
            },
        );
        let blocked = MoveProjector::derive_with_observation(
            &spec(),
            &config(),
            MovePhase::RolledBack,
            Some(&cutover),
            None,
            &cutover_observation,
        )
        .unwrap();
        assert_eq!(
            blocked.activation_requirement.as_ref().unwrap().kind,
            "rollback_receipt"
        );
        assert_eq!(
            blocked.resources[0].endpoint.desired_state,
            DesiredResourceState::Active
        );
        assert_eq!(
            blocked.resources[0].endpoint.activation_job_id.as_deref(),
            Some("move-zulip--item-001-rollback-activate-source")
        );
    }

    #[test]
    fn activation_receipt_is_stable_and_bound_to_requirement() {
        let seeded =
            MoveProjector::derive(&spec(), &config(), MovePhase::Seeded, None, None).unwrap();
        let prepared =
            MoveProjector::derive(&spec(), &config(), MovePhase::Prepared, Some(&seeded), None)
                .unwrap();
        let jobs = [
            "hold-source",
            "hold-target",
            "assert-source-stopped",
            "assert-target-stopped",
            "verify-final",
        ]
        .into_iter()
        .map(|operation| {
            json!({
                "host": "broker",
                "job_id": format!("move-zulip--item-001-prepare-{operation}"),
                "operation": operation,
                "result_sha256": "a".repeat(64),
                "spec_sha256": "b".repeat(64),
            })
        })
        .collect::<Vec<_>>();
        let evidence = vec![json!({"item_id": "item-001", "jobs": jobs})];
        let receipt = MoveProjector::derive_activation_receipt(&prepared, &evidence).unwrap();
        assert_eq!(
            receipt,
            MoveProjector::derive_activation_receipt(&prepared, &evidence).unwrap()
        );
        receipt.validate_for(&prepared).unwrap();

        let mut tampered = receipt;
        tampered.evidence_sha256 = "c".repeat(64);
        assert!(tampered.validate_for(&prepared).is_err());
    }
}
