use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::Deserialize;

use crate::cmd;
use crate::command::CommandResult;

#[derive(Clone, Debug)]
pub struct Incus {
    executable: PathBuf,
}

#[derive(Debug)]
pub struct IncusOutput {
    pub arguments: Vec<String>,
    pub result: CommandResult,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IncusInstanceInfo {
    pub status: String,
    pub kind: String,
    pub root_pool: Option<String>,
}

#[derive(Debug)]
pub struct IncusInstanceProbe {
    pub output: IncusOutput,
    pub info: Option<IncusInstanceInfo>,
}

#[derive(Debug)]
pub struct IncusSnapshotProbe {
    pub output: IncusOutput,
    pub exists: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IncusStoragePoolInfo {
    pub driver: String,
}

#[derive(Debug)]
pub struct IncusStoragePoolProbe {
    pub output: IncusOutput,
    pub info: IncusStoragePoolInfo,
}

pub struct IncusInitRequest<'a> {
    pub image: &'a str,
    pub name: &'a str,
    pub project: &'a str,
    pub profiles: &'a [String],
    pub config: &'a BTreeMap<String, String>,
    pub devices: &'a BTreeMap<String, BTreeMap<String, String>>,
}

pub struct IncusCopyRequest<'a> {
    pub source: &'a str,
    pub target: &'a str,
    pub source_project: &'a str,
    pub target_project: &'a str,
    pub target_pool: &'a str,
    pub mode: &'a str,
    pub refresh: bool,
    pub stateless: bool,
    pub allow_inconsistent: bool,
}

#[derive(Deserialize)]
struct ApiResponse<T> {
    metadata: T,
}

#[derive(Deserialize)]
struct InstanceMetadata {
    #[serde(default)]
    status: String,
    #[serde(default, rename = "type")]
    kind: String,
    #[serde(default)]
    expanded_devices: BTreeMap<String, BTreeMap<String, String>>,
}

#[derive(Deserialize)]
struct StoragePoolMetadata {
    driver: String,
}

impl Incus {
    pub fn new(executable: impl Into<PathBuf>) -> Result<Self> {
        let executable = executable.into();
        if !executable.is_absolute()
            || executable.file_name().and_then(|name| name.to_str()) != Some("incus")
        {
            bail!("Incus executable must be an absolute path ending in incus");
        }
        Ok(Self { executable })
    }

    pub fn executable(&self) -> &Path {
        &self.executable
    }

    pub fn info(&self, instance: &str, project: &str) -> Result<IncusOutput> {
        self.execute(vec![
            "info".to_owned(),
            instance.to_owned(),
            "--project".to_owned(),
            project.to_owned(),
        ])
    }

    pub fn init(&self, request: IncusInitRequest<'_>) -> Result<IncusOutput> {
        let mut arguments = vec![
            "init".to_owned(),
            request.image.to_owned(),
            request.name.to_owned(),
            "--project".to_owned(),
            request.project.to_owned(),
        ];
        for profile in request.profiles {
            arguments.extend(["--profile".to_owned(), profile.clone()]);
        }
        for (key, value) in request.config {
            arguments.extend(["--config".to_owned(), format!("{key}={value}")]);
        }
        for (device, properties) in request.devices {
            let properties = properties
                .iter()
                .map(|(key, value)| format!("{key}={value}"))
                .collect::<Vec<_>>()
                .join(",");
            arguments.extend(["--device".to_owned(), format!("{device},{properties}")]);
        }
        self.execute(arguments)
    }

    pub fn start(&self, instance: &str, project: &str) -> Result<IncusOutput> {
        self.execute(vec![
            "start".to_owned(),
            instance.to_owned(),
            "--project".to_owned(),
            project.to_owned(),
        ])
    }

    pub fn stop(
        &self,
        instance: &str,
        project: &str,
        timeout_seconds: Option<u64>,
        force: bool,
    ) -> Result<IncusOutput> {
        let mut arguments = vec![
            "stop".to_owned(),
            instance.to_owned(),
            "--project".to_owned(),
            project.to_owned(),
        ];
        if let Some(timeout_seconds) = timeout_seconds {
            arguments.extend(["--timeout".to_owned(), timeout_seconds.to_string()]);
        }
        if force {
            arguments.push("--force".to_owned());
        }
        self.execute(arguments)
    }

    pub fn inspect_snapshot(
        &self,
        instance: &str,
        snapshot: &str,
        project: &str,
    ) -> Result<IncusSnapshotProbe> {
        let output = self.info(&format!("{instance}/{snapshot}"), project)?;
        if output.result.success {
            return Ok(IncusSnapshotProbe {
                output,
                exists: true,
            });
        }
        if is_not_found(&output.result.stderr) {
            return Ok(IncusSnapshotProbe {
                output,
                exists: false,
            });
        }
        bail!(
            "Incus snapshot inspection failed with {:?}: {}",
            output.result.exit_code,
            output.result.stderr
        )
    }

