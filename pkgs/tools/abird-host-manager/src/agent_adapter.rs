use std::collections::{BTreeMap, BTreeSet};
use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use abird_host_agent::deployment::{
    NixbotDeployRequest, UNCOMMITTED_CONTROLLER_REVISION, validate_nixbot_deploy_request,
};
use abird_host_agent::instance::{
    InstanceControlAction, InstanceControlRequest, InstanceMigrationPhase, InstanceMigrationRequest,
};
use abird_host_agent::resource::{DataRoot, DataRootPlan};
use abird_host_agent::sha256::digest_bytes;
use abird_host_agent::transfer::RemoteSource;
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::programs::nix::Nix;
use crate::progress::{ProgressReporter, StepProgress};
use crate::repository::Repository;
use crate::service_registry::resolve_service_host;
use crate::ssh_runtime::SshRuntime;
use crate::workflow::{InstanceEndpoint, MoveItem};
use crate::{Action, Adapter, ResourceKind, Transaction};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostManagerConfig {
    pub schema_version: u32,
    pub ssh: SshConfig,
    pub hosts: BTreeMap<String, Host>,
    #[serde(default)]
    pub transfer_broker: Option<String>,
    #[serde(default)]
    pub operation_routes: BTreeMap<String, OperationRoute>,
    #[serde(skip)]
    ssh_runtime: Option<Arc<SshRuntime>>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SshConfig {
    pub program: PathBuf,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default = "default_connect_timeout_seconds")]
    pub connect_timeout_seconds: u32,
    #[serde(default = "default_agent_poll_interval_ms")]
    pub agent_poll_interval_ms: u64,
    #[serde(default = "default_job_timeout_seconds")]
    pub job_timeout_seconds: u64,
    #[serde(default = "default_rsync_program")]
    pub rsync_program: PathBuf,
    #[serde(default = "default_tar_program")]
    pub tar_program: PathBuf,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Host {
    pub address: String,
    #[serde(default)]
    pub local: bool,
    #[serde(default)]
    pub user: Option<String>,
    #[serde(default)]
    pub port: Option<u16>,
    #[serde(default)]
    pub identity_file: Option<PathBuf>,
    #[serde(default)]
    pub operator_user: Option<String>,
    #[serde(default)]
    pub operator_identity_file: Option<PathBuf>,
    #[serde(default)]
    pub operator_port: Option<u16>,
    #[serde(default)]
    pub known_hosts_file: Option<PathBuf>,
    #[serde(default)]
    pub host_key_alias: Option<String>,
    #[serde(default)]
    pub host_key_check: Option<String>,
    #[serde(default)]
    pub ssh_args: Vec<String>,
    #[serde(default)]
    pub proxy_jump: Option<String>,
    #[serde(default)]
    pub proxy_command: Option<String>,
    /// Inventory parent whose declarative deployment creates this host.
    #[serde(default)]
    pub parent: Option<String>,
    /// SSH arguments used from the controller and peers on the managed network.
    #[serde(default)]
    pub broker_ssh_args: Vec<String>,
    #[serde(default = "default_agent_program")]
    pub agent_program: PathBuf,
    #[serde(default)]
    pub agent_prefix: Vec<String>,
    #[serde(default)]
    pub host_resource: Option<String>,
    #[serde(default)]
    pub groups: BTreeSet<String>,
    /// Nixbot deployment identity for this endpoint. This is intentionally
    /// separate from the manager inventory name and SSH address.
    #[serde(default)]
    pub nixbot_deploy: Option<NixbotDeployRequest>,
    #[serde(default = "default_rsync_program")]
    pub rsync_program: PathBuf,
    #[serde(default)]
    pub rsync_prefix: Option<Vec<String>>,
    #[serde(default = "default_tar_program")]
    pub tar_program: PathBuf,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct OperationRoute {
    /// Inventory host name, "$source", or "$target".
    pub executor: String,
    /// Agent resource override. Defaults to the transaction resource.
    #[serde(default)]
    pub resource: Option<String>,
    /// Allowlisted agent operation. Defaults to the manager operation name.
    #[serde(default)]
    pub agent_operation: Option<String>,
    #[serde(default)]
    pub kind: RoutedOperationKind,
    #[serde(default)]
    pub nixbot_deploy: Option<NixbotDeployRoute>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(untagged)]
pub enum NixbotDeployRoute {
    Endpoint(NixbotDeployEndpointRoute),
    Parent(NixbotDeployParentRoute),
    SharedRole(NixbotDeploySharedRoleRoute),
    Request(NixbotDeployRequest),
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct NixbotDeployEndpointRoute {
    pub endpoint: NixbotDeployEndpoint,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct NixbotDeployParentRoute {
    pub parent_of: NixbotDeployEndpoint,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct NixbotDeploySharedRoleRoute {
    pub shared_role: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NixbotDeployEndpoint {
    Source,
    Target,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RoutedOperationKind {
    #[default]
    Named,
    Transfer,
    VerifyTransfer,
    FileState,
    Ready,
    Provision,
    Deploy,
    NixbotDeploy,
}

#[derive(Clone, Debug, Serialize)]
pub struct HostSummary<'a> {
    pub name: &'a str,
    pub address: &'a str,
    pub user: Option<&'a str>,
    pub port: Option<u16>,
    pub local: bool,
    pub groups: &'a BTreeSet<String>,
    pub agent_program: &'a Path,
}

pub struct NativeAdapter {
    config: HostManagerConfig,
    progress: ProgressReporter,
}

#[derive(Clone, Copy)]
enum TransportRole {
    Primary,
    Operator,
}

impl HostManagerConfig {
    pub fn load(path: &Path) -> Result<Self> {
        if path.extension().and_then(|extension| extension.to_str()) == Some("nix") {
            return Self::load_nixbot(path);
        }
        let mut config: Self = serde_json::from_reader(
            File::open(path).with_context(|| format!("open manager config {}", path.display()))?,
        )
        .with_context(|| format!("parse manager config {}", path.display()))?;
        config.ssh_runtime = Some(Arc::new(SshRuntime::from_environment()?));
        config.validate()?;
        Ok(config)
    }

    fn load_nixbot(path: &Path) -> Result<Self> {
        let path = path
            .canonicalize()
            .with_context(|| format!("resolve Nixbot config {}", path.display()))?;
        let nix_program = manager_nix_program();
        let ssh_program = std::env::var_os("ABIRD_HOST_MANAGER_SSH")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/run/current-system/sw/bin/ssh"));
        let overlay = nixbot_overlay_path(&path)?;
        let value =
            Nix::new(nix_program)?.eval_file_with_overlay_json(&path, overlay.as_deref())?;
        let ssh_runtime = Arc::new(SshRuntime::from_environment()?);
        let hosts = value
            .get("hosts")
            .and_then(Value::as_object)
            .context("Nixbot inventory has no hosts attribute set")?;
        let defaults = value.pointer("/config/hostDefaults");
        let default_user = defaults
            .and_then(|value| value.get("user"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        let default_key = defaults
            .and_then(|value| value.get("key"))
            .and_then(Value::as_str);
        let default_operator_user = defaults
            .and_then(|value| value.get("operatorUser"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        let default_operator_key = defaults
            .and_then(|value| value.get("operatorKey"))
            .and_then(Value::as_str);
        let default_known_hosts = defaults
            .and_then(|value| value.get("knownHosts"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty());
        let ssh_args = vec![
            "-F".to_owned(),
            "/dev/null".to_owned(),
            "-o".to_owned(),
            "GlobalKnownHostsFile=/dev/null".to_owned(),
            "-o".to_owned(),
            "StrictHostKeyChecking=yes".to_owned(),
            "-o".to_owned(),
            "LogLevel=ERROR".to_owned(),
        ];
        let default_known_hosts_file = default_known_hosts
            .map(|contents| ssh_runtime.materialize_known_hosts("default inventory", contents))
            .transpose()?;
        let mut inventory = BTreeMap::new();
        for (name, value) in hosts {
            let address = value
                .get("target")
                .and_then(Value::as_str)
                .with_context(|| format!("Nixbot host {name:?} has no string target"))?;
            let user = value
                .get("user")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| default_user.clone());
            let identity_file = value
                .get("key")
                .and_then(Value::as_str)
                .or(default_key)
                .map(|key| resolve_nixbot_path(&path, key))
                .transpose()?;
            let operator_user = value
                .get("operatorUser")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| default_operator_user.clone());
            let operator_identity_file = value
                .get("operatorKey")
                .and_then(Value::as_str)
                .or(default_operator_key)
                .map(|key| resolve_nixbot_path(&path, key))
                .transpose()?;
            let port = nixbot_port(value.get("port"), name, "port")?;
            let operator_port = nixbot_port(
                value.get("bootstrapPort").or_else(|| value.get("port")),
                name,
                "bootstrapPort",
            )?;
            let proxy_jump = value
                .get("proxyJump")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let proxy_command = value
                .get("proxyCommand")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let parent = value
                .get("parent")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let configured_known_hosts_file = value
                .get("knownHosts")
                .and_then(Value::as_str)
                .filter(|contents| !contents.is_empty())
                .map(|contents| {
                    ssh_runtime.materialize_known_hosts(&format!("host {name}"), contents)
                })
                .transpose()?
                .or_else(|| default_known_hosts_file.clone());
            let (known_hosts_file, host_key_check) = match configured_known_hosts_file {
                Some(known_hosts) => (Some(known_hosts), None),
                None => (
                    Some(ssh_runtime.materialize_known_hosts(&format!("host {name}"), "")?),
                    Some("accept-new".to_owned()),
                ),
            };
            let groups = value
                .get("groups")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .filter(|group| !group.starts_with('-'))
                .map(str::to_owned)
                .collect();
            let resource_id = value
                .get("resourceId")
                .and_then(Value::as_str)
                .unwrap_or(name);
            inventory.insert(
                name.clone(),
                Host {
                    address: address.to_owned(),
                    local: false,
                    user,
                    port,
                    identity_file,
                    operator_user,
                    operator_identity_file,
                    operator_port,
                    known_hosts_file,
                    host_key_alias: None,
                    host_key_check,
                    ssh_args: Vec::new(),
                    proxy_jump,
                    proxy_command,
                    parent: parent.clone(),
                    broker_ssh_args: Vec::new(),
                    agent_program: default_agent_program(),
                    agent_prefix: vec!["/run/wrappers/bin/sudo".to_owned(), "-n".to_owned()],
                    host_resource: Some(format!("host:{resource_id}")),
                    groups,
                    nixbot_deploy: Some(NixbotDeployRequest {
                        host: name.clone(),
                        nix_config: None,
                        exclude_hosts: parent.into_iter().collect(),
                    }),
                    rsync_program: default_rsync_program(),
                    rsync_prefix: None,
                    tar_program: default_tar_program(),
                },
            );
        }
        let mut config = Self {
            schema_version: 1,
            ssh: SshConfig {
                program: ssh_program,
                args: ssh_args,
                connect_timeout_seconds: default_connect_timeout_seconds(),
                agent_poll_interval_ms: default_agent_poll_interval_ms(),
                job_timeout_seconds: default_job_timeout_seconds(),
                rsync_program: default_rsync_program(),
                tar_program: default_tar_program(),
            },
            hosts: inventory,
            transfer_broker: None,
            operation_routes: BTreeMap::new(),
            ssh_runtime: Some(ssh_runtime),
        };
        config.derive_repository_defaults(&value)?;
        config.validate()?;
        Ok(config)
    }

    fn derive_repository_defaults(&mut self, inventory: &Value) -> Result<()> {
        let Some(controller_resource) = inventory
            .pointer("/config/ci/host")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        else {
            return Ok(());
        };
        let controller_resource = format!("host:{controller_resource}");
        let controllers = self
            .hosts
            .iter()
            .filter_map(|(name, host)| {
                (host.host_resource.as_deref() == Some(controller_resource.as_str()))
                    .then_some(name.clone())
            })
            .collect::<Vec<_>>();
        let controller = match controllers.as_slice() {
            [controller] => controller.clone(),
            [] => return Ok(()),
            _ => {
                bail!(
                    "Nixbot CI host resource {controller_resource:?} has multiple inventory endpoints"
                )
            }
        };

        self.transfer_broker = Some(controller.clone());
        for (operation, nixbot_deploy) in [
            (
                "provision-target",
                NixbotDeployRoute::Parent(NixbotDeployParentRoute {
                    parent_of: NixbotDeployEndpoint::Target,
                }),
            ),
            (
                "deploy-target-gated",
                NixbotDeployRoute::Endpoint(NixbotDeployEndpointRoute {
                    endpoint: NixbotDeployEndpoint::Target,
                }),
            ),
            (
                "deploy-cutover",
                NixbotDeployRoute::SharedRole(NixbotDeploySharedRoleRoute {
                    shared_role: "proxy".to_owned(),
                }),
            ),
            (
                "deploy-rollback",
                NixbotDeployRoute::SharedRole(NixbotDeploySharedRoleRoute {
                    shared_role: "proxy".to_owned(),
                }),
            ),
        ] {
            self.operation_routes.insert(
                operation.to_owned(),
                OperationRoute {
                    executor: controller.clone(),
                    resource: Some("controller:nixbot".to_owned()),
                    agent_operation: None,
                    kind: RoutedOperationKind::NixbotDeploy,
                    nixbot_deploy: Some(nixbot_deploy),
                },
            );
        }
        Ok(())
    }

    pub fn validate(&self) -> Result<()> {
        if self.schema_version != 1 {
            bail!(
                "unsupported host manager config schema version {}",
                self.schema_version
            );
        }
        if !self.ssh.program.is_absolute()
            || !self.ssh.rsync_program.is_absolute()
            || !self.ssh.tar_program.is_absolute()
        {
            bail!("manager SSH, rsync, and tar programs must be absolute paths");
        }
        if self.ssh.connect_timeout_seconds == 0 || self.ssh.connect_timeout_seconds > 300 {
            bail!("SSH connect timeout must be between 1 and 300 seconds");
        }
        if self.ssh.agent_poll_interval_ms == 0 || self.ssh.agent_poll_interval_ms > 60_000 {
            bail!("agent poll interval must be between 1 and 60000 milliseconds");
        }
        if self.ssh.job_timeout_seconds == 0 || self.ssh.job_timeout_seconds > 604_800 {
            bail!("job timeout must be between 1 and 604800 seconds");
        }
        validate_argv("global SSH arguments", &self.ssh.args)?;
        if self.hosts.is_empty() {
            bail!("manager inventory must declare at least one host");
        }
        for (name, host) in &self.hosts {
            validate_name("host inventory name", name)?;
            if host.address.trim().is_empty()
                || host.address.contains(['\0', '\r', '\n'])
                || host.address.starts_with('-')
            {
                bail!("host {name:?} has an invalid address");
            }
            if host.user.as_ref().is_some_and(|user| !is_safe_user(user)) {
                bail!("host {name:?} has an invalid SSH user");
            }
            if host
                .operator_user
                .as_ref()
                .is_some_and(|user| !is_safe_user(user))
            {
                bail!("host {name:?} has an invalid operator SSH user");
            }
            if host.port == Some(0) {
                bail!("host {name:?} SSH port cannot be zero");
            }
            if host.operator_port == Some(0) {
                bail!("host {name:?} operator SSH port cannot be zero");
            }
            if host
                .identity_file
                .as_ref()
                .is_some_and(|path| !path.is_absolute())
            {
                bail!("host {name:?} identity file must be absolute");
            }
            if host
                .operator_identity_file
                .as_ref()
                .is_some_and(|path| !path.is_absolute())
            {
                bail!("host {name:?} operator identity file must be absolute");
            }
            if host
                .known_hosts_file
                .as_ref()
                .is_some_and(|path| !path.is_absolute())
            {
                bail!("host {name:?} known-hosts file must be absolute");
            }
            if host
                .host_key_alias
                .as_ref()
                .is_some_and(|alias| alias.is_empty() || alias.contains(['\0', '\r', '\n']))
            {
                bail!("host {name:?} has an invalid host-key alias");
            }
            if host
                .host_key_check
                .as_deref()
                .is_some_and(|value| !matches!(value, "yes" | "accept-new"))
            {
                bail!("host {name:?} has an invalid host-key checking policy");
            }
            if !host.agent_program.is_absolute() {
                bail!("host {name:?} agent program must be absolute");
            }
            if !host.rsync_program.is_absolute() || !host.tar_program.is_absolute() {
                bail!("host {name:?} rsync and tar programs must be absolute");
            }
            if let Some(resource) = &host.host_resource {
                validate_name("host resource", resource)?;
            }
            for group in &host.groups {
                validate_name("host inventory group", group)?;
            }
            if let Some(request) = &host.nixbot_deploy {
                validate_nixbot_deploy_request(request)
                    .with_context(|| format!("host {name:?} Nixbot deployment request"))?;
            }
            validate_argv(&format!("host {name:?} SSH arguments"), &host.ssh_args)?;
            if let Some(proxy) = &host.proxy_jump {
                validate_name("proxy host inventory name", proxy)?;
                if proxy == name || !self.hosts.contains_key(proxy) {
                    bail!("host {name:?} has invalid proxy host {proxy:?}");
                }
            }
            if host.proxy_jump.is_some() && host.proxy_command.is_some() {
                bail!("host {name:?} cannot define both proxy_jump and proxy_command");
            }
            if let Some(parent) = &host.parent {
                validate_name("parent host inventory name", parent)?;
                if parent == name || !self.hosts.contains_key(parent) {
                    bail!("host {name:?} has invalid parent host {parent:?}");
                }
            }
            if host
                .proxy_command
                .as_ref()
                .is_some_and(|command| command.is_empty() || command.contains('\0'))
            {
                bail!("host {name:?} has an invalid proxy command");
            }
            validate_argv(
                &format!("host {name:?} broker SSH arguments"),
                &host.broker_ssh_args,
            )?;
            validate_argv(&format!("host {name:?} agent prefix"), &host.agent_prefix)?;
            if let Some(prefix) = &host.rsync_prefix {
                validate_argv(&format!("host {name:?} rsync prefix"), prefix)?;
            }
        }
        for (name, host) in &self.hosts {
            self.ssh_transport_args(name, host, TransportRole::Primary)
                .with_context(|| format!("host {name:?} SSH transport"))?;
        }
        if let Some(broker) = &self.transfer_broker
            && !self.hosts.contains_key(broker)
        {
            bail!("transfer broker {broker:?} is not an inventory host");
        }
        for (operation, route) in &self.operation_routes {
            validate_name("operation route", operation)?;
            if !matches!(route.executor.as_str(), "$source" | "$target")
                && !self.hosts.contains_key(&route.executor)
            {
                bail!(
                    "operation {operation:?} executor {:?} is not an inventory host",
                    route.executor
                );
            }
            if route
                .resource
                .as_ref()
                .is_some_and(|value| value.is_empty())
            {
                bail!("operation {operation:?} has an empty resource override");
            }
            if route
                .agent_operation
                .as_ref()
                .is_some_and(|value| value.is_empty())
            {
                bail!("operation {operation:?} has an empty agent operation");
            }
            match (&route.kind, &route.nixbot_deploy) {
                (RoutedOperationKind::NixbotDeploy, Some(NixbotDeployRoute::Request(request))) => {
                    validate_nixbot_deploy_request(request).with_context(|| {
                        format!("operation {operation:?} Nixbot deployment request")
                    })?;
                    if route.agent_operation.is_some() {
                        bail!(
                            "operation {operation:?} cannot combine Nixbot deployment with an agent operation"
                        );
                    }
                }
                (
                    RoutedOperationKind::NixbotDeploy,
                    Some(NixbotDeployRoute::Endpoint(_) | NixbotDeployRoute::Parent(_)),
                ) => {
                    if route.agent_operation.is_some() {
                        bail!(
                            "operation {operation:?} cannot combine Nixbot deployment with an agent operation"
                        );
                    }
                }
                (
                    RoutedOperationKind::NixbotDeploy,
                    Some(NixbotDeployRoute::SharedRole(shared_role)),
                ) => {
                    validate_name("shared deployment role", &shared_role.shared_role)?;
                    if route.agent_operation.is_some() {
                        bail!(
                            "operation {operation:?} cannot combine Nixbot deployment with an agent operation"
                        );
                    }
                }
                (RoutedOperationKind::NixbotDeploy, None) => {
                    bail!("operation {operation:?} has no Nixbot deployment request");
                }
                (_, Some(_)) => {
                    bail!(
                        "operation {operation:?} has Nixbot deployment parameters for a different route kind"
                    );
                }
                (_, None) => {}
            }
        }
        Ok(())
    }

    pub fn host(&self, name: &str) -> Result<&Host> {
        self.hosts
            .get(name)
            .with_context(|| format!("host {name:?} is not present in manager inventory"))
    }

    pub fn host_name_for_address(&self, address: &str) -> Result<&str> {
        let mut matches = self
            .hosts
            .iter()
            .filter_map(|(name, host)| (host.address == address).then_some(name.as_str()));
        let name = matches
            .next()
            .with_context(|| format!("no inventory host has address {address:?}"))?;
        if matches.next().is_some() {
            bail!("multiple inventory hosts have address {address:?}");
        }
        Ok(name)
    }

    pub fn host_summaries(&self) -> Vec<HostSummary<'_>> {
        self.hosts
            .iter()
            .map(|(name, host)| HostSummary {
                name,
                address: &host.address,
                user: host.user.as_deref(),
                port: host.port,
                local: host.local,
                groups: &host.groups,
                agent_program: &host.agent_program,
            })
            .collect()
    }

    fn resolve_nixbot_deploy_request(
        &self,
        route: &NixbotDeployRoute,
        transaction: &Transaction,
    ) -> Result<NixbotDeployRequest> {
        match route {
            NixbotDeployRoute::Request(request) => Ok(request.clone()),
            NixbotDeployRoute::Endpoint(route) => {
                let inventory_name = match route.endpoint {
                    NixbotDeployEndpoint::Source => &transaction.source,
                    NixbotDeployEndpoint::Target => &transaction.target,
                };
                self.host(inventory_name)?
                    .nixbot_deploy
                    .clone()
                    .with_context(|| {
                        format!(
                            "host {inventory_name:?} has no Nixbot deployment identity for {:?} endpoint route",
                            route.endpoint
                        )
                    })
            }
            NixbotDeployRoute::Parent(route) => {
                let inventory_name = match route.parent_of {
                    NixbotDeployEndpoint::Source => &transaction.source,
                    NixbotDeployEndpoint::Target => &transaction.target,
                };
                let parent = self
                    .host(inventory_name)?
                    .parent
                    .as_deref()
                    .with_context(|| {
                        format!("host {inventory_name:?} has no declarative parent")
                    })?;
                self.host(parent)?.nixbot_deploy.clone().with_context(|| {
                    format!("parent host {parent:?} has no Nixbot deployment identity")
                })
            }
            NixbotDeployRoute::SharedRole(route) => {
                self.shared_role_deploy_request(transaction, &route.shared_role)
            }
        }
    }

    fn shared_role_deploy_request(
        &self,
        transaction: &Transaction,
        role: &str,
    ) -> Result<NixbotDeployRequest> {
        let source = self.host_resource(&transaction.source)?;
        let target = self.host_resource(&transaction.target)?;
        let source_namespace = host_resource_namespace(&source).with_context(|| {
            format!("source host resource {source:?} has no repository role suffix")
        })?;
        let target_namespace = host_resource_namespace(&target).with_context(|| {
            format!("target host resource {target:?} has no repository role suffix")
        })?;
        if source_namespace != target_namespace {
            bail!(
                "source and target host resources do not share a deployment namespace; provide an explicit migration config"
            );
        }
        let resource = format!("host:{source_namespace}-{role}");
        let candidates = self
            .hosts
            .iter()
            .filter_map(|(name, host)| {
                (host.host_resource.as_deref() == Some(resource.as_str())).then_some((name, host))
            })
            .collect::<Vec<_>>();
        let (name, host) = match candidates.as_slice() {
            [(name, host)] => (*name, *host),
            [] => {
                bail!(
                    "no inventory host owns derived deployment role resource {resource:?}; provide an explicit migration config"
                )
            }
            _ => {
                bail!(
                    "multiple inventory hosts own derived deployment role resource {resource:?}; provide an explicit migration config"
                )
            }
        };
        host.nixbot_deploy.clone().with_context(|| {
            format!("derived deployment host {name:?} has no Nixbot deployment identity")
        })
    }

    pub fn host_summary(&self, name: &str) -> Result<HostSummary<'_>> {
        let host = self.host(name)?;
        Ok(HostSummary {
            name: self
                .hosts
                .get_key_value(name)
                .map(|(name, _)| name.as_str())
                .expect("validated inventory key must resolve"),
            address: &host.address,
            user: host.user.as_deref(),
            port: host.port,
            local: host.local,
            groups: &host.groups,
            agent_program: &host.agent_program,
        })
    }

    pub fn host_resource(&self, name: &str) -> Result<String> {
        let host = self.host(name)?;
        Ok(host
            .host_resource
            .clone()
            .unwrap_or_else(|| format!("host:{name}")))
    }

    pub fn remote_source(&self, name: &str) -> Result<RemoteSource> {
        let host = self.host(name)?;
        let ssh_args = self.ssh_transport_args(name, host, TransportRole::Primary)?;
        Ok(RemoteSource {
            host: host.address.clone(),
            host_public_keys: Vec::new(),
            user: host.user.clone(),
            port: host.port,
            identity_file: self.identity_file(host, TransportRole::Primary)?,
            ssh_program: self.ssh.program.clone(),
            ssh_args,
            agent_program: host.agent_program.clone(),
            agent_prefix: host.agent_prefix.clone(),
            rsync_program: host.rsync_program.clone(),
            rsync_prefix: host
                .rsync_prefix
                .clone()
                .unwrap_or_else(|| host.agent_prefix.clone()),
            tar_program: host.tar_program.clone(),
        })
    }

    pub fn broker_endpoint(&self, name: &str, preserve_agent: bool) -> Result<RemoteSource> {
        let host = self.host(name)?;
        if host.local {
            bail!("local inventory host {name:?} cannot be a transfer endpoint");
        }
        let mut agent_prefix = host.agent_prefix.clone();
        if preserve_agent {
            let Some(sudo_index) = agent_prefix.iter().position(|argument| {
                Path::new(argument)
                    .file_name()
                    .and_then(|name| name.to_str())
                    == Some("sudo")
            }) else {
                bail!(
                    "source host {name:?} agent prefix must contain sudo for forwarded authentication"
                );
            };
            agent_prefix.insert(sudo_index + 1, "--preserve-env=SSH_AUTH_SOCK".to_owned());
        }
        let mut ssh_args = self.ssh.args.clone();
        ssh_args.extend([
            "-o".to_owned(),
            format!("ConnectTimeout={}", self.ssh.connect_timeout_seconds),
        ]);
        ssh_args.extend(host.broker_ssh_args.clone());
        Ok(RemoteSource {
            host: host.address.clone(),
            host_public_keys: Vec::new(),
            user: host.user.clone(),
            port: host.port,
            identity_file: None,
            ssh_program: self.ssh.program.clone(),
            ssh_args,
            agent_program: host.agent_program.clone(),
            agent_prefix,
            rsync_program: host.rsync_program.clone(),
            rsync_prefix: host
                .rsync_prefix
                .clone()
                .unwrap_or_else(|| host.agent_prefix.clone()),
            tar_program: host.tar_program.clone(),
        })
    }

    /// Build a peer-transfer endpoint and bind it to the host key observed over
    /// the manager's already authenticated inventory transport.  The durable
    /// broker job can then connect from a different machine without depending
    /// on that machine's ambient known-hosts state.
    pub fn pinned_broker_endpoint(&self, name: &str, preserve_agent: bool) -> Result<RemoteSource> {
        let mut endpoint = self.broker_endpoint(name, preserve_agent)?;
        let response = self.run_agent(
            name,
            &[
                "--json".to_owned(),
                "data".to_owned(),
                "ssh-host-key".to_owned(),
            ],
        )?;
        let public_key = response
            .pointer("/result/public_key")
            .and_then(Value::as_str)
            .with_context(|| format!("host {name:?} returned no public SSH host key"))?;
        if public_key.contains(['\0', '\r', '\n']) || !public_key.starts_with("ssh-") {
            bail!("host {name:?} returned an invalid public SSH host key");
        }
        endpoint.host_public_keys = vec![public_key.to_owned()];
        Ok(endpoint)
    }

    pub fn run_agent(&self, host_name: &str, agent_args: &[String]) -> Result<Value> {
        let host = self.host(host_name)?;
        let remote_argv = agent_argv(host, agent_args);
        let output = if host.local {
            Command::new(
                remote_argv
                    .first()
                    .context("local host-agent command is empty")?,
            )
            .args(&remote_argv[1..])
            .output()
            .with_context(|| format!("run local host agent for {host_name:?}"))?
        } else {
            self.remote_output(host_name, &remote_argv)?
        };
        ensure_success("host agent command", output)
    }

    pub fn run_agent_with_input(
        &self,
        host_name: &str,
        agent_args: &[String],
        input: &[u8],
    ) -> Result<Value> {
        let host = self.host(host_name)?;
        let remote_argv = agent_argv(host, agent_args);
        let mut command = if host.local {
            let mut command = Command::new(
                remote_argv
                    .first()
                    .context("local host-agent command is empty")?,
            );
            command.args(&remote_argv[1..]);
            command
        } else {
            let remote = shell_join(&remote_argv)?;
            let mut command = self.ssh_command(host_name, host, TransportRole::Primary)?;
            command.arg(remote);
            command
        };
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("start host agent with input for {host_name:?}"))?;
        child
            .stdin
            .take()
            .context("host-agent input pipe disappeared")?
            .write_all(input)
            .with_context(|| format!("write host-agent input for {host_name:?}"))?;
        let output = child
            .wait_with_output()
            .with_context(|| format!("wait for host agent on {host_name:?}"))?;
        ensure_success("host agent command", output)
    }

    pub fn run_agent_interactive(&self, host_name: &str, agent_args: &[String]) -> Result<()> {
        let host = self.host(host_name)?;
        let remote_argv = agent_argv(host, agent_args);
        let status = if host.local {
            Command::new(
                remote_argv
                    .first()
                    .context("local host-agent command is empty")?,
            )
            .args(&remote_argv[1..])
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()
            .with_context(|| format!("stream local host agent for {host_name:?}"))?
        } else {
            let remote = shell_join(&remote_argv)?;
            self.ssh_command(host_name, host, TransportRole::Primary)?
                .arg(remote)
                .stdin(Stdio::inherit())
                .stdout(Stdio::inherit())
                .stderr(Stdio::inherit())
                .status()
                .with_context(|| format!("stream host agent for {host_name:?}"))?
        };
        if !status.success() {
            bail!("streaming host-agent command on {host_name:?} failed with {status}");
        }
        Ok(())
    }

    pub fn run_host_command(&self, host_name: &str, argv: &[String]) -> Result<Output> {
        if argv.is_empty() {
            bail!("remote host command argv cannot be empty");
        }
        validate_argv("remote host command", argv)?;
        if self.host(host_name)?.local {
            Command::new(&argv[0])
                .args(&argv[1..])
                .output()
                .with_context(|| format!("run local command for {host_name:?}"))
        } else {
            self.remote_output_with_role(host_name, argv, TransportRole::Operator)
        }
    }

    pub fn run_host_command_interactive(&self, host_name: &str, argv: &[String]) -> Result<()> {
        if argv.is_empty() {
            bail!("remote host command argv cannot be empty");
        }
        validate_argv("remote host command", argv)?;
        let host = self.host(host_name)?;
        if host.local {
            let status = Command::new(&argv[0])
                .args(&argv[1..])
                .stdin(Stdio::inherit())
                .stdout(Stdio::inherit())
                .stderr(Stdio::inherit())
                .status()
                .with_context(|| format!("run interactive local command for {host_name:?}"))?;
            if !status.success() {
                bail!("local command for host {host_name:?} failed with {status}");
            }
            return Ok(());
        }
        let mut command = self.ssh_command(host_name, host, TransportRole::Operator)?;
        let remote = shell_join(argv)?;
        let status = command
            .arg(remote)
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()
            .with_context(|| format!("run interactive command on host {host_name:?}"))?;
        if !status.success() {
            bail!("remote command on host {host_name:?} failed with {status}");
        }
        Ok(())
    }

    pub fn open_ssh(&self, host_name: &str, extra_args: &[String]) -> Result<()> {
        let host = self.host(host_name)?;
        if host.local {
            bail!("local inventory host {host_name:?} has no interactive SSH session");
        }
        validate_argv("interactive SSH arguments", extra_args)?;
        let mut command = self.ssh_base_command(host_name, host, TransportRole::Operator)?;
        let status = command
            .args(extra_args)
            .arg("--")
            .arg(ssh_destination(host, TransportRole::Operator))
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()
            .with_context(|| format!("open SSH session for host {host_name:?}"))?;
        if !status.success() {
            bail!("SSH session for host {host_name:?} failed with {status}");
        }
        Ok(())
    }

    fn remote_output(&self, host_name: &str, argv: &[String]) -> Result<Output> {
        self.remote_output_with_role(host_name, argv, TransportRole::Primary)
    }

    fn remote_output_with_role(
        &self,
        host_name: &str,
        argv: &[String],
        role: TransportRole,
    ) -> Result<Output> {
        let host = self.host(host_name)?;
        if host.local {
            bail!("local inventory host {host_name:?} has no SSH transport");
        }
        let remote = shell_join(argv)?;
        self.ssh_command(host_name, host, role)?
            .arg(remote)
            .output()
            .with_context(|| format!("run SSH transport for host {host_name:?}"))
    }

    fn ssh_command(&self, host_name: &str, host: &Host, role: TransportRole) -> Result<Command> {
        let mut command = self.ssh_base_command(host_name, host, role)?;
        command.arg("--").arg(ssh_destination(host, role));
        Ok(command)
    }

    fn ssh_base_command(
        &self,
        host_name: &str,
        host: &Host,
        role: TransportRole,
    ) -> Result<Command> {
        let mut command = Command::new(&self.ssh.program);
        command.args(self.ssh_transport_args(host_name, host, role)?);
        if let Some(port) = ssh_port(host, role) {
            command.arg("-p").arg(port.to_string());
        }
        if let Some(identity_file) = self.identity_file(host, role)? {
            command
                .arg("-i")
                .arg(identity_file)
                .arg("-o")
                .arg("IdentitiesOnly=yes");
        }
        Ok(command)
    }

    fn ssh_transport_args(
        &self,
        host_name: &str,
        host: &Host,
        role: TransportRole,
    ) -> Result<Vec<String>> {
        let mut args = host_ssh_options(host);
        args.extend(self.ssh.args.clone());
        args.extend([
            "-o".to_owned(),
            "BatchMode=yes".to_owned(),
            "-o".to_owned(),
            format!("ConnectTimeout={}", self.ssh.connect_timeout_seconds),
        ]);
        if let Some(proxy) = &host.proxy_jump {
            args.extend([
                "-o".to_owned(),
                format!(
                    "ProxyCommand={}",
                    self.proxy_command(
                        proxy,
                        &host.address,
                        ssh_port(host, role).unwrap_or(22),
                        &mut BTreeSet::from([host_name.to_owned()]),
                    )?
                ),
            ]);
        } else if let Some(command) = &host.proxy_command {
            args.extend(["-o".to_owned(), format!("ProxyCommand={command}")]);
        }
        Ok(args)
    }

    fn proxy_command(
        &self,
        proxy_name: &str,
        forward_host: &str,
        forward_port: u16,
        visiting: &mut BTreeSet<String>,
    ) -> Result<String> {
        if !visiting.insert(proxy_name.to_owned()) {
            bail!("manager proxy chain contains a cycle at {proxy_name:?}");
        }
        let proxy = self.host(proxy_name)?;
        let role = TransportRole::Operator;
        let mut argv = vec![self.ssh.program.to_string_lossy().into_owned()];
        argv.extend(host_ssh_options(proxy));
        argv.extend(self.ssh.args.clone());
        argv.extend([
            "-o".to_owned(),
            "BatchMode=yes".to_owned(),
            "-o".to_owned(),
            format!("ConnectTimeout={}", self.ssh.connect_timeout_seconds),
        ]);
        if let Some(port) = ssh_port(proxy, role) {
            argv.extend(["-p".to_owned(), port.to_string()]);
        }
        if let Some(identity_file) = self.identity_file(proxy, role)? {
            argv.extend([
                "-i".to_owned(),
                identity_file.to_string_lossy().into_owned(),
                "-o".to_owned(),
                "IdentitiesOnly=yes".to_owned(),
            ]);
        }
        if let Some(next_proxy) = &proxy.proxy_jump {
            let nested = self.proxy_command(
                next_proxy,
                &proxy.address,
                ssh_port(proxy, role).unwrap_or(22),
                visiting,
            )?;
            argv.extend([
                "-o".to_owned(),
                format!("ProxyCommand={}", escape_proxy_tokens(&nested)),
            ]);
        } else if let Some(command) = &proxy.proxy_command {
            argv.extend([
                "-o".to_owned(),
                format!("ProxyCommand={}", escape_proxy_tokens(command)),
            ]);
        }
        argv.extend([
            "-W".to_owned(),
            ssh_forward_destination(forward_host, forward_port),
            "--".to_owned(),
            ssh_destination(proxy, role),
        ]);
        visiting.remove(proxy_name);
        shell_join(&argv)
    }

    fn identity_file(&self, host: &Host, role: TransportRole) -> Result<Option<PathBuf>> {
        let source = match role {
            TransportRole::Primary => host.identity_file.as_deref(),
            TransportRole::Operator => host
                .operator_identity_file
                .as_deref()
                .or(host.identity_file.as_deref()),
        };
        source
            .map(|source| {
                if source.extension().and_then(|value| value.to_str()) == Some("age") {
                    self.ssh_runtime
                        .as_ref()
                        .context("encrypted SSH identity requires a loaded SSH runtime")?
                        .resolve_identity(source)
                } else {
                    if !source.is_file() {
                        bail!("SSH identity does not exist: {}", source.display());
                    }
                    Ok(source.to_path_buf())
                }
            })
            .transpose()
    }
}

fn agent_argv(host: &Host, agent_args: &[String]) -> Vec<String> {
    let mut argv = Vec::with_capacity(host.agent_prefix.len() + agent_args.len() + 1);
    argv.extend(host.agent_prefix.clone());
    argv.push(host.agent_program.to_string_lossy().into_owned());
    argv.extend_from_slice(agent_args);
    argv
}

fn nixbot_overlay_path(config: &Path) -> Result<Option<PathBuf>> {
    for environment in [
        "ABIRD_HOST_MANAGER_CONFIG_OVERRIDE",
        "NIXBOT_CONFIG_OVERRIDE_PATH",
    ] {
        if let Some(path) = std::env::var_os(environment).map(PathBuf::from) {
            let path = if path.is_absolute() {
                path
            } else {
                std::env::current_dir()
                    .with_context(|| format!("resolve {environment} from current directory"))?
                    .join(path)
            };
            if !path.is_file() {
                bail!("{environment} does not name a file: {}", path.display());
            }
            return Ok(Some(path));
        }
    }
    let stem = config
        .file_stem()
        .and_then(|value| value.to_str())
        .context("Nixbot config filename is not valid UTF-8")?;
    let overlay = config.with_file_name(format!("{stem}.override.nix"));
    Ok(overlay.is_file().then_some(overlay))
}

fn manager_nix_program() -> PathBuf {
    std::env::var_os("ABIRD_HOST_MANAGER_NIX")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/current-system/sw/bin/nix"))
}

fn repository_for_config(config: &Path) -> Result<Option<Repository>> {
    if config.file_name().and_then(|name| name.to_str()) != Some("nixbot.nix")
        || config
            .parent()
            .and_then(Path::file_name)
            .and_then(|name| name.to_str())
            != Some("hosts")
    {
        return Ok(None);
    }
    let root = config
        .parent()
        .and_then(Path::parent)
        .context("repository Nixbot config has no repository root")?;
    Repository::from_root(root.to_path_buf()).map(Some)
}

fn resolve_nixbot_path(config: &Path, value: &str) -> Result<PathBuf> {
    let path = PathBuf::from(value);
    if path.is_absolute() {
        return Ok(path);
    }
    if path.is_file() {
        return path
            .canonicalize()
            .with_context(|| format!("resolve Nixbot path {}", path.display()));
    }
    let config_directory = config.parent().context("Nixbot config has no parent")?;
    for candidate in [
        config_directory.join(&path),
        config_directory.join("..").join(&path),
    ] {
        if candidate.is_file() {
            return candidate
                .canonicalize()
                .with_context(|| format!("resolve Nixbot path {}", candidate.display()));
        }
    }
    Ok(config_directory.join("..").join(path))
}

fn nixbot_port(value: Option<&Value>, host: &str, field: &str) -> Result<Option<u16>> {
    let Some(value) = value else {
        return Ok(None);
    };
    if value.is_null() || value.as_str() == Some("") {
        return Ok(None);
    }
    let port = match value {
        Value::Number(value) => value.as_u64(),
        Value::String(value) => value.parse::<u64>().ok(),
        _ => None,
    }
    .filter(|port| (1..=u16::MAX as u64).contains(port))
    .with_context(|| format!("Nixbot host {host:?} has invalid {field}"))?;
    Ok(Some(port as u16))
}

fn ssh_destination(host: &Host, role: TransportRole) -> String {
    let user = match role {
        TransportRole::Primary => host.user.as_ref(),
        TransportRole::Operator => host.operator_user.as_ref().or(host.user.as_ref()),
    };
    match user {
        Some(user) => format!("{user}@{}", host.address),
        None => host.address.clone(),
    }
}

fn ssh_port(host: &Host, role: TransportRole) -> Option<u16> {
    match role {
        TransportRole::Primary => host.port,
        TransportRole::Operator => host.operator_port.or(host.port),
    }
}

fn ssh_forward_destination(host: &str, port: u16) -> String {
    if host.contains(':') && !(host.starts_with('[') && host.ends_with(']')) {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    }
}

fn escape_proxy_tokens(command: &str) -> String {
    command.replace('%', "%%")
}

fn host_ssh_options(host: &Host) -> Vec<String> {
    let mut options = host.ssh_args.clone();
    if let Some(known_hosts) = &host.known_hosts_file {
        options.extend([
            "-o".to_owned(),
            format!("UserKnownHostsFile={}", known_hosts.display()),
        ]);
    }
    if let Some(alias) = &host.host_key_alias {
        options.extend(["-o".to_owned(), format!("HostKeyAlias={alias}")]);
    }
    if let Some(policy) = &host.host_key_check {
        options.extend(["-o".to_owned(), format!("StrictHostKeyChecking={policy}")]);
    }
    options
}

impl NativeAdapter {
    pub fn load(path: &Path) -> Result<Self> {
        Ok(Self {
            config: HostManagerConfig::load(path)?,
            progress: ProgressReporter::new(true),
        })
    }

    pub fn from_config(config: HostManagerConfig) -> Self {
        Self {
            config,
            progress: ProgressReporter::new(false),
        }
    }

    pub fn with_progress(mut self, show_progress: bool) -> Self {
        self.progress = ProgressReporter::new(show_progress);
        self
    }

    pub fn progress(&self) -> &ProgressReporter {
        &self.progress
    }

    pub fn config(&self) -> &HostManagerConfig {
        &self.config
    }

    pub fn preflight_transaction(
        &self,
        transaction: &mut Transaction,
        action: Action,
    ) -> Result<()> {
        self.config.host(&transaction.source)?;
        self.config.host(&transaction.target)?;
        let source_resource =
            self.transaction_resource_for_host(transaction, &transaction.source)?;
        let target_resource =
            self.transaction_resource_for_host(transaction, &transaction.target)?;
        let mut declarations = BTreeMap::new();
        let source = load_resource_declaration(
            &self.config,
            &transaction.source,
            &source_resource,
            &mut declarations,
        )?
        .clone();
        ensure_data_paths(&source, &transaction.source, &source_resource)?;

        if action == Action::Setup {
            let target_probe = self.config.run_agent(
                &transaction.target,
                &["--json".to_owned(), "job".to_owned(), "list".to_owned()],
            );
            if let Err(error) = &target_probe {
                if !self
                    .config
                    .operation_routes
                    .contains_key("provision-target")
                {
                    bail!(
                        "target agent is unreachable and no provision-target route is configured: {error:#}"
                    );
                }
                self.preflight_route_with_cache(
                    transaction,
                    "provision-target",
                    &mut declarations,
                )?;
            }
            if target_probe.is_err()
                || !target_setup_satisfied(
                    &self.config,
                    transaction,
                    &target_resource,
                    &source,
                    &mut declarations,
                )
            {
                self.preflight_route_with_cache(
                    transaction,
                    "deploy-target-gated",
                    &mut declarations,
                )?;
            }
        }

        if matches!(
            action,
            Action::Seed | Action::Prepare | Action::Verify | Action::Cutover | Action::Rollback
        ) {
            let target = load_resource_declaration(
                &self.config,
                &transaction.target,
                &target_resource,
                &mut declarations,
            )?;
            ensure_data_paths(target, &transaction.target, &target_resource)?;
            let resolved = resolve_data_root_plan(&source, target).with_context(|| {
                format!(
                    "map source resource {source_resource:?} to target resource {target_resource:?}"
                )
            })?;
            if transaction.data_root_plan.is_empty() {
                transaction.data_root_plan = resolved;
            } else if transaction.data_root_plan != resolved {
                bail!("declared data-root mapping changed after transaction planning");
            }
        }

        if matches!(
            action,
            Action::Seed | Action::Prepare | Action::Verify | Action::Rollback
        ) {
            self.preflight_broker_transfer(transaction, &source_resource)?;
        }

        match action {
            Action::Cutover => {
                self.preflight_repository_service_placement(transaction, &transaction.target)?
            }
            Action::Rollback => {
                self.preflight_repository_service_placement(transaction, &transaction.source)?
            }
            _ => {}
        }

        for operation in required_routes(action) {
            self.preflight_route_with_cache(transaction, operation, &mut declarations)?;
        }
        Ok(())
    }

    fn preflight_route(&self, transaction: &Transaction, operation: &str) -> Result<()> {
        self.preflight_route_with_cache(transaction, operation, &mut BTreeMap::new())
    }

    fn preflight_broker_transfer(&self, transaction: &Transaction, resource: &str) -> Result<()> {
        let broker = self
            .config
            .transfer_broker
            .as_deref()
            .context("manager inventory has no transfer_broker")?;
        let source = self
            .config
            .pinned_broker_endpoint(&transaction.source, true)?;
        let target = self
            .config
            .pinned_broker_endpoint(&transaction.target, false)?;
        let job_id = format!(
            "preflight-{}",
            &digest_bytes(transaction.id.as_bytes())[..24]
        );
        self.config.run_agent(
            broker,
            &[
                "--json".to_owned(),
                "job".to_owned(),
                "_materialize".to_owned(),
                "--job-id".to_owned(),
                job_id,
                "--transaction".to_owned(),
                transaction.id.clone(),
                "--resource".to_owned(),
                resource.to_owned(),
                "--broker-copy".to_owned(),
                serde_json::to_string(&source)?,
                "--target-endpoint".to_owned(),
                serde_json::to_string(&target)?,
                "--data-root-plan".to_owned(),
                serde_json::to_string(&transaction.data_root_plan)?,
            ],
        )?;
        Ok(())
    }

    fn preflight_route_with_cache(
        &self,
        transaction: &Transaction,
        operation: &str,
        declarations: &mut BTreeMap<String, Value>,
    ) -> Result<()> {
        let route = self
            .config
            .operation_routes
            .get(operation)
            .with_context(|| format!("migration operation route {operation:?} is missing"))?;
        let executor = resolve_executor(&route.executor, transaction);
        self.config.host(executor)?;
        let nixbot_request = if route.kind == RoutedOperationKind::NixbotDeploy {
            Some(
                self.config.resolve_nixbot_deploy_request(
                    route
                        .nixbot_deploy
                        .as_ref()
                        .context("validated Nixbot route has no deployment request")?,
                    transaction,
                )?,
            )
        } else {
            None
        };
        let executor_resource = self.transaction_resource_for_host(transaction, executor)?;
        let resource = route.resource.as_deref().unwrap_or(&executor_resource);
        let declaration =
            load_resource_declaration(&self.config, executor, resource, declarations)?;
        let profile = route.agent_operation.as_deref().unwrap_or(operation);
        ensure_profile(declaration, operation, route.kind, profile)?;
        if let Some(request) = nixbot_request {
            let response = self.config.run_agent(
                executor,
                &[
                    "--json".to_owned(),
                    "job".to_owned(),
                    "_materialize".to_owned(),
                    "--job-id".to_owned(),
                    format!(
                        "preflight-{}",
                        &digest_bytes(format!("{}:{operation}", transaction.id).as_bytes())[..24]
                    ),
                    "--transaction".to_owned(),
                    transaction.id.clone(),
                    "--resource".to_owned(),
                    resource.to_owned(),
                    "--nixbot-deploy".to_owned(),
                    serde_json::to_string(&request)?,
                ],
            )?;
            let revision = response
                .pointer("/result/spec/nixbot_deploy/revision")
                .and_then(Value::as_str)
                .context("controller did not materialize a pinned Nixbot revision")?;
            if revision == UNCOMMITTED_CONTROLLER_REVISION {
                bail!(
                    "controller generation is uncommitted; deploy a committed controller generation before {operation}"
                );
            }
            if let Some(expected) = self.repository_revision(transaction)?
                && revision != expected
            {
                bail!(
                    "controller generation revision {revision:?} does not match repository revision {expected:?}; deploy the controller from the intended committed revision before {operation}"
                );
            }
        }
        Ok(())
    }

    fn repository_revision(&self, transaction: &Transaction) -> Result<Option<String>> {
        let Some(repository) = repository_for_config(&transaction.config)? else {
            return Ok(None);
        };
        let controller = self
            .config
            .transfer_broker
            .as_deref()
            .context("repository-native deployment has no derived controller")?;
        let controller = self
            .config
            .host(controller)?
            .nixbot_deploy
            .as_ref()
            .context("derived controller has no Nixbot deployment identity")?;
        let installable = format!(
            ".#nixosConfigurations.{}.config.system.configurationRevision",
            controller.host
        );
        let value = Nix::new(manager_nix_program())?.eval_installable_apply_json(
            repository.root(),
            &installable,
            "value: value",
        )?;
        value
            .as_str()
            .map(|revision| Some(revision.to_owned()))
            .context(
                "repository has no committed system.configurationRevision; commit the intended placement before deployment",
            )
    }

    fn preflight_repository_service_placement(
        &self,
        transaction: &Transaction,
        expected_host: &str,
    ) -> Result<()> {
        if transaction.resource_kind != ResourceKind::Service {
            return Ok(());
        }
        let Some(repository) = repository_for_config(&transaction.config)? else {
            return Ok(());
        };
        let source = self.config.host_resource(&transaction.source)?;
        let target = self.config.host_resource(&transaction.target)?;
        let source_namespace = host_resource_namespace(&source).with_context(|| {
            format!("source host resource {source:?} has no repository role suffix")
        })?;
        let target_namespace = host_resource_namespace(&target).with_context(|| {
            format!("target host resource {target:?} has no repository role suffix")
        })?;
        if source_namespace != target_namespace {
            bail!(
                "source and target do not share a repository stack; provide an explicit migration config"
            );
        }
        let logical_service = transaction
            .resource
            .strip_prefix(&format!("{source_namespace}-"))
            .unwrap_or(&transaction.resource);
        let placement = resolve_service_host(
            &repository,
            &manager_nix_program(),
            &self.config,
            source_namespace,
            logical_service,
        )?;
        if placement.host != expected_host {
            bail!(
                "repository places service {:?} on {:?}, but this phase requires {:?}; commit the intended declarative placement first",
                transaction.resource,
                placement.host,
                expected_host
            );
        }
        Ok(())
    }

    fn transaction_resource_for_host(
        &self,
        transaction: &Transaction,
        host: &str,
    ) -> Result<String> {
        if transaction.resource_kind == ResourceKind::Host
            && (host == transaction.source || host == transaction.target)
        {
            self.config.host_resource(host)
        } else if transaction.resource_kind == ResourceKind::Resource {
            Ok(transaction.resource.clone())
        } else {
            Ok(format!(
                "{}:{}",
                transaction.resource_kind.as_str(),
                transaction.resource
            ))
        }
    }

    fn run_job(
        &self,
        host: &str,
        transaction: &Transaction,
        resource: &str,
        operation_args: &[String],
    ) -> Result<()> {
        let job_id = transaction
            .active_job_id
            .as_deref()
            .context("native job invocation requires a durable active job ID")?;
        self.run_profile_job(host, job_id, &transaction.id, resource, operation_args)
    }

    pub fn run_profile_job(
        &self,
        host: &str,
        job_id: &str,
        transaction_id: &str,
        resource: &str,
        operation_args: &[String],
    ) -> Result<()> {
        self.run_profile_job_result(host, job_id, transaction_id, resource, operation_args)?;
        Ok(())
    }

    pub fn run_profile_job_result(
        &self,
        host: &str,
        job_id: &str,
        transaction_id: &str,
        resource: &str,
        operation_args: &[String],
    ) -> Result<Value> {
        let mut materialize_args = vec![
            "--json".to_owned(),
            "job".to_owned(),
            "_materialize".to_owned(),
            "--job-id".to_owned(),
            job_id.to_owned(),
            "--transaction".to_owned(),
            transaction_id.to_owned(),
            "--resource".to_owned(),
            resource.to_owned(),
        ];
        materialize_args.extend_from_slice(operation_args);
        let materialized = self.config.run_agent(host, &materialize_args)?;
        let spec = materialized
            .pointer("/result/spec")
            .context("agent job materialization response has no immutable spec")?;
        let status_args = [
            "--json".to_owned(),
            "job".to_owned(),
            "status".to_owned(),
            "--job-id".to_owned(),
            job_id.to_owned(),
        ];
        let existing = self.config.run_agent(host, &status_args).ok();
        if let Some(existing) = &existing {
            let existing_spec = existing
                .pointer("/result/spec")
                .context("existing agent job status has no immutable spec")?;
            if !retry_spec_matches(existing_spec, spec) {
                bail!(
                    "host-agent job {job_id:?} already exists with a different immutable specification; if a terminal failed job must adopt intentionally changed policy, resume the owning transaction with --supersede-failed-job"
                );
            }
        }
        let encoded_spec =
            serde_json::to_vec(spec).context("serialize materialized agent job spec")?;
        let existing_job = existing.is_some();
        let value = match existing {
            Some(value) => value,
            None => self.config.run_agent_with_input(
                host,
                &[
                    "--json".to_owned(),
                    "job".to_owned(),
                    "submit".to_owned(),
                    "--spec".to_owned(),
                    "-".to_owned(),
                    "--defer".to_owned(),
                ],
                &encoded_spec,
            )?,
        };
        let status = if existing_job {
            value
                .pointer("/result/status")
                .and_then(Value::as_str)
                .context("existing agent job status has no status")?
        } else {
            submission_job_status(&value)?
        };
        match status {
            "succeeded" => {
                let pointer = if existing_job {
                    "/result"
                } else {
                    "/result/job"
                };
                return value
                    .pointer(pointer)
                    .cloned()
                    .with_context(|| format!("agent job response has no job record at {pointer}"));
            }
            "failed" => {
                self.config.run_agent_with_input(
                    host,
                    &[
                        "--json".to_owned(),
                        "job".to_owned(),
                        "retry".to_owned(),
                        "--job-id".to_owned(),
                        job_id.to_owned(),
                        "--spec".to_owned(),
                        "-".to_owned(),
                    ],
                    &encoded_spec,
                )?;
            }
            "pending" | "running" => {}
            status => bail!("host-agent job {job_id:?} returned invalid status {status:?}"),
        }

        let deadline = Instant::now() + Duration::from_secs(self.config.ssh.job_timeout_seconds);
        let polling_started = Instant::now();
        let heartbeat_interval = Duration::from_secs(10);
        let mut last_report = Instant::now();
        let poll_interval = Duration::from_millis(self.config.ssh.agent_poll_interval_ms);
        let mut last_transport_error = None;
        let mut last_progress = None;
        loop {
            if Instant::now() >= deadline {
                let progress = last_progress
                    .as_ref()
                    .map(|progress| format_job_progress(host, job_id, progress))
                    .unwrap_or_else(|| "none".to_owned());
                bail!(
                    "timed out waiting for host-agent job {job_id:?}; last progress: {progress}; last transport error: {}",
                    last_transport_error.as_deref().unwrap_or("none")
                );
            }
            thread::sleep(poll_interval);
            let value = match self.config.run_agent(host, &status_args) {
                Ok(value) => {
                    last_transport_error = None;
                    value
                }
                Err(error) => {
                    last_transport_error = Some(format!("{error:#}"));
                    continue;
                }
            };
            if let Some(progress) = value.pointer("/result/progress")
                && progress != &Value::Null
                && last_progress.as_ref() != Some(progress)
            {
                if self.progress.enabled() {
                    eprintln!("{}", format_job_progress(host, job_id, progress));
                }
                last_progress = Some(progress.clone());
                last_report = Instant::now();
            }
            let status = value
                .pointer("/result/status")
                .and_then(Value::as_str)
                .context("agent job status response has no status")?;
            if self.progress.enabled() && last_report.elapsed() >= heartbeat_interval {
                eprintln!(
                    "[{host}][job {job_id}] {status}; waiting for {}",
                    format_wait_duration(polling_started.elapsed())
                );
                last_report = Instant::now();
            }
            match status {
                "succeeded" => {
                    return value
                        .pointer("/result")
                        .cloned()
                        .context("agent job status response has no job record");
                }
                "failed" => bail!(
                    "host-agent job {job_id:?} failed: {}",
                    value.pointer("/result/error").unwrap_or(&Value::Null)
                ),
                "pending" | "running" => {}
                status => bail!("host-agent job {job_id:?} returned invalid status {status:?}"),
            }
        }
    }

    fn route_job(
        &self,
        operation: &str,
        transaction: &Transaction,
        default_resource: &str,
    ) -> Result<()> {
        let route = self
            .config
            .operation_routes
            .get(operation)
            .with_context(|| format!("native operation route {operation:?} is not configured"))?;
        let executor = resolve_executor(&route.executor, transaction);
        let resource = route.resource.as_deref().unwrap_or(default_resource);
        let agent_operation = route.agent_operation.as_deref().unwrap_or(operation);
        let arguments = match route.kind {
            RoutedOperationKind::Named => {
                vec!["--named-operation".to_owned(), agent_operation.to_owned()]
            }
            RoutedOperationKind::Transfer => {
                vec!["--transfer".to_owned(), agent_operation.to_owned()]
            }
            RoutedOperationKind::VerifyTransfer => {
                vec!["--verify-transfer".to_owned(), agent_operation.to_owned()]
            }
            RoutedOperationKind::FileState => {
                vec!["--file-state".to_owned(), agent_operation.to_owned()]
            }
            RoutedOperationKind::Ready => {
                vec!["--operation".to_owned(), "ready".to_owned()]
            }
            RoutedOperationKind::Provision => {
                vec!["--provision".to_owned(), agent_operation.to_owned()]
            }
            RoutedOperationKind::Deploy => {
                vec!["--deploy".to_owned(), agent_operation.to_owned()]
            }
            RoutedOperationKind::NixbotDeploy => vec![
                "--nixbot-deploy".to_owned(),
                serde_json::to_string(
                    &self.config.resolve_nixbot_deploy_request(
                        route
                            .nixbot_deploy
                            .as_ref()
                            .context("validated Nixbot deployment route has no request")?,
                        transaction,
                    )?,
                )?,
            ],
        };
        self.run_job(executor, transaction, resource, &arguments)
    }

    fn route_job_if_configured(
        &self,
        operation: &str,
        transaction: &Transaction,
        default_resource: &str,
    ) -> Result<()> {
        if self.config.operation_routes.contains_key(operation) {
            self.route_job(operation, transaction, default_resource)
        } else {
            Ok(())
        }
    }

    fn run_broker_job(
        &self,
        transaction: &Transaction,
        resource: &str,
        source: &str,
        target: &str,
        verify: bool,
    ) -> Result<()> {
        let job_id = transaction
            .active_job_id
            .as_deref()
            .context("native broker invocation requires a durable active job ID")?;
        let reverse_plan;
        let plan = if source == transaction.source && target == transaction.target {
            &transaction.data_root_plan
        } else if source == transaction.target && target == transaction.source {
            reverse_plan = transaction
                .data_root_plan
                .iter()
                .map(|root| DataRootPlan {
                    name: root.name.clone(),
                    source: root.target.clone(),
                    target: root.source.clone(),
                    excludes: root.excludes.clone(),
                })
                .collect::<Vec<_>>();
            &reverse_plan
        } else {
            bail!("broker transfer endpoints do not match the durable transaction");
        };
        self.run_broker_profile_job(
            job_id,
            &transaction.id,
            resource,
            source,
            target,
            verify,
            None,
            Some(plan),
            false,
        )?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub fn run_broker_profile_job(
        &self,
        job_id: &str,
        transaction_id: &str,
        resource: &str,
        source: &str,
        target: &str,
        verify: bool,
        destination_root: Option<&Path>,
        data_root_plan: Option<&[DataRootPlan]>,
        backup_source: bool,
    ) -> Result<Value> {
        let broker = self
            .config
            .transfer_broker
            .as_deref()
            .context("manager inventory has no transfer_broker")?;
        let source = self.config.pinned_broker_endpoint(source, true)?;
        let target = self.config.pinned_broker_endpoint(target, false)?;
        let mut arguments = vec![
            if verify {
                "--broker-verify".to_owned()
            } else {
                "--broker-copy".to_owned()
            },
            serde_json::to_string(&source)?,
            "--target-endpoint".to_owned(),
            serde_json::to_string(&target)?,
        ];
        if let Some(destination_root) = destination_root {
            arguments.extend([
                "--destination-root".to_owned(),
                destination_root.to_string_lossy().into_owned(),
            ]);
        }
        if let Some(plan) = data_root_plan.filter(|plan| !plan.is_empty()) {
            arguments.extend(["--data-root-plan".to_owned(), serde_json::to_string(plan)?]);
        }
        if backup_source {
            arguments.push("--backup-source".to_owned());
        }
        self.run_profile_job_result(broker, job_id, transaction_id, resource, &arguments)
    }
}

/// Job specifications stay immutable across retries.  The sole compatibility
/// enrichment accepted here is adding manager-authenticated host keys to an
/// older broker endpoint that was persisted before endpoint pinning existed.
fn retry_spec_matches(existing: &Value, desired: &Value) -> bool {
    if existing == desired {
        return true;
    }
    let mut enriched = existing.clone();
    for endpoint in ["source", "target"] {
        let pointer = format!("/operation/{endpoint}/host_public_keys");
        let Some(old_keys) = existing.pointer(&pointer).and_then(Value::as_array) else {
            return false;
        };
        let Some(new_keys) = desired.pointer(&pointer).and_then(Value::as_array) else {
            return false;
        };
        if !old_keys.is_empty() || new_keys.is_empty() {
            return false;
        }
        let Some(slot) = enriched.pointer_mut(&pointer) else {
            return false;
        };
        *slot = Value::Array(new_keys.clone());
    }
    enriched == *desired
}

fn format_job_progress(host: &str, job_id: &str, progress: &Value) -> String {
    let stage = progress
        .get("stage")
        .and_then(Value::as_str)
        .unwrap_or("working");
    let engine = progress
        .get("engine")
        .and_then(Value::as_str)
        .map(|value| format!(" via {value}"))
        .unwrap_or_default();
    let entries = progress
        .get("entries_completed")
        .and_then(Value::as_u64)
        .zip(progress.get("total_entries").and_then(Value::as_u64))
        .map(|(completed, total)| format!("; entries {completed}/{total}"))
        .unwrap_or_default();
    let bytes = progress
        .get("bytes_completed")
        .and_then(Value::as_u64)
        .zip(progress.get("total_bytes").and_then(Value::as_u64))
        .map(|(completed, total)| format!("; bytes {completed}/{total}"))
        .unwrap_or_default();
    let detail = progress
        .get("detail")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(|value| format!("; {value}"))
        .unwrap_or_default();
    format!("[{host} {job_id}] {stage}{engine}{entries}{bytes}{detail}")
}

fn format_wait_duration(duration: Duration) -> String {
    if duration.as_secs() < 60 {
        format!("{}s", duration.as_secs())
    } else {
        format!(
            "{}m{:02}s",
            duration.as_secs() / 60,
            duration.as_secs() % 60
        )
    }
}

fn required_routes(action: Action) -> &'static [&'static str] {
    match action {
        Action::Setup => &[],
        Action::Cutover => &["deploy-cutover"],
        Action::Rollback => &["deploy-rollback"],
        Action::Plan | Action::Seed | Action::Prepare | Action::Verify | Action::Close => &[],
    }
}

pub fn declared_data_roots(declaration: &Value) -> Result<Vec<DataRoot>> {
    let mut roots: Vec<DataRoot> = serde_json::from_value(
        declaration
            .get("data_roots")
            .cloned()
            .unwrap_or_else(|| Value::Array(Vec::new())),
    )
    .context("agent resource declaration has invalid data_roots")?;
    let paths = declaration
        .get("data_paths")
        .and_then(Value::as_array)
        .context("agent resource declaration has no data_paths array")?;
    for path in paths {
        let path = PathBuf::from(
            path.as_str()
                .context("agent resource data_paths entry is not a string")?,
        );
        roots.push(DataRoot {
            name: format!("path-{}", digest_bytes(path.as_os_str().as_encoded_bytes())),
            path,
            excludes: Vec::new(),
        });
    }
    Ok(roots)
}

fn ensure_data_paths(declaration: &Value, host: &str, resource: &str) -> Result<()> {
    if declared_data_roots(declaration)?.is_empty() {
        bail!("resource {resource:?} on host {host:?} has no declared data paths");
    }
    Ok(())
}

fn resolve_data_root_plan(source: &Value, target: &Value) -> Result<Vec<DataRootPlan>> {
    let source = declared_data_roots(source)?;
    let target = declared_data_roots(target)?;
    let targets = target
        .iter()
        .map(|root| (root.name.as_str(), root))
        .collect::<BTreeMap<_, _>>();
    if source.len() != target.len() {
        bail!("source and target declare different data-root sets");
    }
    source
        .into_iter()
        .map(|source| {
            let target = targets
                .get(source.name.as_str())
                .with_context(|| format!("target has no data root named {:?}", source.name))?;
            if source.excludes != target.excludes {
                bail!(
                    "source and target data root {:?} declare different excludes",
                    source.name
                );
            }
            Ok(DataRootPlan {
                name: source.name,
                source: source.path,
                target: target.path.clone(),
                excludes: source.excludes,
            })
        })
        .collect()
}

fn load_resource_declaration<'a>(
    config: &HostManagerConfig,
    host: &str,
    resource: &str,
    declarations: &'a mut BTreeMap<String, Value>,
) -> Result<&'a Value> {
    let key = format!("{host}\0{resource}");
    if !declarations.contains_key(&key) {
        let response = config.run_agent(
            host,
            &[
                "--json".to_owned(),
                "resource".to_owned(),
                "describe".to_owned(),
                "--resource".to_owned(),
                resource.to_owned(),
            ],
        )?;
        let declaration = response
            .pointer("/result/resource")
            .cloned()
            .context("agent resource description has no resource")?;
        declarations.insert(key.clone(), declaration);
    }
    Ok(&declarations[&key])
}

fn target_setup_satisfied(
    config: &HostManagerConfig,
    transaction: &mut Transaction,
    target_resource: &str,
    source: &Value,
    declarations: &mut BTreeMap<String, Value>,
) -> bool {
    let Ok(target) =
        load_resource_declaration(config, &transaction.target, target_resource, declarations)
    else {
        return false;
    };
    let Ok(plan) = resolve_data_root_plan(source, target) else {
        return false;
    };
    if transaction.data_root_plan.is_empty() {
        transaction.data_root_plan = plan;
        true
    } else {
        transaction.data_root_plan == plan
    }
}

fn ensure_profile(
    declaration: &Value,
    operation: &str,
    kind: RoutedOperationKind,
    profile: &str,
) -> Result<()> {
    let field = match kind {
        RoutedOperationKind::Named => Some("operations"),
        RoutedOperationKind::Transfer | RoutedOperationKind::VerifyTransfer => Some("transfers"),
        RoutedOperationKind::FileState => Some("file_states"),
        RoutedOperationKind::Provision => Some("instances"),
        RoutedOperationKind::Deploy => Some("deployments"),
        RoutedOperationKind::NixbotDeploy => Some("nixbot_deploy"),
        RoutedOperationKind::Ready => None,
    };
    if let Some(field) = field {
        if field == "nixbot_deploy" {
            if declaration.get(field).and_then(Value::as_bool) != Some(true) {
                bail!("migration operation {operation:?} requires Nixbot deployment capability");
            }
        } else if declaration
            .get(field)
            .and_then(|profiles| profiles.get(profile))
            .is_none()
        {
            bail!(
                "migration operation {operation:?} requires missing agent {field} profile {profile:?}"
            );
        }
    }
    Ok(())
}

/// Item-aware binding between the generic transaction state machine and the
/// native operation owner for a specific workflow item.
pub struct WorkflowItemAdapter<'a> {
    native: &'a mut NativeAdapter,
    item: &'a MoveItem,
}

impl<'a> WorkflowItemAdapter<'a> {
    pub fn new(native: &'a mut NativeAdapter, item: &'a MoveItem) -> Self {
        Self { native, item }
    }

    pub fn native_progress(&self) -> &ProgressReporter {
        self.native.progress()
    }

    pub fn preflight(&self, transaction: &mut Transaction, action: Action) -> Result<()> {
        match self.item {
            MoveItem::Instance {
                source,
                target,
                policy,
                ..
            } => {
                self.native.config.host(&source.controller)?;
                self.native.config.host(&target.controller)?;
                self.native.config.host(policy.executor(source))?;
                let mut routes = required_routes(action).to_vec();
                if action == Action::Setup
                    && self
                        .native
                        .config
                        .operation_routes
                        .contains_key("provision-target")
                {
                    routes.push("provision-target");
                }
                if action == Action::Setup
                    && self
                        .native
                        .config
                        .operation_routes
                        .contains_key("deploy-target-gated")
                {
                    routes.push("deploy-target-gated");
                }
                for operation in routes {
                    if self.native.config.operation_routes.contains_key(operation) {
                        self.native
                            .preflight_route(transaction, operation)
                            .with_context(|| {
                                format!("preflight optional instance route {operation:?}")
                            })?;
                    }
                }
                Ok(())
            }
            _ => self.native.preflight_transaction(transaction, action),
        }
    }

    pub fn assert_active_job_failed(&self, transaction: &Transaction) -> Result<()> {
        let operation = transaction
            .active_step
            .as_deref()
            .context("transaction item has no active step to supersede")?;
        let job_id = transaction
            .active_job_id
            .as_deref()
            .context("transaction item has no active job to supersede")?;
        let host = self.step_location(operation, transaction);
        let status = self.native.config.run_agent(
            &host,
            &[
                "--json".to_owned(),
                "job".to_owned(),
                "status".to_owned(),
                "--job-id".to_owned(),
                job_id.to_owned(),
            ],
        )?;
        let state = status
            .pointer("/result/status")
            .and_then(Value::as_str)
            .context("host-agent job status response has no status")?;
        if state != "failed" {
            bail!(
                "host-agent job {job_id:?} on {host:?} is {state:?}; only a terminal failed job can be superseded"
            );
        }
        Ok(())
    }

    fn step_progress(&self, operation: &str, transaction: &Transaction) -> StepProgress {
        StepProgress {
            transaction: transaction.id.clone(),
            item: self.item.id().to_owned(),
            action: transaction.pending_action.unwrap_or(Action::Plan),
            step: operation.to_owned(),
            description: step_description(operation).to_owned(),
            location: self.step_location(operation, transaction),
        }
    }

    fn step_location(&self, operation: &str, transaction: &Transaction) -> String {
        if let MoveItem::Instance { source, policy, .. } = self.item {
            return policy.executor(source).to_owned();
        }
        if matches!(
            operation,
            "seed" | "final-transfer" | "verify-final" | "reverse-transfer" | "verify-reverse"
        ) {
            return format!(
                "{} ({} -> {})",
                self.native
                    .config
                    .transfer_broker
                    .as_deref()
                    .unwrap_or("transfer broker"),
                transaction.source,
                transaction.target
            );
        }
        if let Some(route) = self.native.config.operation_routes.get(operation) {
            return resolve_executor(&route.executor, transaction).to_owned();
        }
        if matches!(
            operation,
            "probe"
                | "hold-source"
                | "assert-source-stopped"
                | "backup-source"
                | "activate-source"
                | "verify-source-ready"
                | "release-source"
        ) {
            transaction.source.clone()
        } else if matches!(
            operation,
            "provision-target"
                | "reserve-target"
                | "deploy-target-gated"
                | "hold-target"
                | "assert-target-stopped"
                | "activate-target"
                | "verify-target-ready"
                | "release-target"
        ) {
            transaction.target.clone()
        } else {
            "manager".to_owned()
        }
    }

    fn run_instance(
        &mut self,
        operation: &str,
        transaction: &mut Transaction,
        source: &InstanceEndpoint,
        target: &InstanceEndpoint,
        policy: &crate::workflow::InstanceMovePolicy,
    ) -> Result<()> {
        let executor = policy.executor(source);
        let source_resource = instance_resource(source)?;
        let target_resource = instance_resource(target)?;
        match operation {
            "probe" => {
                let result = self.control_job(
                    executor,
                    transaction,
                    &source_resource,
                    "inspect-source",
                    source,
                    InstanceControlAction::Inspect,
                )?;
                if result
                    .pointer("/result/instance_control/existed")
                    .and_then(Value::as_bool)
                    != Some(true)
                {
                    bail!("source Incus instance {:?} does not exist", source.instance);
                }
                Ok(())
            }
            "provision-target" | "deploy-target-gated" | "deploy-cutover" | "deploy-rollback" => {
                self.native
                    .route_job_if_configured(operation, transaction, &target_resource)
            }
            "reserve-target" => {
                self.reserve_job(executor, transaction, &target_resource, "reserve-target")
            }
            "hold-target" => {
                self.reserve_job(executor, transaction, &target_resource, "reserve-target")?;
                self.control_job(
                    executor,
                    transaction,
                    &target_resource,
                    "stop-target",
                    target,
                    InstanceControlAction::Stop { allow_absent: true },
                )?;
                Ok(())
            }
            "hold-source" => {
                self.reserve_job(executor, transaction, &source_resource, "reserve-source")?;
                // Capture the pre-stop state in its own immutable job. If the
                // stop succeeds but its response is lost, replay still reads
                // this original result rather than observing the now-stopped
                // source and incorrectly deciding it was inactive.
                let inspection = self.control_job(
                    executor,
                    transaction,
                    &source_resource,
                    "inspect-source-before-stop",
                    source,
                    InstanceControlAction::Inspect,
                )?;
                let was_running = inspection
                    .pointer("/result/instance_control/was_running")
                    .and_then(Value::as_bool)
                    .context("source inspection job did not report its runtime state")?;
                match transaction.source_was_active {
                    Some(existing) if existing != was_running => {
                        bail!("durable source runtime state changed across job reconciliation")
                    }
                    Some(_) => {}
                    None => transaction.source_was_active = Some(was_running),
                }
                self.control_job(
                    executor,
                    transaction,
                    &source_resource,
                    "stop-source",
                    source,
                    InstanceControlAction::Stop {
                        allow_absent: false,
                    },
                )?;
                Ok(())
            }
            "assert-source-stopped" => {
                self.assert_stopped(executor, transaction, &source_resource, source, false)
            }
            "assert-target-stopped" => self.assert_stopped(
                executor,
                transaction,
                &target_resource,
                target,
                transaction.pending_action == Some(Action::Setup),
            ),
            "backup-source" => {
                self.control_job(
                    executor,
                    transaction,
                    &source_resource,
                    "safety-snapshot",
                    source,
                    InstanceControlAction::SnapshotCreate {
                        snapshot: safety_snapshot(transaction),
                    },
                )?;
                Ok(())
            }
            "seed" => self.migration_job(
                executor,
                transaction,
                &target_resource,
                "seed-copy",
                source,
                target,
                policy,
                false,
                InstanceMigrationPhase::Seed,
            ),
            "final-transfer" => self.migration_job(
                executor,
                transaction,
                &target_resource,
                "final-copy",
                source,
                target,
                policy,
                false,
                InstanceMigrationPhase::Final,
            ),
            "reverse-transfer" => self.migration_job(
                executor,
                transaction,
                &source_resource,
                "reverse-copy",
                target,
                source,
                policy,
                true,
                InstanceMigrationPhase::Final,
            ),
            "verify-final" => {
                self.assert_stopped(executor, transaction, &source_resource, source, false)?;
                self.assert_stopped(executor, transaction, &target_resource, target, false)?;
                self.verify_migration_target(
                    executor,
                    transaction,
                    &target_resource,
                    "verify-final-target",
                    source,
                    target,
                    policy,
                    false,
                )
            }
            "verify-reverse" => {
                self.assert_stopped(executor, transaction, &source_resource, source, false)?;
                self.assert_stopped(executor, transaction, &target_resource, target, false)?;
                self.verify_migration_target(
                    executor,
                    transaction,
                    &source_resource,
                    "verify-reverse-target",
                    target,
                    source,
                    policy,
                    true,
                )
            }
            "activate-target" => {
                self.control_job(
                    executor,
                    transaction,
                    &target_resource,
                    "activate-target",
                    target,
                    InstanceControlAction::Activate,
                )?;
                Ok(())
            }
            "activate-source" => {
                match transaction.source_was_active {
                    Some(true) => {
                        self.control_job(
                            executor,
                            transaction,
                            &source_resource,
                            "activate-source",
                            source,
                            InstanceControlAction::Activate,
                        )?;
                    }
                    Some(false) => self.release_job(
                        executor,
                        transaction,
                        &source_resource,
                        "release-source-inactive",
                    )?,
                    None => bail!("source runtime state was not captured before rollback"),
                }
                Ok(())
            }
            "verify-target-ready" => {
                self.assert_running(executor, transaction, &target_resource, target)
            }
            "verify-source-ready" => {
                if transaction.source_was_active == Some(true) {
                    self.assert_running(executor, transaction, &source_resource, source)
                } else {
                    self.assert_stopped(executor, transaction, &source_resource, source, false)
                }
            }
            "release-target" => {
                if transaction.pending_action == Some(Action::Rollback) {
                    // Keep the inactive target gated throughout the rollback
                    // window. Close is the explicit point that relinquishes
                    // this controller-side safety authority.
                    return Ok(());
                }
                self.disable_autostart(executor, transaction, &target_resource, target, true)?;
                self.delete_safety_snapshot(executor, transaction, source)?;
                self.release_job(executor, transaction, &target_resource, "release-target")
            }
            "release-source" => {
                self.disable_autostart(executor, transaction, &source_resource, source, false)?;
                self.delete_safety_snapshot(executor, transaction, source)?;
                self.release_job(executor, transaction, &source_resource, "release-source")
            }
            other => bail!("unsupported native instance operation {other:?}"),
        }
    }

    fn job_id(transaction: &Transaction, suffix: &str) -> Result<String> {
        Ok(format!(
            "{}-{suffix}",
            transaction
                .active_job_id
                .as_deref()
                .context("typed instance operation requires a durable active job ID")?
        ))
    }

    fn reserve_job(
        &self,
        executor: &str,
        transaction: &Transaction,
        resource: &str,
        suffix: &str,
    ) -> Result<()> {
        self.native.run_profile_job(
            executor,
            &Self::job_id(transaction, suffix)?,
            &transaction.id,
            resource,
            &["--operation".to_owned(), "reserve".to_owned()],
        )
    }

    fn release_job(
        &self,
        executor: &str,
        transaction: &Transaction,
        resource: &str,
        suffix: &str,
    ) -> Result<()> {
        self.native.run_profile_job(
            executor,
            &Self::job_id(transaction, suffix)?,
            &transaction.id,
            resource,
            &["--operation".to_owned(), "release".to_owned()],
        )
    }

    fn control_job(
        &self,
        executor: &str,
        transaction: &Transaction,
        resource: &str,
        suffix: &str,
        endpoint: &InstanceEndpoint,
        operation: InstanceControlAction,
    ) -> Result<Value> {
        let policy = self.instance_policy()?;
        let request = InstanceControlRequest {
            program: policy.program.clone(),
            remote: endpoint.remote.clone(),
            project: endpoint.project.clone(),
            instance: endpoint.instance.clone(),
            stop_timeout_seconds: policy.stop_timeout_seconds,
            force_after_timeout: policy.force_after_timeout,
            operation,
        };
        self.native.run_profile_job_result(
            executor,
            &Self::job_id(transaction, suffix)?,
            &transaction.id,
            resource,
            &[
                "--control-instance".to_owned(),
                serde_json::to_string(&request)?,
            ],
        )
    }

    fn assert_stopped(
        &self,
        executor: &str,
        transaction: &Transaction,
        resource: &str,
        endpoint: &InstanceEndpoint,
        allow_absent: bool,
    ) -> Result<()> {
        self.control_job(
            executor,
            transaction,
            resource,
            if endpoint == self.instance_source()? {
                "assert-source-stopped"
            } else {
                "assert-target-stopped"
            },
            endpoint,
            InstanceControlAction::AssertStopped { allow_absent },
        )?;
        Ok(())
    }

    fn assert_running(
        &self,
        executor: &str,
        transaction: &Transaction,
        resource: &str,
        endpoint: &InstanceEndpoint,
    ) -> Result<()> {
        self.control_job(
            executor,
            transaction,
            resource,
            if endpoint == self.instance_source()? {
                "assert-source-running"
            } else {
                "assert-target-running"
            },
            endpoint,
            InstanceControlAction::AssertRunning,
        )?;
        Ok(())
    }

    fn instance_source(&self) -> Result<&InstanceEndpoint> {
        match self.item {
            MoveItem::Instance { source, .. } => Ok(source),
            _ => bail!("typed instance helper used for a non-instance item"),
        }
    }

    fn instance_policy(&self) -> Result<&crate::workflow::InstanceMovePolicy> {
        match self.item {
            MoveItem::Instance { policy, .. } => Ok(policy),
            _ => bail!("typed instance helper used for a non-instance item"),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn migration_job(
        &self,
        executor: &str,
        transaction: &Transaction,
        resource: &str,
        suffix: &str,
        source: &InstanceEndpoint,
        target: &InstanceEndpoint,
        policy: &crate::workflow::InstanceMovePolicy,
        reverse: bool,
        phase: InstanceMigrationPhase,
    ) -> Result<()> {
        let request = InstanceMigrationRequest {
            program: policy.program.clone(),
            phase,
            source_instance: source.instance.clone(),
            target_instance: target.instance.clone(),
            source_remote: source.remote.clone(),
            target_remote: target.remote.clone(),
            source_project: source.project.clone(),
            target_project: target.project.clone(),
            snapshot: migration_snapshot(transaction, suffix),
            force_refresh_existing: reverse || policy.adopt_existing_target,
            policy: policy.migration_policy(reverse),
            start_target: false,
        };
        self.native.run_profile_job(
            executor,
            &Self::job_id(transaction, suffix)?,
            &transaction.id,
            resource,
            &[
                "--migrate-instance".to_owned(),
                serde_json::to_string(&request)?,
            ],
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn verify_migration_target(
        &self,
        executor: &str,
        transaction: &Transaction,
        resource: &str,
        suffix: &str,
        source: &InstanceEndpoint,
        target: &InstanceEndpoint,
        policy: &crate::workflow::InstanceMovePolicy,
        reverse: bool,
    ) -> Result<()> {
        let storage_pool = if reverse {
            policy.rollback_storage_pool.clone()
        } else {
            policy.target_storage_pool.clone()
        };
        self.control_job(
            executor,
            transaction,
            resource,
            suffix,
            target,
            InstanceControlAction::VerifyMigrationTarget {
                source_instance: source.instance.clone(),
                source_remote: source.remote.clone(),
                source_project: source.project.clone(),
                storage_pool,
            },
        )?;
        Ok(())
    }

    fn delete_safety_snapshot(
        &self,
        executor: &str,
        transaction: &Transaction,
        source: &InstanceEndpoint,
    ) -> Result<()> {
        self.control_job(
            executor,
            transaction,
            &instance_resource(source)?,
            "delete-safety-snapshot",
            source,
            InstanceControlAction::SnapshotDelete {
                snapshot: safety_snapshot(transaction),
            },
        )?;
        Ok(())
    }

    fn disable_autostart(
        &self,
        executor: &str,
        transaction: &Transaction,
        resource: &str,
        endpoint: &InstanceEndpoint,
        allow_absent: bool,
    ) -> Result<()> {
        self.control_job(
            executor,
            transaction,
            resource,
            if endpoint == self.instance_source()? {
                "disable-source-autostart"
            } else {
                "disable-target-autostart"
            },
            endpoint,
            InstanceControlAction::DisableAutostart { allow_absent },
        )?;
        Ok(())
    }
}

impl Adapter for WorkflowItemAdapter<'_> {
    fn run(&mut self, operation: &str, transaction: &mut Transaction) -> Result<()> {
        let progress = self.step_progress(operation, transaction);
        let started = Instant::now();
        self.native.progress.step_started(&progress);
        let result = match self.item {
            MoveItem::Instance {
                source,
                target,
                policy,
                ..
            } => self.run_instance(operation, transaction, source, target, policy),
            _ => self.native.run(operation, transaction),
        };
        match &result {
            Ok(()) => self
                .native
                .progress
                .step_completed(&progress, started.elapsed()),
            Err(error) => self
                .native
                .progress
                .step_failed(&progress, started.elapsed(), error),
        }
        result
    }
}

fn step_description(operation: &str) -> &str {
    match operation {
        "probe" => "inspect source resource",
        "provision-target" => "check or provision target host",
        "reserve-target" => "reserve target hold",
        "deploy-target-gated" => "check or deploy held target",
        "hold-source" => "hold source writer",
        "hold-target" => "hold target writer",
        "assert-source-stopped" => "verify source writer is stopped",
        "assert-target-stopped" => "verify target writer is stopped",
        "seed" => "copy live source data to held target",
        "backup-source" => "create source safety backup",
        "final-transfer" => "copy final quiesced source data",
        "verify-final" => "verify final target data",
        "deploy-cutover" => "deploy target placement and ingress",
        "activate-target" => "release and start target writer",
        "verify-target-ready" => "verify target readiness",
        "reverse-transfer" => "copy target changes back to source",
        "verify-reverse" => "verify restored source data",
        "deploy-rollback" => "deploy source placement and ingress",
        "activate-source" => "release and start source writer",
        "verify-source-ready" => "verify source readiness",
        "release-target" => "release inactive target hold",
        "release-source" => "release inactive source hold",
        _ => operation,
    }
}

pub fn instance_resource(endpoint: &InstanceEndpoint) -> Result<String> {
    let encoded = serde_json::to_vec(endpoint).context("serialize Incus endpoint authority")?;
    Ok(format!("instance:{}", &digest_bytes(&encoded)[..24]))
}

fn safety_snapshot(transaction: &Transaction) -> String {
    format!(
        "abird-hm-{}-safety",
        &digest_bytes(transaction.id.as_bytes())[..20]
    )
}

fn migration_snapshot(transaction: &Transaction, suffix: &str) -> String {
    format!(
        "abird-hm-{}-{}",
        &digest_bytes(transaction.id.as_bytes())[..16],
        &digest_bytes(suffix.as_bytes())[..8]
    )
}

impl Adapter for NativeAdapter {
    fn run(&mut self, operation: &str, transaction: &mut Transaction) -> Result<()> {
        let source_resource =
            self.transaction_resource_for_host(transaction, &transaction.source)?;
        let target_resource =
            self.transaction_resource_for_host(transaction, &transaction.target)?;
        match operation {
            "probe" => {
                self.config.run_agent(
                    &transaction.source,
                    &[
                        "--json".to_owned(),
                        "resource".to_owned(),
                        "describe".to_owned(),
                        "--resource".to_owned(),
                        source_resource.clone(),
                    ],
                )?;
                Ok(())
            }
            "provision-target" => {
                let target_is_reachable = self
                    .config
                    .run_agent(
                        &transaction.target,
                        &["--json".to_owned(), "job".to_owned(), "list".to_owned()],
                    )
                    .is_ok();
                if target_is_reachable {
                    Ok(())
                } else {
                    self.route_job_if_configured(operation, transaction, &target_resource)
                }
            }
            "reserve-target" => self.run_job(
                &transaction.target,
                transaction,
                &target_resource,
                &["--operation".to_owned(), "reserve".to_owned()],
            ),
            "deploy-target-gated" => {
                let mut declarations = BTreeMap::new();
                let source = load_resource_declaration(
                    &self.config,
                    &transaction.source,
                    &source_resource,
                    &mut declarations,
                )?
                .clone();
                if target_setup_satisfied(
                    &self.config,
                    transaction,
                    &target_resource,
                    &source,
                    &mut declarations,
                ) {
                    Ok(())
                } else {
                    self.route_job(operation, transaction, &target_resource)
                }
            }
            "deploy-cutover" | "deploy-rollback" => {
                self.route_job(operation, transaction, &target_resource)
            }
            "hold-source" => self.run_job(
                &transaction.source,
                transaction,
                &source_resource,
                &["--operation".to_owned(), "hold".to_owned()],
            ),
            "hold-target" => self.run_job(
                &transaction.target,
                transaction,
                &target_resource,
                &["--operation".to_owned(), "hold".to_owned()],
            ),
            "assert-source-stopped" => self.run_job(
                &transaction.source,
                transaction,
                &source_resource,
                &[
                    "--operation".to_owned(),
                    "status".to_owned(),
                    "--expect".to_owned(),
                    "inactive".to_owned(),
                ],
            ),
            "assert-target-stopped" => self.run_job(
                &transaction.target,
                transaction,
                &target_resource,
                &[
                    "--operation".to_owned(),
                    "status".to_owned(),
                    "--expect".to_owned(),
                    "inactive".to_owned(),
                ],
            ),
            "activate-source" => self.run_job(
                &transaction.source,
                transaction,
                &source_resource,
                &["--operation".to_owned(), "activate".to_owned()],
            ),
            "activate-target" => self.run_job(
                &transaction.target,
                transaction,
                &target_resource,
                &["--operation".to_owned(), "activate".to_owned()],
            ),
            "verify-source-ready" => self.run_job(
                &transaction.source,
                transaction,
                &source_resource,
                &["--operation".to_owned(), "ready".to_owned()],
            ),
            "verify-target-ready" => self.run_job(
                &transaction.target,
                transaction,
                &target_resource,
                &["--operation".to_owned(), "ready".to_owned()],
            ),
            "seed" | "final-transfer" => self.run_broker_job(
                transaction,
                &source_resource,
                &transaction.source,
                &transaction.target,
                false,
            ),
            "verify-final" => self.run_broker_job(
                transaction,
                &source_resource,
                &transaction.source,
                &transaction.target,
                true,
            ),
            "backup-source" => self.run_job(
                &transaction.source,
                transaction,
                &source_resource,
                &["--backup".to_owned()],
            ),
            "reverse-transfer" => self.run_broker_job(
                transaction,
                &target_resource,
                &transaction.target,
                &transaction.source,
                false,
            ),
            "verify-reverse" => self.run_broker_job(
                transaction,
                &target_resource,
                &transaction.target,
                &transaction.source,
                true,
            ),
            "release-target" => self.run_job(
                &transaction.target,
                transaction,
                &target_resource,
                &["--operation".to_owned(), "release".to_owned()],
            ),
            "release-source" => self.run_job(
                &transaction.source,
                transaction,
                &source_resource,
                &["--operation".to_owned(), "release".to_owned()],
            ),
            other => bail!("unsupported native manager operation {other:?}"),
        }
    }
}

fn resolve_executor<'a>(executor: &'a str, transaction: &'a Transaction) -> &'a str {
    match executor {
        "$source" => &transaction.source,
        "$target" => &transaction.target,
        host => host,
    }
}

fn host_resource_namespace(resource: &str) -> Option<&str> {
    resource
        .strip_prefix("host:")?
        .rsplit_once('-')
        .map(|(namespace, _)| namespace)
        .filter(|namespace| !namespace.is_empty())
}

fn validate_name(label: &str, value: &str) -> Result<()> {
    if value.is_empty()
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
    {
        bail!("{label} {value:?} contains unsupported characters");
    }
    Ok(())
}

fn validate_argv(label: &str, argv: &[String]) -> Result<()> {
    if argv.iter().any(|argument| argument.contains('\0')) {
        bail!("{label} cannot contain NUL");
    }
    Ok(())
}

fn is_safe_user(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn shell_join(argv: &[String]) -> Result<String> {
    if argv.is_empty() {
        bail!("cannot build an empty remote command");
    }
    Ok(argv
        .iter()
        .map(|argument| format!("'{}'", argument.replace('\'', "'\"'\"'")))
        .collect::<Vec<_>>()
        .join(" "))
}

fn ensure_success(label: &str, output: Output) -> Result<Value> {
    if !output.status.success() {
        bail!(
            "{label} failed with {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    serde_json::from_slice(&output.stdout).with_context(|| {
        format!(
            "parse {label} JSON response; stderr: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )
    })
}

fn submission_job_status(value: &Value) -> Result<&str> {
    value
        .pointer("/result/job/status")
        .and_then(Value::as_str)
        .context("agent job submission response has no job status")
}

fn default_agent_program() -> PathBuf {
    PathBuf::from("/run/current-system/sw/bin/abird-host-agent")
}

fn default_connect_timeout_seconds() -> u32 {
    10
}

fn default_agent_poll_interval_ms() -> u64 {
    1_000
}

fn default_job_timeout_seconds() -> u64 {
    86_400
}

fn default_rsync_program() -> PathBuf {
    PathBuf::from("/run/current-system/sw/bin/rsync")
}

fn default_tar_program() -> PathBuf {
    PathBuf::from("/run/current-system/sw/bin/tar")
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn formats_durable_transfer_progress_for_humans() {
        assert_eq!(
            format_job_progress(
                "target",
                "copy-1",
                &serde_json::json!({
                    "stage": "copying",
                    "engine": "rsync",
                    "entries_completed": 7,
                    "total_entries": 10,
                    "bytes_completed": 4096,
                    "total_bytes": 8192,
                    "detail": "receiving files"
                }),
            ),
            "[target copy-1] copying via rsync; entries 7/10; bytes 4096/8192; receiving files"
        );
        assert_eq!(format_wait_duration(Duration::from_secs(42)), "42s");
        assert_eq!(format_wait_duration(Duration::from_secs(125)), "2m05s");
    }

    #[test]
    fn named_data_roots_map_different_paths_without_weakening_excludes() {
        let plan = resolve_data_root_plan(
            &serde_json::json!({
                "data_paths": [],
                "data_roots": [{
                    "name": "zulip",
                    "path": "/var/lib/abird/zulip",
                    "excludes": ["cache", "tmp/uploads"]
                }]
            }),
            &serde_json::json!({
                "data_paths": [],
                "data_roots": [{
                    "name": "zulip",
                    "path": "/srv/zulip",
                    "excludes": ["cache", "tmp/uploads"]
                }]
            }),
        )
        .unwrap();

        assert_eq!(
            plan,
            [DataRootPlan {
                name: "zulip".to_owned(),
                source: PathBuf::from("/var/lib/abird/zulip"),
                target: PathBuf::from("/srv/zulip"),
                excludes: [PathBuf::from("cache"), PathBuf::from("tmp/uploads")].to_vec(),
            }]
        );
    }

    #[test]
    fn data_root_mapping_rejects_exclusion_drift() {
        assert!(
            resolve_data_root_plan(
                &serde_json::json!({
                    "data_paths": [],
                    "data_roots": [{"name": "state", "path": "/old", "excludes": ["cache"]}]
                }),
                &serde_json::json!({
                    "data_paths": [],
                    "data_roots": [{"name": "state", "path": "/new", "excludes": []}]
                }),
            )
            .is_err()
        );
    }
    use crate::{Action, Transaction};

    #[test]
    fn validates_native_inventory_and_routes() {
        let config: HostManagerConfig = serde_json::from_str(
            r#"{
              "schema_version": 1,
              "ssh": {"program": "/usr/bin/ssh"},
              "hosts": {
                "corp": {
                  "address": "10.0.0.2",
                  "user": "nixbot",
                  "agent_prefix": ["/run/wrappers/bin/sudo", "-n"],
                  "broker_ssh_args": ["-o", "HostKeyAlias=corp"],
                  "host_resource": "host:abird-corp"
                },
                "zulip": {"address": "10.0.0.3"}
              },
              "operation_routes": {
                "seed": {"executor": "$target"},
                "enter-maintenance": {
                  "executor": "corp",
                  "resource": "route:zulip"
                }
              }
            }"#,
        )
        .unwrap();
        config.validate().unwrap();
        assert_eq!(config.host_summaries().len(), 2);
        assert_eq!(config.host_resource("corp").unwrap(), "host:abird-corp");
        assert_eq!(
            config.remote_source("corp").unwrap().rsync_prefix,
            ["/run/wrappers/bin/sudo", "-n"]
        );
        let endpoint = config.broker_endpoint("corp", true).unwrap();
        assert!(endpoint.identity_file.is_none());
        assert!(
            endpoint
                .agent_prefix
                .iter()
                .any(|argument| argument == "--preserve-env=SSH_AUTH_SOCK")
        );
        assert!(
            endpoint
                .ssh_args
                .iter()
                .any(|argument| argument == "HostKeyAlias=corp")
        );
    }

    #[test]
    fn derives_repository_move_policy_from_existing_nixbot_inventory() {
        let mut config: HostManagerConfig = serde_json::from_value(serde_json::json!({
            "schema_version": 1,
            "ssh": {"program": "/usr/bin/ssh"},
            "hosts": {
                "gap3-gondor": {
                    "address": "gateway",
                    "host_resource": "host:gap3-gondor",
                    "nixbot_deploy": {"host": "gap3-gondor"}
                },
                "abird-gondor-ci": {
                    "address": "ci",
                    "host_resource": "host:abird-ci",
                    "nixbot_deploy": {"host": "abird-gondor-ci"}
                },
                "abird-gondor-corp": {
                    "address": "source",
                    "parent": "gap3-gondor",
                    "host_resource": "host:abird-corp",
                    "nixbot_deploy": {
                        "host": "abird-gondor-corp",
                        "exclude_hosts": ["gap3-gondor"]
                    }
                },
                "abird-gondor-zulip": {
                    "address": "target",
                    "parent": "gap3-gondor",
                    "host_resource": "host:abird-zulip",
                    "nixbot_deploy": {
                        "host": "abird-gondor-zulip",
                        "exclude_hosts": ["gap3-gondor"]
                    }
                },
                "abird-gondor-proxy": {
                    "address": "proxy",
                    "parent": "gap3-gondor",
                    "host_resource": "host:abird-proxy",
                    "nixbot_deploy": {
                        "host": "abird-gondor-proxy",
                        "exclude_hosts": ["gap3-gondor"]
                    }
                }
            }
        }))
        .unwrap();
        config
            .derive_repository_defaults(&serde_json::json!({
                "config": {"ci": {"host": "abird-ci"}}
            }))
            .unwrap();
        config.validate().unwrap();

        assert_eq!(config.transfer_broker.as_deref(), Some("abird-gondor-ci"));
        let transaction = Transaction::new_service(
            "abird-zulip".to_owned(),
            "abird-gondor-corp".to_owned(),
            "abird-gondor-zulip".to_owned(),
            PathBuf::from("/hosts/nixbot.nix"),
        )
        .unwrap();
        let request = |operation: &str| {
            config
                .resolve_nixbot_deploy_request(
                    config.operation_routes[operation]
                        .nixbot_deploy
                        .as_ref()
                        .unwrap(),
                    &transaction,
                )
                .unwrap()
        };
        assert_eq!(request("provision-target").host, "gap3-gondor");
        assert_eq!(request("deploy-target-gated").host, "abird-gondor-zulip");
        assert_eq!(request("deploy-cutover").host, "abird-gondor-proxy");
        assert_eq!(request("deploy-rollback").host, "abird-gondor-proxy");
    }

    #[test]
    fn setup_accepts_an_existing_matching_target_without_a_deploy_route() {
        let temp = tempfile::tempdir().unwrap();
        let source_agent = temp.path().join("source-agent");
        let target_agent = temp.path().join("target-agent");
        let declaration = r#"{"ok":true,"result":{"resource":{"data_paths":[],"data_roots":[{"name":"state","path":"/var/lib/state","excludes":[]}]}}}"#;
        fs::write(
            &source_agent,
            format!("#!/bin/sh\nprintf '%s\\n' '{declaration}'\n"),
        )
        .unwrap();
        fs::write(
            &target_agent,
            format!(
                "#!/bin/sh\ncase \"$*\" in\n  *\"job list\"*) printf '%s\\n' '{{\"ok\":true}}' ;;\n  *) printf '%s\\n' '{declaration}' ;;\nesac\n"
            ),
        )
        .unwrap();
        fs::set_permissions(&source_agent, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(&target_agent, fs::Permissions::from_mode(0o700)).unwrap();
        let config: HostManagerConfig = serde_json::from_value(serde_json::json!({
            "schema_version": 1,
            "ssh": {"program": "/bin/false"},
            "hosts": {
                "source": {
                    "address": "local-source",
                    "local": true,
                    "agent_program": source_agent,
                    "agent_prefix": []
                },
                "target": {
                    "address": "local-target",
                    "local": true,
                    "agent_program": target_agent,
                    "agent_prefix": []
                }
            }
        }))
        .unwrap();
        config.validate().unwrap();
        let adapter = NativeAdapter::from_config(config);
        let mut transaction = Transaction::new_service(
            "zulip".to_owned(),
            "source".to_owned(),
            "target".to_owned(),
            PathBuf::from("/hosts/nixbot.nix"),
        )
        .unwrap();

        adapter
            .preflight_transaction(&mut transaction, Action::Setup)
            .unwrap();
        assert_eq!(transaction.data_root_plan.len(), 1);
    }

    #[test]
    fn rejects_unknown_route_executor() {
        let config: HostManagerConfig = serde_json::from_str(
            r#"{
              "schema_version": 1,
              "ssh": {"program": "/usr/bin/ssh"},
              "hosts": {"corp": {"address": "10.0.0.2"}},
              "operation_routes": {"seed": {"executor": "missing"}}
            }"#,
        )
        .unwrap();
        assert!(config.validate().is_err());
    }

    #[test]
    fn host_moves_resolve_each_endpoint_aggregate_resource() {
        let config: HostManagerConfig = serde_json::from_str(
            r#"{
              "schema_version": 1,
              "ssh": {"program": "/usr/bin/ssh"},
              "hosts": {
                "source": {"address": "source", "host_resource": "host:old-name"},
                "target": {"address": "target", "host_resource": "host:new-name"}
              }
            }"#,
        )
        .unwrap();
        let adapter = NativeAdapter::from_config(config);
        let transaction = Transaction::new_host(
            "logical-move".to_owned(),
            "source".to_owned(),
            "target".to_owned(),
            PathBuf::from("/config.json"),
        )
        .unwrap();
        assert_eq!(
            adapter
                .transaction_resource_for_host(&transaction, "source")
                .unwrap(),
            "host:old-name"
        );
        assert_eq!(
            adapter
                .transaction_resource_for_host(&transaction, "target")
                .unwrap(),
            "host:new-name"
        );
    }

    #[test]
    fn preflight_profile_check_is_kind_specific() {
        let declaration = serde_json::json!({
            "transfers": {"copy": {}},
            "file_states": {"target": {}},
            "nixbot_deploy": true,
        });
        ensure_profile(&declaration, "seed", RoutedOperationKind::Transfer, "copy").unwrap();
        assert!(
            ensure_profile(
                &declaration,
                "switch-route-target",
                RoutedOperationKind::FileState,
                "missing",
            )
            .is_err()
        );
        ensure_profile(
            &declaration,
            "deploy-cutover",
            RoutedOperationKind::NixbotDeploy,
            "deploy-cutover",
        )
        .unwrap();
    }

    #[test]
    fn validates_nixbot_route_with_distinct_host_and_nix_config() {
        let config: HostManagerConfig = serde_json::from_str(
            r#"{
              "schema_version": 1,
              "ssh": {"program": "/usr/bin/ssh"},
              "hosts": {"controller": {"address": "local", "local": true}},
              "operation_routes": {
                "deploy-cutover": {
                  "executor": "controller",
                  "resource": "controller:nixbot",
                  "kind": "nixbot_deploy",
                  "nixbot_deploy": {
                    "host": "abird-gondor-proxy",
                    "nix_config": "abird-gondor-proxy-zulip-target",
                    "exclude_hosts": ["gap3-gondor"]
                  }
                }
              }
            }"#,
        )
        .unwrap();
        config.validate().unwrap();
        let request = config.operation_routes["deploy-cutover"]
            .nixbot_deploy
            .as_ref()
            .unwrap();
        let NixbotDeployRoute::Request(request) = request else {
            panic!("expected literal Nixbot deployment request");
        };
        assert_eq!(request.host, "abird-gondor-proxy");
        assert_eq!(
            request.nix_config.as_deref(),
            Some("abird-gondor-proxy-zulip-target")
        );
    }

    #[test]
    fn endpoint_route_resolves_distinct_nixbot_deployment_identity() {
        let config: HostManagerConfig = serde_json::from_str(
            r#"{
              "schema_version": 1,
              "ssh": {"program": "/usr/bin/ssh"},
              "hosts": {
                "source-alias": {
                  "address": "10.0.0.2",
                  "nixbot_deploy": {"host": "source-real"}
                },
                "target-alias": {
                  "address": "10.0.0.3",
                  "nixbot_deploy": {
                    "host": "target-real",
                    "nix_config": "target-generation"
                  }
                }
              },
              "operation_routes": {
                "deploy-cutover": {
                  "executor": "$target",
                  "kind": "nixbot_deploy",
                  "nixbot_deploy": {"endpoint": "target"}
                }
              }
            }"#,
        )
        .unwrap();
        config.validate().unwrap();
        let transaction = Transaction::new_host(
            "logical-move".to_owned(),
            "source-alias".to_owned(),
            "target-alias".to_owned(),
            PathBuf::from("/config.json"),
        )
        .unwrap();
        let request = config
            .resolve_nixbot_deploy_request(
                config.operation_routes["deploy-cutover"]
                    .nixbot_deploy
                    .as_ref()
                    .unwrap(),
                &transaction,
            )
            .unwrap();
        assert_eq!(request.host, "target-real");
        assert_eq!(request.nix_config.as_deref(), Some("target-generation"));
    }

    #[test]
    fn proxy_inventory_resolves_without_ambient_ssh_aliases() {
        let config: HostManagerConfig = serde_json::from_str(
            r#"{
              "schema_version": 1,
              "ssh": {
                "program": "/usr/bin/ssh",
                "args": ["-F", "/var/lib/nixbot/.ssh/config"]
              },
              "hosts": {
                "bastion": {
                  "address": "bastion.example.test",
                  "user": "nixbot",
                  "proxy_command": "cloudflared access ssh --hostname %h"
                },
                "guest": {
                  "address": "10.0.0.3",
                  "user": "nixbot",
                  "proxy_jump": "bastion"
                }
              }
            }"#,
        )
        .unwrap();
        config.validate().unwrap();
        let guest = config.host("guest").unwrap();
        let arguments = config
            .ssh_transport_args("guest", guest, TransportRole::Primary)
            .unwrap();
        let proxy = arguments
            .windows(2)
            .find(|pair| pair[0] == "-o" && pair[1].starts_with("ProxyCommand="))
            .map(|pair| &pair[1])
            .unwrap();
        assert!(proxy.contains("nixbot@bastion.example.test"));
        assert!(proxy.contains("cloudflared access ssh --hostname %%h"));
        assert!(proxy.contains("10.0.0.3:22"));
        assert!(proxy.contains("/var/lib/nixbot/.ssh/config"));
        assert!(!proxy.contains("nixbot@bastion -W"));
    }

    #[test]
    fn nested_proxy_chain_uses_operator_credentials_per_hop() {
        let temp = tempfile::tempdir().unwrap();
        let identity = temp.path().join("operator-key");
        fs::write(&identity, "dummy\n").unwrap();
        let mut config: HostManagerConfig = serde_json::from_str(
            r#"{
              "schema_version": 1,
              "ssh": {"program": "/usr/bin/ssh"},
              "hosts": {
                "workstation": {
                  "address": "workstation.internal",
                  "user": "nixbot"
                },
                "parent": {
                  "address": "10.0.0.10",
                  "user": "nixbot",
                  "proxy_jump": "workstation"
                },
                "guest": {
                  "address": "10.0.1.20",
                  "user": "nixbot",
                  "proxy_jump": "parent"
                }
              }
            }"#,
        )
        .unwrap();
        for host in config.hosts.values_mut() {
            host.operator_user = Some("operator".to_owned());
            host.operator_identity_file = Some(identity.clone());
        }
        config.validate().unwrap();

        let guest = config.host("guest").unwrap();
        let arguments = config
            .ssh_transport_args("guest", guest, TransportRole::Primary)
            .unwrap();
        let proxy = arguments
            .windows(2)
            .find(|pair| pair[0] == "-o" && pair[1].starts_with("ProxyCommand="))
            .map(|pair| &pair[1])
            .unwrap();

        assert!(proxy.contains("operator@workstation.internal"));
        assert!(proxy.contains("operator@10.0.0.10"));
        assert!(proxy.contains(identity.to_string_lossy().as_ref()));
        assert!(proxy.contains("IdentitiesOnly=yes"));
        assert!(proxy.contains("10.0.1.20:22"));
        assert!(proxy.contains("10.0.0.10:22"));
        assert!(!proxy.contains("%h:%p"));
    }

    #[test]
    fn proxy_forwarding_formats_ipv6_and_preserves_nested_tokens() {
        assert_eq!(
            ssh_forward_destination("2001:db8::10", 2222),
            "[2001:db8::10]:2222"
        );
        assert_eq!(
            ssh_forward_destination("host.example", 22),
            "host.example:22"
        );
        assert_eq!(
            escape_proxy_tokens("cloudflared access ssh --hostname %h"),
            "cloudflared access ssh --hostname %%h"
        );
    }

    #[test]
    fn endpoint_host_key_policy_precedes_global_default() {
        let config: HostManagerConfig = serde_json::from_str(
            r#"{
              "schema_version": 1,
              "ssh": {
                "program": "/usr/bin/ssh",
                "args": ["-o", "StrictHostKeyChecking=yes"]
              },
              "hosts": {
                "guest": {
                  "address": "10.0.1.20",
                  "user": "nixbot",
                  "host_key_check": "accept-new"
                }
              }
            }"#,
        )
        .unwrap();
        config.validate().unwrap();

        let guest = config.host("guest").unwrap();
        let arguments = config
            .ssh_transport_args("guest", guest, TransportRole::Primary)
            .unwrap();
        let accept_new = arguments
            .iter()
            .position(|argument| argument == "StrictHostKeyChecking=accept-new")
            .unwrap();
        let strict = arguments
            .iter()
            .position(|argument| argument == "StrictHostKeyChecking=yes")
            .unwrap();

        assert!(accept_new < strict);
    }

    #[test]
    fn interactive_agent_path_preserves_streaming_arguments() {
        let temp = tempfile::tempdir().unwrap();
        let arguments = temp.path().join("arguments");
        let agent = temp.path().join("agent");
        fs::write(
            &agent,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\n",
                arguments.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&agent, fs::Permissions::from_mode(0o700)).unwrap();
        let config: HostManagerConfig = serde_json::from_value(serde_json::json!({
            "schema_version": 1,
            "ssh": {"program": "/bin/false"},
            "hosts": {
                "local": {
                    "address": "localhost",
                    "local": true,
                    "agent_program": agent,
                    "agent_prefix": []
                }
            }
        }))
        .unwrap();
        config.validate().unwrap();

        config
            .run_agent_interactive("local", &["logs".to_owned(), "--follow".to_owned()])
            .unwrap();

        assert_eq!(fs::read_to_string(arguments).unwrap(), "logs\n--follow\n");
    }

    #[test]
    fn remote_shell_arguments_are_single_quoted() {
        assert_eq!(
            shell_join(&["agent".to_owned(), "has space".to_owned(), "a'b".to_owned()]).unwrap(),
            "'agent' 'has space' 'a'\"'\"'b'"
        );
    }

    #[test]
    fn deferred_job_polling_survives_a_transient_transport_drop() {
        let temp = tempfile::tempdir().unwrap();
        let marker = temp.path().join("dropped");
        let ssh = temp.path().join("ssh");
        fs::write(
            &ssh,
            format!(
                r#"#!/bin/sh
case "$*" in
  *"'job' '_materialize'"*)
    printf '%s\n' '{{"ok":true,"result":{{"spec":{{"schema_version":1,"job_id":"job-1"}}}}}}'
    ;;
  *"'job' 'submit'"*)
    printf '%s\n' '{{"ok":true,"result":{{"job":{{"status":"pending"}}}}}}'
    ;;
  *"'job' 'status'"*)
    if [ ! -e '{}' ]; then
      : > '{}'
      exit 255
    fi
    printf '%s\n' '{{"ok":true,"result":{{"status":"succeeded"}}}}'
    ;;
  *) exit 2 ;;
