use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
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
use build_lease::{
    ActiveLease, BuilderLeaseCoordinator, LeaseConnector, LeaseObservation, LeaseProcessSpec,
    LeaseRetryClock, LeaseRetryPolicy, SystemLeaseConnector,
};
use build_runtime::{
    ProtectedBuilder, RemoteBuildTools, execute_remote_command, plan_remote_build,
    realize_protected, validate_remote_build_output,
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
            "--fallback",
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

fn replacement_epochs(count: usize) -> Vec<LeaseObservation> {
    let coordinator = BuilderLeaseCoordinator::new(Arc::new(FakeConnector {
        sessions: Mutex::new((0..count).map(|_| VecDeque::from([true, false])).collect()),
        releases: Arc::new(Mutex::new(0)),
    }));
    let spec = LeaseProcessSpec {
        authority: "builder".to_owned(),
        program: "ssh".to_owned(),
        args: vec![],
        cwd: PathBuf::from("/repo"),
    };
    (0..count)
        .map(|_| coordinator.ensure(&spec).unwrap())
        .collect()
}

struct FakeProtectedBuilder {
    leases: VecDeque<LeaseObservation>,
    outputs: VecDeque<NixStorePath>,
    verification_results: VecDeque<bool>,
    verified: Vec<NixStorePath>,
    realizations: usize,
    confirmations: usize,
}

impl ProtectedBuilder for FakeProtectedBuilder {
    fn ensure_lease(&mut self) -> anyhow::Result<LeaseObservation> {
        self.confirmations += 1;
        Ok(self
            .leases
            .pop_front()
            .expect("unexpected extra lease confirmation"))
    }

    fn realize(&mut self) -> anyhow::Result<NixStorePath> {
        self.realizations += 1;
        Ok(self
            .outputs
            .pop_front()
            .expect("unexpected extra realization"))
    }

    fn verify_closure(&mut self, closure: &NixStorePath) -> anyhow::Result<bool> {
        self.verified.push(closure.clone());
        Ok(self
            .verification_results
            .pop_front()
            .expect("unexpected closure verification"))
    }
}

fn protected_builder(
    leases: impl IntoIterator<Item = LeaseObservation>,
    outputs: &[&str],
    verification_results: &[bool],
) -> FakeProtectedBuilder {
    FakeProtectedBuilder {
        leases: leases.into_iter().collect(),
        outputs: outputs
            .iter()
            .map(|path| NixStorePath::closure_output(path).unwrap())
            .collect(),
        verification_results: verification_results.iter().copied().collect(),
        verified: Vec::new(),
        realizations: 0,
        confirmations: 0,
    }
}

#[test]
fn protected_realization_rejects_changed_output_after_lease_loss() {
    let epochs = replacement_epochs(2);
    let mut builder = protected_builder(
        [epochs[0], epochs[1], epochs[1], epochs[1]],
        &["/nix/store/original-system", "/nix/store/changed-system"],
        &[false],
    );
    let error = realize_protected(&mut builder, 3)
        .expect_err("lease recovery must retain the first realized output identity");
    assert!(
        error
            .to_string()
            .contains("expected /nix/store/original-system")
    );
    assert_eq!(builder.realizations, 2);
    assert_eq!(
        builder.verified,
        [NixStorePath::closure_output("/nix/store/original-system").unwrap()]
    );
}

#[test]
fn protected_realization_verifies_only_pending_closure_then_reconfirms_lease() {
    let epochs = replacement_epochs(2);
    let mut builder = protected_builder(
        [epochs[0], epochs[1], epochs[1], epochs[1]],
        &["/nix/store/pending-system"],
        &[true],
    );
    let (closure, epoch) = realize_protected(&mut builder, 3).unwrap();
    assert_eq!(closure.as_str(), "/nix/store/pending-system");
    assert_eq!(epoch, epochs[1].epoch);
    assert_eq!(builder.realizations, 1);
    assert_eq!(builder.confirmations, 4);
    assert_eq!(builder.verified, [closure]);
}

#[test]
fn protected_realization_retries_when_verification_loses_its_lease_epoch() {
    let epochs = replacement_epochs(3);
    let mut builder = protected_builder(
        [
            epochs[0], epochs[1], epochs[1], epochs[2], epochs[2], epochs[2],
        ],
        &["/nix/store/pending-system"],
        &[true, true],
    );
    let (closure, epoch) = realize_protected(&mut builder, 3).unwrap();
    assert_eq!(epoch, epochs[2].epoch);
    assert_eq!(builder.realizations, 1);
    assert_eq!(builder.confirmations, 6);
    assert_eq!(builder.verified, [closure.clone(), closure]);
}

#[derive(Default)]
struct FakeRetryClock {
    elapsed: Mutex<Duration>,
    waits: Mutex<Vec<Duration>>,
    cancel_after_wait: Mutex<Option<Arc<AtomicBool>>>,
}

impl FakeRetryClock {
    fn advance(&self, duration: Duration) {
        *self.elapsed.lock().unwrap() += duration;
    }
}

impl LeaseRetryClock for FakeRetryClock {
    fn now(&self) -> Duration {
        *self.elapsed.lock().unwrap()
    }
    fn wait(&self, duration: Duration) {
        self.waits.lock().unwrap().push(duration);
        self.advance(duration);
        if let Some(cancelled) = self.cancel_after_wait.lock().unwrap().as_ref() {
            cancelled.store(true, Ordering::Release);
        }
    }
}

enum ConnectionAttempt {
    Failure(Duration),
    Lease(VecDeque<(Duration, bool)>),
}

struct RetryConnector {
    attempts: Mutex<VecDeque<ConnectionAttempt>>,
    calls: Mutex<usize>,
    clock: Arc<FakeRetryClock>,
    releases: Arc<Mutex<usize>>,
}

struct RetryLease {
    confirmations: VecDeque<(Duration, bool)>,
    clock: Arc<FakeRetryClock>,
    releases: Arc<Mutex<usize>>,
}

impl ActiveLease for RetryLease {
    fn confirm(&mut self) -> anyhow::Result<()> {
        let (duration, succeeds) = self
            .confirmations
            .pop_front()
            .unwrap_or((Duration::ZERO, true));
        self.clock.advance(duration);
        if succeeds {
            Ok(())
        } else {
            anyhow::bail!("confirmation disconnected")
        }
    }
    fn release(&mut self) {
        *self.releases.lock().unwrap() += 1;
    }
}

impl LeaseConnector for RetryConnector {
    fn connect(&self, _spec: &LeaseProcessSpec) -> anyhow::Result<Box<dyn ActiveLease>> {
        *self.calls.lock().unwrap() += 1;
        match self
            .attempts
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected connection attempt")
        {
            ConnectionAttempt::Failure(duration) => {
                self.clock.advance(duration);
                anyhow::bail!("transport disconnected")
            }
            ConnectionAttempt::Lease(confirmations) => Ok(Box::new(RetryLease {
                confirmations,
                clock: Arc::clone(&self.clock),
                releases: Arc::clone(&self.releases),
            })),
        }
    }
}

fn retry_spec() -> LeaseProcessSpec {
    LeaseProcessSpec {
        authority: "builder".to_owned(),
        program: "ssh".to_owned(),
        args: vec![],
        cwd: PathBuf::from("/repo"),
    }
}

fn session(confirms: &[bool]) -> ConnectionAttempt {
    ConnectionAttempt::Lease(
        confirms
            .iter()
            .map(|succeeds| (Duration::ZERO, *succeeds))
            .collect(),
    )
}

fn retry_coordinator(
    attempts: Vec<ConnectionAttempt>,
    retry: LeaseRetryPolicy,
) -> (
    BuilderLeaseCoordinator,
    Arc<RetryConnector>,
    Arc<FakeRetryClock>,
) {
    let clock = Arc::new(FakeRetryClock::default());
    let connector = Arc::new(RetryConnector {
        attempts: Mutex::new(attempts.into()),
        calls: Mutex::new(0),
        clock: Arc::clone(&clock),
        releases: Arc::new(Mutex::new(0)),
    });
    let coordinator =
        BuilderLeaseCoordinator::with_retry_clock(connector.clone(), retry, clock.clone());
    (coordinator, connector, clock)
}

#[test]
fn lease_acquisition_retries_connect_and_acquired_confirmation_failures() {
    let (coordinator, connector, clock) = retry_coordinator(
        vec![
            ConnectionAttempt::Failure(Duration::ZERO),
            session(&[false]),
            session(&[true]),
        ],
        LeaseRetryPolicy::new(3, Duration::from_millis(2), Duration::from_secs(1)).unwrap(),
    );
    let lease = coordinator.ensure(&retry_spec()).unwrap();
    assert!(!lease.reacquired);
    assert_eq!(*connector.calls.lock().unwrap(), 3);
    assert_eq!(*connector.releases.lock().unwrap(), 1);
    assert_eq!(
        *clock.waits.lock().unwrap(),
        [Duration::from_millis(2), Duration::from_millis(4)]
    );
}

#[test]
fn each_lost_confirmed_lease_receives_a_fresh_reconnect_budget() {
    let failure = || ConnectionAttempt::Failure(Duration::ZERO);
    let (coordinator, connector, _clock) = retry_coordinator(
        vec![
            session(&[true, false]),
            failure(),
            failure(),
            session(&[true, false]),
            failure(),
            failure(),
            session(&[true]),
        ],
        LeaseRetryPolicy::new(3, Duration::ZERO, Duration::from_secs(1)).unwrap(),
    );
    let first = coordinator.ensure(&retry_spec()).unwrap();
    let second = coordinator.ensure(&retry_spec()).unwrap();
    let third = coordinator.ensure(&retry_spec()).unwrap();
    assert!(second.reacquired && third.reacquired);
    assert!(first.epoch < second.epoch && second.epoch < third.epoch);
    assert_eq!(*connector.calls.lock().unwrap(), 7);
    assert_eq!(*connector.releases.lock().unwrap(), 2);
}

#[test]
fn lease_reconnect_stops_at_elapsed_budget_before_attempt_limit() {
    let (coordinator, connector, clock) = retry_coordinator(
        vec![
            ConnectionAttempt::Failure(Duration::from_millis(1)),
            ConnectionAttempt::Failure(Duration::from_millis(2)),
        ],
        LeaseRetryPolicy::new(5, Duration::from_millis(2), Duration::from_millis(5)).unwrap(),
    );
    let error = coordinator
        .ensure(&retry_spec())
        .expect_err("elapsed retry budget must stop reconnecting");
    assert!(error.to_string().contains("time budget"));
    assert_eq!(*connector.calls.lock().unwrap(), 2);
    assert_eq!(clock.now(), Duration::from_millis(5));
}

#[test]
fn acquired_confirmation_after_deadline_is_released_and_rejected() {
    let (coordinator, connector, _clock) = retry_coordinator(
        vec![ConnectionAttempt::Lease(VecDeque::from([(
            Duration::from_millis(6),
            true,
        )]))],
        LeaseRetryPolicy::new(3, Duration::ZERO, Duration::from_millis(5)).unwrap(),
    );
    let error = coordinator
        .ensure(&retry_spec())
        .expect_err("late confirmation cannot establish protection");
    assert!(error.to_string().contains("time budget"));
    assert_eq!(*connector.calls.lock().unwrap(), 1);
    assert_eq!(*connector.releases.lock().unwrap(), 1);
}

#[test]
fn cancellation_interrupts_reconnect_backoff_before_another_connection() {
    let (coordinator, connector, clock) = retry_coordinator(
        vec![ConnectionAttempt::Failure(Duration::ZERO)],
        LeaseRetryPolicy::new(3, Duration::from_secs(2), Duration::from_secs(10)).unwrap(),
    );
    let cancelled = Arc::new(AtomicBool::new(false));
    *clock.cancel_after_wait.lock().unwrap() = Some(Arc::clone(&cancelled));
    let coordinator =
        coordinator.with_cancellation(Arc::new(move || cancelled.load(Ordering::Acquire)));
    let error = coordinator
        .ensure(&retry_spec())
        .expect_err("cancellation must interrupt backoff");
    assert!(error.to_string().contains("cancelled"));
    assert_eq!(*connector.calls.lock().unwrap(), 1);
    assert_eq!(*clock.waits.lock().unwrap(), [Duration::from_millis(100)]);
}

#[test]
fn live_lease_transport_confirms_heartbeat_and_releases_cleanly() {
    let coordinator = BuilderLeaseCoordinator::with_retry_policy(
        Arc::new(SystemLeaseConnector),
        LeaseRetryPolicy::new(1, Duration::ZERO, Duration::from_secs(2)).unwrap(),
    );
    let spec = LeaseProcessSpec {
        authority: "local-protocol-fixture".to_owned(),
        program: "sh".to_owned(),
        args: vec!["-c".to_owned(), "printf 'READY\\n'; while IFS= read -r frame; do [ \"$frame\" = PING ] || exit 2; printf 'PONG\\n'; done".to_owned()],
        cwd: std::env::current_dir().unwrap(),
    };
    let first = coordinator.ensure(&spec).unwrap();
    let second = coordinator.ensure(&spec).unwrap();
    assert_eq!(first.epoch, second.epoch);
    assert!(!second.reacquired);
    coordinator.release();
}

#[test]
fn live_acquired_lease_missing_heartbeat_obeys_remaining_budget() {
    let coordinator = BuilderLeaseCoordinator::with_retry_policy(
        Arc::new(SystemLeaseConnector),
        LeaseRetryPolicy::new(1, Duration::ZERO, Duration::from_millis(100)).unwrap(),
    );
    let spec = LeaseProcessSpec {
        authority: "local-protocol-fixture".to_owned(),
        program: "sh".to_owned(),
        args: vec![
            "-c".to_owned(),
            "printf 'READY\\n'; while IFS= read -r frame; do :; done".to_owned(),
        ],
        cwd: std::env::current_dir().unwrap(),
    };
    let started = std::time::Instant::now();
    let error = coordinator
        .ensure(&spec)
        .expect_err("missing heartbeat cannot establish a lease");
    assert!(format!("{error:#}").contains("time budget"));
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "the remaining budget must replace the default 20-second heartbeat timeout"
    );
}

