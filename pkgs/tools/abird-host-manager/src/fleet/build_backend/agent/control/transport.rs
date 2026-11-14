//! Installed public-protocol transport. Fixed remote verbs, raw bounded stdin;
//! never root elevation, source-in-argv, shared SSH masters or effect retries.

use std::process::Command;
use std::time::{Duration, Instant};

use abird_host_agent::build_executor::{process, protocol, source_transport};
use anyhow::{Result, ensure};

use crate::fleet::host_runtime::{HostExecutionTarget, ssh_connection_args_without_control_master};

const AGENT: &str = "/run/current-system/sw/bin/abird-host-agent";
const SSH: &str = "/run/current-system/sw/bin/ssh";

pub trait Transport {
    /// Local authenticated capture control, never a builder SSH/control relay.
    fn capture(
        &mut self,
        _command: &abird_host_agent::build_executor::capture_role::Command,
    ) -> Result<abird_host_agent::build_executor::capture_role::Reply> {
        anyhow::bail!("installed caller capture transport unavailable")
    }

    fn request(
        &mut self,
        target: &HostExecutionTarget,
        request: &protocol::Request,
    ) -> Result<protocol::Response>;
    fn inputs(
        &mut self,
        target: &HostExecutionTarget,
        request: &abird_host_agent::build_executor::request::BuildRequest,
        bytes: &[u8],
    ) -> Result<Option<source_transport::Receipt>>;
    fn native_inputs(
        &mut self,
        _target: &HostExecutionTarget,
        _request: &abird_host_agent::build_executor::native_intent::Request,
        _bytes: &[u8],
    ) -> Result<Option<source_transport::Receipt>> {
        anyhow::bail!("native source transport unavailable")
    }
}

#[derive(Default)]
pub struct Installed {
    observation_deadline: Option<Instant>,
    capture_scope:
        Option<std::sync::Arc<abird_host_agent::build_executor::capture_role::TransportScope>>,
    capture_account: Option<abird_host_agent::build_executor::controller_service::Account>,
    relay_port: Option<u16>,
}

impl Installed {
    /// Trusted caller-role transport, separate from every offline source stage.
    /// None account is reserved for its root-only, input-only relay credential.
    pub(crate) fn for_capture(
        scope: std::sync::Arc<abird_host_agent::build_executor::capture_role::TransportScope>,
        account: Option<abird_host_agent::build_executor::controller_service::Account>,
    ) -> Result<Self> {
        ensure!(
            unsafe { libc::geteuid() } == 0,
            "capture transport requires its installed wrapper"
        );
        Ok(Self {
            observation_deadline: None,
            capture_scope: Some(scope),
            capture_account: account,
            relay_port: None,
        })
    }

    pub(crate) fn for_relay(
        scope: std::sync::Arc<abird_host_agent::build_executor::capture_role::TransportScope>,
        port: u16,
    ) -> Result<Self> {
        ensure!(port > 0, "invalid capture relay port");
        let mut value = Self::for_capture(scope, None)?;
        value.relay_port = Some(port);
        Ok(value)
    }

    pub(crate) fn for_capture_reaper(
        account: abird_host_agent::build_executor::controller_service::Account,
    ) -> Result<Self> {
        abird_host_agent::build_executor::capture_role::require_reaper_placement()?;
        Ok(Self {
            observation_deadline: None,
            capture_scope: None,
            capture_account: Some(account),
            relay_port: None,
        })
    }

    /// One local observation window across all children/RPCs, not a new remote
    /// ownership deadline. Later polling cannot extend this window.
    pub fn observe_until(&mut self, deadline: Instant) {
        self.observation_deadline = Some(
            self.observation_deadline
                .map_or(deadline, |old| old.min(deadline)),
        );
    }

    fn connected(&self) -> Result<()> {
        crate::fleet::signal::check_interrupted()?;
        if let Some(scope) = &self.capture_scope {
            scope.active()?;
        }
        ensure!(
            self.observation_deadline
                .is_none_or(|deadline| Instant::now() < deadline),
            "observation ended without settlement; reconnect to the same run"
        );
        Ok(())
    }

    fn deadline(&self, seconds: u64) -> Instant {
        let deadline = Instant::now() + Duration::from_secs(seconds.min(30));
        self.observation_deadline
            .map_or(deadline, |outer| deadline.min(outer))
    }

