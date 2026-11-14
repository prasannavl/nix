use super::*;
use std::collections::VecDeque;
use std::ffi::OsString;

use crate::fleet::repository::{CommandOutput, CommandRequest, ObjectId, ObjectLimits};

fn intent(bytes: Option<&[u8]>) -> Source {
    Source {
        revision: "a".repeat(40),
        base_revision: "a".repeat(40),
        tree_digest: Some("c".repeat(64)),
        patch_digest: bytes.map(|p| format!("{:x}", Sha256::digest(p))),
    }
}
fn patch(bytes: &[u8]) -> StagedPatch {
    StagedPatch {
        base: CommitSha::parse("a".repeat(40)).unwrap(),
        bytes: bytes.into(),
    }
}

#[test]
fn exact_binary_artifact_and_all_intent_claims_are_frozen_without_tree_proof() {
    let bytes = b"binary\0patch\xff";
    let mut source = intent(Some(bytes));
    let recipe = SourceRecipe::bind(&source, Some(patch(bytes))).unwrap();
    source.revision = "b".repeat(40);
    source.tree_digest = None;
    assert_eq!(recipe.intent().revision, "a".repeat(40));
    assert_eq!(
        recipe.intent().tree_digest.as_deref(),
        Some("c".repeat(64).as_str())
    );
    assert_eq!(recipe.patch.as_ref().unwrap().bytes, bytes);
}

#[test]
fn missing_extra_changed_or_wrong_base_artifacts_are_not_reinterpreted() {
    let source = intent(Some(b"expected"));
    assert!(SourceRecipe::bind(&source, None).is_err());
    assert!(SourceRecipe::bind(&intent(None), Some(patch(b"extra"))).is_err());
    assert!(SourceRecipe::bind(&source, Some(patch(b"changed"))).is_err());
    let mut wrong = patch(b"expected");
    wrong.base = CommitSha::parse("b".repeat(40)).unwrap();
    assert!(SourceRecipe::bind(&source, Some(wrong)).is_err());
    let mut mismatch = source;
    mismatch.revision = "b".repeat(40);
    assert!(SourceRecipe::bind(&mismatch, Some(patch(b"expected"))).is_err());
}

#[test]
fn metadata_shape_and_current_native_hash_capability_reject_before_repository_work() {
    let mut source = intent(None);
    source.revision = "main".into();
    assert!(SourceRecipe::bind(&source, None).is_err());
    source = intent(None);
    source.base_revision = "A".repeat(40);
    assert!(SourceRecipe::bind(&source, None).is_err());
    source = intent(None);
    source.tree_digest = Some("private".into());
    assert!(SourceRecipe::bind(&source, None).is_err());
    source = intent(None);
    source.patch_digest = Some("invalid".into());
    assert!(SourceRecipe::bind(&source, None).is_err());
    source = intent(None);
    source.revision = "a".repeat(64);
    source.base_revision = "a".repeat(64);
    assert!(source.validate().is_ok());
    assert!(
        SourceRecipe::bind(&source, None)
            .err()
            .unwrap()
            .to_string()
            .contains("SHA-1 revisions only")
    );
}

#[test]
fn absence_and_explicit_empty_patch_remain_distinct_and_patch_bytes_are_bounded() {
    assert!(SourceRecipe::bind(&intent(None), None).is_ok());
    assert!(SourceRecipe::bind(&intent(Some(b"")), Some(patch(b""))).is_ok());
    assert!(SourceRecipe::bind(&intent(Some(b"")), None).is_err());
    let bytes = vec![b'x'; MAX_PATCH_BYTES];
    assert!(SourceRecipe::bind(&intent(Some(&bytes)), Some(patch(&bytes))).is_ok());
    let oversized = vec![b'x'; MAX_PATCH_BYTES + 1];
    assert!(
        SourceRecipe::bind(&intent(Some(&oversized)), Some(patch(&oversized)))
            .err()
            .unwrap()
            .to_string()
            .contains("exceeds bound")
    );
}

#[test]
fn caller_checkout_reuses_exact_commit_and_patch_without_ref_resolution_or_clone() {
    let temporary = tempfile::tempdir().unwrap();
    let target = temporary.path().join("repo");
    let bytes = b"opaque selected patch";
    let recipe = SourceRecipe::bind(&intent(Some(bytes)), Some(patch(bytes))).unwrap();
    let mut repository = RepositoryManager::new(
        "/installed/git",
        Fake {
            replies: vec![output(0, b""), output(0, b""), output(0, b"")].into(),
            requests: vec![],
        },
    );
    let view = recipe
        .caller_checkout(&mut repository, Path::new("/original/source"), &target)
        .unwrap();
    assert_eq!(view.commit.as_str(), "a".repeat(40));
    let requests = &repository.runner().requests;
    assert_eq!(requests.len(), 3);
    assert_eq!(
        requests[0].args,
        vec![
            OsString::from("worktree"),
            "add".into(),
            "--detach".into(),
            target.as_os_str().to_owned(),
            "a".repeat(40).into()
        ]
    );
    assert_eq!(
        requests[0].current_dir.as_deref(),
        Some(Path::new("/original/source"))
    );
    assert_eq!(
        requests[1].args,
        vec![OsString::from("worktree"), "prune".into()]
    );
    assert_eq!(requests[2].current_dir.as_deref(), Some(target.as_path()));
    assert!(requests[2].args.iter().any(|arg| arg == "apply"));
    assert!(requests[2].args.iter().any(|arg| arg == "--index"));
    assert_eq!(requests[2].stdin.as_deref(), Some(bytes.as_slice()));
}

