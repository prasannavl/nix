//! SSH forced command for the distinct data-only account. Never evaluate the
//! original shell command; only this exact fixed input verb is accepted.

use anyhow::{Context, Result, ensure};
use std::io::Write;

/// The data account uses this binary itself as its login shell: no shell rc,
/// profile, BASH_ENV or caller-selected command interpreter is executed.
pub fn entry(mut arguments: impl Iterator<Item = std::ffi::OsString>) -> Option<bool> {
    match arguments.next()?.to_str()? {
        "_owned-input-relay" => Some(arguments.next().is_none()),
        "-c" => Some(
            arguments
                .next()
                .is_some_and(|arg| arg == "abird-owned-input")
                && arguments.next().is_none(),
        ),
        _ => None,
    }
}

pub fn run() -> Result<()> {
    crate::build_executor::process::protect_worker_memory()?;
    ensure!(
        unsafe { libc::getuid() } > 0 && unsafe { libc::geteuid() } == unsafe { libc::getuid() },
        "input relay requires an unprivileged SSH identity"
    );
    let original = std::env::var("SSH_ORIGINAL_COMMAND").context("input command missing")?;
    let (attempt, digest, length) = parse(&original)?;
    use crate::build_executor::source_transport;
    let cutoff: u64 = std::env::var(source_transport::RELAY_CUTOFF)
        .context("input admission cutoff missing")?
        .parse()
        .context("invalid input admission cutoff")?;
    let receipt = source_transport::deliver_stdin_until(
        &attempt,
        &digest,
        length,
        source_transport::relay_deadline(cutoff)?,
    )?;
    std::io::stdout().write_all(&serde_json::to_vec(&receipt)?)?;
    Ok(())
}

fn parse(original: &str) -> Result<(String, String, usize)> {
    ensure!(original.len() <= 512, "input command exceeds bound");
    let words = shlex::split(original).context("invalid input command")?;
    ensure!(
        words.len() == 10
            && words[0] == "exec"
            && words[1] == "/run/current-system/sw/bin/abird-host-agent"
            && words[2] == "--json"
            && words[3] == "owned-build"
            && words[4] == "inputs"
            && words[6] == "--request-digest"
            && words[8] == "--length",
        "input-only SSH command rejected"
    );
    crate::build_executor::digest(&words[5])?;
    crate::build_executor::digest(&words[7])?;
    let length: usize = words[9].parse()?;
    ensure!(
        (1..=crate::build_executor::preparation::source::MAX_MATERIAL_BYTES).contains(&length),
        "source frame exceeds bound"
    );
    Ok((words[5].clone(), words[7].clone(), length))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn login_shell_only_accepts_the_fixed_marker_without_interpreting_text() {
        let entry =
            |args: &[&str]| super::entry(args.iter().map(|arg| std::ffi::OsString::from(*arg)));
        assert_eq!(entry(&["-c", "abird-owned-input"]), Some(true));
        assert_eq!(entry(&["_owned-input-relay"]), Some(true));
        for args in [
            vec!["-c"],
            vec!["-c", "id"],
            vec!["-c", "abird-owned-input", "extra"],
            vec!["_owned-input-relay", "--help"],
        ] {
            assert_eq!(entry(&args), Some(false));
        }
        assert_eq!(entry(&["--json", "owned-build", "status"]), None);
    }

    #[test]
    fn relay_retains_original_cutoff_and_rejects_expiry() {
        use crate::build_executor::source_transport::{relay_cutoff, relay_deadline};
        use std::time::{Duration, Instant};
        let original = Instant::now() + Duration::from_secs(60);
        let retained = relay_deadline(relay_cutoff(original).unwrap()).unwrap();
        assert!(retained <= original && retained > Instant::now());
        assert!(relay_deadline(0).is_err());
        assert!(relay_cutoff(Instant::now()).is_err());
    }

    #[test]
    fn forced_input_identity_cannot_submit_control_or_shell() {
        let command = format!(
            "exec /run/current-system/sw/bin/abird-host-agent --json owned-build inputs {} --request-digest {} --length 42",
            "a".repeat(64),
            "b".repeat(64)
        );
        assert_eq!(parse(&command).unwrap().2, 42);
        for bad in [
            command.replace("inputs", "request"),
            format!("{command}; id"),
            command.replace("--length 42", "--length 0"),
            "sh".into(),
            "nix-store --serve".into(),
        ] {
            assert!(parse(&bad).is_err());
        }
    }
}
