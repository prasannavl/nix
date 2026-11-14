//! Durable caller references, not a second executor or settlement authority.
//! Dispatch claims precede transport. Reopening observes the same children;
//! missing/uncertain receipts never clear a claim or select another executor.

mod capture;
pub(super) mod controller;
pub(super) mod intent;
mod storage;
use intent::Intent;
pub(crate) use storage::CancellationProbe;

use std::collections::BTreeMap;
use std::path::PathBuf;

use abird_host_agent::build_executor::protocol::{
    self, Command, Reply, Request, Response, Snapshot,
};
use abird_host_agent::build_executor::request::{BuildRequest, Owner};
use abird_host_agent::build_executor::{
    ArtifactDelivery, ArtifactReceipt, ConsumerAck, Outcome, Ownership, Phase,
};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::fleet::host_runtime::HostExecutionTarget;

const MAX_BYTES: usize = 8 * 1024 * 1024;
const MAX_CHILDREN: usize = 64;
const MAX_RETAINED_MATERIAL: usize = 64 * 1024 * 1024;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct MaterialRef {
    digest: String,
    bytes: u64,
    device: u64,
    inode: u64,
}

// Private caller receipts, never deployment or native store authority.
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Consumption {
    ownership: Ownership,
    artifacts: ArtifactReceipt,
    projection_digest: String,
    bytes: u64,
    file: Option<MaterialRef>,
    acquisition: Option<Acquisition>,
    acknowledgement: Option<ConsumerAck>,
    confirmed: bool,
    observed: Option<protocol::ConsumerState>,
    #[serde(default, skip_serializing_if = "is_false")]
    abandoned: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    import_pending: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    import_profile: Option<u32>,
    #[serde(default, skip_serializing_if = "is_false")]
    abandonment_requested: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    abandonment_observed: Option<protocol::AbandonmentState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    planning_digest: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    planning: Option<RetainedPlanning>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct RetainedPlanning {
    bytes: u64,
    file: Option<MaterialRef>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Acquisition {
    binding_digest: String,
    store_id: String,
    claimed_at: u64,
    deadline: u64,
}

impl Acquisition {
    fn active(&self) -> Result<()> {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?;
        ensure!(
            now.as_secs() >= self.claimed_at && now.as_secs() < self.deadline,
            "original consumer acquisition deadline expired or clock regressed"
        );
        Ok(())
    }
}

impl Consumption {
    fn validate(&self, child: &Child) -> Result<()> {
        ensure!(
            valid_digest(&self.projection_digest)
                && self.bytes > 0
                && self.bytes
                    <= abird_host_agent::build_executor::preparation::source::MAX_MATERIAL_BYTES
                        as u64
                && matches!(child.outcome(), Some(Outcome::Succeeded { artifacts }) if artifacts == &self.artifacts)
                && matches!(&child.snapshot, Some(Snapshot::Live { ownership: Some(owner), settled_at: Some(_), .. })
                if owner == &self.ownership),
            "consumer artifact lacks original successful settlement"
        );
        if let Some(file) = &self.file {
            ensure!(
                file.digest == self.projection_digest
                    && file.bytes == self.bytes
                    && file.inode != 0,
                "retained artifact binding differs"
            );
        }
        if let Some(digest) = &self.planning_digest {
            ensure!(valid_digest(digest), "invalid retained planning digest");
        }
        if let Some(planning) = &self.planning {
            ensure!(
                self.file.is_some()
                    && self.planning_digest.is_some()
                    && planning.bytes > 0
                    && planning.bytes
                        <= abird_host_agent::build_executor::preparation::MAX_PREPARED_BYTES as u64,
                "invalid planning reservation"
            );
            if let Some(file) = &planning.file {
                ensure!(
                    valid_digest(&file.digest) && file.bytes == planning.bytes && file.inode != 0,
                    "invalid retained planning binding"
                );
            }
        }
        if let Some(claim) = &self.acquisition {
            ensure!(
                self.planning_digest.is_none()
                    || self.planning.as_ref().is_some_and(|p| p.file.is_some()),
                "acquisition precedes retained planning"
            );
            ensure!(
                self.file.is_some()
                    && valid_digest(&claim.binding_digest)
                    && !claim.store_id.is_empty()
                    && claim.store_id.len() <= 128
                    && claim
                        .store_id
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
                    && !matches!(claim.store_id.as_str(), "." | "..")
                    && claim.claimed_at > 0
                    && claim.claimed_at < claim.deadline
                    && claim.deadline == child.execution_cutoff()?,
                "invalid consumer acquisition claim"
            );
        }
        ensure!(
            self.import_profile.is_none()
                || (self.import_profile == Some(2)
                    && self.acquisition.as_ref().is_some_and(
                        |claim| claim.store_id == super::acquisition::native::STORE_ID
                    )),
            "invalid native import profile"
        );
        ensure!(
            !self.import_pending
                || ((!self.abandoned
                    || (self.import_profile == Some(2)
                        && self.abandonment_requested
                        && self.abandonment_observed.is_none()))
                    && self.acquisition.as_ref().is_some_and(
                        |claim| claim.store_id == super::acquisition::native::STORE_ID
                    )),
            "invalid pending consumer import"
        );
        ensure!(
            !self.abandoned
                || (self.acknowledgement.is_none()
                    && (!self.import_pending
                        || (self.import_profile == Some(2) && self.abandonment_requested))
                    && self.acquisition.as_ref().is_some_and(|claim| {
                        (child.target.local && claim.store_id == super::acquisition::STORE_ID)
                            || claim.store_id == super::acquisition::native::STORE_ID
                    })),
            "invalid settled acquisition abandonment"
        );
        ensure!(
            !self.abandonment_requested || self.abandoned,
            "abandonment request precedes durable revocation"
        );
        if let Some(observed) = &self.abandonment_observed {
            let abandonment = self.abandonment(child)?;
            let request = Request {
                version: protocol::VERSION,
                command: Command::ConsumerAbandonmentStatus {
                    attempt_id: self.ownership.attempt_id.clone(),
                },
            };
            let response = Response {
                version: protocol::VERSION,
                reply: Reply::ConsumerAbandonmentStatus {
                    attempt_id: self.ownership.attempt_id.clone(),
                    state: Some(observed.clone()),
                },
            };
            response.validate_for(&request)?;
            ensure!(
                observed.abandonment_digest == abandonment.digest()?,
                "abandonment observation differs"
            );
        }
        if let Some(receipt) = &self.acknowledgement {
            receipt.validate()?;
            ensure!(
                receipt.ownership == self.ownership
                    && receipt.artifacts == self.artifacts
                    && &receipt.consumer == child.request.controller()
                    && self
                        .acquisition
                        .as_ref()
                        .is_some_and(|claim| claim.store_id == receipt.store_id),
                "consumer acknowledgement differs from acquisition"
            );
        }
        ensure!(
            !self.confirmed || self.acknowledgement.is_some(),
            "consumer confirmation precedes acknowledgement"
        );
        if let Some(observed) = &self.observed {
            let receipt = self
                .acknowledgement
                .as_ref()
                .context("consumer observation before acknowledgement")?;
            let request = Request {
                version: protocol::VERSION,
                command: Command::ConsumerStatus {
                    attempt_id: self.ownership.attempt_id.clone(),
                },
            };
            let response = Response {
                version: protocol::VERSION,
                reply: Reply::ConsumerStatus {
                    attempt_id: self.ownership.attempt_id.clone(),
                    state: Some(observed.clone()),
                },
            };
            response.validate_for(&request)?;
            ensure!(
                self.confirmed && observed.receipt_digest == receipt.digest()?,
                "consumer observation differs"
            );
        }
        Ok(())
    }
}

impl Consumption {
    fn abandonment(
        &self,
        child: &Child,
    ) -> Result<abird_host_agent::build_executor::ConsumerAbandonment> {
        ensure!(
            self.abandonment_requested
                && self.abandoned
                && !self.import_pending
                && self.acknowledgement.is_none(),
            "consumer abandonment is not durably authorized"
        );
        let claim = self
            .acquisition
            .as_ref()
            .context("acquisition not claimed")?;
        let abandonment = abird_host_agent::build_executor::ConsumerAbandonment {
            version: 1,
            ownership: self.ownership.clone(),
            artifacts: self.artifacts.clone(),
            consumer: child.request.controller().clone(),
            store_id: claim.store_id.clone(),
            acquisition_binding: claim.binding_digest.clone(),
        };
        abandonment.validate()?;
        Ok(abandonment)
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Manifest {
    pub version: u32,
    pub run_id: String,
    pub children: BTreeMap<String, Child>,
}

// No Debug: foreground capabilities and private route context remain local.
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Child {
    pub request: Intent,
    pub target: HostExecutionTarget,
    pub(super) native: Option<crate::fleet::build_backend::agent::controller::InvocationRecord>,
    pending: Option<crate::fleet::build_backend::agent::controller::PendingCapture>,
    capture_claimed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    remote_capture: Option<capture::Source>,
    material: Option<MaterialRef>,
    token: Option<String>,
    acceptance: Option<abird_host_agent::build_executor::journal::Acceptance>,
    submit_claimed: bool,
    input_ready: bool,
    event_cursor: u64,
    input_claimed: Option<String>,
    input_received: Option<String>,
    snapshot: Option<Snapshot>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    consumption: Option<Consumption>,
}

impl Child {
    pub(super) fn submitted(&self) -> bool {
        self.submit_claimed
    }

    pub(super) fn pending_capture(
        &self,
    ) -> Option<&crate::fleet::build_backend::agent::controller::PendingCapture> {
        self.pending.as_ref()
    }

    pub(super) fn needs_local_capture(&self) -> bool {
        self.target.local
            && !self.capture_claimed
            && self.material.is_none()
            && self
                .pending
                .as_ref()
                .is_some_and(|pending| pending.bootstrap.is_some() && pending.environment.is_some())
    }

    pub(super) fn require_local_capture(
        &self,
        intent: &abird_host_agent::build_executor::native_intent::Request,
        digest: &str,
    ) -> Result<()> {
        ensure!(
            matches!(&self.request, Intent::Native(request) if request.as_ref() == intent)
                && self.target.local
                && self.capture_claimed
                && self.input_claimed.as_deref() == Some(digest)
                && self
                    .material
                    .as_ref()
                    .is_some_and(|material| material.digest == digest)
                && !self.settled(),
            "local capture private claim differs"
        );
        let bytes = storage::inspect_material(
            &intent.run_id,
            &intent.attempt_id()?,
            self.material
                .as_ref()
                .context("capture directive vanished")?,
        )?;
        ensure!(
            matches!(
                abird_host_agent::build_executor::native_intent::Delivery::decode(&bytes, intent)?,
                abird_host_agent::build_executor::native_intent::Delivery::LocalCapture(_)
            ),
            "capture directive replaced"
        );
        Ok(())
    }

    pub fn new(
        request: BuildRequest,
        target: HostExecutionTarget,
        token: Option<String>,
    ) -> Result<Self> {
        Self::from_intent(Intent::Build(Box::new(request)), target, token, None)
    }

    pub fn native_request(
        request: abird_host_agent::build_executor::native_intent::Request,
        target: HostExecutionTarget,
        token: String,
        pending: crate::fleet::build_backend::agent::controller::PendingCapture,
    ) -> Result<Self> {
        Self::from_intent(
            Intent::Native(Box::new(request)),
            target,
            Some(token),
            Some(pending),
        )
    }

    fn from_intent(
        request: Intent,
        mut target: HostExecutionTarget,
        token: Option<String>,
        pending: Option<crate::fleet::build_backend::agent::controller::PendingCapture>,
    ) -> Result<Self> {
        target.control_master = None;
        let child = Self {
            request,
            target,
            native: None,
            pending,
            capture_claimed: false,
            remote_capture: None,
            material: None,
            token,
            acceptance: None,
            submit_claimed: false,
            input_ready: false,
            event_cursor: 0,
            input_claimed: None,
            input_received: None,
            snapshot: None,
            consumption: None,
        };
        child.validate()?;
        Ok(child)
    }

    fn validate(&self) -> Result<()> {
        self.request.validate()?;
        if let Some(native) = &self.native {
            native.validate(self.request.build()?)?;
            ensure!(
                !self.submit_claimed || self.material.is_some(),
                "native dispatch lacks retained source"
            );
        }
        match (&self.request, &self.pending) {
            (Intent::Native(request), Some(pending)) => {
                pending.validate(request)?;
                ensure!(
                    !self.capture_claimed || (self.submit_claimed && self.input_ready),
                    "native capture precedes admission"
                );
                ensure!(
                    self.material.is_none()
                        || self.capture_claimed
                        || (pending.bootstrap.is_none() && pending.environment.is_none()),
                    "native source lacks capture claim or supplied-input admission"
                );
            }
            (Intent::Build(_), None) => ensure!(
                !self.capture_claimed,
                "resolved input has a native capture claim"
            ),
            _ => anyhow::bail!("native caller capture context differs"),
        }
        if let Some(source) = &self.remote_capture {
            source.validate(self)?;
        } else {
            ensure!(
                !self.installed_remote_capture() || !self.capture_claimed,
                "installed remote capture lacks its original source lifetime"
            );
        }
        if let Some(material) = &self.material {
            ensure!(
                valid_digest(&material.digest)
                    && material.bytes > 0
                    && material.bytes
                        <= abird_host_agent::build_executor::preparation::source::MAX_MATERIAL_BYTES
                            as u64
                    && material.inode != 0,
                "invalid retained source binding"
            );
            ensure!(
                self.input_claimed
                    .as_ref()
                    .is_none_or(|digest| digest == &material.digest),
                "retained source differs from delivery claim"
            );
        }
        ensure!(
            self.target.control_master.is_none()
                && self.target.route.endpoint.node == self.request.builder().host_id,
            "durable child route differs from builder"
        );
        ensure!(
            (self.target.local || self.target.known_hosts_file.is_some())
                && self
                    .target
                    .route
                    .endpoint
                    .identity
                    .as_ref()
                    .is_none_or(|path| path.is_absolute())
                && self.target.route.proxy.hops.iter().all(|hop| hop
                    .endpoint
                    .identity
                    .as_ref()
                    .is_none_or(|path| path.is_absolute())),
            "durable SSH requires explicit host trust and absolute identity paths"
        );
        ensure!(
            self.target.cwd.is_absolute()
                && self
                    .target
                    .known_hosts_file
                    .as_ref()
                    .is_none_or(|path| path.is_absolute())
                && self.target.ssh_connect_timeout_seconds > 0
                && self.target.ssh_connect_timeout_seconds <= 30
                && self.target.remote_read_timeout_seconds > 0
                && self.target.remote_read_timeout_seconds <= 30,
            "unbounded durable caller transport"
        );
        match (self.request.owner(), &self.token) {
            (Owner::Foreground { token_digest }, Some(token)) => {
                ensure!(
                    token.len() >= 32
                        && token.len() <= 128
                        && token.bytes().all(|byte| byte.is_ascii_graphic())
                        && hash(token.as_bytes()) == *token_digest,
                    "foreground capability differs"
                );
            }
            (Owner::Detached, None) => {}
            _ => anyhow::bail!("durable ownership capability differs"),
        }
        if let Some(acceptance) = &self.acceptance {
            ensure!(
                self.submit_claimed
                    && acceptance.attempt_id == self.request.attempt_id()?
                    && acceptance.spec_digest == self.request.digest()?,
                "durable acceptance differs"
            );
        }
        if let Some(digest) = &self.input_claimed {
            ensure!(
                self.submit_claimed && self.input_ready && valid_digest(digest),
                "input precedes durable submit claim"
            );
        }
        if let Some(digest) = &self.input_received {
            ensure!(
                self.input_claimed.as_ref() == Some(digest),
                "input receipt differs from dispatch"
            );
        }
        if let Some(snapshot) = &self.snapshot {
            let request = self.status_request()?;
            // Reuse the wire validator, including positive-settlement fields.
            let response = Response::decode(&serde_json::to_vec(&serde_json::json!({
                "version": protocol::VERSION, "reply": {"kind": "status", "snapshot": snapshot}
            }))?)?;
            response.validate_for(&request)?;
            let acceptance = match snapshot {
                Snapshot::Live { acceptance, .. } | Snapshot::Retired { acceptance, .. } => {
                    acceptance
                }
            };
            ensure!(
                acceptance.spec_digest == self.request.digest()?
                    && self.acceptance.as_ref() == Some(acceptance),
                "child receipt intent differs"
            );
        }
        if let Some(consumption) = &self.consumption {
            consumption.validate(self)?;
        }
        Ok(())
    }

    fn validate_status(&self, response: &Response) -> Result<()> {
        response.validate_for(&self.status_request()?)?;
        if let Reply::Status { snapshot } = &response.reply {
            let acceptance = match snapshot.as_ref() {
                Snapshot::Live { acceptance, .. } | Snapshot::Retired { acceptance, .. } => {
                    acceptance
                }
            };
            ensure!(
                acceptance.spec_digest == self.request.digest()?
                    && self.acceptance.as_ref().is_none_or(|old| old == acceptance),
                "child acceptance changed"
            );
        }
        Ok(())
    }

    pub(in crate::fleet::build_backend::agent) fn status_request(&self) -> Result<Request> {
        Ok(Request {
            version: protocol::VERSION,
            command: Command::Status {
                attempt_id: self.request.attempt_id()?,
            },
        })
    }

    fn execution_cutoff(&self) -> Result<u64> {
        let Some(Snapshot::Live {
            reserved_at: Some(reserved),
            ..
        }) = self.snapshot
        else {
            anyhow::bail!("original execution reservation unavailable");
        };
        reserved
            .checked_add(self.request.runtime_seconds())
            .context("execution cutoff overflow")
    }

    pub fn settled(&self) -> bool {
        self.outcome().is_some()
    }

    pub fn outcome(&self) -> Option<&Outcome> {
        match &self.snapshot {
            Some(Snapshot::Live { outcome, .. }) => outcome.as_ref(),
            Some(Snapshot::Retired { outcome, .. }) => Some(outcome),
            None => None,
        }
    }

    pub fn events_request(&self) -> Result<Request> {
        let attempt_id = self.request.attempt_id()?;
        Ok(Request {
            version: protocol::VERSION,
            command: Command::Events {
                cursor: Some(abird_host_agent::build_executor::events::EventCursor {
                    attempt_id: attempt_id.clone(),
                    after: self.event_cursor,
                }),
                attempt_id,
                limit: abird_host_agent::build_executor::events::MAX_EVENT_PAGE,
            },
        })
    }

    pub fn renew_request(&self) -> Result<Request> {
        ensure!(!self.settled(), "settled child cannot renew");
        let expected = match &self.snapshot {
            Some(Snapshot::Live { ownership, .. }) => ownership.clone(),
            _ => None,
        };
        Ok(Request {
            version: protocol::VERSION,
            command: Command::Renew {
                attempt_id: self.request.attempt_id()?,
                expected,
                token: self
                    .token
                    .clone()
                    .context("detached child has no foreground capability")?,
            },
        })
    }
}

impl Manifest {
    fn retained_bytes(&self) -> u64 {
        self.children
            .values()
            .map(|child| {
                child.material.as_ref().map_or(0, |material| material.bytes)
                    + child.consumption.as_ref().map_or(0, |consumption| {
                        consumption.bytes + consumption.planning.as_ref().map_or(0, |p| p.bytes)
                    })
            })
            .sum()
    }

    pub fn service_owned(&self) -> bool {
        self.children.values().any(
            |child| matches!(&child.request, Intent::Native(request) if request.controller_service),
        )
    }

    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.version == 3 && valid_run(&self.run_id),
            "invalid durable fleet parent"
        );
        ensure!(
            !self.children.is_empty() && self.children.len() <= MAX_CHILDREN,
            "durable child count exceeds bound"
        );
        for (attempt, child) in &self.children {
            child.validate()?;
            ensure!(
                child.request.attempt_id()? == *attempt && child.request.run_id() == self.run_id,
                "durable parent/child reference differs"
            );
        }
        ensure!(
            self.retained_bytes() <= MAX_RETAINED_MATERIAL as u64,
            "retained parent data exceeds bound"
        );
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_BYTES,
            "durable parent exceeds bound"
        );
        Ok(())
    }
}

pub(crate) struct Run {
    directory: storage::Directory,
    manifest: Manifest,
    poisoned: bool,
    // A fresh exclusion acquisition proves earlier helpers (which inherit the
    // same open description) are gone. An unreaped helper in this process does not.
    native_child: Option<String>,
}

impl Run {
    pub fn create(manifest: Manifest) -> Result<Self> {
        Self::create_with_material(manifest, BTreeMap::new())
    }

    pub fn create_with_material(
        mut manifest: Manifest,
        materials: BTreeMap<String, Vec<u8>>,
    ) -> Result<Self> {
        manifest.validate()?;
        ensure!(
            manifest
                .children
                .values()
                .all(|child| child.material.is_none() && child.consumption.is_none()),
            "cannot adopt retained source into a new parent"
        );
        let mut bytes = 0usize;
        for (attempt, material) in &materials {
            let child = manifest
                .children
                .get(attempt)
                .context("retained source names an unknown child")?;
            bytes = bytes
                .checked_add(material.len())
                .context("retained source size overflow")?;
            ensure!(
                bytes <= MAX_RETAINED_MATERIAL,
                "retained parent source exceeds bound"
            );
            child.request.material(material)?;
        }
        ensure!(
            manifest
                .children
                .iter()
                .all(|(attempt, child)| child.native.is_none() || materials.contains_key(attempt)),
            "native parent requires complete retained source before dispatch"
        );
        let directory = storage::Directory::create(&manifest.run_id)?;
        for (attempt, material) in materials {
            let binding = directory.retain_material(&attempt, &material)?;
            manifest
                .children
                .get_mut(&attempt)
                .context("unknown retained source child")?
                .material = Some(binding);
        }
        for (attempt, child) in &mut manifest.children {
            if let Some(path) = &child.target.known_hosts_file {
                child.target.known_hosts_file = Some(directory.pin_known_hosts(attempt, path)?);
            }
            // Built-in routes have no cwd-sensitive script. Custom proxy
            // profiles retain their original cwd rather than silently changing it.
            if child.target.route.proxy_command.is_none()
                && child
                    .target
                    .route
                    .proxy
                    .hops
                    .iter()
                    .all(|hop| hop.proxy_command.is_none())
            {
                child.target.cwd = directory.path().to_owned();
            }
        }
        let mut run = Self {
            directory,
            manifest,
            poisoned: false,
            native_child: None,
        };
        run.save()?;
        Ok(run)
    }

    pub fn open(run_id: &str) -> Result<Self> {
        ensure!(valid_run(run_id), "invalid durable run ID");
        let mut directory = storage::Directory::open(run_id)?;
        let manifest = directory.load()?;
        ensure!(manifest.run_id == run_id, "durable run identity differs");
        ensure!(
            !manifest.service_owned(),
            "CI observer owns this run; attach is observation-only"
        );
        Ok(Self {
            directory,
            manifest,
            poisoned: false,
            native_child: None,
        })
    }

    pub(super) fn try_service(run_id: &str, attempt: &str, spec: &str) -> Result<Option<Self>> {
        ensure!(
            valid_run(run_id) && valid_digest(attempt) && valid_digest(spec),
            "invalid CI observer binding"
        );
        let Some(mut directory) = storage::Directory::try_open(run_id)? else {
            return Ok(None);
        };
        let manifest = directory.load()?;
        ensure!(
            manifest.run_id == run_id && manifest.children.len() == 1,
            "CI observer parent differs"
        );
        let child = manifest
            .children
            .get(attempt)
            .context("CI observer child missing")?;
        ensure!(
            child.submit_claimed
                && child.request.digest()? == spec
                && child.target.local
                && matches!(&child.request, Intent::Native(request) if request.controller_service),
            "CI observer intent differs"
        );
        Ok(Some(Self {
            directory,
            manifest,
            poisoned: false,
            native_child: None,
        }))
    }

    pub fn inspect(run_id: &str) -> Result<Manifest> {
        storage::inspect(run_id)
    }

    /// Caller exclusion only. A released lock means inactive/unconfirmed, never
    /// target settlement, successful deployment or retirement authorization.
    pub fn caller_active(run_id: &str) -> Result<bool> {
        ensure!(valid_run(run_id), "invalid durable run ID");
        let Some(mut directory) = storage::Directory::try_open(run_id)? else {
            return Ok(true);
        };
        let manifest = directory.load()?;
        ensure!(manifest.run_id == run_id, "durable run identity differs");
        Ok(false)
    }

    /// Explicit local retirement: settled failures, completed handoffs, or an
    /// expired/cancelled unacknowledged, import-settled acquisition. Abandonment
    /// revokes consumption durably before removing exact caller roots; it never
    /// asserts consumption or releases the builder's protection. Unconfirmed
    /// import producers veto cleanup even after a later verified handoff.
    pub fn retire(mut self) -> Result<()> {
        self.require_native_quiescence()?;
        self.require_capture_retirement()?;
        ensure!(
            !self.poisoned,
            "durable caller write uncertain; reopen for observation"
        );
        let cancelled = self.cancelled()?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_secs();
        let mut abandon = Vec::new();
        let mut roots = BTreeMap::new();
        for (attempt, child) in &self.manifest.children {
            let settled = matches!(
                &child.snapshot,
                Some(Snapshot::Live {
                    settled_at: Some(_),
                    outcome: Some(_),
                    ..
                }) | Some(Snapshot::Retired { .. })
            );
            ensure!(settled, "child {attempt} is not positively settled");
            ensure!(
                !child
                    .consumption
                    .as_ref()
                    .is_some_and(|record| record.import_pending),
                "consumer import producer settlement is unconfirmed for {attempt}"
            );
            let abandonment_released = child
                .consumption
                .as_ref()
                .and_then(|record| record.abandonment_observed.as_ref())
                .is_some_and(|state| state.release_digest.is_some());
            ensure!(
                !child
                    .consumption
                    .as_ref()
                    .is_some_and(|record| record.abandonment_requested)
                    || self.handoff_retired(attempt)?,
                "builder abandonment cleanup not completed for {attempt}"
            );
            let released = abandonment_released
                || child
                    .consumption
                    .as_ref()
                    .and_then(|record| record.observed.as_ref())
                    .is_some_and(|observed| observed.release_digest.is_some());
            if matches!(child.outcome(), Some(Outcome::Succeeded { .. })) && !released {
                let record = child
                    .consumption
                    .as_ref()
                    .context("successful child not consumed")?;
                let claim = record
                    .acquisition
                    .as_ref()
                    .context("successful child lacks acquisition")?;
                ensure!(
                    record.acknowledgement.is_none()
                        && !record.import_pending
                        && ((child.target.local && claim.store_id == super::acquisition::STORE_ID)
                            || claim.store_id == super::acquisition::native::STORE_ID)
                        && (record.abandoned || cancelled || now >= claim.deadline),
                    "successful child {attempt} requires source release or cancelled/expired settled acquisition abandonment"
                );
                abandon.push(attempt.clone());
            }
            if child
                .consumption
                .as_ref()
                .is_some_and(|record| record.acquisition.is_some())
            {
                self.require_retained_planning(attempt)?;
                let delivery = self
                    .retained_artifact(attempt)?
                    .context("artifact not retained")?;
                // Cleanup may remove only outputs and the optional evaluated
                // tree, never arbitrary residue or a different destination.
                roots.insert(
                    attempt.clone(),
                    super::acquisition::retained_paths(&delivery, true),
                );
            }
        }
        if !abandon.is_empty() {
            for attempt in abandon {
                self.child_mut(&attempt)?
                    .consumption
                    .as_mut()
                    .context("artifact intent missing")?
                    .abandoned = true;
            }
            self.save()?; // Crash after this point cannot resurrect consumption.
        }
        match super::acquisition::run_roots(&self.manifest.run_id) {
            Ok(path) => super::acquisition::release_run_roots(&path, &roots)?,
            Err(error) if !roots.is_empty() => return Err(error),
            Err(_) => {}
        }
        let id = self.manifest.run_id.clone();
        self.directory.retire(&id)
    }

    pub fn request_cancel(run_id: &str) -> Result<(Manifest, bool)> {
        let manifest = Self::inspect(run_id)?;
        // Local disk failure must not prevent authenticated remote withdrawal.
        let persisted = storage::cancel(run_id, &manifest).is_ok();
        Ok((manifest, persisted))
    }

    pub fn cancelled(&self) -> Result<bool> {
        self.directory.cancelled(&self.manifest)
    }

    pub fn cancellation_probe(&self) -> Result<CancellationProbe> {
        self.directory.cancellation_probe(&self.manifest)
    }

    pub fn acquisition_lock(&self) -> Result<std::fs::File> {
        self.directory.inherited_lock()
    }

    /// Record before native import dispatch. A previous unknown import is not
    /// cleared by a later pre-import rejection or by client process exit.
    pub fn begin_import(&mut self, attempt: &str) -> Result<bool> {
        ensure!(
            self.native_child.is_none(),
            "previous acquisition helper unconfirmed; reopen under original exclusion"
        );
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        let record = self
            .child_mut(attempt)?
            .consumption
            .as_mut()
            .context("acquisition missing")?;
        let claim = record
            .acquisition
            .as_ref()
            .context("acquisition not claimed")?;
        claim.active()?;
        ensure!(
            claim.store_id == super::acquisition::native::STORE_ID
                && !record.abandoned
                && record.acknowledgement.is_none(),
            "import unavailable"
        );
        let pending = record.import_pending;
        ensure!(
            !pending || record.import_profile == Some(2),
            "legacy import effects require their original adapter"
        );
        record.import_profile = Some(2);
        record.import_pending = true;
        self.native_child = Some(attempt.to_owned());
        self.save()?;
        Ok(pending)
    }

    pub fn require_native_quiescence(&self) -> Result<()> {
        ensure!(
            !self.poisoned && self.native_child.is_none(),
            "native helper is unconfirmed; reopen under the original exclusion"
        );
        Ok(())
    }

    /// Covers shared pinning, DevBuild publication and ACK verification too.
    /// An inherited clone is not a new exclusion while this writer stays open.
    pub fn begin_native_helper(&mut self, attempt: &str) -> Result<()> {
        self.require_native_quiescence()?;
        ensure!(
            self.manifest.children.contains_key(attempt),
            "unknown native attempt"
        );
        self.native_child = Some(attempt.to_owned());
        Ok(())
    }

    /// Called only after the managed child returned a bound receipt AND was reaped.
    /// This settles the caller-side root producer, not the daemon importer.
    pub fn native_helper_returned(&mut self, attempt: &str) -> Result<()> {
        ensure!(
            self.native_child.as_deref() == Some(attempt),
            "acquisition helper differs"
        );
        self.native_child = None;
        Ok(())
    }

    pub fn require_import_reconciliation(&self, attempt: &str) -> Result<()> {
        ensure!(
            !self.poisoned && self.native_child.is_none(),
            "acquisition helper is unconfirmed; reopen the run"
        );
        let record = self
            .manifest
            .children
            .get(attempt)
            .and_then(|child| child.consumption.as_ref())
            .context("acquisition missing")?;
        ensure!(
            record.import_pending && record.import_profile == Some(2),
            "no bound frozen-metadata NoRepair import to reconcile"
        );
        Ok(())
    }

    /// Explicit retirement may discard incomplete immutable store effects only
    /// after durable consumption revocation. No abandonment RPC is authorized
    /// while import_pending remains true; failed probes preserve this intent.
    pub fn prepare_import_reconciliation(&mut self, attempt: &str) -> Result<bool> {
        self.require_import_reconciliation(attempt)?;
        let cancelled = self.cancelled()?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_secs();
        let record = self
            .child_mut(attempt)?
            .consumption
            .as_mut()
            .context("acquisition missing")?;
        let claim = record
            .acquisition
            .as_ref()
            .context("acquisition not claimed")?;
        if record.acknowledgement.is_some()
            || !(record.abandoned || cancelled || now >= claim.deadline)
        {
            return Ok(false);
        }
        record.abandoned = true;
        record.abandonment_requested = true;
        self.save()?;
        Ok(true)
    }

    /// Native immutable-effect proof, NOT a claim that a daemon process exited.
    pub fn import_effects_reconciled(&mut self, attempt: &str) -> Result<()> {
        self.require_import_reconciliation(attempt)?;
        self.child_mut(attempt)?
            .consumption
            .as_mut()
            .context("acquisition missing")?
            .import_pending = false;
        self.save()
    }

    /// Trusted native receipt only: no import began, or this invocation's
    /// synchronous RPCs completed, with NO earlier uncertain invocation. May
    /// record settlement after cancellation, never infer it from helper exit.
    pub fn import_settled(&mut self, attempt: &str) -> Result<()> {
        ensure!(
            self.native_child.is_none(),
            "acquisition helper is unconfirmed"
        );
        let record = self
            .child_mut(attempt)?
            .consumption
            .as_mut()
            .context("acquisition missing")?;
        ensure!(
            record.import_pending && record.acknowledgement.is_none() && !record.abandoned,
            "import settlement differs"
        );
        record.import_pending = false;
        self.save()
    }

    pub fn import_pending(&self, attempt: &str) -> Result<bool> {
        ensure!(!self.poisoned, "durable caller write uncertain");
        Ok(self
            .manifest
            .children
            .get(attempt)
            .context("unknown consumer attempt")?
            .consumption
            .as_ref()
            .is_some_and(|record| record.import_pending))
    }

    pub fn has_material(&self, attempt: &str) -> bool {
        self.manifest
            .children
            .get(attempt)
            .is_some_and(|child| child.material.is_some())
    }

    pub fn retained_material(&self, attempt: &str) -> Result<Option<Vec<u8>>> {
        ensure!(
            !self.poisoned,
            "durable caller write uncertain; reopen for observation"
        );
        let child = self
            .manifest
            .children
            .get(attempt)
            .context("unknown durable child")?;
        let Some(binding) = &child.material else {
            return Ok(None);
        };
        let bytes = self.directory.read_material(attempt, binding)?;
        child.request.material(&bytes)?;
        Ok(Some(bytes))
    }

    pub fn retain_artifact(&mut self, attempt: &str, delivery: &ArtifactDelivery) -> Result<()> {
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        let bytes = delivery.encode()?;
        ArtifactDelivery::decode(&bytes, &delivery.ownership, &delivery.artifacts)?;
        let child = self.child_mut(attempt)?;
        ensure!(
            child.consumption.is_none(),
            "artifact retention already claimed"
        );
        child.consumption = Some(Consumption {
            ownership: delivery.ownership.clone(),
            artifacts: delivery.artifacts.clone(),
            projection_digest: hash(&bytes),
            bytes: bytes.len() as u64,
            file: None,
            acquisition: None,
            acknowledgement: None,
            confirmed: false,
            observed: None,
            abandoned: false,
            import_pending: false,
            import_profile: None,
            abandonment_requested: false,
            abandonment_observed: None,
            planning_digest: delivery.prepared.planning_digest.clone(),
            planning: None,
        });
        // Intent and the original aggregate byte reservation precede creation.
        self.save()?;
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        self.poisoned = true;
        let file = self.directory.retain_artifact(attempt, &bytes)?;
        self.manifest
            .children
            .get_mut(attempt)
            .context("artifact child vanished")?
            .consumption
            .as_mut()
            .context("artifact intent vanished")?
            .file = Some(file);
        self.save()?;
        Ok(())
    }

    pub fn retained_artifact(&self, attempt: &str) -> Result<Option<ArtifactDelivery>> {
        ensure!(
            !self.poisoned,
            "durable caller write uncertain; reopen for observation"
        );
        let child = self
            .manifest
            .children
            .get(attempt)
            .context("artifact child missing")?;
        let Some(consumption) = &child.consumption else {
            return Ok(None);
        };
        let file = consumption
            .file
            .as_ref()
            .context("artifact publication unconfirmed; do not recreate it")?;
        let bytes = self.directory.read_artifact(attempt, file)?;
        let delivery =
            ArtifactDelivery::decode(&bytes, &consumption.ownership, &consumption.artifacts)?;
        ensure!(
            delivery.prepared.planning_digest == consumption.planning_digest,
            "retained planning digest differs"
        );
        Ok(Some(delivery))
    }

    /// Persist the exact acquisition policy/store binding before native effects.
    /// This primitive never replaces a claim; same-binding idempotent import or
    /// verification retries use reconcile_acquisition, not a fresh reservation.
    pub fn claim_acquisition(
        &mut self,
        attempt: &str,
        binding_digest: &str,
        store_id: &str,
    ) -> Result<(ArtifactDelivery, std::time::Instant)> {
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        let delivery = self
            .retained_artifact(attempt)?
            .context("artifact not retained")?;
        if delivery.prepared.planning_digest.is_some() {
            self.retained_planning(attempt)?
                .context("planning not retained before acquisition")?;
        }
        let monotonic = std::time::Instant::now();
        let wall = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?;
        let child = self.child_mut(attempt)?;
        let deadline = child.execution_cutoff()?;
        let runtime = child.request.runtime_seconds();
        let cutoff = abird_host_agent::build_executor::process::cutoff(
            Some(deadline - runtime),
            runtime,
            wall,
            monotonic,
        )?;
        let record = child
            .consumption
            .as_mut()
            .context("artifact intent missing")?;
        ensure!(
            record.acquisition.is_none(),
            "acquisition already claimed; observe the original consumer"
        );
        record.acquisition = Some(Acquisition {
            binding_digest: binding_digest.to_owned(),
            store_id: store_id.to_owned(),
            claimed_at: wall.as_secs(),
            deadline,
        });
        self.save()?;
        ensure!(
            !self.cancelled()? && std::time::Instant::now() < cutoff,
            "durable parent cancelled or original acquisition deadline expired"
        );
        Ok((delivery, cutoff))
    }

    /// Same-binding reconciliation under the original cutoff. Root/verification
    /// and a future signed import of exactly this immutable output set/store may
    /// be idempotently retried; realization is never authorized here. The held
    /// Directory exclusion prevents concurrent caller writers.
    pub fn reconcile_acquisition(
        &mut self,
        attempt: &str,
        binding_digest: &str,
        store_id: &str,
    ) -> Result<(ArtifactDelivery, std::time::Instant)> {
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        let delivery = self
            .retained_artifact(attempt)?
            .context("artifact not retained")?;
        self.require_retained_planning(attempt)?;
        let child = &self.manifest.children[attempt];
        let record = child
            .consumption
            .as_ref()
            .context("artifact intent missing")?;
        if record.acquisition.is_none() {
            return self.claim_acquisition(attempt, binding_digest, store_id);
        }
        self.require_acquisition_binding(attempt, binding_digest, store_id)?;
        ensure!(
            !record.abandoned && record.acknowledgement.is_none(),
            "acquisition abandoned or receipt already recorded; do not reacquire"
        );
        let claim = record
            .acquisition
            .as_ref()
            .context("acquisition not claimed")?;
        claim.active()?;
        let runtime = child.request.runtime_seconds();
        let monotonic = std::time::Instant::now();
        let wall = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?;
        let cutoff = abird_host_agent::build_executor::process::cutoff(
            Some(claim.deadline - runtime),
            runtime,
            wall,
            monotonic,
        )?;
        // No manifest rewrite: claimed_at, deadline, policy and store stay exact.
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        Ok((delivery, cutoff))
    }

    /// Policy/store equality also applies to recorded ACK retries, which need
    /// not fit the acquisition deadline but must recheck their original roots.
    pub fn require_acquisition_binding(
        &self,
        attempt: &str,
        binding_digest: &str,
        store_id: &str,
    ) -> Result<()> {
        ensure!(
            !self.poisoned,
            "durable caller write uncertain; reopen for observation"
        );
        let claim = self
            .manifest
            .children
            .get(attempt)
            .and_then(|child| child.consumption.as_ref())
            .and_then(|record| record.acquisition.as_ref())
            .context("acquisition not claimed")?;
        ensure!(
            claim.binding_digest == binding_digest && claim.store_id == store_id,
            "consumer acquisition binding differs"
        );
        Ok(())
    }

    /// Trusted acquisition adapter only, after native authentication/content
    /// verification and durable consumer protection. Not inferred from exit0.
    pub fn record_consumption(&mut self, attempt: &str, receipt: ConsumerAck) -> Result<()> {
        self.require_native_quiescence()?;
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        self.require_retained_planning(attempt)?;
        self.retained_artifact(attempt)?
            .context("artifact not retained")?;
        let record = self
            .child_mut(attempt)?
            .consumption
            .as_mut()
            .context("artifact intent missing")?;
        ensure!(
            !record.abandoned && !record.import_pending,
            "consumer acquisition abandoned or import effects unconfirmed"
        );
        if let Some(old) = &record.acknowledgement {
            ensure!(old == &receipt, "consumer receipt changed");
            return Ok(());
        }
        record
            .acquisition
            .as_ref()
            .context("acquisition not claimed")?
            .active()?;
        record.acknowledgement = Some(receipt);
        self.save()
    }

    pub fn consumer_ack(&self, attempt: &str) -> Result<&ConsumerAck> {
        ensure!(
            !self.poisoned,
            "durable caller write uncertain; reopen for observation"
        );
        self.manifest
            .children
            .get(attempt)
            .and_then(|child| child.consumption.as_ref())
            .and_then(|record| record.acknowledgement.as_ref())
            .context("verified consumer receipt missing")
    }

    /// Observation only; not consumer-root validity or target phase authority.
    pub fn handoff_retired(&self, attempt: &str) -> Result<bool> {
        ensure!(!self.poisoned, "durable caller write uncertain");
        let child = self
            .manifest
            .children
            .get(attempt)
            .context("unknown consumer attempt")?;
        Ok(child.consumption.as_ref().is_some_and(|record| {
            record.observed.as_ref().is_some_and(|state| state.retired)
                || record
                    .abandonment_observed
                    .as_ref()
                    .is_some_and(|state| state.retired)
        }))
    }

    pub fn source_release(&self, attempt: &str) -> Result<Option<&str>> {
        self.consumer_ack(attempt)?;
        let state = self.manifest.children[attempt]
            .consumption
            .as_ref()
            .context("consumer intent missing")?;
        Ok(state
            .observed
            .as_ref()
            .and_then(|observed| observed.release_digest.as_deref()))
    }

    pub fn observe_consumer(
        &mut self,
        attempt: &str,
        request: &Request,
        response: &Response,
    ) -> Result<()> {
        response.validate_for(request)?;
        let original = self.consumer_ack(attempt)?;
        ensure!(
            match &request.command {
                Command::AcknowledgeConsumer { receipt } => receipt.as_ref() == original,
                Command::ConsumerStatus { attempt_id } => attempt_id == attempt,
                _ => false,
            },
            "consumer observation request differs"
        );
        let record = self
            .child_mut(attempt)?
            .consumption
            .as_mut()
            .context("consumer intent missing")?;
        let receipt = record
            .acknowledgement
            .as_ref()
            .context("consumer receipt missing")?;
        ensure!(
            receipt.ownership.attempt_id == attempt,
            "consumer attempt differs"
        );
        let digest = receipt.digest()?;
        match &response.reply {
            Reply::ConsumerAcknowledged { receipt_digest, .. } => {
                ensure!(*receipt_digest == digest, "consumer confirmation differs");
                if record.confirmed {
                    return Ok(());
                }
                record.confirmed = true;
            }
            Reply::ConsumerStatus {
                state: Some(observed),
                ..
            } => {
                ensure!(
                    observed.receipt_digest == digest,
                    "consumer observation differs"
                );
                if let Some(old) = &record.observed {
                    ensure!(
                        (!old.retired || observed.retired)
                            && old.release_digest.as_ref().is_none_or(
                                |released| Some(released) == observed.release_digest.as_ref()
                            ),
                        "consumer release observation regressed"
                    );
                }
                if record.observed.as_ref() == Some(observed) {
                    return Ok(());
                }
                record.confirmed = true;
                record.observed = Some(observed.clone());
            }
            Reply::ConsumerStatus { state: None, .. } => {
                ensure!(!record.confirmed, "consumer acknowledgement disappeared");
                return Ok(());
            }
            Reply::Rejected { .. } | Reply::Unconfirmed { .. } => return Ok(()),
            _ => anyhow::bail!("unexpected consumer response"),
        }
        self.save()
    }

    /// Persist revocation before any abandonment request. Exact retries reuse
    /// the original ownership, artifact, consumer, binding and store identity.
    pub fn claim_abandonment(
        &mut self,
        attempt: &str,
    ) -> Result<abird_host_agent::build_executor::ConsumerAbandonment> {
        self.require_native_quiescence()?;
        self.require_retained_planning(attempt)?;
        self.retained_artifact(attempt)?
            .context("artifact not retained")?;
        let cancelled = self.cancelled()?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_secs();
        let child = self.child_mut(attempt)?;
        let record = child.consumption.as_mut().context("acquisition missing")?;
        let claim = record
            .acquisition
            .as_ref()
            .context("acquisition not claimed")?;
        ensure!(
            record.acknowledgement.is_none()
                && !record.import_pending
                && (record.abandoned || cancelled || now >= claim.deadline),
            "abandonment requires cancelled/expired unacknowledged acquisition and positive import settlement"
        );
        record.abandoned = true;
        record.abandonment_requested = true;
        self.save()?;
        self.abandonment(attempt)
    }

    pub fn abandonment(
        &self,
        attempt: &str,
    ) -> Result<abird_host_agent::build_executor::ConsumerAbandonment> {
        ensure!(!self.poisoned, "durable caller write uncertain");
        let child = self
            .manifest
            .children
            .get(attempt)
            .context("unknown consumer attempt")?;
        child
            .consumption
            .as_ref()
            .context("acquisition missing")?
            .abandonment(child)
    }

    pub fn abandonment_release(&self, attempt: &str) -> Result<Option<&str>> {
        self.abandonment(attempt)?;
        Ok(self.manifest.children[attempt]
            .consumption
            .as_ref()
            .and_then(|record| record.abandonment_observed.as_ref())
            .and_then(|state| state.release_digest.as_deref()))
    }

    pub fn observe_abandonment(
        &mut self,
        attempt: &str,
        request: &Request,
        response: &Response,
    ) -> Result<()> {
        response.validate_for(request)?;
        let original = self.abandonment(attempt)?;
        ensure!(
            match &request.command {
                Command::AbandonConsumer { abandonment } => abandonment.as_ref() == &original,
                Command::ConsumerAbandonmentStatus { attempt_id } => attempt_id == attempt,
                _ => false,
            },
            "abandonment observation request differs"
        );
        let digest = original.digest()?;
        let record = self
            .child_mut(attempt)?
            .consumption
            .as_mut()
            .context("acquisition missing")?;
        let observed = match &response.reply {
            Reply::ConsumerAbandoned {
                abandonment_digest, ..
            } => {
                ensure!(
                    *abandonment_digest == digest,
                    "abandonment confirmation differs"
                );
                if record.abandonment_observed.is_some() {
                    return Ok(());
                }
                protocol::AbandonmentState {
                    abandonment_digest: digest.clone(),
                    release_digest: None,
                    retired: false,
                }
            }
            Reply::ConsumerAbandonmentStatus {
                state: Some(state), ..
            } => state.clone(),
            Reply::ConsumerAbandonmentStatus { state: None, .. } => {
                ensure!(
                    record.abandonment_observed.is_none(),
                    "confirmed abandonment disappeared"
                );
                return Ok(());
            }
            Reply::Rejected { .. } | Reply::Unconfirmed { .. } => return Ok(()),
            _ => anyhow::bail!("unexpected abandonment response"),
        };
        ensure!(
            observed.abandonment_digest == digest,
            "abandonment observation differs"
        );
        if let Some(old) = &record.abandonment_observed {
            ensure!(
                (!old.retired || observed.retired)
                    && old
                        .release_digest
                        .as_ref()
                        .is_none_or(|released| Some(released) == observed.release_digest.as_ref()),
                "abandonment release observation regressed"
            );
        }
        record.abandonment_observed = Some(observed);
        self.save()
    }

    pub fn manifest(&self) -> &Manifest {
        &self.manifest
    }
    pub fn path(&self) -> &std::path::Path {
        self.directory.path()
    }

    fn child_mut(&mut self, attempt: &str) -> Result<&mut Child> {
        ensure!(
            !self.poisoned,
            "durable caller write uncertain; reopen for observation"
        );
        self.manifest
            .children
            .get_mut(attempt)
            .context("unknown durable child")
    }

    /// The returned command has one dispatch budget. A crash after this write
    /// and before send still consumes it; reconnect uses Status, not Submit.
    pub fn claim_submit(&mut self, attempt: &str) -> Result<Request> {
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        let child = self.child_mut(attempt)?;
        ensure!(
            !child.submit_claimed,
            "submission already claimed; observe the original attempt"
        );
        ensure!(
            child.native.is_none() || child.material.is_some(),
            "native dispatch lacks retained source"
        );
        child.submit_claimed = true;
        let request = Request {
            version: protocol::VERSION,
            command: child.request.submit(),
        };
        self.save()?;
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        Ok(request)
    }

    /// Persist before any source/profile inspection. Reopening cannot repeat a
    /// claimed capture, even if no source bytes or delivery receipt survived.
    pub fn claim_capture(
        &mut self,
        attempt: &str,
        response: Response,
    ) -> Result<crate::fleet::build_backend::agent::controller::CaptureClaim> {
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        ensure!(
            matches!(&response.reply, Reply::Status { snapshot } if matches!(snapshot.as_ref(),
            Snapshot::Live { ownership: Some(_), phase: Phase::Running, reserved_at: Some(_), outcome: None,
                input: Some(abird_host_agent::build_executor::source_transport::InputState::Ready), .. })),
            "fresh capture admission is unconfirmed"
        );
        self.observe(attempt, response)?;
        let child = self.child_mut(attempt)?;
        let Intent::Native(request) = &child.request else {
            anyhow::bail!("capture requires native admission");
        };
        let Some(Snapshot::Live {
            ownership: Some(owner),
            phase: abird_host_agent::build_executor::Phase::Running,
            reserved_at: Some(reserved_at),
            outcome: None,
            ..
        }) = &child.snapshot
        else {
            anyhow::bail!("capture admission is unconfirmed");
        };
        ensure!(
            child.submit_claimed
                && child.input_ready
                && !child.capture_claimed
                && child.material.is_none(),
            "native capture unavailable or already claimed"
        );
        let claim = crate::fleet::build_backend::agent::controller::CaptureClaim {
            request: (**request).clone(),
            pending: child
                .pending
                .clone()
                .context("native capture context missing")?,
            ownership: owner.clone(),
            reserved_at: *reserved_at,
        };
        if child.needs_remote_capture() {
            child.remote_capture = Some(capture::Source::new(&claim));
        }
        child.capture_claimed = true;
        self.save()?;
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        Ok(claim)
    }

    pub fn retain_capture(&mut self, attempt: &str, bytes: &[u8]) -> Result<()> {
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        let child = self.child_mut(attempt)?;
        ensure!(
            matches!(child.request, Intent::Native(_))
                && child.capture_claimed
                && child.remote_capture.is_none()
                && child.material.is_none()
                && child.input_claimed.is_none()
                && !child.settled(),
            "native capture already consumed or unavailable"
        );
        child.request.material(bytes)?;
        let retained = self.manifest.retained_bytes();
        ensure!(
            retained
                .checked_add(u64::try_from(bytes.len())?)
                .is_some_and(|size| size <= MAX_RETAINED_MATERIAL as u64),
            "retained parent source exceeds bound"
        );
        self.poisoned = true;
        let binding = self.directory.retain_material(attempt, bytes)?;
        self.manifest
            .children
            .get_mut(attempt)
            .context("unknown native capture child")?
            .material = Some(binding);
        self.save()?;
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        Ok(())
    }

    pub fn claim_inputs(&mut self, attempt: &str, material: &[u8]) -> Result<()> {
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        let child = self.child_mut(attempt)?;
        ensure!(
            child.submit_claimed
                && child.input_ready
                && child.input_claimed.is_none()
                && !child.settled(),
            "source delivery unavailable or already claimed"
        );
        ensure!(
            !matches!(child.request, Intent::Native(_)) || child.material.is_some(),
            "native input lacks original retained capture"
        );
        child.request.material(material)?;
        child.input_claimed = Some(hash(material));
        self.save()?;
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        Ok(())
    }

    pub fn input_receipt(
        &mut self,
        receipt: &abird_host_agent::build_executor::source_transport::Receipt,
    ) -> Result<()> {
        let child = self.child_mut(&receipt.attempt_id)?;
        ensure!(
            receipt.version == 1
                && receipt.request_digest == child.request.digest()?
                && child.input_claimed.as_ref() == Some(&receipt.material_digest),
            "source receipt differs from durable child"
        );
        child.input_received = Some(receipt.material_digest.clone());
        self.save()
    }

    pub fn accept(&mut self, attempt: &str, response: &Response) -> Result<()> {
        let child = self.child_mut(attempt)?;
        response.validate_for(&Request {
            version: protocol::VERSION,
            command: child.request.submit(),
        })?;
        if let Reply::Accepted { acceptance } = &response.reply {
            ensure!(
                child
                    .acceptance
                    .as_ref()
                    .is_none_or(|old| old == acceptance),
                "durable acceptance changed"
            );
            child.acceptance = Some(acceptance.clone());
            self.save()?;
        }
        Ok(())
    }

    pub fn observe_events(&mut self, request: &Request, response: Response) -> Result<()> {
        response.validate_for(request)?;
        let Command::Events { attempt_id, .. } = &request.command else {
            anyhow::bail!("expected durable event observation");
        };
        let child = self.child_mut(attempt_id)?;
        ensure!(
            child.snapshot.is_some(),
            "event observation requires a bound child status"
        );
        let Reply::Events { page } = response.reply else {
            return Ok(());
        };
        ensure!(
            page.next.after >= child.event_cursor,
            "event observation regressed"
        );
        for event in &page.events {
            if let abird_host_agent::build_executor::events::EventKind::InputsReceived { digest } =
                &event.detail
            {
                ensure!(
                    child.input_claimed.as_ref() == Some(digest),
                    "observed source delivery differs"
                );
            }
        }
        for event in page.events {
            match event.detail {
                abird_host_agent::build_executor::events::EventKind::InputReady => {
                    child.input_ready = true
                }
                abird_host_agent::build_executor::events::EventKind::InputsReceived { digest } => {
                    child.input_received = Some(digest);
                }
                _ => {}
            }
        }
        child.event_cursor = page.next.after;
        self.save()
    }

    pub fn observe(&mut self, attempt: &str, response: Response) -> Result<()> {
        let child = self.child_mut(attempt)?;
        child.validate_status(&response)?;
        let Reply::Status { snapshot } = response.reply else {
            return Ok(());
        };
        let acceptance = match snapshot.as_ref() {
            Snapshot::Live { acceptance, .. } | Snapshot::Retired { acceptance, .. } => acceptance,
        };
        ensure!(
            acceptance.spec_digest == child.request.digest()?
                && child
                    .acceptance
                    .as_ref()
                    .is_none_or(|old| old == acceptance),
            "child acceptance changed"
        );
        child.acceptance = Some(acceptance.clone());
        let observed_outcome = match snapshot.as_ref() {
            Snapshot::Live { outcome, .. } => outcome.as_ref(),
            Snapshot::Retired { outcome, .. } => Some(outcome),
        };
        if let Some(outcome) = child.outcome() {
            ensure!(
                observed_outcome == Some(outcome),
                "settled child receipt regressed or changed"
            );
            return Ok(());
        }
        if let (Some(Snapshot::Live { phase: old, .. }), Snapshot::Live { phase: new, .. }) =
            (&child.snapshot, snapshot.as_ref())
        {
            ensure!(rank(*new) >= rank(*old), "child observation regressed");
        }
        if let Snapshot::Live { input, .. } = snapshot.as_ref() {
            use abird_host_agent::build_executor::source_transport::InputState;
            if let Some(digest) = &child.input_received {
                ensure!(
                    matches!(input, Some(InputState::Received { digest: observed }) if observed == digest),
                    "durable input receipt regressed"
                );
            }
            match input {
                Some(InputState::Ready) => child.input_ready = true,
                Some(InputState::Received { digest }) => {
                    child.input_ready = true;
                    // An intake racing root capture stays in the authenticated
                    // snapshot, not input_received, until the root claim binds it.
                    if child.remote_capture.is_none() || child.input_claimed.is_some() {
                        ensure!(
                            child.input_claimed.as_ref() == Some(digest),
                            "status source delivery differs"
                        );
                        child.input_received = Some(digest.clone());
                    }
                }
                None => {}
            }
        }
        child.submit_claimed = true;
        child.snapshot = Some(*snapshot);
        self.save()
    }

    fn save(&mut self) -> Result<()> {
        self.poisoned = true;
        self.manifest.validate()?;
        self.directory.save(&self.manifest)?;
        self.poisoned = false;
        Ok(())
    }
}

fn rank(phase: Phase) -> u8 {
    match phase {
        Phase::Pending => 0,
        Phase::Queued => 1,
        Phase::Starting => 2,
        Phase::Running => 3,
        Phase::Verifying => 4,
        Phase::Stopping => 5,
        _ => 6,
    }
}

fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn is_false(value: &bool) -> bool {
    !value
}
fn valid_run(value: &str) -> bool {
    value.len() == 32
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
fn valid_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub(super) fn state_home() -> Result<PathBuf> {
    let base = match std::env::var_os("XDG_STATE_HOME").filter(|value| !value.is_empty()) {
        Some(value) => PathBuf::from(value),
        None => PathBuf::from(
            std::env::var_os("HOME").context("durable fleet state needs HOME or XDG_STATE_HOME")?,
        )
        .join(".local/state"),
    };
    ensure!(
        base.is_absolute(),
        "durable fleet state base must be absolute"
    );
    Ok(base)
}

fn root() -> Result<PathBuf> {
    Ok(state_home()?.join("abird/abird-host-manager/fleet-owned"))
}
