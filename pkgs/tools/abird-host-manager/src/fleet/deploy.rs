// Pure deployment command and verification contracts.
//
// This module does not open SSH connections, mutate profiles, sleep, or invoke
// systemd. It validates values at those boundaries and returns the commands and
// state transitions that a runtime adapter must execute.

use std::time::Duration;

use anyhow::{Result, bail};
use sha2::{Digest, Sha256};

const CURRENT_SYSTEM: &str = "/run/current-system";
const SYSTEM_PROFILE: &str = "/nix/var/nix/profiles/system";
const SYSTEM_BASH: &str = "/run/current-system/sw/bin/bash";
const SYSTEM_CAT: &str = "/run/current-system/sw/bin/cat";
const SYSTEM_FLOCK: &str = "/run/current-system/sw/bin/flock";
const SYSTEM_INSTALL: &str = "/run/current-system/sw/bin/install";
const SYSTEM_MV: &str = "/run/current-system/sw/bin/mv";
const SYSTEM_READLINK: &str = "/run/current-system/sw/bin/readlink";
const SYSTEM_SLEEP: &str = "/run/current-system/sw/bin/sleep";
const SYSTEM_SYSTEMCTL: &str = "/run/current-system/sw/bin/systemctl";
const SYSTEM_TEE: &str = "/run/current-system/sw/bin/tee";
const ACTIVATION_RESULT_DIR: &str = "/var/lib/nixbot/activation-results";
const ACTIVATION_LOCK: &str = "/run/nixos/switch-to-configuration.lock";
const HOST_LOCAL_ACTIVATION_LOCK: &str = "/dev/shm/nixbot-host-local.lock.d";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandSpec {
    pub program: String,
    pub args: Vec<String>,
}

