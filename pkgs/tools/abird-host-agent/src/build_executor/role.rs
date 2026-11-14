//! Installed supervisor adapter. Immutable units and exclusive native-client
//! authority complement the durable fence/claim. This
//! module never adopts foreign work or bootstraps missing authority.

use std::collections::BTreeMap;
use std::ffi::CString;
use std::fs::File;
use std::io::Read;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::daemon::{self, Authority};
use super::journal::{Journal, Pool};
use super::launch_gate::{Fence, Gate};
use super::store_interlock::StoreInterlock;
use super::supervisor::{Active, ClientObservation, Ingress, Launcher, Progress, Supervisor};
use super::units::Units;
use super::workload::{self, FencedWorkload, Population};
use super::{Ownership, PoolHealth};

const SUPERVISOR: &str = "abird-owned-build-supervisor.service";
const CLIENT: &str = "abird-build-client@.service";
const DAEMON: &str = "nix-daemon.service";
const SOCKET: &str = "nix-daemon.socket";
pub(super) const BOOTSTRAP: &str = "abird-owned-build-bootstrap.service";
pub(super) const GC_REQUEST: &str = "abird-owned-maintenance-request.service";
const DECLARED_UNITS: [&str; 13] = [
    SUPERVISOR,
    CLIENT,
    DAEMON,
    SOCKET,
    BOOTSTRAP,
    "abird-owned-build-control@.service",
    "abird-owned-build-control.socket",
    "abird.slice",
    "abird-build.slice",
    "abird-build-owned.slice",
    "abird-control.slice",
    GC_REQUEST,
    super::controller_service::TEMPLATE,
];

/// Fixed modes of the existing manager binary, never caller-selected argv.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ManagerCommand {
    Capture,
    Source,
    Request,
    Prepare,
    Query,
    Controller,
}

impl ManagerCommand {
    pub fn argument(self) -> &'static str {
        match self {
            Self::Capture => "_owned-capture",
            Self::Source => "_owned-source",
            Self::Request => "_owned-request",
            Self::Prepare => "_owned-prepare",
            Self::Query => "_owned-query",
            Self::Controller => "_owned-controller",
        }
    }

    pub fn from_argument(value: &std::ffi::OsStr) -> Option<Self> {
        [
            Self::Capture,
            Self::Source,
            Self::Request,
            Self::Prepare,
            Self::Query,
            Self::Controller,
        ]
        .into_iter()
        .find(|mode| value == mode.argument())
    }

    fn command(self, program: &Path) -> std::process::Command {
        let mut command = std::process::Command::new(program);
        command.arg(self.argument());
        command
    }
}

fn manager_program(path: &Path) -> Result<()> {
    daemon::store_path(path)?;
    ensure!(
        path.ends_with("libexec/abird-host-manager"),
        "owned worker requires the unwrapped manager executable"
    );
    Ok(())
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub version: u32,
    pub manager_program: PathBuf,
    /// Root-installed closureInfo store-paths manifest; no caller root list.
    pub runtime_closure: PathBuf,
    /// Existing cache service shares the budget, never the native kill boundary.
    pub publisher: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub consumer: Option<super::consumer_role::Policy>,
    pub systemctl: PathBuf,
    pub daemon_policy: PathBuf,
    pub control: PathBuf,
    pub input_gid: u32,
    /// Dedicated authenticated source relay UID per ordinary issuer. These
    /// accounts cannot issue control commands or submit native requests.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub input_principals: BTreeMap<String, u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_transport: Option<InputTransport>,
    /// Canonical immutable fragment and drop-in paths, including template files.
    pub definitions: BTreeMap<String, Vec<PathBuf>>,
    pub limits: Limits,
    pub control_limits: ControlLimits,
    pub build: super::build_worker::Policy,
    pub controller: super::controller_service::Policy,
}

/// Fixed admitted inetd SSH endpoint, never another execution authority.
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct InputTransport {
    pub sshd: PathBuf,
    pub configuration: PathBuf,
    pub host_keys: Vec<PathBuf>,
    pub port: u16,
}

impl InputTransport {
    fn validate(&self) -> Result<()> {
        daemon::store_path(&self.sshd)?;
        daemon::store_path(&self.configuration)?;
        ensure!(
            self.sshd.file_name().is_some_and(|name| name == "sshd")
                && self.port > 0
                && !self.host_keys.is_empty()
                && self.host_keys.len() <= 16,
            "invalid input SSH policy"
        );
        for key in &self.host_keys {
            super::capture_role::validate_ssh_path(key)?;
        }
        Ok(())
    }

