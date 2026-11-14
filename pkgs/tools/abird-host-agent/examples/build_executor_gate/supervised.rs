//! Synthetic supervisor fixture only. Not source verification or a production role.
use super::*;
use abird_host_agent::build_executor::context::{
    BuildAction, EvaluationIntent, InputLocation, PlanJobs,
};
use abird_host_agent::build_executor::journal::{JobStatus, Journal};
use abird_host_agent::build_executor::request::*;
use abird_host_agent::build_executor::supervisor::{
    Active, ClientObservation, Ingress, Launcher, Progress, Supervisor,
};
use abird_host_agent::build_executor::units::Units;
use abird_host_agent::build_executor::{ExecutionHandle, StopReason};
use std::path::Path;

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}
const NATIVE_POLICY: &str = "/etc/abird-owned-build/daemon.json";
const CONTROL_POLICY: &str = "/etc/abird-owned-build/control.json";

fn policy() -> AdmissionPolicy {
    let bytes = fs::read(CONTROL_POLICY).expect("installed fixture control declaration");
    let control: abird_host_agent::build_executor::control::Config =
        serde_json::from_slice(&bytes).expect("fixture control schema");
    control.policy
}
fn request() -> BuildRequest {
    BuildRequest {
        parent: None,
        schema_version: REQUEST_VERSION,
        executor_version: 1,
        id: RequestId {
            issued_at: now(),
            nonce: "supervised".into(),
        },
        run_id: "qualification".into(),
        issuer: "operator".into(),
        repository_id: "fixture".into(),
        source: Source {
            revision: "a".repeat(40),
            base_revision: "a".repeat(40),
            tree_digest: None,
            patch_digest: None,
        },
        controller: Peer {
            host_id: "controller".into(),
            fabric_id: "fixture".into(),
        },
        builder: Peer {
            host_id: "builder".into(),
            fabric_id: "fixture".into(),
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
                host: "fixture".into(),
                configuration: "fixture".into(),
                outputs: vec!["out".into()],
            }],
        },
        required_hosts: vec!["fixture".into()],
        nix: NixOptions {
            max_jobs: 1,
            cores: 1,
            substitute: false,
        },
        policy_digest: policy().digest().unwrap(),
        deadlines: policy().deadlines,
        owner: Owner::Detached,
        predecessor: None,
    }
}
fn execution(owner: Ownership) -> Permit {
    Permit {
        version: 1,
        identity: identity(),
        permission: Permission::Execution { ownership: owner },
    }
}

fn prepare_fixture(
    root: &std::path::Path,
    journal: &Journal,
    gate: &Gate,
    acceptance: abird_host_agent::build_executor::journal::Acceptance,
    time: u64,
    expression: &str,
) -> Result<()> {
    fs::write(root.join("client-expression"), expression)?;
    journal.queue(&acceptance.attempt_id, time)?;
    let native = abird_host_agent::build_executor::daemon::Policy::load(std::path::Path::new(
        NATIVE_POLICY,
    ))?;
    journal.recovered(
        journal.pool()?.epoch,
        gate.boot_id(),
        &native.containment_digest,
        time,
    )?;
    fs::write(root.join("request-id"), &acceptance.attempt_id)?;
    println!("abird-build-client@{}.service", acceptance.attempt_id);
    Ok(())
}

