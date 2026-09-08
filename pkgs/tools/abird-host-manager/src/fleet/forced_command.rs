//! Injection-safe request framing for direct and SSH forced-command entrypoints.

use anyhow::{Context, Result, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;

pub const ARGUMENT_PREFIX: &str = "__nixbot_argv64";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RequestSource {
    LocalArguments,
    EncodedArguments,
    ForcedCommandEncoded,
    ForcedCommandSimple,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HydratedRequest {
    pub arguments: Vec<String>,
    pub source: RequestSource,
}

pub fn encode_arguments<S: AsRef<str>>(arguments: &[S]) -> Result<String> {
    let mut framed = Vec::new();
    for argument in arguments {
        let argument = argument.as_ref();
        if argument.as_bytes().contains(&0) {
            bail!("argv cannot contain NUL bytes");
        }
        framed.extend_from_slice(argument.as_bytes());
        framed.push(0);
    }
    Ok(STANDARD.encode(framed))
}

pub fn decode_arguments(encoded: &str) -> Result<Vec<String>> {
    if encoded.is_empty() {
        bail!("empty encoded argv payload");
    }
    let decoded = STANDARD
        .decode(encoded)
        .context("decode base64 argv payload")?;
    if decoded.last() != Some(&0) {
        bail!("encoded argv payload is not NUL terminated");
    }
    decoded[..decoded.len() - 1]
        .split(|byte| *byte == 0)
        .map(|argument| {
            String::from_utf8(argument.to_vec()).context("encoded argv contains invalid UTF-8")
        })
        .collect()
}

pub fn hydrate_arguments(
    arguments: &[String],
    ssh_original_command: Option<&str>,
) -> Result<HydratedRequest> {
    if arguments
        .first()
        .is_some_and(|value| value == ARGUMENT_PREFIX)
    {
        let encoded = arguments
            .get(1)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| anyhow::anyhow!("empty encoded argv payload"))?;
        return Ok(HydratedRequest {
            arguments: decode_arguments(encoded)?,
            source: RequestSource::EncodedArguments,
        });
    }

    if !arguments.is_empty() || ssh_original_command.is_none() {
        return Ok(HydratedRequest {
            arguments: arguments.to_vec(),
            source: RequestSource::LocalArguments,
        });
    }

    let command = ssh_original_command.unwrap_or_default();
    let encoded_prefix = format!("{ARGUMENT_PREFIX} ");
    if let Some(encoded) = command.strip_prefix(&encoded_prefix) {
        if encoded.is_empty() {
            bail!("empty forced-command argv payload");
        }
        return Ok(HydratedRequest {
            arguments: decode_arguments(encoded)?,
            source: RequestSource::ForcedCommandEncoded,
        });
    }
    if command == ARGUMENT_PREFIX {
        bail!("empty forced-command argv payload");
    }
    if command.chars().any(is_forbidden_shell_character) {
        bail!(
            "unsupported SSH forced-command syntax; use nixbot --ci-trigger or an unquoted simple argv form"
        );
    }

    let mut decoded = command
        .split_ascii_whitespace()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    if decoded.first().is_some_and(|argument| argument == "--") {
        decoded.remove(0);
    }
    if decoded
        .first()
        .is_some_and(|argument| is_nixbot_name(argument))
    {
        decoded.remove(0);
    }
    if decoded
        .first()
        .is_some_and(|argument| argument == ARGUMENT_PREFIX)
    {
        let encoded = decoded
            .get(1)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| anyhow::anyhow!("empty encoded argv payload"))?;
        decoded = decode_arguments(encoded)?;
    }
    Ok(HydratedRequest {
        arguments: decoded,
        source: RequestSource::ForcedCommandSimple,
    })
}

fn is_nixbot_name(argument: &str) -> bool {
    matches!(argument.rsplit('/').next(), Some("nixbot" | "nixbot.sh"))
}

fn is_forbidden_shell_character(character: char) -> bool {
    matches!(
        character,
        '`' | '$' | '(' | ')' | '{' | '}' | ';' | '&' | '|' | '<' | '>' | '\\' | '\'' | '"'
    )
}
