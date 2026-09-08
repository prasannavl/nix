//! Pure Terraform/OpenTofu workflow planning.
//!
//! Runtime adapters are responsible for filesystem discovery, Git queries,
//! secret materialization, and process execution. This module accepts those
//! observations as typed inputs and produces deterministic decisions and
//! command specifications without reading files or environment variables.

use std::collections::BTreeSet;
use std::error::Error;
use std::fmt;
use std::path::{Path, PathBuf};

const CONFIGURED_PROJECTS: &[(&str, TerraformPhase)] = &[
    ("cloudflare-dns", TerraformPhase::Dns),
    ("cloudflare-platform", TerraformPhase::Platform),
    ("cloudflare-apps", TerraformPhase::Apps),
];

const R2_SECRET_PATHS: &[(&str, &str)] = &[
    (
        "R2_ACCOUNT_ID",
        "data/secrets/globals/cloudflare/r2-account-id.key.age",
    ),
    (
        "R2_STATE_BUCKET",
        "data/secrets/globals/cloudflare/r2-state-bucket.key.age",
    ),
    (
        "R2_ACCESS_KEY_ID",
        "data/secrets/globals/cloudflare/r2-access-key-id.key.age",
    ),
    (
        "R2_SECRET_ACCESS_KEY",
        "data/secrets/globals/cloudflare/r2-secret-access-key.key.age",
    ),
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerraformPhase {
    Dns,
    Platform,
    Apps,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TerraformAction {
    Tf,
    TfDns,
    TfPlatform,
    TfApps,
    TfProject(String),
    Tofu(Vec<String>),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectRun {
    pub name: String,
    pub phase: TerraformPhase,
    pub directory: PathBuf,
}

/// Expand a Terraform action into its configured sequential project order.
/// `work_dir_override` models `NIXBOT_TF_DIR`: it contributes only to phases
/// matching the directory name's suffix and bypasses the configured list.
pub fn projects_for_action(
    action: &TerraformAction,
    work_dir_override: Option<&Path>,
) -> Result<Vec<ProjectRun>, TerraformError> {
    let phases: &[TerraformPhase] = match action {
        TerraformAction::Tf => &[
            TerraformPhase::Dns,
            TerraformPhase::Platform,
            TerraformPhase::Apps,
        ],
        TerraformAction::TfDns => &[TerraformPhase::Dns],
        TerraformAction::TfPlatform => &[TerraformPhase::Platform],
        TerraformAction::TfApps => &[TerraformPhase::Apps],
        TerraformAction::TfProject(project) => {
            let Some((_, phase)) = CONFIGURED_PROJECTS
                .iter()
                .find(|(configured, _)| configured == project)
            else {
                return Err(TerraformError::UnconfiguredProject(project.clone()));
            };
            return Ok(vec![ProjectRun {
                name: project.clone(),
                phase: *phase,
                directory: PathBuf::from("tf").join(project),
            }]);
        }
        TerraformAction::Tofu(_) => return Ok(Vec::new()),
    };

    let mut projects = Vec::new();
    for phase in phases {
        if let Some(directory) = work_dir_override {
            let name = directory
                .file_name()
                .and_then(|name| name.to_str())
                .ok_or_else(|| TerraformError::InvalidProjectDirectory(directory.to_path_buf()))?;
            if project_phase(name) == Some(*phase) {
                projects.push(ProjectRun {
                    name: name.to_owned(),
                    phase: *phase,
                    directory: PathBuf::from("tf").join(name),
                });
            }
            continue;
        }

        projects.extend(
            CONFIGURED_PROJECTS
                .iter()
                .filter(|(_, configured_phase)| configured_phase == phase)
                .map(|(name, configured_phase)| ProjectRun {
                    name: (*name).to_owned(),
                    phase: *configured_phase,
                    directory: PathBuf::from("tf").join(name),
                }),
        );
    }
    Ok(projects)
}

fn project_phase(name: &str) -> Option<TerraformPhase> {
    match name.rsplit_once('-').map(|(_, suffix)| suffix) {
        Some("dns") => Some(TerraformPhase::Dns),
        Some("platform") => Some(TerraformPhase::Platform),
        Some("apps") => Some(TerraformPhase::Apps),
        _ => None,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BackendKind {
    R2,
    Gcs,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectContext {
    pub directory: PathBuf,
    pub name: String,
    pub provider: String,
    pub backend: BackendKind,
}

/// Resolve the repository project naming contract `tf/<provider>-<name>`.
pub fn project_context(directory: &Path) -> Result<ProjectContext, TerraformError> {
    let name = directory
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| name.contains('-'))
        .ok_or_else(|| TerraformError::InvalidProjectDirectory(directory.to_path_buf()))?;
    if directory
        .parent()
        .and_then(Path::file_name)
        .and_then(|name| name.to_str())
        != Some("tf")
    {
        return Err(TerraformError::InvalidProjectDirectory(
            directory.to_path_buf(),
        ));
    }

    let provider = name
        .rsplit_once('-')
        .map(|(provider, _)| provider)
        .unwrap_or_default();
    let backend = if name == "gcp-bootstrap" || provider == "cloudflare" {
        BackendKind::R2
    } else if provider == "gcp" {
        BackendKind::Gcs
    } else {
        return Err(TerraformError::UnsupportedBackend(name.to_owned()));
    };

    Ok(ProjectContext {
        directory: directory.to_path_buf(),
        name: name.to_owned(),
        provider: provider.to_owned(),
        backend,
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SecretLoad {
    Value,
    Path,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EnvironmentRequirement {
    Required,
    RequiredFile,
    Optional,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EnvironmentDeclaration {
    pub name: String,
    pub secret_path: Option<PathBuf>,
    pub load: Option<SecretLoad>,
    pub requirement: EnvironmentRequirement,
}

impl EnvironmentDeclaration {
    fn required_secret(name: &str, path: &str, load: SecretLoad) -> Self {
        Self {
            name: name.to_owned(),
            secret_path: Some(PathBuf::from(path)),
            load: Some(load),
            requirement: match load {
                SecretLoad::Value => EnvironmentRequirement::Required,
                SecretLoad::Path => EnvironmentRequirement::RequiredFile,
            },
        }
    }

    fn optional_secret(name: &str, path: &str, load: SecretLoad) -> Self {
        Self {
            name: name.to_owned(),
            secret_path: Some(PathBuf::from(path)),
            load: Some(load),
            requirement: EnvironmentRequirement::Optional,
        }
    }

    fn optional(name: &str) -> Self {
        Self {
            name: name.to_owned(),
            secret_path: None,
            load: None,
            requirement: EnvironmentRequirement::Optional,
        }
    }
}

/// Declare every environment input and encrypted source used by a project.
/// Values are intentionally absent: an effect adapter materializes them.
pub fn project_environment_contract(project: &ProjectContext) -> Vec<EnvironmentDeclaration> {
    let mut declarations = match project.backend {
        BackendKind::R2 => R2_SECRET_PATHS
            .iter()
            .map(|(name, path)| {
                EnvironmentDeclaration::required_secret(name, path, SecretLoad::Value)
            })
            .chain([EnvironmentDeclaration::optional("R2_STATE_KEY")])
            .collect::<Vec<_>>(),
        BackendKind::Gcs => vec![
            EnvironmentDeclaration::required_secret(
                "GCP_STATE_BUCKET",
                "data/secrets/globals/gcp/state-bucket.key.age",
                SecretLoad::Value,
            ),
            EnvironmentDeclaration::optional("GCP_STATE_PREFIX"),
            EnvironmentDeclaration::optional_secret(
                "GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT",
                "data/secrets/globals/gcp/backend-impersonate-service-account.key.age",
                SecretLoad::Value,
            ),
        ],
    };

    match project.provider.as_str() {
        "cloudflare" => declarations.push(EnvironmentDeclaration::required_secret(
            "CLOUDFLARE_API_TOKEN",
            "data/secrets/globals/cloudflare/api-token.key.age",
            SecretLoad::Value,
        )),
        "gcp" => declarations.push(EnvironmentDeclaration::required_secret(
            "GOOGLE_APPLICATION_CREDENTIALS",
            "data/secrets/globals/gcp/application-default-credentials.json.age",
            SecretLoad::Path,
        )),
        _ => {}
    }
    declarations
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BackendValues {
    pub r2_account_id: Option<String>,
    pub r2_state_bucket: Option<String>,
    pub r2_access_key_id: Option<String>,
    pub r2_secret_access_key: Option<String>,
    pub r2_state_key: Option<String>,
    pub gcp_state_bucket: Option<String>,
    pub gcp_state_prefix: Option<String>,
    pub gcp_backend_impersonate_service_account: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProcessArgument {
    pub value: String,
    pub sensitive: bool,
}

impl ProcessArgument {
    fn plain(value: impl Into<String>) -> Self {
        Self {
            value: value.into(),
            sensitive: false,
        }
    }

    fn sensitive(value: impl Into<String>) -> Self {
        Self {
            value: value.into(),
            sensitive: true,
        }
    }

    fn redacted(&self) -> String {
        if !self.sensitive {
            return self.value.clone();
        }
        self.value
            .rsplit_once('=')
            .map(|(prefix, _)| format!("{prefix}=<redacted>"))
            .unwrap_or_else(|| "<redacted>".to_owned())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProcessCommand {
    pub program: String,
    pub args: Vec<ProcessArgument>,
    pub current_dir: Option<PathBuf>,
}

impl ProcessCommand {
    fn new(
        program: impl Into<String>,
        args: impl IntoIterator<Item = ProcessArgument>,
        current_dir: impl Into<Option<PathBuf>>,
    ) -> Self {
        Self {
            program: program.into(),
            args: args.into_iter().collect(),
            current_dir: current_dir.into(),
        }
    }

    pub fn redacted_argv(&self) -> Vec<String> {
        self.args.iter().map(ProcessArgument::redacted).collect()
    }
}

fn required<'a>(value: &'a Option<String>, name: &'static str) -> Result<&'a str, TerraformError> {
    value
        .as_deref()
        .filter(|value| !value.is_empty())
        .ok_or(TerraformError::MissingEnvironment(name))
}

/// Build the backend arguments appended to `tofu init`.
pub fn backend_config_args(
    project: &ProjectContext,
    values: &BackendValues,
) -> Result<Vec<ProcessArgument>, TerraformError> {
    match project.backend {
        BackendKind::R2 => {
            let account = required(&values.r2_account_id, "R2_ACCOUNT_ID")?;
            let bucket = required(&values.r2_state_bucket, "R2_STATE_BUCKET")?;
            let access_key = required(&values.r2_access_key_id, "R2_ACCESS_KEY_ID")?;
            let secret_key = required(&values.r2_secret_access_key, "R2_SECRET_ACCESS_KEY")?;
            let state_key = values
                .r2_state_key
                .as_deref()
                .filter(|key| !key.is_empty())
                .map(ToOwned::to_owned)
                .unwrap_or_else(|| format!("{}/terraform.tfstate", project.name));
            Ok(vec![
                ProcessArgument::plain(format!("-backend-config=bucket={bucket}")),
                ProcessArgument::plain(format!("-backend-config=key={state_key}")),
                ProcessArgument::plain("-backend-config=region=auto"),
                ProcessArgument::plain(format!(
                    "-backend-config=endpoint=https://{account}.r2.cloudflarestorage.com"
                )),
                ProcessArgument::sensitive(format!("-backend-config=access_key={access_key}")),
                ProcessArgument::sensitive(format!("-backend-config=secret_key={secret_key}")),
                ProcessArgument::plain("-backend-config=skip_credentials_validation=true"),
                ProcessArgument::plain("-backend-config=skip_region_validation=true"),
                ProcessArgument::plain("-backend-config=skip_requesting_account_id=true"),
                ProcessArgument::plain("-backend-config=use_path_style=true"),
            ])
        }
        BackendKind::Gcs => {
            let bucket = required(&values.gcp_state_bucket, "GCP_STATE_BUCKET")?;
            let prefix = values
                .gcp_state_prefix
                .as_deref()
                .filter(|prefix| !prefix.is_empty())
                .map(ToOwned::to_owned)
                .unwrap_or_else(|| format!("{}/terraform.tfstate", project.name));
            let mut args = vec![
                ProcessArgument::plain(format!("-backend-config=bucket={bucket}")),
                ProcessArgument::plain(format!("-backend-config=prefix={prefix}")),
            ];
            if let Some(account) = values
                .gcp_backend_impersonate_service_account
                .as_deref()
                .filter(|account| !account.is_empty())
            {
                args.push(ProcessArgument::plain(format!(
                    "-backend-config=impersonate_service_account={account}"
                )));
            }
            Ok(args)
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DiffObservation {
    Available(Vec<PathBuf>),
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ChangeGateInput {
    pub if_changed: bool,
    pub target_ref: String,
    pub target_available: bool,
    pub base_ref: Option<String>,
    pub diff: DiffObservation,
    pub worktree_paths: Vec<PathBuf>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ChangeDecision {
    RunForce,
    RunTargetUnavailable { target_ref: String },
    RunBaseUnavailable { target_ref: String },
    RunDiffFailed { range: String },
    RunDiffChanged { path: PathBuf },
    RunWorktreeChanged { path: PathBuf },
    SkipUnchanged,
}

fn path_in_scope(path: &str, scope: &str) -> bool {
    path == scope
        || path
            .strip_prefix(scope)
            .is_some_and(|rest| rest.starts_with('/'))
}

/// Match the exact project change scopes used by the shell implementation.
pub fn is_candidate_path(phase: TerraformPhase, project_name: &str, path: &Path) -> bool {
    let Some(path) = path.to_str() else {
        return false;
    };
    let Some((provider, _)) = project_name.rsplit_once('-') else {
        return false;
    };

    path_in_scope(path, &format!("tf/{project_name}"))
        || path_in_scope(path, &format!("tf/modules/{provider}"))
        || path_in_scope(path, &format!("data/secrets/globals/{provider}"))
        || path == format!("data/secrets/globals/tf/{provider}.tfvars.age")
        || path_in_scope(path, &format!("data/secrets/globals/tf/{provider}"))
        || path == format!("data/secrets/globals/tf/{project_name}.tfvars.age")
        || path_in_scope(path, &format!("data/secrets/globals/tf/{project_name}"))
        || matches!(
            path,
            "data/secrets/globals/cloudflare/r2-account-id.key.age"
                | "data/secrets/globals/cloudflare/r2-state-bucket.key.age"
                | "data/secrets/globals/cloudflare/r2-access-key-id.key.age"
                | "data/secrets/globals/cloudflare/r2-secret-access-key.key.age"
        )
        || (phase == TerraformPhase::Apps && path_in_scope(path, "services"))
}

/// Evaluate pre-collected Git observations. Detection errors deliberately run
/// Terraform, matching the legacy fail-open safety policy.
pub fn evaluate_change_gate(
    phase: TerraformPhase,
    project_name: &str,
    input: &ChangeGateInput,
) -> ChangeDecision {
    if !input.if_changed {
        return ChangeDecision::RunForce;
    }
    if !input.target_available {
        return ChangeDecision::RunTargetUnavailable {
            target_ref: input.target_ref.clone(),
        };
    }
    let Some(base_ref) = &input.base_ref else {
        return ChangeDecision::RunBaseUnavailable {
            target_ref: input.target_ref.clone(),
        };
    };
    let paths = match &input.diff {
        DiffObservation::Available(paths) => paths,
        DiffObservation::Failed => {
            return ChangeDecision::RunDiffFailed {
                range: format!("{base_ref}..{}", input.target_ref),
            };
        }
    };
    if let Some(path) = paths
        .iter()
        .find(|path| is_candidate_path(phase, project_name, path))
    {
        return ChangeDecision::RunDiffChanged { path: path.clone() };
    }
    if let Some(path) = input
        .worktree_paths
        .iter()
        .find(|path| is_candidate_path(phase, project_name, path))
    {
        return ChangeDecision::RunWorktreeChanged { path: path.clone() };
    }
    ChangeDecision::SkipUnchanged
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AutomaticTfvars {
    /// Encrypted declarations found under the provider and project scopes.
    pub discovered_secret_paths: Vec<PathBuf>,
    /// Successfully materialized plaintext files in the runtime directory.
    pub materialized_var_files: Vec<PathBuf>,
}

/// Filter a filesystem listing to the provider/project tfvar conventions.
pub fn select_tfvar_secret_paths(
    project_name: &str,
    paths: impl IntoIterator<Item = PathBuf>,
) -> Vec<PathBuf> {
    let Some((provider, _)) = project_name.rsplit_once('-') else {
        return Vec::new();
    };
    let provider_file = format!("data/secrets/globals/tf/{provider}.tfvars.age");
    let provider_dir = format!("data/secrets/globals/tf/{provider}");
    let project_file = format!("data/secrets/globals/tf/{project_name}.tfvars.age");
    let project_dir = format!("data/secrets/globals/tf/{project_name}");

    paths
        .into_iter()
        .filter(|path| {
            let Some(path) = path.to_str() else {
                return false;
            };
            path.ends_with(".tfvars.age")
                && (path == provider_file
                    || path_in_scope(path, &provider_dir)
                    || path == project_file
                    || path_in_scope(path, &project_dir))
        })
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

fn tofu_subcommand(args: &[String]) -> Option<&str> {
    let mut index = 0;
    while index < args.len() {
        let argument = args[index].as_str();
        match argument {
            "-chdir" => index += 2,
            value if value.starts_with("-chdir=") => index += 1,
            "-help" | "--help" | "-version" | "--version" => index += 1,
            value if value.starts_with('-') => index += 1,
            value => return Some(value),
        }
    }
    None
}

fn has_explicit_vars(args: &[String]) -> bool {
    args.iter().any(|argument| {
        matches!(argument.as_str(), "-var" | "-var-file")
            || argument.starts_with("-var=")
            || argument.starts_with("-var-file=")
    })
}

fn supports_var_files(subcommand: &str) -> bool {
    matches!(
        subcommand,
        "plan" | "apply" | "destroy" | "import" | "console"
    )
}

/// Add materialized `-var-file` flags immediately after the subcommand.
pub fn inject_automatic_tfvars(
    args: &[String],
    tfvars: &AutomaticTfvars,
    project_requires_secret_tfvars: bool,
) -> Result<Vec<String>, TerraformError> {
    let Some(subcommand) = tofu_subcommand(args) else {
        return Ok(args.to_vec());
    };
    if !supports_var_files(subcommand) || has_explicit_vars(args) {
        return Ok(args.to_vec());
    }
    if tfvars.discovered_secret_paths.is_empty()
        && project_requires_secret_tfvars
        && matches!(subcommand, "plan" | "apply" | "destroy")
    {
        return Err(TerraformError::MissingSecretTfvars {
            subcommand: subcommand.to_owned(),
        });
    }

    let materialized = tfvars
        .materialized_var_files
        .iter()
        .cloned()
        .collect::<BTreeSet<_>>();
    let mut result = Vec::with_capacity(args.len() + materialized.len());
    let mut inserted = false;
    for argument in args {
        result.push(argument.clone());
        if !inserted && argument == subcommand {
            result.extend(
                materialized
                    .iter()
                    .map(|path| format!("-var-file={}", path.display())),
            );
            inserted = true;
        }
    }
    Ok(result)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WrapperContext {
    pub directory: PathBuf,
    pub project: Option<ProjectContext>,
}

/// Enforce the wrapper's invocation boundary before runtime preparation.
pub fn validate_tofu_wrapper_invocation(
    args: &[String],
    ssh_original_command: Option<&str>,
) -> Result<(), TerraformError> {
    if args.is_empty() {
        return Err(TerraformError::MissingTofuArguments);
    }
    if ssh_original_command.is_some_and(|command| !command.is_empty()) {
        return Err(TerraformError::RemoteTofuUnsupported);
    }
    Ok(())
}

/// Resolve the first `-chdir` wrapper flag, falling back to the caller's
/// physical working directory.
pub fn resolve_wrapper_context(
    current_dir: &Path,
    args: &[String],
) -> Result<WrapperContext, TerraformError> {
    let mut selected = None;
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "-chdir" if index + 1 < args.len() => {
                selected = Some(PathBuf::from(&args[index + 1]));
                break;
            }
            argument if argument.starts_with("-chdir=") => {
                selected = Some(PathBuf::from(&argument["-chdir=".len()..]));
                break;
            }
            _ => index += 1,
        }
    }
    let mut directory = selected.unwrap_or_else(|| current_dir.to_path_buf());
    if directory.is_relative() {
        directory = current_dir.join(directory);
    }

    let is_repo_project = directory
        .parent()
        .and_then(Path::file_name)
        .and_then(|name| name.to_str())
        == Some("tf")
        && directory
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.contains('-'));
    let project = is_repo_project
        .then(|| project_context(&directory))
        .transpose()?;
    Ok(WrapperContext { directory, project })
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectPlanInput {
    pub repo_root: PathBuf,
    pub project: ProjectContext,
    pub backend_values: BackendValues,
    pub automatic_tfvars: AutomaticTfvars,
    pub project_requires_secret_tfvars: bool,
    pub dry_run: bool,
    pub plan_file: PathBuf,
    /// Present only when `pkgs/<project>/default.nix` exists.
    pub apps_package_default: Option<PathBuf>,
}

fn plain_args(args: impl IntoIterator<Item = String>) -> Vec<ProcessArgument> {
    args.into_iter().map(ProcessArgument::plain).collect()
}

fn tofu_command(args: Vec<ProcessArgument>, current_dir: &Path) -> ProcessCommand {
    ProcessCommand::new("tofu", args, Some(current_dir.to_path_buf()))
}

fn apps_preparation_command(
    project: &ProjectContext,
    package_default: Option<&Path>,
    current_dir: &Path,
) -> Option<ProcessCommand> {
    if !project.name.ends_with("-apps") {
        return None;
    }
    let package_default = package_default?;
    Some(ProcessCommand::new(
        "nix",
        plain_args([
            "build".to_owned(),
            "--file".to_owned(),
            package_default.display().to_string(),
            "--no-link".to_owned(),
        ]),
        Some(current_dir.to_path_buf()),
    ))
}

/// Plan the commands for a managed Terraform project. Apply always consumes
/// the saved plan and therefore intentionally receives no tfvar flags.
pub fn plan_project_commands(
    input: &ProjectPlanInput,
) -> Result<Vec<ProcessCommand>, TerraformError> {
    let chdir = format!("-chdir={}", input.project.directory.display());
    let mut commands = Vec::new();
    if let Some(command) = apps_preparation_command(
        &input.project,
        input.apps_package_default.as_deref(),
        &input.repo_root,
    ) {
        commands.push(command);
    }

    let mut init_args = plain_args([
        chdir.clone(),
        "init".to_owned(),
        "-lockfile=readonly".to_owned(),
    ]);
    init_args.extend(backend_config_args(&input.project, &input.backend_values)?);
    commands.push(tofu_command(init_args, &input.repo_root));

    let mut plan_args = vec![chdir.clone(), "plan".to_owned(), "-input=false".to_owned()];
    if !input.dry_run {
        plan_args.push(format!("-out={}", input.plan_file.display()));
    }
    let plan_args = inject_automatic_tfvars(
        &plan_args,
        &input.automatic_tfvars,
        input.project_requires_secret_tfvars,
    )?;
    commands.push(tofu_command(plain_args(plan_args), &input.repo_root));

    if !input.dry_run {
        commands.push(tofu_command(
            plain_args([
                chdir,
                "apply".to_owned(),
                "-input=false".to_owned(),
                "-auto-approve".to_owned(),
                input.plan_file.display().to_string(),
            ]),
            &input.repo_root,
        ));
    }
    Ok(commands)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TofuWrapperPlan {
    pub context: WrapperContext,
    pub environment_contract: Vec<EnvironmentDeclaration>,
    pub preparation_commands: Vec<ProcessCommand>,
    pub command: ProcessCommand,
}

fn has_explicit_backend_config(args: &[String]) -> bool {
    args.iter()
        .any(|argument| argument == "-backend-config" || argument.starts_with("-backend-config="))
}

/// Plan the local `tofu` wrapper command after its filesystem observations and
/// backend values have been collected by the runtime layer.
pub fn plan_tofu_wrapper_command(
    current_dir: &Path,
    args: &[String],
    backend_values: &BackendValues,
    tfvars: &AutomaticTfvars,
    project_requires_secret_tfvars: bool,
    apps_package_default: Option<&Path>,
) -> Result<TofuWrapperPlan, TerraformError> {
    validate_tofu_wrapper_invocation(args, None)?;
    let context = resolve_wrapper_context(current_dir, args)?;
    let mut environment_contract = Vec::new();
    let mut preparation_commands = Vec::new();
    let mut command_args = plain_args(args.iter().cloned());

    if let Some(project) = &context.project {
        environment_contract = project_environment_contract(project);
        if let Some(command) = apps_preparation_command(project, apps_package_default, current_dir)
        {
            preparation_commands.push(command);
        }

        // Preparation validates the backend environment for every recognized
        // project, even when the wrapper subcommand is not `init`.
        let backend_args = backend_config_args(project, backend_values)?;
        if tofu_subcommand(args) == Some("init") && !has_explicit_backend_config(args) {
            command_args.extend(backend_args);
        } else {
            command_args = plain_args(inject_automatic_tfvars(
                args,
                tfvars,
                project_requires_secret_tfvars,
            )?);
        }
    }

    Ok(TofuWrapperPlan {
        context,
        environment_contract,
        preparation_commands,
        command: tofu_command(command_args, current_dir),
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TerraformError {
    UnconfiguredProject(String),
    InvalidProjectDirectory(PathBuf),
    UnsupportedBackend(String),
    MissingEnvironment(&'static str),
    MissingSecretTfvars { subcommand: String },
    MissingTofuArguments,
    RemoteTofuUnsupported,
}

impl fmt::Display for TerraformError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnconfiguredProject(project) => {
                write!(formatter, "unconfigured Terraform project: {project}")
            }
            Self::InvalidProjectDirectory(directory) => {
                write!(
                    formatter,
                    "invalid Terraform project directory: {}",
                    directory.display()
                )
            }
            Self::UnsupportedBackend(project) => {
                write!(
                    formatter,
                    "unsupported Terraform backend for project: {project}"
                )
            }
            Self::MissingEnvironment(name) => {
                write!(formatter, "missing required environment variable: {name}")
            }
            Self::MissingSecretTfvars { subcommand } => {
                write!(
                    formatter,
                    "refusing Terraform {subcommand}: no encrypted tfvars were discovered"
                )
            }
            Self::MissingTofuArguments => formatter.write_str("tofu arguments are required"),
            Self::RemoteTofuUnsupported => formatter.write_str("the tofu wrapper is local-only"),
        }
    }
}

impl Error for TerraformError {}
