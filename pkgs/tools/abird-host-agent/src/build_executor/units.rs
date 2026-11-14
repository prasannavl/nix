//! Fixed systemd unit adapter. Transport/parse failures never mean inactive.
//! This adapter does not establish ingress ownership or authorize workload kill.

use std::collections::BTreeMap;
use std::io::{ErrorKind, Read};
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail, ensure};

use super::supervisor::ClientObservation;
use super::workload::{RELATIVE, SLICE};
use super::{ClientExit, ExecutionHandle, Ownership};

/// Retry observation, never an effect or an inferred stopped/empty state.
#[derive(Debug)]
pub(super) struct ObservationUnavailable(&'static str);

impl std::fmt::Display for ObservationUnavailable {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for ObservationUnavailable {}

const MAX_BYTES: usize = 16 * 1024;
const DEFINITION_KEYS: &str = "Id,LoadState,FragmentPath,DropInPaths,NeedDaemonReload,Transient";
const PROPERTIES: &str = "Id,LoadState,ActiveState,SubState,InvocationID,ControlGroup,Slice,Restart,Job,ExecMainCode,ExecMainStatus,Result";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Unit {
    pub id: String,
    pub active: String,
    pub sub: String,
    pub invocation: Option<String>,
    pub cgroup: String,
    pub job: String,
    pub exit: Option<ClientExit>,
}

impl Unit {
    pub fn stopped(&self) -> bool {
        matches!(self.active.as_str(), "inactive" | "failed") && self.job == "0"
    }

    /// Empty invocation is permitted only for an inactive, collected unit. It is
    /// not client-exit evidence; aggregate settlement still requires a held fence.
    pub fn matches_handle(&self, handle: &ExecutionHandle) -> Result<bool> {
        ensure!(
            self.id == handle.ownership.unit_name()?,
            "unit identity mismatch"
        );
        Ok(self.invocation.as_deref() == Some(&handle.invocation_id)
            || (self.invocation.is_none() && self.stopped()))
    }

    /// Only exact invocation-bound, retained main-process exit evidence is usable.
    /// Collection/default fields and lost observation never establish success.
    pub fn observe_client(
        &self,
        owner: &Ownership,
        handle: Option<&ExecutionHandle>,
    ) -> Result<ClientObservation> {
        ensure!(self.id == owner.unit_name()?, "client unit mismatch");
        if let Some(handle) = handle {
            ensure!(&handle.ownership == owner, "client ownership mismatch");
            if self
                .invocation
                .as_ref()
                .is_some_and(|id| id != &handle.invocation_id)
            {
                return Ok(ClientObservation::Foreign);
            }
        }
        let exited =
            self.stopped() || (self.active == "active" && self.sub == "exited" && self.job == "0");
        if exited {
            return Ok(match (handle, &self.invocation, self.exit) {
                (Some(handle), Some(id), Some(exit)) if id == &handle.invocation_id => {
                    ClientObservation::Exited {
                        handle: handle.clone(),
                        exit,
                    }
                }
                _ => ClientObservation::Lost,
            });
        }
        Ok(ClientObservation::Pending)
    }

    pub fn decode(bytes: &[u8], expected: &str, workload: bool) -> Result<Self> {
        ensure!(bytes.len() <= MAX_BYTES, "unit observation exceeds bound");
        let text = std::str::from_utf8(bytes)?;
        let mut values = BTreeMap::new();
        for line in text.lines() {
            let (key, value) = line.split_once('=').context("malformed unit observation")?;
            ensure!(
                PROPERTIES.split(',').any(|p| p == key) && values.insert(key, value).is_none(),
                "unknown or duplicate systemd property"
            );
        }
        let get = |key| values.get(key).copied().context("missing systemd property");
        ensure!(
            get("Id")? == expected && get("LoadState")? == "loaded",
            "unit missing/replaced/unloadable"
        );
        let active = get("ActiveState")?;
        ensure!(
            matches!(
                active,
                "active" | "inactive" | "failed" | "activating" | "deactivating" | "reloading"
            ),
            "unknown unit state"
        );
        let sub = get("SubState")?;
        ensure!(
            !sub.is_empty()
                && sub.len() <= 64
                && sub.bytes().all(|b| b.is_ascii_lowercase() || b == b'-'),
            "invalid unit substate"
        );
        let invocation = get("InvocationID")?;
        ensure!(
            invocation.is_empty()
                || (invocation.len() == 32
                    && invocation
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))),
            "invalid systemd invocation"
        );
        let cgroup = if workload {
            get("ControlGroup")?
        } else {
            values.get("ControlGroup").copied().unwrap_or("")
        };
        if workload {
            ensure!(
                get("Slice")? == SLICE && get("Restart")? == "no",
                "unit outside admitted placement/restart policy"
            );
            // ControlGroup names the unit root, including when builders use
            // delegated descendants. Aggregate membership alone is insufficient.
            ensure!(
                cgroup.is_empty() || cgroup == format!("{RELATIVE}/{expected}"),
                "unit cgroup placement differs"
            );
            ensure!(
                !cgroup.split('/').any(|p| p == "." || p == ".."),
                "ambiguous unit cgroup"
            );
        }
        let job = get("Job")?;
        // The pinned systemctl renders the null job as an explicit empty value.
        // Missing property still rejects; neither encoding is client-exit proof.
        let job = if job.is_empty() { "0" } else { job };
        ensure!(
            job.len() <= 128
                && job
                    .split_ascii_whitespace()
                    .next()
                    .is_some_and(|id| id.parse::<u32>().is_ok())
                && job.bytes().all(|b| b.is_ascii_graphic() || b == b' '),
            "invalid job identity"
        );
        let exit = if workload {
            let code: i32 = get("ExecMainCode")?.parse()?;
            let status: u8 = get("ExecMainStatus")?.parse()?;
            match code {
                0 => None,
                1 if status == 0 && get("Result")? == "success" => Some(ClientExit::Success),
                1 if status != 0 => Some(ClientExit::Failed { exit_code: status }),
                2 | 3 if status != 0 => Some(ClientExit::Signalled { signal: status }),
                _ => bail!("unresolved unit exit evidence"),
            }
        } else {
            None
        };
        ensure!(
            !workload
                || matches!(active, "inactive" | "failed")
                || (!invocation.is_empty()
                    && (!cgroup.is_empty()
                        || (active == "active" && sub == "exited" && exit.is_some()))),
            "active unit lacks identity/cgroup"
        );
        Ok(Self {
            id: expected.to_owned(),
            active: active.to_owned(),
            sub: sub.to_owned(),
            invocation: (!invocation.is_empty()).then(|| invocation.to_owned()),
            cgroup: cgroup.to_owned(),
            job: job.to_owned(),
            exit,
        })
    }
}

