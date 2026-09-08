use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum DeployMode {
    #[default]
    Strict,
    Optional,
    Skip,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Host {
    #[serde(default)]
    pub target: Option<String>,
    #[serde(default)]
    pub user: Option<String>,
    #[serde(default, alias = "key")]
    pub identity_key: Option<PathBuf>,
    #[serde(default)]
    pub known_hosts: Option<String>,
    #[serde(default)]
    pub age_identity_key: Option<PathBuf>,
    #[serde(default)]
    pub operator_user: Option<String>,
    #[serde(default)]
    pub operator_key: Option<PathBuf>,
    #[serde(default)]
    pub bootstrap_key: Option<PathBuf>,
    #[serde(default)]
    pub bootstrap_port: Option<u16>,
    #[serde(default)]
    pub proxy_jump: Option<String>,
    #[serde(default)]
    pub proxy_command: Option<String>,
    #[serde(default)]
    pub port: Option<u16>,
    #[serde(default)]
    pub groups: Vec<String>,
    #[serde(default)]
    pub deps: Vec<String>,
    #[serde(default)]
    pub after: Vec<String>,
    #[serde(default)]
    pub parent: Option<String>,
    #[serde(default)]
    pub resource_id: Option<String>,
    #[serde(default)]
    pub parent_reconcile_command: Option<String>,
    #[serde(default)]
    pub parent_settle_command: Option<String>,
    #[serde(default)]
    pub wait: u64,
    #[serde(default)]
    pub skip: bool,
    #[serde(default)]
    pub deploy: DeployMode,
    #[serde(default)]
    pub health_check: HealthCheck,
}

impl Host {
    pub fn resource<'a>(&'a self, inventory_name: &'a str) -> &'a str {
        self.resource_id.as_deref().unwrap_or(inventory_name)
    }

    pub fn positive_groups(&self) -> impl Iterator<Item = &str> {
        self.groups
            .iter()
            .map(String::as_str)
            .filter(|group| !group.starts_with('-'))
    }

    pub fn negative_groups(&self) -> impl Iterator<Item = &str> {
        self.groups
            .iter()
            .filter_map(|group| group.strip_prefix('-'))
    }
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HealthCheck {
    #[serde(default)]
    pub ignore: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostDefaults {
    #[serde(default)]
    pub user: Option<String>,
    #[serde(default, alias = "key")]
    pub identity_key: Option<PathBuf>,
    #[serde(default)]
    pub known_hosts: Option<String>,
    #[serde(default)]
    pub age_identity_key: Option<PathBuf>,
    #[serde(default)]
    pub operator_user: Option<String>,
    #[serde(default)]
    pub operator_key: Option<PathBuf>,
    #[serde(default)]
    pub bootstrap_key: Option<PathBuf>,
    #[serde(default)]
    pub bootstrap_port: Option<u16>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Registry {
    pub host: String,
    pub url: String,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeployConfig {
    #[serde(default)]
    pub default_group: Option<String>,
    #[serde(default)]
    pub default_hosts: Option<String>,
    #[serde(default)]
    pub host_defaults: HostDefaults,
    #[serde(default)]
    pub controller: Option<String>,
    #[serde(default)]
    pub transfer_broker: Option<String>,
    #[serde(default)]
    pub builders: Vec<String>,
    #[serde(default)]
    pub registries: BTreeMap<String, Registry>,
    #[serde(default)]
    pub build_cache: Option<Registry>,
    #[serde(default)]
    pub repo_url: Option<String>,
    #[serde(default)]
    pub deploy_deps_key: Option<String>,
    #[serde(default)]
    pub deploy_jobs_per_domain: Option<usize>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct Inventory {
    #[serde(default)]
    pub hosts: BTreeMap<String, Host>,
    #[serde(default)]
    pub config: DeployConfig,
}

impl Inventory {
    pub fn validate(&self) -> Result<()> {
        if self.hosts.is_empty() {
            bail!("hosts must contain at least one host");
        }
        for (name, host) in &self.hosts {
            validate_host_name(name)?;
            for group in &host.groups {
                if group.is_empty() || group == "-" {
                    bail!("host {name} groups must contain non-empty group names");
                }
            }
            for predecessor in host
                .deps
                .iter()
                .chain(&host.after)
                .chain(host.parent.iter())
            {
                if !self.hosts.contains_key(predecessor) {
                    bail!("host {name} references unknown host {predecessor}");
                }
            }
            let mut ignored = BTreeSet::new();
            for unit in &host.health_check.ignore {
                if unit.is_empty() || unit.chars().any(char::is_whitespace) || !ignored.insert(unit)
                {
                    bail!(
                        "host {name} healthCheck.ignore must be a unique list of non-empty unit names without whitespace"
                    );
                }
            }
        }
        self.validate_ordering_graph()?;
        self.validate_capabilities()?;
        if self.config.deploy_jobs_per_domain == Some(0) {
            bail!("deployJobsPerDomain must be a positive integer");
        }
        Ok(())
    }

    pub fn host_for_resource(&self, name: &str) -> Result<&str> {
        let matching = self
            .hosts
            .iter()
            .filter_map(|(host_name, host)| (host.resource(host_name) == name).then_some(host_name))
            .collect::<Vec<_>>();
        match matching.as_slice() {
            [host] => Ok(host.as_str()),
            [] if self.hosts.contains_key(name) => Ok(self
                .hosts
                .get_key_value(name)
                .expect("checked inventory host exists")
                .0
                .as_str()),
            [] => bail!("unknown inventory host or resource {name}"),
            _ => bail!("resource {name} maps to multiple inventory hosts"),
        }
    }

    pub fn control_plane_hosts(&self) -> Result<Vec<String>> {
        let Some(controller) = self.config.controller.as_deref() else {
            return Ok(Vec::new());
        };
        let mut roles = vec![controller];
        if self.config.registries.is_empty() {
            roles.extend(
                self.config
                    .build_cache
                    .iter()
                    .map(|registry| registry.host.as_str()),
            );
        } else {
            roles.extend(
                self.config
                    .registries
                    .values()
                    .map(|registry| registry.host.as_str()),
            );
        }

        let mut seen = BTreeSet::new();
        let mut hosts = Vec::new();
        for role in roles {
            let host = self.host_for_resource(role)?;
            if seen.insert(host) {
                hosts.push(host.to_owned());
            }
        }
        Ok(hosts)
    }

    pub fn apply_deploy_dependencies(
        &mut self,
        dependencies: BTreeMap<String, Vec<String>>,
    ) -> Result<()> {
        for (host, predecessors) in dependencies {
            if !self.hosts.contains_key(&host) {
                bail!("deploy dependencies name unknown controller host {host}");
            }
            for predecessor in &predecessors {
                if predecessor.is_empty() {
                    bail!("deploy dependencies for {host} contain an empty host name");
                }
                if !self.hosts.contains_key(predecessor) {
                    bail!("deploy dependencies for {host} name unknown host {predecessor}");
                }
            }
            let configured = &mut self
                .hosts
                .get_mut(&host)
                .expect("validated dependency target exists")
                .deps;
            configured.extend(predecessors);
            configured.sort();
            configured.dedup();
        }
        self.validate()
    }

    fn validate_capabilities(&self) -> Result<()> {
        let configured = self.config.controller.is_some()
            || self.config.transfer_broker.is_some()
            || !self.config.builders.is_empty()
            || !self.config.registries.is_empty();
        if !configured {
            return Ok(());
        }
        let controller = required_nonempty(self.config.controller.as_deref(), "controller")?;
        let broker = required_nonempty(self.config.transfer_broker.as_deref(), "transferBroker")?;
        self.host_for_resource(controller)?;
        self.host_for_resource(broker)?;
        if self.config.builders.is_empty() {
            bail!("capability config requires at least one builder");
        }
        let mut builders = BTreeSet::new();
        for builder in &self.config.builders {
            if !builders.insert(builder) {
                bail!("capability config contains duplicate builder {builder}");
            }
            self.host_for_resource(builder)?;
        }
        let nix = self
            .config
            .registries
            .get("nix")
            .ok_or_else(|| anyhow::anyhow!("capability config requires registries.nix"))?;
        for (name, registry) in &self.config.registries {
            if registry.host.is_empty() || registry.url.is_empty() {
                bail!("registry {name} requires a non-empty host and url");
            }
            self.host_for_resource(&registry.host)?;
        }
        if nix.url.is_empty() {
            bail!("registries.nix.url cannot be empty");
        }
        Ok(())
    }

    fn validate_ordering_graph(&self) -> Result<()> {
        fn visit(
            inventory: &Inventory,
            name: &str,
            visiting: &mut BTreeSet<String>,
            visited: &mut BTreeSet<String>,
        ) -> Result<()> {
            if visited.contains(name) {
                return Ok(());
            }
            if !visiting.insert(name.to_owned()) {
                bail!("host dependency cycle detected at {name}");
            }
            let host = &inventory.hosts[name];
            for predecessor in host
                .deps
                .iter()
                .chain(&host.after)
                .chain(host.parent.iter())
            {
                visit(inventory, predecessor, visiting, visited)?;
            }
            visiting.remove(name);
            visited.insert(name.to_owned());
            Ok(())
        }

        let mut visiting = BTreeSet::new();
        let mut visited = BTreeSet::new();
        for name in self.hosts.keys() {
            visit(self, name, &mut visiting, &mut visited)?;
        }
        Ok(())
    }
}

fn required_nonempty<'a>(value: Option<&'a str>, name: &str) -> Result<&'a str> {
    match value {
        Some(value) if !value.is_empty() => Ok(value),
        _ => bail!("capability config requires {name}"),
    }
}

pub fn validate_host_name(name: &str) -> Result<()> {
    let valid = !name.is_empty()
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        && name
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
        && name
            .as_bytes()
            .last()
            .is_some_and(u8::is_ascii_alphanumeric);
    if !valid {
        bail!(
            "host name must start and end with a letter or number and contain only letters, numbers, and hyphens: {name}"
        );
    }
    Ok(())
}