esac
"#,
                marker.display(),
                marker.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&ssh, fs::Permissions::from_mode(0o700)).unwrap();
        let config_path = temp.path().join("config.json");
        fs::write(
            &config_path,
            serde_json::to_vec(&serde_json::json!({
                "schema_version": 1,
                "ssh": {
                    "program": ssh,
                    "agent_poll_interval_ms": 1,
                    "job_timeout_seconds": 2
                },
                "hosts": {
                    "source": {"address": "source.invalid"},
                    "target": {"address": "target.invalid"}
                }
            }))
            .unwrap(),
        )
        .unwrap();
        let mut transaction = Transaction::new_service(
            "zulip".to_owned(),
            "source".to_owned(),
            "target".to_owned(),
            config_path.clone(),
        )
        .unwrap();
        transaction.pending_action = Some(Action::Seed);
        transaction.active_job_id = Some("job-1".to_owned());
        transaction.active_step = Some("hold-source".to_owned());
        let mut adapter = NativeAdapter::load(&config_path).unwrap();
        adapter.run("hold-source", &mut transaction).unwrap();
        assert!(marker.exists());
    }

    #[test]
    fn typed_instance_stop_captures_runtime_state_from_the_durable_job() {
        let temp = tempfile::tempdir().unwrap();
        let log = temp.path().join("agent.log");
        let agent = temp.path().join("agent");
        fs::write(
            &agent,
            format!(
                r#"#!/bin/sh
printf '%s\n' "$*" >> '{}'
case " $* " in
  *" job _materialize "*)
    printf '%s\n' '{{"ok":true,"result":{{"spec":{{"schema_version":1}}}}}}'
    ;;
  *" job submit "*)
    cat >/dev/null
    printf '%s\n' '{{"ok":true,"result":{{"job":{{"status":"succeeded","result":{{"instance_control":{{"existed":true,"was_running":true,"running":false}}}}}}}}}}'
    ;;
  *) exit 2 ;;
