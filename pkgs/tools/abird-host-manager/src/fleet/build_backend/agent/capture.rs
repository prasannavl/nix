//! Original-worker caller capture. No inventory evaluation, store import,
//! realization, remote execution or caller-state repair in this helper.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use abird_host_agent::build_executor::{
    native_intent::{CaptureInput, Material},
    process::{Limits, Runner},
};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

mod checkout;
mod config;
mod contexts;
mod git;
mod image;
use crate::fleet::preparation::source_scope as offline;
mod preflight;
pub mod remote;
pub use checkout::run as checkout;
use git::capture_git;

use crate::fleet::build_backend::agent::controller::{
    CapturedSource, InvocationRecord, Locations, Submission,
};
use crate::fleet::build_backend::agent::run::Run;
use crate::fleet::preparation::{
    InventoryContext,
    repository::{RepositoryCommands, SearchView},
};
use abird_host_agent::build_executor::preparation::search_path::SearchPath;

/// Private original environment, never source data-lane or artifact payload.
/// Admission binds its digest as part of PendingCapture, not just selected keys.
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Environment {
    values: BTreeMap<String, String>,
    uid: u32,
    gid: u32,
    groups: Vec<u32>,
    umask: u32,
    /// Git default profile files the caller did not override, observed in the
    /// original namespace before admission: (dev, ino), or `None` if absent.
    /// The capture namespace must agree; it cannot prove absence alone.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    defaults: BTreeMap<PathBuf, Option<(u64, u64)>>,
}

/// Installed Git's compiled system configuration (no runtime prefix).
const SYSTEM_GIT_CONFIG: &str = "/etc/gitconfig";

impl Environment {
    pub fn current() -> Result<Self> {
        let values = std::env::vars_os()
            .map(|(name, value)| {
                Ok((
                    name.into_string()
                        .map_err(|_| anyhow::anyhow!("non-UTF8 caller environment"))?,
                    value
                        .into_string()
                        .map_err(|_| anyhow::anyhow!("non-UTF8 caller environment"))?,
                ))
            })
            .collect::<Result<_>>()?;
        Self::observed(
            values,
            unsafe { libc::geteuid() },
            unsafe { libc::getegid() },
            groups()?,
            current_umask()?,
        )
    }

    fn observed(
        values: BTreeMap<String, String>,
        uid: u32,
        gid: u32,
        groups: Vec<u32>,
        umask: u32,
    ) -> Result<Self> {
        let mut value = Self {
            values,
            uid,
            gid,
            groups,
            umask,
            defaults: BTreeMap::new(),
        };
        value.validate()?;
        // Unsupported shapes (e.g. relative HOME) are rejected by `supported`.
        if let Ok(paths) = value.default_paths() {
            for path in paths {
                let identity = observe_default(&path)?;
                value.defaults.insert(path, identity);
            }
        }
        Ok(value)
    }

    /// Defaults used by the CLI and native accessor, including auxiliary data.
    /// Observe before admission so a masked source namespace cannot manufacture
    /// global-attribute or ignore-file absence.
    fn default_paths(&self) -> Result<Vec<PathBuf>> {
        let mut paths = Vec::new();
        if !self.values.contains_key("GIT_CONFIG_NOSYSTEM") {
            paths.push(PathBuf::from(SYSTEM_GIT_CONFIG));
        }
        // Upstream libgit2 reads HOME/XDG globals even when the Git CLI has an
        // explicit GIT_CONFIG_GLOBAL. Capture both native consumers' files.
        {
            let home = Path::new(self.values.get("HOME").context("caller HOME missing")?);
            ensure!(home.is_absolute(), "caller HOME must be absolute");
            let xdg = self
                .values
                .get("XDG_CONFIG_HOME")
                .filter(|value| !value.is_empty())
                .map_or_else(|| home.join(".config"), PathBuf::from);
            for name in ["config", "attributes", "ignore"] {
                paths.push(xdg.join("git").join(name));
            }
            paths.push(home.join(".gitconfig"));
        }
        Ok(paths)
    }