    fn invoke(
        &self,
        target: &HostExecutionTarget,
        arguments: &[&str],
        input: &[u8],
        input_limit: usize,
        output_limit: usize,
    ) -> Result<Vec<u8>> {
        self.connected()?;
        ensure!(
            target.cwd.is_absolute() && target.remote_read_timeout_seconds > 0,
            "invalid owned caller context"
        );
        // Only fixed flags and validated hexadecimal identities reach the remote
        // login shell. Request JSON/capabilities/data remain on stdin.
        ensure!(
            arguments.iter().all(|arg| !arg.is_empty()
                && arg
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')),
            "invalid owned remote argument"
        );
        let privileged_relay = self.capture_scope.is_some() && self.capture_account.is_none();
        if self.capture_scope.is_some() || self.capture_account.is_some() {
            abird_host_agent::build_executor::capture_role::trusted_ssh_program(
                std::path::Path::new(SSH),
            )?;
            abird_host_agent::build_executor::capture_role::trusted_ssh_file(
                target
                    .known_hosts_file
                    .as_deref()
                    .ok_or_else(|| anyhow::anyhow!("capture host trust missing"))?,
                false,
            )?;
        }
        if privileged_relay {
            abird_host_agent::build_executor::capture_role::trusted_ssh_file(
                target
                    .route
                    .endpoint
                    .identity
                    .as_deref()
                    .ok_or_else(|| anyhow::anyhow!("capture relay key missing"))?,
                true,
            )?;
        }
        ensure!(
            privileged_relay == self.relay_port.is_some(),
            "capture relay endpoint is not installed"
        );
        let mut command = installed_command(target, arguments, self.relay_port)?;
        // Control/data framing never depends on the continued existence of the
        // caller checkout. All credential and host-trust references are absolute.
        command.current_dir("/var/empty");
        if let Some(scope) = &self.capture_scope {
            scope.configure(&mut command);
        }
        if self.capture_scope.is_some() || self.capture_account.is_some() {
            command
                .env_clear()
                .env("LC_ALL", "C")
                .env("PATH", "/run/current-system/sw/bin");
            if let Some(account) = &self.capture_account {
                command.env("HOME", &account.home);
                abird_host_agent::build_executor::capture_role::caller_credentials(
                    &mut command,
                    account,
                );
            } else {
                command.env("HOME", "/var/empty");
            }
        }
        // Authenticated source delivery is bounded by its original capture
        // lifetime and live owner watcher, not a small metadata-RPC timeout.
        let deadline = if privileged_relay {
            self.observation_deadline
                .ok_or_else(|| anyhow::anyhow!("input relay lacks its original deadline"))?
        } else {
            self.deadline(target.remote_read_timeout_seconds)
        };
        ensure!(
            input.len() <= input_limit,
            "owned transport input exceeds bound"
        );
        let limits = process::Limits {
            stdin: input.len(),
            stdout: output_limit,
            stderr: 64 * 1024,
        };
        let observation = if let Some(scope) = &self.capture_scope {
            process::transport::exchange_capture_while(
                &mut command,
                input,
                limits,
                deadline,
                scope,
                || self.connected(),
            )?
        } else {
            process::transport::exchange_while(&mut command, input, limits, deadline, || {
                self.connected()
            })?
        };
        Ok(observation.stdout)
    }
}

/// An immutable bootstrap is not an executable closure qualification: its
/// ProxyCommand may name a caller-writable helper or dependency. The installed
/// capture policy currently approves direct SSH only. Do not strip/rewrite a
/// requested proxy route into some different reachable endpoint.
pub(crate) fn require_root_relay_route(target: &HostExecutionTarget) -> Result<()> {
    ensure!(
        !target.local
            && target.route.proxy_command.is_none()
            && target.route.proxy.hops.is_empty()
            && target.route.host_key_policy == crate::fleet::transport::HostKeyPolicy::Strict
            && target.known_hosts_file.is_some(),
        "privileged capture relay requires direct pinned SSH; proxy authority is not root-qualified"
    );
    ensure!(
        !target.route.endpoint.host.is_empty()
            && target.route.endpoint.host.len() <= 255
            && target
                .route
                .endpoint
                .host
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b".-_:%".contains(&byte)),
        "capture SSH host must be a literal direct endpoint"
    );
    abird_host_agent::build_executor::capture_role::validate_ssh_path(
        target
            .known_hosts_file
            .as_deref()
            .ok_or_else(|| anyhow::anyhow!("capture host trust missing"))?,
    )?;
    Ok(())
}

