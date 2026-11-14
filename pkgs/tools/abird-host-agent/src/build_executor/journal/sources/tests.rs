use super::*;
use crate::build_executor::journal::tests::{fixture, identity, policy, request};
use crate::build_executor::private_sources::data_root;
use std::os::unix::fs::PermissionsExt;

fn setup(root: &Path, journal: &Journal) -> (Ownership, Allocation) {
    let request = request("source");
    let key = journal
        .submit("operator", request, 1000)
        .unwrap()
        .attempt_id;
    journal.queue(&key, 1000).unwrap();
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    let owner = journal.reserve_next("boot", 1000).unwrap().unwrap();
    journal
        .started(
            ExecutionHandle {
                ownership: owner.clone(),
                invocation_id: "worker".into(),
            },
            1000,
        )
        .unwrap();
    let path = data_root(Some(root), None).unwrap();
    fs::create_dir_all(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    let meta = fs::metadata(&path).unwrap();
    let allocation = serde_json::from_value(serde_json::json!({
        "version": 1, "data_root": path,
        "authority": {"device": meta.dev(), "inode": meta.ino()},
        "source_uid": 1000, "reader_gid": 1000,
        "limits": {"entries": 128, "bytes": 65536, "depth": 16},
        "directory": null, "retired": false,
    }))
    .unwrap();
    (owner, allocation)
}

#[test]
fn input_receipt_survives_history_rotation_without_reopening_the_endpoint() {
    use crate::build_executor::diagnostics::{Activity, Diagnostic, Observation};
    use crate::build_executor::source_transport::{EndpointBinding, InputState};
    let (root, journal) = fixture();
    let (owner, allocation) = setup(root.path(), &journal);
    journal.register_source(&owner, allocation, 1000).unwrap();
    let directory = serde_json::from_value(serde_json::json!({"device": 1, "inode": 2})).unwrap();
    journal.bind_source(&owner, directory, 1000).unwrap();
    assert!(journal.input_event(&owner, None, 1000).is_err());
    journal
        .bind_source_endpoint(
            &owner,
            EndpointBinding {
                device: 1,
                inode: 3,
                parent_device: 1,
                parent_inode: 4,
            },
            1000,
        )
        .unwrap();
    journal.input_event(&owner, None, 1000).unwrap();
    assert!(journal.input_event(&owner, None, 1000).is_err());
    let digest = "a".repeat(64);
    journal
        .input_event(&owner, Some(digest.clone()), 1000)
        .unwrap();
    assert!(
        journal
            .input_event(&owner, Some(digest.clone()), 1000)
            .is_err()
    );
    let handle = ExecutionHandle {
        ownership: owner.clone(),
        invocation_id: "worker".into(),
    };
    for _ in 0..70 {
        journal
            .record_diagnostic(
                &handle,
                Diagnostic {
                    activity: Activity::Verify,
                    observation: Observation::Returned,
                },
                1000,
            )
            .unwrap();
    }
    let reopened = Journal::open(journal.authority_root(), identity(), policy()).unwrap();
    let events = reopened
        .events("operator", &owner.attempt_id, None, 32)
        .unwrap();
    assert!(
        events.gap
            && events.events.iter().all(|event| !matches!(
                event.detail,
                EventKind::InputReady | EventKind::InputsReceived { .. }
            ))
    );
    let status = reopened.status("operator", &owner.attempt_id).unwrap();
    assert!(
        matches!(status, JobStatus::Live { input: Some(InputState::Received { digest: received }), settled_at: None, .. } if received == digest)
    );
    assert!(reopened.input_event(&owner, None, 1000).is_err());
    assert!(
        reopened
            .input_event(&owner, Some("b".repeat(64)), 1000)
            .is_err()
    );
}

#[test]
fn source_registration_publication_uncertainty_never_authorizes_replay() {
    for point in [
        CommitPoint::Created,
        CommitPoint::Written,
        CommitPoint::FileSynced,
        CommitPoint::Renamed,
        CommitPoint::DirectorySynced,
    ] {
        let (temp, journal) = fixture();
        let (owner, allocation) = setup(temp.path(), &journal);
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "build_executor::journal::sources::tests::worker",
                "--nocapture",
            ])
            .env_clear()
            .env("SOURCE_JOURNAL_STATE", journal.authority_root())
            .env(
                "SOURCE_JOURNAL_OWNER",
                serde_json::to_string(&owner).unwrap(),
            )
            .env(
                "SOURCE_JOURNAL_ALLOCATION",
                serde_json::to_string(&allocation).unwrap(),
            )
            .env("SOURCE_JOURNAL_POINT", format!("{point:?}"))
            .status()
            .unwrap();
        assert_eq!(status.code(), Some(79), "{point:?}");
        let committed = matches!(point, CommitPoint::Renamed | CommitPoint::DirectorySynced);
        let reopened = Journal::open(
            journal.authority_root(),
            journal.identity().clone(),
            journal.admission_policy().clone(),
        )
        .unwrap();
        assert_eq!(reopened.source_allocation(&owner).is_ok(), committed);
        assert!(!allocation.data_root.join(&owner.attempt_id).exists());
        if committed {
            assert!(reopened.register_source(&owner, allocation, 1000).is_err());
        }
    }
}

