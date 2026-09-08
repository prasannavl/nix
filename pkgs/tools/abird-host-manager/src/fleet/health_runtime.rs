use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use base64::Engine as _;

use super::build::CommandSpec;
use super::health::{
    AgentStatusResponse, BaselineTimerUnits, DurableHoldResponse, DurableUserHold, HealthDecision,
    HealthEvidence, PodmanContainer, PodmanHealth, ReadinessBudget, RootlessMutation, SystemdJob,
    UnitSnapshot, classify_expected_unit, classify_held_unit, classify_podman_runtime,
    classify_transitional_unit, derive_readiness_budget, validate_deferred_resources,
    validate_durable_holds,
};
use super::host_runtime::{EffectKind, HostExecutionTarget, HostRuntime, ProcessRunner};

const POLL_INTERVAL: Duration = Duration::from_secs(5);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ManagedHealthReport {
    pub decision: HealthDecision,
    pub details: Vec<String>,
    pub ignored_system_failures: Vec<String>,
    pub attempts: usize,
    pub readiness_budget: Option<ReadinessBudget>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct UserObservation {
    uid: Option<u32>,
    manager_active: bool,
    expected_query_ok: bool,
    runtime_query_ok: bool,
    expected_units: Vec<String>,
    runtime_lines: Vec<String>,
    jobs: Vec<SystemdJob>,
    expected: BTreeMap<String, (UnitSnapshot, Option<u64>)>,
    held: BTreeMap<String, UnitSnapshot>,
    failed: Vec<String>,
    transitional: Vec<(UnitSnapshot, Option<u64>)>,
    containers: Vec<PodmanContainer>,
    mutations: Vec<RootlessMutation>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct Observation {
    hold_absent: bool,
    hold_error: bool,
    hold_response: Option<DurableHoldResponse>,
    status_absent: bool,
    status_error: bool,
    status_response: Option<AgentStatusResponse>,
    system_failed: Vec<String>,
    system_transitional: Vec<(UnitSnapshot, bool)>,
    system_containers: Vec<PodmanContainer>,
    users: BTreeMap<String, UserObservation>,
    registry_timeouts: Vec<u64>,
}

pub fn managed_health_command() -> CommandSpec {
    CommandSpec::new(
        "/run/current-system/sw/bin/bash",
        ["-c".to_owned(), HEALTH_COLLECTOR.to_owned()],
    )
}

pub fn check_managed_health<R: ProcessRunner>(
    runtime: &mut HostRuntime<R>,
    target: &HostExecutionTarget,
) -> Result<ManagedHealthReport> {
    check_managed_health_with_ignored_system_units(runtime, target, &BTreeSet::new())
}

pub fn check_managed_health_with_ignored_system_units<R: ProcessRunner>(
    runtime: &mut HostRuntime<R>,
    target: &HostExecutionTarget,
    ignored_system_units: &BTreeSet<String>,
) -> Result<ManagedHealthReport> {
    let command = managed_health_command();
    let mut attempts = 0usize;
    let mut baseline = BaselineTimerUnits::default();
    let mut budget = None;
    let mut ignored_system_failures = BTreeSet::new();
    loop {
        attempts += 1;
        let output = runtime.execute_remote_command_bounded(
            target,
            &command,
            EffectKind::ReadOnly,
            "post-switch-health",
        )?;
        if !output.succeeded() {
            bail!(
                "managed health collector failed with {:?}: {}",
                output.status,
                output.combined_output().trim()
            );
        }
        let mut observation = parse_observation(&output.stdout)?;
        ignored_system_failures.extend(take_ignored_system_failures(
            &mut observation,
            ignored_system_units,
        ));
        if attempts == 1 {
            baseline = BaselineTimerUnits::from_names(
                observation
                    .system_transitional
                    .iter()
                    .filter(|(_, timer)| *timer)
                    .map(|(unit, _)| unit.name.as_str()),
            );
        }
        let mut report = classify_observation(&observation, &baseline)?;
        report.ignored_system_failures = ignored_system_failures.iter().cloned().collect();
        match report.decision {
            HealthDecision::Settling { .. } => {
                let resolved = derive_observation_budget(&observation)?;
                if budget.is_none() {
                    budget = resolved;
                }
                let Some(readiness) = &budget else {
                    return Ok(ManagedHealthReport {
                        decision: HealthDecision::ServiceFailure {
                            evidence: vec![HealthEvidence::ReportedFailure {
                                scope: "readiness".to_owned(),
                                detail: "deployment work is settling without timeoutReadySeconds metadata"
                                    .to_owned(),
                            }],
                        },
                        details: vec![
                            "deployment work is still settling, but no service-owned timeoutReadySeconds metadata was found"
                                .to_owned(),
                        ],
                        ignored_system_failures: report.ignored_system_failures,
                        attempts,
                        readiness_budget: None,
                    });
                };
                let maximum_attempts = readiness
                    .timeout_seconds
                    .div_ceil(POLL_INTERVAL.as_secs())
                    .saturating_add(1) as usize;
                if attempts >= maximum_attempts {
                    return Ok(ManagedHealthReport {
                        decision: HealthDecision::ServiceFailure {
                            evidence: vec![HealthEvidence::ReportedFailure {
                                scope: "readiness".to_owned(),
                                detail: format!(
                                    "deployment work still settling after {}s",
                                    readiness.timeout_seconds
                                ),
                            }],
                        },
                        details: report.details,
                        ignored_system_failures: report.ignored_system_failures,
                        attempts,
                        readiness_budget: budget,
                    });
                }
                runtime.wait(POLL_INTERVAL);
            }
            _ => {
                report.attempts = attempts;
                report.readiness_budget = budget;
                return Ok(report);
            }
        }
    }
}

fn take_ignored_system_failures(
    observation: &mut Observation,
    ignored_system_units: &BTreeSet<String>,
) -> Vec<String> {
    let mut ignored = Vec::new();
    observation.system_failed.retain(|failed| {
        let is_ignored = failed
            .split_whitespace()
            .next()
            .is_some_and(|unit| ignored_system_units.contains(unit));
        if is_ignored {
            ignored.push(failed.clone());
        }
        !is_ignored
    });
    ignored
}

fn derive_observation_budget(observation: &Observation) -> Result<Option<ReadinessBudget>> {
    let observed = observation
        .users
        .values()
        .flat_map(|user| {
            user.expected
                .values()
                .filter_map(|(_, timeout)| *timeout)
                .chain(user.transitional.iter().filter_map(|(_, timeout)| *timeout))
        })
        .collect::<Vec<_>>();
    derive_readiness_budget(&observed, &observation.registry_timeouts)
        .map_err(|error| anyhow::anyhow!(error))
}

fn classify_observation(
    observation: &Observation,
    baseline: &BaselineTimerUnits,
) -> Result<ManagedHealthReport> {
    let mut decision = HealthDecision::healthy();
    let mut details = Vec::new();
    let deployment_work = observation_has_settling(observation, baseline);
    if observation.hold_error {
        decision = decision.merge(service_failure("host-agent holds", "query failed"));
        details.push("durable host-agent hold state is unavailable".to_owned());
    }
    if !observation.hold_absent {
        match validate_durable_holds(observation.hold_response.as_ref()) {
            Ok(_) => {}
            Err(error) => {
                decision = decision.merge(service_failure("host-agent holds", &error.to_string()));
                details.push(error.to_string());
            }
        }
    }
    if observation.status_error {
        decision = decision.merge(structural_failure("deferred resources", "query failed"));
        details.push("deferred resource isolation is unavailable".to_owned());
    }
    if !observation.status_absent {
        match validate_deferred_resources(observation.status_response.as_ref()) {
            Ok(resources) => details.extend(resources.into_iter().map(|resource| {
                format!(
                    "resource={} outcome=deferred-held reason={} generation={}",
                    resource.resource, resource.reason, resource.generation
                )
            })),
            Err(error) => {
                decision =
                    decision.merge(structural_failure("deferred resources", &error.to_string()));
                details.push(error.to_string());
            }
        }
    }

    for failed in &observation.system_failed {
        decision = decision.merge(service_failure("system unit", failed));
        details.push(format!("failed system unit: {failed}"));
    }
    for (unit, _) in &observation.system_transitional {
        decision = decision.merge(classify_transitional_unit(unit, baseline));
        if !baseline.as_set().contains(&unit.name) {
            details.push(format!("system unit still settling: {}", unit.name));
        }
    }
    decision = decision.merge(classify_podman_runtime(
        &observation.system_containers,
        &[],
        deployment_work,
    ));

    let holds = if observation.hold_absent || observation.hold_error {
        Vec::new()
    } else {
        validate_durable_holds(observation.hold_response.as_ref()).unwrap_or_default()
    };
    let held_by_user = holds_by_user(&holds);
    for (name, user) in &observation.users {
        let held = held_by_user.get(name).cloned().unwrap_or_default();
        if user.uid.is_none() {
            if !held.is_empty() {
                decision = decision.merge(structural_failure(name, "held account is missing"));
                details.push(format!("user={name} hold=active account=missing"));
            }
            continue;
        }
        if !user.expected_query_ok {
            decision = decision.merge(structural_failure(name, "declaration query failed"));
            details.push(format!("user={name} declaration-query=failed"));
            continue;
        }
        if !user.manager_active && (!user.expected_units.is_empty() || !held.is_empty()) {
            decision = decision.merge(structural_failure(name, "user manager is inactive"));
            details.push(format!("user={name} user-manager=inactive"));
            continue;
        }
        if !user.runtime_query_ok {
            decision = decision.merge(if deployment_work {
                HealthDecision::Settling {
                    evidence: vec![HealthEvidence::DeploymentWorkSettling],
                }
            } else {
                service_failure(name, "expected runtime query failed")
            });
            details.push(format!("user={name} expected-runtime=query-failed"));
        }
        for line in &user.runtime_lines {
            if line.starts_with("starting ") {
                decision = decision.merge(HealthDecision::Settling {
                    evidence: vec![HealthEvidence::DeploymentWorkSettling],
                });
                details.push(format!("user={name} {line}"));
            } else {
                decision = decision.merge(if deployment_work {
                    HealthDecision::Settling {
                        evidence: vec![HealthEvidence::DeploymentWorkSettling],
                    }
                } else {
                    service_failure(name, line)
                });
                details.push(format!("user={name} {line}"));
            }
        }
        for unit in &held {
            match user.held.get(unit) {
                Some(snapshot) => decision = decision.merge(classify_held_unit(snapshot)),
                None => {
                    decision = decision.merge(structural_failure(
                        name,
                        &format!("held unit {unit} has no state"),
                    ));
                }
            }
        }
        for unit in &user.expected_units {
            match user.expected.get(unit) {
                Some((snapshot, _)) => {
                    decision = decision.merge(classify_expected_unit(snapshot, &user.jobs));
                }
                None => {
                    decision = decision.merge(structural_failure(
                        name,
                        &format!("expected unit {unit} has no state"),
                    ));
                }
            }
        }
        for failed in &user.failed {
            decision = decision.merge(service_failure(name, failed));
            details.push(format!("user={name} failed-unit={failed}"));
        }
        for (unit, _) in &user.transitional {
            decision = decision.merge(classify_transitional_unit(
                unit,
                &BaselineTimerUnits::default(),
            ));
            details.push(format!("user={name} unit={} settling", unit.name));
        }
        decision = decision.merge(classify_podman_runtime(
            &user.containers,
            &user.mutations,
            deployment_work,
        ));
    }

    Ok(ManagedHealthReport {
        decision,
        details,
        ignored_system_failures: Vec::new(),
        attempts: 1,
        readiness_budget: derive_observation_budget(observation)?,
    })
}

fn observation_has_settling(observation: &Observation, baseline: &BaselineTimerUnits) -> bool {
    observation
        .system_transitional
        .iter()
        .any(|(unit, _)| !baseline.as_set().contains(&unit.name))
        || observation
            .system_containers
            .iter()
            .any(|container| container.health == PodmanHealth::Starting)
        || observation.users.values().any(|user| {
            user.runtime_lines
                .iter()
                .any(|line| line.starts_with("starting "))
                || !user.transitional.is_empty()
                || user.mutations.iter().any(|mutation| mutation.live)
                || user
                    .containers
                    .iter()
                    .any(|container| container.health == PodmanHealth::Starting)
                || user.expected.values().any(|(unit, _)| {
                    matches!(
                        unit.active_state.as_str(),
                        "activating" | "deactivating" | "reloading"
                    ) || user.jobs.iter().any(|job| {
                        job.unit == unit.name
                            && matches!(
                                job.kind.as_str(),
                                "start" | "restart" | "try-restart" | "reload-or-start"
                            )
                            && matches!(job.state.as_str(), "waiting" | "running")
                    })
                })
                || user
                    .held
                    .values()
                    .any(|unit| unit.active_state == "deactivating")
        })
}

fn holds_by_user(holds: &[DurableUserHold]) -> BTreeMap<String, BTreeSet<String>> {
    let mut grouped = BTreeMap::<String, BTreeSet<String>>::new();
    for hold in holds {
        grouped
            .entry(hold.user.clone())
            .or_default()
            .insert(hold.unit.clone());
    }
    grouped
}

fn service_failure(scope: &str, detail: &str) -> HealthDecision {
    HealthDecision::ServiceFailure {
        evidence: vec![HealthEvidence::ReportedFailure {
            scope: scope.to_owned(),
            detail: detail.to_owned(),
        }],
    }
}

fn structural_failure(scope: &str, detail: &str) -> HealthDecision {
    HealthDecision::StructuralFailure {
        evidence: vec![HealthEvidence::StructuralIssue {
            scope: scope.to_owned(),
            detail: detail.to_owned(),
        }],
    }
}

fn parse_observation(value: &str) -> Result<Observation> {
    let mut observation = Observation::default();
    for (line_number, line) in value.lines().enumerate() {
        if line.is_empty() {
            continue;
        }
        let mut fields = line.split('\t');
        let kind = fields.next().context("health record has no kind")?;
        let fields = fields
            .map(decode_field)
            .collect::<Result<Vec<_>>>()
            .with_context(|| format!("decode health record on line {}", line_number + 1))?;
        parse_record(&mut observation, kind, &fields)
            .with_context(|| format!("parse health record on line {}", line_number + 1))?;
    }
    Ok(observation)
}

fn decode_field(value: &str) -> Result<String> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(value)
        .context("decode base64 health field")?;
    String::from_utf8(bytes).context("health field is not UTF-8")
}

fn parse_record(observation: &mut Observation, kind: &str, fields: &[String]) -> Result<()> {
    let field = |index: usize| {
        fields
            .get(index)
            .map(String::as_str)
            .with_context(|| format!("{kind} record is missing field {index}"))
    };
    match kind {
        "hold-absent" => observation.hold_absent = true,
        "hold-error" => observation.hold_error = true,
        "hold-response" => observation.hold_response = Some(serde_json::from_str(field(0)?)?),
        "status-absent" => observation.status_absent = true,
        "status-error" => observation.status_error = true,
        "status-response" => observation.status_response = Some(serde_json::from_str(field(0)?)?),
        "system-failed" => observation.system_failed.push(field(0)?.to_owned()),
        "system-transition" => observation.system_transitional.push((
            transition_snapshot(field(0)?, field(1)?),
            field(2)? == "timer",
        )),
        "container" => {
            let container = parse_container(field(2)?, field(3)?, field(4)?)?;
            if field(0)? == "system" {
                observation.system_containers.push(container);
            } else {
                observation
                    .users
                    .entry(field(1)?.to_owned())
                    .or_default()
                    .containers
                    .push(container);
            }
        }
        "user" => {
            let user = observation.users.entry(field(0)?.to_owned()).or_default();
            user.uid = (!field(1)?.is_empty())
                .then(|| field(1)?.parse::<u32>().context("invalid managed uid"))
                .transpose()?;
            user.manager_active = field(2)? == "active";
            user.expected_query_ok = field(3)? == "ok";
            user.runtime_query_ok = field(4)? == "ok";
        }
        "expected-unit" => observation
            .users
            .entry(field(0)?.to_owned())
            .or_default()
            .expected_units
            .push(field(1)?.to_owned()),
        "runtime" => observation
            .users
            .entry(field(0)?.to_owned())
            .or_default()
            .runtime_lines
            .push(field(1)?.to_owned()),
        "job" => observation
            .users
            .entry(field(0)?.to_owned())
            .or_default()
            .jobs
            .push(SystemdJob {
                id: field(1)?.parse()?,
                unit: field(2)?.to_owned(),
                kind: field(3)?.to_owned(),
                state: field(4)?.to_owned(),
            }),
        "unit" => {
            let user = observation.users.entry(field(0)?.to_owned()).or_default();
            let snapshot = UnitSnapshot {
                name: field(2)?.to_owned(),
                load_state: field(3)?.to_owned(),
                active_state: field(4)?.to_owned(),
                sub_state: field(5)?.to_owned(),
                needs_daemon_reload: field(6)? == "yes",
            };
            if field(1)? == "expected" {
                let timeout = (!field(7)?.is_empty())
                    .then(|| {
                        field(7)?
                            .parse::<u64>()
                            .context("invalid unit readiness timeout")
                    })
                    .transpose()?;
                user.expected
                    .insert(snapshot.name.clone(), (snapshot, timeout));
            } else if field(1)? == "held" {
                user.held.insert(snapshot.name.clone(), snapshot);
            } else {
                bail!("invalid unit role: {}", field(1)?);
            }
        }
        "user-failed" => observation
            .users
            .entry(field(0)?.to_owned())
            .or_default()
            .failed
            .push(field(1)?.to_owned()),
        "user-transition" => observation
            .users
            .entry(field(0)?.to_owned())
            .or_default()
            .transitional
            .push((
                transition_snapshot(field(1)?, field(2)?),
                (!field(3)?.is_empty())
                    .then(|| {
                        field(3)?
                            .parse::<u64>()
                            .context("invalid transitional readiness timeout")
                    })
                    .transpose()?,
            )),
        "mutation" => observation
            .users
            .entry(field(0)?.to_owned())
            .or_default()
            .mutations
            .push(RootlessMutation {
                service: field(1)?.to_owned(),
                pid: field(2)?.parse()?,
                reason: field(3)?.to_owned(),
                started_at: field(4)?.to_owned(),
                live: true,
            }),
        "timeout" => observation.registry_timeouts.push(field(0)?.parse()?),
        _ => bail!("unknown health record kind: {kind}"),
    }
    Ok(())
}

fn transition_snapshot(name: &str, state: &str) -> UnitSnapshot {
    let (active, sub) = state.split_once('/').unwrap_or((state, "unknown"));
    UnitSnapshot {
        name: name.to_owned(),
        load_state: "loaded".to_owned(),
        active_state: active.to_owned(),
        sub_state: sub.to_owned(),
        needs_daemon_reload: false,
    }
}

fn parse_container(health: &str, name: &str, status: &str) -> Result<PodmanContainer> {
    let health = match health {
        "healthy" => PodmanHealth::Healthy,
        "starting" => PodmanHealth::Starting,
        "unhealthy" => PodmanHealth::Unhealthy,
        _ => bail!("invalid Podman health state: {health}"),
    };
    Ok(PodmanContainer {
        name: name.to_owned(),
        health,
        status: status.to_owned(),
    })
}

const HEALTH_COLLECTOR: &str = r#"set -Eeuo pipefail
base64_bin=/run/current-system/sw/bin/base64
agent=/run/current-system/sw/bin/abird-host-agent
control=/run/current-system/sw/bin/podman-composectl
registry=/run/current-system/share/podman-compose/control-registry.json
emit() {
    local kind="$1" value encoded
    shift
    printf '%s' "$kind"
    for value in "$@"; do
        encoded="$(printf '%s' "$value" | "$base64_bin" -w0)"
        printf '\t%s' "$encoded"
    done
    printf '\n'
}
healthcheck_unit() {
    case "$1" in
        *'[systemd-run]'*podman*'healthcheck run '*|*'.podman-wrapped healthcheck run '*) return 0 ;;
        *) return 1 ;;
    esac
}
hold_json= status_json= held_tsv=
if [ ! -x "$agent" ]; then
    emit hold-absent
    emit status-absent
