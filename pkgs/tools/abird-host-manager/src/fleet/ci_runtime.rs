//! Effect adapter for repository-backed CI trigger execution.
//!
//! CI request construction remains owned by [`super::repository`]. This module
//! resolves the local repository and inventory inputs, materializes ephemeral
//! SSH credentials, and executes the resulting forced-command request without
//! a local shell.

use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};
use tempfile::{Builder as TempBuilder, TempDir};

use super::cli::{LogFormat, Options};
use super::inventory::Inventory;
use super::repository::{
    CiCleanMode, CiHostSelection, CiLogFormat, CiTriggerPlan, CiTriggerRequest, CommandOutput,
    CommandRequest, CommandRunner, CommitSha, DirtyForwarding, ProcessCommandRunner,
    SSH_ARGV_PREFIX, StagedPatch, decode_argv, plan_ci_trigger,
};
use super::system::resolve_host;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CiRevisionSource {
    NotRequired,
    Explicit,
    Head,
}

#[derive(Clone, Debug)]
pub struct CiRequestInput<'a> {
    pub action: &'a str,
    pub clean_mode: CiCleanMode,
    pub options: &'a Options,
    pub inventory: &'a Inventory,
    pub repository_root: &'a Path,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CiForwardedSelection {
    pub group: Option<String>,
    pub hosts: Option<CiHostSelection>,
}

/// Preserve the caller's workflow scope. In particular, a group-only request
/// remains group-only rather than being flattened into its current host list.
pub fn forwarded_selection(
    options: &Options,
    inventory: &Inventory,
) -> Result<CiForwardedSelection> {
    if options.host.is_some() && options.hosts.is_some() {
        bail!("CI trigger cannot combine singular and plural host selection");
    }

    let hosts_explicit = options.host.is_some() || options.hosts.is_some();
    let groups = if options.groups.is_empty() && !hosts_explicit {
        inventory
            .config
            .default_group
            .as_deref()
            .map(split_values)
            .unwrap_or_default()
    } else {
        options.groups.clone()
    };
    let group = (!groups.is_empty()).then(|| groups.join(","));
    let hosts = if let Some(host) = &options.host {
        Some(CiHostSelection::Singular(host.clone()))
    } else if let Some(hosts) = &options.hosts {
        Some(CiHostSelection::Selectors(hosts.clone()))
    } else if group.is_some() {
        None
    } else {
        Some(CiHostSelection::Selectors(
            inventory
                .config
                .default_hosts
                .clone()
                .unwrap_or_else(|| "all".to_owned()),
        ))
    };
    Ok(CiForwardedSelection { group, hosts })
}

fn split_values(raw: &str) -> Vec<String> {
    raw.split([',', ' ', '\t', '\n'])
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .collect()
}

pub fn forwarded_log_format(format: LogFormat) -> CiLogFormat {
    match format {
        LogFormat::Auto => CiLogFormat::Auto,
        LogFormat::GithubActions => CiLogFormat::GithubActions,
        LogFormat::Plain => CiLogFormat::Plain,
    }
}

