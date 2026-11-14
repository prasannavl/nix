use super::*;
use crate::build_executor::RecoveryAction;
use crate::build_executor::context::{BuildAction, EvaluationIntent, InputLocation, PlanJobs};
use crate::build_executor::request::*;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::process::{Command, Stdio};
use std::sync::Arc;

pub(in crate::build_executor) fn identity() -> StorageIdentity {
    StorageIdentity {
        authority_id: "authority".into(),
        builder_id: "ci".into(),
        store_id: "ci-store".into(),
    }
}
pub(in crate::build_executor) fn policy() -> AdmissionPolicy {
    AdmissionPolicy {
        capacity_digest: "c".repeat(64),
        max_jobs: 1,
        max_cores: 2,
        submission_age_seconds: 60,
        future_skew_seconds: 2,
        replay_seconds: 120,
        deadlines: Deadlines {
            heartbeat_seconds: 2,
            stale_seconds: 6,
            owner_seconds: 12,
            queue_seconds: 30,
            runtime_seconds: 60,
            stop_grace_seconds: 3,
            stop_limit_seconds: 10,
            retention_seconds: 20,
        },
    }
}
pub(in crate::build_executor) fn request(nonce: &str) -> BuildRequest {
    BuildRequest {
        parent: None,
        schema_version: REQUEST_VERSION,
        executor_version: 1,
        id: RequestId {
            issued_at: 1000,
            nonce: nonce.into(),
        },
        run_id: "run".into(),
        issuer: "operator".into(),
        repository_id: "repo".into(),
        source: Source {
            revision: "a".repeat(40),
            base_revision: "a".repeat(40),
            tree_digest: Some("b".repeat(64)),
            patch_digest: None,
        },
        controller: Peer {
            host_id: "controller".into(),
            fabric_id: "fleet".into(),
        },
        builder: Peer {
            host_id: "ci".into(),
            fabric_id: "fleet".into(),
        },
        storage: identity(),
        mode: BuildMode::System,
        evaluation: EvaluationIntent {
            version: 1,
            action: BuildAction::Build,
            build_flake: InputLocation::source(""),
            inventory: InputLocation::source("hosts/nixbot.nix"),
            overlay: None,
            repository_config: None,
            dependency_flake: InputLocation::source(""),
            plan_jobs: PlanJobs::Auto,
            deploy_jobs_per_domain: None,
        },
        selection: Selection::Exact {
            targets: vec![BuildTarget {
                host: "app".into(),
                configuration: "app".into(),
                outputs: vec!["out".into()],
            }],
        },
        required_hosts: vec!["app".into()],
        nix: NixOptions {
            max_jobs: 1,
            cores: 2,
            substitute: true,
        },
        policy_digest: policy().digest().unwrap(),
        deadlines: policy().deadlines,
        owner: Owner::Foreground {
            token_digest: digest_bytes(b"synthetic-token"),
        },
        predecessor: None,
    }
}
fn exact(request: &mut BuildRequest) -> &mut Vec<BuildTarget> {
    let Selection::Exact { targets } = &mut request.selection else {
        panic!()
    };
    targets
}
pub(in crate::build_executor) fn inputs(request: &BuildRequest) -> PreparedInputs {
    let Selection::Exact { targets } = &request.selection else {
        panic!()
    };
    PreparedInputs {
        version: super::super::preparation::VERSION,
        attempt_id: request.attempt_id().unwrap(),
        spec_digest: request.digest().unwrap(),
        source_path: format!("/nix/store/{}-source", "0".repeat(32)),
        tree_digest: request.source.tree_digest.clone().unwrap_or("b".repeat(64)),
        evaluation_digest: request.evaluation.digest().unwrap(),
        context_sources: std::collections::BTreeMap::new(),
        caller_repository: None,
        resolved: targets
            .iter()
            .map(|target| super::super::preparation::ResolvedTarget {
                host: target.host.clone(),
                configuration: target.configuration.clone(),
                disposition: super::super::preparation::Disposition::Build,
            })
            .collect(),
        targets: targets
            .iter()
            .map(|target| super::super::preparation::PreparedTarget {
                target: target.clone(),
                derivation: format!("/nix/store/{}-system.drv", "0".repeat(32)),
            })
            .collect(),
        required_hosts: request.required_hosts.clone(),
        selection_digest: "c".repeat(64),
        planning_digest: None,
        protection_digest: "d".repeat(64),
    }
}
pub(in crate::build_executor) fn fixture() -> (tempfile::TempDir, Journal) {
    let root = tempfile::tempdir().unwrap();
    let journal =
        Journal::initialize(&root.path().join("authority"), identity(), policy(), 1000).unwrap();
    (root, journal)
}
pub(in crate::build_executor) fn live(journal: &Journal, key: &str) -> Attempt {
    match journal.status("operator", key).unwrap() {
        JobStatus::Live { attempt, .. } => *attempt,
        _ => panic!("expected live record"),
    }
}
pub(in crate::build_executor) fn accepted(journal: &Journal, nonce: &str) -> Acceptance {
    journal.submit("operator", request(nonce), 1000).unwrap()
}
fn reserve(journal: &Journal, key: &str) -> Ownership {
    journal.queue(key, 1000).unwrap();
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    journal.reserve_next("boot", 1000).unwrap().unwrap()
}
fn cancel_settle(journal: &Journal, key: &str, owner: Option<&Ownership>, now: u64) {
    journal.cancel("operator", key, owner, now).unwrap();
    let evidence = owner.map_or(Settlement::Unlaunched, |owner| Settlement::FencedEmpty {
        ownership: owner.clone(),
    });
    journal.settle(key, evidence, None, now).unwrap();
}