pub struct Units {
    systemctl: PathBuf,
    timeout: Duration,
    deadline: Option<Instant>,
    // A timed-out local probe must be reaped before another is spawned. It is
    // never confused with the workload; blocked probes cannot accumulate.
    pending: Option<Child>,
}

impl Units {
    pub fn new(systemctl: PathBuf, timeout: Duration) -> Result<Self> {
        ensure!(
            systemctl.is_absolute() && !timeout.is_zero() && timeout <= Duration::from_secs(30),
            "invalid systemd adapter configuration"
        );
        Ok(Self {
            systemctl,
            timeout,
            deadline: None,
            pending: None,
        })
    }

    /// Local adapter work shares the enclosing lifetime, including spawn time.
    pub(super) fn with_deadline(mut self, deadline: Instant) -> Self {
        self.deadline = Some(self.deadline.map_or(deadline, |old| old.min(deadline)));
        self
    }

    pub fn client(&mut self, owner: &Ownership) -> Result<Unit> {
        self.show(&owner.unit_name()?, true)
    }
    pub fn daemon(&mut self) -> Result<Unit> {
        self.show("nix-daemon.service", true)
    }
    pub fn socket(&mut self) -> Result<Unit> {
        self.show("nix-daemon.socket", false)
    }

    pub(super) fn capture_unit(&mut self, attempt: &str) -> Result<Unit> {
        let name = super::capture_role::unit(attempt)?;
        let properties = format!("--property={PROPERTIES}");
        let bytes = self.run(&["show", &properties, "--", &name])?;
        let unit = Unit::decode(&bytes, &name, false)?;
        let properties = std::str::from_utf8(&bytes)?;
        let value = |name: &str| {
            properties.lines().find_map(|line| {
                let (key, value) = line.split_once('=')?;
                (key == name).then_some(value)
            })
        };
        ensure!(
            value("Slice") == Some(super::workload::BUDGET_SLICE)
                && value("Restart") == Some("no")
                && (unit.cgroup == format!("{}/{name}", super::workload::BUDGET_RELATIVE)
                    || (unit.stopped() && unit.cgroup.is_empty()))
                && (unit.stopped() || unit.invocation.is_some()),
            "capture unit placement or lifetime differs"
        );
        Ok(unit)
    }

