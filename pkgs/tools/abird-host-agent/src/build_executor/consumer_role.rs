//! Fixed shared-store consumer authority. No daemon window, scheduler, arbitrary
//! command, or process adoption. Root entry drops credentials without another exec.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::{controller_service, daemon, process, role, units::Units, workload};

pub const SLICE: &str = "abird-build-consumer.slice";
pub const TEMPLATE: &str = "abird-owned-consumer@.service";
pub const SOCKET: &str = "abird-owned-consumer.socket";
pub const ENDPOINT: &str = "/run/abird/abird-host-agent/owned-build/consumer.sock";
const POLICY: &str = "/etc/abird-owned-build/role.json";

/// Fixed diagnostics only; underlying errors may carry private caller data.
#[derive(Debug)]
pub enum FailureStage {
    Peer,
    GcLock,
    Placement,
    Policy,
    Program,
    Account,
    Groups,
    Units,
    Budget,
    Credentials,
    Exclusion,
    Request,
    Operation,
    Reply,
}

impl std::fmt::Display for FailureStage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Peer => "peer",
            Self::GcLock => "gc-lock",
            Self::Placement => "placement",
            Self::Policy => "policy",
            Self::Program => "program",
            Self::Account => "account",
            Self::Groups => "groups",
            Self::Units => "units",
            Self::Budget => "budget",
            Self::Credentials => "credentials",
            Self::Exclusion => "run-exclusion",
            Self::Request => "request",
            Self::Operation => "operation",
            Self::Reply => "reply",
        })
    }
}

impl std::error::Error for FailureStage {}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub definitions: BTreeMap<String, Vec<PathBuf>>,
}

impl Policy {
    pub(super) fn validate(&self) -> Result<()> {
        ensure!(self.definitions.len() == 2, "invalid consumer unit set");
        for name in [TEMPLATE, SOCKET] {
            let paths = self
                .definitions
                .get(name)
                .context("consumer definition missing")?;
            ensure!(
                !paths.is_empty() && paths.len() <= 8,
                "invalid consumer definitions"
            );
            let mut unique = BTreeSet::new();
            for path in paths {
                daemon::store_path(path)?;
                ensure!(unique.insert(path), "duplicate consumer definition");
            }
        }
        Ok(())
    }

    pub(super) fn require(&self, units: &mut Units) -> Result<()> {
        // A separate fixed two-unit query preserves the existing observation bound.
        units.require_definitions(&self.definitions)
    }
}

/// Called once by the fixed root-started manager entry, before reading any
/// caller payload. `uid` must come from the connected socket's SO_PEERCRED.
pub fn enter(uid: u32) -> Result<()> {
    ensure!(
        unsafe { libc::geteuid() } == 0 && uid > 0 && uid < u32::MAX,
        "consumer wrapper requires root and an ordinary peer"
    );
    process::protect_worker_memory()?;
    ensure!(
        std::fs::read_dir("/proc/self/task")?.take(2).count() == 1,
        "consumer privilege transition requires a single thread"
    );
    let unit = workload::consumer_unit().context(FailureStage::Placement)?;
    let policy = role::Policy::load(Path::new(POLICY)).context(FailureStage::Policy)?;
    let consumer = policy
        .consumer
        .as_ref()
        .context("shared consumer role unavailable")?;
    ensure!(
        std::fs::canonicalize(&policy.manager_program).context(FailureStage::Program)?
            == std::env::current_exe().context(FailureStage::Program)?,
        FailureStage::Program
    );
    let account = policy
        .controller
        .accounts
        .values()
        .find(|account| account.uid == uid)
        .context(FailureStage::Account)?;
    controller_service::require_primary_group(account).context(FailureStage::Account)?;
    controller_service::require_groups(account).context(FailureStage::Groups)?;
    let mut units = Units::new(policy.systemctl.clone(), Duration::from_secs(2))
        .context(FailureStage::Units)?;
    units
        .require_definition(&unit, &consumer.definitions[TEMPLATE])
        .context(FailureStage::Units)?;
    units
        .require_definition(SOCKET, &consumer.definitions[SOCKET])
        .context(FailureStage::Units)?;
    units
        .require_definition(SLICE, &policy.definitions[SLICE])
        .context(FailureStage::Units)?;
    policy
        .limits
        .require_budget()
        .context(FailureStage::Budget)?;
    process::child_credentials(account.uid, account.gid, &account.groups)
        .context(FailureStage::Credentials)?;
    // setresuid changes dumpability. Protect again; never exec after this drop.
    process::protect_worker_memory()?;
    ensure!(
        unsafe { libc::getuid() } == uid && unsafe { libc::geteuid() } == uid,
        "consumer credential transition incomplete"
    );
    Ok(())
}