    pub fn snapshot_create(
        &self,
        instance: &str,
        snapshot: &str,
        project: &str,
        stateful: bool,
    ) -> Result<IncusOutput> {
        let mut arguments = vec![
            "snapshot".to_owned(),
            "create".to_owned(),
            instance.to_owned(),
            snapshot.to_owned(),
            "--project".to_owned(),
            project.to_owned(),
        ];
        if stateful {
            arguments.push("--stateful".to_owned());
        }
        self.execute(arguments)
    }

    pub fn snapshot_delete(
        &self,
        instance: &str,
        snapshot: &str,
        project: &str,
    ) -> Result<IncusOutput> {
        self.execute(vec![
            "snapshot".to_owned(),
            "delete".to_owned(),
            format!("{instance}/{snapshot}"),
            "--project".to_owned(),
            project.to_owned(),
        ])
    }

    pub fn export(
        &self,
        remote: &str,
        instance: &str,
        project: &str,
        archive: &Path,
        include_snapshots: bool,
        optimized_storage: bool,
    ) -> Result<IncusOutput> {
        let mut arguments = vec![
            "export".to_owned(),
            format!("{remote}:{instance}"),
            archive.to_string_lossy().into_owned(),
            "--project".to_owned(),
            project.to_owned(),
            "--compression".to_owned(),
            "gzip".to_owned(),
            "--force".to_owned(),
        ];
        if !include_snapshots {
            arguments.push("--instance-only".to_owned());
        }
        if optimized_storage {
            arguments.push("--optimized-storage".to_owned());
        }
        self.execute(arguments)
    }

    pub fn import(
        &self,
        remote: &str,
        archive: &Path,
        instance: &str,
        project: &str,
        storage_pool: Option<&str>,
    ) -> Result<IncusOutput> {
        let mut arguments = vec![
            "import".to_owned(),
            format!("{remote}:"),
            archive.to_string_lossy().into_owned(),
            instance.to_owned(),
            "--project".to_owned(),
            project.to_owned(),
        ];
        if let Some(storage_pool) = storage_pool {
            arguments.extend(["--storage".to_owned(), storage_pool.to_owned()]);
        }
        self.execute(arguments)
    }

    pub fn delete(&self, remote: &str, instance: &str, project: &str) -> Result<IncusOutput> {
        self.execute(vec![
            "delete".to_owned(),
            format!("{remote}:{instance}"),
            "--project".to_owned(),
            project.to_owned(),
        ])
    }

    pub fn copy(&self, request: IncusCopyRequest<'_>) -> Result<IncusOutput> {
        let mut arguments = vec![
            "--project".to_owned(),
            request.source_project.to_owned(),
            "copy".to_owned(),
            request.source.to_owned(),
            request.target.to_owned(),
            "--target-project".to_owned(),
            request.target_project.to_owned(),
            "--storage".to_owned(),
            request.target_pool.to_owned(),
            "--mode".to_owned(),
            request.mode.to_owned(),
        ];
        if request.refresh {
            arguments.extend(["--refresh".to_owned(), "--refresh-exclude-older".to_owned()]);
        }
        if request.stateless {
            arguments.push("--stateless".to_owned());
        }
        if request.allow_inconsistent {
            arguments.push("--allow-inconsistent".to_owned());
        }
        self.execute(arguments)
    }

    pub fn config_get(&self, instance: &str, project: &str, key: &str) -> Result<IncusOutput> {
        self.execute(vec![
            "config".to_owned(),
            "get".to_owned(),
            instance.to_owned(),
            key.to_owned(),
            "--project".to_owned(),
            project.to_owned(),
        ])
    }

    pub fn config_set(
        &self,
        instance: &str,
        project: &str,
        key: &str,
        value: &str,
    ) -> Result<IncusOutput> {
        self.execute(vec![
            "config".to_owned(),
            "set".to_owned(),
            instance.to_owned(),
            format!("{key}={value}"),
            "--project".to_owned(),
            project.to_owned(),
        ])
    }

    pub fn inspect_instance(
        &self,
        remote: &str,
        instance: &str,
        project: &str,
    ) -> Result<IncusInstanceProbe> {
        let output = self.execute(vec![
            "query".to_owned(),
            query_ref(
                remote,
                &format!("/1.0/instances/{instance}?project={project}"),
            ),
            "--raw".to_owned(),
        ])?;
        if !output.result.success {
            if is_not_found(&output.result.stderr) {
                return Ok(IncusInstanceProbe { output, info: None });
            }
            bail!(
                "Incus instance inspection failed with {:?}: {}",
                output.result.exit_code,
                output.result.stderr
            );
        }
        let response: ApiResponse<InstanceMetadata> =
            serde_json::from_str(&output.result.stdout)
                .context("parse Incus instance inspection JSON")?;
        let root_pool = response
            .metadata
            .expanded_devices
            .values()
            .find_map(|device| {
                (device.get("type").map(String::as_str) == Some("disk")
                    && device.get("path").map(String::as_str) == Some("/"))
                .then(|| device.get("pool").cloned())
                .flatten()
            });
        Ok(IncusInstanceProbe {
            output,
            info: Some(IncusInstanceInfo {
                status: response.metadata.status,
                kind: response.metadata.kind,
                root_pool,
            }),
        })
    }

