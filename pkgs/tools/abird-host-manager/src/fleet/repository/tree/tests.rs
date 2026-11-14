use super::*;
use std::collections::VecDeque;
use std::ffi::OsString;

use crate::fleet::repository::{CommandOutput, CommandRequest};

fn record(mode: &[u8], name: &[u8], id: u8) -> Vec<u8> {
    [mode, b" ", name, b"\0", &[id; 20]].concat()
}
fn identity() -> ObjectId {
    ObjectId::parse("a".repeat(40)).unwrap()
}
fn reject(bytes: &[u8], expected: &str) {
    let error = entries(bytes).err().unwrap().to_string();
    assert!(error.contains(expected), "{error}");
    assert!(!error.contains("PRIVATE-TREE"));
}

#[test]
fn raw_names_modes_and_ids_preserve_native_directory_order_without_decoding() {
    assert!(entries(b"").unwrap().is_empty());
    let rows = [
        (b"100644".as_slice(), b"a.b".as_slice(), TreeKind::File),
        (b"40000", b"a", TreeKind::Directory),
        (b"100755", b"b", TreeKind::Executable),
        (b"120000", b"c", TreeKind::Symlink),
        (b"100644", b"raw\tname\n\xff", TreeKind::File),
    ];
    let bytes = rows
        .iter()
        .flat_map(|(mode, name, _)| record(mode, name, 0xab))
        .collect::<Vec<_>>();
    let parsed = entries(&bytes).unwrap();
    assert_eq!(parsed.len(), rows.len());
    for (entry, (_, name, kind)) in parsed.iter().zip(rows) {
        assert_eq!(entry.name(), name);
        assert!(entry.kind() == kind);
        assert_eq!(entry.object().as_str(), "ab".repeat(20));
    }
}

#[test]
fn unsupported_modes_names_and_metadata_components_are_not_normalized() {
    for mode in [
        b"040000".as_slice(),
        b"100664",
        b"160000",
        b"100600",
        b"PRIVATE-TREE",
    ] {
        reject(&record(mode, b"name", 1), "unsupported native tree mode");
    }
    for name in [
        b"".as_slice(),
        b".",
        b"..",
        b".git",
        b".GiT",
        b"a/b",
        b"/absolute",
    ] {
        reject(&record(b"100644", name, 1), "unsupported native tree name");
    }
    assert!(entries(&record(b"100644", &vec![b'x'; MAX_NAME], 1)).is_ok());
    reject(
        &record(b"100644", &vec![b'x'; MAX_NAME + 1], 1),
        "unsupported native tree name",
    );
}

#[test]
fn malformed_truncated_null_and_trailing_frames_fail_without_private_bytes() {
    reject(b"PRIVATE-TREE", "invalid native tree mode frame");
    reject(b"100644 PRIVATE-TREE", "unterminated native tree name");
    for len in 0..20 {
        reject(
            &[b"100644 name\0".as_slice(), &vec![1; len]].concat(),
            "truncated native tree object ID",
        );
    }
    reject(
        &record(b"100644", b"name", 0),
        "unsupported native object ID",
    );
    let mut bytes = record(b"100644", b"name", 1);
    bytes.push(0);
    reject(&bytes, "invalid native tree mode frame");
}

#[test]
fn duplicate_names_and_noncanonical_order_are_rejected_not_sorted() {
    reject(
        &[record(b"100644", b"a", 1), record(b"40000", b"a", 2)].concat(),
        "duplicate native tree name",
    );
    reject(
        &[record(b"40000", b"a", 1), record(b"100644", b"a.b", 2)].concat(),
        "noncanonical native tree order",
    );
    reject(
        &[record(b"100644", b"b", 1), record(b"100644", b"a", 2)].concat(),
        "noncanonical native tree order",
    );
}

