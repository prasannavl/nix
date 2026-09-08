//! Managed repository, execution-worktree, and CI request support.
//!
//! Repository snapshots provide data and the execution working directory. They
//! never provide executable authority: callers must continue running the
//! installed Rust fleet binary.

use std::ffi::OsString;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::process::ExitStatusExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;

pub const SSH_ARGV_PREFIX: &str = "__nixbot_argv64";

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub fn ssh_repository_endpoint(url: &str) -> Result<Option<(String, u16)>> {
    let endpoint = if let Some(rest) = url.strip_prefix("ssh://") {
        let authority = rest
            .split('/')
            .next()
            .ok_or_else(|| anyhow::anyhow!("repository SSH URL has no authority"))?;
        let host_port = authority
            .rsplit_once('@')
            .map_or(authority, |(_, value)| value);
        if let Some(bracketed) = host_port.strip_prefix('[') {
            let (host, suffix) = bracketed
                .split_once(']')
                .ok_or_else(|| anyhow::anyhow!("repository SSH URL has an invalid IPv6 host"))?;
            let port = match suffix {
                "" => 22,
                suffix if suffix.starts_with(':') => parse_repository_port(&suffix[1..])?,
                _ => bail!("repository SSH URL has invalid text after its IPv6 host"),
            };
            (host.to_owned(), port)
        } else if let Some((host, port)) = host_port.rsplit_once(':') {
            (host.to_owned(), parse_repository_port(port)?)
        } else {
            (host_port.to_owned(), 22)
        }
    } else if let Some((user_host, _path)) = url.split_once(':') {
        let Some((_user, host)) = user_host.rsplit_once('@') else {
            return Ok(None);
        };
        (host.to_owned(), 22)
    } else {
        return Ok(None);
    };
    if endpoint.0.is_empty()
        || endpoint
            .0
            .bytes()
            .any(|byte| byte.is_ascii_whitespace() || matches!(byte, b'/' | b'@' | b'[' | b']'))
    {
        bail!("repository SSH URL has an invalid host");
    }
    Ok(Some(endpoint))
}

fn parse_repository_port(value: &str) -> Result<u16> {
    let port = value
        .parse::<u16>()
        .context("repository SSH URL port is not an unsigned 16-bit integer")?;
    if port == 0 {
        bail!("repository SSH URL port must be positive");
    }
    Ok(port)
}

