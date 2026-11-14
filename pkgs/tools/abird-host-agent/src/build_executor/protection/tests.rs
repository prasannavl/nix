use super::*;
use crate::build_executor::journal::tests::{accepted, fixture, identity, policy};
use crate::build_executor::tests::wait_ready;
use crate::build_executor::{Phase, Settlement};
use std::process::Command;

fn paths() -> Vec<String> {
    vec![
        format!("/nix/store/{}-source", "0".repeat(32)),
        format!("/nix/store/{}-target.drv", "1".repeat(32)),
    ]
}
fn ready(journal: &Journal, root: &Path) -> (Gate, Ownership, NativeRoots) {
    let gate = Gate::initialize(&journal.authority_root().join("launch"), identity()).unwrap();
    let key = accepted(journal, "one").attempt_id;
    journal.queue(&key, 1000).unwrap();
    journal
        .recovered(0, gate.boot_id(), &"d".repeat(64), 1000)
        .unwrap();
    let owner = journal.reserve_next(gate.boot_id(), 1000).unwrap().unwrap();
    wait_ready(|| gate.try_fence())
        .publish(&Permit {
            version: 1,
            identity: identity(),
            permission: Permission::Execution {
                ownership: owner.clone(),
            },
        })
        .unwrap();
    let roots = NativeRoots::at(journal, owner.clone(), root, true, false).unwrap();
    (gate, owner, roots)
}
fn settle(journal: &Journal, gate: &Gate, owner: &Ownership) {
    let _fence = wait_ready(|| gate.try_fence());
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
}

#[test]
fn native_roots_are_additive_bound_and_reopen_without_realisation() {
    let (temp, journal) = fixture();
    let (gate, owner, roots) = ready(&journal, temp.path());
    let before = fs::read(journal.authority_root().join("state.json")).unwrap();
    assert!(roots.verify(&journal).is_err());
    let first = roots.retain(&journal, &gate, &paths()[..1]).unwrap();
    let second = roots.retain(&journal, &gate, &paths()).unwrap();
    assert_ne!(first.digest().unwrap(), second.digest().unwrap());
    let manifest = fs::read(roots.state.path.join("roots.json")).unwrap();
    assert_eq!(second, roots.retain(&journal, &gate, &paths()).unwrap());
    assert_eq!(
        manifest,
        fs::read(roots.state.path.join("roots.json")).unwrap()
    );
    let reopened = NativeRoots::at(&journal, owner.clone(), temp.path(), false, false).unwrap();
    assert_eq!(second, reopened.verify(&journal).unwrap());
    assert!(NativeRoots::at(&journal, owner.clone(), temp.path(), true, false).is_err());
    let mut foreign = owner;
    foreign.pool_epoch = std::num::NonZeroU64::new(foreign.pool_epoch.get() + 1).unwrap();
    assert!(NativeRoots::at(&journal, foreign, temp.path(), false, false).is_err());
    for path in paths() {
        assert_eq!(
            fs::read_link(roots.native_path(&path)).unwrap(),
            Path::new(&path)
        );
    }
    assert_eq!(
        before,
        fs::read(journal.authority_root().join("state.json")).unwrap()
    );
}

#[test]
fn retention_veto_survives_deadlines_cancellation_and_settlement() {
    let (temp, journal) = fixture();
    assert!(journal.retention_clear().unwrap());
    let (gate, owner, roots) = ready(&journal, temp.path());
    assert!(!journal.retention_clear().unwrap());
    roots.retain(&journal, &gate, &paths()).unwrap();
    assert!(roots.release(&journal, &"e".repeat(64), 1000).is_err());
    journal.expire(1013).unwrap();
    assert_eq!(
        crate::build_executor::journal::tests::live(&journal, &owner.attempt_id).phase(),
        Phase::Stopping
    );
    assert!(!journal.retention_clear().unwrap());
    let _fence = wait_ready(|| gate.try_fence());
    journal
        .settle(
            &owner.attempt_id,
            Settlement::FencedEmpty {
                ownership: owner.clone(),
            },
            None,
            1013,
        )
        .unwrap();
    assert!(!journal.retention_clear().unwrap());
    roots.release(&journal, &"e".repeat(64), 1013).unwrap();
    assert!(journal.retention_clear().unwrap());
    // This says nothing about the still-Recovering pool/unknown ingress or GC authority.
    assert_eq!(
        journal.pool().unwrap().health,
        super::super::PoolHealth::Recovering
    );
    assert!(roots.verify(&journal).is_err());
    roots.release(&journal, &"e".repeat(64), 1013).unwrap();
    assert!(roots.release(&journal, &"f".repeat(64), 1013).is_err());
    assert_eq!(fs::read_dir(&roots.native.path).unwrap().count(), 0);
}

