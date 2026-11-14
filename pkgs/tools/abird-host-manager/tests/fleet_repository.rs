use std::ffi::OsString;
use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::process::Command;

use abird_host_manager::fleet::repository::{
    CiCleanMode, CiHostSelection, CiLogFormat, CiTriggerRequest, CommandOutput, CommandRequest,
    CommandRunner, CommitSha, DirtyForwarding, InstalledBinary, ManagedRepository,
    ProcessCommandRunner, RepositoryManager, RootSelectionInput, SelectedRepositoryRoot,
    decode_argv, encode_argv, plan_ci_trigger, plan_installed_execution, read_staged_patch_stdin,
    repo_git_ssh_command, select_repository_root, ssh_repository_endpoint,
};
use abird_host_manager::programs::clear_git_repository_environment;
use anyhow::Result;

/// A `git` command that ignores the ambient repository environment, so a test
/// repository is never re-resolved onto the caller's checkout.
fn git_command() -> Command {
    let mut command = Command::new("git");
    clear_git_repository_environment(&mut command);
    command
}

fn run(command: &mut Command) -> String {
    let output = command.output().unwrap();
    assert!(
        output.status.success(),
        "command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

fn git(repo: &Path, args: &[&str]) -> String {
    run(git_command().arg("-C").arg(repo).args(args))
}

fn init_repo(path: &Path) -> String {
    run(git_command().args(["init", "-q"]).arg(path));
    git(path, &["config", "user.name", "Fleet Test"]);
    git(path, &["config", "user.email", "fleet@example.invalid"]);
    git(path, &["config", "commit.gpgsign", "false"]);
    fs::write(path.join("state"), "initial\n").unwrap();
    git(path, &["add", "state"]);
    git(path, &["commit", "-qm", "initial"]);
    git(path, &["rev-parse", "HEAD"])
}

fn manager() -> RepositoryManager<ProcessCommandRunner> {
    RepositoryManager::new("git", ProcessCommandRunner)
}

#[test]
fn process_command_runner_removes_git_checkout_selectors() {
    let selectors = ["GIT_DIR", "GIT_WORK_TREE"];
    let request = CommandRequest::new("env").environment(
        selectors
            .iter()
            .map(|name| (OsString::from(name), OsString::from("inherited-selector"))),
    );
    let output = ProcessCommandRunner.run(&request).unwrap();
    assert!(output.succeeded());
    let environment = String::from_utf8(output.stdout).unwrap();
    for selector in selectors {
        assert!(
            !environment
                .lines()
                .any(|line| line.starts_with(&format!("{selector}="))),
            "{selector} reached the child process"
        );
    }
}

#[test]
fn repository_ssh_endpoint_parsing_matches_supported_git_url_shapes() {
    assert_eq!(
        ssh_repository_endpoint("ssh://git@git.example:2222/team/repo.git").unwrap(),
        Some(("git.example".to_owned(), 2222))
    );
    assert_eq!(
        ssh_repository_endpoint("ssh://git@[2001:db8::7]/team/repo.git").unwrap(),
        Some(("2001:db8::7".to_owned(), 22))
    );
    assert_eq!(
        ssh_repository_endpoint("git@git.example:team/repo.git").unwrap(),
        Some(("git.example".to_owned(), 22))
    );
    assert_eq!(
        ssh_repository_endpoint("https://git.example/team/repo.git").unwrap(),
        None
    );
    assert!(ssh_repository_endpoint("ssh://git@:22/team/repo.git").is_err());
    assert!(ssh_repository_endpoint("ssh://git@git.example:0/team/repo.git").is_err());
}

#[test]
fn repository_root_selection_reuses_local_checkout_only_for_local_requests() {
    let managed = PathBuf::from("/var/lib/nixbot/nix");
    let local = PathBuf::from("/src/z");
    let base = RootSelectionInput {
        configured_root: managed.clone(),
        configured_root_explicit: false,
        inherited_worktree: None,
        forced_command: false,
        current_checkout: Some(local.clone()),
    };
    assert_eq!(
        select_repository_root(&base),
        SelectedRepositoryRoot {
            source_root: local,
            managed: false,
            inherited_worktree: None,
        }
    );

    for input in [
        RootSelectionInput {
            configured_root_explicit: true,
            ..base.clone()
        },
        RootSelectionInput {
            forced_command: true,
            ..base.clone()
        },
        RootSelectionInput {
            inherited_worktree: Some(PathBuf::from("/run/nixbot/repo")),
            ..base.clone()
        },
    ] {
        let selected = select_repository_root(&input);
        assert_eq!(selected.source_root, managed);
        assert!(selected.managed);
    }
}

#[test]
fn commit_sha_validation_matches_the_legacy_contract() {
    assert!(CommitSha::parse("abcdef0").is_ok());
    assert!(CommitSha::parse("a".repeat(40)).is_ok());
    for invalid in ["abcdef", "ABCDEF0", "abc_def0", &"a".repeat(41)] {
        assert!(CommitSha::parse(invalid).is_err(), "accepted {invalid:?}");
    }
}

#[test]
fn managed_repository_clones_reconciles_fetches_and_tracks_default_ref() {
    let temp = tempfile::tempdir().unwrap();
    let remote = temp.path().join("remote.git");
    let seed = temp.path().join("seed");
    let mirror = temp.path().join("mirror");
    run(git_command().args(["init", "-q", "--bare"]).arg(&remote));
    let first = init_repo(&seed);
    git(
        &seed,
        &["remote", "add", "origin", remote.to_str().unwrap()],
    );
    git(&seed, &["push", "-q", "origin", "HEAD:main"]);
    run(git_command()
        .arg("-C")
        .arg(&remote)
        .args(["symbolic-ref", "HEAD", "refs/heads/main"]));

    let mut manager = manager();
    let first_sync = manager
        .prepare_managed(&ManagedRepository {
            root: mirror.clone(),
            url: remote.to_string_lossy().into_owned(),
            allow_dirty: false,
        })
        .unwrap();
    assert_eq!(first_sync.head.as_str(), first);
    assert_eq!(first_sync.default_ref, "origin/main");
    assert_eq!(
        git(&mirror, &["remote", "get-url", "origin"]),
        remote.to_string_lossy()
    );
    assert_eq!(git(&mirror, &["status", "--porcelain=v1"]), "");

    let wrong = temp.path().join("wrong.git");
    run(git_command().args(["init", "-q", "--bare"]).arg(&wrong));
    git(
        &mirror,
        &["remote", "set-url", "origin", wrong.to_str().unwrap()],
    );
    manager
        .reconcile_origin(&mirror, Some(remote.to_str().unwrap()))
        .unwrap();
    assert_eq!(
        git(&mirror, &["remote", "get-url", "origin"]),
        remote.to_string_lossy()
    );

    git(&mirror, &["remote", "remove", "origin"]);
    manager
        .reconcile_origin(&mirror, Some(remote.to_str().unwrap()))
        .unwrap();
    assert_eq!(
        git(&mirror, &["remote", "get-url", "origin"]),
        remote.to_string_lossy()
    );
    manager.reconcile_origin(&mirror, None).unwrap();
    assert_eq!(
        git(&mirror, &["remote", "get-url", "origin"]),
        remote.to_string_lossy()
    );

    fs::write(seed.join("state"), "second\n").unwrap();
    git(&seed, &["commit", "-qam", "second"]);
    git(&seed, &["push", "-q", "origin", "HEAD:main"]);
    let second_sync = manager.sync_managed(&mirror).unwrap();
    assert_ne!(second_sync.head, first_sync.head);
    assert_eq!(
        fs::read_to_string(mirror.join("state")).unwrap(),
        "second\n"
    );
}

#[test]
fn repository_cleanliness_is_enforced_unless_explicitly_bypassed() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("repo");
    init_repo(&root);
    fs::write(root.join("untracked"), "dirty\n").unwrap();

    let mut manager = manager();
    assert!(manager.capture_staged_patch(&root).unwrap().is_none());
    let error = manager.ensure_clean(&root, false).unwrap_err().to_string();
    assert!(error.contains("repository is dirty"), "{error}");
    manager.ensure_clean(&root, true).unwrap();
}

#[test]
fn detached_worktree_lifecycle_keeps_the_source_checkout_unchanged() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("repo");
    let checkout = temp.path().join("isolated");
    let head = init_repo(&root);

    let mut manager = manager();
    let worktree = manager
        .create_detached_worktree(&root, &checkout, &head)
        .unwrap();
    assert_eq!(worktree.commit.as_str(), head);
    assert_eq!(git(&checkout, &["rev-parse", "HEAD"]), head);
    let symbolic = git_command()
        .arg("-C")
        .arg(&checkout)
        .args(["symbolic-ref", "--quiet", "HEAD"])
        .status()
        .unwrap();
    assert!(!symbolic.success(), "execution worktree must be detached");
    assert!(
        manager
            .create_detached_worktree(&root, &temp.path().join("missing"), "deadbee")
            .is_err()
    );

    manager.remove_worktree(&root, &checkout).unwrap();
    assert!(!checkout.exists());
    assert_eq!(git(&root, &["rev-parse", "HEAD"]), head);
}

