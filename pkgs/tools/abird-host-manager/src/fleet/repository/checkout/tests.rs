use super::*;
use std::collections::VecDeque;
use std::os::unix::fs::PermissionsExt;

use crate::fleet::repository::{CommandOutput, CommandRequest};

fn reply(status: i32, bytes: &[u8]) -> CommandOutput {
    CommandOutput {
        status,
        stdout: bytes.into(),
        stderr: b"PRIVATE-CONFIG".to_vec(),
    }
}
#[derive(Default)]
struct Fake {
    replies: VecDeque<Result<CommandOutput>>,
    requests: Vec<CommandRequest>,
}
impl CommandRunner for Fake {
    fn run(&mut self, request: &CommandRequest) -> Result<CommandOutput> {
        self.requests.push(request.clone());
        self.replies.pop_front().expect("unexpected Git operation")
    }
}
fn manager(replies: Vec<CommandOutput>) -> RepositoryManager<Fake> {
    RepositoryManager::new(
        "/pinned/git",
        Fake {
            replies: replies.into_iter().map(Ok).collect(),
            ..Fake::default()
        },
    )
}

#[test]
fn configuration_framing_and_bounds_are_exact_without_disclosing_values() {
    for bytes in [
        b"secret".to_vec(),
        b"\0".to_vec(),
        b"\nsecret\0".to_vec(),
        vec![b'x'; 128 * 1024 + 1],
        b"a\0".repeat(4097),
        [b"core.eol\n".to_vec(), vec![b'x'; 129], vec![0]].concat(),
    ] {
        let error = configuration(&bytes).err().unwrap().to_string();
        assert!(!error.contains("secret") && !error.contains("PRIVATE-CONFIG"));
    }
    assert!(configuration(b"").unwrap().iter().all(Option::is_none));
}

#[test]
fn effective_values_override_shadowed_values_but_preserve_bare_and_empty() {
    let raw = configuration(b"core.autocrlf\ninput\0remote.origin.url\nPRIVATE\0core.autocrlf\nfalse\0core.filemode\0core.symlinks\n\0").unwrap();
    assert!(matches!(&raw[0],Some(Raw::Value(v)) if v == b"false"));
    assert!(matches!(&raw[2], Some(Raw::Bare)));
    assert!(matches!(&raw[3],Some(Raw::Value(v)) if v.is_empty()));
    assert!(raw[1].is_none());
}

#[test]
fn absent_settings_are_not_fabricated_and_snapshot_is_one_command() {
    let mut manager = manager(vec![reply(0, b"user.name\nprivate-name\0")]);
    assert!(
        manager
            .checkout_settings(Path::new("/repo"))
            .unwrap()
            .0
            .iter()
            .all(Option::is_none)
    );
    assert_eq!(manager.runner().requests.len(), 1);
    assert_eq!(
        manager.runner().requests[0].args,
        ["config", "--null", "--list"].map(OsString::from)
    );
}

#[test]
fn native_conversion_sees_only_the_effective_value_not_shadowed_input() {
    let mut manager = manager(vec![
        reply(
            0,
            b"core.autocrlf\ninput\0core.autocrlf\nfalse\0core.filemode\0core.symlinks\n\0",
        ),
        reply(0, b"false\0"),
        reply(0, b"true\0"),
        reply(0, b"false\0"),
    ]);
    let settings = manager.checkout_settings(Path::new("/repo")).unwrap();
    assert_eq!(
        settings.0,
        [Some("false"), None, Some("true"), Some("false"), None, None]
    );
    for request in &manager.runner().requests[1..] {
        assert_eq!(
            request.args,
            [
                "config",
                "--file",
                "-",
                "--null",
                "--type=bool",
                "--get",
                "checkout.value"
            ]
            .map(OsString::from)
        );
    }
    assert_eq!(
        manager.runner().requests[1].stdin.as_deref(),
        Some(&b"[checkout]\nvalue=\"false\"\n"[..])
    );
    assert_eq!(
        manager.runner().requests[2].stdin.as_deref(),
        Some(&b"[checkout]\nvalue\n"[..])
    );
    assert_eq!(
        manager.runner().requests[3].stdin.as_deref(),
        Some(&b"[checkout]\nvalue=\"\"\n"[..])
    );
}

#[test]
fn isolated_value_quoting_preserves_git_escapes_without_new_keys() {
    assert_eq!(
        Raw::Value(b"a\\\"\n\t\x08b".to_vec()).inline(),
        b"[checkout]\nvalue=\"a\\\\\\\"\\n\\t\\bb\"\n"
    );
}

