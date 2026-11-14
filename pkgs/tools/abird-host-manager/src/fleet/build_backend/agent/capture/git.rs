//! One bounded filesystem-only Git-metadata intake. No clone, ref resolution,
//! filtering, Nix evaluation or store ingress. The same kernel read window also
//! surrounds native revision/patch capture; full profile coherence remains open.

use std::path::Path;
use std::process::Command;
use std::time::Instant;

use abird_host_agent::build_executor::{
    preparation::git_context::{GitContext, MAX_NAR_BYTES, Observation, window::ReadWindow},
    private_tree,
    process::{Limits, Runner},
};
use anyhow::{Result, ensure};

pub(super) fn layout(
    root: &Path,
    git: &Path,
    environment: &[(std::ffi::OsString, std::ffi::OsString)],
    runner: &mut Runner,
    window: &ReadWindow,
) -> Result<abird_host_agent::build_executor::preparation::git_context::GitLayout> {
    let mut command = Command::new(git);
    command
        .current_dir(root)
        .env_clear()
        .envs(environment.iter().cloned())
        .args([
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir",
            "--absolute-git-dir",
        ]);
    window.prepare_command(&mut command)?;
    let output = runner.run_while(&mut command, &[], || window.poll())?;
    window.check()?;
    ensure!(
        output.status.success(),
        "native Git layout discovery failed"
    );
    let text = std::str::from_utf8(&output.stdout)?;
    let paths = text.lines().collect::<Vec<_>>();
    ensure!(paths.len() == 2, "ambiguous native Git layout");
    let layout = abird_host_agent::build_executor::preparation::git_context::GitLayout {
        worktree: root.to_owned(),
        common: paths[0].into(),
        git_dir: paths[1].into(),
    };
    layout.validate()?;
    ensure!(
        std::fs::canonicalize(&layout.common)? == layout.common
            && std::fs::canonicalize(&layout.git_dir)? == layout.git_dir,
        "native Git administration redirected"
    );
    Ok(layout)
}

#[allow(clippy::too_many_arguments)]
pub(super) fn capture_git(
    root: &Path,
    program: &Path,
    configuration: &Path,
    caller_digest: &str,
    uid: u32,
    limits: private_tree::Limits,
    deadline: Instant,
    window: &ReadWindow,
) -> Result<GitContext> {
    window.check()?;
    abird_host_agent::build_executor::daemon::trusted_path(configuration)?;
    ensure!(
        configuration.starts_with("/nix/store") && configuration.is_dir(),
        "invalid native NAR configuration"
    );
    let git = root.to_path_buf();
    window.require_path(&git)?;
    ensure!(
        std::fs::symlink_metadata(&git)?.is_dir() && std::fs::canonicalize(&git)? == git,
        "caller Git metadata is not standalone"
    );
    // Linked worktrees and alternate object databases need separate native Git
    // contexts. Do not dereference them or silently clone a different history.
    for name in [
        "commondir",
        "gitdir",
        "objects/info/alternates",
        "objects/info/http-alternates",
    ] {
        match std::fs::symlink_metadata(git.join(name)) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            _ => anyhow::bail!("caller Git metadata requires an external context"),
        }
    }
    let before = Observation::read(&git, uid, limits, deadline)?;
    let mut runner = Runner::new_source(
        uid,
        Limits {
            stdin: 1,
            stdout: MAX_NAR_BYTES,
            stderr: 4096,
        },
        deadline,
        MAX_NAR_BYTES,
    )?;
    let mut command = Command::new(program);
    command
        .env_clear()
        .env("HOME", "/var/empty")
        .env("LC_ALL", "C")
        .env("PATH", "/var/empty")
        .env("NIX_CONF_DIR", configuration)
        .current_dir("/var/empty")
        .arg("--dump")
        .arg(&git);
    window.prepare_command(&mut command)?;
    let output = runner.run_while(&mut command, &[], || window.poll())?;
    window.check()?;
    ensure!(output.status.success(), "caller Git NAR capture failed");
    runner.check_ready()?;
    let after = Observation::read(&git, uid, limits, deadline)?;
    ensure!(
        before == after,
        "caller Git metadata changed during capture"
    );
    window.check()?;
    // Neither this window nor stable metadata closes external profile, worktree
    // attributes, private checkout or actual consumed-root obligations.
    GitContext::new(caller_digest.to_owned(), &output.stdout, before)
}