    pub(super) fn ready(&self) -> Result<()> {
        self.validate()?;
        daemon::trusted_path(&self.sshd)?;
        daemon::read_declaration(&self.configuration)?;
        ensure!(
            matches!(std::fs::symlink_metadata("/etc/ssh/sshrc"), Err(error) if error.kind() == std::io::ErrorKind::NotFound),
            "input SSH does not authorize a system sshrc helper"
        );
        for key in &self.host_keys {
            super::capture_role::trusted_ssh_file(key, true)?;
        }
        Ok(())
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ControlLimits {
    pub memory_max: u64,
    pub tasks_max: u64,
    pub cpu_percent: u64,
}

impl ControlLimits {
    pub(super) fn ready(&self) -> Result<()> {
        for (name, expected) in [
            ("memory.max", self.memory_max.to_string()),
            ("pids.max", self.tasks_max.to_string()),
            ("memory.swap.max", "0".to_owned()),
            ("cpu.max", format!("{} 100000", self.cpu_percent * 1000)),
        ] {
            let mut value = String::new();
            File::open(format!(
                "/sys/fs/cgroup/{}/{name}",
                workload::CONTROL.trim_start_matches('/')
            ))?
            .take(513)
            .read_to_string(&mut value)?;
            ensure!(
                value.len() <= 512 && value.trim_end() == expected,
                "effective control limit differs"
            );
        }
        Ok(())
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Limits {
    pub cpu_quota_micros: u64,
    pub cpu_period_micros: u64,
    pub memory_high: u64,
    pub memory_max: u64,
    pub swap_max: u64,
    pub tasks_max: u64,
    pub min_store_free_bytes: u64,
    pub min_state_free_bytes: u64,
}

impl Policy {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.version == 2, "unsupported installed role policy");
        manager_program(&self.manager_program)?;
        daemon::store_path(&self.runtime_closure)?;
        self.build.validate()?;
        self.controller.validate()?;
        if let Some(consumer) = &self.consumer {
            consumer.validate()?;
            ensure!(
                !self.controller.accounts.is_empty(),
                "consumer accounts missing"
            );
        }
        ensure!(
            self.input_principals.len() <= 64,
            "too many input principals"
        );
        ensure!(
            self.input_transport.is_some() != self.input_principals.is_empty(),
            "input SSH authority is incomplete"
        );
        if let Some(input) = &self.input_transport {
            input.validate()?;
        }
        let mut input_uids = std::collections::BTreeSet::new();
        for (issuer, uid) in &self.input_principals {
            super::identifier(issuer)?;
            ensure!(
                *uid > 0
                    && *uid < u32::MAX
                    && *uid != self.build.uid
                    && *uid != self.build.source_uid
                    && input_uids.insert(*uid),
                "invalid or duplicate input principal"
            );
        }
        ensure!(
            self.control_limits.memory_max > 0
                && self.control_limits.tasks_max > 0
                && self.control_limits.cpu_percent > 0
                && self.control_limits.cpu_percent <= u64::MAX / 1000,
            "incomplete control resource policy"
        );
        ensure!(
            self.input_gid > 0 && self.input_gid < u32::MAX && self.input_gid != self.build.gid,
            "invalid source ingress group"
        );
        daemon::store_path(&self.systemctl)?;
        ensure!(
            self.systemctl
                .file_name()
                .is_some_and(|name| name == "systemctl"),
            "unexpected role observer"
        );
        for path in [&self.daemon_policy, &self.control] {
            ensure!(
                path.is_absolute()
                    && !path
                        .components()
                        .any(|part| part == std::path::Component::ParentDir),
                "invalid role declaration path"
            );
        }
        ensure!(
            self.definitions.len()
                == DECLARED_UNITS.len()
                    + usize::from(self.publisher)
                    + usize::from(self.consumer.is_some()),
            "incomplete installed unit set"
        );
        for name in DECLARED_UNITS
            .into_iter()
            .chain(self.publisher.then_some("harmonia.service"))
            .chain(self.consumer.as_ref().map(|_| super::consumer_role::SLICE))
        {
            let paths = self
                .definitions
                .get(name)
                .context("installed unit definition missing")?;
            ensure!(
                !paths.is_empty() && paths.len() <= 8,
                "invalid installed unit definitions"
            );
            let mut unique = std::collections::BTreeSet::new();
            for path in paths {
                daemon::store_path(path)?;
                ensure!(unique.insert(path), "duplicate installed unit definition");
            }
        }
        let limits = &self.limits;
        ensure!(
            limits.cpu_quota_micros > 0
                && (1_000..=1_000_000).contains(&limits.cpu_period_micros)
                && limits.memory_high > 0
                && limits.memory_high < limits.memory_max
                && limits.tasks_max > 0
                && limits.min_store_free_bytes > 0
                && limits.min_state_free_bytes >= 32 * 1024 * 1024,
            "incomplete role resource policy"
        );
        Ok(())
    }

    pub(super) fn budget_members(&self, units: &mut Units) -> Result<()> {
        let mut expected = vec![workload::SLICE];
        if self.publisher {
            units.require_publisher_placement()?;
            expected.push("harmonia.service");
        }
        if self.consumer.is_some() {
            expected.push(super::consumer_role::SLICE);
        }
        ensure!(
            workload::only_budget_roots(&expected)?,
            "undeclared aggregate budget population"
        );
        Ok(())
    }

    pub(super) fn manager(&self, operation: ManagerCommand) -> std::process::Command {
        operation.command(&self.manager_program)
    }

    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        let mut bytes = b"abird-owned-role-v2\n".to_vec();
        bytes.extend(serde_json::to_vec(&serde_json::to_value(self)?)?);
        Ok(crate::sha256::digest_bytes(&bytes))
    }

    pub(super) fn load(path: &Path) -> Result<Self> {
        let value: Self = serde_json::from_slice(&daemon::read_declaration(path)?)
            .map_err(|_| anyhow::anyhow!("invalid installed role declaration"))?;
        value.validate()?;
        daemon::executable(&value.systemctl)?;
        daemon::executable(&value.manager_program)?;
        for paths in value.definitions.values().chain(
            value
                .consumer
                .iter()
                .flat_map(|consumer| consumer.definitions.values()),
        ) {
            for path in paths {
                daemon::trusted_path(path)?;
                let resolved = std::fs::canonicalize(path)?;
                daemon::store_path(&resolved)?;
                daemon::trusted_path(&resolved)?;
                ensure!(resolved.is_file(), "installed unit definition unavailable");
            }
        }
        Ok(value)
    }
}

impl Limits {
    /// Admission headroom is not a physical reserve or quota certificate.
    pub(super) fn ready(&self, state_root: &Path) -> Result<bool> {
        self.require_budget()?;
        Ok(
            free_bytes(Path::new("/nix/store"))? >= self.min_store_free_bytes
                && free_bytes(state_root)? >= self.min_state_free_bytes,
        )
    }

