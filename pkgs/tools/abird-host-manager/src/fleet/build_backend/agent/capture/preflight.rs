//! Trusted filesystem/profile discovery before ordinary Git. This selects only
//! candidate administrative/config paths; native Git subsequently verifies the
//! exact root/common/admin layout. No include is opened by unrestricted Git.
use super::{Environment, config, contexts, offline::Runtime};
use abird_host_agent::build_executor::{
    native_intent::CaptureInput,
    preparation::{
        git_context::{GitLayout, window::ReadWindow},
        git_profile::ConfigImage,
    },
    process::Runner,
};
use anyhow::{Context, Result, ensure};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

#[allow(clippy::too_many_arguments)]
pub(super) fn prepare(
    input: &CaptureInput,
    cwd: &Path,
    environment: &Environment,
    configuration: &mut ConfigImage,
    git: &Path,
    runner: &mut Runner,
    window: &mut ReadWindow,
    runtime: &Runtime,
    deadline: Instant,
    invocation: &crate::fleet::cli::Invocation,
) -> Result<GitLayout> {
    let root = crate::fleet::runtime::find_repository_root(cwd)?;
    let primary = layout(&root, input, configuration, window, deadline)?;
    window.bind_git(&primary.common)?;
    let pinned = crate::fleet::runtime::pin_inventory_input_at(
        invocation,
        &root,
        crate::fleet::inventory_overlay::OverlayPolicy::Allowed,
        cwd,
        false,
    )?;
    let mut repositories = BTreeSet::from([root.clone()]);
    for path in std::iter::once(&pinned.source_config).chain(pinned.overlay.iter()) {
        let path = contexts::normalize(path)?;
        ensure!(
            input.roots.iter().any(|root| path.starts_with(root)),
            "profile context outside declared capture roots"
        );
        let parent = path.parent().context("profile context parent missing")?;
        if let Ok(repository) = crate::fleet::runtime::find_repository_root(parent) {
            repositories.insert(repository);
        }
    }
    let mut reads = BTreeSet::new();
    for root in repositories {
        let image = if root == primary.worktree {
            primary.clone()
        } else {
            layout(&root, input, configuration, window, deadline)?
        };
        if image.common != primary.common {
            window.extend_git(&image.common)?;
        }
        config::local(
            configuration,
            &image.common,
            &image.git_dir,
            environment,
            git,
            runner,
            window,
            deadline,
            runtime,
        )?;
        reads.insert(image.worktree);
        reads.insert(image.common);
    }
    // A standalone overlay has no Git root but still needs its bounded sibling
    // import context. Do not turn a declared parent allowance into a whole-HOME scan.
    if let Some(path) = &pinned.overlay {
        let path = contexts::normalize(path)?;
        let parent = path.parent().context("overlay parent missing")?;
        if crate::fleet::runtime::find_repository_root(parent).is_err() {
            reads.insert(parent.to_owned());
        }
    }
    reads.extend(configuration.paths().map(Path::to_owned));
    let mut minimal: Vec<PathBuf> = Vec::new();
    for path in reads {
        if !minimal.iter().any(|parent| path.starts_with(parent)) {
            minimal.push(path);
        }
    }
    runtime
        .policy(
            &minimal,
            &[
                Path::new("/tmp"),
                Path::new("/var/tmp"),
                Path::new("/dev/shm"),
            ],
            true,
        )?
        .enter()?;
    abird_host_agent::build_executor::process::offline::require_read_scope()?;
    Ok(primary)
}

fn layout(
    root: &Path,
    input: &CaptureInput,
    configuration: &mut ConfigImage,
    window: &mut ReadWindow,
    deadline: Instant,
) -> Result<GitLayout> {
    ensure!(
        fs::canonicalize(root)? == root
            && input.roots.iter().any(|allowed| root.starts_with(allowed)),
        "candidate Git root is outside the declared namespace"
    );
    let marker = root.join(".git");
    window.hold_source_directory(root)?;
    let metadata = fs::symlink_metadata(&marker)?;
    let admin = if metadata.is_dir() {
        marker
    } else {
        ensure!(metadata.is_file(), "unsupported Git marker type");
        let text = captured_text(&marker, configuration, window, deadline)?;
        let path = text
            .strip_prefix("gitdir: ")
            .context("unsupported Git file format")?;
        fs::canonicalize(root.join(path))?
    };
    ensure!(
        input.roots.iter().any(|allowed| admin.starts_with(allowed)),
        "candidate Git administration outside declared roots"
    );
    window.hold_source_directory(&admin)?;
    let pointer = admin.join("commondir");
    let common = match fs::symlink_metadata(&pointer) {
        Ok(metadata) => {
            ensure!(metadata.is_file(), "unsupported common Git pointer");
            fs::canonicalize(admin.join(captured_text(&pointer, configuration, window, deadline)?))?
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => admin.clone(),
        Err(error) => return Err(error.into()),
    };
    ensure!(
        input
            .roots
            .iter()
            .any(|allowed| common.starts_with(allowed)),
        "candidate common Git directory outside declared roots"
    );
    let value = GitLayout {
        worktree: root.to_owned(),
        common,
        git_dir: admin,
    };
    value.validate()?;
    Ok(value)
}

fn captured_text(
    path: &Path,
    configuration: &mut ConfigImage,
    window: &mut ReadWindow,
    deadline: Instant,
) -> Result<String> {
    if !configuration.contains(path) {
        configuration.capture(path, window, deadline)?;
    }
    let bytes = configuration.bytes(path)?;
    let text = std::str::from_utf8(&bytes)?
        .strip_suffix('\n')
        .unwrap_or(std::str::from_utf8(&bytes)?);
    ensure!(
        !text.is_empty() && !text.contains(['\n', '\r', '\0']),
        "invalid Git administrative pointer"
    );
    Ok(text.to_owned())
}
