use std::collections::BTreeMap;
use std::fmt;
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::Serialize;
use serde_json::Value;

use crate::service::{ServiceScope, ServiceTarget};

#[derive(Clone, Debug)]
pub struct Journalctl {
    executable: PathBuf,
    runuser: PathBuf,
}

#[derive(Debug, Serialize)]
pub struct JournalResult {
    pub target: ServiceTarget,
    pub executable: PathBuf,
    pub arguments: Vec<String>,
    pub success: bool,
    pub exit_code: Option<i32>,
    pub entries: Vec<Value>,
    pub malformed_lines: Vec<String>,
    pub stderr: String,
}

#[derive(Debug, Serialize)]
pub struct HostJournalResult {
    pub executable: PathBuf,
    pub arguments: Vec<String>,
    pub success: bool,
    pub exit_code: Option<i32>,
    pub entries: Vec<Value>,
    pub malformed_lines: Vec<String>,
    pub stderr: String,
}

#[derive(Debug, Serialize)]
pub struct JournalFollowResult {
    pub success: bool,
    pub exit_code: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub failed_context: Option<String>,
    pub invocations: Vec<JournalFollowInvocation>,
}

#[derive(Debug, Serialize)]
pub struct JournalFollowInvocation {
    pub context: String,
    pub executable: PathBuf,
    pub arguments: Vec<String>,
    pub success: bool,
    pub exit_code: Option<i32>,
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum JournalContext {
    System,
    CurrentUser,
    User(String),
}

impl fmt::Display for JournalContext {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::System => formatter.write_str("system"),
            Self::CurrentUser => formatter.write_str("current-user"),
            Self::User(user) => write!(formatter, "user:{user}"),
        }
    }
}

#[derive(Clone, Debug)]
struct JournalInvocation {
    context: JournalContext,
    executable: PathBuf,
    arguments: Vec<String>,
}

struct FollowChild {
    invocation: JournalInvocation,
    child: Child,
    status: Option<ExitStatus>,
}

impl Journalctl {
    pub fn new(executable: impl Into<PathBuf>, runuser: impl Into<PathBuf>) -> Self {
        Self {
            executable: executable.into(),
            runuser: runuser.into(),
        }
    }

    pub fn logs(
        &self,
        target: &ServiceTarget,
        lines: usize,
        since: Option<&str>,
    ) -> Result<JournalResult> {
        validate_request(lines, since)?;
        let context = context_for(target);
        let arguments = journal_arguments(&context, &[target.unit.as_str()], lines, since, false);
        let invocation = self.invocation(context, arguments);
        let output = self.run(&invocation)?;
        let (entries, malformed_lines) = parse_entries(&output.stdout);
        Ok(JournalResult {
            target: target.clone(),
            executable: invocation.executable,
            arguments: invocation.arguments,
            success: output.status.success(),
            exit_code: output.status.code(),
            entries,
            malformed_lines,
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        })
    }

    pub fn host_logs(&self, lines: usize, since: Option<&str>) -> Result<HostJournalResult> {
        validate_request(lines, since)?;
        let context = JournalContext::System;
        let arguments = journal_arguments(&context, &[], lines, since, false);
        let invocation = self.invocation(context, arguments);
        let output = self.run(&invocation)?;
        let (entries, malformed_lines) = parse_entries(&output.stdout);
        Ok(HostJournalResult {
            executable: invocation.executable,
            arguments: invocation.arguments,
            success: output.status.success(),
            exit_code: output.status.code(),
            entries,
            malformed_lines,
            stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        })
    }

    pub fn follow_host(&self, lines: usize, since: Option<&str>) -> Result<JournalFollowResult> {
        validate_request(lines, since)?;
        let context = JournalContext::System;
        let arguments = journal_arguments(&context, &[], lines, since, true);
        self.run_follow(vec![self.invocation(context, arguments)])
    }

    pub fn follow_targets(
        &self,
        targets: &[ServiceTarget],
        lines: usize,
        since: Option<&str>,
    ) -> Result<JournalFollowResult> {
        if targets.is_empty() {
            bail!("cannot follow logs without at least one service target");
        }
        validate_request(lines, since)?;
        let grouped = group_targets(targets);
        let invocations = grouped
            .into_iter()
            .map(|(context, units)| {
                let units = units.iter().map(String::as_str).collect::<Vec<_>>();
                let arguments = journal_arguments(&context, &units, lines, since, true);
                self.invocation(context, arguments)
            })
            .collect();
        self.run_follow(invocations)
    }

