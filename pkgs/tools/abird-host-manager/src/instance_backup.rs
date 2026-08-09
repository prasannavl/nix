use std::fs;
use std::path::{Path, PathBuf};

use abird_host_agent::instance::{InstanceControlAction, InstanceControlRequest};
use abird_host_agent::instance_backup::{InstanceBackupAction, InstanceBackupRequest};
use abird_host_agent::resource::DataRootPlan;
use abird_host_agent::sha256::{digest_bytes, digest_reader};
use abird_host_agent::transfer::{TransferDefinition, transfer_with_excludes_progress};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::agent_adapter::{HostManagerConfig, NativeAdapter, instance_resource};
use crate::backup_runtime::{BackupArtifact, InstanceExportLocation};
use crate::workflow::{InstanceBackupPolicy, InstanceEndpoint};

const ARCHIVE_PATH: &str = "/instance.tar.gz";
const ARCHIVE_FILE: &str = "instance.tar.gz";

#[derive(Clone)]
pub struct InstanceBackupContext {
    pub endpoint: InstanceEndpoint,
    pub policy: InstanceBackupPolicy,
    pub executor: String,
    pub resource: String,
    pub was_running: Option<bool>,
}

impl InstanceBackupContext {
    pub fn new(endpoint: &InstanceEndpoint, policy: &InstanceBackupPolicy) -> Result<Self> {
        Ok(Self {
            endpoint: endpoint.clone(),
            policy: policy.clone(),
            executor: policy.executor(endpoint).to_owned(),
            resource: instance_resource(endpoint)?,
            was_running: None,
        })
    }
}

pub struct CompletedInstanceCopy {
    pub evidence: Value,
    pub artifact: BackupArtifact,
}

pub fn inspect(
    adapter: &NativeAdapter,
    context: &InstanceBackupContext,
    owner: &str,
    job_id: &str,
) -> Result<bool> {
    let result = control(
        adapter,
        context,
        owner,
        job_id,
        InstanceControlAction::Inspect,
    )?;
    if result
        .pointer("/result/instance_control/existed")
        .and_then(Value::as_bool)
        != Some(true)
    {
        bail!("source Incus instance does not exist");
    }
    result
        .pointer("/result/instance_control/was_running")
        .and_then(Value::as_bool)
        .context("instance inspection did not report runtime state")
}

pub fn hold(
    adapter: &NativeAdapter,
    context: &InstanceBackupContext,
    owner: &str,
    job_prefix: &str,
) -> Result<()> {
    if context.was_running.is_none() {
        bail!("instance backup did not durably capture pre-stop runtime state");
    }
    adapter.run_profile_job(
        &context.executor,
        &format!("{job_prefix}-reserve"),
        owner,
        &context.resource,
        &["--operation".to_owned(), "reserve".to_owned()],
    )?;
    control(
        adapter,
        context,
        owner,
        &format!("{job_prefix}-stop"),
        InstanceControlAction::Stop {
            allow_absent: false,
        },
    )?;
    control(
        adapter,
        context,
        owner,
        &format!("{job_prefix}-inactive"),
        InstanceControlAction::AssertStopped {
            allow_absent: false,
        },
    )?;
    Ok(())
}

pub fn release(
    adapter: &NativeAdapter,
    context: &InstanceBackupContext,
    owner: &str,
    job_prefix: &str,
) -> Result<()> {
    match context.was_running {
        Some(true) => {
            control(
                adapter,
                context,
                owner,
                &format!("{job_prefix}-activate"),
                InstanceControlAction::Activate,
            )?;
        }
        Some(false) => adapter.run_profile_job(
            &context.executor,
            &format!("{job_prefix}-release"),
            owner,
            &context.resource,
            &["--operation".to_owned(), "release".to_owned()],
        )?,
        None => bail!("instance backup has no durable pre-stop runtime state"),
    }
    Ok(())
}