#[test]
fn failed_caller_checkout_never_reselects_reclones_or_cleans_unsettled_data() {
    let temporary = tempfile::tempdir().unwrap();
    let target = temporary.path().join("repo");
    let recipe = SourceRecipe::bind(&intent(None), None).unwrap();
    let mut repository = RepositoryManager::new(
        "/installed/git",
        Fake {
            replies: vec![output(1, b"")].into(),
            requests: vec![],
        },
    );
    assert!(
        recipe
            .caller_checkout(&mut repository, Path::new("/original/source"), &target)
            .is_err()
    );
    assert_eq!(repository.runner().requests.len(), 1);
    assert_eq!(repository.runner().requests[0].args[0], "worktree");
    assert_eq!(repository.runner().requests[0].args[1], "add");
}

struct Fake {
    replies: VecDeque<CommandOutput>,
    requests: Vec<CommandRequest>,
}
impl CommandRunner for Fake {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput> {
        self.requests.push(request.clone());
        let output = self.replies.pop_front().expect("unexpected operation");
        if output.status == 0 && request.args.starts_with(&["worktree".into(), "add".into()]) {
            // Model only directory creation, not Git metadata or checkout bytes.
            std::fs::create_dir_all(Path::new(&request.args[3]))?;
        }
        Ok(output)
    }
}
fn output(status: i32, bytes: &[u8]) -> CommandOutput {
    CommandOutput {
        status,
        stdout: bytes.into(),
        stderr: Vec::new(),
    }
}
fn observed(id: &str) -> TreeInventory {
    let mut repository = RepositoryManager::new(
        "/installed/git",
        Fake {
            replies: vec![output(0, b""), output(0, format!("{id}\n").as_bytes())].into(),
            requests: Vec::new(),
        },
    );
    repository
        .observe_tree(
            Path::new("/repo"),
            &ObjectId::parse(id).unwrap(),
            ObjectLimits {
                entries: 1,
                bytes: 0,
                depth: 1,
                path_bytes: 0,
            },
        )
        .unwrap()
}
fn manager(resolved: &str, apply_status: i32) -> RepositoryManager<Fake> {
    manager_with_index(resolved, apply_status, b"")
}
fn manager_with_index(resolved: &str, apply_status: i32, index: &[u8]) -> RepositoryManager<Fake> {
    RepositoryManager::new(
        "/installed/git",
        Fake {
            replies: vec![
                output(
                    0,
                    format!("tree {}\n\nprivate commit bytes", "c".repeat(40)).as_bytes(),
                ),
                output(0, format!("{}\n", "a".repeat(40)).as_bytes()),
                output(0, b""),
                output(0, format!("{}\n", "c".repeat(40)).as_bytes()),
                output(0, resolved.as_bytes()),
                output(0, resolved.as_bytes()),
                output(0, resolved.as_bytes()),
                output(0, b""),
                output(0, b""),
                output(0, index),
                output(apply_status, b""),
            ]
            .into(),
            requests: Vec::new(),
        },
    )
}

#[test]
fn native_worktree_uses_exact_intent_and_existing_binary_patch_operations() {
    for bytes in [None, Some(b"binary\0patch\xff".as_slice())] {
        let source = intent(bytes);
        let recipe = SourceRecipe::bind(&source, bytes.map(patch)).unwrap();
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("native");
        let mut manager = manager(&source.revision, 0);
        let view = recipe
            .native_worktree(
                &mut manager,
                root.path(),
                &target,
                &observed(&"c".repeat(40)),
            )
            .unwrap();
        assert_eq!(view.commit.as_str(), source.revision);
        assert_eq!(view.path, target);
        let requests = &manager.runner().requests;
        assert_eq!(requests.len(), if bytes.is_some() { 11 } else { 10 });
        assert_eq!(requests[9].args[0], "ls-files");
        assert_eq!(requests[9].current_dir.as_deref(), Some(target.as_path()));
        for request in &requests[4..7] {
            assert_eq!(
                request.args,
                [
                    "rev-parse",
                    "--verify",
                    &format!("{}^{{commit}}", source.revision)
                ]
                .map(OsString::from)
            );
        }
        assert_eq!(requests[7].args.last().unwrap(), source.revision.as_str());
        if let Some(bytes) = bytes {
            assert_eq!(
                requests[10].args,
                ["apply", "--index", "--binary", "--allow-empty", "-"].map(OsString::from)
            );
            assert_eq!(requests[10].stdin.as_deref(), Some(bytes));
        }
    }
}

