//! Capture configuration bytes and ask installed Git to parse include paths.
//! No hand-written Git parser, flattened config replay or missing-file fallback.

use super::{Environment, offline::Runtime};
use abird_host_agent::build_executor::{
    preparation::{
        git_context::window::ReadWindow,
        git_profile::{ConfigImage, MAX_FILES},
    },
    process::Runner,
};
use anyhow::{Context, Result, ensure};
use std::collections::{BTreeSet, VecDeque};
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::time::Instant;

pub(super) fn global(
    environment: &Environment,
    git: &Path,
    runner: &mut Runner,
    window: &mut ReadWindow,
    deadline: Instant,
    runtime: &Runtime,
) -> Result<ConfigImage> {
    // A masked HOME cannot supply authoritative default-file absence: the
    // caller's original-namespace observation binds it; this view must agree.
    // Files are acquired, never replaced by worker config.
    environment.check_defaults()?;
    let roots = environment
        .global_roots()?
        .iter()
        .map(|path| normalize(path))
        .collect::<Result<Vec<_>>>()?;
    let mut image = ConfigImage::new(environment.uid)?;
    extend(
        &mut image,
        roots,
        environment,
        git,
        runner,
        window,
        deadline,
        runtime,
    )?;
    for (path, present) in &environment.defaults {
        if present.is_some()
            && (path.ends_with("git/attributes") || path.ends_with("git/ignore"))
            && !image.contains(path)
        {
            image.capture(path, window, deadline)?;
        }
    }
    environment.check_defaults()?;
    Ok(image)
}

