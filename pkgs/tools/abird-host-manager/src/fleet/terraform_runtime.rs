//! Effect adapters for the pure Terraform/OpenTofu planning contracts.
//!
//! Repository paths, environment values, decrypted files, process execution,
//! and Git observations enter through explicit boundaries. Command diagnostics
//! contain redacted arguments and output only.

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::{Builder as TempBuilder, TempDir};

use super::terraform::{
    AutomaticTfvars, BackendValues, ChangeDecision, ChangeGateInput, DiffObservation,
    EnvironmentDeclaration, EnvironmentRequirement, ProcessCommand, ProjectContext,
    ProjectPlanInput, ProjectRun, SecretLoad, TerraformAction, TerraformPhase, backend_config_args,
    evaluate_change_gate, plan_project_commands, project_context, projects_for_action,
};

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RuntimePrograms {
    programs: BTreeMap<String, PathBuf>,
}

impl RuntimePrograms {
    pub fn from_pairs<I, N, P>(pairs: I) -> Self
    where
        I: IntoIterator<Item = (N, P)>,
        N: Into<String>,
        P: Into<PathBuf>,
    {
        Self {
            programs: pairs
                .into_iter()
                .map(|(name, path)| (name.into(), path.into()))
                .collect(),
        }
    }

    fn resolve(&self, name: &str) -> Option<&Path> {
        self.programs.get(name).map(PathBuf::as_path)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CopySafeOutput {
    pub stdout: String,
    pub stderr: String,
}

impl CopySafeOutput {
    pub fn new(
        stdout: impl Into<String>,
        stderr: impl Into<String>,
        replacements: &[(String, String)],
    ) -> Self {
        let mut replacements = replacements.to_vec();
        replacements.sort_by_key(|replacement| std::cmp::Reverse(replacement.0.len()));
        let redact = |mut text: String| {
            for (sensitive, replacement) in &replacements {
                if !sensitive.is_empty() {
                    text = text.replace(sensitive, replacement);
                }
            }
            text
        };
        Self {
            stdout: redact(stdout.into()),
            stderr: redact(stderr.into()),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandOutput {
    pub status: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub redacted_argv: Vec<String>,
}

impl CommandOutput {
    pub fn success(&self) -> bool {
        self.status == Some(0)
    }
}

pub trait CommandExecutor {
    fn execute(
        &mut self,
        repo_root: &Path,
        command: &ProcessCommand,
        environment: &BTreeMap<String, String>,
    ) -> Result<CommandOutput, RuntimeError>;
}

#[derive(Clone, Debug)]
pub struct SystemCommandExecutor {
    programs: RuntimePrograms,
}

impl SystemCommandExecutor {
    pub fn new(programs: RuntimePrograms) -> Self {
        Self { programs }
    }
}

fn sensitive_replacements(command: &ProcessCommand) -> Vec<(String, String)> {
    let redacted = command.redacted_argv();
    let mut replacements = Vec::new();
    for (argument, safe) in command.args.iter().zip(redacted) {
        if !argument.sensitive {
            continue;
        }
        replacements.push((argument.value.clone(), safe));
        if let Some((_, value)) = argument.value.rsplit_once('=') {
            replacements.push((value.to_owned(), "<redacted>".to_owned()));
        }
    }
    replacements
}

fn secret_environment_replacements(
    environment: &BTreeMap<String, String>,
) -> Vec<(String, String)> {
    environment
        .iter()
        .filter(|(name, value)| {
            !value.is_empty()
                && (name.contains("SECRET")
                    || name.contains("TOKEN")
                    || name.contains("PASSWORD")
                    || name.contains("CREDENTIAL")
                    || name.ends_with("_KEY")
                    || name.ends_with("_KEY_ID")
                    || name.starts_with("TF_VAR_"))
        })
        .map(|(_, value)| (value.clone(), "<redacted>".to_owned()))
        .collect()
}

impl CommandExecutor for SystemCommandExecutor {
    fn execute(
        &mut self,
        repo_root: &Path,
        command: &ProcessCommand,
        environment: &BTreeMap<String, String>,
    ) -> Result<CommandOutput, RuntimeError> {
        if command.current_dir.as_deref() != Some(repo_root) {
            return Err(RuntimeError::RepositoryCurrentDirMismatch {
                expected: repo_root.to_path_buf(),
                command: command.current_dir.clone(),
            });
        }
        let program = self
            .programs
            .resolve(&command.program)
            .ok_or_else(|| RuntimeError::UnknownProgram(command.program.clone()))?;
        let output = Command::new(program)
            .args(command.args.iter().map(|argument| &argument.value))
            .current_dir(repo_root)
            .envs(environment)
            .output()
            .map_err(|error| RuntimeError::Spawn {
                program: program.to_path_buf(),
                message: error.to_string(),
            })?;
        let mut replacements = sensitive_replacements(command);
        replacements.extend(secret_environment_replacements(environment));
        let safe = CopySafeOutput::new(
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
            &replacements,
        );
        Ok(CommandOutput {
            status: output.status.code(),
            stdout: safe.stdout,
            stderr: safe.stderr,
            redacted_argv: command.redacted_argv(),
        })
    }
}

pub trait Decryptor {
    fn decrypt(&mut self, source: &Path, destination: &Path) -> Result<(), String>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgeCommandDecryptor {
    pub program: PathBuf,
    pub identities: Vec<PathBuf>,
}

impl Decryptor for AgeCommandDecryptor {
    fn decrypt(&mut self, source: &Path, destination: &Path) -> Result<(), String> {
        let identities = self
            .identities
            .iter()
            .filter(|identity| identity.is_file())
            .collect::<Vec<_>>();
        if identities.is_empty() {
            return Err("no readable age identities".to_owned());
        }
        for identity in identities {
            let _ = fs::remove_file(destination);
            let status = Command::new(&self.program)
                .arg("--decrypt")
                .arg("-i")
                .arg(identity)
                .arg("-o")
                .arg(destination)
                .arg(source)
                .status()
                .map_err(|error| format!("cannot execute age: {error}"))?;
            if status.success() {
                return Ok(());
            }
        }
        let _ = fs::remove_file(destination);
        Err("unable to decrypt with available age identities".to_owned())
    }
}

pub struct SecureMaterializer<D> {
    directory: TempDir,
    decryptor: D,
    next_file: u64,
}

impl<D: Decryptor> SecureMaterializer<D> {
    pub fn new(parent: &Path, decryptor: D) -> Result<Self, RuntimeError> {
        let directory = TempBuilder::new()
            .prefix("abird-tf-secrets-")
            .tempdir_in(parent)
            .map_err(|error| RuntimeError::TemporaryDirectory(error.to_string()))?;
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).map_err(
            |error| RuntimeError::TemporaryDirectory(format!("set private mode: {error}")),
        )?;
        Ok(Self {
            directory,
            decryptor,
            next_file: 0,
        })
    }

    pub fn root(&self) -> &Path {
        self.directory.path()
    }

    pub fn materialize_file(
        &mut self,
        source: &Path,
        label: &str,
    ) -> Result<PathBuf, RuntimeError> {
        if !source.is_file() {
            return Err(RuntimeError::SecretSourceMissing(source.to_path_buf()));
        }
        self.next_file = self
            .next_file
            .checked_add(1)
            .ok_or(RuntimeError::MaterializationCounterOverflow)?;
        let safe_label = label
            .chars()
            .map(|character| {
                if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-') {
                    character
                } else {
                    '_'
                }
            })
            .collect::<String>();
        let destination = self
            .directory
            .path()
            .join(format!("{safe_label}-{:06}", self.next_file));
        if let Err(message) = self.decryptor.decrypt(source, &destination) {
            let _ = fs::remove_file(&destination);
            return Err(RuntimeError::Decrypt {
                source: source.to_path_buf(),
                message,
            });
        }
        if !destination.is_file() {
            return Err(RuntimeError::Decrypt {
                source: source.to_path_buf(),
                message: "decryptor did not create an output file".to_owned(),
            });
        }
        fs::set_permissions(&destination, fs::Permissions::from_mode(0o600)).map_err(|error| {
            RuntimeError::SecureMode {
                path: destination.clone(),
                message: error.to_string(),
            }
        })?;
        Ok(destination)
    }
}

pub fn resolve_environment<D: Decryptor>(
    declarations: &[EnvironmentDeclaration],
    inherited: &BTreeMap<String, String>,
    repo_root: &Path,
    materializer: &mut SecureMaterializer<D>,
) -> Result<BTreeMap<String, String>, RuntimeError> {
    let mut resolved = inherited.clone();
    for declaration in declarations {
        if resolved
            .get(&declaration.name)
            .is_some_and(|value| !value.is_empty())
        {
            continue;
        }
        resolved.remove(&declaration.name);
        let Some(secret_path) = &declaration.secret_path else {
            if declaration.requirement != EnvironmentRequirement::Optional {
                return Err(RuntimeError::MissingEnvironment(declaration.name.clone()));
            }
            continue;
        };
        if secret_path.is_absolute()
            || secret_path
                .components()
                .any(|component| matches!(component, std::path::Component::ParentDir))
        {
            return Err(RuntimeError::SecretOutsideRepository(secret_path.clone()));
        }
        let source = repo_root.join(secret_path);
        if !source.is_file() {
            if declaration.requirement == EnvironmentRequirement::Optional {
                continue;
            }
            return Err(RuntimeError::SecretSourceMissing(source));
        }
        let materialized = materializer.materialize_file(&source, &declaration.name)?;
        let value = match declaration.load {
            Some(SecretLoad::Value) => fs::read_to_string(&materialized)
                .map_err(|error| RuntimeError::ReadMaterialized {
                    path: materialized.clone(),
                    message: error.to_string(),
                })?
                .trim_end_matches('\n')
                .to_owned(),
            Some(SecretLoad::Path) => materialized.display().to_string(),
            None => String::new(),
        };
        if value.is_empty() {
            if declaration.requirement == EnvironmentRequirement::Optional {
                continue;
            }
            return Err(RuntimeError::MissingEnvironment(declaration.name.clone()));
        }
        resolved.insert(declaration.name.clone(), value);
    }
    Ok(resolved)
}

fn env_value<'a>(environment: &'a BTreeMap<String, String>, name: &str) -> Option<&'a str> {
    environment
        .get(name)
        .map(String::as_str)
        .filter(|value| !value.is_empty())
}

/// Validate backend and provider inputs, returning the typed backend subset
/// used by the pure command planner.
pub fn validate_project_environment(
    project: &ProjectContext,
    environment: &BTreeMap<String, String>,
) -> Result<BackendValues, RuntimeError> {
    let values = BackendValues {
        r2_account_id: env_value(environment, "R2_ACCOUNT_ID").map(ToOwned::to_owned),
        r2_state_bucket: env_value(environment, "R2_STATE_BUCKET").map(ToOwned::to_owned),
        r2_access_key_id: env_value(environment, "R2_ACCESS_KEY_ID").map(ToOwned::to_owned),
        r2_secret_access_key: env_value(environment, "R2_SECRET_ACCESS_KEY").map(ToOwned::to_owned),
        r2_state_key: env_value(environment, "R2_STATE_KEY").map(ToOwned::to_owned),
        gcp_state_bucket: env_value(environment, "GCP_STATE_BUCKET").map(ToOwned::to_owned),
        gcp_state_prefix: env_value(environment, "GCP_STATE_PREFIX").map(ToOwned::to_owned),
        gcp_backend_impersonate_service_account: env_value(
            environment,
            "GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT",
        )
        .map(ToOwned::to_owned),
    };
    backend_config_args(project, &values).map_err(|error| match error {
        super::terraform::TerraformError::MissingEnvironment(name) => {
            RuntimeError::MissingEnvironment(name.to_owned())
        }
        other => RuntimeError::Plan(other.to_string()),
    })?;

    match project.provider.as_str() {
        "cloudflare" if env_value(environment, "CLOUDFLARE_API_TOKEN").is_none() => {
            return Err(RuntimeError::MissingEnvironment(
                "CLOUDFLARE_API_TOKEN".to_owned(),
            ));
        }
        "cloudflare" => {}
        "gcp" => {
            let name = "GOOGLE_APPLICATION_CREDENTIALS";
            let path = env_value(environment, name)
                .ok_or_else(|| RuntimeError::MissingEnvironment(name.to_owned()))?;
            let path = PathBuf::from(path);
            if !path.is_file() {
                return Err(RuntimeError::EnvironmentFileMissing {
                    name: name.to_owned(),
                    path,
                });
            }
        }
        _ => {}
    }
    Ok(values)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiscoveredSecret {
    pub declaration: PathBuf,
    pub source: PathBuf,
}

fn collect_tfvars(
    repo_root: &Path,
    relative: &Path,
    recursive: bool,
    found: &mut BTreeMap<PathBuf, PathBuf>,
) -> Result<(), RuntimeError> {
    let absolute = repo_root.join(relative);
    if absolute.is_file() {
        if absolute
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with(".tfvars.age"))
        {
            found.insert(relative.to_path_buf(), absolute);
        }
        return Ok(());
    }
    if !recursive || !absolute.is_dir() {
        return Ok(());
    }
    let entries = fs::read_dir(&absolute).map_err(|error| RuntimeError::SecretDiscovery {
        path: absolute.clone(),
        message: error.to_string(),
    })?;
    for entry in entries {
        let entry = entry.map_err(|error| RuntimeError::SecretDiscovery {
            path: absolute.clone(),
            message: error.to_string(),
        })?;
        let name = entry.file_name();
        let child_relative = relative.join(name);
        let file_type = entry
            .file_type()
            .map_err(|error| RuntimeError::SecretDiscovery {
                path: entry.path(),
                message: error.to_string(),
            })?;
        if file_type.is_dir() {
            collect_tfvars(repo_root, &child_relative, true, found)?;
        } else if file_type.is_file()
            && entry
                .file_name()
                .to_str()
                .is_some_and(|name| name.ends_with(".tfvars.age"))
        {
            found.insert(child_relative, entry.path());
        }
    }
    Ok(())
}

/// Discover encrypted tfvars by name only under provider and project scopes.
pub fn discover_tfvar_secrets(
    repo_root: &Path,
    project_name: &str,
) -> Result<Vec<DiscoveredSecret>, RuntimeError> {
    let Some((provider, _)) = project_name.rsplit_once('-') else {
        return Err(RuntimeError::InvalidProjectName(project_name.to_owned()));
    };
    let mut found = BTreeMap::new();
    for (relative, recursive) in [
        (
            PathBuf::from(format!("data/secrets/globals/tf/{provider}.tfvars.age")),
            false,
        ),
        (
            PathBuf::from(format!("data/secrets/globals/tf/{provider}")),
            true,
        ),
        (
            PathBuf::from(format!("data/secrets/globals/tf/{project_name}.tfvars.age")),
            false,
        ),
        (
            PathBuf::from(format!("data/secrets/globals/tf/{project_name}")),
            true,
        ),
    ] {
        collect_tfvars(repo_root, &relative, recursive, &mut found)?;
    }
    Ok(found
        .into_iter()
        .map(|(declaration, source)| DiscoveredSecret {
            declaration,
            source,
        })
        .collect())
}

pub fn materialize_tfvars<D: Decryptor>(
    discovered: &[DiscoveredSecret],
    materializer: &mut SecureMaterializer<D>,
) -> Result<AutomaticTfvars, RuntimeError> {
    let mut declarations = Vec::with_capacity(discovered.len());
    let mut materialized = Vec::with_capacity(discovered.len());
    for secret in discovered {
        declarations.push(secret.declaration.clone());
        materialized.push(materializer.materialize_file(&secret.source, "tfvar")?);
    }
    Ok(AutomaticTfvars {
        discovered_secret_paths: declarations,
        materialized_var_files: materialized,
    })
}

pub trait ChangeGateSource {
    fn collect(
        &mut self,
        repo_root: &Path,
        phase: TerraformPhase,
        project: &str,
        if_changed: bool,
        target_ref: &str,
        preferred_base_ref: Option<&str>,
    ) -> ChangeGateInput;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SystemGitChangeSource {
    pub git_program: PathBuf,
}

impl SystemGitChangeSource {
    fn output(&self, repo_root: &Path, args: &[&str]) -> io::Result<std::process::Output> {
        Command::new(&self.git_program)
            .args(args)
            .current_dir(repo_root)
            .output()
    }

    fn verify(&self, repo_root: &Path, reference: &str) -> Option<String> {
        let output = self
            .output(repo_root, &["rev-parse", "--verify", reference])
            .ok()?;
        output
            .status
            .success()
            .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
    }
}

fn lines(output: &[u8]) -> Vec<PathBuf> {
    String::from_utf8_lossy(output)
        .lines()
        .filter(|line| !line.is_empty())
        .map(PathBuf::from)
        .collect()
}

fn porcelain_paths(output: &[u8]) -> Vec<PathBuf> {
    String::from_utf8_lossy(output)
        .lines()
        .filter_map(|line| line.get(3..))
        .map(|path| path.rsplit_once(" -> ").map_or(path, |(_, new)| new))
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .collect()
}

impl ChangeGateSource for SystemGitChangeSource {
    fn collect(
        &mut self,
        repo_root: &Path,
        _phase: TerraformPhase,
        _project: &str,
        if_changed: bool,
        target_ref: &str,
        preferred_base_ref: Option<&str>,
    ) -> ChangeGateInput {
        let Some(target_commit) = self.verify(repo_root, target_ref) else {
            return ChangeGateInput {
                if_changed,
                target_ref: target_ref.to_owned(),
                target_available: false,
                base_ref: None,
                diff: DiffObservation::Available(Vec::new()),
                worktree_paths: Vec::new(),
            };
        };
        let preferred = preferred_base_ref.and_then(|reference| {
            self.verify(repo_root, reference)
                .filter(|commit| commit != &target_commit)
                .map(|_| reference.to_owned())
        });
        let base_ref = preferred.or_else(|| {
            let parent = format!("{target_ref}^1");
            self.verify(repo_root, &parent).map(|_| parent)
        });

        let diff = base_ref.as_deref().map_or_else(
            || DiffObservation::Available(Vec::new()),
            |base| match self.output(repo_root, &["diff", "--name-only", base, target_ref, "--"]) {
                Ok(output) if output.status.success() => {
                    DiffObservation::Available(lines(&output.stdout))
                }
                _ => DiffObservation::Failed,
            },
        );
        let worktree_paths = self
            .output(
                repo_root,
                &["status", "--porcelain=v1", "--untracked-files=all"],
            )
            .ok()
            .map(|output| porcelain_paths(&output.stdout))
            .unwrap_or_default();
        ChangeGateInput {
            if_changed,
            target_ref: target_ref.to_owned(),
            target_available: true,
            base_ref,
            diff,
            worktree_paths,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectSelection {
    pub run: ProjectRun,
    pub decision: ChangeDecision,
}

pub fn select_projects_for_execution<S: ChangeGateSource>(
    action: &TerraformAction,
    work_dir_override: Option<&Path>,
    repo_root: &Path,
    if_changed: bool,
    target_ref: &str,
    preferred_base_ref: Option<&str>,
    changes: &mut S,
) -> Result<Vec<ProjectSelection>, RuntimeError> {
    let runs = projects_for_action(action, work_dir_override)
        .map_err(|error| RuntimeError::Plan(error.to_string()))?;
    let mut selections = Vec::with_capacity(runs.len());
    for mut run in runs {
        if run.directory.is_relative() {
            run.directory = repo_root.join(&run.directory);
        }
        if !run.directory.is_dir() {
            return Err(RuntimeError::ProjectDirectoryMissing(run.directory));
        }
        let mut observation = changes.collect(
            repo_root,
            run.phase,
            &run.name,
            if_changed,
            target_ref,
            preferred_base_ref,
        );
        observation.if_changed = if_changed;
        observation.target_ref = target_ref.to_owned();
        let decision = evaluate_change_gate(run.phase, &run.name, &observation);
        selections.push(ProjectSelection { run, decision });
    }
    Ok(selections)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectRuntimeInput {
    pub selection: ProjectSelection,
    pub environment: BTreeMap<String, String>,
    pub automatic_tfvars: AutomaticTfvars,
    pub project_requires_secret_tfvars: bool,
    pub dry_run: bool,
    pub plan_file: PathBuf,
    pub apps_package_default: Option<PathBuf>,
    pub repo_root: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectExecution {
    pub name: String,
    pub decision: ChangeDecision,
    pub commands: Vec<ProcessCommand>,
    pub environment: BTreeMap<String, String>,
}

pub fn prepare_project_execution(
    input: &ProjectRuntimeInput,
) -> Result<ProjectExecution, RuntimeError> {
    if input.selection.decision == ChangeDecision::SkipUnchanged {
        return Ok(ProjectExecution {
            name: input.selection.run.name.clone(),
            decision: input.selection.decision.clone(),
            commands: Vec::new(),
            environment: BTreeMap::new(),
        });
    }
    let project = project_context(&input.selection.run.directory)
        .map_err(|error| RuntimeError::Plan(error.to_string()))?;
    let backend_values = validate_project_environment(&project, &input.environment)?;
    let commands = plan_project_commands(&ProjectPlanInput {
        repo_root: input.repo_root.clone(),
        project,
        backend_values,
        automatic_tfvars: input.automatic_tfvars.clone(),
        project_requires_secret_tfvars: input.project_requires_secret_tfvars,
        dry_run: input.dry_run,
        plan_file: input.plan_file.clone(),
        apps_package_default: input.apps_package_default.clone(),
    })
    .map_err(|error| RuntimeError::Plan(error.to_string()))?;
    Ok(ProjectExecution {
        name: input.selection.run.name.clone(),
        decision: input.selection.decision.clone(),
        commands,
        environment: input.environment.clone(),
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PhaseProjectStatus {
    Skipped,
    Succeeded,
    Failed { status: Option<i32> },
    NotRun,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PhaseProjectResult {
    pub name: String,
    pub status: PhaseProjectStatus,
    pub commands: Vec<CommandOutput>,
    pub diagnostic: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PhaseExecutionReport {
    pub projects: Vec<PhaseProjectResult>,
    pub success: bool,
}

/// Execute projects and their commands sequentially, stopping the phase at the
/// first command error or nonzero status.
pub fn execute_phase<E: CommandExecutor>(
    projects: &[ProjectExecution],
    repo_root: &Path,
    executor: &mut E,
) -> PhaseExecutionReport {
    let mut results = Vec::with_capacity(projects.len());
    let mut failed = false;
    for project in projects {
        if failed {
            results.push(PhaseProjectResult {
                name: project.name.clone(),
                status: PhaseProjectStatus::NotRun,
                commands: Vec::new(),
                diagnostic: None,
            });
            continue;
        }
        if project.decision == ChangeDecision::SkipUnchanged {
            results.push(PhaseProjectResult {
                name: project.name.clone(),
                status: PhaseProjectStatus::Skipped,
                commands: Vec::new(),
                diagnostic: None,
            });
            continue;
        }

        let mut outputs = Vec::with_capacity(project.commands.len());
        let mut status = PhaseProjectStatus::Succeeded;
        let mut diagnostic = None;
        for command in &project.commands {
            match executor.execute(repo_root, command, &project.environment) {
                Ok(output) if output.success() => outputs.push(output),
                Ok(output) => {
                    status = PhaseProjectStatus::Failed {
                        status: output.status,
                    };
                    outputs.push(output);
                    failed = true;
                    break;
                }
                Err(error) => {
                    status = PhaseProjectStatus::Failed { status: None };
                    diagnostic = Some(error.to_string());
                    failed = true;
                    break;
                }
            }
        }
        results.push(PhaseProjectResult {
            name: project.name.clone(),
            status,
            commands: outputs,
            diagnostic,
        });
    }
    PhaseExecutionReport {
        success: !failed,
        projects: results,
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RuntimeError {
    RepositoryCurrentDirMismatch {
        expected: PathBuf,
        command: Option<PathBuf>,
    },
    UnknownProgram(String),
    Spawn {
        program: PathBuf,
        message: String,
    },
    TemporaryDirectory(String),
    MaterializationCounterOverflow,
    SecretSourceMissing(PathBuf),
    SecretOutsideRepository(PathBuf),
    Decrypt {
        source: PathBuf,
        message: String,
    },
    SecureMode {
        path: PathBuf,
        message: String,
    },
    ReadMaterialized {
        path: PathBuf,
        message: String,
    },
    MissingEnvironment(String),
    EnvironmentFileMissing {
        name: String,
        path: PathBuf,
    },
    SecretDiscovery {
        path: PathBuf,
        message: String,
    },
    InvalidProjectName(String),
    ProjectDirectoryMissing(PathBuf),
    Plan(String),
}

impl std::fmt::Display for RuntimeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::RepositoryCurrentDirMismatch { expected, command } => write!(
                formatter,
                "command current directory {:?} does not match repository {}",
                command,
                expected.display()
            ),
            Self::UnknownProgram(program) => {
                write!(formatter, "unknown runtime program: {program}")
            }
            Self::Spawn { program, message } => {
                write!(formatter, "cannot execute {}: {message}", program.display())
            }
            Self::TemporaryDirectory(message) => {
                write!(
                    formatter,
                    "cannot create secure temporary directory: {message}"
                )
            }
            Self::MaterializationCounterOverflow => {
                formatter.write_str("secret materialization counter overflow")
            }
            Self::SecretSourceMissing(path) => {
                write!(formatter, "secret source is missing: {}", path.display())
            }
            Self::SecretOutsideRepository(path) => write!(
                formatter,
                "secret declaration escapes repository: {}",
                path.display()
            ),
            Self::Decrypt { source, message } => {
                write!(
                    formatter,
                    "cannot materialize {}: {message}",
                    source.display()
                )
            }
            Self::SecureMode { path, message } => {
                write!(formatter, "cannot secure {}: {message}", path.display())
            }
            Self::ReadMaterialized { path, message } => {
                write!(formatter, "cannot read {}: {message}", path.display())
            }
            Self::MissingEnvironment(name) => {
                write!(formatter, "missing required environment variable: {name}")
            }
            Self::EnvironmentFileMissing { name, path } => write!(
                formatter,
                "environment variable {name} does not name a file: {}",
                path.display()
            ),
            Self::SecretDiscovery { path, message } => {
                write!(formatter, "cannot scan {}: {message}", path.display())
            }
            Self::InvalidProjectName(project) => {
                write!(formatter, "invalid Terraform project name: {project}")
            }
            Self::ProjectDirectoryMissing(path) => {
                write!(
                    formatter,
                    "Terraform project directory missing: {}",
                    path.display()
                )
            }
            Self::Plan(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for RuntimeError {}
