use std::collections::BTreeMap;
use std::env;
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime};

use anyhow::{Context, Result, bail};

use crate::programs::nix::Nix;

use super::ci_runtime::{
    AgeOrFileCredentialMaterializer, CiConnectionInput, CiPrograms, CiRequestInput,
    ProcessCiRepositorySource, SystemCiExecutor, execute_ci_trigger, prepare_ci_trigger,
    resolve_ci_connection,
};
use super::cli::{Action, Invocation};
use super::environment::Environment;
use super::inventory::Inventory;
use super::maintenance::{CleanMode as MaintenanceCleanMode, clean_roots, missing_programs};
use super::native::NativeFleetEffects;
use super::plan::Phase;
use super::presentation::FleetProgress;
use super::repository::{
    CiCleanMode, CommitSha, ManagedRepository, ProcessCommandRunner, RepositoryManager,
    StagedPatch, repo_git_ssh_command, ssh_repository_endpoint,
};
use super::run_state::{
    CleanupOptions, DirectoryLock, RetentionOutcome, RunState, RuntimeRootPreference, RuntimeRoots,
    SystemProcessProbe,
};
use super::selection::{Selection, SelectionOptions, select};
use super::terraform::{
    AutomaticTfvars, BackendValues, plan_tofu_wrapper_command, validate_tofu_wrapper_invocation,
};

const DEFAULT_DEPLOY_DEPS_KEY: &str = "nixbot.deployDependencies";

pub const FLEET_VERSION: &str = "2026.07.23";
pub const USAGE: &str = r#"Usage:
  nixbot
  nixbot <deps|check-deps|version>
  nixbot repo sync
  nixbot --list-hosts [selection/config options]
  nixbot --list-groups [config options]
  nixbot <run|deploy|build|dev-build|tf|tf-dns|tf-platform|tf-apps|tf/PROJECT|check-bootstrap|clean> [options]
  nixbot --clean[=auto|all] [--dry] [--ci-trigger]
  nixbot tofu <tofu-args...>

Canonical surface:
  abird-host-manager fleet <hosts|groups|run|deploy|build|dev-build|check-bootstrap|clean>
  abird-host-manager fleet terraform <all|dns|platform|apps|project NAME>
  abird-host-manager fleet repo sync
  abird-host-manager fleet tofu <tofu-args...>

Selection: --group, --host, --hosts, --nix-config, --sha, --control-plane-first
Build: --build-host, --build-host-deploy-mode, --build-cache-url,
       --build-cache-host, --build-plan-jobs, --build-jobs, --build-logs
Deploy: --goal, --deploy-jobs, --deploy-jobs-per-domain, --verify-jobs,
        --bootstrap, --no-rollback, --no-verify, --restart-managed
Repository: --dirty, --dirty-staged, --repo-url, --repo-path, --ci-trigger
Behavior: --dry, --force, --skip-global-lock, --no-override,
          --prefix-host-logs, --verbose, --quiet, --log-format
Authentication: --user, --ssh-key, --operator-user, --operator-key,
                --bootstrap-key, --known-hosts, --age-key-file,
                --discover-keys, --config
"#;

#[derive(Clone, Debug)]
pub struct RuntimeConfig {
    pub nix_program: PathBuf,
    pub search_paths: Vec<PathBuf>,
    pub runtime_root: PathBuf,
    pub runtime_fallback_root: PathBuf,
    pub diagnostic_root: PathBuf,
    pub git_program: PathBuf,
    pub inherited_repository_root: Option<PathBuf>,
    pub inherited_worktree_root: Option<PathBuf>,
    pub repo_ssh_key_paths: Vec<PathBuf>,
    pub repo_known_hosts_file: Option<PathBuf>,
    pub repo_reexec_installable: String,
    pub repo_reexec_arguments: Vec<String>,
}

impl RuntimeConfig {
    pub fn from_environment() -> Self {
        let search_paths = env::split_paths(&env::var_os("PATH").unwrap_or_default()).collect();
        Self {
            nix_program: env::var_os("ABIRD_HOST_MANAGER_NIX")
                .or_else(|| env::var_os("NIXBOT_NIX"))
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/run/current-system/sw/bin/nix")),
            search_paths,
            runtime_root: env::var_os("NIXBOT_RUNTIME_WORK_ROOT")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/dev/shm/nixbot")),
            runtime_fallback_root: env::var_os("NIXBOT_RUNTIME_FALLBACK_ROOT")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    env::var_os("TMPDIR")
                        .map(PathBuf::from)
                        .unwrap_or_else(|| PathBuf::from("/tmp"))
                        .join("nixbot")
                }),
            diagnostic_root: env::var_os("NIXBOT_DIAG_KEEP_ROOT")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/var/tmp/nixbot")),
            git_program: env::var_os("ABIRD_HOST_MANAGER_GIT")
                .or_else(|| env::var_os("NIXBOT_GIT"))
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("git")),
            inherited_repository_root: env::var_os("NIXBOT_REPO_ROOT").map(PathBuf::from),
            inherited_worktree_root: env::var_os("NIXBOT_REPO_WORKTREE_ROOT").map(PathBuf::from),
            repo_ssh_key_paths: env::var_os("NIXBOT_REPO_SSH_KEY_PATHS")
                .map(|paths| env::split_paths(&paths).collect())
                .unwrap_or_default(),
            repo_known_hosts_file: env::var_os("NIXBOT_REPO_KNOWN_HOSTS_FILE").map(PathBuf::from),
            repo_reexec_installable: ".#nixbot".to_owned(),
            repo_reexec_arguments: Vec::new(),
        }
    }
}

