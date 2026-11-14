//! Existing-attempt transport only. The durable executor owns the lifecycle;
//! no submission, realization, new selector, failover or release authority here.

#[path = "control/transport.rs"]
pub mod transport;

use std::sync::Arc;

use abird_host_agent::build_executor::events::EventCursor;
use abird_host_agent::build_executor::protocol::{
    self, Command, Reply, Request, Response, Snapshot, Unconfirmed,
};
use anyhow::Result;

use crate::fleet::build::CommandSpec;
use crate::fleet::host_runtime::{
    EffectKind, Execution, HostExecutionTarget, HostRuntime, ProcessRunner,
};
use crate::fleet::task::Task;

#[derive(Clone, Copy, Debug)]
pub enum Operation {
    Status,
    Cancel,
    Events { after: Option<u64>, limit: usize },
}

fn unavailable() -> Response {
    Response {
        version: protocol::VERSION,
        reply: Reply::Unconfirmed {
            code: Unconfirmed::Unavailable,
        },
    }
}

pub fn exchange<R: ProcessRunner>(
    runtime: &mut HostRuntime<R>,
    target: &HostExecutionTarget,
    attempt_id: &str,
    operation: Operation,
    task: Arc<dyn Task>,
) -> Result<Execution<Response>> {
    let (command, verb, effect) = match operation {
        Operation::Status => (
            Command::Status {
                attempt_id: attempt_id.to_owned(),
            },
            "status",
            EffectKind::ReadOnly,
        ),
        Operation::Cancel => (
            Command::Cancel {
                attempt_id: attempt_id.to_owned(),
                expected: None,
            },
            "cancel",
            EffectKind::Mutation,
        ),
        Operation::Events { after, limit } => (
            Command::Events {
                attempt_id: attempt_id.to_owned(),
                cursor: after.map(|after| EventCursor {
                    attempt_id: attempt_id.to_owned(),
                    after,
                }),
                limit,
            },
            "events",
            EffectKind::ReadOnly,
        ),
    };
    let request = Request {
        version: protocol::VERSION,
        command,
    };
    Request::decode(&serde_json::to_vec(&request)?)?;
    let mut args = vec![
        "--json".to_owned(),
        "owned-build".to_owned(),
        verb.to_owned(),
        attempt_id.to_owned(),
    ];
    if let Operation::Events { after, limit } = operation {
        args.extend(["--limit".to_owned(), limit.to_string()]);
        if let Some(after) = after {
            args.extend(["--after".to_owned(), after.to_string()]);
        }
    }
    let command = CommandSpec::new("/run/current-system/sw/bin/abird-host-agent", args);
    let output = match runtime.execute_control_command(target, &command, effect, task) {
        Ok(output) if output.skipped => return Ok(Execution::DryRun),
        Ok(output) => output,
        Err(_) => return Ok(Execution::Executed(unavailable())),
    };
    // A complete authenticated receipt survives a later SSH/client failure.
    // Conversely, exit zero without a valid matching response proves nothing.
    let body = output.stdout.strip_suffix('\n').unwrap_or(&output.stdout);
    let response = Response::decode(body.as_bytes()).ok().filter(|response| {
        if matches!(operation, Operation::Cancel)
            && let Reply::Status { snapshot } = &response.reply
        {
            let settled = matches!(
                snapshot.as_ref(),
                Snapshot::Retired { .. }
                    | Snapshot::Live {
                        outcome: Some(_),
                        ..
                    }
            );
            return settled
                && response
                    .validate_for(&Request {
                        version: protocol::VERSION,
                        command: Command::Status {
                            attempt_id: attempt_id.to_owned(),
                        },
                    })
                    .is_ok();
        }
        response.validate_for(&request).is_ok()
    });
    Ok(Execution::Executed(response.unwrap_or_else(unavailable)))
}
