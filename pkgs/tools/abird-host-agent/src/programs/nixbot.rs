use anyhow::Result;

use crate::cmd;
use crate::command::CommandResult;
use crate::deployment::{
    NixbotDeployPolicy, NixbotDeployRequest, validate_nixbot_deploy_policy,
    validate_nixbot_deploy_request,
};

pub fn deploy(policy: &NixbotDeployPolicy, request: &NixbotDeployRequest) -> Result<CommandResult> {
    validate_nixbot_deploy_policy(policy)?;
    validate_nixbot_deploy_request(request)?;

    let mut command = cmd!(
        &policy.runuser_program,
        "-u",
        &policy.user,
        "--",
        &policy.env_program,
        format!("HOME={}", policy.home.display()),
        format!("NIXBOT_REPO_URL={}", policy.repository_url),
        format!("NIXBOT_REPO_PATH={}", policy.repository_path.display()),
    );
    if !policy.repository_ssh_key_paths.is_empty() {
        command = command.arg(format!(
            "NIXBOT_REPO_SSH_KEY_PATHS={}",
            policy
                .repository_ssh_key_paths
                .iter()
                .map(|path| path.to_string_lossy())
                .collect::<Vec<_>>()
                .join(":")
        ));
    }
    command = command
        .arg(&policy.program)
        .args(["deploy", "--sha", &policy.revision]);
    if request.exclude_hosts.is_empty() {
        command = command.args(["--host", request.host.as_str()]);
    } else {
        let selection = std::iter::once(request.host.as_str())
            .chain(request.exclude_hosts.iter().map(|host| host.as_str()))
            .enumerate()
            .map(|(index, host)| {
                if index == 0 {
                    host.to_owned()
                } else {
                    format!("-{host}")
                }
            })
            .collect::<Vec<_>>()
            .join(",");
        command = command.args(["--hosts", &selection]);
    }
    if let Some(nix_config) = &request.nix_config {
        command = command.args(["--nix-config", nix_config]);
    }
    command.arg("--no-rollback").output()
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

    use super::*;

    #[test]
    fn keeps_connection_host_and_nix_config_separate() {
        let temp = tempfile::tempdir().unwrap();
        let capture = temp.path().join("capture");
        let fake = temp.path().join("runuser");
        fs::write(
            &fake,
            format!("#!/bin/sh\nprintf '%s\\n' \"$@\" >{}\n", capture.display()),
        )
        .unwrap();
        fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
        let mut policy = NixbotDeployPolicy {
            program: PathBuf::from("/nix/store/nixbot/bin/nixbot"),
            runuser_program: fake,
            env_program: PathBuf::from("/run/current-system/sw/bin/env"),
            user: "nixbot".to_owned(),
            home: PathBuf::from("/var/lib/nixbot"),
            repository_url: "ssh://git@example.test/repo".to_owned(),
            repository_path: PathBuf::from("/var/lib/nixbot/repo"),
            repository_ssh_key_paths: vec![PathBuf::from("/var/lib/nixbot/.ssh/repo-example")],
            revision: "0123456789abcdef".to_owned(),
        };
        let request = NixbotDeployRequest {
            host: "abird-gondor-proxy".to_owned(),
            nix_config: Some("abird-gondor-proxy-zulip-target".to_owned()),
            exclude_hosts: vec!["gap3-gondor".to_owned()],
        };
        deploy(&policy, &request).unwrap();
        let argv = fs::read_to_string(&capture).unwrap();
        assert!(argv.contains("NIXBOT_REPO_SSH_KEY_PATHS=/var/lib/nixbot/.ssh/repo-example"));
        assert!(argv.contains("abird-gondor-proxy,-gap3-gondor"));
        assert!(argv.contains("abird-gondor-proxy-zulip-target"));

        policy.repository_ssh_key_paths.clear();
        deploy(&policy, &request).unwrap();
        let argv = fs::read_to_string(&capture).unwrap();
        assert!(!argv.contains("NIXBOT_REPO_SSH_KEY_PATHS="));
    }
}
