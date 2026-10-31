//! Operator inventory overlay selection.
//!
//! One resolver for the native fleet CLI and the host-manager adapter so
//! `--config-override`, `--no-override` and the environment form cannot drift
//! apart.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

/// Environment variables naming an explicit operator overlay, highest first.
pub const OVERLAY_ENVIRONMENT: [&str; 2] = [
    "ABIRD_HOST_MANAGER_CONFIG_OVERRIDE",
    "NIXBOT_CONFIG_OVERRIDE_PATH",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OverlayPolicy {
    Allowed,
    Forbidden,
}

/// Resolve and pin the operator overlay before a worktree or re-exec can change
/// the config sibling or relative-path base.
pub fn resolve(
    config: &Path,
    explicit: Option<&Path>,
    no_override: bool,
) -> Result<Option<PathBuf>> {
    resolve_from(
        config,
        explicit,
        no_override,
        OverlayPolicy::Allowed,
        &std::env::current_dir().context("resolve operator overlay from current directory")?,
    )
}

pub fn reject_managed_explicit_input(explicit: Option<&Path>, managed: bool) -> Result<()> {
    if !managed {
        return Ok(());
    }
    if explicit.is_some() {
        bail!("Nixbot config overrides are allowed only for direct developer execution");
    }
    for environment in OVERLAY_ENVIRONMENT {
        if std::env::var_os(environment).is_some_and(|value| !value.is_empty()) {
            bail!("Nixbot config overrides are allowed only for direct developer execution");
        }
    }
    Ok(())
}

pub fn resolve_from(
    config: &Path,
    explicit: Option<&Path>,
    no_override: bool,
    policy: OverlayPolicy,
    invocation_cwd: &Path,
) -> Result<Option<PathBuf>> {
    if policy == OverlayPolicy::Forbidden {
        if explicit.is_some() {
            bail!("CI inventory forbids --config-override");
        }
        for environment in OVERLAY_ENVIRONMENT {
            if std::env::var_os(environment).is_some_and(|value| !value.is_empty()) {
                bail!("CI inventory forbids {environment}");
            }
        }
        return Ok(None);
    }
    if no_override {
        return Ok(None);
    }
    if let Some(path) = explicit {
        let path = absolute_from(path, invocation_cwd);
        if !path.is_file() {
            bail!("--config-override does not name a file: {}", path.display());
        }
        return Ok(Some(path));
    }
    for environment in OVERLAY_ENVIRONMENT {
        let Some(value) = std::env::var_os(environment).filter(|value| !value.is_empty()) else {
            continue;
        };
        let path = absolute_from(Path::new(&value), invocation_cwd);
        if !path.is_file() {
            bail!("{environment} does not name a file: {}", path.display());
        }
        return Ok(Some(path));
    }
    let stem = config
        .file_stem()
        .and_then(|value| value.to_str())
        .context("Nixbot config filename is not valid UTF-8")?;
    let sibling = config.with_file_name(format!("{stem}.override.nix"));
    Ok(sibling.is_file().then_some(sibling))
}

fn absolute_from(path: &Path, cwd: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        cwd.join(path)
    }
}

/// Re-state the parser's winning explicit overlay for a repository re-exec.
///
/// The repository re-exec runs from a worktree, so a relative operator path
/// would resolve against the wrong directory. The CLI already decided which
/// token is a value and which is an override, so never rescan argv: a value
/// such as `--known-hosts --config-override=literal` is data. Preserve every
/// original argv byte and append the absolute winning flag; last-flag-wins
/// makes that trailing flag authoritative. File existence is not checked here:
/// a missing explicit overlay must still fail when the inventory loads.
pub fn normalize_reexec_arguments(
    arguments: &[String],
    pinned_overlay: Option<&Path>,
) -> Vec<String> {
    let mut normalized = arguments.to_vec();
    match pinned_overlay {
        Some(path) => {
            normalized.push("--config-override".to_owned());
            normalized.push(path.to_string_lossy().into_owned());
        }
        None => normalized.push("--no-override".to_owned()),
    }
    normalized
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_override_skips_the_environment_and_the_sibling() {
        // The flag must win over any named overlay, otherwise a controller run
        // could pick up operator settings it cannot see.
        assert_eq!(
            resolve(Path::new("/nonexistent/hosts.nix"), None, true).unwrap(),
            None
        );
        assert_eq!(
            resolve(
                Path::new("/nonexistent/hosts.nix"),
                Some(Path::new("/x.nix")),
                true
            )
            .unwrap(),
            None
        );
    }

    #[test]
    fn explicit_overlay_outranks_the_sibling() {
        let temporary = tempfile::tempdir().unwrap();
        let config = temporary.path().join("nixbot.nix");
        std::fs::write(&config, "{}\n").unwrap();
        std::fs::write(temporary.path().join("nixbot.override.nix"), "{}\n").unwrap();
        let explicit = temporary.path().join("operator.override.nix");
        std::fs::write(&explicit, "{}\n").unwrap();
        assert_eq!(
            resolve(&config, Some(&explicit), false).unwrap(),
            Some(explicit.clone())
        );

        let missing = temporary.path().join("gone.override.nix");
        let error = resolve(&config, Some(&missing), false)
            .unwrap_err()
            .to_string();
        assert!(error.contains("--config-override"), "{error}");
    }

    #[test]
    fn missing_sibling_is_not_an_error() {
        let temporary = tempfile::tempdir().unwrap();
        let config = temporary.path().join("nixbot.nix");
        std::fs::write(&config, "{}\n").unwrap();
        assert_eq!(resolve(&config, None, false).unwrap(), None);

        let sibling = temporary.path().join("nixbot.override.nix");
        std::fs::write(&sibling, "{}\n").unwrap();
        assert_eq!(resolve(&config, None, false).unwrap(), Some(sibling));
    }

    #[test]
    fn reexec_arguments_pin_the_resolved_overlay_or_its_absence() {
        let arguments = vec!["build".to_owned(), "--use-repo-script".to_owned()];
        assert_eq!(
            normalize_reexec_arguments(
                &arguments,
                Some(Path::new("/source/hosts/nixbot.override.nix")),
            ),
            [
                "build",
                "--use-repo-script",
                "--config-override",
                "/source/hosts/nixbot.override.nix",
            ]
        );
        assert_eq!(
            normalize_reexec_arguments(&arguments, None),
            ["build", "--use-repo-script", "--no-override"]
        );
    }

    #[test]
    fn managed_execution_rejects_explicit_operator_input_before_resolution() {
        let explicit = Path::new("missing-operator.nix");
        let error = reject_managed_explicit_input(Some(explicit), true)
            .unwrap_err()
            .to_string();
        assert!(error.contains("direct developer execution"), "{error}");
        reject_managed_explicit_input(Some(explicit), false).unwrap();
    }

    #[test]
    fn forbidden_policy_ignores_only_the_implicit_sibling() {
        let temporary = tempfile::tempdir().unwrap();
        let config = temporary.path().join("nixbot.nix");
        std::fs::write(&config, "{}\n").unwrap();
        std::fs::write(temporary.path().join("nixbot.override.nix"), "{}\n").unwrap();
        assert_eq!(
            resolve_from(
                &config,
                None,
                false,
                OverlayPolicy::Forbidden,
                temporary.path(),
            )
            .unwrap(),
            None
        );
        assert!(
            resolve_from(
                &config,
                Some(Path::new("operator.nix")),
                false,
                OverlayPolicy::Forbidden,
                temporary.path(),
            )
            .is_err()
        );
    }
}