else
    if hold_json="$($agent --json hold list 2>/dev/null)"; then
        emit hold-response "$hold_json"
        held_tsv="$(printf '%s' "$hold_json" | jq -r '.result.holds[]?.services[]? | select(.scope == "user") | [.user,.unit] | @tsv' 2>/dev/null || true)"
    else
        emit hold-error
    fi
    if status_json="$($agent --json status 2>/dev/null)"; then
        emit status-response "$status_json"
    else
        emit status-error
    fi
fi
while IFS= read -r line; do
    [ -n "$line" ] || continue
    healthcheck_unit "$line" || emit system-failed "$line"
done < <(systemctl list-units --failed --no-legend --plain 2>/dev/null || true)
while IFS= read -r line; do
    [ -n "$line" ] || continue
    healthcheck_unit "$line" && continue
    unit="${line%% *}"
    active="$(systemctl show "$unit" --property=ActiveState --value 2>/dev/null || true)"
    sub="$(systemctl show "$unit" --property=SubState --value 2>/dev/null || true)"
    triggered="$(systemctl show "$unit" --property=TriggeredBy --value 2>/dev/null || true)"
    timer=none
    if printf '%s\n' "$triggered" | grep -Eq '(^|[[:space:]])[^[:space:]]+\.timer($|[[:space:]])'; then timer=timer; fi
    emit system-transition "$unit" "${active:-unknown}/${sub:-unknown}" "$timer"
