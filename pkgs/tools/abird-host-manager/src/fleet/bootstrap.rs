//! Pure bootstrap, identity-materialization, and transport-selection contracts.
//!
//! The types in this module describe filesystem and remote effects without
//! performing them. Runtime code supplies observations through small traits,
//! which keeps key material and live hosts outside the planning layer.

use std::collections::BTreeSet;
use std::error::Error;
use std::fmt;
use std::path::{Path, PathBuf};

pub const REMOTE_NIXBOT_BASE: &str = "/var/lib/nixbot";
pub const REMOTE_NIXBOT_PRIMARY_KEY: &str = "/var/lib/nixbot/.ssh/id_ed25519";
pub const REMOTE_NIXBOT_LEGACY_KEY: &str = "/var/lib/nixbot/.ssh/id_ed25519_legacy";
pub const REMOTE_NIXBOT_AUTHORIZED_KEYS: &str = "/etc/ssh/authorized_keys.d/nixbot";
pub const REMOTE_NIXBOT_AGE_IDENTITY: &str = "/var/lib/nixbot/.age/identity";
pub const REMOTE_NIXBOT_DEPLOY_SCRIPT: &str = "/run/current-system/sw/bin/nixbot";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FileMode(pub u32);

pub trait PathInspector {
    fn is_file(&self, path: &Path) -> bool;
    fn canonicalize(&self, path: &Path) -> Result<PathBuf, SecretPathError>;
}