esac
"#,
                log.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&agent, fs::Permissions::from_mode(0o700)).unwrap();
        let config: HostManagerConfig = serde_json::from_value(serde_json::json!({
            "schema_version": 1,
            "ssh": {"program": "/bin/false"},
            "hosts": {
                "controller": {
                    "address": "localhost",
                    "local": true,
                    "agent_program": agent,
                    "agent_prefix": []
                }
            }
        }))
        .unwrap();
        let source = InstanceEndpoint {
            controller: "controller".to_owned(),
            remote: "local".to_owned(),
            project: "source".to_owned(),
            instance: "zulip".to_owned(),
        };
        let target = InstanceEndpoint {
            project: "target".to_owned(),
            ..source.clone()
        };
        let item = MoveItem::Instance {
            id: "zulip".to_owned(),
            source,
            target,
            policy: crate::workflow::InstanceMovePolicy::default(),
        };
        let mut transaction = Transaction::new_instance(
            "zulip".to_owned(),
            "controller".to_owned(),
            "controller".to_owned(),
            PathBuf::from("/config.json"),
        )
        .unwrap();
        transaction.pending_action = Some(Action::Prepare);
        transaction.active_step = Some("hold-source".to_owned());
        transaction.active_job_id = Some("move-prepare-hold-source".to_owned());
        let mut native = NativeAdapter::from_config(config);
        let mut adapter = WorkflowItemAdapter::new(&mut native, &item);

        adapter.run("hold-source", &mut transaction).unwrap();

        assert_eq!(transaction.source_was_active, Some(true));
        let calls = fs::read_to_string(log).unwrap();
        assert!(calls.contains("--operation reserve"));
        assert!(calls.contains("--control-instance"));
        assert!(calls.contains(r#""action":"stop""#));
        assert!(calls.contains("move-prepare-hold-source-reserve-source"));
        assert!(calls.contains("move-prepare-hold-source-inspect-source-before-stop"));
        assert!(calls.contains("move-prepare-hold-source-stop-source"));
    }

    #[test]
    fn failed_broker_job_retry_accepts_only_host_key_enrichment() {
        let existing = serde_json::json!({
            "schema_version": 1,
            "job_id": "move-seed",
            "operation": {
                "kind": "broker_copy",
                "source": {"host": "source", "host_public_keys": []},
                "target": {"host": "target", "host_public_keys": []}
            }
        });
        let desired = serde_json::json!({
            "schema_version": 1,
            "job_id": "move-seed",
            "operation": {
                "kind": "broker_copy",
                "source": {"host": "source", "host_public_keys": ["ssh-ed25519 source"]},
                "target": {"host": "target", "host_public_keys": ["ssh-ed25519 target"]}
            }
        });
        assert!(retry_spec_matches(&existing, &desired));

        let mut drifted = desired.clone();
        drifted["operation"]["target"]["host"] = serde_json::json!("other-target");
        assert!(!retry_spec_matches(&existing, &drifted));
    }

    #[test]
    fn broker_job_retry_rejects_replacing_an_existing_host_key_pin() {
        let existing = serde_json::json!({
            "operation": {
                "source": {"host_public_keys": ["ssh-ed25519 old-source"]},
                "target": {"host_public_keys": ["ssh-ed25519 old-target"]}
            }
        });
        let desired = serde_json::json!({
            "operation": {
                "source": {"host_public_keys": ["ssh-ed25519 new-source"]},
                "target": {"host_public_keys": ["ssh-ed25519 new-target"]}
            }
        });
        assert!(!retry_spec_matches(&existing, &desired));
    }

    #[test]
    fn broker_endpoint_carries_the_key_observed_over_inventory_transport() {
        let temp = tempfile::tempdir().unwrap();
        let ssh = temp.path().join("ssh");
        fs::write(
            &ssh,
            "#!/bin/sh\nprintf '%s\\n' '{\"ok\":true,\"result\":{\"public_key\":\"ssh-ed25519 observed-key\"}}'\n",
        )
        .unwrap();
        fs::set_permissions(&ssh, fs::Permissions::from_mode(0o700)).unwrap();
        let config: HostManagerConfig = serde_json::from_value(serde_json::json!({
            "schema_version": 1,
            "ssh": {"program": ssh},
            "hosts": {
                "source": {
                    "address": "10.0.0.2",
                    "user": "nixbot",
                    "agent_program": "/bin/abird-host-agent",
                    "agent_prefix": ["/bin/sudo", "-n"]
                }
            }
        }))
        .unwrap();

        let endpoint = config.pinned_broker_endpoint("source", true).unwrap();
        assert_eq!(
            endpoint.host_public_keys,
            ["ssh-ed25519 observed-key".to_owned()]
        );
        assert!(
            endpoint
                .agent_prefix
                .iter()
                .any(|argument| argument == "--preserve-env=SSH_AUTH_SOCK")
        );
    }
}