struct RepositoryRuntime {
    manager: RepositoryManager<ProcessCommandRunner>,
    _temporary_known_hosts: Option<tempfile::TempDir>,
}

fn repository_manager(runtime: &RuntimeConfig, url: Option<&str>) -> Result<RepositoryRuntime> {
    let mut temporary = None;
    let environment = match url.map(ssh_repository_endpoint).transpose()? {
        Some(Some((host, port))) => {
            let known_hosts = if let Some(path) = runtime.repo_known_hosts_file.clone() {
                if !path.is_absolute() {
                    bail!("NIXBOT_REPO_KNOWN_HOSTS_FILE must be absolute");
                }
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent).with_context(|| {
                        format!(
                            "create repository known-hosts directory {}",
                            parent.display()
                        )
                    })?;
                }
                path
            } else {
                let directory = tempfile::Builder::new()
                    .prefix("abird-repo-transport-")
                    .tempdir()
                    .context("create repository transport directory")?;
                let path = directory.path().join("known_hosts");
                temporary = Some(directory);
                path
            };
            let populated = known_hosts
                .metadata()
                .map(|metadata| metadata.is_file() && metadata.len() > 0)
                .unwrap_or(false);
            if !populated {
                let scanned = scan_repository_host_key(&host, port)?;
                let mut file = std::fs::OpenOptions::new()
                    .create(true)
                    .write(true)
                    .truncate(true)
                    .mode(0o600)
                    .open(&known_hosts)
                    .with_context(|| {
                        format!(
                            "write repository known-hosts file {}",
                            known_hosts.display()
                        )
                    })?;
                file.write_all(&scanned)?;
                file.write_all(b"\n")?;
                std::fs::set_permissions(&known_hosts, std::fs::Permissions::from_mode(0o600))?;
            }
            vec![(
                "GIT_SSH_COMMAND".to_owned(),
                repo_git_ssh_command(&known_hosts, &runtime.repo_ssh_key_paths)?,
            )]
        }
        Some(None) | None => Vec::new(),
    };
    Ok(RepositoryRuntime {
        manager: RepositoryManager::new(&runtime.git_program, ProcessCommandRunner)
            .with_environment(environment),
        _temporary_known_hosts: temporary,
    })
}

fn scan_repository_host_key(host: &str, port: u16) -> Result<Vec<u8>> {
    for algorithm in [Some("ed25519"), None] {
        let mut command = Command::new("ssh-keyscan");
        command.args(["-T", "10", "-H", "-p", &port.to_string()]);
        if let Some(algorithm) = algorithm {
            command.args(["-t", algorithm]);
        }
        let output = command
            .arg(host)
            .output()
            .with_context(|| format!("scan repository SSH host key for {host}"))?;
        if output
            .stdout
            .split(|byte| *byte == b'\n')
            .any(|line| !line.is_empty() && !line.starts_with(b"#"))
        {
            return Ok(output.stdout);
        }
    }
    bail!("could not determine repository SSH host key for {host}")
}

pub fn run(invocation: Invocation, runtime: RuntimeConfig) -> Result<()> {
    super::signal::install()?;
    if invocation.options.ci_trigger {
        return run_auxiliary_step(&invocation, "Trigger remote fleet command", || {
            run_ci_trigger(&invocation, &runtime)
        });
    }
    let action_name = action_name(&invocation.action);
    let _mutex = if !invocation.options.skip_global_lock
        && super::run_state::action_needs_local_mutex(action_name)
    {
        let path = env::var_os("NIXBOT_HOST_LOCAL_LOCK_PATH")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/dev/shm/nixbot-host-local.lock.d"));
        Some(acquire_action_mutex(&path, action_name)?)
    } else {
        None
    };
    run_unlocked(invocation, runtime)
}