struct MovingWorktreeRef {
    root: PathBuf,
    resolved: String,
    replacement: String,
    remove_resolved: bool,
    requests: Vec<CommandRequest>,
}

impl CommandRunner for MovingWorktreeRef {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput> {
        self.requests.push(request.clone());
        if request.args.starts_with(&["worktree".into(), "add".into()]) {
            git(
                &self.root,
                &["update-ref", "refs/heads/moving", &self.replacement],
            );
            if self.remove_resolved {
                fs::remove_file(
                    self.root
                        .join(".git/objects")
                        .join(&self.resolved[..2])
                        .join(&self.resolved[2..]),
                )?;
            }
        }
        ProcessCommandRunner.run(request)
    }
}

fn moving_ref_fixture(root: &Path, remove_resolved: bool) -> MovingWorktreeRef {
    let resolved = init_repo(root);
    fs::write(root.join("state"), "replacement\n").unwrap();
    git(root, &["commit", "-qam", "replacement"]);
    let replacement = git(root, &["rev-parse", "HEAD"]);
    git(root, &["branch", "moving", &resolved]);
    MovingWorktreeRef {
        root: root.into(),
        resolved,
        replacement,
        remove_resolved,
        requests: Vec::new(),
    }
}

#[test]
fn detached_worktree_uses_resolved_commit_even_if_target_ref_moves_before_add() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("repo");
    let checkout = temp.path().join("execution");
    let runner = moving_ref_fixture(&root, false);
    let resolved = runner.resolved.clone();
    let replacement = runner.replacement.clone();
    let mut manager = RepositoryManager::new("git", runner);
    let worktree = manager
        .create_detached_worktree(&root, &checkout, "moving")
        .unwrap();
    assert_eq!(worktree.commit.as_str(), resolved);
    assert_eq!(git(&checkout, &["rev-parse", "HEAD"]), resolved);
    assert_eq!(
        fs::read_to_string(checkout.join("state")).unwrap(),
        "initial\n"
    );
    assert_eq!(git(&root, &["rev-parse", "moving"]), replacement);
    assert_eq!(git(&root, &["rev-parse", "HEAD"]), replacement);
    manager.remove_worktree(&root, &checkout).unwrap();
}

#[test]
fn detached_worktree_does_not_substitute_moved_ref_when_resolved_object_is_missing() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("repo");
    let checkout = temp.path().join("execution");
    let runner = moving_ref_fixture(&root, true);
    let resolved = runner.resolved.clone();
    let mut manager = RepositoryManager::new("git", runner);
    assert!(
        manager
            .create_detached_worktree(&root, &checkout, "moving")
            .is_err()
    );
    let requests = &manager.runner().requests;
    assert_eq!(
        requests.len(),
        2,
        "missing commit must not trigger another selection"
    );
    assert_eq!(requests[1].args.last(), Some(&OsString::from(resolved)));
}

