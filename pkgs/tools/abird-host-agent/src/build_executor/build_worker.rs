//! Installed Build worker lifetime. Source preparation plugs into this same
//! claim/guard/deadline; it does not create a second scheduler or realization.
//! A verifier receipt precedes exit, never descendant settlement or release.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

pub(in crate::build_executor) mod caller_view;
mod capture;
mod ingress;
mod input;
mod source;

use super::artifacts;
use super::daemon;
use super::journal::Journal;
use super::launch_gate::Gate;
use super::preparation::{Preparation, PreparedInputs};
use super::process::{Limits, Runner};
use super::protection::NativeRoots;
use super::request::BuildRequest;
use super::stage::{Stage, Step};
use super::store_interlock::{BuildGuard, StoreInterlock};
use super::{ExecutionHandle, Outcome, role, workload};

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub uid: u32,
    pub gid: u32,
    pub git_configuration: PathBuf,
    pub git_program: PathBuf,
    pub source_uid: u32,
    pub source_user: String,
    pub source_limits: super::private_tree::Limits,
    pub repositories: std::collections::BTreeMap<String, String>,
}

impl Policy {
    pub(super) fn validate(&self) -> Result<()> {
        ensure!(
            self.uid > 0 && self.uid < u32::MAX && self.gid > 0 && self.gid < u32::MAX,
            "invalid installed build credentials"
        );
        ensure!(
            self.source_uid > 0 && self.source_uid < u32::MAX && self.source_uid != self.uid,
            "source producer must have distinct credentials"
        );
        daemon::validate_source_account(self.source_uid, &self.source_user)?;
        self.source_limits.validate()?;
        daemon::store_path(&self.git_program)?;
        ensure!(
            self.git_program
                .file_name()
                .is_some_and(|name| name == "git"),
            "unexpected source executable"
        );
        ensure!(
            !self.repositories.is_empty() && self.repositories.len() <= 64,
            "invalid installed repository set"
        );
        for (name, url) in &self.repositories {
            super::identifier(name)?;
            super::preparation::source::repository_url(url)?;
        }
        daemon::store_path(&self.git_configuration)?;
        Ok(())
    }
}

pub(super) struct Session<'a> {
    journal: &'a Journal,
    gate: &'a Gate,
    native: &'a daemon::Policy,
    role: &'a role::Policy,
    policy: &'a Policy,
    handle: ExecutionHandle,
    intent: super::journal::work::Work,
    request: Option<BuildRequest>,
    native_capture: Option<super::native_intent::Validation>,
    deadline: Instant,
    store: BuildGuard<'a>,
    roots: NativeRoots,
    runner: Runner,
    prepared: Option<Preparation>,
    preparation_claimed: bool,
    evaluation_claimed: bool,
    source_claimed: bool,
    cache: Option<PathBuf>,
    native_context: Option<source::NativeContext>,
    source_slot: Option<super::private_sources::SourceSlot>,
    repository_production: Option<source::Production>,
    source_delivery_claimed: bool,
    source_context: Option<artifacts::SourceContext>,
    source_observation: Option<String>,
    poisoned: bool,
}