impl CommandSpec {
    pub fn new(program: impl Into<String>, args: impl IntoIterator<Item = String>) -> Self {
        Self {
            program: program.into(),
            args: args.into_iter().collect(),
        }
    }
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct SystemGeneration(String);

impl SystemGeneration {
    pub fn parse(value: &str) -> Result<Self> {
        if value.is_empty() || value.contains(char::is_whitespace) {
            bail!("NixOS generation must be one non-empty path");
        }
        let Some(name) = value.strip_prefix("/nix/store/") else {
            bail!("NixOS generation is not a store path: {value}");
        };
        if name.contains('/') {
            bail!("NixOS generation has a nested store path: {value}");
        }
        let Some((store_name, system_name)) = name.split_once("-nixos-system-") else {
            bail!("store path is not a NixOS system generation: {value}");
        };
        if store_name.is_empty() || system_name.is_empty() {
            bail!("store path is not a complete NixOS system generation: {value}");
        }
        Ok(Self(value.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum GenerationSnapshot {
    NotRequested,
    Captured(SystemGeneration),
    Missing,
}

impl GenerationSnapshot {
    /// Extract exactly one NixOS system path while tolerating diagnostic lines.
    pub fn parse(output: &str) -> Result<Self> {
        let generations = output
            .lines()
            .filter_map(|line| SystemGeneration::parse(line).ok())
            .collect::<Vec<_>>();
        match generations.as_slice() {
            [generation] => Ok(Self::Captured(generation.clone())),
            [] => bail!("snapshot output contains no NixOS system generation"),
            _ => bail!("snapshot output contains multiple NixOS system generations"),
        }
    }

    pub fn captured(generation: SystemGeneration) -> Self {
        Self::Captured(generation)
    }

    pub fn missing() -> Self {
        Self::Missing
    }

    pub fn not_requested() -> Self {
        Self::NotRequested
    }

    pub fn generation(&self) -> Option<&SystemGeneration> {
        match self {
            Self::Captured(generation) => Some(generation),
            Self::NotRequested | Self::Missing => None,
        }
    }

    pub fn deploy_decision(
        &self,
        requirement: SnapshotRequirement,
        desired: &SystemGeneration,
        if_changed: bool,
    ) -> DeployDecision {
        match self {
            Self::NotRequested => DeployDecision::Deploy {
                rollback_generation: None,
            },
            Self::Captured(generation) if if_changed && generation == desired => {
                DeployDecision::SkipUnchanged
            }
            Self::Captured(generation) => DeployDecision::Deploy {
                rollback_generation: Some(generation.clone()),
            },
            Self::Missing if requirement == SnapshotRequirement::Optional => {
                DeployDecision::SkipOptionalMissing
            }
            Self::Missing => DeployDecision::RefuseRequiredMissing,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SnapshotRequirement {
    Required,
    Optional,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DeployDecision {
    Deploy {
        rollback_generation: Option<SystemGeneration>,
    },
    SkipUnchanged,
    SkipOptionalMissing,
    RefuseRequiredMissing,
}

pub fn snapshot_command() -> CommandSpec {
    CommandSpec::new("readlink", ["-f".to_owned(), CURRENT_SYSTEM.to_owned()])
}

const DEFAULT_PARENT_RECONCILE: &str =
    "/run/current-system/sw/bin/incus-machines-reconciler{resourceArgs}";
const DEFAULT_PARENT_SETTLE: &str =
    "/run/current-system/sw/bin/incus-machines-settlement --timeout {timeout}{resourceArgs}";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ParentReadinessCommands {
    pub reconcile: CommandSpec,
    pub settle: CommandSpec,
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn render_parent_template(template: &str, resource: &str, timeout: Duration) -> Result<String> {
    if template.is_empty() {
        bail!("parent readiness template cannot be empty");
    }
    let resource = shell_quote(resource);
    let resource_args = format!(" --machine {resource}");
    let rendered = template
        .replace("{resourceArgs}", &resource_args)
        .replace("{resource}", &resource)
        .replace("{timeout}", &timeout.as_secs().to_string());
    if rendered.contains("{resource") || rendered.contains("{timeout}") {
        bail!("parent readiness template contains an unresolved placeholder");
    }
    Ok(rendered)
}

pub fn parent_readiness_commands(
    resource: &str,
    reconcile_template: Option<&str>,
    settle_template: Option<&str>,
    timeout: Duration,
) -> Result<ParentReadinessCommands> {
    if resource.is_empty() {
        bail!("parent resource cannot be empty");
    }
    let command = |template: &str| -> Result<CommandSpec> {
        Ok(CommandSpec::new(
            SYSTEM_BASH,
            [
                "-c".to_owned(),
                render_parent_template(template, resource, timeout)?,
            ],
        ))
    };
    Ok(ParentReadinessCommands {
        reconcile: command(reconcile_template.unwrap_or(DEFAULT_PARENT_RECONCILE))?,
        settle: command(settle_template.unwrap_or(DEFAULT_PARENT_SETTLE))?,
    })
}

pub fn pre_activation_image_pull_command(generation: &SystemGeneration) -> CommandSpec {
    const SCRIPT: &str = r#"set -Eeuo pipefail
system_path="$1"
plan="${system_path}/share/podman-compose/image-pulls.json"
runner="${system_path}/sw/bin/podman-compose-image-pull-all"
if { [ ! -e "$plan" ] && [ ! -x "$runner" ]; } || [ ! -s "$plan" ]; then
    exit 0
fi
if [ ! -x "$runner" ]; then
    echo "podman compose image-pull plan exists but runner is missing: $runner" >&2
    exit 1
fi
echo "[pre-activation] pulling declared Podman Compose images from $plan" >&2
NIX_PODMAN_COMPOSE_IMAGE_PULL_PLAN="$plan" "$runner"
"#;
    CommandSpec::new(
        SYSTEM_BASH,
        [
            "-c".to_owned(),
            SCRIPT.to_owned(),
            "nixbot-pre-activation-image-pull".to_owned(),
            generation.as_str().to_owned(),
        ],
    )
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ActivationGoal {
    Switch,
    Boot,
    Test,
    DryActivate,
}

impl ActivationGoal {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Switch => "switch",
            Self::Boot => "boot",
            Self::Test => "test",
            Self::DryActivate => "dry-activate",
        }
    }

    pub fn persists_profile(self) -> bool {
        matches!(self, Self::Switch | Self::Boot)
    }

    pub fn post_promote_bootloader_goal(self, environment: BootEnvironment) -> Option<Self> {
        (self.persists_profile() && environment == BootEnvironment::Physical).then_some(Self::Boot)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BootEnvironment {
    Container,
    Physical,
}

impl BootEnvironment {
    pub fn parse_nix_json(output: &str) -> Result<Self> {
        match output.trim() {
            "true" => Ok(Self::Container),
            "false" => Ok(Self::Physical),
            value => bail!("unexpected boot.isContainer value: {value}"),
        }
    }
}

pub fn boot_is_container_command(
    nix: &str,
    nix_args: &[String],
    configuration: &str,
) -> CommandSpec {
    let mut args = vec!["eval".to_owned()];
    args.extend_from_slice(nix_args);
    args.extend([
        "--option".to_owned(),
        "warn-dirty".to_owned(),
        "false".to_owned(),
        "--json".to_owned(),
        "--no-write-lock-file".to_owned(),
        format!(".#nixosConfigurations.{configuration}.config.boot.isContainer"),
    ]);
    CommandSpec::new(nix, args)
}

fn sanitized_run_id(runtime_work_dir: &str) -> String {
    let basename = runtime_work_dir
        .rsplit('/')
        .find(|part| !part.is_empty())
        .unwrap_or(runtime_work_dir);
    let value = basename.strip_prefix("run-").unwrap_or(basename);
    value
        .bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-') {
                byte as char
            } else {
                '-'
            }
        })
        .collect()
}

fn host_hash(host: &str) -> String {
    format!("{:x}", Sha256::digest(host.as_bytes()))[..16].to_owned()
}

fn host_unit_name(purpose: &str, runtime_work_dir: &str, host: &str) -> String {
    format!(
        "nixbot-{purpose}-{}-{}",
        sanitized_run_id(runtime_work_dir),
        host_hash(host)
    )
}

pub fn deploy_unit_name(runtime_work_dir: &str, host: &str, attempt: usize) -> String {
    let base = host_unit_name("switch-to-configuration", runtime_work_dir, host);
    if attempt <= 1 {
        base
    } else {
        format!("{base}-retry{attempt}")
    }
}

pub fn rollback_unit_name(runtime_work_dir: &str, host: &str) -> String {
    host_unit_name("rollback-to-configuration", runtime_work_dir, host)
}

const PRE_SWITCH_ADMISSION_SCRIPT: &str = r#"set -Eeuo pipefail
reset_system_failed_state() {
    failed_output="$(systemctl list-units --failed --no-legend --plain 2>/dev/null || true)"
    [ -n "$failed_output" ] || return 0
    echo '[pre-switch] resetting failed system units:' >&2
    echo "$failed_output" >&2
    systemctl reset-failed
}
managed_user_names() {
    for unit_file in /etc/systemd/user/*-managed.target; do
        [ -e "$unit_file" ] || continue
        user="$(awk -F= '$1 == "ConditionUser" { print $2; exit }' "$unit_file" 2>/dev/null || true)"
        [ -n "$user" ] || continue
        case "$user" in !*|*@*) continue ;; esac
        printf '%s\n' "$user"
    done | sort -u
}
user_manager_bus_ready() {
    setpriv --reuid="$1" --regid="$3" --init-groups \
        env XDG_RUNTIME_DIR="/run/user/$2" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$2/bus" \
        systemctl --user show-environment >/dev/null 2>&1
}
repair_logind_user_managers() {
    if ! users="$(loginctl list-users --no-legend --no-pager 2>/dev/null)"; then
        echo '[pre-switch] unable to enumerate logind users' >&2
        return 1
    fi
    while read -r uid user _; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        [ -n "$user" ] || continue
        gid="$(id -g "$user" 2>/dev/null || true)"
        [ -n "$gid" ] || return 1
        if ! systemctl is-active --quiet "user@${uid}.service" 2>/dev/null; then
            systemctl start "user@${uid}.service" || return 1
        fi
        for ((attempt = 0; attempt < 20; attempt++)); do
            user_manager_bus_ready "$user" "$uid" "$gid" && break
            sleep 0.25
        done
        if [ "$attempt" -eq 20 ]; then
            echo "[pre-switch] user=${user} manager=active bus=unreachable" >&2
            return 1
        fi
    done <<<"$users"
}
report_user_failed_state() {
    units="$(managed_user_names)"
    [ -n "$units" ] || return 0
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        uid="$(id -u "$user" 2>/dev/null || true)"
        [ -n "$uid" ] || continue
        systemctl is-active --quiet "user@${uid}.service" 2>/dev/null || continue
        failed_output="$(setpriv --reuid="$user" --regid="$(id -g "$user")" --init-groups \
            env XDG_RUNTIME_DIR="/run/user/${uid}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
            systemctl --user list-units --failed --no-legend --plain 2>/dev/null || true)"
        [ -n "$failed_output" ] || continue
        echo "[pre-switch] preserving failed user units for ${user} for post-switch reconciliation:" >&2
        echo "$failed_output" >&2
    done <<<"$units"
}
if ! reset_system_failed_state || ! repair_logind_user_managers || ! report_user_failed_state; then
    echo 'Pre-switch checks failed' >&2
    exit 1
fi
"#;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoteCommand {
    pub program: String,
    pub args: Vec<String>,
    pub environment: Vec<(String, String)>,
    pub unit: String,
    pub script: String,
    /// Target-local observer run after detached unit submission. It tails the
    /// retained log and returns the marker's authoritative exit status.
    pub observer_script: Option<String>,
}

pub fn pre_switch_admission_command() -> RemoteCommand {
    RemoteCommand {
        program: SYSTEM_BASH.to_owned(),
        args: vec!["-s".to_owned()],
        environment: Vec::new(),
        unit: String::new(),
        script: PRE_SWITCH_ADMISSION_SCRIPT.to_owned(),
        observer_script: None,
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActivationCommand {
    pub run_id: String,
    pub host: String,
    pub attempt: usize,
    pub generation: SystemGeneration,
    pub goal: ActivationGoal,
    pub boot_environment: BootEnvironment,
    pub restart_managed: bool,
    pub runtime_max: Duration,
    pub stop_timeout: Duration,
    pub lock_wait: Duration,
}

fn activation_script(
    generation: &SystemGeneration,
    goal: ActivationGoal,
    boot_environment: BootEnvironment,
    restart_managed: bool,
    rollback_projection_admission: bool,
    unit: &str,
    lock_wait: Duration,
) -> String {
    let system = generation.as_str();
    let switch = format!("{system}/bin/switch-to-configuration");
    let result = format!("{ACTIVATION_RESULT_DIR}/{unit}.result");
    let log = format!("{ACTIVATION_RESULT_DIR}/{unit}.log");
    let mut body = format!(
        r#"set -Eeuo pipefail
{SYSTEM_INSTALL} -d -m 0700 {ACTIVATION_RESULT_DIR}
printf 'OutcomeSource=marker\nResult=running\nExecMainStatus=255\n' > {result}.tmp
{SYSTEM_MV} -f {result}.tmp {result}
if [ ! -x {switch} ]; then
    echo 'system path is not activatable: {system}' >&2
    exit 1
fi
"#
    );
    if rollback_projection_admission {
        body.push_str(&format!(
            r#"projection_preflight={CURRENT_SYSTEM}/sw/bin/abird-host-agent-projection-preflight
if [ ! -x "$projection_preflight" ]; then
    echo '[rollback-admission] current generation has no projection preflight; refusing automatic rollback because projection safety cannot be proven' >&2
    exit 1
fi
"$projection_preflight" {system} {} rollback
"#,
            goal.as_str()
        ));
    }
    body.push_str(&format!(
        "NIXOS_INSTALL_BOOTLOADER=0 {switch} {}\n",
        goal.as_str()
    ));
    if goal.persists_profile() {
        body.push_str(&format!(
            r#"if [ ! -f {system}/nixos-version ] || [ ! -x {system}/sw/bin/nix-env ]; then
    echo 'system path cannot be promoted to the system profile: {system}' >&2
    exit 1
fi
{system}/sw/bin/nix-env -p {SYSTEM_PROFILE} --set {system}
"#
        ));
        if let Some(post_goal) = goal.post_promote_bootloader_goal(boot_environment) {
            body.push_str(&format!(
                "NIXOS_INSTALL_BOOTLOADER=1 {switch} {}\n",
                post_goal.as_str()
            ));
        }
    }
    if restart_managed {
        body.push_str(&format!(
            r#"control={system}/sw/bin/podman-composectl
registry={system}/share/podman-compose/control-registry.json
if [ -x "$control" ]; then
    NIX_PODMAN_COMPOSE_CONTROL_REGISTRY="$registry" "$control" restart-managed
else
    echo '[managed-restart] no managed service control plane; skipping' >&2
fi
"#
        ));
    }
    body.push_str(&format!(
        r#"printf 'OutcomeSource=marker\nResult=success\nExecMainStatus=0\n' > {result}.tmp
{SYSTEM_MV} -f {result}.tmp {result}
"#
    ));

    // The target-local unit owns both the activation lock and retained output.
    // Its marker remains authoritative if the SSH observer disappears.
    format!(
        r#"set -o pipefail
set +e
{SYSTEM_INSTALL} -d -m 0755 {HOST_LOCAL_ACTIVATION_LOCK}
{SYSTEM_FLOCK} -w {} {HOST_LOCAL_ACTIVATION_LOCK} {SYSTEM_BASH} -c {} 2>&1 | {SYSTEM_TEE} --output-error=warn-nopipe {log}
pipeline_status=("${{PIPESTATUS[@]}}")
rc="${{pipeline_status[0]}}"
if [ "$rc" -ne 0 ]; then
    printf 'OutcomeSource=marker\nResult=exit-code\nExecMainStatus=%s\n' "$rc" > {result}.tmp
    {SYSTEM_MV} -f {result}.tmp {result}
fi
exit "$rc"
"#,
        lock_wait.as_secs(),
        shell_single_quote(&body)
    )
}

fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn supervised_activation_command(
    unit: String,
    script: String,
    runtime_max: Duration,
    stop_timeout: Duration,
) -> RemoteCommand {
    let observer_script = activation_observer_script(&unit, runtime_max + stop_timeout);
    RemoteCommand {
        program: "systemd-run".to_owned(),
        args: vec![
            "-E".to_owned(),
            "LOCALE_ARCHIVE".to_owned(),
            "-E".to_owned(),
            "NIXOS_INSTALL_BOOTLOADER".to_owned(),
            "-E".to_owned(),
            "NIXOS_NO_CHECK".to_owned(),
            "--expand-environment=no".to_owned(),
            "--collect".to_owned(),
            "--no-block".to_owned(),
            "--no-ask-password".to_owned(),
            "--quiet".to_owned(),
            "--service-type=exec".to_owned(),
            format!("--property=RuntimeMaxSec={}s", runtime_max.as_secs()),
            format!("--property=TimeoutStopSec={}s", stop_timeout.as_secs()),
            "--property=KillMode=control-group".to_owned(),
            "--property=CollectMode=inactive-or-failed".to_owned(),
            format!("--unit={unit}"),
            SYSTEM_BASH.to_owned(),
            "-c".to_owned(),
            script.clone(),
        ],
        environment: vec![("NIXOS_INSTALL_BOOTLOADER".to_owned(), "0".to_owned())],
        unit,
        script,
        observer_script: Some(observer_script),
    }
}

fn activation_observer_script(unit: &str, max_wait: Duration) -> String {
    let result = format!("{ACTIVATION_RESULT_DIR}/{unit}.result");
    let log = format!("{ACTIVATION_RESULT_DIR}/{unit}.log");
    // The extra ten seconds matches nixbot's allowance for unit collection and
    // final marker publication after RuntimeMaxSec plus TimeoutStopSec.
    let max_polls = (max_wait.as_secs() + 10).saturating_mul(10);
    format!(
        r#"result_file={result}
log_file={log}
unit={unit}
for ((polls = 0; polls < {max_polls}; polls++)); do
    result=running
    exec_main_status=255
    if [ -s "$result_file" ]; then
        while IFS= read -r line; do
            case "$line" in
                Result=*) result="${{line#Result=}}" ;;
                ExecMainStatus=*) exec_main_status="${{line#ExecMainStatus=}}" ;;
            esac
        done < "$result_file"
    fi
    [ "$result" = running ] || break
    active_state="$({SYSTEM_SYSTEMCTL} show --property=ActiveState --value "$unit" 2>/dev/null || true)"
    load_state="$({SYSTEM_SYSTEMCTL} show --property=LoadState --value "$unit" 2>/dev/null || true)"
    case "${{load_state}}:${{active_state}}" in
        not-found:*|*:inactive|*:failed)
            [ -s "$result_file" ] || exit 255
            break
            ;;
    esac
    {SYSTEM_SLEEP} 0.1
done
[ ! -e "$log_file" ] || {SYSTEM_CAT} "$log_file"
case "$exec_main_status" in ''|*[!0-9]*) exit 255 ;; *) exit "$exec_main_status" ;; esac
"#
    )
}

pub fn activation_command(spec: ActivationCommand) -> RemoteCommand {
    let unit = deploy_unit_name(&spec.run_id, &spec.host, spec.attempt);
    let script = activation_script(
        &spec.generation,
        spec.goal,
        spec.boot_environment,
        spec.restart_managed,
        false,
        &unit,
        spec.lock_wait,
    );
    supervised_activation_command(unit, script, spec.runtime_max, spec.stop_timeout)
}

pub fn rollback_command(
    run_id: &str,
    host: &str,
    generation: SystemGeneration,
    boot_environment: BootEnvironment,
    runtime_max: Duration,
    stop_timeout: Duration,
    lock_wait: Duration,
) -> RemoteCommand {
    let unit = rollback_unit_name(run_id, host);
    let script = activation_script(
        &generation,
        ActivationGoal::Switch,
        boot_environment,
        false,
        true,
        &unit,
        lock_wait,
    );
    supervised_activation_command(unit, script, runtime_max, stop_timeout)
}

pub fn rollback_waves(levels: &[Vec<String>]) -> Vec<Vec<String>> {
    levels.iter().rev().cloned().collect()
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ActivationSample {
    pub outcome_source: Option<String>,
    pub load_state: Option<String>,
    pub active_state: Option<String>,
    pub result: Option<String>,
    pub exec_main_status: Option<u8>,
    pub current_system: Option<SystemGeneration>,
    pub system_profile: Option<SystemGeneration>,
}

impl ActivationSample {
    pub fn parse(output: &str) -> Result<Self> {
        let mut sample = Self::default();
        for line in output.lines() {
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            match key {
                "OutcomeSource" => {
                    set_once(&mut sample.outcome_source, value.to_owned(), key)?;
                    if value != "marker" {
                        bail!("unsupported activation outcome source: {value}");
                    }
                }
                "LoadState" => set_once(&mut sample.load_state, value.to_owned(), key)?,
                "ActiveState" => set_once(&mut sample.active_state, value.to_owned(), key)?,
                "Result" => set_once(&mut sample.result, value.to_owned(), key)?,
                "ExecMainStatus" => {
                    let status = value
                        .parse::<u8>()
                        .map_err(|_| anyhow::anyhow!("invalid ExecMainStatus: {value}"))?;
                    set_once(&mut sample.exec_main_status, status, key)?;
                }
                "CurrentSystemPath" if !value.is_empty() => set_once(
                    &mut sample.current_system,
                    SystemGeneration::parse(value)?,
                    key,
                )?,
                "SystemProfilePath" if !value.is_empty() => set_once(
                    &mut sample.system_profile,
                    SystemGeneration::parse(value)?,
                    key,
                )?,
                _ => {}
            }
        }
        Ok(sample)
    }

    pub fn authoritative(&self) -> bool {
        self.outcome_source.as_deref() == Some("marker")
            || self.load_state.as_deref() == Some("loaded")
    }

    pub fn successful(&self) -> bool {
        self.result.as_deref() == Some("success") && self.exec_main_status == Some(0)
    }

    pub fn running(&self) -> bool {
        matches!(
            self.active_state.as_deref(),
            Some("active" | "activating" | "reloading" | "deactivating")
        )
    }

    pub fn settled(&self) -> bool {
        matches!(self.active_state.as_deref(), Some("inactive" | "failed"))
    }
}

fn set_once<T>(field: &mut Option<T>, value: T, key: &str) -> Result<()> {
    if field.is_some() {
        bail!("duplicate activation outcome property: {key}");
    }
    *field = Some(value);
    Ok(())
}

pub fn activation_verification_command(unit: &str) -> RemoteCommand {
    let result = format!("{ACTIVATION_RESULT_DIR}/{unit}.result");
    let script = format!(
        r#"if [ -s {result} ]; then
    {SYSTEM_CAT} {result}
else
    {SYSTEM_SYSTEMCTL} show --property=LoadState,ActiveState,Result,ExecMainStatus {unit} 2>/dev/null || true
fi
printf 'CurrentSystemPath='
{SYSTEM_READLINK} -f {CURRENT_SYSTEM} 2>/dev/null || true
printf 'SystemProfilePath='
{SYSTEM_READLINK} -f {SYSTEM_PROFILE} 2>/dev/null || true
"#
    );
    RemoteCommand {
        program: SYSTEM_BASH.to_owned(),
        args: vec!["-c".to_owned(), script.clone()],
        environment: Vec::new(),
        unit: unit.to_owned(),
        script,
        observer_script: None,
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum VerificationDecision {
    Pending,
    Succeeded,
    Failed(String),
}

pub fn verify_activation(
    sample: &ActivationSample,
    target: &SystemGeneration,
    goal: ActivationGoal,
) -> VerificationDecision {
    if !sample.authoritative() || sample.running() || !sample.settled() {
        return VerificationDecision::Pending;
    }
    if sample.current_system.as_ref() != Some(target) {
        return VerificationDecision::Failed(format!(
            "activation settled without switching current system to {}",
            target.as_str()
        ));
    }
    if !sample.successful() {
        return VerificationDecision::Failed(format!(
            "activation settled unsuccessfully: result={:?} status={:?}",
            sample.result, sample.exec_main_status
        ));
    }
    if goal.persists_profile() && sample.system_profile.as_ref() != Some(target) {
        return VerificationDecision::Failed(format!(
            "activation switched current system but did not promote profile to {}",
            target.as_str()
        ));
    }
    VerificationDecision::Succeeded
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeployFailureAction {
    ReturnSignal(i32),
    RejectBeforeSwitch,
    RetryBeforeAdmission { next_attempt: usize },
    VerifyTarget,
    Fail(i32),
}

pub fn classify_deploy_failure(
    status: i32,
    output: &str,
    activation_admitted: bool,
    attempt: usize,
    max_attempts: usize,
) -> DeployFailureAction {
    if matches!(status, 130 | 143) {
        return DeployFailureAction::ReturnSignal(status);
    }
    if output.contains("Pre-switch checks failed") {
        return DeployFailureAction::RejectBeforeSwitch;
    }
    if !activation_admitted && pre_admission_ssh_failure(output) {
        return if attempt < max_attempts {
            DeployFailureAction::RetryBeforeAdmission {
                next_attempt: attempt + 1,
            }
        } else {
            DeployFailureAction::Fail(status)
        };
    }
    if transport_loss(output) || matches!(status, 124 | 255) {
        return DeployFailureAction::VerifyTarget;
    }
    DeployFailureAction::Fail(status)
}

fn host_key_verification_failure(output: &str) -> bool {
    [
        "REMOTE HOST IDENTIFICATION HAS CHANGED",
        "Host key verification failed",
        "Offending ",
    ]
    .iter()
    .any(|needle| output.contains(needle))
}

fn pre_admission_ssh_failure(output: &str) -> bool {
    if host_key_verification_failure(output) {
        return false;
    }
    [
        "Connection timed out during banner exchange",
        "Connection refused",
        "Connection timed out",
        "No route to host",
        "Network is unreachable",
        "kex_exchange_identification",
        "ssh_exchange_identification",
    ]
    .iter()
    .any(|needle| output.contains(needle))
}

fn transport_loss(output: &str) -> bool {
    if host_key_verification_failure(output) {
        return false;
    }
    [
        "failed to start SSH connection",
        "mux_client_request_session",
        "kex_exchange_identification",
        "ssh_exchange_identification",
        "Connection reset by peer",
        "Connection closed by remote host",
        "Received disconnect",
        "Broken pipe",
        "Bad file descriptor",
        "stdio forwarding failed",
        "Connection timed out",
        "No route to host",
    ]
    .iter()
    .any(|needle| output.contains(needle))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LockContentionEvidence {
    direct: bool,
    retained: bool,
}

impl LockContentionEvidence {
    pub fn inspect(output: &str, retained_journal: &str) -> Self {
        let has_evidence = |value: &str| {
            value.contains("Could not acquire lock")
                || value.contains(ACTIVATION_LOCK)
                || value.contains("Acquiring lock")
                || value.contains("Creating lock file")
        };
        Self {
            direct: has_evidence(output),
            retained: has_evidence(retained_journal),
        }
    }

    pub fn detected(&self) -> bool {
        self.direct || self.retained
    }

    /// A direct failure forces the remote diagnostic report even if the unit's
    /// own journal was already collected or rotated.
    pub fn force_report(&self) -> bool {
        self.direct
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CancellationAction {
    Stop,
    Wait(Duration),
    Kill,
    Complete,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CancellationState {
    Initial,
    Waiting,
    Killed,
    Complete,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CancellationController {
    grace: Duration,
    state: CancellationState,
}

impl CancellationController {
    pub fn new(grace: Duration) -> Self {
        Self {
            grace,
            state: CancellationState::Initial,
        }
    }

    /// Return one bounded cancellation effect. `elapsed` is measured from the
    /// initial stop request; callers perform at most one-second poll waits.
    pub fn next_action(&mut self, elapsed: Duration, units_running: bool) -> CancellationAction {
        match self.state {
            CancellationState::Initial => {
                self.state = CancellationState::Waiting;
                CancellationAction::Stop
            }
            CancellationState::Waiting if !units_running => {
                self.state = CancellationState::Complete;
                CancellationAction::Complete
            }
            CancellationState::Waiting if elapsed >= self.grace => {
                self.state = CancellationState::Killed;
                CancellationAction::Kill
            }
            CancellationState::Waiting => {
                let remaining = self.grace.saturating_sub(elapsed);
                CancellationAction::Wait(remaining.min(Duration::from_secs(1)))
            }
            CancellationState::Killed | CancellationState::Complete => {
                self.state = CancellationState::Complete;
                CancellationAction::Complete
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ActivationStatus {
    Exited(i32),
    Signalled(i32),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActivationResult {
    pub status: ActivationStatus,
    pub output: String,
}

pub trait ActivationExecutor {
    fn execute(&mut self, command: &RemoteCommand) -> ActivationResult;
}