    pub(super) fn require_budget(&self) -> Result<()> {
        for (name, expected) in [
            (
                "cpu.max",
                format!("{} {}", self.cpu_quota_micros, self.cpu_period_micros),
            ),
            ("memory.high", self.memory_high.to_string()),
            ("memory.max", self.memory_max.to_string()),
            ("memory.swap.max", self.swap_max.to_string()),
            ("pids.max", self.tasks_max.to_string()),
        ] {
            let mut value = String::new();
            File::open(Path::new(workload::BUDGET_CGROUP).join(name))?
                .take(513)
                .read_to_string(&mut value)?;
            ensure!(
                value.len() <= 512 && value.trim_end() == expected,
                "effective work limit differs"
            );
        }
        Ok(())
    }
}

fn free_bytes(path: &Path) -> Result<u64> {
    let path = CString::new(path.as_os_str().as_bytes())?;
    let mut value: libc::statvfs = unsafe { std::mem::zeroed() };
    ensure!(
        unsafe { libc::statvfs(path.as_ptr(), &mut value) } == 0,
        std::io::Error::last_os_error()
    );
    value
        .f_bavail
        .checked_mul(value.f_frsize)
        .context("filesystem capacity overflow")
}

struct Runtime<'a> {
    policy: &'a Policy,
    digest: String,
    journal: &'a Journal,
    units: Units,
}

