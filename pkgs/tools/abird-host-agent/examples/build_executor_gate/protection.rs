//! Native-root qualification only: fixed disposable inputs, not source verification
//! or a production GC admission/maintenance adapter.
use super::*;
use abird_host_agent::build_executor::journal::Journal;
use abird_host_agent::build_executor::protection::NativeRoots;
use std::path::Path;

fn nix(program: &Path, arguments: &[&str]) -> Result<String> {
    let output = Command::new(program)
        .env_clear()
        .env("HOME", "/home/builder")
        .uid(1000)
        .gid(1000)
        .args(["--store", "daemon"])
        .args(arguments)
        .output()?;
    ensure!(
        output.status.success(),
        "fixture Nix failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(String::from_utf8(output.stdout)?.trim().to_owned())
}

pub fn client(
    root: &Path,
    journal: &Journal,
    gate: &Gate,
    owner: Ownership,
    executable: &Path,
) -> Result<()> {
    ensure!(
        unsafe { libc::setgroups(0, std::ptr::null()) } == 0,
        "setgroups"
    );
    let bin = executable.parent().context("Nix bin directory missing")?;
    let store = bin.join("nix-store");
    // Pause before any input import/root publication. The VM checks the durable
    // veto after controller death; this is not global maintenance qualification.
    println!("BEFORE_ROOT_PUBLICATION");
    std::io::stdout().flush()?;
    File::open("/run/qualification-before-roots")?.read_exact(&mut [0])?;
    let file = "/run/qualification-root-source";
    let mut input = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(file)?;
    writeln!(input, "retained:{}", owner.attempt_id)?;
    // Fixed synthetic input: root writes; the unprivileged native client reads.
    std::os::unix::fs::chown(file, None, Some(1000))?;
    input.set_permissions(fs::Permissions::from_mode(0o640))?;
    input.sync_all()?;
    drop(input);
    let source = nix(&store, &["--add", file])?;
    fs::write(file, format!("unprotected:{}\n", owner.attempt_id))?;
    let unprotected = nix(&store, &["--add", file])?;
    let derivation = nix(&bin.join("nix-instantiate"), &["/etc/protected-build.nix"])?;
    let unbuilt = nix(&store, &["--query", "--outputs", &derivation])?;
    ensure!(
        !Path::new(&unbuilt).exists(),
        "rooting must not realise the derivation"
    );
    let roots = NativeRoots::initialize(journal, gate, owner.clone())?;
    let receipt = roots.retain(journal, gate, &[source, derivation])?;
    fs::write(root.join("root-owner.json"), serde_json::to_vec(&owner)?)?;
    fs::write(
        root.join("root-info.json"),
        serde_json::to_vec(&serde_json::json!({
            "roots": receipt, "unprotected": unprotected, "unbuilt": unbuilt
        }))?,
    )?;
    println!("ROOTS_READY");
    std::io::stdout().flush()?;
    // Test kills this process; roots and the journal retention veto must outlive it.
    File::open("/run/qualification-roots-hold")?.read_exact(&mut [0])?;
    bail!("unexpected fixture FIFO input")
}

pub fn inspect(action: &str, root: &Path, journal: &Journal, now: u64) -> Result<()> {
    let owner: Ownership = serde_json::from_slice(&fs::read(root.join("root-owner.json"))?)?;
    if action == "supervised-roots-retire" {
        NativeRoots::retire(journal, &owner)?;
        return Ok(());
    }
    let roots = NativeRoots::open(journal, owner)?;
    if action == "supervised-roots-release" {
        roots.release(journal, &"e".repeat(64), now)?;
    } else if action == "supervised-roots-check" {
        println!("{}", serde_json::to_string(&roots.verify(journal)?)?);
    } else {
        bail!("unknown root fixture action");
    }
    println!("retention_clear={}", journal.retention_clear()?);
    Ok(())
}