fn installed_command(
    target: &HostExecutionTarget,
    arguments: &[&str],
    relay_port: Option<u16>,
) -> Result<Command> {
    // This guard precedes SSH argv/proxy rendering and any process creation.
    if let Some(port) = relay_port {
        require_root_relay_route(target)?;
        ensure!(
            port > 0 && port != target.route.endpoint.port,
            "capture requires a distinct admitted input port"
        );
    }
    if target.local {
        let mut command = Command::new(AGENT);
        command.args(arguments);
        return Ok(command);
    }
    let mut command = Command::new(SSH);
    let mut endpoint = target.clone();
    if let Some(port) = relay_port {
        endpoint.route.endpoint.port = port;
    }
    command.args(ssh_connection_args_without_control_master(&endpoint)?);
    if relay_port.is_some() {
        // Same authenticated builder host key as control, on the explicitly
        // installed data endpoint. No new TOFU/pin or route/helper selection.
        let host = &target.route.endpoint.host;
        let alias = if target.route.endpoint.port == 22 {
            host.clone()
        } else {
            format!("[{host}]:{}", target.route.endpoint.port)
        };
        command.args(["-o", &format!("HostKeyAlias={alias}")]);
    }
    command.args([
        "-T",
        "-o",
        "ForwardAgent=no",
        "-o",
        "ClearAllForwardings=yes",
        "--",
    ]);
    command.arg(target.route.endpoint.connect_target());
    command.arg(format!("exec {AGENT} {}", arguments.join(" ")));
    Ok(command)
}

impl Transport for Installed {
    fn capture(
        &mut self,
        command: &abird_host_agent::build_executor::capture_role::Command,
    ) -> Result<abird_host_agent::build_executor::capture_role::Reply> {
        use abird_host_agent::build_executor::capture_role;
        ensure!(
            self.capture_scope.is_none(),
            "nested capture control is forbidden"
        );
        let deadline = self
            .observation_deadline
            .unwrap_or_else(|| Instant::now() + Duration::from_secs(3));
        Ok(capture_role::client_until(command, deadline)
            .unwrap_or(capture_role::Reply::Unconfirmed))
    }

    fn request(
        &mut self,
        target: &HostExecutionTarget,
        request: &protocol::Request,
    ) -> Result<protocol::Response> {
        self.connected()?;
        let bytes = serde_json::to_vec(request)?;
        protocol::Request::decode(&bytes)?;
        let output = self.invoke(
            target,
            &["--json", "owned-build", "request"],
            &bytes,
            protocol::MAX_FRAME_BYTES,
            protocol::MAX_FRAME_BYTES + 1,
        );
        let response = output
            .ok()
            .and_then(|bytes| {
                protocol::Response::decode(bytes.strip_suffix(b"\n").unwrap_or(&bytes)).ok()
            })
            .filter(|response| response.validate_for(request).is_ok());
        Ok(response.unwrap_or_else(super::unavailable))
    }

    fn inputs(
        &mut self,
        target: &HostExecutionTarget,
        request: &abird_host_agent::build_executor::request::BuildRequest,
        bytes: &[u8],
    ) -> Result<Option<source_transport::Receipt>> {
        self.connected()?;
        abird_host_agent::build_executor::preparation::source::Material::decode(bytes, request)?;
        self.deliver(target, request.attempt_id()?, request.digest()?, bytes)
    }

    fn native_inputs(
        &mut self,
        target: &HostExecutionTarget,
        request: &abird_host_agent::build_executor::native_intent::Request,
        bytes: &[u8],
    ) -> Result<Option<source_transport::Receipt>> {
        self.connected()?;
        abird_host_agent::build_executor::native_intent::Delivery::decode(bytes, request)?;
        self.deliver(target, request.attempt_id()?, request.digest()?, bytes)
    }
}