#[test]
fn byte_and_logical_entry_bounds_are_independent() {
    reject(
        &vec![b'x'; object::MAX_TREE_BYTES + 1],
        "native tree object exceeds bound",
    );
    let mut bytes = (0..MAX_ENTRIES)
        .flat_map(|i| record(b"100644", format!("{i:05}").as_bytes(), 1))
        .collect::<Vec<_>>();
    assert_eq!(entries(&bytes).unwrap().len(), MAX_ENTRIES);
    bytes.extend(record(b"100644", format!("{MAX_ENTRIES:05}").as_bytes(), 1));
    assert!(bytes.len() < object::MAX_TREE_BYTES);
    reject(&bytes, "entry count exceeds bound");
}

struct Fake {
    replies: VecDeque<CommandOutput>,
    requests: Vec<CommandRequest>,
}
impl CommandRunner for Fake {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput> {
        self.requests.push(request.clone());
        Ok(self.replies.pop_front().expect("unexpected helper"))
    }
}
fn output(status: i32, bytes: &[u8]) -> CommandOutput {
    CommandOutput {
        status,
        stdout: bytes.into(),
        stderr: b"PRIVATE-TREE".to_vec(),
    }
}
fn manager(replies: Vec<CommandOutput>) -> RepositoryManager<Fake> {
    RepositoryManager::new(
        "/installed/git",
        Fake {
            replies: replies.into(),
            requests: Vec::new(),
        },
    )
}

#[test]
fn native_tree_capture_rehashes_exact_binary_bytes_without_pretty_print_or_writes() {
    for bytes in [Vec::new(), record(b"100644", b"raw\tname\n\xff", 1)] {
        let mut manager = manager(vec![
            output(0, &bytes),
            output(0, format!("{}\n", identity().as_str()).as_bytes()),
        ]);
        let tree = manager
            .tree_object(Path::new("/repo"), &identity())
            .unwrap();
        assert_eq!(tree.identity().as_str(), identity().as_str());
        assert_eq!(tree.entries().len(), usize::from(!bytes.is_empty()));
        let requests = &manager.runner().requests;
        assert_eq!(requests.len(), 2);
        assert_eq!(
            requests[0].args,
            ["cat-file", "tree", identity().as_str()].map(OsString::from)
        );
        assert_eq!(
            requests[1].args,
            ["hash-object", "--no-filters", "-t", "tree", "--stdin"].map(OsString::from)
        );
        assert_eq!(requests[1].stdin.as_deref(), Some(bytes.as_slice()));
        for request in requests {
            assert_eq!(request.current_dir.as_deref(), Some(Path::new("/repo")));
            assert!(request.environment.is_empty());
        }
    }
}

#[test]
fn failed_capture_hash_or_identity_never_returns_partial_tree_or_private_stderr() {
    for replies in [
        vec![output(128, b"PRIVATE-TREE")],
        vec![output(0, b""), output(1, b"PRIVATE-TREE")],
        vec![output(0, b""), output(0, b"PRIVATE-TREE")],
        vec![output(0, b""), output(0, identity().as_str().as_bytes())],
        vec![
            output(0, b""),
            output(0, format!("{}\n", "b".repeat(40)).as_bytes()),
        ],
    ] {
        let count = replies.len();
        let mut manager = manager(replies);
        let error = manager
            .tree_object(Path::new("/repo"), &identity())
            .err()
            .unwrap();
        assert!(!error.to_string().contains("PRIVATE-TREE"));
        assert_eq!(manager.runner().requests.len(), count);
    }
}

#[test]
fn object_ids_are_exact_nonzero_sha1_not_refs_abbreviations_or_other_formats() {
    assert_eq!(
        ObjectId::parse("0123456789abcdef0123456789abcdef01234567")
            .unwrap()
            .as_str()
            .len(),
        40
    );
    for id in [
        String::new(),
        "abcdef0".into(),
        "HEAD".into(),
        "A".repeat(40),
        "a".repeat(64),
        "0".repeat(40),
        "g".repeat(40),
    ] {
        assert!(ObjectId::parse(id).is_err());
    }
}
