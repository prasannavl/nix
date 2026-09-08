//! Invocation-owned runtime state, diagnostics, and local serialization.
//!
//! Runtime trees have one explicit owner and are removed only by
//! [`RunState::normal_cleanup`]. No `Drop` implementation claims crash-safe
//! cleanup: an uncatchable `SIGKILL` requires a separate, durable reaper.

use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{ErrorKind, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use sha2::{Digest, Sha256};
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeRoots {
    pub primary: PathBuf,
    pub fallback: PathBuf,
    pub diagnostic_keep: PathBuf,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeRootPreference {
    Auto,
    Primary,
    Fallback,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunLayout {
    pub run_dir: PathBuf,
    pub diagnostic_dir: PathBuf,
    run_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PhaseItemPaths {
    pub log: PathBuf,
    pub status: PathBuf,
    pub duration: PathBuf,
    pub artifact_dir: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RegistryEntry {
    pub path: PathBuf,
    pub contents: String,
}

impl RunLayout {
    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn phase_item(
        &self,
        phase: &str,
        item: &str,
        subitem: Option<&str>,
    ) -> Result<PhaseItemPaths> {
        validate_safe_name("phase", phase)?;
        validate_safe_name("phase item", item)?;
        let item_name = if phase == "tf" {
            let subitem = subitem.ok_or_else(|| anyhow!("Terraform phase item needs a subitem"))?;
            validate_safe_name("phase subitem", subitem)?;
            format!("{item}.{subitem}")
        } else {
            if subitem.is_some() {
                bail!("phase subitems are supported only for Terraform");
            }
            item.to_owned()
        };
        Ok(PhaseItemPaths {
            log: self
                .diagnostic_dir
                .join(format!("logs.{phase}"))
                .join(format!("{item_name}.log")),
            status: self
                .diagnostic_dir
                .join(format!("status.{phase}"))
                .join(format!("{item_name}.rc")),
            duration: self
                .diagnostic_dir
                .join(format!("status.{phase}"))
                .join(format!("{item_name}.duration")),
            artifact_dir: self.run_dir.join(format!("artifacts.{phase}")),
        })
    }

    pub fn active_deploy(&self, node: &str) -> RegistryEntry {
        RegistryEntry {
            path: self
                .run_dir
                .join("active-deploys")
                .join(format!("{}.deploy", digest_hex(node))),
            contents: format!("{node}\n"),
        }
    }

    pub fn deploy_job(&self, pid: u32, node: &str) -> RegistryEntry {
        RegistryEntry {
            path: self.run_dir.join("deploy-jobs").join(format!("{pid}.job")),
            contents: format!("{node}\n"),
        }
    }

    pub fn activation_marker(&self, node: &str) -> PathBuf {
        self.run_dir
            .join("deploy-jobs")
            .join(format!("{}.activation", digest_hex(node)))
    }

    pub fn pre_switch_rejection_marker(&self, node: &str) -> PathBuf {
        self.run_dir
            .join("deploy-jobs")
            .join(format!("{}.pre-switch-rejected", digest_hex(node)))
    }
}

#[derive(Debug)]
pub struct RunState {
    roots: RuntimeRoots,
    namespace_root: PathBuf,
    layout: RunLayout,
}

impl RunState {
    pub fn allocate(roots: RuntimeRoots, preference: RuntimeRootPreference) -> Result<Self> {
        Self::allocate_with_id(roots, &Uuid::new_v4().simple().to_string(), preference)
    }

    pub fn allocate_with_id(
        roots: RuntimeRoots,
        run_id: &str,
        preference: RuntimeRootPreference,
    ) -> Result<Self> {
        validate_roots(&roots)?;
        validate_safe_name("run ID", run_id)?;
        let namespace_root = choose_namespace_root(&roots, preference);
        ensure_directory(&namespace_root, 0o700)?;

        let run_dir = namespace_root.join(format!("run-{run_id}"));
        create_owned_directory(&run_dir)?;
        let diagnostic_dir = namespace_root.join(format!("diag-{run_id}"));
        if let Err(error) = create_owned_directory(&diagnostic_dir) {
            let _ = remove_tree_no_follow(&run_dir);
            return Err(error);
        }

        let state = Self {
            roots,
            namespace_root,
            layout: RunLayout {
                run_dir,
                diagnostic_dir,
                run_id: run_id.to_owned(),
            },
        };
        if let Err(error) = state.initialize_runtime_directories() {
            let _ = remove_tree_no_follow(&state.layout.diagnostic_dir);
            let _ = remove_tree_no_follow(&state.layout.run_dir);
            return Err(error);
        }
        Ok(state)
    }

    pub fn adopt(roots: RuntimeRoots, run_dir: PathBuf, diagnostic_dir: PathBuf) -> Result<Self> {
        validate_roots(&roots)?;
        let namespace_root = direct_namespace(&roots, &run_dir, "run-")?;
        let run_name = run_dir
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| anyhow!("runtime directory name is not UTF-8"))?;
        let run_id = run_name
            .strip_prefix("run-")
            .ok_or_else(|| anyhow!("runtime directory is missing the run- prefix"))?
            .to_owned();
        validate_safe_name("run ID", &run_id)?;
        let expected_diag = namespace_root.join(format!("diag-{run_id}"));
        if diagnostic_dir != expected_diag {
            bail!(
                "diagnostic directory {} does not match runtime directory {}",
                diagnostic_dir.display(),
                run_dir.display()
            );
        }
        Ok(Self {
            roots,
            namespace_root,
            layout: RunLayout {
                run_dir,
                diagnostic_dir,
                run_id,
            },
        })
    }

    pub fn layout(&self) -> &RunLayout {
        &self.layout
    }

    pub fn line_state(&self, name: &str) -> Result<LineState> {
        validate_safe_name("line state name", name)?;
        Ok(LineState {
            path: self.layout.run_dir.join(name),
            lock_path: self
                .layout
                .run_dir
                .join("state-locks")
                .join(format!("{name}.lock")),
            cache: Vec::new(),
        })
    }

    pub fn normal_cleanup(self, options: CleanupOptions) -> Result<CleanupReport> {
        let mut errors = Vec::new();
        let diagnostics =
            match verify_owned_tree(&self.namespace_root, &self.layout.diagnostic_dir, "diag-")
                .and_then(|()| self.cleanup_diagnostics(options))
            {
                Ok(diagnostics) => diagnostics,
                Err(error) => {
                    errors.push(format!("diagnostic cleanup: {error:#}"));
                    RetentionOutcome::CleanupFailed
                }
            };
        if let Err(error) = verify_owned_tree(&self.namespace_root, &self.layout.run_dir, "run-")
            .and_then(|()| remove_tree_no_follow(&self.layout.run_dir))
        {
            errors.push(format!("runtime cleanup: {error:#}"));
        }
        for root in [
            &self.namespace_root,
            &self.roots.primary,
            &self.roots.fallback,
            &self.roots.diagnostic_keep,
        ] {
            remove_empty_directory(root);
        }
        if !errors.is_empty() {
            bail!("normal cleanup encountered errors: {}", errors.join("; "));
        }
        Ok(CleanupReport { diagnostics })
    }

    fn initialize_runtime_directories(&self) -> Result<()> {
        for relative in [
            "secrets",
            "ssh",
            "target-tmp",
            "stdout",
            "build-results",
            "build-plans",
            "artifacts.tf",
            "active-deploys",
            "deploy-jobs",
            "state-locks",
        ] {
            ensure_directory(&self.layout.run_dir.join(relative), 0o700)?;
        }
        ensure_directory(&self.layout.diagnostic_dir.join("stderr"), 0o700)?;
        for phase in ["tf", "build", "snapshot", "deploy", "rollback", "health"] {
            ensure_directory(
                &self.layout.diagnostic_dir.join(format!("logs.{phase}")),
                0o700,
            )?;
            ensure_directory(
                &self.layout.diagnostic_dir.join(format!("status.{phase}")),
                0o700,
            )?;
        }
        Ok(())
    }

    fn cleanup_diagnostics(&self, options: CleanupOptions) -> Result<RetentionOutcome> {
        let retain = options.keep_diagnostics || (!options.succeeded && options.keep_on_failure);
        if !directory_has_regular_file(&self.layout.diagnostic_dir)? {
            remove_tree_no_follow(&self.layout.diagnostic_dir)?;
            return Ok(RetentionOutcome::DiscardedEmpty);
        }
        if !retain {
            remove_tree_no_follow(&self.layout.diagnostic_dir)?;
            return Ok(RetentionOutcome::Discarded);
        }

        ensure_directory(&self.roots.diagnostic_keep, 0o700)?;
        let base_name = self
            .layout
            .diagnostic_dir
            .file_name()
            .ok_or_else(|| anyhow!("diagnostic directory has no file name"))?;
        let mut destination = self.roots.diagnostic_keep.join(base_name);
        if fs::symlink_metadata(&destination).is_ok() {
            destination = self.roots.diagnostic_keep.join(format!(
                "{}.{}",
                base_name.to_string_lossy(),
                Uuid::new_v4().simple()
            ));
        }
        move_tree_no_follow(&self.layout.diagnostic_dir, &destination).with_context(|| {
            format!(
                "retain diagnostics {} as {}",
                self.layout.diagnostic_dir.display(),
                destination.display()
            )
        })?;
        Ok(RetentionOutcome::Retained(destination))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CleanupOptions {
    pub succeeded: bool,
    pub keep_diagnostics: bool,
    pub keep_on_failure: bool,
}

impl Default for CleanupOptions {
    fn default() -> Self {
        Self {
            succeeded: true,
            keep_diagnostics: false,
            keep_on_failure: false,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RetentionOutcome {
    Retained(PathBuf),
    Discarded,
    DiscardedEmpty,
    CleanupFailed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CleanupReport {
    pub diagnostics: RetentionOutcome,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CleanupStep {
    TerminateBackgroundJobs,
    ReleaseHostLocalMutex,
    RestoreTty,
    EndLogGroups,
    CleanupRepositoryWorktree,
    ReleaseRepositoryRootLock,
    RetainOrDiscardDiagnostics,
    RemoveRuntimeDirectory,
    RemoveEmptyRoots,
}

pub fn cleanup_order(repository_root_lock_held: bool) -> Vec<CleanupStep> {
    let mut steps = vec![
        CleanupStep::TerminateBackgroundJobs,
        CleanupStep::ReleaseHostLocalMutex,
        CleanupStep::RestoreTty,
        CleanupStep::EndLogGroups,
        CleanupStep::CleanupRepositoryWorktree,
    ];
    if repository_root_lock_held {
        steps.push(CleanupStep::ReleaseRepositoryRootLock);
    }
    steps.extend([
        CleanupStep::RetainOrDiscardDiagnostics,
        CleanupStep::RemoveRuntimeDirectory,
        CleanupStep::RemoveEmptyRoots,
        CleanupStep::RestoreTty,
    ]);
    steps
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CleanupGuarantee {
    NormalExitOnly,
}

impl CleanupGuarantee {
    pub const fn current() -> Self {
        Self::NormalExitOnly
    }

    pub const fn reaps_after_sigkill(self) -> bool {
        false
    }
}

pub fn action_needs_local_mutex(action: &str) -> bool {
    matches!(
        action,
        "run"
            | "deploy"
            | "build"
            | "dev-build"
            | "tf"
            | "tf-dns"
            | "tf-platform"
            | "tf-apps"
            | "clean"
    ) || action.starts_with("tf/")
}

#[derive(Debug)]
pub struct ActionMutex {
    file: File,
    path: PathBuf,
}

impl ActionMutex {
    pub fn try_acquire(path: &Path) -> Result<Option<Self>> {
        prepare_persistent_lock_directory(path)?;
        let file = open_directory_no_follow(path)?;
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result == 0 {
            return Ok(Some(Self {
                file,
                path: path.to_path_buf(),
            }));
        }
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::EWOULDBLOCK) {
            Ok(None)
        } else {
            Err(error).with_context(|| format!("lock {}", path.display()))
        }
    }

    pub fn acquire(path: &Path) -> Result<Self> {
        prepare_persistent_lock_directory(path)?;
        let file = open_directory_no_follow(path)?;
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
        if result != 0 {
            return Err(std::io::Error::last_os_error())
                .with_context(|| format!("lock {}", path.display()));
        }
        Ok(Self {
            file,
            path: path.to_path_buf(),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for ActionMutex {
    fn drop(&mut self) {
        let _ = unsafe { libc::flock(self.file.as_raw_fd(), libc::LOCK_UN) };
    }
}

pub trait ProcessProbe {
    fn is_alive(&self, pid: u32) -> bool;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct SystemProcessProbe;

impl ProcessProbe for SystemProcessProbe {
    fn is_alive(&self, pid: u32) -> bool {
        if pid == 0 || pid > i32::MAX as u32 {
            return false;
        }
        let result = unsafe { libc::kill(pid as i32, 0) };
        result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }
}

#[derive(Debug)]
pub struct StateLock {
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl StateLock {
    pub fn try_acquire(path: &Path, owner_pid: u32, probe: &impl ProcessProbe) -> Result<Self> {
        if owner_pid == 0 {
            bail!("state lock owner PID must be positive");
        }
        if let Some(parent) = path.parent() {
            ensure_directory(parent, 0o700)?;
        }
        loop {
            match fs::create_dir(path) {
                Ok(()) => {
                    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
                    let owner_path = path.join("pid");
                    if let Err(error) =
                        write_private_file(&owner_path, format!("{owner_pid}\n").as_bytes())
                    {
                        let _ = remove_tree_no_follow(path);
                        return Err(error);
                    }
                    let metadata = fs::symlink_metadata(path)?;
                    return Ok(Self {
                        path: path.to_path_buf(),
                        device: metadata.dev(),
                        inode: metadata.ino(),
                    });
                }
                Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                    reject_symlink(path, "state lock")?;
                    let held_pid = read_owner_pid(path);
                    if held_pid.is_some_and(|pid| probe.is_alive(pid)) {
                        bail!(
                            "runtime state lock {} is held by live pid {}",
                            path.display(),
                            held_pid.unwrap()
                        );
                    }
                    remove_tree_no_follow(path).with_context(|| {
                        format!("remove stale runtime state lock {}", path.display())
                    })?;
                }
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("create runtime state lock {}", path.display()));
                }
            }
        }
    }
}

impl Drop for StateLock {
    fn drop(&mut self) {
        let Ok(metadata) = fs::symlink_metadata(&self.path) else {
            return;
        };
        if !metadata.file_type().is_symlink()
            && metadata.is_dir()
            && metadata.dev() == self.device
            && metadata.ino() == self.inode
        {
            let _ = remove_tree_no_follow(&self.path);
        }
    }
}

/// Cross-process lock compatible with the legacy repository lock directory.
/// A live owner is waited for up to the configured deadline; stale directories
/// are removed only after the recorded pid is proven absent.
#[derive(Debug)]
pub struct DirectoryLock {
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl DirectoryLock {
    pub fn acquire(
        path: &Path,
        owner_pid: u32,
        timeout: Duration,
        probe: &impl ProcessProbe,
    ) -> Result<Self> {
        if owner_pid == 0 {
            bail!("directory lock owner PID must be positive");
        }
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("create directory lock parent {}", parent.display()))?;
        }
        let started = Instant::now();
        loop {
            match fs::create_dir(path) {
                Ok(()) => {
                    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
                    if let Err(error) =
                        write_private_file(&path.join("pid"), format!("{owner_pid}\n").as_bytes())
                    {
                        let _ = remove_tree_no_follow(path);
                        return Err(error);
                    }
                    let metadata = fs::symlink_metadata(path)?;
                    return Ok(Self {
                        path: path.to_path_buf(),
                        device: metadata.dev(),
                        inode: metadata.ino(),
                    });
                }
                Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                    reject_symlink(path, "directory lock")?;
                    let held_pid = read_owner_pid(path);
                    if held_pid.is_some_and(|pid| probe.is_alive(pid)) {
                        if started.elapsed() >= timeout {
                            bail!(
                                "timed out waiting for directory lock {} held by pid {}",
                                path.display(),
                                held_pid.expect("checked live owner")
                            );
                        }
                        std::thread::sleep(
                            timeout
                                .saturating_sub(started.elapsed())
                                .min(Duration::from_millis(200)),
                        );
                        continue;
                    }
                    remove_tree_no_follow(path).with_context(|| {
                        format!("remove stale directory lock {}", path.display())
                    })?;
                }
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("create directory lock {}", path.display()));
                }
            }
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for DirectoryLock {
    fn drop(&mut self) {
        let Ok(metadata) = fs::symlink_metadata(&self.path) else {
            return;
        };
        if !metadata.file_type().is_symlink()
            && metadata.is_dir()
            && metadata.dev() == self.device
            && metadata.ino() == self.inode
        {
            let _ = remove_tree_no_follow(&self.path);
        }
    }
}

#[derive(Debug)]
pub struct LineState {
    path: PathBuf,
    lock_path: PathBuf,
    cache: Vec<String>,
}

impl LineState {
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn lock_path(&self) -> &Path {
        &self.lock_path
    }

    pub fn contains(&mut self, item: &str) -> Result<bool> {
        validate_line_item(item)?;
        self.with_locked_lines(|lines| Ok((lines.iter().any(|line| line == item), false)))
    }

    pub fn mark(&mut self, item: &str) -> Result<()> {
        validate_line_item(item)?;
        self.with_locked_lines(|lines| {
            let changed = !lines.iter().any(|line| line == item);
            if changed {
                lines.push(item.to_owned());
            }
            Ok(((), changed))
        })
    }

    pub fn mark_new(&mut self, item: &str) -> Result<bool> {
        validate_line_item(item)?;
        self.with_locked_lines(|lines| {
            let changed = !lines.iter().any(|line| line == item);
            if changed {
                lines.push(item.to_owned());
            }
            Ok((changed, changed))
        })
    }

    pub fn clear(&mut self, item: &str) -> Result<()> {
        validate_line_item(item)?;
        self.with_locked_lines(|lines| {
            let previous_len = lines.len();
            lines.retain(|line| line != item);
            let changed = lines.len() != previous_len;
            Ok(((), changed))
        })
    }

    fn with_locked_lines<T>(
        &mut self,
        operation: impl FnOnce(&mut Vec<String>) -> Result<(T, bool)>,
    ) -> Result<T> {
        let _lock =
            StateLock::try_acquire(&self.lock_path, std::process::id(), &SystemProcessProbe)?;
        let mut lines = read_lines(&self.path)?;
        let (result, changed) = operation(&mut lines)?;
        if changed {
            write_lines_atomically(&self.path, &lines)?;
        }
        self.cache = lines;
        Ok(result)
    }
}

pub fn deploy_activation_unit_name(run_id: &str, node: &str) -> Result<String> {
    host_unit_name("switch-to-configuration", run_id, node)
}

pub fn deploy_activation_attempt_unit_name(
    run_id: &str,
    node: &str,
    attempt: u32,
) -> Result<String> {
    if attempt == 0 {
        bail!("activation attempt must be positive");
    }
    let base = deploy_activation_unit_name(run_id, node)?;
    if attempt == 1 {
        Ok(base)
    } else {
        Ok(format!("{base}-retry{attempt}"))
    }
}

pub fn rollback_activation_unit_name(run_id: &str, node: &str) -> Result<String> {
    host_unit_name("rollback-to-configuration", run_id, node)
}

fn host_unit_name(purpose: &str, run_id: &str, node: &str) -> Result<String> {
    validate_safe_name("unit purpose", purpose)?;
    validate_safe_name("run ID", run_id)?;
    if node.is_empty() {
        bail!("unit node cannot be empty");
    }
    Ok(format!(
        "nixbot-{purpose}-{run_id}-{}",
        &digest_hex(node)[..16]
    ))
}

fn digest_hex(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}

fn validate_safe_name(label: &str, value: &str) -> Result<()> {
    if value.is_empty()
        || matches!(value, "." | "..")
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        bail!("{label} is not a safe path component: {value:?}");
    }
    Ok(())
}

fn validate_line_item(item: &str) -> Result<()> {
    validate_safe_name("line state item", item)
}

fn validate_roots(roots: &RuntimeRoots) -> Result<()> {
    for (label, root) in [
        ("primary runtime root", &roots.primary),
        ("fallback runtime root", &roots.fallback),
        ("diagnostic retention root", &roots.diagnostic_keep),
    ] {
        if !root.is_absolute() || root == Path::new("/") {
            bail!(
                "{label} must be an absolute non-root path: {}",
                root.display()
            );
        }
    }
    if roots.primary == roots.diagnostic_keep || roots.fallback == roots.diagnostic_keep {
        bail!("diagnostic retention root must differ from runtime roots");
    }
    Ok(())
}

fn choose_namespace_root(roots: &RuntimeRoots, preference: RuntimeRootPreference) -> PathBuf {
    match preference {
        RuntimeRootPreference::Primary => roots.primary.clone(),
        RuntimeRootPreference::Fallback => roots.fallback.clone(),
        RuntimeRootPreference::Auto if namespace_is_usable(&roots.primary) => roots.primary.clone(),
        RuntimeRootPreference::Auto => roots.fallback.clone(),
    }
}

fn namespace_is_usable(root: &Path) -> bool {
    if let Ok(metadata) = fs::symlink_metadata(root) {
        return metadata.is_dir()
            && !metadata.file_type().is_symlink()
            && libc_access_writable(root);
    }
    let mut ancestor = root.parent();
    while let Some(path) = ancestor {
        if path.exists() {
            return path.is_dir() && libc_access_writable(path);
        }
        ancestor = path.parent();
    }
    false
}

fn libc_access_writable(path: &Path) -> bool {
    let Ok(path) = CString::new(path.as_os_str().as_bytes()) else {
        return false;
    };
    unsafe { libc::access(path.as_ptr(), libc::W_OK) == 0 }
}

fn ensure_directory(path: &Path, mode: u32) -> Result<()> {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            bail!("directory path is not a real directory: {}", path.display());
        }
    } else {
        fs::create_dir_all(path).with_context(|| format!("create directory {}", path.display()))?;
    }
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
        .with_context(|| format!("set directory mode on {}", path.display()))
}

fn create_owned_directory(path: &Path) -> Result<()> {
    fs::create_dir(path).with_context(|| format!("allocate owned directory {}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
        .with_context(|| format!("set owned directory mode on {}", path.display()))
}

fn prepare_persistent_lock_directory(path: &Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create lock parent {}", parent.display()))?;
    }
    match fs::create_dir(path) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            reject_symlink(path, "host-local lock")?;
            if !fs::metadata(path)?.is_dir() {
                bail!(
                    "host-local lock path is not a directory: {}",
                    path.display()
                );
            }
        }
        Err(error) => {
            return Err(error)
                .with_context(|| format!("create host-local lock directory {}", path.display()));
        }
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o755))
        .with_context(|| format!("set host-local lock mode on {}", path.display()))
}

fn open_directory_no_follow(path: &Path) -> Result<File> {
    let path_bytes = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| anyhow!("path contains a NUL byte: {}", path.display()))?;
    let fd = unsafe {
        libc::open(
            path_bytes.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error())
            .with_context(|| format!("open lock directory {}", path.display()));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn reject_symlink(path: &Path, label: &str) -> Result<()> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect {label} {}", path.display()))?;
    if metadata.file_type().is_symlink() {
        bail!("{label} must not be a symlink: {}", path.display());
    }
    Ok(())
}

fn read_owner_pid(path: &Path) -> Option<u32> {
    fs::read_to_string(path.join("pid"))
        .ok()?
        .trim()
        .parse()
        .ok()
}

fn write_private_file(path: &Path, contents: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("create private file {}", path.display()))?;
    file.write_all(contents)?;
    file.sync_all()?;
    Ok(())
}

fn read_lines(path: &Path) -> Result<Vec<String>> {
    let contents = match fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error).with_context(|| format!("read {}", path.display())),
    };
    let mut lines = Vec::new();
    for line in contents.lines().filter(|line| !line.is_empty()) {
        validate_line_item(line)
            .with_context(|| format!("invalid line state in {}", path.display()))?;
        if !lines.iter().any(|existing| existing == line) {
            lines.push(line.to_owned());
        }
    }
    Ok(lines)
}

fn write_lines_atomically(path: &Path, lines: &[String]) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("line state path has no parent: {}", path.display()))?;
    let name = path
        .file_name()
        .ok_or_else(|| anyhow!("line state path has no file name: {}", path.display()))?
        .to_string_lossy();
    let temporary = parent.join(format!(".{name}.tmp.{}", Uuid::new_v4().simple()));
    let result = (|| -> Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)
            .with_context(|| format!("create {}", temporary.display()))?;
        for line in lines {
            writeln!(file, "{line}")?;
        }
        file.sync_all()?;
        fs::rename(&temporary, path)
            .with_context(|| format!("replace line state {}", path.display()))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn direct_namespace(roots: &RuntimeRoots, path: &Path, prefix: &str) -> Result<PathBuf> {
    for root in [&roots.primary, &roots.fallback] {
        if path.parent() == Some(root.as_path())
            && path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with(prefix) && name.len() > prefix.len())
        {
            return Ok(root.clone());
        }
    }
    bail!(
        "owned path must be a direct child of a configured runtime root: {}",
        path.display()
    )
}

fn verify_owned_tree(root: &Path, path: &Path, prefix: &str) -> Result<()> {
    if path.parent() != Some(root) {
        bail!(
            "owned path escaped its runtime root: {} is not beneath {}",
            path.display(),
            root.display()
        );
    }
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| anyhow!("owned path has no UTF-8 name: {}", path.display()))?;
    if !name.starts_with(prefix) || name.len() == prefix.len() {
        bail!("owned path has an unexpected name: {}", path.display());
    }
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect owned path {}", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        bail!("owned path is not a real directory: {}", path.display());
    }
    Ok(())
}

fn directory_has_regular_file(path: &Path) -> Result<bool> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("inspect diagnostic tree {}", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        bail!(
            "diagnostic tree is not a real directory: {}",
            path.display()
        );
    }
    for entry in fs::read_dir(path).with_context(|| format!("read {}", path.display()))? {
        let entry = entry?;
        let metadata = fs::symlink_metadata(entry.path())?;
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_file() {
            return Ok(true);
        }
        if metadata.is_dir() && directory_has_regular_file(&entry.path())? {
            return Ok(true);
        }
    }
    Ok(false)
}

