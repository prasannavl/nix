use std::fs;
use std::path::Path;
use std::process::Command;

use abird_host_manager::fleet::repository::{
    CommitSha, ManagedRepository, ProcessCommandRunner, RepositoryManager, StagedPatch,
};
use abird_host_manager::fleet::source_identity::SourceIdentity;
use abird_host_manager::fleet::workspace::{
    ExecutionWorkspaceRequest, cleanup_execution_workspace, prepare_execution_workspace,
};
use abird_host_manager::programs::clear_git_repository_environment;

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

fn git(root: &Path, args: &[&str]) -> String {
    run(git_command().arg("-C").arg(root).args(args))
}

fn init_repo(root: &Path) -> String {
    run(git_command().args(["init", "-q"]).arg(root));
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
    let identity = SourceIdentity::execution(Path::new("git"), &workspace).unwrap();
    assert_eq!(
        identity.display(),
        git(&workspace.root, &["rev-parse", "--short=8", "HEAD"])
    );
    assert!(identity.diagnostic().contains(&head));
    assert_eq!(workspace.root, execution);
    assert!(workspace.owned);
    assert_eq!(git(&workspace.root, &["rev-parse", "HEAD"]), head);
    assert!(
        !git_command()
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
    let patch = git_command()
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
    let identity = SourceIdentity::execution(Path::new("git"), &workspace).unwrap();
    assert!(identity.display().contains(" + staged:"));
    assert!(identity.diagnostic().contains("staged patch sha256:"));
    assert!(identity.diagnostic().contains(&head));
    // The caller's index may change after capture; it cannot relabel this run.
    fs::write(source.join("state"), "later caller edit\n").unwrap();
    git(&source, &["add", "state"]);
    assert_eq!(
        SourceIdentity::execution(Path::new("git"), &workspace).unwrap(),
        identity
    );
    // Inherited re-exec reads the already-applied index, not caller patch bytes.
    let inherited = prepare_execution_workspace(
        &mut manager,
        &ExecutionWorkspaceRequest {
            source_root: source.clone(),
            execution_root: workspace.root.clone(),
            target: Some(head.clone()),
            managed: None,
            allow_dirty: true,
            staged_patch: None,
            inherited: true,
        },
    )
    .unwrap();
    assert_eq!(
        SourceIdentity::execution(Path::new("git"), &inherited).unwrap(),
        identity
    );
    cleanup_execution_workspace(&mut manager, &inherited).unwrap();
    assert!(workspace.root.exists());
    fs::write(workspace.root.join("state"), "different executed patch\n").unwrap();
    git(&workspace.root, &["add", "state"]);
    assert_ne!(
        SourceIdentity::execution(Path::new("git"), &workspace).unwrap(),
        identity
    );
    cleanup_execution_workspace(&mut manager, &workspace).unwrap();
    git(&source, &["restore", "--staged", "state"]);
    fs::write(source.join("state"), "one\n").unwrap();

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
    let mut manager = RepositoryManager::new("git", ProcessCommandRunner);
    manager
        .create_detached_worktree(&source, &execution, &head)
        .unwrap();
    fs::write(execution.join("sentinel"), "keep\n").unwrap();

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
    manager
        .remove_worktree(&workspace.source_root, &execution)
        .unwrap();
}

#[test]
fn dirty_permission_does_not_claim_unconsumed_caller_edits() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let head = init_repo(&source);
    fs::write(source.join("state"), "unconsumed\n").unwrap();
    git(&source, &["add", "state"]);
    let mut manager = RepositoryManager::new("git", ProcessCommandRunner);
    let workspace = prepare_execution_workspace(
        &mut manager,
        &ExecutionWorkspaceRequest {
            source_root: source,
            execution_root: temp.path().join("execution"),
            target: None,
            managed: None,
            allow_dirty: true,
            staged_patch: None,
            inherited: false,
        },
    )
    .unwrap();
    let identity = SourceIdentity::execution(Path::new("git"), &workspace).unwrap();
    assert!(!identity.display().contains("dirty"));
    assert!(identity.diagnostic().contains(&head));
    assert_eq!(
        fs::read_to_string(workspace.root.join("state")).unwrap(),
        "one\n"
    );
    cleanup_execution_workspace(&mut manager, &workspace).unwrap();
}

#[test]
fn exact_target_identity_is_not_recomputed_from_newer_caller_head() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("source");
    let first = init_repo(&source);
    fs::write(source.join("state"), "new head\n").unwrap();
    git(&source, &["add", "state"]);
    git(&source, &["commit", "-qm", "two"]);
    let mut manager = RepositoryManager::new("git", ProcessCommandRunner);
    let workspace = prepare_execution_workspace(
        &mut manager,
        &ExecutionWorkspaceRequest {
            source_root: source.clone(),
            execution_root: temp.path().join("execution"),
            target: Some(first.clone()),
            managed: None,
            allow_dirty: false,
            staged_patch: None,
            inherited: false,
        },
    )
    .unwrap();
    let identity = SourceIdentity::execution(Path::new("git"), &workspace).unwrap();
    assert_eq!(
        identity.display(),
        git(&source, &["rev-parse", "--short=8", &first])
    );
    assert!(identity.diagnostic().contains(&first));
    assert!(
        !identity
            .diagnostic()
            .contains(&git(&source, &["rev-parse", "HEAD"]))
    );
    fs::write(workspace.root.join("state"), "unexpected mutation\n").unwrap();
    assert!(SourceIdentity::execution(Path::new("git"), &workspace).is_err());
    cleanup_execution_workspace(&mut manager, &workspace).unwrap();
}

#[test]
fn development_identity_is_always_labelled_mutable() {
    let temp = tempfile::tempdir().unwrap();
    let head = init_repo(temp.path());
    let clean = SourceIdentity::development(Path::new("git"), temp.path()).unwrap();
    assert!(clean.display().starts_with("mutable "));
    assert!(!clean.display().contains("dirty"));
    assert!(clean.diagnostic().contains(&head));
    assert!(clean.diagnostic().contains("no immutable source identity"));
    fs::write(temp.path().join("state"), "live edits\n").unwrap();
    let dirty = SourceIdentity::development(Path::new("git"), temp.path()).unwrap();
    assert!(dirty.display().starts_with("mutable "));
    assert!(dirty.display().ends_with("-dirty"));
}

#[test]
fn managed_request_uses_declared_repository_contract_before_worktree_creation() {
    let temp = tempfile::tempdir().unwrap();
    let seed = temp.path().join("seed");
    let remote = temp.path().join("remote.git");
    let mirror = temp.path().join("mirror");
    let execution = temp.path().join("run/repo");
    let head = init_repo(&seed);
    run(git_command().args(["init", "-q", "--bare"]).arg(&remote));
    git(
        &seed,
        &["remote", "add", "origin", remote.to_str().unwrap()],
    );
    git(&seed, &["push", "-q", "origin", "HEAD:master"]);
    run(git_command()
        .arg("-C")
        .arg(&remote)
        .args(["symbolic-ref", "HEAD", "refs/heads/master"]));
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