#[test]
fn request_schema_binds_exact_source_outputs_and_rejects_unsafe_inputs() {
    let original = request("one");
    let mut replacement = original.clone();
    replacement.storage.authority_id = "replacement-authority".into();
    assert_ne!(
        replacement.attempt_id().unwrap(),
        original.attempt_id().unwrap()
    );
    let encoded = serde_json::to_vec(&original).unwrap();
    assert_eq!(BuildRequest::decode(&encoded).unwrap(), original);
    let mut value = serde_json::to_value(&original).unwrap();
    value["nix"]["extra_flags"] = "--store local".into();
    assert!(BuildRequest::decode(&serde_json::to_vec(&value).unwrap()).is_err());
    for mutation in [
        |r: &mut BuildRequest| r.schema_version = 1,
        |r: &mut BuildRequest| r.source.revision = "HEAD".into(),
        |r: &mut BuildRequest| exact(r)[0].configuration = "../input".into(),
        |r: &mut BuildRequest| exact(r)[0].outputs.push("out".into()),
        |r: &mut BuildRequest| r.required_hosts.push("missing".into()),
        |r: &mut BuildRequest| r.nix.cores = 0,
        |r: &mut BuildRequest| r.builder.host_id = "other".into(),
        |r: &mut BuildRequest| r.id.nonce = "../escape".into(),
        |r: &mut BuildRequest| r.source.tree_digest = Some("bad".into()),
    ] {
        let mut changed = original.clone();
        mutation(&mut changed);
        assert!(changed.validate().is_err());
    }
    assert!(BuildRequest::decode(&vec![b' '; MAX_REQUEST_BYTES + 1]).is_err());
    let mut changed = original.clone();
    exact(&mut changed)[0].configuration = "other".into();
    assert_eq!(
        changed.attempt_id().unwrap(),
        original.attempt_id().unwrap()
    );
    assert_ne!(changed.digest().unwrap(), original.digest().unwrap());
}

#[test]
fn xdg_resolution_has_no_legacy_or_relative_fallback() {
    assert_eq!(
        state_root(Some(Path::new("/state")), None).unwrap(),
        Path::new("/state/abird/abird-host-agent/owned-build")
    );
    assert_eq!(
        state_root(None, Some(Path::new("/home/service"))).unwrap(),
        Path::new("/home/service/.local/state/abird/abird-host-agent/owned-build")
    );
    assert!(
        state_root(
            Some(Path::new("relative")),
            Some(Path::new("/home/service"))
        )
        .is_err()
    );
    assert!(state_root(None, Some(Path::new("relative"))).is_err());
    assert!(state_root(None, None).is_err());
}