#[test]
fn metadata_only_work_does_not_claim_store_protection() {
    let (_temp, journal) = fixture();
    let key = accepted(&journal, "one").attempt_id;
    assert!(journal.retention_clear().unwrap());
    journal.cancel("operator", &key, None, 1000).unwrap();
    journal.settle_unlaunched(1000).unwrap();
    assert!(journal.retention_clear().unwrap());
}

#[test]
fn fenced_bounded_and_malformed_publication_has_no_native_effect() {
    let (temp, journal) = fixture();
    let (gate, _owner, roots) = ready(&journal, temp.path());
    for input in [
        vec![],
        vec![paths()[0].clone(); MAX_ROOTS + 1],
        vec!["/nix/store/../elsewhere".into()],
    ] {
        assert!(roots.retain(&journal, &gate, &input).is_err());
    }
    let _fence = wait_ready(|| gate.try_fence());
    assert!(roots.retain(&journal, &gate, &paths()).is_err());
    assert_eq!(fs::read_dir(&roots.native.path).unwrap().count(), 0);
}

#[test]
fn missing_corrupt_and_redirected_metadata_never_reinitialize() {
    for kind in ["missing", "corrupt", "symlink"] {
        let (temp, journal) = fixture();
        let (_gate, owner, roots) = ready(&journal, temp.path());
        let manifest = roots.state.path.join("roots.json");
        fs::remove_file(&manifest).unwrap();
        if kind == "corrupt" {
            fs::write(&manifest, b"{}").unwrap();
        }
        if kind == "symlink" {
            symlink("missing-target", &manifest).unwrap();
        }
        assert!(NativeRoots::at(&journal, owner.clone(), temp.path(), false, false).is_err());
        if kind != "missing" {
            assert!(NativeRoots::at(&journal, owner, temp.path(), true, false).is_err());
        }
    }
}

#[test]
fn foreign_roots_and_replaced_directories_never_authorize_cleanup() {
    for kind in ["foreign-name", "foreign-target", "directory"] {
        let (temp, journal) = fixture();
        let (gate, owner, roots) = ready(&journal, temp.path());
        roots.retain(&journal, &gate, &paths()).unwrap();
        let alien = roots.native.path.join("unknown");
        if kind == "foreign-name" {
            symlink(&paths()[0], &alien).unwrap();
        }
        if kind == "foreign-target" {
            let slot = roots.native_path(&paths()[0]);
            fs::remove_file(&slot).unwrap();
            symlink(&paths()[1], &slot).unwrap();
        }
        if kind == "directory" {
            fs::rename(&roots.native.path, roots.native.path.with_extension("old")).unwrap();
            fs::create_dir(&roots.native.path).unwrap();
            symlink(&paths()[0], &alien).unwrap();
        }
        assert!(roots.verify(&journal).is_err());
        settle(&journal, &gate, &owner);
        assert!(roots.release(&journal, &"e".repeat(64), 1000).is_err());
        assert!(!journal.retention_clear().unwrap());
        assert!(
            !fs::read_dir(&roots.native.path)
                .unwrap()
                .collect::<Vec<_>>()
                .is_empty()
        );
    }
}

#[test]
fn partial_root_publication_is_retryable_without_replaying_nix() {
    for point in [
        "Created",
        "Written",
        "FileSynced",
        "Renamed",
        "DirectorySynced",
        "RootCreated",
        "RootsSynced",
    ] {
        let (temp, journal) = fixture();
        let (gate, owner, roots) = ready(&journal, temp.path());
        child_crash(temp.path(), &owner, point, "retain");
        assert!(!journal.retention_clear().unwrap());
        // An unpublished/partially published set is never a complete root receipt.
        assert!(roots.verify(&journal).is_err() || point == "RootsSynced");
        let reopened = NativeRoots::at(&journal, owner, temp.path(), false, false).unwrap();
        let expected = reopened.retain(&journal, &gate, &paths()).unwrap();
        assert_eq!(expected, reopened.verify(&journal).unwrap());
    }
}

#[test]
fn partial_release_never_clears_retention_before_durable_native_cleanup() {
    for point in [
        "Created",
        "Written",
        "FileSynced",
        "Renamed",
        "DirectorySynced",
        "ReleasePlanned",
        "RootRemoved",
        "ReleaseSynced",
    ] {
        let (temp, journal) = fixture();
        let (gate, owner, roots) = ready(&journal, temp.path());
        roots.retain(&journal, &gate, &paths()).unwrap();
        settle(&journal, &gate, &owner);
        child_crash(temp.path(), &owner, point, "release");
        assert!(!journal.retention_clear().unwrap());
        let reopened = NativeRoots::at(&journal, owner, temp.path(), false, false).unwrap();
        reopened.release(&journal, &"e".repeat(64), 1000).unwrap();
        assert!(journal.retention_clear().unwrap());
        assert_eq!(fs::read_dir(&roots.native.path).unwrap().count(), 0);
        assert!(roots.retain(&journal, &gate, &paths()).is_err());
    }
}