    pub(super) fn stop_capture(&mut self, attempt: &str, invocation: &str) -> Result<()> {
        let unit = self.capture_unit(attempt)?;
        ensure!(
            unit.invocation.as_deref() == Some(invocation)
                || (unit.stopped() && unit.invocation.is_none()),
            "capture unit invocation changed"
        );
        if !unit.stopped() {
            // The durable Running/revoked launch record forbids any successor.
            // This acknowledges only the stop request, never actual settlement.
            self.run(&["stop", "--no-block", "--", &unit.id])?;
        }
        Ok(())
    }

    /// Shared publisher is accounted but is not an owned native producer. This
    /// observation grants no stop/restart authority over that existing service.
    pub(super) fn require_publisher_placement(&mut self) -> Result<()> {
        let properties = format!("--property={PROPERTIES}");
        let bytes = self.run(&["show", &properties, "--", "harmonia.service"])?;
        let unit = Unit::decode(&bytes, "harmonia.service", false)?;
        let slice = std::str::from_utf8(&bytes)?
            .lines()
            .find_map(|line| line.strip_prefix("Slice="));
        ensure!(
            slice == Some(super::workload::BUDGET_SLICE)
                && (unit.cgroup
                    == format!("{}/harmonia.service", super::workload::BUDGET_RELATIVE)
                    || (unit.stopped() && unit.cgroup.is_empty())),
            "publisher outside shared work budget"
        );
        Ok(())
    }

    /// Match the loaded unit to the root-declared immutable definition set.
    /// Runtime/transient overrides and pending reloads veto effects.
    pub(super) fn require_definition(&mut self, name: &str, expected: &[PathBuf]) -> Result<()> {
        self.require_definitions(&BTreeMap::from([(name.to_owned(), expected.to_vec())]))
    }

    /// One bounded observation for the installed set, not one process per unit.
    pub(super) fn require_definitions(
        &mut self,
        expected: &BTreeMap<String, Vec<PathBuf>>,
    ) -> Result<()> {
        ensure!(
            !expected.is_empty() && expected.len() <= 16,
            "unit definition query exceeds bound"
        );
        let expected = Self::definition_queries(expected)?;
        let property = format!("--property={DEFINITION_KEYS}");
        let mut args = vec!["show", property.as_str(), "--"];
        args.extend(expected.keys().map(String::as_str));
        let bytes = self.run(&args)?;
        let mut seen = std::collections::BTreeSet::new();
        for record in std::str::from_utf8(&bytes)?
            .trim_end_matches('\n')
            .split("\n\n")
        {
            let name = record
                .lines()
                .find_map(|line| line.strip_prefix("Id="))
                .context("unit definition identity missing")?;
            ensure!(seen.insert(name), "duplicate unit definition observation");
            let paths = expected.get(name).context("unexpected unit definition")?;
            Self::definition(record, name, paths)?;
        }
        ensure!(seen.len() == expected.len(), "unit definitions missing");
        Ok(())
    }

