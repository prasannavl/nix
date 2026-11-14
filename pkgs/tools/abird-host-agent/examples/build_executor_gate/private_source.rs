//! Disposable inode tests and native Git counterexamples, not source verification.
//! This synthetic actor also runs native queries as UID1000; it is deliberately
//! NOT the installed source role or evidence of source/native authority isolation.
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

use abird_host_agent::build_executor::journal::{JobStatus, Journal};
use abird_host_agent::build_executor::launch_gate::Gate;
use abird_host_agent::build_executor::private_sources::{SourceSlot, data_root};
use abird_host_agent::build_executor::process::{Limits as CaptureLimits, Runner};
use abird_host_agent::build_executor::protocol::Snapshot;
use abird_host_agent::build_executor::request::{BuildRequest, MAX_REQUEST_BYTES, Source};
use abird_host_agent::build_executor::{Outcome, Ownership, StopReason, private_tree};
use anyhow::{Context, Result, ensure};

// Fixed synthetic bytes/identity, declared before journal submission or producers.
// This is not an expected-source calculator for arbitrary repositories.
pub fn intent() -> Source {
    Source {
        revision: "457936b47da4479bafc4e194bc64084bca8b6da7".into(),
        base_revision: "457936b47da4479bafc4e194bc64084bca8b6da7".into(),
        tree_digest: None,
        patch_digest: Some(
            "8198d1252e279f62112ef7bf8e633cdc6a17753711c497b4fb275b0d6e6bbd23".into(),
        ),
    }
}

fn limits() -> private_tree::Limits {
    private_tree::Limits {
        entries: 128,
        bytes: 256 * 1024,
        depth: 16,
    }
}

pub fn client(
    state: &Path,
    owner: &Ownership,
    nix: &Path,
    journal: &Journal,
    gate: &Gate,
    now: u64,
) -> Result<()> {
    let received = Instant::now();
    let JobStatus::Live {
        request,
        reserved_at: Some(reserved),
        ..
    } = journal.status("operator", &owner.attempt_id)?
    else {
        anyhow::bail!("source fixture not reserved");
    };
    let request = request.context("fixture source is not resolved")?;
    let expires = reserved
        .checked_add(request.deadlines.runtime_seconds)
        .context("source fixture deadline overflow")?;
    let remaining = expires
        .checked_sub(now)
        .context("source fixture deadline expired")?;
    ensure!(remaining > 0, "source fixture deadline expired");
    let deadline = received
        .checked_add(Duration::from_secs(remaining))
        .context("source fixture deadline overflow")?;
    ensure!(
        request.id.nonce == "private-copy" && request.source == intent(),
        "source fixture intent differs from journal"
    );
    let home = std::path::PathBuf::from(std::env::var("OB_GATE_HOME")?);
    let data = data_root(Some(&home.join(".local/share")), None)?;
    let slot = SourceSlot::allocate(journal, gate, owner.clone(), 1000, 1000, limits(), now)?;
    drop(slot.directory(journal, now)?);
    let parent = data.join(&owner.attempt_id);
    let source = parent.join("producer");
    let target = parent.join("copy");
    let reader_home = parent.join("reader-home");
    let git = std::env::var("OB_PRIVATE_GIT")?;
    let manager = std::env::var("OB_NATIVE_PREPARATION")?;
    // Diagnostic locator only; the journal allocation is the durable authority.
    let mut info = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(state.join("private-copy-fixture.json"))?;
    fs::set_permissions(
        state.join("private-copy-fixture.json"),
        fs::Permissions::from_mode(0o600),
    )?;
    info.write_all(&serde_json::to_vec(
        &serde_json::json!({"owner": owner, "source": source, "copy": target}),
    )?)?;
    info.sync_all()?;
    let info_meta = info.metadata()?;
    let forbidden = (info_meta.dev(), info_meta.ino());
    drop(info);
    File::open(state)?.sync_all()?;
    fs::create_dir(&reader_home)?;
    std::os::unix::fs::chown(&reader_home, Some(1000), Some(1000))?;
    fs::set_permissions(&reader_home, fs::Permissions::from_mode(0o700))?;
    fs::create_dir(&source)?;
    std::os::unix::fs::chown(&source, Some(1000), Some(1000))?;
    fs::set_permissions(&source, fs::Permissions::from_mode(0o700))?;
    fs::create_dir(&target)?;
    fs::set_permissions(&target, fs::Permissions::from_mode(0o700))?;
    let (mut control, mut producer) = UnixStream::pair()?;
    // Destination descriptors are opened only after fork; none reaches producer.
    let pid = unsafe { libc::fork() };
    ensure!(pid >= 0, "fork source fixture");
    if pid == 0 {
        drop(control);
        let result = produce(
            &source,
            &target,
            &reader_home,
            Programs {
                git: Path::new(&git),
                nix,
                manager: Path::new(&manager),
                deadline,
                expires,
                request: &request,
            },
            &mut producer,
            forbidden,
        );
        if let Err(error) = &result {
            eprintln!("private source fixture: {error:#}");
        }
        unsafe {
            libc::_exit(if result.is_ok() { 0 } else { 1 });
        }
    }
    drop(producer);
    let mut signal = [0];
    bound_handshake(&control, deadline)?;
    control.read_exact(&mut signal)?;
    ensure!(signal == [1], "producer not ready");
    let summary = private_tree::copy(
        &File::open(&source)?,
        &File::open(&target)?,
        1000,
        1000,
        limits(),
    )?;
    ensure!(
        summary.entries > 4 && summary.symlinks == 0,
        "wrong copy footprint"
    );
    ensure!(
        fs::metadata(target.join("payload"))?.uid() == 0,
        "copy is not service-owned"
    );
    bound_handshake(&control, deadline)?;
    control.write_all(&[2])?;
    bound_handshake(&control, deadline)?;
    control.read_exact(&mut signal)?;
    ensure!(signal == [3], "producer checks failed");
    let mut status = 0;
    ensure!(
        unsafe { libc::waitpid(pid, &mut status, 0) } == pid
            && libc::WIFEXITED(status)
            && libc::WEXITSTATUS(status) == 0,
        "producer did not exit cleanly"
    );
    ensure!(
        fs::read(source.join("renamed"))? == b"tampered",
        "producer descriptor not exercised"
    );
    ensure!(
        fs::read(target.join("payload"))? == b"selected",
        "old writer mutated copy"
    );
    println!("PRIVATE_COPY_FRESH_INODES_AND_UIDS");
    Ok(())
}

