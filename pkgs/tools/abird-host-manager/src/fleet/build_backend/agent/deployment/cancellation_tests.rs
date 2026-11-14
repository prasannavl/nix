//! Real caller journal/withdrawal boundary, with target effects confined to a
//! test file. Installed activation/admission authority belongs to the VM suite.

use std::cell::Cell;
use std::path::{Path, PathBuf};
use std::process::Command;

use abird_host_agent::build_executor::protocol::Description;
use abird_host_agent::build_executor::request::{
    AdmissionPolicy, Deadlines, NixOptions, Peer, StorageIdentity,
};
use anyhow::{Result, bail, ensure};

use super::{Controller, check_interrupted};
use crate::fleet::build_backend::agent::controller::{Binding, PendingCapture, admit};
use crate::fleet::build_backend::agent::run::Run;
use crate::fleet::cli::Invocation;
use crate::fleet::engine::{FleetEffects, PhaseFailure, execute_retained_with_interrupt_check};
use crate::fleet::host_runtime::HostExecutionTarget;
use crate::fleet::plan::Phase;
use crate::fleet::transport::{SshEndpoint, SshRoutePlan, TransportRole};

const TEST: &str = "fleet::build_backend::agent::deployment::cancellation_tests::durable_marker_stops_retained_phases";
const OPERATION: &str = "ABIRD_TEST_RETAINED_CANCEL";

#[test]
fn durable_marker_stops_retained_phases() {
    match std::env::var(OPERATION).as_deref() {
        Ok("withdraw") => {
            let run = std::env::var("ABIRD_TEST_RETAINED_RUN").unwrap();
            assert!(Run::request_cancel(&run).unwrap().1);
        }
        Ok("exercise") => exercise(),
        _ => {
            let directory = tempfile::tempdir().unwrap();
            let output = Command::new(std::env::current_exe().unwrap())
                .args(["--exact", TEST, "--nocapture"])
                .env(OPERATION, "exercise")
                .env("XDG_STATE_HOME", directory.path())
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }
}

fn withdraw(run: &str) {
    // A second process can persist withdrawal while the deployment writer owns
    // controller.lock. No signal and no builder/target process killing.
    let output = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", TEST, "--nocapture"])
        .env(OPERATION, "withdraw")
        .env("ABIRD_TEST_RETAINED_RUN", run)
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
}

#[derive(Clone, Copy, Debug)]
enum Boundary {
    BeforeFirst,
    Acquire,
    Deploy,
    BeforeHealth,
    Health,
    FailedDeploy,
    DuringRollback,
    RollbackFailure,
    NoRollback,
    InvalidMarker,
}

struct Effects<'a> {
    run: &'a str,
    boundary: Boundary,
    mutation: PathBuf,
    completed_deploy: &'a Cell<bool>,
    phases: Vec<Phase>,
    rollback: Vec<(Phase, bool)>,
}

impl FleetEffects for Effects<'_> {
    fn run_phase(&mut self, phase: Phase) -> Result<(), PhaseFailure> {
        self.phases.push(phase);
        if phase == Phase::Deploy {
            std::fs::write(&self.mutation, b"new generation").unwrap();
            self.completed_deploy.set(true);
        }
        match (self.boundary, phase) {
            (Boundary::Acquire, Phase::Acquire)
            | (Boundary::Health, Phase::Health)
            | (
                Boundary::Deploy
                | Boundary::FailedDeploy
                | Boundary::RollbackFailure
                | Boundary::NoRollback,
                Phase::Deploy,
            ) => withdraw(self.run),
            (Boundary::InvalidMarker, Phase::Deploy) => {
                withdraw(self.run);
                let marker = self
                    .mutation
                    .parent()
                    .unwrap()
                    .join("abird/abird-host-manager/fleet-owned")
                    .join(self.run)
                    .join("cancel.intent");
                std::fs::write(marker, b"wrong intent").unwrap();
            }
            _ => {}
        }
        if phase == Phase::Deploy
            && matches!(
                self.boundary,
                Boundary::FailedDeploy | Boundary::DuringRollback
            )
        {
            return Err(PhaseFailure::continuing_through(
                phase,
                "activation failed after mutation",
                Phase::Health,
            ));
        }
        Ok(())
    }

    fn rollback(&mut self, phase: Phase) -> Result<()> {
        self.rollback.push((phase, false));
        assert!(matches!(self.boundary, Boundary::DuringRollback));
        withdraw(self.run);
        // Ordinary rollback may cover only failed targets. Cancellation must
        // still reach the interruption hook for other activated targets.
        Ok(())
    }

    fn rollback_interrupted(&mut self, phase: Phase) -> Result<()> {
        self.rollback.push((phase, true));
        crate::fleet::signal::check_interrupted()?;
        let signal = crate::fleet::signal::runtime().unwrap();
        ensure!(!signal.cancel_local() && !signal.force_remote());
        if matches!(self.boundary, Boundary::RollbackFailure) {
            bail!("target rollback rejected");
        }
        // Real child execution remains available despite durable withdrawal.
        let status = Command::new("sh").args(["-c", "exit 0"]).status()?;
        ensure!(status.success());
        std::fs::remove_file(&self.mutation)?;
        Ok(())
    }
}

