//! One caller-owned native import subprocess. Never borrows preparation-worker
//! authority; the ordinary local daemon authenticates the caller UID.

mod child;
mod service;

use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::{
    ffi::OsStrExt,
    fs::{FileTypeExt, MetadataExt},
};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use abird_host_agent::build_executor::ArtifactDelivery;
use abird_host_agent::sha256::digest_bytes;
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

pub(super) const MAX_REQUEST: usize = 16 * 1024 * 1024;
const MAX_REPLY: usize = 4096;
pub const STORE_ID: &str = "caller-daemon-store";
const SOCKET: &str = "/nix/var/nix/daemon-socket/socket";
const URI: &str = "unix:///nix/var/nix/daemon-socket/socket";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Destination {
    uri: String,
    store: (u64, u64),
    database: (u64, u64),
    socket: (u64, u64),
}

impl Destination {
    pub(super) fn capture() -> Result<Self> {
        let directory = |path: &str| -> Result<(u64, u64)> {
            let metadata = std::fs::symlink_metadata(path)?;
            // Upstream's ordinary root:nixbld store is 1775. The sticky bit
            // protects root-owned store objects; state/endpoint parents are not writable.
            let writable = metadata.mode() & 0o022;
            ensure!(
                metadata.is_dir()
                    && metadata.uid() == 0
                    && (writable == 0
                        || (path == "/nix/store"
                            && writable == 0o020
                            && metadata.mode() & libc::S_ISVTX != 0)),
                "local store directory identity differs"
            );
            Ok((metadata.dev(), metadata.ino()))
        };
        directory("/nix")?;
        directory("/nix/var")?;
        directory("/nix/var/nix")?;
        directory("/nix/var/nix/daemon-socket")?;
        let socket = std::fs::symlink_metadata(SOCKET)?;
        ensure!(
            socket.file_type().is_socket() && socket.uid() == 0,
            "local store endpoint is not a root-owned socket"
        );
        Ok(Self {
            uri: URI.into(),
            store: directory("/nix/store")?,
            database: directory("/nix/var/nix/db")?,
            socket: (socket.dev(), socket.ino()),
        })
    }

    fn check(&self) -> Result<()> {
        ensure!(
            *self == Self::capture()?,
            "consumer destination store replaced"
        );
        Ok(())
    }
}

#[derive(Clone, Copy)]
pub(crate) struct Input<'a> {
    pub program: &'a Path,
    pub source: &'a str,
    pub roots: &'a Path,
    pub tree: bool,
    pub delivery: &'a ArtifactDelivery,
}