impl Runtime<'_> {
    fn definitions(&mut self, owner: Option<&Ownership>) -> Result<()> {
        super::store_binding::validate(self.journal.authority_root(), self.journal.identity())?;
        self.policy.control_limits.ready()?;
        let mut definitions = self.policy.definitions.clone();
        if let Some(owner) = owner {
            let paths = definitions
                .remove(CLIENT)
                .context("client template missing")?;
            definitions.insert(owner.unit_name()?, paths);
        }
        self.units.require_definitions(&definitions)?;
        if let Some(consumer) = &self.policy.consumer {
            consumer.require(&mut self.units)?;
        }
        self.policy.budget_members(&mut self.units)
    }

    fn recover(&mut self, gate: &Gate) -> Result<()> {
        let pool = self.journal.pool()?;
        if pool.owner.is_some() {
            return Ok(());
        }
        let Some(fence) = gate.try_fence()? else {
            return Ok(());
        };
        self.definitions(None)?;
        if self.units.socket()?.stopped()
            && self.units.daemon()?.stopped()
            && FencedWorkload::new(&fence)?.population()? == Population::Empty
            && self.policy.limits.ready(self.journal.authority_root())?
        {
            for owner in self.journal.release_settled_maintenance(daemon::now()?)? {
                super::native_phase::Gate::retire(self.journal, &owner, || {
                    ensure!(
                        self.journal.pool()? == pool
                            && FencedWorkload::new(&fence)?.population()? == Population::Empty,
                        "maintenance gate retirement lost its original fence"
                    );
                    Ok(())
                })?;
            }
            if pool.health != PoolHealth::Available {
                self.journal
                    .recovered(pool.epoch, gate.boot_id(), &self.digest, daemon::now()?)?;
            }
        }
        Ok(())
    }
}

impl Launcher for Runtime<'_> {
    fn ready(&mut self, fence: &Fence<'_>, pool: &Pool) -> Result<bool> {
        self.definitions(None)?;
        if let Some(input) = &self.policy.input_transport {
            input.ready()?;
        }
        Ok(
            pool.recovery_digest.as_deref() == Some(self.digest.as_str())
                && self.units.socket()?.stopped()
                && self.units.daemon()?.stopped()
                && FencedWorkload::new(fence)?.population()? == Population::Empty
                && self.policy.limits.ready(self.journal.authority_root())?,
        )
    }

    fn start_once(&mut self, owner: &Ownership) -> Result<()> {
        self.definitions(Some(owner))?;
        let client = self.units.client(owner)?;
        ensure!(
            client.stopped() && client.invocation.is_none(),
            "client unit already used"
        );
        if let Some(request) = self.journal.claim_controller(owner, daemon::now()?)? {
            ensure!(
                self.policy
                    .controller
                    .accounts
                    .contains_key(&request.issuer),
                "CI observer account is not installed"
            );
            let unit = super::controller_service::unit(&owner.attempt_id)?;
            self.units.require_definition(
                &unit,
                &self.policy.definitions[super::controller_service::TEMPLATE],
            )?;
            let observed = self.units.controller(&owner.attempt_id)?;
            ensure!(
                observed.stopped() && observed.invocation.is_none(),
                "CI observer unit was already used"
            );
            let path = format!("/sys/fs/cgroup{}/{unit}", workload::CONTROL);
            ensure!(
                matches!(std::fs::symlink_metadata(path), Err(error) if error.kind() == std::io::ErrorKind::NotFound),
                "CI observer cgroup already exists or is unconfirmed"
            );
            self.units.request_controller_start(&owner.attempt_id)?;
        }
        if self.journal.work_kind(owner, daemon::now()?)? == super::journal::work::Kind::Retirement
        {
            self.units.request_retirement_start(owner)
        } else {
            self.units.request_start(owner)
        }
    }
}

