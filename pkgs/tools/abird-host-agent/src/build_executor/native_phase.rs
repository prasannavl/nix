//! One monotonic root-side command gate per worker. Upstream Nix receives no
//! phase descriptor; trusted clients cannot launch writers after closure.
//! Writer settlement uses the frozen original unit, never a daemon restart.

use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, ensure};

use super::journal::native_phase::{FileId, NativePhase};
use super::journal::{Journal, open_directory};
use super::stage::ProducerGroup;
use super::{ExecutionHandle, Ownership, daemon, workload};

/// Private binding captured by the original daemon wrapper before exec.
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(in crate::build_executor) struct Runtime {
    unit: FileId,
    producer: FileId,
    listener: FileId,
    socket: FileId,
    process: Process,
}

impl Runtime {
    pub(super) fn validate(&self) -> Result<()> {
        ensure!(
            self.process.pid > 1
                && self.process.pid <= i32::MAX as u32
                && self.process.start_ticks > 0
                && self.unit.inode > 0
                && self.producer.inode > 0
                && self.listener.inode > 0
                && self.socket.inode > 0
                && self.unit.device == self.producer.device
                && self.unit.device == self.listener.device
                && self.unit != self.producer
                && self.unit != self.listener
                && self.producer != self.listener,
            "invalid native runtime binding"
        );
        Ok(())
    }

    fn groups(&self) -> Result<(ProducerGroup, ProducerGroup, ProducerGroup)> {
        self.validate()?;
        let base = Path::new(workload::CGROUP).join("nix-daemon.service");
        let unit = ProducerGroup::open(base.clone())?;
        let producer = ProducerGroup::open(base.join("producer"))?;
        let listener = ProducerGroup::open(base.join("listener"))?;
        ensure!(
            unit.identity()? == self.unit
                && producer.identity()? == self.producer
                && listener.identity()? == self.listener,
            "original native groups differ"
        );
        Ok((unit, producer, listener))
    }

    fn sealed_listener(&self) -> Result<LiveProcess> {
        let process = LiveProcess::open(self.process.clone())?;
        let (unit, producer, _) = self.groups()?;
        ensure!(
            !unit.freeze_requested()? && !unit.event("frozen")?,
            "native listener is still frozen"
        );
        process.placed("listener")?;
        ensure!(
            producer.empty()?,
            "native writer subtree changed after settlement"
        );
        process.alive()?;
        Ok(process)
    }
}

#[derive(Clone, Deserialize, Serialize, Eq, PartialEq)]
#[serde(deny_unknown_fields)]
struct Process {
    pid: u32,
    #[serde(rename = "start")]
    start_ticks: u64,
}

fn bounded_proc(pid: u32, name: &str) -> Result<String> {
    let mut value = String::new();
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(format!("/proc/{pid}/{name}"))?
        .take(4097)
        .read_to_string(&mut value)?;
    ensure!(
        value.len() <= 4096,
        "native process observation exceeds bound"
    );
    Ok(value)
}

fn start_ticks(pid: u32, value: &str) -> Result<u64> {
    let (prefix, fields) = value
        .rsplit_once(") ")
        .context("invalid native process stat")?;
    ensure!(
        prefix
            .split_once(" (")
            .and_then(|(id, _)| id.parse::<u32>().ok())
            == Some(pid),
        "native process stat identity differs"
    );
    let ticks = fields
        .split_ascii_whitespace()
        .nth(19)
        .context("native process start time missing")?
        .parse::<u64>()?;
    ensure!(ticks > 0, "invalid native process start time");
    Ok(ticks)
}

