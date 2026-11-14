use super::*;
use crate::build_executor::context::{BuildAction, InputLocation, InputTree, PlanJobs};
use crate::build_executor::preparation::{Disposition, ResolvedTarget};

fn no_work() -> (BuildRequest, PreparedInputs) {
    let mut request = request("no-work");
    request.evaluation.action = BuildAction::Deploy;
    request.selection = Selection::Fleet {
        groups: Vec::new(),
        host: Some("external".into()),
        hosts: None,
        nix_config: None,
        control_plane_first: false,
    };
    request.required_hosts = vec!["external".into()];
    let mut prepared = inputs(&super::request("seed"));
    prepared.attempt_id = request.attempt_id().unwrap();
    prepared.spec_digest = request.digest().unwrap();
    prepared.evaluation_digest = request.evaluation.digest().unwrap();
    prepared.targets.clear();
    prepared.resolved = vec![ResolvedTarget {
        host: "external".into(),
        configuration: "external".into(),
        disposition: Disposition::NoNativePlan,
    }];
    prepared.required_hosts = request.required_hosts.clone();
    (request, prepared)
}

#[test]
fn no_work_can_have_required_coverage_without_any_fabricated_derivation() {
    let (request, prepared) = no_work();
    prepared.validate(&request).unwrap();
    assert!(prepared.targets.is_empty());
    let bytes = serde_json::to_vec(&prepared).unwrap();
    assert_eq!(PreparedInputs::decode(&bytes, &request).unwrap(), prepared);
    assert!(!std::str::from_utf8(&bytes).unwrap().contains(".drv"));
    for action in [BuildAction::Build, BuildAction::DevBuild] {
        let mut invalid = request.clone();
        invalid.evaluation.action = action;
        invalid.mode = action.mode();
        let mut inputs = prepared.clone();
        inputs.spec_digest = invalid.digest().unwrap();
        inputs.evaluation_digest = invalid.evaluation.digest().unwrap();
        assert!(inputs.validate(&invalid).is_err());
    }
    let mut missing = prepared.clone();
    missing.required_hosts.clear();
    assert!(missing.validate(&request).is_err());
    missing = prepared;
    missing.resolved.clear();
    assert!(missing.validate(&request).is_err());
}

#[test]
fn no_work_still_requires_worker_verification_settlement_and_retention_release() {
    let (_root, journal) = fixture();
    let (request, prepared) = no_work();
    let key = journal
        .submit("operator", request.clone(), 1000)
        .unwrap()
        .attempt_id;
    let owner = reserve(&journal, &key);
    assert!(
        journal
            .record_prepared(&owner, prepared.clone(), 1000)
            .is_err()
    );
    let handle = ExecutionHandle {
        ownership: owner.clone(),
        invocation_id: "worker".into(),
    };
    journal.started(handle.clone(), 1000).unwrap();
    let prepared_digest = journal.record_prepared(&owner, prepared, 1000).unwrap();
    journal
        .client_exited(&handle, ClientExit::Success, 1000)
        .unwrap();
    assert_eq!(live(&journal, &key).phase(), Phase::Verifying);
    assert!(live(&journal, &key).outcome().is_none());
    assert!(
        journal
            .settle(
                &key,
                Settlement::FencedEmpty {
                    ownership: owner.clone()
                },
                None,
                1000
            )
            .is_err()
    );
    journal
        .settle(
            &key,
            Settlement::FencedEmpty { ownership: owner },
            Some(ArtifactReceipt {
                spec_digest: request.digest().unwrap(),
                preparation_digest: prepared_digest,
                closure_digest: digest_bytes(b"synthetic-verified-empty-output-set"),
                roots_digest: digest_bytes(b"synthetic-retained-inputs"),
            }),
            1000,
        )
        .unwrap();
    assert!(matches!(
        live(&journal, &key).outcome(),
        Some(Outcome::Succeeded { .. })
    ));
    assert!(!journal.retention_clear().unwrap());
    journal.released(&key, &"f".repeat(64), 1001).unwrap();
    assert!(journal.retention_clear().unwrap());
}

#[test]
fn resolved_order_build_dispositions_and_exact_targets_cannot_diverge() {
    let request = request("one");
    let prepared = inputs(&request);
    for mutate in [
        |p: &mut PreparedInputs| p.resolved.clear(),
        |p: &mut PreparedInputs| p.resolved.push(p.resolved[0].clone()),
        |p: &mut PreparedInputs| p.resolved[0].host = "foreign".into(),
        |p: &mut PreparedInputs| p.resolved[0].configuration = "foreign".into(),
        |p: &mut PreparedInputs| p.resolved[0].disposition = Disposition::NoNativePlan,
        |p: &mut PreparedInputs| p.targets.clear(),
        |p: &mut PreparedInputs| p.evaluation_digest = "e".repeat(64),
    ] {
        let mut changed = prepared.clone();
        mutate(&mut changed);
        assert!(changed.validate(&request).is_err());
    }
}

#[test]
fn context_snapshots_require_exact_intent_and_store_path_binding() {
    let mut request = request("context");
    let nar = "e".repeat(64);
    request.evaluation.overlay = Some(InputLocation {
        tree: InputTree::Snapshot {
            nar_digest: nar.clone(),
        },
        relative: "overlay.nix".into(),
    });
    let mut prepared = inputs(&request);
    assert!(prepared.validate(&request).is_err());
    prepared.context_sources.insert(
        nar.clone(),
        format!("/nix/store/{}-context", "1".repeat(32)),
    );
    prepared.validate(&request).unwrap();
    let mut changed = prepared.clone();
    changed
        .context_sources
        .insert("f".repeat(64), changed.context_sources[&nar].clone());
    assert!(changed.validate(&request).is_err());
    prepared.context_sources.insert(nar, "/tmp/foreign".into());
    assert!(prepared.validate(&request).is_err());
}

#[test]
fn context_changes_conflict_without_creating_another_attempt_or_effect() {
    let (_root, journal) = fixture();
    let request = request("context");
    let key = journal
        .submit("operator", request.clone(), 1000)
        .unwrap()
        .attempt_id;
    let before = fs::read(journal.root.join(STATE)).unwrap();
    for change in [
        |r: &mut BuildRequest| r.evaluation.plan_jobs = PlanJobs::Count { jobs: 2 },
        |r: &mut BuildRequest| r.evaluation.action = BuildAction::Deploy,
        |r: &mut BuildRequest| r.evaluation.overlay = Some(InputLocation::source("local.nix")),
    ] {
        let mut changed = request.clone();
        change(&mut changed);
        assert_eq!(changed.attempt_id().unwrap(), key);
        assert_eq!(
            journal
                .submit("operator", changed, 1000)
                .unwrap_err()
                .downcast_ref::<Rejection>(),
            Some(&Rejection::Conflict)
        );
        assert_eq!(fs::read(journal.root.join(STATE)).unwrap(), before);
    }
}