pub fn repo_git_ssh_command(known_hosts: &Path, identities: &[PathBuf]) -> Result<String> {
    if !known_hosts.is_absolute() || !known_hosts.is_file() {
        bail!(
            "repository known_hosts file does not exist: {}",
            known_hosts.display()
        );
    }
    let mut command = format!(
        "ssh -F /dev/null -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile={} -o StrictHostKeyChecking=yes",
        shell_quote(&known_hosts.display().to_string())
    );
    for identity in identities {
        if !identity.is_absolute() || !identity.is_file() {
            bail!(
                "configured repository SSH identity does not exist: {}",
                identity.display()
            );
        }
        command.push_str(" -i ");
        command.push_str(&shell_quote(&identity.display().to_string()));
        command.push_str(" -o IdentitiesOnly=yes");
    }
    Ok(command)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandRequest {
    pub program: PathBuf,
    pub args: Vec<OsString>,
    pub current_dir: Option<PathBuf>,
    pub stdin: Option<Vec<u8>>,
    pub environment: Vec<(OsString, OsString)>,
}

impl CommandRequest {
    pub fn new(program: impl Into<PathBuf>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            current_dir: None,
            stdin: None,
            environment: Vec::new(),
        }
    }

    pub fn args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        self.args.extend(args.into_iter().map(Into::into));
        self
    }

    pub fn current_dir(mut self, path: impl Into<PathBuf>) -> Self {
        self.current_dir = Some(path.into());
        self
    }

    pub fn stdin(mut self, contents: Vec<u8>) -> Self {
        self.stdin = Some(contents);
        self
    }

    pub fn environment<I, N, V>(mut self, values: I) -> Self
    where
        I: IntoIterator<Item = (N, V)>,
        N: Into<OsString>,
        V: Into<OsString>,
    {
        self.environment.extend(
            values
                .into_iter()
                .map(|(name, value)| (name.into(), value.into())),
        );
        self
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandOutput {
    pub status: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl CommandOutput {
    pub fn success(stdout: Vec<u8>) -> Self {
        Self {
            status: 0,
            stdout,
            stderr: Vec::new(),
        }
    }

    pub fn succeeded(&self) -> bool {
        self.status == 0
    }
}

pub trait CommandRunner {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput>;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ProcessCommandRunner;

impl CommandRunner for ProcessCommandRunner {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput> {
        let mut command = Command::new(&request.program);
        command.args(&request.args);
        command.envs(request.environment.iter().cloned());
        if let Some(current_dir) = &request.current_dir {
            command.current_dir(current_dir);
        }
        command.stdout(Stdio::piped()).stderr(Stdio::piped());
        if request.stdin.is_some() {
            command.stdin(Stdio::piped());
        }
        let mut child = command
            .spawn()
            .with_context(|| format!("spawn {}", request.program.display()))?;
        if let Some(contents) = &request.stdin {
            child
                .stdin
                .take()
                .context("command stdin was not piped")?
                .write_all(contents)
                .context("write command stdin")?;
        }
        let output = child.wait_with_output().context("wait for command")?;
        Ok(CommandOutput {
            status: output
                .status
                .code()
                .unwrap_or_else(|| 128 + output.status.signal().unwrap_or(0)),
            stdout: output.stdout,
            stderr: output.stderr,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RootSelectionInput {
    pub configured_root: PathBuf,
    pub configured_root_explicit: bool,
    pub inherited_worktree: Option<PathBuf>,
    pub forced_command: bool,
    pub current_checkout: Option<PathBuf>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SelectedRepositoryRoot {
    pub source_root: PathBuf,
    pub managed: bool,
    pub inherited_worktree: Option<PathBuf>,
}

pub fn select_repository_root(input: &RootSelectionInput) -> SelectedRepositoryRoot {
    let can_reuse_local = input.inherited_worktree.is_none()
        && !input.configured_root_explicit
        && !input.forced_command;
    if can_reuse_local && let Some(current_checkout) = &input.current_checkout {
        return SelectedRepositoryRoot {
            source_root: current_checkout.clone(),
            managed: false,
            inherited_worktree: None,
        };
    }
    SelectedRepositoryRoot {
        source_root: input.configured_root.clone(),
        managed: true,
        inherited_worktree: input.inherited_worktree.clone(),
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct CommitSha(String);

impl CommitSha {
    pub fn parse(value: impl Into<String>) -> Result<Self> {
        let value = value.into();
        if !(7..=40).contains(&value.len())
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            bail!("unsupported commit SHA: {value}");
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ManagedRepository {
    pub root: PathBuf,
    pub url: String,
    pub allow_dirty: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RepositorySync {
    pub head: CommitSha,
    pub default_ref: String,
    pub change_base: Option<CommitSha>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DetachedWorktree {
    pub path: PathBuf,
    pub commit: CommitSha,
}

pub struct RepositoryManager<R> {
    git_program: PathBuf,
    runner: R,
    environment: Vec<(OsString, OsString)>,
}

impl<R: CommandRunner> RepositoryManager<R> {
    pub fn new(git_program: impl Into<PathBuf>, runner: R) -> Self {
        Self {
            git_program: git_program.into(),
            runner,
            environment: Vec::new(),
        }
    }

    pub fn with_environment<I, N, V>(mut self, values: I) -> Self
    where
        I: IntoIterator<Item = (N, V)>,
        N: Into<OsString>,
        V: Into<OsString>,
    {
        self.environment = values
            .into_iter()
            .map(|(name, value)| (name.into(), value.into()))
            .collect();
        self
    }

    pub fn runner(&self) -> &R {
        &self.runner
    }

    pub fn prepare_managed(&mut self, repository: &ManagedRepository) -> Result<RepositorySync> {
        if repository.url.is_empty() {
            bail!("managed repository requires a configured URL");
        }
        self.clone_if_missing(&repository.root, &repository.url)?;
        self.reconcile_origin(&repository.root, Some(&repository.url))?;
        self.ensure_clean(&repository.root, repository.allow_dirty)?;
        self.sync_managed(&repository.root)
    }

    pub fn clone_if_missing(&mut self, root: &Path, url: &str) -> Result<()> {
        if root.join(".git").exists() {
            return Ok(());
        }
        if url.is_empty() {
            bail!("managed repository is missing and no repository URL is configured");
        }
        if let Some(parent) = root.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("create repository parent {}", parent.display()))?;
        }
        let request = CommandRequest::new(&self.git_program)
            .args([
                OsString::from("clone"),
                OsString::from(url),
                root.as_os_str().to_owned(),
            ])
            .environment(self.environment.clone());
        self.run_checked(&request, "clone managed repository")?;
        Ok(())
    }

    pub fn reconcile_origin(&mut self, root: &Path, configured_url: Option<&str>) -> Result<()> {
        let Some(configured_url) = configured_url.filter(|url| !url.is_empty()) else {
            return Ok(());
        };
        let get = self.run_git(root, ["remote", "get-url", "origin"], None)?;
        if !get.succeeded() {
            let add = self.git_request(root, ["remote", "add", "origin", configured_url], None);
            self.run_checked(&add, "add configured repository origin")?;
            return Ok(());
        }
        let existing = output_text(&get.stdout, "repository origin URL")?;
        if existing.trim() != configured_url {
            let set = self.git_request(root, ["remote", "set-url", "origin", configured_url], None);
            self.run_checked(&set, "reconcile configured repository origin")?;
        }
        Ok(())
    }

    pub fn ensure_clean(&mut self, root: &Path, allow_dirty: bool) -> Result<()> {
        if allow_dirty {
            return Ok(());
        }
        let status = self.git_request(
            root,
            ["status", "--porcelain=v1", "--untracked-files=all"],
            None,
        );
        let output = self.run_checked(&status, "inspect repository status")?;
        if !output.stdout.is_empty() {
            bail!("repository is dirty; fleet execution uses committed state only");
        }
        Ok(())
    }

    pub fn fetch_origin(&mut self, root: &Path) -> Result<()> {
        let fetch = self.git_request(root, ["fetch", "--prune", "origin"], None);
        self.run_checked(&fetch, "fetch repository origin")?;
        Ok(())
    }

    pub fn sync_managed(&mut self, root: &Path) -> Result<RepositorySync> {
        self.fetch_origin(root)?;
        let default_ref = self.resolve_remote_default_ref(root)?;
        let checkout = self.git_request(
            root,
            ["checkout", "-B", "master", default_ref.as_str()],
            None,
        );
        self.run_checked(&checkout, "synchronize managed repository checkout")?;

        let head = self.resolve_commit(root, "HEAD")?;
        let remote_ref = format!("refs/remotes/{default_ref}");
        let mut change_base = self.try_resolve_commit(root, &remote_ref)?;
        if change_base.is_none() {
            change_base = self.try_resolve_commit(root, "refs/remotes/origin/master")?;
        }
        Ok(RepositorySync {
            head,
            default_ref,
            change_base,
        })
    }

    pub fn create_detached_worktree(
        &mut self,
        source_root: &Path,
        worktree: &Path,
        target_ref: &str,
    ) -> Result<DetachedWorktree> {
        let commit = self.resolve_commit(source_root, target_ref)?;
        let add = self.git_request(
            source_root,
            [
                OsString::from("worktree"),
                OsString::from("add"),
                OsString::from("--detach"),
                worktree.as_os_str().to_owned(),
                OsString::from(target_ref),
            ],
            None,
        );
        self.run_checked(&add, "create detached execution worktree")?;
        self.prune_worktrees(source_root);
        Ok(DetachedWorktree {
            path: worktree.to_path_buf(),
            commit,
        })
    }

    pub fn remove_worktree(&mut self, source_root: &Path, worktree: &Path) -> Result<()> {
        let remove = self.git_request(
            source_root,
            [
                OsString::from("worktree"),
                OsString::from("remove"),
                OsString::from("--force"),
                worktree.as_os_str().to_owned(),
            ],
            None,
        );
        self.run_checked(&remove, "remove execution worktree")?;
        self.prune_worktrees(source_root);
        Ok(())
    }

    pub fn capture_staged_patch(&mut self, root: &Path) -> Result<Option<StagedPatchCapture>> {
        let quiet = self.run_git(
            root,
            ["diff", "--cached", "--quiet", "--no-ext-diff", "--"],
            None,
        )?;
        match quiet.status {
            0 => return Ok(None),
            1 => {}
            status => bail!("inspect staged changes failed with status {status}"),
        }

        let diff = self.git_request(
            root,
            [
                "diff",
                "--cached",
                "--binary",
                "--full-index",
                "--no-ext-diff",
                "--",
            ],
            None,
        );
        let output = self.run_checked(&diff, "capture staged binary patch")?;
        if output.stdout.is_empty() {
            bail!("staged patch was unexpectedly empty");
        }
        let base = self.resolve_commit(root, "HEAD")?;
        let ignored = self.inspect_ignored_changes(root)?;
        Ok(Some(StagedPatchCapture {
            patch: StagedPatch {
                base,
                bytes: output.stdout,
            },
            ignored,
        }))
    }

    pub fn validate_staged_base(
        &mut self,
        root: &Path,
        target_ref: &str,
        base: &CommitSha,
    ) -> Result<CommitSha> {
        let target = self.resolve_commit(root, target_ref)?;
        let resolved_base = self.resolve_commit(root, base.as_str())?;
        if target != resolved_base {
            bail!(
                "staged patch is based on {}, but requested target is {}",
                resolved_base.as_str(),
                target.as_str()
            );
        }
        Ok(target)
    }

    pub fn apply_staged_patch(&mut self, worktree: &Path, patch: &StagedPatch) -> Result<()> {
        let apply = self.git_request(
            worktree,
            ["apply", "--index", "--binary", "--allow-empty", "-"],
            Some(patch.bytes.clone()),
        );
        self.run_checked(&apply, "apply staged patch to execution worktree")?;
        Ok(())
    }

    fn inspect_ignored_changes(&mut self, root: &Path) -> Result<IgnoredChanges> {
        let tracked = self.run_git(root, ["diff", "--quiet", "--no-ext-diff", "--"], None)?;
        if !matches!(tracked.status, 0 | 1) {
            bail!(
                "inspect unstaged tracked changes failed with status {}",
                tracked.status
            );
        }
        let untracked =
            self.git_request(root, ["ls-files", "--others", "--exclude-standard"], None);
        let untracked = self.run_checked(&untracked, "inspect untracked repository files")?;
        Ok(IgnoredChanges {
            unstaged_tracked: tracked.status == 1,
            untracked: !untracked.stdout.is_empty(),
        })
    }

    fn resolve_remote_default_ref(&mut self, root: &Path) -> Result<String> {
        let symbolic_args = [
            "symbolic-ref",
            "--quiet",
            "--short",
            "refs/remotes/origin/HEAD",
        ];
        let mut symbolic = self.run_git(root, symbolic_args, None)?;
        if !symbolic.succeeded() {
            let set_head = self.git_request(root, ["remote", "set-head", "origin", "--auto"], None);
            let _ = self.runner.run(&set_head);
            symbolic = self.run_git(root, symbolic_args, None)?;
        }
        if symbolic.succeeded() {
            let default_ref = output_text(&symbolic.stdout, "remote default reference")?
                .trim()
                .to_owned();
            if !default_ref.is_empty() {
                return Ok(default_ref);
            }
        }
        Ok("origin/master".to_owned())
    }

    fn resolve_commit(&mut self, root: &Path, target: &str) -> Result<CommitSha> {
        self.try_resolve_commit(root, target)?
            .with_context(|| format!("requested repository target is unavailable: {target}"))
    }

    fn try_resolve_commit(&mut self, root: &Path, target: &str) -> Result<Option<CommitSha>> {
        let commitish = format!("{target}^{{commit}}");
        let output = self.run_git(root, ["rev-parse", "--verify", commitish.as_str()], None)?;
        if !output.succeeded() {
            return Ok(None);
        }
        let sha = output_text(&output.stdout, "resolved repository commit")?;
        Ok(Some(CommitSha::parse(sha.trim())?))
    }

    fn prune_worktrees(&mut self, source_root: &Path) {
        let prune = self.git_request(source_root, ["worktree", "prune"], None);
        let _ = self.runner.run(&prune);
    }

    fn git_request<I, S>(&self, root: &Path, args: I, stdin: Option<Vec<u8>>) -> CommandRequest
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        let mut request = CommandRequest::new(&self.git_program)
            .args(args)
            .current_dir(root)
            .environment(self.environment.clone());
        if let Some(stdin) = stdin {
            request = request.stdin(stdin);
        }
        request
    }

    fn run_git<I, S>(
        &mut self,
        root: &Path,
        args: I,
        stdin: Option<Vec<u8>>,
    ) -> Result<CommandOutput>
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        let request = self.git_request(root, args, stdin);
        self.runner.run(&request)
    }

    fn run_checked(&mut self, request: &CommandRequest, context: &str) -> Result<CommandOutput> {
        let output = self.runner.run(request)?;
        if !output.succeeded() {
            bail!(
                "{context} failed with status {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        Ok(output)
    }
}

fn output_text<'a>(output: &'a [u8], description: &str) -> Result<&'a str> {
    std::str::from_utf8(output).with_context(|| format!("{description} was not UTF-8"))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IgnoredChanges {
    pub unstaged_tracked: bool,
    pub untracked: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StagedPatch {
    pub base: CommitSha,
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StagedPatchCapture {
    pub patch: StagedPatch,
    pub ignored: IgnoredChanges,
}

pub fn read_staged_patch_stdin(mut reader: impl Read, base: CommitSha) -> Result<StagedPatch> {
    let mut bytes = Vec::new();
    reader
        .read_to_end(&mut bytes)
        .context("read staged patch from stdin")?;
    if bytes.is_empty() {
        bail!("dirty-staged patch payload was empty");
    }
    Ok(StagedPatch { base, bytes })
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum CiCleanMode {
    #[default]
    Auto,
    All,
}

impl CiCleanMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::All => "all",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CiHostSelection {
    Singular(String),
    Selectors(String),
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum CiLogFormat {
    #[default]
    Auto,
    GithubActions,
    Plain,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DirtyForwarding {
    Clean,
    AllowDirty,
    Staged { patch: StagedPatch },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CiTriggerRequest {
    pub action: String,
    pub sha: Option<CommitSha>,
    pub clean_mode: CiCleanMode,
    pub group: Option<String>,
    pub hosts: Option<CiHostSelection>,
    pub nix_config: Option<String>,
    pub log_format: CiLogFormat,
    pub dry_run: bool,
    pub force: bool,
    pub restart_managed: bool,
    pub control_plane_first: bool,
    pub verify: bool,
    pub dirty: DirtyForwarding,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CiTriggerPlan {
    pub argv: Vec<String>,
    pub encoded_argv: String,
    pub remote_command: String,
    pub stdin: Option<Vec<u8>>,
}

pub fn plan_ci_trigger(request: &CiTriggerRequest) -> Result<CiTriggerPlan> {
    validate_ci_action(&request.action)?;
    let clean = request.action == "clean";
    if clean && !matches!(request.dirty, DirtyForwarding::Clean) {
        bail!("clean CI trigger does not accept dirty repository forwarding");
    }

    let mut argv = if clean {
        vec![
            request.action.clone(),
            "--no-override".to_owned(),
            "--clean".to_owned(),
            request.clean_mode.as_str().to_owned(),
        ]
    } else {
        let sha = request
            .sha
            .as_ref()
            .context("non-clean CI trigger requires a commit SHA")?;
        vec![
            request.action.clone(),
            "--sha".to_owned(),
            sha.as_str().to_owned(),
            "--no-override".to_owned(),
        ]
    };

    if !clean {
        if let Some(group) = request.group.as_deref() {
            require_nonempty(group, "CI trigger group")?;
            argv.extend(["--group".to_owned(), group.to_owned()]);
        }
        if let Some(hosts) = &request.hosts {
            match hosts {
                CiHostSelection::Singular(host) => {
                    require_nonempty(host, "CI trigger host")?;
                    argv.extend(["--host".to_owned(), host.clone()]);
                }
                CiHostSelection::Selectors(hosts) => {
                    require_nonempty(hosts, "CI trigger host selectors")?;
                    argv.extend(["--hosts".to_owned(), hosts.clone()]);
                }
            }
        } else if request.group.is_none() {
            bail!("non-clean CI trigger requires a host or group selection");
        }
        if let Some(nix_config) = request.nix_config.as_deref() {
            require_nonempty(nix_config, "CI trigger Nix configuration")?;
            argv.extend(["--nix-config".to_owned(), nix_config.to_owned()]);
        }
    }

    match request.log_format {
        CiLogFormat::Auto => {}
        CiLogFormat::GithubActions => {
            argv.extend(["--log-format".to_owned(), "gh".to_owned()]);
        }
        CiLogFormat::Plain => {
            argv.extend(["--log-format".to_owned(), "plain".to_owned()]);
        }
    }
    append_flag(&mut argv, request.dry_run, "--dry");
    append_flag(&mut argv, request.force, "--force");
    append_flag(&mut argv, request.restart_managed, "--restart-managed");
    append_flag(
        &mut argv,
        request.control_plane_first,
        "--control-plane-first",
    );
    append_flag(&mut argv, !request.verify, "--no-verify");

    let stdin = match &request.dirty {
        DirtyForwarding::Clean => None,
        DirtyForwarding::AllowDirty => {
            argv.push("--dirty".to_owned());
            None
        }
        DirtyForwarding::Staged { patch } => {
            let sha = request
                .sha
                .as_ref()
                .context("dirty-staged CI trigger requires a commit SHA")?;
            if !same_revision_prefix(sha, &patch.base) {
                bail!(
                    "dirty-staged patch base {} does not match trigger SHA {}",
                    patch.base.as_str(),
                    sha.as_str()
                );
            }
            if patch.bytes.is_empty() {
                bail!("dirty-staged CI trigger patch was empty");
            }
            argv.extend([
                "--dirty-staged".to_owned(),
                "--dirty-staged-patch-stdin".to_owned(),
                "--dirty-staged-base".to_owned(),
                patch.base.as_str().to_owned(),
            ]);
            Some(patch.bytes.clone())
        }
    };

    let encoded_argv = encode_argv(&argv);
    let remote_command = format!("{SSH_ARGV_PREFIX} {encoded_argv}");
    Ok(CiTriggerPlan {
        argv,
        encoded_argv,
        remote_command,
        stdin,
    })
}

fn validate_ci_action(action: &str) -> Result<()> {
    let supported = matches!(
        action,
        "run"
            | "deploy"
            | "build"
            | "tf"
            | "tf-dns"
            | "tf-platform"
            | "tf-apps"
            | "check-bootstrap"
            | "clean"
    ) || action
        .strip_prefix("tf/")
        .is_some_and(|project| !project.is_empty() && safe_component(project));
    if !supported {
        bail!("unsupported action for CI trigger: {action}");
    }
    Ok(())
}

fn safe_component(value: &str) -> bool {
    value
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn require_nonempty(value: &str, description: &str) -> Result<()> {
    if value.is_empty() {
        bail!("{description} cannot be empty");
    }
    Ok(())
}

fn append_flag(argv: &mut Vec<String>, enabled: bool, flag: &str) {
    if enabled {
        argv.push(flag.to_owned());
    }
}

fn same_revision_prefix(left: &CommitSha, right: &CommitSha) -> bool {
    left.as_str().starts_with(right.as_str()) || right.as_str().starts_with(left.as_str())
}

pub fn encode_argv(argv: &[String]) -> String {
    let mut payload = Vec::new();
    for argument in argv {
        payload.extend_from_slice(argument.as_bytes());
        payload.push(0);
    }
    BASE64.encode(payload)
}

pub fn decode_argv(encoded: &str) -> Result<Vec<String>> {
    let mut payload = BASE64
        .decode(encoded)
        .context("decode base64 argv payload")?;
    if payload.is_empty() {
        return Ok(Vec::new());
    }
    if payload.last() != Some(&0) {
        bail!("encoded argv payload is not NUL terminated");
    }
    payload.pop();
    payload
        .split(|byte| *byte == 0)
        .map(|argument| {
            String::from_utf8(argument.to_vec()).context("encoded argv contains non-UTF-8 data")
        })
        .collect()
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstalledBinary(PathBuf);

impl InstalledBinary {
    pub fn new(path: impl Into<PathBuf>) -> Result<Self> {
        let path = path.into();
        if !is_normal_absolute_path(&path) {
            bail!("installed fleet binary path must be normalized and absolute");
        }
        Ok(Self(path))
    }

    pub fn as_path(&self) -> &Path {
        &self.0
    }
}

pub fn plan_installed_execution(
    binary: &InstalledBinary,
    worktree: &Path,
    argv: &[String],
) -> Result<CommandRequest> {
    if !is_normal_absolute_path(worktree) {
        bail!("execution worktree path must be normalized and absolute");
    }
    if binary.as_path().starts_with(worktree) {
        bail!("refusing repository-local executable from execution worktree");
    }
    Ok(CommandRequest::new(binary.as_path())
        .args(argv.iter().map(OsString::from))
        .current_dir(worktree))
}

fn is_normal_absolute_path(path: &Path) -> bool {
    path.is_absolute()
        && path
            .components()
            .all(|component| matches!(component, Component::RootDir | Component::Normal(_)))
}
