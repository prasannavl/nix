//! Fixed, one-shot CI observer service. Credentials change only in its child;
//! the observer has ordinary principal authority, never journal/store authority.

use std::collections::BTreeMap;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::{daemon, role, units::Units, workload};

pub(super) const TEMPLATE: &str = "abird-owned-fleet@.service";
pub(super) const OBSERVER: &str = "observer";

fn group_path(attempt: &str) -> Result<PathBuf> {
    Ok(Path::new("/sys/fs/cgroup")
        .join(workload::CONTROL.trim_start_matches('/'))
        .join(unit(attempt)?)
        .join(OBSERVER))
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Group {
    device: u64,
    inode: u64,
}

impl Group {
    pub(super) fn validate(&self) -> Result<()> {
        ensure!(self.inode > 0, "invalid controller cgroup identity");
        Ok(())
    }
}

fn group(attempt: &str) -> Result<(std::fs::File, Group)> {
    group_at(&group_path(attempt)?)
}

fn group_at(path: &Path) -> Result<(std::fs::File, Group)> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    ensure!(
        std::fs::canonicalize(path)? == path,
        "controller cgroup redirected"
    );
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = file.metadata()?;
    let mut filesystem = std::mem::MaybeUninit::<libc::statfs>::uninit();
    ensure!(
        unsafe { libc::fstatfs(file.as_raw_fd(), filesystem.as_mut_ptr()) } == 0,
        std::io::Error::last_os_error()
    );
    ensure!(
        unsafe { filesystem.assume_init() }.f_type == 0x63677270
            && metadata.uid() == 0
            && metadata.mode() & 0o022 == 0,
        "controller cgroup owner/filesystem differs"
    );
    Ok((
        file,
        Group {
            device: metadata.dev(),
            inode: metadata.ino(),
        },
    ))
}

fn population(attempt: &str, expected: &Group) -> Result<workload::Population> {
    population_at(&group_path(attempt)?, expected)
}

fn population_at(path: &Path, expected: &Group) -> Result<workload::Population> {
    use std::io::Read;
    use std::os::fd::{AsRawFd, FromRawFd};
    let (directory, observed) = group_at(path)?;
    ensure!(&observed == expected, "controller cgroup replaced");
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            c"cgroup.events".as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    ensure!(fd >= 0, std::io::Error::last_os_error());
    let mut bytes = String::new();
    unsafe { std::fs::File::from_raw_fd(fd) }
        .take(4097)
        .read_to_string(&mut bytes)?;
    ensure!(
        bytes.len() <= 4096 && &group_at(path)?.1 == expected,
        "controller population observation changed"
    );
    workload::parse_events(&bytes)
}

