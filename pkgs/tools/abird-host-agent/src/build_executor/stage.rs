//! Root-owned producer subgroups inside one admitted attempt. Direct-child exit
//! is not settlement; input/output sealing waits for positive producer emptiness.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};

use super::{ExecutionHandle, Ownership, diagnostics::Activity, units::Unit, workload};

pub(super) enum SourceStep {
    Restore,
    Import,
    Hash,
}

pub(super) enum Step {
    Capture,
    Resolve,
    Source,
    CallerCheckout,
    SourceCheck,
    SourceImport,
    Prepare,
    Realize,
}
impl Step {
    fn activity(&self) -> Activity {
        match self {
            Self::Capture => Activity::Capture,
            Self::Resolve => Activity::Resolve,
            Self::Source => Activity::Source,
            Self::CallerCheckout => Activity::SourceCheckout,
            Self::SourceCheck => Activity::SourceCheck,
            Self::SourceImport => Activity::SourceImport,
            Self::Prepare => Activity::Prepare,
            Self::Realize => Activity::Realize,
        }
    }
    fn name(&self) -> &'static str {
        match self {
            Self::Capture => "capture",
            Self::Resolve => "resolve",
            Self::Source => "source",
            Self::SourceCheck => "source-check",
            Self::SourceImport => "source-import",
            Self::CallerCheckout => "caller-checkout",
            Self::Prepare => "prepare",
            Self::Realize => "realize",
        }
    }
}

pub(super) struct ProducerGroup {
    path: PathBuf,
    directory: File,
}