#[test]
fn staged_binary_patch_is_captured_base_checked_and_applied_with_index_state() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("repo");
    let checkout = temp.path().join("isolated");
    let head = init_repo(&root);
    let before = vec![0, 1, 2, 3, 0, 9];
    let after = vec![0, 8, 7, 6, 0, 5, 4, 3];
    fs::write(root.join("asset.bin"), &before).unwrap();
    git(&root, &["add", "asset.bin"]);
    git(&root, &["commit", "-qm", "binary"]);
    let base = git(&root, &["rev-parse", "HEAD"]);
    fs::write(root.join("asset.bin"), &after).unwrap();
    git(&root, &["add", "asset.bin"]);
    fs::write(root.join("state"), "ignored unstaged\n").unwrap();
    fs::write(root.join("ignored-untracked"), "ignored\n").unwrap();

    let mut manager = manager();
    let captured = manager.capture_staged_patch(&root).unwrap().unwrap();
    assert_eq!(captured.patch.base.as_str(), base);
    assert!(
        captured
            .patch
            .bytes
            .windows(16)
            .any(|part| part == b"GIT binary patch")
    );
    assert!(captured.ignored.unstaged_tracked);
    assert!(captured.ignored.untracked);
    manager
        .validate_staged_base(&root, &base, &captured.patch.base)
        .unwrap();
    assert!(
        manager
            .validate_staged_base(&root, &head, &captured.patch.base)
            .is_err()
    );

    manager
        .create_detached_worktree(&root, &checkout, &base)
        .unwrap();
    manager
        .apply_staged_patch(&checkout, &captured.patch)
        .unwrap();
    assert_eq!(fs::read(checkout.join("asset.bin")).unwrap(), after);
    assert!(!git(&checkout, &["diff", "--cached", "--name-only"]).is_empty());
    manager.remove_worktree(&root, &checkout).unwrap();
}

#[test]
fn standalone_checkout_preserves_native_settings_and_selected_bytes_without_parent_metadata() {
    for autocrlf in ["false", "true", "input"] {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        let base = init_repo(&source);
        git(&source, &["config", "core.autocrlf", autocrlf]);
        git(&source, &["config", "core.eol", "lf"]);
        fs::write(source.join("state"), "selected\n").unwrap();
        git(&source, &["add", "state"]);
        fs::write(source.join("state"), "ignored unstaged\n").unwrap();
        fs::write(source.join("untracked"), "ignored\n").unwrap();
        let mut manager = manager();
        let patch = manager
            .capture_staged_patch(&source)
            .unwrap()
            .unwrap()
            .patch;
        let native = temp.path().join("native");
        manager
            .create_detached_worktree(&source, &native, &base)
            .unwrap();
        manager.apply_staged_patch(&native, &patch).unwrap();
        let settings = manager.checkout_settings(&native).unwrap();
        let target = temp.path().join("standalone");
        let replica = manager
            .create_standalone_checkout(&source, &target, &patch.base, &settings)
            .unwrap();
        manager.apply_staged_patch(&target, &patch).unwrap();
        assert_eq!(replica.path, target);
        assert_eq!(replica.commit, patch.base);
        assert!(
            manager.checkout_settings(&native).unwrap()
                == manager.checkout_settings(&target).unwrap()
        );
        assert_eq!(
            fs::read(native.join("state")).unwrap(),
            fs::read(target.join("state")).unwrap()
        );
        assert!(!target.join("untracked").exists());
        assert!(target.join(".git").is_dir());
        assert!(!target.join(".git/commondir").exists());
        assert!(!target.join(".git/objects/info/alternates").exists());
        fs::rename(&source, temp.path().join("source-moved")).unwrap();
        assert_eq!(git(&target, &["rev-parse", "HEAD"]), base);
        assert!(
            !git_command()
                .arg("-C")
                .arg(&native)
                .args(["rev-parse", "HEAD"])
                .output()
                .unwrap()
                .status
                .success()
        );
        git(&target, &["fsck", "--full", "--strict", "--no-reflogs"]);
    }
}

#[test]
fn native_projection_preserves_modes_but_does_not_verify_working_bytes_or_checkout_context() {
    use std::os::unix::{ffi::OsStrExt, fs::symlink};

    use abird_host_manager::fleet::repository::{ObjectLimits, TreeKind};

    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    init_repo(&source);
    for (key, value) in [
        ("core.autocrlf", "false"),
        ("core.eol", "lf"),
        ("core.filemode", "true"),
        ("core.symlinks", "true"),
        ("core.ignorecase", "false"),
        ("core.safecrlf", "false"),
    ] {
        git(&source, &["config", key, value]);
    }
    fs::write(
        source.join(".gitattributes"),
        b"crlf.txt text eol=crlf\nlink.txt text eol=crlf\nfiltered.txt filter=mark\n",
    )
    .unwrap();
    fs::write(source.join("crlf.txt"), b"line\n").unwrap();
    fs::write(source.join("filtered.txt"), b"payload\n").unwrap();
    symlink("dest\n", source.join("link.txt")).unwrap();
    git(
        &source,
        &[
            "add",
            ".gitattributes",
            "crlf.txt",
            "filtered.txt",
            "link.txt",
        ],
    );
    git(&source, &["commit", "-qm", "checkout context"]);
    let revision = CommitSha::parse(git(&source, &["rev-parse", "HEAD"])).unwrap();
    git(&source, &["config", "filter.mark.required", "true"]);
    git(
        &source,
        &[
            "config",
            "filter.mark.smudge",
            ": > .projection-effect; printf 'smudged:'; while IFS= read -r line; do printf '%s\\n' \"$line\"; done",
        ],
    );
    git(
        &source,
        &[
            "config",
            "filter.mark.clean",
            "while IFS= read -r line; do printf '%s\\n' \"${line#smudged:}\"; done",
        ],
    );
    let mut manager = manager();
    let commit = manager.commit_object(&source, &revision).unwrap();
    let observed = manager
        .observe_tree(
            &source,
            &commit.tree_id().unwrap(),
            ObjectLimits {
                entries: 16,
                bytes: 8192,
                depth: 4,
                path_bytes: 8192,
            },
        )
        .unwrap();
    for symlinks in ["true", "false"] {
        git(&source, &["config", "core.symlinks", symlinks]);
        let native = temp.path().join(format!("native-{symlinks}"));
        manager
            .create_detached_worktree(&source, &native, revision.as_str())
            .unwrap();
        assert!(native.join(".projection-effect").exists());
        fs::remove_file(native.join(".projection-effect")).unwrap();
        let filtered = manager
            .checkout_projection(&native, &observed, b"filtered.txt")
            .unwrap();
        assert_eq!(filtered.bytes(), b"smudged:payload\n");
        assert_eq!(
            filtered.bytes(),
            fs::read(native.join("filtered.txt")).unwrap()
        );
        assert!(native.join(".projection-effect").exists());
        let link = manager
            .checkout_projection(&native, &observed, b"link.txt")
            .unwrap();
        assert!(link.kind() == TreeKind::Symlink);
        assert_eq!(link.bytes(), b"dest\n");
        if symlinks == "true" {
            assert_eq!(
                fs::read_link(native.join("link.txt"))
                    .unwrap()
                    .as_os_str()
                    .as_bytes(),
                link.bytes()
            );
        } else {
            assert!(!native.join("link.txt").is_symlink());
            assert_eq!(fs::read(native.join("link.txt")).unwrap(), link.bytes());
        }
        let wrong = git_command()
            .arg("-C")
            .arg(&native)
            .args([
                "cat-file",
                "--filters",
                "--path=link.txt",
                link.object().as_str(),
            ])
            .output()
            .unwrap();
        assert!(wrong.status.success());
        assert_eq!(wrong.stdout, b"dest\r\n");
        let text = manager
            .checkout_projection(&native, &observed, b"crlf.txt")
            .unwrap();
        assert_eq!(text.bytes(), b"line\r\n");
        assert_eq!(text.bytes(), fs::read(native.join("crlf.txt")).unwrap());
        fs::write(native.join("crlf.txt"), b"tampered\n").unwrap();
        assert!(
            manager
                .index_entries(&native)
                .unwrap()
                .matches_tree(&observed)
        );
        assert_ne!(
            manager
                .checkout_projection(&native, &observed, b"crlf.txt")
                .unwrap()
                .bytes(),
            fs::read(native.join("crlf.txt")).unwrap(),
        );
    }
    fs::write(source.join(".git/info/attributes"), b"crlf.txt -text\n").unwrap();
    let native = temp.path().join("native-info");
    manager
        .create_detached_worktree(&source, &native, revision.as_str())
        .unwrap();
    let settings = manager.checkout_settings(&native).unwrap();
    let replica = temp.path().join("replica");
    manager
        .create_standalone_checkout(&source, &replica, &revision, &settings)
        .unwrap();
    assert!(manager.checkout_settings(&replica).unwrap() == settings);
    for name in [b"crlf.txt".as_slice(), b"filtered.txt"] {
        let actual = manager
            .checkout_projection(&native, &observed, name)
            .unwrap();
        let copied = manager
            .checkout_projection(&replica, &observed, name)
            .unwrap();
        assert_ne!(actual.bytes(), copied.bytes());
        for path in [&native, &replica] {
            assert!(manager.index_entries(path).unwrap().matches_tree(&observed));
        }
    }
}

