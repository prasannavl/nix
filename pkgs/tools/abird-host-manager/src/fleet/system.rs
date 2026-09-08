//! Resolution of inventory defaults into concrete fleet endpoints.

use std::path::PathBuf;

use anyhow::{Result, bail};

use super::cli::Options;
use super::inventory::Inventory;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedHost {
    pub inventory_name: String,
    pub resource: String,
    pub target: String,
    pub user: String,
    pub port: u16,
    pub identity_key: Option<PathBuf>,
    pub known_hosts: Option<String>,
    pub bootstrap_key: Option<PathBuf>,
    pub operator_user: Option<String>,
    pub operator_port: u16,
    pub operator_key: Option<PathBuf>,
    pub age_identity_key: Option<PathBuf>,
    pub proxy_jump: Option<String>,
    pub proxy_command: Option<String>,
}

pub fn resolve_host(
    inventory: &Inventory,
    role_or_host: &str,
    options: &Options,
) -> Result<ResolvedHost> {
    let inventory_name = inventory.host_for_resource(role_or_host)?.to_owned();
    let host = &inventory.hosts[&inventory_name];
    let defaults = &inventory.config.host_defaults;

    let user = host
        .user
        .clone()
        .or_else(|| defaults.user.clone())
        .unwrap_or_else(|| "root".to_owned());
    let identity_key = host
        .identity_key
        .clone()
        .or_else(|| defaults.identity_key.clone());
    let operator_user = host
        .operator_user
        .clone()
        .or_else(|| defaults.operator_user.clone());
    let operator_key = host
        .operator_key
        .clone()
        .or_else(|| defaults.operator_key.clone());

    let user_overridden = options.user.is_some();
    let operator_overridden = options.operator_user.is_some();
    let user = options.user.clone().unwrap_or(user);
    let identity_key =
        options
            .ssh_key
            .clone()
            .or(if user_overridden { None } else { identity_key });
    let operator_user = options.operator_user.clone().or(operator_user);
    let operator_key = options.operator_key.clone().or({
        if operator_overridden {
            None
        } else {
            operator_key
        }
    });
    let port = host.port.unwrap_or(22);
    let operator_port = host
        .bootstrap_port
        .or(host.port)
        .or(defaults.bootstrap_port)
        .unwrap_or(22);
    if port == 0 || operator_port == 0 {
        bail!("host {inventory_name} SSH ports must be positive");
    }
    let bootstrap_key = options
        .bootstrap_key
        .clone()
        .or_else(|| host.bootstrap_key.clone())
        .or_else(|| defaults.bootstrap_key.clone())
        .or_else(|| identity_key.clone());

    Ok(ResolvedHost {
        inventory_name: inventory_name.clone(),
        resource: host.resource(&inventory_name).to_owned(),
        target: host
            .target
            .clone()
            .unwrap_or_else(|| inventory_name.clone()),
        user,
        port,
        identity_key,
        known_hosts: options
            .known_hosts
            .clone()
            .or_else(|| host.known_hosts.clone())
            .or_else(|| defaults.known_hosts.clone()),
        bootstrap_key,
        operator_user,
        operator_port,
        operator_key,
        age_identity_key: host
            .age_identity_key
            .clone()
            .or_else(|| defaults.age_identity_key.clone()),
        proxy_jump: host.proxy_jump.clone(),
        proxy_command: host.proxy_command.clone(),
    })
}
