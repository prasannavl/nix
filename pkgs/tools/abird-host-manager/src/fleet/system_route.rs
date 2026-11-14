//! Pure transport assembly shared by native execution and installed bootstrap.

use super::system::ResolvedHost;
use super::transport::{
    HostTransport, ProxyCommandTemplate, SshEndpoint, SshRoutePlan, TransportRole, plan_proxy_chain,
};
use anyhow::Result;
use std::collections::BTreeMap;

pub(super) fn host_transport(host: &ResolvedHost, local: bool) -> Result<HostTransport> {
    let operator = host
        .operator_user
        .as_ref()
        .map(|user| {
            SshEndpoint::new(
                host.inventory_name.clone(),
                host.target.clone(),
                user.clone(),
                host.operator_port,
                TransportRole::Operator,
                host.operator_key.clone(),
            )
        })
        .transpose()?;
    Ok(HostTransport {
        primary: primary(host)?,
        operator,
        proxy_jump: host.proxy_jump.clone(),
        proxy_command: host
            .proxy_command
            .clone()
            .map(ProxyCommandTemplate::new)
            .transpose()?,
        local,
    })
}

pub(super) fn primary_route(
    host: &ResolvedHost,
    transports: &BTreeMap<String, HostTransport>,
    trim: bool,
) -> Result<SshRoutePlan> {
    let proxy = plan_proxy_chain(transports, host.proxy_jump.as_deref())?;
    let proxy = if trim {
        proxy.with_leading_local_hops_trimmed()
    } else {
        proxy
    };
    let endpoint = primary(host)?;
    Ok(if let Some(command) = &host.proxy_command {
        SshRoutePlan::via_command(endpoint, ProxyCommandTemplate::new(command.clone())?)
    } else if proxy.is_empty() {
        SshRoutePlan::direct(endpoint)
    } else {
        SshRoutePlan::via_chain(endpoint, proxy)
    })
}

fn primary(host: &ResolvedHost) -> Result<SshEndpoint> {
    SshEndpoint::new(
        host.inventory_name.clone(),
        host.target.clone(),
        host.user.clone(),
        host.port,
        TransportRole::Primary,
        host.identity_key.clone(),
    )
}
