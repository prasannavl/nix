//! Linux cgroup-v2 adapter for the owned native domain and its shared budget.
//!
//! Trusted supervisor only: first verify role/ingress ownership and stop socket,
//! daemon and restart sources. A fence is necessary, not sufficient authorization
//! to kill unknown work. No PID/name-based killing or control-plane fallback.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

use anyhow::{Context, Result, ensure};

use super::launch_gate::Fence;

/// Shared budget, including an explicitly enabled read-only cache publisher.
pub const BUDGET_SLICE: &str = "abird-build.slice";
pub const BUDGET_CGROUP: &str = "/sys/fs/cgroup/abird.slice/abird-build.slice";
pub(super) const BUDGET_RELATIVE: &str = "/abird.slice/abird-build.slice";
/// Only this original native execution domain is subject to fenced hard-stop.
pub const SLICE: &str = "abird-build-owned.slice";
pub const CGROUP: &str = "/sys/fs/cgroup/abird.slice/abird-build.slice/abird-build-owned.slice";
pub(super) const RELATIVE: &str = "/abird.slice/abird-build.slice/abird-build-owned.slice";
pub(super) const CONTROL: &str = "/abird.slice/abird-control.slice";
const MAX_OBSERVATION_BYTES: u64 = 4096;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Population {
    /// Whole slice absent, or cgroup.events positively reports populated=0.
    Empty,
    Populated,
}

/// Bound to the held start fence. No independently reusable empty-workload token.
pub struct FencedWorkload<'a> {
    _fence: &'a Fence<'a>,
}

impl<'a> FencedWorkload<'a> {
    pub fn new(fence: &'a Fence<'a>) -> Result<Self> {
        // Refuse to operate when the supervisor itself entered the kill boundary.
        ensure!(!inside_workload()?, "supervisor is inside workload");
        Ok(Self { _fence: fence })
    }

    /// Caller must already have durably recorded escalation and quiesced ingress.
    /// Success is only a kill request, never proof that every worker stopped.
    pub fn kill(&self) -> Result<()> {
        let Some(directory) = directory()? else {
            return Ok(());
        };
        let mut kill = child(&directory, c"cgroup.kill", libc::O_WRONLY)?;
        kill.write_all(b"1")?;
        Ok(())
    }

    /// Unknown/malformed/unreadable state is an error, never an empty pool.
    /// Keep holding the fence through the subsequent durable settlement write.
    pub fn population(&self) -> Result<Population> {
        observe_population()
    }
}

fn observe_population() -> Result<Population> {
    observe_population_at(CGROUP)
}

/// Observation only. The caller must close the original capture's launch source
/// and establish its exact unit lifetime before using absence as settlement.
pub(super) fn capture_empty(attempt: &str) -> Result<bool> {
    let unit = super::capture_role::unit(attempt)?;
    Ok(observe_population_at(&format!("{BUDGET_CGROUP}/{unit}"))? == Population::Empty)
}

fn observe_population_at(path: &str) -> Result<Population> {
    let Some(directory) = directory_at(path)? else {
        return Ok(Population::Empty);
    };
    let events = child(&directory, c"cgroup.events", libc::O_RDONLY)?;
    let mut bytes = Vec::new();
    events
        .take(MAX_OBSERVATION_BYTES + 1)
        .read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= MAX_OBSERVATION_BYTES,
        "cgroup observation exceeds bound"
    );
    let result = parse_events(std::str::from_utf8(&bytes)?)?;
    // Removal/recreation during observation is unresolved, not empty evidence.
    let current = directory_identity(Path::new(path))?;
    let observed = directory.metadata()?;
    ensure!(
        current == (observed.dev(), observed.ino()),
        "workload changed during observation"
    );
    Ok(result)
}

/// Unit wrapper must enter the accounted subtree before acquiring launch permission.
pub fn require_wrapper_placement() -> Result<()> {
    ensure!(
        inside_path_for(&own_cgroup()?, BUDGET_RELATIVE)?,
        "wrapper outside accounted subtree"
    );
    Ok(())
}

/// Exact client unit, not another unit or a descendant inside the aggregate.
/// Still only a necessary placement veto, not namespace/all-ingress authority.
pub(super) fn require_client_placement(owner: &super::Ownership) -> Result<()> {
    unit_path(&own_cgroup()?, &owner.unit_name()?)
}

/// Native daemon wrapper cannot enter from a client unit or delegated descendant.
/// Placement is a necessary veto, not provenance or permission to stop that unit.
pub(super) fn require_daemon_placement() -> Result<()> {
    unit_path(&own_cgroup()?, "nix-daemon.service")
}