impl ProducerGroup {
    pub(super) fn open(path: PathBuf) -> Result<Self> {
        let directory = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&path)?;
        let value = Self { path, directory };
        value.validate()?;
        Ok(value)
    }

    /// Caller has matched the actual loaded native unit definitions to its
    /// immutable policy. Never construct this observation from caller claims.
    pub(super) fn native(handle: &ExecutionHandle, unit: &Unit) -> Result<Self> {
        ensure!(
            unit.id == "nix-daemon.service"
                && unit.active == "active"
                && unit.sub == "running"
                && unit.job == "0"
                && unit.invocation.as_deref() == Some(handle.invocation_id.as_str())
                && unit.cgroup == format!("{}/nix-daemon.service", workload::RELATIVE),
            "native producer invocation differs"
        );
        Self::open(Path::new(workload::CGROUP).join("nix-daemon.service/producer"))
    }

    fn validate(&self) -> Result<()> {
        let observed = self.directory.metadata()?;
        let current = fs::symlink_metadata(&self.path)?;
        ensure!(
            current.is_dir()
                && current.uid() == 0
                && current.mode() & 0o022 == 0
                && current.dev() == observed.dev()
                && current.ino() == observed.ino()
                && fs::canonicalize(&self.path)? == self.path,
            "producer subgroup replaced"
        );
        let mut filesystem: libc::statfs = unsafe { std::mem::zeroed() };
        ensure!(
            unsafe { libc::fstatfs(self.directory.as_raw_fd(), &mut filesystem) } == 0
                && filesystem.f_type == libc::CGROUP2_SUPER_MAGIC,
            "producer cgroup filesystem differs"
        );
        Ok(())
    }

    pub(super) fn identity(&self) -> Result<super::journal::native_phase::FileId> {
        self.validate()?;
        let meta = self.directory.metadata()?;
        Ok(super::journal::native_phase::FileId {
            device: meta.dev(),
            inode: meta.ino(),
        })
    }

    fn member(&self, name: &std::ffi::CStr, flags: i32) -> Result<File> {
        self.validate()?;
        let fd = unsafe {
            libc::openat(
                self.directory.as_raw_fd(),
                name.as_ptr(),
                flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        ensure!(fd >= 0, std::io::Error::last_os_error());
        Ok(unsafe { std::os::fd::FromRawFd::from_raw_fd(fd) })
    }

    pub(super) fn place(&self, pid: u32) -> Result<()> {
        self.member(c"cgroup.procs", libc::O_WRONLY)?
            .write_all(format!("{pid}\n").as_bytes())?;
        self.validate()
    }

    pub(super) fn freeze_requested(&self) -> Result<bool> {
        let mut bytes = String::new();
        self.member(c"cgroup.freeze", libc::O_RDONLY)?
            .take(3)
            .read_to_string(&mut bytes)?;
        self.validate()?;
        match bytes.as_str() {
            "0\n" => Ok(false),
            "1\n" => Ok(true),
            _ => anyhow::bail!("invalid native freezer request"),
        }
    }

    pub(super) fn freeze(&self, frozen: bool) -> Result<()> {
        self.member(c"cgroup.freeze", libc::O_WRONLY)?
            .write_all(if frozen { b"1" } else { b"0" })?;
        self.validate()
    }

    pub(super) fn event(&self, key: &str) -> Result<bool> {
        let mut contents = String::new();
        self.member(c"cgroup.events", libc::O_RDONLY)?
            .take(4097)
            .read_to_string(&mut contents)?;
        ensure!(contents.len() <= 4096, "producer observation exceeds bound");
        let value = event(&contents, key)?;
        self.validate()?;
        Ok(value)
    }

    pub(super) fn empty(&self) -> Result<bool> {
        Ok(!self.event("populated")?)
    }

    /// ACK does not permit sealing, retirement or success: observe empty().
    pub(super) fn request_stop(&self) -> Result<()> {
        self.member(c"cgroup.kill", libc::O_WRONLY)?
            .write_all(b"1")?;
        self.validate()
    }
}

fn event(contents: &str, key: &str) -> Result<bool> {
    let mut found = None;
    let mut names = std::collections::BTreeSet::new();
    for line in contents.lines() {
        let (name, value) = line
            .split_once(' ')
            .context("invalid producer observation")?;
        let value: u64 = value.parse()?;
        ensure!(names.insert(name), "duplicate producer observation");
        if name == key {
            ensure!(value <= 1, "ambiguous producer observation");
            found = Some(value != 0);
        }
    }
    found.context("missing producer observation")
}

pub struct Stage {
    group: ProducerGroup,
    process: File,
    claimed: bool,
    activity: Activity,
}

impl Stage {
    /// Exclusive creation, after the worker's durable one-shot claim. Never
    /// adopt or recreate missing/replaced producer data during recovery.
    pub(super) fn create(owner: &Ownership, step: Step) -> Result<Self> {
        Self::named(owner, step.name(), step.activity())
    }

    /// Caller-only role: same root-owned producer boundary, subordinate to the
    /// original builder admission rather than a second local build owner.
    pub(super) fn capture(attempt: &str, ordinal: u16) -> Result<Self> {
        ensure!(ordinal < 32, "capture stage count exceeds bound");
        super::capture_role::require_placement(attempt)?;
        let parent = Path::new(workload::BUDGET_CGROUP).join(super::capture_role::unit(attempt)?);
        let path = parent.join(format!("capture-{ordinal:02}"));
        fs::create_dir(&path)?;
        let process = OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path.join("cgroup.procs"))?;
        let group = ProducerGroup::open(path)?;
        ensure!(group.empty()?, "new capture producer is populated");
        Ok(Self {
            group,
            process,
            claimed: false,
            activity: Activity::Capture,
        })
    }

    /// Sequential verifier commands each get their own one-shot subgroup.
    /// The worker claim prevents a new process from restarting this sequence.
    pub(super) fn verification(owner: &Ownership, ordinal: u16) -> Result<Self> {
        ensure!(ordinal < 1028, "verification command count exceeds bound");
        Self::named(owner, &format!("verify-{ordinal:04}"), Activity::Verify)
    }

    pub(super) fn input_transport(owner: &Ownership, ordinal: u16) -> Result<Self> {
        ensure!(ordinal < 8, "input SSH connection bound exceeded");
        Self::named(owner, &format!("input-ssh-{ordinal:02}"), Activity::Receive)
    }

    pub(super) fn input(owner: &Ownership, ordinal: u16) -> Result<Self> {
        ensure!(
            ordinal < 32,
            "input verification command count exceeds bound"
        );
        Self::named(owner, &format!("input-{ordinal:02}"), Activity::InputVerify)
    }

    pub(super) fn source(owner: &Ownership, operation: SourceStep, ordinal: u16) -> Result<Self> {
        // Slots 16+ are reserved for independent Git roots, not extra retries.
        ensure!(ordinal < 32, "source command count exceeds bound");
        let (name, activity) = match operation {
            SourceStep::Restore => ("restore", Activity::SourceRestore),
            SourceStep::Import => ("import", Activity::SourceImport),
            SourceStep::Hash => ("hash", Activity::SourceHash),
        };
        Self::named(owner, &format!("source-{name}-{ordinal:02}"), activity)
    }

    pub(super) fn activity(&self) -> Activity {
        self.activity
    }
    pub(super) fn verification_only(&self) -> bool {
        self.activity == Activity::Verify
    }

    fn named(owner: &Ownership, name: &str, activity: Activity) -> Result<Self> {
        ensure!(
            unsafe { libc::geteuid() } == 0,
            "producer stage requires root"
        );
        workload::require_client_placement(owner)?;
        let parent = Path::new(workload::CGROUP).join(owner.unit_name()?);
        ensure!(
            fs::canonicalize(&parent)? == parent,
            "producer unit redirected"
        );
        let metadata = fs::metadata(&parent)?;
        ensure!(
            metadata.uid() == 0 && metadata.mode() & 0o022 == 0,
            "producer unit writable"
        );
        let path = parent.join(name);
        fs::create_dir(&path)?;
        let process = OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path.join("cgroup.procs"))?;
        let group = ProducerGroup::open(path)?;
        ensure!(group.empty()?, "new producer stage is populated");
        Ok(Self {
            group,
            process,
            claimed: false,
            activity,
        })
    }

    pub(super) fn claim_process_fd(&mut self) -> Result<i32> {
        self.group.validate()?;
        ensure!(
            !self.claimed && self.empty()?,
            "producer stage already claimed"
        );
        self.claimed = true;
        Ok(self.process.as_raw_fd())
    }

    pub(super) fn empty(&self) -> Result<bool> {
        self.group.empty()
    }
    pub(super) fn request_stop(&self) -> Result<()> {
        self.group.request_stop()
    }
}

#[cfg(test)]
mod tests {
    use super::event;

    #[test]
    fn missing_duplicate_or_unknown_freezer_state_never_proves_quiescence() {
        assert!(event("populated 1\nfrozen 1\n", "frozen").unwrap());
        assert!(!event("populated 0\nfrozen 0\n", "populated").unwrap());
        for value in [
            "populated 0\n",
            "frozen 1\nfrozen 1\n",
            "frozen 2\n",
            "frozen yes\n",
            "frozen 1 extra\n",
        ] {
            assert!(event(value, "frozen").is_err());
        }
    }
}