struct FixtureIngress(Units);
impl Launcher for FixtureIngress {
    fn ready(
        &mut self,
        fence: &abird_host_agent::build_executor::launch_gate::Fence<'_>,
        _: &abird_host_agent::build_executor::journal::Pool,
    ) -> Result<bool> {
        // Isolated VM role only; this is not a production/global ingress verifier.
        Ok(
            FencedWorkload::new(fence)?.population()? == Population::Empty
                && self.0.socket()?.stopped()
                && self.0.daemon()?.stopped(),
        )
    }
    fn start_once(&mut self, owner: &Ownership) -> Result<()> {
        let unit = self.0.client(owner)?;
        ensure!(
            unit.stopped() && unit.invocation.is_none(),
            "fixture client already used"
        );
        fs::write("/run/qualification-open", b"")?;
        self.0.request_start(owner)
    }
}
impl Ingress for FixtureIngress {
    fn observe_client(&mut self, active: &Active) -> Result<ClientObservation> {
        self.0
            .client(&active.owner)?
            .observe_client(&active.owner, active.handle.as_ref())
    }
    fn owns_ingress(&mut self, active: &Active) -> Result<bool> {
        // Trust is restricted to this disposable VM's declared, isolated fixture.
        // Production needs complete ingress/maintenance qualification, not this check.
        let client = self.0.client(&active.owner)?;
        self.0.daemon()?;
        Ok(active
            .handle
            .as_ref()
            .is_none_or(|handle| client.matches_handle(handle).unwrap_or(false)))
    }
    fn request_stop(&mut self, active: &Active) -> Result<()> {
        match fs::remove_file("/run/qualification-open") {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
        self.0.request_stop(&active.owner)
    }
    fn quiescent(&mut self, _: &Active) -> Result<bool> {
        // Stop ACK replaced pending starts; Restart=no checked above. Socket is
        // actually closed and the exec fence stays held. Stop jobs may still run.
        Ok(self.0.socket()?.stopped())
    }
}

pub fn run(
    action: &str,
    root: &std::path::Path,
    mut args: impl Iterator<Item = String>,
) -> Result<()> {
    if action == "supervised-init" {
        // Exercise installed one-shot provisioning. Never manufacture its store
        // binding, completion receipt or a mutable control-policy substitute.
        let systemctl = args.next().context("pinned systemctl required")?;
        ensure!(
            Command::new(systemctl)
                .args(["start", "abird-owned-build-bootstrap.service"])
                .status()?
                .success(),
            "installed fixture bootstrap failed"
        );
        Journal::open(root, identity(), policy())?;
        Gate::open(&root.join("launch"), identity())?;
        return Ok(());
    }
    let journal = Journal::open(root, identity(), policy())?;
    let gate = Gate::open(&root.join("launch"), identity())?;
    if matches!(
        action,
        "supervised-roots-check" | "supervised-roots-release" | "supervised-roots-retire"
    ) {
        return super::protection::inspect(action, root, &journal, now());
    }
    if matches!(
        action,
        "supervised-source-retire-empty" | "supervised-source-retain-nonempty"
    ) {
        return super::private_source::inspect(action, root, &journal, now());
    }
    if action == "supervised-prepare" {
        let _controller = gate.try_controller()?.context("controller busy")?;
        let fence = gate.try_fence()?.context("launch pending")?;
        ensure!(
            FencedWorkload::new(&fence)?.population()? == Population::Empty,
            "fixture is not empty"
        );
        let time = now();
        let nonce = args.next().unwrap_or("supervised".into());
        if nonce == "collect" {
            let acceptance = journal.submit_maintenance(
                abird_host_agent::build_executor::maintenance::Request {
                    version: abird_host_agent::build_executor::maintenance::VERSION,
                    id: RequestId {
                        issued_at: time,
                        nonce,
                    },
                    storage: identity(),
                    policy_digest: policy().digest()?,
                    deadlines: policy().deadlines,
                    operation:
                        abird_host_agent::build_executor::maintenance::Operation::CollectGarbage,
                },
                time,
            )?;
            return prepare_fixture(root, &journal, &gate, acceptance, time, "collect");
        }
        let mut request = request();
        request.id.nonce = nonce;
        if request.id.nonce == "private-copy" {
            request.source = super::private_source::intent();
        }
        let native = matches!(
            request.id.nonce.as_str(),
            "native-base"
                | "native-overlay"
                | "native-config"
                | "native-partial"
                | "native-fallback"
        );
        if native {
            request.evaluation.repository_config = Some(InputLocation::source("config"));
            request.evaluation.dependency_flake = InputLocation::source("fallback");
            let configured = matches!(
                request.id.nonce.as_str(),
                "native-config" | "native-partial"
            );
            request.selection = Selection::Fleet {
                groups: Vec::new(),
                host: configured.then(|| "app".into()),
                hosts: None,
                nix_config: configured.then(|| {
                    if request.id.nonce == "native-config" {
                        "alternate"
                    } else {
                        "missing"
                    }
                    .into()
                }),
                control_plane_first: false,
            };
            request.required_hosts = vec!["app".into(), "db".into()];
            if configured || request.id.nonce == "native-overlay" {
                request.evaluation.overlay = Some(InputLocation::source("operator.nix"));
            }
            if request.id.nonce == "native-overlay" {
                request.evaluation.action = BuildAction::Deploy;
                request.owner = Owner::Foreground {
                    token_digest: "e".repeat(64),
                };
                request.required_hosts = vec!["external".into()];
            }
            if request.id.nonce == "native-config" {
                request.mode = BuildMode::Development;
                request.evaluation.action = BuildAction::DevBuild;
            }
            if request.id.nonce == "native-fallback" {
                request.evaluation.build_flake = InputLocation::source("fallback");
            }
        }
        let expression = match request.id.nonce.as_str() {
            "healthy" => "/etc/healthy-build.nix",
            "protected" => "protected",
            "private-copy" => "private-copy",
            "source-slot-empty" => "source-slot-empty",
            _ if native => "native",
            _ => "/etc/blocked-build.nix",
        };
        let native_request = native.then(|| serde_json::to_vec(&request)).transpose()?;
        let acceptance = journal.submit("operator", request, time)?;
        if let Some(bytes) = native_request {
            use std::os::unix::fs::PermissionsExt;
            fs::write(root.join("native-request"), bytes)?;
            fs::set_permissions(
                root.join("native-request"),
                fs::Permissions::from_mode(0o600),
            )?;
        }
        return prepare_fixture(root, &journal, &gate, acceptance, time, expression);
    }

    if action == "supervised-retention-check" {
        let store =
            abird_host_agent::build_executor::store_interlock::StoreInterlock::open(identity())?;
        println!(
            "serialized_retention_clear={}",
            store.try_retention_check(&journal)?.is_some()
        );
        return Ok(());
    }
    if action == "supervised-status" {
        let key = fs::read_to_string(root.join("request-id"))?;
        let (attempt, pool) = if fs::read_to_string(root.join("client-expression"))? == "collect" {
            let status = journal.maintenance_status(&key)?;
            (Box::new(status.attempt), status.pool)
        } else {
            let JobStatus::Live { attempt, pool, .. } = journal.status("operator", &key)? else {
                bail!("unexpected retirement")
            };
            (attempt, pool)
        };
        let snapshot = journal.supervision()?;
        println!(
            "{}",
            serde_json::json!({"phase": attempt.phase(), "outcome": attempt.outcome(), "pool": pool,
            "stop": snapshot.active.and_then(|active| active.stop)})
        );
        return Ok(());
    }
    if action == "supervised-stop" {
        let owner = journal.pool()?.owner.context("no active owner")?;
        journal.stop(&owner, StopReason::Cancelled, now())?;
        return Ok(());
    }
    if action == "supervised-poll" {
        let systemctl = PathBuf::from(args.next().context("pinned systemctl required")?);
        let controller = gate.try_controller()?.context("controller busy")?;
        let mut supervisor = Supervisor::new(&journal, controller)?;
        let store =
            abird_host_agent::build_executor::store_interlock::StoreInterlock::open(identity())?;
        let mut ingress = FixtureIngress(Units::new(systemctl, Duration::from_secs(2))?);
        let deadline = Instant::now() + Duration::from_secs(120);
        let mut previous = None;
        loop {
            if journal.pool()?.health == abird_host_agent::build_executor::PoolHealth::Available {
                supervisor.launch_next(&store, &mut ingress, now())?;
            }
            let progress = supervisor.poll(&mut ingress, now())?;
            if progress == Progress::Verifying {
                // Synthetic Build/collector paths never certify artifacts. The
                // installed supervisor alone finishes real verifier receipts.
                let owner = journal
                    .pool()?
                    .owner
                    .context("fixture verifier owner missing")?;
                journal.stop(&owner, StopReason::VerificationFailed, now())?;
            }
            if previous != Some(progress) {
                println!("{progress:?}");
                std::io::stdout().flush()?;
                previous = Some(progress);
            }
            if matches!(progress, Progress::Settled | Progress::Interrupted) {
                return Ok(());
            }
            ensure!(
                Instant::now() < deadline,
                "supervisor qualification timed out"
            );
            std::thread::park_timeout(Duration::from_millis(100));
        }
    }
    let owner = journal.pool()?.owner.context("no active owner")?;
    if action == "supervised-client" {
        ensure!(
            args.next().as_deref() == Some(owner.attempt_id.as_str()),
            "stale client instance"
        );
    }
    workload::require_wrapper_placement()?;
    if action == "supervised-client"
        && journal
            .maintenance_status(&owner.attempt_id)
            .is_ok_and(|status| {
                matches!(
                    status.request.operation,
                    abird_host_agent::build_executor::maintenance::Operation::RetireFailed { .. }
                )
            })
    {
        let native = abird_host_agent::build_executor::daemon::Policy::load(std::path::Path::new(
            NATIVE_POLICY,
        ))?;
        // Real queued Retirement; never provision a native gate or replay Build.
        return Err(Command::new(&native.launcher)
            .args(["_owned-worker", "--role"])
            .arg(&native.role_policy)
            .arg("--attempt")
            .arg(&owner.attempt_id)
            .env_clear()
            .env("HOME", "/var/empty")
            .env(
                "XDG_STATE_HOME",
                Path::new(&std::env::var("OB_GATE_HOME")?).join(".local/state"),
            )
            .env(
                "XDG_DATA_HOME",
                Path::new(&std::env::var("OB_GATE_HOME")?).join(".local/share"),
            )
            .env("INVOCATION_ID", std::env::var("INVOCATION_ID")?)
            .exec()
            .into());
    }
    if action == "supervised-client"
        && fs::read_to_string(root.join("client-expression"))? == "collect"
    {
        // Exercise the actual installed worker. The example does not grant a
        // worker invocation or acquire the maintenance interlock on its behalf.
        use std::os::fd::AsRawFd;
        let declaration = std::path::Path::new(NATIVE_POLICY);
        let policy = abird_host_agent::build_executor::daemon::Policy::load(declaration)?;
        let extra = File::open("/dev/null")?;
        ensure!(
            unsafe { libc::dup2(extra.as_raw_fd(), 190) } == 190,
            "fixture descriptor"
        );
        let mut child = Command::new(policy.launcher)
            .args(["_owned-maintenance", "--policy"])
            .arg(declaration)
            .arg("--control")
            .arg(CONTROL_POLICY)
            .arg("--attempt")
            .arg(&owner.attempt_id)
            .env_clear()
            .env("HOME", "/var/empty")
            .env(
                "XDG_STATE_HOME",
                std::path::Path::new(&std::env::var("OB_GATE_HOME")?).join(".local/state"),
            )
            .env("INVOCATION_ID", std::env::var("INVOCATION_ID")?)
            .env(
                "OB_MAINTENANCE_PRIVATE_SENTINEL",
                "must-not-reach-collector",
            )
            .env("NIX_CONFIG", "untrusted-maintenance-sentinel = true")
            .spawn()?;
        // Root fault driver only. The installed collector has no marker hook,
        // inherited diagnostic FD or root credentials. A VM-held native GC lock
        // supplies the pause; observing this file is not settlement.
        fs::write(
            "/run/qualification-maintenance-worker-pid",
            child.id().to_string(),
        )?;
        let exit = child.wait()?;
        ensure!(exit.success(), "installed maintenance fixture failed");
        println!("MAINTENANCE_COLLECTOR_EXITED");
        return Ok(());
    }
    let _launch = gate
        .authorize(&execution(owner.clone()))?
        .context("launch pending")?;
    let executable = args.next().context("pinned Nix executable required")?;
    let mut command = Command::new(&executable);
    match action {
        "supervised-gc" => {
            drop_native_credentials()?;
            command.env_clear().args(["--store", "daemon", "--gc"]);
        }
        "supervised-daemon" => {
            command.arg("--daemon");
        }
        "supervised-helper" => {
            drop_native_credentials()?;
            command
                .env_clear()
                .arg(args.next().context("fixture FIFO required")?);
        }
        "supervised-client" => {
            let expression = fs::read_to_string(root.join("client-expression"))?;
            let native_input = (expression == "native")
                .then(|| fs::File::open(root.join("native-request")))
                .transpose()?;
            // A maintenance row cannot enter a build branch if this diagnostic
            // expression file changed or lied about its kind.
            journal.status("operator", &owner.attempt_id)?;
            abird_host_agent::build_executor::native_phase::begin_worker(
                &journal,
                &gate,
                ExecutionHandle {
                    ownership: owner.clone(),
                    invocation_id: std::env::var("INVOCATION_ID")?,
                },
                now(),
            )?;
            if expression == "private-copy" {
                drop(_launch);
                return super::private_source::client(
                    root,
                    &owner,
                    std::path::Path::new(&executable),
                    &journal,
                    &gate,
                    now(),
                );
            }
            if expression == "source-slot-empty" {
                drop(_launch);
                return super::private_source::empty_client(&journal, &gate, owner, now());
            }
            if expression == "protected" {
                // This fixed, admitted Rust worker now owns its in-slice child
                // commands. Do not pin the launch lock across the workflow.
                drop(_launch);
                return super::protection::client(
                    root,
                    &journal,
                    &gate,
                    owner,
                    std::path::Path::new(&executable),
                );
            }
            drop_native_credentials()?;
            if expression == "native" {
                return Err(Command::new(std::env::var("OB_NATIVE_PREPARATION")?)
                    .stdin(native_input.context("native request input missing")?)
                    .env_clear()
                    .env("HOME", "/home/builder")
                    .env("NIX_REMOTE", "daemon")
                    .arg(&executable)
                    .arg(std::env::var("OB_NATIVE_PREPARATION_SOURCE")?)
                    .exec()
                    .into());
            }
            command
                .env_clear()
                .env("HOME", "/home/builder")
                .args([
                    "build",
                    "--store",
                    "daemon",
                    "--no-link",
                    "--print-build-logs",
                    "--file",
                ])
                .arg(expression);
        }
        _ => bail!("unknown supervised fixture action"),
    }
    Err(command.exec().into())
}

// Fixed synthetic native clients share the installed executor identity.
fn drop_native_credentials() -> Result<()> {
    ensure!(
        unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } == 0,
        "fixture no-new-privileges"
    );
    ensure!(
        unsafe { libc::setgroups(0, std::ptr::null()) } == 0
            && unsafe { libc::setresgid(1000, 1000, 1000) } == 0
            && unsafe { libc::setresuid(1000, 1000, 1000) } == 0,
        "fixture native credentials"
    );
    Ok(())
}