fn exercise() {
    crate::fleet::signal::install().unwrap();
    let root = PathBuf::from(std::env::var_os("XDG_STATE_HOME").unwrap());
    for boundary in [
        Boundary::BeforeFirst,
        Boundary::Acquire,
        Boundary::Deploy,
        Boundary::BeforeHealth,
        Boundary::Health,
        Boundary::FailedDeploy,
        Boundary::DuringRollback,
        Boundary::RollbackFailure,
        Boundary::NoRollback,
        Boundary::InvalidMarker,
    ] {
        let mut invocation = Invocation::parse_legacy(["deploy", "--strategy=agent"]).unwrap();
        invocation.options.no_rollback = matches!(boundary, Boundary::NoRollback);
        let parent = parent(&root, invocation.clone());
        let id = parent.run_id().to_owned();
        let completed_deploy = Cell::new(false);
        let post_deploy_checks = Cell::new(0);
        let mut effects = Effects {
            run: &id,
            boundary,
            mutation: root.join(format!("mutation-{id}")),
            completed_deploy: &completed_deploy,
            phases: Vec::new(),
            rollback: Vec::new(),
        };
        if matches!(boundary, Boundary::BeforeFirst) {
            withdraw(&id);
        }
        let error = execute_retained_with_interrupt_check(&invocation, &mut effects, || {
            if matches!(boundary, Boundary::BeforeHealth) && completed_deploy.get() {
                post_deploy_checks.set(post_deploy_checks.get() + 1);
                if post_deploy_checks.get() == 2 {
                    withdraw(&id);
                }
            }
            check_interrupted(&parent)
        })
        .unwrap_err();
        let message = format!("{error:#}");
        assert!(
            message.contains(if matches!(boundary, Boundary::InvalidMarker) {
                "durable cancellation intent differs"
            } else {
                "durable parent is cancelling"
            }),
            "{boundary:?}: {message}"
        );
        let expected_phases = match boundary {
            Boundary::BeforeFirst => vec![],
            Boundary::Acquire => vec![Phase::Build, Phase::Snapshot, Phase::Acquire],
            Boundary::Health => vec![
                Phase::Build,
                Phase::Snapshot,
                Phase::Acquire,
                Phase::Deploy,
                Phase::Health,
            ],
            _ => vec![Phase::Build, Phase::Snapshot, Phase::Acquire, Phase::Deploy],
        };
        assert_eq!(effects.phases, expected_phases, "{boundary:?}");
        let expected_rollback = match boundary {
            Boundary::BeforeFirst | Boundary::Acquire | Boundary::NoRollback => vec![],
            Boundary::Health => vec![(Phase::Health, true)],
            Boundary::DuringRollback => vec![(Phase::Deploy, false), (Phase::Deploy, true)],
            _ => vec![(Phase::Deploy, true)],
        };
        assert_eq!(effects.rollback, expected_rollback, "{boundary:?}");
        assert_eq!(
            effects.mutation.exists(),
            matches!(boundary, Boundary::NoRollback | Boundary::RollbackFailure),
            "{boundary:?}"
        );
        if matches!(boundary, Boundary::RollbackFailure) {
            assert!(message.contains("target rollback rejected"));
        }
        drop(parent);
        // Reattachment cannot erase withdrawal, including when rollback failed.
        let reopened = Controller::open(&id).unwrap();
        assert!(check_interrupted(&reopened).is_err(), "{boundary:?}");
        assert!(crate::fleet::signal::check_interrupted().is_ok());
    }
}

fn parent(root: &Path, invocation: Invocation) -> Controller {
    let endpoint = SshEndpoint::new(
        "ci",
        "ci.example",
        "operator",
        22,
        TransportRole::Primary,
        None,
    )
    .unwrap();
    admit(
        PendingCapture {
            invocation,
            cwd: root.join("not-read"),
            bootstrap: None,
            environment: None,
        },
        Binding {
            declaration: Description {
                identity: StorageIdentity {
                    authority_id: "authority".into(),
                    builder_id: "ci".into(),
                    store_id: "store".into(),
                },
                issuer: "operator".into(),
                policy: AdmissionPolicy {
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
                        queue_seconds: 60,
                        runtime_seconds: 600,
                        stop_grace_seconds: 3,
                        stop_limit_seconds: 10,
                        retention_seconds: 60,
                    },
                },
            },
            controller: Peer {
                host_id: "controller".into(),
                fabric_id: "fleet".into(),
            },
            builder: Peer {
                host_id: "ci".into(),
                fabric_id: "fleet".into(),
            },
            repository_id: "repo".into(),
            nix: NixOptions {
                max_jobs: 1,
                cores: 2,
                substitute: true,
            },
            target: HostExecutionTarget {
                route: SshRoutePlan::direct(endpoint),
                cwd: root.to_owned(),
                known_hosts_file: None,
                local: true,
                ssh_connect_timeout_seconds: 2,
                ssh_server_alive_interval_seconds: 1,
                ssh_server_alive_count_max: 1,
                remote_read_timeout_seconds: 2,
                control_master: None,
            },
        },
    )
    .unwrap()
}