pub(super) fn binding(
    source: &str,
    program: &Path,
    roots: &Path,
    tree: bool,
    destination: &Destination,
) -> Result<String> {
    let bytes = serde_json::to_vec(&(
        "abird-owned-remote-acquisition-v2",
        super::signed_source(source)?,
        program,
        STORE_ID,
        destination,
        library()?,
        roots,
        tree,
    ))?;
    Ok(digest_bytes(&bytes))
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Request {
    version: u32,
    program: PathBuf,
    source: String,
    destination: Option<Destination>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    development: Option<super::development::Development>,
    roots: PathBuf,
    tree: bool,
    paths: Vec<String>,
    delivery: ArtifactDelivery,
    import: bool,
    #[serde(default)]
    reconcile_only: bool,
    #[serde(default)]
    discard: bool,
    #[serde(default)]
    shared_verify: bool,
    #[serde(default)]
    publish_roots: bool,
    deadline_unix_millis: u64,
    lock_fd: i32,
}

impl Request {
    pub(super) fn new(
        input: Input<'_>,
        import: bool,
        cutoff: Instant,
        lock: &File,
    ) -> Result<Self> {
        Self::with_mode(input, import, None, false, cutoff, lock)
    }

    pub(super) fn reconciliation(
        input: Input<'_>,
        discard: bool,
        cutoff: Instant,
        lock: &File,
    ) -> Result<Self> {
        let mut request = Self::new(input, false, cutoff, lock)?;
        request.reconcile_only = true;
        request.discard = discard;
        request.validate()?;
        Ok(request)
    }

    pub(super) fn shared(
        input: Input<'_>,
        publish_roots: bool,
        cutoff: Instant,
        lock: &File,
    ) -> Result<Self> {
        let mut request = Self::with_mode(input, false, None, true, cutoff, lock)?;
        request.publish_roots = publish_roots;
        request.validate()?;
        Ok(request)
    }

    pub(super) fn development(
        input: Input<'_>,
        development: super::development::Development,
        cutoff: Instant,
        lock: &File,
    ) -> Result<Self> {
        Self::with_mode(input, false, Some(development), false, cutoff, lock)
    }

    fn with_mode(
        input: Input<'_>,
        import: bool,
        development: Option<super::development::Development>,
        shared_verify: bool,
        cutoff: Instant,
        lock: &File,
    ) -> Result<Self> {
        let Input {
            program,
            source,
            roots,
            tree,
            delivery,
        } = input;
        let now = Instant::now();
        let remaining = cutoff
            .checked_duration_since(now)
            .context("acquisition deadline expired")?;
        let deadline = SystemTime::now()
            .duration_since(UNIX_EPOCH)?
            .checked_add(remaining)
            .context("acquisition deadline overflow")?;
        let request = Self {
            version: 2,
            program: program.into(),
            source: source.into(),
            destination: if shared_verify || development.as_ref().is_some_and(|value| value.shared)
            {
                None
            } else {
                Some(Destination::capture()?)
            },
            development,
            roots: roots.into(),
            tree,
            paths: super::retained_paths(delivery, tree),
            delivery: delivery.clone(),
            import,
            reconcile_only: false,
            discard: false,
            shared_verify,
            publish_roots: false,
            deadline_unix_millis: u64::try_from(deadline.as_millis())?,
            lock_fd: lock.as_raw_fd(),
        };
        request.validate()?;
        Ok(request)
    }

    pub(super) fn binding(&self) -> Result<String> {
        binding(
            &self.source,
            &self.program,
            &self.roots,
            self.tree,
            self.destination
                .as_ref()
                .context("missing daemon destination")?,
        )
    }

    fn shared_operation(&self) -> bool {
        self.shared_verify || self.development.as_ref().is_some_and(|value| value.shared)
    }

    fn validate(&self) -> Result<()> {
        ensure!(
            self.version == 2
                && self.program.starts_with("/nix/store")
                && self.program.ends_with("bin/nix")
                && self.paths.len() <= 1024
                && self.lock_fd >= 3,
            "invalid native acquisition request"
        );
        super::signed_source(&self.source)?;
        ensure!(
            !self.reconcile_only
                || (!self.import && !self.shared_verify && self.development.is_none()),
            "invalid import reconciliation mode"
        );
        ensure!(
            !self.discard || self.reconcile_only,
            "discard requires read-only reconciliation"
        );
        if let Some(destination) = &self.destination {
            destination.check()?;
        }
        ensure!(
            !self.publish_roots || self.shared_verify,
            "root publication requires shared verification"
        );
        if self.shared_verify {
            ensure!(
                !self.import && self.destination.is_none() && self.development.is_none(),
                "shared verification has daemon authority"
            );
        } else if let Some(development) = &self.development {
            development.validate()?;
            ensure!(
                !self.import
                    && !self.tree
                    && development.shared == self.destination.is_none()
                    && development
                        .links
                        .values()
                        .all(|path| self.paths.contains(path)),
                "development publication differs from original outputs"
            );
        } else {
            ensure!(
                self.destination.is_some(),
                "missing local daemon destination"
            );
        }
        let attempt = &self.delivery.ownership.attempt_id;
        let run = self.roots.parent().context("missing consumer run roots")?;
        let run_id = run
            .file_name()
            .and_then(|s| s.to_str())
            .context("invalid consumer run")?;
        ensure!(
            run_id.len() == 32
                && run_id
                    .bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
                && self.roots.file_name().and_then(|s| s.to_str()) == Some(attempt.as_str())
                && run.parent() == Some(super::roots_base()?.as_path()),
            "native acquisition roots differ"
        );
        let bytes = self.delivery.encode()?;
        ArtifactDelivery::decode(&bytes, &self.delivery.ownership, &self.delivery.artifacts)?;
        ensure!(
            self.paths == super::retained_paths(&self.delivery, self.tree),
            "native root set differs"
        );
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_REQUEST,
            "native acquisition request exceeds bound"
        );
        Ok(())
    }
}