pub trait CiRepositorySource {
    fn resolve_commit(&mut self, root: &Path, reference: &str) -> Result<CommitSha>;
    fn capture_staged_patch(&mut self, root: &Path) -> Result<Option<StagedPatch>>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PreparedCiTrigger {
    pub plan: CiTriggerPlan,
    pub revision_source: CiRevisionSource,
    pub base_proven: bool,
}

/// Resolve the target revision and staged overlay before delegating final argv
/// construction to the pure repository CI planner.
pub fn prepare_ci_trigger<R: CiRepositorySource>(
    input: &CiRequestInput<'_>,
    repository: &mut R,
) -> Result<PreparedCiTrigger> {
    let clean = input.action == "clean";
    let (sha, revision_source) = if clean {
        (None, CiRevisionSource::NotRequired)
    } else {
        let (reference, source) = input
            .options
            .sha
            .as_deref()
            .map(|sha| (sha, CiRevisionSource::Explicit))
            .unwrap_or(("HEAD", CiRevisionSource::Head));
        (
            Some(repository.resolve_commit(input.repository_root, reference)?),
            source,
        )
    };

    let mut base_proven = false;
    let dirty = if clean {
        DirtyForwarding::Clean
    } else if input.options.dirty_staged {
        match repository.capture_staged_patch(input.repository_root)? {
            None => DirtyForwarding::Clean,
            Some(patch) => {
                let target = sha
                    .as_ref()
                    .context("staged CI trigger target was not resolved")?;
                let base = repository.resolve_commit(input.repository_root, patch.base.as_str())?;
                if &base != target {
                    bail!(
                        "staged patch base {} does not match requested target {}",
                        base.as_str(),
                        target.as_str()
                    );
                }
                base_proven = true;
                DirtyForwarding::Staged {
                    patch: StagedPatch {
                        base,
                        bytes: patch.bytes,
                    },
                }
            }
        }
    } else if input.options.dirty {
        DirtyForwarding::AllowDirty
    } else {
        DirtyForwarding::Clean
    };

    let selection = if clean {
        CiForwardedSelection {
            group: None,
            hosts: None,
        }
    } else {
        forwarded_selection(input.options, input.inventory)?
    };
    let plan = plan_ci_trigger(&CiTriggerRequest {
        action: input.action.to_owned(),
        sha,
        clean_mode: input.clean_mode,
        group: selection.group,
        hosts: selection.hosts,
        nix_config: input.options.nix_config.clone(),
        log_format: forwarded_log_format(input.options.log_format),
        dry_run: input.options.dry_run,
        force: input.options.force,
        restart_managed: input.options.restart_managed,
        control_plane_first: input.options.control_plane_first,
        verify: !input.options.no_verify,
        dirty,
    })?;
    Ok(PreparedCiTrigger {
        plan,
        revision_source,
        base_proven,
    })
}

/// Git-backed source for the read-only revision and staged-index observations
/// needed by a CI trigger.
pub struct ProcessCiRepositorySource<R> {
    git_program: PathBuf,
    runner: R,
}

impl<R: CommandRunner> ProcessCiRepositorySource<R> {
    pub fn new(git_program: impl Into<PathBuf>, runner: R) -> Self {
        Self {
            git_program: git_program.into(),
            runner,
        }
    }

    pub fn runner(&self) -> &R {
        &self.runner
    }

    fn git(
        &mut self,
        root: &Path,
        args: impl IntoIterator<Item = impl Into<OsString>>,
    ) -> Result<CommandOutput> {
        self.runner.run(
            &CommandRequest::new(&self.git_program)
                .args(args)
                .current_dir(root),
        )
    }
}

impl<R: CommandRunner> CiRepositorySource for ProcessCiRepositorySource<R> {
    fn resolve_commit(&mut self, root: &Path, reference: &str) -> Result<CommitSha> {
        let target = format!("{reference}^{{commit}}");
        let output = self.git(root, ["rev-parse", "--verify", target.as_str()])?;
        if !output.succeeded() {
            bail!("requested CI revision is unavailable: {reference}");
        }
        let value = std::str::from_utf8(&output.stdout)
            .context("resolved CI revision was not UTF-8")?
            .trim();
        CommitSha::parse(value)
    }