impl Ingress for Runtime<'_> {
    fn observe_client(&mut self, active: &Active) -> Result<ClientObservation> {
        if self.journal.claimed_daemon(&active.owner)?.is_some() {
            super::native_phase::Gate::open(self.journal, active.owner.clone())?
                .validate(self.journal)?;
        }
        self.units
            .require_definition(&active.owner.unit_name()?, &self.policy.definitions[CLIENT])?;
        self.units
            .client(&active.owner)?
            .observe_client(&active.owner, active.handle.as_ref())
    }

    fn owns_ingress(&mut self, active: &Active) -> Result<bool> {
        self.definitions(Some(&active.owner))?;
        let pool = self.journal.pool()?;
        if pool.owner.as_ref() != Some(&active.owner)
            || pool.recovery_digest.as_deref() != Some(self.digest.as_str())
            || pool.verified_boot.as_deref() != Some(active.owner.boot_id.as_str())
        {
            return Ok(false);
        }
        let client = self.units.client(&active.owner)?;
        if let Some(handle) = &active.handle {
            if !client.matches_handle(handle)? {
                return Ok(false);
            }
        } else if !client.stopped() {
            return Ok(false);
        }
        let daemon = self.units.daemon()?;
        let claim = self.journal.claimed_daemon(&active.owner)?;
        let retirement = self.journal.retirement_operation(&active.owner)?;
        if !daemon_ingress_owned(
            claim.as_ref().map(|handle| handle.invocation_id.as_str()),
            daemon.invocation.as_deref(),
            daemon.stopped(),
            retirement,
            || Ok(self.units.socket()?.stopped()),
        )? {
            return Ok(false);
        }
        workload::only_unit_roots(&[DAEMON, &active.owner.unit_name()?])
    }

    fn request_stop(&mut self, active: &Active) -> Result<()> {
        if self.journal.retirement_operation(&active.owner)? {
            self.units.request_retirement_stop(&active.owner)
        } else {
            self.units.request_stop(&active.owner)
        }
    }

    fn quiescent(&mut self, active: &Active) -> Result<bool> {
        // The held fence blocks all wrappers. Closing the native socket removes
        // new peers; surviving handlers remain inside the accounted daemon unit.
        Ok(self.units.socket()?.stopped()
            && workload::only_unit_roots(&[DAEMON, &active.owner.unit_name()?])?)
    }
}

/// Whether the native daemon unit's state is attributable to this attempt.
/// A stopped unit keeps its last InvocationID, possibly from an earlier,
/// already settled job: with no claim by this attempt (e.g. lost before its
/// pre-exec claim) there is nothing running to own or adopt. A running
/// unclaimed daemon is foreign. Retirement additionally requires a closed
/// socket (it never opens native ingress). Settlement still needs socket
/// closure and positive aggregate emptiness under the held fence.
fn daemon_ingress_owned(
    claim: Option<&str>,
    invocation: Option<&str>,
    stopped: bool,
    retirement: bool,
    socket_stopped: impl FnOnce() -> Result<bool>,
) -> Result<bool> {
    Ok(match claim {
        Some(claimed) if invocation == Some(claimed) => true,
        _ if invocation.is_none() && stopped => true,
        None if retirement => stopped && socket_stopped()?,
        None => stopped,
        Some(_) => false,
    })
}

/// Existing authority only. No init/regrant on daemon, supervisor or caller loss.
/// Fixed template entry; kind comes from the original journal owner, never argv.
pub fn run_worker(path: &Path, attempt: &str) -> Result<()> {
    let role = Policy::load(path)?;
    let authority = daemon::open_authority(&role.daemon_policy, &role.control)?;
    ensure!(
        authority.policy.containment_digest == role.digest()?,
        "worker role binding differs"
    );
    let owner = authority
        .journal
        .pool()?
        .owner
        .context("worker owner missing")?;
    ensure!(owner.attempt_id == attempt, "worker instance differs");
    workload::require_client_placement(&owner)?;
    let mut units = Units::new(role.systemctl.clone(), Duration::from_secs(2))?;
    units.require_definition(&owner.unit_name()?, &role.definitions[CLIENT])?;
    match authority.journal.work_kind(&owner, daemon::now()?)? {
        super::journal::work::Kind::Build => {
            let config: super::control::Config =
                serde_json::from_slice(&daemon::read_declaration(&role.control)?)?;
            let store = StoreInterlock::open(authority.journal.identity().clone())?;
            super::build_worker::Session::start(
                &authority.journal,
                &authority.gate,
                &authority.policy,
                &role,
                &store,
                attempt,
            )?
            .execute(&config)
        }
        super::journal::work::Kind::Maintenance => {
            super::maintenance_worker::run_installed(&role, attempt)
        }
        super::journal::work::Kind::Retirement => super::retirement::run_installed(&role, attempt),
    }
}