    fn definition_queries(
        expected: &BTreeMap<String, Vec<PathBuf>>,
    ) -> Result<BTreeMap<String, &[PathBuf]>> {
        let mut queries = BTreeMap::new();
        for (name, paths) in expected {
            // systemctl show rejects bare templates. A fixed, never-started
            // instance observes their definitions only; it grants no ownership.
            // Before effects, the actual execution instance is checked separately.
            let observed = match name.strip_suffix("@.service") {
                Some(prefix) => format!("{prefix}@abird-owned-definition.service"),
                None => name.clone(),
            };
            ensure!(
                queries.insert(observed, paths.as_slice()).is_none(),
                "unit definition probe identity collides"
            );
        }
        Ok(queries)
    }

    fn definition(text: &str, name: &str, expected: &[PathBuf]) -> Result<()> {
        let mut fields = BTreeMap::new();
        for line in text.lines() {
            let (key, value) = line
                .split_once('=')
                .context("invalid unit definition observation")?;
            ensure!(
                DEFINITION_KEYS.split(',').any(|known| known == key)
                    && fields.insert(key, value).is_none(),
                "ambiguous unit definition observation"
            );
        }
        let get = |key| {
            fields
                .get(key)
                .copied()
                .context("missing unit definition property")
        };
        ensure!(
            get("Id")? == name
                && get("LoadState")? == "loaded"
                && get("NeedDaemonReload")? == "no"
                && get("Transient")? == "no",
            "unit definition is not current"
        );
        let mut actual = vec![PathBuf::from(get("FragmentPath")?)];
        actual.extend(
            get("DropInPaths")?
                .split_ascii_whitespace()
                .map(PathBuf::from),
        );
        ensure!(
            actual.len() == expected.len(),
            "unit definition count differs"
        );
        for path in &mut actual {
            super::daemon::trusted_path(path)?;
            *path = std::fs::canonicalize(&path)?;
            super::daemon::store_path(path)?;
        }
        actual.sort();
        let mut expected = expected
            .iter()
            .map(|path| -> Result<PathBuf> {
                super::daemon::trusted_path(path)?;
                let path = std::fs::canonicalize(path)?;
                super::daemon::store_path(&path)?;
                super::daemon::trusted_path(&path)?;
                Ok(path)
            })
            .collect::<Result<Vec<_>>>()?;
        expected.sort();
        ensure!(actual == expected, "loaded unit definitions differ");
        Ok(())
    }

    fn show(&mut self, name: &str, workload: bool) -> Result<Unit> {
        let bytes = self.run(&["show", &format!("--property={PROPERTIES}"), "--", name])?;
        Unit::decode(&bytes, name, workload)
    }

    /// One delivery only, after a fresh durable reservation and permit publication.
    /// An error/timeout must be observed/reconciled, never retried as realization.
    pub fn request_start(&mut self, owner: &Ownership) -> Result<()> {
        self.run(&[
            "start",
            "--no-block",
            "--",
            "nix-daemon.socket",
            &owner.unit_name()?,
        ])?;
        Ok(())
    }

    pub(super) fn request_retirement_start(&mut self, owner: &Ownership) -> Result<()> {
        self.run(&["start", "--no-block", "--", &owner.unit_name()?])?;
        Ok(())
    }

    pub(super) fn request_retirement_stop(&mut self, owner: &Ownership) -> Result<()> {
        self.run(&["stop", "--no-block", "--", &owner.unit_name()?])?;
        Ok(())
    }

    pub(super) fn controller(&mut self, attempt: &str) -> Result<Unit> {
        self.show(&super::controller_service::unit(attempt)?, false)
    }

    pub(super) fn request_controller_start(&mut self, attempt: &str) -> Result<()> {
        self.run(&[
            "start",
            "--no-block",
            "--",
            &super::controller_service::unit(attempt)?,
        ])?;
        Ok(())
    }

