use std::fmt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::str::FromStr;
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::ValueEnum;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum ServiceScope {
    System,
    User,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ServiceTarget {
    pub scope: ServiceScope,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    pub unit: String,
}

impl ServiceTarget {
    pub fn new(scope: ServiceScope, user: Option<String>, unit: String) -> Result<Self> {
        if unit.trim().is_empty() || unit.starts_with('-') {
            bail!("service unit cannot be empty or start with '-'");
        }
        if unit
            .bytes()
            .any(|byte| byte.is_ascii_whitespace() || byte == b'\0')
        {
            bail!("service unit cannot contain whitespace or NUL");
        }
        if scope == ServiceScope::System && user.is_some() {
            bail!("--user is only valid with user-scoped services");
        }
        if user.as_ref().is_some_and(|value| value.trim().is_empty()) {
            bail!("service user cannot be empty");
        }
        if user
            .as_ref()
            .is_some_and(|value| value.contains(['\0', '@']))
        {
            bail!("service user cannot contain NUL or '@'");
        }

        Ok(Self { scope, user, unit })
    }

    pub fn validate(&self) -> Result<()> {
        Self::new(self.scope, self.user.clone(), self.unit.clone()).map(|_| ())
    }

    pub fn system(unit: impl Into<String>) -> Self {
        Self {
            scope: ServiceScope::System,
            user: None,
            unit: unit.into(),
        }
    }

    fn systemctl_args(&self, operation: ServiceOperation) -> Vec<String> {
        let mut args = self.systemctl_scope_args();
        args.push(operation.systemctl_verb().to_owned());
        args.push("--".to_owned());
        args.push(self.unit.clone());
        args
    }

    fn systemctl_scope_args(&self) -> Vec<String> {
        let mut args = Vec::new();
        if self.scope == ServiceScope::User {
            args.push("--user".to_owned());
            if let Some(user) = &self.user {
                args.push("--machine".to_owned());
                // An empty machine component selects the local user's manager
                // directly. Routing the same request through `.host` adds a
                // systemd-machined transport that can disconnect while a NixOS
                // generation reexecutes systemd.
                args.push(format!("{user}@"));
            }
        }
        args
    }

    fn with_unit(&self, unit: String) -> Result<Self> {
        Self::new(self.scope, self.user.clone(), unit)
    }
}

impl fmt::Display for ServiceTarget {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match (&self.scope, &self.user) {
            (ServiceScope::System, _) => write!(formatter, "system:{}", self.unit),
            (ServiceScope::User, Some(user)) => {
                write!(formatter, "user:{user}:{}", self.unit)
            }
            (ServiceScope::User, None) => write!(formatter, "user:{}", self.unit),
        }
    }
}

impl FromStr for ServiceTarget {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        if let Some(unit) = value.strip_prefix("system:") {
            return Self::new(ServiceScope::System, None, unit.to_owned());
        }
        if let Some(value) = value.strip_prefix("user:") {
            let (user, unit) = match value.split_once(':') {
                Some((user, unit)) => (Some(user.to_owned()), unit.to_owned()),
                None => (None, value.to_owned()),
            };
            return Self::new(ServiceScope::User, user, unit);
        }
        bail!("invalid service target {value:?}; use system:UNIT, user:UNIT, or user:USER:UNIT")
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum ServiceOperation {
    Start,
    Stop,
    Restart,
    Reload,
    TryReloadOrRestart,
    Status,
}

impl ServiceOperation {
    fn systemctl_verb(self) -> &'static str {
        match self {
            Self::Start => "start",
            Self::Stop => "stop",
            Self::Restart => "restart",
            Self::Reload => "reload",
            Self::TryReloadOrRestart => "try-reload-or-restart",
            Self::Status => "is-active",
        }
    }
}

#[derive(Debug, Serialize)]
pub struct ServiceResult {
    pub operation: ServiceOperation,
    pub target: ServiceTarget,
    pub executable: PathBuf,
    pub arguments: Vec<String>,
    pub success: bool,
    pub exit_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

#[derive(Clone, Debug)]
pub struct Systemctl {
    executable: PathBuf,
}

impl Systemctl {
    pub fn new(executable: impl Into<PathBuf>) -> Self {
        Self {
            executable: executable.into(),
        }
    }

    pub fn executable(&self) -> &Path {
        &self.executable
    }

    fn query_with_retry(&self, arguments: &[String]) -> Result<Output> {
        const ATTEMPTS: usize = 9;
        const DELAY: Duration = Duration::from_millis(250);

        let mut last_output = None;
        for attempt in 0..ATTEMPTS {
            let output = Command::new(&self.executable)
                .args(arguments)
                .output()
                .with_context(|| format!("run {}", self.executable.display()))?;
            if output.status.success() {
                return Ok(output);
            }
            last_output = Some(output);
            if attempt + 1 < ATTEMPTS {
                thread::sleep(DELAY);
            }
        }

        Ok(last_output.expect("query loop always runs at least once"))
    }

    pub fn run(
        &self,
        operation: ServiceOperation,
        target: &ServiceTarget,
    ) -> Result<ServiceResult> {
        let arguments = target.systemctl_args(operation);
        let output = self.query_with_retry(&arguments)?;

        let result = ServiceResult {
            operation,
            target: target.clone(),
            executable: self.executable.clone(),
            arguments,
            success: output.status.success(),
            exit_code: output.status.code(),
            stdout: String::from_utf8_lossy(&output.stdout).trim().to_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        };

        if operation != ServiceOperation::Status && !result.success {
            bail!(
                "{} {} failed with status {:?}: {}",
                operation.systemctl_verb(),
                target,
                result.exit_code,
                result.stderr
            );
        }
        Ok(result)
    }

