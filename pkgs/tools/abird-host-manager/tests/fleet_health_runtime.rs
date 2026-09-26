use std::collections::{BTreeSet, VecDeque};
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use abird_host_manager::fleet::health::{HealthDecision, HealthEvidence};
use abird_host_manager::fleet::health_runtime::check_managed_health_with_ignored_system_units;
use abird_host_manager::fleet::host_runtime::{
    DryRun, HostExecutionTarget, HostRuntime, ProcessOutput, ProcessRequest, ProcessRunner,
};
use abird_host_manager::fleet::system::ResolvedHost;
use abird_host_manager::fleet::transport::{
    HostKeyPolicy, ProcessStatus, ProxyPlan, SshEndpoint, SshRoutePlan, TransportRole,
};
use base64::Engine as _;

#[derive(Default)]
struct FakeRunner {
    outputs: VecDeque<ProcessOutput>,
    requests: Vec<ProcessRequest>,
    waits: Vec<Duration>,
}

impl FakeRunner {
    fn samples(samples: impl IntoIterator<Item = String>) -> Self {
        Self {
            outputs: samples
                .into_iter()
                .map(|stdout| ProcessOutput {
                    status: ProcessStatus::Code(0),
                    stdout,
                    stderr: String::new(),
                    skipped: false,
                })
                .collect(),
            ..Self::default()
        }
    }
}

impl ProcessRunner for FakeRunner {
    fn run(&mut self, request: &ProcessRequest) -> io::Result<ProcessOutput> {
        self.requests.push(request.clone());
        Ok(self
            .outputs
            .pop_front()
            .expect("unexpected collector invocation"))
    }

    fn wait(&mut self, duration: Duration) {
        self.waits.push(duration);
    }
}

fn record(kind: &str, fields: &[&str]) -> String {
    let fields = fields
        .iter()
        .map(|field| base64::engine::general_purpose::STANDARD.encode(field))
        .collect::<Vec<_>>()
        .join("\t");
    format!("{kind}\t{fields}\n")
}

fn sample(records: &[String]) -> String {
    [
        record("hold-absent", &[]),
        record("status-absent", &[]),
        records.concat(),
    ]
    .concat()
}

fn target() -> HostExecutionTarget {
    let host = ResolvedHost {
        inventory_name: "inventory-node".into(),
        resource: "host:inventory-node".into(),
        target: "ssh-alias.example".into(),
        user: "root".into(),
        port: 22,
        identity_key: None,
        known_hosts: None,
        bootstrap_key: None,
        operator_user: None,
        operator_port: 22,
        operator_key: None,
        age_identity_key: None,
        proxy_jump: None,
        proxy_command: None,
    };
    let endpoint = SshEndpoint::new(
        &host.inventory_name,
        &host.target,
        &host.user,
        host.port,
        TransportRole::Primary,
        None,
    )
    .unwrap();
    HostExecutionTarget::from_resolved(
        &host,
        SshRoutePlan {
            endpoint,
            proxy: ProxyPlan::default(),
            proxy_command: None,
            host_key_policy: HostKeyPolicy::Strict,
        },
        Path::new("/repo"),
        None,
        false,
    )
    .unwrap()
}

#[test]
fn ignored_system_unit_does_not_mask_same_name_failed_user_unit() {
    let unit = "same-name.service";
    let system_failure = format!("{unit} loaded failed failed system failure");
    let user_failure = format!("{unit} loaded failed failed user failure");
    let observation = sample(&[
        record("system-failed", &[&system_failure]),
        record("user", &["app", "1000", "active", "ok", "ok"]),
        record("user-failed", &["app", &user_failure]),
    ]);
    let mut runtime = HostRuntime::new(
        FakeRunner::samples([observation]),
        PathBuf::from("/repo"),
        DryRun::No,
    )
    .unwrap();
    let report = check_managed_health_with_ignored_system_units(
        &mut runtime,
        &target(),
        &BTreeSet::from([unit.to_owned()]),
    )
    .unwrap();
    assert!(
        matches!(report.decision, HealthDecision::ServiceFailure { ref evidence }
        if evidence.contains(&HealthEvidence::ReportedFailure { scope: "app".into(), detail: user_failure.clone() }))
    );
    assert_eq!(report.ignored_system_failures, [system_failure]);
    assert_eq!(report.attempts, 1);
}

#[test]
fn multiple_ignored_system_units_remain_in_healthy_evidence_across_samples() {
    let first = "first.service loaded failed failed first failure";
    let second = "second.service loaded failed failed second failure";
    let settling = sample(&[
        record("system-failed", &[first]),
        record("user", &["app", "1000", "active", "ok", "ok"]),
        record("expected-unit", &["app", "app.service"]),
        record(
            "unit",
            &[
                "app",
                "expected",
                "app.service",
                "loaded",
                "activating",
                "start",
                "no",
                "30",
            ],
        ),
    ]);
    let healthy = sample(&[
        record("system-failed", &[second]),
        record("system-failed", &[second]),
        record("user", &["app", "1000", "active", "ok", "ok"]),
        record("expected-unit", &["app", "app.service"]),
        record(
            "unit",
            &[
                "app",
                "expected",
                "app.service",
                "loaded",
                "active",
                "running",
                "no",
                "30",
            ],
        ),
    ]);
    let mut runtime = HostRuntime::new(
        FakeRunner::samples([settling, healthy]),
        PathBuf::from("/repo"),
        DryRun::No,
    )
    .unwrap();
    let report = check_managed_health_with_ignored_system_units(
        &mut runtime,
        &target(),
        &BTreeSet::from(["first.service".into(), "second.service".into()]),
    )
    .unwrap();
    assert!(matches!(report.decision, HealthDecision::Healthy { .. }));
    assert_eq!(report.ignored_system_failures, [first, second]);
    assert_eq!(report.attempts, 2);
    assert_eq!(runtime.into_runner().waits, [Duration::from_secs(5)]);
}

#[test]
fn explicit_ignore_policy_survives_distinct_inventory_and_transport_names() {
    // Inventory policy resolution belongs to the fleet engine. This exercises
    // its explicit policy handoff through the public remote-health boundary.
    let failure = "ignored.service loaded failed failed ignored failure";
    let runner = FakeRunner::samples([sample(&[record("system-failed", &[failure])])]);
    let mut runtime = HostRuntime::new(runner, PathBuf::from("/repo"), DryRun::No).unwrap();
    let target = target();
    assert_ne!(target.route.endpoint.node, target.route.endpoint.host);
    let report = check_managed_health_with_ignored_system_units(
        &mut runtime,
        &target,
        &BTreeSet::from(["ignored.service".into()]),
    )
    .unwrap();
    assert!(matches!(report.decision, HealthDecision::Healthy { .. }));
    assert_eq!(report.ignored_system_failures, [failure]);
    let requests = runtime.into_runner().requests;
    assert_eq!(requests.len(), 1);
    assert!(
        requests[0]
            .args
            .iter()
            .any(|arg| arg == "root@ssh-alias.example")
    );
}
