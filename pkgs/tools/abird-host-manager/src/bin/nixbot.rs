use std::process::ExitCode;

use abird_host_manager::fleet::cli::Invocation;
use abird_host_manager::fleet::environment::Environment;
use abird_host_manager::fleet::forced_command::hydrate_arguments;
use abird_host_manager::fleet::runtime::{RuntimeConfig, run};
use abird_host_manager::progress::command_reporter;

fn main() -> ExitCode {
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
    let original_command = std::env::var("SSH_ORIGINAL_COMMAND").ok();
    match hydrate_arguments(&arguments, original_command.as_deref()).and_then(|request| {
        let mut runtime = RuntimeConfig::from_environment();
        runtime.repo_reexec_arguments = request.arguments.clone();
        let invocation =
            Invocation::parse_legacy_with_environment(request.arguments, &Environment::current())?;
        run(invocation, runtime)
    }) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            if let Some(interrupted) =
                error.downcast_ref::<abird_host_manager::fleet::signal::Interrupted>()
            {
                return ExitCode::from(interrupted.status() as u8);
            }
            if abird_host_manager::fleet::presentation::take_failure_presented() {
                return ExitCode::FAILURE;
            }
            command_reporter().fail_active("Command stopped", &format!("{error:#}"));
            ExitCode::FAILURE
        }
    }
}
