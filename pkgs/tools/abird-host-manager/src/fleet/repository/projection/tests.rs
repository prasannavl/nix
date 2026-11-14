use std::collections::VecDeque;

use super::*;
use crate::fleet::repository::{CommandOutput, CommandRequest, ObjectLimits};

#[derive(Default)]
struct Fake {
    replies: VecDeque<Result<CommandOutput>>,
    requests: Vec<CommandRequest>,
}
impl CommandRunner for Fake {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput> {
        self.requests.push(request.clone());
        self.replies.pop_front().expect("unexpected helper")
    }
}
fn id(n: u8) -> ObjectId {
    ObjectId::parse(format!("{n:02x}").repeat(20)).unwrap()
}
fn ok(bytes: impl Into<Vec<u8>>) -> Result<CommandOutput> {
    Ok(CommandOutput {
        status: 0,
        stdout: bytes.into(),
        stderr: Vec::new(),
    })
}
fn failed() -> Result<CommandOutput> {
    Ok(CommandOutput {
        status: 128,
        stdout: Vec::new(),
        stderr: b"PRIVATE-PROJECTION".to_vec(),
    })
}
fn manager(replies: Vec<Result<CommandOutput>>) -> RepositoryManager<Fake> {
    RepositoryManager::new(
        "/installed/git",
        Fake {
            replies: replies.into(),
            ..Fake::default()
        },
    )
}
fn inventory(mode: &[u8], path: &[u8]) -> TreeInventory {
    let root = [mode, b" ", path, b"\0", &[2; 20]].concat();
    manager(vec![
        ok(root),
        ok(format!("{}\n", id(1).as_str())),
        ok(Vec::new()),
        ok(format!("{}\n", id(2).as_str())),
    ])
    .observe_tree(
        Path::new("/repo"),
        &id(1),
        ObjectLimits {
            entries: 2,
            bytes: 4096,
            depth: 2,
            path_bytes: 4096,
        },
    )
    .unwrap()
}

#[test]
fn regular_and_executable_preserve_binary_path_arguments_and_filter_output() {
    let path = b"-private\t\n\xff";
    for (mode, kind) in [
        (b"100644".as_slice(), TreeKind::File),
        (b"100755".as_slice(), TreeKind::Executable),
    ] {
        let tree = inventory(mode, path);
        let raw = b"canonical\0\xff\n";
        let bytes = b"filtered\0\xff\r\n";
        let mut manager = manager(vec![
            ok(raw),
            ok(format!("{}\n", id(2).as_str())),
            ok(bytes),
        ]);
        let projected = manager
            .checkout_projection(Path::new("/repo"), &tree, path)
            .unwrap();
        assert_eq!(projected.path(), path);
        assert_eq!(projected.object().as_str(), id(2).as_str());
        assert!(projected.kind() == kind);
        assert_eq!(projected.bytes(), bytes);
        let requests = &manager.runner.requests;
        assert_eq!(requests.len(), 3);
        for request in requests {
            assert_eq!(request.program.as_path(), Path::new("/installed/git"));
            assert_eq!(request.current_dir.as_deref(), Some(Path::new("/repo")));
            assert!(request.environment.is_empty());
        }
        assert_eq!(requests[0].args, ["cat-file", "blob", id(2).as_str()]);
        assert_eq!(
            requests[1].args,
            ["hash-object", "--no-filters", "-t", "blob", "--stdin"]
        );
        assert_eq!(requests[1].stdin.as_deref(), Some(raw.as_slice()));
        assert_eq!(
            requests[2].args,
            [
                OsString::from("cat-file"),
                OsString::from("--filters"),
                OsString::from_vec([b"--path=", path.as_slice()].concat()),
                OsString::from(id(2).as_str()),
            ]
        );
        assert!(requests[0].stdin.is_none() && requests[2].stdin.is_none());
    }
}

#[test]
fn symlink_returns_raw_target_without_filtering_or_following_it() {
    let tree = inventory(b"120000", b"link.txt");
    let target = b"../../outside\n";
    let mut manager = manager(vec![ok(target), ok(format!("{}\n", id(2).as_str()))]);
    let projected = manager
        .checkout_projection(Path::new("/repo"), &tree, b"link.txt")
        .unwrap();
    assert!(projected.kind() == TreeKind::Symlink);
    assert_eq!(projected.bytes(), target);
    assert_eq!(manager.runner.requests.len(), 2);
}

#[test]
fn absent_aliased_or_directory_paths_reject_before_helpers() {
    let tree = inventory(b"40000", b"dir");
    for path in [
        b"dir".as_slice(),
        b"/dir",
        b"./dir",
        b"dir/",
        b"dir/../dir",
        b".git",
        b"absent",
        b"dir\0",
    ] {
        let mut manager = manager(Vec::new());
        assert!(
            manager
                .checkout_projection(Path::new("/repo"), &tree, path)
                .is_err()
        );
        assert!(manager.runner.requests.is_empty());
    }
}

#[test]
fn raw_capture_hash_and_identity_failures_prevent_filter_execution() {
    let tree = inventory(b"100644", b"file");
    for replies in [
        vec![failed()],
        vec![ok(b"raw"), failed()],
        vec![ok(b"raw"), ok(format!("{}\n", id(3).as_str()))],
        vec![Err(anyhow::anyhow!("capture uncertain"))],
    ] {
        let count = replies.len();
        let mut manager = manager(replies);
        let error = manager
            .checkout_projection(Path::new("/repo"), &tree, b"file")
            .err()
            .unwrap();
        assert!(!error.to_string().contains("PRIVATE-PROJECTION"));
        assert_eq!(manager.runner.requests.len(), count);
        assert!(manager.runner.replies.is_empty());
    }
}

#[test]
fn filter_failure_or_uncertainty_has_no_partial_value_stderr_disclosure_or_retry() {
    let tree = inventory(b"100644", b"file");
    for outcome in [failed(), Err(anyhow::anyhow!("filter uncertain"))] {
        let mut manager = manager(vec![
            ok(b"raw"),
            ok(format!("{}\n", id(2).as_str())),
            outcome,
        ]);
        let error = manager
            .checkout_projection(Path::new("/repo"), &tree, b"file")
            .err()
            .unwrap();
        assert!(!error.to_string().contains("PRIVATE-PROJECTION"));
        assert_eq!(manager.runner.requests.len(), 3);
        assert!(manager.runner.replies.is_empty());
    }
}

#[test]
fn projected_byte_ceiling_includes_exact_limit_and_empty_but_does_not_bound_capture() {
    let tree = inventory(b"100644", b"file");
    for size in [0, MAX_BLOB_BYTES, MAX_BLOB_BYTES + 1] {
        let mut manager = manager(vec![
            ok(Vec::new()),
            ok(format!("{}\n", id(2).as_str())),
            ok(vec![b'x'; size]),
        ]);
        let result = manager.checkout_projection(Path::new("/repo"), &tree, b"file");
        if size <= MAX_BLOB_BYTES {
            assert_eq!(result.unwrap().bytes().len(), size);
        } else {
            assert_eq!(
                result.err().unwrap().to_string(),
                "native checkout projection exceeds bound"
            );
        }
        assert_eq!(manager.runner.requests.len(), 3);
    }
}