#[test]
fn source_binding_is_immutable_and_same_binding_does_not_rewrite() {
    let (temp, journal) = fixture();
    let (owner, allocation) = setup(temp.path(), &journal);
    journal.register_source(&owner, allocation, 1000).unwrap();
    let id: DirectoryId =
        serde_json::from_value(serde_json::json!({"device": 1, "inode": 2})).unwrap();
    journal.bind_source(&owner, id.clone(), 1000).unwrap();
    let before = fs::read(journal.authority_root().join(STATE)).unwrap();
    journal.bind_source(&owner, id, 1001).unwrap();
    assert_eq!(
        before,
        fs::read(journal.authority_root().join(STATE)).unwrap()
    );
    let other = serde_json::from_value(serde_json::json!({"device": 1, "inode": 3})).unwrap();
    assert!(journal.bind_source(&owner, other, 1000).is_err());
    assert!(journal.retire_source(&owner, 1000).is_err());
}

#[test]
fn old_schema_and_corrupt_source_metadata_fail_without_reset() {
    for case in 0..3 {
        let (temp, journal) = fixture();
        let (owner, allocation) = setup(temp.path(), &journal);
        journal.register_source(&owner, allocation, 1000).unwrap();
        let directory = journal.lock().unwrap();
        let mut state = journal.read(&directory).unwrap();
        match case {
            0 => state.version = 5,
            1 => state.jobs[0].private_source.as_mut().unwrap().source_uid = 0,
            _ => state.jobs[0].private_source.as_mut().unwrap().retired = true,
        }
        let bytes = serde_json::to_vec(&EnvelopeRef {
            checksum: digest_bytes(&serde_json::to_vec(&state).unwrap()),
            state: &state,
        })
        .unwrap();
        fs::write(journal.authority_root().join(STATE), &bytes).unwrap();
        drop(directory);
        assert!(
            Journal::open(
                journal.authority_root(),
                journal.identity().clone(),
                journal.admission_policy().clone()
            )
            .is_err()
        );
        assert_eq!(
            bytes,
            fs::read(journal.authority_root().join(STATE)).unwrap()
        );
    }
}

#[test]
fn source_methods_are_not_caller_wire_verbs() {
    let (temp, journal) = fixture();
    let (_owner, _allocation) = setup(temp.path(), &journal);
    let before = fs::read(journal.authority_root().join(STATE)).unwrap();
    for kind in [
        "register_source",
        "bind_source",
        "retire_source",
        "allocate_source",
        "source_active",
    ] {
        let wire =
            serde_json::to_vec(&serde_json::json!({"version": 3, "command": {"kind": kind}}))
                .unwrap();
        let response = journal.handle("operator", &wire, 1000);
        assert!(matches!(
            response.reply,
            super::super::super::protocol::Reply::Rejected { .. }
        ));
    }
    assert_eq!(
        before,
        fs::read(journal.authority_root().join(STATE)).unwrap()
    );
}

#[test]
fn worker() {
    let Some(root) = std::env::var_os("SOURCE_JOURNAL_STATE") else {
        return;
    };
    let mut journal = Journal::open(Path::new(&root), identity(), policy()).unwrap();
    let owner = serde_json::from_str(&std::env::var("SOURCE_JOURNAL_OWNER").unwrap()).unwrap();
    let allocation =
        serde_json::from_str(&std::env::var("SOURCE_JOURNAL_ALLOCATION").unwrap()).unwrap();
    journal.fault = Some(|point| {
        if format!("{point:?}") == std::env::var("SOURCE_JOURNAL_POINT").unwrap() {
            unsafe {
                libc::_exit(79);
            }
        }
        Ok(())
    });
    journal.register_source(&owner, allocation, 1000).unwrap();
    panic!("source journal fault point not reached");
}