pub fn copy(
    adapter: &NativeAdapter,
    context: &InstanceBackupContext,
    target: &str,
    owner: &str,
    copy_id: &str,
) -> Result<CompletedInstanceCopy> {
    let controller_target = Path::new(target).is_absolute();
    if controller_target {
        if Path::new(target) == Path::new("/") {
            bail!("controller backup destination cannot be the filesystem root");
        }
        require_controller_backup_privileges()?;
    } else {
        adapter.config().host(target)?;
    }

    let destination_root = if controller_target {
        PathBuf::from(target)
            .join(digest_bytes(context.resource.as_bytes()))
            .join(copy_id)
    } else {
        archive_root(adapter.config(), target, &context.resource, copy_id)?
    };
    let same_host_destination = !controller_target && context.executor == target;
    let staging_snapshot = if same_host_destination {
        copy_id.to_owned()
    } else {
        format!("{copy_id}-stage")
    };
    let staging_root = archive_root(
        adapter.config(),
        &context.executor,
        &context.resource,
        &staging_snapshot,
    )?;
    let export = run_job(
        adapter,
        &context.executor,
        context,
        owner,
        &format!("{copy_id}-export"),
        InstanceBackupAction::Export {
            archive_root: staging_root.clone(),
            include_snapshots: context.policy.include_snapshots,
            optimized_storage: context.policy.optimized_storage,
        },
    )?;
    let sha256 = export
        .pointer("/result/instance_backup/sha256")
        .and_then(Value::as_str)
        .context("instance export job did not report SHA-256")?
        .to_owned();
    let size_bytes = export
        .pointer("/result/instance_backup/size_bytes")
        .and_then(Value::as_u64)
        .context("instance export job did not report archive size")?;

    let target_is_local = !controller_target && adapter.config().host(target)?.local;
    let copy = if same_host_destination {
        json!({ "engine": "agent_local", "export": export })
    } else if controller_target || target_is_local {
        if target_is_local {
            require_controller_backup_privileges()?;
        }
        let remote_source = if adapter.config().host(&context.executor)?.local {
            None
        } else {
            Some(adapter.config().remote_source(&context.executor)?)
        };
        let transfer = transfer_with_excludes_progress(
            &TransferDefinition {
                source: staging_root.clone(),
                destination: destination_root.clone(),
                rsync_program: adapter.config().ssh.rsync_program.clone(),
                remote_source,
                remote_destination: None,
                tar_program: adapter.config().ssh.tar_program.clone(),
                delete: true,
                fallback_copy: true,
            },
            &[],
            |_| Ok(()),
        )?;
        json!({ "engine": "controller", "transfer": transfer, "export": export })
    } else {
        let plan = vec![DataRootPlan {
            name: "instance-export".to_owned(),
            source: staging_root.clone(),
            target: destination_root.clone(),
            excludes: Vec::new(),
        }];
        let copy = adapter.run_broker_profile_job(
            &format!("{copy_id}-copy"),
            owner,
            &context.resource,
            &context.executor,
            target,
            false,
            None,
            Some(&plan),
            true,
        )?;
        let verification = adapter.run_broker_profile_job(
            &format!("{copy_id}-verify-transfer"),
            owner,
            &context.resource,
            &context.executor,
            target,
            true,
            None,
            Some(&plan),
            true,
        )?;
        json!({
            "engine": "controller_broker",
            "copy": copy,
            "verification": verification,
            "export": export,
        })
    };

    let location = if controller_target {
        verify_controller_export(&destination_root, &sha256, size_bytes)?;
        InstanceExportLocation::ControllerDirectory {
            root: destination_root.clone(),
        }
    } else {
        verify_on_host(
            adapter,
            context,
            target,
            owner,
            &format!("{copy_id}-verify-archive"),
            &destination_root,
            ArchiveIntegrity {
                sha256: &sha256,
                size_bytes,
            },
        )?;
        InstanceExportLocation::Host {
            host: target.to_owned(),
            root: destination_root.clone(),
        }
    };
    let staging = (!same_host_destination).then(|| InstanceExportLocation::Host {
        host: context.executor.clone(),
        root: staging_root,
    });
    Ok(CompletedInstanceCopy {
        evidence: json!({
            "ok": true,
            "resource": context.resource,
            "instance": context.endpoint,
            "from": context.executor,
            "to": target,
            "backup": owner,
            "copy_id": copy_id,
            "consistency": "quiesced",
            "sha256": sha256,
            "size_bytes": size_bytes,
            "copy": copy,
        }),
        artifact: BackupArtifact::InstanceExport {
            source: context.endpoint.clone(),
            location,
            staging,
            sha256,
            size_bytes,
        },
    })
}