#[test]
fn checkout_settings_use_effective_values_and_distinguish_bare_from_empty() {
    use std::io::Write;
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let base = init_repo(&source);
    git(&source, &["config", "--add", "core.autocrlf", "input"]);
    git(&source, &["config", "--add", "core.autocrlf", "false"]);
    // Native typed --get rejects shadowed input even though the effective value
    // is false. Snapshot + isolated conversion must not inherit that failure.
    assert!(
        !git_command()
            .arg("-C")
            .arg(&source)
            .args(["config", "--type=bool", "--get", "core.autocrlf"])
            .output()
            .unwrap()
            .status
            .success()
    );
    let mut manager = manager();
    let settings = manager.checkout_settings(&source).unwrap();
    let target = temp.path().join("replica");
    manager
        .create_standalone_checkout(
            &source,
            &target,
            &CommitSha::parse(base).unwrap(),
            &settings,
        )
        .unwrap();
    assert_eq!(git(&target, &["config", "--get", "core.autocrlf"]), "false");
    fs::OpenOptions::new()
        .append(true)
        .open(source.join(".git/config"))
        .unwrap()
        .write_all(b"\n[core]\nautocrlf\nfilemode=\n")
        .unwrap();
    let implicit = manager.checkout_settings(&source).unwrap();
    manager.apply_checkout_settings(&target, &implicit).unwrap();
    assert_eq!(git(&target, &["config", "--get", "core.autocrlf"]), "true");
    assert_eq!(git(&target, &["config", "--get", "core.filemode"]), "false");
}

#[test]
fn native_index_entries_reject_hidden_flags_but_do_not_claim_working_bytes_or_index_identity() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("source");
    init_repo(&root);
    let mut manager = manager();
    let baseline = manager.index_entries(&root).unwrap();
    let commit = manager
        .commit_object(
            &root,
            &CommitSha::parse(git(&root, &["rev-parse", "HEAD"])).unwrap(),
        )
        .unwrap();
    let limits = abird_host_manager::fleet::repository::ObjectLimits {
        entries: 16,
        bytes: 4096,
        depth: 4,
        path_bytes: 4096,
    };
    let observed = manager
        .observe_tree(&root, &commit.tree_id().unwrap(), limits)
        .unwrap();
    assert!(baseline.matches_tree(&observed));
    fs::write(root.join("state"), b"unrequested bytes\n").unwrap();
    assert!(manager.index_entries(&root).unwrap() == baseline);
    assert!(
        manager
            .index_entries(&root)
            .unwrap()
            .matches_tree(&observed)
    );
    for flag in ["assume-unchanged", "skip-worktree"] {
        git(
            &root,
            &["update-index", &format!("--{flag}"), "--", "state"],
        );
        let error = manager.index_entries(&root).err().unwrap().to_string();
        assert!(error.contains("unsupported native index entry flags"));
        git(
            &root,
            &["update-index", &format!("--no-{flag}"), "--", "state"],
        );
        assert!(manager.index_entries(&root).unwrap() == baseline);
    }
    git(&root, &["add", "state"]);
    assert!(manager.index_entries(&root).unwrap() != baseline);
    // Intent-to-add is not exposed by this listing; do not call it an index-file
    // verifier. Full flags/extensions and source semantics remain separate gates.
    fs::write(root.join("empty"), b"").unwrap();
    git(&root, &["add", "-N", "empty"]);
    let intent = manager.index_entries(&root).unwrap();
    git(&root, &["add", "empty"]);
    assert!(manager.index_entries(&root).unwrap() == intent);
    let indexed =
        abird_host_manager::fleet::repository::ObjectId::parse(git(&root, &["write-tree"]))
            .unwrap();
    let ordinary = manager.observe_tree(&root, &indexed, limits).unwrap();
    assert!(intent.matches_tree(&ordinary)); // Projection still hides intent-to-add.
}

