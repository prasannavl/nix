use std::collections::BTreeMap;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::programs::incus::{
    Incus, IncusCopyRequest, IncusInitRequest, IncusInstanceInfo, IncusOutput,
};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct InstanceDefinition {
    pub program: PathBuf,
    pub name: String,
    pub image: String,
    #[serde(default = "default_project")]
    pub project: String,
    #[serde(default)]
    pub profiles: Vec<String>,
    #[serde(default)]
    pub config: BTreeMap<String, String>,
    #[serde(default)]
    pub devices: BTreeMap<String, BTreeMap<String, String>>,
    #[serde(default)]
    pub start: bool,
}

#[derive(Debug, Serialize)]
pub struct InstanceResult {
    pub name: String,
    pub project: String,
    pub existed: bool,
    pub created: bool,
    pub started: bool,
    pub commands: Vec<InstanceCommandResult>,
}

#[derive(Debug, Serialize)]
pub struct InstanceCommandResult {
    pub arguments: Vec<String>,
    pub success: bool,
    pub exit_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum InstanceMigrationPhase {
    Seed,
    /// The authoritative final copy. This is prepare semantics: it never starts a writer.
    Final,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum IncusCopyMode {
    #[default]
    Pull,
    Push,
    Relay,
}

impl IncusCopyMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pull => "pull",
            Self::Push => "push",
            Self::Relay => "relay",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SeedConsistency {
    Strict,
    #[default]
    AllowInconsistent,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeStateMode {
    #[default]
    Discard,
    Preserve,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct InstanceMigrationPolicy {
    #[serde(default)]
    pub copy_mode: IncusCopyMode,
    #[serde(default)]
    pub target_storage_pool: Option<String>,
    #[serde(default = "default_stop_timeout_seconds")]
    pub stop_timeout_seconds: u64,
    #[serde(default)]
    pub force_after_timeout: bool,
    #[serde(default)]
    pub seed_consistency: SeedConsistency,
    #[serde(default)]
    pub runtime_state: RuntimeStateMode,
}

impl Default for InstanceMigrationPolicy {
    fn default() -> Self {
        Self {
            copy_mode: IncusCopyMode::Pull,
            target_storage_pool: None,
            stop_timeout_seconds: default_stop_timeout_seconds(),
            force_after_timeout: false,
            seed_consistency: SeedConsistency::AllowInconsistent,
            runtime_state: RuntimeStateMode::Discard,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct InstanceMigrationRequest {
    pub program: PathBuf,
    pub phase: InstanceMigrationPhase,
    pub source_instance: String,
    pub target_instance: String,
    #[serde(default = "default_remote")]
    pub source_remote: String,
    #[serde(default = "default_remote")]
    pub target_remote: String,
    #[serde(default = "default_project")]
    pub source_project: String,
    #[serde(default = "default_project")]
    pub target_project: String,
    pub snapshot: String,
    #[serde(default)]
    pub force_refresh_existing: bool,
    /// Immutable Incus copy and shutdown policy captured by the durable job.
    #[serde(default)]
    pub policy: InstanceMigrationPolicy,
    /// Retained only for compatibility with already serialized requests.
    /// Final copy now always leaves both instances stopped.
    #[serde(default = "default_true")]
    pub start_target: bool,
}

#[derive(Debug, Serialize)]
pub struct InstanceMigrationResult {
    pub phase: InstanceMigrationPhase,
    pub source: String,
    pub target: String,
    pub target_existed: bool,
    pub source_was_running: bool,
    pub target_was_running: bool,
    pub target_storage_pool: String,
    pub target_storage_driver: String,
    /// Always false. Starting a writer belongs to cutover, not seed/final copy.
    pub target_started: bool,
    pub commands: Vec<InstanceCommandResult>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum InstanceControlAction {
    Inspect,
    VerifyMigrationTarget {
        source_instance: String,
        source_remote: String,
        source_project: String,
        #[serde(default)]
        storage_pool: Option<String>,
    },
    Stop {
        #[serde(default)]
        allow_absent: bool,
    },
    DisableAutostart {
        #[serde(default)]
        allow_absent: bool,
    },
    AssertStopped {
        #[serde(default)]
        allow_absent: bool,
    },
    Activate,
    AssertRunning,
    SnapshotCreate {
        snapshot: String,
    },
    SnapshotDelete {
        snapshot: String,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct InstanceControlRequest {
    pub program: PathBuf,
    #[serde(default = "default_remote")]
    pub remote: String,
    #[serde(default = "default_project")]
    pub project: String,
    pub instance: String,
    #[serde(default = "default_stop_timeout_seconds")]
    pub stop_timeout_seconds: u64,
    #[serde(default)]
    pub force_after_timeout: bool,
    pub operation: InstanceControlAction,
}

#[derive(Debug, Serialize)]
pub struct InstanceControlResult {
    pub instance: String,
    pub project: String,
    pub existed: bool,
    pub was_running: bool,
    pub running: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<String>,
    pub changed: bool,
    pub commands: Vec<InstanceCommandResult>,
}

pub fn validate_instance(instance: &InstanceDefinition) -> Result<()> {
    if !instance.program.is_absolute() {
        bail!("instance program must be absolute");
    }
    for (label, value) in [
        ("instance name", instance.name.as_str()),
        ("instance image", instance.image.as_str()),
        ("instance project", instance.project.as_str()),
    ] {
        if value.trim().is_empty() || value.contains('\0') || value.starts_with('-') {
            bail!("{label} is invalid");
        }
    }
    if instance
        .profiles
        .iter()
        .chain(instance.config.keys())
        .chain(instance.config.values())
        .chain(instance.devices.keys())
        .chain(instance.devices.values().flat_map(|device| device.keys()))
        .chain(instance.devices.values().flat_map(|device| device.values()))
        .any(|value| value.contains('\0'))
    {
        bail!("instance definition cannot contain NUL");
    }
    Ok(())
}

pub fn ensure_instance(instance: &InstanceDefinition) -> Result<InstanceResult> {
    validate_instance(instance)?;
    let incus = Incus::new(&instance.program)?;
    let mut commands = Vec::new();
    let info = incus.info(&instance.name, &instance.project)?;
    let existed = info.result.success;
    commands.push(record(info));

    let mut created = false;
    if !existed {
        let result = incus.init(IncusInitRequest {
            image: &instance.image,
            name: &instance.name,
            project: &instance.project,
            profiles: &instance.profiles,
            config: &instance.config,
            devices: &instance.devices,
        })?;
        ensure_success("instance init", &result)?;
        commands.push(record(result));
        created = true;
    }

    let mut started = false;
    if instance.start {
        let result = incus.start(&instance.name, &instance.project)?;
        if !result.result.success && !result.result.stderr.contains("already running") {
            bail!(
                "instance start failed with {:?}: {}",
                result.result.exit_code,
                result.result.stderr
            );
        }
        started = result.result.success;
        commands.push(record(result));
    }
    Ok(InstanceResult {
        name: instance.name.clone(),
        project: instance.project.clone(),
        existed,
        created,
        started,
        commands,
    })
}

pub fn validate_instance_control(request: &InstanceControlRequest) -> Result<()> {
    if !request.program.is_absolute()
        || request.program.file_name().and_then(|name| name.to_str()) != Some("incus")
    {
        bail!("instance control program must be an absolute incus executable");
    }
    for (label, value) in [
        ("instance", request.instance.as_str()),
        ("remote", request.remote.as_str()),
        ("project", request.project.as_str()),
    ] {
        if !safe_incus_name(value) {
            bail!("instance control {label} is invalid");
        }
    }
    if !(1..=86_400).contains(&request.stop_timeout_seconds) {
        bail!("instance stop timeout must be between 1 and 86400 seconds");
    }
    if let InstanceControlAction::SnapshotCreate { snapshot }
    | InstanceControlAction::SnapshotDelete { snapshot } = &request.operation
        && !safe_incus_name(snapshot)
    {
        bail!("instance snapshot name is invalid");
    }
    if let InstanceControlAction::VerifyMigrationTarget {
        source_instance,
        source_remote,
        source_project,
        storage_pool,
    } = &request.operation
    {
        for (label, value) in [
            ("source instance", source_instance),
            ("source remote", source_remote),
            ("source project", source_project),
        ] {
            if !safe_incus_name(value) {
                bail!("instance migration verification {label} is invalid");
            }
        }
        if storage_pool
            .as_ref()
            .is_some_and(|pool| !safe_incus_name(pool))
        {
            bail!("instance migration verification storage pool is invalid");
        }
    }
    Ok(())
}

pub fn control_instance(request: &InstanceControlRequest) -> Result<InstanceControlResult> {
    validate_instance_control(request)?;
    let incus = Incus::new(&request.program)?;
    let instance = instance_ref(&request.remote, &request.instance);
    let mut commands = Vec::new();
    let probe = incus.inspect_instance(&request.remote, &request.instance, &request.project)?;
    let before = probe.info.clone();
    commands.push(record(probe.output));
    let existed = before.is_some();
    let was_running = before.as_ref().is_some_and(is_running);
    if let Some(info) = &before {
        validate_runtime_status("controlled", info)?;
    }

    let mut changed = false;
    let mut snapshot = None;
    match &request.operation {
        InstanceControlAction::Inspect => {}
        InstanceControlAction::VerifyMigrationTarget {
            source_instance,
            source_remote,
            source_project,
            storage_pool,
        } => {
            let info = before.as_ref().with_context(|| {
                format!("migration target instance {instance:?} does not exist")
            })?;
            for (suffix, expected) in [
                ("source-instance", source_instance.as_str()),
                ("source-remote", source_remote.as_str()),
                ("source-project", source_project.as_str()),
            ] {
                let output = incus.config_get(
                    &instance,
                    &request.project,
                    &format!("user.abird-host-manager.{suffix}"),
                )?;
                let actual = output.result.success.then(|| output.result.stdout.trim());
                if actual != Some(expected) {
                    bail!(
                        "migration target instance {instance:?} marker {suffix:?} is {:?}, expected {expected:?}",
                        actual
                    );
                }
                commands.push(record(output));
            }
            if let Some(expected) = storage_pool {
                let actual = info
                    .root_pool
                    .as_deref()
                    .context("migration target instance has no expanded root-disk storage pool")?;
                if actual != expected {
                    bail!(
                        "migration target instance {instance:?} storage pool is {actual:?}, expected {expected:?}"
                    );
                }
            }
        }
        InstanceControlAction::Stop { allow_absent }
        | InstanceControlAction::DisableAutostart { allow_absent }
        | InstanceControlAction::AssertStopped { allow_absent }
            if before.is_none() =>
        {
            if !allow_absent {
                bail!("instance {instance:?} does not exist");
            }
        }
        InstanceControlAction::Stop { .. } => {
            if was_running {
                stop_if_running(
                    &incus,
                    &request.remote,
                    &request.instance,
                    &request.project,
                    before.as_ref().expect("checked instance presence"),
                    &InstanceMigrationPolicy {
                        stop_timeout_seconds: request.stop_timeout_seconds,
                        force_after_timeout: request.force_after_timeout,
                        ..InstanceMigrationPolicy::default()
                    },
                    &mut commands,
                )?;
                changed = true;
            }
        }
        InstanceControlAction::DisableAutostart { .. } => {
            let output =
                incus.config_set(&instance, &request.project, "boot.autostart", "false")?;
            ensure_success("disable instance autostart", &output)?;
            commands.push(record(output));
            changed = true;
        }
        InstanceControlAction::AssertStopped { .. } => {
            if was_running {
                bail!("instance {instance:?} is running");
            }
        }
        InstanceControlAction::Activate => {
            if before.is_none() {
                bail!("instance {instance:?} does not exist");
            }
            if !was_running {
                let output = incus.start(&instance, &request.project)?;
                ensure_success("instance activation", &output)?;
                commands.push(record(output));
                changed = true;
            }
        }
        InstanceControlAction::AssertRunning => {
            if !was_running {
                bail!("instance {instance:?} is not running");
            }
        }
        InstanceControlAction::SnapshotCreate {
            snapshot: snapshot_name,
        } => {
            if before.is_none() {
                bail!("instance {instance:?} does not exist");
            }
            if was_running {
                bail!("refusing to snapshot running instance {instance:?}");
            }
            let existing = incus.inspect_snapshot(&instance, snapshot_name, &request.project)?;
            let exists = existing.exists;
            commands.push(record(existing.output));
            if !exists {
                let output =
                    incus.snapshot_create(&instance, snapshot_name, &request.project, false)?;
                ensure_success("instance safety snapshot", &output)?;
                commands.push(record(output));
                changed = true;
            }
            snapshot = Some(snapshot_name.clone());
        }
        InstanceControlAction::SnapshotDelete {
            snapshot: snapshot_name,
        } => {
            if before.is_some() {
                let existing =
                    incus.inspect_snapshot(&instance, snapshot_name, &request.project)?;
                let exists = existing.exists;
                commands.push(record(existing.output));
                if exists {
                    let output =
                        incus.snapshot_delete(&instance, snapshot_name, &request.project)?;
                    ensure_success("instance safety snapshot deletion", &output)?;
                    commands.push(record(output));
                    changed = true;
                }
            }
            snapshot = Some(snapshot_name.clone());
        }
    }

    let after = incus.inspect_instance(&request.remote, &request.instance, &request.project)?;
    let running = after.info.as_ref().is_some_and(is_running);
    commands.push(record(after.output));
    match &request.operation {
        InstanceControlAction::Inspect | InstanceControlAction::VerifyMigrationTarget { .. } => {}
        InstanceControlAction::Stop { .. }
        | InstanceControlAction::DisableAutostart { .. }
        | InstanceControlAction::AssertStopped { .. }
            if running =>
        {
            bail!("instance {instance:?} is running after stop verification");
        }
        InstanceControlAction::Activate | InstanceControlAction::AssertRunning if !running => {
            bail!("instance {instance:?} is not running after activation verification");
        }
        _ => {}
    }
    Ok(InstanceControlResult {
        instance,
        project: request.project.clone(),
        existed,
        was_running,
        running,
        snapshot,
        changed,
        commands,
    })
}

pub fn migrate_instance(request: &InstanceMigrationRequest) -> Result<InstanceMigrationResult> {
    migrate_instance_with_policy(request, &request.policy)
}

pub fn migrate_instance_with_policy(
    request: &InstanceMigrationRequest,
    policy: &InstanceMigrationPolicy,
) -> Result<InstanceMigrationResult> {
    validate_migration(request, policy)?;
    let incus = Incus::new(&request.program)?;
    let source = instance_ref(&request.source_remote, &request.source_instance);
    let target = instance_ref(&request.target_remote, &request.target_instance);
    let mut commands = Vec::new();

    let source_probe = incus.inspect_instance(
        &request.source_remote,
        &request.source_instance,
        &request.source_project,
    )?;
    let source_info = source_probe
        .info
        .clone()
        .with_context(|| format!("source instance {source:?} does not exist"))?;
    commands.push(record(source_probe.output));
    validate_runtime_state_policy(request, policy, &source_info)?;

    let target_probe = incus.inspect_instance(
        &request.target_remote,
        &request.target_instance,
        &request.target_project,
    )?;
    let target_info = target_probe.info.clone();
    commands.push(record(target_probe.output));
    let target_existed = target_info.is_some();
    if target_existed {
        verify_target_marker(request, &incus, &target, &mut commands)?;
    }

    let source_pool = source_info
        .root_pool
        .as_deref()
        .context("source instance has no expanded root-disk storage pool")?;
    let target_pool = policy.target_storage_pool.as_deref().unwrap_or(source_pool);
    if let Some(info) = &target_info {
        let actual_pool = info
            .root_pool
            .as_deref()
            .context("target instance has no expanded root-disk storage pool")?;
        if actual_pool != target_pool {
            bail!(
                "target instance root pool {actual_pool:?} does not match requested pool {target_pool:?}"
            );
        }
    }
    let storage = incus.inspect_storage_pool(&request.target_remote, target_pool)?;
    let target_storage_driver = storage.info.driver.clone();
    commands.push(record(storage.output));

    let source_was_running = is_running(&source_info);
    let target_was_running = target_info.as_ref().is_some_and(is_running);
    validate_runtime_status("source", &source_info)?;
    if let Some(info) = &target_info {
        validate_runtime_status("target", info)?;
    }

    let preserve_runtime = request.phase == InstanceMigrationPhase::Final
        && policy.runtime_state == RuntimeStateMode::Preserve;
    if preserve_runtime {
        replace_snapshot(&incus, &source, request, true, &mut commands)?;
    }

    if request.phase == InstanceMigrationPhase::Final {
        stop_if_running(
            &incus,
            &request.source_remote,
            &request.source_instance,
            &request.source_project,
            &source_info,
            policy,
            &mut commands,
        )?;
        if let Some(info) = &target_info {
            stop_if_running(
                &incus,
                &request.target_remote,
                &request.target_instance,
                &request.target_project,
                info,
                policy,
                &mut commands,
            )?;
        }
    }

    if !preserve_runtime {
        replace_snapshot(&incus, &source, request, false, &mut commands)?;
    }

    let snapshot_ref = format!("{source}/{}", request.snapshot);
    let copy = incus.copy(IncusCopyRequest {
        source: &snapshot_ref,
        target: &target,
        source_project: &request.source_project,
        target_project: &request.target_project,
        target_pool,
        mode: policy.copy_mode.as_str(),
        refresh: target_existed,
        stateless: policy.runtime_state == RuntimeStateMode::Discard,
        allow_inconsistent: request.phase == InstanceMigrationPhase::Seed
            && policy.seed_consistency == SeedConsistency::AllowInconsistent,
    })?;
    ensure_success("instance copy", &copy)?;
    commands.push(record(copy));
    write_target_marker(request, &incus, &target, &mut commands)?;

    let delete = incus.snapshot_delete(&source, &request.snapshot, &request.source_project)?;
    ensure_success("source snapshot cleanup", &delete)?;
    commands.push(record(delete));

    let target_probe = incus.inspect_instance(
        &request.target_remote,
        &request.target_instance,
        &request.target_project,
    )?;
    let target_after_copy = target_probe
        .info
        .clone()
        .with_context(|| format!("target instance {target:?} is absent after copy"))?;
    commands.push(record(target_probe.output));
    let actual_pool = target_after_copy
        .root_pool
        .as_deref()
        .context("target instance has no expanded root-disk storage pool after copy")?;
    if actual_pool != target_pool {
        bail!(
            "target instance root pool {actual_pool:?} does not match copied pool {target_pool:?}"
        );
    }
    if request.phase == InstanceMigrationPhase::Final && is_running(&target_after_copy) {
        bail!("prepared target instance {target:?} is unexpectedly running after copy");
    }

    Ok(InstanceMigrationResult {
        phase: request.phase,
        source,
        target,
        target_existed,
        source_was_running,
        target_was_running,
        target_storage_pool: target_pool.to_owned(),
        target_storage_driver,
        target_started: false,
        commands,
    })
}

fn validate_migration(
    request: &InstanceMigrationRequest,
    policy: &InstanceMigrationPolicy,
) -> Result<()> {
    if !request.program.is_absolute()
        || request.program.file_name().and_then(|name| name.to_str()) != Some("incus")
    {
        bail!("instance migration program must be an absolute incus executable");
    }
    for (label, value) in [
        ("source instance", request.source_instance.as_str()),
        ("target instance", request.target_instance.as_str()),
        ("source remote", request.source_remote.as_str()),
        ("target remote", request.target_remote.as_str()),
        ("source project", request.source_project.as_str()),
        ("target project", request.target_project.as_str()),
        ("snapshot", request.snapshot.as_str()),
    ] {
        if !safe_incus_name(value) {
            bail!("{label} is invalid");
        }
    }
    if let Some(pool) = &policy.target_storage_pool
        && !safe_incus_name(pool)
    {
        bail!("target storage pool is invalid");
    }
    if !(1..=86_400).contains(&policy.stop_timeout_seconds) {
        bail!("instance stop timeout must be between 1 and 86400 seconds");
    }
    if request.source_remote == request.target_remote
        && request.source_project == request.target_project
        && request.source_instance == request.target_instance
    {
        bail!("source and target instance locations must differ");
    }
    Ok(())
}

fn validate_runtime_state_policy(
    request: &InstanceMigrationRequest,
    policy: &InstanceMigrationPolicy,
    source: &IncusInstanceInfo,
) -> Result<()> {
    if policy.runtime_state != RuntimeStateMode::Preserve {
        return Ok(());
    }
    if source.kind != "virtual-machine" {
        bail!(
            "runtime-state preservation is supported only for virtual machines; source type is {:?}",
            source.kind
        );
    }
    if request.phase == InstanceMigrationPhase::Final && !is_running(source) {
        bail!("cannot preserve runtime state for a source instance that is not running");
    }
    Ok(())
}

fn validate_runtime_status(label: &str, info: &IncusInstanceInfo) -> Result<()> {
    if is_running(info) || info.status.eq_ignore_ascii_case("stopped") {
        return Ok(());
    }
    bail!(
        "{label} instance must be running or stopped before migration; current status is {:?}",
        info.status
    )
}

fn replace_snapshot(
    incus: &Incus,
    source: &str,
    request: &InstanceMigrationRequest,
    stateful: bool,
    commands: &mut Vec<InstanceCommandResult>,
) -> Result<()> {
    let existing = incus.inspect_snapshot(source, &request.snapshot, &request.source_project)?;
    if existing.exists {
        commands.push(record(existing.output));
        let deleted = incus.snapshot_delete(source, &request.snapshot, &request.source_project)?;
        ensure_success("replace source snapshot", &deleted)?;
        commands.push(record(deleted));
    } else {
        commands.push(record(existing.output));
    }
    let created =
        incus.snapshot_create(source, &request.snapshot, &request.source_project, stateful)?;
    ensure_success("source snapshot creation", &created)?;
    commands.push(record(created));
    Ok(())
}

fn stop_if_running(
    incus: &Incus,
    remote: &str,
    instance_name: &str,
    project: &str,
    info: &IncusInstanceInfo,
    policy: &InstanceMigrationPolicy,
    commands: &mut Vec<InstanceCommandResult>,
) -> Result<()> {
    if !is_running(info) {
        return Ok(());
    }
    let instance = instance_ref(remote, instance_name);
    let graceful = incus.stop(&instance, project, Some(policy.stop_timeout_seconds), false)?;
    let graceful_succeeded = graceful.result.success;
    let graceful_error = graceful.result.stderr.clone();
    commands.push(record(graceful));
    if !graceful_succeeded {
        if !policy.force_after_timeout {
            bail!("graceful instance stop failed: {graceful_error}");
        }
        let forced = incus.stop(&instance, project, None, true)?;
        ensure_success("forced instance stop", &forced)?;
        commands.push(record(forced));
    }
    let probe = incus.inspect_instance(remote, instance_name, project)?;
    let stopped = probe
        .info
        .as_ref()
        .is_some_and(|current| current.status.eq_ignore_ascii_case("stopped"));
    commands.push(record(probe.output));
    if !stopped {
        bail!("instance {instance:?} is still running after stop");
    }
    Ok(())
}

fn verify_target_marker(
    request: &InstanceMigrationRequest,
    incus: &Incus,
    target: &str,
    commands: &mut Vec<InstanceCommandResult>,
) -> Result<()> {
    let expected = [
        ("source-instance", request.source_instance.as_str()),
        ("source-project", request.source_project.as_str()),
        ("source-remote", request.source_remote.as_str()),
    ];
    for (suffix, expected) in expected {
        let current = marker_value(request, incus, target, suffix, commands)?;
        if current.as_deref() != Some(expected) && !request.force_refresh_existing {
            bail!(
                "target instance marker {suffix:?} does not match {expected:?}; pass force_refresh_existing only after operator review"
            );
        }
    }
    Ok(())
}

fn marker_value(
    request: &InstanceMigrationRequest,
    incus: &Incus,
    target: &str,
    suffix: &str,
    commands: &mut Vec<InstanceCommandResult>,
) -> Result<Option<String>> {
    let result = incus.config_get(
        target,
        &request.target_project,
        &format!("user.abird-host-manager.{suffix}"),
    )?;
    let value = result
        .result
        .success
        .then(|| result.result.stdout.trim().to_owned());
    commands.push(record(result));
    Ok(value.filter(|value| !value.is_empty()))
}

fn write_target_marker(
    request: &InstanceMigrationRequest,
    incus: &Incus,
    target: &str,
    commands: &mut Vec<InstanceCommandResult>,
) -> Result<()> {
    for (suffix, value) in [
        ("source-instance", request.source_instance.as_str()),
        ("source-project", request.source_project.as_str()),
        ("source-remote", request.source_remote.as_str()),
    ] {
        let result = incus.config_set(
            target,
            &request.target_project,
            &format!("user.abird-host-manager.{suffix}"),
            value,
        )?;
        ensure_success("write target migration marker", &result)?;
        commands.push(record(result));
    }
    Ok(())
}

fn ensure_success(operation: &str, output: &IncusOutput) -> Result<()> {
    if !output.result.success {
        bail!(
            "{operation} {:?} failed with {:?}: {}",
            output.arguments,
            output.result.exit_code,
            output.result.stderr
        );
    }
    Ok(())
}

fn record(output: IncusOutput) -> InstanceCommandResult {
    InstanceCommandResult {
        arguments: output.arguments,
        success: output.result.success,
        exit_code: output.result.exit_code,
        stdout: output.result.stdout.trim().to_owned(),
        stderr: output.result.stderr.trim().to_owned(),
    }
}

fn is_running(info: &IncusInstanceInfo) -> bool {
    info.status.eq_ignore_ascii_case("running")
}

fn safe_incus_name(value: &str) -> bool {
    !value.is_empty()
        && !value.starts_with('-')
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

fn instance_ref(remote: &str, instance: &str) -> String {
    if remote == "local" {
        instance.to_owned()
    } else {
        format!("{remote}:{instance}")
    }
}

fn default_project() -> String {
    "default".to_owned()
}

fn default_remote() -> String {
    "local".to_owned()
}

fn default_stop_timeout_seconds() -> u64 {
    60
}

fn default_true() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use std::fs::{self, File};
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    fn write_program(path: &std::path::Path, script: &str) {
        let mut file = File::create(path).unwrap();
        file.write_all(format!("#!/bin/sh\n{script}\n").as_bytes())
            .unwrap();
        file.sync_all().unwrap();
        drop(file);
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }

    fn request(program: PathBuf, phase: InstanceMigrationPhase) -> InstanceMigrationRequest {
        InstanceMigrationRequest {
            program,
            phase,
            source_instance: "source".to_owned(),
            target_instance: "target".to_owned(),
            source_remote: "local".to_owned(),
            target_remote: "local".to_owned(),
            source_project: "old".to_owned(),
            target_project: "new".to_owned(),
            snapshot: "migration-final".to_owned(),
            force_refresh_existing: false,
            policy: InstanceMigrationPolicy::default(),
            start_target: true,
        }
    }

    #[test]
    fn provision_is_idempotent_when_instance_exists() {
        let temp = tempfile::tempdir().unwrap();
        let program = temp.path().join("incus");
        write_program(&program, "[ \"$1\" = info ]");
        let result = ensure_instance(&InstanceDefinition {
            program,
            name: "abird-zulip".to_owned(),
            image: "images:nixos/26.05".to_owned(),
            project: "default".to_owned(),
            profiles: Vec::new(),
            config: BTreeMap::new(),
            devices: BTreeMap::new(),
            start: false,
        })
        .unwrap();
        assert!(result.existed);
        assert!(!result.created);
        assert_eq!(result.commands.len(), 1);
    }

    #[test]
    fn policy_defaults_are_safe_and_compatible() {
        let policy: InstanceMigrationPolicy = serde_json::from_str("{}").unwrap();
        assert_eq!(policy, InstanceMigrationPolicy::default());
        assert_eq!(policy.copy_mode, IncusCopyMode::Pull);
        assert_eq!(policy.stop_timeout_seconds, 60);
        assert!(!policy.force_after_timeout);
    }

    #[test]
    fn policy_request_deserializes_explicit_controls() {
        let request: InstanceMigrationRequest = serde_json::from_value(serde_json::json!({
            "program": "/bin/incus",
            "phase": "seed",
            "source_instance": "source",
            "target_instance": "target",
            "snapshot": "seed",
            "policy": {
                "copy_mode": "relay",
                "target_storage_pool": "fast",
                "stop_timeout_seconds": 30,
                "force_after_timeout": true,
                "seed_consistency": "strict",
                "runtime_state": "preserve"
            }
        }))
        .unwrap();
        assert_eq!(request.policy.copy_mode, IncusCopyMode::Relay);
        assert_eq!(request.policy.target_storage_pool.as_deref(), Some("fast"));
        assert_eq!(request.policy.stop_timeout_seconds, 30);
        assert!(request.policy.force_after_timeout);
        assert_eq!(request.policy.seed_consistency, SeedConsistency::Strict);
        assert_eq!(request.policy.runtime_state, RuntimeStateMode::Preserve);
    }

    #[test]
    fn preserve_runtime_rejects_lxc_before_mutation() {
        let temp = tempfile::tempdir().unwrap();
        let program = temp.path().join("incus");
        let log = temp.path().join("log");
        write_program(
            &program,
            &format!(
                r#"printf '%s\n' "$*" >> '{}'
printf '%s' '{{"metadata":{{"status":"Running","type":"container","expanded_devices":{{"root":{{"type":"disk","path":"/","pool":"fast"}}}}}}}}'"#,
                log.display()
            ),
        );
        let error = migrate_instance_with_policy(
            &request(program, InstanceMigrationPhase::Final),
            &InstanceMigrationPolicy {
                runtime_state: RuntimeStateMode::Preserve,
                ..InstanceMigrationPolicy::default()
            },
        )
        .unwrap_err();
        assert!(error.to_string().contains("only for virtual machines"));
        let log = fs::read_to_string(log).unwrap();
        assert_eq!(log.lines().count(), 1);
        assert!(log.starts_with("query "));
    }

    #[test]
    fn existing_target_pool_mismatch_fails_before_copy() {
        let temp = tempfile::tempdir().unwrap();
        let program = temp.path().join("incus");
        let log = temp.path().join("log");
        write_program(
            &program,
            &format!(
                r#"printf '%s\n' "$*" >> '{}'
case "$*" in
  *'/1.0/instances/source?'*) pool=fast ;;
  *'/1.0/instances/target?'*) pool=slow ;;
  *'config get'*source-instance*) printf source ; exit 0 ;;
  *'config get'*source-project*) printf old ; exit 0 ;;
  *'config get'*source-remote*) printf local ; exit 0 ;;
esac
printf '{{"metadata":{{"status":"Stopped","type":"container","expanded_devices":{{"root":{{"type":"disk","path":"/","pool":"%s"}}}}}}}}' "$pool""#,
                log.display()
            ),
        );
        let error = migrate_instance_with_policy(
            &request(program, InstanceMigrationPhase::Seed),
            &InstanceMigrationPolicy {
                target_storage_pool: Some("fast".to_owned()),
                ..InstanceMigrationPolicy::default()
            },
        )
        .unwrap_err();
        assert!(error.to_string().contains("does not match requested pool"));
        assert!(!fs::read_to_string(log).unwrap().contains("copy "));
    }

    #[test]
    fn stop_timeout_fails_closed_without_force() {
        let temp = tempfile::tempdir().unwrap();
        let program = temp.path().join("incus");
        let log = temp.path().join("log");
        write_program(
            &program,
            &format!(
                r#"printf '%s\n' "$*" >> '{}'
case "$*" in
  *'/1.0/instances/source?'*) printf '%s' '{{"metadata":{{"status":"Running","type":"container","expanded_devices":{{"root":{{"type":"disk","path":"/","pool":"fast"}}}}}}}}' ;;
  *'/1.0/instances/target?'*) printf '%s' '{{"metadata":{{"status":"Stopped","type":"container","expanded_devices":{{"root":{{"type":"disk","path":"/","pool":"fast"}}}}}}}}' ;;
  *'/1.0/storage-pools/fast'*) printf '%s' '{{"metadata":{{"driver":"btrfs"}}}}' ;;
  'config get '*source-instance*) printf source ;;
  'config get '*source-project*) printf old ;;
  'config get '*source-remote*) printf local ;;
  'stop '*) printf timeout >&2 ; exit 1 ;;
esac"#,
                log.display()
            ),
        );
        let error = migrate_instance_with_policy(
            &request(program, InstanceMigrationPhase::Final),
            &InstanceMigrationPolicy::default(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("graceful instance stop failed"));
        let log = fs::read_to_string(log).unwrap();
        assert!(log.contains("stop source --project old --timeout 60"));
        assert!(!log.contains("--force"));
        assert!(!log.contains("snapshot create"));
    }

    #[test]
    fn explicit_force_fallback_still_leaves_both_sides_stopped() {
        let temp = tempfile::tempdir().unwrap();
        let program = temp.path().join("incus");
        let log = temp.path().join("log");
        let source_stopped = temp.path().join("source-stopped");
        write_program(
            &program,
            &format!(
                r#"printf '%s\n' "$*" >> '{}'
case "$*" in
  *'/1.0/instances/source?'*) if [ -e '{}' ]; then status=Stopped; else status=Running; fi; printf '{{"metadata":{{"status":"%s","type":"container","expanded_devices":{{"root":{{"type":"disk","path":"/","pool":"fast"}}}}}}}}' "$status" ;;
  *'/1.0/instances/target?'*) printf '%s' '{{"metadata":{{"status":"Stopped","type":"container","expanded_devices":{{"root":{{"type":"disk","path":"/","pool":"fast"}}}}}}}}' ;;
  *'/1.0/storage-pools/fast'*) printf '%s' '{{"metadata":{{"driver":"btrfs"}}}}' ;;
  'config get '*source-instance*) printf source ;;
  'config get '*source-project*) printf old ;;
  'config get '*source-remote*) printf local ;;
  'stop source --project old --timeout 5') printf timeout >&2 ; exit 1 ;;
  'stop source --project old --force') : > '{}' ;;
  'info source/migration-final '*) printf 'not found' >&2 ; exit 1 ;;