#[test]
fn periodic_lease_heartbeat_runs_before_the_console_progress_interval() {
    use std::collections::BTreeMap;
    use std::fs;
    use std::sync::atomic::AtomicUsize;
    use std::time::Instant;

    use abird_host_manager::fleet::cli::Options;
    use abird_host_manager::fleet::environment::Environment;
    use abird_host_manager::fleet::host_runtime::{
        EffectKind, ProcessEventObserver, ProcessRequest, ProcessRunner, ProcessStream,
        ReportingProcessRunner,
    };
    use abird_host_manager::fleet::presentation::FleetProgress;

    struct CountingProgress {
        inner: Arc<dyn ProcessEventObserver>,
        heartbeats: Arc<AtomicUsize>,
    }
    impl ProcessEventObserver for CountingProgress {
        fn started(&self, request: &ProcessRequest) {
            self.inner.started(request);
        }
        fn output(&self, request: &ProcessRequest, stream: ProcessStream, chunk: &str) {
            self.inner.output(request, stream, chunk);
        }
        fn finished(&self, request: &ProcessRequest, elapsed: Duration, succeeded: bool) {
            self.inner.finished(request, elapsed, succeeded);
        }
        fn heartbeat_interval(&self, request: &ProcessRequest) -> Option<Duration> {
            self.inner.heartbeat_interval(request)
        }
        fn heartbeat(&self, request: &ProcessRequest, elapsed: Duration) {
            self.heartbeats.fetch_add(1, Ordering::Relaxed);
            self.inner.heartbeat(request, elapsed);
        }
    }

    let temporary = tempfile::tempdir().unwrap();
    let frames = temporary.path().join("frames");
    let periodic_seen = temporary.path().join("periodic-seen");
    let spec = LeaseProcessSpec {
        authority: "local-periodic-protocol-fixture".to_owned(),
        program: "sh".to_owned(),
        args: vec![
            "-c".to_owned(),
            r#"printf 'READY\n'
count=0
while IFS= read -r frame; do
    [ "$frame" = PING ] || exit 2
    count=$((count + 1))
    printf '%s\n' "$frame" >> "$1"
    printf 'PONG\n'
    if [ "$count" -ge 2 ]; then : > "$2"; fi
done"#
                .to_owned(),
            "periodic-lease-fixture".to_owned(),
            frames.to_string_lossy().into_owned(),
            periodic_seen.to_string_lossy().into_owned(),
        ],
        cwd: temporary.path().to_path_buf(),
    };
    let coordinator = BuilderLeaseCoordinator::with_retry_policy(
        Arc::new(SystemLeaseConnector),
        LeaseRetryPolicy::new(1, Duration::ZERO, Duration::from_secs(2)).unwrap(),
    );
    coordinator.ensure(&spec).unwrap();
    assert_eq!(fs::read_to_string(&frames).unwrap(), "PING\n");

    let settings = Environment::from_map(BTreeMap::from([(
        "NIXBOT_BUILD_HEARTBEAT_SECS".to_owned(),
        "60".to_owned(),
    )]))
    .settings()
    .unwrap();
    let progress = FleetProgress::from_options(&Options::default())
        .with_heartbeat_intervals(
            settings.build_heartbeat_seconds,
            settings.activation_heartbeat_seconds,
        )
        .process_observer();
    let heartbeats = Arc::new(AtomicUsize::new(0));
    let observer: Arc<dyn ProcessEventObserver> = Arc::new(CountingProgress {
        inner: progress,
        heartbeats: Arc::clone(&heartbeats),
    });
    let request = ProcessRequest {
        // This process emits no progress and ends only after the transport
        // observes another PING, or at the fixture's bounded deadline.
        program: "timeout".to_owned(),
        args: vec![
            "15".to_owned(),
            "sh".to_owned(),
            "-c".to_owned(),
            "while [ ! -f \"$1\" ]; do sleep 0.02; done".to_owned(),
            "silent-build-fixture".to_owned(),
            periodic_seen.to_string_lossy().into_owned(),
        ],
        environment: Vec::new(),
        clear_git_repository_environment: false,
        cwd: temporary.path().to_path_buf(),
        stdin: None,
        effect: EffectKind::ReadOnly,
        label: "fixture-remote-build".to_owned(),
    };
    let progress_interval = observer.heartbeat_interval(&request).unwrap();
    assert_eq!(progress_interval, Duration::from_secs(60));
    let started = Instant::now();
    let output = ReportingProcessRunner::new(observer).run(&request).unwrap();
    let elapsed = started.elapsed();
    coordinator.release();

    // No further ensure/confirm call or fixture scheduler sends PING. The
    // production lease driver's idle timer must supply the second frame.
    assert!(output.succeeded(), "{output:?}");
    assert!(output.stdout.is_empty() && output.stderr.is_empty());
    assert_eq!(fs::read_to_string(&frames).unwrap(), "PING\nPING\n");
    assert!(elapsed < progress_interval, "{elapsed:?}");
    assert_eq!(heartbeats.load(Ordering::Relaxed), 0);
}
