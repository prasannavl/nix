//! Installed native daemon handoff, not a proxy or global ingress certificate.
//! Only an existing execution owner may start it. Recovery starts stay closed.

use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::control;
use super::journal::{Journal, work::Kind};
use super::launch_gate::{Gate, Permission, Permit};
use super::request::state_root;
use super::workload;

mod peers;
pub use peers::Client;

const MAX_BYTES: u64 = 32 * 1024;
const SOCKET: &str = "/nix/var/nix/daemon-socket/socket";

/// Root-generated declaration. The digest binds this handoff policy together
/// with the separately approved containment digest; it does not verify capacity.
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub version: u32,
    pub containment_digest: String,
    pub control_digest: String,
    pub role_policy: PathBuf,
    pub launcher: PathBuf,
    pub program: PathBuf,
    pub evaluation_library: PathBuf,
    pub system: String,
    pub search_path: String,
    pub configuration_directory: PathBuf,
    pub certificate_bundle: PathBuf,
    pub clients: Vec<Client>,
}

impl Policy {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.version == 7, "unsupported daemon policy");
        super::preparation::worker::Input::validate_system(&self.system)?;
        peers::validate(&self.clients)?;
        ensure!(
            self.clients.len() == 1,
            "upstream executor requires one exclusive native client UID"
        );
        super::digest(&self.containment_digest)?;
        super::digest(&self.control_digest)?;
        ensure!(
            self.role_policy.is_absolute()
                && self.role_policy.as_os_str().len() <= 4096
                && self.role_policy.components().all(|part| matches!(
                    part,
                    std::path::Component::RootDir | std::path::Component::Normal(_)
                )),
            "invalid native executor role path"
        );
        store_path(&self.launcher)?;
        store_path(&self.program)?;
        store_path(&self.evaluation_library)?;
        ensure!(
            self.evaluation_library
                .file_name()
                .is_some_and(|name| name == "libabird-owned-nix.so"),
            "unexpected native evaluation library"
        );
        store_path(&self.configuration_directory)?;
        store_path(&self.certificate_bundle)?;
        ensure!(
            self.launcher
                .file_name()
                .is_some_and(|n| n == "abird-host-agent")
                && self.program.file_name().is_some_and(|n| n == "nix-daemon"),
            "unexpected daemon executable"
        );
        ensure!(
            !self.search_path.is_empty()
                && self.search_path.len() <= 8192
                && self.search_path.split(':').count() <= 64,
            "invalid daemon search path"
        );
        for path in self.search_path.split(':') {
            store_path(Path::new(path))?;
        }
        Ok(())
    }

    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        let mut bytes = b"abird-owned-daemon-policy-v7\n".to_vec();
        bytes.extend(serde_json::to_vec(&serde_json::to_value(self)?)?);
        Ok(crate::sha256::digest_bytes(&bytes))
    }

    pub fn load(path: &Path) -> Result<Self> {
        let bytes = read_declaration(path)?;
        let policy: Self =
            serde_json::from_slice(&bytes).map_err(|_| anyhow::anyhow!("invalid daemon policy"))?;
        policy.validate()?;
        Ok(policy)
    }

    pub(super) fn require_executor(&self, policy: &super::build_worker::Policy) -> Result<()> {
        self.validate()?;
        policy.validate()?;
        ensure!(
            !self
                .clients
                .iter()
                .any(|client| client.uid == policy.source_uid),
            "source producer has native store authority"
        );
        ensure!(
            self.clients[0].uid == policy.uid,
            "native executor UID differs from build role"
        );
        Ok(())
    }

    /// Kernel DAC excludes source/caller/build-user identities before native
    /// username authentication. The exclusive executor UID is trusted code.
    pub(super) fn require_socket(&self) -> Result<super::journal::native_phase::FileId> {
        self.validate()?;
        let metadata = socket_metadata()?;
        socket_access(metadata.uid(), metadata.mode(), self.clients[0].uid)?;
        Ok(super::journal::native_phase::FileId {
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }

    /// Fixed client of this exact native multicall package. No ambient NIX_*,
    /// shell, PATH-selected executable, alternate store or trust override.
    pub(super) fn native_client(&self) -> Result<Command> {
        let mut command = self.native_command()?;
        command.args(["--store", "daemon"]);
        Ok(command)
    }

    /// Pure filesystem NAR hashing; this command does not open any store backend.
    pub(super) fn native_hash(&self, path: &str) -> Result<Command> {
        super::request::store_path(path)?;
        let mut command = self.native_command()?;
        command.args(["hash", "path", "--type", "sha256", "--base16", "--", path]);
        Ok(command)
    }

    /// Fixed filesystem-only NAR decoder, with no LocalStore/daemon opening.
    pub(super) fn native_restore(&self, path: &Path) -> Result<Command> {
        let mut command = Command::new(self.native_nar_program()?);
        command
            .env_clear()
            .env("HOME", "/var/empty")
            .env("LC_ALL", "C")
            .env("PATH", &self.search_path)
            .env("NIX_CONF_DIR", &self.configuration_directory)
            .env("NIX_SSL_CERT_FILE", &self.certificate_bundle)
            .current_dir("/var/empty")
            .arg("--restore")
            .arg(path);
        Ok(command)
    }

    /// Filesystem dump/restore share the exact installed native package, without
    /// daemon access or an alternate LocalStore. Caller pins the operation.
    pub(super) fn native_nar_program(&self) -> Result<PathBuf> {
        let program = self.program.with_file_name("nix-store");
        executable(&program)?;
        ensure!(
            fs::canonicalize(&program)? == fs::canonicalize(&self.program)?,
            "native NAR package differs"
        );
        Ok(program)
    }

    fn native_command(&self) -> Result<Command> {
        let program = self.program.with_file_name("nix");
        executable(&program)?;
        ensure!(
            fs::canonicalize(&program)? == fs::canonicalize(&self.program)?,
            "native client package differs"
        );
        let mut command = Command::new(program);
        command
            .args([
                "--option",
                "system",
                &self.system,
                "--option",
                "accept-flake-config",
                "false",
                "--option",
                "allow-unsafe-native-code-during-evaluation",
                "false",
            ])
            .env_clear()
            .env("HOME", "/var/empty")
            .env("LC_ALL", "C")
            .env("PATH", &self.search_path)
            .env("NIX_CONF_DIR", &self.configuration_directory)
            .env("NIX_SSL_CERT_FILE", &self.certificate_bundle)
            .current_dir("/var/empty");
        Ok(command)
    }

    fn command(&self, kind: Kind, owner: &super::Ownership) -> Result<Command> {
        super::digest(&owner.attempt_id)?;
        let allowed = match kind {
            // Upstream has no job-kind operation filter. Both fixed clients
            // use this exclusive, Nix-untrusted identity; root stays separate.
            Kind::Build | Kind::Maintenance => peers::allowed(&self.clients),
            Kind::Retirement => anyhow::bail!("retirement has no native daemon authority"),
        };
        let mut command = Command::new(&self.program);
        command
            .args([
                "--daemon",
                "--option",
                "allowed-users",
                &allowed,
                "--option",
                "trusted-users",
                "root",
                "--option",
                "min-free",
                "0",
                "--option",
                "system",
                &self.system,
            ])
            .env_clear()
            .env("HOME", "/var/empty")
            .env("LC_ALL", "C")
            .env("PATH", &self.search_path)
            .env("NIX_CONF_DIR", &self.configuration_directory)
            .env("NIX_SSL_CERT_FILE", &self.certificate_bundle)
            .env("LISTEN_PID", std::process::id().to_string())
            .env("LISTEN_FDS", "1");
        Ok(command)
    }
}

fn socket_access(uid: u32, mode: u32, expected: u32) -> Result<()> {
    ensure!(
        uid == expected && mode & 0o7777 == 0o600,
        "native socket is not exclusive to the trusted executor UID"
    );
    Ok(())
}

fn socket_metadata() -> Result<fs::Metadata> {
    let path = Path::new(SOCKET);
    let parent = path.parent().context("native socket parent missing")?;
    let metadata = fs::symlink_metadata(parent)?;
    ensure!(
        metadata.is_dir()
            && metadata.uid() == 0
            && metadata.mode() & 0o022 == 0
            && fs::canonicalize(parent)? == parent,
        "native socket parent is not root-controlled"
    );
    let metadata = fs::symlink_metadata(path)?;
    ensure!(
        metadata.file_type().is_socket(),
        "native socket replaced or redirected"
    );
    Ok(metadata)
}

pub(super) fn socket_identity() -> Result<super::journal::native_phase::FileId> {
    let metadata = socket_metadata()?;
    ensure!(
        metadata.mode() & 0o7777 == 0o600,
        "native socket permissions changed"
    );
    Ok(super::journal::native_phase::FileId {
        device: metadata.dev(),
        inode: metadata.ino(),
    })
}

pub(super) fn store_path(path: &Path) -> Result<()> {
    let text = path.to_str().context("non-UTF8 daemon path")?;
    let normalized: PathBuf = path.components().collect();
    ensure!(
        text.len() <= 4096
            && !text.as_bytes().contains(&0)
            && normalized.as_os_str() == path.as_os_str()
            && !path
                .components()
                .any(|c| c == std::path::Component::ParentDir),
        "invalid daemon path"
    );
    let rest = text
        .strip_prefix("/nix/store/")
        .context("daemon path outside store")?;
    // writeText/linkFarm declarations may be the store object itself. Fixed
    // executable basenames and resolved file types are checked by their users.
    let package = rest
        .split('/')
        .next()
        .context("daemon store object missing")?;
    super::request::store_path(&format!("/nix/store/{package}"))
        .context("invalid daemon package path")
}

// Root-owned symlinks (e.g. /etc -> generated store files) are allowed. Both
// requested and resolved ancestry must be trusted; sticky shared parents need
// a root-owned child. No leaf-only permission test or alternate authority.
pub fn trusted_path(path: &Path) -> Result<()> {
    ensure!(
        path.is_absolute(),
        "daemon declaration path must be absolute"
    );
    for ancestor in path.ancestors() {
        let metadata = fs::symlink_metadata(ancestor)?;
        ensure!(metadata.uid() == 0, "daemon policy has foreign ancestry");
        ensure!(
            metadata.file_type().is_symlink()
                || metadata.mode() & 0o022 == 0
                || (metadata.is_dir() && metadata.mode() & 0o1000 != 0),
            "daemon policy has writable ancestry"
        );
    }
    Ok(())
}

pub fn read_declaration(path: &Path) -> Result<Vec<u8>> {
    trusted_path(path)?;
    let resolved = fs::canonicalize(path)?;
    trusted_path(&resolved)?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&resolved)?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file() && metadata.uid() == 0 && metadata.mode() & 0o022 == 0,
        "daemon declaration is not root-controlled"
    );
    let mut bytes = Vec::new();
    file.take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= MAX_BYTES,
        "daemon declaration exceeds bound"
    );
    Ok(bytes)
}

