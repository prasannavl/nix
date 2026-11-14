//! Installed metadata before Git/Nix/workspace effects. This catalog bootstraps
//! one builder/control route only; admitted source remains the selection truth.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use abird_host_agent::build_executor::request::{AdmissionPolicy, NixOptions, Peer};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::fleet::build_backend::agent::control::transport::Transport;
use crate::fleet::build_backend::agent::controller::{self, Binding, Controller, PendingCapture};
use crate::fleet::cli::Invocation;
use crate::fleet::host_runtime::HostExecutionTarget;
use crate::fleet::inventory::Inventory;
use crate::fleet::inventory_routing::{self, SelfIdentity};
use crate::fleet::system::{self, ResolvedHost};
use crate::fleet::transport::HostTransport;

pub const DIRECTORY: &str = "/etc/abird-owned-fleet";

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Bootstrap {
    #[serde(skip)]
    pub reference: Option<Reference>,
    pub version: u32,
    pub uid: u32,
    pub controller: Peer,
    pub repository_id: String,
    pub inventory: Value,
    pub known_hosts_file: PathBuf,
    /// Existing credential references, never secret bytes or decryption here.
    pub credentials: BTreeMap<PathBuf, PathBuf>,
    #[serde(default)]
    nix: RequestedNix,
    pub local_control: bool,
    pub controller_service: bool,
    pub state_home: PathBuf,
}

/// Missing ceilings are resolved once against authenticated builder policy, not
/// host hardware or caller environment. Concrete options live in the request.
#[derive(Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct RequestedNix {
    max_jobs: Option<u16>,
    cores: Option<u16>,
    substitute: Option<bool>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Reference {
    pub path: PathBuf,
    pub digest: String,
}

impl Reference {
    pub(crate) fn load(&self) -> Result<Bootstrap> {
        self.validate()?;
        ensure!(
            std::fs::canonicalize(&self.path)? == self.path,
            "bootstrap reference redirected"
        );
        let bytes = abird_host_agent::build_executor::daemon::read_declaration(&self.path)?;
        ensure!(
            abird_host_agent::sha256::digest_bytes(&bytes) == self.digest,
            "retained bootstrap differs"
        );
        Bootstrap::decode(&bytes, self.clone())
    }

    pub(crate) fn validate(&self) -> Result<()> {
        absolute(&self.path)?;
        ensure!(
            self.path.starts_with("/nix/store")
                && self.digest.len() == 64
                && self
                    .digest
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
            "invalid bootstrap reference"
        );
        Ok(())
    }
}

impl Bootstrap {
    pub fn load() -> Result<Self> {
        let declaration = Path::new(DIRECTORY).join(format!("{}.json", unsafe { libc::geteuid() }));
        abird_host_agent::build_executor::daemon::trusted_path(&declaration)?;
        let resolved = std::fs::canonicalize(&declaration)?;
        ensure!(
            resolved.starts_with("/nix/store"),
            "owned bootstrap is not immutable store metadata"
        );
        let bytes = abird_host_agent::build_executor::daemon::read_declaration(&resolved)?;
        ensure!(
            std::fs::canonicalize(&declaration)? == resolved,
            "owned bootstrap changed during load"
        );
        Self::decode(
            &bytes,
            Reference {
                path: resolved,
                digest: abird_host_agent::sha256::digest_bytes(&bytes),
            },
        )
    }

    fn decode(bytes: &[u8], reference: Reference) -> Result<Self> {
        Self::decode_for(
            bytes,
            reference,
            unsafe { libc::geteuid() },
            &crate::fleet::build_backend::agent::run::state_home()?,
        )
    }

    /// Root capture wrapper reads only the installed immutable declaration.
    /// Caller environment/state is validated separately against the admission.
    pub(super) fn for_capture(
        caller: &abird_host_agent::build_executor::capture_role::Caller,
    ) -> Result<Self> {
        abird_host_agent::build_executor::daemon::trusted_path(&caller.bootstrap)?;
        ensure!(
            std::fs::canonicalize(&caller.bootstrap)? == caller.bootstrap,
            "capture bootstrap redirected"
        );
        let bytes = abird_host_agent::build_executor::daemon::read_declaration(&caller.bootstrap)?;
        let reference = Reference {
            path: caller.bootstrap.clone(),
            digest: abird_host_agent::sha256::digest_bytes(&bytes),
        };
        reference.validate()?;
        Self::decode_for(
            &bytes,
            reference,
            caller.account.uid,
            &caller.account.state_home,
        )
    }