#[derive(Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub(super) enum ImportState {
    NotStarted,
    Completed,
    Unconfirmed,
}

impl ImportState {
    pub(super) fn settles(&self, previously_pending: bool) -> bool {
        // This receipt speaks only for this invocation. An older disconnected
        // daemon producer is not settled by a new successful identical import.
        !previously_pending && matches!(self, Self::Completed | Self::NotStarted)
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Reply {
    version: u32,
    request_digest: String,
    pub import_state: ImportState,
    pub verified: bool,
    pub development_published: bool,
    pub effects_confined: bool,
}

pub(super) fn library() -> Result<PathBuf> {
    Ok(std::env::current_exe()?.with_file_name("libabird-owned-nix.so"))
}

/// Metadata/symbol qualification only: no store opening, import or claim. The
/// worker repeats this exact check; preflight never settles an older import.
pub(crate) fn preflight(program: &Path) -> Result<()> {
    let mut command = managed_command_for("_owned-acquire-preflight")?;
    command.arg(program);
    ensure!(
        child::preflight(&mut command)? == b"ready\n",
        "native consumer preflight unconfirmed"
    );
    Ok(())
}

/// Same isolated, loader-sanitized process as acquisition, without a request,
/// store connection or inherited run lock. Native globals never enter the UI.
pub fn preflight_worker(program: &Path) -> Result<()> {
    ensure!(
        unsafe { libc::geteuid() } > 0,
        "consumer requires ordinary caller credentials"
    );
    abird_host_agent::build_executor::process::protect_worker_memory()?;
    load_api(&library()?, program)?;
    std::io::stdout().write_all(b"ready\n")?;
    Ok(())
}

pub(super) fn run(
    request: &Request,
    lock: &File,
    cutoff: Instant,
    active: impl FnMut() -> Result<()>,
) -> Result<Reply> {
    request.validate()?;
    let bytes = serde_json::to_vec(request)?;
    let output = if request.shared_operation() {
        service::run(&bytes, lock, cutoff, active)?
    } else {
        child::run(&mut managed_command()?, &bytes, lock, cutoff, active)?
    };
    let reply: Reply =
        serde_json::from_slice(&output).context("native acquisition receipt unavailable")?;
    ensure!(
        reply.version == 2 && reply.request_digest == digest_bytes(&bytes),
        "native acquisition receipt binding differs"
    );
    ensure!(
        (!reply.verified
            || ((request.shared_verify || reply.effects_confined)
                && request.development.is_none()
                && !request.discard))
            && (!request.shared_verify || !reply.effects_confined)
            && (!reply.development_published
                || (request.development.is_some() && !reply.verified && !reply.effects_confined))
            && (request.import || reply.import_state == ImportState::NotStarted),
        "native acquisition receipt contradicts requested operation"
    );
    if let Some(destination) = &request.destination {
        destination.check()?;
    }
    Ok(reply)
}

/// Fixed private entry. No caller-controlled library or executable lookup.
pub fn worker(library: &Path) -> Result<()> {
    ensure!(
        unsafe { libc::geteuid() } > 0,
        "acquisition helper requires ordinary caller credentials"
    );
    abird_host_agent::build_executor::process::protect_worker_memory()?;
    let mut bytes = Vec::new();
    std::io::stdin()
        .take(MAX_REQUEST as u64 + 1)
        .read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= MAX_REQUEST,
        "native acquisition input exceeds bound"
    );
    let output = execute(library, bytes, None, -1)?;
    let mut stdout = std::io::stdout().lock();
    stdout.write_all(&output)?;
    stdout.flush()?;
    Ok(())
}

pub fn shared_worker() -> Result<()> {
    service::worker()
}

fn require_program(program: &Path, installed: &CStr) -> Result<()> {
    // Stock packages may expose bin/nix through an immutable output symlink.
    let installed = Path::new(std::ffi::OsStr::from_bytes(installed.to_bytes()));
    ensure!(
        std::fs::canonicalize(program)? == std::fs::canonicalize(installed)?,
        "native acquisition Nix profile differs"
    );
    Ok(())
}

fn require_profile(abi: u32, program: &Path, installed: &CStr) -> Result<()> {
    ensure!(abi == 3, "native acquisition adapter ABI differs");
    require_program(program, installed)
}

type Acquire = unsafe extern "C" fn(*const c_char, c_int, Callback, *mut c_void) -> c_int;

/// Shared by admission and the fixed worker. Only immutable package code is
/// loaded; the operation symbol is returned without invoking native store APIs.
fn load_api(library: &Path, expected: &Path) -> Result<Acquire> {
    ensure!(
        library == self::library()?,
        "native acquisition library outside manager package"
    );
    let canonical = std::fs::canonicalize(library)?;
    let metadata = std::fs::metadata(&canonical)?;
    ensure!(
        canonical.starts_with("/nix/store")
            && metadata.is_file()
            && metadata.uid() == 0
            && metadata.mode() & 0o022 == 0,
        "native acquisition library is mutable"
    );
    let name = CString::new(canonical.as_os_str().as_bytes())?;
    let handle = unsafe {
        libc::dlopen(
            name.as_ptr(),
            libc::RTLD_NOW | libc::RTLD_LOCAL | libc::RTLD_NODELETE,
        )
    };
    ensure!(!handle.is_null(), "native acquisition library unavailable");
    let symbol = |name: &CStr| -> Result<*mut c_void> {
        let symbol = unsafe { libc::dlsym(handle, name.as_ptr()) };
        ensure!(!symbol.is_null(), "native acquisition symbol unavailable");
        Ok(symbol)
    };
    type Abi = unsafe extern "C" fn() -> u32;
    type Program = unsafe extern "C" fn() -> *const c_char;
    let abi: Abi =
        unsafe { std::mem::transmute::<*mut c_void, Abi>(symbol(c"abird_owned_acquisition_abi")?) };
    let program: Program = unsafe {
        std::mem::transmute::<*mut c_void, Program>(symbol(c"abird_owned_acquisition_program")?)
    };
    let acquire: Acquire =
        unsafe { std::mem::transmute::<*mut c_void, Acquire>(symbol(c"abird_owned_acquire")?) };
    let program = unsafe { program() };
    ensure!(
        !program.is_null() && unsafe { libc::strnlen(program, 4097) } <= 4096,
        "native acquisition Nix profile differs"
    );
    require_profile(unsafe { abi() }, expected, unsafe {
        CStr::from_ptr(program)
    })?;
    Ok(acquire)
}

fn execute(
    library: &Path,
    bytes: Vec<u8>,
    inherited_lock: Option<i32>,
    gc_fd: i32,
) -> Result<Vec<u8>> {
    ensure!(
        unsafe { libc::geteuid() } > 0,
        "native acquisition cannot run as root"
    );
    let request: Request = serde_json::from_slice(&bytes)?;
    request.validate()?;
    ensure!(
        request.shared_operation() == (gc_fd >= 3)
            && inherited_lock.is_some() == request.shared_operation(),
        "shared acquisition requires the fixed installed work role"
    );
    let mut metadata: libc::stat = unsafe { std::mem::zeroed() };
    ensure!(
        unsafe { libc::fstat(inherited_lock.unwrap_or(request.lock_fd), &mut metadata) } == 0
            && metadata.st_mode & libc::S_IFMT == libc::S_IFREG
            && metadata.st_uid == unsafe { libc::geteuid() }
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o7777 == 0o600,
        "native acquisition exclusion not inherited"
    );
    let remaining = Duration::from_millis(request.deadline_unix_millis)
        .checked_sub(SystemTime::now().duration_since(UNIX_EPOCH)?)
        .filter(|left| !left.is_zero())
        .context("native acquisition deadline expired")?;
    ensure!(
        remaining <= Duration::from_secs(86400 * 7),
        "native acquisition deadline exceeds bound"
    );
    // Parent enforces the tighter monotonic deadline; this is the fail-closed
    // independent bound if its supervising thread disappears during native I/O.
    let _deadline = std::thread::spawn(move || {
        std::thread::sleep(remaining);
        unsafe { libc::_exit(124) };
    });
    let acquire = load_api(library, &request.program)?;
    abird_host_agent::build_executor::process::restrict_worker_exec()?;
    let input = CString::new(bytes)?;
    let mut output: Option<Vec<u8>> = None;
    let result = unsafe {
        acquire(
            input.as_ptr(),
            gc_fd,
            capture,
            std::ptr::from_mut(&mut output).cast(),
        )
    };
    ensure!(result == 0, "native acquisition failed without receipt");
    output.context("native acquisition response absent")
}

fn managed_command() -> Result<std::process::Command> {
    let mut command = managed_command_for("_owned-acquire")?;
    command.arg(library()?);
    Ok(command)
}

fn managed_command_for(mode: &str) -> Result<std::process::Command> {
    let mut command = std::process::Command::new(std::env::current_exe()?);
    command.arg(mode).current_dir("/");
    // Keep ordinary caller HOME/XDG_CONFIG_HOME: their normal public trust
    // configuration is intentionally read afresh, not frozen in a claim.
    // Disallow alternate config-file lists, inline trust and loader overrides.
    for name in [
        "NIX_REMOTE",
        "NIX_STORE",
        "NIX_STORE_DIR",
        "NIX_STATE_DIR",
        "NIX_CONFIG",
        "NIX_CONF_DIR",
        "NIX_USER_CONF_FILES",
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "LD_AUDIT",
    ] {
        command.env_remove(name);
    }
    Ok(command)
}

type Callback = unsafe extern "C" fn(*const c_char, usize, *mut c_void) -> c_int;
unsafe extern "C" fn capture(start: *const c_char, count: usize, user: *mut c_void) -> c_int {
    let output = unsafe { &mut *user.cast::<Option<Vec<u8>>>() };
    if output.is_some() || start.is_null() || count > MAX_REPLY {
        return 1;
    }
    *output = Some(unsafe { std::slice::from_raw_parts(start.cast(), count) }.to_vec());
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_program_profile_accepts_only_the_same_canonical_executable() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        let executable = root.path().join("nix");
        let alias = root.path().join("package-nix");
        let other = root.path().join("other-nix");
        std::fs::write(&executable, b"fixture").unwrap();
        std::fs::write(&other, b"fixture").unwrap();
        symlink(&executable, &alias).unwrap();
        let installed = CString::new(alias.as_os_str().as_bytes()).unwrap();
        require_profile(3, &alias, &installed).unwrap();
        require_profile(3, &executable, &installed).unwrap();
        assert!(require_profile(2, &alias, &installed).is_err());
        assert!(require_profile(3, &other, &installed).is_err());
        assert!(require_profile(3, &root.path().join("missing"), &installed).is_err());
    }

