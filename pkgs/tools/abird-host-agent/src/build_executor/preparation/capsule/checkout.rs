//! Root-side checkout mechanics shared by caller-only and colocated capture.
//! Caller supplies existing admitted stages, namespace, limits and deadline.
use super::super::git_context::GitContext;
use crate::build_executor::{
    build_worker::caller_view::View,
    controller_service::Account,
    daemon,
    native_intent::{CALLER_GIT_PROFILE, CheckoutInput},
    process::{DirectoryFd, Limits, Runner},
    stage::Stage,
};
use anyhow::{Result, ensure};
use std::fs::{self, File};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;
use std::time::Instant;

pub struct CheckoutExecution<'a> {
    pub directory: &'a Path,
    pub account: &'a Account,
    pub input: &'a CheckoutInput,
    pub git_context: &'a mut GitContext,
    pub manager: &'a Path,
    pub git: &'a Path,
    pub nar: &'a Path,
    pub nar_configuration: &'a Path,
    pub source_limits: crate::build_executor::private_tree::Limits,
    pub local: bool,
    pub deadline: Instant,
}

impl CheckoutExecution<'_> {
    /// Payload is the manager's typed checkout/export input. No shell command,
    /// transport key, daemon FD or caller-selected executable crosses this seam.
    pub fn run(self, payload: &[u8], restore: &mut Stage, checkout: &mut Stage) -> Result<Vec<u8>> {
        ensure!(
            unsafe { libc::geteuid() } == 0 && Instant::now() < self.deadline,
            "private checkout requires original root lifetime"
        );
        self.input.validate()?;
        ensure!(
            self.input.limits == self.source_limits,
            "checkout read/source limits differ"
        );
        daemon::trusted_path(&self.input.runtime_closure)?;
        self.git_context.require_limits(self.source_limits)?;
        for program in [self.manager, self.git, self.nar] {
            daemon::executable(program)?;
        }
        daemon::trusted_path(self.nar_configuration)?;
        fs::create_dir(self.directory)?;
        fs::set_permissions(self.directory, fs::Permissions::from_mode(0o700))?;
        let producer = self.directory.join("producer");
        fs::create_dir(&producer)?;
        fs::set_permissions(&producer, fs::Permissions::from_mode(0o700))?;
        let file = File::open(&producer)?;
        ensure!(
            unsafe { libc::fchown(file.as_raw_fd(), self.account.uid, self.account.gid) } == 0,
            "private checkout producer ownership failed"
        );
        file.sync_all()?;
        File::open(self.directory)?.sync_all()?;
        let scope = DirectoryFd::new(&file)?;
        let mut command = Command::new(self.nar);
        command
            .current_dir("/var/empty")
            .env_clear()
            .env("HOME", "/var/empty")
            .env("PATH", "/var/empty")
            .env("NIX_CONF_DIR", self.nar_configuration)
            .arg("--restore")
            .arg(scope.path().join(".git"));
        let bound = super::super::source::material_limit(self.source_limits)?;
        let mut runner = Runner::new_source(
            self.account.uid,
            Limits {
                stdin: bound / 2,
                stdout: 64,
                stderr: 4096,
            },
            self.deadline,
            bound,
        )?;
        let output = runner.run_as_directory(
            &mut command,
            &self.git_context.archive()?,
            self.account.gid,
            scope,
            restore,
        )?;
        ensure!(
            output.status.success() && output.stdout.is_empty(),
            "private common Git restore failed"
        );
        self.git_context.restore_times(
            &producer.join(".git"),
            self.account.uid,
            self.source_limits,
            self.deadline,
        )?;
        // Destructive consumption: after verified restore no caller needs the
        // initial common-Git hex again. Release it BEFORE a child exports the
        // replacement image, rather than retaining two large images at once.
        drop(std::mem::take(&mut self.git_context.nar));
        let view = View::prepare(
            self.directory,
            &producer,
            self.input,
            self.account,
            self.deadline,
        )?;
        let mut command = Command::new(self.manager);
        command
            .arg(crate::build_executor::role::ManagerCommand::Capture.argument())
            .arg(if self.local {
                "--checkout-export-local"
            } else {
                "--checkout-export"
            })
            .arg(self.git)
            .current_dir("/var/empty")
            .env_clear()
            .env("HOME", &self.account.home)
            .env("XDG_STATE_HOME", &self.account.state_home)
            .env("PATH", "/var/empty")
            .env("LC_ALL", "C")
            .envs(CALLER_GIT_PROFILE);
        let mut runner = Runner::new_source(
            self.account.uid,
            Limits {
                stdin: payload.len(),
                stdout: bound,
                stderr: 4096,
            },
            self.deadline,
            bound,
        )?
        .with_umask(self.input.context()?.1.umask)?;
        let output = runner.run_as_view(
            &mut command,
            payload,
            self.account.gid,
            &self.account.groups,
            view,
            checkout,
        )?;
        ensure!(
            output.status.success(),
            "original native checkout/export failed"
        );
        Ok(output.stdout)
    }
}
