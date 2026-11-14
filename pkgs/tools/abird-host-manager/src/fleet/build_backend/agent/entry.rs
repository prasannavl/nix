//! Fixed internal manager modes. No caller config, terminal UI or error payloads.
//! Credentials, placement and lifetime belong to the original agent worker.

use std::ffi::OsString;
use std::io::{Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::process::ExitCode;

use abird_host_agent::build_executor::{
    native_intent::Validation,
    preparation::{
        self,
        source::{MAX_MATERIAL_BYTES, ProducerInput},
        worker::Input,
    },
    role::ManagerCommand,
    workload,
};
use anyhow::{Context, Result, ensure};

/// Intercept before normal manager initialization, including unknown private
/// modes. Neither parser failures nor source errors enter the public renderer.
pub fn dispatch(arguments: impl IntoIterator<Item = OsString>) -> Option<ExitCode> {
    let mut arguments = arguments.into_iter();
    let first = arguments.next()?;
    if !first.as_bytes().starts_with(b"_owned-") {
        return None;
    }
    if first == "_owned-shared-acquire" {
        let result = (|| -> Result<()> {
            ensure!(
                arguments.next().is_none(),
                "invalid shared acquisition worker arguments"
            );
            super::acquisition::native::shared_worker()
        })();
        return Some(match result {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                let stage = error
                    .downcast_ref::<abird_host_agent::build_executor::consumer_role::FailureStage>(
                    );
                if let Some(stage) = stage {
                    eprintln!("owned shared artifact acquisition unconfirmed ({stage})");
                } else {
                    eprintln!("owned shared artifact acquisition unconfirmed");
                }
                ExitCode::FAILURE
            }
        });
    }
    if first == "_owned-acquire-preflight" {
        let args = arguments.take(2).collect::<Vec<_>>();
        let result = (|| -> Result<()> {
            ensure!(args.len() == 1, "invalid consumer preflight arguments");
            super::acquisition::native::preflight_worker(std::path::Path::new(&args[0]))
        })();
        return Some(if result.is_ok() {
            ExitCode::SUCCESS
        } else {
            eprintln!("owned native consumer preflight failed");
            ExitCode::FAILURE
        });
    }
    if first == "_owned-acquire" {
        let args = arguments.take(2).collect::<Vec<_>>();
        let result = (|| -> Result<()> {
            ensure!(args.len() == 1, "invalid acquisition worker arguments");
            super::acquisition::native::worker(std::path::Path::new(&args[0]))
        })();
        return Some(if result.is_ok() {
            ExitCode::SUCCESS
        } else {
            eprintln!("owned artifact acquisition unconfirmed");
            ExitCode::FAILURE
        });
    }
    if first == "_owned-capture-control"
        || first == "_owned-capture-worker"
        || first == "_owned-capture-reap"
    {
        let args = arguments.take(2).collect::<Vec<_>>();
        let result = (|| -> Result<()> {
            ensure!(
                unsafe { libc::geteuid() } == 0,
                "capture wrapper requires root"
            );
            if first == "_owned-capture-control" {
                ensure!(args.is_empty(), "invalid capture control arguments");
                abird_host_agent::build_executor::capture_role::serve()
            } else if first == "_owned-capture-reap" {
                ensure!(args.is_empty(), "invalid capture reaper arguments");
                super::remote_capture::reap()
            } else {
                ensure!(args.len() == 1, "invalid capture worker arguments");
                super::remote_capture::worker(args[0].to_str().context("invalid capture attempt")?)
            }
        })();
        return Some(match result {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                if let Some(stage) = error.downcast_ref::<super::remote_capture::FailureStage>() {
                    eprintln!("owned caller capture unconfirmed ({stage})");
                } else {
                    eprintln!("owned caller capture unconfirmed");
                }
                ExitCode::FAILURE
            }
        });
    }
    let mode = ManagerCommand::from_argument(&first);
    let args = arguments.take(6).collect::<Vec<_>>();
    let result = mode
        .context("unknown worker mode")
        .and_then(|mode| run(mode, &args));
    Some(match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            let detail = if mode == Some(ManagerCommand::Prepare) {
                error.chain().rev().find_map(|cause| {
                    preparation::worker::failure_diagnostic(cause.to_string().as_bytes())
                })
            } else {
                None
            };
            eprintln!("{}", detail.unwrap_or(diagnostic(mode)));
            ExitCode::FAILURE
        }
    })
}