    fn decode_for(bytes: &[u8], reference: Reference, uid: u32, state_home: &Path) -> Result<Self> {
        let mut value: Self = serde_json::from_slice(bytes)
            .map_err(|_| anyhow::anyhow!("invalid owned bootstrap declaration"))?;
        ensure!(
            value.version == 1
                && value.uid > 0
                && value.uid == uid
                && value.inventory.is_object()
                && value.credentials.len() <= 64
                && value.nix.max_jobs.is_none_or(|jobs| jobs > 0)
                && value.nix.cores.is_none_or(|cores| cores > 0),
            "owned bootstrap context differs"
        );
        absolute(&value.state_home)?;
        absolute(&value.known_hosts_file)?;
        ensure!(
            !value.controller_service || value.local_control,
            "CI observer bootstrap must use local IPC"
        );
        for path in value.credentials.values() {
            absolute(path)?;
        }
        ensure!(
            state_home == value.state_home,
            "owned caller XDG base differs from installed bootstrap"
        );
        value.reference = Some(reference);
        Ok(value)
    }

    pub(super) fn nix_for(&self, policy: &AdmissionPolicy) -> Result<NixOptions> {
        policy.validate()?;
        let nix = NixOptions {
            max_jobs: self.nix.max_jobs.unwrap_or(policy.max_jobs),
            cores: self.nix.cores.unwrap_or(policy.max_cores),
            substitute: self.nix.substitute.unwrap_or(true),
        };
        ensure!(
            nix.max_jobs > 0
                && nix.max_jobs <= policy.max_jobs
                && nix.cores > 0
                && nix.cores <= policy.max_cores,
            "caller Nix options exceed installed builder policy"
        );
        Ok(nix)
    }

    /// Offline capture receives concrete, originally admitted options. Check
    /// explicit constraints without rediscovering policy or resolving defaults.
    pub(super) fn matches_admitted_nix(&self, nix: &NixOptions) -> bool {
        nix.max_jobs > 0
            && nix.cores > 0
            && self.nix.max_jobs.is_none_or(|jobs| jobs == nix.max_jobs)
            && self.nix.cores.is_none_or(|cores| cores == nix.cores)
            && self.nix.substitute.unwrap_or(true) == nix.substitute
    }

    /// Native route resolver over immutable metadata, not a source evaluator.
    /// Overrides/dependency/default-target semantics are evaluated after admission.
    pub fn inventory(&self, invocation: &Invocation) -> Result<Inventory> {
        let identity = SelfIdentity::detect()?;
        let mut value = self.inventory.clone();
        let decision = inventory_routing::apply_named_routes_with_source(
            &mut value,
            &self.inventory,
            None,
            invocation.options.route,
            invocation.options.route_source,
            Some(&identity),
        )?;
        let mut inventory: Inventory = serde_json::from_value(value)?;
        inventory.route_decision = Some(decision);
        inventory.validate()?;
        Ok(inventory)
    }

    pub fn target(&self, invocation: &Invocation, cwd: &Path) -> Result<HostExecutionTarget> {
        absolute(cwd)?;
        let inventory = self.inventory(invocation)?;
        let builder = invocation
            .options
            .build_host
            .as_deref()
            .or_else(|| inventory.config.builders.first().map(String::as_str))
            .unwrap_or("local");
        let builder = if builder == "local" {
            self.controller.host_id.as_str()
        } else {
            builder
        };
        let mut host = system::resolve_host(&inventory, builder, &invocation.options)?;
        self.credentials(&mut host)?;
        crate::fleet::preparation::ensure_explicit_named_route_effective(
            &inventory,
            [host.inventory_name.as_str()],
        )?;
        let transports = inventory
            .hosts
            .keys()
            .map(|name| {
                let mut resolved = system::resolve_host(&inventory, name, &invocation.options)?;
                self.credentials(&mut resolved)?;
                let local = self.local_control && name == &self.controller.host_id;
                Ok((
                    name.clone(),
                    crate::fleet::system_route::host_transport(&resolved, local)?,
                ))
            })
            .collect::<Result<BTreeMap<String, HostTransport>>>()?;
        let local = self.local_control && host.inventory_name == self.controller.host_id;
        ensure!(
            !self.controller_service || local,
            "CI observer cannot move to another builder"
        );
        let mut route = crate::fleet::system_route::primary_route(&host, &transports, true)?;
        if !local {
            // Installed caller admission cannot establish host trust by TOFU.
            abird_host_agent::build_executor::capture_role::trusted_ssh_program(Path::new(
                "/run/current-system/sw/bin/ssh",
            ))?;
            abird_host_agent::build_executor::capture_role::trusted_ssh_file(
                &self.known_hosts_file,
                false,
            )?;
            route.host_key_policy = crate::fleet::transport::HostKeyPolicy::Strict;
        }
        let target = HostExecutionTarget::from_resolved(
            &host,
            route,
            cwd,
            Some(self.known_hosts_file.clone()),
            local,
        )?;
        if !local {
            super::control::transport::require_root_relay_route(&target)?;
        }
        Ok(target)
    }

