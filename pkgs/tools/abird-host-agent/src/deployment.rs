use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

pub const UNCOMMITTED_CONTROLLER_REVISION: &str = "UNCOMMITTED-CONTROLLER-GENERATION";

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivationMode {
    Switch,
    Test,
    Boot,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DeploymentDefinition {
    pub system: PathBuf,
    pub mode: ActivationMode,
}

#[derive(Debug, Serialize)]
pub struct DeploymentResult {
    pub system: PathBuf,
    pub program: PathBuf,
    pub mode: ActivationMode,
    pub exit_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct NixbotDeployPolicy {
    pub program: PathBuf,
    pub runuser_program: PathBuf,
    pub env_program: PathBuf,
    pub user: String,
    pub home: PathBuf,
    pub repository_url: String,
    pub repository_path: PathBuf,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub repository_ssh_key_paths: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub config_override_path: Option<PathBuf>,
    pub revision: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct NixbotDeployRequest {
    pub host: String,
    #[serde(default)]
    pub nix_config: Option<String>,
    #[serde(default)]
    pub exclude_hosts: Vec<String>,
}

pub fn validate_deployment(deployment: &DeploymentDefinition) -> Result<()> {
    if !deployment.system.is_absolute()
        || !deployment.system.starts_with("/nix/store")
        || deployment.system == Path::new("/nix/store")
    {
        bail!("deployment system must be a concrete absolute /nix/store path");
    }
    Ok(())
}

pub fn validate_nixbot_deploy_policy(policy: &NixbotDeployPolicy) -> Result<()> {
    for (label, path) in [
        ("Nixbot", &policy.program),
        ("runuser", &policy.runuser_program),
        ("env", &policy.env_program),
        ("home", &policy.home),
        ("repository", &policy.repository_path),
    ] {
        if !path.is_absolute() {
            bail!("{label} path must be absolute");
        }
    }
    if !is_safe_name(&policy.user) {
        bail!("Nixbot deployment user is invalid");
    }
    if policy.repository_url.trim().is_empty() || policy.repository_url.contains(['\0', '\r', '\n'])
    {
        bail!("Nixbot repository URL is invalid");
    }
    for path in &policy.repository_ssh_key_paths {
        if !path.is_absolute() || path.as_os_str().as_encoded_bytes().contains(&b':') {
            bail!("Nixbot repository SSH identity path must be absolute and cannot contain ':'");
        }
    }
    if policy
        .config_override_path
        .as_ref()
        .is_some_and(|path| !path.is_absolute())
    {
        bail!("Nixbot configuration override path must be absolute");
    }
    if !is_commit_revision(&policy.revision) && policy.revision != UNCOMMITTED_CONTROLLER_REVISION {
        bail!("Nixbot deployment revision must be a commit ID or the fail-closed sentinel");
    }
    Ok(())
}

pub fn validate_nixbot_deploy_request(request: &NixbotDeployRequest) -> Result<()> {
    if !is_safe_name(&request.host) {
        bail!("Nixbot deployment host is invalid");
    }
    if request
        .nix_config
        .as_ref()
        .is_some_and(|nix_config| !is_safe_name(nix_config))
    {
        bail!("Nixbot deployment Nix config is invalid");
    }
    for host in &request.exclude_hosts {
        if !is_safe_name(host) || host == &request.host {
            bail!("Nixbot deployment exclusion is invalid");
        }
    }
    let mut exclusions = request.exclude_hosts.clone();
    exclusions.sort();
    exclusions.dedup();
    if exclusions.len() != request.exclude_hosts.len() {
        bail!("Nixbot deployment exclusions cannot contain duplicates");
    }
    Ok(())
}

pub fn activate(deployment: &DeploymentDefinition) -> Result<DeploymentResult> {
    validate_deployment(deployment)?;
    let program = deployment.system.join("bin/switch-to-configuration");
    let mode = match deployment.mode {
        ActivationMode::Switch => "switch",
        ActivationMode::Test => "test",
        ActivationMode::Boot => "boot",
    };
    let output = Command::new(&program)
        .arg(mode)
        .output()
        .with_context(|| format!("activate NixOS system {}", deployment.system.display()))?;
    let result = DeploymentResult {
        system: deployment.system.clone(),
        program,
        mode: deployment.mode,
        exit_code: output.status.code(),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    };
    if !output.status.success() {
        bail!(
            "NixOS activation failed with {:?}: {}",
            result.exit_code,
            result.stderr.trim()
        );
    }
    Ok(result)
}

fn is_safe_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 253
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
        && value
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
        && value
            .as_bytes()
            .last()
            .is_some_and(u8::is_ascii_alphanumeric)
}

fn is_commit_revision(value: &str) -> bool {
    (7..=64).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_non_store_activation() {
        assert!(
            validate_deployment(&DeploymentDefinition {
                system: PathBuf::from("/tmp/system"),
                mode: ActivationMode::Switch,
            })
            .is_err()
        );
    }

    #[test]
    fn validates_separate_nixbot_host_and_nix_config() {
        let policy = NixbotDeployPolicy {
            program: PathBuf::from("/nix/store/nixbot/bin/nixbot"),
            runuser_program: PathBuf::from("/run/current-system/sw/bin/runuser"),
            env_program: PathBuf::from("/run/current-system/sw/bin/env"),
            user: "nixbot".to_owned(),
            home: PathBuf::from("/var/lib/nixbot"),
            repository_url: "ssh://git@example.test/repo".to_owned(),
            repository_path: PathBuf::from("/var/lib/nixbot/repo"),
            repository_ssh_key_paths: vec![PathBuf::from("/var/lib/nixbot/.ssh/repo-example")],
            config_override_path: Some(PathBuf::from("/etc/nixbot/controller.override.nix")),
            revision: "0123456789abcdef".to_owned(),
        };
        let request = NixbotDeployRequest {
            host: "abird-gondor-proxy".to_owned(),
            nix_config: Some("abird-gondor-proxy-zulip-target".to_owned()),
            exclude_hosts: vec!["gap3-gondor".to_owned()],
        };
        validate_nixbot_deploy_policy(&policy).unwrap();
        validate_nixbot_deploy_request(&request).unwrap();
    }
}
