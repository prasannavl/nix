use std::fmt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::str::FromStr;

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
        let mut args = Vec::new();
        if self.scope == ServiceScope::User {
            args.push("--user".to_owned());
            if let Some(user) = &self.user {
                args.push("--machine".to_owned());
                args.push(format!("{user}@.host"));
            }
        }
        args.push(operation.systemctl_verb().to_owned());
        args.push("--".to_owned());
        args.push(self.unit.clone());
        args
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
    Status,
}

impl ServiceOperation {
    fn systemctl_verb(self) -> &'static str {
        match self {
            Self::Start => "start",
            Self::Stop => "stop",
            Self::Restart => "restart",
            Self::Reload => "reload",
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

    pub fn run(
        &self,
        operation: ServiceOperation,
        target: &ServiceTarget,
    ) -> Result<ServiceResult> {
        let arguments = target.systemctl_args(operation);
        let output = Command::new(&self.executable)
            .args(&arguments)
            .output()
            .with_context(|| format!("run {}", self.executable.display()))?;

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
                "abird@.host",
                "stop",
                "--",
                "zulip.target"
            ]
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
