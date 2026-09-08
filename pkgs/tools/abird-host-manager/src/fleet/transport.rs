//! Pure fleet transport and closure-distribution planning.
//!
//! This module deliberately contains no process, network, or filesystem I/O.
//! Runtime adapters consume these validated plans and retain ownership of the
//! corresponding effects.

use std::collections::BTreeMap;
use std::path::PathBuf;

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TransportRole {
    Primary,
    Operator,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum HostKeyPolicy {
    Strict,
    AcceptNew,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SshEndpoint {
    pub node: String,
    pub host: String,
    pub user: String,
    pub port: u16,
    pub role: TransportRole,
    pub identity: Option<PathBuf>,
}

impl SshEndpoint {
    pub fn new(
        node: impl Into<String>,
        host: impl Into<String>,
        user: impl Into<String>,
        port: u16,
        role: TransportRole,
        identity: Option<PathBuf>,
    ) -> Result<Self> {
        let endpoint = Self {
            node: node.into(),
            host: host.into(),
            user: user.into(),
            port,
            role,
            identity,
        };
        if endpoint.node.is_empty() {
            bail!("SSH endpoint node cannot be empty");
        }
        if endpoint.host.is_empty() {
            bail!("SSH endpoint host cannot be empty");
        }
        if endpoint.user.is_empty() {
            bail!("SSH endpoint user cannot be empty");
        }
        if endpoint.port == 0 {
            bail!("SSH endpoint port must be positive");
        }
        Ok(endpoint)
    }

    pub fn connect_target(&self) -> String {
        format!("{}@{}", self.user, self.host)
    }

    pub fn forward_destination(&self) -> String {
        if self.host.contains(':') && !(self.host.starts_with('[') && self.host.ends_with(']')) {
            format!("[{}]:{}", self.host, self.port)
        } else {
            format!("{}:{}", self.host, self.port)
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct ProxyCommandTemplate(String);

impl ProxyCommandTemplate {
    pub fn new(template: impl Into<String>) -> Result<Self> {
        let template = template.into();
        if template.is_empty() {
            bail!("proxy command template cannot be empty");
        }
        Ok(Self(template))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn render(&self, host: &str, port: u16) -> String {
        self.0.replace("%h", host).replace("%p", &port.to_string())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostTransport {
    pub primary: SshEndpoint,
    pub operator: Option<SshEndpoint>,
    pub proxy_jump: Option<String>,
    pub proxy_command: Option<ProxyCommandTemplate>,
    pub local: bool,
}

impl HostTransport {
    fn validate_for_node(&self, node: &str) -> Result<()> {
        if self.primary.node != node {
            bail!(
                "primary endpoint node {} does not match {node}",
                self.primary.node
            );
        }
        if self.primary.role != TransportRole::Primary {
            bail!("primary endpoint must use primary role for {node}");
        }
        if let Some(operator) = &self.operator {
            if operator.node != node {
                bail!(
                    "operator endpoint node {} does not match {node}",
                    operator.node
                );
            }
            if operator.role != TransportRole::Operator {
                bail!("operator endpoint must use operator role for {node}");
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProxyHop {
    pub node: String,
    pub endpoint: SshEndpoint,
    pub proxy_command: Option<ProxyCommandTemplate>,
    pub local: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProxyPlan {
    pub hops: Vec<ProxyHop>,
}

impl ProxyPlan {
    pub fn with_leading_local_hops_trimmed(mut self) -> Self {
        let retained_from = self
            .hops
            .iter()
            .position(|hop| !hop.local)
            .unwrap_or(self.hops.len());
        self.hops.drain(..retained_from);
        self
    }

    pub fn is_empty(&self) -> bool {
        self.hops.is_empty()
    }
}

pub fn plan_proxy_chain(
    hosts: &BTreeMap<String, HostTransport>,
    first_hop: Option<&str>,
) -> Result<ProxyPlan> {
    let Some(first_hop) = first_hop else {
        return Ok(ProxyPlan::default());
    };
    if first_hop.is_empty() {
        return Ok(ProxyPlan::default());
    }

    let mut plan = ProxyPlan::default();
    let mut visiting = Vec::new();
    resolve_proxy_hop(first_hop, hosts, &mut visiting, &mut plan.hops)?;
    Ok(plan)
}

fn resolve_proxy_hop(
    node: &str,
    hosts: &BTreeMap<String, HostTransport>,
    visiting: &mut Vec<String>,
    output: &mut Vec<ProxyHop>,
) -> Result<()> {
    if let Some(cycle_start) = visiting.iter().position(|candidate| candidate == node) {
        let mut cycle = visiting[cycle_start..].to_vec();
        cycle.push(node.to_owned());
        bail!("proxy jump cycle detected: {}", cycle.join(" -> "));
    }
    let host = hosts
        .get(node)
        .ok_or_else(|| anyhow::anyhow!("unknown proxy hop {node}"))?;
    host.validate_for_node(node)?;

    visiting.push(node.to_owned());
    if let Some(next) = host.proxy_jump.as_deref().filter(|next| !next.is_empty()) {
        resolve_proxy_hop(next, hosts, visiting, output)?;
    }
    visiting.pop();

    output.push(ProxyHop {
        node: node.to_owned(),
        endpoint: host
            .operator
            .clone()
            .unwrap_or_else(|| host.primary.clone()),
        proxy_command: host.proxy_command.clone(),
        local: host.local,
    });
    Ok(())
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SshRoutePlan {
    pub endpoint: SshEndpoint,
    pub proxy: ProxyPlan,
    pub proxy_command: Option<ProxyCommandTemplate>,
    pub host_key_policy: HostKeyPolicy,
}

impl SshRoutePlan {
    pub fn direct(endpoint: SshEndpoint) -> Self {
        Self {
            endpoint,
            proxy: ProxyPlan::default(),
            proxy_command: None,
            host_key_policy: HostKeyPolicy::Strict,
        }
    }

    pub fn via_chain(endpoint: SshEndpoint, proxy: ProxyPlan) -> Self {
        let host_key_policy = if proxy.is_empty() {
            HostKeyPolicy::Strict
        } else {
            HostKeyPolicy::AcceptNew
        };
        Self {
            endpoint,
            proxy,
            proxy_command: None,
            host_key_policy,
        }
    }

    pub fn via_command(endpoint: SshEndpoint, proxy_command: ProxyCommandTemplate) -> Self {
        Self {
            endpoint,
            proxy: ProxyPlan::default(),
            proxy_command: Some(proxy_command),
            host_key_policy: HostKeyPolicy::AcceptNew,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProcessStatus {
    Code(i32),
    Signal(i32),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FailureClass {
    Signal(i32),
    HostKeyVerification,
    Timeout,
    TransportLoss,
    DaemonDisconnected,
    Permanent,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FailureEvidence {
    pub status: ProcessStatus,
    pub output: String,
}

impl FailureEvidence {
    pub fn new(status: ProcessStatus, output: impl Into<String>) -> Self {
        Self {
            status,
            output: output.into(),
        }
    }

    pub fn classify(&self) -> FailureClass {
        if let ProcessStatus::Signal(signal) = self.status {
            return FailureClass::Signal(signal);
        }
        if contains_host_key_failure(&self.output) {
            return FailureClass::HostKeyVerification;
        }
        if contains_daemon_disconnect(&self.output) {
            return FailureClass::DaemonDisconnected;
        }
        if self.status == ProcessStatus::Code(124) {
            return FailureClass::Timeout;
        }
        if self.status == ProcessStatus::Code(255) || contains_transport_loss(&self.output) {
            return FailureClass::TransportLoss;
        }
        FailureClass::Permanent
    }

    pub fn is_pre_admission_ssh_failure(&self) -> bool {
        if matches!(self.status, ProcessStatus::Signal(_))
            || contains_host_key_failure(&self.output)
        {
            return false;
        }
        self.output
            .contains("Connection timed out during banner exchange")
            || ((self.output.contains("ssh: connect to host ")
                || self.output.contains("connect to host "))
                && [
                    "Connection refused",
                    "Connection timed out",
                    "No route to host",
                    "Network is unreachable",
                ]
                .iter()
                .any(|message| self.output.contains(message)))
            || self.output.contains("kex_exchange_identification")
            || self.output.contains("ssh_exchange_identification")
    }
}

fn contains_host_key_failure(output: &str) -> bool {
    output.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")
        || output.contains("Host key verification failed")
        || (output.contains("Offending ") && output.contains(" key in "))
}

fn contains_daemon_disconnect(output: &str) -> bool {
    output.contains("Nix daemon disconnected unexpectedly")
        || (output.contains("cannot connect to socket at ")
            && output.contains("nix/daemon-socket/socket"))
}

fn contains_transport_loss(output: &str) -> bool {
    [
        "failed to start SSH connection",
        "mux_client_request_session",
        "kex_exchange_identification",
        "ssh_exchange_identification",
        "Connection reset by peer",
        "Connection closed by remote host",
        "Received disconnect",
        "client_loop: send disconnect: Broken pipe",
        "Broken pipe",
        "Bad file descriptor",
        "stdio forwarding failed",
        "Connection timed out",
        "No route to host",
    ]
    .iter()
    .any(|message| output.contains(message))
        || (output.contains("Connection closed by ") && output.contains(" port "))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetryScope {
    Transport,
    RemoteStore,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RetryPolicy {
    max_attempts: u32,
    base_delay_seconds: u64,
}

impl RetryPolicy {
    pub fn new(max_attempts: u32, base_delay_seconds: u64) -> Result<Self> {
        if max_attempts == 0 {
            bail!("retry policy must allow at least one attempt");
        }
        Ok(Self {
            max_attempts,
            base_delay_seconds,
        })
    }

    pub fn decide(
        &self,
        failure: &FailureEvidence,
        scope: RetryScope,
        completed_attempts: u32,
    ) -> RetryDecision {
        let class = failure.classify();
        let status_retryable = matches!(failure.status, ProcessStatus::Code(124 | 255));
        let remote_store_retryable = scope == RetryScope::RemoteStore
            && matches!(
                class,
                FailureClass::TransportLoss | FailureClass::DaemonDisconnected
            );
        let protected = matches!(
            class,
            FailureClass::Signal(_) | FailureClass::HostKeyVerification
        );
        if protected
            || (!status_retryable && !remote_store_retryable)
            || completed_attempts >= self.max_attempts
        {
            return RetryDecision::Stop(class);
        }

        let next_attempt = completed_attempts.saturating_add(1);
        RetryDecision::RetryAfter {
            next_attempt,
            delay_seconds: self
                .base_delay_seconds
                .saturating_mul(u64::from(next_attempt.saturating_sub(1))),
            failure: class,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RetryDecision {
    RetryAfter {
        next_attempt: u32,
        delay_seconds: u64,
        failure: FailureClass,
    },
    Stop(FailureClass),
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SelfTargetMode {
    Auto,
    On,
    Off,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SelfTargetEvidence {
    pub alias_matches: bool,
    pub address_matches: bool,
    pub effective_uid: u32,
    pub current_user: String,
    pub deploy_user: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SelfTargetRemoteReason {
    Disabled,
    NotThisHost,
    UnauthorizedUser,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SelfTargetDecision {
    Local,
    Remote(SelfTargetRemoteReason),
}

pub fn plan_self_target(mode: SelfTargetMode, evidence: &SelfTargetEvidence) -> SelfTargetDecision {
    let matches = match mode {
        SelfTargetMode::Off => {
            return SelfTargetDecision::Remote(SelfTargetRemoteReason::Disabled);
        }
        SelfTargetMode::On => true,
        SelfTargetMode::Auto => evidence.alias_matches || evidence.address_matches,
    };
    if !matches {
        return SelfTargetDecision::Remote(SelfTargetRemoteReason::NotThisHost);
    }
    if evidence.effective_uid == 0
        || (!evidence.deploy_user.is_empty() && evidence.current_user == evidence.deploy_user)
    {
        SelfTargetDecision::Local
    } else {
        SelfTargetDecision::Remote(SelfTargetRemoteReason::UnauthorizedUser)
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum CacheTransferPolicy {
    Auto,
    Cache,
    LocalCopy,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BuildLocation {
    Local,
    Remote { resource: String },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CacheEndpoint {
    pub owner_resource: String,
    pub url: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DistributionInput {
    pub mode: CacheTransferPolicy,
    pub build: BuildLocation,
    pub target_resource: String,
    pub target_is_local: bool,
    pub cache: Option<CacheEndpoint>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CacheFallback {
    LocalRelay,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DistributionPlan {
    SameStoreVerify,
    LocalCopy,
    TargetCache {
        cache: CacheEndpoint,
        retry_transport: bool,
        fallback: Option<CacheFallback>,
    },
    LocalRelay {
        cache: CacheEndpoint,
    },
}

impl DistributionPlan {
    pub fn fallback_after(&self, failure: &FailureClass) -> Option<CacheFallback> {
        match self {
            Self::TargetCache {
                fallback: Some(fallback),
                ..
            } if !matches!(failure, FailureClass::Signal(_)) => Some(*fallback),
            _ => None,
        }
    }
}

pub fn plan_cache_distribution(input: &DistributionInput) -> Result<DistributionPlan> {
    if input.target_resource.is_empty() {
        bail!("target resource cannot be empty");
    }
    let BuildLocation::Remote { resource } = &input.build else {
        return Ok(DistributionPlan::LocalCopy);
    };
    if resource.is_empty() {
        bail!("remote build resource cannot be empty");
    }
    if resource == &input.target_resource {
        return Ok(DistributionPlan::SameStoreVerify);
    }

    let cache = input
        .cache
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("remote build distribution requires a configured cache"))?;
    if cache.owner_resource != *resource {
        bail!("configured cache is not owned by remote build resource {resource}");
    }
    if cache.url.is_empty() {
        bail!("remote build cache URL cannot be empty");
    }

    match input.mode {
        CacheTransferPolicy::Auto => Ok(DistributionPlan::TargetCache {
            cache: cache.clone(),
            retry_transport: false,
            fallback: (!input.target_is_local).then_some(CacheFallback::LocalRelay),
        }),
        CacheTransferPolicy::Cache => Ok(DistributionPlan::TargetCache {
            cache: cache.clone(),
            retry_transport: true,
            fallback: None,
        }),
        CacheTransferPolicy::LocalCopy => Ok(DistributionPlan::LocalRelay {
            cache: cache.clone(),
        }),
    }
}