// Native queries share the original reservation, not an unrelated10s IPC timer.
fn bound_handshake(socket: &UnixStream, deadline: Instant) -> Result<()> {
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .filter(|remaining| !remaining.is_zero())
        .context("source fixture handshake deadline expired")?;
    socket.set_read_timeout(Some(remaining))?;
    socket.set_write_timeout(Some(remaining))?;
    Ok(())
}

pub fn empty_client(journal: &Journal, gate: &Gate, owner: Ownership, now: u64) -> Result<()> {
    let data = data_root(
        Some(&std::path::PathBuf::from(std::env::var("XDG_DATA_HOME")?)),
        None,
    )?;
    let ancestor = data.parent().context("missing fixture ancestor")?;
    // The hardened worker cannot change its ancestors (ProtectSystem=strict);
    // the qualification script flips this one around the bounded waits.
    let owned_by = |uid: u32| -> Result<()> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while fs::metadata(ancestor)?.uid() != uid {
            ensure!(
                std::time::Instant::now() < deadline,
                "fixture ancestor owner not changed"
            );
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        Ok(())
    };
    println!("PRIVATE_SOURCE_AWAITING_FOREIGN_ANCESTOR");
    owned_by(1000)?;
    let rejected = SourceSlot::allocate(journal, gate, owner.clone(), 1000, 1000, limits(), now);
    let error = rejected.err().context("foreign ancestor accepted")?;
    ensure!(
        error.to_string().contains("foreign ancestor"),
        "unexpected ancestry rejection: {error}"
    );
    println!("PRIVATE_SOURCE_FOREIGN_ANCESTOR_REJECTED");
    owned_by(0)?;
    // Successful retry also proves the rejected call neither registered nor mkdir'd.
    let slot = SourceSlot::allocate(journal, gate, owner.clone(), 1000, 1000, limits(), now)?;
    drop(slot.directory(journal, now)?);
    println!("PRIVATE_SOURCE_EMPTY_BOUND");
    Ok(())
}