    fn invocation(
        &self,
        context: JournalContext,
        journal_arguments: Vec<String>,
    ) -> JournalInvocation {
        if let JournalContext::User(user) = &context {
            let mut arguments = vec![
                "-u".to_owned(),
                user.clone(),
                "--".to_owned(),
                self.executable.display().to_string(),
            ];
            arguments.extend(journal_arguments);
            JournalInvocation {
                context,
                executable: self.runuser.clone(),
                arguments,
            }
        } else {
            JournalInvocation {
                context,
                executable: self.executable.clone(),
                arguments: journal_arguments,
            }
        }
    }

    fn run_follow(&self, invocations: Vec<JournalInvocation>) -> Result<JournalFollowResult> {
        let mut children = Vec::with_capacity(invocations.len());
        for invocation in invocations {
            let child = match Command::new(&invocation.executable)
                .args(&invocation.arguments)
                .stdin(Stdio::inherit())
                .stdout(Stdio::inherit())
                .stderr(Stdio::inherit())
                .spawn()
            {
                Ok(child) => child,
                Err(error) => {
                    terminate_followers(&mut children);
                    return Err(error).with_context(|| {
                        format!(
                            "follow {} journal with {}",
                            invocation.context,
                            invocation.executable.display()
                        )
                    });
                }
            };
            children.push(FollowChild {
                invocation,
                child,
                status: None,
            });
        }

        let mut failed = None;
        loop {
            let mut running = false;
            for index in 0..children.len() {
                if children[index].status.is_some() {
                    continue;
                }
                let status = match children[index].child.try_wait() {
                    Ok(status) => status,
                    Err(error) => {
                        let context = children[index].invocation.context.to_string();
                        terminate_followers(&mut children);
                        return Err(error)
                            .with_context(|| format!("wait for {context} journal follow"));
                    }
                };
                match status {
                    Some(status) => {
                        if !status.success() && failed.is_none() {
                            failed = Some(index);
                        }
                        children[index].status = Some(status);
                    }
                    None => running = true,
                }
            }
            if failed.is_some() || !running {
                break;
            }
            thread::sleep(Duration::from_millis(25));
        }

        if failed.is_some() {
            terminate_followers(&mut children);
        }
        for follower in &mut children {
            if follower.status.is_none() {
                follower.status = Some(follower.child.wait().with_context(|| {
                    format!("reap {} journal follow", follower.invocation.context)
                })?);
            }
        }

        let failed_context = failed.map(|index| children[index].invocation.context.to_string());
        let failed_exit_code =
            failed.and_then(|index| children[index].status.as_ref().and_then(ExitStatus::code));
        let invocations = children
            .into_iter()
            .map(|follower| {
                let status = follower
                    .status
                    .expect("every journal follower must have a terminal status");
                JournalFollowInvocation {
                    context: follower.invocation.context.to_string(),
                    executable: follower.invocation.executable,
                    arguments: follower.invocation.arguments,
                    success: status.success(),
                    exit_code: status.code(),
                }
            })
            .collect::<Vec<_>>();
        Ok(JournalFollowResult {
            success: failed.is_none(),
            exit_code: failed_exit_code,
            failed_context,
            invocations,
        })
    }

    fn run(&self, invocation: &JournalInvocation) -> Result<std::process::Output> {
        Command::new(&invocation.executable)
            .args(&invocation.arguments)
            .output()
            .with_context(|| {
                format!(
                    "read {} journal with {}",
                    invocation.context,
                    invocation.executable.display()
                )
            })
    }
}

fn context_for(target: &ServiceTarget) -> JournalContext {
    match (&target.scope, &target.user) {
        (ServiceScope::System, _) => JournalContext::System,
        (ServiceScope::User, Some(user)) => JournalContext::User(user.clone()),
        (ServiceScope::User, None) => JournalContext::CurrentUser,
    }
}

fn group_targets(targets: &[ServiceTarget]) -> BTreeMap<JournalContext, Vec<String>> {
    let mut grouped = BTreeMap::<JournalContext, Vec<String>>::new();
    for target in targets {
        grouped
            .entry(context_for(target))
            .or_default()
            .push(target.unit.clone());
    }
    grouped
}

