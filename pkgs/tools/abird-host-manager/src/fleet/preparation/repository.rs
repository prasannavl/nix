//! Bounded adapter for the existing native repository/workspace implementation.
//! Trusted policy, not filesystem confinement, admission or verified source.

use abird_host_agent::build_executor::preparation::{
    git_profile::ConfigImage, search_path::SearchPath,
};
use std::collections::BTreeMap;
use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use abird_host_agent::build_executor::preparation::git_context::window::ReadWindow;
use abird_host_agent::build_executor::process::{Captured, Runner};
use anyhow::{Result, ensure};

use crate::fleet::repository::{
    CommandOutput, CommandRequest, CommandRunner, InstalledBinary, RepositoryManager,
    plan_installed_execution,
};
use crate::programs::GIT_REPOSITORY_ENVIRONMENT;

/// Select before/after alias vetoes or checks of the installed private view.
/// Neither mode proves coherent consumption or grants execution authority.
#[derive(Clone, Copy)]
pub enum SearchView {
    Original,
    Private,
}

struct CallerContext {
    search: SearchPath,
    configuration: ConfigImage,
    view: SearchView,
    git_directory: PathBuf,
    deadline: Instant,
}
impl CallerContext {
    fn check(&self, _root: &Path) -> Result<()> {
        ensure!(
            Instant::now() < self.deadline,
            "caller context lifetime expired"
        );
        match self.view {
            SearchView::Original => {
                self.search.check_live(self.deadline)?;
                self.configuration.check_live(self.deadline)
            }
            SearchView::Private => {
                self.search.check_view()?;
                self.configuration
                    .check_view(&self.git_directory, true, self.deadline)
            }
        }
    }
}