fn move_tree_no_follow(source: &Path, destination: &Path) -> Result<()> {
    match fs::rename(source, destination) {
        Ok(()) => return Ok(()),
        Err(error) if error.raw_os_error() == Some(libc::EXDEV) => {}
        Err(error) => return Err(error).context("rename owned tree"),
    }

    if let Err(error) = copy_tree_no_follow(source, destination) {
        let _ = remove_tree_no_follow(destination);
        return Err(error).context("copy owned tree across filesystems");
    }
    remove_tree_no_follow(source).context("remove source after cross-filesystem copy")
}

fn copy_tree_no_follow(source: &Path, destination: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(source)
        .with_context(|| format!("inspect source tree {}", source.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        bail!("source tree is not a real directory: {}", source.display());
    }
    fs::create_dir(destination)
        .with_context(|| format!("create destination tree {}", destination.display()))?;
    fs::set_permissions(destination, fs::Permissions::from_mode(0o700))?;

    for entry in fs::read_dir(source).with_context(|| format!("read {}", source.display()))? {
        let entry = entry?;
        let source_child = entry.path();
        let destination_child = destination.join(entry.file_name());
        let metadata = fs::symlink_metadata(&source_child)?;
        if metadata.file_type().is_symlink() {
            bail!(
                "refusing to retain a diagnostic symlink: {}",
                source_child.display()
            );
        }
        if metadata.is_dir() {
            copy_tree_no_follow(&source_child, &destination_child)?;
        } else if metadata.is_file() {
            let mut input = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&source_child)?;
            let opened = input.metadata()?;
            if !opened.is_file() || opened.dev() != metadata.dev() || opened.ino() != metadata.ino()
            {
                bail!(
                    "diagnostic file changed while being retained: {}",
                    source_child.display()
                );
            }
            let mut output = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&destination_child)?;
            std::io::copy(&mut input, &mut output)?;
            output.sync_all()?;
        } else {
            bail!(
                "refusing to retain a non-regular diagnostic entry: {}",
                source_child.display()
            );
        }
    }
    File::open(destination)?.sync_all()?;
    Ok(())
}

fn remove_tree_no_follow(path: &Path) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error).with_context(|| format!("inspect {}", path.display())),
    };
    if metadata.file_type().is_symlink() {
        bail!(
            "refusing to remove an owned-tree symlink: {}",
            path.display()
        );
    }
    if !metadata.is_dir() {
        bail!("owned tree is not a directory: {}", path.display());
    }
    for entry in fs::read_dir(path).with_context(|| format!("read {}", path.display()))? {
        let entry = entry?;
        let child = entry.path();
        let metadata = fs::symlink_metadata(&child)?;
        if metadata.is_dir() && !metadata.file_type().is_symlink() {
            remove_tree_no_follow(&child)?;
        } else {
            fs::remove_file(&child).with_context(|| format!("remove {}", child.display()))?;
        }
    }
    fs::remove_dir(path).with_context(|| format!("remove directory {}", path.display()))
}

fn remove_empty_directory(path: &Path) {
    if fs::symlink_metadata(path)
        .is_ok_and(|metadata| metadata.is_dir() && !metadata.file_type().is_symlink())
    {
        let _ = fs::remove_dir(path);
    }
}
