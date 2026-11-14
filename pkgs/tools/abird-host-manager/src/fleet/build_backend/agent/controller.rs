//! Native invocation → immutable owned intent. Selection/evaluation stay in the
//! existing admitted preparation engine; this adapter never evaluates inventory,
//! resolves Git refs, realizes paths or grants deployment authority.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use abird_host_agent::build_executor::context::{
    BuildAction, EvaluationIntent, InputLocation, InputTree, PlanJobs,
};
use abird_host_agent::build_executor::preparation::source::{
    MAX_MATERIAL_BYTES, MAX_PATCH_BYTES, Material,
};
use abird_host_agent::build_executor::protocol::{self, Description, Reply, Request, Response};
use abird_host_agent::build_executor::request::{
    BuildRequest, NixOptions, Owner, Peer, REQUEST_VERSION, RequestId, Selection, Source,
};
use abird_host_agent::build_executor::strategy::Strategy;
use abird_host_agent::sha256::digest_bytes;
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::fleet::build_backend::agent::control::transport::Transport;
use crate::fleet::build_backend::agent::run::{Child, Manifest, Run, controller};
use crate::fleet::cli::{Action, Invocation, JobCount};
use crate::fleet::host_runtime::HostExecutionTarget;
use crate::fleet::preparation::InventoryContext;
use crate::fleet::repository::{CommitSha, StagedPatch};

/// Locations captured by the native pinning/snapshot adapter, not discovered on
/// reconnect. Explicit external bindings also cover untracked in-repo overlays.
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Locations {
    pub build_flake: InputLocation,
    pub inventory: InputLocation,
    pub overlay: Option<InputLocation>,
    pub repository_config: Option<InputLocation>,
    pub dependency_flake: InputLocation,
}

impl Locations {
    pub fn from_native(
        source_root: &Path,
        build_repository: &Path,
        inventory: &InventoryContext,
        external: &BTreeMap<PathBuf, InputLocation>,
    ) -> Result<Self> {
        normalized(source_root)?;
        for flake in [build_repository, inventory.dependency_repository.as_path()] {
            ensure!(
                (flake.starts_with(source_root) && !external.contains_key(flake))
                    || external
                        .get(flake)
                        .is_some_and(|location| matches!(location.tree, InputTree::Git { .. })),
                "native external flake requires its own Git-context binding, not a path snapshot"
            );
        }
        let paths = [
            Some(build_repository),
            Some(inventory.config.as_path()),
            inventory.overlay.as_deref(),
            inventory.repository_config.as_deref(),
            Some(inventory.dependency_repository.as_path()),
        ];
        ensure!(
            external.len() <= 5
                && external.keys().all(|path| paths
                    .iter()
                    .flatten()
                    .any(|expected| *expected == path.as_path())),
            "unused native context binding"
        );
        let locate = |path: &Path| -> Result<InputLocation> {
            normalized(path)?;
            if let Some(location) = external.get(path) {
                ensure!(
                    matches!(
                        location.tree,
                        InputTree::Snapshot { .. } | InputTree::Git { .. }
                    ),
                    "external context lacks a captured binding"
                );
                return Ok(location.clone());
            }
            let relative = path
                .strip_prefix(source_root)
                .context("external native context was not captured")?;
            Ok(InputLocation::source(
                relative.to_str().context("non-UTF8 native context")?,
            ))
        };
        Ok(Self {
            build_flake: locate(build_repository)?,
            inventory: locate(&inventory.config)?,
            overlay: inventory.overlay.as_deref().map(locate).transpose()?,
            repository_config: inventory
                .repository_config
                .as_deref()
                .map(locate)
                .transpose()?,
            dependency_flake: locate(&inventory.dependency_repository)?,
        })
    }

    fn evaluation(&self, invocation: &Invocation) -> Result<EvaluationIntent> {
        let options = &invocation.options;
        ensure!(
            !options.no_override || self.overlay.is_none(),
            "native overlay contradicts --no-override"
        );
        ensure!(
            options.config_override.is_none() || self.overlay.is_some(),
            "explicit native overlay was not captured"
        );
        let evaluation = EvaluationIntent {
            version: abird_host_agent::build_executor::context::VERSION,
            action: action(&invocation.action)?,
            build_flake: self.build_flake.clone(),
            inventory: self.inventory.clone(),
            overlay: self.overlay.clone(),
            repository_config: self.repository_config.clone(),
            dependency_flake: self.dependency_flake.clone(),
            plan_jobs: match options.build_plan_jobs {
                JobCount::Auto => PlanJobs::Auto,
                JobCount::Count(jobs) => PlanJobs::Count {
                    jobs: jobs
                        .try_into()
                        .context("native plan concurrency exceeds bound")?,
                },
            },
            deploy_jobs_per_domain: options
                .deploy_jobs_per_domain_explicit
                .then(|| {
                    u16::try_from(options.deploy_jobs_per_domain)
                        .context("native deployment wave exceeds bound")
                })
                .transpose()?,
        };
        evaluation.validate()?;
        Ok(evaluation)
    }
}

/// Already-resolved native source. Construction is not capture/admission proof;
/// filesystem/Git/NAR effects belong to the original accounted source adapter.
/// No Debug; raw patch/NAR bytes stay private until data-lane delivery.
pub struct CapturedSource {
    revision: CommitSha,
    patch: Option<StagedPatch>,
    snapshots: BTreeMap<String, Vec<u8>>,
    git_context: Option<abird_host_agent::build_executor::preparation::git_context::GitContext>,
    capsule: Option<abird_host_agent::build_executor::preparation::capsule::Capsule>,
}

impl CapturedSource {
    pub fn new(
        revision: CommitSha,
        patch: Option<StagedPatch>,
        snapshots: BTreeMap<String, Vec<u8>>,
    ) -> Result<Self> {
        ensure!(snapshots.len() <= 5, "native context count exceeds bound");
        let mut bytes = 0usize;
        if let Some(patch) = &patch {
            ensure!(
                patch.base == revision && patch.bytes.len() <= MAX_PATCH_BYTES,
                "native staged source differs or exceeds bound"
            );
            bytes = patch.bytes.len();
        }
        for (digest, nar) in &snapshots {
            bytes = bytes
                .checked_add(nar.len())
                .context("native source size overflow")?;
            ensure!(
                bytes <= MAX_MATERIAL_BYTES / 2 && digest_bytes(nar) == *digest,
                "native context differs or exceeds bound"
            );
        }
        Ok(Self {
            revision,
            patch,
            snapshots,
            git_context: None,
            capsule: None,
        })
    }

    pub(crate) fn with_git_context(
        mut self,
        context: abird_host_agent::build_executor::preparation::git_context::GitContext,
    ) -> Result<Self> {
        context.validate()?;
        self.git_context = Some(context);
        Ok(self)
    }

    pub fn with_capsule(
        mut self,
        capsule: abird_host_agent::build_executor::preparation::capsule::Capsule,
    ) -> Result<Self> {
        ensure!(
            self.git_context.is_none(),
            "legacy Git and capsule capture overlap"
        );
        ensure!(
            capsule.primary()?.revision == self.revision.as_str(),
            "capsule primary revision differs"
        );
        self.capsule = Some(capsule);
        Ok(self)
    }

    fn intent(&self) -> Source {
        Source {
            revision: self.revision.as_str().to_owned(),
            base_revision: self.revision.as_str().to_owned(),
            tree_digest: None,
            patch_digest: self.patch.as_ref().map(|patch| digest_bytes(&patch.bytes)),
        }
    }