#[test]
fn acceptance_is_durable_idempotent_and_issuer_spec_fenced() {
    let (_root, journal) = fixture();
    let acceptance = accepted(&journal, "one");
    let reopened = Journal::open(&journal.root, identity(), policy()).unwrap();
    assert_eq!(
        reopened.submit("operator", request("one"), 1001).unwrap(),
        acceptance
    );
    let mut changed = request("one");
    changed.source.tree_digest = Some("f".repeat(64));
    assert!(reopened.submit("operator", changed, 1001).is_err());
    assert!(reopened.submit("intruder", request("one"), 1001).is_err());
    assert!(reopened.status("intruder", &acceptance.attempt_id).is_err());
    assert_eq!(
        live(&reopened, &acceptance.attempt_id).phase(),
        Phase::Pending
    );
    // Late retries return the retained job, not a newly timed execution.
    assert_eq!(
        reopened.submit("operator", request("one"), 2000).unwrap(),
        acceptance
    );
}

#[test]
fn policy_storage_and_time_mismatches_fail_closed() {
    let (_root, journal) = fixture();
    let mut other = identity();
    other.store_id = "elsewhere".into();
    assert!(Journal::open(&journal.root, other, policy()).is_err());
    let mut new_policy = policy();
    new_policy.max_cores = 3;
    assert!(Journal::open(&journal.root, identity(), new_policy).is_err());
    for mutation in [
        |r: &mut BuildRequest| r.nix.cores = 3,
        |r: &mut BuildRequest| r.id.issued_at = 900,
        |r: &mut BuildRequest| r.id.issued_at = 1003,
        |r: &mut BuildRequest| r.deadlines.owner_seconds += 1,
        |r: &mut BuildRequest| r.policy_digest = "0".repeat(64),
    ] {
        let mut changed = request("one");
        mutation(&mut changed);
        assert!(journal.submit("operator", changed, 1000).is_err());
    }
    accepted(&journal, "one");
    journal.prune(1001).unwrap();
    assert!(journal.prune(1000).is_err());
}

#[test]
fn initialization_is_explicit_and_missing_or_corrupt_authority_never_resets() {
    let (_root, journal) = fixture();
    assert!(Journal::initialize(&journal.root, identity(), policy(), 1000).is_err());
    fs::write(journal.root.join(STATE), b"partial").unwrap();
    assert!(Journal::open(&journal.root, identity(), policy()).is_err());
    fs::remove_file(journal.root.join(STATE)).unwrap();
    assert!(Journal::open(&journal.root, identity(), policy()).is_err());
    assert!(Journal::initialize(&journal.root, identity(), policy(), 1000).is_err());
}

#[test]
fn checksum_permissions_symlinks_and_hardlinks_are_checked() {
    let (root, journal) = fixture();
    let state_path = journal.root.join(STATE);
    let original = fs::read(&state_path).unwrap();
    let mut value: serde_json::Value = serde_json::from_slice(&original).unwrap();
    value["state"]["last_time"] = 1001.into();
    fs::write(&state_path, serde_json::to_vec(&value).unwrap()).unwrap();
    assert!(journal.pool().is_err());
    fs::write(&state_path, &original).unwrap();
    fs::set_permissions(&state_path, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(journal.pool().is_err());
    fs::set_permissions(&state_path, fs::Permissions::from_mode(0o600)).unwrap();
    let alias = root.path().join("alias");
    fs::hard_link(&state_path, &alias).unwrap();
    assert!(journal.pool().is_err());
    fs::remove_file(&alias).unwrap();
    fs::rename(&state_path, &alias).unwrap();
    symlink(&alias, &state_path).unwrap();
    assert!(journal.pool().is_err());
    fs::remove_file(&state_path).unwrap();
    fs::rename(&alias, &state_path).unwrap();
    symlink(&journal.root, &alias).unwrap();
    assert!(Journal::open(&alias, identity(), policy()).is_err());
}

#[test]
fn directory_replacement_is_not_a_second_lock_lane() {
    let (root, journal) = fixture();
    fs::rename(&journal.root, root.path().join("old")).unwrap();
    let _other = Journal::initialize(&journal.root, identity(), policy(), 1000).unwrap();
    assert!(journal.pool().is_err());
}

#[test]
fn admission_is_fifo_and_requires_fresh_recovery_and_owner() {
    let (_root, journal) = fixture();
    let first = accepted(&journal, "z-first");
    let second = accepted(&journal, "a-second");
    assert!(journal.reserve_next("boot", 1000).is_err());
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    journal.queue(&second.attempt_id, 1000).unwrap();
    assert!(journal.reserve_next("boot", 1000).unwrap().is_none());
    journal.queue(&first.attempt_id, 1000).unwrap();
    assert!(journal.reserve_next("another-boot", 1000).is_err());
    assert!(journal.reserve_next("boot", 1006).unwrap().is_none());
    journal
        .renew(
            "operator",
            &first.attempt_id,
            None,
            b"synthetic-token",
            1006,
        )
        .unwrap();
    let owner = journal.reserve_next("boot", 1006).unwrap().unwrap();
    assert_eq!(owner.attempt_id, first.attempt_id);
    assert!(journal.reserve_next("boot", 1006).is_err());
    assert_eq!(journal.pool().unwrap().epoch, 1);
}

#[test]
fn cancellation_expiry_and_late_start_cannot_release_unknown_work() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "one").attempt_id;
    let owner = reserve(&journal, &key);
    assert!(journal.cancel("operator", &key, None, 1000).is_err());
    assert!(
        journal
            .renew("operator", &key, Some(&owner), b"wrong", 1000)
            .is_err()
    );
    journal.expire(1012).unwrap();
    let handle = ExecutionHandle {
        ownership: owner.clone(),
        invocation_id: "invocation".into(),
    };
    journal.started(handle.clone(), 1012).unwrap();
    journal
        .client_exited(&handle, ClientExit::Success, 1012)
        .unwrap();
    assert_eq!(live(&journal, &key).phase(), Phase::Stopping);
    assert!(live(&journal, &key).outcome().is_none());
    assert!(
        journal
            .renew("operator", &key, Some(&owner), b"synthetic-token", 1012)
            .is_err()
    );
    assert!(journal.released(&key, &"e".repeat(64), 1012).is_err());
    journal.prune(2000).unwrap();
    assert_eq!(journal.pool().unwrap().owner, Some(owner.clone()));
    assert!(journal.recovered(1, "boot", &"d".repeat(64), 2000).is_err());
    journal
        .settle(
            &key,
            Settlement::FencedEmpty { ownership: owner },
            None,
            2000,
        )
        .unwrap();
    assert_eq!(
        live(&journal, &key).outcome(),
        Some(&Outcome::Cancelled {
            reason: StopReason::OwnerExpired
        })
    );
    assert_eq!(journal.pool().unwrap().health, PoolHealth::Recovering);
}