    /// Global profile roots: the explicit file, or the present defaults.
    pub(super) fn global_roots(&self) -> Result<Vec<PathBuf>> {
        let mut paths = self
            .defaults
            .iter()
            .filter(|(path, identity)| {
                identity.is_some()
                    && !path.ends_with("git/attributes")
                    && !path.ends_with("git/ignore")
            })
            .map(|(path, _)| path.clone())
            .collect::<Vec<_>>();
        if let Some(path) = self.values.get("GIT_CONFIG_GLOBAL") {
            paths.push(PathBuf::from(path));
        }
        paths.sort();
        paths.dedup();
        Ok(paths)
    }

    /// This namespace observes the same default files as the original one.
    pub(super) fn check_defaults(&self) -> Result<()> {
        for (path, expected) in &self.defaults {
            ensure!(
                observe_default(path)? == *expected,
                "caller default Git profile differs from its original namespace"
            );
        }
        Ok(())
    }

    pub(crate) fn validate(&self) -> Result<()> {
        ensure!(
            self.uid > 0
                && self.gid > 0
                && self.umask <= 0o777
                && self.groups.len() <= 64
                && self.groups.windows(2).all(|pair| pair[0] < pair[1]),
            "invalid caller credential context"
        );
        ensure!(
            self.values.len() <= 256
                && self.defaults.len() <= 5
                && serde_json::to_vec(self)?.len() <= 64 * 1024
                && self.values.iter().all(|(key, value)| !key.is_empty()
                    && key
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
                    && !value.contains('\0')),
            "caller environment exceeds bound or is invalid"
        );
        Ok(())
    }

    /// Pre-admission check of the supported caller profile (explicit or
    /// discovered default), so an unsupported one rejects before admitted work.
    pub(crate) fn supported(&self) -> Result<()> {
        self.validate()?;
        ensure!(
            self.values
                .get("GIT_CONFIG_GLOBAL")
                .is_none_or(|path| Path::new(path).is_absolute())
                && abird_host_agent::build_executor::native_intent::CALLER_GIT_PROFILE
                    .iter()
                    .all(|(key, value)| self.values.get(*key).is_none_or(|v| v == value)),
            "agent strategy caller Git profile: GIT_CONFIG_GLOBAL must be absolute; \
             GIT_CONFIG_NOSYSTEM=1 GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 if set"
        );
        let expected = self.default_paths()?;
        ensure!(
            self.defaults.len() == expected.len()
                && expected.iter().all(|path| self.defaults.contains_key(path)),
            "caller default Git profile was not observed"
        );
        ensure!(
            self.values
                .get("XDG_CONFIG_HOME")
                .is_none_or(|value| value.is_empty() || Path::new(value).is_absolute()),
            "caller XDG_CONFIG_HOME must be absolute"
        );
        ensure!(
            !self.values.keys().any(|key| key.starts_with("LD_")
                || key.starts_with("DYLD_")
                || matches!(
                    key.as_str(),
                    "BASH_ENV" | "ENV" | "SSH_AUTH_SOCK" | "SSH_AGENT_PID"
                )),
            "caller loader/credential context requires binding"
        );
        ensure!(
            !self.values.keys().any(|key| key.starts_with("GIT_")
                && !matches!(
                    key.as_str(),
                    "GIT_CONFIG_GLOBAL"
                        | "GIT_CONFIG_NOSYSTEM"
                        | "GIT_OPTIONAL_LOCKS"
                        | "GIT_TERMINAL_PROMPT"
                )),
            "caller Git context requires binding"
        );
        ensure!(
            self.values
                .get("NIXBOT_EXECUTOR_KIND")
                .is_none_or(|kind| kind == "developer")
                && !self.values.contains_key("NIXBOT_REPO_WORKTREE_ROOT")
                && !self.values.contains_key("NIXBOT_REPO_ROOT"),
            "managed/inherited capture requires its admitted repository planner"
        );
        Ok(())
    }