    fn material(self, request: &BuildRequest) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(&self.material_value(request)?)?)
    }

    fn material_value(self, request: &BuildRequest) -> Result<Material> {
        let value = Material {
            version: if self.capsule.is_some() { 2 } else { 1 },
            request_digest: request.digest()?,
            patch: self.patch.map(|patch| hex(&patch.bytes)),
            snapshots: self
                .snapshots
                .into_iter()
                .map(|(digest, nar)| (digest, hex(&nar)))
                .collect(),
            git_context: self.git_context,
            capsule: self.capsule,
        };
        value.validate(request)?;
        Ok(value)
    }
}

/// Full normal command semantics survive controller loss. This private record is
/// evidence, not a command to reexecute; capabilities remain in Child separately.
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct InvocationRecord {
    pub caller: Invocation,
    pub effective: Invocation,
    pub source_root: PathBuf,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caller_repository:
        Option<abird_host_agent::build_executor::native_intent::CallerRepository>,
    pub locations: Locations,
    pub ci_argv: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_context_digest: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkout: Option<abird_host_agent::build_executor::native_intent::Checkout>,
}

impl InvocationRecord {
    pub(crate) fn validate(&self, request: &BuildRequest) -> Result<()> {
        normalized(&self.source_root)?;
        if let Some(repository) = &self.caller_repository {
            repository.validate()?;
            ensure!(
                repository.path == self.source_root
                    && self.effective.action == Action::DevBuild
                    && request
                        .parent
                        .as_ref()
                        .is_some_and(|parent| parent.bootstrap_digest.is_some()
                            && parent.caller_digest.is_some()),
                "caller repository identity lacks original DevBuild capture"
            );
        }
        if let Some(checkout) = &self.checkout {
            checkout.validate()?;
            checkout.workspace(&request.run_id)?;
            ensure!(
                request
                    .parent
                    .as_ref()
                    .is_some_and(|parent| parent.bootstrap_digest.is_some()),
                "caller checkout lacks original installed capture"
            );
        }
        if let Some(digest) = &self.git_context_digest {
            ensure!(
                digest.len() == 64
                    && digest
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                    && request
                        .parent
                        .as_ref()
                        .is_some_and(|parent| parent.bootstrap_digest.is_some()
                            && parent.caller_digest.is_some()),
                "native Git context lacks original capture binding"
            );
        }
        ensure!(
            matches!(request.owner, Owner::Foreground { .. }),
            "native parent requires renewable child ownership"
        );
        ensure!(
            self.caller.options.strategy == Strategy::Agent
                && self.effective.options.strategy == Strategy::Agent,
            "native parent did not select owned execution"
        );
        ensure!(
            self.caller.action == self.effective.action && !self.effective.options.ci_trigger,
            "native parent action/controller differs"
        );
        if let Some(argv) = &self.ci_argv {
            ensure!(
                self.caller.options.ci_trigger
                    && !argv.is_empty()
                    && argv.len() <= 256
                    && argv.iter().map(String::len).sum::<usize>() <= 32 * 1024,
                "invalid durable CI invocation"
            );
            ensure!(
                self.effective.options.no_override && self.locations.overlay.is_none(),
                "managed CI overlay is forbidden"
            );
        } else {
            ensure!(
                self.caller == self.effective && !self.caller.options.ci_trigger,
                "direct invocation changed"
            );
        }
        ensure!(
            self.locations.evaluation(&self.effective)? == request.evaluation
                && selection(&self.effective) == request.selection
                && self.effective.options.required_hosts == request.required_hosts,
            "native parent/request semantics differ"
        );
        if self.effective.options.dirty_staged_patch_stdin {
            ensure!(
                request.source.patch_digest.is_some()
                    && self.effective.options.dirty_staged_base.as_ref()
                        == Some(&request.source.base_revision),
                "native stdin patch base differs"
            );
        }
        ensure!(
            request.source.patch_digest.is_none() || self.effective.options.dirty_staged,
            "native patch was not requested"
        );
        if let Some(sha) = self
            .effective
            .options
            .sha
            .as_ref()
            .filter(|_| self.effective.action != Action::DevBuild)
        {
            // Symbolic names were resolved once by capture, never again here.
            if sha.len() == 40 && sha.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                ensure!(
                    sha == &request.source.revision,
                    "native exact revision changed"
                );
            }
        }
        ensure!(
            serde_json::to_vec(self)?.len() <= 128 * 1024,
            "native invocation record exceeds bound"
        );
        Ok(())
    }
}

pub struct Binding {
    pub declaration: Description,
    pub controller: Peer,
    pub builder: Peer,
    pub repository_id: String,
    pub nix: NixOptions,
    pub target: HostExecutionTarget,
}

/// Preparation projection only. Transport credentials and deployment controls
/// stay in the private caller record; they never enter native admission metadata.
pub fn preparation_invocation(invocation: &Invocation) -> Invocation {
    let source = &invocation.options;
    Invocation {
        action: invocation.action.clone(),
        options: crate::fleet::cli::Options {
            strategy: source.strategy,
            strategy_explicit: true,
            sha: source.sha.clone(),
            host: source.host.clone(),
            hosts: source.hosts.clone(),
            groups: source.groups.clone(),
            required_hosts: source.required_hosts.clone(),
            nix_config: source.nix_config.clone(),
            control_plane_first: source.control_plane_first,
            build_plan_jobs: source.build_plan_jobs,
            build_jobs: source.build_jobs,
            deploy_jobs_per_domain: source.deploy_jobs_per_domain,
            deploy_jobs_per_domain_explicit: source.deploy_jobs_per_domain_explicit,
            dirty: source.dirty,
            dirty_staged: source.dirty_staged,
            dirty_staged_patch_stdin: source.dirty_staged_patch_stdin,
            dirty_staged_base: source.dirty_staged_base.clone(),
            no_override: source.no_override,
            config_override: source.config_override.clone(),
            config: source.config.clone(),
            ci_trigger: source.ci_trigger,
            dry_run: source.dry_run,
            ..crate::fleet::cli::Options::default()
        },
    }
}

/// Shared by caller construction and the fixed unprivileged installed validator.
/// This verifies metadata semantics, not coherent caller Git/profile consumption.
pub fn validate_resolution(
    input: abird_host_agent::build_executor::native_intent::Validation,
) -> Result<String> {
    input.validate()?;
    let parent = input
        .request
        .parent
        .as_ref()
        .context("native admission missing")?;
    let invocation: Invocation = serde_json::from_value(parent.invocation.clone())
        .map_err(|_| anyhow::anyhow!("invalid native invocation"))?;
    ensure!(
        invocation == preparation_invocation(&invocation)
            && action(&invocation.action)? == parent.action,
        "native admission contains non-preparation options"
    );
    let record: InvocationRecord = serde_json::from_value(input.context)
        .map_err(|_| anyhow::anyhow!("invalid native capture context"))?;
    ensure!(
        preparation_invocation(&record.caller) == invocation,
        "native capture changed the admitted command"
    );
    record.validate(&input.request)?;
    if let Some(argv) = &record.ci_argv {
        let forwarded = Invocation::parse_legacy(argv.clone())?;
        ensure!(
            forwarded.action == record.effective.action
                && forwarded.options.strategy == Strategy::Agent
                && (forwarded.options.groups.is_empty()
                    || forwarded.options.groups == record.effective.options.groups)
                && (forwarded.options.host.is_none()
                    || forwarded.options.host == record.effective.options.host)
                && (forwarded.options.hosts.is_none()
                    || forwarded.options.hosts == record.effective.options.hosts)
                && (forwarded.options.nix_config.is_none()
                    || forwarded.options.nix_config == record.effective.options.nix_config)
                && (!forwarded.options.control_plane_first
                    || record.effective.options.control_plane_first)
                && (forwarded.options.required_hosts.is_empty()
                    || forwarded.options.required_hosts == record.effective.options.required_hosts)
                && forwarded.options.sha == record.effective.options.sha
                && forwarded.options.dirty_staged == record.effective.options.dirty_staged
                && forwarded.options.dirty_staged_patch_stdin
                    == record.effective.options.dirty_staged_patch_stdin
                && forwarded.options.dirty_staged_base
                    == record.effective.options.dirty_staged_base
                && forwarded.options.no_override,
            "native CI capture differs from forwarded command"
        );
    }
    input.request.binding_digest()
}