    #[test]
    fn native_receipt_distinguishes_preflight_completion_and_unknown_import() {
        assert!(ImportState::NotStarted.settles(false));
        assert!(!ImportState::NotStarted.settles(true));
        assert!(ImportState::Completed.settles(false));
        assert!(!ImportState::Completed.settles(true));
        assert!(!ImportState::Unconfirmed.settles(false));
        assert!(!ImportState::Unconfirmed.settles(true));
        for state in ["exited", "cancelled", "timed_out"] {
            assert!(serde_json::from_value::<ImportState>(serde_json::json!(state)).is_err());
        }
    }

    #[test]
    fn remote_binding_pins_destination_not_ambient_daemon_selection() {
        let destination = Destination {
            uri: URI.into(),
            store: (1, 2),
            database: (1, 3),
            socket: (1, 4),
        };
        let nix = Path::new("/nix/store/00000000000000000000000000000000-nix/bin/nix");
        let roots = Path::new("/roots/run/attempt");
        let original = binding("http://builder:5000", nix, roots, true, &destination).unwrap();
        let mut changed = destination.clone();
        changed.store.1 += 1;
        assert_ne!(
            binding("http://builder:5000", nix, roots, true, &changed).unwrap(),
            original
        );
        changed = destination.clone();
        changed.database.1 += 1;
        assert_ne!(
            binding("http://builder:5000", nix, roots, true, &changed).unwrap(),
            original
        );
        changed = destination.clone();
        changed.socket.1 += 1;
        assert_ne!(
            binding("http://builder:5000", nix, roots, true, &changed).unwrap(),
            original
        );
        assert_ne!(
            binding("http://other:5000", nix, roots, true, &destination).unwrap(),
            original
        );
        assert_ne!(
            binding("http://builder:5000", nix, roots, false, &destination).unwrap(),
            original
        );
        assert!(
            binding(
                "http://builder:5000?trusted=1",
                nix,
                roots,
                true,
                &destination
            )
            .is_err()
        );
    }

