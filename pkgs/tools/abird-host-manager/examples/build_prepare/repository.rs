//! Synthetic admitted source fixture; no verified preparation or sealed Git claim.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use abird_host_agent::build_executor::process::{Captured, Limits, Runner};
use abird_host_manager::fleet::build::query::FlakeQuery;
use abird_host_manager::fleet::preparation::repository::RepositoryCommands;

#[path = "query.rs"]
mod query;
use abird_host_manager::fleet::preparation::source::SourceRecipe;
use abird_host_manager::fleet::repository::{ObjectLimits, TreeKind};
use anyhow::{Context, Result, ensure};
use serde_json::Value;

pub fn run(mut args: impl Iterator<Item = String>) -> Result<()> {
    let received = Instant::now();
    let git = PathBuf::from(args.next().context("fixture Git required")?);
    let nix = PathBuf::from(args.next().context("fixture Nix required")?);
    let source = PathBuf::from(args.next().context("fixture source required")?);
    let home = PathBuf::from(args.next().context("fixture HOME required")?);
    let expires: u64 = args
        .next()
        .context("original fixture expiry required")?
        .parse()?;
    let manager = PathBuf::from(args.next().context("fixture manager required")?);
    let library = PathBuf::from(args.next().context("fixture native API required")?);
    ensure!(
        args.next().is_none(),
        "unexpected repository fixture argument"
    );
    let remaining = expires
        .checked_sub(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs())
        .context("repository fixture expired")?;
    ensure!(remaining > 0, "repository fixture expired");
    let deadline = received
        .checked_add(Duration::from_secs(remaining))
        .context("repository fixture deadline overflow")?;
    let mut runner = Runner::new(
        1000,
        Limits {
            stdin: 256 * 1024,
            stdout: 128 * 1024,
            stderr: 32 * 1024,
        },
        deadline,
    )?;
    // Input comes from the parent's journal lookup, not a digest of producer
    // output. Parent transport and supervisor retain the original deadline.
    let request = super::read_request()?;
    ensure!(
        request.id.nonce == "private-copy",
        "wrong source fixture request"
    );
    let workspace = source.join("adapter-worktree");
    let clean = source.join("adapter-clean");
    // All producer data stays in this registered source slot. No nonempty
    // post-settlement deletion or source receipt is implemented by this fixture.
    let replica = home.join("standalone-dirty");
    let clean_replica = home.join("standalone-clean");
    let commands = RepositoryCommands::new(
        git.clone(),
        source.clone(),
        vec![
            workspace.clone(),
            clean.clone(),
            replica.clone(),
            clean_replica.clone(),
        ],
        vec![
            ("HOME".into(), home.as_os_str().to_owned()),
            (
                "PATH".into(),
                git.parent()
                    .context("Git bin directory required")?
                    .as_os_str()
                    .to_owned(),
            ),
            ("GIT_CONFIG_NOSYSTEM".into(), "1".into()),
            ("LC_ALL".into(), "C".into()),
        ],
    )?;
    let (base, settings) = commands.with_repository(&mut runner, |manager| {
        fs::write(source.join("payload"), b"unstaged")?;
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(source.join("ignored-untracked"))?
            .write_all(b"ignored")?;
        let selected = manager
            .capture_staged_patch(&source)?
            .context("missing staged fixture patch")?;
        ensure!(
            selected.ignored.unstaged_tracked && selected.ignored.untracked,
            "native ignored-change reporting lost"
        );
        ensure!(
            selected
                .patch
                .bytes
                .windows(b"GIT binary patch".len())
                .any(|s| s == b"GIT binary patch"),
            "missing binary patch"
        );
        let mut changed = selected.patch.clone();
        changed.bytes.push(b' ');
        ensure!(
            SourceRecipe::bind(&request.source, Some(changed)).is_err()
                && SourceRecipe::bind(&request.source, None).is_err()
                && !workspace.exists(),
            "wrong source artifact accepted or materialized"
        );
        println!("NATIVE_SOURCE_RECIPE_REJECTS_WRONG_ARTIFACT");
        let recipe = SourceRecipe::bind(&request.source, Some(selected.patch.clone()))?;
        let base = &selected.patch.base;
        // Unpatched base objects only; no finished source/history receipt.
        let commit = manager.commit_object(&source, base)?;
        let observed = manager.observe_tree(
            &source,
            &commit.tree_id()?,
            ObjectLimits {
                entries: 128,
                bytes: 256 * 1024,
                depth: 16,
                path_bytes: 16 * 1024,
            },
        )?;
        ensure!(
            observed.entries().keys().map(Vec::as_slice).eq([
                "binary",
                "flake.nix",
                "payload",
                "text"
            ]
            .map(str::as_bytes))
                && observed
                    .entries()
                    .values()
                    .all(|entry| entry.kind() == TreeKind::File),
            "synthetic base object inventory differs"
        );
        println!("NATIVE_BASE_TREE_OBJECTS_OBSERVED");
        let worktree = recipe.native_worktree(manager, &source, &workspace, &observed)?;
        println!("NATIVE_BASE_INDEX_MATCHES_OBSERVED_TREE");
        ensure!(worktree.commit == *base, "native exact commit lost");
        println!("NATIVE_SOURCE_RECIPE_MATCHES_JOURNAL_INTENT");
        let settings = manager.checkout_settings(&workspace)?;
        manager.create_standalone_checkout(&source, &replica, base, &settings)?;
        manager.apply_staged_patch(&replica, &selected.patch)?;
        ensure!(
            manager.index_entries(&workspace)? == manager.index_entries(&replica)?,
            "native staged entries differ"
        );
        for path in [&workspace, &replica] {
            ensure!(
                fs::read(path.join("payload"))? == b"selected",
                "unstaged payload leaked"
            );
            ensure!(
                fs::read(path.join("binary"))? == b"selected\0binary\xff",
                "binary patch lost"
            );
            ensure!(
                fs::read(path.join("text"))? == b"selected\r\n",
                "native checkout conversion lost"
            );
            ensure!(
                !path.join("ignored-untracked").exists(),
                "untracked payload leaked"
            );
        }
        ensure!(
            fs::read_to_string(workspace.join(".git"))?.starts_with("gitdir: "),
            "expected native linked pointer"
        );
        manager.create_detached_worktree(&source, &clean, base.as_str())?;
        manager.create_standalone_checkout(&source, &clean_replica, base, &settings)?;
        for path in [&clean, &clean_replica] {
            let projected = manager.checkout_projection(path, &observed, b"text")?;
            ensure!(
                projected.bytes() == b"baseline\r\n"
                    && projected.bytes() == fs::read(path.join("text"))?,
                "synthetic filtered base bytes differ"
            );
        }
        println!("NATIVE_FILTERED_BASE_BYTES_OBSERVED");
        for path in [&replica, &clean_replica] {
            ensure!(
                path.join(".git").is_dir()
                    && !path.join(".git/commondir").exists()
                    && !path.join(".git/objects/info/alternates").exists(),
                "replica has external Git metadata"
            );
        }
        Ok((base.clone(), settings))
    })?;
    let native_dirty = metadata(&mut runner, &nix, &workspace, &home)?;
    let standalone_dirty = metadata(&mut runner, &nix, &replica, &home)?;
    ensure!(
        native_dirty == standalone_dirty
            && native_dirty.0["dirty"] == format!("{}-dirty", base.as_str()),
        "dirty metadata/NAR differs"
    );
    let native_clean = metadata(&mut runner, &nix, &clean, &home)?;
    ensure!(
        native_clean == metadata(&mut runner, &nix, &clean_replica, &home)?
            && native_clean.0["revision"] == base.as_str()
            && native_clean.0["count"] == 1,
        "clean metadata/NAR differs"
    );

    consumed_absence_and_error(&mut runner, &nix, &clean, &home)?;
    query::run(&mut runner, &git, &nix, &home, &manager, &library)?;

    // Same bytes/NAR, wrong native metadata if effective checkout config is lost.
    successful(
        &mut runner,
        &git,
        &["config", "--local", "core.autocrlf", "false"],
        &clean_replica,
        &home,
    )?;
    // A fresh projection cannot reuse the producer index's stat-cache shortcut.
    fs::File::open(clean_replica.join("text"))?.set_modified(UNIX_EPOCH)?;
    let wrong = metadata(&mut runner, &nix, &clean_replica, &home)?;
    ensure!(
        wrong.1 == native_clean.1 && wrong.0 != native_clean.0 && wrong.0["revision"].is_null(),
        "config-loss negative fixture ineffective"
    );
    commands.with_repository(&mut runner, |manager| {
        manager.apply_checkout_settings(&clean_replica, &settings)
    })?;
    ensure!(
        native_clean == metadata(&mut runner, &nix, &clean_replica, &home)?,
        "configuration restoration lost metadata"
    );
    println!("NATIVE_CHECKOUT_CONFIG_AND_METADATA_PRESERVED");

    for flag in ["assume-unchanged", "skip-worktree"] {
        successful(
            &mut runner,
            &git,
            &["update-index", &format!("--{flag}"), "--", "payload"],
            &clean_replica,
            &home,
        )?;
        fs::write(clean_replica.join("payload"), b"tampered-index")?;
        successful(
            &mut runner,
            &git,
            &["diff", "--quiet", "--no-ext-diff", "--"],
            &clean_replica,
            &home,
        )?;
        successful(
            &mut runner,
            &git,
            &["fsck", "--full", "--strict", "--no-reflogs"],
            &clean_replica,
            &home,
        )?;
        let rejected = commands
            .with_repository(&mut runner, |manager| manager.index_entries(&clean_replica))
            .err()
            .context("hidden index flags accepted")?;
        ensure!(
            rejected
                .to_string()
                .contains("unsupported native index entry flags"),
            "wrong index rejection"
        );
        // Even an independently matching store NAR does not bind this evaluator's
        // Git view. Known synthetic metadata deliberately observes the split.
        let observed = observe(&mut runner, &nix, &clean_replica, &home)?;
        ensure!(
            observed.metadata["revision"] == base.as_str()
                && observed.metadata["payload"] == "tampered-index"
                && observed.nar == native_clean.1
                && !observed.retained_matches,
            "index-flag divergence fixture ineffective"
        );
        fs::write(clean_replica.join("payload"), b"baseline")?;
        successful(
            &mut runner,
            &git,
            &["update-index", &format!("--no-{flag}"), "--", "payload"],
            &clean_replica,
            &home,
        )?;
    }
    commands.with_repository(&mut runner, |manager| manager.index_entries(&clean_replica))?;
    ensure!(
        metadata(&mut runner, &nix, &clean_replica, &home)? == native_clean,
        "index restoration lost native metadata"
    );
    println!("NATIVE_INDEX_FLAGS_HIDE_EVALUATION_BYTES");

    // Break only this synthetic producer's metadata ancestry; replicas keep
    // their own objects. This is not a general closure/confinement verifier.
    fs::rename(source.join(".git"), source.join(".git-moved"))?;
    ensure!(
        !output(&mut runner, &git, &["rev-parse", "HEAD"], &workspace, &home)?
            .status
            .success(),
        "linked metadata unexpectedly independent"
    );
    for path in [&replica, &clean_replica] {
        successful(
            &mut runner,
            &git,
            &["fsck", "--full", "--strict", "--no-reflogs"],
            path,
            &home,
        )?;
    }
    ensure!(
        metadata(&mut runner, &nix, &replica, &home)? == standalone_dirty,
        "replica depends on producer ancestry"
    );
    fs::rename(source.join(".git-moved"), source.join(".git"))?;
    println!("NATIVE_STANDALONE_SOURCE_PARENT_INDEPENDENT");
    commands.with_repository(&mut runner, |manager| {
        manager.remove_worktree(&source, &workspace)?;
        manager.remove_worktree(&source, &clean)?;
        ensure!(
            !workspace.exists() && !clean.exists(),
            "native worktree cleanup incomplete"
        );
        fs::remove_file(source.join("ignored-untracked"))?;
        fs::write(source.join("payload"), b"selected")?;
        Ok(())
    })?;
    println!("NATIVE_SOURCE_ADAPTER_BINARY_PATCH");
    println!("NATIVE_LINKED_WORKTREE_NOT_SEALED");
    Ok(())
}