/// Only metadata negotiation; actual submission still requires policy matching,
/// authentication and admission. Failure never chooses another route or builder.
pub fn describe(
    target: &HostExecutionTarget,
    transport: &mut impl Transport,
) -> Result<Description> {
    let request = Request {
        version: protocol::VERSION,
        command: protocol::Command::Describe,
    };
    let response = transport.request(target, &request)?;
    response.validate_for(&request)?;
    let Reply::Description { declaration } = response.reply else {
        anyhow::bail!("owned builder declaration is unconfirmed or unavailable");
    };
    ensure!(
        declaration.identity.builder_id == target.route.endpoint.node,
        "owned declaration differs from native route"
    );
    Ok(declaration)
}

/// A single native batch, with all selectors left for the admitted evaluator.
/// No per-host scheduler or eager inventory/catalog expansion.
pub struct Submission {
    record: InvocationRecord,
    binding: Binding,
    source: CapturedSource,
}

impl Submission {
    pub fn native(
        invocation: Invocation,
        source_root: PathBuf,
        locations: Locations,
        binding: Binding,
        source: CapturedSource,
    ) -> Result<Self> {
        ensure!(
            !invocation.options.ci_trigger,
            "CI invocation requires the native CI planner"
        );
        Self::new(
            InvocationRecord {
                caller: invocation.clone(),
                effective: invocation,
                source_root,
                caller_repository: None,
                locations,
                ci_argv: None,
                git_context_digest: None,
                checkout: None,
            },
            binding,
            source,
        )
    }

    pub(crate) fn ci(
        record: InvocationRecord,
        binding: Binding,
        source: CapturedSource,
    ) -> Result<Self> {
        Self::new(record, binding, source)
    }

    fn new(record: InvocationRecord, binding: Binding, source: CapturedSource) -> Result<Self> {
        action(&record.effective.action)?;
        binding.declaration.validate()?;
        ensure!(
            binding.nix.max_jobs <= binding.declaration.policy.max_jobs
                && binding.nix.cores <= binding.declaration.policy.max_cores,
            "native Nix capacity exceeds installed policy"
        );
        ensure!(
            record
                .locations
                .evaluation(&record.effective)?
                .snapshot_digests()
                == source
                    .snapshots
                    .keys()
                    .map(String::as_str)
                    .collect::<BTreeSet<_>>(),
            "native context coverage differs"
        );
        Ok(Self {
            record,
            binding,
            source,
        })
    }

    /// Bind captured native inputs inside the original early admission. No new
    /// request identity, foreground capability, deadline or Submit command.
    pub fn resolve(
        self,
        parent: &abird_host_agent::build_executor::native_intent::Request,
    ) -> Result<abird_host_agent::build_executor::native_intent::Material> {
        ensure!(
            self.binding.repository_id == parent.repository_id
                && self.binding.controller == parent.controller
                && self.binding.builder == parent.builder
                && self.binding.declaration.identity == parent.storage
                && self.binding.declaration.issuer == parent.issuer
                && self.binding.declaration.policy.digest()? == parent.policy_digest
                && self.binding.nix == parent.nix,
            "native capture binding changed after admission"
        );
        Self::resolve_capture(self.record, self.source, parent)
    }

    pub(crate) fn resolve_capture(
        record: InvocationRecord,
        source: CapturedSource,
        parent: &abird_host_agent::build_executor::native_intent::Request,
    ) -> Result<abird_host_agent::build_executor::native_intent::Material> {
        let action = action(&record.effective.action)?;
        let request = BuildRequest {
            schema_version: REQUEST_VERSION,
            executor_version: 1,
            parent: Some(Box::new(parent.clone())),
            id: parent.id.clone(),
            run_id: parent.run_id.clone(),
            issuer: parent.issuer.clone(),
            repository_id: parent.repository_id.clone(),
            source: source.intent(),
            selection: selection(&record.effective),
            required_hosts: record.effective.options.required_hosts.clone(),
            evaluation: record.locations.evaluation(&record.effective)?,
            mode: action.mode(),
            controller: parent.controller.clone(),
            builder: parent.builder.clone(),
            storage: parent.storage.clone(),
            nix: parent.nix.clone(),
            policy_digest: parent.policy_digest.clone(),
            deadlines: parent.deadlines.clone(),
            owner: parent.owner.clone(),
            predecessor: None,
        };
        request.validate()?;
        let mut record = record;
        let git_context_digest = if let Some(capsule) = &source.capsule {
            capsule.validate(&request)?;
            Some(capsule.digest()?)
        } else {
            source
                .git_context
                .as_ref()
                .map(|context| context.digest())
                .transpose()?
        };
        ensure!(
            record.git_context_digest.is_none() || record.git_context_digest == git_context_digest,
            "native Git context changed"
        );
        record.git_context_digest = git_context_digest;
        record.caller = preparation_invocation(&record.caller);
        record.effective = preparation_invocation(&record.effective);
        let context = serde_json::to_value(&record)?;
        validate_resolution(
            abird_host_agent::build_executor::native_intent::Validation {
                request: request.clone(),
                context: context.clone(),
            },
        )?;
        let source = source.material_value(&request)?;
        let material = abird_host_agent::build_executor::native_intent::Material {
            version: 1,
            request,
            context,
            source,
        };
        material.validate(parent)?;
        Ok(material)
    }

    /// Captured-input compatibility entry; not an admission-before-capture path.
    pub fn record(self) -> Result<Controller> {
        ensure!(
            !self.record.effective.options.dry_run,
            "dry owned intent cannot be submitted"
        );
        let id = Uuid::new_v4().simple().to_string();
        let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        let policy = &self.binding.declaration.policy;
        let request = BuildRequest {
            parent: None,
            schema_version: REQUEST_VERSION,
            executor_version: 1,
            id: RequestId {
                issued_at: SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs(),
                nonce: Uuid::new_v4().simple().to_string(),
            },
            run_id: id.clone(),
            issuer: self.binding.declaration.issuer,
            repository_id: self.binding.repository_id,
            source: self.source.intent(),
            controller: self.binding.controller,
            builder: self.binding.builder,
            storage: self.binding.declaration.identity,
            mode: action(&self.record.effective.action)?.mode(),
            evaluation: self.record.locations.evaluation(&self.record.effective)?,
            selection: selection(&self.record.effective),
            required_hosts: self.record.effective.options.required_hosts.clone(),
            nix: self.binding.nix,
            policy_digest: policy.digest()?,
            deadlines: policy.deadlines.clone(),
            owner: Owner::Foreground {
                token_digest: digest_bytes(token.as_bytes()),
            },
            predecessor: None,
        };
        request.validate()?;
        self.record.validate(&request)?;
        let attempt = request.attempt_id()?;
        let material = self.source.material(&request)?;
        let mut child = Child::new(request, self.binding.target, Some(token))?;
        child.native = Some(self.record);
        let run = Run::create_with_material(
            Manifest {
                version: 3,
                run_id: id,
                children: BTreeMap::from([(attempt.clone(), child)]),
            },
            BTreeMap::from([(attempt, material)]),
        )?;
        Ok(Controller {
            run,
            initial_dispatch: true,
        })
    }
}

/// Private caller metadata persisted before admission; no source reads here.
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PendingCapture {
    pub invocation: Invocation,
    pub cwd: PathBuf,
    pub bootstrap: Option<crate::fleet::build_backend::agent::bootstrap::Reference>,
    #[serde(default)]
    pub environment: Option<crate::fleet::build_backend::agent::capture::Environment>,
}