    fn capture_staged_patch(&mut self, root: &Path) -> Result<Option<StagedPatch>> {
        let quiet = self.git(root, ["diff", "--cached", "--quiet", "--no-ext-diff", "--"])?;
        match quiet.status {
            0 => return Ok(None),
            1 => {}
            status => bail!("inspect staged changes failed with status {status}"),
        }
        let output = self.git(
            root,
            [
                "diff",
                "--cached",
                "--binary",
                "--full-index",
                "--no-ext-diff",
                "--",
            ],
        )?;
        if !output.succeeded() {
            bail!(
                "capture staged binary patch failed with status {}",
                output.status
            );
        }
        if output.stdout.is_empty() {
            bail!("staged patch was unexpectedly empty");
        }
        Ok(Some(StagedPatch {
            base: self.resolve_commit(root, "HEAD")?,
            bytes: output.stdout,
        }))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CiPrivateKey {
    Inline(String),
    Source(PathBuf),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CiConnection {
    pub inventory_name: Option<String>,
    pub target: String,
    pub user: String,
    pub port: u16,
    pub private_key: Option<CiPrivateKey>,
    pub known_hosts: Option<String>,
    pub proxy_jump: Option<String>,
}

#[derive(Clone, Debug)]
pub struct CiConnectionInput<'a> {
    pub inventory: &'a Inventory,
    pub options: &'a Options,
    /// CI-specific key declaration. It takes precedence over the inventory's
    /// normal deploy identity, while an explicit inline CI key takes precedence
    /// over both.
    pub default_private_key: Option<&'a Path>,
}

pub fn resolve_ci_connection(input: &CiConnectionInput<'_>) -> Result<CiConnection> {
    let explicit_host = input.options.ci_host.as_deref();
    let requested = explicit_host
        .or(input.inventory.config.controller.as_deref())
        .context("CI trigger host is not configured")?;
    validate_ssh_target(requested)?;

    let resolved_name = input.inventory.host_for_resource(requested).ok();
    let resolved = resolved_name
        .map(|_| resolve_host(input.inventory, requested, &Options::default()))
        .transpose()?;
    if explicit_host.is_none() && resolved.is_none() {
        bail!("configured CI controller is not present in the inventory: {requested}");
    }

    let declared_user = resolved_name.and_then(|name| {
        input.inventory.hosts[name]
            .user
            .clone()
            .or_else(|| input.inventory.config.host_defaults.user.clone())
    });
    let user = input
        .options
        .ci_user
        .clone()
        .or(declared_user)
        .unwrap_or_else(|| "nixbot".to_owned());
    validate_ssh_user(&user)?;

    let private_key = input
        .options
        .ci_ssh_key
        .clone()
        .map(CiPrivateKey::Inline)
        .or_else(|| {
            input
                .default_private_key
                .map(|path| CiPrivateKey::Source(path.to_path_buf()))
        })
        .or_else(|| {
            resolved
                .as_ref()
                .and_then(|host| host.identity_key.clone())
                .map(CiPrivateKey::Source)
        });
    let known_hosts = input
        .options
        .ci_known_hosts
        .clone()
        .or_else(|| resolved.as_ref().and_then(|host| host.known_hosts.clone()));

    Ok(CiConnection {
        inventory_name: resolved.as_ref().map(|host| host.inventory_name.clone()),
        target: resolved
            .as_ref()
            .map(|host| host.target.clone())
            .unwrap_or_else(|| requested.to_owned()),
        user,
        port: resolved.as_ref().map_or(22, |host| host.port),
        private_key,
        known_hosts,
        proxy_jump: resolved.and_then(|host| host.proxy_jump),
    })
}

fn validate_ssh_user(user: &str) -> Result<()> {
    if user.is_empty()
        || !user
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    {
        bail!("unsafe CI SSH user: {user}");
    }
    Ok(())
}

fn validate_ssh_target(target: &str) -> Result<()> {
    if target.is_empty()
        || target.starts_with('-')
        || target
            .bytes()
            .any(|byte| byte.is_ascii_whitespace() || byte.is_ascii_control() || byte == b'@')
    {
        bail!("unsafe CI SSH target: {target}");
    }
    Ok(())
}

pub trait CiCredentialMaterializer {
    fn materialize(&mut self, source: &Path, destination: &Path) -> Result<()>;
}

/// Materialize direct key files by copying and encrypted `.age` declarations
/// by trying the declared identities in order.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgeOrFileCredentialMaterializer {
    pub age_program: PathBuf,
    pub identities: Vec<PathBuf>,
}

impl CiCredentialMaterializer for AgeOrFileCredentialMaterializer {
    fn materialize(&mut self, source: &Path, destination: &Path) -> Result<()> {
        if source.extension().and_then(|extension| extension.to_str()) != Some("age") {
            fs::copy(source, destination)
                .with_context(|| format!("copy CI private key declaration {}", source.display()))?;
            return Ok(());
        }
        let identities = self
            .identities
            .iter()
            .filter(|identity| identity.is_file())
            .collect::<Vec<_>>();
        if identities.is_empty() {
            bail!("no readable age identity is available for the CI private key");
        }
        for identity in identities {
            let _ = fs::remove_file(destination);
            let status = Command::new(&self.age_program)
                .arg("--decrypt")
                .arg("-i")
                .arg(identity)
                .arg("-o")
                .arg(destination)
                .arg(source)
                .status()
                .with_context(|| format!("execute {}", self.age_program.display()))?;
            if status.success() {
                return Ok(());
            }
        }
        let _ = fs::remove_file(destination);
        bail!("unable to decrypt the CI private key with the available age identities")
    }
}

struct CiCredentialStore {
    directory: TempDir,
}

impl CiCredentialStore {
    fn new(parent: &Path) -> Result<Self> {
        let directory = TempBuilder::new()
            .prefix("abird-ci-trigger-")
            .tempdir_in(parent)
            .context("create CI trigger credential directory")?;
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700))
            .context("secure CI trigger credential directory")?;
        Ok(Self { directory })
    }

