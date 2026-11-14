use super::*;
use crate::build_executor::journal::{
    JobStatus,
    tests::{accepted, fixture, identity, policy},
};
use crate::build_executor::{ExecutionHandle, Settlement};
use std::os::unix::fs::{PermissionsExt, symlink};

fn ready(journal: &Journal, started: bool) -> Ownership {
    let key = accepted(journal, "source").attempt_id;
    journal.queue(&key, 1000).unwrap();
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    let owner = journal.reserve_next("boot", 1000).unwrap().unwrap();
    if started {
        journal
            .started(
                ExecutionHandle {
                    ownership: owner.clone(),
                    invocation_id: "source-worker".into(),
                },
                1000,
            )
            .unwrap();
    }
    owner
}
fn depot(root: &Path) -> PathBuf {
    let path = data_root(Some(root), None).unwrap();
    fs::create_dir_all(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    path
}
fn limits() -> Limits {
    Limits {
        entries: 128,
        bytes: 65536,
        depth: 16,
    }
}
fn allocate(journal: &Journal, owner: &Ownership, path: &Path, now: u64) -> Result<SourceSlot> {
    SourceSlot::allocate_at(
        journal,
        owner.clone(),
        path.to_owned(),
        1000,
        unsafe { libc::getegid() }.max(1),
        limits(),
        now,
        |_| Ok(()),
    )
}
fn release(journal: &Journal, owner: &Ownership) {
    journal
        .cancel("operator", &owner.attempt_id, Some(owner), 1000)
        .unwrap();
    journal
        .settle(
            &owner.attempt_id,
            Settlement::FencedEmpty {
                ownership: owner.clone(),
            },
            None,
            1000,
        )
        .unwrap();
    journal
        .released(&owner.attempt_id, &"e".repeat(64), 1000)
        .unwrap();
}
fn live(journal: &Journal, owner: &Ownership) -> bool {
    matches!(
        journal.status("operator", &owner.attempt_id).unwrap(),
        JobStatus::Live { .. }
    )
}

#[test]
fn xdg_data_location_is_distinct_strict_and_has_no_legacy_fallback() {
    assert_eq!(
        data_root(Some(Path::new("/data")), None).unwrap(),
        Path::new("/data/abird/abird-host-agent/owned-build/sources")
    );
    assert_eq!(
        data_root(None, Some(Path::new("/home/test"))).unwrap(),
        Path::new("/home/test/.local/share/abird/abird-host-agent/owned-build/sources")
    );
    assert_eq!(
        data_root(Some(Path::new("")), Some(Path::new("/home/test"))).unwrap(),
        data_root(None, Some(Path::new("/home/test"))).unwrap()
    );
    assert!(data_root(Some(Path::new("relative")), Some(Path::new("/home/test"))).is_err());
    assert!(data_root(None, Some(Path::new("relative"))).is_err());
    assert!(data_root(None, None).is_err());
    assert_ne!(
        data_root(Some(Path::new("/same")), None).unwrap(),
        super::super::request::state_root(Some(Path::new("/same")), None).unwrap()
    );
}

#[test]
fn retirement_budget_covers_copies_and_encoding_without_changing_source_limits() {
    let source = limits();
    let cleanup = super::cleanup::limits(source).unwrap();
    let material = crate::build_executor::preparation::source::material_limit(source).unwrap();
    assert!(cleanup.bytes >= 4 * source.bytes + material as u64);
    assert!(cleanup.entries > 4 * source.entries);
    assert_eq!(cleanup.depth, source.depth + 8);
    assert_eq!(source, limits());
    assert!(
        super::cleanup::limits(Limits {
            bytes: u64::MAX,
            ..source
        })
        .is_err()
    );
    assert!(
        super::cleanup::limits(Limits {
            entries: u32::MAX,
            ..source
        })
        .is_err()
    );
}

#[test]
fn admission_and_worker_start_precede_source_effects() {
    let (temp, journal) = fixture();
    let path = depot(temp.path());
    let owner = ready(&journal, false);
    assert!(allocate(&journal, &owner, &path, 1000).is_err());
    assert_eq!(fs::read_dir(&path).unwrap().count(), 0);
    assert!(journal.source_allocation(&owner).is_err());
    journal
        .started(
            ExecutionHandle {
                ownership: owner.clone(),
                invocation_id: "source-worker".into(),
            },
            1000,
        )
        .unwrap();
    let slot = allocate(&journal, &owner, &path, 1000).unwrap();
    let allocation = journal.source_allocation(&owner).unwrap();
    assert!(allocation.directory.is_some() && !allocation.retired);
    assert_eq!(allocation.data_root, path);
    assert_eq!(allocation.limits, limits());
    let parent = slot.authority.lock().unwrap();
    let directory = slot.checked(&parent, &allocation).unwrap();
    assert_eq!(directory.metadata().unwrap().mode() & 0o7777, 0o710);
    assert!(super::super::private_tree::directory_empty(&directory).unwrap());
    drop(parent);
    SourceSlot::open_at(
        &Journal::open(journal.authority_root(), identity(), policy()).unwrap(),
        owner,
    )
    .unwrap();
}

#[test]
fn registration_is_one_shot_even_when_created_directory_disappears() {
    let (temp, journal) = fixture();
    let path = depot(temp.path());
    let owner = ready(&journal, true);
    allocate(&journal, &owner, &path, 1000).unwrap();
    let before = fs::read(journal.authority_root().join("state.json")).unwrap();
    assert!(allocate(&journal, &owner, &path, 1000).is_err());
    fs::remove_dir(path.join(&owner.attempt_id)).unwrap();
    assert!(allocate(&journal, &owner, &path, 1000).is_err());
    assert!(!path.join(&owner.attempt_id).exists());
    assert_eq!(
        before,
        fs::read(journal.authority_root().join("state.json")).unwrap()
    );
    assert!(SourceSlot::open_at(&journal, owner).is_err());
}

#[test]
fn settlement_and_release_do_not_erase_allocation_before_retirement() {
    let (temp, journal) = fixture();
    let path = depot(temp.path());
    let owner = ready(&journal, true);
    allocate(&journal, &owner, &path, 1000).unwrap();
    assert!(SourceSlot::retire_at(&journal, &owner, 1000, |_| Ok(())).is_err());
    release(&journal, &owner);
    journal.prune(1021).unwrap();
    assert!(live(&journal, &owner));
    SourceSlot::retire_at(&journal, &owner, 1021, |_| Ok(())).unwrap();
    assert!(!path.join(&owner.attempt_id).exists());
    let before = fs::read(journal.authority_root().join("state.json")).unwrap();
    SourceSlot::retire_at(&journal, &owner, 1022, |_| Ok(())).unwrap();
    assert_eq!(
        before,
        fs::read(journal.authority_root().join("state.json")).unwrap()
    );
    journal.prune(1022).unwrap();
    assert!(!live(&journal, &owner));
}

#[test]
fn nonempty_or_reappeared_allocations_are_not_deleted_or_forgotten() {
    let (temp, journal) = fixture();
    let path = depot(temp.path());
    let owner = ready(&journal, true);
    allocate(&journal, &owner, &path, 1000).unwrap();
    let entry = path.join(&owner.attempt_id).join("unverified");
    fs::write(&entry, b"retain").unwrap();
    release(&journal, &owner);
    assert!(SourceSlot::retire_at(&journal, &owner, 1000, |_| Ok(())).is_err());
    assert_eq!(fs::read(&entry).unwrap(), b"retain");
    journal.prune(1021).unwrap();
    assert!(live(&journal, &owner));
    // Exact test-owned fixture cleanup, not the production retirement primitive.
    fs::remove_file(entry).unwrap();
    SourceSlot::retire_at(&journal, &owner, 1021, |_| Ok(())).unwrap();
    fs::create_dir(path.join(&owner.attempt_id)).unwrap();
    assert!(SourceSlot::retire_at(&journal, &owner, 1021, |_| Ok(())).is_err());
    assert!(path.join(&owner.attempt_id).is_dir());
    journal.prune(1021).unwrap();
    assert!(live(&journal, &owner));
}

#[test]
fn directory_replacement_and_symlinks_fail_closed() {
    for link in [false, true] {
        let (temp, journal) = fixture();
        let path = depot(temp.path());
        let owner = ready(&journal, true);
        allocate(&journal, &owner, &path, 1000).unwrap();
        let target = path.join(&owner.attempt_id);
        let saved = path.join("saved");
        fs::rename(&target, &saved).unwrap();
        if link {
            symlink(&saved, &target).unwrap();
        } else {
            fs::create_dir(&target).unwrap();
            fs::set_permissions(&target, fs::Permissions::from_mode(0o710)).unwrap();
        }
        assert!(SourceSlot::open_at(&journal, owner.clone()).is_err());
        release(&journal, &owner);
        assert!(SourceSlot::retire_at(&journal, &owner, 1000, |_| Ok(())).is_err());
        assert!(saved.is_dir());
        assert!(fs::symlink_metadata(&target).is_ok());
        assert!(!journal.source_allocation(&owner).unwrap().retired);
    }
}

#[test]
fn missing_or_replaced_data_authority_never_reinitializes() {
    let (temp, journal) = fixture();
    let path = depot(temp.path());
    let owner = ready(&journal, true);
    allocate(&journal, &owner, &path, 1000).unwrap();
    fs::rename(&path, path.with_file_name("saved")).unwrap();
    assert!(SourceSlot::open_at(&journal, owner.clone()).is_err());
    assert!(!path.exists());
    fs::create_dir(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    release(&journal, &owner);
    assert!(SourceSlot::retire_at(&journal, &owner, 1000, |_| Ok(())).is_err());
    assert!(!journal.source_allocation(&owner).unwrap().retired);
}

#[test]
fn foreign_owner_expiry_quarantine_and_backward_time_reject_before_mkdir() {
    for case in 0..4 {
        let (temp, journal) = fixture();
        let path = depot(temp.path());
        let mut owner = ready(&journal, true);
        let now = match case {
            0 => {
                owner.boot_id = "foreign".into();
                1000
            }
            1 => 1060,
            2 => {
                journal.quarantine(1000).unwrap();
                1000
            }
            _ => 999,
        };
        assert!(allocate(&journal, &owner, &path, now).is_err());
        assert_eq!(fs::read_dir(path).unwrap().count(), 0);
    }
}

#[test]
fn policy_and_unknown_preexisting_directory_reject_before_registration() {
    let (temp, journal) = fixture();
    let path = depot(temp.path());
    let owner = ready(&journal, true);
    for (uid, gid, limit) in [
        (0, 1000, limits()),
        (1000, 0, limits()),
        (
            1000,
            1000,
            Limits {
                entries: 0,
                ..limits()
            },
        ),
    ] {
        assert!(
            SourceSlot::allocate_at(
                &journal,
                owner.clone(),
                path.clone(),
                uid,
                gid,
                limit,
                1000,
                |_| Ok(())
            )
            .is_err()
        );
        assert!(journal.source_allocation(&owner).is_err());
    }
    fs::create_dir(path.join(&owner.attempt_id)).unwrap();
    assert!(allocate(&journal, &owner, &path, 1000).is_err());
    assert!(journal.source_allocation(&owner).is_err());
}

#[test]
fn private_data_cannot_alias_the_journal_lock_authority() {
    let (_temp, journal) = fixture();
    let owner = ready(&journal, true);
    assert!(
        allocate(&journal, &owner, journal.authority_root(), 1000)
            .err()
            .unwrap()
            .to_string()
            .contains("source and journal authorities overlap")
    );
    assert!(journal.source_allocation(&owner).is_err());
}

#[test]
fn child_death_preserves_creation_and_retirement_recovery_order() {
    for stop in [
        Point::Registered,
        Point::Created,
        Point::Permissions,
        Point::ParentSynced,
        Point::Bound,
    ] {
        let (temp, journal) = fixture();
        let path = depot(temp.path());
        let owner = ready(&journal, true);
        child_crash(&journal, &owner, &path, stop, "allocate", None);
        let journal = Journal::open(journal.authority_root(), identity(), policy()).unwrap();
        assert!(journal.source_allocation(&owner).is_ok());
        assert!(allocate(&journal, &owner, &path, 1000).is_err());
        release(&journal, &owner);
        journal.prune(1021).unwrap();
        assert!(live(&journal, &owner));
        SourceSlot::retire_at(&journal, &owner, 1021, |_| Ok(())).unwrap();
        journal.prune(1021).unwrap();
        assert!(!live(&journal, &owner));
    }
    for stop in [Point::Removed, Point::Retired] {
        let (temp, journal) = fixture();
        let path = depot(temp.path());
        let owner = ready(&journal, true);
        allocate(&journal, &owner, &path, 1000).unwrap();
        release(&journal, &owner);
        child_crash(&journal, &owner, &path, stop, "retire", None);
        let journal = Journal::open(journal.authority_root(), identity(), policy()).unwrap();
        assert!(!path.join(&owner.attempt_id).exists());
        SourceSlot::retire_at(&journal, &owner, 1000, |_| Ok(())).unwrap();
        journal.prune(1021).unwrap();
        assert!(!live(&journal, &owner));
    }
}

#[test]
fn mkdir_umask_and_inherited_setgid_gaps_retire_without_permission_rewrites() {
    for (parent_mode, mask, expected) in [(0o700, 0o200, 0o500), (0o2700, 0o200, 0o2500)] {
        let (temp, journal) = fixture();
        let path = depot(temp.path());
        fs::set_permissions(&path, fs::Permissions::from_mode(parent_mode)).unwrap();
        let owner = ready(&journal, true);
        child_crash(
            &journal,
            &owner,
            &path,
            Point::Created,
            "allocate",
            Some(mask),
        );
        let held = File::open(path.join(&owner.attempt_id)).unwrap();
        assert_eq!(held.metadata().unwrap().mode() & 0o7777, expected);
        release(&journal, &owner);
        SourceSlot::retire_at(&journal, &owner, 1000, |_| Ok(())).unwrap();
        assert_eq!(held.metadata().unwrap().mode() & 0o7777, expected);
        assert!(!path.join(&owner.attempt_id).exists());
        assert!(journal.source_allocation(&owner).unwrap().retired);
    }
}

#[test]
fn broadened_or_special_unbound_permissions_remain_tracked() {
    for mode in [0o750, 0o770, 0o711, 0o1700, 0o4700] {
        let (temp, journal) = fixture();
        let path = depot(temp.path());
        let owner = ready(&journal, true);
        assert!(
            SourceSlot::allocate_at(
                &journal,
                owner.clone(),
                path.clone(),
                1000,
                unsafe { libc::getegid() }.max(1),
                limits(),
                1000,
                |point| {
                    ensure!(!matches!(point, Point::Created), "creation gap");
                    Ok(())
                }
            )
            .is_err()
        );
        let target = path.join(&owner.attempt_id);
        fs::set_permissions(&target, fs::Permissions::from_mode(mode)).unwrap();
        release(&journal, &owner);
        assert!(SourceSlot::retire_at(&journal, &owner, 1000, |_| Ok(())).is_err());
        assert!(target.exists());
        assert!(!journal.source_allocation(&owner).unwrap().retired);
    }
}

#[test]
fn writable_nonsticky_ancestors_reject_before_registration_or_effects() {
    for mode in [0o770, 0o777] {
        let (temp, journal) = fixture();
        let base = temp.path().join("unsafe-data");
        let path = depot(&base);
        let owner = ready(&journal, true);
        fs::set_permissions(&base, fs::Permissions::from_mode(mode)).unwrap();
        let error = allocate(&journal, &owner, &path, 1000).err().unwrap();
        assert!(error.to_string().contains("writable ancestor"));
        assert!(journal.source_allocation(&owner).is_err());
        assert!(!path.join(&owner.attempt_id).exists());
    }
}

#[test]
fn trusted_sticky_ancestor_is_supported_but_later_loss_vetoes_retirement() {
    let (temp, journal) = fixture();
    let base = temp.path().join("shared-data");
    let path = depot(&base);
    let owner = ready(&journal, true);
    fs::set_permissions(&base, fs::Permissions::from_mode(0o1777)).unwrap();
    allocate(&journal, &owner, &path, 1000).unwrap();
    release(&journal, &owner);
    fs::set_permissions(&base, fs::Permissions::from_mode(0o777)).unwrap();
    assert!(SourceSlot::open_at(&journal, owner.clone()).is_err());
    assert!(SourceSlot::retire_at(&journal, &owner, 1000, |_| Ok(())).is_err());
    assert!(path.join(&owner.attempt_id).is_dir());
    assert!(!journal.source_allocation(&owner).unwrap().retired);
}

fn child_crash(
    journal: &Journal,
    owner: &Ownership,
    data: &Path,
    point: Point,
    operation: &str,
    mask: Option<u32>,
) {
    let mut command = std::process::Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--exact",
            "build_executor::private_sources::tests::worker",
            "--nocapture",
        ])
        .env_clear()
        .env("SOURCE_TEST_STATE", journal.authority_root())
        .env("SOURCE_TEST_OWNER", serde_json::to_string(owner).unwrap())
        .env("SOURCE_TEST_DATA", data)
        .env("SOURCE_TEST_POINT", format!("{point:?}"))
        .env("SOURCE_TEST_OPERATION", operation);
    if let Some(mask) = mask {
        command.env("SOURCE_TEST_MASK", mask.to_string());
    }
    assert_eq!(
        command.status().unwrap().code(),
        Some(79),
        "{operation}:{point:?}"
    );
}