impl<'a> Session<'a> {
    pub(super) fn start(
        journal: &'a Journal,
        gate: &'a Gate,
        native: &'a daemon::Policy,
        role: &'a role::Policy,
        store: &'a StoreInterlock,
        attempt_id: &str,
    ) -> Result<Self> {
        let policy = &role.build;
        policy.validate()?;
        daemon::executable(&role.manager_program)?;
        daemon::executable(&policy.git_program)?;
        native.require_executor(policy)?;
        daemon::trusted_path(&native.evaluation_library)?;
        ensure!(
            native.evaluation_library
                == role.manager_program.with_file_name("libabird-owned-nix.so"),
            "native adapter is outside the manager package"
        );
        daemon::trusted_path(&policy.git_configuration)?;
        let git_configuration = std::fs::canonicalize(&policy.git_configuration)?;
        daemon::store_path(&git_configuration)?;
        daemon::trusted_path(&git_configuration)?;
        ensure!(
            git_configuration.is_file(),
            "installed Git context unavailable"
        );
        ensure!(
            native.containment_digest == role.digest()?,
            "build role binding differs"
        );
        let monotonic = Instant::now();
        let wall = SystemTime::now().duration_since(UNIX_EPOCH)?;
        let owner = journal.pool()?.owner.context("build owner missing")?;
        ensure!(owner.attempt_id == attempt_id, "build instance differs");
        let (intent, reserved_at) = journal.build_worker_input(&owner, daemon::now()?)?;
        ensure!(
            policy.repositories.contains_key(intent.repository_id()?),
            "repository is not installed"
        );
        let request = match &intent {
            super::journal::work::Work::Build(request) => Some((**request).clone()),
            _ => None,
        };
        workload::require_client_placement(&owner)?;
        let handle = ExecutionHandle {
            ownership: owner,
            invocation_id: std::env::var("INVOCATION_ID")
                .map_err(|_| anyhow::anyhow!("build invocation unavailable"))?,
        };
        handle.validate(attempt_id)?;
        let deadline = super::process::cutoff(
            Some(reserved_at),
            intent.deadlines().runtime_seconds,
            wall,
            monotonic,
        )?;
        let guard = loop {
            ensure!(Instant::now() < deadline, "build deadline expired");
            if let Some(guard) = store.try_build(journal, &handle.ownership, daemon::now()?)? {
                break guard;
            }
            std::thread::park_timeout(Duration::from_millis(10));
        };
        super::native_phase::begin_worker(journal, gate, handle.clone(), daemon::now()?)?;
        daemon::verify_source_account(policy.source_uid, &policy.source_user)?;
        ensure!(
            Instant::now() < deadline,
            "source account lookup exceeded original deadline"
        );
        journal.source_active(&handle.ownership, daemon::now()?)?;
        let roots = NativeRoots::initialize(journal, gate, handle.ownership.clone())?;
        let runner = Runner::new(
            policy.uid,
            Limits {
                stdin: 16 * 1024 * 1024,
                stdout: artifacts::MAX_BYTES,
                stderr: 128 * 1024,
            },
            deadline,
        )?;
        Ok(Self {
            journal,
            gate,
            native,
            role,
            policy,
            handle,
            intent,
            request,
            native_capture: None,
            deadline,
            store: guard,
            roots,
            runner,
            prepared: None,
            preparation_claimed: false,
            evaluation_claimed: false,
            source_claimed: false,
            cache: None,
            native_context: None,
            source_slot: None,
            repository_production: None,
            source_delivery_claimed: false,
            source_context: None,
            source_observation: None,
            poisoned: false,
        })
    }

    pub(super) fn execute(mut self, config: &super::control::Config) -> Result<()> {
        let journal = self.journal;
        let handle = self.handle.clone();
        journal.diagnose(&handle, super::diagnostics::Activity::Worker, || {
            let material =
                journal.diagnose(&handle, super::diagnostics::Activity::Receive, || {
                    self.receive(config)
                })?;
            self.materialize(material)?;
            self.finish()
        })
    }

    fn active(&self) -> Result<()> {
        ensure!(!self.poisoned, "build worker unresolved");
        ensure!(Instant::now() < self.deadline, "build deadline expired");
        super::store_binding::validate(self.journal.authority_root(), self.journal.identity())?;
        self.store.validate(self.journal, daemon::now()?)?;
        self.journal
            .source_active(&self.handle.ownership, daemon::now()?)
    }

