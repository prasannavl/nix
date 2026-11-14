//! Original caller checkout inside the root-installed private path view. Local
//! and remote orchestration share this operation; neither reselects a ref.
use crate::fleet::build_backend::agent::{controller::InvocationRecord, run::Run};
use crate::fleet::preparation::{
    repository::{RepositoryCommands, SearchView},
    source::SourceRecipe,
};
use crate::fleet::repository::{CommitSha, StagedPatch};
use crate::fleet::run_state::RunState;
use abird_host_agent::build_executor::preparation::source::{MAX_PATCH_BYTES, unhex};
use abird_host_agent::build_executor::{
    native_intent::CheckoutInput,
    process::{Limits, Runner},
};
use anyhow::{Context, Result, ensure};
use std::ffi::OsString;
use std::path::PathBuf;
use std::time::{Duration, Instant};

pub fn run(input: CheckoutInput, git: PathBuf) -> Result<String> {
    input.validate()?;
    let intent = input
        .validation
        .request
        .parent
        .as_ref()
        .context("checkout parent missing")?;
    let manifest = Run::inspect(&intent.run_id)?;
    let child = manifest
        .children
        .get(&intent.attempt_id()?)
        .context("checkout child missing")?;
    child.require_local_capture(intent, &input.delivery_digest)?;
    let pending = child
        .pending_capture()
        .context("checkout caller context missing")?;
    pending.validate(intent)?;
    let expected =
        crate::fleet::build_backend::agent::controller::preparation_invocation(&pending.invocation);
    let record: InvocationRecord = serde_json::from_value(input.validation.context.clone())?;
    ensure!(
        record.caller == expected && record.effective == expected,
        "caller checkout invocation differs"
    );
    execute(
        &input,
        git,
        pending
            .environment
            .as_ref()
            .context("checkout profile missing")?,
    )?;
    // Initial admission binds pending bytes; the original worker owns liveness.
    // Never reread the observer's replaceable manifest after entering offline.
    input.validation.request.binding_digest()
}

pub(super) fn execute(
    input: &CheckoutInput,
    git: PathBuf,
    environment: &super::Environment,
) -> Result<PathBuf> {
    input.validate()?;
    abird_host_agent::build_executor::workload::require_wrapper_placement()?;
    let uid = unsafe { libc::geteuid() };
    ensure!(
        uid > 0
            && git.starts_with("/nix/store")
            && git.file_name().is_some_and(|name| name == "git"),
        "invalid caller checkout executable/credential"
    );
    let deadline = Instant::now()
        .checked_add(Duration::from_millis(input.budget_millis))
        .context("caller checkout deadline overflow")?;
    let request = &input.validation.request;
    let intent = request
        .parent
        .as_ref()
        .context("caller checkout parent missing")?;
    let record: InvocationRecord = serde_json::from_value(input.validation.context.clone())?;
    record.validate(request)?;
    let variables = environment.installed()?;
    input.search_path.require_value(
        environment
            .values
            .get("PATH")
            .context("caller PATH missing")?,
    )?;
    input.search_path.check_view()?;
    if !["ABIRD_HOST_MANAGER_GIT", "NIXBOT_GIT"]
        .iter()
        .any(|key| environment.values.contains_key(*key))
    {
        input.search_path.require_program("git", &git, deadline)?;
    }
    let (source, checkout) = input.context()?;
    let common = input.common_directory()?;
    input.configuration.check_view(&common, false, deadline)?;
    ensure!(
        record.source_root == source
            && checkout.umask == environment.umask
            && super::current_umask()? == checkout.umask,
        "caller checkout path/mask differs"
    );
    for key in ["ABIRD_HOST_MANAGER_GIT", "NIXBOT_GIT"] {
        ensure!(
            environment
                .values
                .get(key)
                .is_none_or(|value| std::path::Path::new(value) == git),
            "caller checkout Git executable differs"
        );
    }
    let roots = crate::fleet::runtime::runtime_roots(|name| {
        environment.values.get(name).map(OsString::from)
    });
    let state =
        RunState::allocate_selected(roots, &intent.run_id, checkout.namespace_root.clone())?;
    let target = checkout.workspace(&intent.run_id)?;
    ensure!(
        state.layout().run_dir.join("repo") == target,
        "native workspace layout differs"
    );
    // Only fresh private descendants and restored Git administration are writable.
    // Hooks, filters and fsmonitor still run under the exact caller profile.
    let runtime = super::offline::Runtime::load(&input.runtime_closure, input.limits, deadline)?;
    let mut reads = vec![source.clone(), common.clone()];
    reads.extend(input.configuration.paths().map(std::path::Path::to_owned));
    runtime
        .policy(
            &reads,
            &[
                &common,
                &state.layout().run_dir,
                &state.layout().diagnostic_dir,
                std::path::Path::new("/tmp"),
                std::path::Path::new("/var/tmp"),
            ],
            true,
        )?
        .enter()?;
    abird_host_agent::build_executor::process::offline::require_read_scope()?;
    let patch = input
        .patch
        .as_ref()
        .map(|bytes| -> Result<StagedPatch> {
            Ok(StagedPatch {
                base: CommitSha::parse(request.source.base_revision.clone())?,
                bytes: unhex(bytes, MAX_PATCH_BYTES)?,
            })
        })
        .transpose()?;
    let recipe = SourceRecipe::bind(&request.source, patch)?;
    let mut runner = Runner::new(
        uid,
        Limits {
            stdin: MAX_PATCH_BYTES,
            stdout: 16 * 1024 * 1024,
            stderr: 128 * 1024,
        },
        deadline,
    )?;
    let commands = RepositoryCommands::new(git, source.clone(), vec![target.clone()], variables)?
        .bind_caller_at(
        input.search_path.clone(),
        input.configuration.clone(),
        SearchView::Private,
        common,
        deadline,
    )?;
    let workspace = commands.with_repository(&mut runner, |manager| {
        recipe.caller_checkout(manager, &source, &target)
    })?;
    ensure!(
        workspace.path == target && workspace.commit.as_str() == request.source.revision,
        "native checkout changed captured source"
    );
    runner.check_ready()?;
    Ok(target)
}
