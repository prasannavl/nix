//! Intake/encoding regressions only. No native source equivalence or public
//! lifecycle acceptance is established by these fixtures.

use super::*;
use std::os::unix::ffi::OsStringExt;
use std::os::unix::fs::symlink;
use std::time::Duration;

fn bounds() -> Limits {
    Limits {
        entries: 32,
        bytes: 4096,
        depth: 8,
    }
}
fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(10)
}
fn uid() -> u32 {
    unsafe { libc::geteuid() }
}
fn observe(path: &Path, end: Instant) -> Observation {
    Observation::read(path, uid(), bounds(), end).unwrap()
}
fn empty_nar() -> Vec<u8> {
    let mut bytes = Vec::new();
    for token in ["nix-archive-1", "(", "type", "directory", ")"] {
        bytes.extend((token.len() as u64).to_le_bytes());
        bytes.extend(token.as_bytes());
        bytes.resize(bytes.len().next_multiple_of(8), 0);
    }
    bytes
}

#[test]
fn linked_layout_keeps_real_common_and_per_worktree_administration() {
    let mut layout = GitLayout {
        worktree: "/home/operator/linked".into(),
        common: "/home/operator/main/.git".into(),
        git_dir: "/home/operator/main/.git/worktrees/linked".into(),
    };
    layout.validate().unwrap();
    layout.git_dir = layout.common.clone();
    layout.validate().unwrap();
    for path in [
        "/outside/admin",
        "/home/operator/main/.git/../admin",
        "/home/operator/main/.git/objects/admin",
    ] {
        layout.git_dir = path.into();
        assert!(layout.validate().is_err());
    }
}

#[test]
fn git_image_digest_binds_original_caller_and_nar_omitted_timestamps() {
    let directory = tempfile::tempdir().unwrap();
    let mut image = GitContext::new(
        "a".repeat(64),
        &empty_nar(),
        observe(directory.path(), deadline()),
    )
    .unwrap();
    let original = image.digest().unwrap();
    image.stamps.get_mut("").unwrap().seconds -= 1;
    assert_ne!(image.digest().unwrap(), original);
    let timestamp = image.digest().unwrap();
    image.caller_digest = "b".repeat(64);
    assert_ne!(image.digest().unwrap(), timestamp);
    image.nar_digest = "c".repeat(64);
    assert!(image.validate().is_err());
}

#[test]
fn git_intake_retains_raw_names_and_vetoes_replaced_metadata() {
    let directory = tempfile::tempdir().unwrap();
    let name = std::ffi::OsString::from_vec(b"raw-\xff".to_vec());
    let path = directory.path().join(&name);
    std::fs::write(&path, b"same bytes").unwrap();
    let end = deadline();
    let first = observe(directory.path(), end);
    assert!(first.stamps.contains_key(&hex(b"raw-\xff")));
    assert!(first == observe(directory.path(), end));
    let replacement = directory.path().join("replacement");
    std::fs::write(&replacement, b"same bytes").unwrap();
    std::fs::rename(replacement, path).unwrap();
    assert!(first != observe(directory.path(), end));
}

#[test]
fn git_intake_keeps_symlinks_but_rejects_hardlinks_and_fifo_without_reading_payloads() {
    let directory = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let secret = outside.path().join("not-source");
    std::fs::write(&secret, b"not an input").unwrap();
    let link = directory.path().join("redirect");
    symlink(&secret, &link).unwrap();
    let observation = Observation::read(directory.path(), uid(), bounds(), deadline()).unwrap();
    assert!(observation.stamps[&hex(b"redirect")].symlink);
    std::fs::remove_file(&link).unwrap();
    std::fs::hard_link(&secret, &link).unwrap();
    assert!(Observation::read(directory.path(), uid(), bounds(), deadline()).is_err());
    std::fs::remove_file(&link).unwrap();
    use std::os::unix::ffi::OsStrExt;
    let fifo = CString::new(link.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    assert!(Observation::read(directory.path(), uid(), bounds(), deadline()).is_err());
}

#[test]
fn git_intake_honors_original_deadline_entries_depth_and_bytes() {
    let directory = tempfile::tempdir().unwrap();
    std::fs::create_dir(directory.path().join("objects")).unwrap();
    std::fs::write(directory.path().join("objects/data"), b"payload").unwrap();
    assert!(Observation::read(directory.path(), uid(), bounds(), Instant::now()).is_err());
    for limits in [
        Limits {
            entries: 1,
            ..bounds()
        },
        Limits {
            depth: 1,
            ..bounds()
        },
        Limits {
            bytes: 1,
            ..bounds()
        },
    ] {
        assert!(Observation::read(directory.path(), uid(), limits, deadline()).is_err());
    }
}

#[test]
fn git_image_rejects_path_escapes_missing_parents_and_invalid_timestamps() {
    let directory = tempfile::tempdir().unwrap();
    let mut image = GitContext::new(
        "a".repeat(64),
        &empty_nar(),
        observe(directory.path(), deadline()),
    )
    .unwrap();
    let file = Stamp {
        symlink: false,
        directory: false,
        executable: false,
        bytes: 0,
        seconds: 1,
        nanoseconds: 0,
    };
    for name in [
        b"../escape".as_slice(),
        b"/absolute",
        b"a//b",
        b"a/./b",
        b"a\0b",
        b"missing/file",
    ] {
        image.stamps.insert(hex(name), file.clone());
        assert!(image.validate().is_err());
        image.stamps.remove(&hex(name));
    }
    image.stamps.get_mut("").unwrap().nanoseconds = 1_000_000_000;
    assert!(image.validate().is_err());
}

#[test]
fn git_timestamp_restoration_has_no_unplaced_caller_entry() {
    let directory = tempfile::tempdir().unwrap();
    let image = GitContext::new(
        "a".repeat(64),
        &empty_nar(),
        observe(directory.path(), deadline()),
    )
    .unwrap();
    assert!(
        image
            .restore_times(directory.path(), uid(), bounds(), deadline())
            .is_err()
    );
}