#[test]
fn selected_tree_observation_rejects_substituted_child_blobs_with_valid_parent_objects() {
    use abird_host_manager::fleet::repository::ObjectLimits;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    for replacement_ref in [false, true] {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        init_repo(&source);
        fs::create_dir(source.join("d")).unwrap();
        fs::write(source.join("d/file"), b"child\0\xff").unwrap();
        git(&source, &["add", "d/file"]);
        git(&source, &["commit", "-m", "child"]);
        let base = CommitSha::parse(git(&source, &["rev-parse", "HEAD"])).unwrap();
        let mut manager = manager();
        let commit = manager.commit_object(&source, &base).unwrap();
        let root = commit.tree_id().unwrap();
        let limits = ObjectLimits {
            entries: 16,
            bytes: 4096,
            depth: 4,
            path_bytes: 4096,
        };
        let observed = manager.observe_tree(&source, &root, limits).unwrap();
        assert_eq!(observed.entries().len(), 3);
        let child = observed
            .entries()
            .get(b"d/file".as_slice())
            .unwrap()
            .object();
        let made = ProcessCommandRunner
            .run(
                &CommandRequest::new("git")
                    .args(["hash-object", "--no-filters", "-t", "blob", "-w", "--stdin"])
                    .current_dir(&source)
                    .stdin(b"changed child\n".to_vec()),
            )
            .unwrap();
        assert!(made.succeeded());
        let other = String::from_utf8(made.stdout).unwrap().trim().to_owned();
        assert_ne!(child.as_str(), other);
        if replacement_ref {
            git(&source, &["replace", child.as_str(), &other]);
        } else {
            let path = source
                .join(".git/objects")
                .join(&child.as_str()[..2])
                .join(&child.as_str()[2..]);
            let other = source
                .join(".git/objects")
                .join(&other[..2])
                .join(&other[2..]);
            let meta = fs::symlink_metadata(&path).unwrap();
            assert!(meta.is_file() && meta.nlink() == 1);
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
            fs::write(path, fs::read(other).unwrap()).unwrap();
        }
        assert_eq!(
            manager.commit_object(&source, &base).unwrap().bytes(),
            commit.bytes()
        );
        manager.tree_object(&source, &root).unwrap();
        manager
            .tree_object(
                &source,
                observed.entries().get(b"d".as_slice()).unwrap().object(),
            )
            .unwrap();
        let error = manager.observe_tree(&source, &root, limits).err().unwrap();
        assert!(error.to_string().contains("native blob content differs"));
    }
}

#[test]
fn hashed_tree_with_missing_child_is_not_a_complete_selected_tree_observation() {
    use abird_host_manager::fleet::repository::{ObjectId, ObjectLimits};
    let temp = tempfile::tempdir().unwrap();
    init_repo(temp.path());
    let bytes = [b"100644 missing\0".as_slice(), &[1; 20]].concat();
    let made = ProcessCommandRunner
        .run(
            &CommandRequest::new("git")
                .args(["hash-object", "--no-filters", "-t", "tree", "-w", "--stdin"])
                .current_dir(temp.path())
                .stdin(bytes),
        )
        .unwrap();
    assert!(made.succeeded());
    let root = ObjectId::parse(String::from_utf8(made.stdout).unwrap().trim()).unwrap();
    let mut manager = manager();
    assert_eq!(
        manager
            .tree_object(temp.path(), &root)
            .unwrap()
            .entries()
            .len(),
        1
    );
    let error = manager
        .observe_tree(
            temp.path(),
            &root,
            ObjectLimits {
                entries: 16,
                bytes: 4096,
                depth: 4,
                path_bytes: 4096,
            },
        )
        .err()
        .unwrap();
    assert!(error.to_string().contains("read native blob object failed"));
}

#[test]
fn root_tree_hash_rejects_replacement_and_corruption_before_recipe_worktree_creation() {
    use abird_host_agent::build_executor::request::Source;
    use abird_host_manager::fleet::preparation::source::SourceRecipe;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    for replacement_ref in [false, true] {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        let base = CommitSha::parse(init_repo(&source)).unwrap();
        let mut manager = manager();
        let commit = manager.commit_object(&source, &base).unwrap();
        let id = commit.tree_id().unwrap();
        let observed = manager
            .observe_tree(
                &source,
                &id,
                abird_host_manager::fleet::repository::ObjectLimits {
                    entries: 16,
                    bytes: 4096,
                    depth: 4,
                    path_bytes: 4096,
                },
            )
            .unwrap();
        let tree = manager.tree_object(&source, &id).unwrap();
        assert_eq!(tree.identity().as_str(), id.as_str());
        assert_eq!(tree.entries().len(), 1);
        assert_eq!(tree.entries()[0].name(), b"state");
        let raw = ProcessCommandRunner
            .run(
                &CommandRequest::new("git")
                    .args(["cat-file", "tree", id.as_str()])
                    .current_dir(&source),
            )
            .unwrap();
        assert!(raw.succeeded());
        let mut changed = raw.stdout;
        assert_eq!(&changed[7..12], b"state");
        changed[7..12].copy_from_slice(b"other");
        let made = ProcessCommandRunner
            .run(
                &CommandRequest::new("git")
                    .args(["hash-object", "--no-filters", "-t", "tree", "-w", "--stdin"])
                    .current_dir(&source)
                    .stdin(changed.clone()),
            )
            .unwrap();
        assert!(made.succeeded());
        let other = String::from_utf8(made.stdout).unwrap().trim().to_owned();
        assert_ne!(other, id.as_str());
        if replacement_ref {
            git(&source, &["replace", id.as_str(), &other]);
        } else {
            let path = source
                .join(".git/objects")
                .join(&id.as_str()[..2])
                .join(&id.as_str()[2..]);
            let other_path = source
                .join(".git/objects")
                .join(&other[..2])
                .join(&other[2..]);
            let meta = fs::symlink_metadata(&path).unwrap();
            assert!(meta.is_file() && meta.nlink() == 1);
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
            fs::write(path, fs::read(other_path).unwrap()).unwrap();
        }
        // Commit bytes still match; root-tree bytes are a distinct obligation.
        assert_eq!(
            manager.commit_object(&source, &base).unwrap().bytes(),
            commit.bytes()
        );
        let error = manager.tree_object(&source, &id).err().unwrap();
        assert!(error.to_string().contains("native tree content differs"));
        let recipe = SourceRecipe::bind(
            &Source {
                revision: base.as_str().into(),
                base_revision: base.as_str().into(),
                tree_digest: None,
                patch_digest: None,
            },
            None,
        )
        .unwrap();
        let target = temp.path().join("new-parent/view");
        let error = recipe
            .native_worktree(&mut manager, &source, &target, &observed)
            .err()
            .unwrap();
        assert!(error.to_string().contains("native tree content differs"));
        assert!(!target.parent().unwrap().exists());
    }
}

