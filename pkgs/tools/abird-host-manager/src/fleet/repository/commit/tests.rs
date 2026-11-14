use super::super::object::MAX_COMMIT_BYTES as MAX_BYTES;
use super::*;
use std::collections::VecDeque;
use std::ffi::OsString;

use crate::fleet::repository::{CommandOutput, CommandRequest};

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
fn reply(status: i32, bytes: &[u8]) -> Result<CommandOutput> {
    Ok(CommandOutput {
        status,
        stdout: bytes.into(),
        stderr: b"PRIVATE-COMMIT".to_vec(),
    })
}
fn manager(replies: Vec<Result<CommandOutput>>) -> RepositoryManager<Fake> {
    RepositoryManager::new(
        "/installed/git",
        Fake {
            replies: replies.into(),
            requests: Vec::new(),
        },
    )
}
fn revision() -> CommitSha {
    CommitSha::parse("a".repeat(40)).unwrap()
}
fn hash() -> Vec<u8> {
    format!("{}\n", revision().as_str()).into_bytes()
}
fn error(manager: &mut RepositoryManager<Fake>) -> String {
    let result = manager
        .commit_object(Path::new("/repo"), &revision())
        .err()
        .unwrap();
    let text = format!("{result:#}");
    assert!(!text.contains("PRIVATE-COMMIT"));
    text
}

#[test]
fn native_bytes_are_rehashed_without_filters_writes_or_text_conversion() {
    let bytes = b"private commit\0message\xff\r\n";
    let mut manager = manager(vec![reply(0, bytes), reply(0, &hash())]);
    let object = manager
        .commit_object(Path::new("/repo"), &revision())
        .unwrap();
    assert_eq!(object.revision(), &revision());
    assert_eq!(object.bytes(), bytes);
    let requests = &manager.runner().requests;
    assert_eq!(requests.len(), 2);
    assert_eq!(
        requests[0].args,
        ["cat-file", "commit", revision().as_str()].map(OsString::from)
    );
    assert_eq!(
        requests[1].args,
        ["hash-object", "--no-filters", "-t", "commit", "--stdin"].map(OsString::from)
    );
    assert!(requests[0].stdin.is_none());
    assert_eq!(requests[1].stdin.as_deref(), Some(bytes.as_slice()));
    for request in requests {
        assert_eq!(request.program, Path::new("/installed/git"));
        assert_eq!(request.current_dir.as_deref(), Some(Path::new("/repo")));
        assert!(request.environment.is_empty());
    }
}

#[test]
fn tree_header_is_exact_and_does_not_read_parent_or_message_claims() {
    let id = "b".repeat(40);
    let object = CommitObject {
        revision: revision(),
        bytes: format!(
            "tree {id}\nparent {}\n\ntree {}\n",
            "c".repeat(40),
            "d".repeat(40)
        )
        .into_bytes(),
    };
    assert_eq!(object.tree_id().unwrap().as_str(), id);
    for bytes in [
        Vec::new(),
        format!("tree {id}").into_bytes(),
        format!("tree {id}\r\n").into_bytes(),
        format!(" tree {id}\n").into_bytes(),
        format!("tree {}\n", "b".repeat(64)).into_bytes(),
        format!("tree {}\n", "B".repeat(40)).into_bytes(),
        format!("tree {}\n", "0".repeat(40)).into_bytes(),
        b"tree PRIVATE-COMMIT\n".to_vec(),
    ] {
        let object = CommitObject {
            revision: revision(),
            bytes,
        };
        let error = object.tree_id().err().unwrap();
        assert!(!error.to_string().contains("PRIVATE-COMMIT"));
    }
}

#[test]
fn abbreviated_commit_is_not_resolved_or_read() {
    let mut manager = manager(Vec::new());
    assert!(
        manager
            .commit_object(Path::new("/repo"), &CommitSha::parse("abcdef0").unwrap())
            .is_err()
    );
    assert!(manager.runner().requests.is_empty());
}

#[test]
fn empty_or_oversized_objects_reject_before_rehash() {
    for bytes in [Vec::new(), vec![b'x'; MAX_BYTES + 1]] {
        let mut manager = manager(vec![reply(0, &bytes)]);
        assert!(error(&mut manager).contains("size outside bound"));
        assert_eq!(manager.runner().requests.len(), 1);
    }
    let bytes = vec![b'x'; MAX_BYTES];
    let mut manager = manager(vec![reply(0, &bytes), reply(0, &hash())]);
    assert_eq!(
        manager
            .commit_object(Path::new("/repo"), &revision())
            .unwrap()
            .bytes(),
        bytes
    );
}

#[test]
fn nonzero_reads_and_hashes_never_become_an_observation_or_disclose_stderr() {
    for status in [1, 128] {
        let mut read = manager(vec![reply(status, b"PRIVATE-COMMIT")]);
        assert!(error(&mut read).contains("read native commit object failed"));
        assert_eq!(read.runner().requests.len(), 1);
        let mut hash = manager(vec![reply(0, b"private"), reply(status, b"PRIVATE-COMMIT")]);
        assert!(error(&mut hash).contains("hash native commit object failed"));
        assert_eq!(hash.runner().requests.len(), 2);
    }
}

#[test]
fn hash_identity_and_framing_are_exact_not_whitespace_normalized() {
    for bytes in [
        Vec::new(),
        b"PRIVATE-COMMIT".to_vec(),
        revision().as_str().as_bytes().to_vec(),
        format!("{}\n", "b".repeat(40)).into_bytes(),
        format!("{}\r\n", revision().as_str()).into_bytes(),
        format!("{}\n\n", revision().as_str()).into_bytes(),
        format!("{}\n", "a".repeat(64)).into_bytes(),
        format!("{}\n", "A".repeat(40)).into_bytes(),
    ] {
        let mut manager = manager(vec![reply(0, b"private"), reply(0, &bytes)]);
        assert!(error(&mut manager).contains("differs from requested identity"));
        assert_eq!(manager.runner().requests.len(), 2);
    }
}

#[test]
fn transport_uncertainty_propagates_without_retry_or_partial_object() {
    for replies in [
        vec![Err(anyhow::anyhow!("transport uncertain"))],
        vec![
            reply(0, b"private"),
            Err(anyhow::anyhow!("transport uncertain")),
        ],
    ] {
        let count = replies.len();
        let mut manager = manager(replies);
        assert!(error(&mut manager).contains("transport uncertain"));
        assert_eq!(manager.runner().requests.len(), count);
    }
}
