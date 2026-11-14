//! Installed source producer/observer. Root owns admission, the original cap,
//! producer settlement and fresh-inode sealing. No native store access here.

use std::ffi::OsString;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use abird_host_agent::build_executor::preparation::source::{
    MAX_PATCH_BYTES, ProducerInput, unhex,
};
use abird_host_agent::build_executor::process::{Limits, Runner};
use anyhow::{Context, Result, ensure};

use super::repository::RepositoryCommands;
use super::source::SourceRecipe;
use crate::fleet::repository::{CommitSha, StagedPatch};

pub fn run(input: ProducerInput, git: PathBuf, produce: bool) -> Result<String> {
    execute(&input, git, produce, Ok)
}

/// Resolve ordinary CI metadata from the actual selected checkout, not from the
/// receiving account's current HEAD or a reconstructed operator filesystem.
pub fn repository(
    input: abird_host_agent::build_executor::preparation::source::RepositoryInput,
    git: PathBuf,
) -> Result<abird_host_agent::build_executor::preparation::source::RepositoryOutput> {
    use crate::fleet::build_backend::agent::controller::{
        CapturedSource, InvocationRecord, Locations, Submission, configured_invocation,
    };
    input.validate()?;
    let invocation = configured_invocation(
        &input.intent,
        &input.producer.source,
        input.producer.patch.is_some(),
    )?;
    let patch = input
        .producer
        .patch
        .as_ref()
        .map(|bytes| -> Result<StagedPatch> {
            Ok(StagedPatch {
                base: CommitSha::parse(input.producer.source.base_revision.clone())?,
                bytes: unhex(bytes, MAX_PATCH_BYTES)?,
            })
        })
        .transpose()?;
    let source = CapturedSource::new(
        CommitSha::parse(input.producer.source.revision.clone())?,
        patch,
        Default::default(),
    )?;
    let config = invocation
        .options
        .config
        .as_deref()
        .unwrap_or_else(|| std::path::Path::new("hosts/nixbot.nix"));
    let relative = if config.is_absolute() {
        config
            .strip_prefix(&input.source_root)
            .context("CI inventory must belong to the configured repository")?
    } else {
        config
    };
    ensure!(
        relative
            .components()
            .all(|part| matches!(part, std::path::Component::Normal(_)))
            && !relative.as_os_str().is_empty(),
        "CI inventory must be repository-relative"
    );
    let checkout = input.producer.directory.join("repository");
    let config = checkout.join(relative);
    execute(&input.producer, git, true, |observation| {
        let context = crate::fleet::runtime::inventory_context(config, None)?;
        let locations =
            Locations::from_native(&checkout, &checkout, &context, &Default::default())?;
        let material = Submission::resolve_capture(
            InvocationRecord {
                caller: invocation.clone(),
                effective: invocation,
                source_root: input.source_root.clone(),
                caller_repository: None,
                locations,
                ci_argv: None,
                git_context_digest: None,
                checkout: None,
            },
            source,
            &input.intent,
        )?;
        ensure!(
            material.request.source == input.producer.source,
            "CI source recipe changed"
        );
        Ok(
            abird_host_agent::build_executor::preparation::source::RepositoryOutput {
                observation,
                material,
            },
        )
    })
}

fn execute<T>(
    input: &ProducerInput,
    git: PathBuf,
    produce: bool,
    finish: impl FnOnce(String) -> Result<T>,
) -> Result<T> {
    input.validate()?;
    abird_host_agent::build_executor::workload::require_wrapper_placement()?;
    let uid = unsafe { libc::geteuid() };
    ensure!(
        uid > 0 && uid < u32::MAX,
        "source helper must be unprivileged"
    );
    ensure!(
        git.is_absolute()
            && git.starts_with("/nix/store")
            && git.file_name().is_some_and(|name| name == "git"),
        "invalid source Git executable"
    );
    let patch = input
        .patch
        .as_ref()
        .map(|bytes| -> Result<StagedPatch> {
            Ok(StagedPatch {
                base: CommitSha::parse(input.source.base_revision.clone())?,
                bytes: unhex(bytes, MAX_PATCH_BYTES)?,
            })
        })
        .transpose()?;
    let recipe = SourceRecipe::bind(&input.source, patch)?;
    let mut environment = Vec::new();
    for name in [
        "HOME",
        "LC_ALL",
        "PATH",
        "GIT_CONFIG_GLOBAL",
        "GIT_CONFIG_NOSYSTEM",
    ] {
        environment.push((
            OsString::from(name),
            std::env::var_os(name).context("source environment missing")?,
        ));
    }
    environment.push(("GIT_OPTIONAL_LOCKS".into(), "0".into()));
    environment.push(("GIT_TERMINAL_PROMPT".into(), "0".into()));
    let repository = input.directory.join("repository");
    let commands = RepositoryCommands::new(
        git,
        input.directory.clone(),
        vec![repository.clone()],
        environment,
    )?;
    let deadline = Instant::now()
        .checked_add(Duration::from_millis(input.budget_millis))
        .context("source deadline overflow")?;
    let mut runner = Runner::new(
        uid,
        Limits {
            stdin: MAX_PATCH_BYTES,
            stdout: 16 * 1024 * 1024,
            stderr: 128 * 1024,
        },
        deadline,
    )?;
    let runtime =
        super::source_scope::Runtime::load(&input.runtime_closure, input.limits, deadline)?;
    let profile = PathBuf::from(
        std::env::var_os("GIT_CONFIG_GLOBAL").context("installed source profile missing")?,
    );
    abird_host_agent::build_executor::daemon::trusted_path(&profile)?;
    let restrict = |root: &std::path::Path, writable: bool| -> Result<()> {
        let reads = vec![root.to_owned(), profile.clone()];
        let writes = if writable { vec![root] } else { Vec::new() };
        // This legacy source-UID producer does not claim a private PID/proc
        // view. Only caller/capture entries may grant their fresh proc mount.
        runtime.policy(&reads, &writes, false)?.enter()?;
        abird_host_agent::build_executor::process::offline::require_read_scope()?;
        Ok(())
    };
    if !produce {
        restrict(&repository, false)?;
    }
    commands.with_repository(&mut runner, |manager| {
        let observation = if produce {
            recipe.installed_checkout(manager, &input.directory, &input.url, |root| {
                restrict(root, true)
            })?
        } else {
            recipe.observe_installed(manager, &repository)?
        };
        finish(observation)
    })
}