#[test]
fn queued_cancel_needs_unlaunched_receipt_and_cannot_later_launch() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "one").attempt_id;
    journal.cancel("operator", &key, None, 1000).unwrap();
    assert!(journal.queue(&key, 1000).is_err());
    assert!(live(&journal, &key).outcome().is_none());
    journal
        .settle(&key, Settlement::Unlaunched, None, 1000)
        .unwrap();
    assert_eq!(live(&journal, &key).phase(), Phase::Cancelled);
}

#[test]
fn terminal_receipts_and_releases_are_immutable() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "one").attempt_id;
    let owner = reserve(&journal, &key);
    let handle = ExecutionHandle {
        ownership: owner,
        invocation_id: "invocation".into(),
    };
    journal.started(handle.clone(), 1000).unwrap();
    let preparation_digest = journal
        .record_prepared(&handle.ownership, inputs(&request("one")), 1000)
        .unwrap();
    journal
        .client_exited(&handle, ClientExit::Success, 1000)
        .unwrap();
    let artifacts = ArtifactReceipt {
        preparation_digest,
        spec_digest: request("one").digest().unwrap(),
        closure_digest: "e".repeat(64),
        roots_digest: "f".repeat(64),
    };
    let evidence = Settlement::Idle { handle };
    journal
        .settle(&key, evidence.clone(), Some(artifacts.clone()), 1001)
        .unwrap();
    journal
        .settle(&key, evidence.clone(), Some(artifacts), 1002)
        .unwrap();
    assert!(journal.settle(&key, evidence, None, 1002).is_err());
    journal.released(&key, &"a".repeat(64), 1002).unwrap();
    assert!(journal.released(&key, &"b".repeat(64), 1002).is_err());
    assert_eq!(live(&journal, &key).phase(), Phase::Succeeded);
}