/// Explicit private environment and exact cwd set. Caller binds executable,
/// namespace, credentials, quotas and original deadline.
pub struct RepositoryCommands {
    git: InstalledBinary,
    cwd: PathBuf,
    directories: Vec<PathBuf>,
    environment: BTreeMap<OsString, OsString>,
    caller: Option<CallerContext>,
}
impl RepositoryCommands {
    pub fn new(
        git: PathBuf,
        cwd: PathBuf,
        directories: Vec<PathBuf>,
        environment: Vec<(OsString, OsString)>,
    ) -> Result<Self> {
        let git = InstalledBinary::new(git)?;
        ensure!(
            directories.len() <= 16 && environment.len() <= 256,
            "repository policy exceeds bound"
        );
        for directory in std::iter::once(&cwd).chain(&directories) {
            plan_installed_execution(&git, directory, &[])?;
        }
        let mut values = BTreeMap::new();
        let mut bytes = 0usize;
        for (name, value) in environment {
            let key = name.as_bytes();
            ensure!(
                !key.is_empty() && key.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'_'),
                "invalid repository environment name"
            );
            ensure!(
                !value.as_bytes().contains(&0),
                "invalid repository environment value"
            );
            ensure!(
                !GIT_REPOSITORY_ENVIRONMENT
                    .iter()
                    .any(|selector| name == OsStr::new(selector)),
                "repository environment redirects selection"
            );
            bytes = bytes
                .checked_add(key.len())
                .and_then(|n| n.checked_add(value.len()))
                .ok_or_else(|| anyhow::anyhow!("repository environment exceeds bound"))?;
            ensure!(bytes <= 64 * 1024, "repository environment exceeds bound");
            ensure!(
                values.insert(name, value).is_none(),
                "duplicate repository environment"
            );
        }
        ensure!(
            values
                .get(OsStr::new("GIT_CONFIG_NOSYSTEM"))
                .is_none_or(|v| v == "1"),
            "unsupported repository system configuration selector"
        );
        ensure!(
            values
                .get(OsStr::new("PATH"))
                .is_some_and(|v| !v.is_empty()),
            "repository PATH is required"
        );
        let home = values
            .get(OsStr::new("HOME"))
            .ok_or_else(|| anyhow::anyhow!("repository HOME is required"))?;
        plan_installed_execution(&git, Path::new(home), &[])?;
        Ok(Self {
            git,
            cwd,
            directories,
            environment: values,
            caller: None,
        })
    }

    /// Bind the caller context as one unit; no path-only/config-only execution.
    pub fn bind_caller(
        self,
        search: SearchPath,
        configuration: ConfigImage,
        view: SearchView,
        deadline: Instant,
    ) -> Result<Self> {
        let common = self.cwd.join(".git");
        self.bind_caller_at(search, configuration, view, common, deadline)
    }

    pub fn bind_caller_at(
        mut self,
        search: SearchPath,
        configuration: ConfigImage,
        view: SearchView,
        git_directory: PathBuf,
        deadline: Instant,
    ) -> Result<Self> {
        search.require_value(
            self.environment
                .get(OsStr::new("PATH"))
                .and_then(|value| value.to_str())
                .ok_or_else(|| anyhow::anyhow!("caller PATH missing"))?,
        )?;
        let caller = CallerContext {
            search,
            configuration,
            view,
            git_directory,
            deadline,
        };
        caller.check(&self.cwd)?;
        self.caller = Some(caller);
        Ok(self)
    }

    fn check_context(&self) -> Result<()> {
        ensure!(
            self.caller.is_some()
                || self
                    .environment
                    .get(OsStr::new("GIT_CONFIG_NOSYSTEM"))
                    .is_some_and(|value| value == "1"),
            "system configuration requires captured caller profile"
        );
        if let Some(caller) = &self.caller {
            abird_host_agent::build_executor::process::offline::require_read_scope()?;
            caller.check(&self.cwd)?;
        }
        Ok(())
    }

    /// Every native operation shares the supplied runner; no per-command TTL.
    /// Scope checks stop swallowed prune/capture errors becoming a result.
    pub fn with_repository<T>(
        &self,
        runner: &mut Runner,
        operation: impl FnOnce(&mut RepositoryManager<RepositoryRunner<'_>>) -> Result<T>,
    ) -> Result<T> {
        self.with_capture(runner, operation)
    }

    /// The global profile is held before repository discovery. Child commands
    /// keep the original signal mask and poll the same nonrenewable window.
    pub(crate) fn with_profile_window<T>(
        &self,
        runner: &mut Runner,
        window: &ReadWindow,
        operation: impl FnOnce(&mut RepositoryManager<RepositoryRunner<'_>>) -> Result<T>,
    ) -> Result<T> {
        self.with_capture(&mut WindowCapture { runner, window }, operation)
    }

    /// The same admitted runner, with the original Git read window around every
    /// native command. Neither swallowed errors nor child signal setup bypass it.
    pub(crate) fn with_git_window_at<T>(
        &self,
        runner: &mut Runner,
        window: &ReadWindow,
        common: &Path,
        operation: impl FnOnce(&mut RepositoryManager<RepositoryRunner<'_>>) -> Result<T>,
    ) -> Result<T> {
        window.require_path(common)?;
        ensure!(
            self.directories.is_empty(),
            "one Git read window cannot cover another repository"
        );
        self.with_profile_window(runner, window, operation)
    }

    fn with_capture<T>(
        &self,
        capture: &mut dyn Capture,
        operation: impl FnOnce(&mut RepositoryManager<RepositoryRunner<'_>>) -> Result<T>,
    ) -> Result<T> {
        capture.check()?;
        self.check_context()?;
        let adapter = RepositoryRunner {
            policy: self,
            capture,
            failed: false,
        };
        let mut manager = RepositoryManager::new(self.git.as_path(), adapter);
        let result = operation(&mut manager);
        ensure!(
            !manager.runner().failed,
            "owned repository scope unresolved"
        );
        manager.runner().capture.check()?;
        self.check_context()?;
        result
    }

    fn command(&self, request: &CommandRequest) -> Result<Command> {
        ensure!(
            request.program == self.git.as_path(),
            "repository executable differs from policy"
        );
        ensure!(
            request.environment.is_empty(),
            "per-command repository environment is forbidden"
        );
        let cwd = request.current_dir.as_deref().unwrap_or(&self.cwd);
        ensure!(
            cwd == self.cwd || self.directories.iter().any(|p| p == cwd),
            "repository cwd differs from policy"
        );
        let mut command = Command::new(self.git.as_path());
        command
            .env_clear()
            .envs(&self.environment)
            .current_dir(cwd)
            .args(&request.args);
        Ok(command)
    }
}

// Public only because native RepositoryManager carries its runner type. No
// constructor: creation/entry/exit checks stay within with_repository.
pub struct RepositoryRunner<'a> {
    policy: &'a RepositoryCommands,
    capture: &'a mut dyn Capture,
    failed: bool,
}
impl CommandRunner for RepositoryRunner<'_> {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput> {
        ensure!(!self.failed, "owned repository scope unresolved");
        let result = (|| {
            self.policy.check_context()?;
            let mut command = self.policy.command(request)?;
            let output = self
                .capture
                .run(&mut command, request.stdin.as_deref().unwrap_or_default())?;
            self.policy.check_context()?;
            Ok(CommandOutput {
                status: output
                    .status
                    .code()
                    .unwrap_or_else(|| 128 + output.status.signal().unwrap_or(0)),
                stdout: output.stdout,
                // Native run_checked interpolates stderr. Persistent private
                // diagnostics need a separately qualified capture sink.
                stderr: Vec::new(),
            })
        })();
        if result.is_err() {
            self.failed = true;
        }
        result
    }
}

trait Capture {
    fn run(&mut self, command: &mut Command, input: &[u8]) -> Result<Captured>;
    fn check(&self) -> Result<()>;
}
impl Capture for Runner {
    fn run(&mut self, command: &mut Command, input: &[u8]) -> Result<Captured> {
        Runner::run(self, command, input)
    }
    fn check(&self) -> Result<()> {
        self.check_ready()
    }
}

struct WindowCapture<'a> {
    runner: &'a mut Runner,
    window: &'a ReadWindow,
}
impl Capture for WindowCapture<'_> {
    fn run(&mut self, command: &mut Command, input: &[u8]) -> Result<Captured> {
        self.window.prepare_command(command)?;
        let result = self.runner.run_while(command, input, || self.window.poll());
        self.window.check()?;
        result
    }
    fn check(&self) -> Result<()> {
        self.runner.check_ready()?;
        self.window.check()
    }
}

#[cfg(test)]
mod tests;