/// Installed controller is outside the kill boundary, in its fixed system unit.
pub(super) fn require_supervisor_placement() -> Result<()> {
    ensure!(
        own_cgroup()?.trim_end_matches('\n')
            == format!("0::{CONTROL}/abird-owned-build-supervisor.service"),
        "supervisor unit placement differs"
    );
    Ok(())
}

pub fn require_controller_placement(attempt: &str) -> Result<()> {
    let unit = super::controller_service::unit(attempt)?;
    let suffix = if unsafe { libc::geteuid() } == 0 {
        String::new()
    } else {
        format!("/{}", super::controller_service::OBSERVER)
    };
    ensure!(
        own_cgroup()?.trim_end_matches('\n') == format!("0::{CONTROL}/{unit}{suffix}"),
        "CI observer placement differs"
    );
    Ok(())
}

pub(super) fn require_bootstrap_placement() -> Result<()> {
    ensure!(
        own_cgroup()?.trim_end_matches('\n')
            == format!("0::{CONTROL}/abird-owned-build-bootstrap.service"),
        "bootstrap unit placement differs"
    );
    Ok(())
}

pub(super) fn require_maintenance_request_placement() -> Result<()> {
    ensure!(
        own_cgroup()?.trim_end_matches('\n')
            == format!("0::{CONTROL}/abird-owned-maintenance-request.service"),
        "maintenance requester placement differs"
    );
    Ok(())
}

/// Bootstrap observes only; no kill/fence authority exists yet.
pub(super) fn bootstrap_empty() -> Result<bool> {
    require_bootstrap_placement()?;
    Ok(observe_population()? == Population::Empty)
}

/// Observation only. Unknown populated unit roots veto aggregate ownership;
/// empty remnants are harmless. Descendants remain accounted under these roots.
pub(super) fn only_unit_roots(expected: &[&str]) -> Result<bool> {
    only_roots_at(CGROUP, expected)
}

pub(super) fn only_budget_roots(expected: &[&str]) -> Result<bool> {
    only_roots_at(BUDGET_CGROUP, expected)
}

fn only_roots_at(path: &str, expected: &[&str]) -> Result<bool> {
    let Some(root) = directory_at(path)? else {
        return Ok(true);
    };
    let metadata = root.metadata()?;
    let mut count = 0;
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        count += 1;
        ensure!(count <= 256, "workload unit observation exceeds bound");
        let name = entry.file_name();
        if expected.iter().any(|expected| name == *expected) {
            continue;
        }
        let events = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(entry.path().join("cgroup.events"))?;
        let mut bytes = String::new();
        events
            .take(MAX_OBSERVATION_BYTES + 1)
            .read_to_string(&mut bytes)?;
        ensure!(
            bytes.len() as u64 <= MAX_OBSERVATION_BYTES,
            "cgroup observation exceeds bound"
        );
        if parse_events(&bytes)? != Population::Empty {
            return Ok(false);
        }
    }
    ensure!(
        directory_identity(Path::new(path))? == (metadata.dev(), metadata.ino()),
        "workload changed during observation"
    );
    // No process may live directly in the aggregate itself.
    let mut processes = String::new();
    child(&root, c"cgroup.procs", libc::O_RDONLY)?
        .take(MAX_OBSERVATION_BYTES + 1)
        .read_to_string(&mut processes)?;
    Ok(processes.is_empty())
}

/// Fixed socket worker must be born in its declared non-daemon work subtree.
pub(super) fn consumer_unit() -> Result<String> {
    consumer_unit_for(&own_cgroup()?)
}

fn consumer_unit_for(cgroup: &str) -> Result<String> {
    let prefix = format!("0::{BUDGET_RELATIVE}/{}/", super::consumer_role::SLICE);
    let unit = cgroup
        .trim_end_matches('\n')
        .strip_prefix(&prefix)
        .context("consumer outside accounted subtree")?;
    ensure!(
        unit.len() <= 255
            && unit.starts_with("abird-owned-consumer@")
            && unit.ends_with(".service")
            && !unit.contains('/')
            && unit.bytes().all(|byte| byte.is_ascii_graphic()),
        "consumer outside fixed socket unit"
    );
    Ok(unit.to_owned())
}

fn own_cgroup() -> Result<String> {
    let mut own = String::new();
    File::open("/proc/self/cgroup")?
        .take(MAX_OBSERVATION_BYTES + 1)
        .read_to_string(&mut own)?;
    ensure!(
        own.len() as u64 <= MAX_OBSERVATION_BYTES,
        "cgroup identity exceeds bound"
    );
    Ok(own)
}