pub fn cleanup_staging(
    adapter: &NativeAdapter,
    context: &InstanceBackupContext,
    owner: &str,
    location: &InstanceExportLocation,
) -> Result<()> {
    let InstanceExportLocation::Host { host, root } = location else {
        return Ok(());
    };
    run_job(
        adapter,
        host,
        context,
        owner,
        &format!(
            "stage-delete-{}-{}",
            &digest_bytes(root.as_os_str().as_encoded_bytes())[..16],
            &Uuid::new_v4().simple().to_string()[..16]
        ),
        InstanceBackupAction::DeleteArchive {
            archive_root: root.clone(),
        },
    )?;
    Ok(())
}

pub fn cleanup_pending_stage(
    adapter: &NativeAdapter,
    context: &InstanceBackupContext,
    owner: &str,
    copy_id: &str,
    same_host_destination: bool,
) -> Result<()> {
    let snapshot = if same_host_destination {
        copy_id.to_owned()
    } else {
        format!("{copy_id}-stage")
    };
    let root = archive_root(
        adapter.config(),
        &context.executor,
        &context.resource,
        &snapshot,
    )?;
    run_job(
        adapter,
        &context.executor,
        context,
        owner,
        &format!(
            "abort-delete-{}-{}",
            &digest_bytes(format!("{owner}-{snapshot}").as_bytes())[..16],
            &Uuid::new_v4().simple().to_string()[..16]
        ),
        InstanceBackupAction::DeleteArchive { archive_root: root },
    )?;
    Ok(())
}

pub fn create_safety_export(
    adapter: &NativeAdapter,
    context: &InstanceBackupContext,
    owner: &str,
    snapshot: &str,
) -> Result<BackupArtifact> {
    let root = archive_root(
        adapter.config(),
        &context.executor,
        &context.resource,
        snapshot,
    )?;
    let result = run_job(
        adapter,
        &context.executor,
        context,
        owner,
        &format!("{snapshot}-export"),
        InstanceBackupAction::Export {
            archive_root: root.clone(),
            include_snapshots: true,
            optimized_storage: false,
        },
    )?;
    let sha256 = result
        .pointer("/result/instance_backup/sha256")
        .and_then(Value::as_str)
        .context("safety export did not report SHA-256")?
        .to_owned();
    let size_bytes = result
        .pointer("/result/instance_backup/size_bytes")
        .and_then(Value::as_u64)
        .context("safety export did not report size")?;
    Ok(BackupArtifact::InstanceExport {
        source: context.endpoint.clone(),
        location: InstanceExportLocation::Host {
            host: context.executor.clone(),
            root,
        },
        staging: None,
        sha256,
        size_bytes,
    })
}