impl PendingCapture {
    pub(crate) fn digest(&self) -> Result<String> {
        let mut bytes = b"abird-owned-private-caller-v1\n".to_vec();
        bytes.extend(serde_json::to_vec(self)?);
        ensure!(
            bytes.len() <= 128 * 1024,
            "private caller context exceeds bound"
        );
        Ok(digest_bytes(&bytes))
    }

    pub(crate) fn validate(
        &self,
        request: &abird_host_agent::build_executor::native_intent::Request,
    ) -> Result<()> {
        normalized(&self.cwd)?;
        ensure!(
            request.caller_digest.as_deref() == Some(self.digest()?.as_str()),
            "private caller context differs from admission"
        );
        if let Some(reference) = &self.bootstrap {
            reference.validate()?;
        }
        if let Some(environment) = &self.environment {
            environment.validate()?;
        }
        ensure!(
            self.bootstrap.as_ref().map(|reference| &reference.digest)
                == request.bootstrap_digest.as_ref(),
            "native bootstrap binding differs"
        );
        ensure!(
            // `--dry` still builds, consumes and roots (build-validating dry
            // deployment); only target-mutating phases are suppressed.
            self.invocation.options.strategy == Strategy::Agent
                && serde_json::to_value(preparation_invocation(&self.invocation))?
                    == request.invocation
                && action(&self.invocation.action)? == request.action
                && serde_json::to_vec(self)?.len() <= 128 * 1024,
            "pending native capture differs from admitted command"
        );
        Ok(())
    }
}

/// A one-shot metadata claim, not proof of physical caller containment. Source
/// adapters must enforce the original deadline and their installed capture role.
pub struct CaptureClaim {
    pub request: abird_host_agent::build_executor::native_intent::Request,
    pub pending: PendingCapture,
    pub ownership: abird_host_agent::build_executor::Ownership,
    pub reserved_at: u64,
}

/// The early entry seam: negotiated route/policy + CLI metadata only. Do not
/// evaluate inventory or prepare a workspace before calling this constructor.
pub fn admit(pending: PendingCapture, binding: Binding) -> Result<Controller> {
    admit_with_service(pending, binding, false, None)
}

/// Receiving CI entry: retain only the already-forwarded exact source inputs.
/// No repository/profile reads or checkout before the builder accepts the job.
pub(super) fn admit_repository(
    invocation: Invocation,
    source_root: PathBuf,
    binding: Binding,
    runtime: &crate::fleet::runtime::RuntimeConfig,
) -> Result<Controller> {
    ensure!(
        matches!(invocation.action, Action::Build | Action::Deploy)
            && !invocation.options.ci_trigger
            && invocation.options.no_override
            && invocation.options.config_override.is_none()
            && !invocation.options.use_repo_script
            && (!invocation.options.dirty_staged || invocation.options.dirty_staged_patch_stdin),
        "owned CI requires the ordinary SHA/patch command with --no-override"
    );
    let revision = CommitSha::parse(
        invocation
            .options
            .sha
            .clone()
            .context("owned CI requires an exact --sha")?,
    )?;
    let patch = crate::fleet::runtime::staged_patch(&invocation, &source_root, runtime)?;
    let source = CapturedSource::new(revision, patch, BTreeMap::new())?;
    let recipe = abird_host_agent::build_executor::native_intent::RepositoryRecipe {
        request_digest: String::new(),
        source_root: source_root.clone(),
        source: source.intent(),
        patch: source.patch.as_ref().map(|patch| hex(&patch.bytes)),
    };
    admit_with_service(
        PendingCapture {
            invocation,
            cwd: source_root,
            bootstrap: None,
            environment: None,
        },
        binding,
        false,
        Some(recipe),
    )
}

pub(in crate::fleet) fn configured_invocation(
    intent: &abird_host_agent::build_executor::native_intent::Request,
    source: &Source,
    patch: bool,
) -> Result<Invocation> {
    intent.validate()?;
    source.validate()?;
    let invocation: Invocation = serde_json::from_value(intent.invocation.clone())?;
    let options = &invocation.options;
    ensure!(
        intent.bootstrap_digest.is_none()
            && intent.caller_digest.is_some()
            && source.base_revision == source.revision
            && source.tree_digest.is_none()
            && patch == source.patch_digest.is_some()
            && invocation == preparation_invocation(&invocation)
            && matches!(invocation.action, Action::Build | Action::Deploy)
            && action(&invocation.action)? == intent.action
            && options.strategy == Strategy::Agent
            && !options.ci_trigger
            && options.no_override
            && options.config_override.is_none()
            && options.sha.as_deref() == Some(source.revision.as_str())
            && options.dirty_staged == patch
            && options.dirty_staged_patch_stdin == patch
            && (!patch
                || options.dirty_staged_base.as_deref() == Some(source.base_revision.as_str())),
        "configured source differs from the forwarded CI command"
    );
    Ok(invocation)
}

pub fn admit_service(pending: PendingCapture, binding: Binding) -> Result<Controller> {
    ensure!(
        binding.target.local,
        "durable CI parent must use its installed local control lane"
    );
    admit_with_service(pending, binding, true, None)
}

fn admit_with_service(
    pending: PendingCapture,
    binding: Binding,
    controller_service: bool,
    recipe: Option<abird_host_agent::build_executor::native_intent::RepositoryRecipe>,
) -> Result<Controller> {
    binding.declaration.validate()?;
    ensure!(
        binding.target.route.endpoint.node == binding.builder.host_id
            && binding.builder.host_id == binding.declaration.identity.builder_id,
        "native admission route differs"
    );
    let run_id = Uuid::new_v4().simple().to_string();
    let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
    let request = abird_host_agent::build_executor::native_intent::Request {
        version: 1,
        executor_version: 1,
        controller_service,
        bootstrap_digest: pending
            .bootstrap
            .as_ref()
            .map(|reference| reference.digest.clone()),
        caller_digest: Some(pending.digest()?),
        id: RequestId {
            nonce: Uuid::new_v4().simple().to_string(),
            issued_at: SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs(),
        },
        run_id: run_id.clone(),
        issuer: binding.declaration.issuer,
        repository_id: binding.repository_id,
        controller: binding.controller,
        builder: binding.builder,
        storage: binding.declaration.identity.clone(),
        action: action(&pending.invocation.action)?,
        invocation: serde_json::to_value(preparation_invocation(&pending.invocation))?,
        nix: binding.nix,
        policy_digest: binding.declaration.policy.digest()?,
        deadlines: binding.declaration.policy.deadlines.clone(),
        owner: Owner::Foreground {
            token_digest: digest_bytes(token.as_bytes()),
        },
    };
    request.authority(&binding.declaration.identity, &binding.declaration.policy)?;
    pending.validate(&request)?;
    let attempt = request.attempt_id()?;
    let materials = if let Some(mut recipe) = recipe {
        recipe.request_digest = request.digest()?;
        recipe.validate(&request)?;
        configured_invocation(&request, &recipe.source, recipe.patch.is_some())?;
        BTreeMap::from([(
            attempt.clone(),
            serde_json::to_vec(
                &abird_host_agent::build_executor::native_intent::Delivery::Repository { recipe },
            )?,
        )])
    } else {
        BTreeMap::new()
    };
    let child = Child::native_request(request, binding.target, token, pending)?;
    let run = Run::create_with_material(
        Manifest {
            version: 3,
            run_id,
            children: BTreeMap::from([(attempt, child)]),
        },
        materials,
    )?;
    Ok(Controller {
        run,
        initial_dispatch: true,
    })
}