fn unit_path(own: &str, unit: &str) -> Result<()> {
    ensure!(inside_path(own)?, "role outside accounted subtree");
    ensure!(
        own.strip_suffix('\n').unwrap_or(own) == format!("0::{RELATIVE}/{unit}"),
        "role unit placement differs"
    );
    Ok(())
}

fn inside_workload() -> Result<bool> {
    inside_path(&own_cgroup()?)
}

fn inside_path(own: &str) -> Result<bool> {
    inside_path_for(own, RELATIVE)
}

fn inside_path_for(own: &str, boundary: &str) -> Result<bool> {
    ensure!(
        own.len() as u64 <= MAX_OBSERVATION_BYTES,
        "cgroup identity exceeds bound"
    );
    let relative = own
        .trim()
        .strip_prefix("0::")
        .context("unified cgroup-v2 required")?;
    ensure!(!relative.contains('\n'), "ambiguous process cgroup");
    ensure!(
        Path::new(relative).is_absolute()
            && Path::new(relative).components().all(|component| matches!(
                component,
                std::path::Component::RootDir | std::path::Component::Normal(_)
            )),
        "unresolved cgroup namespace"
    );
    Ok(relative == boundary || relative.starts_with(&format!("{boundary}/")))
}

fn directory_identity(path: &Path) -> Result<(u64, u64)> {
    let metadata = fs::symlink_metadata(path)?;
    ensure!(
        metadata.is_dir() && metadata.uid() == 0,
        "unsafe workload directory"
    );
    Ok((metadata.dev(), metadata.ino()))
}

fn directory() -> Result<Option<File>> {
    directory_at(CGROUP)
}