#[test]
fn resolved_identity_mismatch_rejects_before_worktree_filesystem_effects() {
    for bytes in [None, Some(b"patch".as_slice())] {
        let recipe = SourceRecipe::bind(&intent(bytes), bytes.map(patch)).unwrap();
        let root = tempfile::tempdir().unwrap();
        let parent = root.path().join("new-parent");
        let mut manager = manager(&"b".repeat(40), 0);
        assert!(
            recipe
                .native_worktree(
                    &mut manager,
                    root.path(),
                    &parent.join("view"),
                    &observed(&"c".repeat(40))
                )
                .is_err()
        );
        assert_eq!(manager.runner().requests.len(), 6);
        assert!(!parent.exists());
    }
}

#[test]
fn observed_patch_failure_does_not_retry_or_return_a_source_result() {
    let source = intent(Some(b"patch"));
    let recipe = SourceRecipe::bind(&source, Some(patch(b"patch"))).unwrap();
    let root = tempfile::tempdir().unwrap();
    let mut manager = manager(&source.revision, 1);
    assert!(
        recipe
            .native_worktree(
                &mut manager,
                root.path(),
                &root.path().join("view"),
                &observed(&"c".repeat(40))
            )
            .is_err()
    );
    assert_eq!(manager.runner().requests.len(), 11);
}

#[test]
fn foreign_observed_root_rejects_before_worktree_effects() {
    let recipe = SourceRecipe::bind(&intent(None), None).unwrap();
    let root = tempfile::tempdir().unwrap();
    let target = root.path().join("new-parent/view");
    let mut repository = manager(&"a".repeat(40), 0);
    let error = recipe
        .native_worktree(
            &mut repository,
            root.path(),
            &target,
            &observed(&"d".repeat(40)),
        )
        .err()
        .unwrap();
    assert!(
        error
            .to_string()
            .contains("observed source tree differs from intent")
    );
    assert_eq!(repository.runner().requests.len(), 2);
    assert!(!target.parent().unwrap().exists());
}

#[test]
fn differing_base_index_rejects_after_creation_without_patch_retry_or_cleanup() {
    for bytes in [None, Some(b"patch".as_slice())] {
        let recipe = SourceRecipe::bind(&intent(bytes), bytes.map(patch)).unwrap();
        let root = tempfile::tempdir().unwrap();
        let target = root.path().join("new-parent/view");
        let index = format!("H 100644 {} 0\tPRIVATE-INDEX\0", "a".repeat(40));
        let mut repository = manager_with_index(&"a".repeat(40), 0, index.as_bytes());
        let error = recipe
            .native_worktree(
                &mut repository,
                root.path(),
                &target,
                &observed(&"c".repeat(40)),
            )
            .err()
            .unwrap();
        assert_eq!(
            error.to_string(),
            "native base index differs from observed tree"
        );
        let requests = &repository.runner().requests;
        assert_eq!(requests.len(), 10);
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
        assert!(target.is_dir());
    }
}

#[test]
fn differing_root_tree_content_rejects_before_worktree_effects() {
    let recipe = SourceRecipe::bind(&intent(None), None).unwrap();
    let root = tempfile::tempdir().unwrap();
    let target = root.path().join("new-parent/view");
    let mut manager = RepositoryManager::new(
        "/installed/git",
        Fake {
            replies: vec![
                output(0, format!("tree {}\n\nprivate", "c".repeat(40)).as_bytes()),
                output(0, format!("{}\n", "a".repeat(40)).as_bytes()),
                output(0, b""),
                output(0, format!("{}\n", "d".repeat(40)).as_bytes()),
            ]
            .into(),
            requests: Vec::new(),
        },
    );
    let error = recipe
        .native_worktree(
            &mut manager,
            root.path(),
            &target,
            &observed(&"c".repeat(40)),
        )
        .err()
        .unwrap();
    assert!(error.to_string().contains("native tree content differs"));
    assert_eq!(manager.runner().requests.len(), 4);
    assert!(!target.parent().unwrap().exists());
}

#[test]
fn differing_native_commit_content_rejects_before_worktree_effects() {
    let recipe = SourceRecipe::bind(&intent(None), None).unwrap();
    let root = tempfile::tempdir().unwrap();
    let target = root.path().join("new-parent/view");
    let mut manager = RepositoryManager::new(
        "/installed/git",
        Fake {
            replies: vec![
                output(0, b"changed commit"),
                output(0, format!("{}\n", "b".repeat(40)).as_bytes()),
            ]
            .into(),
            requests: Vec::new(),
        },
    );
    let error = recipe
        .native_worktree(
            &mut manager,
            root.path(),
            &target,
            &observed(&"c".repeat(40)),
        )
        .err()
        .unwrap();
    assert!(
        error
            .to_string()
            .contains("content differs from requested identity")
    );
    assert_eq!(manager.runner().requests.len(), 2);
    assert!(!target.parent().unwrap().exists());
}
