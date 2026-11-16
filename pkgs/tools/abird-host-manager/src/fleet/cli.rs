use std::env;
use std::io::{self, IsTerminal};
use std::path::PathBuf;

use abird_host_agent::build_executor::strategy::{ExecutionStrategy, Strategy};
use anyhow::{Context, Result, bail};
use clap::builder::NonEmptyStringValueParser;
use clap::builder::styling::{AnsiColor, Styles};
use clap::{Arg, ArgAction, ArgMatches, ColorChoice, Command};
use serde::{Deserialize, Serialize};

use super::environment::Environment;
use super::inventory::validate_host_name;
use super::inventory_routing::{RouteRequest, RouteSource};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
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
    Prepare,
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

impl Action {
    pub fn uses_build_strategy(&self) -> bool {
        matches!(
            self,
            Self::Run | Self::Deploy | Self::Prepare | Self::Build | Self::DevBuild
        )
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum CleanMode {
    #[default]
    Auto,
    All,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum ActivationGoal {
    #[default]
    Switch,
    Boot,
    Test,
    DryActivate,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum BuildHostDeployMode {
    #[default]
    Auto,
    Cache,
    LocalCopy,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum JobCount {
    #[default]
    Auto,
    Count(usize),
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum LogFormat {
    #[default]
    Auto,
    GithubActions,
    Plain,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum DiscoverKeys {
    #[default]
    Auto,
    On,
    Off,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Options {
    pub sha: Option<String>,
    pub host: Option<String>,
    pub hosts: Option<String>,
    pub required_hosts: Vec<String>,
    pub groups: Vec<String>,
    pub nix_config: Option<String>,
    pub goal: ActivationGoal,
    pub strategy: Strategy,
    pub strategy_explicit: bool,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deploy_jobs_per_domain_max: Option<usize>,
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
    pub config_override: Option<PathBuf>,
    pub route: RouteRequest,
    pub route_source: RouteSource,
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
            required_hosts: Vec::new(),
            groups: Vec::new(),
            nix_config: None,
            goal: ActivationGoal::Switch,
            strategy: Strategy::Auto,
            strategy_explicit: false,
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
            deploy_jobs_per_domain_max: None,
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
            config_override: None,
            route: RouteRequest::Auto,
            route_source: RouteSource::Cli,
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

pub fn print_help() -> Result<()> {
    let mut command = fleet_command();
    command.print_help()?;
    println!();
    Ok(())
}

fn help_color_choice() -> ColorChoice {
    let disabled = env::var_os("NO_COLOR").is_some()
        || env::var("GITHUB_ACTIONS").as_deref() == Ok("true")
        || env::var_os("TERM")
            .is_some_and(|term| term.to_string_lossy().eq_ignore_ascii_case("dumb"));
    if io::stdout().is_terminal() && !disabled {
        ColorChoice::Always
    } else {
        ColorChoice::Never
    }
}

fn fleet_command() -> Command {
    let styles = Styles::styled()
        .header(AnsiColor::Cyan.on_default())
        .usage(AnsiColor::Cyan.on_default())
        .literal(AnsiColor::Green.on_default())
        .placeholder(AnsiColor::Yellow.on_default());
    let flag = |name: &'static str, help: &'static str| {
        Arg::new(name)
            .long(name)
            .action(ArgAction::SetTrue)
            .global(true)
            .help(help)
    };
    let value = |name: &'static str, value_name: &'static str, help: &'static str| {
        Arg::new(name)
            .long(name)
            .value_name(value_name)
            .num_args(1)
            .value_parser(NonEmptyStringValueParser::new())
            .action(ArgAction::Append)
            .global(true)
            .help(help)
    };

    Command::new("fleet")
        .bin_name("abird-host-manager fleet")
        .about("Build, deploy, verify, and maintain the managed host fleet")
        .long_about(
            "Build, deploy, prepare, inspect, and maintain the managed host fleet.\n\
             The legacy `nixbot` command remains an alias for this surface.",
        )
        .color(help_color_choice())
        .styles(styles)
        // Clap otherwise caps help layout at 100 columns, which can push an
        // entire option group into spacious next-line help because of one long
        // flag. Respect the real terminal width instead: wide terminals stay
        // dense, while Clap still wraps naturally on narrow terminals.
        .max_term_width(0)
        .disable_help_flag(true)
        .disable_help_subcommand(true)
        .arg(
            Arg::new("help-flag")
                .short('h')
                .long("help")
                .action(ArgAction::SetTrue)
                .global(true)
                .help("Show fleet help"),
        )
        .subcommand_help_heading("Commands")
        .subcommand(Command::new("help").about("Show fleet help"))
        .subcommand(Command::new("hosts").about("List the selected host topology"))
        .subcommand(Command::new("groups").about("List inventory groups"))
        .subcommand(Command::new("run").about("Run infrastructure and host deployment phases"))
        .subcommand(Command::new("deploy").about("Build, acquire, deploy, and verify hosts"))
        .subcommand(Command::new("prepare").about("Build and acquire hosts without activation"))
        .subcommand(Command::new("build").about("Build selected host systems"))
        .subcommand(Command::new("dev-build").about("Build the local development system"))
        .subcommand(Command::new("check-bootstrap").about("Check bootstrap access"))
        .subcommand(
            Command::new("clean")
                .about("Clean fleet runtime state")
                .arg(
                    Arg::new("mode")
                        .value_name("auto|all")
                        .value_parser(["auto", "all"])
                        .required(false),
                ),
        )
        .subcommand(
            Command::new("terraform")
                .about("Apply Terraform/OpenTofu fleet infrastructure")
                .subcommand(Command::new("all").about("Apply all infrastructure layers"))
                .subcommand(Command::new("dns").about("Apply DNS infrastructure"))
                .subcommand(Command::new("platform").about("Apply platform infrastructure"))
                .subcommand(Command::new("apps").about("Apply application infrastructure"))
                .subcommand(
                    Command::new("project")
                        .about("Apply one infrastructure project")
                        .arg(Arg::new("NAME").required(true)),
                ),
        )
        .subcommand(
            Command::new("repo")
                .about("Repository operations")
                .subcommand(Command::new("sync").about("Synchronize the fleet repository")),
        )
        .subcommand(
            Command::new("owned")
                .about("Operate a durable owned build/deployment run")
                .subcommand(Command::new("submit").about("Submit a private owned-build intent"))
                .subcommand(Command::new("status").about("Show durable run status"))
                .subcommand(Command::new("attach").about("Attach retained private material"))
                .subcommand(Command::new("cancel").about("Request durable cancellation"))
                .subcommand(Command::new("consume").about("Consume a settled run into deployment"))
                .subcommand(Command::new("retire").about("Retire a settled durable run"))
                .subcommand(Command::new("events").about("Read durable run events"))
                .subcommand(Command::new("logs").about("Read bounded lifecycle diagnostics"))
                .subcommand(Command::new("help").about("Show owned-run help")),
        )
        .subcommand(
            Command::new("tofu")
                .about("Pass arguments directly to OpenTofu")
                .arg(
                    Arg::new("ARGS")
                        .num_args(0..)
                        .trailing_var_arg(true)
                        .allow_hyphen_values(true),
                ),
        )
        .subcommand(Command::new("deps").about("Show required runtime dependencies"))
        .subcommand(Command::new("check-deps").about("Check required runtime dependencies"))
        .subcommand(Command::new("version").about("Show fleet compatibility version"))
        .next_help_heading("Selection")
        .arg(value("group", "GROUP", "Select an inventory group").action(ArgAction::Append))
        .arg(value("host", "HOST", "Select one exact host").conflicts_with("hosts"))
        .arg(value(
            "hosts",
            "SELECTORS",
            "Select hosts by selector expression",
        ))
        .arg(
            value(
                "require-hosts",
                "HOSTS",
                "Require selected deployment coverage for these hosts",
            )
            .action(ArgAction::Append),
        )
        .arg(value(
            "nix-config",
            "ATTR",
            "Select a Nix configuration attribute",
        ))
        .arg(value("sha", "REV", "Use an explicit repository revision"))
        .arg(flag(
            "control-plane-first",
            "Prioritize control-plane hosts where dependencies permit",
        ))
        .next_help_heading("Build")
        .arg(
            value(
                "strategy",
                "auto|nix|agent",
                "Build execution strategy (env: NIXBOT_STRATEGY)",
            )
            .value_parser(clap::builder::ValueParser::new(|value: &str| {
                Strategy::parse(value)
                    .map(|_| value.to_owned())
                    .map_err(|error| error.to_string())
            })),
        )
        .arg(value(
            "build-host",
            "HOST",
            "Use an explicit remote build host",
        ))
        .arg(
            value(
                "build-host-deploy-mode",
                "auto|cache|local-copy",
                "How remote build results reach deployment hosts",
            )
            .value_parser(["auto", "cache", "local-copy"]),
        )
        .arg(value(
            "build-cache-url",
            "URL",
            "Binary cache URL for build distribution",
        ))
        .arg(value(
            "build-cache-host",
            "HOST",
            "Host that serves the build cache",
        ))
        .arg(value(
            "build-plan-jobs",
            "N|auto",
            "Parallel build-plan evaluations",
        ))
        .arg(value("build-jobs", "N", "Parallel host builds"))
        .arg(flag("build-logs", "Show build process output").overrides_with("no-build-logs"))
        .arg(flag("no-build-logs", "Disable build process output").overrides_with("build-logs"))
        .next_help_heading("Deployment")
        .arg(
            value("goal", "switch|boot|test|dry-activate", "Activation goal").value_parser([
                "switch",
                "boot",
                "test",
                "dry-activate",
            ]),
        )
        .arg(value("deploy-jobs", "N", "Global deployment concurrency").visible_alias("jobs"))
        .arg(
            value(
                "deploy-jobs-per-domain",
                "N",
                "Initial deployment concurrency per domain",
            )
            .visible_alias("jobs-per-domain"),
        )
        .arg(
            value(
                "deploy-jobs-per-domain-max",
                "N",
                "Hard deployment concurrency ceiling per domain",
            )
            .visible_alias("jobs-per-domain-max")
            .help(
                "Hard deployment concurrency ceiling per domain (env: NIXBOT_JOBS_PER_DOMAIN_MAX)",
            ),
        )
        .arg(value(
            "verify-jobs",
            "N",
            "Parallel health verification jobs",
        ))
        .arg(flag("bootstrap", "Allow bootstrap deployment behavior"))
        .arg(flag(
            "no-rollback",
            "Disable rollback snapshots and automatic rollback",
        ))
        .arg(flag(
            "no-verify",
            "Skip post-deployment health verification",
        ))
        .arg(flag(
            "restart-managed",
            "Restart managed resources after activation",
        ))
        .next_help_heading("Repository")
        .arg(flag("dirty", "Allow execution from a dirty checkout"))
        .arg(flag(
            "dirty-staged",
            "Execute the staged repository state as an isolated source",
        ))
        .arg(value("repo-url", "URL", "Fleet repository URL"))
        .arg(value("repo-path", "PATH", "Fleet repository path"))
        .arg(flag(
            "ci-trigger",
            "Submit the fleet command to the CI controller",
        ))
        .next_help_heading("CI")
        .arg(value("ci-host", "HOST", "CI controller host"))
        .arg(value("ci-user", "USER", "CI controller SSH user"))
        .arg(value("ci-ssh-key", "KEY", "CI controller SSH key material"))
        .arg(value(
            "ci-known-hosts",
            "KNOWN_HOSTS",
            "Pinned CI controller known-hosts material",
        ))
        .arg(value(
            "ci-check-ssh-key-path",
            "PATH",
            "CI controller SSH key path used for connection checks",
        ))
        .next_help_heading("Behavior")
        .arg(flag("dry", "Plan without mutating deployment state"))
        .arg(flag("force", "Bypass eligible operator confirmations"))
        .arg(flag("skip-global-lock", "Skip the host-local action mutex"))
        .arg(
            value(
                "config-override",
                "PATH",
                "Use an explicit inventory override",
            )
            .conflicts_with("no-override"),
        )
        .arg(
            flag("no-override", "Disable implicit inventory overrides")
                .conflicts_with("config-override"),
        )
        .arg(
            value("route", "auto|default|cf|ts", "Select the transport route")
                .value_parser(["auto", "default", "cf", "ts"]),
        )
        .arg(flag(
            "prefix-host-logs",
            "Always prefix streamed logs with host identity",
        ))
        .arg(flag("verbose", "Show the live verbose log view").overrides_with("quiet"))
        .arg(flag("quiet", "Reduce nonessential output").overrides_with("verbose"))
        .arg(
            value("log-format", "auto|github-actions|plain", "Output format").value_parser([
                "auto",
                "gh",
                "github-actions",
                "plain",
            ]),
        )
        .next_help_heading("Authentication")
        .arg(value("user", "USER", "SSH user"))
        .arg(value("ssh-key", "PATH", "SSH identity key"))
        .arg(value("operator-user", "USER", "Fallback operator SSH user"))
        .arg(value("operator-key", "PATH", "Fallback operator SSH key"))
        .arg(value("bootstrap-key", "PATH", "Bootstrap SSH key"))
        .arg(value("known-hosts", "PATH", "Known-hosts material"))
        .arg(value("age-key-file", "PATH", "Age identity file"))
        .arg(
            Arg::new("discover-keys")
                .long("discover-keys")
                .value_name("auto|on|off")
                .num_args(0..=1)
                .default_missing_value("on")
                .require_equals(true)
                .value_parser(["auto", "on", "off"])
                .action(ArgAction::Append)
                .global(true)
                .overrides_with("no-discover-keys")
                .help("SSH key discovery policy"),
        )
        .arg(flag("no-discover-keys", "Disable SSH key discovery").overrides_with("discover-keys"))
        .arg(value("config", "PATH", "Fleet inventory configuration"))
        // Private/compatibility transports are parsed by the same grammar but
        // intentionally omitted from public help.
        .arg(value("dirty-staged-base", "REV", "staged source base").hide(true))
        .arg(flag("dirty-staged-patch-stdin", "read staged patch from stdin").hide(true))
        .arg(flag("use-repo-script", "compatibility repository re-exec").hide(true))
        .arg(
            Arg::new("clean-legacy")
                .long("clean")
                .value_name("auto|all")
                .num_args(0..=1)
                .default_missing_value("auto")
                .value_parser(["auto", "all"])
                .action(ArgAction::Append)
                .global(true)
                .hide(true),
        )
}

impl Options {
    /// Omit implicit auto for old controllers; preserve every explicit choice.
    pub fn forwarded_strategy(&self) -> Option<Strategy> {
        (self.strategy_explicit || self.strategy != Strategy::Auto).then_some(self.strategy)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Invocation {
    pub action: Action,
    pub options: Options,
}

impl Invocation {
    /// Check at execution boundaries, not while parsing a remote request.
    pub fn resolve_build_strategy(&self) -> Result<Option<ExecutionStrategy>> {
        self.action
            .uses_build_strategy()
            .then(|| self.options.strategy.resolve())
            .transpose()
    }

    /// Reject unsupported entrypoints before repository, profile or CI effects.
    pub fn validate_execution_support(&self) -> Result<()> {
        if self.action == Action::Prepare {
            if self.options.strategy == Strategy::Agent {
                bail!(
                    "prepare is not supported by --strategy=agent; use --strategy=nix explicitly"
                );
            }
            if self.options.ci_trigger {
                bail!(
                    "prepare is not supported through --ci-trigger; run it directly on the controller"
                );
            }
        }
        Ok(())
    }

    /// The nix pipeline/engine: everything except an agent-resolved build action.
    pub fn require_nix_pipeline(&self) -> Result<Option<ExecutionStrategy>> {
        let strategy = self.resolve_build_strategy()?;
        anyhow::ensure!(
            strategy != Some(ExecutionStrategy::Agent),
            abird_host_agent::build_executor::strategy::AGENT_BACKEND_ONLY
        );
        Ok(strategy)
    }

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
        let canonical = translate_legacy(arguments)?;
        Self::parse_canonical_with_defaults(canonical, options, jobs_per_domain_explicit)
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
        let matches = fleet_command()
            .color(ColorChoice::Never)
            .try_get_matches_from(std::iter::once("fleet".to_owned()).chain(arguments))
            .map_err(|error| anyhow::anyhow!(error.to_string()))?;
        let mut action = canonical_action(&matches)?;
        let mut options = apply_canonical_options(&matches, options, jobs_per_domain_explicit)?;
        if let Some(mode) = last_value(&matches, "clean-legacy") {
            action = Action::Clean(parse_clean_mode(&mode)?);
        }
        enable_parallel_log_prefixes(&mut options);
        validate(&action, &options)?;
        Ok(Self { action, options })
    }
}

fn translate_legacy<I, S>(arguments: I) -> Result<Vec<String>>
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
        return Ok(vec!["fleet".into(), "help".into()]);
    };
    if first != "tofu"
        && arguments
            .iter()
            .any(|value| matches!(value.as_str(), "-h" | "--help"))
    {
        return Ok(vec!["fleet".into(), "help".into()]);
    }
    let (prefix, consumed) = match first.as_str() {
        "help" | "-h" | "--help" => (vec!["help".into()], 1),
        "deps" | "check-deps" | "version" | "run" | "deploy" | "prepare" | "build"
        | "dev-build" | "check-bootstrap" | "clean" | "tofu" => (vec![first], 1),
        "repo" if arguments.get(1).is_some_and(|value| value == "sync") => {
            (vec!["repo".into(), "sync".into()], 2)
        }
        "--list-hosts" => (vec!["hosts".into()], 1),
        "--list-groups" => (vec!["groups".into()], 1),
        "tf" => (vec!["terraform".into(), "all".into()], 1),
        "tf-dns" => (vec!["terraform".into(), "dns".into()], 1),
        "tf-platform" => (vec!["terraform".into(), "platform".into()], 1),
        "tf-apps" => (vec!["terraform".into(), "apps".into()], 1),
        value if value.starts_with("tf/") && value.len() > 3 => (
            vec!["terraform".into(), "project".into(), value[3..].to_owned()],
            1,
        ),
        "--clean" => (Vec::new(), 0),
        value if value.starts_with("--clean=") => (Vec::new(), 0),
        _ => bail!("unknown nixbot action: {first}"),
    };
    let mut canonical = vec!["fleet".to_owned()];
    canonical.extend(prefix);
    canonical.extend(arguments.into_iter().skip(consumed));
    Ok(canonical)
}

fn canonical_action(matches: &ArgMatches) -> Result<Action> {
    if matches.get_flag("help-flag") {
        return Ok(Action::Help);
    }
    match matches.subcommand() {
        None | Some(("help", _)) => Ok(Action::Help),
        Some(("deps", _)) => Ok(Action::Deps),
        Some(("check-deps", _)) => Ok(Action::CheckDeps),
        Some(("version", _)) => Ok(Action::Version),
        Some(("hosts", _)) => Ok(Action::ListHosts),
        Some(("groups", _)) => Ok(Action::ListGroups),
        Some(("run", _)) => Ok(Action::Run),
        Some(("deploy", _)) => Ok(Action::Deploy),
        Some(("prepare", _)) => Ok(Action::Prepare),
        Some(("build", _)) => Ok(Action::Build),
        Some(("dev-build", _)) => Ok(Action::DevBuild),
        Some(("check-bootstrap", _)) => Ok(Action::CheckBootstrap),
        Some(("clean", subcommand)) => Ok(Action::Clean(
            subcommand
                .get_one::<String>("mode")
                .map(|value| parse_clean_mode(value))
                .transpose()?
                .unwrap_or_default(),
        )),
        Some(("repo", subcommand)) => match subcommand.subcommand_name() {
            Some("sync") => Ok(Action::RepoSync),
            _ => bail!("repo requires sync"),
        },
        Some(("terraform", subcommand)) => match subcommand.subcommand() {
            Some(("all", _)) => Ok(Action::TerraformAll),
            Some(("dns", _)) => Ok(Action::TerraformDns),
            Some(("platform", _)) => Ok(Action::TerraformPlatform),
            Some(("apps", _)) => Ok(Action::TerraformApps),
            Some(("project", project)) => Ok(Action::TerraformProject(
                project
                    .get_one::<String>("NAME")
                    .cloned()
                    .context("terraform project requires a name")?,
            )),
            _ => bail!("terraform requires all, dns, platform, apps, or project NAME"),
        },
        Some(("tofu", subcommand)) => Ok(Action::Tofu(
            subcommand
                .get_many::<String>("ARGS")
                .map(|values| values.cloned().collect())
                .unwrap_or_default(),
        )),
        Some(("owned", _)) => bail!("fleet owned is handled by the durable owned-run command"),
        Some((name, _)) => bail!("unknown fleet action: {name}"),
    }
}

fn last_value(matches: &ArgMatches, id: &str) -> Option<String> {
    matches
        .get_many::<String>(id)
        .and_then(|mut values| values.next_back().cloned())
}

fn all_values(matches: &ArgMatches, id: &str) -> Vec<String> {
    matches
        .get_many::<String>(id)
        .map(|values| values.cloned().collect())
        .unwrap_or_default()
}

fn apply_canonical_options(
    matches: &ArgMatches,
    mut options: Options,
    jobs_per_domain_explicit: bool,
) -> Result<Options> {
    if let Some(value) = last_value(matches, "sha") {
        options.sha = Some(value);
    }
    if let Some(value) = last_value(matches, "host") {
        options.host = Some(value);
        options.hosts = None;
    }
    if let Some(value) = last_value(matches, "hosts") {
        options.hosts = Some(value);
        options.host = None;
    }
    for raw in all_values(matches, "require-hosts") {
        let hosts = split_values(&raw);
        if hosts.is_empty() {
            bail!("--require-hosts cannot be empty");
        }
        for host in &hosts {
            validate_host_name(host)?;
        }
        options.required_hosts.extend(hosts);
    }
    let groups = all_values(matches, "group");
    if !groups.is_empty() {
        options.groups.clear();
        for raw in groups {
            options.groups.extend(split_values(&raw));
        }
    }
    if let Some(value) = last_value(matches, "nix-config") {
        options.nix_config = Some(value);
    }
    if let Some(value) = last_value(matches, "goal") {
        options.goal = parse_goal(&value)?;
    }
    if let Some(value) = last_value(matches, "strategy") {
        options.strategy = Strategy::parse(&value)?;
        options.strategy_explicit = true;
    }
    if let Some(value) = last_value(matches, "build-host") {
        options.build_host = Some(value);
        options.build_host_explicit = true;
    }
    if let Some(value) = last_value(matches, "build-host-deploy-mode") {
        options.build_host_deploy_mode = parse_build_host_deploy_mode(&value)?;
    }
    if let Some(value) = last_value(matches, "build-cache-url") {
        options.build_cache_url = Some(value);
    }
    if let Some(value) = last_value(matches, "build-cache-host") {
        options.build_cache_host = Some(value);
    }
    if let Some(value) = last_value(matches, "build-plan-jobs") {
        options.build_plan_jobs = parse_job_count(&value)?;
    }
    if let Some(value) = last_value(matches, "build-jobs") {
        options.build_jobs = positive(&value, "--build-jobs")?;
    }
    if matches.get_flag("build-logs") {
        options.build_logs = true;
    } else if matches.get_flag("no-build-logs") {
        options.build_logs = false;
    }
    let deploy_jobs_cli = last_value(matches, "deploy-jobs");
    if let Some(value) = &deploy_jobs_cli {
        options.deploy_jobs = positive(value, "--deploy-jobs")?;
    }
    let per_domain_cli = last_value(matches, "deploy-jobs-per-domain");
    let mut per_domain_explicit = jobs_per_domain_explicit;
    if let Some(value) = per_domain_cli {
        options.deploy_jobs_per_domain = positive(&value, "--deploy-jobs-per-domain")?;
        per_domain_explicit = true;
    } else if deploy_jobs_cli.is_some() && !per_domain_explicit {
        options.deploy_jobs_per_domain = options.deploy_jobs;
    }
    options.deploy_jobs_per_domain_explicit = per_domain_explicit;
    if let Some(value) = last_value(matches, "deploy-jobs-per-domain-max") {
        options.deploy_jobs_per_domain_max =
            Some(positive(&value, "--deploy-jobs-per-domain-max")?);
    }
    if let Some(value) = last_value(matches, "verify-jobs") {
        options.verify_jobs = positive(&value, "--verify-jobs")?;
    }
    if let Some(value) = last_value(matches, "log-format") {
        options.log_format = parse_log_format(&value)?;
    }
    for value in all_values(matches, "user") {
        set_once(&mut options.user, value, "user")?;
    }
    for value in all_values(matches, "ssh-key") {
        set_once(&mut options.ssh_key, PathBuf::from(value), "SSH key")?;
    }
    for value in all_values(matches, "operator-user") {
        set_once(&mut options.operator_user, value, "operator user")?;
    }
    for value in all_values(matches, "operator-key") {
        set_once(
            &mut options.operator_key,
            PathBuf::from(value),
            "operator key",
        )?;
    }
    if let Some(value) = last_value(matches, "bootstrap-key") {
        options.bootstrap_key = Some(PathBuf::from(value));
    }
    if let Some(value) = last_value(matches, "known-hosts") {
        options.known_hosts = Some(value);
    }
    if let Some(value) = last_value(matches, "config") {
        options.config = Some(PathBuf::from(value));
    }
    if let Some(value) = last_value(matches, "age-key-file") {
        options.age_key_file = Some(PathBuf::from(value));
    }
    if let Some(value) = last_value(matches, "discover-keys") {
        options.discover_keys = parse_discover_keys(&value)?;
    } else if matches.get_flag("no-discover-keys") {
        options.discover_keys = DiscoverKeys::Off;
    }
    if let Some(value) = last_value(matches, "repo-url") {
        options.repo_url = Some(value);
    }
    if let Some(value) = last_value(matches, "repo-path") {
        options.repo_path = Some(PathBuf::from(value));
    }
    if let Some(value) = last_value(matches, "ci-check-ssh-key-path") {
        options.ci_check_ssh_key_path = Some(PathBuf::from(value));
    }
    if let Some(value) = last_value(matches, "ci-host") {
        options.ci_host = Some(value);
    }
    if let Some(value) = last_value(matches, "ci-user") {
        options.ci_user = Some(value);
    }
    if let Some(value) = last_value(matches, "ci-ssh-key") {
        options.ci_ssh_key = Some(value);
    }
    if let Some(value) = last_value(matches, "ci-known-hosts") {
        options.ci_known_hosts = Some(value);
    }
    if let Some(value) = last_value(matches, "dirty-staged-base") {
        options.dirty_staged_base = Some(value);
    }
    if matches.get_flag("control-plane-first") {
        options.control_plane_first = true;
    }
    if matches.get_flag("force") {
        options.force = true;
    }
    if matches.get_flag("restart-managed") {
        options.restart_managed = true;
    }
    if matches.get_flag("bootstrap") {
        options.bootstrap = true;
    }
    if matches.get_flag("skip-global-lock") {
        options.skip_global_lock = true;
    }
    if matches.get_flag("dirty") {
        options.dirty = true;
    }
    if matches.get_flag("dirty-staged") {
        options.dirty = true;
        options.dirty_staged = true;
    }
    if matches.get_flag("dirty-staged-patch-stdin") {
        options.dirty_staged_patch_stdin = true;
    }
    if matches.get_flag("dry") {
        options.dry_run = true;
    }
    if matches.get_flag("no-override") {
        options.no_override = true;
    }
    if let Some(value) = last_value(matches, "config-override") {
        options.config_override = Some(PathBuf::from(value));
    }
    if let Some(value) = last_value(matches, "route") {
        options.route = RouteRequest::parse(&value)?;
        options.route_source = RouteSource::Cli;
    }
    if matches.get_flag("no-rollback") {
        options.no_rollback = true;
    }
    if matches.get_flag("no-verify") {
        options.no_verify = true;
    }
    if matches.get_flag("prefix-host-logs") {
        options.prefix_host_logs = true;
        options.prefix_host_logs_explicit = true;
    }
    if matches.get_flag("verbose") {
        options.verbose = true;
    } else if matches.get_flag("quiet") {
        options.verbose = false;
    }
    if matches.get_flag("use-repo-script") {
        options.use_repo_script = true;
    }
    if matches.get_flag("ci-trigger") {
        options.ci_trigger = true;
    }
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
    if let Some(max) = options.deploy_jobs_per_domain_max
        && (max == 0
            || (options.deploy_jobs_per_domain_explicit && max < options.deploy_jobs_per_domain))
    {
        bail!(
            "--jobs-per-domain-max must be at least the initial --jobs-per-domain ({})",
            options.deploy_jobs_per_domain
        );
    }
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
    if options.ci_trigger && options.config_override.is_some() {
        bail!("--ci-trigger forbids --config-override");
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fleet_help_is_clap_formatted_grouped_and_color_capable() {
        let mut plain_command = fleet_command().color(ColorChoice::Never).term_width(160);
        let plain = plain_command.render_help().to_string();
        assert!(plain.contains("Usage: abird-host-manager fleet"), "{plain}");
        for heading in [
            "Commands:",
            "Selection:",
            "Build:",
            "Deployment:",
            "Repository:",
            "CI:",
            "Behavior:",
            "Authentication:",
        ] {
            assert!(plain.contains(heading), "missing {heading:?}:\n{plain}");
        }
        for command in ["deploy", "prepare", "terraform", "repo", "owned", "tofu"] {
            assert!(plain.contains(command), "missing {command:?}:\n{plain}");
        }
        let dense = plain
            .lines()
            .find(|line| line.contains("--build-host-deploy-mode"))
            .expect("build host deploy mode is documented");
        assert!(
            dense.contains("How remote build results reach deployment hosts"),
            "wide-terminal help should keep option and help text together:\n{plain}"
        );

        let styled = fleet_command();
        let styles = format!("{:?}", styled.get_styles());
        assert!(styles.contains("Cyan"), "{styles}");
        assert!(styles.contains("Green"), "{styles}");
    }

    #[test]
    fn canonical_clap_schema_parses_hidden_transport_without_documenting_it() {
        let mut command = fleet_command().color(ColorChoice::Never);
        let help = command.render_help().to_string();
        for hidden in [
            "--clean",
            "--dirty-staged-base",
            "--dirty-staged-patch-stdin",
            "--use-repo-script",
        ] {
            assert!(
                !help.contains(hidden),
                "hidden transport leaked into help: {hidden}"
            );
        }

        let parsed = Invocation::parse_canonical([
            "fleet",
            "deploy",
            "--dirty-staged-base=abc123",
            "--dirty-staged-patch-stdin",
            "--use-repo-script",
        ])
        .unwrap();
        assert_eq!(parsed.options.dirty_staged_base.as_deref(), Some("abc123"));
        assert!(parsed.options.dirty_staged_patch_stdin);
        assert!(parsed.options.use_repo_script);
    }

    #[test]
    fn legacy_translation_and_canonical_clap_share_one_option_semantics() {
        let legacy = Invocation::parse_legacy([
            "nixbot",
            "deploy",
            "--host=app",
            "--jobs=3",
            "--jobs-per-domain=2",
            "--goal=test",
            "--build-logs",
            "--route=cf",
        ])
        .unwrap();
        let canonical = Invocation::parse_canonical([
            "fleet",
            "deploy",
            "--host=app",
            "--jobs=3",
            "--jobs-per-domain=2",
            "--goal=test",
            "--build-logs",
            "--route=cf",
        ])
        .unwrap();
        assert_eq!(legacy, canonical);

        assert_eq!(
            Invocation::parse_legacy(["nixbot", "tf-dns"]).unwrap(),
            Invocation::parse_canonical(["fleet", "terraform", "dns"]).unwrap()
        );
        assert_eq!(
            Invocation::parse_legacy(["nixbot", "--list-hosts"]).unwrap(),
            Invocation::parse_canonical(["fleet", "hosts"]).unwrap()
        );
        assert_eq!(
            Invocation::parse_legacy(["nixbot", "tf/apps"]).unwrap(),
            Invocation::parse_canonical(["fleet", "terraform", "project", "apps"]).unwrap()
        );
    }

    #[test]
    fn route_flag_is_parsed_exactly() {
        for (value, expected) in [
            ("auto", RouteRequest::Auto),
            ("default", RouteRequest::Default),
            ("cf", RouteRequest::Cf),
            ("ts", RouteRequest::Ts),
        ] {
            let flagged =
                Invocation::parse_canonical(["fleet", "deploy", &format!("--route={value}")])
                    .unwrap();
            assert_eq!(flagged.options.route, expected);
        }
        for value in ["", "on", "off", " cf", "cf ", "maybe"] {
            assert!(
                Invocation::parse_canonical(["fleet", "deploy", &format!("--route={value}")])
                    .is_err(),
                "{value:?}"
            );
        }
    }

    #[test]
    fn config_override_flag_conflicts_with_no_override() {
        let named = Invocation::parse_canonical([
            "fleet",
            "deploy",
            "--config-override=/tmp/operator.override.nix",
        ])
        .unwrap();
        assert_eq!(
            named.options.config_override,
            Some(std::path::PathBuf::from("/tmp/operator.override.nix"))
        );

        for arguments in [
            [
                "fleet",
                "deploy",
                "--no-override",
                "--config-override=/tmp/x.nix",
            ],
            [
                "fleet",
                "deploy",
                "--config-override=/tmp/x.nix",
                "--no-override",
            ],
        ] {
            assert!(
                Invocation::parse_canonical(arguments).is_err(),
                "{arguments:?} must be rejected"
            );
        }
        assert!(
            Invocation::parse_canonical([
                "fleet",
                "deploy",
                "--ci-trigger",
                "--config-override=/tmp/x.nix",
            ])
            .is_err()
        );
    }
}