fn observed(
    runner: &mut Runner,
    nix: &Path,
    root: &Path,
    home: &Path,
    query: FlakeQuery,
) -> Result<Captured> {
    let reference = format!("git+file://{}", root.display());
    let arguments = [
        "--store",
        "daemon",
        "--no-update-lock-file",
        "--option",
        "allow-import-from-derivation",
        "false",
        "--option",
        "eval-cache",
        "false",
    ]
    .map(str::to_owned);
    let command = query.selection_command(
        nix.to_str().context("fixture Nix encoding")?,
        &arguments,
        &reference,
        "x86_64-linux",
    )?;
    output(
        runner,
        nix,
        &command.args.iter().map(String::as_str).collect::<Vec<_>>(),
        root,
        home,
    )
}

fn consumed_absence_and_error(
    runner: &mut Runner,
    nix: &Path,
    root: &Path,
    home: &Path,
) -> Result<()> {
    // An absent catalog must not run attrNames on null.
    let absent = observed(runner, nix, root, home, FlakeQuery::catalog())?;
    ensure!(
        absent.status.success(),
        "upstream catalog absence query failed"
    );
    let absent: Value = serde_json::from_slice(&absent.stdout)?;
    ensure!(
        absent["version"] == 1
            && absent["system"] == "x86_64-linux"
            && absent["present"] == false
            && absent["attribute"].is_null()
            && absent["result"].is_null()
            && absent.get("sourceInfo").is_none(),
        "native output-absence envelope differs"
    );
    let failed = observed(
        runner,
        nix,
        root,
        home,
        FlakeQuery::value("metadata.payload.missing"),
    )?;
    ensure!(
        !failed.status.success() && failed.stdout.is_empty(),
        "native traversal failure became absence"
    );
    println!("NATIVE_OUTPUT_ABSENCE_NOT_EVALUATION_FAILURE");
    Ok(())
}

