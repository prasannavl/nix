use super::*;
use crate::build_executor::diagnostics::Activity;
use crate::build_executor::events::{LOG_RECORD_BYTES, MAX_LOG_PAGE_BYTES};
use crate::build_executor::journal::tests::{identity, policy, request};

fn running(now: u64) -> (tempfile::TempDir, Journal, ExecutionHandle) {
    let root = tempfile::tempdir().unwrap();
    let journal =
        Journal::initialize(&root.path().join("authority"), identity(), policy(), now).unwrap();
    let mut request = request("diagnostics");
    request.id.issued_at = now;
    let key = journal.submit("operator", request, now).unwrap().attempt_id;
    journal.queue(&key, now).unwrap();
    journal.recovered(0, "boot", &"d".repeat(64), now).unwrap();
    let owner = journal.reserve_next("boot", now).unwrap().unwrap();
    let handle = ExecutionHandle {
        ownership: owner,
        invocation_id: "worker".into(),
    };
    journal.started(handle.clone(), now).unwrap();
    (root, journal, handle)
}

fn diagnostic(observation: Observation) -> Diagnostic {
    Diagnostic {
        activity: Activity::Capture,
        observation,
    }
}

#[test]
fn persisted_diagnostics_are_allowlisted_and_reopen_without_execution() {
    let now = crate::build_executor::daemon::now().unwrap();
    let (_root, journal, handle) = running(now);
    let key = &handle.ownership.attempt_id;
    let result: Result<()> = journal.diagnose(&handle, Activity::Capture, || {
        bail!("PRIVATE_TOKEN_AND_GIT_CONFIG_MUST_NOT_ENTER_LOGS");
    });
    assert!(result.is_err());
    let page = journal
        .logs("operator", key, None, MAX_LOG_PAGE_BYTES)
        .unwrap();
    assert!(!page.sealed && !page.gap && !page.more);
    let text = std::str::from_utf8(&page.bytes).unwrap();
    assert!(
        text.contains("\"activity\":\"capture\"") && text.contains("\"observation\":\"error\"")
    );
    assert!(!text.contains("PRIVATE_TOKEN") && !text.contains("synthetic-token"));
    assert!(
        serde_json::from_value::<Diagnostic>(serde_json::json!({
            "activity": "capture", "observation": "error", "message": "PRIVATE_TOKEN",
        }))
        .is_err()
    );
    let reopened = Journal::open(journal.authority_root(), identity(), policy()).unwrap();
    assert_eq!(
        reopened
            .logs("operator", key, None, MAX_LOG_PAGE_BYTES)
            .unwrap(),
        page
    );
    assert!(
        matches!(reopened.status("operator", key).unwrap(), JobStatus::Live {
        settled_at: None, attempt, ..
    } if attempt.phase() == Phase::Running)
    );
    assert!(
        journal
            .logs("foreign", key, None, MAX_LOG_PAGE_BYTES)
            .is_err()
    );
}

#[test]
fn byte_cursors_survive_pages_and_report_eviction_not_empty_success() {
    let (_root, journal, handle) = running(1000);
    let key = &handle.ownership.attempt_id;
    let full = journal
        .logs("operator", key, None, MAX_LOG_PAGE_BYTES)
        .unwrap();
    let first = journal.logs("operator", key, None, 731).unwrap();
    assert!(first.more && first.next.offset == 731);
    let second = journal
        .logs("operator", key, Some(&first.next), MAX_LOG_PAGE_BYTES)
        .unwrap();
    assert_eq!([first.bytes, second.bytes].concat(), full.bytes);
    for _ in 0..70 {
        journal
            .record_diagnostic(&handle, diagnostic(Observation::Returned), 1000)
            .unwrap();
    }
    let rotated = journal
        .logs("operator", key, Some(&full.next), MAX_LOG_PAGE_BYTES)
        .unwrap();
    assert!(rotated.gap && rotated.more && !rotated.sealed);
    let base = rotated.next.offset - rotated.bytes.len() as u64;
    assert!(base > full.next.offset && base.is_multiple_of(LOG_RECORD_BYTES as u64));
    let event: crate::build_executor::events::Event =
        serde_json::from_slice(&rotated.bytes[..LOG_RECORD_BYTES]).unwrap();
    assert_eq!(event.sequence, base / LOG_RECORD_BYTES as u64 + 1);
    let mut wrong = full.next;
    wrong.generation = "replaced".into();
    assert!(
        journal
            .logs("operator", key, Some(&wrong), MAX_LOG_PAGE_BYTES)
            .unwrap()
            .gap
    );
    wrong.generation = crate::build_executor::events::LOG_GENERATION.into();
    wrong.offset = u64::MAX;
    assert!(
        journal
            .logs("operator", key, Some(&wrong), MAX_LOG_PAGE_BYTES)
            .is_err()
    );
}

#[test]
fn cancellation_and_log_completion_cannot_change_ownership_grace_or_settlement() {
    let (_root, journal, handle) = running(1000);
    let key = &handle.ownership.attempt_id;
    journal
        .record_diagnostic(&handle, diagnostic(Observation::Entered), 1000)
        .unwrap();
    journal
        .cancel("operator", key, Some(&handle.ownership), 1001)
        .unwrap();
    let before = journal.supervision().unwrap().active.unwrap();
    journal
        .record_diagnostic(&handle, diagnostic(Observation::Error), 1002)
        .unwrap();
    let after = journal.supervision().unwrap().active.unwrap();
    assert_eq!(before.stop, after.stop);
    assert_eq!(before.owner, after.owner);
    assert!(
        journal
            .record_diagnostic(&handle, diagnostic(Observation::Entered), 1002)
            .is_err()
    );
    let mut foreign = handle.clone();
    foreign.invocation_id = "another-worker".into();
    assert!(
        journal
            .record_diagnostic(&foreign, diagnostic(Observation::Returned), 1002)
            .is_err()
    );
    assert!(
        !journal
            .logs("operator", key, None, MAX_LOG_PAGE_BYTES)
            .unwrap()
            .sealed
    );
    journal
        .settle(
            key,
            Settlement::FencedEmpty {
                ownership: handle.ownership.clone(),
            },
            None,
            1002,
        )
        .unwrap();
    let final_page = journal
        .logs("operator", key, None, MAX_LOG_PAGE_BYTES)
        .unwrap();
    assert!(final_page.sealed);
    assert!(
        journal
            .record_diagnostic(&handle, diagnostic(Observation::Returned), 1002)
            .is_err()
    );
    journal.released(key, &"e".repeat(64), 1002).unwrap();
    journal.prune(1023).unwrap();
    let retired = journal
        .logs("operator", key, Some(&final_page.next), MAX_LOG_PAGE_BYTES)
        .unwrap();
    assert!(retired.sealed && retired.gap && !retired.more && retired.bytes.is_empty());
}

#[test]
fn failed_diagnostic_admission_never_invokes_the_operation() {
    let (_root, journal, handle) = running(1000);
    journal
        .cancel(
            "operator",
            &handle.ownership.attempt_id,
            Some(&handle.ownership),
            1000,
        )
        .unwrap();
    let mut invoked = false;
    let result = journal.diagnose(&handle, Activity::Realize, || {
        invoked = true;
        Ok(())
    });
    assert!(result.is_err() && !invoked);
}
