//! Caller data contexts. Preserve relative imports without putting overrides in
//! a Git index or publishing Git administration. Source selection stays native.
use std::collections::BTreeSet;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::os::unix::{ffi::OsStrExt, fs::PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use abird_host_agent::build_executor::{
    preparation::{git_context::window::ReadWindow, source::MAX_MATERIAL_BYTES},
    private_tree,
    process::{Limits, Runner},
};
use abird_host_agent::sha256::digest_bytes;
use anyhow::{Context, Result, ensure};

/// Snapshot the live tracked working view plus the selected file's sibling
/// subtree. This covers ordinary local overlays and relative module imports.
/// Unbound imports outside this declared tree are not a supported impure input.
#[allow(clippy::too_many_arguments)]
pub(super) fn snapshot(
    root: &Path,
    selected: &Path,
    git: &Path,
    nar: &Path,
    nar_configuration: &Path,
    environment: &[(OsString, OsString)],
    runner: &mut Runner,
    window: &mut ReadWindow,
    limits: private_tree::Limits,
    deadline: Instant,
) -> Result<(String, Vec<u8>, String)> {
    ensure!(
        selected.starts_with(root),
        "context file outside its import root"
    );
    let mut paths = BTreeSet::new();
    if root.join(".git").exists() {
        // A data-only overlay may live in another Git repository. Its index
        // chooses the tracked import closure too; do not read that list outside
        // the same coherent window merely because this is not a flake root.
        let layout = super::git::layout(root, git, environment, runner, window)?;
        let index = layout.git_dir.join("index");
        match fs::symlink_metadata(&index) {
            Ok(_) => window.hold_source_file(&index)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                window.hold_source_directory(&layout.git_dir)?
            }
            Err(error) => return Err(error.into()),
        }
        let mut command = Command::new(git);
        command
            .current_dir(root)
            .env_clear()
            .envs(environment.iter().cloned())
            .args(["ls-files", "--cached", "-z"]);
        window.prepare_command(&mut command)?;
        let result = runner.run_while(&mut command, &[], || window.poll())?;
        ensure!(
            result.status.success(),
            "context tracked-path discovery failed"
        );
        ensure!(
            result.stdout.is_empty() || result.stdout.last() == Some(&0),
            "unterminated context paths"
        );
        for name in result
            .stdout
            .split(|b| *b == 0)
            .filter(|name| !name.is_empty())
        {
            let path = PathBuf::from(OsStr::from_bytes(name));
            relative(&path)?;
            paths.insert(path);
        }
    }
    let parent = selected.parent().context("context parent missing")?;
    collect(root, parent, &mut paths, limits, deadline, window)?;
    let temporary = tempfile::Builder::new()
        .prefix("owned-context-")
        .tempdir_in("/tmp")?;
    let tree = temporary.path().join("tree");
    fs::create_dir(&tree)?;
    let mut bytes = 0u64;
    for relative in paths {
        ensure!(Instant::now() < deadline, "context capture expired");
        prohibited(&relative)?;
        let source = root.join(&relative);
        window.hold_source_directory(source.parent().context("source parent missing")?)?;
        let metadata = match fs::symlink_metadata(&source) {
            Ok(value) => value,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        };
        if metadata.is_dir() {
            continue;
        } // gitlinks are not imported recursively
        let destination = tree.join(&relative);
        fs::create_dir_all(
            destination
                .parent()
                .context("context destination parent missing")?,
        )?;
        if metadata.is_symlink() {
            window.hold_source_link(&source)?;
            std::os::unix::fs::symlink(fs::read_link(&source)?, &destination)?;
        } else {
            ensure!(metadata.is_file(), "unsupported context file type");
            window.hold_source_file(&source)?;
            let metadata = fs::symlink_metadata(&source)?;
            bytes = bytes
                .checked_add(metadata.len())
                .context("context size overflow")?;
            ensure!(
                bytes <= limits.bytes,
                "context exceeds declared source bytes"
            );
            fs::copy(&source, &destination)?;
            fs::set_permissions(
                &destination,
                fs::Permissions::from_mode(if metadata.permissions().mode() & 0o100 != 0 {
                    0o700
                } else {
                    0o600
                }),
            )?;
        }
        window.check()?;
    }
    let mut capture = Runner::new_source(
        unsafe { libc::geteuid() },
        Limits {
            stdin: 1,
            stdout: (limits.bytes as usize)
                .saturating_add(1024 * 1024)
                .min(MAX_MATERIAL_BYTES / 2),
            stderr: 4096,
        },
        deadline,
        MAX_MATERIAL_BYTES / 2,
    )?;
    let mut command = Command::new(nar);
    command
        .env_clear()
        .env("HOME", "/var/empty")
        .env("PATH", "/var/empty")
        .env("NIX_CONF_DIR", nar_configuration)
        .current_dir("/var/empty")
        .arg("--dump")
        .arg(&tree);
    window.prepare_command(&mut command)?;
    let output = capture.run_while(&mut command, &[], || window.poll())?;
    ensure!(output.status.success(), "context NAR capture failed");
    window.check()?;
    Ok((
        digest_bytes(&output.stdout),
        output.stdout,
        selected
            .strip_prefix(root)?
            .to_str()
            .context("non-UTF8 context file")?
            .to_owned(),
    ))
}

fn collect(
    root: &Path,
    directory: &Path,
    paths: &mut BTreeSet<PathBuf>,
    limits: private_tree::Limits,
    deadline: Instant,
    window: &mut ReadWindow,
) -> Result<()> {
    window.hold_source_directory(directory)?;
    let relative = directory.strip_prefix(root)?;
    ensure!(
        relative.components().count() < usize::from(limits.depth),
        "context depth exceeds bound"
    );
    for entry in fs::read_dir(directory)? {
        ensure!(
            Instant::now() < deadline && paths.len() < limits.entries as usize,
            "context entry/deadline bound exceeded"
        );
        let entry = entry?;
        if entry.file_name() == ".git" {
            continue;
        }
        let path = entry.path();
        let relative = path.strip_prefix(root)?.to_owned();
        prohibited(&relative)?;
        if entry.file_type()?.is_dir() {
            collect(root, &path, paths, limits, deadline, window)?;
        } else {
            paths.insert(relative);
        }
    }
    Ok(())
}

pub(super) fn normalize(path: &Path) -> Result<PathBuf> {
    ensure!(path.is_absolute(), "context path must be absolute");
    let mut result = PathBuf::from("/");
    for part in path.components() {
        match part {
            std::path::Component::RootDir | std::path::Component::CurDir => {}
            std::path::Component::Normal(name) => result.push(name),
            std::path::Component::ParentDir => {
                ensure!(
                    fs::canonicalize(&result)? == result,
                    "context traversal crosses an unbound alias"
                );
                ensure!(result.pop(), "context path escapes root");
            }
            _ => anyhow::bail!("invalid context path"),
        }
    }
    Ok(result)
}

fn relative(path: &Path) -> Result<()> {
    ensure!(
        !path.as_os_str().is_empty()
            && path
                .components()
                .all(|part| matches!(part, std::path::Component::Normal(_))),
        "invalid context relative path"
    );
    prohibited(path)
}
fn prohibited(path: &Path) -> Result<()> {
    ensure!(
        !path.components().any(|part| matches!(part,
        std::path::Component::Normal(name) if name == ".git"))
            && path.extension().is_none_or(|extension| extension != "key"),
        "context enters Git administration or prohibited key material"
    );
    Ok(())
}