#[test]
fn native_commit_bytes_reject_replacement_and_corrupt_objects_at_the_requested_name() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    for replacement_ref in [false, true] {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source");
        let base = CommitSha::parse(init_repo(&source)).unwrap();
        let mut manager = manager();
        let original = manager.commit_object(&source, &base).unwrap();
        assert_eq!(original.revision(), &base);
        let mut changed = original.bytes().to_vec();
        changed.extend_from_slice(b"different synthetic message\n");
        let made = ProcessCommandRunner
            .run(
                &CommandRequest::new("git")
                    .args([
                        "hash-object",
                        "--no-filters",
                        "-t",
                        "commit",
                        "-w",
                        "--stdin",
                    ])
                    .current_dir(&source)
                    .stdin(changed.clone()),
            )
            .unwrap();
        assert!(made.succeeded());
        let other = String::from_utf8(made.stdout).unwrap().trim().to_owned();
        assert_ne!(other, base.as_str());
        if replacement_ref {
            git(&source, &["replace", base.as_str(), &other]);
            assert_eq!(git(&source, &["rev-parse", "HEAD"]), base.as_str());
        } else {
            // Only freshly created synthetic, unshared loose objects.
            let path = source
                .join(".git/objects")
                .join(&base.as_str()[..2])
                .join(&base.as_str()[2..]);
            let other_path = source
                .join(".git/objects")
                .join(&other[..2])
                .join(&other[2..]);
            let meta = fs::symlink_metadata(&path).unwrap();
            assert!(meta.is_file() && meta.nlink() == 1);
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
            fs::write(path, fs::read(other_path).unwrap()).unwrap();
            // Native resolution itself checks corruption; cat-file alone doesn't.
            assert!(
                manager
                    .validate_staged_base(&source, base.as_str(), &base)
                    .is_err()
            );
        }
        let captured = ProcessCommandRunner
            .run(
                &CommandRequest::new("git")
                    .args(["cat-file", "commit", base.as_str()])
                    .current_dir(&source),
            )
            .unwrap();
        assert!(captured.succeeded());
        assert_eq!(captured.stdout, changed);
        let error = manager.commit_object(&source, &base).err().unwrap();
        assert!(
            error
                .to_string()
                .contains("content differs from requested identity")
        );
    }
}

struct ReplaceCommitBeforeWorktree {
    root: PathBuf,
    base: String,
    replacement: String,
    requests: Vec<CommandRequest>,
}
impl CommandRunner for ReplaceCommitBeforeWorktree {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput> {
        self.requests.push(request.clone());
        if request.args.starts_with(&["worktree".into(), "add".into()]) {
            git(&self.root, &["replace", &self.base, &self.replacement]);
        }
        ProcessCommandRunner.run(request)
    }
}

#[test]
fn recipe_rejects_late_replacement_base_index_before_patch_without_cleanup_or_replay() {
    use abird_host_agent::build_executor::request::Source;
    use abird_host_manager::fleet::preparation::source::SourceRecipe;
    use abird_host_manager::fleet::repository::ObjectLimits;
    use sha2::{Digest, Sha256};
    for with_patch in [false, true] {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("repo");
        let base = init_repo(&root);
        fs::write(root.join("unexpected"), b"not selected\n").unwrap();
        git(&root, &["add", "unexpected"]);
        git(&root, &["commit", "-m", "replacement"]);
        let replacement = git(&root, &["rev-parse", "HEAD"]);
        git(&root, &["checkout", "--detach", &base]);
        let mut observer = manager();
        let patch = if with_patch {
            fs::write(root.join("state"), b"selected\n").unwrap();
            git(&root, &["add", "state"]);
            Some(observer.capture_staged_patch(&root).unwrap().unwrap().patch)
        } else {
            None
        };
        let intent = Source {
            revision: base.clone(),
            base_revision: base.clone(),
            tree_digest: None,
            patch_digest: patch
                .as_ref()
                .map(|p| format!("{:x}", Sha256::digest(&p.bytes))),
        };
        let recipe = SourceRecipe::bind(&intent, patch).unwrap();
        let commit = observer
            .commit_object(&root, &CommitSha::parse(base.clone()).unwrap())
            .unwrap();
        let observed = observer
            .observe_tree(
                &root,
                &commit.tree_id().unwrap(),
                ObjectLimits {
                    entries: 16,
                    bytes: 4096,
                    depth: 4,
                    path_bytes: 4096,
                },
            )
            .unwrap();
        let mut repository = RepositoryManager::new(
            "git",
            ReplaceCommitBeforeWorktree {
                root: root.clone(),
                base: base.clone(),
                replacement,
                requests: Vec::new(),
            },
        );
        let target = temp.path().join("view");
        let error = recipe
            .native_worktree(&mut repository, &root, &target, &observed)
            .err()
            .unwrap();
        assert_eq!(
            error.to_string(),
            "native base index differs from observed tree"
        );
        assert_eq!(git(&target, &["rev-parse", "HEAD"]), base);
        assert_eq!(fs::read(target.join("state")).unwrap(), b"initial\n");
        assert_eq!(
            fs::read(target.join("unexpected")).unwrap(),
            b"not selected\n"
        );
        let requests = &repository.runner().requests;
        assert_eq!(
            requests
                .iter()
                .filter(|r| r.args.starts_with(&["worktree".into(), "add".into()]))
                .count(),
            1
        );
        assert!(
            !requests.iter().any(|r| r.args[0] == "apply"
                || r.args.starts_with(&["worktree".into(), "remove".into()]))
        );
    }
}

