use std::fs;
use std::path::Path;
use std::process::Command;

use abird_host_manager::fleet::repository::{
    CommitSha, ManagedRepository, ProcessCommandRunner, RepositoryManager, StagedPatch,
};
use abird_host_manager::fleet::workspace::{
    ExecutionWorkspaceRequest, cleanup_execution_workspace, prepare_execution_workspace,
};

fn run(command: &mut Command) -> String {
    let output = command.output().unwrap();
    assert!(
        output.status.success(),
        "command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

fn git(root: &Path, args: &[&str]) -> String {
    run(Command::new("git").arg("-C").arg(root).args(args))
}

fn init_repo(root: &Path) -> String {
    run(Command::new("git").args(["init", "-q"]).arg(root));
    git(root, &["config", "user.name", "Fleet Test"]);
    git(root, &["config", "user.email", "fleet@example.invalid"]);
    git(root, &["config", "commit.gpgsign", "false"]);
    fs::write(root.join("state"), "one\n").unwrap();
    git(root, &["add", "state"]);
    git(root, &["commit", "-qm", "one"]);
    git(root, &["rev-parse", "HEAD"])
}

#[test]
fn local_execution_uses_an_isolated_detached_worktree_and_cleans_it() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let execution = temp.path().join("run/repo");
    let head = init_repo(&source);
    let mut manager = RepositoryManager::new("git", ProcessCommandRunner);

    let workspace = prepare_execution_workspace(
        &mut manager,
        &ExecutionWorkspaceRequest {
            source_root: source.clone(),
            execution_root: execution.clone(),
            target: None,
            managed: None,
            allow_dirty: false,
            staged_patch: None,
            inherited: false,
        },
    )
    .unwrap();

    assert_eq!(workspace.commit.as_str(), head);
    assert_eq!(workspace.root, execution);
    assert!(workspace.owned);
    assert_eq!(git(&workspace.root, &["rev-parse", "HEAD"]), head);
    assert!(
        !Command::new("git")
            .arg("-C")
            .arg(&workspace.root)
            .args(["symbolic-ref", "--quiet", "HEAD"])
            .status()
            .unwrap()
            .success()
    );

    cleanup_execution_workspace(&mut manager, &workspace).unwrap();
    assert!(!execution.exists());
    assert_eq!(git(&source, &["rev-parse", "HEAD"]), head);
}

#[test]
fn staged_patch_is_applied_only_inside_execution_tree_and_base_is_checked() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let execution = temp.path().join("run/repo");
    let head = init_repo(&source);
    fs::write(source.join("state"), "two\n").unwrap();
    git(&source, &["add", "state"]);
    let patch = Command::new("git")
        .arg("-C")
        .arg(&source)
        .args(["diff", "--cached", "--binary", "--full-index"])
        .output()
        .unwrap()
        .stdout;
    git(&source, &["restore", "--staged", "state"]);
    fs::write(source.join("state"), "one\n").unwrap();
    let mut manager = RepositoryManager::new("git", ProcessCommandRunner);

    let workspace = prepare_execution_workspace(
        &mut manager,
        &ExecutionWorkspaceRequest {
            source_root: source.clone(),
            execution_root: execution,
            target: Some(head.clone()),
            managed: None,
            allow_dirty: false,
            staged_patch: Some(StagedPatch {
                base: CommitSha::parse(head.clone()).unwrap(),
                bytes: patch,
            }),
            inherited: false,
        },
    )
    .unwrap();
    assert_eq!(
        fs::read_to_string(workspace.root.join("state")).unwrap(),
        "two\n"
    );
    assert_eq!(fs::read_to_string(source.join("state")).unwrap(), "one\n");
    cleanup_execution_workspace(&mut manager, &workspace).unwrap();

    let error = prepare_execution_workspace(
        &mut manager,
        &ExecutionWorkspaceRequest {
            source_root: source,
            execution_root: temp.path().join("bad/repo"),
            target: Some(head),
            managed: None,
            allow_dirty: false,
            staged_patch: Some(StagedPatch {
                base: CommitSha::parse("deadbee").unwrap(),
                bytes: b"not used".to_vec(),
            }),
            inherited: false,
        },
    )
    .unwrap_err()
    .to_string();
    assert!(error.contains("does not match"), "{error}");
}

#[test]
fn inherited_execution_tree_is_never_removed_or_resynchronized() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let execution = temp.path().join("inherited");
    let head = init_repo(&source);
    fs::create_dir_all(&execution).unwrap();
    fs::write(execution.join("sentinel"), "keep\n").unwrap();
    let mut manager = RepositoryManager::new("git", ProcessCommandRunner);

    let workspace = prepare_execution_workspace(
        &mut manager,
        &ExecutionWorkspaceRequest {
            source_root: source,
            execution_root: execution.clone(),
            target: Some(head.clone()),
            managed: None,
            allow_dirty: false,
            staged_patch: None,
            inherited: true,
        },
    )
    .unwrap();
    assert!(!workspace.owned);
    assert_eq!(workspace.commit.as_str(), head);
    cleanup_execution_workspace(&mut manager, &workspace).unwrap();
    assert_eq!(
        fs::read_to_string(execution.join("sentinel")).unwrap(),
        "keep\n"
    );
}

#[test]
fn managed_request_uses_declared_repository_contract_before_worktree_creation() {
    let temp = tempfile::tempdir().unwrap();
    let seed = temp.path().join("seed");
    let remote = temp.path().join("remote.git");
    let mirror = temp.path().join("mirror");
    let execution = temp.path().join("run/repo");
    let head = init_repo(&seed);
    run(Command::new("git")
        .args(["init", "-q", "--bare"])
        .arg(&remote));
    git(
        &seed,
        &["remote", "add", "origin", remote.to_str().unwrap()],
    );
    git(&seed, &["push", "-q", "origin", "HEAD:master"]);
    run(Command::new("git").arg("-C").arg(&remote).args([
        "symbolic-ref",
        "HEAD",
        "refs/heads/master",
    ]));
    let mut manager = RepositoryManager::new("git", ProcessCommandRunner);

    let workspace = prepare_execution_workspace(
        &mut manager,
        &ExecutionWorkspaceRequest {
            source_root: mirror.clone(),
            execution_root: execution,
            target: None,
            managed: Some(ManagedRepository {
                root: mirror.clone(),
                url: remote.to_string_lossy().into_owned(),
                allow_dirty: false,
            }),
            allow_dirty: false,
            staged_patch: None,
            inherited: false,
        },
    )
    .unwrap();
    assert_eq!(workspace.commit.as_str(), head);
    assert_eq!(
        git(&mirror, &["remote", "get-url", "origin"]),
        remote.to_string_lossy()
    );
    cleanup_execution_workspace(&mut manager, &workspace).unwrap();
}
