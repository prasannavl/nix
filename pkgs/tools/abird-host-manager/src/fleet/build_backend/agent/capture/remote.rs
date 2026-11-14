//! Source-only remote orchestration. Admission, authenticated relay and control
//! are owned by capture_role; these stages never receive transport credentials.
use std::fs::{self, File};
use std::os::{fd::AsRawFd, unix::fs::PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use crate::fleet::build_backend::agent::controller::PendingCapture;
use abird_host_agent::build_executor::{
    capture_role::Execution,
    native_intent::{self, CaptureInput, CheckoutInput, Material, Validation},
    preparation::{
        capsule::{Capsule, CheckoutExecution, GitImage},
        git_context::window::ReadWindow,
    },
    private_tree,
    process::{Limits, Runner, offline::CaptureView},
    role::ManagerCommand,
};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Capture {
    pub input: CaptureInput,
    pub pending: PendingCapture,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Export {
    pub input: CheckoutInput,
    pub environment: super::Environment,
    pub nar: PathBuf,
    pub nar_configuration: PathBuf,
    pub limits: private_tree::Limits,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LocalExport {
    pub input: CheckoutInput,
    pub nar: PathBuf,
    pub nar_configuration: PathBuf,
    pub limits: private_tree::Limits,
}

pub fn export_local(value: LocalExport, git: PathBuf) -> Result<Capsule> {
    use crate::fleet::build_backend::agent::run::Run;
    let intent = value
        .input
        .validation
        .request
        .parent
        .as_ref()
        .context("local export parent missing")?;
    let manifest = Run::inspect(&intent.run_id)?;
    let child = manifest
        .children
        .get(&intent.attempt_id()?)
        .context("local export child missing")?;
    child.require_local_capture(intent, &value.input.delivery_digest)?;
    let pending = child
        .pending_capture()
        .context("local export caller missing")?;
    pending.validate(intent)?;
    let environment = pending
        .environment
        .clone()
        .context("local export environment missing")?;
    let configuration = value.input.configuration.clone();
    let caller_digest = intent
        .caller_digest
        .clone()
        .context("local export caller digest missing")?;
    let primary = export(
        Export {
            input: value.input,
            environment: environment.clone(),
            nar: value.nar,
            nar_configuration: value.nar_configuration,
            limits: value.limits,
        },
        git,
    )?;
    // Keep the admitted pending binding; export's offline scope must not
    // regain access to the observer's replaceable manifest.
    let hash = primary.image.nar_digest.clone();
    let home = PathBuf::from(
        environment
            .values
            .get("HOME")
            .context("caller HOME missing")?,
    );
    let xdg = environment
        .values
        .get("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map_or_else(|| home.join(".config"), PathBuf::from);
    Ok(Capsule {
        version: 1,
        caller_digest,
        primary: hash.clone(),
        roots: std::collections::BTreeMap::from([(hash, primary)]),
        home,
        xdg_config_home: xdg,
        system_configuration: environment.native_system_configuration(),
        configuration,
    })
}

/// Fixed unprivileged initial-capture entry, called only by the admitted role.
pub fn capture(value: Capture, git: PathBuf, nar: PathBuf) -> Result<Material> {
    value.pending.validate(&value.input.intent)?;
    super::captured(value.input, git, nar, &value.pending)
}

/// Fixed offline native checkout/export. No caller Run lookup on a builder and
/// no command/credential data supplied by the transport peer.
pub fn export(value: Export, git: PathBuf) -> Result<GitImage> {
    ensure!(
        value.input.limits == value.limits,
        "checkout source limits differ"
    );
    let deadline = Instant::now()
        .checked_add(Duration::from_millis(value.input.budget_millis))
        .context("checkout export deadline overflow")?;
    let target = super::checkout::execute(&value.input, git.clone(), &value.environment)?;
    let environment = value.environment.installed()?;
    let uid = unsafe { libc::geteuid() };
    let mut window = ReadWindow::begin(uid, value.limits, deadline)?;
    let mut runner = Runner::new(
        uid,
        Limits {
            stdin: 1,
            stdout: 65536,
            stderr: 4096,
        },
        deadline,
    )?;
    let layout = super::git::layout(&target, &git, &environment, &mut runner, &window)?;
    window.bind_git(&layout.common)?;
    value
        .input
        .configuration
        .check_view(&layout.common, true, deadline)?;
    super::config::require_bound_auxiliary(
        &value.input.configuration,
        &target,
        &value.environment,
        &git,
        &mut runner,
        &window,
    )?;
    let caller = value
        .input
        .validation
        .request
        .parent
        .as_ref()
        .and_then(|parent| parent.caller_digest.as_deref())
        .context("export caller missing")?;
    let image = super::image::capture(
        &layout,
        value.input.validation.request.source.revision.clone(),
        &target
            .parent()
            .context("checkout parent missing")?
            .join("capsule-image"),
        &git,
        &value.nar,
        &value.nar_configuration,
        &environment,
        value.limits,
        deadline,
        &mut window,
        caller,
    )?;
    window.finish()?;
    Ok(image)
}

/// Root orchestration within the original capture-only unit. `directory` is the
/// remote owner's registered exclusive attempt directory; never a caller path.
pub fn run(
    execution: &Execution,
    mut input: CaptureInput,
    pending: PendingCapture,
    directory: &Path,
) -> Result<Material> {
    execution.active()?;
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "capture orchestration requires root"
    );
    let policy = &execution.policy;
    let account = &policy.caller(execution.uid)?.account;
    ensure!(
        input.runtime_closure == policy.runtime_closure
            && input.limits == policy.limits
            && input.roots == account.capture_roots,
        "capture scope differs from installed role"
    );
    pending.validate(&input.intent)?;
    let deadline = execution.deadline()?;
    input.budget_millis = deadline
        .saturating_duration_since(Instant::now())
        .as_millis()
        .try_into()?;
    let environment = pending
        .environment
        .clone()
        .context("capture environment missing")?;
    let parent = input.intent.clone();
    let delivery_digest = input.delivery_digest.clone();
    let scratch = directory.join("source-capture");
    fs::create_dir(&scratch)?;
    fs::set_permissions(&scratch, fs::Permissions::from_mode(0o700))?;
    let scratch = File::open(scratch)?;
    ensure!(
        unsafe { libc::fchown(scratch.as_raw_fd(), account.uid, account.gid) } == 0,
        "capture scratch ownership failed"
    );
    scratch.sync_all()?;
    File::open(directory)?.sync_all()?;
    let view = CaptureView::prepare(&scratch)?;
    ensure!(
        view.preserves(&account.capture_roots)
            && view.preserves(&[account.home.clone(), account.state_home.clone()]),
        "capture roots overlap scratch namespace"
    );
    let mut command = Command::new(&policy.manager);
    command
        .arg(ManagerCommand::Capture.argument())
        .arg("--remote-capture")
        .arg(&policy.git)
        .arg(&policy.nar)
        .current_dir("/var/empty")
        .env_clear()
        .env("HOME", &account.home)
        .env("XDG_STATE_HOME", &account.state_home)
        .env("PATH", "/var/empty")
        .env("LC_ALL", "C")
        .envs(native_intent::CALLER_GIT_PROFILE);
    let bound =
        abird_host_agent::build_executor::preparation::source::material_limit(policy.limits)?;
    let mut runner = Runner::new_source(
        account.uid,
        Limits {
            stdin: 256 * 1024,
            stdout: bound,
            stderr: 4096,
        },
        deadline,
        bound,
    )?;
    let output = runner.run_as_capture(
        &mut command,
        &serde_json::to_vec(&Capture { input, pending })?,
        account.gid,
        &account.groups,
        view,
        &mut execution.stage()?,
    )?;
    ensure!(output.status.success(), "operator source capture failed");
    execution.active()?;
    let mut material = Material::decode(&output.stdout, &parent)?;
    drop(output);
    if let Some(capsule) = &material.source.capsule {
        material.validate(&parent)?;
        capsule.require_limits(policy.limits, &material.source.snapshots)?;
        return Ok(material); // dev-build observes the original live Git root
    }
    let mut captured = material
        .source
        .git_context
        .take()
        .context("captured common Git image missing")?;
    let checkout = CheckoutInput {
        validation: Validation {
            request: material.request.clone(),
            context: material.context.clone(),
        },
        delivery_digest,
        patch: material.source.patch.clone(),
        search_path: captured
            .search_path
            .clone()
            .context("captured PATH missing")?,
        configuration: captured
            .configuration
            .clone()
            .context("captured Git profile missing")?,
        git_layout: captured.layout.clone(),
        runtime_closure: policy.runtime_closure.clone(),
        limits: policy.limits,
        budget_millis: deadline
            .saturating_duration_since(Instant::now())
            .as_millis()
            .try_into()?,
    };
    checkout.validate()?;
    let export = Export {
        input: checkout,
        environment: environment.clone(),
        nar: policy.nar.clone(),
        nar_configuration: policy.nar_configuration.clone(),
        limits: policy.limits,
    };
    let bytes = CheckoutExecution {
        directory: &directory.join("source-checkout"),
        account,
        input: &export.input,
        git_context: &mut captured,
        manager: &policy.manager,
        git: &policy.git,
        nar: &policy.nar,
        nar_configuration: &policy.nar_configuration,
        source_limits: policy.limits,
        local: false,
        deadline,
    }
    .run(
        &serde_json::to_vec(&export)?,
        &mut execution.stage()?,
        &mut execution.stage()?,
    )?;
    execution.active()?;
    let configuration = captured
        .configuration
        .take()
        .context("captured profile vanished")?;
    let mut roots = std::mem::take(&mut captured.external);
    drop(captured); // release original Git hex before decoding the exported image
    let primary: GitImage = serde_json::from_slice(&bytes)?;
    drop(bytes);
    primary.validate()?;
    primary.image.require_limits(policy.limits)?;
    let hash = primary.image.nar_digest.clone();
    roots.insert(hash.clone(), primary);
    let home = PathBuf::from(
        environment
            .values
            .get("HOME")
            .context("caller HOME missing")?,
    );
    let xdg = environment
        .values
        .get("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map_or_else(|| home.join(".config"), PathBuf::from);
    let capsule = Capsule {
        version: 1,
        caller_digest: parent
            .caller_digest
            .clone()
            .context("caller digest missing")?,
        primary: hash,
        roots,
        home,
        xdg_config_home: xdg,
        system_configuration: environment.native_system_configuration(),
        configuration,
    };
    capsule.validate(&material.request)?;
    capsule.require_limits(policy.limits, &material.source.snapshots)?;
    material.context["git_context_digest"] = serde_json::Value::String(capsule.digest()?);
    material.source.capsule = Some(capsule);
    material.source.version = 2;
    material.validate(&parent)?;
    abird_host_agent::build_executor::preparation::source::encoding::require_size(
        &material, bound,
    )?;
    execution.active()?;
    Ok(material)
}