pub(super) fn executable(path: &Path) -> Result<()> {
    store_path(path)?;
    trusted_path(path)?;
    let resolved = fs::canonicalize(path)?;
    store_path(&resolved)?;
    trusted_path(&resolved)?;
    let metadata = fs::metadata(resolved)?;
    ensure!(
        metadata.is_file() && metadata.mode() & 0o111 != 0,
        "installed executable unavailable"
    );
    Ok(())
}

fn activation(pid: Option<&str>, count: Option<&str>) -> Result<UnixListener> {
    ensure!(
        pid == Some(std::process::id().to_string().as_str()) && count == Some("1"),
        "one native activation socket required"
    );
    for (option, expected) in [
        (libc::SO_TYPE, libc::SOCK_STREAM),
        (libc::SO_DOMAIN, libc::AF_UNIX),
        (libc::SO_ACCEPTCONN, 1),
    ] {
        let mut value: libc::c_int = -1;
        let mut length = std::mem::size_of_val(&value) as libc::socklen_t;
        ensure!(
            unsafe {
                libc::getsockopt(
                    3,
                    libc::SOL_SOCKET,
                    option,
                    (&mut value as *mut libc::c_int).cast(),
                    &mut length,
                )
            } == 0
                && value == expected
                && length as usize == std::mem::size_of_val(&value),
            "native listening Unix socket required"
        );
    }
    let fd = unsafe { libc::fcntl(3, libc::F_DUPFD_CLOEXEC, 4) };
    ensure!(fd >= 0, std::io::Error::last_os_error());
    Ok(unsafe { UnixListener::from_raw_fd(fd) })
}