#[test]
fn worker() {
    let Some(root) = std::env::var_os("SOURCE_TEST_STATE") else {
        return;
    };
    let journal = Journal::open(Path::new(&root), identity(), policy()).unwrap();
    let owner: Ownership =
        serde_json::from_str(&std::env::var("SOURCE_TEST_OWNER").unwrap()).unwrap();
    if let Ok(mask) = std::env::var("SOURCE_TEST_MASK") {
        unsafe {
            libc::umask(mask.parse().unwrap());
        }
    }
    let fault = |point: Point| {
        if format!("{point:?}") == std::env::var("SOURCE_TEST_POINT").unwrap() {
            unsafe {
                libc::_exit(79);
            }
        }
        Ok(())
    };
    match std::env::var("SOURCE_TEST_OPERATION").unwrap().as_str() {
        "allocate" => {
            let path = PathBuf::from(std::env::var_os("SOURCE_TEST_DATA").unwrap());
            SourceSlot::allocate_at(
                &journal,
                owner,
                path,
                1000,
                unsafe { libc::getegid() }.max(1),
                limits(),
                1000,
                fault,
            )
            .unwrap();
        }
        "retire" => SourceSlot::retire_at(&journal, &owner, 1000, fault).unwrap(),
        _ => panic!("unknown source test operation"),
    }
    panic!("source fault point not reached");
}