#[test]
fn reboot_is_interruption_and_epochs_fence_delayed_controls() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "one").attempt_id;
    let old = reserve(&journal, &key);
    journal
        .settle(
            &key,
            Settlement::Rebooted {
                ownership: old.clone(),
                new_boot_id: "boot-two".into(),
            },
            None,
            1001,
        )
        .unwrap();
    assert_eq!(live(&journal, &key).phase(), Phase::Interrupted);
    let mut next = request("two");
    next.predecessor = Some(key.clone());
    let next_key = journal.submit("operator", next, 1001).unwrap().attempt_id;
    journal.queue(&next_key, 1001).unwrap();
    assert!(
        journal
            .recovered(0, "boot-two", &"d".repeat(64), 1001)
            .is_err()
    );
    journal
        .recovered(1, "boot-two", &"d".repeat(64), 1001)
        .unwrap();
    let new = journal.reserve_next("boot-two", 1001).unwrap().unwrap();
    assert_eq!(new.pool_epoch.get(), 2);
    assert!(
        journal
            .cancel("operator", &next_key, Some(&old), 1001)
            .is_err()
    );
    assert_eq!(journal.pool().unwrap().owner, Some(new));
    let mut duplicate = request("three");
    duplicate.predecessor = Some(key);
    assert!(journal.submit("operator", duplicate, 1001).is_err());
}

#[test]
fn retention_requires_release_and_replay_floor_prevents_resurrection() {
    let (_root, journal) = fixture();
    let acceptance = accepted(&journal, "one");
    cancel_settle(&journal, &acceptance.attempt_id, None, 1000);
    journal.prune(1040).unwrap();
    assert!(matches!(
        journal.status("operator", &acceptance.attempt_id).unwrap(),
        JobStatus::Live { .. }
    ));
    journal
        .released(&acceptance.attempt_id, &"e".repeat(64), 1040)
        .unwrap();
    journal.prune(1040).unwrap();
    assert!(matches!(
        journal.status("operator", &acceptance.attempt_id).unwrap(),
        JobStatus::Retired { .. }
    ));
    assert_eq!(
        journal.submit("operator", request("one"), 1040).unwrap(),
        acceptance
    );
    journal.prune(1201).unwrap();
    assert!(journal.status("operator", &acceptance.attempt_id).is_err());
    assert!(journal.submit("operator", request("one"), 1201).is_err());
    let mut changed = request("one");
    changed.source.tree_digest = Some("e".repeat(64));
    assert!(journal.submit("operator", changed, 1201).is_err());
    let directory = journal.lock().unwrap();
    assert_eq!(journal.read(&directory).unwrap().replay_floor, 1081);
}

#[test]
fn detached_runtime_and_foreground_queue_deadlines_still_require_settlement() {
    let (_root, journal) = fixture();
    let mut spec = request("one");
    spec.owner = Owner::Detached;
    let key = journal.submit("operator", spec, 1000).unwrap().attempt_id;
    let owner = reserve(&journal, &key);
    journal.expire(1060).unwrap();
    assert_eq!(live(&journal, &key).phase(), Phase::Stopping);
    assert_eq!(journal.pool().unwrap().owner, Some(owner));
    assert!(
        journal
            .renew("operator", &key, None, b"synthetic-token", 1060)
            .is_err()
    );
    let (_root2, other) = fixture();
    let key = accepted(&other, "queue").attempt_id;
    other
        .renew("operator", &key, None, b"synthetic-token", 1005)
        .unwrap();
    other.expire(1030).unwrap();
    assert_eq!(live(&other, &key).phase(), Phase::Stopping);
}

#[test]
fn concurrent_threads_share_one_admission_authority() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "one").attempt_id;
    journal.queue(&key, 1000).unwrap();
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    let journal = Arc::new(journal);
    let workers: Vec<_> = (0..8)
        .map(|_| {
            let journal = Arc::clone(&journal);
            std::thread::spawn(move || journal.reserve_next("boot", 1000).is_ok())
        })
        .collect();
    let winners = workers
        .into_iter()
        .map(|worker| worker.join().unwrap())
        .filter(|won| *won)
        .count();
    assert_eq!(winners, 1);
    assert_eq!(journal.pool().unwrap().epoch, 1);
}

fn child(root: &Path, operation: &str, point: &str) -> Command {
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--exact",
            "build_executor::journal::tests::worker_process",
            "--nocapture",
        ])
        .env("OWNED_TEST_ROOT", root)
        .env("OWNED_TEST_OPERATION", operation)
        .env("OWNED_TEST_POINT", point)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