    pub fn inspect_storage_pool(&self, remote: &str, pool: &str) -> Result<IncusStoragePoolProbe> {
        let output = self.execute(vec![
            "query".to_owned(),
            query_ref(remote, &format!("/1.0/storage-pools/{pool}")),
            "--raw".to_owned(),
        ])?;
        if !output.result.success {
            bail!(
                "Incus storage-pool inspection failed with {:?}: {}",
                output.result.exit_code,
                output.result.stderr
            );
        }
        let response: ApiResponse<StoragePoolMetadata> =
            serde_json::from_str(&output.result.stdout)
                .context("parse Incus storage-pool inspection JSON")?;
        if response.metadata.driver.trim().is_empty() {
            bail!("Incus storage-pool inspection returned an empty driver");
        }
        Ok(IncusStoragePoolProbe {
            output,
            info: IncusStoragePoolInfo {
                driver: response.metadata.driver,
            },
        })
    }

    fn execute(&self, arguments: Vec<String>) -> Result<IncusOutput> {
        let result = cmd!(&self.executable).args(&arguments).output()?;
        Ok(IncusOutput { arguments, result })
    }
}

fn query_ref(remote: &str, path: &str) -> String {
    if remote == "local" {
        path.to_owned()
    } else {
        format!("{remote}:{path}")
    }
}

fn is_not_found(stderr: &str) -> bool {
    let stderr = stderr.to_ascii_lowercase();
    stderr.contains("not found") || stderr.contains("404")
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    fn fake_incus(script: &str) -> (tempfile::TempDir, Incus) {
        let temp = tempfile::tempdir().unwrap();
        let program = temp.path().join("incus");
        fs::write(&program, format!("#!/bin/sh\n{script}\n")).unwrap();
        fs::set_permissions(&program, fs::Permissions::from_mode(0o700)).unwrap();
        let incus = Incus::new(&program).unwrap();
        (temp, incus)
    }

    #[test]
    fn copy_owns_incus_flag_vocabulary() {
        let temp = tempfile::tempdir().unwrap();
        let args = temp.path().join("args");
        let program = temp.path().join("incus");
        fs::write(
            &program,
            format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\n", args.display()),
        )
        .unwrap();
        fs::set_permissions(&program, fs::Permissions::from_mode(0o700)).unwrap();
        let incus = Incus::new(&program).unwrap();
        incus
            .copy(IncusCopyRequest {
                source: "source/snapshot",
                target: "remote:target",
                source_project: "old",
                target_project: "new",
                target_pool: "fast",
                mode: "relay",
                refresh: true,
                stateless: true,
                allow_inconsistent: true,
            })
            .unwrap();
        assert_eq!(
            fs::read_to_string(args).unwrap(),
            "--project\nold\ncopy\nsource/snapshot\nremote:target\n--target-project\nnew\n--storage\nfast\n--mode\nrelay\n--refresh\n--refresh-exclude-older\n--stateless\n--allow-inconsistent\n"
        );
    }

    #[test]
    fn inspection_extracts_runtime_type_and_root_pool() {
        let (_temp, incus) = fake_incus(
            r#"printf '%s' '{"metadata":{"status":"Running","type":"virtual-machine","expanded_devices":{"root":{"type":"disk","path":"/","pool":"fast"}}}}'"#,
        );
        let probe = incus
            .inspect_instance("local", "source", "default")
            .unwrap();
        assert_eq!(
            probe.info,
            Some(IncusInstanceInfo {
                status: "Running".to_owned(),
                kind: "virtual-machine".to_owned(),
                root_pool: Some("fast".to_owned()),
            })
        );
    }

    #[test]
    fn backup_commands_own_portable_export_and_restore_vocabulary() {
        let temp = tempfile::tempdir().unwrap();
        let args = temp.path().join("args");
        let program = temp.path().join("incus");
        fs::write(
            &program,
            format!("#!/bin/sh\nprintf '%s\\n' \"$@\" >> '{}'\n", args.display()),
        )
        .unwrap();
        fs::set_permissions(&program, fs::Permissions::from_mode(0o700)).unwrap();
        let incus = Incus::new(&program).unwrap();
        let archive = temp.path().join("instance.tar.gz");
        incus
            .export("prod", "zulip", "abird", &archive, false, true)
            .unwrap();
        incus
            .import("prod", &archive, "zulip-restored", "abird", Some("fast"))
            .unwrap();
        incus.delete("prod", "zulip-restored", "abird").unwrap();
        assert_eq!(
            fs::read_to_string(args).unwrap(),
            format!(
                "export\nprod:zulip\n{}\n--project\nabird\n--compression\ngzip\n--force\n--instance-only\n--optimized-storage\nimport\nprod:\n{}\nzulip-restored\n--project\nabird\n--storage\nfast\ndelete\nprod:zulip-restored\n--project\nabird\n",
                archive.display(),
                archive.display()
            )
        );
    }
}