    /// Stop only the already-settled observer, never the current worker/daemon.
    /// The retirement adapter supplies the original invocation/group evidence.
    pub(super) fn request_controller_stop(&mut self, attempt: &str) -> Result<()> {
        self.run(&[
            "stop",
            "--no-block",
            "--",
            &super::controller_service::unit(attempt)?,
        ])?;
        Ok(())
    }

    pub fn request_stop(&mut self, owner: &Ownership) -> Result<()> {
        self.run(&[
            "stop",
            "--no-block",
            "--",
            "nix-daemon.socket",
            "nix-daemon.service",
            &owner.unit_name()?,
        ])?;
        Ok(())
    }

    fn run(&mut self, args: &[&str]) -> Result<Vec<u8>> {
        let deadline = Instant::now() + self.timeout;
        let deadline = self.deadline.map_or(deadline, |outer| deadline.min(outer));
        ensure!(
            Instant::now() < deadline,
            "systemd adapter lifetime expired"
        );
        if let Some(child) = &mut self.pending {
            ensure!(
                child.try_wait()?.is_some(),
                ObservationUnavailable("previous systemd probe remains unresolved")
            );
            self.pending = None;
        }
        let child = Command::new(&self.systemctl)
            .env_clear()
            .env("LC_ALL", "C")
            .args(["--system", "--no-pager", "--no-ask-password"])
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0)
            .spawn()?;
        self.pending = Some(child);
        let result = self.capture(deadline);
        if result.is_err()
            && let Some(child) = &mut self.pending
        {
            // Only our unreaped, session-local systemctl process group.
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            if child.try_wait()?.is_some() {
                self.pending = None;
            }
        }
        result
    }

    fn capture(&mut self, deadline: Instant) -> Result<Vec<u8>> {
        let child = self
            .pending
            .as_mut()
            .context("missing local systemd probe")?;
        let mut stdout = child.stdout.take().context("missing stdout")?;
        let mut stderr = child.stderr.take().context("missing stderr")?;
        nonblocking(stdout.as_raw_fd())?;
        nonblocking(stderr.as_raw_fd())?;
        let mut output = Vec::new();
        let mut errors = Vec::new();
        let mut status = None;
        loop {
            let out_done = drain(&mut stdout, &mut output)?;
            let err_done = drain(&mut stderr, &mut errors)?;
            if status.is_none() {
                status = child.try_wait()?;
            }
            if let Some(status) = status {
                // No descendants are expected from pinned systemctl with pager/
                // password helpers disabled. Never signal a reaped PID on error.
                self.pending = None;
                ensure!(
                    status.success()
                        && (out_done || drain(&mut stdout, &mut output)?)
                        && (err_done || drain(&mut stderr, &mut errors)?),
                    ObservationUnavailable("systemd observation unconfirmed")
                );
                return Ok(output);
            }
            ensure!(
                Instant::now() < deadline,
                ObservationUnavailable("systemd observation timed out")
            );
            std::thread::park_timeout(
                Duration::from_millis(2).min(deadline.saturating_duration_since(Instant::now())),
            );
        }
    }
}

impl Drop for Units {
    fn drop(&mut self) {
        if let Some(child) = &mut self.pending {
            // No blocking wait in the control lane, even for uninterruptible I/O.
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            let _ = child.try_wait();
        }
    }
}

fn nonblocking(fd: i32) -> Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    ensure!(
        flags >= 0 && unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == 0,
        "cannot bound systemd pipe reads"
    );
    Ok(())
}
fn drain(reader: &mut impl Read, output: &mut Vec<u8>) -> Result<bool> {
    let mut bytes = [0; 1024];
    // Bound each poll even if a faulty producer writes continuously.
    for _ in 0..=MAX_BYTES / bytes.len() {
        match reader.read(&mut bytes) {
            Ok(0) => return Ok(true),
            Ok(count) => {
                ensure!(
                    output.len() + count <= MAX_BYTES,
                    "systemd output exceeds bound"
                );
                output.extend_from_slice(&bytes[..count]);
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => return Ok(false),
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.into()),
        }
    }
    Ok(false)
}

#[cfg(test)]
mod tests;