    /// Source adapter supplies the fresh, sealed native Git view. Every hash,
    /// shared-engine evaluation and producer settlement remains under this
    /// worker's original admission/guard/deadline, not a helper-created lifetime.
    pub(super) fn evaluate(&mut self, mut input: super::preparation::worker::Input) -> Result<()> {
        self.active()?;
        ensure!(
            !self.evaluation_claimed,
            "native preparation already dispatched"
        );
        self.evaluation_claimed = true;
        let request = self.request.clone().context("native input is unresolved")?;
        let result = (|| {
            input.validate()?;
            ensure!(
                input.request == request && input.native_system == self.native.system,
                "native preparation intent/system differs"
            );
            let mut sources = std::collections::BTreeMap::from([(
                input.source.path.clone(),
                input.source.nar_digest.clone(),
            )]);
            for (hash, path) in &input.snapshots {
                if let Some(old) = sources.insert(path.clone(), hash.clone()) {
                    ensure!(old == *hash, "input source hashes disagree");
                }
            }
            let roots = self.roots.retain(
                self.journal,
                self.gate,
                &sources.keys().cloned().collect::<Vec<_>>(),
            )?;
            for (ordinal, (path, hash)) in sources.iter().enumerate() {
                let mut command = self.native.native_hash(path)?;
                let mut stage = Stage::input(&self.handle.ownership, u16::try_from(ordinal)?)?;
                let observed = self.run(&mut command, &mut stage)?;
                let observed = std::str::from_utf8(&observed)
                    .context("invalid source hash encoding")?
                    .trim_end_matches('\n');
                ensure!(observed == hash, "input NAR differs");
            }
            for root in input.native_roots.values() {
                self.roots.retain(
                    self.journal,
                    self.gate,
                    std::slice::from_ref(&root.source.path),
                )?;
                let mut command = self.native.native_hash(&root.source.path)?;
                let mut stage = Stage::input(&self.handle.ownership, 16)?;
                let observed = self.run(&mut command, &mut stage)?;
                ensure!(
                    std::str::from_utf8(&observed)?.trim_end_matches('\n')
                        == root.source.nar_digest,
                    "native context NAR differs"
                );
            }
            input.protection_digest = if input.native_roots.is_empty() {
                roots.digest()?
            } else {
                self.roots.verify(self.journal)?.digest()?
            };
            input.budget_millis = u64::try_from(
                self.deadline
                    .saturating_duration_since(Instant::now())
                    .as_millis(),
            )?;
            input.validate()?;
            let bytes = serde_json::to_vec(&input)?;
            let mut command = self.role.manager(role::ManagerCommand::Prepare);
            command
                .arg(self.native.program.with_file_name("nix"))
                .arg(&self.native.evaluation_library)
                .current_dir("/var/empty")
                .env_clear()
                .env("HOME", "/var/empty")
                .env("LC_ALL", "C")
                .env("PATH", &self.native.search_path)
                .env("NIX_CONF_DIR", &self.native.configuration_directory)
                .env(
                    "NIX_CONFIG",
                    super::preparation::worker::evaluation_configuration(&input.native_system)?,
                )
                .env("NIX_SSL_CERT_FILE", &self.native.certificate_bundle)
                .env("GIT_CONFIG_GLOBAL", &self.policy.git_configuration)
                .env("GIT_CONFIG_NOSYSTEM", "1");
            self.git_context(&mut command)?;
            let mut stage = Stage::create(&self.handle.ownership, Step::Prepare)?;
            self.active()?;
            self.native.require_socket()?;
            super::native_phase::Gate::open(self.journal, self.handle.ownership.clone())?
                .authorize_command(self.journal, false)?;
            let view = self.native_view()?;
            let result = self.journal.diagnose(&self.handle, stage.activity(), || {
                let result = if let Some(view) = view {
                    self.runner.run_as_native_view(
                        &mut command,
                        &bytes,
                        self.policy.gid,
                        &[],
                        view,
                        &mut stage,
                    )?
                } else {
                    self.runner
                        .run_as(&mut command, &bytes, self.policy.gid, &mut stage)?
                };
                ensure!(
                    result.status.success(),
                    "{}",
                    super::preparation::worker::failure_diagnostic(&result.stderr)
                        .unwrap_or("native preparation failed")
                );
                Ok(result)
            })?;
            self.active()?;
            // The original preparation subgroup is positively empty before
            // consuming its complete result. Never reconstruct/replay queries.
            let output = super::preparation::worker::Output::decode(&result.stdout, &input)?;
            self.source_context = Some(artifacts::SourceContext {
                input,
                consumed: output.consumed,
                planning: output.planning,
                observation: self
                    .source_observation
                    .take()
                    .context("settled source observation missing")?,
                native_capture: self.native_capture.clone(),
            });
            self.prepared(output.prepared)
        })();
        if result.is_err() {
            self.poisoned = true;
        }
        result
    }

    /// Trusted source adapter calls only after its producer settlement, fresh
    /// private snapshot and native-context/source verification. No wire caller.
    /// Root each input/derivation before recording the exact shared-plan result.
    pub(super) fn prepared(&mut self, mut inputs: PreparedInputs) -> Result<()> {
        self.active()?;
        ensure!(
            !self.preparation_claimed,
            "build preparation already consumed"
        );
        self.preparation_claimed = true;
        let request = self.request.clone().context("native input is unresolved")?;
        inputs.validate(&request)?;
        let mut paths = BTreeSet::from([inputs.source_path.clone()]);
        paths.extend(inputs.context_sources.values().cloned());
        paths.extend(
            inputs
                .targets
                .iter()
                .map(|target| target.derivation.clone()),
        );
        let roots = self.roots.retain(
            self.journal,
            self.gate,
            &paths.into_iter().collect::<Vec<_>>(),
        )?;
        inputs.protection_digest = roots.digest()?;
        let prepared = Preparation::new(inputs, &request)?;
        ensure!(
            self.journal.record_prepared(
                &self.handle.ownership,
                prepared.inputs.clone(),
                daemon::now()?
            )? == prepared.digest,
            "persisted preparation differs"
        );
        self.prepared = Some(prepared);
        Ok(())
    }

    fn native_view(&mut self) -> Result<Option<caller_view::View>> {
        let Some(context) = &mut self.native_context else {
            return Ok(None);
        };
        Ok(Some(context.view(
            self.cache.as_deref().context("native cache missing")?,
            self.deadline,
        )?))
    }

