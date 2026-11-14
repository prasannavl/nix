use std::os::fd::AsRawFd;
use std::os::unix::fs::{PermissionsExt, symlink};

use super::*;
use crate::build_executor::Settlement;
use crate::build_executor::journal::tests::{accepted, fixture, identity};

/// Expected-free locks only. Another test thread's fork holds a duplicate of a
/// just-released CLOEXEC descriptor until its exec; wait that out, bounded.
/// Expected-busy assertions stay immediate.
fn eventually<T>(mut acquire: impl FnMut() -> Result<Option<T>>) -> T {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        if let Some(guard) = acquire().unwrap() {
            return guard;
        }
        assert!(std::time::Instant::now() < deadline, "lock stayed busy");
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
}

fn setup() -> (tempfile::TempDir, Journal, StoreInterlock) {
    let (root, journal) = fixture();
    let path = root.path().join("store");
    fs::create_dir(&path).unwrap();
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    let store = StoreInterlock::at(&path, identity()).unwrap();
    (root, journal, store)
}

#[test]
fn shared_and_exclusive_guards_interoperate_with_native_flock_and_are_cloexec() {
    let (_root, journal, store) = setup();
    let first = eventually(|| store.try_admission(&journal));
    let second = eventually(|| store.try_admission(&journal));
    let native = File::open(&store.root).unwrap();
    assert_ne!(
        unsafe { libc::fcntl(first._directory.as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC,
        0
    );
    assert_eq!(
        unsafe { libc::flock(native.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
        -1
    );
    assert_eq!(
        std::io::Error::last_os_error().kind(),
        std::io::ErrorKind::WouldBlock
    );
    assert!(store.try_retention_check(&journal).unwrap().is_none());
    drop(first);
    assert!(store.try_retention_check(&journal).unwrap().is_none());
    drop(second);
    eventually(|| {
        Ok(
            (unsafe { libc::flock(native.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0)
                .then_some(()),
        )
    });
    assert!(store.try_admission(&journal).unwrap().is_none());
    assert!(store.try_retention_check(&journal).unwrap().is_none());
    drop(native);
    let checked = eventually(|| store.try_retention_check(&journal));
    assert_ne!(
        unsafe { libc::fcntl(checked._directory.as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC,
        0
    );
    assert!(store.try_admission(&journal).unwrap().is_none());
    drop(checked);
    drop(eventually(|| store.try_admission(&journal)));
}

#[test]
fn reservation_veto_survives_descriptor_loss_expiry_and_settlement_until_release_and_recovery() {
    let (_root, journal, store) = setup();
    let key = accepted(&journal, "prepublication").attempt_id;
    journal.queue(&key, 1000).unwrap();
    drop(eventually(|| store.try_retention_check(&journal)));
    let guard = eventually(|| store.try_admission(&journal));
    let owner = journal.reserve_next("boot", 1000).unwrap().unwrap();
    // Metadata only: no inputs, preparation or native roots have been published.
    drop(guard);
    let native = File::open(&store.root).unwrap();
    eventually(|| Ok(native.try_lock().ok()));
    drop(native);
    assert!(store.try_retention_check(&journal).unwrap().is_none());
    journal.expire(1013).unwrap();
    assert!(store.try_retention_check(&journal).unwrap().is_none());
    journal
        .settle(
            &key,
            Settlement::FencedEmpty {
                ownership: owner.clone(),
            },
            None,
            1013,
        )
        .unwrap();
    assert!(store.try_retention_check(&journal).unwrap().is_none());
    journal.released(&key, &"e".repeat(64), 1013).unwrap();
    assert!(journal.retention_clear().unwrap());
    // Even a clear retention predicate does not imply a reconciled pool.
    assert!(store.try_retention_check(&journal).unwrap().is_none());
    journal
        .recovered(owner.pool_epoch.get(), "boot", &"d".repeat(64), 1013)
        .unwrap();
    drop(eventually(|| store.try_retention_check(&journal)));
}

#[test]
fn journal_identity_alias_and_corruption_never_grant_a_retention_check() {
    let (_root, journal, store) = setup();
    let mut other = identity();
    other.store_id = "another-store".into();
    let foreign = StoreInterlock::at(&store.root, other).unwrap();
    assert!(foreign.try_admission(&journal).is_err());
    assert!(foreign.try_retention_check(&journal).is_err());
    let alias = StoreInterlock::at(journal.authority_root(), identity()).unwrap();
    assert!(alias.try_admission(&journal).is_err());
    assert!(alias.try_retention_check(&journal).is_err());
    fs::write(journal.authority_root().join("state.json"), b"invalid").unwrap();
    assert!(store.try_retention_check(&journal).is_err());
}

#[test]
fn missing_replaced_or_redirected_lock_inode_is_not_recreated_or_adopted() {
    let (root, journal, store) = setup();
    fs::rename(&store.root, root.path().join("old-store")).unwrap();
    assert!(store.try_admission(&journal).is_err());
    assert!(!store.root.exists());
    fs::create_dir(&store.root).unwrap();
    assert!(store.try_admission(&journal).is_err());
    assert!(store.try_retention_check(&journal).is_err());
    fs::remove_dir(&store.root).unwrap();
    symlink(root.path().join("old-store"), &store.root).unwrap();
    assert!(store.try_admission(&journal).is_err());
    assert!(StoreInterlock::at(&store.root, identity()).is_err());
}

#[test]
fn writable_leaf_or_nonsticky_ancestor_is_rejected_without_chmod_or_creation() {
    let (root, journal, store) = setup();
    fs::set_permissions(&store.root, fs::Permissions::from_mode(0o777)).unwrap();
    assert!(store.try_admission(&journal).is_err());
    assert_eq!(fs::metadata(&store.root).unwrap().mode() & 0o777, 0o777);
    fs::set_permissions(&store.root, fs::Permissions::from_mode(0o755)).unwrap();
    fs::set_permissions(root.path(), fs::Permissions::from_mode(0o777)).unwrap();
    assert!(store.try_retention_check(&journal).is_err());
    fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
    drop(eventually(|| store.try_retention_check(&journal)));
}

#[test]
fn store_guards_do_not_hold_the_journal_transaction_or_clear_quarantine() {
    let (_root, journal, store) = setup();
    let guard = eventually(|| store.try_admission(&journal));
    let key = accepted(&journal, "status").attempt_id;
    journal.queue(&key, 1000).unwrap();
    journal.status("operator", &key).unwrap();
    journal.cancel("operator", &key, None, 1000).unwrap();
    journal.quarantine(1000).unwrap();
    drop(guard);
    assert!(store.try_retention_check(&journal).unwrap().is_none());
    assert_eq!(journal.pool().unwrap().health, PoolHealth::Quarantined);
}
