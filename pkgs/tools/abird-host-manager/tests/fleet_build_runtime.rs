use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[path = "../src/fleet/build.rs"]
#[allow(dead_code)]
mod build;
#[path = "../src/fleet/build_lease.rs"]
#[allow(dead_code)]
mod build_lease;
#[path = "../src/fleet/build_runtime.rs"]
#[allow(dead_code)]
mod build_runtime;

use build::{
    BuildArgs, CommandAttempt, CommandExecutor, CommandSpec, NixStorePath, RemoteFailureKind,
    RetryPolicy,
};
use build_lease::{ActiveLease, BuilderLeaseCoordinator, LeaseConnector, LeaseProcessSpec};
use build_runtime::{
    RemoteBuildTools, execute_remote_command, plan_remote_build, validate_remote_build_output,
};

#[test]
fn command_plan_is_unrooted_and_preserves_nix_arguments() {
    let tools = RemoteBuildTools::new(
        "/run/current-system/sw/bin/nix",
        "/run/current-system/sw/bin/bash",
        "/run/current-system/sw/bin/flock",
        "/nix/var/nix",
    )
    .unwrap();
    let drv = NixStorePath::derivation("/nix/store/abc-system.drv").unwrap();
    let build = BuildArgs::new(
        vec![
            "--option".to_owned(),
            "eval-cache".to_owned(),
            "false".to_owned(),
        ],
        true,
    );
    let commands = plan_remote_build(&tools, &drv, &build);
    assert_eq!(commands.build.program, "/run/current-system/sw/bin/bash");
    assert_eq!(commands.build.args[0], "-c");
    assert_eq!(commands.build.args[2], "nixbot-build-lease");
    assert_eq!(commands.build.args[3], "run");
    assert_eq!(commands.build.args[4], "/run/current-system/sw/bin/flock");
    assert_eq!(commands.build.args[5], "/nix/var/nix");
    assert_eq!(commands.build.args[6], "/run/current-system/sw/bin/nix");
    assert_eq!(
        &commands.build.args[7..],
        [
            "build",
            "--option",
            "eval-cache",
            "false",
            "--print-out-paths",
            "--no-link",
            "-L",
            "/nix/store/abc-system.drv^out",
        ]
    );
    assert!(
        !commands
            .build
            .args
            .iter()
            .any(|arg| arg.contains("abird-nix-build-lease"))
    );
    assert!(!commands.build.args.contains(&"-o".to_owned()));
}

#[test]
fn build_output_must_be_one_exact_store_path() {
    let built = CommandAttempt::success("/nix/store/output-system\n");
    assert_eq!(
        validate_remote_build_output(&built).unwrap().path.as_str(),
        "/nix/store/output-system"
    );
    assert!(
        validate_remote_build_output(&CommandAttempt::success("/nix/store/a\n/nix/store/b\n"))
            .is_err()
    );
    assert!(validate_remote_build_output(&CommandAttempt::failure(1, "", "build failed")).is_err());
}

#[derive(Default)]
struct FakeExecutor {
    attempts: VecDeque<CommandAttempt>,
    commands: Vec<CommandSpec>,
    waits: Vec<Duration>,
}

impl CommandExecutor for FakeExecutor {
    fn execute(&mut self, command: &CommandSpec) -> CommandAttempt {
        self.commands.push(command.clone());
        self.attempts.pop_front().unwrap()
    }

    fn wait_before_retry(&mut self, delay: Duration) {
        self.waits.push(delay);
    }
}

#[test]
fn injected_execution_retains_daemon_and_transport_retry_evidence() {
    let command = CommandSpec::new("nix", ["build".to_owned()]);
    let mut executor = FakeExecutor {
        attempts: VecDeque::from([
            CommandAttempt::failure(1, "", "Nix daemon disconnected unexpectedly"),
            CommandAttempt::failure(255, "", "client_loop: send disconnect: Broken pipe"),
            CommandAttempt::success("/nix/store/output-system\n"),
        ]),
        ..FakeExecutor::default()
    };
    let execution = execute_remote_command(
        &mut executor,
        &command,
        RetryPolicy::new(3, Duration::from_secs(2)).unwrap(),
    );
    assert_eq!(
        executor.waits,
        [Duration::from_secs(2), Duration::from_secs(4)]
    );
    assert_eq!(
        execution.failures[0].kind,
        RemoteFailureKind::DaemonDisconnect
    );
    assert_eq!(execution.failures[1].kind, RemoteFailureKind::TransportLoss);
}

struct FakeLease {
    confirms: VecDeque<bool>,
    releases: Arc<Mutex<usize>>,
}

impl ActiveLease for FakeLease {
    fn confirm(&mut self) -> anyhow::Result<()> {
        if self.confirms.pop_front().unwrap_or(true) {
            Ok(())
        } else {
            anyhow::bail!("lease lost")
        }
    }

    fn release(&mut self) {
        *self.releases.lock().unwrap() += 1;
    }
}

struct FakeConnector {
    sessions: Mutex<VecDeque<VecDeque<bool>>>,
    releases: Arc<Mutex<usize>>,
}

impl LeaseConnector for FakeConnector {
    fn connect(&self, _spec: &LeaseProcessSpec) -> anyhow::Result<Box<dyn ActiveLease>> {
        Ok(Box::new(FakeLease {
            confirms: self.sessions.lock().unwrap().pop_front().unwrap(),
            releases: Arc::clone(&self.releases),
        }))
    }
}

#[test]
fn lost_lease_is_reacquired_with_a_new_epoch_and_no_remote_cleanup() {
    let releases = Arc::new(Mutex::new(0));
    let connector = Arc::new(FakeConnector {
        sessions: Mutex::new(VecDeque::from([
            VecDeque::from([true, false]),
            VecDeque::from([true, true]),
        ])),
        releases: Arc::clone(&releases),
    });
    let coordinator = BuilderLeaseCoordinator::new(connector);
    let spec = LeaseProcessSpec {
        authority: "builder".to_owned(),
        program: "ssh".to_owned(),
        args: vec!["builder".to_owned()],
        cwd: PathBuf::from("/repo"),
    };
    let first = coordinator.ensure(&spec).unwrap();
    assert!(!first.reacquired);
    let second = coordinator.ensure(&spec).unwrap();
    assert!(second.reacquired);
    assert_ne!(second.epoch, first.epoch);
    coordinator.release();
    assert_eq!(*releases.lock().unwrap(), 2);
}

#[test]
fn coordinator_rejects_builder_authority_changes() {
    let releases = Arc::new(Mutex::new(0));
    let coordinator = BuilderLeaseCoordinator::new(Arc::new(FakeConnector {
        sessions: Mutex::new(VecDeque::from([VecDeque::from([true, true])])),
        releases,
    }));
    let first = LeaseProcessSpec {
        authority: "builder-a".to_owned(),
        program: "ssh".to_owned(),
        args: vec!["builder-a".to_owned()],
        cwd: PathBuf::from("/repo"),
    };
    let mut other = first.clone();
    other.authority = "builder-b".to_owned();
    other.args = vec!["builder-b".to_owned()];
    coordinator.ensure(&first).unwrap();
    assert!(coordinator.ensure(&other).is_err());
}
