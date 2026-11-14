//! Explicit root provisioning only. No boot-time initialization, adoption,
//! repair, ingress stop, store creation or recovery grant.

use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, ensure};

use super::request::state_root;
use super::{daemon, journal::Journal, launch_gate::Gate, role, units::Units, workload};

pub(super) fn validate(root: &Path, capacity: &str) -> Result<()> {
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(root.join("bootstrap.complete"))?;
    let meta = file.metadata()?;
    ensure!(
        meta.is_file()
            && meta.uid() == 0
            && meta.mode() & 0o7777 == 0o600
            && meta.nlink() == 1
            && meta.len() == 64,
        "bootstrap completion unavailable"
    );
    let mut bytes = [0u8; 64];
    file.read_exact(&mut bytes)?;
    ensure!(bytes == capacity.as_bytes(), "bootstrap binding differs");
    Ok(())
}

pub fn run_service(path: &Path) -> Result<()> {
    workload::require_bootstrap_placement()?;
    let role = role::Policy::load(path)?;
    role.control_limits.ready()?;
    let (native, control) = daemon::declarations(&role.daemon_policy, &role.control)?;
    ensure!(
        native.containment_digest == role.digest()?,
        "bootstrap role binding differs"
    );
    let mut units = Units::new(role.systemctl.clone(), Duration::from_secs(2))?;
    units.require_definitions(&role.definitions)?;
    role.budget_members(&mut units)?;
    ensure!(
        units.socket()?.stopped() && units.daemon()?.stopped() && workload::bootstrap_empty()?,
        "bootstrap requires already stopped ingress and an empty native execution domain"
    );
    let root = state_root(
        std::env::var_os("XDG_STATE_HOME").as_deref().map(Path::new),
        std::env::var_os("HOME").as_deref().map(Path::new),
    )?;
    let parent = root.parent().context("authority parent missing")?;
    daemon::trusted_path(parent)?;
    ensure!(
        std::fs::canonicalize(parent)? == parent && role.limits.ready(parent)?,
        "bootstrap namespace/headroom unavailable"
    );
    match std::fs::symlink_metadata(&root) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        _ => anyhow::bail!("bootstrap cannot adopt or repair existing authority"),
    }
    // Journal creation is exclusive and durably starts Quarantined. Any partial
    // initialization stays unusable; a second bootstrap cannot fill its gaps.
    let capacity = control.policy.capacity_digest.clone();
    Journal::initialize(
        &root,
        control.identity.clone(),
        control.policy,
        daemon::now()?,
    )?;
    super::store_binding::initialize(&root, &control.identity)?;
    let gate = Gate::initialize(&root.join("launch"), control.identity)?;
    let fence = gate.try_fence()?.context("bootstrap launch fence busy")?;
    ensure!(
        units.socket()?.stopped()
            && units.daemon()?.stopped()
            && workload::FencedWorkload::new(&fence)?.population()? == workload::Population::Empty,
        "bootstrap observation changed"
    );
    // Last publication, after every prerequisite. Open never fills creation gaps.
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut complete = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(root.join("bootstrap.complete"))?;
    complete.write_all(capacity.as_bytes())?;
    complete.sync_all()?;
    std::fs::File::open(&root)?.sync_all()?;
    // Supervisor separately proves recovery, under its controller lock.
    Ok(())
}