#[test]
fn source_recipe_binds_exact_binary_artifact_before_native_materialization() {
    use abird_host_agent::build_executor::request::Source;
    use abird_host_manager::fleet::preparation::source::SourceRecipe;
    use sha2::{Digest, Sha256};
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let base = init_repo(&source);
    fs::write(source.join("binary"), b"selected\0binary\xff").unwrap();
    fs::write(source.join("state"), b"selected\n").unwrap();
    git(&source, &["add", "state", "binary"]);
    fs::write(source.join("state"), b"ignored unstaged\n").unwrap();
    fs::write(source.join("ignored"), b"untracked").unwrap();
    let mut manager = manager();
    let selected = manager.capture_staged_patch(&source).unwrap().unwrap();
    let intent = Source {
        revision: base.clone(),
        base_revision: base.clone(),
        tree_digest: None,
        patch_digest: Some(format!("{:x}", Sha256::digest(&selected.patch.bytes))),
    };
    let mut corrupt = selected.patch.clone();
    corrupt.bytes.push(b' ');
    assert!(SourceRecipe::bind(&intent, Some(corrupt)).is_err());
    let recipe = SourceRecipe::bind(&intent, Some(selected.patch)).unwrap();
    let target = temp.path().join("native");
    let commit = manager
        .commit_object(&source, &CommitSha::parse(base.clone()).unwrap())
        .unwrap();
    let observed = manager
        .observe_tree(
            &source,
            &commit.tree_id().unwrap(),
            abird_host_manager::fleet::repository::ObjectLimits {
                entries: 16,
                bytes: 4096,
                depth: 4,
                path_bytes: 4096,
            },
        )
        .unwrap();
    let view = recipe
        .native_worktree(&mut manager, &source, &target, &observed)
        .unwrap();
    assert_eq!(view.commit.as_str(), base);
    assert_eq!(git(&target, &["rev-parse", "HEAD"]), base);
    assert_eq!(fs::read(target.join("state")).unwrap(), b"selected\n");
    assert_eq!(
        fs::read(target.join("binary")).unwrap(),
        b"selected\0binary\xff"
    );
    assert!(!target.join("ignored").exists());
    manager.remove_worktree(&source, &target).unwrap();
}

#[test]
fn standalone_missing_commit_does_not_fallback_or_adopt_existing_data() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let base = init_repo(&source);
    let mut manager = manager();
    let settings = manager.checkout_settings(&source).unwrap();
    let missing = CommitSha::parse("f".repeat(40)).unwrap();
    assert_ne!(missing.as_str(), base);
    let target = temp.path().join("standalone");
    assert!(
        manager
            .create_standalone_checkout(&source, &target, &missing, &settings)
            .is_err()
    );
    assert!(
        target.join(".git").is_dir(),
        "failed producer remains tracked, not deleted"
    );
    assert!(
        manager
            .create_standalone_checkout(
                &source,
                &target,
                &CommitSha::parse(base.clone()).unwrap(),
                &settings
            )
            .is_err()
    );
    assert_eq!(git(&source, &["rev-parse", "HEAD"]), base);
}

#[derive(Default)]
struct RecordingRunner {
    requests: Vec<CommandRequest>,
}

impl CommandRunner for RecordingRunner {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput> {
        self.requests.push(request.clone());
        Ok(CommandOutput::success(Vec::new()))
    }
}

#[test]
fn staged_patch_application_uses_git_apply_stdin_without_shell_interpolation() {
    let patch = read_staged_patch_stdin(
        Cursor::new(b"binary patch payload"),
        CommitSha::parse("abcdef0").unwrap(),
    )
    .unwrap();
    let mut manager = RepositoryManager::new("/usr/bin/git", RecordingRunner::default());
    manager
        .apply_staged_patch(Path::new("/isolated/repo"), &patch)
        .unwrap();

    let request = &manager.runner().requests[0];
    assert_eq!(request.program, Path::new("/usr/bin/git"));
    assert_eq!(
        request.current_dir.as_deref(),
        Some(Path::new("/isolated/repo"))
    );
    assert_eq!(
        request.args,
        ["apply", "--index", "--binary", "--allow-empty", "-"].map(OsString::from)
    );
    assert_eq!(
        request.stdin.as_deref(),
        Some(b"binary patch payload".as_slice())
    );

    assert!(
        read_staged_patch_stdin(
            Cursor::new(Vec::<u8>::new()),
            CommitSha::parse("abcdef0").unwrap()
        )
        .is_err()
    );
}

#[test]
fn repository_git_transport_trusts_on_first_use_and_is_propagated_to_every_git_request() {
    let temporary = tempfile::tempdir().unwrap();
    let known_hosts = temporary.path().join("known hosts");
    let identity = temporary.path().join("identity's key");
    fs::write(&known_hosts, "git.example ssh-ed25519 AAAA\n").unwrap();
    fs::write(&identity, "fixture\n").unwrap();
    let command = repo_git_ssh_command(&known_hosts, std::slice::from_ref(&identity)).unwrap();
    assert!(command.contains("StrictHostKeyChecking=accept-new"));
    assert!(command.contains("GlobalKnownHostsFile=/dev/null"));
    assert!(command.contains("IdentitiesOnly=yes"));
    assert!(command.contains(&format!(
        "'{}'",
        identity.display().to_string().replace('\'', "'\\''")
    )));

    let mut manager = RepositoryManager::new("/usr/bin/git", RecordingRunner::default())
        .with_environment([("GIT_SSH_COMMAND", command.clone())]);
    let patch =
        read_staged_patch_stdin(Cursor::new(b"patch"), CommitSha::parse("abcdef0").unwrap())
            .unwrap();
    manager
        .apply_staged_patch(Path::new("/isolated/repo"), &patch)
        .unwrap();
    assert_eq!(
        manager.runner().requests[0].environment,
        vec![(OsString::from("GIT_SSH_COMMAND"), OsString::from(command))]
    );
}

