use std::collections::{BTreeMap, HashSet};
use std::fs::File;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use clap::ValueEnum;
use serde::{Deserialize, Serialize};

use crate::deployment::{
    DeploymentDefinition, NixbotDeployPolicy, validate_deployment, validate_nixbot_deploy_policy,
};
use crate::file_state::{FileStateDefinition, validate_file_state};
use crate::instance::{InstanceDefinition, validate_instance};
use crate::readiness::{ReadinessCheck, validate_check};
use crate::service::{ServiceScope, ServiceTarget};
use crate::sha256::digest_bytes;
use crate::transfer::{TransferDefinition, validate_transfer};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum ExpectedState {
    Any,
    Active,
    Inactive,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ResourceManifest {
    pub schema_version: u32,
    #[serde(default)]
    pub broker_transfer: Option<BrokerTransferPolicy>,
    #[serde(default)]
    pub nixbot_deploy: Option<NixbotDeployPolicy>,
    #[serde(default = "default_backup_root")]
    pub backup_root: PathBuf,
    #[serde(default = "default_rsync_program")]
    pub rsync_program: PathBuf,
    #[serde(default = "default_tar_program")]
    pub tar_program: PathBuf,
    pub resources: Vec<ResourceDefinition>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BrokerTransferPolicy {
    pub identity_file: PathBuf,
    pub ssh_program: PathBuf,
    pub ssh_agent_program: PathBuf,
    pub ssh_add_program: PathBuf,
    #[serde(default)]
    pub ssh_args: Vec<String>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BackupConsistency {
    Live,
    #[default]
    Quiesced,
}

/// One stable, independently addressable data root owned by a resource.
///
/// Excludes are relative subtree paths. They never escape the root and match
/// only the named entry and its descendants.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DataRoot {
    pub name: String,
    pub path: PathBuf,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub excludes: Vec<PathBuf>,
}

/// Immutable source/target mapping embedded in a durable broker job.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DataRootPlan {
    pub name: String,
    pub source: PathBuf,
    pub target: PathBuf,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub excludes: Vec<PathBuf>,
}

impl DataRootPlan {
    pub fn source_root(&self) -> DataRoot {
        DataRoot {
            name: self.name.clone(),
            path: self.source.clone(),
            excludes: self.excludes.clone(),
        }
    }

    pub fn target_root(&self) -> DataRoot {
        DataRoot {
            name: self.name.clone(),
            path: self.target.clone(),
            excludes: self.excludes.clone(),
        }
    }
}

pub fn validate_data_root_plan(plan: &DataRootPlan) -> Result<()> {
    validate_data_root(&plan.source_root())?;
    validate_data_root(&plan.target_root())
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ResourceDefinition {
    pub id: String,
    #[serde(default)]
    pub services: Vec<ServiceTarget>,
    #[serde(default)]
    pub data_paths: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub data_roots: Vec<DataRoot>,
    #[serde(default)]
    pub backup_consistency: BackupConsistency,
    #[serde(default)]
    pub operations: BTreeMap<String, NamedOperation>,
    #[serde(default)]
    pub readiness: Vec<ReadinessCheck>,
    #[serde(default)]
    pub transfers: BTreeMap<String, TransferDefinition>,
    #[serde(default)]
    pub file_states: BTreeMap<String, FileStateDefinition>,
    #[serde(default)]
    pub instances: BTreeMap<String, InstanceDefinition>,
    #[serde(default)]
    pub deployments: BTreeMap<String, DeploymentDefinition>,
    #[serde(default)]
    pub nixbot_deploy: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct NamedOperation {
    /// Fixed executable and argument vector. No shell expansion is performed.
    pub argv: Vec<String>,
}

impl ResourceManifest {
    pub fn load(path: &Path) -> Result<Self> {
        let file = File::open(path)
            .with_context(|| format!("open resource manifest {}", path.display()))?;
        let manifest: Self = serde_json::from_reader(file)
            .with_context(|| format!("parse resource manifest {}", path.display()))?;
        manifest.validate()?;
        Ok(manifest)
    }

    pub fn resource(&self, id: &str) -> Result<&ResourceDefinition> {
        self.resources
            .iter()
            .find(|resource| resource.id == id)
            .with_context(|| format!("resource {id:?} is not declared in the resource manifest"))
    }

    fn validate(&self) -> Result<()> {
        if self.schema_version != 1 {
            bail!(
                "unsupported resource manifest schema version {}",
                self.schema_version
            );
        }
        if !self.backup_root.is_absolute() || self.backup_root == Path::new("/") {
            bail!("backup root must be an absolute non-root path");
        }
        if !self.rsync_program.is_absolute() || !self.tar_program.is_absolute() {
            bail!("resource manifest copy programs must be absolute");
        }
        if let Some(policy) = &self.broker_transfer {
            policy.validate()?;
        }
        if let Some(policy) = &self.nixbot_deploy {
            validate_nixbot_deploy_policy(policy)?;
        }
        let mut ids = HashSet::new();
        for resource in &self.resources {
            if resource.id.trim().is_empty() || resource.id.contains('\0') {
                bail!("resource IDs must be non-empty and cannot contain NUL");
            }
            if !ids.insert(&resource.id) {
                bail!("duplicate resource ID {:?}", resource.id);
            }
            if resource.services.is_empty()
                && resource.data_paths.is_empty()
                && resource.data_roots.is_empty()
                && resource.operations.is_empty()
                && resource.readiness.is_empty()
                && resource.transfers.is_empty()
                && resource.file_states.is_empty()
                && resource.instances.is_empty()
                && resource.deployments.is_empty()
                && !resource.nixbot_deploy
            {
                bail!(
                    "resource {:?} must declare at least one service, data path, or operation",
                    resource.id
                );
            }
            for (index, service) in resource.services.iter().enumerate() {
                validate_declared_service_target(service)
                    .with_context(|| format!("resource {:?} service target", resource.id))?;
                if resource.services[..index].contains(service) {
                    bail!(
                        "resource {:?} contains duplicate service target {service}",
                        resource.id
                    );
                }
            }
            for path in &resource.data_paths {
                if !path.is_absolute() || path == Path::new("/") {
                    bail!(
                        "resource {:?} data path must be absolute and cannot be root: {}",
                        resource.id,
                        path.display()
                    );
                }
            }
            let mut root_names = HashSet::new();
            let mut root_paths = resource.data_paths.iter().collect::<HashSet<_>>();
            for root in &resource.data_roots {
                validate_data_root(root)
                    .with_context(|| format!("resource {:?} data root", resource.id))?;
                if !root_names.insert(&root.name) {
                    bail!(
                        "resource {:?} contains duplicate data-root name {:?}",
                        resource.id,
                        root.name
                    );
                }
                if !root_paths.insert(&root.path) {
                    bail!(
                        "resource {:?} declares data-root path more than once: {}",
                        resource.id,
                        root.path.display()
                    );
                }
            }
            for check in &resource.readiness {
                validate_check(check)
                    .with_context(|| format!("resource {:?} readiness check", resource.id))?;
            }
            for (name, operation) in &resource.operations {
                if name.trim().is_empty() || name.contains('\0') {
                    bail!("resource {:?} has an invalid operation name", resource.id);
                }
                let Some(executable) = operation.argv.first() else {
                    bail!(
                        "resource {:?} operation {name:?} has an empty argv",
                        resource.id
                    );
                };
                if !Path::new(executable).is_absolute() {
                    bail!(
                        "resource {:?} operation {name:?} executable must be absolute",
                        resource.id
                    );
                }
                if operation
                    .argv
                    .iter()
                    .any(|argument| argument.contains('\0'))
                {
                    bail!(
                        "resource {:?} operation {name:?} argv cannot contain NUL",
                        resource.id
                    );
                }
            }
            for (name, transfer) in &resource.transfers {
                if name.trim().is_empty() || name.contains('\0') {
                    bail!("resource {:?} has an invalid transfer name", resource.id);
                }
                validate_transfer(transfer)
                    .with_context(|| format!("resource {:?} transfer {name:?}", resource.id))?;
            }
            for (name, state) in &resource.file_states {
                if name.trim().is_empty() || name.contains('\0') {
                    bail!("resource {:?} has an invalid file-state name", resource.id);
                }
                validate_file_state(state)
                    .with_context(|| format!("resource {:?} file state {name:?}", resource.id))?;
                for service in &state.reload_services {
                    validate_declared_service_target(service).with_context(|| {
                        format!(
                            "resource {:?} file state {name:?} reload target",
                            resource.id
                        )
                    })?;
                }
            }
            for (name, instance) in &resource.instances {
                validate_profile_name(&resource.id, "instance", name)?;
                validate_instance(instance)
                    .with_context(|| format!("resource {:?} instance {name:?}", resource.id))?;
            }
            for (name, deployment) in &resource.deployments {
                validate_profile_name(&resource.id, "deployment", name)?;
                validate_deployment(deployment)
                    .with_context(|| format!("resource {:?} deployment {name:?}", resource.id))?;
            }
            if resource.nixbot_deploy && self.nixbot_deploy.is_none() {
                bail!(
                    "resource {:?} enables Nixbot deployment without a controller policy",
                    resource.id
                );
            }
        }
        Ok(())
    }
}

impl ResourceDefinition {
    /// Return one normalized representation while preserving `data_paths` as
    /// the backwards-compatible zero-exclude shorthand.
    pub fn effective_data_roots(&self) -> Vec<DataRoot> {
        let mut roots = self.data_roots.clone();
        roots.extend(self.data_paths.iter().map(|path| DataRoot {
            name: format!("path-{}", digest_bytes(path.as_os_str().as_encoded_bytes())),
            path: path.clone(),
            excludes: Vec::new(),
        }));
        roots
    }
}

pub fn validate_data_root(root: &DataRoot) -> Result<()> {
    if root.name.trim().is_empty()
        || root.name.contains('\0')
        || !root
            .name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    {
        bail!("data-root name {:?} is invalid", root.name);
    }
    if !root.path.is_absolute() || root.path == Path::new("/") {
        bail!(
            "data-root path must be absolute and cannot be root: {}",
            root.path.display()
        );
    }
    let mut excludes = HashSet::new();
    for exclude in &root.excludes {
        if exclude.as_os_str().is_empty()
            || exclude.is_absolute()
            || exclude == Path::new(".")
            || exclude
                .components()
                .any(|part| !matches!(part, std::path::Component::Normal(_)))
        {
            bail!(
                "data-root exclude must be a normalized non-empty relative path: {}",
                exclude.display()
            );
        }
        if !excludes.insert(exclude) {
            bail!("duplicate data-root exclude: {}", exclude.display());
        }
    }
    Ok(())
}

fn validate_declared_service_target(service: &ServiceTarget) -> Result<()> {
    service.validate()?;
    if service.scope == ServiceScope::User && service.user.is_none() {
        bail!("a declared user-scoped service must name its user-manager owner");
    }
    Ok(())
}

impl BrokerTransferPolicy {
    fn validate(&self) -> Result<()> {
        for (label, path) in [
            ("identity", &self.identity_file),
            ("SSH", &self.ssh_program),
            ("ssh-agent", &self.ssh_agent_program),
            ("ssh-add", &self.ssh_add_program),
        ] {
            if !path.is_absolute() {
                bail!("broker transfer {label} path must be absolute");
            }
        }
        if self.ssh_args.iter().any(|argument| argument.contains('\0')) {
            bail!("broker transfer SSH argv cannot contain NUL");
        }
        Ok(())
    }
}

fn default_backup_root() -> PathBuf {
    PathBuf::from("/var/lib/abird-host-agent/backups")
}

fn default_rsync_program() -> PathBuf {
    PathBuf::from("/run/current-system/sw/bin/rsync")
}

fn default_tar_program() -> PathBuf {
    PathBuf::from("/run/current-system/sw/bin/tar")
}

fn validate_profile_name(resource: &str, kind: &str, name: &str) -> Result<()> {
    if name.trim().is_empty() || name.contains('\0') {
        bail!("resource {resource:?} has an invalid {kind} profile name");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    #[test]
    fn loads_declared_resource() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("resources.json");
        fs::write(
            &path,
            r#"{
              "schema_version": 1,
              "resources": [{
                "id": "service:zulip",
                "services": [{"scope":"system","unit":"zulip.service"}],
                "data_paths": ["/var/lib/zulip"],
                "operations": {
                  "seed": {"argv":["/run/current-system/sw/bin/rsync","--archive"]}
                }
              }]
            }"#,
        )
        .unwrap();

        let manifest = ResourceManifest::load(&path).unwrap();
        let resource = manifest.resource("service:zulip").unwrap();
        assert_eq!(resource.services, [ServiceTarget::system("zulip.service")]);
        assert_eq!(resource.data_paths, [PathBuf::from("/var/lib/zulip")]);
        assert_eq!(resource.operations["seed"].argv[1], "--archive");
    }

    #[test]
    fn rejects_unsafe_data_paths() {
        let manifest = ResourceManifest {
            schema_version: 1,
            broker_transfer: None,
            nixbot_deploy: None,
            backup_root: default_backup_root(),
            rsync_program: default_rsync_program(),
            tar_program: default_tar_program(),
            resources: vec![ResourceDefinition {
                id: "service:zulip".to_owned(),
                services: Vec::new(),
                data_paths: vec![PathBuf::from("relative")],
                data_roots: Vec::new(),
                backup_consistency: BackupConsistency::Quiesced,
                operations: BTreeMap::new(),
                readiness: Vec::new(),
                transfers: BTreeMap::new(),
                file_states: BTreeMap::new(),
                instances: BTreeMap::new(),
                deployments: BTreeMap::new(),
                nixbot_deploy: false,
            }],
        };
        assert!(
            manifest
                .validate()
                .unwrap_err()
                .to_string()
                .contains("absolute")
        );
        let mut root = manifest;
        root.resources[0].data_paths = vec![PathBuf::from("/")];
        assert!(
            root.validate()
                .unwrap_err()
                .to_string()
                .contains("cannot be root")
        );
    }

    #[test]
    fn declared_user_services_require_an_owner() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("resources.json");
        fs::write(
            &path,
            r#"{
              "schema_version": 1,
              "resources": [{
                "id": "service:worker",
                "services": [{"scope":"user","unit":"worker.service"}]
              }]
            }"#,
        )
        .unwrap();

        let error = ResourceManifest::load(&path).unwrap_err();
        assert!(format!("{error:#}").contains("must name its user-manager owner"));
    }
}
