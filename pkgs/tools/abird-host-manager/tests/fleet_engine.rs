use std::cell::RefCell;

use abird_host_manager::fleet::cli::{Action, Invocation, Options};
use abird_host_manager::fleet::engine::{FleetEffects, PhaseFailure, execute};
use abird_host_manager::fleet::plan::Phase;

#[derive(Default)]
struct FakeEffects {
    calls: RefCell<Vec<String>>,
    fail: Option<Phase>,
}

impl FleetEffects for FakeEffects {
    fn run_phase(&mut self, phase: Phase) -> Result<(), PhaseFailure> {
        self.calls.borrow_mut().push(format!("phase:{phase:?}"));
        if self.fail == Some(phase) {
            Err(PhaseFailure::new(phase, "injected failure"))
        } else {
            Ok(())
        }
    }

    fn rollback(&mut self, failed_phase: Phase) -> anyhow::Result<()> {
        self.calls
            .borrow_mut()
            .push(format!("rollback:{failed_phase:?}"));
        Ok(())
    }
}

fn invocation(action: Action) -> Invocation {
    Invocation {
        action,
        options: Options::default(),
    }
}

#[test]
fn full_run_executes_every_phase_in_the_legacy_order() {
    let mut effects = FakeEffects::default();
    execute(&invocation(Action::Run), &mut effects).unwrap();
    assert_eq!(
        *effects.calls.borrow(),
        [
            "phase:TerraformDns",
            "phase:TerraformPlatform",
            "phase:Build",
            "phase:Snapshot",
            "phase:Deploy",
            "phase:Health",
            "phase:TerraformApps",
        ]
    );
}

#[test]
fn failure_stops_later_work_and_rolls_back_only_after_snapshot_boundary() {
    for (action, failed, rollback) in [
        (Action::Deploy, Phase::Build, false),
        (Action::Deploy, Phase::Snapshot, false),
        (Action::Deploy, Phase::Deploy, true),
        (Action::Deploy, Phase::Health, true),
        (Action::Run, Phase::TerraformApps, false),
    ] {
        let mut effects = FakeEffects {
            fail: Some(failed),
            ..FakeEffects::default()
        };
        assert!(execute(&invocation(action), &mut effects).is_err());
        assert_eq!(
            effects
                .calls
                .borrow()
                .iter()
                .any(|call| call.starts_with("rollback:")),
            rollback,
            "failed phase {failed:?}"
        );
    }
}

#[test]
fn no_rollback_option_preserves_original_failure_without_rollback() {
    let mut effects = FakeEffects {
        fail: Some(Phase::Deploy),
        ..FakeEffects::default()
    };
    let mut request = invocation(Action::Deploy);
    request.options.no_rollback = true;
    let error = execute(&request, &mut effects).unwrap_err();
    assert!(error.to_string().contains("injected failure"));
    assert!(
        !effects
            .calls
            .borrow()
            .iter()
            .any(|call| call.starts_with("rollback:"))
    );
}

#[test]
fn rollback_failure_retains_both_action_and_rollback_evidence() {
    struct BrokenRollback;
    impl FleetEffects for BrokenRollback {
        fn run_phase(&mut self, phase: Phase) -> Result<(), PhaseFailure> {
            (phase != Phase::Deploy)
                .then_some(())
                .ok_or_else(|| PhaseFailure::new(phase, "deploy broke"))
        }

        fn rollback(&mut self, _failed_phase: Phase) -> anyhow::Result<()> {
            anyhow::bail!("rollback broke")
        }
    }
    let error = execute(&invocation(Action::Deploy), &mut BrokenRollback).unwrap_err();
    let rendered = format!("{error:#}");
    assert!(rendered.contains("deploy broke"));
    assert!(rendered.contains("rollback broke"));
}