done < <(systemctl list-units --state=activating,deactivating,reloading --type=service --no-legend --plain 2>/dev/null || true)
for health in unhealthy starting; do
    while IFS=$'\t' read -r name status; do
        [ -n "$name" ] || continue
        emit container system '' "$health" "$name" "$status"
    done < <(cd /; podman ps --filter "health=$health" --format '{{.Names}}\t{{.Status}}' 2>/dev/null || true)
done
users="$({
    for file in /etc/systemd/user/*-managed.target; do
        [ -e "$file" ] || continue
        awk -F= '$1 == "ConditionUser" { print $2; exit }' "$file" 2>/dev/null || true
    done
    printf '%s\n' "$held_tsv" | cut -f1
} | sed '/^$/d;/^!/d;/@/d' | sort -u)"
while IFS= read -r user; do
    [ -n "$user" ] || continue
    held_units="$(printf '%s\n' "$held_tsv" | awk -F '\t' -v user="$user" '$1 == user {print $2}')"
    uid="$(id -u "$user" 2>/dev/null || true)"
    if [ -z "$uid" ]; then
        emit user "$user" '' inactive skipped skipped
        continue
    fi
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
    runtime_dir="/run/user/$uid"
    bus="unix:path=$runtime_dir/bus"
    manager=inactive
    systemctl is-active --quiet "user@$uid.service" 2>/dev/null && manager=active
    expected_status=ok
    runtime_status=ok
    expected_units=
    runtime_output=
    args=(expected-units "$user")
    while IFS= read -r unit; do [ -z "$unit" ] || args+=(--exclude-unit "$unit"); done <<<"$held_units"
    if [ ! -x "$control" ] || ! expected_units="$($control "${args[@]}" 2>/dev/null)"; then expected_status=error; fi
    args=(expected-runtime "$user")
    while IFS= read -r unit; do [ -z "$unit" ] || args+=(--exclude-unit "$unit"); done <<<"$held_units"
    if [ "$manager" = active ]; then
        if [ ! -x "$control" ] || ! runtime_output="$($control "${args[@]}" 2>/dev/null)"; then runtime_status=error; fi
    else
        runtime_status=skipped
    fi
    emit user "$user" "$uid" "$manager" "$expected_status" "$runtime_status"
    while IFS= read -r unit; do [ -z "$unit" ] || emit expected-unit "$user" "$unit"; done <<<"$expected_units"
    while IFS= read -r line; do [ -z "$line" ] || emit runtime "$user" "$line"; done <<<"$runtime_output"
    [ "$manager" = active ] || continue
    while read -r id unit kind state _; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        emit job "$user" "$id" "$unit" "$kind" "$state"
    done < <(setpriv --reuid="$user" --regid="$(id -g "$user")" --init-groups env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$bus" systemctl --user list-jobs --no-legend --plain 2>/dev/null || true)
    for role in held expected; do
        if [ "$role" = held ]; then unit_list="$held_units"; else unit_list="$expected_units"; fi
        while IFS= read -r unit; do
            [ -n "$unit" ] || continue
            state="$(setpriv --reuid="$user" --regid="$(id -g "$user")" --init-groups env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$bus" systemctl --user show --property=LoadState,ActiveState,SubState,NeedDaemonReload "$unit" 2>/dev/null || true)"
            load="$(printf '%s\n' "$state" | sed -n 's/^LoadState=//p')"
            active="$(printf '%s\n' "$state" | sed -n 's/^ActiveState=//p')"
            sub="$(printf '%s\n' "$state" | sed -n 's/^SubState=//p')"
            reload="$(printf '%s\n' "$state" | sed -n 's/^NeedDaemonReload=//p')"
            timeout=
            if [ "$role" = expected ]; then
                timeout="$(setpriv --reuid="$user" --regid="$(id -g "$user")" --init-groups env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$bus" systemctl --user show --property=Environment --value "$unit" 2>/dev/null | grep -Eo 'NIXBOT_TIMEOUT_READY_SECONDS=[0-9]+' | sed -n '1s/^[^=]*=//p' || true)"
            fi
            emit unit "$user" "$role" "$unit" "${load:-unknown}" "${active:-unknown}" "${sub:-unknown}" "${reload:-unknown}" "$timeout"
        done <<<"$unit_list"
    done
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        healthcheck_unit "$line" || emit user-failed "$user" "$line"
    done < <(setpriv --reuid="$user" --regid="$(id -g "$user")" --init-groups env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$bus" systemctl --user list-units --failed --no-legend --plain 2>/dev/null || true)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        healthcheck_unit "$line" && continue
        unit="${line%% *}"
        active="$(setpriv --reuid="$user" --regid="$(id -g "$user")" --init-groups env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$bus" systemctl --user show "$unit" --property=ActiveState --value 2>/dev/null || true)"
        sub="$(setpriv --reuid="$user" --regid="$(id -g "$user")" --init-groups env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$bus" systemctl --user show "$unit" --property=SubState --value 2>/dev/null || true)"
        timeout="$(setpriv --reuid="$user" --regid="$(id -g "$user")" --init-groups env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$bus" systemctl --user show --property=Environment --value "$unit" 2>/dev/null | grep -Eo 'NIXBOT_TIMEOUT_READY_SECONDS=[0-9]+' | sed -n '1s/^[^=]*=//p' || true)"
        emit user-transition "$user" "$unit" "${active:-unknown}/${sub:-unknown}" "$timeout"
    done < <(setpriv --reuid="$user" --regid="$(id -g "$user")" --init-groups env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$bus" systemctl --user list-units --state=activating,deactivating,reloading --type=service,target --no-legend --plain 2>/dev/null || true)
    for marker in "$runtime_dir"/podman-compose/rootless-mutations/*; do
        [ -f "$marker" ] || continue
        pid="$(sed -n 's/^pid=//p' "$marker" | head -1)"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -0 "$pid" 2>/dev/null || continue
        service="$(sed -n 's/^service=//p' "$marker" | head -1)"
        reason="$(sed -n 's/^reason=//p' "$marker" | head -1)"
        started="$(sed -n 's/^startedAt=//p' "$marker" | head -1)"
        emit mutation "$user" "${service:-${marker##*/}}" "$pid" "${reason:-unknown}" "${started:-unknown}"
    done
    for health in unhealthy starting; do
        while IFS=$'\t' read -r name status; do
            [ -n "$name" ] || continue
            emit container user "$user" "$health" "$name" "$status"
        done < <(cd /; setpriv --reuid="$user" --regid="$(id -g "$user")" --init-groups env HOME="${home:-/}" XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$bus" podman ps --filter "health=$health" --format '{{.Names}}\t{{.Status}}' 2>/dev/null || true)
    done
done <<<"$users"
if [ -r "$registry" ]; then
    { grep -Eo '"timeoutReadySeconds":[[:space:]]*[0-9]+' "$registry" || true; } | sed -E 's/.*:[[:space:]]*//' | while IFS= read -r timeout; do emit timeout "$timeout"; done
fi
"#;

#[cfg(test)]
mod tests {
    use std::io::Write as _;
    use std::process::{Command, Stdio};

    use super::*;

    fn encoded(kind: &str, fields: &[&str]) -> String {
        let fields = fields
            .iter()
            .map(|field| base64::engine::general_purpose::STANDARD.encode(field))
            .collect::<Vec<_>>()
            .join("\t");
        format!("{kind}\t{fields}\n")
    }

    #[test]
    fn parser_and_classifier_cover_managed_user_success() {
        let mut input = String::new();
        input.push_str(&encoded("hold-absent", &[]));
        input.push_str(&encoded("status-absent", &[]));
        input.push_str(&encoded("user", &["app", "1000", "active", "ok", "ok"]));
        input.push_str(&encoded("expected-unit", &["app", "app.service"]));
        input.push_str(&encoded(
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
        ));
        let observation = parse_observation(&input).unwrap();
        let report = classify_observation(&observation, &BaselineTimerUnits::default()).unwrap();
        assert!(matches!(report.decision, HealthDecision::Healthy { .. }));
        assert_eq!(report.readiness_budget.unwrap().timeout_seconds, 30);
    }

    #[test]
    fn collector_is_valid_bash_and_keeps_classification_out_of_shell() {
        let mut child = Command::new("bash")
            .arg("-n")
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(HEALTH_COLLECTOR.as_bytes())
            .unwrap();
        assert!(child.wait().unwrap().success());
        assert!(!HEALTH_COLLECTOR.contains("return 3"));
        assert!(!HEALTH_COLLECTOR.contains("FAILED —"));
    }

    #[test]
    fn inactive_expected_unit_with_start_job_is_settling() {
        let mut input = String::new();
        input.push_str(&encoded("hold-absent", &[]));
        input.push_str(&encoded("status-absent", &[]));
        input.push_str(&encoded("user", &["app", "1000", "active", "ok", "ok"]));
        input.push_str(&encoded("expected-unit", &["app", "app.service"]));
        input.push_str(&encoded(
            "job",
            &["app", "7", "app.service", "start", "waiting"],
        ));
        input.push_str(&encoded(
            "unit",
            &[
                "app",
                "expected",
                "app.service",
                "loaded",
                "inactive",
                "dead",
                "no",
                "60",
            ],
        ));
        let report = classify_observation(
            &parse_observation(&input).unwrap(),
            &BaselineTimerUnits::default(),
        )
        .unwrap();
        assert!(matches!(report.decision, HealthDecision::Settling { .. }));
    }

    #[test]
    fn unsafe_deferred_resource_is_structural_failure() {
        let mut input = String::new();
        input.push_str(&encoded("hold-absent", &[]));
        input.push_str(&encoded(
            "status-response",
            &[r#"{"ok":true,"operation":"agent_status","result":{"status_schema_version":2,"deferred_resources":{"count":1,"resources":[{"resource":"db","reason":"held","generation":4,"isolated":false}]}}}"#],
        ));
        let report = classify_observation(
            &parse_observation(&input).unwrap(),
            &BaselineTimerUnits::default(),
        )
        .unwrap();
        assert!(matches!(
            report.decision,
            HealthDecision::StructuralFailure { .. }
        ));
    }

    #[test]
    fn system_failure_ignore_matches_exact_unit_names() {
        let ignored = "systemd-backlight@backlight:nvidia_wmi_ec_backlight.service";
        let similar = "systemd-backlight@backlight:nvidia_wmi_ec_backlight-similar.service";
        let mut input = String::new();
        input.push_str(&encoded("hold-absent", &[]));
        input.push_str(&encoded("status-absent", &[]));
        input.push_str(&encoded(
            "system-failed",
            &[&format!("{ignored} loaded failed failed ignored")],
        ));
        input.push_str(&encoded(
            "system-failed",
            &[&format!("{similar} loaded failed failed retained")],
        ));
        let mut observation = parse_observation(&input).unwrap();
        let ignored_failures =
            take_ignored_system_failures(&mut observation, &BTreeSet::from([ignored.to_owned()]));

        assert_eq!(
            observation.system_failed,
            [format!("{similar} loaded failed failed retained")]
        );
        assert_eq!(
            ignored_failures,
            [format!("{ignored} loaded failed failed ignored")]
        );
        let report = classify_observation(&observation, &BaselineTimerUnits::default()).unwrap();
        assert!(matches!(
            report.decision,
            HealthDecision::ServiceFailure { .. }
        ));
    }

    #[test]
    fn unhealthy_container_is_only_settling_with_active_deployment_work() {
        let base = [
            encoded("hold-absent", &[]),
            encoded("status-absent", &[]),
            encoded("user", &["app", "1000", "active", "ok", "ok"]),
            encoded(
                "container",
                &["user", "app", "unhealthy", "web", "unhealthy"],
            ),
        ]
        .concat();
        let report = classify_observation(
            &parse_observation(&base).unwrap(),
            &BaselineTimerUnits::default(),
        )
        .unwrap();
        assert!(matches!(
            report.decision,
            HealthDecision::ServiceFailure { .. }
        ));

        let settling = format!(
            "{base}{}",
            encoded("mutation", &["app", "web", "42", "reload", "now"])
        );
        let report = classify_observation(
            &parse_observation(&settling).unwrap(),
            &BaselineTimerUnits::default(),
        )
        .unwrap();
        assert!(matches!(report.decision, HealthDecision::Settling { .. }));
    }
}