fn journal_arguments(
    context: &JournalContext,
    units: &[&str],
    lines: usize,
    since: Option<&str>,
    follow: bool,
) -> Vec<String> {
    let mut arguments = vec!["--no-pager".to_owned()];
    arguments.push(
        match context {
            JournalContext::System => "--system",
            JournalContext::CurrentUser | JournalContext::User(_) => "--user",
        }
        .to_owned(),
    );
    if follow {
        arguments.push("--follow".to_owned());
    } else {
        arguments.push("--output=json".to_owned());
    }
    arguments.extend(["--lines".to_owned(), lines.to_string()]);
    for unit in units {
        arguments.extend(["--unit".to_owned(), (*unit).to_owned()]);
    }
    if let Some(since) = since {
        arguments.extend(["--since".to_owned(), since.to_owned()]);
    }
    arguments
}

fn validate_request(lines: usize, since: Option<&str>) -> Result<()> {
    if lines == 0 || lines > 10_000 {
        bail!("journal line count must be between 1 and 10000");
    }
    if since.is_some_and(|value| value.contains('\0')) {
        bail!("journal --since value cannot contain NUL");
    }
    Ok(())
}

fn terminate_followers(followers: &mut [FollowChild]) {
    for follower in followers {
        if follower.status.is_none() {
            let _ = follower.child.kill();
            if let Ok(status) = follower.child.wait() {
                follower.status = Some(status);
            }
        }
    }
}