/// Reproduce the key lookup order without accessing the filesystem directly.
pub fn resolve_key_source_path(
    key_path: &str,
    current_dir: &Path,
    config_dir: Option<&Path>,
    paths: &impl PathInspector,
) -> Result<PathBuf, SecretPathError> {
    if key_path.is_empty() {
        return Ok(PathBuf::new());
    }
    let requested = Path::new(key_path);
    if requested.is_absolute() {
        return Ok(requested.to_path_buf());
    }

    let current_candidate = current_dir.join(requested);
    if paths.is_file(&current_candidate) {
        return paths.canonicalize(&current_candidate);
    }

    if let Some(config_dir) = config_dir {
        let config_candidate = config_dir.join(requested);
        if paths.is_file(&config_candidate) {
            return Ok(config_candidate);
        }
        let parent_candidate = config_dir.join("..").join(requested);
        if paths.is_file(&parent_candidate) {
            return Ok(parent_candidate);
        }
        return Ok(parent_candidate);
    }

    Ok(requested.to_path_buf())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgeDiscoveryMode {
    Auto,
    On,
    Off,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgeIdentityPolicy {
    pub configured: PathBuf,
    pub configured_explicitly: bool,
    pub discovery: AgeDiscoveryMode,
}

/// Return candidates in attempted order with stable deduplication.
pub fn age_identity_candidates(policy: &AgeIdentityPolicy) -> Vec<PathBuf> {
    let discover = match policy.discovery {
        AgeDiscoveryMode::On => true,
        AgeDiscoveryMode::Off => false,
        AgeDiscoveryMode::Auto => !policy.configured_explicitly,
    };
    let mut seen = BTreeSet::new();
    let mut candidates = Vec::new();
    let requested = std::iter::once(policy.configured.clone()).chain(
        discover
            .then_some([
                PathBuf::from(REMOTE_NIXBOT_PRIMARY_KEY),
                PathBuf::from(REMOTE_NIXBOT_AGE_IDENTITY),
            ])
            .into_iter()
            .flatten(),
    );
    for candidate in requested {
        if candidate.as_os_str().is_empty() || !seen.insert(candidate.clone()) {
            continue;
        }
        candidates.push(candidate);
    }
    candidates
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum IdentityMaterializationPlan {
    Missing {
        source: PathBuf,
    },
    Plain {
        source: PathBuf,
    },
    AgeDecrypt {
        source: PathBuf,
        identity_candidates: Vec<PathBuf>,
        output: PathBuf,
        output_mode: FileMode,
    },
}

/// Describe plain passthrough or sequential age decryption. Callers still
/// verify that a successful decrypted output is nonempty and usable.
pub fn plan_identity_materialization(
    source: &Path,
    source_exists: bool,
    require_age: bool,
    identity_candidates: &[PathBuf],
    output: &Path,
) -> Result<IdentityMaterializationPlan, SecretPathError> {
    if !source_exists {
        return Ok(IdentityMaterializationPlan::Missing {
            source: source.to_path_buf(),
        });
    }
    let encrypted = source
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.ends_with(".age"));
    if require_age && !encrypted {
        return Err(SecretPathError::EncryptedIdentityRequired(
            source.to_path_buf(),
        ));
    }
    if !encrypted {
        return Ok(IdentityMaterializationPlan::Plain {
            source: source.to_path_buf(),
        });
    }

    Ok(IdentityMaterializationPlan::AgeDecrypt {
        source: source.to_path_buf(),
        identity_candidates: stable_paths(identity_candidates),
        output: output.to_path_buf(),
        output_mode: FileMode(0o600),
    })
}

fn stable_paths(paths: &[PathBuf]) -> Vec<PathBuf> {
    let mut seen = BTreeSet::new();
    paths
        .iter()
        .filter(|path| !path.as_os_str().is_empty())
        .filter(|path| seen.insert((*path).clone()))
        .cloned()
        .collect()
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProxyHop {
    pub target: String,
    pub has_proxy_command: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KnownHostsInput {
    pub node: String,
    pub target_host: String,
    pub configured_contents: Option<String>,
    pub proxy_chain: Vec<ProxyHop>,
    pub proxy_command: Option<String>,
    pub output_file: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum KnownHostsSeed {
    Configured { contents: String },
    Empty,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SshHostKeyPolicy {
    Strict,
    AcceptNew,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScanAlgorithm {
    Ed25519,
    Any,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KnownHostScan {
    pub host: String,
    pub algorithm: ScanAlgorithm,
    pub only_if_host_still_missing: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KnownHostsPlan {
    pub output_file: PathBuf,
    pub seed: KnownHostsSeed,
    pub mode: FileMode,
    pub host_key_policy: SshHostKeyPolicy,
    pub scans: Vec<KnownHostScan>,
}

fn scans_for(host: &str) -> Vec<KnownHostScan> {
    vec![
        KnownHostScan {
            host: host.to_owned(),
            algorithm: ScanAlgorithm::Ed25519,
            only_if_host_still_missing: false,
        },
        KnownHostScan {
            host: host.to_owned(),
            algorithm: ScanAlgorithm::Any,
            only_if_host_still_missing: true,
        },
    ]
}

/// Plan isolated known_hosts creation and scanning. Proxied connections use
/// `accept-new`, which still rejects changed keys.
pub fn known_hosts_plan(input: &KnownHostsInput) -> KnownHostsPlan {
    let configured = input
        .configured_contents
        .as_deref()
        .is_some_and(|contents| !contents.is_empty());
    let proxied = !input.proxy_chain.is_empty()
        || input
            .proxy_command
            .as_deref()
            .is_some_and(|command| !command.is_empty());
    let scans = if configured {
        Vec::new()
    } else if !proxied {
        scans_for(&input.target_host)
    } else if let Some(first) = input
        .proxy_chain
        .first()
        .filter(|hop| !hop.has_proxy_command)
    {
        scans_for(&first.target)
    } else {
        Vec::new()
    };

    KnownHostsPlan {
        output_file: input.output_file.clone(),
        seed: if configured {
            KnownHostsSeed::Configured {
                contents: input.configured_contents.clone().unwrap_or_default(),
            }
        } else {
            KnownHostsSeed::Empty
        },
        mode: FileMode(0o600),
        host_key_policy: if proxied {
            SshHostKeyPolicy::AcceptNew
        } else {
            SshHostKeyPolicy::Strict
        },
        scans,
    }
}

/// Errors treated as temporary transport unavailability before bootstrap
/// fallback is considered.
pub fn temporary_transport_failure(output: &str) -> bool {
    [
        "Connection timed out",
        "Connection timed out during banner exchange",
        "No route to host",
        "Connection reset by peer",
        "Connection closed by remote host",
        "kex_exchange_identification",
        "ssh_exchange_identification",
        "stdio forwarding failed",
        "mux_client_request_session",
        "Broken pipe",
    ]
    .iter()
    .any(|fragment| output.contains(fragment))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PrimaryRoute {
    Direct,
    FullProxy,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProbeObservation {
    Reachable,
    Failed { status: i32, output: String },
}

impl ProbeObservation {
    pub fn failed(status: i32, output: impl Into<String>) -> Self {
        Self::Failed {
            status,
            output: output.into(),
        }
    }

    fn output(&self) -> &str {
        match self {
            Self::Reachable => "",
            Self::Failed { output, .. } => output,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ForcedCommandObservation {
    Succeeded,
    Failed { output: String },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ForcedCommandReadiness {
    Ready,
    LegacyAuthenticated,
    Failed,
}

pub fn classify_forced_command_readiness(
    observation: &ForcedCommandObservation,
) -> ForcedCommandReadiness {
    match observation {
        ForcedCommandObservation::Succeeded => ForcedCommandReadiness::Ready,
        ForcedCommandObservation::Failed { output }
            if output.contains("Unsupported action: check-bootstrap")
                || output.contains("invalid action") =>
        {
            ForcedCommandReadiness::LegacyAuthenticated
        }
        ForcedCommandObservation::Failed { .. } => ForcedCommandReadiness::Failed,
    }
}

pub trait BootstrapExecutor {
    fn probe_primary(&mut self, route: PrimaryRoute) -> ProbeObservation;
    fn check_forced_command(&mut self) -> ForcedCommandObservation;
    fn install_bootstrap_key(&mut self) -> Result<(), String>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TransportInput {
    pub node: String,
    pub primary_target: String,
    pub operator_target: Option<String>,
    pub has_full_proxy_route: bool,
    pub force_bootstrap: bool,
    pub primary_only: bool,
    pub bootstrap_key_configured: bool,
    pub bootstrap_ready_cached: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BootstrapReadiness {
    Cached,
    ForcedCommand,
    Injected,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TransportDecision {
    Primary {
        route: PrimaryRoute,
    },
    OperatorFallback {
        target: String,
        readiness: BootstrapReadiness,
    },
    RetryTemporaryTransport,
}

fn probe_primary<E: BootstrapExecutor>(
    input: &TransportInput,
    executor: &mut E,
) -> Result<PrimaryRoute, ProbeObservation> {
    let direct = executor.probe_primary(PrimaryRoute::Direct);
    if direct == ProbeObservation::Reachable {
        return Ok(PrimaryRoute::Direct);
    }
    if !input.has_full_proxy_route {
        return Err(direct);
    }
    let proxied = executor.probe_primary(PrimaryRoute::FullProxy);
    if proxied == ProbeObservation::Reachable {
        Ok(PrimaryRoute::FullProxy)
    } else {
        Err(proxied)
    }
}

/// Select primary or operator transport while preserving the temporary-error
/// retry boundary and forced-command shortcut.
pub fn prepare_transport<E: BootstrapExecutor>(
    input: &TransportInput,
    executor: &mut E,
) -> Result<TransportDecision, BootstrapError> {
    if input.force_bootstrap {
        let target = input
            .operator_target
            .clone()
            .ok_or_else(|| BootstrapError::MissingOperator(input.node.clone()))?;
        if input.bootstrap_key_configured {
            executor
                .install_bootstrap_key()
                .map_err(BootstrapError::BootstrapInstall)?;
        }
        return Ok(TransportDecision::OperatorFallback {
            target,
            readiness: BootstrapReadiness::Injected,
        });
    }

    let failure = match probe_primary(input, executor) {
        Ok(route) => return Ok(TransportDecision::Primary { route }),
        Err(failure) => failure,
    };
    if input.primary_only {
        return Err(BootstrapError::PrimaryUnavailable {
            target: input.primary_target.clone(),
        });
    }
    if temporary_transport_failure(failure.output()) {
        return Ok(TransportDecision::RetryTemporaryTransport);
    }
    let target = input
        .operator_target
        .clone()
        .ok_or_else(|| BootstrapError::MissingOperator(input.node.clone()))?;

    let readiness = if input.bootstrap_ready_cached {
        BootstrapReadiness::Cached
    } else if input.bootstrap_key_configured {
        match classify_forced_command_readiness(&executor.check_forced_command()) {
            ForcedCommandReadiness::Ready | ForcedCommandReadiness::LegacyAuthenticated => {
                BootstrapReadiness::ForcedCommand
            }
            ForcedCommandReadiness::Failed => {
                executor
                    .install_bootstrap_key()
                    .map_err(BootstrapError::BootstrapInstall)?;
                BootstrapReadiness::Injected
            }
        }
    } else {
        // `ensure_bootstrap_key_ready` is a successful no-op when no key was
        // configured, and the operator path may already have admission.
        BootstrapReadiness::Injected
    };

    if readiness != BootstrapReadiness::ForcedCommand
        && let Ok(route) = probe_primary(input, executor)
    {
        return Ok(TransportDecision::Primary { route });
    }
    Ok(TransportDecision::OperatorFallback { target, readiness })
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ForcedCommandInput {
    pub node: String,
    pub ssh_target: String,
    pub ssh_options: Vec<String>,
    pub override_identity: Option<PathBuf>,
    pub sha: Option<String>,
    pub config_path: Option<PathBuf>,
    pub repo_worktree: Option<PathBuf>,
    pub repo_root: Option<PathBuf>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ForcedCommandPlan {
    pub ssh_target: String,
    pub ssh_args: Vec<String>,
    pub remote_command: Vec<String>,
}

fn without_identity_options(options: &[String]) -> Vec<String> {
    let mut retained = Vec::new();
    let mut index = 0;
    while index < options.len() {
        let option = options[index].as_str();
        if option == "-i" {
            index += 2;
            continue;
        }
        if option == "-o" && index + 1 < options.len() {
            if options[index + 1].starts_with("IdentitiesOnly=") {
                index += 2;
                continue;
            }
            retained.push(options[index].clone());
            retained.push(options[index + 1].clone());
            index += 2;
            continue;
        }
        if option.starts_with("-oIdentitiesOnly=") || option.starts_with("IdentitiesOnly=") {
            index += 1;
            continue;
        }
        retained.push(options[index].clone());
        index += 1;
    }
    retained
}

fn forwarded_config_path(input: &ForcedCommandInput) -> Result<Option<PathBuf>, BootstrapError> {
    let Some(config) = &input.config_path else {
        return Ok(None);
    };
    if config.is_relative() {
        return Ok(Some(config.clone()));
    }
    for root in [&input.repo_worktree, &input.repo_root]
        .into_iter()
        .flatten()
    {
        if let Ok(relative) = config.strip_prefix(root) {
            return Ok(Some(relative.to_path_buf()));
        }
    }
    Err(BootstrapError::ConfigOutsideRepository(config.clone()))
}

/// Build the forced-command readiness probe without retaining the deploy
/// identity when a dedicated check identity is supplied.
pub fn build_forced_command_check(
    input: &ForcedCommandInput,
) -> Result<ForcedCommandPlan, BootstrapError> {
    let mut ssh_args = input.ssh_options.clone();
    if let Some(identity) = &input.override_identity {
        ssh_args = without_identity_options(&ssh_args);
        ssh_args.splice(
            0..0,
            [
                "-i".to_owned(),
                identity.display().to_string(),
                "-o".to_owned(),
                "IdentitiesOnly=yes".to_owned(),
            ],
        );
    }

    let mut remote_command = vec![
        REMOTE_NIXBOT_DEPLOY_SCRIPT.to_owned(),
        "check-bootstrap".to_owned(),
    ];
    if let Some(sha) = input.sha.as_deref().filter(|sha| !sha.is_empty()) {
        remote_command.extend(["--sha".to_owned(), sha.to_owned()]);
    }
    remote_command.extend(["--hosts".to_owned(), input.node.clone()]);
    if let Some(config) = forwarded_config_path(input)? {
        remote_command.extend(["--config".to_owned(), config.display().to_string()]);
    }
    Ok(ForcedCommandPlan {
        ssh_target: input.ssh_target.clone(),
        ssh_args,
        remote_command,
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BootstrapKeyInstallPlan {
    pub local_source: PathBuf,
    pub remote_base: PathBuf,
    pub remote_directory: PathBuf,
    pub destination: PathBuf,
    pub legacy_destination: PathBuf,
    pub remote_base_mode: FileMode,
    pub directory_mode: FileMode,
    pub file_mode: FileMode,
    pub temporary_mode: FileMode,
    pub owner_if_account_exists: Option<(String, String)>,
    pub backup_existing_to_legacy: bool,
}

pub fn bootstrap_key_install_plan(local_source: &Path) -> BootstrapKeyInstallPlan {
    BootstrapKeyInstallPlan {
        local_source: local_source.to_path_buf(),
        remote_base: PathBuf::from(REMOTE_NIXBOT_BASE),
        remote_directory: PathBuf::from("/var/lib/nixbot/.ssh"),
        destination: PathBuf::from(REMOTE_NIXBOT_PRIMARY_KEY),
        legacy_destination: PathBuf::from(REMOTE_NIXBOT_LEGACY_KEY),
        remote_base_mode: FileMode(0o755),
        directory_mode: FileMode(0o700),
        file_mode: FileMode(0o400),
        temporary_mode: FileMode(0o600),
        owner_if_account_exists: Some(("nixbot".to_owned(), "nixbot".to_owned())),
        backup_existing_to_legacy: true,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BootstrapKeyState {
    Matching,
    Different,
    Unreachable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BootstrapInstallAction {
    EnsureAuthorizedOnly,
    InstallAndEnsureAuthorized,
    FailUnreachable,
}

pub fn bootstrap_key_action(state: BootstrapKeyState) -> BootstrapInstallAction {
    match state {
        BootstrapKeyState::Matching => BootstrapInstallAction::EnsureAuthorizedOnly,
        BootstrapKeyState::Different => BootstrapInstallAction::InstallAndEnsureAuthorized,
        BootstrapKeyState::Unreachable => BootstrapInstallAction::FailUnreachable,
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AuthorizedKeyAction {
    AlreadyPresent,
    PreserveAppendInstall {
        destination: PathBuf,
        mode: FileMode,
        owner: String,
        group: String,
    },
}

/// Exact-line membership is the idempotence boundary for authorized_keys.
pub fn authorized_key_action(
    destination_exists: bool,
    exact_public_key_present: bool,
) -> AuthorizedKeyAction {
    if destination_exists && exact_public_key_present {
        AuthorizedKeyAction::AlreadyPresent
    } else {
        AuthorizedKeyAction::PreserveAppendInstall {
            destination: PathBuf::from(REMOTE_NIXBOT_AUTHORIZED_KEYS),
            mode: FileMode(0o444),
            owner: "root".to_owned(),
            group: "root".to_owned(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostAgeIdentityInstallPlan {
    pub local_source: PathBuf,
    pub expected_sha256: String,
    pub remote_base: PathBuf,
    pub remote_directory: PathBuf,
    pub destination: PathBuf,
    pub remote_base_mode: FileMode,
    pub directory_mode: FileMode,
    pub file_mode: FileMode,
    pub temporary_mode: FileMode,
    pub owner: String,
    pub group: String,
}

pub fn host_age_identity_install_plan(
    local_source: &Path,
    expected_sha256: &str,
) -> HostAgeIdentityInstallPlan {
    HostAgeIdentityInstallPlan {
        local_source: local_source.to_path_buf(),
        expected_sha256: expected_sha256.to_owned(),
        remote_base: PathBuf::from(REMOTE_NIXBOT_BASE),
        remote_directory: PathBuf::from("/var/lib/nixbot/.age"),
        destination: PathBuf::from(REMOTE_NIXBOT_AGE_IDENTITY),
        remote_base_mode: FileMode(0o755),
        directory_mode: FileMode(0o710),
        file_mode: FileMode(0o440),
        temporary_mode: FileMode(0o600),
        owner: "root".to_owned(),
        group: "nixbot".to_owned(),
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostAgeIdentityInput {
    pub materialized_file: Option<PathBuf>,
    pub expected_sha256: Option<String>,
    pub remote_sha256: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HostAgeIdentityAction {
    NotConfigured,
    InvalidMaterial,
    AlreadyCurrent,
    Install,
}

pub fn host_age_identity_action(input: &HostAgeIdentityInput) -> HostAgeIdentityAction {
    match (&input.materialized_file, &input.expected_sha256) {
        (None, None) => HostAgeIdentityAction::NotConfigured,
        (Some(_), Some(expected)) if input.remote_sha256.as_deref() == Some(expected) => {
            HostAgeIdentityAction::AlreadyCurrent
        }
        (Some(_), Some(_)) => HostAgeIdentityAction::Install,
        _ => HostAgeIdentityAction::InvalidMaterial,
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VisibilityPlan {
    pub destination: PathBuf,
    pub expected_sha256: String,
    pub maximum_attempts: u32,
    pub retry_interval_seconds: u64,
    pub via_activation_context: bool,
    pub command: String,
}

impl VisibilityPlan {
    pub fn host_age_identity(expected_sha256: &str) -> Self {
        Self {
            destination: PathBuf::from(REMOTE_NIXBOT_AGE_IDENTITY),
            expected_sha256: expected_sha256.to_owned(),
            maximum_attempts: 10,
            retry_interval_seconds: 1,
            via_activation_context: true,
            command: concat!(
                "sudo -n systemd-run --wait --pipe --quiet --service-type=exec ",
                "sha256sum /var/lib/nixbot/.age/identity"
            )
            .to_owned(),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SudoAdmission {
    Root,
    Passwordless,
    Denied,
}

pub fn sudo_admission(deploy_user: &str, passwordless_probe: Option<bool>) -> SudoAdmission {
    if deploy_user == "root" {
        SudoAdmission::Root
    } else if passwordless_probe == Some(true) {
        SudoAdmission::Passwordless
    } else {
        SudoAdmission::Denied
    }
}

pub fn sudo_probe_command() -> [&'static str; 3] {
    ["sudo", "-n", "true"]
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BootstrapCheckObservation {
    NotChecked,
    MaterializationFailed,
    Missing { resolved: PathBuf },
    Unreadable { resolved: PathBuf },
    Readable { fingerprint: String },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BootstrapCheckHost {
    pub host: String,
    pub configured_key: Option<PathBuf>,
    pub observation: BootstrapCheckObservation,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CheckBootstrapResult {
    pub ok_hosts: Vec<String>,
    pub failed_hosts: Vec<String>,
    pub success: bool,
}

/// Aggregate `check-bootstrap` exactly as a key-material check: a host with no
/// configured bootstrap key is successful without probing a file.
pub fn check_bootstrap_results(hosts: &[BootstrapCheckHost]) -> CheckBootstrapResult {
    let mut ok_hosts = Vec::new();
    let mut failed_hosts = Vec::new();
    for host in hosts {
        let ok = host.configured_key.is_none()
            || matches!(
                &host.observation,
                BootstrapCheckObservation::Readable { fingerprint }
                    if !fingerprint.is_empty()
            );
        if ok {
            ok_hosts.push(host.host.clone());
        } else {
            failed_hosts.push(host.host.clone());
        }
    }
    CheckBootstrapResult {
        success: failed_hosts.is_empty(),
        ok_hosts,
        failed_hosts,
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SecretPathError {
    Canonicalize(PathBuf),
    EncryptedIdentityRequired(PathBuf),
}

impl fmt::Display for SecretPathError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Canonicalize(path) => {
                write!(
                    formatter,
                    "cannot canonicalize key path: {}",
                    path.display()
                )
            }
            Self::EncryptedIdentityRequired(path) => write!(
                formatter,
                "identity must be an age-encrypted file: {}",
                path.display()
            ),
        }
    }
}

impl Error for SecretPathError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BootstrapError {
    MissingOperator(String),
    PrimaryUnavailable { target: String },
    BootstrapInstall(String),
    ConfigOutsideRepository(PathBuf),
}

impl fmt::Display for BootstrapError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingOperator(node) => {
                write!(formatter, "host {node} has no operator user configured")
            }
            Self::PrimaryUnavailable { target } => {
                write!(formatter, "primary deploy target unavailable: {target}")
            }
            Self::BootstrapInstall(error) => {
                write!(formatter, "bootstrap key installation failed: {error}")
            }
            Self::ConfigOutsideRepository(path) => write!(
                formatter,
                "cannot forward config outside repository: {}",
                path.display()
            ),
        }
    }
}

impl Error for BootstrapError {}