    /// Native filesystem preflight only; these failures precede any daemon RPC
    /// or GC lock acquisition. Run each case in a fresh single-use ABI process.
    #[test]
    #[ignore = "requires ABIRD_TEST_ACQUISITION_LIBRARY with acquisition ABI 3"]
    fn native_development_preflight_preserves_foreign_result_entries() {
        use std::os::unix::fs::{DirBuilderExt, symlink};
        const TEST: &str = "fleet::build_backend::agent::acquisition::native::tests::native_development_preflight_preserves_foreign_result_entries";
        let library =
            std::env::var_os("ABIRD_TEST_ACQUISITION_LIBRARY").expect("native library required");
        let Ok(case) = std::env::var("ABIRD_TEST_DEVELOPMENT_CASE") else {
            for case in ["file", "directory", "foreign-link", "directory-link"] {
                let mut command = std::process::Command::new(std::env::current_exe().unwrap());
                command
                    .args(["--exact", TEST, "--ignored", "--nocapture"])
                    .env("ABIRD_TEST_DEVELOPMENT_CASE", case);
                let lock = tempfile::tempfile().unwrap();
                child::run(
                    &mut command,
                    b"",
                    &lock,
                    Instant::now() + Duration::from_secs(10),
                    || Ok(()),
                )
                .unwrap_or_else(|error| panic!("{case}: {error}"));
            }
            return;
        };
        let directory = tempfile::tempdir().unwrap();
        let base = directory.path().join("roots");
        let run = base.join("a".repeat(32));
        let roots = run.join("b".repeat(64));
        let repository = directory.path().join("repository");
        for path in [&base, &run, &roots, &repository] {
            std::fs::DirBuilder::new().mode(0o700).create(path).unwrap();
        }
        let target = format!("/nix/store/{}-fixture", "a".repeat(32));
        symlink(&target, roots.join("0")).unwrap();
        let results = repository.join("result-dev");
        if case == "directory-link" {
            symlink(&base, &results).unwrap();
        } else {
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&results)
                .unwrap();
            match case.as_str() {
                "file" => std::fs::write(results.join("host"), b"foreign contents").unwrap(),
                "directory" => std::fs::create_dir(results.join("host")).unwrap(),
                "foreign-link" => symlink("/outside-missing", results.join("host")).unwrap(),
                _ => panic!("unknown case"),
            }
        }
        let metadata = repository.metadata().unwrap();
        let library = CString::new(library.as_bytes()).unwrap();
        let handle = unsafe {
            libc::dlopen(
                library.as_ptr(),
                libc::RTLD_NOW | libc::RTLD_LOCAL | libc::RTLD_NODELETE,
            )
        };
        assert!(!handle.is_null());
        type Program = unsafe extern "C" fn() -> *const c_char;
        type Acquire = unsafe extern "C" fn(*const c_char, c_int, Callback, *mut c_void) -> c_int;
        type Abi = unsafe extern "C" fn() -> u32;
        let abi = unsafe { libc::dlsym(handle, c"abird_owned_acquisition_abi".as_ptr()) };
        assert!(!abi.is_null());
        let abi: Abi = unsafe { std::mem::transmute::<*mut c_void, Abi>(abi) };
        assert_eq!(unsafe { abi() }, 3, "native acquisition ABI mismatch");
        let program = unsafe { libc::dlsym(handle, c"abird_owned_acquisition_program".as_ptr()) };
        let acquire = unsafe { libc::dlsym(handle, c"abird_owned_acquire".as_ptr()) };
        assert!(!program.is_null() && !acquire.is_null());
        let program: Program = unsafe { std::mem::transmute::<*mut c_void, Program>(program) };
        let acquire: Acquire = unsafe { std::mem::transmute::<*mut c_void, Acquire>(acquire) };
        let installed = unsafe { CStr::from_ptr(program()) };
        let canonical =
            std::fs::canonicalize(Path::new(std::ffi::OsStr::from_bytes(installed.to_bytes())))
                .unwrap();
        let bytes = serde_json::to_vec(&serde_json::json!({
            "version": 2, "program": canonical,
            "source": "http://builder", "import": false, "paths": [&target], "roots": roots,
            "development": { "repository": repository, "identity": [metadata.dev(), metadata.ino()],
                "shared": true, "links": { "host": target } },
        }))
        .unwrap();
        let digest = digest_bytes(&bytes);
        let input = CString::new(bytes).unwrap();
        let mut output: Option<Vec<u8>> = None;
        assert_eq!(
            unsafe {
                acquire(
                    input.as_ptr(),
                    -1,
                    capture,
                    std::ptr::from_mut(&mut output).cast(),
                )
            },
            0
        );
        let reply: Reply = serde_json::from_slice(&output.unwrap()).unwrap();
        assert_eq!(reply.version, 2);
        assert_eq!(reply.request_digest, digest);
        assert_eq!(reply.import_state, ImportState::NotStarted);
        assert!(!reply.verified && !reply.development_published);
        if case != "directory-link" {
            // Establish that native preflight reached the actual foreign entry,
            // rather than failing earlier at configuration or request parsing.
            assert!(base.join("development").is_dir());
        }
        match case.as_str() {
            "file" => assert_eq!(
                std::fs::read(results.join("host")).unwrap(),
                b"foreign contents"
            ),
            "directory" => assert!(results.join("host").is_dir()),
            "foreign-link" => assert_eq!(
                std::fs::read_link(results.join("host")).unwrap(),
                Path::new("/outside-missing")
            ),
            "directory-link" => assert_eq!(std::fs::read_link(&results).unwrap(), base),
            _ => unreachable!(),
        }
    }

    #[test]
    fn managed_child_removes_loader_and_configuration_redirection() {
        let command = managed_command().unwrap();
        let environment = command
            .get_envs()
            .collect::<std::collections::BTreeMap<_, _>>();
        for name in [
            "LD_AUDIT",
            "LD_PRELOAD",
            "LD_LIBRARY_PATH",
            "NIX_STORE",
            "NIX_REMOTE",
            "NIX_CONFIG",
            "NIX_CONF_DIR",
            "NIX_USER_CONF_FILES",
        ] {
            assert_eq!(
                environment.get(std::ffi::OsStr::new(name)),
                Some(&None),
                "{name}"
            );
        }
        assert!(!environment.contains_key(std::ffi::OsStr::new("HOME")));
        assert!(!environment.contains_key(std::ffi::OsStr::new("XDG_CONFIG_HOME")));
    }

    #[test]
    fn native_callback_is_single_bounded_receipt() {
        let mut output: Option<Vec<u8>> = None;
        let user = std::ptr::from_mut(&mut output).cast();
        assert_eq!(unsafe { capture(c"{}".as_ptr(), 2, user) }, 0);
        assert_eq!(unsafe { capture(c"{}".as_ptr(), 2, user) }, 1);
        assert_eq!(output.as_deref(), Some(b"{}".as_slice()));
        output = None;
        let user = std::ptr::from_mut(&mut output).cast();
        assert_eq!(unsafe { capture(c"{}".as_ptr(), MAX_REPLY + 1, user) }, 1);
        assert!(output.is_none());
    }
}