    fn credentials(&self, host: &mut ResolvedHost) -> Result<()> {
        let bind = |path: &Path| -> Result<PathBuf> {
            let bound = self
                .credentials
                .get(path)
                .map(PathBuf::as_path)
                .unwrap_or(path);
            absolute(bound)?;
            ensure!(
                bound.extension().is_none_or(|extension| extension != "age"),
                "bootstrap credential requires installed materialization"
            );
            Ok(bound.to_owned())
        };
        host.identity_key = host.identity_key.as_deref().map(bind).transpose()?;
        host.operator_key = host.operator_key.as_deref().map(bind).transpose()?;
        Ok(())
    }

    pub(super) fn admit_repository(
        self,
        invocation: Invocation,
        source_root: PathBuf,
        runtime: &crate::fleet::runtime::RuntimeConfig,
        transport: &mut impl Transport,
    ) -> Result<Controller> {
        ensure!(
            !self.controller_service,
            abird_host_agent::build_executor::strategy::AGENT_CI_DEFERRED
        );
        let target = self.target(&invocation, &source_root)?;
        let declaration = controller::describe(&target, transport)?;
        let nix = self.nix_for(&declaration.policy)?;
        let binding = Binding {
            builder: Peer {
                host_id: declaration.identity.builder_id.clone(),
                fabric_id: self.controller.fabric_id.clone(),
            },
            declaration,
            controller: self.controller,
            repository_id: self.repository_id,
            nix,
            target,
        };
        controller::admit_repository(invocation, source_root, binding, runtime)
    }

    pub fn admit(
        self,
        invocation: Invocation,
        cwd: PathBuf,
        transport: &mut impl Transport,
    ) -> Result<Controller> {
        // CI first-hop forwarding must deliver an admitted capsule, not invoke
        // legacy prepare_ci_trigger before ownership. Its entry is separate.
        ensure!(
            !invocation.options.ci_trigger,
            "owned CI forwarding requires the admitted controller entry"
        );
        let target = self.target(&invocation, &cwd)?;
        if !target.local {
            ensure!(
                !self.local_control && !self.controller_service,
                "remote capture requires an explicitly remote caller bootstrap"
            );
            let policy = abird_host_agent::build_executor::capture_role::Policy::load()
                .context("remote source capture requires the installed caller-only capture role")?;
            ensure!(
                policy.relay_port != target.route.endpoint.port,
                "capture data requires a dedicated admitted SSH endpoint"
            );
            let caller = policy.caller(unsafe { libc::geteuid() })?;
            ensure!(
                self.reference
                    .as_ref()
                    .is_some_and(|reference| reference.path == caller.bootstrap)
                    && caller.account.state_home == self.state_home,
                "remote capture bootstrap differs from its installed role"
            );
            use abird_host_agent::build_executor::capture_role;
            ensure!(
                matches!(
                    capture_role::client(&capture_role::Command::Check)?,
                    capture_role::Reply::Ready
                ),
                "root capture credential profile is unavailable or unsafe"
            );
        }
        let declaration = controller::describe(&target, transport)?;
        let nix = self.nix_for(&declaration.policy)?;
        let builder = Peer {
            host_id: declaration.identity.builder_id.clone(),
            fabric_id: self.controller.fabric_id.clone(),
        };
        let binding = Binding {
            declaration,
            controller: self.controller,
            builder,
            repository_id: self.repository_id,
            nix,
            target,
        };
        let reference = self.reference.ok_or_else(|| {
            anyhow::anyhow!("bootstrap was not loaded from its installed declaration")
        })?;
        let pending = PendingCapture {
            invocation,
            cwd,
            bootstrap: Some(reference),
            environment: Some(crate::fleet::build_backend::agent::capture::Environment::current()?),
        };
        if self.controller_service {
            controller::admit_service(pending, binding)
        } else {
            controller::admit(pending, binding)
        }
    }
}