fn diagnostic(mode: Option<ManagerCommand>) -> &'static str {
    match mode {
        Some(ManagerCommand::Capture) => "owned caller capture failed",
        Some(ManagerCommand::Source) => "owned source operation failed",
        Some(ManagerCommand::Request) => "owned native request validation failed",
        Some(ManagerCommand::Prepare) => "owned preparation failed",
        Some(ManagerCommand::Query) => "owned native evaluation failed",
        Some(ManagerCommand::Controller) => "owned CI observation ended unconfirmed",
        None => "invalid owned worker mode",
    }
}

fn validate_arguments(mode: ManagerCommand, args: &[OsString]) -> Result<()> {
    let expected = match mode {
        ManagerCommand::Capture if args.first().is_some_and(|arg| arg == "--remote-capture") => 3,
        ManagerCommand::Capture | ManagerCommand::Source => 2,
        ManagerCommand::Request => 0,
        ManagerCommand::Prepare => 2,
        ManagerCommand::Query => 1,
        ManagerCommand::Controller => 5,
    };
    ensure!(args.len() == expected, "invalid worker arguments");
    if mode == ManagerCommand::Source {
        ensure!(
            args[0] == "produce" || args[0] == "observe" || args[0] == "repository",
            "invalid source operation"
        );
    }
    Ok(())
}

fn run(mode: ManagerCommand, args: &[OsString]) -> Result<()> {
    validate_arguments(mode, args)?;
    ensure!(
        unsafe { libc::geteuid() } > 0,
        "worker mode requires unprivileged credentials"
    );
    if mode != ManagerCommand::Controller {
        workload::require_wrapper_placement()?;
    }
    abird_host_agent::build_executor::process::protect_worker_memory()?;
    match mode {
        ManagerCommand::Capture => capture(args),
        ManagerCommand::Source => source(args),
        ManagerCommand::Request => request(),
        ManagerCommand::Prepare => prepare(args),
        ManagerCommand::Query => query(args),
        ManagerCommand::Controller => controller(args),
    }
}

fn read_input(limit: usize) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    std::io::stdin()
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= limit, "worker input exceeds bound");
    Ok(bytes)
}

fn write_json(value: &impl serde::Serialize, limit: usize) -> Result<()> {
    abird_host_agent::build_executor::preparation::source::encoding::require_size(value, limit)?;
    // A Git capsule is already hex encoded: do not allocate a second full JSON
    // image merely to write the fixed helper's bounded output pipe.
    serde_json::to_writer(std::io::stdout().lock(), value)?;
    Ok(())
}

fn capture(args: &[OsString]) -> Result<()> {
    if args[0] == "--remote-capture" {
        let material = super::capture::remote::capture(
            serde_json::from_slice(&read_input(
                abird_host_agent::build_executor::capture_role::MAX_FRAME,
            )?)?,
            PathBuf::from(&args[1]),
            PathBuf::from(&args[2]),
        )?;
        return write_json(&material, MAX_MATERIAL_BYTES);
    }
    if args[0] == "--checkout-export" {
        let image = super::capture::remote::export(
            serde_json::from_slice(&read_input(MAX_MATERIAL_BYTES)?)?,
            PathBuf::from(&args[1]),
        )?;
        return write_json(&image, MAX_MATERIAL_BYTES);
    }
    if args[0] == "--checkout-export-local" {
        let capsule = super::capture::remote::export_local(
            serde_json::from_slice(&read_input(MAX_MATERIAL_BYTES)?)?,
            PathBuf::from(&args[1]),
        )?;
        return write_json(&capsule, MAX_MATERIAL_BYTES);
    }
    let checkout = args[0] == "--checkout";
    let bytes = read_input(if checkout {
        MAX_MATERIAL_BYTES
    } else {
        32 * 1024
    })?;
    if checkout {
        let receipt = crate::fleet::build_backend::agent::capture::checkout(
            serde_json::from_slice(&bytes)?,
            PathBuf::from(&args[1]),
        )?;
        std::io::stdout().write_all(receipt.as_bytes())?;
    } else {
        let material = crate::fleet::build_backend::agent::capture::run(
            serde_json::from_slice(&bytes)?,
            PathBuf::from(&args[0]),
            PathBuf::from(&args[1]),
        )?;
        write_json(&material, MAX_MATERIAL_BYTES)?;
    }
    Ok(())
}