pub fn restore(
    adapter: &NativeAdapter,
    context: &InstanceBackupContext,
    artifact: &BackupArtifact,
    owner: &str,
) -> Result<Value> {
    let BackupArtifact::InstanceExport {
        source,
        location,
        sha256,
        size_bytes,
        ..
    } = artifact
    else {
        bail!("data backup artifact cannot restore an Incus instance")
    };
    if source != &context.endpoint {
        bail!("instance export source identity differs from restore target");
    }
    let (restore_root, staged, copy) = match location {
        InstanceExportLocation::Host { host, root } if host == &context.executor => {
            (root.clone(), false, json!({ "engine": "agent_local" }))
        }
        location => {
            let stage_snapshot = format!(
                "{}-restore-{}-{}",
                &digest_bytes(owner.as_bytes())[..16],
                &digest_bytes(context.resource.as_bytes())[..12],
                &sha256[..12]
            );
            let stage_root = archive_root(
                adapter.config(),
                &context.executor,
                &context.resource,
                &stage_snapshot,
            )?;
            let copy = match location {
                InstanceExportLocation::ControllerDirectory { root } => {
                    require_controller_backup_privileges()?;
                    let remote_destination = if adapter.config().host(&context.executor)?.local {
                        None
                    } else {
                        Some(adapter.config().remote_source(&context.executor)?)
                    };
                    let transfer = transfer_with_excludes_progress(
                        &TransferDefinition {
                            source: root.clone(),
                            destination: stage_root.clone(),
                            rsync_program: adapter.config().ssh.rsync_program.clone(),
                            remote_source: None,
                            remote_destination,
                            tar_program: adapter.config().ssh.tar_program.clone(),
                            delete: true,
                            fallback_copy: true,
                        },
                        &[],
                        |_| Ok(()),
                    )?;
                    json!({ "engine": "controller", "transfer": transfer })
                }
                InstanceExportLocation::Host { host, root } => {
                    let plan = vec![DataRootPlan {
                        name: "instance-export".to_owned(),
                        source: root.clone(),
                        target: stage_root.clone(),
                        excludes: Vec::new(),
                    }];
                    let copy = adapter.run_broker_profile_job(
                        &format!("{stage_snapshot}-copy"),
                        owner,
                        &context.resource,
                        host,
                        &context.executor,
                        false,
                        None,
                        Some(&plan),
                        true,
                    )?;
                    let verification = adapter.run_broker_profile_job(
                        &format!("{stage_snapshot}-verify"),
                        owner,
                        &context.resource,
                        host,
                        &context.executor,
                        true,
                        None,
                        Some(&plan),
                        true,
                    )?;
                    json!({
                        "engine": "controller_broker",
                        "copy": copy,
                        "verification": verification,
                    })
                }
            };
            verify_on_host(
                adapter,
                context,
                &context.executor,
                owner,
                &format!("{stage_snapshot}-verify-archive"),
                &stage_root,
                ArchiveIntegrity {
                    sha256,
                    size_bytes: *size_bytes,
                },
            )?;
            (stage_root, true, copy)
        }
    };
    let replace = run_job(
        adapter,
        &context.executor,
        context,
        owner,
        &format!(
            "{}-replace-{}",
            &digest_bytes(format!("{owner}\0{}", context.resource).as_bytes())[..16],
            &sha256[..12]
        ),
        InstanceBackupAction::Replace {
            archive_root: restore_root.clone(),
            sha256: sha256.clone(),
            size_bytes: *size_bytes,
            storage_pool: context.policy.restore_storage_pool.clone(),
        },
    )?;
    if staged {
        cleanup_staging(
            adapter,
            context,
            owner,
            &InstanceExportLocation::Host {
                host: context.executor.clone(),
                root: restore_root,
            },
        )?;
    }
    Ok(json!({
        "engine": "incus_import",
        "copy": copy,
        "replace": replace,
        "staging_deleted": staged,
    }))
}

pub fn verify_controller_export(root: &Path, sha256: &str, size_bytes: u64) -> Result<()> {
    let archive = root.join(ARCHIVE_FILE);
    let file = fs::File::open(&archive)
        .with_context(|| format!("open controller instance export {}", archive.display()))?;
    let actual_size = file.metadata()?.len();
    let actual_sha256 = digest_reader(file).context("hash controller instance export")?;
    if actual_size != size_bytes || actual_sha256 != sha256 {
        bail!("controller instance export failed independent integrity verification");
    }
    Ok(())
}

pub fn verify_on_host_fresh(
    adapter: &NativeAdapter,
    context: &InstanceBackupContext,
    host: &str,
    owner: &str,
    root: &Path,
    sha256: &str,
    size_bytes: u64,
) -> Result<()> {
    verify_on_host(
        adapter,
        context,
        host,
        owner,
        &format!(
            "verify-{}-{}",
            &digest_bytes(root.as_os_str().as_encoded_bytes())[..16],
            &Uuid::new_v4().simple().to_string()[..16]
        ),
        root,
        ArchiveIntegrity { sha256, size_bytes },
    )
}

pub fn delete(
    adapter: &NativeAdapter,
    context: &InstanceBackupContext,
    owner: &str,
    artifact: &BackupArtifact,
) -> Result<()> {
    let BackupArtifact::InstanceExport {
        location, staging, ..
    } = artifact
    else {
        bail!("data backup artifact cannot be deleted as an instance export")
    };
    for location in staging.iter().chain(std::iter::once(location)) {
        match location {
            InstanceExportLocation::ControllerDirectory { root } => {
                require_controller_backup_privileges()?;
                if !root.is_absolute() || root == Path::new("/") {
                    bail!("refusing to delete an invalid controller instance export");
                }
                if root.exists() {
                    fs::remove_dir_all(root).with_context(|| {
                        format!("delete controller instance export {}", root.display())
                    })?;
                    if let Some(parent) = root.parent() {
                        fs::File::open(parent)?.sync_all()?;
                    }
                }
            }
            InstanceExportLocation::Host { host, root } => {
                run_job(
                    adapter,
                    host,
                    context,
                    owner,
                    &format!(
                        "delete-instance-export-{}-{}",
                        &digest_bytes(root.as_os_str().as_encoded_bytes())[..16],
                        &Uuid::new_v4().simple().to_string()[..16]
                    ),
                    InstanceBackupAction::DeleteArchive {
                        archive_root: root.clone(),
                    },
                )?;
            }
        }
    }
    Ok(())
}