/// Normal native entry, reached only after the unchanged availability guard.
/// No legacy workspace/inventory/source preparation occurs before this parent.
pub(in crate::fleet) fn run_installed(invocation: Invocation) -> Result<()> {
    crate::fleet::signal::install()?;
    // Reject what this backend cannot complete before any lock/state effect.
    // The forwarding operator has already resolved the CI revision/patch.
    // Independent observer ownership remains a separate availability gate.
    ensure!(
        !invocation.options.ci_trigger,
        "CI forwarding belongs to the ordinary caller"
    );
    let managed = crate::fleet::inventory_routing::managed_execution_context()?;
    // Run's Terraform phases need a writable original worktree.
    ensure!(
        !matches!(invocation.action, Action::Run),
        "owned builds hand off Build/DevBuild/Deploy; run Terraform separately"
    );
    // Reject predictable local consumer incompatibility before recording a run,
    // acquiring the action lock or submitting any remote work.
    consumer_nix()?;
    let bootstrap = crate::fleet::build_backend::agent::bootstrap::Bootstrap::load().context(
        "agent strategy requires this host's installed build controller metadata \
         (services.abird-host-manager.buildController)",
    )?;
    let service = bootstrap.controller_service;
    ensure!(
        !service,
        abird_host_agent::build_executor::strategy::AGENT_CI_DEFERRED
    );
    if !managed {
        crate::fleet::build_backend::agent::capture::Environment::current()?.supported()?;
    }
    // The ordinary host-local action lock, held for the whole action.
    let lock = super::deployment::ActionLock(crate::fleet::runtime::action_mutex(&invocation)?);
    let cwd = std::env::current_dir()?;
    let mut transport =
        crate::fleet::build_backend::agent::control::transport::Installed::default();
    let mut parent = if managed {
        let runtime = crate::fleet::runtime::RuntimeConfig::from_environment();
        let source_root = runtime
            .inherited_repository_root
            .as_ref()
            .or(invocation.options.repo_path.as_ref())
            .cloned()
            .unwrap_or(cwd);
        ensure!(
            source_root.is_absolute(),
            "owned CI repository root must be absolute"
        );
        bootstrap.admit_repository(invocation, source_root, &runtime, &mut transport)?
    } else {
        bootstrap.admit(invocation, cwd, &mut transport)?
    };
    let run = parent.run_id().to_owned();
    println!(
        "{}",
        serde_json::json!({"run_id": run, "state": "recorded", "attempts": parent.run.manifest().children.keys().collect::<Vec<_>>() })
    );
    let accepted = parent.submit(&mut transport)?;
    ensure!(
        accepted.len() == parent.run.manifest().children.len()
            && accepted
                .values()
                .all(|reply| matches!(reply.reply, Reply::Accepted { .. })),
        "submission unconfirmed or rejected; observe this run, never repeat submission"
    );
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3600);
    transport.observe_until(deadline);
    if service {
        parent.handoff()?;
        let manifest = Run::inspect(&run)?;
        let replies =
            crate::fleet::build_backend::agent::commands::observe_result(&run, deadline, || {
                controller::status(&manifest, &mut transport)
            })?;
        controller::require_successful_builds(&replies)?;
        anyhow::bail!(
            "owned CI parent settled; consumer handoff belongs to its controller service"
        );
    }
    let replies = crate::fleet::build_backend::agent::commands::observe_parent_result(
        &run,
        deadline,
        &mut parent,
        &mut transport,
    )?;
    // Execution settlement alone is never build/deployment success.
    controller::require_successful_builds(&replies)?;
    hand_off(parent, &mut transport, deadline, &lock)
}

/// Consumption, then (for Deploy) the ordinary deployment phases over the
/// retained results, then caller retirement. Reconnect resumes here without
/// copying or building again; a failed deployment keeps the run for retry.
pub fn hand_off(
    mut parent: Controller,
    transport: &mut impl Transport,
    deadline: std::time::Instant,
    lock: &super::deployment::ActionLock,
) -> Result<()> {
    let handed = consume(&mut parent, transport, deadline)?;
    println!(
        "{}",
        serde_json::json!({"run_id": parent.run_id(), "state": "consumed", "outputs": handed})
    );
    let nix = consumer_nix()?;
    let attempts = parent
        .run
        .manifest()
        .children
        .keys()
        .cloned()
        .collect::<Vec<_>>();
    for attempt in attempts {
        match parent
            .original_invocation(&attempt)
            .map(|invocation| invocation.action)
        {
            Ok(Action::Deploy) => super::deployment::deploy(&parent, &attempt, &nix, lock)?,
            Ok(Action::DevBuild) => {
                super::acquisition::development::publish(&mut parent, &attempt, &nix, deadline)?;
            }
            // Submitted intents (no captured invocation) are build-only.
            Ok(Action::Build) | Err(_) => {}
            Ok(_) => anyhow::bail!("owned attempt has no supported handoff"),
        }
    }
    let run = parent.run_id().to_owned();
    parent.run.retire()?;
    println!("{}", serde_json::json!({"run_id": run, "state": "retired"}));
    Ok(())
}

pub(super) fn consumer_nix() -> Result<PathBuf> {
    let qualify = || -> Result<PathBuf> {
        let nix = std::fs::canonicalize(
            crate::fleet::runtime::RuntimeConfig::from_environment().nix_program,
        )?;
        super::acquisition::native::preflight(&nix)?;
        Ok(nix)
    };
    qualify().context("agent strategy requires a compatible installed native consumer adapter")
}

/// Attempt → host → output name → consumer-rooted store path.
pub type ConsumedOutputs = BTreeMap<String, BTreeMap<String, BTreeMap<String, String>>>;