#[test]
fn worker_process() {
    let Some(root) = std::env::var_os("OWNED_TEST_ROOT") else {
        return;
    };
    let mut journal = Journal::open(Path::new(&root), identity(), policy()).unwrap();
    let operation = std::env::var("OWNED_TEST_OPERATION").unwrap();
    if operation.starts_with("crash-") {
        journal.fault = Some(|point| {
            if format!("{point:?}") == std::env::var("OWNED_TEST_POINT").unwrap() {
                std::process::exit(77);
            }
            Ok(())
        });
    }
    if operation.contains("dispatch") {
        let gate = crate::build_executor::launch_gate::Gate::open(
            &Path::new(&root).join("launch"),
            identity(),
        )
        .unwrap();
        let mut supervisor = crate::build_executor::supervisor::Supervisor::new(
            &journal,
            gate.try_controller().unwrap().unwrap(),
        )
        .unwrap();
        let mut delivery = driver_tests::Dispatch {
            journal: &journal,
            calls: 0,
            ready: true,
            uncertain: false,
            crash: operation.strip_prefix("dispatch-").unwrap_or(""),
        };
        supervisor
            .launch_next(&driver_tests::store(&journal), &mut delivery, 1000)
            .unwrap();
    } else if operation.ends_with("submit") {
        let acceptance = journal.submit("operator", request("one"), 1000).unwrap();
        println!("ACCEPTED {}", acceptance.sequence);
    } else if operation.ends_with("prepare") {
        let owner = journal.pool().unwrap().owner.unwrap();
        let digest = journal
            .record_prepared(&owner, inputs(&request("one")), 1000)
            .unwrap();
        println!("PREPARED {digest}");
    } else if operation.ends_with("escalate") {
        let owner = journal.pool().unwrap().owner.unwrap();
        journal
            .advance_stop(&owner, StopStage::Killing, 1004)
            .unwrap();
        println!("EFFECT_ALLOWED");
    } else {
        match journal.reserve_next("boot", 1000) {
            Ok(Some(_)) => println!("RESERVED"),
            _ => println!("REJECTED"),
        }
    }
}

#[test]
fn separate_processes_deduplicate_and_cannot_double_reserve() {
    let (_root, journal) = fixture();
    let children: Vec<_> = (0..6)
        .map(|_| child(&journal.root, "submit", "").spawn().unwrap())
        .collect();
    for worker in children {
        let output = worker.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(String::from_utf8_lossy(&output.stdout).contains("ACCEPTED 1"));
    }
    let key = request("one").attempt_id().unwrap();
    journal.queue(&key, 1000).unwrap();
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    let children: Vec<_> = (0..6)
        .map(|_| child(&journal.root, "reserve", "").spawn().unwrap())
        .collect();
    let mut owners = 0;
    for worker in children {
        let output = worker.wait_with_output().unwrap();
        assert!(output.status.success());
        owners += usize::from(String::from_utf8_lossy(&output.stdout).contains("RESERVED"));
    }
    assert_eq!(owners, 1);
    assert_eq!(journal.pool().unwrap().epoch, 1);
}