#[test]
fn argv_codec_round_trips_nuls_spaces_unicode_and_empty_arguments() {
    let argv = vec![
        "deploy".to_owned(),
        "--host".to_owned(),
        "name with spaces".to_owned(),
        "snowman-☃".to_owned(),
        String::new(),
    ];
    let encoded = encode_argv(&argv);
    assert!(!encoded.contains('\n'));
    assert_eq!(decode_argv(&encoded).unwrap(), argv);
    assert!(decode_argv("not base64!").is_err());
}

fn deploy_trigger() -> CiTriggerRequest {
    CiTriggerRequest {
        action: "deploy".to_owned(),
        strategy: None,
        sha: Some(CommitSha::parse("abcdef0").unwrap()),
        clean_mode: CiCleanMode::Auto,
        group: Some("prod".to_owned()),
        hosts: None,
        required_hosts: Vec::new(),
        nix_config: Some("app-system".to_owned()),
        log_format: CiLogFormat::Plain,
        dry_run: true,
        force: true,
        restart_managed: true,
        control_plane_first: true,
        verify: false,
        dirty: DirtyForwarding::Clean,
    }
}

#[test]
fn ci_trigger_plans_only_the_remote_contract_and_exact_patch_stdin() {
    let group_only = plan_ci_trigger(&deploy_trigger()).unwrap();
    assert_eq!(
        group_only.argv[0..4],
        ["deploy", "--sha", "abcdef0", "--no-override"]
    );
    assert!(
        group_only
            .argv
            .windows(2)
            .any(|pair| pair == ["--group", "prod"])
    );
    assert!(!group_only.argv.iter().any(|arg| arg == "--hosts"));
    assert!(!group_only.argv.iter().any(|arg| arg == "--build-host"));
    assert!(!group_only.argv.iter().any(|arg| arg == "--route"));
    assert!(
        !group_only
            .argv
            .iter()
            .any(|arg| arg.starts_with("--route="))
    );
    assert!(
        group_only
            .argv
            .iter()
            .any(|arg| arg == "--control-plane-first")
    );
    assert_eq!(
        decode_argv(&group_only.encoded_argv).unwrap(),
        group_only.argv
    );
    assert!(group_only.remote_command.starts_with("__nixbot_argv64 "));
    assert!(group_only.stdin.is_none());

    let mut selectors = deploy_trigger();
    selectors.group = None;
    selectors.hosts = Some(CiHostSelection::Selectors("app-*,-old".to_owned()));
    selectors.log_format = CiLogFormat::GithubActions;
    selectors.dirty = DirtyForwarding::AllowDirty;
    let selectors = plan_ci_trigger(&selectors).unwrap();
    assert!(
        selectors
            .argv
            .windows(2)
            .any(|pair| pair == ["--hosts", "app-*,-old"])
    );
    assert!(
        selectors
            .argv
            .windows(2)
            .any(|pair| pair == ["--log-format", "gh"])
    );
    assert!(selectors.argv.iter().any(|arg| arg == "--dirty"));

    let mut staged = deploy_trigger();
    staged.hosts = Some(CiHostSelection::Singular("app".to_owned()));
    staged.dirty = DirtyForwarding::Staged {
        patch: read_staged_patch_stdin(
            Cursor::new(b"patch bytes"),
            CommitSha::parse("abcdef0").unwrap(),
        )
        .unwrap(),
    };
    let staged = plan_ci_trigger(&staged).unwrap();
    assert!(staged.argv.windows(2).any(|pair| pair == ["--host", "app"]));
    assert!(
        staged
            .argv
            .iter()
            .any(|arg| arg == "--dirty-staged-patch-stdin")
    );
    assert_eq!(staged.stdin.as_deref(), Some(b"patch bytes".as_slice()));

    let mut mismatched = deploy_trigger();
    mismatched.dirty = DirtyForwarding::Staged {
        patch: read_staged_patch_stdin(
            Cursor::new(b"patch bytes"),
            CommitSha::parse("1234567").unwrap(),
        )
        .unwrap(),
    };
    assert!(plan_ci_trigger(&mismatched).is_err());

    let clean = plan_ci_trigger(&CiTriggerRequest {
        action: "clean".to_owned(),
        strategy: None,
        sha: None,
        clean_mode: CiCleanMode::All,
        group: None,
        hosts: None,
        required_hosts: Vec::new(),
        nix_config: None,
        log_format: CiLogFormat::Auto,
        dry_run: false,
        force: false,
        restart_managed: false,
        control_plane_first: false,
        verify: true,
        dirty: DirtyForwarding::Clean,
    })
    .unwrap();
    assert_eq!(clean.argv, ["clean", "--no-override", "--clean", "all"]);
}

#[test]
fn installed_rust_binary_remains_authoritative_inside_checked_out_worktree() {
    let worktree = Path::new("/run/nixbot/repo");
    let installed = InstalledBinary::new("/nix/store/manager/bin/nixbot").unwrap();
    let plan = plan_installed_execution(
        &installed,
        worktree,
        &["deploy".to_owned(), "--host".to_owned(), "app".to_owned()],
    )
    .unwrap();
    assert_eq!(plan.program, Path::new("/nix/store/manager/bin/nixbot"));
    assert_eq!(plan.current_dir.as_deref(), Some(worktree));
    assert_ne!(
        plan.program,
        worktree.join("bin/nixbot"),
        "a checkout-local binary must never silently replace installed authority"
    );

    let repo_local = InstalledBinary::new("/run/nixbot/repo/bin/nixbot").unwrap();
    assert!(plan_installed_execution(&repo_local, worktree, &[]).is_err());
    assert!(InstalledBinary::new("relative/bin/nixbot").is_err());
    assert!(
        plan_installed_execution(&installed, Path::new("/run/nixbot/../nixbot/repo"), &[]).is_err()
    );
}

#[test]
fn ci_dispatch_preserves_exact_required_hosts_and_rejects_patterns() {
    let mut request = deploy_trigger();
    request.required_hosts = vec!["app".to_owned(), "db".to_owned()];
    let plan = plan_ci_trigger(&request).unwrap();
    let forwarded = decode_argv(&plan.encoded_argv).unwrap();
    assert!(
        forwarded
            .windows(2)
            .any(|pair| pair == ["--require-hosts", "app,db"])
    );
    for host in ["", "-app", "app-*", "app;id"] {
        request.required_hosts = vec![host.to_owned()];
        assert!(plan_ci_trigger(&request).is_err(), "{host}");
    }
}