#[test]
fn pruning_waits_for_crash_recoverable_root_retirement() {
    for point in ["NativeRetired", "ManifestRemoved", "StateRetired"] {
        let (temp, journal) = fixture();
        let (gate, owner, roots) = ready(&journal, temp.path());
        roots.retain(&journal, &gate, &paths()).unwrap();
        assert!(NativeRoots::retire_at(&journal, &owner, temp.path(), |_| Ok(())).is_err());
        settle(&journal, &gate, &owner);
        roots.release(&journal, &"e".repeat(64), 1000).unwrap();
        journal.prune(1021).unwrap();
        assert!(matches!(
            journal.status("operator", &owner.attempt_id).unwrap(),
            crate::build_executor::journal::JobStatus::Live { .. }
        ));
        child_crash(temp.path(), &owner, point, "retire");
        NativeRoots::retire_at(&journal, &owner, temp.path(), |_| Ok(())).unwrap();
        NativeRoots::retire_at(&journal, &owner, temp.path(), |_| Ok(())).unwrap();
        assert!(!roots.state.path.exists() && !roots.native.path.exists());
        journal.prune(1021).unwrap();
        assert!(matches!(
            journal.status("operator", &owner.attempt_id).unwrap(),
            crate::build_executor::journal::JobStatus::Retired { .. }
        ));
    }
}

#[test]
fn oversized_old_and_misbound_root_records_are_not_receipts() {
    for kind in ["oversized", "old", "misbound", "checksum"] {
        let (temp, journal) = fixture();
        let (gate, _owner, roots) = ready(&journal, temp.path());
        roots.retain(&journal, &gate, &paths()).unwrap();
        let path = roots.state.path.join("roots.json");
        let mut envelope: Envelope = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        match kind {
            "old" => envelope.record.roots.version = 0,
            "misbound" => envelope.record.roots.spec_digest = "f".repeat(64),
            _ => {}
        }
        envelope.checksum = if kind == "checksum" {
            "a".repeat(64)
        } else {
            digest_bytes(&serde_json::to_vec(&envelope.record).unwrap())
        };
        let bytes = if kind == "oversized" {
            vec![b' '; MAX_BYTES as usize + 1]
        } else {
            serde_json::to_vec(&envelope).unwrap()
        };
        fs::write(&path, bytes).unwrap();
        assert!(roots.verify(&journal).is_err());
        assert!(roots.retain(&journal, &gate, &paths()).is_err());
    }
}

fn child_crash(root: &Path, owner: &Ownership, point: &str, operation: &str) {
    let status = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "build_executor::protection::tests::worker",
            "--nocapture",
        ])
        .env("OWNED_ROOT_TEST", root)
        .env("OWNED_ROOT_OWNER", serde_json::to_string(owner).unwrap())
        .env("OWNED_ROOT_POINT", point)
        .env("OWNED_ROOT_OP", operation)
        .status()
        .unwrap();
    assert_eq!(status.code(), Some(79), "{operation}:{point}");
}

#[test]
fn worker() {
    let Some(root) = std::env::var_os("OWNED_ROOT_TEST") else {
        return;
    };
    let root = PathBuf::from(root);
    let owner: Ownership =
        serde_json::from_str(&std::env::var("OWNED_ROOT_OWNER").unwrap()).unwrap();
    let journal = Journal::open(&root.join("authority"), identity(), policy()).unwrap();
    let gate = Gate::open(&journal.authority_root().join("launch"), identity()).unwrap();
    let mut roots = NativeRoots::at(&journal, owner, &root, false, false).unwrap();
    roots.fault = Some(|point| {
        if format!("{point:?}") == std::env::var("OWNED_ROOT_POINT").unwrap() {
            std::process::exit(79);
        }
        Ok(())
    });
    match std::env::var("OWNED_ROOT_OP").unwrap().as_str() {
        "retain" => {
            roots.retain(&journal, &gate, &paths()).unwrap();
        }
        "release" => roots.release(&journal, &"e".repeat(64), 1000).unwrap(),
        "retire" => {
            NativeRoots::retire_at(&journal, &roots.owner, &root, |point| roots.point(point))
                .unwrap()
        }
        _ => panic!("unknown operation"),
    }
    panic!("fault point not reached");
}
