use std::fs::{self, FileTimes, OpenOptions};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::time::{Duration, SystemTime};

use abird_host_manager::fleet::maintenance::{
    CleanMode, CleanOutcome, REQUIRED_PROGRAMS, clean_roots, missing_programs,
};

#[test]
fn dependency_check_reports_every_missing_program_in_stable_order() {
    let temporary = tempfile::tempdir().unwrap();
    let bin = temporary.path().join("bin");
    fs::create_dir(&bin).unwrap();
    for name in ["age", "git", "nix"] {
        let path = bin.join(name);
        fs::write(&path, "#!/bin/sh\n").unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }
    let missing = missing_programs(&[bin]).unwrap();
    assert_eq!(
        missing,
        REQUIRED_PROGRAMS
            .iter()
            .filter(|name| !matches!(**name, "age" | "git" | "nix"))
            .map(|name| (*name).to_owned())
            .collect::<Vec<_>>()
    );
}

#[test]
fn automatic_cleanup_removes_only_old_owned_run_and_diag_directories() {
    let temporary = tempfile::tempdir().unwrap();
    let runtime = temporary.path().join("runtime");
    let diagnostics = temporary.path().join("diagnostics");
    for root in [&runtime, &diagnostics] {
        fs::create_dir(root).unwrap();
        fs::create_dir(root.join("run-old")).unwrap();
        fs::create_dir(root.join("diag-old")).unwrap();
        fs::create_dir(root.join("run-new")).unwrap();
        fs::create_dir(root.join("unrelated-old")).unwrap();
        let old = SystemTime::now() - Duration::from_secs(90_000);
        for name in ["run-old", "diag-old", "unrelated-old"] {
            OpenOptions::new()
                .read(true)
                .open(root.join(name))
                .unwrap()
                .set_times(FileTimes::new().set_modified(old))
                .unwrap();
        }
    }

    let report = clean_roots(
        [&runtime, &diagnostics],
        CleanMode::Automatic {
            older_than: Duration::from_secs(86_400),
            now: SystemTime::now(),
        },
        false,
    )
    .unwrap();
    assert_eq!(report.removed.len(), 4);
    for root in [&runtime, &diagnostics] {
        assert!(!root.join("run-old").exists());
        assert!(!root.join("diag-old").exists());
        assert!(root.join("run-new").is_dir());
        assert!(root.join("unrelated-old").is_dir());
    }
}

#[test]
fn dry_run_reports_without_removing_and_all_mode_does_not_follow_symlinks() {
    let temporary = tempfile::tempdir().unwrap();
    let outside = temporary.path().join("outside");
    let root = temporary.path().join("runtime");
    fs::create_dir(&outside).unwrap();
    fs::write(outside.join("keep"), "owned elsewhere").unwrap();
    symlink(&outside, &root).unwrap();

    let dry = clean_roots([&root], CleanMode::All, true).unwrap();
    assert_eq!(dry.outcomes, [(root.clone(), CleanOutcome::WouldRemove)]);
    assert!(
        fs::symlink_metadata(&root)
            .unwrap()
            .file_type()
            .is_symlink()
    );

    let applied = clean_roots([&root], CleanMode::All, false).unwrap();
    assert_eq!(applied.outcomes, [(root.clone(), CleanOutcome::Removed)]);
    assert!(!root.exists());
    assert_eq!(
        fs::read_to_string(outside.join("keep")).unwrap(),
        "owned elsewhere"
    );
}

#[test]
fn cleanup_rejects_relative_and_filesystem_root_targets() {
    assert!(clean_roots([std::path::Path::new("relative")], CleanMode::All, false).is_err());
    assert!(clean_roots([std::path::Path::new("/")], CleanMode::All, false).is_err());
}