/// Only FD0..3 survive, with FD3 the validated native listener. Interlocks and
/// any unrelated non-CLOEXEC descriptors close atomically on successful exec.
fn handoff(command: &mut Command, listener: &UnixListener) -> Result<()> {
    // Direct execve avoids Command::exec's process-wide SIGPIPE reset. No signal
    // disposition, mask or pending signal is changed/consumed before exec.
    let program = CString::new(command.get_program().as_bytes())?;
    let args = std::iter::once(command.get_program())
        .chain(command.get_args())
        .map(|arg| CString::new(arg.as_bytes()))
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let environment = command
        .get_envs()
        .map(|(key, value)| {
            let value = value.context("daemon environment removal unsupported")?;
            let mut bytes = key.as_bytes().to_vec();
            bytes.push(b'=');
            bytes.extend(value.as_bytes());
            Ok(CString::new(bytes)?)
        })
        .collect::<Result<Vec<_>>>()?;
    let argv: Vec<_> = args
        .iter()
        .map(|s| s.as_ptr())
        .chain(std::iter::once(std::ptr::null()))
        .collect();
    let envp: Vec<_> = environment
        .iter()
        .map(|s| s.as_ptr())
        .chain(std::iter::once(std::ptr::null()))
        .collect();
    // Unshare the descriptor table first; no unrelated thread's FD flags change.
    ensure!(
        unsafe {
            libc::syscall(
                libc::SYS_close_range,
                4u32,
                u32::MAX,
                libc::CLOSE_RANGE_CLOEXEC | libc::CLOSE_RANGE_UNSHARE,
            )
        } == 0,
        std::io::Error::last_os_error()
    );
    ensure!(
        unsafe { libc::dup2(listener.as_raw_fd(), 3) } == 3,
        std::io::Error::last_os_error()
    );
    unsafe {
        libc::execve(program.as_ptr(), argv.as_ptr(), envp.as_ptr());
    }
    Err(std::io::Error::last_os_error().into())
}

