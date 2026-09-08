//! Remote realization boundary for builds protected by a builder GC lease.

use std::path::Path;

use anyhow::{Result, bail};

use super::build::{
    BuildArgs, CommandAttempt, CommandExecutor, CommandSpec, CommandStatus, NixStorePath,
    RemoteBuildOutput, RetryExecution, RetryPolicy, execute_with_retry, remote_build_command,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoteBuildTools {
    pub nix: String,
    pub bash: String,
    pub flock: String,
    pub lock_target: String,
}

impl RemoteBuildTools {
    pub fn new(
        nix: impl Into<String>,
        bash: impl Into<String>,
        flock: impl Into<String>,
        lock_target: impl Into<String>,
    ) -> Result<Self> {
        let nix = nix.into();
        let bash = bash.into();
        let flock = flock.into();
        let lock_target = lock_target.into();
        for (label, path) in [
            ("Nix program", &nix),
            ("Bash program", &bash),
            ("flock program", &flock),
            ("Nix store lock target", &lock_target),
        ] {
            if !Path::new(path).is_absolute() || path.as_bytes().contains(&0) {
                bail!("remote {label} must be an absolute path without NUL bytes");
            }
        }
        Ok(Self {
            nix,
            bash,
            flock,
            lock_target,
        })
    }
}

const BUILD_LEASE_SCRIPT: &str = r#"set -Eeuo pipefail
mode="$1"
flock_program="$2"
lock_target="$3"
shift 3
exec 9<"$lock_target"
"$flock_program" --shared 9
case "$mode" in
hold)
    [ "$#" -eq 0 ] || exit 2
    printf 'READY\n'
    while IFS= read -r -t 45 heartbeat; do
        [ "$heartbeat" = PING ] || exit 2
        printf 'PONG\n'
    done
    ;;
run)
    [ "$#" -gt 0 ] || exit 2
    exec "$@"
    ;;
*) exit 2 ;;
esac"#;

fn lease_command(
    tools: &RemoteBuildTools,
    mode: &str,
    command: impl IntoIterator<Item = String>,
) -> CommandSpec {
    let mut args = vec![
        "-c".to_owned(),
        BUILD_LEASE_SCRIPT.to_owned(),
        "nixbot-build-lease".to_owned(),
        mode.to_owned(),
        tools.flock.clone(),
        tools.lock_target.clone(),
    ];
    args.extend(command);
    CommandSpec::new(tools.bash.clone(), args)
}

pub fn builder_lease_hold_command(tools: &RemoteBuildTools) -> CommandSpec {
    lease_command(tools, "hold", [])
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoteBuildCommands {
    pub build: CommandSpec,
}

pub fn plan_remote_build(
    tools: &RemoteBuildTools,
    drv: &NixStorePath,
    build: &BuildArgs,
) -> RemoteBuildCommands {
    let build = remote_build_command(&tools.nix, drv, build);
    RemoteBuildCommands {
        build: lease_command(
            tools,
            "run",
            std::iter::once(build.program).chain(build.args),
        ),
    }
}

pub fn validate_remote_build_output(build: &CommandAttempt) -> Result<RemoteBuildOutput> {
    if build.status != CommandStatus::Success {
        bail!(
            "remote build failed with status {}: {}",
            build.status.code(),
            build.stderr.trim()
        );
    }
    RemoteBuildOutput::validate(&build.stdout)
}

pub fn execute_remote_command(
    executor: &mut impl CommandExecutor,
    command: &CommandSpec,
    retry_policy: RetryPolicy,
) -> RetryExecution {
    execute_with_retry(executor, command, retry_policy)
}
