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
use anyhow::Result;

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
    run(Command::new("git").arg("-C").arg(repo).args(args))
}

fn init_repo(path: &Path) -> String {
    run(Command::new("git").args(["init", "-q"]).arg(path));
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
    run(Command::new("git")
        .args(["init", "-q", "--bare"])
        .arg(&remote));
    let first = init_repo(&seed);
    git(
        &seed,
        &["remote", "add", "origin", remote.to_str().unwrap()],
    );
    git(&seed, &["push", "-q", "origin", "HEAD:main"]);
    run(Command::new("git").arg("-C").arg(&remote).args([
        "symbolic-ref",
        "HEAD",
        "refs/heads/main",
    ]));

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
    run(Command::new("git")
        .args(["init", "-q", "--bare"])
        .arg(&wrong));
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
    let symbolic = Command::new("git")
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
fn repository_git_transport_is_strict_and_propagated_to_every_git_request() {
    let temporary = tempfile::tempdir().unwrap();
    let known_hosts = temporary.path().join("known hosts");
    let identity = temporary.path().join("identity's key");
    fs::write(&known_hosts, "git.example ssh-ed25519 AAAA\n").unwrap();
    fs::write(&identity, "fixture\n").unwrap();
    let command = repo_git_ssh_command(&known_hosts, std::slice::from_ref(&identity)).unwrap();
    assert!(command.contains("StrictHostKeyChecking=yes"));
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
        sha: Some(CommitSha::parse("abcdef0").unwrap()),
        clean_mode: CiCleanMode::Auto,
        group: Some("prod".to_owned()),
        hosts: None,
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
        sha: None,
        clean_mode: CiCleanMode::All,
        group: None,
        hosts: None,
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