pub fn run_service(path: &Path) -> Result<()> {
    let policy = Policy::load(path)?;
    let Authority {
        policy: native,
        journal,
        gate,
    } = daemon::open_supervisor_authority(&policy.daemon_policy, &policy.control)?;
    let digest = policy.digest()?;
    ensure!(
        native.containment_digest == digest,
        "installed role binding differs"
    );
    let controller = gate
        .try_controller()?
        .context("owned supervisor already active")?;
    let mut supervisor = Supervisor::new(&journal, controller)?;
    let store = StoreInterlock::open(journal.identity().clone())?;
    let mut runtime = Runtime {
        policy: &policy,
        digest,
        journal: &journal,
        units: Units::new(policy.systemctl.clone(), Duration::from_secs(10))?,
    };
    let mut next_prune = Instant::now();
    loop {
        let step = (|| -> Result<()> {
            let now = daemon::now()?;
            if Instant::now() >= next_prune {
                journal.prune_if_due(now)?;
                next_prune = Instant::now() + Duration::from_secs(15);
            }
            runtime.recover(&gate)?;
            if journal.pool()?.health == PoolHealth::Available {
                journal.schedule_retirement(daemon::now()?)?;
                if let Err(error) = supervisor.launch_next(&store, &mut runtime, daemon::now()?) {
                    let Some(owner) = journal.pool()?.owner else {
                        return Err(error);
                    };
                    // Reservation consumed dispatch even if systemd lost its ACK.
                    // Observe that original owner; never start it a second time.
                    journal.dispatch_unconfirmed(&owner, daemon::now()?)?;
                }
            }
            if supervisor.poll(&mut runtime, daemon::now()?)? == Progress::Verifying {
                supervisor.finish_verified(&mut runtime, daemon::now()?)?;
            }
            Ok(())
        })();
        if let Err(error) = step
            && !error.is::<super::units::ObservationUnavailable>()
        {
            return Err(error);
        }
        // Unavailable probes retain their original handle and all ownership.
        // A fresh positive observation is still required before any next effect.
        std::thread::park_timeout(Duration::from_millis(250));
    }
}

#[cfg(test)]
mod manager_tests {
    use super::*;

    #[test]
    fn unclaimed_stopped_daemon_with_a_stale_invocation_is_not_foreign() {
        let ok = || Ok(true);
        // Earlier settled job's InvocationID on a stopped unit: ownable.
        assert!(daemon_ingress_owned(None, Some("old"), true, false, ok).unwrap());
        // Running daemon without this attempt's claim: foreign.
        assert!(!daemon_ingress_owned(None, Some("old"), false, false, ok).unwrap());
        // Claimed: only the exact invocation, or a collected stopped unit.
        assert!(daemon_ingress_owned(Some("a"), Some("a"), false, false, ok).unwrap());
        assert!(!daemon_ingress_owned(Some("a"), Some("b"), true, false, ok).unwrap());
        assert!(daemon_ingress_owned(Some("a"), None, true, false, ok).unwrap());
        // Retirement never opens ingress: a listening socket is foreign.
        assert!(!daemon_ingress_owned(None, Some("old"), true, true, || Ok(false)).unwrap());
        assert!(daemon_ingress_owned(None, Some("old"), true, true, ok).unwrap());
    }

    #[test]
    fn all_worker_modes_share_one_unwrapped_binary_and_fixed_first_argument() {
        let program = Path::new(
            "/nix/store/00000000000000000000000000000000-manager/libexec/abird-host-manager",
        );
        assert!(manager_program(program).is_ok());
        for mode in [
            ManagerCommand::Capture,
            ManagerCommand::Source,
            ManagerCommand::Request,
            ManagerCommand::Prepare,
            ManagerCommand::Query,
            ManagerCommand::Controller,
        ] {
            assert_eq!(
                ManagerCommand::from_argument(std::ffi::OsStr::new(mode.argument())),
                Some(mode)
            );
            let command = mode.command(program);
            assert_eq!(command.get_program(), program.as_os_str());
            assert_eq!(
                command.get_args().collect::<Vec<_>>(),
                vec![std::ffi::OsStr::new(mode.argument())]
            );
        }
        for rejected in [
            "/nix/store/00000000000000000000000000000000-manager/bin/abird-host-manager",
            "/nix/store/00000000000000000000000000000000-manager/bin/abird-owned-prepare",
            "/usr/libexec/abird-host-manager",
        ] {
            assert!(manager_program(Path::new(rejected)).is_err());
        }
        for rejected in [
            "fleet",
            "--help",
            "_owned-unknown",
            "_owned-prepare --impure",
        ] {
            assert!(ManagerCommand::from_argument(std::ffi::OsStr::new(rejected)).is_none());
        }
    }
}
