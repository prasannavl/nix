//! Bounded caller-private retention. Only positively settled original capture
//! records are eligible. Lost delivery ACK is reconciled by authenticated status,
//! never by a new launch, capsule reconstruction, or source retransmission.

use std::time::{Duration, Instant};

use abird_host_agent::build_executor::{
    capture_role::{self, Phase, Policy, Record, State},
    protocol::{self, Command, Reply, Request, Snapshot},
    source_transport::{InputState, Receipt},
};
use anyhow::{Result, ensure};

use crate::fleet::build_backend::agent::{
    bootstrap::Bootstrap,
    control::transport::{Installed, Transport},
    controller::PendingCapture,
};

pub fn reap() -> Result<()> {
    capture_role::require_reaper_placement()?;
    abird_host_agent::build_executor::process::protect_worker_memory()?;
    let policy = Policy::load()?;
    let state = State::open(&policy)?;
    let deadline = Instant::now() + Duration::from_secs(25);
    let mut incomplete = false;
    for attempt in state.attempts()? {
        if Instant::now() >= deadline {
            break;
        }
        let result = (|| -> Result<()> {
            if attempt.starts_with("expired-") {
                return state.prune(&attempt, deadline);
            }
            capture_role::reconcile_unit(&policy, &state, &attempt, deadline)?;
            let record = state.read(&attempt)?;
            if !record.phase.terminal() {
                return Ok(());
            }
            if !record.cleanup_allowed() {
                reconcile(&policy, &state, &record, deadline)?;
            }
            let record = state.read(&attempt)?;
            if record.cleanup_allowed() {
                // A partial deletion is safe to resume, but never occupies the
                // caller control-state lock for the whole timer allowance.
                state.release_data(
                    &attempt,
                    deadline.min(Instant::now() + Duration::from_secs(1)),
                )?;
                state.prune(&attempt, deadline)?;
            }
            Ok(())
        })();
        incomplete |= result.is_err();
    }
    ensure!(!incomplete, "capture retirement remains incomplete");
    Ok(())
}

fn reconcile(policy: &Policy, state: &State, record: &Record, deadline: Instant) -> Result<()> {
    let intent = &record.input.request;
    let caller = policy.caller(record.uid)?;
    let pending: PendingCapture = serde_json::from_value(record.input.pending.clone())?;
    pending.validate(intent)?;
    let bootstrap = Bootstrap::for_capture(caller)?;
    ensure!(
        bootstrap
            .reference
            .as_ref()
            .map(|reference| &reference.digest)
            == intent.bootstrap_digest.as_ref(),
        "capture reaper bootstrap differs"
    );
    let mut target = bootstrap.target(&pending.invocation, &pending.cwd)?;
    ensure!(
        !target.local,
        "capture reaper requires the retained remote route"
    );
    target.remote_read_timeout_seconds = target.remote_read_timeout_seconds.min(2);
    let mut transport = Installed::for_capture_reaper(caller.account.clone())?;
    transport.observe_until(deadline);
    let query = Request {
        version: protocol::VERSION,
        command: Command::Status {
            attempt_id: intent.attempt_id()?,
        },
    };
    let reply = transport.request(&target, &query)?;
    reply.validate_for(&query)?;
    let Reply::Status { snapshot } = reply.reply else {
        anyhow::bail!("source intake remains unconfirmed")
    };
    let (acceptance, input, stopped) = match snapshot.as_ref() {
        Snapshot::Live {
            acceptance,
            input,
            outcome,
            settled_at,
            ..
        } => (
            acceptance,
            input.as_ref(),
            settled_at.is_some() && outcome.as_ref().is_some_and(stopped),
        ),
        Snapshot::Retired {
            acceptance,
            outcome,
            ..
        } => (acceptance, None, stopped(outcome)),
    };
    ensure!(
        acceptance.attempt_id == intent.attempt_id()?
            && acceptance.spec_digest == intent.digest()?,
        "capture reaper acceptance differs"
    );
    let received = match input {
        Some(InputState::Received { digest }) => {
            ensure!(
                record.delivery_claim.as_deref() == Some(digest.as_str()),
                "builder received different capture material"
            );
            Some(Receipt {
                version: 1,
                attempt_id: intent.attempt_id()?,
                request_digest: intent.digest()?,
                material_digest: digest.clone(),
            })
        }
        _ => None,
    };
    if received.is_some() || stopped {
        state.update(&intent.attempt_id()?, |current| {
            ensure!(
                current.phase == Phase::Settled && current.delivery_claim == record.delivery_claim,
                "capture reaper record changed"
            );
            current.receipt = received;
            current.builder_stopped |= stopped;
            Ok(())
        })?;
    }
    Ok(())
}

fn stopped(outcome: &abird_host_agent::build_executor::Outcome) -> bool {
    matches!(
        outcome,
        abird_host_agent::build_executor::Outcome::Cancelled { .. }
            | abird_host_agent::build_executor::Outcome::Interrupted
            | abird_host_agent::build_executor::Outcome::Failed { .. }
    )
}