#[test]
fn process_death_at_every_commit_boundary_recovers_exact_acceptance_and_owner() {
    for operation in ["submit", "reserve"] {
        for point in [
            "Created",
            "Written",
            "FileSynced",
            "Renamed",
            "DirectorySynced",
        ] {
            let (_root, journal) = fixture();
            if operation == "reserve" {
                let key = accepted(&journal, "one").attempt_id;
                journal.queue(&key, 1000).unwrap();
                journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
            }
            let output = child(&journal.root, &format!("crash-{operation}"), point)
                .output()
                .unwrap();
            assert_eq!(
                output.status.code(),
                Some(77),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            let reopened = Journal::open(&journal.root, identity(), policy()).unwrap();
            let committed = matches!(point, "Renamed" | "DirectorySynced");
            let key = request("one").attempt_id().unwrap();
            if operation == "reserve" {
                let page = reopened.events("operator", &key, None, 32).unwrap();
                assert_eq!(page.latest, if committed { 3 } else { 2 });
                assert_eq!(
                    page.events.last().unwrap().detail,
                    if committed {
                        EventKind::Reserved {
                            epoch: NonZeroU64::new(1).unwrap(),
                        }
                    } else {
                        EventKind::Queued
                    }
                );
            }
            if operation == "submit" {
                assert_eq!(reopened.status("operator", &key).is_ok(), committed);
                assert_eq!(
                    reopened
                        .submit("operator", request("one"), 1000)
                        .unwrap()
                        .sequence,
                    1
                );
                assert_eq!(
                    reopened.events("operator", &key, None, 32).unwrap().latest,
                    1
                );
            } else {
                assert_eq!(reopened.pool().unwrap().owner.is_some(), committed);
                if committed {
                    assert_eq!(
                        live(&reopened, &key).recovery_action(),
                        RecoveryAction::ReconcileExecution
                    );
                    assert!(reopened.reserve_next("boot", 1000).is_err());
                } else {
                    assert_eq!(
                        reopened
                            .reserve_next("boot", 1000)
                            .unwrap()
                            .unwrap()
                            .pool_epoch
                            .get(),
                        1
                    );
                }
            }
        }
    }
}

#[test]
fn failed_fsync_boundary_never_returns_an_acceptance() {
    for fault in [
        (|point| {
            if point == CommitPoint::FileSynced {
                bail!("synthetic sync failure")
            } else {
                Ok(())
            }
        }) as fn(CommitPoint) -> Result<()>,
        |point| {
            if point == CommitPoint::Renamed {
                bail!("synthetic directory sync failure")
            } else {
                Ok(())
            }
        },
    ] {
        let (_root, mut journal) = fixture();
        journal.fault = Some(fault);
        assert!(journal.submit("operator", request("one"), 1000).is_err());
        journal.fault = None;
        assert_eq!(
            journal
                .submit("operator", request("one"), 1000)
                .unwrap()
                .sequence,
            1
        );
    }
}

#[test]
fn global_epoch_overflow_and_metadata_capacity_reject_without_wrapping() {
    let (_root, journal) = fixture();
    let capacity = (0..=MAX_JOBS)
        .filter(|n| metadata_room(*n, 0))
        .max()
        .unwrap();
    // Same ledger bound, including each future consumer acknowledgement.
    assert_eq!(capacity, 119);
    assert!(metadata_room(89, MAX_TOMBSTONES));
    assert!(!metadata_room(90, MAX_TOMBSTONES));
    // Public work leaves one already-budgeted slot for retirement.
    for index in 0..capacity - 1 {
        accepted(&journal, &format!("job-{index}"));
    }
    assert!(
        journal
            .submit("operator", request("overflow"), 1000)
            .is_err()
    );
    let key = request("job-0").attempt_id().unwrap();
    journal.queue(&key, 1000).unwrap();
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    {
        let directory = journal.lock().unwrap();
        let mut state = journal.read(&directory).unwrap();
        state.pool.epoch = u64::MAX;
        journal.write(&directory, &state).unwrap();
    }
    assert!(journal.reserve_next("boot", 1000).is_err());
    assert_eq!(journal.pool().unwrap().epoch, u64::MAX);
}

#[test]
fn malformed_deadlines_reject_before_acceptance() {
    let mut spec = request("one");
    spec.deadlines.heartbeat_seconds = spec.deadlines.stale_seconds;
    assert!(BuildRequest::decode(&serde_json::to_vec(&spec).unwrap()).is_err());
    let mut limits = policy();
    limits.replay_seconds = 0;
    assert!(limits.validate().is_err());
}

#[test]
fn quarantine_survives_expiry_exit_and_terminal_settlement() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "one").attempt_id;
    let owner = reserve(&journal, &key);
    let handle = ExecutionHandle {
        ownership: owner.clone(),
        invocation_id: "invocation".into(),
    };
    journal.started(handle.clone(), 1000).unwrap();
    journal.quarantine(1000).unwrap();
    journal.expire(1012).unwrap();
    journal
        .client_exited(&handle, ClientExit::Failed { exit_code: 1 }, 1012)
        .unwrap();
    journal
        .cancel("operator", &key, Some(&owner), 1012)
        .unwrap();
    assert_eq!(journal.pool().unwrap().health, PoolHealth::Quarantined);
    journal
        .settle(
            &key,
            Settlement::FencedEmpty { ownership: owner },
            None,
            1012,
        )
        .unwrap();
    assert_eq!(journal.pool().unwrap().health, PoolHealth::Quarantined);
    assert!(journal.reserve_next("boot", 1012).is_err());
}

#[test]
fn initialization_rejects_a_redirected_parent_before_creating_state() {
    let root = tempfile::tempdir().unwrap();
    let real = root.path().join("real");
    fs::create_dir(&real).unwrap();
    let alias = root.path().join("alias");
    symlink(&real, &alias).unwrap();
    assert!(Journal::initialize(&alias.join("authority"), identity(), policy(), 1000).is_err());
    assert!(!real.join("authority").exists());
}