pub fn inspect(action: &str, state: &Path, journal: &Journal, now: u64) -> Result<()> {
    let empty = action == "supervised-source-retire-empty";
    let key = fs::read_to_string(state.join("request-id"))?;
    let status = journal.status("operator", &key)?;
    let JobStatus::Live {
        request,
        prepared,
        attempt,
        settled_at,
        ..
    } = &status
    else {
        anyhow::bail!("fixture record retired");
    };
    let request = request.as_ref().context("fixture source is not resolved")?;
    ensure!(
        request.id.nonce
            == if empty {
                "source-slot-empty"
            } else {
                "private-copy"
            }
            && prepared.is_none()
            && settled_at.is_some()
            && matches!(
                attempt.outcome(),
                Some(Outcome::Failed {
                    reason: StopReason::VerificationFailed
                })
            ),
        "wrong/unsettled source fixture"
    );
    let Snapshot::Live {
        ownership: Some(owner),
        ..
    } = Snapshot::from(status)
    else {
        anyhow::bail!("fixture ownership missing");
    };
    // Journal-bound fixed fixture, no realised artifacts or consumer handoff claim.
    // Diagnostic locators cannot select an owner or grant release.
    journal.released(&owner.attempt_id, &"e".repeat(64), now)?;
    if empty {
        SourceSlot::retire_empty(journal, &owner, now)?;
        ensure!(
            SourceSlot::open(journal, owner).is_err(),
            "retired allocation reopened"
        );
        println!("PRIVATE_SOURCE_EMPTY_RETIRED");
    } else {
        let error = SourceSlot::retire_empty(journal, &owner, now)
            .err()
            .context("nonempty source was removed")?;
        ensure!(
            error
                .to_string()
                .contains("source contents require qualified cleanup"),
            "unexpected source retirement rejection: {error}"
        );
        SourceSlot::open(journal, owner)?;
        println!("PRIVATE_SOURCE_NONEMPTY_RETAINED");
    }
    Ok(())
}

fn run(
    runner: &mut Runner,
    program: &Path,
    args: &[&str],
    cwd: &Path,
    home: &Path,
) -> Result<String> {
    run_input(runner, program, args, cwd, home, &[])
}

fn run_input(
    runner: &mut Runner,
    program: &Path,
    args: &[&str],
    cwd: &Path,
    home: &Path,
    input: &[u8],
) -> Result<String> {
    let mut command = Command::new(program);
    command
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("LC_ALL", "C")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_DATE", "2020-09-13T12:26:40Z")
        .env("GIT_COMMITTER_DATE", "2020-09-13T12:26:40Z")
        .env("NIX_REMOTE", "daemon");
    let output = runner.run(&mut command, input)?;
    ensure!(
        output.status.success(),
        "synthetic source command {args:?}: {}: {}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(String::from_utf8(output.stdout)?)
}

struct Programs<'a> {
    git: &'a Path,
    nix: &'a Path,
    manager: &'a Path,
    deadline: Instant,
    expires: u64,
    request: &'a BuildRequest,
}