fn source(args: &[OsString]) -> Result<()> {
    if args[0] == "repository" {
        let output = crate::fleet::preparation::source_executor::repository(
            serde_json::from_slice(&read_input(MAX_MATERIAL_BYTES)?)?,
            PathBuf::from(&args[1]),
        )?;
        return write_json(&output, MAX_MATERIAL_BYTES);
    }
    let input: ProducerInput = serde_json::from_slice(&read_input(MAX_MATERIAL_BYTES)?)?;
    let digest = crate::fleet::preparation::source_executor::run(
        input,
        PathBuf::from(&args[1]),
        args[0] == "produce",
    )?;
    std::io::stdout().write_all(digest.as_bytes())?;
    Ok(())
}

fn request() -> Result<()> {
    let input: Validation = serde_json::from_slice(&read_input(128 * 1024)?)?;
    let digest = crate::fleet::build_backend::agent::controller::validate_resolution(input)?;
    std::io::stdout().write_all(digest.as_bytes())?;
    Ok(())
}

fn prepare(args: &[OsString]) -> Result<()> {
    let input = Input::decode(&read_input(preparation::worker::MAX_BYTES)?)?;
    let result = crate::fleet::preparation::executor::prepare(
        input,
        PathBuf::from(&args[0]),
        PathBuf::from(&args[1]),
    )?;
    write_json(&result, preparation::MAX_PREPARED_BYTES)
}

fn query(args: &[OsString]) -> Result<()> {
    let request = serde_json::from_slice(&read_input(
        crate::fleet::preparation::native_api::QUERY_LIMITS.stdin,
    )?)?;
    let output = crate::fleet::preparation::native_api::evaluate_worker(
        &request,
        PathBuf::from(&args[0]).as_path(),
    )?;
    std::io::stdout().write_all(&output)?;
    Ok(())
}

fn controller(args: &[OsString]) -> Result<()> {
    let args = args
        .iter()
        .map(|value| value.to_str().context("invalid observer argument"))
        .collect::<Result<Vec<_>>>()?;
    let budget = args[4].parse().context("invalid observer budget")?;
    crate::fleet::build_backend::agent::service::run(args[0], args[1], args[2], args[3], budget)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_modes_reject_missing_extra_and_wrong_operation_arguments_before_input() {
        for (mode, valid) in [
            (
                ManagerCommand::Capture,
                vec!["--checkout", "/nix/store/git/bin/git"],
            ),
            (
                ManagerCommand::Capture,
                vec![
                    "--remote-capture",
                    "/nix/store/git/bin/git",
                    "/nix/store/nix/bin/nix-store",
                ],
            ),
            (
                ManagerCommand::Capture,
                vec!["--checkout-export", "/nix/store/git/bin/git"],
            ),
            (
                ManagerCommand::Capture,
                vec!["--checkout-export-local", "/nix/store/git/bin/git"],
            ),
            (
                ManagerCommand::Source,
                vec!["observe", "/nix/store/git/bin/git"],
            ),
            (ManagerCommand::Request, vec![]),
            (
                ManagerCommand::Prepare,
                vec![
                    "/nix/store/nix/bin/nix",
                    "/nix/store/nix/lib/libnixflakec.so",
                ],
            ),
            (
                ManagerCommand::Query,
                vec!["/nix/store/nix/lib/libnixflakec.so"],
            ),
            (
                ManagerCommand::Controller,
                vec!["run", "attempt", "digest", "invocation", "1000"],
            ),
        ] {
            let valid = valid.into_iter().map(OsString::from).collect::<Vec<_>>();
            assert!(validate_arguments(mode, &valid).is_ok());
            let mut extra = valid.clone();
            extra.push("--help".into());
            assert!(validate_arguments(mode, &extra).is_err());
            if !valid.is_empty() {
                assert!(validate_arguments(mode, &valid[..valid.len() - 1]).is_err());
            }
        }
        assert!(
            validate_arguments(ManagerCommand::Source, &["build".into(), "git".into()]).is_err()
        );
    }

    #[test]
    fn acquisition_dispatch_rejects_missing_or_extra_arguments_before_io() {
        for args in [
            vec!["_owned-acquire"],
            vec!["_owned-acquire", "/nix/store/library", "extra"],
            vec!["_owned-acquire-preflight"],
            vec![
                "_owned-acquire-preflight",
                "/nix/store/nix/bin/nix",
                "extra",
            ],
        ] {
            assert_eq!(
                dispatch(args.into_iter().map(OsString::from)),
                Some(ExitCode::FAILURE)
            );
        }
    }

    #[test]
    fn public_commands_do_not_enter_private_worker_dispatch() {
        assert!(dispatch(Vec::<OsString>::new()).is_none());
        for public in ["fleet", "--help", "transaction", "--json"] {
            assert!(dispatch([OsString::from(public)]).is_none());
        }
    }
}
