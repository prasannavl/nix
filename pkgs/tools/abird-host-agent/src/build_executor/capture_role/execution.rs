//! Exact local unit and original producer groups. The worker stays outside its
//! child groups and can stop them without treating child exit as settlement.

use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, ensure};

use super::{Phase, Policy, Record, State};
use crate::build_executor::{
    Ownership, controller_service, daemon, process,
    stage::{ProducerGroup, Stage},
    workload,
};

pub fn require_placement(attempt: &str) -> Result<()> {
    require_unit(&super::unit(attempt)?)
}

pub fn require_reaper_placement() -> Result<()> {
    require_unit("abird-owned-capture-reap.service")
}

/// Recover only the original one-shot lifetime after startup failure, OOM or
/// caller loss. Stop acknowledgement/process exit alone is never settlement.
pub fn reconcile_unit(
    policy: &Policy,
    state: &State,
    attempt: &str,
    deadline: Instant,
) -> Result<()> {
    require_reaper_placement()?;
    let record = state.read(attempt)?;
    if record.phase.terminal() {
        return Ok(());
    }
    let cutoff = record
        .input
        .reserved_at
        .checked_add(record.input.request.deadlines.runtime_seconds)
        .context("capture cutoff overflow")?;
    let horizon = record
        .input
        .request
        .id
        .issued_at
        .checked_add(record.input.request.deadlines.queue_seconds)
        .and_then(|time| time.checked_add(record.input.request.deadlines.runtime_seconds))
        .context("capture request horizon overflow")?;
    if record.cancelled || daemon::now()? >= cutoff.min(horizon) {
        // Durable before StopUnit; if a launch won the state lock, this records
        // cancellation only. Otherwise the late start is permanently rejected.
        state.status(record.uid, attempt, &record.input.request.digest()?, true)?;
    }
    let record = state.read(attempt)?;
    if record.phase != Phase::Running {
        return Ok(());
    }
    let invocation = record
        .invocation
        .as_deref()
        .context("capture invocation missing")?;
    let mut units =
        crate::build_executor::units::Units::new(policy.systemctl.clone(), Duration::from_secs(2))?
            .with_deadline(deadline);
    if record.cancelled {
        units.stop_capture(attempt, invocation)?;
    }
    let unit = units.capture_unit(attempt)?;
    ensure!(
        unit.invocation.as_deref() == Some(invocation)
            || (unit.stopped() && unit.invocation.is_none()),
        "capture reconciliation found a different invocation"
    );
    // Running was committed before any producer; it consumes the sole launch.
    // No successor can appear after these observations, including when systemd
    // collected the inactive unit. Require actual kernel emptiness as well.
    if unit.stopped() && workload::capture_empty(attempt)? {
        state.update(attempt, |current| {
            if current.phase.terminal() {
                return Ok(());
            }
            ensure!(
                current.phase == Phase::Running
                    && current.invocation.as_deref() == Some(invocation),
                "capture lifetime changed during reconciliation"
            );
            current.phase = Phase::Settled;
            current.settled_at = Some(daemon::now()?);
            Ok(())
        })?;
    }
    Ok(())
}

fn require_unit(unit: &str) -> Result<()> {
    ensure!(
        unsafe { libc::getuid() } == 0 && unsafe { libc::geteuid() } == 0,
        "capture wrapper requires root"
    );
    let mut group = String::new();
    File::open("/proc/self/cgroup")?
        .take(4097)
        .read_to_string(&mut group)?;
    ensure!(
        group == format!("0::{}/{unit}\n", workload::BUDGET_RELATIVE),
        "capture unit placement differs"
    );
    Ok(())
}

