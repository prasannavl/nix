use std::collections::BTreeMap;
use std::env;
use std::path::PathBuf;

use anyhow::{Result, bail};

use super::cli::{ActivationGoal, BuildHostDeployMode, DiscoverKeys, JobCount, LogFormat, Options};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum LocalSelfTarget {
    #[default]
    Auto,
    On,
    Off,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Settings {
    pub build_plan_cache: bool,
    pub build_plan_cache_dir: Option<PathBuf>,
    pub build_heartbeat_seconds: u64,
    pub activation_heartbeat_seconds: u64,
    pub local_self_target: LocalSelfTarget,
    pub transport_retry_attempts: usize,
    pub transport_retry_delay_seconds: u64,
    pub ssh_connect_timeout_seconds: u64,
    pub ssh_server_alive_interval_seconds: u64,
    pub ssh_server_alive_count_max: usize,
    pub ssh_control_persist_seconds: u64,
    pub remote_read_timeout_seconds: u64,
    pub remote_activation_runtime_max_seconds: u64,
    pub remote_activation_stop_timeout_seconds: u64,
    pub parent_settle_timeout_seconds: u64,
    pub parent_snapshot_ready_timeout_seconds: u64,
    pub parent_snapshot_ready_interval_seconds: u64,
    pub parent_readiness_slow_seconds: u64,
    pub repo_root_lock_timeout_seconds: u64,
    pub state_lock_timeout_seconds: u64,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            build_plan_cache: true,
            build_plan_cache_dir: None,
            build_heartbeat_seconds: 30,
            activation_heartbeat_seconds: 30,
            local_self_target: LocalSelfTarget::Auto,
            transport_retry_attempts: 3,
            transport_retry_delay_seconds: 2,
            ssh_connect_timeout_seconds: 30,
            ssh_server_alive_interval_seconds: 5,
            ssh_server_alive_count_max: 3,
            ssh_control_persist_seconds: 120,
            remote_read_timeout_seconds: 20,
            remote_activation_runtime_max_seconds: 1200,
            remote_activation_stop_timeout_seconds: 180,
            parent_settle_timeout_seconds: 180,
            parent_snapshot_ready_timeout_seconds: 45,
            parent_snapshot_ready_interval_seconds: 5,
            parent_readiness_slow_seconds: 10,
            repo_root_lock_timeout_seconds: 60,
            state_lock_timeout_seconds: 30,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Environment {
    values: BTreeMap<String, String>,
}

#[derive(Clone, Debug)]
pub(crate) struct Defaults {
    pub options: Options,
    pub jobs_per_domain_explicit: bool,
}

impl Environment {
    pub fn current() -> Self {
        Self::from_map(env::vars().collect())
    }

    pub fn from_map(values: BTreeMap<String, String>) -> Self {
        Self { values }
    }

    pub fn settings(&self) -> Result<Settings> {
        let defaults = Settings::default();
        Ok(Settings {
            build_plan_cache: self.boolean("NIXBOT_BUILD_PLAN_CACHE", defaults.build_plan_cache)?,
            build_plan_cache_dir: self.path("NIXBOT_BUILD_PLAN_CACHE_DIR"),
            build_heartbeat_seconds: self.non_negative(
                "NIXBOT_BUILD_HEARTBEAT_SECS",
                defaults.build_heartbeat_seconds,
            )?,
            activation_heartbeat_seconds: self.non_negative(
                "NIXBOT_ACTIVATION_HEARTBEAT_SECS",
                defaults.activation_heartbeat_seconds,
            )?,
            local_self_target: match self.value("NIXBOT_LOCAL_SELF_TARGET").unwrap_or("auto") {
                "auto" => LocalSelfTarget::Auto,
                "on" => LocalSelfTarget::On,
                "off" => LocalSelfTarget::Off,
                value => bail!("NIXBOT_LOCAL_SELF_TARGET has unsupported value: {value}"),
            },
            transport_retry_attempts: self.positive(
                "NIXBOT_TRANSPORT_RETRY_ATTEMPTS",
                defaults.transport_retry_attempts,
            )?,
            transport_retry_delay_seconds: self.non_negative(
                "NIXBOT_TRANSPORT_RETRY_DELAY_SECS",
                defaults.transport_retry_delay_seconds,
            )?,
            ssh_connect_timeout_seconds: self.positive(
                "NIXBOT_SSH_CONNECT_TIMEOUT_SECS",
                defaults.ssh_connect_timeout_seconds as usize,
            )? as u64,
            ssh_server_alive_interval_seconds: self.positive(
                "NIXBOT_SSH_SERVER_ALIVE_INTERVAL_SECS",
                defaults.ssh_server_alive_interval_seconds as usize,
            )? as u64,
            ssh_server_alive_count_max: self.positive(
                "NIXBOT_SSH_SERVER_ALIVE_COUNT_MAX",
                defaults.ssh_server_alive_count_max,
            )?,
            ssh_control_persist_seconds: self.positive(
                "NIXBOT_CONTROL_PERSIST_SECS",
                defaults.ssh_control_persist_seconds as usize,
            )? as u64,
            remote_read_timeout_seconds: self.positive(
                "NIXBOT_REMOTE_READ_TIMEOUT_SECS",
                defaults.remote_read_timeout_seconds as usize,
            )? as u64,
            remote_activation_runtime_max_seconds: self.positive(
                "NIXBOT_REMOTE_ACTIVATION_RUNTIME_MAX_SECS",
                defaults.remote_activation_runtime_max_seconds as usize,
            )? as u64,
            remote_activation_stop_timeout_seconds: self.positive(
                "NIXBOT_REMOTE_ACTIVATION_STOP_TIMEOUT_SECS",
                defaults.remote_activation_stop_timeout_seconds as usize,
            )? as u64,
            parent_settle_timeout_seconds: self.positive(
                "NIXBOT_PARENT_SETTLE_TIMEOUT",
                defaults.parent_settle_timeout_seconds as usize,
            )? as u64,
            parent_snapshot_ready_timeout_seconds: self.positive(
                "NIXBOT_PARENT_SNAPSHOT_READY_TIMEOUT",
                defaults.parent_snapshot_ready_timeout_seconds as usize,
            )? as u64,
            parent_snapshot_ready_interval_seconds: self.positive(
                "NIXBOT_PARENT_SNAPSHOT_READY_INTERVAL_SECS",
                defaults.parent_snapshot_ready_interval_seconds as usize,
            )? as u64,
            parent_readiness_slow_seconds: self.non_negative(
                "NIXBOT_PARENT_READINESS_SLOW_SECS",
                defaults.parent_readiness_slow_seconds,
            )?,
            repo_root_lock_timeout_seconds: self.positive(
                "NIXBOT_REPO_ROOT_LOCK_TIMEOUT",
                defaults.repo_root_lock_timeout_seconds as usize,
            )? as u64,
            state_lock_timeout_seconds: self.positive(
                "NIXBOT_STATE_LOCK_TIMEOUT",
                defaults.state_lock_timeout_seconds as usize,
            )? as u64,
        })
    }

    pub(crate) fn defaults(&self) -> Result<Defaults> {
        // Validate operational settings together with public options. This keeps
        // malformed NIXBOT_* input from becoming action-dependent.
        self.settings()?;
        let mut options = Options::default();
        options.hosts = self.owned("NIXBOT_HOSTS");
        options.groups = self
            .value("NIXBOT_GROUPS")
            .map(split_values)
            .unwrap_or_default();
        options.nix_config = self.owned("NIXBOT_NIX_CONFIG");
        options.sha = self.owned("NIXBOT_SHA");
        options.goal = self
            .value("NIXBOT_GOAL")
            .map(parse_goal)
            .transpose()?
            .unwrap_or_default();
        options.build_host = self.owned("NIXBOT_BUILD_HOST");
        options.build_host_explicit = self.values.contains_key("NIXBOT_BUILD_HOST");
        options.build_host_deploy_mode = self
            .value("NIXBOT_BUILD_HOST_DEPLOY_MODE")
            .map(parse_build_host_deploy_mode)
            .transpose()?
            .unwrap_or_default();
        options.build_cache_url = self.owned("NIXBOT_BUILD_CACHE_URL");
        options.build_cache_host = self.owned("NIXBOT_BUILD_CACHE_HOST");
        options.build_plan_jobs = self
            .value("NIXBOT_BUILD_PLAN_JOBS")
            .map(parse_job_count)
            .transpose()?
            .unwrap_or_default();
        options.build_jobs = self.positive("NIXBOT_BUILD_JOBS", options.build_jobs)?;
        options.build_logs = self.boolean("NIXBOT_BUILD_LOGS", options.build_logs)?;
        options.deploy_jobs = self.positive("NIXBOT_JOBS", options.deploy_jobs)?;
        let jobs_per_domain_explicit = self.values.contains_key("NIXBOT_JOBS_PER_DOMAIN");
        options.deploy_jobs_per_domain = if jobs_per_domain_explicit {
            self.positive("NIXBOT_JOBS_PER_DOMAIN", options.deploy_jobs_per_domain)?
        } else {
            options.deploy_jobs
        };
        options.deploy_jobs_per_domain_explicit = jobs_per_domain_explicit;
        options.verify_jobs = self.positive("NIXBOT_VERIFY_JOBS", options.verify_jobs)?;
        options.force = self.boolean("NIXBOT_FORCE", false)?;
        options.restart_managed = self.boolean("NIXBOT_RESTART_MANAGED", false)?;
        options.bootstrap = self.boolean("NIXBOT_BOOTSTRAP", false)?;
        options.control_plane_first = self.boolean("NIXBOT_CONTROL_PLANE_FIRST", false)?;
        options.skip_global_lock = self.boolean("NIXBOT_SKIP_GLOBAL_LOCK", false)?;
        options.dirty = self.boolean("NIXBOT_DIRTY", false)?;
        options.dirty_staged = self.boolean("NIXBOT_DIRTY_STAGED", false)?;
        options.dirty |= options.dirty_staged;
        options.dry_run = self.boolean("NIXBOT_DRY", false)?;
        options.no_rollback = self.boolean("NIXBOT_NO_ROLLBACK", false)?;
        options.no_verify = self.boolean("NIXBOT_NO_VERIFY", false)?;
        options.prefix_host_logs = self.boolean("NIXBOT_PREFIX_HOST_LOGS", false)?;
        options.prefix_host_logs_explicit = self.values.contains_key("NIXBOT_PREFIX_HOST_LOGS");
        options.verbose = self.boolean("NIXBOT_VERBOSE", false)?;
        options.log_format = self
            .value("NIXBOT_LOG_FORMAT")
            .map(parse_log_format)
            .transpose()?
            .unwrap_or_default();
        options.user = self.owned("NIXBOT_USER");
        options.ssh_key = self.path("NIXBOT_SSH_KEY");
        options.operator_user = self.owned("NIXBOT_OPERATOR_USER");
        options.operator_key = self.path("NIXBOT_OPERATOR_KEY");
        options.bootstrap_key = self.path("NIXBOT_BOOTSTRAP_KEY");
        options.known_hosts = self.owned("NIXBOT_SSH_KNOWN_HOSTS");
        options.config = self.path("NIXBOT_CONFIG");
        options.age_key_file = self.path("AGE_KEY_FILE");
        options.discover_keys = self
            .value("NIXBOT_DISCOVER_KEYS")
            .map(parse_discover_keys)
            .transpose()?
            .unwrap_or_default();
        options.repo_url = self.owned("NIXBOT_REPO_URL");
        options.repo_path = self.path("NIXBOT_REPO_PATH");
        options.use_repo_script = self.boolean("NIXBOT_USE_REPO_SCRIPT", false)?;
        options.ci_check_ssh_key_path = self.path("NIXBOT_CI_SSH_KEY_PATH");
        options.ci_trigger = self.boolean("NIXBOT_CI_TRIGGER", false)?;
        options.ci_host = self.owned("NIXBOT_CI_HOST");
        options.ci_user = self
            .owned("NIXBOT_CI_USER")
            .or_else(|| Some("nixbot".to_owned()));
        options.ci_ssh_key = self.owned("NIXBOT_CI_SSH_KEY");
        options.ci_known_hosts = self.owned("NIXBOT_CI_KNOWN_HOSTS");
        Ok(Defaults {
            options,
            jobs_per_domain_explicit,
        })
    }

    fn value(&self, name: &str) -> Option<&str> {
        self.values
            .get(name)
            .map(String::as_str)
            .filter(|v| !v.is_empty())
    }

    fn owned(&self, name: &str) -> Option<String> {
        self.value(name).map(str::to_owned)
    }

    fn path(&self, name: &str) -> Option<PathBuf> {
        self.value(name).map(PathBuf::from)
    }

    fn boolean(&self, name: &str, default: bool) -> Result<bool> {
        let Some(value) = self.values.get(name) else {
            return Ok(default);
        };
        match value.as_str() {
            "1" | "true" | "TRUE" | "yes" | "YES" | "on" | "ON" => Ok(true),
            "" | "0" | "false" | "FALSE" | "no" | "NO" | "off" | "OFF" => Ok(false),
            value => bail!("{name} has unsupported boolean value: {value}"),
        }
    }

    fn positive<T>(&self, name: &str, default: T) -> Result<T>
    where
        T: TryFrom<usize> + Copy,
    {
        let Some(value) = self.value(name) else {
            return Ok(default);
        };
        let parsed = value
            .parse::<usize>()
            .ok()
            .filter(|value| *value > 0)
            .ok_or_else(|| anyhow::anyhow!("{name} must be a positive integer"))?;
        T::try_from(parsed).map_err(|_| anyhow::anyhow!("{name} is too large"))
    }

    fn non_negative(&self, name: &str, default: u64) -> Result<u64> {
        self.value(name)
            .map(|value| {
                value
                    .parse::<u64>()
                    .map_err(|_| anyhow::anyhow!("{name} must be a non-negative integer"))
            })
            .transpose()
            .map(|value| value.unwrap_or(default))
    }
}

fn split_values(raw: &str) -> Vec<String> {
    raw.split([',', ' ', '\t', '\n'])
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .collect()
}

fn parse_goal(value: &str) -> Result<ActivationGoal> {
    match value {
        "switch" => Ok(ActivationGoal::Switch),
        "boot" => Ok(ActivationGoal::Boot),
        "test" => Ok(ActivationGoal::Test),
        "dry-activate" => Ok(ActivationGoal::DryActivate),
        _ => bail!("NIXBOT_GOAL has unsupported value: {value}"),
    }
}

fn parse_build_host_deploy_mode(value: &str) -> Result<BuildHostDeployMode> {
    match value {
        "auto" => Ok(BuildHostDeployMode::Auto),
        "cache" => Ok(BuildHostDeployMode::Cache),
        "local-copy" => Ok(BuildHostDeployMode::LocalCopy),
        _ => bail!("NIXBOT_BUILD_HOST_DEPLOY_MODE has unsupported value: {value}"),
    }
}

fn parse_job_count(value: &str) -> Result<JobCount> {
    if value == "auto" {
        Ok(JobCount::Auto)
    } else {
        value
            .parse::<usize>()
            .ok()
            .filter(|value| *value > 0)
            .map(JobCount::Count)
            .ok_or_else(|| {
                anyhow::anyhow!("NIXBOT_BUILD_PLAN_JOBS must be auto or a positive integer")
            })
    }
}

fn parse_log_format(value: &str) -> Result<LogFormat> {
    match value {
        "auto" => Ok(LogFormat::Auto),
        "gh" | "github-actions" => Ok(LogFormat::GithubActions),
        "plain" => Ok(LogFormat::Plain),
        _ => bail!("NIXBOT_LOG_FORMAT has unsupported value: {value}"),
    }
}

fn parse_discover_keys(value: &str) -> Result<DiscoverKeys> {
    match value {
        "auto" => Ok(DiscoverKeys::Auto),
        "on" => Ok(DiscoverKeys::On),
        "off" => Ok(DiscoverKeys::Off),
        _ => bail!("NIXBOT_DISCOVER_KEYS has unsupported value: {value}"),
    }
}
