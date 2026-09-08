use std::path::PathBuf;

use anyhow::{Result, bail};

use super::environment::Environment;
use super::inventory::validate_host_name;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Action {
    Help,
    Deps,
    CheckDeps,
    Version,
    RepoSync,
    ListHosts,
    ListGroups,
    Run,
    Deploy,
    Build,
    DevBuild,
    TerraformAll,
    TerraformDns,
    TerraformPlatform,
    TerraformApps,
    TerraformProject(String),
    CheckBootstrap,
    Clean(CleanMode),
    Tofu(Vec<String>),
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum CleanMode {
    #[default]
    Auto,
    All,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum ActivationGoal {
    #[default]
    Switch,
    Boot,
    Test,
    DryActivate,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum BuildHostDeployMode {
    #[default]
    Auto,
    Cache,
    LocalCopy,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum JobCount {
    #[default]
    Auto,
    Count(usize),
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum LogFormat {
    #[default]
    Auto,
    GithubActions,
    Plain,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum DiscoverKeys {
    #[default]
    Auto,
    On,
    Off,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Options {
    pub sha: Option<String>,
    pub host: Option<String>,
    pub hosts: Option<String>,
    pub groups: Vec<String>,
    pub nix_config: Option<String>,
    pub goal: ActivationGoal,
    pub build_host: Option<String>,
    pub build_host_explicit: bool,
    pub build_host_deploy_mode: BuildHostDeployMode,
    pub build_cache_url: Option<String>,
    pub build_cache_host: Option<String>,
    pub build_plan_jobs: JobCount,
    pub build_jobs: usize,
    pub build_logs: bool,
    pub deploy_jobs: usize,
    pub deploy_jobs_per_domain: usize,
    pub deploy_jobs_per_domain_explicit: bool,
    pub verify_jobs: usize,
    pub force: bool,
    pub restart_managed: bool,
    pub bootstrap: bool,
    pub control_plane_first: bool,
    pub skip_global_lock: bool,
    pub dirty: bool,
    pub dirty_staged: bool,
    pub dirty_staged_patch_stdin: bool,
    pub dirty_staged_base: Option<String>,
    pub dry_run: bool,
    pub no_override: bool,
    pub no_rollback: bool,
    pub no_verify: bool,
    pub prefix_host_logs: bool,
    pub prefix_host_logs_explicit: bool,
    pub verbose: bool,
    pub log_format: LogFormat,
    pub user: Option<String>,
    pub ssh_key: Option<PathBuf>,
    pub operator_user: Option<String>,
    pub operator_key: Option<PathBuf>,
    pub bootstrap_key: Option<PathBuf>,
    pub known_hosts: Option<String>,
    pub config: Option<PathBuf>,
    pub age_key_file: Option<PathBuf>,
    pub discover_keys: DiscoverKeys,
    pub repo_url: Option<String>,
    pub repo_path: Option<PathBuf>,
    pub use_repo_script: bool,
    pub ci_check_ssh_key_path: Option<PathBuf>,
    pub ci_trigger: bool,
    pub ci_host: Option<String>,
    pub ci_user: Option<String>,
    pub ci_ssh_key: Option<String>,
    pub ci_known_hosts: Option<String>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            sha: None,
            host: None,
            hosts: None,
            groups: Vec::new(),
            nix_config: None,
            goal: ActivationGoal::Switch,
            build_host: None,
            build_host_explicit: false,
            build_host_deploy_mode: BuildHostDeployMode::Auto,
            build_cache_url: None,
            build_cache_host: None,
            build_plan_jobs: JobCount::Auto,
            build_jobs: 1,
            build_logs: false,
            deploy_jobs: 8,
            deploy_jobs_per_domain: 8,
            deploy_jobs_per_domain_explicit: false,
            verify_jobs: 16,
            force: false,
            restart_managed: false,
            bootstrap: false,
            control_plane_first: false,
            skip_global_lock: false,
            dirty: false,
            dirty_staged: false,
            dirty_staged_patch_stdin: false,
            dirty_staged_base: None,
            dry_run: false,
            no_override: false,
            no_rollback: false,
            no_verify: false,
            prefix_host_logs: false,
            prefix_host_logs_explicit: false,
            verbose: false,
            log_format: LogFormat::Auto,
            user: None,
            ssh_key: None,
            operator_user: None,
            operator_key: None,
            bootstrap_key: None,
            known_hosts: None,
            config: None,
            age_key_file: None,
            discover_keys: DiscoverKeys::Auto,
            repo_url: None,
            repo_path: None,
            use_repo_script: false,
            ci_check_ssh_key_path: None,
            ci_trigger: false,
            ci_host: None,
            ci_user: None,
            ci_ssh_key: None,
            ci_known_hosts: None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Invocation {
    pub action: Action,
    pub options: Options,
}

impl Invocation {
    pub fn parse_legacy<I, S>(arguments: I) -> Result<Self>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self::parse_legacy_with_defaults(arguments, Options::default(), false)
    }

    pub fn parse_legacy_with_environment<I, S>(
        arguments: I,
        environment: &Environment,
    ) -> Result<Self>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let defaults = environment.defaults()?;
        Self::parse_legacy_with_defaults(
            arguments,
            defaults.options,
            defaults.jobs_per_domain_explicit,
        )
    }

    fn parse_legacy_with_defaults<I, S>(
        arguments: I,
        options: Options,
        jobs_per_domain_explicit: bool,
    ) -> Result<Self>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut arguments = arguments.into_iter().map(Into::into).collect::<Vec<_>>();
        if arguments.first().is_some_and(|value| {
            value == "nixbot" || value.ends_with("/nixbot") || value.ends_with("/nixbot.sh")
        }) {
            arguments.remove(0);
        }
        let Some(first) = arguments.first().cloned() else {
            return Ok(Self {
                action: Action::Help,
                options,
            });
        };
        let (action, consumed) = match first.as_str() {
            "help" | "-h" | "--help" => (Action::Help, 1),
            "deps" | "check-deps" | "version"
                if arguments
                    .get(1)
                    .is_some_and(|value| matches!(value.as_str(), "-h" | "--help")) =>
            {
                (Action::Help, 2)
            }
            "deps" => (Action::Deps, 1),
            "check-deps" => (Action::CheckDeps, 1),
            "version" => (Action::Version, 1),
            "repo" if arguments.get(1).is_some_and(|value| value == "sync") => {
                (Action::RepoSync, 2)
            }
            "--list-hosts" => (Action::ListHosts, 1),
            "--list-groups" => (Action::ListGroups, 1),
            "run" => (Action::Run, 1),
            "deploy" => (Action::Deploy, 1),
            "build" => (Action::Build, 1),
            "dev-build" => (Action::DevBuild, 1),
            "tf" => (Action::TerraformAll, 1),
            "tf-dns" => (Action::TerraformDns, 1),
            "tf-platform" => (Action::TerraformPlatform, 1),
            "tf-apps" => (Action::TerraformApps, 1),
            "check-bootstrap" => (Action::CheckBootstrap, 1),
            "clean" => {
                let mode = arguments
                    .get(1)
                    .filter(|value| !value.starts_with('-'))
                    .map(|value| parse_clean_mode(value))
                    .transpose()?
                    .unwrap_or_default();
                (
                    Action::Clean(mode),
                    usize::from(
                        arguments
                            .get(1)
                            .is_some_and(|value| !value.starts_with('-')),
                    ) + 1,
                )
            }
            "--clean" => {
                let mode = arguments
                    .get(1)
                    .filter(|value| !value.starts_with('-'))
                    .map(|value| parse_clean_mode(value))
                    .transpose()?
                    .unwrap_or_default();
                (
                    Action::Clean(mode),
                    usize::from(
                        arguments
                            .get(1)
                            .is_some_and(|value| !value.starts_with('-')),
                    ) + 1,
                )
            }
            value if value.starts_with("--clean=") => {
                (Action::Clean(parse_clean_mode(&value[8..])?), 1)
            }
            value if value.starts_with("tf/") && value.len() > 3 => {
                (Action::TerraformProject(value[3..].to_owned()), 1)
            }
            "tofu" => {
                return Ok(Self {
                    action: Action::Tofu(arguments[1..].to_vec()),
                    options,
                });
            }
            _ => bail!("unknown nixbot action: {first}"),
        };
        if arguments[consumed..]
            .iter()
            .any(|value| matches!(value.as_str(), "-h" | "--help"))
        {
            return Ok(Self {
                action: Action::Help,
                options,
            });
        }
        let mut action = action;
        let options = parse_options(
            &arguments[consumed..],
            &mut action,
            options,
            jobs_per_domain_explicit,
        )?;
        let mut options = options;
        enable_parallel_log_prefixes(&mut options);
        validate(&action, &options)?;
        Ok(Self { action, options })
    }

    pub fn parse_canonical<I, S>(arguments: I) -> Result<Self>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self::parse_canonical_with_defaults(arguments, Options::default(), false)
    }

    pub fn parse_canonical_with_environment<I, S>(
        arguments: I,
        environment: &Environment,
    ) -> Result<Self>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let defaults = environment.defaults()?;
        Self::parse_canonical_with_defaults(
            arguments,
            defaults.options,
            defaults.jobs_per_domain_explicit,
        )
    }

    fn parse_canonical_with_defaults<I, S>(
        arguments: I,
        options: Options,
        jobs_per_domain_explicit: bool,
    ) -> Result<Self>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut arguments = arguments.into_iter().map(Into::into).collect::<Vec<_>>();
        if arguments.first().is_some_and(|value| value == "fleet") {
            arguments.remove(0);
        }
        let Some(first) = arguments.first().cloned() else {
            return Ok(Self {
                action: Action::Help,
                options,
            });
        };
        let (action, consumed) = match first.as_str() {
            "help" | "-h" | "--help" => (Action::Help, 1),
            "deps" => (Action::Deps, 1),
            "check-deps" => (Action::CheckDeps, 1),
            "version" => (Action::Version, 1),
            "hosts" => (Action::ListHosts, 1),
            "groups" => (Action::ListGroups, 1),
            "run" => (Action::Run, 1),
            "deploy" => (Action::Deploy, 1),
            "build" => (Action::Build, 1),
            "dev-build" => (Action::DevBuild, 1),
            "check-bootstrap" => (Action::CheckBootstrap, 1),
            "repo" if arguments.get(1).is_some_and(|value| value == "sync") => {
                (Action::RepoSync, 2)
            }
            "terraform" => match arguments.get(1).map(String::as_str) {
                Some("all") => (Action::TerraformAll, 2),
                Some("dns") => (Action::TerraformDns, 2),
                Some("platform") => (Action::TerraformPlatform, 2),
                Some("apps") => (Action::TerraformApps, 2),
                Some("project") => {
                    let project = arguments
                        .get(2)
                        .filter(|value| !value.is_empty())
                        .ok_or_else(|| anyhow::anyhow!("terraform project requires a name"))?;
                    (Action::TerraformProject(project.clone()), 3)
                }
                _ => bail!("terraform requires all, dns, platform, apps, or project NAME"),
            },
            "clean" => {
                let mode = arguments
                    .get(1)
                    .filter(|value| !value.starts_with('-'))
                    .map(|value| parse_clean_mode(value))
                    .transpose()?
                    .unwrap_or_default();
                (
                    Action::Clean(mode),
                    usize::from(
                        arguments
                            .get(1)
                            .is_some_and(|value| !value.starts_with('-')),
                    ) + 1,
                )
            }
            "tofu" => {
                return Ok(Self {
                    action: Action::Tofu(arguments[1..].to_vec()),
                    options,
                });
            }
            _ => bail!("unknown fleet action: {first}"),
        };
        if arguments[consumed..]
            .iter()
            .any(|value| matches!(value.as_str(), "-h" | "--help"))
        {
            return Ok(Self {
                action: Action::Help,
                options,
            });
        }
        let mut action = action;
        let mut options = parse_options(
            &arguments[consumed..],
            &mut action,
            options,
            jobs_per_domain_explicit,
        )?;
        enable_parallel_log_prefixes(&mut options);
        validate(&action, &options)?;
        Ok(Self { action, options })
    }
}

fn parse_options(
    arguments: &[String],
    action: &mut Action,
    mut options: Options,
    mut deploy_jobs_per_domain_explicit: bool,
) -> Result<Options> {
    let mut group_from_flag = false;
    let mut host_from_flag = false;
    let mut hosts_from_flag = false;
    let mut index = 0;
    while index < arguments.len() {
        let argument = &arguments[index];
        let (name, attached) = argument
            .split_once('=')
            .map_or((argument.as_str(), None), |(name, value)| {
                (name, Some(value))
            });
        let mut value = || -> Result<String> {
            if let Some(value) = attached {
                if value.is_empty() {
                    bail!("{name} requires a value");
                }
                return Ok(value.to_owned());
            }
            index += 1;
            arguments
                .get(index)
                .filter(|value| !value.is_empty())
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("{name} requires a value"))
        };
        match name {
            "--sha" => options.sha = Some(value()?),
            "--host" => {
                if hosts_from_flag {
                    bail!("use either --host or --hosts, not both");
                }
                options.host = Some(value()?);
                options.hosts = None;
                host_from_flag = true;
            }
            "--hosts" => {
                if host_from_flag {
                    bail!("use either --host or --hosts, not both");
                }
                options.hosts = Some(value()?);
                options.host = None;
                hosts_from_flag = true;
            }
            "--group" => {
                if !group_from_flag {
                    options.groups.clear();
                    group_from_flag = true;
                }
                options.groups.extend(split_values(&value()?));
            }
            "--nix-config" => options.nix_config = Some(value()?),
            "--goal" => options.goal = parse_goal(&value()?)?,
            "--build-host" => {
                options.build_host = Some(value()?);
                options.build_host_explicit = true;
            }
            "--build-host-deploy-mode" => {
                options.build_host_deploy_mode = parse_build_host_deploy_mode(&value()?)?
            }
            "--build-cache-url" => options.build_cache_url = Some(value()?),
            "--build-cache-host" => options.build_cache_host = Some(value()?),
            "--build-plan-jobs" => options.build_plan_jobs = parse_job_count(&value()?)?,
            "--build-jobs" => options.build_jobs = positive(&value()?, name)?,
            "--deploy-jobs" => {
                options.deploy_jobs = positive(&value()?, name)?;
                if !deploy_jobs_per_domain_explicit {
                    options.deploy_jobs_per_domain = options.deploy_jobs;
                }
            }
            "--deploy-jobs-per-domain" => {
                options.deploy_jobs_per_domain = positive(&value()?, name)?;
                deploy_jobs_per_domain_explicit = true;
                options.deploy_jobs_per_domain_explicit = true;
            }
            "--verify-jobs" => options.verify_jobs = positive(&value()?, name)?,
            "--log-format" => options.log_format = parse_log_format(&value()?)?,
            "--user" => set_once(&mut options.user, value()?, "user")?,
            "--ssh-key" => set_once(&mut options.ssh_key, PathBuf::from(value()?), "SSH key")?,
            "--operator-user" => set_once(&mut options.operator_user, value()?, "operator user")?,
            "--operator-key" => set_once(
                &mut options.operator_key,
                PathBuf::from(value()?),
                "operator key",
            )?,
            "--bootstrap-key" => options.bootstrap_key = Some(PathBuf::from(value()?)),
            "--known-hosts" => options.known_hosts = Some(value()?),
            "--config" => options.config = Some(PathBuf::from(value()?)),
            "--age-key-file" => options.age_key_file = Some(PathBuf::from(value()?)),
            "--discover-keys" => {
                options.discover_keys =
                    attached.map_or(Ok(DiscoverKeys::On), parse_discover_keys)?
            }
            "--no-discover-keys" => options.discover_keys = DiscoverKeys::Off,
            "--repo-url" => options.repo_url = Some(value()?),
            "--repo-path" => options.repo_path = Some(PathBuf::from(value()?)),
            "--ci-check-ssh-key-path" => {
                options.ci_check_ssh_key_path = Some(PathBuf::from(value()?))
            }
            "--ci-host" => options.ci_host = Some(value()?),
            "--ci-user" => options.ci_user = Some(value()?),
            "--ci-ssh-key" => options.ci_ssh_key = Some(value()?),
            "--ci-known-hosts" => options.ci_known_hosts = Some(value()?),
            "--dirty-staged-base" => options.dirty_staged_base = Some(value()?),
            "--clean" => {
                let mode = match attached {
                    Some(value) => parse_clean_mode(value)?,
                    None if arguments
                        .get(index + 1)
                        .is_some_and(|value| !value.starts_with('-')) =>
                    {
                        index += 1;
                        parse_clean_mode(&arguments[index])?
                    }
                    None => CleanMode::Auto,
                };
                *action = Action::Clean(mode);
            }
            "--build-logs" => options.build_logs = true,
            "--no-build-logs" => options.build_logs = false,
            "--force" => options.force = true,
            "--restart-managed" => options.restart_managed = true,
            "--bootstrap" => options.bootstrap = true,
            "--control-plane-first" => options.control_plane_first = true,
            "--skip-global-lock" => options.skip_global_lock = true,
            "--dirty" => options.dirty = true,
            "--dirty-staged" => {
                options.dirty = true;
                options.dirty_staged = true;
            }
            "--dirty-staged-patch-stdin" => options.dirty_staged_patch_stdin = true,
            "--dry" => options.dry_run = true,
            "--no-override" => options.no_override = true,
            "--no-rollback" => options.no_rollback = true,
            "--no-verify" => options.no_verify = true,
            "--prefix-host-logs" => {
                options.prefix_host_logs = true;
                options.prefix_host_logs_explicit = true;
            }
            "--verbose" => options.verbose = true,
            "--quiet" => options.verbose = false,
            "--use-repo-script" => options.use_repo_script = true,
            "--ci-trigger" => options.ci_trigger = true,
            _ => bail!("unknown option: {argument}"),
        }
        index += 1;
    }
    options.deploy_jobs_per_domain_explicit = deploy_jobs_per_domain_explicit;
    Ok(options)
}

fn enable_parallel_log_prefixes(options: &mut Options) {
    if options.prefix_host_logs_explicit {
        return;
    }
    options.prefix_host_logs = matches!(
        options.build_plan_jobs,
        JobCount::Auto | JobCount::Count(2..)
    ) || options.build_jobs > 1
        || options.deploy_jobs > 1
        || options.verify_jobs > 1;
}

fn validate(action: &Action, options: &Options) -> Result<()> {
    if options.host.is_some() && options.hosts.is_some() {
        bail!("use either --host or --hosts, not both");
    }
    if let Some(host) = &options.host {
        validate_host_name(host)?;
        if host == "all" {
            bail!("--host requires one exact host; use --hosts=all for fleet selection");
        }
    }
    if let Some(configuration) = &options.nix_config {
        validate_host_name(configuration)?;
        let selectors = options
            .host
            .clone()
            .into_iter()
            .chain(options.hosts.iter().flat_map(|value| split_values(value)))
            .filter(|value| !value.starts_with('-'))
            .collect::<Vec<_>>();
        if selectors.len() != 1 || selectors[0] == "all" || contains_glob(&selectors[0]) {
            bail!("--nix-config requires exactly one positive, exact host selector");
        }
    }
    if options.restart_managed {
        if !matches!(action, Action::Run | Action::Deploy) {
            bail!("--restart-managed requires the run or deploy action");
        }
        if !matches!(options.goal, ActivationGoal::Switch | ActivationGoal::Test) {
            bail!("--restart-managed requires --goal switch or --goal test");
        }
    }
    if matches!(action, Action::DevBuild) && options.sha.is_some() {
        bail!("dev-build uses the current local checkout; --sha is unsupported");
    }
    if matches!(action, Action::Clean(_)) && options.sha.is_some() {
        bail!("clean uses the current checkout; --sha is unsupported");
    }
    if matches!(action, Action::ListHosts | Action::ListGroups) && options.sha.is_some() {
        bail!("inventory listing uses the current checkout; --sha is unsupported");
    }
    if options.ci_trigger
        && matches!(
            action,
            Action::DevBuild | Action::ListHosts | Action::ListGroups | Action::Tofu(_)
        )
    {
        bail!("selected action is local-only and cannot run through --ci-trigger");
    }
    Ok(())
}

fn parse_clean_mode(value: &str) -> Result<CleanMode> {
    match value {
        "auto" => Ok(CleanMode::Auto),
        "all" => Ok(CleanMode::All),
        _ => bail!("unsupported clean mode: {value}"),
    }
}

fn parse_goal(value: &str) -> Result<ActivationGoal> {
    match value {
        "switch" => Ok(ActivationGoal::Switch),
        "boot" => Ok(ActivationGoal::Boot),
        "test" => Ok(ActivationGoal::Test),
        "dry-activate" => Ok(ActivationGoal::DryActivate),
        _ => bail!("unsupported activation goal: {value}"),
    }
}

fn parse_build_host_deploy_mode(value: &str) -> Result<BuildHostDeployMode> {
    match value {
        "auto" => Ok(BuildHostDeployMode::Auto),
        "cache" => Ok(BuildHostDeployMode::Cache),
        "local-copy" => Ok(BuildHostDeployMode::LocalCopy),
        _ => bail!("unsupported build-host deploy mode: {value}"),
    }
}

fn parse_job_count(value: &str) -> Result<JobCount> {
    if value == "auto" {
        Ok(JobCount::Auto)
    } else {
        Ok(JobCount::Count(positive(value, "job count")?))
    }
}

fn parse_log_format(value: &str) -> Result<LogFormat> {
    match value {
        "auto" => Ok(LogFormat::Auto),
        "gh" | "github-actions" => Ok(LogFormat::GithubActions),
        "plain" => Ok(LogFormat::Plain),
        _ => bail!("unsupported log format: {value}"),
    }
}

fn parse_discover_keys(value: &str) -> Result<DiscoverKeys> {
    match value {
        "auto" => Ok(DiscoverKeys::Auto),
        "on" => Ok(DiscoverKeys::On),
        "off" => Ok(DiscoverKeys::Off),
        _ => bail!("unsupported decrypt-key discovery mode: {value}"),
    }
}

fn positive(value: &str, name: &str) -> Result<usize> {
    let parsed = value
        .parse::<usize>()
        .map_err(|_| anyhow::anyhow!("{name} must be a positive integer"))?;
    if parsed == 0 {
        bail!("{name} must be a positive integer");
    }
    Ok(parsed)
}

fn set_once<T: Eq>(slot: &mut Option<T>, value: T, name: &str) -> Result<()> {
    if slot.as_ref().is_some_and(|existing| existing != &value) {
        bail!("conflicting {name} overrides");
    }
    *slot = Some(value);
    Ok(())
}

fn split_values(raw: &str) -> Vec<String> {
    raw.split([',', ' ', '\t', '\n'])
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .collect()
}

fn contains_glob(value: &str) -> bool {
    value.bytes().any(|byte| matches!(byte, b'*' | b'?' | b'['))
}
