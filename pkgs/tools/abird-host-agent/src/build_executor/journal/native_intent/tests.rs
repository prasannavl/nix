//! Journal contracts only; not capture containment or end-to-end acceptance.

use super::*;
use crate::build_executor::journal::tests::{fixture, live, request};
use crate::build_executor::protocol::{Command, Reply, Request as WireRequest, VERSION};

fn native(nonce: &str) -> Request {
    let resolved = request(nonce);
    Request {
        version: 1,
        executor_version: 1,
        controller_service: false,
        bootstrap_digest: None,
        caller_digest: None,
        id: resolved.id,
        run_id: resolved.run_id,
        issuer: resolved.issuer,
        repository_id: resolved.repository_id,
        controller: resolved.controller,
        builder: resolved.builder,
        storage: resolved.storage,
        action: resolved.evaluation.action,
        invocation: serde_json::json!({ "action": "build", "options": {} }),
        nix: resolved.nix,
        policy_digest: resolved.policy_digest,
        deadlines: resolved.deadlines,
        owner: resolved.owner,
    }
}

#[test]
fn dev_destination_is_captured_metadata_and_changes_the_preparation_binding() {
    use crate::build_executor::context::BuildAction;
    use crate::build_executor::native_intent::{CallerRepository, Validation};
    let mut intent = native("destination");
    intent.run_id = "1".repeat(32);
    intent.bootstrap_digest = Some("a".repeat(64));
    intent.caller_digest = Some("b".repeat(64));
    intent.action = BuildAction::DevBuild;
    let mut resolved = request("destination");
    resolved.run_id = intent.run_id.clone();
    resolved.evaluation.action = BuildAction::DevBuild;
    resolved.mode = crate::build_executor::request::BuildMode::Development;
    resolved.parent = Some(Box::new(intent));
    let repository = CallerRepository {
        path: "/home/operator/repo".into(),
        device: 17,
        inode: 23,
    };
    let mut validation = Validation {
        request: resolved,
        context: serde_json::json!({"source_root": repository.path,
            "caller_repository": repository}),
    };
    assert_eq!(
        validation.caller_repository().unwrap(),
        Some(repository.clone())
    );
    let mut prepared = crate::build_executor::journal::tests::inputs(&validation.request);
    prepared.caller_repository = Some(repository);
    prepared.validate(&validation.request).unwrap();
    let digest = prepared.digest().unwrap();
    prepared.caller_repository.as_mut().unwrap().inode += 1;
    assert_ne!(prepared.digest().unwrap(), digest);
    validation.context["source_root"] = serde_json::json!("/unrelated/repository");
    assert!(validation.caller_repository().is_err());
    validation.context["source_root"] = serde_json::json!("/home/operator/repo");
    validation.context["caller_repository"]["inode"] = serde_json::json!(0);
    assert!(validation.caller_repository().is_err());
    validation
        .context
        .as_object_mut()
        .unwrap()
        .remove("caller_repository");
    assert!(validation.caller_repository().unwrap().is_none());
    // Legacy absence is not permission to invent a destination during acquire.
}

#[test]
fn capture_directive_is_bound_and_cannot_smuggle_resolved_or_foreign_input() {
    use crate::build_executor::native_intent::{Capture, Delivery};
    let mut intent = native("capture");
    intent.controller = intent.builder.clone();
    intent.run_id = "1".repeat(32);
    intent.bootstrap_digest = Some("a".repeat(64));
    intent.caller_digest = Some("b".repeat(64));
    let directive = Capture {
        version: 1,
        capture: true,
        request_digest: intent.digest().unwrap(),
    };
    let bytes = serde_json::to_vec(&directive).unwrap();
    assert!(matches!(
        Delivery::decode(&bytes, &intent).unwrap(),
        Delivery::LocalCapture(_)
    ));
    let mut extra = serde_json::to_value(&directive).unwrap();
    extra["source"] = serde_json::json!({"revision":"unadmitted"});
    assert!(Delivery::decode(&serde_json::to_vec(&extra).unwrap(), &intent).is_err());
    let mut resolved = request("capture");
    resolved.controller = intent.controller.clone();
    resolved.run_id = intent.run_id.clone();
    resolved.parent = Some(Box::new(intent.clone()));
    let supplied = crate::build_executor::native_intent::Material {
        version: 1,
        request: resolved,
        context: serde_json::json!({}),
        source: crate::build_executor::preparation::source::Material {
            version: 1,
            request_digest: intent.digest().unwrap(),
            patch: None,
            snapshots: Default::default(),
            git_context: None,
            capsule: None,
        },
    };
    supplied.validate(&intent).unwrap();
    assert!(Delivery::decode(&serde_json::to_vec(&supplied).unwrap(), &intent).is_err());
    let mut changed = intent.clone();
    changed.caller_digest = Some("c".repeat(64));
    assert!(Delivery::decode(&bytes, &changed).is_err());
    changed = intent.clone();
    changed.controller.host_id = "other-node".into();
    let foreign = Capture {
        version: 1,
        capture: true,
        request_digest: changed.digest().unwrap(),
    };
    assert!(foreign.validate(&changed).is_err());
    changed = intent;
    changed.caller_digest = None;
    assert!(
        Capture {
            version: 1,
            capture: true,
            request_digest: changed.digest().unwrap()
        }
        .validate(&changed)
        .is_err()
    );
}