struct LiveProcess {
    identity: Process,
    descriptor: File,
}
impl LiveProcess {
    fn open(identity: Process) -> Result<Self> {
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, identity.pid, 0) };
        ensure!(fd >= 0, std::io::Error::last_os_error());
        let process = Self {
            identity,
            descriptor: unsafe { File::from_raw_fd(fd as i32) },
        };
        process.alive()?;
        ensure!(
            start_ticks(
                process.identity.pid,
                &bounded_proc(process.identity.pid, "stat")?
            )? == process.identity.start_ticks,
            "native process was replaced"
        );
        process.alive()?;
        Ok(process)
    }

    fn alive(&self) -> Result<()> {
        let mut item = libc::pollfd {
            fd: self.descriptor.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        ensure!(
            unsafe { libc::poll(&mut item, 1, 0) } == 0,
            "original native listener exited or is unobservable"
        );
        Ok(())
    }

    fn producer_location(&self) -> Result<String> {
        self.alive()?;
        let observed = bounded_proc(self.identity.pid, "cgroup")?;
        let location = producer_location(&observed)?;
        self.alive()?;
        Ok(location.to_owned())
    }

    fn placed(&self, group: &str) -> Result<()> {
        self.alive()?;
        ensure!(
            bounded_proc(self.identity.pid, "cgroup")?
                == format!("0::{}/nix-daemon.service/{group}\n", workload::RELATIVE),
            "original native listener placement differs"
        );
        self.alive()
    }
}

fn producer_location(observed: &str) -> Result<&'static str> {
    // Upstream's delegated mode moves the listener into nix-daemon beneath
    // its cached root; classic mode remains directly in producer.
    for location in ["producer", "producer/nix-daemon"] {
        if observed == format!("0::{}/nix-daemon.service/{location}\n", workload::RELATIVE) {
            return Ok(location);
        }
    }
    anyhow::bail!("native listener left the original producer subtree")
}

// A lost thaw is not settlement; the aggregate supervisor still owns this unit.
struct Frozen<'a>(&'a ProducerGroup);
impl<'a> Frozen<'a> {
    fn begin(group: &'a ProducerGroup) -> Result<Self> {
        ensure!(
            !group.freeze_requested()?,
            "native unit already frozen by another operation"
        );
        let guard = Self(group);
        group.freeze(true)?;
        Ok(guard)
    }
    fn thaw(self) -> Result<()> {
        self.0.freeze(false)?;
        std::mem::forget(self);
        Ok(())
    }
}
impl Drop for Frozen<'_> {
    fn drop(&mut self) {
        let _ = self.0.freeze(false);
    }
}

fn pause(deadline: Instant) -> Result<()> {
    ensure!(
        Instant::now() < deadline,
        "native producer settlement deadline expired"
    );
    std::thread::park_timeout(
        Duration::from_millis(10).min(deadline.saturating_duration_since(Instant::now())),
    );
    Ok(())
}

/// Installed root worker entry: consume the worker claim and provision its
/// native gate before any helper/import/evaluation. No retry after uncertainty.
/// Caller separately owns the immutable role and store-exclusion proof.
pub fn begin_worker(
    journal: &Journal,
    gate: &super::launch_gate::Gate,
    handle: ExecutionHandle,
    now: u64,
) -> Result<()> {
    ensure!(
        unsafe { libc::getuid() } == 0 && unsafe { libc::geteuid() } == 0,
        "installed worker requires root"
    );
    workload::require_client_placement(&handle.ownership)?;
    ensure!(
        journal.identity() == gate.identity(),
        "worker gate identity differs"
    );
    let _launch = gate
        .authorize(&super::launch_gate::Permit {
            version: 1,
            identity: journal.identity().clone(),
            permission: super::launch_gate::Permission::Execution {
                ownership: handle.ownership.clone(),
            },
        })?
        .context("installed worker launch fenced")?;
    journal.begin_worker(handle.clone(), now)?;
    Gate::create(journal, handle.ownership.clone(), daemon::now()?)?;
    ensure!(
        journal.daemon_owner(daemon::now()?)? == handle.ownership,
        "installed worker deadline or authority changed"
    );
    Ok(())
}

fn path(journal: &Journal, owner: &Ownership) -> Result<PathBuf> {
    super::digest(&owner.attempt_id)?;
    Ok(journal
        .authority_root()
        .join(format!("native-{}.gate", owner.attempt_id)))
}

fn identity(file: &File) -> Result<FileId> {
    let meta = file.metadata()?;
    ensure!(
        meta.is_file()
            && meta.uid() == 0
            && meta.mode() & 0o7777 == 0o600
            && meta.nlink() == 1
            && meta.len() == 1,
        "native gate identity or permissions differ"
    );
    Ok(FileId {
        device: meta.dev(),
        inode: meta.ino(),
    })
}