impl Installed {
    fn deliver(
        &self,
        target: &HostExecutionTarget,
        attempt: String,
        digest: String,
        bytes: &[u8],
    ) -> Result<Option<source_transport::Receipt>> {
        let output = self.invoke(
            target,
            &[
                "--json",
                "owned-build",
                "inputs",
                &attempt,
                "--request-digest",
                &digest,
                "--length",
                &bytes.len().to_string(),
            ],
            bytes,
            abird_host_agent::build_executor::preparation::source::MAX_MATERIAL_BYTES,
            513,
        );
        let receipt = output
            .ok()
            .and_then(|bytes| serde_json::from_slice::<source_transport::Receipt>(&bytes).ok());
        Ok(receipt.filter(|receipt| {
            receipt.version == 1
                && receipt.attempt_id == attempt
                && receipt.request_digest == digest
                && receipt.material_digest == abird_host_agent::sha256::digest_bytes(bytes)
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn caller_writable_uid_proxy_is_rejected_before_privileged_command_creation() {
        use crate::fleet::transport::{
            HostKeyPolicy, ProxyCommandTemplate, ProxyHop, SshEndpoint, SshRoutePlan, TransportRole,
        };
        let scratch = tempfile::tempdir().unwrap();
        let proxy = scratch.path().join("caller-proxy");
        let marker = scratch.path().join("executed-uid");
        // Disposable writable helper: report UID only, no real credential reads.
        std::fs::write(&proxy, b"id -u > \"$1\"\n").unwrap();
        assert!(
            Command::new("sh")
                .arg(&proxy)
                .arg(&marker)
                .status()
                .unwrap()
                .success()
        );
        assert_eq!(
            std::fs::read_to_string(&marker).unwrap().trim(),
            unsafe { libc::geteuid() }.to_string()
        );
        std::fs::remove_file(&marker).unwrap();
        let endpoint = SshEndpoint::new(
            "builder",
            "192.0.2.1",
            "input-relay",
            22,
            TransportRole::Primary,
            None,
        )
        .unwrap();
        let mut route = SshRoutePlan::direct(endpoint.clone());
        route.host_key_policy = HostKeyPolicy::Strict;
        let mut target = HostExecutionTarget {
            route,
            cwd: "/var/empty".into(),
            known_hosts_file: Some(scratch.path().join("known-hosts")),
            local: false,
            ssh_connect_timeout_seconds: 1,
            ssh_server_alive_interval_seconds: 1,
            ssh_server_alive_count_max: 1,
            remote_read_timeout_seconds: 1,
            control_master: None,
        };
        let direct =
            installed_command(&target, &["--json", "owned-build", "inputs"], Some(2022)).unwrap();
        assert_eq!(direct.get_program(), SSH);
        let args = direct
            .get_args()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert!(args.windows(2).any(|args| args == ["-p", "2022"]));
        assert!(args.iter().any(|arg| arg == "HostKeyAlias=192.0.2.1"));
        assert!(
            !direct
                .get_args()
                .any(|arg| arg.to_string_lossy().contains("ProxyCommand="))
        );
        let template =
            ProxyCommandTemplate::new(format!("sh '{}' '{}'", proxy.display(), marker.display()))
                .unwrap();
        target.route.proxy_command = Some(template.clone());
        assert!(installed_command(&target, &["--json"], Some(2022)).is_err());
        assert!(!marker.exists());
        target.route.proxy_command = None;
        target.route.proxy.hops.push(ProxyHop {
            node: "jump".into(),
            endpoint,
            proxy_command: Some(template),
            local: false,
        });
        assert!(installed_command(&target, &["--json"], Some(2022)).is_err());
        assert!(!marker.exists());
        // Mechanical jump SSH also needs separately qualified root credentials;
        // absence of an explicit helper is not an implicit approval.
        target.route.proxy.hops[0].proxy_command = None;
        assert!(installed_command(&target, &["--json"], Some(2022)).is_err());
        assert!(!marker.exists());
    }

    #[test]
    fn polling_and_data_delivery_share_a_nonrenewable_observation_window() {
        let mut transport = Installed::default();
        let original = Instant::now() + Duration::from_secs(5);
        transport.observe_until(original);
        assert_eq!(transport.deadline(30), original);
        transport.observe_until(original + Duration::from_secs(60));
        assert_eq!(transport.deadline(30), original);
        assert!(transport.deadline(1) < original);
        let expired = Instant::now();
        transport.observe_until(expired);
        assert_eq!(transport.deadline(30), expired);
        assert!(transport.connected().is_err());
        transport.observe_until(original);
        assert!(transport.connected().is_err());
    }
}