fn produce(
    source: &Path,
    target: &Path,
    home: &Path,
    programs: Programs<'_>,
    control: &mut UnixStream,
    forbidden: (u64, u64),
) -> Result<()> {
    ensure!(
        unsafe { libc::setgroups(0, std::ptr::null()) } == 0,
        "clear groups"
    );
    ensure!(
        unsafe { libc::setgid(1000) } == 0 && unsafe { libc::setuid(1000) } == 0,
        "drop source privileges"
    );
    for entry in fs::read_dir("/proc/self/fd")? {
        let fd: i32 = entry?
            .file_name()
            .to_str()
            .context("fixture fd name")?
            .parse()?;
        let mut meta = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe { libc::fstat(fd, meta.as_mut_ptr()) } == 0 {
            let meta = unsafe { meta.assume_init() };
            ensure!(
                (meta.st_dev, meta.st_ino) != forbidden,
                "diagnostic descriptor leaked to producer"
            );
        } else {
            ensure!(
                std::io::Error::last_os_error().raw_os_error() == Some(libc::EBADF),
                "inspect fixture descriptor"
            );
        }
    }
    println!("PRIVATE_SOURCE_DIAGNOSTIC_FD_CLOSED");
    let Programs {
        git,
        nix,
        manager,
        deadline,
        expires,
        request,
    } = programs;
    let mut runner = Runner::new(
        1000,
        CaptureLimits {
            stdin: MAX_REQUEST_BYTES,
            stdout: 128 * 1024,
            stderr: 32 * 1024,
        },
        deadline,
    )?;
    fs::write(source.join("payload"), b"baseline")?;
    fs::write(source.join("binary"), b"baseline\0binary\xff")?;
    fs::write(source.join("text"), b"baseline\n")?;
    fs::write(
        source.join("flake.nix"),
        r#"{ outputs = { self }: { metadata = { revision = self.rev or null; dirty = self.dirtyRev or null; count = self.revCount or null; modified = self.lastModified; out = self.outPath; payload = builtins.readFile ./payload; text = builtins.readFile ./text; }; }; }"#,
    )?;
    run(
        &mut runner,
        git,
        &["init", "--template=", "--initial-branch=main", "."],
        source,
        home,
    )?;
    run(
        &mut runner,
        git,
        &["add", "payload", "flake.nix", "binary", "text"],
        source,
        home,
    )?;
    run(
        &mut runner,
        git,
        &[
            "-c",
            "user.name=fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "-m",
            "synthetic source fixture",
        ],
        source,
        home,
    )?;
    let revision = run(&mut runner, git, &["rev-parse", "HEAD"], source, home)?;
    ensure!(
        revision.trim() == request.source.revision,
        "synthetic producer revision differs from intent"
    );
    fs::write(source.join("payload"), b"selected")?;
    fs::write(source.join("binary"), b"selected\0binary\xff")?;
    fs::write(source.join("text"), b"selected\n")?;
    run(
        &mut runner,
        git,
        &["add", "payload", "binary", "text"],
        source,
        home,
    )?;
    run(
        &mut runner,
        git,
        &["config", "--local", "core.autocrlf", "true"],
        source,
        home,
    )?;
    let libraries = abird_host_agent::build_executor::daemon::Policy::load(Path::new(
        "/etc/abird-owned-build/daemon.json",
    ))?;
    let native = run_input(
        &mut runner,
        manager,
        &[
            "--repository-fixture",
            git.to_str().context("fixture Git path")?,
            nix.to_str().context("fixture Nix path")?,
            source.to_str().context("fixture source path")?,
            home.to_str().context("fixture HOME path")?,
            &expires.to_string(),
            &std::env::var("OB_NATIVE_MANAGER")?,
            libraries
                .evaluation_library
                .to_str()
                .context("fixture native library path")?,
        ],
        source,
        home,
        &serde_json::to_vec(request)?,
    )?;
    for marker in [
        "NATIVE_BASE_TREE_OBJECTS_OBSERVED",
        "NATIVE_BASE_INDEX_MATCHES_OBSERVED_TREE",
        "NATIVE_FILTERED_BASE_BYTES_OBSERVED",
        "NATIVE_SOURCE_RECIPE_MATCHES_JOURNAL_INTENT",
        "NATIVE_SOURCE_RECIPE_REJECTS_WRONG_ARTIFACT",
        "NATIVE_SOURCE_ADAPTER_BINARY_PATCH",
        "NATIVE_LINKED_WORKTREE_NOT_SEALED",
        "NATIVE_CHECKOUT_CONFIG_AND_METADATA_PRESERVED",
        "NATIVE_STANDALONE_SOURCE_PARENT_INDEPENDENT",
        "NATIVE_INDEX_FLAGS_HIDE_EVALUATION_BYTES",
        "UPSTREAM_DOT_ROOT_SOURCE_INFO_IS_CALLER_OUTPUT_NOT_PROVENANCE",
        "UPSTREAM_JSON_OUTPATH_ATTRSET_COERCION",
        "UPSTREAM_NATIVE_ADAPTER_ACCESSOR_BINDING_IGNORES_OUTPUT_SOURCE_INFO",
        "UPSTREAM_NATIVE_ADAPTER_JSON_PATH_PARITY",
        "UPSTREAM_OUTPUT_QUERY_NATIVE_PREFIX_ERROR_AND_RAW_PARITY",
        "NATIVE_OUTPUT_ABSENCE_NOT_EVALUATION_FAILURE",
    ] {
        ensure!(
            native.lines().any(|line| line == marker),
            "native source adapter fixture failed"
        );
        println!("{marker}");
    }
    run(
        &mut runner,
        git,
        &["config", "--local", "--unset-all", "core.autocrlf"],
        source,
        home,
    )?;
    let mut writer = OpenOptions::new()
        .write(true)
        .open(source.join("payload"))?;
    ensure!(
        File::open(target).is_err(),
        "private destination visible before copy"
    );
    bound_handshake(control, deadline)?;
    control.write_all(&[1])?;
    let mut signal = [0];
    bound_handshake(control, deadline)?;
    control.read_exact(&mut signal)?;
    ensure!(signal == [2], "copy not ready");
    fs::rename(source.join("payload"), source.join("renamed"))?;
    writer.seek(SeekFrom::Start(0))?;
    writer.write_all(b"tampered")?;
    writer.sync_all()?;
    ensure!(
        fs::read(target.join("payload"))? == b"selected",
        "copied inode aliases producer"
    );
    ensure!(
        fs::read(target.join(".git/HEAD"))? == b"ref: refs/heads/main\n",
        "private metadata missing"
    );
    run(
        &mut runner,
        git,
        &[
            "config",
            "--global",
            "--add",
            "safe.directory",
            target.to_str().context("fixture path UTF-8")?,
        ],
        source,
        home,
    )?;
    let reference = format!("git+file://{}", target.display());
    let observed: serde_json::Value = serde_json::from_str(&run(
        &mut runner,
        nix,
        &[
            "--store",
            "daemon",
            "eval",
            "--json",
            "--no-write-lock-file",
            "--no-update-lock-file",
            &format!("{reference}#metadata"),
        ],
        target,
        home,
    )?)?;
    ensure!(
        observed["revision"].is_null()
            && observed["dirty"] == format!("{}-dirty", revision.trim())
            && observed["modified"] == 1600000000u64
            && observed["payload"] == "selected",
        "private Git metadata changed: {observed}"
    );
    let metadata: serde_json::Value = serde_json::from_str(&run(
        &mut runner,
        nix,
        &[
            "--store",
            "daemon",
            "flake",
            "metadata",
            "--json",
            "--no-write-lock-file",
            "--no-update-lock-file",
            &reference,
        ],
        target,
        home,
    )?)?;
    let retained = Path::new(
        metadata["path"]
            .as_str()
            .context("missing retained source")?,
    );
    ensure!(
        retained.starts_with("/nix/store") && !retained.join(".git").exists(),
        "Git metadata entered public store"
    );
    ensure!(
        fs::read(retained.join("payload"))? == b"selected",
        "wrong retained payload"
    );
    println!("PRIVATE_GIT_METADATA_PRESERVED_NO_GIT_IN_STORE");
    println!("PRIVATE_SOURCE_HELPERS_BOUNDED");
    let write = OpenOptions::new()
        .write(true)
        .open(target.join("payload"))
        .err()
        .context("copy writable by reader")?;
    ensure!(
        write.kind() == std::io::ErrorKind::PermissionDenied,
        "wrong write rejection"
    );
    ensure!(
        fs::rename(target.join("payload"), target.join("replaced")).is_err(),
        "reader renamed copied entry"
    );
    bound_handshake(control, deadline)?;
    control.write_all(&[3])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handshake_keeps_the_original_reservation_deadline() {
        let (socket, _peer) = UnixStream::pair().unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        bound_handshake(&socket, deadline).unwrap();
        assert!(socket.read_timeout().unwrap().unwrap() <= Duration::from_secs(30));
        assert!(socket.write_timeout().unwrap().unwrap() <= Duration::from_secs(30));
        assert!(bound_handshake(&socket, Instant::now() - Duration::from_secs(1)).is_err());
    }
}