    fn native_system_configuration(&self) -> bool {
        self.defaults
            .get(Path::new(SYSTEM_GIT_CONFIG))
            .is_some_and(Option::is_some)
    }

    fn installed(&self) -> Result<Vec<(OsString, OsString)>> {
        self.supported()?;
        ensure!(
            self.uid == unsafe { libc::geteuid() }
                && self.gid == unsafe { libc::getegid() }
                && self.groups == groups()?,
            "caller/installed credentials differ"
        );
        // Do not silently normalize a caller profile onto the worker profile.
        // Unset fixed keys take the helper value: lock/prompt behavior only,
        // and NOSYSTEM only with system configuration observed absent.
        let mut values = self.values.clone();
        for (key, value) in abird_host_agent::build_executor::native_intent::CALLER_GIT_PROFILE {
            if key != "GIT_CONFIG_NOSYSTEM"
                || self
                    .defaults
                    .get(Path::new(SYSTEM_GIT_CONFIG))
                    .is_none_or(Option::is_none)
            {
                values
                    .entry(key.to_owned())
                    .or_insert_with(|| value.to_owned());
            }
        }
        for key in std::iter::once("HOME").chain(
            abird_host_agent::build_executor::native_intent::CALLER_GIT_PROFILE
                .iter()
                .map(|(key, _)| *key)
                .filter(|key| *key != "GIT_CONFIG_NOSYSTEM"),
        ) {
            ensure!(
                values.get(key) == std::env::var(key).ok().as_ref(),
                "caller/installed Git context differs"
            );
        }
        Ok(values
            .into_iter()
            .map(|(key, value)| (key.into(), value.into()))
            .collect())
    }
}

/// Identity as Git would open it (symlinks followed); absence only for a
/// missing path, never for unreadable or non-regular files.
fn observe_default(path: &Path) -> Result<Option<(u64, u64)>> {
    use std::os::unix::fs::MetadataExt;
    match std::fs::metadata(path) {
        Ok(metadata) => {
            ensure!(
                metadata.is_file(),
                "caller default Git profile is not a regular file"
            );
            Ok(Some((metadata.dev(), metadata.ino())))
        }
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
            ) =>
        {
            Ok(None)
        }
        Err(error) => Err(error.into()),
    }
}

fn current_umask() -> Result<u32> {
    use std::io::Read;
    let mut status = String::new();
    std::fs::File::open("/proc/self/status")?
        .take(16 * 1024 + 1)
        .read_to_string(&mut status)?;
    ensure!(status.len() <= 16 * 1024, "caller status exceeds bound");
    let mut values = status
        .lines()
        .filter_map(|line| line.strip_prefix("Umask:"));
    let value = u32::from_str_radix(values.next().context("caller umask unavailable")?.trim(), 8)?;
    ensure!(
        values.next().is_none() && value <= 0o777,
        "invalid caller umask"
    );
    Ok(value)
}

fn groups() -> Result<Vec<u32>> {
    let mut groups = [0u32; 64];
    let count = unsafe { libc::getgroups(groups.len() as libc::c_int, groups.as_mut_ptr()) };
    ensure!(count >= 0, "caller groups unavailable or exceed bound");
    let mut groups = groups[..usize::try_from(count)?].to_vec();
    groups.sort_unstable();
    groups.dedup();
    Ok(groups)
}

pub fn run(input: CaptureInput, git: PathBuf, nar: PathBuf) -> Result<Material> {
    let attempt = input.intent.attempt_id()?;
    let manifest = Run::inspect(&input.intent.run_id)?;
    let child = manifest
        .children
        .get(&attempt)
        .context("capture child missing")?;
    child.require_local_capture(&input.intent, &input.delivery_digest)?;
    let pending = child
        .pending_capture()
        .context("capture caller context missing")?;
    // Admission binds pending bytes before the irreversible read scope. The
    // observer's replaceable manifest is neither source authority nor liveness.
    captured(input, git, nar, pending)
}