    fn run(&mut self, command: &mut Command, stage: &mut Stage) -> Result<Vec<u8>> {
        let result = (|| {
            self.active()?;
            self.git_context(command)?;
            self.native.require_socket()?;
            super::native_phase::Gate::open(self.journal, self.handle.ownership.clone())?
                .authorize_command(self.journal, stage.verification_only())?;
            let activity = stage.activity();
            let mut view = self.native_view()?;
            let mut operation = || {
                let result = if let Some(view) = view.take() {
                    self.runner.run_as_native_view(
                        command,
                        &[],
                        self.policy.gid,
                        &[],
                        view,
                        stage,
                    )?
                } else {
                    self.runner.run_as(command, &[], self.policy.gid, stage)?
                };
                // Never repeat an RPC/build to recover an observation or log.
                ensure!(result.status.success(), "native build-stage command failed");
                Ok(result)
            };
            // Verification has one outer diagnostic, not two journal fsyncs for
            // each of up to 1028 read-only native queries.
            let result = if activity == super::diagnostics::Activity::Verify {
                operation()?
            } else {
                self.journal.diagnose(&self.handle, activity, operation)?
            };
            self.active()?;
            Ok(result.stdout)
        })();
        if result.is_err() {
            self.poisoned = true;
        }
        result
    }

    /// Consuming self prevents a second realization in this process. The durable
    /// worker claim independently prevents process/service restart from replaying.
    pub(super) fn finish(mut self) -> Result<()> {
        self.active()?;
        let request = self.request.clone().context("native input is unresolved")?;
        let prepared = self.prepared.take().context("build preparation missing")?;
        let inputs = artifacts::installables(&prepared);
        let built = if inputs.is_empty() {
            Vec::new()
        } else {
            let mut command = self.native.native_client()?;
            command
                .args(["build", "--no-link", "--json", "--max-jobs"])
                .arg(request.nix.max_jobs.to_string())
                .arg("--cores")
                .arg(request.nix.cores.to_string())
                .args([
                    "--option",
                    "substitute",
                    if request.nix.substitute {
                        "true"
                    } else {
                        "false"
                    },
                    "--",
                ])
                .args(inputs);
            let mut stage = Stage::create(&self.handle.ownership, Step::Realize)?;
            artifacts::decode_built(&self.run(&mut command, &mut stage)?, &prepared)?
        };
        self.active()?;
        self.roots
            .retain(self.journal, self.gate, &artifacts::outputs(&built))?;
        let phase = super::native_phase::Gate::open(self.journal, self.handle.ownership.clone())?;
        let mut units =
            super::units::Units::new(self.role.systemctl.clone(), Duration::from_secs(2))?
                .with_deadline(self.deadline);
        self.journal.diagnose(
            &self.handle,
            super::diagnostics::Activity::NativeSeal,
            || {
                phase.seal_and_settle(
                    self.journal,
                    &mut units,
                    &self.role.definitions["nix-daemon.service"],
                    &self.native.program,
                    self.deadline,
                )
            },
        )?;
        let native = self
            .journal
            .claimed_daemon(&self.handle.ownership)?
            .context("build native claim missing")?;
        let mut ordinal = 0u16;
        // Clone small immutable context to keep the credentialed runner as the
        // sole mutable callback. No subprocess gets journal/root descriptors.
        let handle = self.handle.clone();
        let policy = self.native;
        let context = self
            .source_context
            .clone()
            .context("native source context missing")?;
        let journal = self.journal;
        let manifest = journal.diagnose(&handle, super::diagnostics::Activity::Verify, || {
            artifacts::verify(
                policy,
                &request,
                &prepared,
                &handle,
                artifacts::Unverified {
                    native,
                    built,
                    source_context: context,
                },
                |command| {
                    let mut stage = Stage::verification(&handle.ownership, ordinal)?;
                    ordinal = ordinal
                        .checked_add(1)
                        .context("verification command overflow")?;
                    self.run(command, &mut stage)
                },
            )
        })?;
        self.active()?;
        let roots_digest = self.roots.verify(self.journal)?.digest()?;
        let artifacts =
            self.journal
                .diagnose(&handle, super::diagnostics::Activity::Publish, || {
                    let receipt = artifacts::publish(
                        self.journal,
                        &handle.ownership,
                        &manifest,
                        &prepared,
                        &roots_digest,
                    )?;
                    // Reopen the durable exact inode/checksum, not merely successful IO.
                    artifacts::read(self.journal, &handle.ownership)?;
                    Ok(receipt)
                })?;
        ensure!(
            self.roots.verify(self.journal)?.digest()? == roots_digest,
            "artifact roots changed during publication"
        );
        self.active()?;
        self.journal
            .record_verified(&handle, Outcome::Succeeded { artifacts }, daemon::now()?)
    }
}