pub(super) fn validate_source_account(uid: u32, user: &str) -> Result<()> {
    peers::validate(&[Client {
        uid,
        user: user.to_owned(),
    }])
}

pub(super) fn verify_source_account(uid: u32, user: &str) -> Result<()> {
    peers::verify(&[Client {
        uid,
        user: user.to_owned(),
    }])
}

pub(super) fn now() -> Result<u64> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs())
}

/// Shared installed root declaration loader. No authority initialization,
/// recovery grant, proxying or local-store fallback.
pub(super) fn open_authority(policy_path: &Path, control_path: &Path) -> Result<Authority> {
    workload::require_wrapper_placement()?;
    open_existing_authority(policy_path, control_path)
}

pub(super) fn open_controller_authority(
    policy_path: &Path,
    control_path: &Path,
    attempt: &str,
) -> Result<Authority> {
    workload::require_controller_placement(attempt)?;
    open_existing_authority(policy_path, control_path)
}

pub(super) fn open_maintenance_request_authority(
    policy_path: &Path,
    control_path: &Path,
) -> Result<Authority> {
    workload::require_maintenance_request_placement()?;
    open_existing_authority(policy_path, control_path)
}

pub(super) fn open_supervisor_authority(
    policy_path: &Path,
    control_path: &Path,
) -> Result<Authority> {
    workload::require_supervisor_placement()?;
    open_existing_authority(policy_path, control_path)
}