#[derive(Clone, Copy)]
struct ArchiveIntegrity<'a> {
    sha256: &'a str,
    size_bytes: u64,
}

fn verify_on_host(
    adapter: &NativeAdapter,
    context: &InstanceBackupContext,
    host: &str,
    owner: &str,
    job_id: &str,
    root: &Path,
    integrity: ArchiveIntegrity<'_>,
) -> Result<()> {
    run_job(
        adapter,
        host,
        context,
        owner,
        job_id,
        InstanceBackupAction::Verify {
            archive_root: root.to_path_buf(),
            sha256: integrity.sha256.to_owned(),
            size_bytes: integrity.size_bytes,
        },
    )?;
    Ok(())
}

fn control(
    adapter: &NativeAdapter,
    context: &InstanceBackupContext,
    owner: &str,
    job_id: &str,
    operation: InstanceControlAction,
) -> Result<Value> {
    let request = InstanceControlRequest {
        program: context.policy.program.clone(),
        remote: context.endpoint.remote.clone(),
        project: context.endpoint.project.clone(),
        instance: context.endpoint.instance.clone(),
        stop_timeout_seconds: context.policy.stop_timeout_seconds,
        force_after_timeout: context.policy.force_after_timeout,
        operation,
    };
    adapter.run_profile_job_result(
        &context.executor,
        job_id,
        owner,
        &context.resource,
        &[
            "--control-instance".to_owned(),
            serde_json::to_string(&request)?,
        ],
    )
}

fn run_job(
    adapter: &NativeAdapter,
    executor: &str,
    context: &InstanceBackupContext,
    owner: &str,
    job_id: &str,
    operation: InstanceBackupAction,
) -> Result<Value> {
    let request = InstanceBackupRequest {
        program: context.policy.program.clone(),
        remote: context.endpoint.remote.clone(),
        project: context.endpoint.project.clone(),
        instance: context.endpoint.instance.clone(),
        operation,
    };
    adapter.run_profile_job_result(
        executor,
        job_id,
        owner,
        &context.resource,
        &[
            "--backup-instance".to_owned(),
            serde_json::to_string(&request)?,
        ],
    )
}

fn archive_root(
    config: &HostManagerConfig,
    host: &str,
    resource: &str,
    snapshot: &str,
) -> Result<PathBuf> {
    let plan = config.run_agent(
        host,
        &[
            "--json".to_owned(),
            "data".to_owned(),
            "backup-plan".to_owned(),
            "--resource".to_owned(),
            resource.to_owned(),
            "--snapshot".to_owned(),
            snapshot.to_owned(),
            "--source-path".to_owned(),
            ARCHIVE_PATH.to_owned(),
        ],
    )?;
    plan.pointer("/result/destination_root")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .context("agent instance backup plan has no destination_root")
}

fn require_controller_backup_privileges() -> Result<()> {
    let status = fs::read_to_string("/proc/self/status").context("read process credentials")?;
    let effective_uid = status
        .lines()
        .find_map(|line| line.strip_prefix("Uid:"))
        .and_then(|uids| uids.split_whitespace().nth(1))
        .context("process status has no effective UID")?
        .parse::<u32>()
        .context("parse effective UID")?;
    if effective_uid != 0 {
        bail!(
            "controller-directory instance backups must run through local sudo so restrictive modes remain exact"
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn endpoint(project: &str) -> InstanceEndpoint {
        InstanceEndpoint {
            controller: "gondor".to_owned(),
            remote: "prod".to_owned(),
            project: project.to_owned(),
            instance: "zulip".to_owned(),
        }
    }

    #[test]
    fn context_binds_full_endpoint_authority_and_explicit_executor() {
        let mut policy = InstanceBackupPolicy::default();
        policy.executor_controller = Some("backup-controller".to_owned());
        let first = InstanceBackupContext::new(&endpoint("abird"), &policy).unwrap();
        let second = InstanceBackupContext::new(&endpoint("other"), &policy).unwrap();
        assert_eq!(first.executor, "backup-controller");
        assert_ne!(first.resource, second.resource);
        assert!(first.resource.starts_with("instance:"));
    }
}