/// Target is terminal, so begin_controller is fenced independently of systemd.
/// Positive original observer-group emptiness precedes StopUnit. The wrapper
/// retains its unit only within the original deadline; RemainAfterExit alone
/// does not preserve an empty cgroup. Missing/replaced evidence stays a veto.
pub(super) fn retire(
    journal: &super::journal::Journal,
    cleanup: &super::Ownership,
    target: &super::Ownership,
    role: &role::Policy,
    deadline: Instant,
) -> Result<()> {
    let Some(claim) = journal.controller_retirement(target)? else {
        return Ok(());
    };
    let expected = claim.group.context("controller cgroup was not bound")?;
    let invocation = claim
        .invocation
        .context("controller invocation was not bound")?;
    let name = unit(&target.attempt_id)?;
    let cgroup = format!("{}/{}", workload::CONTROL, name);
    let parent = Path::new("/sys/fs/cgroup").join(cgroup.trim_start_matches('/'));
    let mut parent_binding = None;
    let mut units =
        Units::new(role.systemctl.clone(), Duration::from_secs(2))?.with_deadline(deadline);
    let active = || -> Result<()> {
        ensure!(
            Instant::now() < deadline,
            "controller retirement deadline expired"
        );
        journal.retirement_active(cleanup, daemon::now()?)
    };
    let mut stopping = false;
    loop {
        active()?;
        units.require_definition(&name, &role.definitions[TEMPLATE])?;
        let observed = units.controller(&target.attempt_id)?;
        if !stopping {
            ensure!(
                observed.invocation.as_deref() == Some(invocation.as_str())
                    && observed.cgroup == cgroup,
                "controller invocation/cgroup changed"
            );
            if population(&target.attempt_id, &expected)? == workload::Population::Empty
                && observed.job == "0"
            {
                let (_, identity) = group_at(&parent)?;
                active()?;
                if observed.stopped() {
                    ensure!(
                        population_at(&parent, &identity)? == workload::Population::Empty,
                        "controller unit still populated after stop"
                    );
                    journal.retire_controller(cleanup, target, daemon::now()?)?;
                    return Ok(());
                }
                // One dispatch only. A lost stop response leaves cleanup
                // unresolved; neither retry nor a missing cgroup repairs it.
                parent_binding = Some(identity);
                units.request_controller_stop(&target.attempt_id)?;
                stopping = true;
            }
        } else {
            ensure!(
                observed.invocation.as_deref() == Some(invocation.as_str())
                    || (observed.invocation.is_none() && observed.stopped()),
                "controller invocation changed during retirement"
            );
            ensure!(
                observed.cgroup == cgroup
                    || (observed.cgroup.is_empty()
                        && (observed.stopped() || observed.active == "deactivating")),
                "controller cgroup changed during retirement"
            );
            match std::fs::symlink_metadata(group_path(&target.attempt_id)?) {
                Ok(_) => ensure!(
                    population(&target.attempt_id, &expected)? == workload::Population::Empty,
                    "controller repopulated after settlement"
                ),
                // Only after this invocation's positively empty group and our
                // one StopUnit. Absence here is removal, never settlement proof.
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
            if observed.stopped() {
                // Retained parent residue cannot hide a surviving wrapper or
                // control helper. Observer settlement was proved before StopUnit.
                match std::fs::symlink_metadata(&parent) {
                    Ok(_) => ensure!(
                        population_at(
                            &parent,
                            parent_binding
                                .as_ref()
                                .context("controller stop binding missing")?
                        )? == workload::Population::Empty,
                        "controller unit still populated after stop"
                    ),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => return Err(error.into()),
                }
                active()?;
                journal.retire_controller(cleanup, target, daemon::now()?)?;
                return Ok(());
            }
        }
        std::thread::park_timeout(
            Duration::from_millis(25).min(deadline.saturating_duration_since(Instant::now())),
        );
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Account {
    pub user: String,
    pub uid: u32,
    pub gid: u32,
    pub home: PathBuf,
    pub state_home: PathBuf,
    #[serde(default)]
    pub capture_roots: Vec<PathBuf>,
    #[serde(default)]
    pub groups: Vec<u32>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub accounts: BTreeMap<String, Account>,
}

impl Policy {
    pub(super) fn validate(&self) -> Result<()> {
        ensure!(self.accounts.len() <= 64, "invalid CI observer policy");
        let mut uids = std::collections::BTreeSet::new();
        for (issuer, account) in &self.accounts {
            super::identifier(issuer)?;
            daemon::validate_source_account(account.uid, &account.user)?;
            ensure!(
                account.gid > 0 && account.gid < u32::MAX && uids.insert(account.uid),
                "invalid CI observer credential"
            );
            ensure!(
                account.groups.len() <= 64
                    && account.groups.windows(2).all(|pair| pair[0] < pair[1])
                    && account.groups.iter().all(|gid| *gid > 0 && *gid < u32::MAX),
                "invalid installed capture groups"
            );
            ensure!(
                account.capture_roots.len() <= 16
                    && account
                        .capture_roots
                        .iter()
                        .all(|root| root.components().count() > 2 && root != &account.home),
                "capture root count/scope exceeds bound"
            );
            for path in [&account.home, &account.state_home]
                .into_iter()
                .chain(&account.capture_roots)
            {
                ensure!(
                    path.is_absolute()
                        && path.components().all(|part| matches!(
                            part,
                            std::path::Component::RootDir | std::path::Component::Normal(_)
                        )),
                    "invalid CI observer state path"
                );
            }
        }
        Ok(())
    }
}

pub(super) fn unit(attempt: &str) -> Result<String> {
    super::digest(attempt)?;
    Ok(format!("abird-owned-fleet@{attempt}.service"))
}

pub fn run(path: &Path, attempt: &str) -> Result<()> {
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "installed CI observer wrapper requires root"
    );
    workload::require_controller_placement(attempt)?;
    let role = role::Policy::load(path)?;
    let authority = daemon::open_controller_authority(&role.daemon_policy, &role.control, attempt)?;
    ensure!(
        authority.policy.containment_digest == role.digest()?,
        "CI observer role differs"
    );
    role.control_limits.ready()?;
    daemon::executable(&role.manager_program)?;
    let mut units = Units::new(role.systemctl.clone(), Duration::from_secs(2))?;
    units.require_definition(&unit(attempt)?, &role.definitions[TEMPLATE])?;
    let invocation = std::env::var("INVOCATION_ID").context("CI observer invocation missing")?;
    let (request, owner, reserved_at) =
        authority
            .journal
            .begin_controller(attempt, &invocation, daemon::now()?)?;
    let deadline = super::process::cutoff(
        Some(reserved_at),
        request.deadlines.runtime_seconds,
        SystemTime::now().duration_since(UNIX_EPOCH)?,
        Instant::now(),
    )?;
    // Exclusive root-owned subgroup, before the only ordinary-UID child.
    // Never adopt residue, including an empty group from a failed launch.
    authority.journal.build_active(&owner, daemon::now()?)?;
    std::fs::create_dir(group_path(attempt)?)?;
    let (directory, bound_group) = group(attempt)?;
    authority.journal.bind_controller_group(
        &owner,
        &invocation,
        bound_group.clone(),
        daemon::now()?,
    )?;
    use std::os::fd::{AsRawFd, FromRawFd};
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            c"cgroup.procs".as_ptr(),
            libc::O_WRONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    ensure!(fd >= 0, std::io::Error::last_os_error());
    let placement = unsafe { std::fs::File::from_raw_fd(fd) };
    let account = role
        .controller
        .accounts
        .get(&request.issuer)
        .context("CI observer principal is not installed")?;
    let control: super::control::Config =
        serde_json::from_slice(&daemon::read_declaration(&role.control)?)?;
    ensure!(
        control
            .principals
            .iter()
            .any(|principal| principal.issuer == request.issuer && principal.uid == account.uid)
            && !control.workload_uids.contains(&account.uid),
        "CI observer principal differs"
    );
    daemon::verify_source_account(account.uid, &account.user)?;
    require_primary_group(account)?;
    ensure!(
        Instant::now() < deadline,
        "CI observer NSS exceeded original deadline"
    );
    authority.journal.build_active(&owner, daemon::now()?)?;
    let uid = account.uid;
    let gid = account.gid;
    let groups = [gid, role.input_gid];
    let mut command = role.manager(role::ManagerCommand::Controller);
    command
        .args([
            request.run_id.as_str(),
            attempt,
            &request.digest()?,
            &invocation,
        ])
        .arg(
            u64::try_from(
                deadline
                    .saturating_duration_since(Instant::now())
                    .as_millis(),
            )?
            .to_string(),
        )
        .env_clear()
        .env("HOME", &account.home)
        .env("XDG_STATE_HOME", &account.state_home)
        .env("LC_ALL", "C")
        .env("INVOCATION_ID", &invocation)
        .current_dir("/var/empty")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(move || {
            // Placement before credentials/exec; the writable descriptor never
            // reaches the observer or its descendants.
            if libc::write(placement.as_raw_fd(), b"0\n".as_ptr().cast(), 2) != 2 {
                return Err(std::io::Error::last_os_error());
            }
            super::process::child_credentials(uid, gid, &groups)?;
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
    let mut child = command.spawn()?;
    drop(command);
    drop(directory);
    ensure!(
        group(attempt)?.1 == bound_group,
        "controller cgroup replaced during launch"
    );
    let mut reaped = false;
    loop {
        if !reaped && child.try_wait()?.is_some() {
            reaped = true;
        }
        if Instant::now() >= deadline {
            if !reaped {
                let _ = child.kill();
            }
            anyhow::bail!("CI observer original deadline expired");
        }
        // The root control wrapper performs no observer work after child exit.
        // Keeping it alive preserves the subgroup for admitted retirement's
        // positive population observation, including surviving descendants.
        // No extension: expiry/crash loses this opportunity and retains cleanup.
        std::thread::park_timeout(
            Duration::from_millis(100).min(deadline.saturating_duration_since(Instant::now())),
        );
    }
}

pub(super) fn require_groups(account: &Account) -> Result<()> {
    let name = std::ffi::CString::new(account.user.as_str())?;
    let mut groups = [0u32; 64];
    let mut count = groups.len() as libc::c_int;
    ensure!(
        unsafe { libc::getgrouplist(name.as_ptr(), account.gid, groups.as_mut_ptr(), &mut count) }
            >= 0
            && (0..=64).contains(&count),
        "capture NSS groups unavailable or exceed bound"
    );
    let mut groups = groups[..usize::try_from(count)?].to_vec();
    groups.sort_unstable();
    groups.dedup();
    ensure!(
        groups == account.groups,
        "capture NSS groups differ from installed policy"
    );
    Ok(())
}

pub(super) fn require_primary_group(account: &Account) -> Result<()> {
    let name = std::ffi::CString::new(account.user.as_str())?;
    let mut buffer = vec![0u8; 64 * 1024];
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result = std::ptr::null_mut();
    ensure!(
        unsafe {
            libc::getpwnam_r(
                name.as_ptr(),
                &mut entry,
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut result,
            )
        } == 0
            && !result.is_null()
            && entry.pw_uid == account.uid
            && entry.pw_gid == account.gid,
        "CI observer NSS credential differs"
    );
    Ok(())
}
