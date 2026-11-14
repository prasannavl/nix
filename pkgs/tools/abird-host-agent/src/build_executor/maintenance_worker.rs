//! Installed fixed collector for already-admitted maintenance. No scheduler,
//! caller GC verb, release grant or descendant-settlement claim. A matching
//! native collector can record verification; the supervisor still owns settlement.

use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, ensure};

use super::ExecutionHandle;
use super::daemon::{self, Authority, Policy};
use super::launch_gate::{Permission, Permit};
use super::maintenance::Operation;
use super::store_interlock::StoreInterlock;
use super::workload;

/// Derived from the declared immutable Nix package, never PATH or caller argv.
/// Output is discarded until bounded persistent capture is qualified separately.
fn command(policy: &Policy) -> Command {
    let mut command = Command::new(policy.program.with_file_name("nix-store"));
    command
        .args(["--store", "daemon", "--gc"])
        .env_clear()
        .env("HOME", "/var/empty")
        .env("LC_ALL", "C")
        .env("PATH", &policy.search_path)
        .env("NIX_CONF_DIR", &policy.configuration_directory)
        .env("NIX_SSL_CERT_FILE", &policy.certificate_bundle)
        .current_dir("/var/empty")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command
}

// Child-only descriptor table; parent retains store exclusion through wait.
fn close_descriptors() -> std::io::Result<()> {
    if unsafe {
        libc::syscall(
            libc::SYS_close_range,
            3u32,
            u32::MAX,
            libc::CLOSE_RANGE_CLOEXEC | libc::CLOSE_RANGE_UNSHARE,
        )
    } != 0
    {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

// Native GC uses the same exclusive, unprivileged executor as Build. The root
// parent alone retains journal/exclusion authority; none crosses exec.
fn collector_child((uid, gid): (u32, u32)) -> std::io::Result<()> {
    super::process::child_credentials(uid, gid, &[])?;
    close_descriptors()
}

fn cutoff(
    reserved: Option<u64>,
    runtime: u64,
    wall: Duration,
    monotonic: Instant,
) -> Result<Instant> {
    super::process::cutoff(reserved, runtime, wall, monotonic)
}

fn before(deadline: Instant) -> Result<()> {
    ensure!(Instant::now() < deadline, "maintenance deadline expired");
    Ok(())
}

/// Trusted root unit only. Reuses the original reservation, invocation, store
/// lock, launch permit and one-shot worker grant. Zero exit is NOT job success.
/// Fixed installed intent issuer. No caller arguments, native effects or retry.
pub fn request_service(path: &std::path::Path) -> Result<()> {
    let role = super::role::Policy::load(path)?;
    let authority = daemon::open_maintenance_request_authority(&role.daemon_policy, &role.control)?;
    ensure!(
        authority.policy.containment_digest == role.digest()?,
        "maintenance requester binding differs"
    );
    role.control_limits.ready()?;
    let mut units =
        super::units::Units::new(role.systemctl.clone(), std::time::Duration::from_secs(2))?;
    units.require_definition(
        super::role::GC_REQUEST,
        &role.definitions[super::role::GC_REQUEST],
    )?;
    let nonce = std::env::var("INVOCATION_ID")
        .map_err(|_| anyhow::anyhow!("maintenance invocation unavailable"))?;
    ensure!(
        nonce.len() == 32 && nonce.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "invalid maintenance invocation"
    );
    let now = daemon::now()?;
    let policy = authority.journal.admission_policy();
    authority.journal.submit_maintenance(
        super::maintenance::Request {
            version: super::maintenance::VERSION,
            id: super::request::RequestId {
                issued_at: now,
                nonce,
            },
            storage: authority.journal.identity().clone(),
            policy_digest: policy.digest()?,
            deadlines: policy.deadlines.clone(),
            operation: super::maintenance::Operation::CollectGarbage,
        },
        now,
    )?;
    Ok(())
}

pub fn run_service(policy_path: &Path, control_path: &Path, attempt: &str) -> Result<()> {
    super::identifier(attempt)?;
    run(
        daemon::open_authority(policy_path, control_path)?,
        attempt,
        None,
    )
}

pub(super) fn run_installed(role: &super::role::Policy, attempt: &str) -> Result<()> {
    let authority = daemon::open_authority(&role.daemon_policy, &role.control)?;
    ensure!(
        authority.policy.containment_digest == role.digest()?,
        "maintenance role binding differs"
    );
    run(authority, attempt, Some(role))
}

fn run(authority: Authority, attempt: &str, role: Option<&super::role::Policy>) -> Result<()> {
    let Authority {
        policy,
        journal,
        gate,
    } = authority;
    let executor = super::role::Policy::load(&policy.role_policy)?;
    ensure!(
        executor.digest()? == policy.containment_digest,
        "maintenance executor binding differs"
    );
    policy.require_executor(&executor.build)?;
    let credentials = (executor.build.uid, executor.build.gid);
    let owner = journal.pool()?.owner.context("maintenance owner missing")?;
    ensure!(owner.attempt_id == attempt, "maintenance instance differs");
    workload::require_client_placement(&owner)?;
    let handle = ExecutionHandle {
        ownership: owner.clone(),
        invocation_id: std::env::var("INVOCATION_ID")
            .map_err(|_| anyhow::anyhow!("maintenance invocation unavailable"))?,
    };
    handle.validate(attempt)?;
    // Take monotonic time before wall time and before reading the reservation.
    // Later clock regressions cannot extend this cap; retain subsecond elapsed.
    let monotonic = Instant::now();
    let wall = SystemTime::now().duration_since(UNIX_EPOCH)?;
    let status = journal.maintenance_status(attempt)?;
    ensure!(
        status.attempt.phase() == super::Phase::Starting,
        "maintenance worker already started or stopped"
    );
    ensure!(
        status.request.operation == Operation::CollectGarbage,
        "unsupported maintenance operation"
    );
    let deadline = cutoff(
        status.reserved_at,
        status.request.deadlines.runtime_seconds,
        wall,
        monotonic,
    )?;
    let mut command = command(&policy);
    daemon::executable(Path::new(command.get_program()))?;
    let store = StoreInterlock::open(journal.identity().clone())?;
    let maintenance = loop {
        before(deadline)?;
        if let Some(guard) = store.try_maintenance(&journal, &owner, daemon::now()?)? {
            break guard;
        }
        std::thread::park_timeout(Duration::from_millis(10));
    };
    let launch = gate
        .authorize(&Permit {
            version: 1,
            identity: journal.identity().clone(),
            permission: Permission::Execution { ownership: owner },
        })?
        .context("maintenance launch pending")?;
    before(deadline)?;
    maintenance.validate(&journal, daemon::now()?)?;
    super::native_phase::begin_worker(&journal, &gate, handle.clone(), daemon::now()?)?;
    journal.diagnose(&handle, super::diagnostics::Activity::Collect, || {
        let native_phase = super::native_phase::Gate::open(&journal, handle.ownership.clone())?;
        native_phase.require_open(&journal)?;
        policy.require_socket()?;
        before(deadline)?;
        unsafe {
            command.pre_exec(move || collector_child(credentials));
        }
        let mut child = command.spawn()?;
        drop(launch);
        loop {
            before(deadline)?;
            maintenance.validate(&journal, daemon::now()?)?;
            if let Some(exit) = child.try_wait()? {
                ensure!(exit.success(), "maintenance collector failed");
                // Only the same immutable native multicall binary can certify this
                // fixed RPC. Interposition/qualification helpers remain unverified.
                if let Some(role) = role {
                    ensure!(
                        std::fs::canonicalize(command.get_program())?
                            == std::fs::canonicalize(&policy.program)?,
                        "maintenance collector is not the declared native binary"
                    );
                    let mut units =
                        super::units::Units::new(role.systemctl.clone(), Duration::from_secs(2))?
                            .with_deadline(deadline);
                    journal.diagnose(&handle, super::diagnostics::Activity::NativeSeal, || {
                        native_phase.seal_and_settle(
                            &journal,
                            &mut units,
                            &role.definitions["nix-daemon.service"],
                            &policy.program,
                            deadline,
                        )
                    })?;
                    before(deadline)?;
                    maintenance.validate(&journal, daemon::now()?)?;
                    let native = journal
                        .claimed_daemon(&handle.ownership)?
                        .context("collector daemon claim missing")?;
                    let mut bytes = b"abird-owned-native-gc-verification-v1\0".to_vec();
                    bytes.extend(serde_json::to_vec(&(
                        &handle,
                        native,
                        status.request.digest()?,
                        policy.digest()?,
                    ))?);
                    journal.record_verified(
                        &handle,
                        super::Outcome::MaintenanceSucceeded {
                            verification_digest: crate::sha256::digest_bytes(&bytes),
                        },
                        daemon::now()?,
                    )?;
                }
                return Ok(());
            }
            std::thread::park_timeout(Duration::from_millis(100));
        }
    })
    // Any error leaves possible surviving work accounted by the durable owner;
    // child/guard drop and CLI exit do not settle, release or permit replay.
}

#[cfg(test)]
mod tests;