#[allow(clippy::too_many_arguments)]
pub(super) fn local(
    image: &mut ConfigImage,
    root: &Path,
    admin: &Path,
    environment: &Environment,
    git: &Path,
    runner: &mut Runner,
    window: &mut ReadWindow,
    deadline: Instant,
    runtime: &Runtime,
) -> Result<()> {
    window.check()?;
    let mut roots = vec![root.join("config")];
    let worktree = admin.join("config.worktree");
    match std::fs::symlink_metadata(&worktree) {
        Ok(_) => roots.push(worktree),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    extend(
        image,
        roots,
        environment,
        git,
        runner,
        window,
        deadline,
        runtime,
    )?;
    window.check()
}

#[allow(clippy::too_many_arguments)]
fn extend(
    image: &mut ConfigImage,
    roots: impl IntoIterator<Item = PathBuf>,
    environment: &Environment,
    git: &Path,
    runner: &mut Runner,
    window: &mut ReadWindow,
    deadline: Instant,
    runtime: &Runtime,
) -> Result<()> {
    let mut pending: VecDeque<_> = roots.into_iter().collect();
    let mut parsed = BTreeSet::new();
    while let Some(path) = pending.pop_front() {
        ensure!(
            Instant::now() < deadline,
            "private Git profile capture expired"
        );
        if !parsed.insert(path.clone()) {
            continue;
        }
        if !image.contains(&path) {
            image.capture(&path, window, deadline)?;
        }
        let bytes = image.bytes(&path)?;
        // Pure decoder: stdin is the already captured file, --no-includes forbids
        // implicit reads. HOME/NSS still expand native ~ paths. These overrides
        // apply only to this decoder, never the actual caller Git operations.
        let mut command = Command::new(git);
        command
            .current_dir("/var/empty")
            .env_clear()
            .envs(&environment.values)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .args([
                "config",
                "--file",
                "-",
                "--no-includes",
                "--null",
                "--type=path",
                "--get-regexp",
                "^include(if\\..*)?\\.path$",
            ]);
        window.prepare_command(&mut command)?;
        let result =
            runner.run_offline_while(&mut command, &bytes, runtime.decoder()?, || window.poll());
        window.check()?;
        let output = result?;
        let includes = decode(output.status.code(), &output.stdout)?;
        for include in includes {
            let target = include_path(&path, &include)?;
            if !parsed.contains(&target) && !pending.contains(&target) {
                ensure!(
                    image.contains(&target) || image.paths().count() + pending.len() < MAX_FILES,
                    "private Git include count exceeds bound"
                );
                pending.push_back(target);
            }
        }
        // Discover all declared auxiliary file providers from these captured
        // bytes, including inactive conditional-include files. This decoder
        // cannot follow includes or execute caller filters/fsmonitor.
        for key in ["core.attributesFile", "core.excludesFile"] {
            let mut command = Command::new(git);
            command
                .current_dir("/var/empty")
                .env_clear()
                .envs(&environment.values)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .args([
                    "config",
                    "--file",
                    "-",
                    "--no-includes",
                    "--null",
                    "--type=path",
                    "--get-all",
                    key,
                ]);
            window.prepare_command(&mut command)?;
            let output =
                runner.run_offline_while(&mut command, &bytes, runtime.decoder()?, || {
                    window.poll()
                })?;
            window.check()?;
            if output.status.code() == Some(1) {
                ensure!(
                    output.stdout.is_empty(),
                    "ambiguous auxiliary provider absence"
                );
                continue;
            }
            ensure!(
                output.status.success(),
                "Git auxiliary provider decoding failed"
            );
            let values = output
                .stdout
                .strip_suffix(&[0])
                .context("unterminated auxiliary providers")?;
            for value in values.split(|byte| *byte == 0) {
                let provider = Path::new(OsStr::from_bytes(value));
                // Only active providers are required by auxiliary()/the selected
                // checkout check below. Do not turn an inactive missing/relative
                // setting into a different effective Git profile.
                if !provider.is_absolute() {
                    continue;
                }
                let provider = normalize(provider)?;
                match std::fs::metadata(&provider) {
                    Ok(metadata) if metadata.is_file() && !image.contains(&provider) => {
                        image.capture(&provider, window, deadline)?;
                    }
                    Ok(_) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => return Err(error.into()),
                }
            }
        }
        image.check_live(deadline)?;
        window.check()?;
    }
    Ok(())
}

/// Attribute/ignore files are Git data dependencies, not arbitrary helpers.
/// Capture present absolute providers rather than silently dropping them from
/// the private HOME. A missing explicit provider or a mutable live-default
/// namespace cannot be approximated as an empty profile.
#[allow(clippy::too_many_arguments)]
pub(super) fn auxiliary(
    image: &mut ConfigImage,
    root: &Path,
    environment: &Environment,
    git: &Path,
    runner: &mut Runner,
    window: &mut ReadWindow,
    deadline: Instant,
    read_roots: &[std::path::PathBuf],
) -> Result<()> {
    for (path, explicit) in auxiliary_paths(root, environment, git, runner, window)? {
        match std::fs::symlink_metadata(&path) {
            Ok(_) => {
                if !image.contains(&path) {
                    image.capture(&path, window, deadline)?;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                ensure!(
                    !explicit && !read_roots.iter().any(|root| path.starts_with(root)),
                    "missing Git auxiliary provider requires a frozen explicit context"
                );
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

pub(super) fn require_bound_auxiliary(
    image: &ConfigImage,
    root: &Path,
    environment: &Environment,
    git: &Path,
    runner: &mut Runner,
    window: &ReadWindow,
) -> Result<()> {
    for (path, explicit) in auxiliary_paths(root, environment, git, runner, window)? {
        ensure!(
            image.contains(&path)
                || (!explicit
                    && environment.defaults.get(&path).is_some_and(Option::is_none)
                    && matches!(std::fs::symlink_metadata(&path), Err(error)
                if error.kind() == std::io::ErrorKind::NotFound)),
            "selected checkout activates an uncaptured Git data provider"
        );
    }
    Ok(())
}

fn auxiliary_paths(
    root: &Path,
    environment: &Environment,
    git: &Path,
    runner: &mut Runner,
    window: &ReadWindow,
) -> Result<Vec<(PathBuf, bool)>> {
    let values = environment.installed()?;
    let home = PathBuf::from(
        environment
            .values
            .get("HOME")
            .context("caller HOME missing")?,
    );
    let xdg = environment
        .values
        .get("XDG_CONFIG_HOME")
        .filter(|value| !value.is_empty())
        .map_or_else(|| home.join(".config"), PathBuf::from);
    let mut paths = Vec::new();
    for (key, default) in [
        ("core.attributesFile", "attributes"),
        ("core.excludesFile", "ignore"),
    ] {
        let mut command = Command::new(git);
        command
            .current_dir(root)
            .env_clear()
            .envs(values.iter().cloned())
            .args(["config", "--null", "--path", "--get", key]);
        window.prepare_command(&mut command)?;
        let output = runner.run_while(&mut command, &[], || window.poll())?;
        window.check()?;
        let explicit = output.status.success();
        let path = if explicit {
            let bytes = output
                .stdout
                .strip_suffix(&[0])
                .context("unterminated Git auxiliary path")?;
            ensure!(!bytes.contains(&0), "ambiguous Git auxiliary path");
            PathBuf::from(OsStr::from_bytes(bytes))
        } else {
            ensure!(
                output.status.code() == Some(1) && output.stdout.is_empty(),
                "Git auxiliary path selection failed"
            );
            xdg.join("git").join(default)
        };
        ensure!(
            path.is_absolute(),
            "relative Git auxiliary provider needs an explicit context"
        );
        paths.push((normalize(&path)?, explicit));
    }
    Ok(paths)
}

/// Optional external filters can silently substitute unfiltered bytes when
/// offline dependencies fail. Keep Git's required-filter failure semantics;
/// fsmonitor's ordinary full-scan fallback is not a content substitution.
pub(super) fn require_filters(
    root: &Path,
    git: &Path,
    environment: &[(std::ffi::OsString, std::ffi::OsString)],
    runner: &mut Runner,
    window: &ReadWindow,
) -> Result<()> {
    let mut command = Command::new(git);
    command
        .current_dir(root)
        .env_clear()
        .envs(environment.iter().cloned())
        .args([
            "config",
            "--null",
            "--name-only",
            "--get-regexp",
            "^filter\\..*\\.(clean|smudge|process)$",
        ]);
    window.prepare_command(&mut command)?;
    let output = runner.run_while(&mut command, &[], || window.poll())?;
    window.check()?;
    if output.status.code() == Some(1) {
        ensure!(
            output.stdout.is_empty(),
            "ambiguous external-filter absence"
        );
        return Ok(());
    }
    ensure!(
        output.status.success() && output.stdout.last() == Some(&0),
        "native filter discovery failed"
    );
    let keys = std::str::from_utf8(&output.stdout)?;
    let mut filters = std::collections::BTreeSet::new();
    for key in keys.split('\0').filter(|key| !key.is_empty()) {
        let (prefix, _) = key.rsplit_once('.').context("invalid native filter key")?;
        ensure!(filters.len() < 64, "native filter count exceeds bound");
        filters.insert(prefix);
    }
    for filter in filters {
        let mut command = Command::new(git);
        command
            .current_dir(root)
            .env_clear()
            .envs(environment.iter().cloned())
            .args(["config", "--type=bool", "--get"])
            .arg(format!("{filter}.required"));
        window.prepare_command(&mut command)?;
        let output = runner.run_while(&mut command, &[], || window.poll())?;
        window.check()?;
        ensure!(
            output.status.success() && output.stdout == b"true\n",
            "offline capture requires external Git filters to declare required=true"
        );
    }
    Ok(())
}

fn decode(status: Option<i32>, bytes: &[u8]) -> Result<Vec<PathBuf>> {
    if status == Some(1) {
        ensure!(bytes.is_empty(), "ambiguous native Git include absence");
        return Ok(Vec::new());
    }
    ensure!(status == Some(0), "native Git include parsing failed");
    let fields = bytes
        .strip_suffix(&[0])
        .context("unterminated native Git includes")?;
    let mut result = Vec::new();
    for field in fields.split(|byte| *byte == 0) {
        let at = field
            .iter()
            .position(|byte| *byte == b'\n')
            .context("native Git include value missing")?;
        let (key, value) = (&field[..at], &field[at + 1..]);
        ensure!(
            result.len() < MAX_FILES
                && !value.is_empty()
                && !value.contains(&b'\n')
                && (key == b"include.path"
                    || (key.starts_with(b"includeif.") && key.ends_with(b".path"))),
            "invalid native Git include record"
        );
        result.push(PathBuf::from(OsStr::from_bytes(value)));
    }
    Ok(result)
}

fn include_path(source: &Path, include: &Path) -> Result<PathBuf> {
    if include.is_absolute() {
        return normalize(include);
    }
    let parent = source.parent().context("Git include parent missing")?;
    let mut target = parent.to_path_buf();
    let mut entered = false;
    for part in include.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                ensure!(
                    !entered && std::fs::canonicalize(parent)? == parent,
                    "Git include upward traversal requires its original namespace"
                );
                ensure!(target.pop(), "Git include escapes root");
            }
            Component::Normal(name) => {
                entered = true;
                target.push(name);
            }
            _ => anyhow::bail!("invalid relative Git include"),
        }
    }
    normalize(&target)
}

fn normalize(path: &Path) -> Result<PathBuf> {
    ensure!(
        path.is_absolute() && path.as_os_str().len() <= 4096,
        "Git configuration path must be absolute"
    );
    let mut result = PathBuf::from("/");
    for part in path.components() {
        match part {
            Component::RootDir | Component::CurDir => {}
            Component::Normal(name) => result.push(name),
            Component::ParentDir => {
                anyhow::bail!("Git configuration upward traversal requires its original namespace")
            }
            Component::Prefix(_) => anyhow::bail!("invalid Git configuration path prefix"),
        }
    }
    // ConfigImage captures aliases before reading; never canonicalize them away.
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn includes_use_the_logical_file_parent_and_never_erase_alias_traversal() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        std::fs::create_dir(root.join("elsewhere")).unwrap();
        std::fs::write(root.join("elsewhere/config"), b"# fixture").unwrap();
        let source = root.join("global");
        std::os::unix::fs::symlink("elsewhere/config", &source).unwrap();
        assert_eq!(normalize(&source).unwrap(), source);
        assert_eq!(
            include_path(&source, Path::new("sibling")).unwrap(),
            root.join("sibling")
        );
        assert_eq!(
            include_path(&source, Path::new("../sibling")).unwrap(),
            root.parent().unwrap().join("sibling")
        );
        assert!(include_path(&source, Path::new("other/../sibling")).is_err());
        assert!(normalize(&root.join("elsewhere/../config")).is_err());
        assert!(normalize(Path::new("relative")).is_err());
    }

    #[test]
    fn native_includes_preserve_conditional_paths_without_selecting_or_flattening_them() {
        let paths = decode(Some(0), b"include.path\ncommon.gitconfig\0includeif.gitdir:/original/worktrees/.path\n/worktree/profile\0").unwrap();
        assert_eq!(
            paths,
            vec![
                PathBuf::from("common.gitconfig"),
                PathBuf::from("/worktree/profile")
            ]
        );
        assert!(decode(Some(1), b"").unwrap().is_empty());
        assert!(decode(Some(1), b"partial").is_err());
        assert!(decode(Some(128), b"").is_err());
        assert!(decode(None, b"").is_err());
        assert!(decode(Some(0), b"include.path\nmissing-terminator").is_err());
        assert!(decode(Some(0), b"other.path\n/value\0").is_err());
    }
}