pub(super) fn captured(
    input: CaptureInput,
    git: PathBuf,
    nar: PathBuf,
    pending: &crate::fleet::build_backend::agent::controller::PendingCapture,
) -> Result<Material> {
    input.validate()?;
    abird_host_agent::build_executor::workload::require_wrapper_placement()?;
    let uid = unsafe { libc::geteuid() };
    ensure!(
        uid > 0
            && git.starts_with("/nix/store")
            && git.file_name().is_some_and(|name| name == "git"),
        "invalid capture helper identity/executable"
    );
    abird_host_agent::build_executor::daemon::trusted_path(&nar)?;
    ensure!(
        nar.starts_with("/nix/store") && nar.file_name().is_some_and(|name| name == "nix-store"),
        "invalid capture NAR executable"
    );
    let deadline = Instant::now()
        .checked_add(Duration::from_millis(input.budget_millis))
        .context("capture deadline overflow")?;
    pending.validate(&input.intent)?;
    let profile = pending
        .bootstrap
        .as_ref()
        .context("capture bootstrap missing")?
        .load()?;
    ensure!(
        profile.local_control == (input.intent.controller == input.intent.builder)
            && profile.controller == input.intent.controller
            && profile.repository_id == input.intent.repository_id
            && profile.matches_admitted_nix(&input.intent.nix)
            && profile.controller_service == input.intent.controller_service,
        "capture bootstrap/admission differs"
    );
    let caller_environment = pending
        .environment
        .as_ref()
        .context("capture environment missing")?;
    for key in ["ABIRD_HOST_MANAGER_GIT", "NIXBOT_GIT"] {
        ensure!(
            caller_environment
                .values
                .get(key)
                .is_none_or(|value| Path::new(value) == git),
            "caller Git executable differs"
        );
    }
    let environment = caller_environment.installed()?;
    let mut window =
        abird_host_agent::build_executor::preparation::git_context::window::ReadWindow::begin(
            uid,
            input.limits,
            deadline,
        )?;
    let search_path = SearchPath::capture_with_window(
        caller_environment
            .values
            .get("PATH")
            .context("caller PATH missing")?,
        &mut window,
        deadline,
    )?;
    if !["ABIRD_HOST_MANAGER_GIT", "NIXBOT_GIT"]
        .iter()
        .any(|key| caller_environment.values.contains_key(*key))
    {
        search_path.require_program("git", &git, deadline)?;
    }
    let invocation = &pending.invocation;
    let live = invocation.action == crate::fleet::cli::Action::DevBuild;
    // These need the admitted managed/CI/snapshot adapters. Never substitute a
    // local checkout or a path snapshot for their native source semantics.
    ensure!(
        !invocation.options.ci_trigger
            && invocation.options.repo_path.is_none()
            && invocation.options.repo_url.is_none()
            && !invocation.options.dirty_staged_patch_stdin
            && !invocation.options.use_repo_script,
        "capture requires an admitted managed/CI/reexecution adapter"
    );
    let cwd = std::fs::canonicalize(&pending.cwd)?;
    ensure!(
        cwd == pending.cwd && input.roots.iter().any(|root| cwd.starts_with(root)),
        "capture cwd outside installed roots"
    );
    for root in &input.roots {
        ensure!(
            std::fs::canonicalize(root)? == *root,
            "capture root redirected"
        );
    }
    let mut runner = Runner::new(
        uid,
        Limits {
            stdin: 4 * 1024 * 1024,
            stdout: 16 * 1024 * 1024,
            stderr: 128 * 1024,
        },
        deadline,
    )?
    .with_umask(caller_environment.umask)?;
    let runtime = offline::Runtime::load(&input.runtime_closure, input.limits, deadline)?;
    let mut configuration = config::global(
        caller_environment,
        &git,
        &mut runner,
        &mut window,
        deadline,
        &runtime,
    )?;
    let candidate = preflight::prepare(
        &input,
        &cwd,
        caller_environment,
        &mut configuration,
        &git,
        &mut runner,
        &mut window,
        &runtime,
        deadline,
        invocation,
    )?;
    let source_root =
        RepositoryCommands::new(git.clone(), cwd.clone(), vec![], environment.clone())?
            .bind_caller(
                search_path.clone(),
                configuration.clone(),
                SearchView::Original,
                deadline,
            )?
            .with_profile_window(&mut runner, &window, |manager| {
                manager.repository_root(&cwd)
            })?;
    configuration.check_live(deadline)?;
    ensure!(
        source_root == candidate.worktree
            && source_root == std::fs::canonicalize(&source_root)?
            && input.roots.iter().any(|root| source_root.starts_with(root)),
        "capture repository outside installed roots"
    );
    if std::fs::symlink_metadata(source_root.join(".git"))?.is_file()
        && !configuration.contains(&source_root.join(".git"))
    {
        configuration.capture(&source_root.join(".git"), &mut window, deadline)?;
    }
    let layout = git::layout(&source_root, &git, &environment, &mut runner, &window)?;
    ensure!(
        layout == candidate,
        "native Git layout differs from held candidate"
    );
    window.require_path(&layout.common)?;
    config::local(
        &mut configuration,
        &layout.common,
        &layout.git_dir,
        caller_environment,
        &git,
        &mut runner,
        &mut window,
        deadline,
        &runtime,
    )?;
    config::auxiliary(
        &mut configuration,
        &source_root,
        caller_environment,
        &git,
        &mut runner,
        &mut window,
        deadline,
        &input.roots,
    )?;
    config::require_filters(&source_root, &git, &environment, &mut runner, &window)?;
    let mut pinned = crate::fleet::runtime::pin_inventory_input_at(
        invocation,
        &source_root,
        crate::fleet::inventory_overlay::OverlayPolicy::Allowed,
        &cwd,
        false,
    )?;
    pinned.source_config = contexts::normalize(&pinned.source_config)?;
    pinned.overlay = pinned
        .overlay
        .as_deref()
        .map(contexts::normalize)
        .transpose()?;
    for path in std::iter::once(&pinned.source_config).chain(pinned.overlay.iter()) {
        ensure!(
            input.roots.iter().any(|root| path.starts_with(root)),
            "inventory context outside declared capture roots"
        );
    }
    let dependency = crate::fleet::runtime::find_repository_root(
        pinned
            .source_config
            .parent()
            .context("inventory parent missing")?,
    )?;
    let commands = RepositoryCommands::new(
        git.clone(),
        source_root.clone(),
        vec![],
        environment.clone(),
    )?
    .bind_caller(
        search_path.clone(),
        configuration.clone(),
        SearchView::Original,
        deadline,
    )?;
    let (revision, patch, repository_config) =
        commands.with_git_window_at(&mut runner, &window, &layout.common, |manager| {
            let patch = if invocation.options.dirty_staged && !live {
                manager
                    .capture_staged_patch(&source_root)?
                    .map(|capture| capture.patch)
            } else {
                None
            };
            if !live {
                manager.ensure_clean(&source_root, invocation.options.dirty)?;
            }
            let revision = manager.resolve_commit(
                &source_root,
                if live {
                    "HEAD"
                } else {
                    invocation.options.sha.as_deref().unwrap_or("HEAD")
                },
            )?;
            if let Some(patch) = &patch {
                ensure!(
                    patch.base == revision,
                    "captured staged base differs from resolved target"
                );
            }
            let index = if patch.is_some() {
                Some(manager.index_entries(&source_root)?)
            } else {
                None
            };
            let mut present = |path: &Path| -> Result<bool> {
                let relative = path
                    .strip_prefix(&source_root)
                    .context("external native inventory context")?;
                match &index {
                    Some(index) => index.regular_file(relative.as_os_str().as_bytes()),
                    None => manager.tracked_regular_file(&source_root, &revision, relative),
                }
            };
            if !live && dependency == source_root && pinned.source_config.starts_with(&source_root)
            {
                ensure!(
                    present(&pinned.source_config)?,
                    "captured inventory is absent from selected Git source"
                );
            }
            let repository_config = if live {
                source_root.join("config/default.nix").is_file()
            } else {
                present(&source_root.join("config/default.nix"))?
            }
            .then(|| source_root.join("config"));
            Ok((revision, patch, repository_config))
        })?;
    runner.check_ready()?;
    let mut snapshots = BTreeMap::new();
    let mut external = BTreeMap::new();
    let mut native_roots = BTreeMap::new();
    let caller_digest = input
        .intent
        .caller_digest
        .as_deref()
        .context("caller digest missing")?;
    let repository_config = if dependency != source_root {
        let extra_layout = git::layout(&dependency, &git, &environment, &mut runner, &window)?;
        ensure!(
            input
                .roots
                .iter()
                .any(|root| extra_layout.common.starts_with(root)),
            "external Git administration outside captured roots"
        );
        // The trusted preflight already held this candidate administration and
        // its complete profile before any caller-context Git command.
        config::local(
            &mut configuration,
            &extra_layout.common,
            &extra_layout.git_dir,
            caller_environment,
            &git,
            &mut runner,
            &mut window,
            deadline,
            &runtime,
        )?;
        config::auxiliary(
            &mut configuration,
            &dependency,
            caller_environment,
            &git,
            &mut runner,
            &mut window,
            deadline,
            &input.roots,
        )?;
        config::require_filters(&dependency, &git, &environment, &mut runner, &window)?;
        let commands =
            RepositoryCommands::new(git.clone(), dependency.clone(), vec![], environment.clone())?
                .bind_caller(
                    search_path.clone(),
                    configuration.clone(),
                    SearchView::Original,
                    deadline,
                )?;
        let revision = commands.with_profile_window(&mut runner, &window, |manager| {
            manager.resolve_commit(&dependency, "HEAD")
        })?;
        let scratch = tempfile::Builder::new()
            .prefix("owned-native-")
            .tempdir_in("/tmp")?;
        let root = image::capture(
            &extra_layout,
            revision.as_str().to_owned(),
            &scratch.path().join("image"),
            &git,
            &nar,
            &input.nar_configuration,
            &environment,
            input.limits,
            deadline,
            &mut window,
            caller_digest,
        )?;
        let hash = root.image.nar_digest.clone();
        external.insert(
            dependency.clone(),
            abird_host_agent::build_executor::context::InputLocation {
                tree: abird_host_agent::build_executor::context::InputTree::Git {
                    context_digest: hash.clone(),
                },
                relative: String::new(),
            },
        );
        native_roots.insert(hash, root);
        dependency
            .join("config/default.nix")
            .is_file()
            .then(|| dependency.join("config"))
    } else {
        repository_config
    };
    let mut data = Vec::new();
    if live || dependency != source_root {
        data.push((pinned.source_config.clone(), dependency.clone(), false));
    }
    if let Some(overlay) = &pinned.overlay {
        let parent = overlay.parent().context("overlay parent missing")?;
        let root = crate::fleet::runtime::find_repository_root(parent)
            .unwrap_or_else(|_| parent.to_owned());
        data.push((overlay.clone(), root, false));
    }
    if (live || dependency != source_root)
        && let Some(config) = &repository_config
    {
        data.push((config.join("default.nix"), dependency.clone(), true));
    }
    for (file, root, directory) in data {
        let (hash, nar_bytes, relative) = contexts::snapshot(
            &root,
            &file,
            &git,
            &nar,
            &input.nar_configuration,
            &environment,
            &mut runner,
            &mut window,
            input.limits,
            deadline,
        )?;
        let relative = if directory {
            Path::new(&relative)
                .parent()
                .context("config parent missing")?
                .to_str()
                .context("non-UTF8 config")?
                .to_owned()
        } else {
            relative
        };
        external.insert(
            if directory {
                file.parent().unwrap().to_owned()
            } else {
                file
            },
            abird_host_agent::build_executor::context::InputLocation {
                tree: abird_host_agent::build_executor::context::InputTree::Snapshot {
                    nar_digest: hash.clone(),
                },
                relative,
            },
        );
        snapshots.insert(hash, nar_bytes);
    }
    // One caller pathname can play two roles: base rebases into the selected
    // checkout while an explicitly identical overlay still reads caller bytes.
    let selected_inventory = if !live && dependency == source_root {
        Some(
            abird_host_agent::build_executor::context::InputLocation::source(
                pinned
                    .source_config
                    .strip_prefix(&source_root)?
                    .to_str()
                    .context("non-UTF8 selected inventory")?,
            ),
        )
    } else {
        None
    };
    let mut locations = Locations::from_native(
        &source_root,
        &source_root,
        &InventoryContext {
            config: pinned.source_config,
            overlay: pinned.overlay,
            repository_config,
            dependency_repository: dependency,
        },
        &external,
    )?;
    if let Some(inventory) = selected_inventory {
        locations.inventory = inventory;
    }
    search_path.check_live(deadline)?;
    configuration.check_live(deadline)?;
    let source = if live {
        let scratch = tempfile::Builder::new()
            .prefix("owned-live-")
            .tempdir_in("/tmp")?;
        let primary = image::capture(
            &layout,
            revision.as_str().to_owned(),
            &scratch.path().join("image"),
            &git,
            &nar,
            &input.nar_configuration,
            &environment,
            input.limits,
            deadline,
            &mut window,
            caller_digest,
        )?;
        let hash = primary.image.nar_digest.clone();
        native_roots.insert(hash.clone(), primary);
        let home = PathBuf::from(
            caller_environment
                .values
                .get("HOME")
                .context("caller HOME missing")?,
        );
        let xdg = caller_environment
            .values
            .get("XDG_CONFIG_HOME")
            .filter(|v| !v.is_empty())
            .map_or_else(|| home.join(".config"), PathBuf::from);
        CapturedSource::new(revision, patch, snapshots)?.with_capsule(
            abird_host_agent::build_executor::preparation::capsule::Capsule {
                version: 1,
                caller_digest: caller_digest.to_owned(),
                primary: hash,
                roots: native_roots,
                home,
                xdg_config_home: xdg,
                system_configuration: caller_environment.native_system_configuration(),
                configuration,
            },
        )?
    } else {
        let mut git_context = capture_git(
            &layout.common,
            &nar,
            &input.nar_configuration,
            caller_digest,
            uid,
            input.limits,
            deadline,
            &window,
        )?;
        git_context.layout = Some(layout);
        git_context.external = native_roots;
        git_context.search_path = Some(search_path);
        git_context.configuration = Some(configuration);
        CapturedSource::new(revision, patch, snapshots)?.with_git_context(git_context)?
    };
    let roots = crate::fleet::runtime::runtime_roots(|name| {
        caller_environment.values.get(name).map(OsString::from)
    });
    let checkout = abird_host_agent::build_executor::native_intent::Checkout {
        namespace_root: roots
            .select_namespace(crate::fleet::run_state::RuntimeRootPreference::Auto)?,
        umask: caller_environment.umask,
    };
    checkout.validate()?;
    let caller_repository = if live {
        use std::os::unix::fs::MetadataExt;
        let metadata = std::fs::symlink_metadata(&source_root)?;
        ensure!(
            metadata.is_dir(),
            "original DevBuild directory was redirected"
        );
        Some(
            abird_host_agent::build_executor::native_intent::CallerRepository {
                path: source_root.clone(),
                device: metadata.dev(),
                inode: metadata.ino(),
            },
        )
    } else {
        None
    };
    let record = InvocationRecord {
        caller: invocation.clone(),
        effective: invocation.clone(),
        source_root,
        caller_repository,
        locations,
        ci_argv: None,
        git_context_digest: None,
        checkout: (!live).then_some(checkout),
    };
    runner.check_ready()?;
    let material = Submission::resolve_capture(record, source, &input.intent)?;
    if let Some(capsule) = &material.source.capsule {
        capsule.require_limits(input.limits, &material.source.snapshots)?;
    }
    window.finish()?;
    Ok(material)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn environment(home: &Path, extra: &[(&str, &str)]) -> Environment {
        let mut values = BTreeMap::from([
            ("HOME".to_owned(), home.to_str().unwrap().to_owned()),
            ("GIT_CONFIG_NOSYSTEM".to_owned(), "1".to_owned()),
        ]);
        for (key, value) in extra {
            values.insert((*key).to_owned(), (*value).to_owned());
        }
        Environment::observed(values, 1000, 100, vec![100], 0o022).unwrap()
    }

    #[test]
    fn default_git_profile_binds_original_presence_and_absence() {
        let home = tempfile::tempdir().unwrap();
        let global = home.path().join(".gitconfig");
        std::fs::write(&global, b"[user]\n").unwrap();
        let caller = environment(home.path(), &[]);
        caller.supported().unwrap();
        assert_eq!(
            caller.global_roots().unwrap(),
            std::slice::from_ref(&global)
        );
        assert_eq!(
            caller.defaults[&home.path().join(".config/git/config")],
            None
        );
        caller.check_defaults().unwrap();
        // Another namespace view (new inode, or a newly visible file) differs.
        let original = std::fs::File::open(&global).unwrap();
        std::fs::remove_file(&global).unwrap();
        std::fs::write(&global, b"[user]\n").unwrap();
        assert!(caller.check_defaults().is_err());
        drop(original);
        let caller = environment(home.path(), &[]);
        std::fs::create_dir_all(home.path().join(".config/git")).unwrap();
        std::fs::write(home.path().join(".config/git/config"), b"").unwrap();
        assert!(caller.check_defaults().is_err());
        // Unobserved defaults are never treated as absent.
        let mut unobserved = environment(home.path(), &[]);
        unobserved.defaults.clear();
        assert!(unobserved.supported().is_err());
    }

    #[test]
    fn explicit_profile_and_fixed_git_keys_stay_exact() {
        let home = tempfile::tempdir().unwrap();
        let explicit = home.path().join("profile");
        let caller = environment(
            home.path(),
            &[("GIT_CONFIG_GLOBAL", explicit.to_str().unwrap())],
        );
        caller.supported().unwrap();
        assert_eq!(caller.defaults.len(), 4); // native HOME/XDG defaults still apply
        assert_eq!(caller.global_roots().unwrap(), [explicit]);
        for (key, value) in [
            ("GIT_CONFIG_GLOBAL", "relative"),
            ("GIT_OPTIONAL_LOCKS", "1"),
            ("GIT_CONFIG_NOSYSTEM", "0"),
        ] {
            assert!(
                environment(home.path(), &[(key, value)])
                    .supported()
                    .is_err()
            );
        }
        // A present system profile now joins raw captured native configuration.
        let mut system = environment(home.path(), &[]);
        system.values.remove("GIT_CONFIG_NOSYSTEM");
        system
            .defaults
            .insert(PathBuf::from(SYSTEM_GIT_CONFIG), None);
        system.supported().unwrap();
        assert!(!system.native_system_configuration());
        system
            .defaults
            .insert(PathBuf::from(SYSTEM_GIT_CONFIG), Some((1, 1)));
        system.supported().unwrap();
        assert!(system.native_system_configuration());
        assert!(
            system
                .global_roots()
                .unwrap()
                .contains(&PathBuf::from(SYSTEM_GIT_CONFIG))
        );
    }
}