    fn destination(&self, name: &str) -> PathBuf {
        self.directory.path().join(name)
    }

    fn write_private(&self, name: &str, contents: &[u8]) -> Result<PathBuf> {
        let path = self.destination(name);
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .with_context(|| format!("create private CI material {}", path.display()))?;
        file.write_all(contents)
            .with_context(|| format!("write private CI material {}", path.display()))?;
        Ok(path)
    }

    fn materialize_key<M: CiCredentialMaterializer>(
        &self,
        key: &CiPrivateKey,
        repository_root: &Path,
        materializer: &mut M,
    ) -> Result<PathBuf> {
        match key {
            CiPrivateKey::Inline(contents) => {
                if contents.trim().is_empty() {
                    bail!("explicit CI private key is empty");
                }
                let mut bytes = contents.as_bytes().to_vec();
                if !bytes.ends_with(b"\n") {
                    bytes.push(b'\n');
                }
                self.write_private("ci-key", &bytes)
            }
            CiPrivateKey::Source(declaration) => {
                let source = resolve_declared_path(repository_root, declaration)?;
                if !source.is_file() {
                    bail!(
                        "CI private key declaration is not a file: {}",
                        source.display()
                    );
                }
                let destination = self.destination("ci-key");
                if let Err(error) = materializer.materialize(&source, &destination) {
                    let _ = fs::remove_file(&destination);
                    return Err(error).with_context(|| {
                        format!(
                            "materialize CI private key declaration {}",
                            source.display()
                        )
                    });
                }
                if !destination.is_file() {
                    bail!("CI key materializer did not create a private key file");
                }
                fs::set_permissions(&destination, fs::Permissions::from_mode(0o600))
                    .context("secure materialized CI private key")?;
                Ok(destination)
            }
        }
    }
}

fn resolve_declared_path(root: &Path, declaration: &Path) -> Result<PathBuf> {
    if declaration.is_absolute() {
        return Ok(declaration.to_path_buf());
    }
    if declaration
        .components()
        .any(|component| matches!(component, Component::ParentDir))
    {
        bail!("relative CI key declaration escapes the repository");
    }
    Ok(root.join(declaration))
}