#[test]
fn input_warn_and_eol_are_not_reinterpreted_as_booleans() {
    for eol in ["lf", "crlf", "native"] {
        let mut manager = manager(vec![reply(
            0,
            format!("core.autocrlf\ninput\0core.eol\n{eol}\0core.safecrlf\nwarn\0").as_bytes(),
        )]);
        assert_eq!(
            manager.checkout_settings(Path::new("/repo")).unwrap().0,
            [Some("input"), Some(eol), None, None, None, Some("warn")]
        );
        assert_eq!(manager.runner().requests.len(), 1);
    }
}

#[test]
fn malformed_or_failed_capture_and_conversion_never_become_absence() {
    for replies in [
        vec![reply(1, b"")],
        vec![reply(0, b"core.eol\nsecret\0")],
        vec![reply(0, b"core.eol\0")],
        vec![reply(0, b"core.filemode\nsecret\0"), reply(128, b"")],
        vec![reply(0, b"core.filemode\0"), reply(0, b"yes\0")],
    ] {
        let error = manager(replies)
            .checkout_settings(Path::new("/repo"))
            .err()
            .unwrap()
            .to_string();
        assert!(!error.contains("secret") && !error.contains("PRIVATE-CONFIG"));
    }
}

#[test]
fn replay_checks_effective_values_and_only_changes_the_enumerated_keys() {
    let settings = CheckoutSettings([None, Some("lf"), None, None, None, None]);
    let mut replies = vec![
        reply(5, b""),
        reply(0, b""),
        reply(5, b""),
        reply(5, b""),
        reply(5, b""),
        reply(5, b""),
    ];
    replies.push(reply(0, b"core.eol\nlf\0"));
    let mut replay = manager(replies);
    replay
        .apply_checkout_settings(Path::new("/repo"), &settings)
        .unwrap();
    for request in &replay.runner().requests[..6] {
        assert!(request.args.iter().any(|a| a == "--local"));
        assert!(request.args.iter().any(|a| KEYS.iter().any(|key| a == key)));
    }
    let mut replies = (0..6).map(|_| reply(0, b"")).collect::<Vec<_>>();
    replies.push(reply(0, b""));
    assert!(
        manager(replies)
            .apply_checkout_settings(Path::new("/repo"), &settings)
            .is_err()
    );
    for output in [reply(1, b""), reply(0, b"unexpected"), reply(128, b"")] {
        assert!(
            manager(vec![output])
                .apply_checkout_settings(Path::new("/repo"), &CheckoutSettings([None; 6]))
                .is_err()
        );
    }
}

#[test]
fn standalone_failure_keeps_private_exclusive_directory_without_replay_or_adoption() {
    let temp = tempfile::tempdir().unwrap();
    let target = temp.path().join("replica");
    let fake = Fake {
        replies: [Err(anyhow::anyhow!("capture uncertain"))].into(),
        ..Fake::default()
    };
    let mut manager = RepositoryManager::new("/pinned/git", fake);
    let commit = CommitSha::parse("a".repeat(40)).unwrap();
    let settings = CheckoutSettings([None; 6]);
    assert!(
        manager
            .create_standalone_checkout(temp.path(), &target, &commit, &settings)
            .is_err()
    );
    assert!(target.is_dir());
    assert_eq!(target.metadata().unwrap().permissions().mode() & 0o077, 0);
    assert!(
        manager
            .create_standalone_checkout(temp.path(), &target, &commit, &settings)
            .is_err()
    );
    assert_eq!(manager.runner().requests.len(), 1);
    assert_eq!(
        &manager.runner().requests[0].args[..6],
        [
            "clone",
            "--no-local",
            "--no-hardlinks",
            "--no-checkout",
            "--template=",
            "--"
        ]
        .map(OsString::from)
    );
}

#[test]
fn standalone_rejects_short_commit_and_existing_or_symlinked_destinations() {
    let temp = tempfile::tempdir().unwrap();
    let mut manager = manager(Vec::new());
    let target = temp.path().join("replica");
    let settings = CheckoutSettings([None; 6]);
    let short = CommitSha::parse("abcdef0").unwrap();
    assert!(
        manager
            .create_standalone_checkout(temp.path(), &target, &short, &settings)
            .is_err()
    );
    assert!(!target.exists());
    std::os::unix::fs::symlink(temp.path().join("missing"), &target).unwrap();
    let commit = CommitSha::parse("a".repeat(40)).unwrap();
    assert!(
        manager
            .create_standalone_checkout(temp.path(), &target, &commit, &settings)
            .is_err()
    );
    assert!(manager.runner().requests.is_empty());
}