esac"#,
                log.display(),
                source_stopped.display(),
                source_stopped.display()
            ),
        );
        let result = migrate_instance_with_policy(
            &request(program, InstanceMigrationPhase::Final),
            &InstanceMigrationPolicy {
                stop_timeout_seconds: 5,
                force_after_timeout: true,
                ..InstanceMigrationPolicy::default()
            },
        )
        .unwrap();
        assert!(result.source_was_running);
        assert!(!result.target_was_running);
        assert!(!result.target_started);
        let log = fs::read_to_string(log).unwrap();
        assert!(log.contains("stop source --project old --timeout 5"));
        assert!(log.contains("stop source --project old --force"));
        assert!(log.contains("snapshot create source migration-final --project old"));
        assert!(!log.contains("--allow-inconsistent"));
        assert!(!log.lines().any(|line| line.starts_with("start ")));
    }

    #[test]
    fn seed_derives_pool_and_never_starts_or_stops_a_writer() {
        let temp = tempfile::tempdir().unwrap();
        let program = temp.path().join("incus");
        let log = temp.path().join("log");
        let copied = temp.path().join("copied");
        write_program(
            &program,
            &format!(
                r#"printf '%s\n' "$*" >> '{}'
case "$*" in
  *'/1.0/instances/source?'*) printf '%s' '{{"metadata":{{"status":"Running","type":"container","expanded_devices":{{"root":{{"type":"disk","path":"/","pool":"fast"}}}}}}}}' ;;
  *'/1.0/instances/target?'*) if [ -e '{}' ]; then printf '%s' '{{"metadata":{{"status":"Stopped","type":"container","expanded_devices":{{"root":{{"type":"disk","path":"/","pool":"fast"}}}}}}}}'; else printf 'not found' >&2; exit 1; fi ;;
  *'/1.0/storage-pools/fast'*) printf '%s' '{{"metadata":{{"driver":"btrfs"}}}}' ;;
  'info source/migration-final '*) printf 'not found' >&2; exit 1 ;;
  *' copy '*) : > '{}' ;;
esac"#,
                log.display(),
                copied.display(),
                copied.display()
            ),
        );
        let result = migrate_instance_with_policy(
            &request(program, InstanceMigrationPhase::Seed),
            &InstanceMigrationPolicy {
                copy_mode: IncusCopyMode::Push,
                ..InstanceMigrationPolicy::default()
            },
        )
        .unwrap();
        assert_eq!(result.target_storage_pool, "fast");
        assert_eq!(result.target_storage_driver, "btrfs");
        assert!(!result.target_started);
        let log = fs::read_to_string(log).unwrap();
        assert!(log.contains("--storage fast --mode push --stateless --allow-inconsistent"));
        assert!(!log.lines().any(|line| line.starts_with("start ")));
        assert!(!log.lines().any(|line| line.starts_with("stop ")));
    }
}