pub(super) fn declarations(
    policy_path: &Path,
    control_path: &Path,
) -> Result<(Policy, control::Config)> {
    ensure!(
        unsafe { libc::getuid() } == 0
            && unsafe { libc::geteuid() } == 0
            && unsafe { libc::getgid() } == 0
            && unsafe { libc::getegid() } == 0,
        "owned role requires root"
    );
    let policy = Policy::load(policy_path)?;
    let config: control::Config = serde_json::from_slice(&read_declaration(control_path)?)
        .map_err(|_| anyhow::anyhow!("invalid installed control declaration"))?;
    config.validate()?;
    peers::validate_workload(&policy.clients, &config.workload_uids)?;
    ensure!(
        config.policy.capacity_digest == policy.digest()?
            && config.binding_digest()? == policy.control_digest,
        "daemon policy binding mismatch"
    );
    ensure!(
        fs::canonicalize(&policy.launcher)? == std::env::current_exe()?,
        "daemon launcher differs"
    );
    for path in [&policy.launcher, &policy.program] {
        executable(path)?;
    }
    for path in [&policy.configuration_directory, &policy.certificate_bundle] {
        trusted_path(path)?;
        let resolved = fs::canonicalize(path)?;
        store_path(&resolved)?;
        trusted_path(&resolved)?;
    }
    ensure!(
        policy.configuration_directory.is_dir() && policy.certificate_bundle.is_file(),
        "daemon configuration unavailable"
    );
    Ok((policy, config))
}

fn open_existing_authority(policy_path: &Path, control_path: &Path) -> Result<Authority> {
    let (policy, config) = declarations(policy_path, control_path)?;
    let root = state_root(
        std::env::var_os("XDG_STATE_HOME").as_deref().map(Path::new),
        std::env::var_os("HOME").as_deref().map(Path::new),
    )?;
    super::bootstrap::validate(&root, &config.policy.capacity_digest)?;
    super::store_binding::validate(&root, &config.identity)?;
    let journal = Journal::open(&root, config.identity.clone(), config.policy)?;
    let gate = Gate::open(&root.join("launch"), config.identity.clone())?;
    Ok(Authority {
        policy,
        journal,
        gate,
    })
}

/// Existing root authority only; no initialization, migration or recovery.
pub(super) struct Authority {
    pub policy: Policy,
    pub journal: Journal,
    pub gate: Gate,
}

/// Preserve native activation and native peer authentication; no root relay.
pub fn run_service(policy_path: &Path, control_path: &Path) -> Result<()> {
    let Authority {
        policy,
        journal,
        gate,
    } = open_authority(policy_path, control_path)?;
    workload::require_daemon_placement()?;
    let listener = activation(
        std::env::var("LISTEN_PID").ok().as_deref(),
        std::env::var("LISTEN_FDS").ok().as_deref(),
    )?;
    ensure!(
        listener.local_addr()?.as_pathname() == Some(Path::new(SOCKET)),
        "unexpected native socket"
    );
    // Descriptor validation retains native socket activation and native peer UID
    // authentication. It does not establish socket/all-ingress policy by itself.
    let role = super::role::Policy::load(&policy.role_policy)?;
    ensure!(
        role.digest()? == policy.containment_digest,
        "native executor role binding differs"
    );
    policy.require_executor(&role.build)?;
    let socket = policy.require_socket()?;
    let owner = journal.daemon_owner(now()?)?;
    let _launch = gate
        .authorize(&Permit {
            version: 1,
            identity: journal.identity().clone(),
            permission: Permission::Execution {
                ownership: owner.clone(),
            },
        })?
        .context("daemon launch pending")?;
    ensure!(
        journal.daemon_owner(now()?)? == owner,
        "daemon owner changed"
    );
    ensure!(
        listener.as_raw_fd() > 3,
        "activation retention overlaps native descriptor"
    );
    let handle = super::ExecutionHandle {
        ownership: owner.clone(),
        invocation_id: std::env::var("INVOCATION_ID")
            .map_err(|_| anyhow::anyhow!("daemon invocation unavailable"))?,
    };
    // A failed exec or lost service/controller never permits a second native
    // daemon for this owner. Connection workers can outlive the daemon parent.
    let phase = super::native_phase::Gate::open(&journal, owner.clone())?;
    phase.require_open(&journal)?;
    let kind = journal.begin_daemon(handle, now()?)?;
    phase.start_native(&journal, socket)?;
    peers::verify(&policy.clients)?;
    ensure!(
        journal.daemon_owner(now()?)? == owner,
        "daemon owner changed"
    );
    handoff(&mut policy.command(kind, &owner)?, &listener)
}

#[cfg(test)]
mod tests;