fn output(
    runner: &mut Runner,
    program: &Path,
    args: &[&str],
    cwd: &Path,
    home: &Path,
) -> Result<Captured> {
    let mut command = Command::new(program);
    command
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("LC_ALL", "C")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("NIX_REMOTE", "daemon");
    runner.run(&mut command, &[])
}
fn successful(
    runner: &mut Runner,
    program: &Path,
    args: &[&str],
    cwd: &Path,
    home: &Path,
) -> Result<Vec<u8>> {
    let output = output(runner, program, args, cwd, home)?;
    ensure!(
        output.status.success(),
        "synthetic projection command: {}",
        output.status
    );
    Ok(output.stdout)
}
fn metadata(runner: &mut Runner, nix: &Path, root: &Path, home: &Path) -> Result<(Value, String)> {
    let observed = observe(runner, nix, root, home)?;
    ensure!(
        observed.retained_matches,
        "fixture evaluation differs from retained source"
    );
    Ok((observed.metadata, observed.nar))
}

struct Observation {
    metadata: Value,
    nar: String,
    retained_matches: bool,
}

fn observe(runner: &mut Runner, nix: &Path, root: &Path, home: &Path) -> Result<Observation> {
    let reference = format!("git+file://{}", root.display());
    let reply = observed(runner, nix, root, home, FlakeQuery::value("metadata"))?;
    ensure!(reply.status.success(), "output fixture query failed");
    let observed: Value = serde_json::from_slice(&reply.stdout)?;
    ensure!(
        observed["version"] == 1
            && observed["system"] == "x86_64-linux"
            && observed["present"] == true
            && observed["attribute"] == "metadata"
            && observed.as_object().is_some_and(|object| object.len() == 5),
        "native output envelope differs"
    );
    let observed = observed
        .get("result")
        .context("output result missing")?
        .clone();
    // Deliberately independent metadata below remains a counterexample probe,
    // never a production anchor for the query above.
    let flake: Value = serde_json::from_slice(&successful(
        runner,
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
        root,
        home,
    )?)?;
    let path = Path::new(
        flake["path"]
            .as_str()
            .context("missing fixture store path")?,
    );
    ensure!(
        path.starts_with("/nix/store") && !path.join(".git").exists(),
        "private Git history entered store"
    );
    let nar = flake["locked"]["narHash"]
        .as_str()
        .context("missing fixture NAR")?
        .to_owned();
    ensure!(
        observed["out"].as_str() == path.to_str(),
        "fixture evaluation/store locations differ"
    );
    let actual = successful(
        runner,
        nix,
        &[
            "hash",
            "path",
            "--type",
            "sha256",
            "--sri",
            path.to_str().context("fixture store encoding")?,
        ],
        root,
        home,
    )?;
    ensure!(
        std::str::from_utf8(&actual)?.trim() == nar,
        "reported fixture NAR differs from actual bytes"
    );
    let mut retained_matches = true;
    for name in ["payload", "text"] {
        retained_matches &= observed[name]
            .as_str()
            .context("fixture file metadata missing")?
            .as_bytes()
            == fs::read(path.join(name))?;
    }
    Ok(Observation {
        metadata: observed,
        nar,
        retained_matches,
    })
}