/// Trusted transport children only. Source helpers use Runner and its prepared
/// offline scope instead; they never get the relay key or this control context.
pub fn caller_credentials(command: &mut Command, account: &controller_service::Account) {
    let (uid, gid, groups) = (account.uid, account.gid, account.groups.clone());
    unsafe {
        command.pre_exec(move || {
            process::child_credentials(uid, gid, &groups)?;
            if libc::syscall(
                libc::SYS_close_range,
                3u32,
                u32::MAX,
                libc::CLOSE_RANGE_CLOEXEC | libc::CLOSE_RANGE_UNSHARE,
            ) != 0
            {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

pub struct TransportScope {
    process: File,
    policy: Policy,
    attempt: String,
    deadline: Instant,
    stopped: Arc<AtomicBool>,
    next_check: Mutex<Instant>,
}

impl TransportScope {
    pub(in crate::build_executor) fn material_limit(&self) -> Result<usize> {
        super::super::preparation::source::material_limit(self.policy.limits)
    }

    pub(in crate::build_executor) fn require_deadline(&self, deadline: Instant) -> Result<()> {
        ensure!(
            deadline <= self.deadline,
            "capture transport deadline exceeds admission"
        );
        self.active()
    }

    pub fn active(&self) -> Result<()> {
        ensure!(
            !self.stopped.load(Ordering::Acquire) && Instant::now() < self.deadline,
            "capture transport stopped or expired"
        );
        let mut next = self
            .next_check
            .lock()
            .map_err(|_| anyhow::anyhow!("capture transport poisoned"))?;
        if Instant::now() >= *next {
            let record = State::open(&self.policy)?.read(&self.attempt)?;
            ensure!(
                record.phase == Phase::Running
                    && !record.cancelled
                    && record
                        .cutoff
                        .is_none_or(|cutoff| daemon::now().is_ok_and(|now| now < cutoff)),
                "capture transport cancelled or expired"
            );
            *next = Instant::now() + Duration::from_millis(100);
        }
        Ok(())
    }

    pub fn configure(&self, command: &mut Command) {
        let fd = self.process.as_raw_fd();
        unsafe {
            command.pre_exec(move || {
                if libc::write(fd, b"0".as_ptr().cast(), 1) != 1
                    || libc::syscall(
                        libc::SYS_close_range,
                        3u32,
                        u32::MAX,
                        libc::CLOSE_RANGE_CLOEXEC | libc::CLOSE_RANGE_UNSHARE,
                    ) != 0
                {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
}

pub struct Execution {
    pub policy: Policy,
    pub attempt: String,
    pub uid: u32,
    invocation: String,
    deadline: Mutex<Instant>,
    stopped: Arc<AtomicBool>,
    next: AtomicU16,
    groups: Mutex<Vec<Arc<ProducerGroup>>>,
}

impl Execution {
    pub fn start(attempt: &str) -> Result<Self> {
        require_placement(attempt)?;
        process::protect_worker_memory()?;
        let policy = Policy::load()?;
        let state = State::open(&policy)?;
        let invocation = std::env::var("INVOCATION_ID").context("capture invocation missing")?;
        let (uid, proposed_cutoff) = state.update(attempt, |record| {
            record.start(&invocation)?;
            Ok((
                record.uid,
                record
                    .input
                    .reserved_at
                    .checked_add(record.input.request.deadlines.runtime_seconds)
                    .context("capture cutoff overflow")?,
            ))
        })?;
        let account = &policy.caller(uid)?.account;
        daemon::verify_source_account(account.uid, &account.user)?;
        controller_service::require_primary_group(account)?;
        controller_service::require_groups(account)?;
        // Caller evidence can only shorten this pre-verification metadata
        // window. Fresh authenticated bind remains mandatory before source.
        let remaining = proposed_cutoff
            .saturating_sub(daemon::now()?)
            .min(policy.max_seconds);
        let deadline = Instant::now() + Duration::from_secs(remaining);
        Ok(Self {
            policy,
            attempt: attempt.to_owned(),
            uid,
            invocation,
            deadline: Mutex::new(deadline),
            stopped: Arc::new(AtomicBool::new(false)),
            next: AtomicU16::new(0),
            groups: Mutex::new(Vec::new()),
        })
    }

    pub fn record(&self) -> Result<Record> {
        let record = State::open(&self.policy)?.read(&self.attempt)?;
        ensure!(
            record.uid == self.uid
                && record.invocation.as_ref() == Some(&self.invocation)
                && record.phase == Phase::Running,
            "capture lifetime changed"
        );
        Ok(record)
    }

    pub fn deadline(&self) -> Result<Instant> {
        Ok(*self
            .deadline
            .lock()
            .map_err(|_| anyhow::anyhow!("capture clock poisoned"))?)
    }

    pub fn bind(&self, owner: Ownership, reserved_at: u64) -> Result<()> {
        self.active()?;
        let record = self.record()?;
        let cutoff = reserved_at
            .checked_add(record.input.request.deadlines.runtime_seconds)
            .context("capture cutoff overflow")?;
        let remaining = cutoff
            .checked_sub(daemon::now()?)
            .filter(|seconds| *seconds > 0)
            .context("original capture cutoff expired")?;
        let mut deadline = self
            .deadline
            .lock()
            .map_err(|_| anyhow::anyhow!("capture clock poisoned"))?;
        *deadline = (*deadline).min(Instant::now() + Duration::from_secs(remaining));
        State::open(&self.policy)?.update(&self.attempt, |record| {
            ensure!(
                record.ownership.is_none() && record.cutoff.is_none() && !record.cancelled,
                "capture admission already bound or cancelled"
            );
            record.ownership = Some(owner);
            record.cutoff = Some(cutoff);
            Ok(())
        })
    }

    pub fn active(&self) -> Result<()> {
        ensure!(
            !self.stopped.load(Ordering::Acquire) && Instant::now() < self.deadline()?,
            "capture stopped or expired"
        );
        let record = self.record()?;
        ensure!(
            !record.cancelled
                && record
                    .cutoff
                    .is_none_or(|cutoff| daemon::now().is_ok_and(|now| now < cutoff)),
            "capture cancelled or original cutoff expired"
        );
        Ok(())
    }

    pub fn directory(&self) -> Result<PathBuf> {
        State::open(&self.policy)?.directory(&self.attempt)
    }

    fn track(&self, path: PathBuf) -> Result<Arc<ProducerGroup>> {
        let group = Arc::new(ProducerGroup::open(path)?);
        ensure!(group.empty()?, "new capture subgroup populated");
        let mut groups = self
            .groups
            .lock()
            .map_err(|_| anyhow::anyhow!("capture groups poisoned"))?;
        ensure!(
            !self.stopped.load(Ordering::Acquire),
            "capture stopped before subgroup publication"
        );
        groups.push(group.clone());
        Ok(group)
    }

    pub fn transport(&self) -> Result<Arc<TransportScope>> {
        self.active()?;
        let directory = Path::new(workload::BUDGET_CGROUP)
            .join(super::unit(&self.attempt)?)
            .join("transport");
        fs::create_dir(&directory)?;
        self.track(directory.clone())?;
        let process = OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(directory.join("cgroup.procs"))?;
        Ok(Arc::new(TransportScope {
            process,
            policy: self.policy.clone(),
            attempt: self.attempt.clone(),
            deadline: self.deadline()?,
            stopped: self.stopped.clone(),
            next_check: Mutex::new(Instant::now()),
        }))
    }

    /// Fixed source orchestration only, after fresh admission. Runner retains
    /// the original credential/namespace/positive-settlement boundary.
    pub fn stage(&self) -> Result<Stage> {
        self.active()?;
        ensure!(
            self.record()?.ownership.is_some(),
            "source effects precede builder admission"
        );
        let ordinal = self.next.fetch_add(1, Ordering::AcqRel);
        let stage = Stage::capture(&self.attempt, ordinal)?;
        self.track(
            Path::new(workload::BUDGET_CGROUP)
                .join(super::unit(&self.attempt)?)
                .join(format!("capture-{ordinal:02}")),
        )?;
        Ok(stage)
    }

    /// Requests every original child subgroup to stop; failure keeps the run
    /// unresolved. No unit restart, foreign PID kill or missing-group adoption.
    pub fn stop(&self) -> Result<()> {
        self.stopped.store(true, Ordering::Release);
        let groups = self
            .groups
            .lock()
            .map_err(|_| anyhow::anyhow!("capture groups poisoned"))?;
        for group in groups.iter() {
            group.request_stop()?;
        }
        Ok(())
    }

    pub fn empty(&self) -> Result<bool> {
        let groups = self
            .groups
            .lock()
            .map_err(|_| anyhow::anyhow!("capture groups poisoned"))?;
        for group in groups.iter() {
            if !group.empty()? {
                return Ok(false);
            }
        }
        Ok(true)
    }

    pub fn claim_delivery(&self, digest: &str) -> Result<()> {
        self.active()?;
        crate::build_executor::digest(digest)?;
        ensure!(self.empty()?, "capture producers not positively settled");
        State::open(&self.policy)?.update(&self.attempt, |record| {
            ensure!(
                record.delivery_claim.is_none() && !record.cancelled && record.ownership.is_some(),
                "capture delivery already claimed or unavailable"
            );
            record.delivery_claim = Some(digest.to_owned());
            Ok(())
        })
    }

    pub fn finish(
        &self,
        receipt: Option<crate::build_executor::source_transport::Receipt>,
    ) -> Result<()> {
        ensure!(self.empty()?, "local capture settlement unconfirmed");
        let state = State::open(&self.policy)?;
        state.update(&self.attempt, |record| {
            ensure!(
                record.invocation.as_ref() == Some(&self.invocation)
                    && record.phase == Phase::Running,
                "capture lifetime changed"
            );
            record.receipt = receipt;
            record.phase = Phase::Settled;
            record.settled_at = Some(daemon::now()?);
            Ok(())
        })?;
        if state.read(&self.attempt)?.cleanup_allowed() && Instant::now() < self.deadline()? {
            // Cleanup is separately observable through data_released and the
            // bounded reaper. Never monopolize caller control/admission locks
            // for the remainder of a source job, or revoke positive settlement
            // merely because retirement needs another bounded pass.
            let _ = state.release_data(
                &self.attempt,
                self.deadline()?
                    .min(Instant::now() + Duration::from_secs(1)),
            );
        }
        Ok(())
    }
}