fn acquire_action_mutex(path: &Path, action: &str) -> Result<super::run_state::ActionMutex> {
    let started = Instant::now();
    let reporter = crate::progress::command_reporter();
    let mut announced = false;
    loop {
        super::signal::check_interrupted()?;
        if let Some(lock) = super::run_state::ActionMutex::try_acquire(path)? {
            if announced {
                reporter.completed(
                    format!("Host-local action lock · {action}"),
                    started.elapsed(),
                );
            }
            return Ok(lock);
        }
        if !announced {
            reporter.started(format!("Waiting for host-local action lock · {action}"));
            announced = true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn run_unlocked(invocation: Invocation, runtime: RuntimeConfig) -> Result<()> {
    match &invocation.action {
        Action::Help => {
            print!("{USAGE}");
            Ok(())
        }
        Action::Deps | Action::CheckDeps => {
            run_auxiliary_phase(&invocation, Phase::DependencyCheck, || {
                let missing = missing_programs(&runtime.search_paths)?;
                if !missing.is_empty() {
                    bail!("required commands not found: {}", missing.join(", "));
                }
                Ok(())
            })
        }
        Action::Version => {
            println!("{FLEET_VERSION}");
            Ok(())
        }
        Action::RepoSync => {
            let root = invocation
                .options
                .repo_path
                .as_deref()
                .context("repo sync requires NIXBOT_REPO_PATH or --repo-path")?;
            let url = invocation
                .options
                .repo_url
                .as_deref()
                .context("repo sync requires NIXBOT_REPO_URL or --repo-url")?;
            let synchronized = run_auxiliary_phase(&invocation, Phase::RepositorySync, || {
                let settings = Environment::current().settings()?;
                let _lock = repository_lock(
                    &runtime.git_program,
                    root,
                    settings.repo_root_lock_timeout_seconds,
                )?;
                let mut repository = repository_manager(&runtime, Some(url))?;
                repository.manager.prepare_managed(&ManagedRepository {
                    root: root.to_path_buf(),
                    url: url.to_owned(),
                    allow_dirty: invocation.options.dirty,
                })
            })?;
            println!("{}", synchronized.head.as_str());
            Ok(())
        }
        Action::ListGroups => {
            let inventory = load_inventory(&invocation, &runtime)?;
            print_groups(&inventory);
            Ok(())
        }
        Action::ListHosts => {
            let inventory = load_inventory(&invocation, &runtime)?;
            let selection = select_inventory(&inventory, &invocation)?;
            print_hosts(&inventory, &selection);
            Ok(())
        }
        Action::Clean(mode) => {
            let mode = match mode {
                super::cli::CleanMode::Auto => MaintenanceCleanMode::Automatic {
                    older_than: Duration::from_secs(24 * 60 * 60),
                    now: SystemTime::now(),
                },
                super::cli::CleanMode::All => MaintenanceCleanMode::All,
            };
            let mut roots = Vec::new();
            for root in [
                &runtime.runtime_root,
                &runtime.runtime_fallback_root,
                &runtime.diagnostic_root,
            ] {
                if !roots.contains(&root) {
                    roots.push(root);
                }
            }
            let report = run_auxiliary_phase(&invocation, Phase::Clean, || {
                clean_roots(roots, mode, invocation.options.dry_run)
            })?;
            for (path, outcome) in report.outcomes {
                println!("{} {}", clean_outcome_label(outcome), path.display());
            }
            Ok(())
        }
        Action::Tofu(arguments) => {
            run_auxiliary_step(&invocation, "Run infrastructure command", || {
                run_tofu(arguments, &invocation, &runtime)
            })
        }
        _ => run_native_workflow(invocation, runtime),
    }
}

fn run_auxiliary_phase<T>(
    invocation: &Invocation,
    phase: Phase,
    operation: impl FnOnce() -> Result<T>,
) -> Result<T> {
    let progress = FleetProgress::from_options(&invocation.options);
    let started = Instant::now();
    progress.phase_started(phase, 0);
    match operation() {
        Ok(value) => {
            progress.phase_completed(phase, 0, started.elapsed());
            Ok(value)
        }
        Err(error) => {
            progress.phase_failed(phase, 0, started.elapsed(), &format!("{error:#}"));
            Err(error)
        }
    }
}

fn run_auxiliary_step<T>(
    invocation: &Invocation,
    label: &str,
    operation: impl FnOnce() -> Result<T>,
) -> Result<T> {
    let progress = FleetProgress::from_options(&invocation.options);
    let started = Instant::now();
    progress.step_started(label);
    match operation() {
        Ok(value) => {
            progress.step_completed(label, started.elapsed());
            Ok(value)
        }
        Err(error) => {
            progress.step_failed(label, &format!("{error:#}"));
            Err(error)
        }
    }
}

fn action_name(action: &Action) -> &str {
    match action {
        Action::Help => "help",
        Action::Deps => "deps",
        Action::CheckDeps => "check-deps",
        Action::Version => "version",
        Action::RepoSync => "repo-sync",
        Action::ListHosts => "list-hosts",
        Action::ListGroups => "list-groups",
        Action::Run => "run",
        Action::Deploy => "deploy",
        Action::Build => "build",
        Action::DevBuild => "dev-build",
        Action::TerraformAll => "tf",
        Action::TerraformDns => "tf-dns",
        Action::TerraformPlatform => "tf-platform",
        Action::TerraformApps => "tf-apps",
        Action::TerraformProject(_) => "tf/project",
        Action::CheckBootstrap => "check-bootstrap",
        Action::Clean(_) => "clean",
        Action::Tofu(_) => "tofu",
    }
}

fn run_ci_trigger(invocation: &Invocation, runtime: &RuntimeConfig) -> Result<()> {
    if matches!(
        invocation.action,
        Action::Help
            | Action::Deps
            | Action::CheckDeps
            | Action::Version
            | Action::RepoSync
            | Action::ListHosts
            | Action::ListGroups
            | Action::DevBuild
            | Action::Tofu(_)
    ) {
        bail!(
            "{:?} is local-only and cannot run through --ci-trigger",
            invocation.action
        );
    }
    let repository_root = repository_root(&runtime.git_program, &env::current_dir()?)?;
    let inventory = load_inventory_at(invocation, runtime, &repository_root)?;
    let (action, clean_mode) = ci_action(&invocation.action)?;
    let mut source =
        ProcessCiRepositorySource::new(runtime.git_program.clone(), ProcessCommandRunner);
    let prepared = prepare_ci_trigger(
        &CiRequestInput {
            action: &action,
            clean_mode,
            options: &invocation.options,
            inventory: &inventory,
            repository_root: &repository_root,
        },
        &mut source,
    )?;
    let default_key = invocation
        .options
        .ci_check_ssh_key_path
        .clone()
        .unwrap_or_else(|| PathBuf::from("data/secrets/globals/ci/nixbot-ci-ssh.key.age"));
    let connection = resolve_ci_connection(&CiConnectionInput {
        inventory: &inventory,
        options: &invocation.options,
        default_private_key: Some(&default_key),
    })?;
    let mut materializer = AgeOrFileCredentialMaterializer {
        age_program: PathBuf::from("age"),
        identities: super::native::age_identities(&invocation.options),
    };
    let temporary = tempfile::Builder::new()
        .prefix("abird-ci-trigger-parent-")
        .tempdir()
        .context("create CI trigger temporary parent")?;
    let report = execute_ci_trigger(
        &prepared.plan,
        &connection,
        &repository_root,
        temporary.path(),
        &CiPrograms::new("ssh", "ssh-keyscan"),
        &mut SystemCiExecutor,
        &mut materializer,
        10,
    )?;
    std::io::Write::write_all(&mut std::io::stdout(), &report.stdout)?;
    std::io::Write::write_all(&mut std::io::stderr(), &report.stderr)?;
    if report.status != 0 {
        bail!("remote CI trigger failed with status {}", report.status);
    }
    Ok(())
}

fn ci_action(action: &Action) -> Result<(String, CiCleanMode)> {
    let result = match action {
        Action::Run => ("run".to_owned(), CiCleanMode::Auto),
        Action::Deploy => ("deploy".to_owned(), CiCleanMode::Auto),
        Action::Build => ("build".to_owned(), CiCleanMode::Auto),
        Action::TerraformAll => ("tf".to_owned(), CiCleanMode::Auto),
        Action::TerraformDns => ("tf-dns".to_owned(), CiCleanMode::Auto),
        Action::TerraformPlatform => ("tf-platform".to_owned(), CiCleanMode::Auto),
        Action::TerraformApps => ("tf-apps".to_owned(), CiCleanMode::Auto),
        Action::TerraformProject(name) => (format!("tf/{name}"), CiCleanMode::Auto),
        Action::CheckBootstrap => ("check-bootstrap".to_owned(), CiCleanMode::Auto),
        Action::Clean(super::cli::CleanMode::Auto) => ("clean".to_owned(), CiCleanMode::Auto),
        Action::Clean(super::cli::CleanMode::All) => ("clean".to_owned(), CiCleanMode::All),
        _ => bail!("unsupported action for --ci-trigger: {action:?}"),
    };
    Ok(result)
}

fn run_native_workflow(invocation: Invocation, runtime: RuntimeConfig) -> Result<()> {
    let current = env::current_dir().context("resolve fleet invocation directory")?;
    let source_root = runtime
        .inherited_repository_root
        .clone()
        .or_else(|| invocation.options.repo_path.clone())
        .map(Ok)
        .unwrap_or_else(|| repository_root(&runtime.git_program, &current))?;

    if matches!(invocation.action, Action::DevBuild) {
        let state = allocate_run_state(&runtime)?;
        let inventory = load_inventory_at(&invocation, &runtime, &source_root)?;
        let selection = select_inventory(&inventory, &invocation)?;
        let mut effects = NativeFleetEffects::new_with_diagnostics(
            &invocation,
            &runtime.nix_program,
            &source_root,
            &inventory,
            &selection,
            Some(&state.layout().diagnostic_dir),
        )?;
        let started = Instant::now();
        let action = super::engine::execute(&invocation, &mut effects);
        effects.report_summary(action.is_ok(), started.elapsed());
        drop(effects);
        return finish_run_state(state, action);
    }

    let state = allocate_run_state(&runtime)?;
    let diagnostic_dir = state.layout().diagnostic_dir.clone();
    let execution_root = state.layout().run_dir.join("repo");
    let inherited = runtime.inherited_worktree_root.is_some();
    let execution_root = runtime
        .inherited_worktree_root
        .clone()
        .unwrap_or(execution_root);
    let staged_patch = staged_patch(&invocation, &source_root, &runtime)?;
    let configured_repo_url = if invocation.options.repo_url.is_none() && source_root.is_dir() {
        load_inventory_at(&invocation, &runtime, &source_root)
            .ok()
            .and_then(|inventory| inventory.config.repo_url)
    } else {
        None
    };
    let managed = invocation
        .options
        .repo_path
        .is_some()
        .then(|| {
            invocation
                .options
                .repo_url
                .as_ref()
                .or(configured_repo_url.as_ref())
                .map(|url| ManagedRepository {
                    root: source_root.clone(),
                    url: url.clone(),
                    allow_dirty: invocation.options.dirty,
                })
        })
        .flatten();
    if !inherited && invocation.options.repo_path.is_some() && managed.is_none() {
        bail!("managed fleet execution requires NIXBOT_REPO_URL or --repo-url");
    }

    let settings = Environment::current().settings()?;
    let repository_url = managed.as_ref().map(|repository| repository.url.as_str());
    let mut repository = repository_manager(&runtime, repository_url)?;
    let manager = &mut repository.manager;
    let prepare_lock = repository_lock(
        &runtime.git_program,
        &source_root,
        settings.repo_root_lock_timeout_seconds,
    )?;
    let workspace = super::workspace::prepare_execution_workspace(
        manager,
        &super::workspace::ExecutionWorkspaceRequest {
            source_root: source_root.clone(),
            execution_root,
            target: invocation.options.sha.clone(),
            managed,
            allow_dirty: invocation.options.dirty,
            staged_patch,
            inherited,
        },
    );
    drop(prepare_lock);
    let action = match workspace {
        Ok(workspace) => {
            let action = if invocation.options.use_repo_script
                && env::var("NIXBOT_REEXECED_FROM_REPO").as_deref() != Ok("1")
            {
                reexec_from_workspace(&runtime, &source_root, &workspace.root)
            } else {
                (|| {
                    let inventory = load_inventory_at(&invocation, &runtime, &workspace.root)?;
                    let selection = select_inventory(&inventory, &invocation)?;
                    let mut effects = NativeFleetEffects::new_with_diagnostics(
                        &invocation,
                        &runtime.nix_program,
                        &workspace.root,
                        &inventory,
                        &selection,
                        Some(&diagnostic_dir),
                    )?;
                    let started = Instant::now();
                    let action = super::engine::execute(&invocation, &mut effects);
                    effects.report_summary(action.is_ok(), started.elapsed());
                    action
                })()
            };
            let cleanup = repository_lock(
                &runtime.git_program,
                &source_root,
                settings.repo_root_lock_timeout_seconds,
            )
            .and_then(|_lock| super::workspace::cleanup_execution_workspace(manager, &workspace));
            combine_action_cleanup(action, cleanup, "execution worktree cleanup")
        }
        Err(error) => Err(error),
    };
    finish_run_state(state, action)
}

fn reexec_from_workspace(
    runtime: &RuntimeConfig,
    source_root: &Path,
    workspace: &Path,
) -> Result<()> {
    if runtime.repo_reexec_arguments.is_empty() {
        bail!("--use-repo-script requires the invoking binary to preserve its arguments");
    }
    let status = Command::new(&runtime.nix_program)
        .args(["run", runtime.repo_reexec_installable.as_str(), "--"])
        .args(&runtime.repo_reexec_arguments)
        .current_dir(workspace)
        .env("NIXBOT_REEXECED_FROM_REPO", "1")
        .env("NIXBOT_REPO_ROOT", source_root)
        .env("NIXBOT_REPO_WORKTREE_ROOT", workspace)
        .status()
        .context("re-execute fleet command from the exact repository worktree")?;
    if status.success() {
        return Ok(());
    }
    if let Some(code @ (129 | 130 | 143)) = status.code() {
        return Err(super::signal::Interrupted::from_status(code).into());
    }
    bail!("repository worktree fleet command failed with {status}")
}

fn repository_lock(git_program: &Path, root: &Path, timeout_seconds: u64) -> Result<DirectoryLock> {
    let path = repository_lock_path(git_program, root);
    DirectoryLock::acquire(
        &path,
        std::process::id(),
        Duration::from_secs(timeout_seconds),
        &SystemProcessProbe,
    )
}

fn repository_lock_path(git_program: &Path, root: &Path) -> PathBuf {
    let common = Command::new(git_program)
        .args(["-C"])
        .arg(root)
        .args(["rev-parse", "--git-common-dir"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|value| PathBuf::from(value.trim()))
        .filter(|path| !path.as_os_str().is_empty());
    if let Some(common) = common {
        let common = if common.is_absolute() {
            common
        } else {
            root.join(common)
        };
        common.join("nixbot-worktree.lock")
    } else {
        let mut path = root.as_os_str().to_owned();
        path.push(".nixbot-worktree.lock");
        PathBuf::from(path)
    }
}

fn allocate_run_state(runtime: &RuntimeConfig) -> Result<RunState> {
    RunState::allocate(
        RuntimeRoots {
            primary: runtime.runtime_root.clone(),
            fallback: runtime.runtime_fallback_root.clone(),
            diagnostic_keep: runtime.diagnostic_root.clone(),
        },
        RuntimeRootPreference::Auto,
    )
}

fn finish_run_state<T>(state: RunState, action: Result<T>) -> Result<T> {
    let succeeded = action.is_ok();
    let cleanup = state.normal_cleanup(CleanupOptions {
        succeeded,
        keep_diagnostics: false,
        keep_on_failure: true,
    });
    if let Ok(report) = &cleanup
        && let RetentionOutcome::Retained(path) = &report.diagnostics
    {
        crate::progress::command_reporter().message(format!("Logs kept at: {}", path.display()));
    }
    combine_action_cleanup(action, cleanup.map(|_| ()), "runtime cleanup")
}

fn staged_patch(
    invocation: &Invocation,
    source_root: &Path,
    runtime: &RuntimeConfig,
) -> Result<Option<StagedPatch>> {
    if !invocation.options.dirty_staged {
        return Ok(None);
    }
    if invocation.options.dirty_staged_patch_stdin {
        let base = invocation
            .options
            .dirty_staged_base
            .clone()
            .or_else(|| invocation.options.sha.clone())
            .context("stdin staged patch requires --dirty-staged-base or --sha")?;
        let mut bytes = Vec::new();
        std::io::stdin()
            .read_to_end(&mut bytes)
            .context("read staged patch from stdin")?;
        if bytes.is_empty() {
            bail!("dirty-staged patch payload was empty");
        }
        return Ok(Some(StagedPatch {
            base: CommitSha::parse(base)?,
            bytes,
        }));
    }
    repository_manager(runtime, None)?
        .manager
        .capture_staged_patch(source_root)
        .map(|capture| capture.map(|capture| capture.patch))
}

fn combine_action_cleanup<T>(
    action: Result<T>,
    cleanup: Result<()>,
    cleanup_label: &str,
) -> Result<T> {
    match (action, cleanup) {
        (Ok(value), Ok(())) => Ok(value),
        (Err(action), Ok(())) => Err(action),
        (Ok(_), Err(cleanup)) => Err(cleanup).with_context(|| cleanup_label.to_owned()),
        (Err(action), Err(cleanup)) => Err(anyhow::anyhow!(
            "{action:#}; {cleanup_label} also failed: {cleanup:#}"
        )),
    }
}

fn repository_root(git: &Path, current: &Path) -> Result<PathBuf> {
    let output = Command::new(git)
        .args(["rev-parse", "--show-toplevel"])
        .current_dir(current)
        .output()
        .context("locate fleet repository")?;
    if !output.status.success() {
        bail!("fleet workflow must run from inside a Git checkout");
    }
    let root = PathBuf::from(String::from_utf8(output.stdout)?.trim());
    if !root.is_absolute() || !root.is_dir() {
        bail!(
            "Git returned an invalid repository root: {}",
            root.display()
        );
    }
    Ok(root)
}

fn run_tofu(arguments: &[String], invocation: &Invocation, runtime: &RuntimeConfig) -> Result<()> {
    let original_command = env::var("SSH_ORIGINAL_COMMAND").ok();
    validate_tofu_wrapper_invocation(arguments, original_command.as_deref())?;
    let current_dir = env::current_dir().context("resolve tofu working directory")?;
    let context = super::terraform::resolve_wrapper_context(&current_dir, arguments)?;
    let repository_root = current_dir
        .ancestors()
        .find(|directory| directory.join("flake.nix").is_file())
        .map(Path::to_path_buf)
        .unwrap_or_else(|| current_dir.clone());
    let decryptor = super::terraform_runtime::AgeCommandDecryptor {
        program: PathBuf::from("age"),
        identities: super::native::age_identities(&invocation.options),
    };
    let temporary = tempfile::tempdir().context("create tofu secret runtime")?;
    let mut materializer =
        super::terraform_runtime::SecureMaterializer::new(temporary.path(), decryptor)?;
    let inherited = env::vars().collect::<BTreeMap<_, _>>();
    let (environment, backend, tfvars, requires_secret_tfvars, apps_default) =
        if let Some(project) = &context.project {
            let environment = super::terraform_runtime::resolve_environment(
                &super::terraform::project_environment_contract(project),
                &inherited,
                &repository_root,
                &mut materializer,
            )?;
            let backend =
                super::terraform_runtime::validate_project_environment(project, &environment)?;
            let discovered =
                super::terraform_runtime::discover_tfvar_secrets(&repository_root, &project.name)?;
            let tfvars =
                super::terraform_runtime::materialize_tfvars(&discovered, &mut materializer)?;
            let apps = repository_root
                .join("pkgs")
                .join(&project.name)
                .join("default.nix");
            (
                environment,
                backend,
                tfvars,
                project_requires_secret_tfvars(&project.directory)?,
                apps.is_file().then_some(apps),
            )
        } else {
            (
                inherited,
                backend_values_from_environment(),
                AutomaticTfvars::default(),
                false,
                None,
            )
        };
    let plan = plan_tofu_wrapper_command(
        &current_dir,
        arguments,
        &backend,
        &tfvars,
        requires_secret_tfvars,
        apps_default.as_deref(),
    )?;
    let programs = super::terraform_runtime::RuntimePrograms::from_pairs([
        ("tofu", PathBuf::from("tofu")),
        ("nix", runtime.nix_program.clone()),
    ]);
    let mut executor = super::terraform_runtime::SystemCommandExecutor::new(programs);
    for command in plan.preparation_commands.iter().chain([&plan.command]) {
        let output = super::terraform_runtime::CommandExecutor::execute(
            &mut executor,
            &current_dir,
            command,
            &environment,
        )?;
        print!("{}", output.stdout);
        eprint!("{}", output.stderr);
        if !output.success() {
            bail!("{} failed with status {:?}", command.program, output.status);
        }
    }
    Ok(())
}

fn project_requires_secret_tfvars(root: &Path) -> Result<bool> {
    if !root.is_dir() {
        return Ok(false);
    }
    for entry in std::fs::read_dir(root)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        if kind.is_dir() && project_requires_secret_tfvars(&entry.path())? {
            return Ok(true);
        }
        if !kind.is_file()
            || entry.path().extension().and_then(|value| value.to_str()) != Some("tfvars")
        {
            continue;
        }
        let contents = std::fs::read_to_string(entry.path())?;
        if contents.contains("config_secret_refs")
            || contents
                .split(|character: char| !character.is_ascii_alphanumeric() && character != '_')
                .any(|word| {
                    word.starts_with("secret_") && (word.ends_with("ref") || word.ends_with("refs"))
                })
        {
            return Ok(true);
        }
    }
    Ok(false)
}

fn backend_values_from_environment() -> BackendValues {
    let value = |name: &str| env::var(name).ok().filter(|value| !value.is_empty());
    BackendValues {
        r2_account_id: value("R2_ACCOUNT_ID"),
        r2_state_bucket: value("R2_STATE_BUCKET"),
        r2_access_key_id: value("R2_ACCESS_KEY_ID"),
        r2_secret_access_key: value("R2_SECRET_ACCESS_KEY"),
        r2_state_key: value("R2_STATE_KEY"),
        gcp_state_bucket: value("GCP_STATE_BUCKET"),
        gcp_state_prefix: value("GCP_STATE_PREFIX"),
        gcp_backend_impersonate_service_account: value("GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT"),
    }
}

fn clean_outcome_label(outcome: super::maintenance::CleanOutcome) -> &'static str {
    match outcome {
        super::maintenance::CleanOutcome::Absent => "absent",
        super::maintenance::CleanOutcome::Retained => "retained",
        super::maintenance::CleanOutcome::WouldRemove => "would remove",
        super::maintenance::CleanOutcome::Removed => "remove",
    }
}

pub fn load_inventory(invocation: &Invocation, runtime: &RuntimeConfig) -> Result<Inventory> {
    let current = env::current_dir().context("resolve inventory working directory")?;
    load_inventory_at(invocation, runtime, &current)
}

pub fn load_inventory_at(
    invocation: &Invocation,
    runtime: &RuntimeConfig,
    repository: &Path,
) -> Result<Inventory> {
    let config = invocation
        .options
        .config
        .clone()
        .unwrap_or_else(|| PathBuf::from("hosts/nixbot.nix"));
    let config = absolute_from(&config, repository);
    if !config.is_file() {
        bail!("deploy config not found: {}", config.display());
    }
    let overlay = (!invocation.options.no_override)
        .then(|| overlay_path(&config))
        .filter(|path| path.is_file());
    let value = Nix::new(&runtime.nix_program)?
        .eval_file_with_overlay_json(&config, overlay.as_deref())
        .with_context(|| format!("evaluate fleet inventory {}", config.display()))?;
    let mut inventory: Inventory = serde_json::from_value(value)
        .with_context(|| format!("decode fleet inventory {}", config.display()))?;
    let key = inventory
        .config
        .deploy_deps_key
        .clone()
        .unwrap_or_else(|| DEFAULT_DEPLOY_DEPS_KEY.to_owned());
    if key.is_empty()
        || !key
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        bail!("config.deployDepsKey must be a non-empty flake attribute path");
    }
    let repository = find_repository_root(
        config
            .parent()
            .context("fleet inventory path has no parent directory")?,
    )?;
    let dependencies = Nix::new(&runtime.nix_program)?
        .eval_installable_json(&repository, &format!(".#{key}"))
        .with_context(|| format!("evaluate deploy dependency attribute {key}"))?;
    let dependencies = serde_json::from_value::<BTreeMap<String, Vec<String>>>(dependencies)
        .context("decode evaluated deploy dependencies")?;
    inventory.apply_deploy_dependencies(dependencies)?;
    inventory.validate()?;
    Ok(inventory)
}

fn find_repository_root(start: &Path) -> Result<PathBuf> {
    for directory in start.ancestors() {
        if directory.join("flake.nix").is_file()
            && (directory.join(".git").exists() || directory.join(".git").is_file())
        {
            return Ok(directory.to_path_buf());
        }
    }
    bail!("config.deployDepsKey requires the inventory to belong to a flake worktree")
}

fn select_inventory(inventory: &Inventory, invocation: &Invocation) -> Result<Selection> {
    let hosts_explicit = invocation.options.host.is_some() || invocation.options.hosts.is_some();
    let groups = if invocation.options.groups.is_empty() && !hosts_explicit {
        inventory
            .config
            .default_group
            .as_deref()
            .map(split_values)
            .unwrap_or_default()
    } else {
        invocation.options.groups.clone()
    };
    let hosts = invocation.options.hosts.clone().or_else(|| {
        (!hosts_explicit)
            .then(|| inventory.config.default_hosts.clone())
            .flatten()
    });
    let deploy_jobs_per_domain = if invocation.options.deploy_jobs_per_domain_explicit {
        invocation.options.deploy_jobs_per_domain
    } else {
        inventory
            .config
            .deploy_jobs_per_domain
            .unwrap_or(invocation.options.deploy_jobs_per_domain)
    };
    select(
        inventory,
        &SelectionOptions {
            groups,
            host: invocation.options.host.clone(),
            hosts,
            control_plane_first: invocation.options.control_plane_first,
            deploy_jobs_per_domain,
        },
    )
}

fn split_values(raw: &str) -> Vec<String> {
    raw.split([',', ' ', '\t', '\n'])
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .collect()
}

fn absolute_from(path: &Path, base: &Path) -> PathBuf {
    if path.is_absolute() {
        return path.to_path_buf();
    }
    base.join(path)
}

fn overlay_path(config: &Path) -> PathBuf {
    let mut name = config
        .file_stem()
        .map(|name| name.to_os_string())
        .unwrap_or_default();
    name.push(".override.nix");
    config.with_file_name(name)
}

fn print_groups(inventory: &Inventory) {
    let mut groups = BTreeMap::<String, Vec<&str>>::new();
    let mut ungrouped = Vec::new();
    for (name, host) in &inventory.hosts {
        let positives = host.positive_groups().collect::<Vec<_>>();
        if positives.is_empty() {
            ungrouped.push(name.as_str());
        }
        for group in positives {
            groups.entry(group.to_owned()).or_default().push(name);
        }
    }
    println!("Groups:");
    for (group, hosts) in groups {
        println!("  - {group}: {}", hosts.join(", "));
    }
    if !ungrouped.is_empty() {
        println!("  - (ungrouped): {}", ungrouped.join(", "));
    }
}

fn print_hosts(inventory: &Inventory, selection: &Selection) {
    println!("Hosts:");
    for name in &selection.ordered {
        let host = &inventory.hosts[name];
        let target = host.target.as_deref().unwrap_or(name);
        let mut annotations = Vec::new();
        if host.deploy != super::inventory::DeployMode::Strict {
            annotations.push(format!("deploy={:?}", host.deploy).to_ascii_lowercase());
        }
        if host.wait != 0 {
            annotations.push(format!("wait={}s", host.wait));
        }
        if let Some(parent) = &host.parent {
            annotations.push(format!("parent={parent}"));
        }
        let suffix = if annotations.is_empty() {
            String::new()
        } else {
            format!(" ({})", annotations.join(", "))
        };
        println!("  - {name}: {target}{suffix}");
    }
}