    /// Return the systemd units whose lifecycle is owned by `target` through
    /// `PartOf=`. Quadlet exposes generated container and network units through
    /// this `ConsistsOf` relationship on the public service.
    pub fn consists_of(&self, target: &ServiceTarget) -> Result<Vec<ServiceTarget>> {
        let mut arguments = target.systemctl_scope_args();
        arguments.extend([
            "show".to_owned(),
            "--property=ConsistsOf".to_owned(),
            "--value".to_owned(),
            "--".to_owned(),
            target.unit.clone(),
        ]);
        let output = self.query_with_retry(&arguments)?;
        if !output.status.success() {
            bail!(
                "query owned units for {target} failed with status {:?}: {}",
                output.status.code(),
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }

        String::from_utf8_lossy(&output.stdout)
            .split_ascii_whitespace()
            .map(|unit| target.with_unit(unit.to_owned()))
            .collect()
    }

    /// Clear failure state only after a successful explicit stop, and only for
    /// the stopped service plus units systemd declares it owns.
    pub fn reset_failed(&self, targets: &[ServiceTarget]) -> Result<()> {
        let Some(first) = targets.first() else {
            return Ok(());
        };
        if targets
            .iter()
            .any(|target| target.scope != first.scope || target.user != first.user)
        {
            bail!("reset-failed targets must share one systemd manager");
        }

        let failed = self.failed_targets(targets)?;
        if failed.is_empty() {
            return Ok(());
        }

        let mut arguments = first.systemctl_scope_args();
        arguments.push("reset-failed".to_owned());
        arguments.push("--".to_owned());
        for target in &failed {
            arguments.push(target.unit.clone());
        }
        let output = Command::new(&self.executable)
            .args(&arguments)
            .output()
            .with_context(|| format!("run {}", self.executable.display()))?;
        if !output.status.success() {
            let remaining = self.failed_targets(&failed)?;
            if remaining.is_empty() {
                return Ok(());
            }
            bail!(
                "reset failure state for {first} failed with status {:?}; still failed: {}: {}",
                output.status.code(),
                remaining
                    .iter()
                    .map(|target| target.unit.as_str())
                    .collect::<Vec<_>>()
                    .join(", "),
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        Ok(())
    }

    fn failed_targets(&self, targets: &[ServiceTarget]) -> Result<Vec<ServiceTarget>> {
        let Some(first) = targets.first() else {
            return Ok(Vec::new());
        };

        let mut arguments = first.systemctl_scope_args();
        arguments.extend([
            "list-units".to_owned(),
            "--state=failed".to_owned(),
            "--plain".to_owned(),
            "--no-legend".to_owned(),
            "--no-pager".to_owned(),
            "--".to_owned(),
        ]);
        arguments.extend(targets.iter().map(|target| target.unit.clone()));
        let output = self.query_with_retry(&arguments)?;
        if !output.status.success() {
            bail!(
                "query failed units for {first} failed with status {:?}: {}",
                output.status.code(),
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let listed = stdout
            .lines()
            .filter_map(|line| line.split_ascii_whitespace().next())
            .collect::<std::collections::HashSet<_>>();
        Ok(targets
            .iter()
            .filter(|target| listed.contains(target.unit.as_str()))
            .cloned()
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_service_targets() {
        assert_eq!(
            "system:zulip.service".parse::<ServiceTarget>().unwrap(),
            ServiceTarget::system("zulip.service")
        );
        assert_eq!(
            "user:abird:zulip.target".parse::<ServiceTarget>().unwrap(),
            ServiceTarget {
                scope: ServiceScope::User,
                user: Some("abird".to_owned()),
                unit: "zulip.target".to_owned(),
            }
        );
    }

    #[test]
    fn builds_named_user_systemctl_arguments() {
        let target = "user:abird:zulip.target".parse::<ServiceTarget>().unwrap();
        assert_eq!(
            target.systemctl_args(ServiceOperation::Stop),
            [
                "--user",
                "--machine",
                "abird@",
                "stop",
                "--",
                "zulip.target"
            ]
        );
    }

    #[test]
    fn builds_reload_or_restart_systemctl_arguments() {
        let target = "user:abird:abird-nginx.service"
            .parse::<ServiceTarget>()
            .unwrap();
        assert_eq!(
            target.systemctl_args(ServiceOperation::TryReloadOrRestart),
            [
                "--user",
                "--machine",
                "abird@",
                "try-reload-or-restart",
                "--",
                "abird-nginx.service"
            ]
        );
    }

    #[test]
    fn builds_named_user_systemctl_scope_arguments() {
        let target = "user:abird:zulip.target".parse::<ServiceTarget>().unwrap();
        assert_eq!(
            target.systemctl_scope_args(),
            ["--user", "--machine", "abird@"]
        );
        assert_eq!(
            target
                .with_unit("zulip-container.service".to_owned())
                .unwrap(),
            "user:abird:zulip-container.service"
                .parse::<ServiceTarget>()
                .unwrap()
        );
    }

    #[test]
    fn systemctl_executable_is_configurable() {
        let executable = std::env::current_exe().unwrap();
        let result = Systemctl::new(&executable)
            .run(
                ServiceOperation::Status,
                &ServiceTarget::system("test.service"),
            )
            .unwrap();
        assert!(result.success);
        assert_eq!(result.executable, executable);
        assert_eq!(result.arguments, ["is-active", "--", "test.service"]);
    }
}