fn parse_entries(output: &[u8]) -> (Vec<Value>, Vec<String>) {
    let mut entries = Vec::new();
    let mut malformed_lines = Vec::new();
    for line in String::from_utf8_lossy(output).lines() {
        match serde_json::from_str(line) {
            Ok(value) => entries.push(value),
            Err(_) => malformed_lines.push(line.to_owned()),
        }
    }
    (entries, malformed_lines)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::time::{Duration, Instant};

    use super::*;

    fn executable(path: &std::path::Path, body: &str) {
        // Publish a closed inode atomically. Executing a just-written script can
        // otherwise race with overlay-backed Nix build directories and fail
        // spuriously with ETXTBSY under parallel tests.
        let staging = path.with_extension("tmp");
        fs::write(&staging, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&staging, fs::Permissions::from_mode(0o700)).unwrap();
        fs::rename(staging, path).unwrap();
    }

    #[test]
    fn preserves_structured_and_malformed_journal_output() {
        let temp = tempfile::tempdir().unwrap();
        let journalctl = temp.path().join("journalctl");
        executable(
            &journalctl,
            "printf '%s\\n' '{\"MESSAGE\":\"ready\"}' 'not-json'",
        );
        let result = Journalctl::new(&journalctl, "/does/not/exist")
            .logs(&ServiceTarget::system("zulip.service"), 50, None)
            .unwrap();
        assert!(result.success);
        assert_eq!(result.entries[0]["MESSAGE"], "ready");
        assert_eq!(result.malformed_lines, ["not-json"]);
        assert!(
            result
                .arguments
                .iter()
                .any(|argument| argument == "--system")
        );
    }

    #[test]
    fn reads_named_user_journal_through_runuser() {
        let temp = tempfile::tempdir().unwrap();
        let capture = temp.path().join("capture");
        let journalctl = temp.path().join("journalctl");
        let runuser = temp.path().join("runuser");
        executable(&journalctl, "printf '%s\\n' '{\"MESSAGE\":\"ready\"}'");
        executable(
            &runuser,
            &format!(
                "printf '%s\\n' \"$@\" > {}; shift 3; exec \"$@\"",
                capture.display()
            ),
        );
        let target = ServiceTarget::new(
            ServiceScope::User,
            Some("alice".to_owned()),
            "worker.service".to_owned(),
        )
        .unwrap();
        let result = Journalctl::new(&journalctl, &runuser)
            .logs(&target, 25, Some("today"))
            .unwrap();

        assert!(result.success);
        assert_eq!(result.executable, runuser);
        assert_eq!(result.entries[0]["MESSAGE"], "ready");
        assert_eq!(
            fs::read_to_string(capture)
                .unwrap()
                .lines()
                .collect::<Vec<_>>(),
            [
                "-u",
                "alice",
                "--",
                journalctl.to_str().unwrap(),
                "--no-pager",
                "--user",
                "--output=json",
                "--lines",
                "25",
                "--unit",
                "worker.service",
                "--since",
                "today",
            ]
        );
    }

    #[test]
    fn reads_the_unfiltered_host_journal() {
        let temp = tempfile::tempdir().unwrap();
        let journalctl = temp.path().join("journalctl");
        executable(&journalctl, "printf '%s\\n' '{\"MESSAGE\":\"booted\"}'");
        let result = Journalctl::new(&journalctl, "/does/not/exist")
            .host_logs(20, Some("today"))
            .unwrap();
        assert_eq!(result.entries[0]["MESSAGE"], "booted");
        assert_eq!(result.arguments.last().map(String::as_str), Some("today"));
        assert!(
            result
                .arguments
                .iter()
                .any(|argument| argument == "--system")
        );
        assert!(!result.arguments.iter().any(|argument| argument == "--unit"));
    }

    #[test]
    fn partitions_mixed_targets_by_execution_identity() {
        let targets = [
            ServiceTarget::system("api.service"),
            ServiceTarget::system("db.service"),
            ServiceTarget::new(
                ServiceScope::User,
                Some("alice".to_owned()),
                "worker.service".to_owned(),
            )
            .unwrap(),
            ServiceTarget::new(
                ServiceScope::User,
                Some("alice".to_owned()),
                "timer.service".to_owned(),
            )
            .unwrap(),
            ServiceTarget::new(
                ServiceScope::User,
                Some("bob".to_owned()),
                "worker.service".to_owned(),
            )
            .unwrap(),
            ServiceTarget::new(ServiceScope::User, None, "local.service".to_owned()).unwrap(),
        ];

        let grouped = group_targets(&targets);
        assert_eq!(grouped.len(), 4);
        assert_eq!(
            grouped[&JournalContext::System],
            ["api.service", "db.service"]
        );
        assert_eq!(
            grouped[&JournalContext::User("alice".to_owned())],
            ["worker.service", "timer.service"]
        );
        assert_eq!(
            grouped[&JournalContext::User("bob".to_owned())],
            ["worker.service"]
        );
        assert_eq!(grouped[&JournalContext::CurrentUser], ["local.service"]);
    }

    #[test]
    fn follows_multiple_contexts_without_buffering_json() {
        let temp = tempfile::tempdir().unwrap();
        let journalctl = temp.path().join("journalctl");
        let runuser = temp.path().join("runuser");
        executable(&journalctl, "exit 0");
        executable(&runuser, "shift 3; exec \"$@\"");
        let result = Journalctl::new(&journalctl, &runuser)
            .follow_targets(
                &[
                    ServiceTarget::system("zulip.service"),
                    ServiceTarget::new(
                        ServiceScope::User,
                        Some("zulip".to_owned()),
                        "worker.service".to_owned(),
                    )
                    .unwrap(),
                ],
                25,
                Some("today"),
            )
            .unwrap();

        assert!(result.success);
        assert_eq!(result.invocations.len(), 2);
        assert!(result.invocations.iter().all(|invocation| {
            invocation
                .arguments
                .iter()
                .any(|argument| argument == "--follow")
                && !invocation
                    .arguments
                    .iter()
                    .any(|argument| argument == "--output=json")
        }));
        assert!(result.invocations.iter().any(|invocation| {
            invocation.context == "system"
                && invocation
                    .arguments
                    .windows(2)
                    .any(|pair| pair == ["--unit", "zulip.service"])
        }));
        assert!(result.invocations.iter().any(|invocation| {
            invocation.context == "user:zulip"
                && invocation
                    .arguments
                    .windows(2)
                    .any(|pair| pair == ["--unit", "worker.service"])
        }));
    }

    #[test]
    fn a_failed_follow_context_terminates_its_peers() {
        let temp = tempfile::tempdir().unwrap();
        let journalctl = temp.path().join("journalctl");
        let runuser = temp.path().join("runuser");
        executable(&journalctl, "exec sleep 30");
        executable(&runuser, "exit 7");
        let started = Instant::now();
        let result = Journalctl::new(&journalctl, &runuser)
            .follow_targets(
                &[
                    ServiceTarget::system("api.service"),
                    ServiceTarget::new(
                        ServiceScope::User,
                        Some("bob".to_owned()),
                        "worker.service".to_owned(),
                    )
                    .unwrap(),
                ],
                10,
                None,
            )
            .unwrap();

        assert!(started.elapsed() < Duration::from_secs(2));
        assert!(!result.success);
        assert_eq!(result.exit_code, Some(7));
        assert_eq!(result.failed_context.as_deref(), Some("user:bob"));
    }
}