fn absolute(path: &Path) -> Result<()> {
    ensure!(
        path.is_absolute()
            && path.to_str().is_some()
            && path.components().all(|part| matches!(
                part,
                std::path::Component::RootDir | std::path::Component::Normal(_)
            )),
        "noncanonical owned bootstrap path"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn policy() -> AdmissionPolicy {
        serde_json::from_value(json!({
            "capacity_digest": "c".repeat(64),
            "deadlines": {
                "heartbeat_seconds": 2, "stale_seconds": 6, "owner_seconds": 12,
                "queue_seconds": 60, "runtime_seconds": 600,
                "stop_grace_seconds": 3, "stop_limit_seconds": 10,
                "retention_seconds": 60
            },
            "max_jobs": 3, "max_cores": 4,
            "submission_age_seconds": 60, "future_skew_seconds": 2,
            "replay_seconds": 120
        }))
        .unwrap()
    }

    fn profile() -> Value {
        json!({
            "version": 1, "uid": 1100,
            "controller": {"host_id": "caller", "fabric_id": "fleet"},
            "repository_id": "repo", "inventory": {"hosts": {"builder": {}}},
            "known_hosts_file": "/etc/ssh/ssh_known_hosts", "credentials": {},
            "local_control": false, "controller_service": false,
            "state_home": "/home/operator/.local/state"
        })
    }

    fn decode(value: &Value) -> Result<Bootstrap> {
        let bytes = serde_json::to_vec(value)?;
        Bootstrap::decode_for(
            &bytes,
            Reference {
                path: "/nix/store/test-caller-bootstrap.json".into(),
                digest: abird_host_agent::sha256::digest_bytes(&bytes),
            },
            1100,
            Path::new("/home/operator/.local/state"),
        )
    }

    #[test]
    fn generated_profile_uses_builder_policy_without_replacing_explicit_options() {
        let mut value = profile();
        let bootstrap = decode(&value).unwrap();
        assert_eq!(
            bootstrap.nix_for(&policy()).unwrap(),
            NixOptions {
                max_jobs: 3,
                cores: 4,
                substitute: true
            }
        );
        assert!(bootstrap.matches_admitted_nix(&bootstrap.nix_for(&policy()).unwrap()));
        value["nix"] = json!({"substitute": false});
        assert_eq!(
            decode(&value).unwrap().nix_for(&policy()).unwrap(),
            NixOptions {
                max_jobs: 3,
                cores: 4,
                substitute: false
            }
        );
        value["nix"] = json!({"max_jobs": 1, "cores": 2, "substitute": false});
        assert_eq!(
            decode(&value).unwrap().nix_for(&policy()).unwrap(),
            NixOptions {
                max_jobs: 1,
                cores: 2,
                substitute: false
            }
        );
        let explicit = decode(&value).unwrap();
        let mut admitted = explicit.nix_for(&policy()).unwrap();
        assert!(explicit.matches_admitted_nix(&admitted));
        admitted.max_jobs += 1;
        assert!(!explicit.matches_admitted_nix(&admitted));
        admitted = explicit.nix_for(&policy()).unwrap();
        admitted.substitute = true;
        assert!(!explicit.matches_admitted_nix(&admitted));
        // Original references retain the exact input bytes, not normalized defaults.
        assert_ne!(
            bootstrap.reference.unwrap().digest,
            decode(&value).unwrap().reference.unwrap().digest
        );
    }

    #[test]
    fn generated_profile_rejects_invalid_options_and_cannot_raise_builder_capacity() {
        for options in [
            json!({"max_jobs": 0}),
            json!({"cores": 0}),
            json!({"max_jobs": 65536}),
            json!({"unknown": true}),
        ] {
            let mut value = profile();
            value["nix"] = options;
            assert!(decode(&value).is_err());
        }
        for options in [json!({"max_jobs": 4}), json!({"cores": 5})] {
            let mut value = profile();
            value["nix"] = options;
            assert!(decode(&value).unwrap().nix_for(&policy()).is_err());
        }
        let mut invalid = policy();
        invalid.max_jobs = 0;
        assert!(decode(&profile()).unwrap().nix_for(&invalid).is_err());
    }

    #[test]
    fn generated_profile_preserves_account_and_original_state_binding() {
        for (field, replacement) in [
            ("uid", json!(1101)),
            ("state_home", json!("/home/other/.local/state")),
            ("known_hosts_file", json!("relative/known_hosts")),
        ] {
            let mut value = profile();
            value[field] = replacement;
            assert!(decode(&value).is_err());
        }
    }
}