fn valid_known_hosts(contents: &str) -> bool {
    contents.lines().any(|line| {
        let line = line.trim();
        !line.is_empty() && !line.starts_with('#') && line.split_whitespace().count() >= 3
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CiPrograms {
    pub ssh: PathBuf,
    pub ssh_keyscan: PathBuf,
}

impl CiPrograms {
    pub fn new(ssh: impl Into<PathBuf>, ssh_keyscan: impl Into<PathBuf>) -> Self {
        Self {
            ssh: ssh.into(),
            ssh_keyscan: ssh_keyscan.into(),
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct SystemCiExecutor;

impl CommandRunner for SystemCiExecutor {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput> {
        ProcessCommandRunner.run(request)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CiExecutionReport {
    pub status: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub dry_run: bool,
    pub stdin_bytes: usize,
    pub used_keyscan: bool,
    pub ssh_argv: Vec<OsString>,
}

/// Execute a prepared CI plan over one strictly checked SSH transport. A dry
/// run still reaches the CI host because `--dry` belongs to the remote action;
/// the report makes that mode explicit to callers.
#[allow(clippy::too_many_arguments)]
pub fn execute_ci_trigger<E: CommandRunner, M: CiCredentialMaterializer>(
    plan: &CiTriggerPlan,
    connection: &CiConnection,
    repository_root: &Path,
    temporary_parent: &Path,
    programs: &CiPrograms,
    executor: &mut E,
    materializer: &mut M,
    keyscan_timeout_seconds: u64,
) -> Result<CiExecutionReport> {
    validate_remote_command(plan)?;
    validate_ssh_target(&connection.target)?;
    validate_ssh_user(&connection.user)?;
    if connection.port == 0 {
        bail!("CI SSH port must be positive");
    }

    let store = CiCredentialStore::new(temporary_parent)?;
    let private_key = connection
        .private_key
        .as_ref()
        .map(|key| store.materialize_key(key, repository_root, materializer))
        .transpose()?;

    let (known_hosts, used_keyscan) = if let Some(configured) = &connection.known_hosts {
        if !valid_known_hosts(configured) {
            bail!("configured CI known-hosts material contains no host key");
        }
        (configured.clone(), false)
    } else {
        if keyscan_timeout_seconds == 0 {
            bail!("CI host-key scan timeout must be positive");
        }
        let mut arguments = vec![
            OsString::from("-T"),
            OsString::from(keyscan_timeout_seconds.to_string()),
            OsString::from("-H"),
        ];
        if connection.port != 22 {
            arguments.extend([
                OsString::from("-p"),
                OsString::from(connection.port.to_string()),
            ]);
        }
        arguments.push(OsString::from(&connection.target));
        let output = executor.run(
            &CommandRequest::new(&programs.ssh_keyscan)
                .args(arguments)
                .current_dir(repository_root),
        )?;
        let scanned = std::str::from_utf8(&output.stdout)
            .context("CI host-key scan output was not UTF-8")?
            .to_owned();
        if !valid_known_hosts(&scanned) {
            bail!(
                "could not determine CI host key for {}; configure known-hosts or ensure bounded keyscan access",
                connection.target
            );
        }
        (scanned, true)
    };
    let mut known_hosts_bytes = known_hosts.trim_end_matches('\n').as_bytes().to_vec();
    known_hosts_bytes.push(b'\n');
    let known_hosts_path = store.write_private("known-hosts", &known_hosts_bytes)?;

    let mut args = vec![
        OsString::from("-F"),
        OsString::from("/dev/null"),
        OsString::from("-o"),
        OsString::from("BatchMode=yes"),
        OsString::from("-o"),
        OsString::from("GlobalKnownHostsFile=/dev/null"),
        OsString::from("-o"),
        OsString::from("StrictHostKeyChecking=yes"),
        OsString::from("-o"),
        OsString::from(format!("UserKnownHostsFile={}", known_hosts_path.display())),
    ];
    if connection.port != 22 {
        args.extend([
            OsString::from("-p"),
            OsString::from(connection.port.to_string()),
        ]);
    }
    if let Some(private_key) = private_key {
        args.extend([
            OsString::from("-i"),
            private_key.into_os_string(),
            OsString::from("-o"),
            OsString::from("IdentitiesOnly=yes"),
        ]);
    }
    if let Some(proxy_jump) = &connection.proxy_jump {
        validate_ssh_target(proxy_jump)?;
        args.extend([OsString::from("-J"), OsString::from(proxy_jump)]);
    }
    args.extend([
        OsString::from("--"),
        OsString::from(format!("{}@{}", connection.user, connection.target)),
        OsString::from(&plan.remote_command),
    ]);

    let stdin_bytes = plan.stdin.as_ref().map_or(0, Vec::len);
    let request = CommandRequest {
        program: programs.ssh.clone(),
        args: args.clone(),
        current_dir: Some(repository_root.to_path_buf()),
        stdin: plan.stdin.clone(),
        environment: Vec::new(),
    };
    let output = executor.run(&request)?;
    Ok(CiExecutionReport {
        status: output.status,
        stdout: output.stdout,
        stderr: output.stderr,
        dry_run: plan.argv.iter().any(|argument| argument == "--dry"),
        stdin_bytes,
        used_keyscan,
        ssh_argv: args,
    })
}

fn validate_remote_command(plan: &CiTriggerPlan) -> Result<()> {
    let (prefix, encoded) = plan
        .remote_command
        .split_once(' ')
        .context("CI forced command is not Base64 framed")?;
    if prefix != SSH_ARGV_PREFIX
        || encoded.is_empty()
        || !encoded
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'/' | b'='))
        || decode_argv(encoded)? != plan.argv
    {
        bail!("CI forced command does not match its Base64-framed argv");
    }
    Ok(())
}
