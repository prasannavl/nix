use super::*;
use std::ffi::OsString;

use crate::fleet::repository::{CommandOutput, CommandRequest};

fn record(flag: &str, mode: &str, stage: &str, path: &[u8]) -> Vec<u8> {
    let mut bytes = format!("{flag} {mode} {} {stage}\t", "a".repeat(40)).into_bytes();
    bytes.extend_from_slice(path);
    bytes.push(0);
    bytes
}

#[test]
fn entries_keep_raw_names_objects_and_modes_without_order_or_text_normalization() {
    let file = record("H", "100644", "0", b"directory/raw\tname\n\xff");
    let exec = record("H", "100755", "0", b"executable");
    let link = record("H", "120000", "0", b"link");
    let left = entries(&[file.clone(), exec.clone(), link.clone()].concat()).unwrap();
    let right = entries(&[link, exec, file.clone()].concat()).unwrap();
    assert!(left == right);
    assert!(left != entries(&file).unwrap());
    assert!(
        entries(&file).unwrap()
            != entries(&record("H", "100755", "0", b"directory/raw\tname\n\xff")).unwrap()
    );
    let mut changed = file.clone();
    changed[9] = b'b';
    assert!(entries(&file).unwrap() != entries(&changed).unwrap());
    assert!(entries(b"").unwrap() == entries(b"").unwrap());
}

#[test]
fn hidden_flags_merge_stages_and_gitlinks_are_not_normalized_into_plain_entries() {
    for flag in ["h", "S", "s", "M", "R", "C", "K", "?", ""] {
        assert!(entries(&record(flag, "100644", "0", b"PRIVATE_INDEX")).is_err());
    }
    for stage in ["1", "2", "3", "00", ""] {
        assert!(entries(&record("H", "100644", stage, b"PRIVATE_INDEX")).is_err());
    }
    for mode in ["160000", "040000", "100664", "100644 ", ""] {
        assert!(entries(&record("H", mode, "0", b"PRIVATE_INDEX")).is_err());
    }
}

#[test]
fn malformed_frames_objects_and_duplicate_paths_fail_without_private_data() {
    let valid = record("H", "100644", "0", b"PRIVATE_INDEX");
    let mut zero = valid.clone();
    zero[9..49].fill(b'0');
    let mut uppercase = valid.clone();
    uppercase[9] = b'A';
    for bytes in [
        b"PRIVATE_INDEX".to_vec(),
        b"\0".to_vec(),
        valid[..valid.len() - 1].to_vec(),
        [valid.clone(), valid.clone()].concat(),
        zero,
        uppercase,
        b"H 100644 abc 0\tPRIVATE_INDEX\0".to_vec(),
        b"H 100644 abc 0 extra\tPRIVATE_INDEX\0".to_vec(),
    ] {
        let error = entries(&bytes).err().unwrap().to_string();
        assert!(!error.contains("PRIVATE_INDEX"));
    }
}

#[test]
fn paths_are_bounded_relative_names_not_metadata_or_traversal() {
    for path in [
        b"".as_slice(),
        b"/root",
        b"a//b",
        b"a/./b",
        b"a/../b",
        b".git/config",
        b"a/.GiT/config",
        b"a/",
    ] {
        assert!(entries(&record("H", "100644", "0", path)).is_err());
    }
    assert!(entries(&record("H", "100644", "0", &vec![b'a'; MAX_PATH])).is_ok());
    assert!(entries(&record("H", "100644", "0", &vec![b'a'; MAX_PATH + 1])).is_err());
}

#[test]
fn byte_and_entry_bounds_are_independent() {
    assert!(entries(&vec![b' '; MAX_BYTES + 1]).is_err());
    let mut bytes = Vec::new();
    for i in 0..MAX_ENTRIES {
        bytes.extend(record("H", "100644", "0", i.to_string().as_bytes()));
    }
    assert!(entries(&bytes).is_ok());
    bytes.extend(record("H", "100644", "0", b"last"));
    assert!(
        entries(&bytes)
            .err()
            .unwrap()
            .to_string()
            .contains("entry count")
    );
}

struct Fake {
    output: Option<CommandOutput>,
    request: Option<CommandRequest>,
}
impl CommandRunner for Fake {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput> {
        self.request = Some(request.clone());
        Ok(self.output.take().unwrap())
    }
}

#[test]
fn native_capture_requests_both_flag_classes_and_never_treats_failure_as_empty() {
    for status in [0, 1, 128] {
        let mut manager = RepositoryManager::new(
            "/installed/git",
            Fake {
                output: Some(CommandOutput {
                    status,
                    stdout: Vec::new(),
                    stderr: b"PRIVATE_INDEX".to_vec(),
                }),
                request: None,
            },
        );
        let result = manager.index_entries(Path::new("/repo"));
        if status == 0 {
            assert!(result.is_ok());
        } else {
            assert!(!result.err().unwrap().to_string().contains("PRIVATE_INDEX"));
        }
        let request = manager.runner().request.as_ref().unwrap();
        assert_eq!(
            request.args,
            [
                "ls-files",
                "--cached",
                "--stage",
                "-v",
                "-f",
                "--full-name",
                "-z",
                "--"
            ]
            .map(OsString::from)
        );
        assert_eq!(request.current_dir.as_deref(), Some(Path::new("/repo")));
        assert!(request.stdin.is_none());
    }
}