/// Successful-path consumer handoff for every attempt: retained artifact and
/// planning, signed acquisition, durable consumer roots, verified ACK, then
/// observed source-protection release. Reopening rechecks an unfinished shared-
/// store acquisition or re-sends its exact recorded statement; no copy replay.
pub fn consume(
    parent: &mut Controller,
    transport: &mut impl Transport,
    deadline: std::time::Instant,
) -> Result<ConsumedOutputs> {
    let nix = consumer_nix()?;
    parent.run.require_native_quiescence()?;
    parent.refresh_statuses(transport, deadline)?;
    parent.settle_captures(transport, deadline)?;
    parent.run.require_capture_success()?;
    let attempts = parent
        .run
        .manifest()
        .children
        .keys()
        .cloned()
        .collect::<Vec<_>>();
    let mut handed = BTreeMap::new();
    for attempt in &attempts {
        let delivery = parent.artifact(attempt, transport)?;
        let planning = parent.planning(attempt, transport)?;
        // Deployment also retains the exact evaluated source tree.
        let tree = planning.as_ref().is_some_and(|planning| {
            abird_host_agent::build_executor::preparation::worker::needs_activation(
                &planning.request,
            )
        });
        let inventory = match planning {
            Some(_) => Some(parent.restored_planning(attempt)?.inventory),
            None => None,
        };
        let options = parent.run.manifest().children[attempt]
            .pending_capture()
            .map(|pending| &pending.invocation.options);
        let source = acquisition_source(options, inventory.as_ref())?;
        if parent.run.consumer_ack(attempt).is_err() {
            super::acquisition::acquire(parent, attempt, &nix, &source, tree)?;
        }
        let roots = parent.consumer_roots(attempt)?;
        let shared = parent.shares_store(attempt)?;
        let (binding, store_id) =
            super::acquisition::consumer_binding(shared, &source, &nix, &roots, tree)?;
        parent.require_acquisition_binding(attempt, &binding, store_id)?;
        let input = super::acquisition::native::Input {
            program: &nix,
            source: &source,
            roots: &roots,
            tree,
            delivery: &delivery,
        };
        let cancellation = parent.cancellation_probe()?;
        let lock = parent.acquisition_lock()?;
        parent.begin_native_helper(attempt)?;
        let response = parent.acknowledge_consumer(attempt, transport, |ack| {
            if shared {
                super::acquisition::retained_shared(input, ack, &lock, deadline, || {
                    crate::fleet::signal::check_interrupted()?;
                    cancellation.check()
                })
            } else {
                super::acquisition::retained_remote(input, ack, &lock, deadline, || {
                    crate::fleet::signal::check_interrupted()?;
                    cancellation.check()
                })
            }
        })?;
        parent.native_helper_returned(attempt)?;
        ensure!(
            matches!(response.reply, Reply::ConsumerAcknowledged { .. }),
            "consumer acknowledgement unconfirmed; reconnect with `fleet owned consume`"
        );
        // Builder-side ACK-bound retirement releases source protection.
        while parent.source_release(attempt)?.is_none() {
            crate::fleet::signal::check_interrupted()?;
            ensure!(
                std::time::Instant::now() < deadline,
                "source-protection release not yet observed; reconnect to the same run"
            );
            parent.consumer_status(attempt, transport)?;
            if parent.source_release(attempt)?.is_none() {
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        }
        let hosts = delivery
            .prepared
            .targets
            .iter()
            .map(|target| {
                Ok((
                    target.target.host.clone(),
                    delivery.host_outputs(&target.target.host)?,
                ))
            })
            .collect::<Result<BTreeMap<_, _>>>()?;
        handed.insert(attempt.clone(), hosts);
    }
    Ok(handed)
}

/// The deployment's existing signed cache endpoint: explicit original option,
/// else the evaluated inventory's `nix` registry or build cache. Never the
/// builder's store socket and never a newly supplied reconnect option.
pub(crate) fn acquisition_source(
    options: Option<&crate::fleet::cli::Options>,
    inventory: Option<&crate::fleet::inventory::Inventory>,
) -> Result<String> {
    let url = options
        .and_then(|options| options.build_cache_url.clone())
        .or_else(|| {
            inventory.and_then(|inventory| {
                inventory
                    .config
                    .registries
                    .get("nix")
                    .map(|registry| registry.url.clone())
                    .or_else(|| {
                        inventory
                            .config
                            .build_cache
                            .as_ref()
                            .map(|cache| cache.url.clone())
                    })
            })
        })
        .context("no signed acquisition source; configure the deployment build cache")?;
    super::acquisition::signed_source(&url)?;
    Ok(url)
}

pub struct Controller {
    run: Run,
    initial_dispatch: bool,
}

impl Controller {
    pub fn open(run_id: &str) -> Result<Self> {
        Ok(Self {
            run: Run::open(run_id)?,
            initial_dispatch: false,
        })
    }
    pub fn run_id(&self) -> &str {
        &self.run.manifest().run_id
    }

    pub fn cancelled(&self) -> Result<bool> {
        self.run.cancelled()
    }

    pub(crate) fn cancellation_probe(&self) -> Result<super::run::CancellationProbe> {
        self.run.cancellation_probe()
    }

    pub(crate) fn acquisition_lock(&self) -> Result<std::fs::File> {
        self.run.acquisition_lock()
    }

    pub(crate) fn begin_import(&mut self, attempt: &str) -> Result<bool> {
        self.run.begin_import(attempt)
    }

    pub(crate) fn import_settled(&mut self, attempt: &str) -> Result<()> {
        self.run.import_settled(attempt)
    }

    pub(crate) fn begin_native_helper(&mut self, attempt: &str) -> Result<()> {
        self.run.begin_native_helper(attempt)
    }

    pub(crate) fn native_helper_returned(&mut self, attempt: &str) -> Result<()> {
        self.run.native_helper_returned(attempt)
    }

    pub(crate) fn require_import_reconciliation(&self, attempt: &str) -> Result<()> {
        self.run.require_import_reconciliation(attempt)
    }

    pub(crate) fn import_effects_reconciled(&mut self, attempt: &str) -> Result<()> {
        self.run.import_effects_reconciled(attempt)
    }

    pub(crate) fn prepare_import_reconciliation(&mut self, attempt: &str) -> Result<bool> {
        self.run.prepare_import_reconciliation(attempt)
    }

    /// Unknown import effects veto abandonment; caller exit is not settlement.
    pub fn import_pending(&self, attempt: &str) -> Result<bool> {
        self.run.import_pending(attempt)
    }

    pub fn shares_store(&self, attempt: &str) -> Result<bool> {
        Ok(self
            .run
            .manifest()
            .children
            .get(attempt)
            .context("unknown consumer attempt")?
            .target
            .local)
    }

    /// Explicit caller retirement, including cancelled/expired unacknowledged
    /// import-settled abandonment. Never a builder release; see `Run::retire`.
    pub fn retire(self) -> Result<()> {
        self.run.retire()
    }

    /// Refresh each child's durable status by observation only, under the
    /// same exclusion and observation deadline as handoff cleanup.
    fn refresh_statuses(
        &mut self,
        transport: &mut impl Transport,
        deadline: std::time::Instant,
    ) -> Result<()> {
        let attempts = self
            .run
            .manifest()
            .children
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        for attempt in attempts {
            crate::fleet::signal::check_interrupted()?;
            ensure!(
                std::time::Instant::now() < deadline,
                "retirement observation deadline expired"
            );
            let child = &self.run.manifest().children[&attempt];
            let request = child.status_request()?;
            let response = transport.request(&child.target, &request)?;
            response.validate_for(&request)?;
            if matches!(response.reply, Reply::Status { .. }) {
                self.run.observe(&attempt, response)?;
            }
        }
        Ok(())
    }

    pub fn artifact(
        &mut self,
        attempt: &str,
        transport: &mut impl Transport,
    ) -> Result<abird_host_agent::build_executor::ArtifactDelivery> {
        ensure!(!self.run.cancelled()?, "durable parent is cancelling");
        if let Some(retained) = self.run.retained_artifact(attempt)? {
            return Ok(retained);
        }
        let delivery = controller::artifact(self.run.manifest(), attempt, transport)?;
        self.run.retain_artifact(attempt, &delivery)?;
        Ok(delivery)
    }

    /// Retain evaluated private metadata; never reevaluate the source to recover it.
    pub fn planning(
        &mut self,
        attempt: &str,
        transport: &mut impl Transport,
    ) -> Result<Option<abird_host_agent::build_executor::preparation::worker::Planning>> {
        self.run.planning(attempt, transport)
    }

    /// Restore original evaluated inputs, not source access or phase authority.
    pub fn restored_planning(
        &self,
        attempt: &str,
    ) -> Result<crate::fleet::preparation::bound::Restored> {
        use crate::fleet::preparation::bound::{BoundPreparation, RetainedTrees};
        ensure!(!self.run.cancelled()?, "durable parent is cancelling");
        let delivery = self
            .run
            .retained_artifact(attempt)?
            .context("artifact not retained")?;
        let planning = self
            .run
            .retained_planning(attempt)?
            .context("planning not retained")?;
        let bound = BoundPreparation::new(
            planning.request.clone(),
            RetainedTrees {
                source: delivery.prepared.source_path.clone(),
                snapshots: delivery.prepared.context_sources.clone(),
            },
        )?;
        bound.restore_planning(&planning, &delivery.prepared)
    }

    pub fn claim_acquisition(
        &mut self,
        attempt: &str,
        binding_digest: &str,
        store_id: &str,
    ) -> Result<(
        abird_host_agent::build_executor::ArtifactDelivery,
        std::time::Instant,
    )> {
        self.run
            .claim_acquisition(attempt, binding_digest, store_id)
    }

    /// Claim once, or reconcile the same unfinished binding under run exclusion.
    /// A future signed `nix copy --from` may idempotently import the identical
    /// immutable output set into the identical store within this cutoff, then
    /// fully reverify/root/ACK. No changed destination or realization replay.
    /// Remote abandonment additionally needs original import-producer settlement.
    pub fn reconcile_acquisition(
        &mut self,
        attempt: &str,
        binding_digest: &str,
        store_id: &str,
    ) -> Result<(
        abird_host_agent::build_executor::ArtifactDelivery,
        std::time::Instant,
    )> {
        self.run
            .reconcile_acquisition(attempt, binding_digest, store_id)
    }

    pub fn require_acquisition_binding(
        &self,
        attempt: &str,
        binding_digest: &str,
        store_id: &str,
    ) -> Result<()> {
        self.run
            .require_acquisition_binding(attempt, binding_digest, store_id)
    }

    /// Direct GC-root directory under the caller's provisioned gcroots base.
    pub fn consumer_roots(&self, attempt: &str) -> Result<PathBuf> {
        ensure!(
            self.run.manifest().children.contains_key(attempt),
            "unknown consumer attempt"
        );
        Ok(super::acquisition::run_roots(self.run_id())?.join(attempt))
    }

    /// The builder recorded in the original request (inventory host name).
    pub fn builder(
        &self,
        attempt: &str,
    ) -> Result<&abird_host_agent::build_executor::request::Peer> {
        Ok(self
            .run
            .manifest()
            .children
            .get(attempt)
            .context("unknown builder attempt")?
            .request
            .builder())
    }

    /// The authenticated controller identity recorded in the original request.
    pub fn consumer(
        &self,
        attempt: &str,
    ) -> Result<&abird_host_agent::build_executor::request::Peer> {
        Ok(self
            .run
            .manifest()
            .children
            .get(attempt)
            .context("unknown consumer attempt")?
            .request
            .controller())
    }

    /// The caller's original invocation, captured before admission.
    pub fn original_invocation(&self, attempt: &str) -> Result<Invocation> {
        Ok(self
            .run
            .manifest()
            .children
            .get(attempt)
            .and_then(|child| child.pending_capture())
            .context("original caller invocation not retained")?
            .invocation
            .clone())
    }

    pub(crate) fn recorded_consumer(
        &self,
        attempt: &str,
    ) -> Result<&abird_host_agent::build_executor::ConsumerAck> {
        self.run.consumer_ack(attempt)
    }

    pub(crate) fn retained_acquisition_source(&self, attempt: &str) -> Result<String> {
        self.run.require_retained_planning(attempt)?;
        let inventory = self
            .run
            .retained_planning(attempt)?
            .map(|planning| serde_json::from_value(planning.inventory))
            .transpose()?;
        let options = self.run.manifest().children[attempt]
            .pending_capture()
            .map(|pending| &pending.invocation.options);
        acquisition_source(options, inventory.as_ref())
    }

    /// Original retained artifact only; never fetched again here.
    pub fn retained(
        &self,
        attempt: &str,
    ) -> Result<abird_host_agent::build_executor::ArtifactDelivery> {
        self.run
            .retained_artifact(attempt)?
            .context("artifact not retained")
    }

    /// Source protection release only; target authorization and consumer root
    /// validity must still be checked independently at deployment handoff.
    pub fn source_release(&self, attempt: &str) -> Result<Option<&str>> {
        self.run.source_release(attempt)
    }

    /// Called by the fixed acquisition adapter, never from a delivery/status
    /// success. This persists the verified consumer statement before sending it.
    pub fn record_consumption(
        &mut self,
        attempt: &str,
        receipt: abird_host_agent::build_executor::ConsumerAck,
    ) -> Result<()> {
        self.run.record_consumption(attempt, receipt)
    }

    /// Exact ACK retries are metadata-only. The acquisition adapter must recheck
    /// its original retained roots/binding before each send, including reconnect.
    pub fn acknowledge_consumer(
        &mut self,
        attempt: &str,
        transport: &mut impl Transport,
        retained: impl FnMut(&abird_host_agent::build_executor::ConsumerAck) -> Result<()>,
    ) -> Result<Response> {
        self.send_recorded_ack(attempt, transport, retained, false)
    }

    fn send_recorded_ack(
        &mut self,
        attempt: &str,
        transport: &mut impl Transport,
        mut retained: impl FnMut(&abird_host_agent::build_executor::ConsumerAck) -> Result<()>,
        allow_cancelled: bool,
    ) -> Result<Response> {
        ensure!(
            allow_cancelled || !self.run.cancelled()?,
            "durable parent is cancelling"
        );
        let receipt = self.run.consumer_ack(attempt)?.clone();
        self.run.require_retained_planning(attempt)?;
        self.run
            .retained_artifact(attempt)?
            .context("consumer artifact missing")?;
        retained(&receipt)?;
        ensure!(
            allow_cancelled || !self.run.cancelled()?,
            "durable parent is cancelling"
        );
        let request = Request {
            version: protocol::VERSION,
            command: protocol::Command::AcknowledgeConsumer {
                receipt: Box::new(receipt),
            },
        };
        let child = &self.run.manifest().children[attempt];
        let response = transport.request(&child.target, &request)?;
        self.run.observe_consumer(attempt, &request, &response)?;
        Ok(response)
    }

    pub fn consumer_status(
        &mut self,
        attempt: &str,
        transport: &mut impl Transport,
    ) -> Result<Response> {
        self.run.consumer_ack(attempt)?;
        let request = Request {
            version: protocol::VERSION,
            command: protocol::Command::ConsumerStatus {
                attempt_id: attempt.to_owned(),
            },
        };
        let child = &self.run.manifest().children[attempt];
        let response = transport.request(&child.target, &request)?;
        self.run.observe_consumer(attempt, &request, &response)?;
        Ok(response)
    }
    /// Revokes consumption before send. Neither this reply nor helper exit is
    /// builder root release; poll the distinct abandonment status afterwards.
    pub fn abandon_consumer(
        &mut self,
        attempt: &str,
        transport: &mut impl Transport,
    ) -> Result<Response> {
        let abandonment = self.run.claim_abandonment(attempt)?;
        let request = Request {
            version: protocol::VERSION,
            command: protocol::Command::AbandonConsumer {
                abandonment: Box::new(abandonment),
            },
        };
        let child = &self.run.manifest().children[attempt];
        let response = transport.request(&child.target, &request)?;
        self.run.observe_abandonment(attempt, &request, &response)?;
        Ok(response)
    }

    pub fn abandonment_status(
        &mut self,
        attempt: &str,
        transport: &mut impl Transport,
    ) -> Result<Response> {
        self.run.abandonment(attempt)?;
        let request = Request {
            version: protocol::VERSION,
            command: protocol::Command::ConsumerAbandonmentStatus {
                attempt_id: attempt.to_owned(),
            },
        };
        let child = &self.run.manifest().children[attempt];
        let response = transport.request(&child.target, &request)?;
        self.run.observe_abandonment(attempt, &request, &response)?;
        Ok(response)
    }

    pub fn abandonment_release(&self, attempt: &str) -> Result<Option<&str>> {
        self.run.abandonment_release(attempt)
    }

    /// Bounded explicit cleanup, not a new lease. The installed transport must
    /// share this same observation deadline. NotFound is never release evidence.
    pub fn retire_observed(
        mut self,
        transport: &mut impl Transport,
        deadline: std::time::Instant,
    ) -> Result<()> {
        self.run.require_native_quiescence()?;
        self.refresh_statuses(transport, deadline)?;
        self.settle_captures(transport, deadline)?;
        let attempts = self
            .run
            .manifest()
            .children
            .iter()
            .filter(|(_, child)| {
                matches!(
                    child.outcome(),
                    Some(abird_host_agent::build_executor::Outcome::Succeeded { .. })
                )
            })
            .map(|(attempt, _)| attempt.clone())
            .collect::<Vec<_>>();
        for attempt in &attempts {
            if self.import_pending(attempt)? {
                let tree = self
                    .run
                    .retained_planning(attempt)?
                    .as_ref()
                    .is_some_and(|planning| {
                        abird_host_agent::build_executor::preparation::worker::needs_activation(
                            &planning.request,
                        )
                    });
                super::acquisition::reconcile_pending(
                    &mut self,
                    attempt,
                    &consumer_nix()?,
                    tree,
                    deadline,
                )?;
            }
        }
        for attempt in attempts {
            let acknowledged = self.run.consumer_ack(&attempt).is_ok();
            while !self.run.handoff_retired(&attempt)? {
                crate::fleet::signal::check_interrupted()?;
                ensure!(
                    std::time::Instant::now() < deadline,
                    "builder cleanup unconfirmed; reconnect to this same run"
                );
                let response = if acknowledged {
                    self.consumer_status(&attempt, transport)?
                } else if self.run.abandonment(&attempt).is_ok() {
                    self.abandonment_status(&attempt, transport)?
                } else {
                    self.abandon_consumer(&attempt, transport)?
                };
                match response.reply {
                    Reply::ConsumerStatus { state: None, .. } if acknowledged => {
                        let response = self.retry_recorded_ack(&attempt, transport, deadline)?;
                        ensure!(
                            matches!(response.reply, Reply::ConsumerAcknowledged { .. }),
                            "original consumer ACK remains unconfirmed"
                        );
                    }
                    Reply::ConsumerAbandonmentStatus { state: None, .. } if !acknowledged => {
                        let response = self.abandon_consumer(&attempt, transport)?;
                        ensure!(
                            matches!(response.reply, Reply::ConsumerAbandoned { .. }),
                            "original abandonment remains unconfirmed"
                        );
                    }
                    Reply::ConsumerStatus { state: Some(_), .. }
                    | Reply::ConsumerAbandonmentStatus { state: Some(_), .. }
                    | Reply::ConsumerAbandoned { .. }
                    | Reply::Unconfirmed { .. } => {}
                    _ => anyhow::bail!(
                        "builder cleanup rejected or unavailable; preserve this run, never infer NotFound success"
                    ),
                }
                if !self.run.handoff_retired(&attempt)? {
                    std::thread::sleep(
                        std::time::Duration::from_millis(250)
                            .min(deadline.saturating_duration_since(std::time::Instant::now())),
                    );
                }
            }
        }
        self.run.retire()
    }

    /// Reconcile a real persisted ACK race, even after cancellation. This path
    /// can only verify the original protection and resend the exact statement;
    /// it cannot import, repair roots, issue a replacement ACK or activate.
    fn retry_recorded_ack(
        &mut self,
        attempt: &str,
        transport: &mut impl Transport,
        deadline: std::time::Instant,
    ) -> Result<Response> {
        self.run.consumer_ack(attempt)?;
        let delivery = self.retained(attempt)?;
        let planning = self.run.retained_planning(attempt)?;
        let tree = planning.as_ref().is_some_and(|planning| {
            abird_host_agent::build_executor::preparation::worker::needs_activation(
                &planning.request,
            )
        });
        let inventory = planning
            .map(|planning| serde_json::from_value(planning.inventory))
            .transpose()?;
        let options = self.run.manifest().children[attempt]
            .pending_capture()
            .map(|pending| &pending.invocation.options);
        let source = acquisition_source(options, inventory.as_ref())?;
        let nix = consumer_nix()?;
        let roots = self.consumer_roots(attempt)?;
        let shared = self.shares_store(attempt)?;
        let (binding, store_id) =
            super::acquisition::consumer_binding(shared, &source, &nix, &roots, tree)?;
        self.require_acquisition_binding(attempt, &binding, store_id)?;
        let input = super::acquisition::native::Input {
            program: &nix,
            source: &source,
            roots: &roots,
            tree,
            delivery: &delivery,
        };
        let lock = self.acquisition_lock()?;
        self.begin_native_helper(attempt)?;
        let response = self.send_recorded_ack(
            attempt,
            transport,
            |ack| {
                crate::fleet::signal::check_interrupted()?;
                if shared {
                    super::acquisition::retained_shared(
                        input,
                        ack,
                        &lock,
                        deadline,
                        crate::fleet::signal::check_interrupted,
                    )
                } else {
                    super::acquisition::retained_remote(
                        input,
                        ack,
                        &lock,
                        deadline,
                        crate::fleet::signal::check_interrupted,
                    )
                }
            },
            true,
        )?;
        self.native_helper_returned(attempt)?;
        Ok(response)
    }

    pub fn submit(&mut self, transport: &mut impl Transport) -> Result<BTreeMap<String, Response>> {
        ensure!(
            self.initial_dispatch,
            "reopened or dispatched native parent is observation-only"
        );
        self.initial_dispatch = false;
        controller::submit(&mut self.run, transport)
    }
    pub fn poll(&mut self, transport: &mut impl Transport) -> Result<BTreeMap<String, Response>> {
        controller::poll(&mut self.run, transport, |_| Ok(None))
    }

    pub(super) fn captures_settled(&self) -> bool {
        self.run.captures_settled()
    }

    fn settle_captures(
        &mut self,
        transport: &mut impl Transport,
        deadline: std::time::Instant,
    ) -> Result<()> {
        while self.run.require_capture_retirement().is_err() {
            crate::fleet::signal::check_interrupted()?;
            ensure!(
                std::time::Instant::now() < deadline,
                "source cleanup unconfirmed; reconnect to the original run"
            );
            self.run.poll_captures(transport)?;
            if self.run.require_capture_retirement().is_err() {
                std::thread::park_timeout(
                    std::time::Duration::from_millis(250)
                        .min(deadline.saturating_duration_since(std::time::Instant::now())),
                );
            }
        }
        Ok(())
    }

    /// Release only this process's writer. Not a service-start/settlement ACK.
    pub fn handoff(self) -> Result<String> {
        ensure!(
            self.run.manifest().service_owned()
                && self
                    .run
                    .manifest()
                    .children
                    .values()
                    .all(|child| child.submitted()),
            "native parent was not dispatched for CI ownership"
        );
        Ok(self.run_id().to_owned())
    }

    pub fn claim_capture(
        &mut self,
        attempt: &str,
        transport: &mut impl Transport,
    ) -> Result<CaptureClaim> {
        let child = self
            .run
            .manifest()
            .children
            .get(attempt)
            .context("unknown native capture child")?;
        let response = transport.request(&child.target, &child.status_request()?)?;
        self.run.claim_capture(attempt, response)
    }

    pub fn retain_capture(&mut self, claim: &CaptureClaim, submission: Submission) -> Result<()> {
        ensure!(
            submission.record.caller == claim.pending.invocation,
            "native capture changed private caller options"
        );
        let attempt = claim.request.attempt_id()?;
        let material = submission.resolve(&claim.request)?;
        self.run
            .retain_capture(&attempt, &serde_json::to_vec(&material)?)
    }
}

fn action(action: &Action) -> Result<BuildAction> {
    Ok(match action {
        Action::Run => BuildAction::Run,
        Action::Deploy => BuildAction::Deploy,
        Action::Build => BuildAction::Build,
        Action::DevBuild => BuildAction::DevBuild,
        _ => anyhow::bail!("owned request requires a native build action"),
    })
}

fn selection(invocation: &Invocation) -> Selection {
    let options = &invocation.options;
    Selection::Fleet {
        groups: options.groups.clone(),
        host: options.host.clone(),
        hosts: options.hosts.clone(),
        nix_config: options.nix_config.clone(),
        control_plane_first: options.control_plane_first,
    }
}

fn normalized(path: &Path) -> Result<()> {
    ensure!(
        path.is_absolute()
            && path.to_str().is_some()
            && path
                .components()
                .all(|part| matches!(part, Component::RootDir | Component::Normal(_))),
        "native context path is not canonical absolute UTF-8"
    );
    Ok(())
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(char::from(DIGITS[usize::from(byte >> 4)]));
        encoded.push(char::from(DIGITS[usize::from(byte & 15)]));
    }
    encoded
}

#[cfg(test)]
mod tests;
