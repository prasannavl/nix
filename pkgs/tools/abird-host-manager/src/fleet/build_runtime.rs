//! Remote realization boundary for builds protected by a builder GC lease.

use std::path::Path;

use anyhow::{Result, bail};
use base64::{Engine as _, engine::general_purpose::STANDARD};

use super::build::{
    BuildArgs, CommandAttempt, CommandExecutor, CommandSpec, CommandStatus, NixStorePath,
    RemoteBuildOutput, RetryExecution, RetryPolicy, execute_with_retry, remote_build_command,
};
use super::build_lease::{LeaseEpoch, LeaseObservation};

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

const BUILD_RESULT_VERSION: &str = "abird-build-result-v1";
const MAX_BUILD_PATH_BYTES: usize = 4096;

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
    [ "$#" -ge 3 ] || exit 2
    nonce="$1"
    derivation="$2"
    shift 2
    # Fixed NixOS system tools; never depend on an SSH login-shell PATH.
    coreutils=/run/current-system/sw/bin
    output_file="$("$coreutils/mktemp")" || exit 2
    trap '"$coreutils/rm" -f -- "$output_file"' EXIT
    if "$@" > "$output_file"; then
        result=0
    else
        result=$?
    fi
    path="-"
    if [ "$result" -eq 0 ]; then
        size="$("$coreutils/wc" -c < "$output_file")"
        if [ "$size" -le 4096 ]; then
            path="$("$coreutils/base64" -w0 "$output_file")"
        else
            path="!"
        fi
    fi
    printf 'abird-build-result-v1\t%s\t%s\t%s\t%s\n' \
        "$nonce" "$derivation" "$result" "$path"
    exit "$result"
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
    pub receipt: BuildReceipt,
}

/// One-time expectation for the SSH launcher, not a remote state store.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BuildReceipt {
    nonce: String,
    derivation: NixStorePath,
}

impl BuildReceipt {
    pub fn new(nonce: impl Into<String>, derivation: NixStorePath) -> Result<Self> {
        let nonce = nonce.into();
        if nonce.len() != 32 || !nonce.bytes().all(|b| b.is_ascii_hexdigit()) {
            bail!("remote build receipt nonce must be 32 hexadecimal characters");
        }
        Ok(Self { nonce, derivation })
    }
}

pub fn plan_remote_build(
    tools: &RemoteBuildTools,
    drv: &NixStorePath,
    build: &BuildArgs,
) -> RemoteBuildCommands {
    let receipt = BuildReceipt::new(uuid::Uuid::new_v4().simple().to_string(), drv.clone())
        .expect("UUID v4 simple form is 32 hexadecimal characters");
    let build = remote_build_command(&tools.nix, drv, build);
    RemoteBuildCommands {
        build: lease_command(
            tools,
            "run",
            [
                receipt.nonce.clone(),
                drv.as_str().to_owned(),
                build.program,
            ]
            .into_iter()
            .chain(build.args),
        ),
        receipt,
    }
}

/// The trusted launcher observed Nix exit; unlike an SSH status, this is a
/// terminal observation of the build command.
pub struct FailedBuild {
    status: u8,
    observation: CommandAttempt,
}

impl FailedBuild {
    pub fn status(&self) -> u8 {
        self.status
    }

    pub fn observation(&self) -> &CommandAttempt {
        &self.observation
    }
}

impl std::fmt::Debug for FailedBuild {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FailedBuild")
            .field("status", &self.status)
            .finish_non_exhaustive()
    }
}

impl std::fmt::Display for FailedBuild {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "remote Nix build failed (exit {})", self.status)
    }
}

impl std::error::Error for FailedBuild {}

/// Lost client observation is not proof that native workers settled.
pub struct UnconfirmedBuild {
    observation: Option<CommandAttempt>,
    reason: &'static str,
}

impl UnconfirmedBuild {
    pub(super) fn unobserved() -> Self {
        Self {
            observation: None,
            reason: "no SSH observation",
        }
    }

    pub fn observation(&self) -> Option<&CommandAttempt> {
        self.observation.as_ref()
    }

    pub fn reason(&self) -> &'static str {
        self.reason
    }
}

impl std::fmt::Debug for UnconfirmedBuild {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UnconfirmedBuild")
            .field(
                "status",
                &self.observation.as_ref().map(|attempt| attempt.status),
            )
            .finish_non_exhaustive()
    }
}

impl std::fmt::Display for UnconfirmedBuild {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "remote build unconfirmed")?;
        if let Some(attempt) = &self.observation {
            write!(f, " (client {:?})", attempt.status)?;
        }
        write!(
            f,
            "; {}; remote work may still be running; realization was not retried",
            self.reason
        )
    }
}