fn directory_at(path: &str) -> Result<Option<File>> {
    // The mount must exist even when systemd removed an empty child slice.
    // A missing cgroup mount or redirected namespace is not settlement.
    let base = Path::new("/sys/fs/cgroup");
    ensure!(fs::canonicalize(base)? == base, "cgroup root redirected");
    let base = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(base)?;
    let mut stat: libc::statfs = unsafe { std::mem::zeroed() };
    ensure!(
        unsafe { libc::fstatfs(base.as_raw_fd(), &mut stat) } == 0
            && stat.f_type == libc::CGROUP2_SUPER_MAGIC,
        "cgroup-v2 filesystem required"
    );
    let root = Path::new(path);
    let directory = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(root)
    {
        Ok(directory) => directory,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // No symlink in an existing ancestor may turn absence into a claim.
            let parent = root.parent().context("workload has no parent")?;
            match fs::symlink_metadata(parent) {
                Ok(_) => {
                    ensure!(
                        fs::canonicalize(parent)? == parent,
                        "workload parent redirected"
                    );
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
            return Ok(None);
        }
        Err(error) => return Err(error.into()),
    };
    ensure!(fs::canonicalize(root)? == root, "workload redirected");
    let metadata = directory.metadata()?;
    ensure!(
        metadata.uid() == 0 && metadata.mode() & 0o022 == 0,
        "workload is not exclusively root-writable"
    );
    let mut stat: libc::statfs = unsafe { std::mem::zeroed() };
    ensure!(
        unsafe { libc::fstatfs(directory.as_raw_fd(), &mut stat) } == 0
            && stat.f_type == libc::CGROUP2_SUPER_MAGIC,
        "workload is not cgroup-v2"
    );
    ensure!(
        directory_identity(root)? == (metadata.dev(), metadata.ino()),
        "workload directory replaced"
    );
    Ok(Some(directory))
}

fn child(directory: &File, name: &std::ffi::CStr, mode: libc::c_int) -> Result<File> {
    let fd = unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            mode | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    ensure!(fd >= 0, std::io::Error::last_os_error());
    Ok(unsafe { File::from_raw_fd(fd) })
}

pub(super) fn parse_events(value: &str) -> Result<Population> {
    let mut populated = None;
    let mut keys = std::collections::BTreeSet::new();
    for line in value.lines() {
        let mut parts = line.split_ascii_whitespace();
        let key = parts.next().context("empty cgroup event")?;
        let number: u64 = parts
            .next()
            .context("missing cgroup event value")?
            .parse()?;
        ensure!(
            parts.next().is_none() && keys.insert(key),
            "ambiguous cgroup event"
        );
        if key == "populated" {
            populated = Some(match number {
                0 => Population::Empty,
                1 => Population::Populated,
                _ => anyhow::bail!("invalid cgroup population"),
            });
        }
    }
    populated.context("missing cgroup population")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn consumer_requires_exact_non_daemon_socket_unit_placement() {
        let prefix = format!(
            "0::{BUDGET_RELATIVE}/{}",
            super::super::consumer_role::SLICE
        );
        assert_eq!(
            consumer_unit_for(&format!("{prefix}/abird-owned-consumer@1.service\n")).unwrap(),
            "abird-owned-consumer@1.service"
        );
        for path in [
            format!("0::{RELATIVE}/abird-owned-consumer@1.service\n"),
            format!("{prefix}/ordinary.service\n"),
            format!("{prefix}/abird-owned-consumer@1.service/child\n"),
            format!("{prefix}/abird-owned-consumer@1.service\n0::/other\n"),
        ] {
            assert!(consumer_unit_for(&path).is_err());
        }
    }

    #[test]
    fn placement_rejects_ambiguous_namespaces_and_compares_whole_components() {
        for value in [
            format!("0::{RELATIVE}\n"),
            format!("0::{RELATIVE}/client.service\n"),
        ] {
            assert!(inside_path(&value).unwrap());
        }
        for value in [
            "0::/\n",
            "0::/system.slice/agent.service\n",
            "0::/abird.slice/abird-build.slice-other/client.service\n",
        ] {
            assert!(!inside_path(value).unwrap());
        }
        for value in [
            "",
            "1:memory:/abird.slice",
            "0::relative",
            "0::/../other",
            "0::/abird.slice\n0::/another",
        ] {
            assert!(inside_path(value).is_err());
        }
        assert!(
            inside_path(&format!(
                "0::/{}",
                "a".repeat(MAX_OBSERVATION_BYTES as usize)
            ))
            .is_err()
        );
    }

    #[test]
    fn shared_publisher_is_accounted_but_never_in_the_native_kill_domain() {
        let publisher = format!("0::{BUDGET_RELATIVE}/harmonia.service\n");
        assert!(inside_path_for(&publisher, BUDGET_RELATIVE).unwrap());
        assert!(!inside_path(&publisher).unwrap());
        assert!(
            inside_path_for(
                &format!("0::{RELATIVE}/nix-daemon.service\n"),
                BUDGET_RELATIVE
            )
            .unwrap()
        );
    }

    #[test]
    fn client_placement_requires_exact_unit_not_aggregate_or_descendant() {
        let unit = "abird-build-client@attempt.service";
        assert!(unit_path(&format!("0::{RELATIVE}/{unit}\n"), unit).is_ok());
        for own in [
            format!("0::{RELATIVE}"),
            format!("0::{RELATIVE}/other.service"),
            format!("0::{RELATIVE}/{unit}/child"),
            format!("0::{RELATIVE}//{unit}"),
            format!("0::{RELATIVE}/{unit}\n\n"),
            format!("0::{RELATIVE}/{unit}\n0::/"),
            format!("0::/system.slice/{unit}"),
        ] {
            assert!(unit_path(&own, unit).is_err());
        }
    }

    #[test]
    fn daemon_placement_rejects_client_units_and_delegated_descendants() {
        let unit = "nix-daemon.service";
        assert!(unit_path(&format!("0::{RELATIVE}/{unit}\n"), unit).is_ok());
        for own in [
            format!("0::{RELATIVE}"),
            format!("0::{RELATIVE}/abird-build-client@attempt.service"),
            format!("0::{RELATIVE}/{unit}/daemon"),
            format!("0::{RELATIVE}//{unit}"),
            format!("0::{RELATIVE}/{unit}\n\n"),
            format!("0::/system.slice/{unit}"),
        ] {
            assert!(unit_path(&own, unit).is_err());
        }
    }

    #[test]
    fn population_requires_positive_unambiguous_kernel_evidence() {
        assert_eq!(
            parse_events("populated 0\nfrozen 0\n").unwrap(),
            Population::Empty
        );
        assert_eq!(
            parse_events("frozen 1\npopulated 1\nfuture_counter 27\n").unwrap(),
            Population::Populated
        );
        for invalid in [
            "",
            "frozen 0",
            "populated",
            "populated -1",
            "populated 2",
            "populated 0\npopulated 1",
            "populated 0\nfrozen 0\nfrozen 0",
            "populated 0 garbage",
            "populated 0\n\n",
            "populated 0\nfrozen bogus",
        ] {
            assert!(parse_events(invalid).is_err(), "{invalid:?}");
        }
    }
}
