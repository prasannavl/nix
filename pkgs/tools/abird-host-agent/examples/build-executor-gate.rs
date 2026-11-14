//! Disposable VM qualification driver, not installed by the production package.
//! No public service/forced-command endpoint. Synthetic identities and budgets.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::num::NonZeroU64;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

use abird_host_agent::build_executor::Ownership;
use abird_host_agent::build_executor::launch_gate::{Gate, Permission, Permit};
use abird_host_agent::build_executor::request::{StorageIdentity, state_root};
use abird_host_agent::build_executor::workload::{self, FencedWorkload, Population};
use abird_host_agent::sha256::digest_bytes;
use anyhow::{Context, Result, bail, ensure};

#[path = "build_executor_gate/private_source.rs"]
mod private_source;
#[path = "build_executor_gate/protection.rs"]
mod protection;
#[path = "build_executor_gate/supervised.rs"]
mod supervised;

fn identity() -> StorageIdentity {
    StorageIdentity {
        authority_id: "qualification".into(),
        builder_id: "builder".into(),
        store_id: "shared-store".into(),
    }
}
fn permit(gate: &Gate, epoch: u64) -> Permit {
    Permit {
        version: 1,
        identity: identity(),
        permission: match NonZeroU64::new(epoch) {
            None => Permission::Recovery {
                epoch,
                boot_id: gate.boot_id().into(),
            },
            Some(pool_epoch) => Permission::Execution {
                ownership: Ownership {
                    executor_version: 1,
                    builder_id: "builder".into(),
                    store_id: "shared-store".into(),
                    attempt_id: digest_bytes(format!("qualification-{epoch}").as_bytes()),
                    pool_epoch,
                    boot_id: gate.boot_id().into(),
                },
            },
        },
    }
}
fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let action = args.next().context("action required")?;
    if action == "control-request" {
        let socket = args.next().context("socket required")?;
        let mut bytes = Vec::new();
        std::io::stdin()
            .take(abird_host_agent::build_executor::protocol::MAX_FRAME_BYTES as u64 + 1)
            .read_to_end(&mut bytes)?;
        let stream = std::os::unix::net::UnixStream::connect(socket)?;
        let response = abird_host_agent::build_executor::control::exchange(
            stream,
            0,
            &bytes,
            Duration::from_secs(5),
        );
        println!("{}", String::from_utf8(response.encode()?)?);
        return Ok(());
    }
    ensure!(
        unsafe { libc::geteuid() } == 0,
        "qualification driver requires root"
    );
    let home = PathBuf::from(std::env::var_os("OB_GATE_HOME").context("OB_GATE_HOME required")?);
    let root = state_root(None, Some(&home))?;
    if action.starts_with("supervised-") {
        return supervised::run(&action, &root, args);
    }
    if action == "init" {
        fs::create_dir_all(&root)?;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
        Gate::initialize(&root.join("launch"), identity())?;
        return Ok(());
    }
    let gate = Gate::open(&root.join("launch"), identity())?;
    if action == "grant" || action == "fence" {
        let deadline = Instant::now() + Duration::from_secs(10);
        let fence = loop {
            if let Some(fence) = gate.try_fence()? {
                break fence;
            }
            ensure!(Instant::now() < deadline, "fence remained pending");
            std::thread::park_timeout(Duration::from_millis(5));
        };
        if action == "fence" {
            // The driver keeps this descriptor outside the killable subtree.
            println!("FENCED");
            std::io::stdout().flush()?;
            File::open(root.join("release-fence"))?.read_exact(&mut [0])?;
            let workload = FencedWorkload::new(&fence)?;
            workload.kill()?;
            let deadline = Instant::now() + Duration::from_secs(10);
            loop {
                if matches!(workload.population(), Ok(Population::Empty)) {
                    break;
                }
                ensure!(Instant::now() < deadline, "workload settlement unconfirmed");
                std::thread::park_timeout(Duration::from_millis(5));
            }
            println!("SETTLED");
            std::io::stdout().flush()?;
            File::open(root.join("release-fence"))?.read_exact(&mut [0])?;
            drop(fence);
        } else {
            let epoch: u64 = args.next().context("epoch required")?.parse()?;
            let mut file = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(root.join("epoch"))?;
            write!(file, "{epoch}")?;
            file.sync_all()?;
            fence.publish(&permit(&gate, epoch))?;
        }
        return Ok(());
    }
    let epoch: u64 = if action == "daemon" || action == "probe" {
        fs::read_to_string(root.join("epoch"))?.parse()?
    } else {
        args.next().context("client epoch required")?.parse()?
    };
    if action == "pending" {
        fs::write(root.join("pending-entered"), b"waiting")?;
        File::open(root.join("release-start"))?.read_exact(&mut [0])?;
    }
    workload::require_wrapper_placement()?;
    let expected = permit(&gate, epoch);
    let _launch = gate
        .authorize(&expected)?
        .context("launch pending behind fence")?;
    let executable = args.next().context("pinned Nix executable required")?;
    let mut command = Command::new(executable);
    match action.as_str() {
        "daemon" => {
            command.arg("--daemon");
        }
        "client" | "pending" | "probe" => {
            ensure!(
                action == "probe" || epoch != 0,
                "recovery permission cannot launch a build"
            );
            ensure!(
                action != "probe" || epoch == 0,
                "probe requires recovery permission"
            );
            let uid: u32 = args.next().context("client uid required")?.parse()?;
            let gid: u32 = args.next().context("client gid required")?.parse()?;
            ensure!(uid != 0 && gid != 0, "client must be unprivileged");
            // Ordinary Nix clients only; root remains solely the launch guard.
            ensure!(
                unsafe { libc::setgroups(0, std::ptr::null()) } == 0,
                "setgroups failed"
            );
            ensure!(unsafe { libc::setgid(gid) } == 0, "setgid failed");
            ensure!(unsafe { libc::setuid(uid) } == 0, "setuid failed");
            command.env_clear().env("HOME", "/home/builder");
            if action == "probe" {
                command.args(["store", "ping", "--store", "daemon"]);
            } else {
                command
                    .args([
                        "build",
                        "--store",
                        "daemon",
                        "--no-link",
                        "--print-out-paths",
                        "--print-build-logs",
                        "--file",
                    ])
                    .arg(args.next().context("fixture expression required")?);
            }
        }
        _ => bail!("unknown qualification action"),
    }
    ensure!(args.next().is_none(), "unexpected arguments");
    // PID/socket-activation descriptors preserved; the interlock is CLOEXEC.
    Err(command.exec().into())
}