impl std::error::Error for UnconfirmedBuild {}

/// Display-only error ranking, shared by bounded capture and presentation.
/// This never decides whether a remote build settled.
pub(crate) fn build_error_priority(raw: &str) -> u8 {
    let line = raw.trim().trim_start_matches('>').trim();
    if line.starts_with("The system library ") || line.starts_with("Unable to find ") {
        5
    } else if line.starts_with("error[") || line.contains("panicked at ") {
        4
    } else if line.starts_with("error: ") && !line.contains("Cannot build") {
        3
    } else if line.starts_with("Reason: ") {
        2
    } else if line.starts_with("error: Cannot build ") {
        1
    } else {
        0
    }
}

pub fn validate_remote_build_output(
    build: &CommandAttempt,
    expected: &BuildReceipt,
) -> Result<RemoteBuildOutput> {
    let unconfirmed = |reason| UnconfirmedBuild {
        observation: Some(build.clone()),
        reason,
    };
    let client_exit = match build.status {
        CommandStatus::Success => 0,
        CommandStatus::Exit(code) if (1..=255).contains(&code) => code,
        _ => return Err(unconfirmed("SSH client did not confirm the launcher result").into()),
    };
    let Some(frame) = build.stdout.strip_suffix('\n') else {
        return Err(unconfirmed("missing or invalid remote completion receipt").into());
    };
    let fields = frame.split('\t').collect::<Vec<_>>();
    if fields.len() != 5
        || fields[0] != BUILD_RESULT_VERSION
        || fields[1] != expected.nonce
        || fields[2] != expected.derivation.as_str()
        || frame.contains('\r')
        || fields[3].contains(['\n', '\r'])
        || fields[4].contains(['\n', '\r'])
    {
        return Err(unconfirmed("missing or invalid remote completion receipt").into());
    }
    let status = fields[3]
        .parse::<u8>()
        .map_err(|_| unconfirmed("invalid remote build exit status"))?;
    if i32::from(status) != client_exit {
        return Err(unconfirmed("SSH exit status disagrees with remote completion receipt").into());
    }
    if status != 0 {
        if fields[4] != "-" {
            return Err(unconfirmed("failed build receipt contains unexpected output").into());
        }
        return Err(FailedBuild {
            status,
            observation: build.clone(),
        }
        .into());
    }
    if fields[4].len() > MAX_BUILD_PATH_BYTES.div_ceil(3) * 4 {
        return Err(unconfirmed("remote build path exceeds output limit").into());
    }
    let path = STANDARD
        .decode(fields[4])
        .map_err(|_| unconfirmed("invalid remote build path encoding"))?;
    let path =
        std::str::from_utf8(&path).map_err(|_| unconfirmed("remote build path is not UTF-8"))?;
    let path = RemoteBuildOutput::validate(path)
        .map_err(|_| unconfirmed("missing or invalid remote build output path"))?;
    Ok(path)
}

pub fn execute_remote_command(
    executor: &mut impl CommandExecutor,
    command: &CommandSpec,
    retry_policy: RetryPolicy,
) -> RetryExecution {
    execute_with_retry(executor, command, retry_policy)
}

/// Effects used while retaining one remote realization across lease epochs.
pub trait ProtectedBuilder {
    fn ensure_lease(&mut self) -> Result<LeaseObservation>;
    fn realize(&mut self) -> Result<NixStorePath>;
    fn verify_closure(&mut self, closure: &NixStorePath) -> Result<bool>;
}

pub fn realize_protected(
    builder: &mut impl ProtectedBuilder,
    attempts: usize,
) -> Result<(NixStorePath, LeaseEpoch)> {
    let mut pending: Option<NixStorePath> = None;
    for _ in 0..attempts {
        let before = builder.ensure_lease()?;
        let closure = if let Some(expected) = &pending {
            if !builder.verify_closure(expected)? {
                bail!(
                    "builder protection lost for {}; refusing to repeat realization",
                    expected.as_str()
                );
            }
            expected.clone()
        } else {
            let realized = builder.realize()?;
            pending = Some(realized.clone());
            realized
        };
        let after = builder.ensure_lease()?;
        // Verification and realization both need continuous protection. A
        // replacement epoch invalidates evidence, but never the first output
        // identity already selected for this build.
        if after.epoch == before.epoch {
            return Ok((closure, after.epoch));
        }
    }
    bail!("builder lease changed repeatedly while realizing closure")
}