#[test]
fn repository_recipe_binds_exact_input_without_authorizing_caller_capture() {
    use crate::build_executor::native_intent::{Delivery, RepositoryRecipe};
    let mut intent = native("repository");
    intent.action = crate::build_executor::context::BuildAction::Build;
    intent.caller_digest = Some("b".repeat(64));
    let mut source = request("repository").source;
    source.base_revision = source.revision.clone();
    source.tree_digest = None;
    source.patch_digest = None;
    let mut recipe = RepositoryRecipe {
        request_digest: intent.digest().unwrap(),
        source_root: "/logical/not-mounted".into(),
        source,
        patch: None,
    };
    recipe.validate(&intent).unwrap();
    let bytes = serde_json::to_vec(&Delivery::Repository {
        recipe: recipe.clone(),
    })
    .unwrap();
    assert!(matches!(
        Delivery::decode(&bytes, &intent).unwrap(),
        Delivery::Repository { .. }
    ));
    recipe.patch = Some("00".into());
    assert!(recipe.validate(&intent).is_err());
    recipe.source.patch_digest = Some(crate::sha256::digest_bytes(&[0]));
    recipe.validate(&intent).unwrap();
    recipe.source_root = "/logical/../outside".into();
    assert!(recipe.validate(&intent).is_err());
    intent.bootstrap_digest = Some("a".repeat(64));
    recipe.source_root = "/logical/not-mounted".into();
    recipe.request_digest = intent.digest().unwrap();
    assert!(recipe.validate(&intent).is_err()); // Never substitute for installed capture.
}

#[test]
fn unresolved_native_admission_has_no_fake_source_and_keeps_one_acceptance() {
    let (_root, journal) = fixture();
    let intent = native("early");
    let accepted = journal
        .submit_native("operator", intent.clone(), 1000)
        .unwrap();
    assert_eq!(
        accepted,
        journal
            .submit_native("operator", intent.clone(), 1001)
            .unwrap()
    );
    assert!(matches!(
        journal.status("operator", &accepted.attempt_id).unwrap(),
        JobStatus::Live {
            request: None,
            prepared: None,
            reserved_at: None,
            settled_at: None,
            ..
        }
    ));
    let wire = WireRequest {
        version: VERSION,
        command: Command::SubmitNative {
            request: Box::new(intent),
        },
    };
    let response = journal.handle("operator", &serde_json::to_vec(&wire).unwrap(), 1001);
    assert!(matches!(response.reply, Reply::Accepted { acceptance } if acceptance == accepted));
}

#[test]
fn native_withdrawal_fences_delayed_submit_without_resolution_or_settlement() {
    let (_root, journal) = fixture();
    let intent = native("withdraw");
    let accepted = journal
        .withdraw_native("operator", intent.clone(), 1000)
        .unwrap();
    assert_eq!(
        accepted,
        journal
            .submit_native("operator", intent.clone(), 1001)
            .unwrap()
    );
    assert_eq!(
        live(&journal, &accepted.attempt_id).phase(),
        Phase::Stopping
    );
    assert!(matches!(
        journal.status("operator", &accepted.attempt_id).unwrap(),
        JobStatus::Live {
            request: None,
            prepared: None,
            settled_at: None,
            ..
        }
    ));
    journal.queue_pending(1001).unwrap();
    assert!(journal.queue(&accepted.attempt_id, 1001).is_err());
    assert!(journal.withdraw_native("another", intent, 1001).is_err());
}

#[test]
fn resolved_native_data_cannot_become_another_public_submission() {
    let (_root, journal) = fixture();
    let parent = native("binding");
    let accepted = journal
        .submit_native("operator", parent.clone(), 1000)
        .unwrap();
    let mut resolved = request("binding");
    resolved.parent = Some(Box::new(parent.clone()));
    resolved.validate().unwrap();
    assert_eq!(resolved.attempt_id().unwrap(), accepted.attempt_id);
    assert_eq!(resolved.digest().unwrap(), accepted.spec_digest);
    let original_binding = resolved.binding_digest().unwrap();
    resolved.source.revision = "e".repeat(40);
    resolved.source.base_revision = "e".repeat(40);
    assert_eq!(resolved.digest().unwrap(), accepted.spec_digest);
    assert_ne!(resolved.binding_digest().unwrap(), original_binding);
    assert!(journal.submit("operator", resolved.clone(), 1000).is_err());
    assert!(
        journal
            .withdraw("operator", resolved.clone(), 1000)
            .is_err()
    );
    journal.queue(&accepted.attempt_id, 1000).unwrap();
    journal.recovered(0, "boot", &"d".repeat(64), 1000).unwrap();
    let owner = journal.reserve_next("boot", 1000).unwrap().unwrap();
    // A queue/owner handle alone cannot bind source or mint a new execution.
    assert!(
        journal
            .bind_native(&owner, resolved, "f".repeat(64), 1000)
            .is_err()
    );
    assert!(matches!(
        journal.status("operator", &accepted.attempt_id).unwrap(),
        JobStatus::Live { request: None, .. }
    ));
    assert_eq!(journal.pool().unwrap().owner, Some(owner));
}