pub(super) struct Gate {
    owner: Ownership,
    file: File,
    id: FileId,
}

impl Gate {
    /// Register before exclusive creation. Any uncertain creation is consumed;
    /// neither daemon startup nor worker recovery may create a replacement.
    pub(super) fn create(journal: &Journal, owner: Ownership, now: u64) -> Result<Self> {
        ensure!(unsafe { libc::geteuid() } == 0, "native gate requires root");
        workload::require_client_placement(&owner)?;
        journal.register_native_phase(&owner, now)?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path(journal, &owner)?)?;
        file.write_all_at(b"0", 0)?;
        file.sync_all()?;
        open_directory(journal.authority_root())?.sync_all()?;
        let id = identity(&file)?;
        journal.bind_native_phase(&owner, id.clone(), daemon::now()?)?;
        Ok(Self { owner, file, id })
    }

    pub(super) fn open(journal: &Journal, owner: Ownership) -> Result<Self> {
        let phase = journal.native_phase(&owner)?;
        ensure!(!phase.retired, "native gate retired");
        let id = phase.file.context("native gate not bound")?;
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path(journal, &owner)?)?;
        ensure!(identity(&file)? == id, "native gate replaced");
        Ok(Self { owner, file, id })
    }

    fn byte(&self) -> Result<u8> {
        ensure!(identity(&self.file)? == self.id, "native gate changed");
        let mut byte = [0];
        self.file.read_exact_at(&mut byte, 0)?;
        ensure!(matches!(byte[0], b'0' | b'1'), "invalid native gate byte");
        Ok(byte[0])
    }

    pub(super) fn validate(&self, journal: &Journal) -> Result<()> {
        let phase = journal.native_phase(&self.owner)?;
        ensure!(
            !phase.retired && (phase.sealed_at.is_some() || self.byte()? == b'0'),
            "native phase byte differs from intent"
        );
        self.byte()?;
        Ok(())
    }

    pub(super) fn require_open(&self, journal: &Journal) -> Result<()> {
        let phase = journal.native_phase(&self.owner)?;
        ensure!(
            !phase.retired && phase.sealed_at.is_none() && self.byte()? == b'0',
            "native execution already sealed"
        );
        Ok(())
    }

    pub(super) fn authorize_command(&self, journal: &Journal, verification: bool) -> Result<()> {
        if let Some(runtime) = journal.native_phase(&self.owner)?.runtime {
            ensure!(
                daemon::socket_identity()? == runtime.socket,
                "original native endpoint replaced"
            );
        }
        if verification {
            self.require_sealed(journal)
        } else {
            self.require_open(journal)
        }
    }

    /// Exclusive groups belong to the original unit, not to upstream Nix.
    pub(super) fn start_native(&self, journal: &Journal, socket: FileId) -> Result<()> {
        workload::require_daemon_placement()?;
        self.require_open(journal)?;
        let base = Path::new(workload::CGROUP).join("nix-daemon.service");
        let unit = ProducerGroup::open(base.clone())?;
        for name in ["producer", "listener"] {
            fs::create_dir(base.join(name))?;
        }
        let producer = ProducerGroup::open(base.join("producer"))?;
        let listener = ProducerGroup::open(base.join("listener"))?;
        ensure!(
            producer.empty()? && listener.empty()?,
            "new native groups are populated"
        );
        let pid = std::process::id();
        let runtime = Runtime {
            unit: unit.identity()?,
            producer: producer.identity()?,
            listener: listener.identity()?,
            socket,
            process: Process {
                pid,
                start_ticks: start_ticks(pid, &bounded_proc(pid, "stat")?)?,
            },
        };
        journal.bind_native_runtime(&self.owner, runtime, daemon::now()?)?;
        producer.place(pid)?;
        ensure!(
            bounded_proc(pid, "cgroup")?
                == format!("0::{}/nix-daemon.service/producer\n", workload::RELATIVE),
            "native initial placement differs"
        );
        self.require_open(journal)
    }

    pub(super) fn require_sealed(&self, journal: &Journal) -> Result<()> {
        let phase = journal.native_phase(&self.owner)?;
        ensure!(
            !phase.retired
                && phase.sealed_at.is_some()
                && phase.writers_settled_at.is_some()
                && self.byte()? == b'1',
            "native execution not sealed"
        );
        let runtime = phase.runtime.context("native runtime not bound")?;
        ensure!(
            daemon::socket_identity()? == runtime.socket,
            "original native endpoint replaced"
        );
        // Empty writers do not prove the original listener/unit survived.
        // Recheck all three bound groups and the same live process before use.
        runtime.sealed_listener()?;
        Ok(())
    }

    /// Freeze the original unit before separating its bound listener. Only a
    /// positively empty producer subtree permits verification-only commands.
    /// Upstream Nix itself has no operation guard; trusted ingress is mandatory.
    pub(super) fn seal_and_settle(
        &self,
        journal: &Journal,
        units: &mut super::units::Units,
        definitions: &[PathBuf],
        program: &Path,
        deadline: Instant,
    ) -> Result<()> {
        workload::require_client_placement(&self.owner)?;
        self.require_open(journal)?;
        let runtime = journal
            .native_phase(&self.owner)?
            .runtime
            .context("native runtime not bound")?;
        let process = LiveProcess::open(runtime.process.clone())?;
        ensure!(
            fs::read_link(format!("/proc/{}/exe", process.identity.pid))?
                == fs::canonicalize(program)?,
            "original listener is not the installed native program"
        );
        let handle = journal
            .claimed_daemon(&self.owner)?
            .context("native producer claim missing")?;
        let active = || -> Result<()> {
            ensure!(
                Instant::now() < deadline && journal.daemon_owner(daemon::now()?)? == self.owner,
                "native sealing authority expired"
            );
            process.alive()
        };
        active()?;
        units.require_definition("nix-daemon.service", definitions)?;
        let producer = ProducerGroup::native(&handle, &units.daemon()?)?;
        let base = Path::new(workload::CGROUP).join("nix-daemon.service");
        let (unit, original_producer, listener) = runtime.groups()?;
        ensure!(
            producer.identity()? == original_producer.identity()? && listener.empty()?,
            "original native groups differ"
        );
        let location = process.producer_location()?;
        let resume = ProducerGroup::open(base.join(&location))?;
        process.placed(&location)?;
        journal.seal_native_phase(&self.owner, daemon::now()?)?;
        let writer = OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path(journal, &self.owner)?)?;
        ensure!(identity(&writer)? == self.id, "native seal target replaced");
        writer.write_all_at(b"1", 0)?;
        writer.sync_all()?;
        loop {
            active()?;
            let frozen = Frozen::begin(&unit)?;
            while !unit.event("frozen")? {
                active()?;
                pause(deadline)?;
            }
            active()?;
            process.placed(&location)?;
            listener.place(process.identity.pid)?;
            process.placed("listener")?;
            if producer.empty()? {
                active()?;
                ensure!(
                    unit.event("frozen")?,
                    "native unit thawed during settlement"
                );
                journal.settle_native_writers(&self.owner, daemon::now()?)?;
                frozen.thaw()?;
                while unit.event("frozen")? {
                    active()?;
                    pause(deadline)?;
                }
                active()?;
                // Verification connections inherit listener, not the now-empty
                // writer subtree. Their eventual settlement is still separate.
                self.require_sealed(journal)?;
                return Ok(());
            }
            resume.place(process.identity.pid)?;
            process.placed(&location)?;
            frozen.thaw()?;
            pause(deadline)?;
        }
    }

    pub(super) fn retire(
        journal: &Journal,
        owner: &Ownership,
        mut active: impl FnMut() -> Result<()>,
    ) -> Result<()> {
        journal.native_phase_releasable(owner)?;
        let record = journal.native_phase(owner)?;
        ensure!(!record.retired, "native gate retirement already consumed");
        super::retirement::file::remove(
            &path(journal, owner)?,
            record.file.as_ref(),
            1,
            &mut active,
        )?;
        journal.retire_native_phase(owner, daemon::now()?)
    }
}

pub(super) fn retired(journal: &Journal, record: &NativePhase, owner: &Ownership) -> Result<bool> {
    if !record.retired {
        return Ok(false);
    }
    match fs::symlink_metadata(path(journal, owner)?) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
        Ok(_) => anyhow::bail!("retired native gate reappeared"),
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests;