#[test]
fn deadline_cannot_be_extended_by_renewal_and_status_keeps_contact_time() {
    let (_root, journal) = fixture();
    let key = accepted(&journal, "one").attempt_id;
    for time in [1005, 1010, 1015, 1020, 1025] {
        journal
            .renew("operator", &key, None, b"synthetic-token", time)
            .unwrap();
    }
    assert!(
        journal
            .renew("operator", &key, None, b"synthetic-token", 1030)
            .is_err()
    );
    match journal.status("operator", &key).unwrap() {
        JobStatus::Live {
            accepted_at,
            renewed_at,
            ..
        } => {
            assert_eq!(accepted_at, 1000);
            assert_eq!(renewed_at, 1025);
        }
        _ => panic!("expected live record"),
    }
    journal.expire(1030).unwrap();
    assert_eq!(live(&journal, &key).phase(), Phase::Stopping);
}

#[test]
fn no_space_and_io_errors_before_publication_never_acknowledge_acceptance() {
    for fault in [
        (|point| {
            if point == CommitPoint::Written {
                Err(std::io::Error::from_raw_os_error(libc::ENOSPC).into())
            } else {
                Ok(())
            }
        }) as fn(CommitPoint) -> Result<()>,
        |point| {
            if point == CommitPoint::Renamed {
                Err(std::io::Error::from_raw_os_error(libc::EIO).into())
            } else {
                Ok(())
            }
        },
    ] {
        let (_root, mut journal) = fixture();
        journal.fault = Some(fault);
        assert!(journal.submit("operator", request("one"), 1000).is_err());
        let recovered = Journal::open(&journal.root, identity(), policy()).unwrap();
        assert_eq!(
            recovered
                .submit("operator", request("one"), 1000)
                .unwrap()
                .sequence,
            1
        );
    }
}

#[test]
fn daemon_start_veto_preserves_owner_deadlines_and_does_not_grant_worker() {
    for maintenance in [false, true] {
        let (_root, journal) = fixture();
        assert!(journal.daemon_owner(1000).is_err());
        let accepted = if maintenance {
            journal
                .submit_maintenance(
                    crate::build_executor::maintenance::Request {
                        version: crate::build_executor::maintenance::VERSION,
                        id: RequestId {
                            issued_at: 1000,
                            nonce: "daemon-maintenance".into(),
                        },
                        storage: identity(),
                        policy_digest: policy().digest().unwrap(),
                        deadlines: policy().deadlines,
                        operation: crate::build_executor::maintenance::Operation::CollectGarbage,
                    },
                    1000,
                )
                .unwrap()
        } else {
            accepted(&journal, "daemon-build")
        };
        assert!(journal.daemon_owner(1000).is_err());
        let owner = reserve(&journal, &accepted.attempt_id);
        let before = fs::read(journal.root.join(STATE)).unwrap();
        assert_eq!(journal.daemon_owner(1000).unwrap(), owner);
        assert_eq!(journal.daemon_owner(1005).unwrap(), owner);
        assert!(journal.daemon_owner(999).is_err());
        if maintenance {
            assert_eq!(journal.daemon_owner(1059).unwrap(), owner);
        } else {
            assert!(journal.daemon_owner(1006).is_err());
        }
        assert!(journal.daemon_owner(1060).is_err());
        assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
        let handle = ExecutionHandle {
            ownership: owner.clone(),
            invocation_id: "daemon-worker".into(),
        };
        journal.begin_worker(handle.clone(), 1001).unwrap();
        assert_eq!(journal.daemon_owner(1001).unwrap(), owner);
        assert!(journal.begin_worker(handle, 1001).is_err());
        journal.stop(&owner, StopReason::Cancelled, 1002).unwrap();
        assert!(journal.daemon_owner(1002).is_err());
    }
}

#[test]
fn daemon_start_veto_rejects_quarantined_reserved_work() {
    let (_root, journal) = fixture();
    let accepted = accepted(&journal, "daemon-quarantine");
    reserve(&journal, &accepted.attempt_id);
    journal.quarantine(1001).unwrap();
    assert!(journal.daemon_owner(1001).is_err());
}

#[path = "clock_tests.rs"]
mod clock_tests;

#[path = "wire_tests.rs"]
mod wire_tests;

#[path = "preparation_tests.rs"]
mod preparation_tests;

#[path = "context_tests.rs"]
mod context_tests;

#[path = "supervisor_tests.rs"]
mod supervisor_tests;

#[path = "driver_tests.rs"]
mod driver_tests;
