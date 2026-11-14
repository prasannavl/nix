//! Caller-only installed capture orchestration. Builder admission remains the
//! single owner. Source helpers are offline; this trusted wrapper alone observes
//! admission and relays the sealed capsule with its input-only credential.

use std::os::unix::fs::DirBuilderExt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use abird_host_agent::build_executor::{
    capture_role::{self, Execution, Reply as CaptureReply, Status},
    native_intent,
    protocol::{self, Command, Reply, Request, Snapshot},
};
use anyhow::{Context, Result, ensure};

use super::bootstrap::Bootstrap;
use super::control::transport::{Installed, Transport};
use super::controller::{CaptureClaim, PendingCapture};
use crate::fleet::host_runtime::HostExecutionTarget;

mod reap;
pub use reap::reap;

/// Only fixed stage labels cross the private entry's redaction boundary.
#[derive(Debug)]
pub(super) struct FailureStage(&'static str);

impl std::fmt::Display for FailureStage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

impl std::error::Error for FailureStage {}

/// Main calls this only after its durable Run::claim_capture. A lost reply is
/// observed through status; Begin never launches an existing attempt again.
pub fn begin(transport: &mut impl Transport, claim: &CaptureClaim) -> Result<Option<Status>> {
    response(
        transport.capture(&capture_role::Command::Begin {
            input: Box::new(capture_role::Begin {
                request: claim.request.clone(),
                ownership: claim.ownership.clone(),
                reserved_at: claim.reserved_at,
                pending: serde_json::to_value(&claim.pending)?,
            }),
        })?,
        &claim.request,
    )
}

pub fn status(
    transport: &mut impl Transport,
    request: &native_intent::Request,
) -> Result<Option<Status>> {
    response(
        transport.capture(&capture_role::Command::Status {
            attempt: request.attempt_id()?,
            request_digest: request.digest()?,
        })?,
        request,
    )
}

/// Retention acknowledgement only, after Run durably stores the positive local
/// settlement plus matched intake receipt (or settled cancellation). Lost ACK is
/// harmless: never erase caller evidence or launch/deliver again. Without this,
/// bounded root metadata remains available for later reconnect.
pub enum Retention {
    Unconfirmed,
    Acknowledged(Status),
    Closed,
}

pub fn acknowledge(
    transport: &mut impl Transport,
    request: &native_intent::Request,
) -> Result<Retention> {
    let reply = transport.capture(&capture_role::Command::Acknowledge {
        request: Box::new(request.clone()),
    })?;
    if let CaptureReply::RetentionClosed {
        attempt,
        request_digest,
    } = reply
    {
        ensure!(
            attempt == request.attempt_id()? && request_digest == request.digest()?,
            "capture retention closure identity differs"
        );
        return Ok(Retention::Closed);
    }
    Ok(match response(reply, request)? {
        Some(status) => {
            ensure!(
                status.phase.terminal() && status.data_released,
                "capture retention ACK precedes source settlement"
            );
            Retention::Acknowledged(status)
        }
        None => Retention::Unconfirmed,
    })
}

/// Stop intent only, never a local/builder settlement receipt.
pub fn cancel(transport: &mut impl Transport, claim: &CaptureClaim) -> Result<Option<Status>> {
    response(
        transport.capture(&capture_role::Command::Revoke {
            input: Box::new(capture_role::Begin {
                request: claim.request.clone(),
                ownership: claim.ownership.clone(),
                reserved_at: claim.reserved_at,
                pending: serde_json::to_value(&claim.pending)?,
            }),
        })?,
        &claim.request,
    )
}

fn response(reply: CaptureReply, request: &native_intent::Request) -> Result<Option<Status>> {
    let status = match reply {
        CaptureReply::Status { status } => status,
        CaptureReply::Unconfirmed | CaptureReply::Rejected => return Ok(None),
        CaptureReply::Ready | CaptureReply::RetentionClosed { .. } => {
            anyhow::bail!("capture metadata reply is not execution/intake evidence")
        }
    };
    status.validate_for(request)?;
    Ok(Some(*status))
}

/// Fixed root-only entry; no public configuration/CLI initialization. The source
/// owner supplies the native private checkout/capsule implementation.
pub fn worker(attempt: &str) -> Result<()> {
    let execution = Execution::start(attempt).context(FailureStage("startup"))?;
    let mut stage = "bootstrap";
    let result = run(&execution, &mut stage).with_context(|| FailureStage(stage));
    if result.is_err() || !execution.empty()? {
        execution.stop()?;
    }
    // Never extend the original lifetime to manufacture local settlement.
    while !execution.empty()? && Instant::now() < execution.deadline()? {
        std::thread::sleep(Duration::from_millis(10));
    }
    match result {
        Ok(receipt) => execution.finish(receipt),
        Err(error) => {
            execution.finish(None)?;
            Err(error)
        }
    }
}

fn run(
    execution: &Execution,
    stage: &mut &'static str,
) -> Result<Option<abird_host_agent::build_executor::source_transport::Receipt>> {
    let record = execution.record()?;
    let intent = &record.input.request;
    let pending: PendingCapture = serde_json::from_value(record.input.pending.clone())?;
    pending.validate(intent)?;
    let caller = execution.policy.caller(execution.uid)?;
    ensure!(
        pending
            .bootstrap
            .as_ref()
            .is_some_and(|reference| reference.path == caller.bootstrap),
        "caller bootstrap differs from installed capture account"
    );
    let bootstrap = Bootstrap::for_capture(caller)?;
    ensure!(
        !bootstrap.local_control
            && !bootstrap.controller_service
            && bootstrap.controller == intent.controller
            && bootstrap.repository_id == intent.repository_id
            && bootstrap.reference.as_ref().map(|r| &r.digest) == intent.bootstrap_digest.as_ref(),
        "capture bootstrap differs from native admission"
    );
    let target = bootstrap.target(&pending.invocation, &pending.cwd)?;
    // Inventory aliases are routing names, not builder authority. Describe and
    // the original native intent below bind the authenticated builder identity.
    ensure!(
        !target.local && execution.policy.relay_port != target.route.endpoint.port,
        "capture requires the retained remote route and dedicated input endpoint"
    );
    *stage = "transport";
    capture_role::trusted_ssh_file(&execution.policy.relay_key, true)?;
    let scope = execution.transport()?;
    let mut transport = Installed::for_capture(scope.clone(), Some(caller.account.clone()))?;
    transport.observe_until(execution.deadline()?);
    *stage = "describe";
    let declaration = super::controller::describe(&target, &mut transport)?;
    ensure!(
        declaration.issuer == intent.issuer,
        "capture issuer differs"
    );
    intent.authority(&declaration.identity, &declaration.policy)?;
    ensure!(
        bootstrap.nix_for(&declaration.policy)? == intent.nix,
        "capture Nix options differ from original admission"
    );
    *stage = "status";
    let initial = observe(&mut transport, &target, intent)?;
    *stage = "admission";
    let lease = admitted(
        &initial,
        &record.input.ownership,
        record.input.reserved_at,
        intent,
        None,
    )?;
    *stage = "source-setup";
    execution.bind(record.input.ownership.clone(), record.input.reserved_at)?;

    // The public caller continues normal renewals. This wrapper observes them;
    // it cannot turn capture activity into another renewable owner.
    let source = execution.directory()?.join("source");
    std::fs::DirBuilder::new().mode(0o700).create(&source)?;
    std::fs::File::open(execution.directory()?)?.sync_all()?;
    // This digest identifies the local capture directive, NOT builder intake.
    let mut claim = b"abird-owned-remote-capture-claim-v1\n".to_vec();
    claim.extend(serde_json::to_vec(&record.input)?);
    let input = native_intent::CaptureInput {
        intent: intent.clone(),
        delivery_digest: abird_host_agent::sha256::digest_bytes(&claim),
        budget_millis: execution
            .deadline()?
            .saturating_duration_since(Instant::now())
            .as_millis()
            .try_into()?,
        roots: caller.account.capture_roots.clone(),
        limits: execution.policy.limits,
        nar_configuration: execution.policy.nar_configuration.clone(),
        runtime_closure: execution.policy.runtime_closure.clone(),
    };
    input.validate()?;
    let lease_deadline = lease_deadline(lease, intent, execution)?;
    let finished = AtomicBool::new(false);
    // Quiesce metadata SSH while checking all original groups before delivery.
    let observation = std::sync::Mutex::new(());
    *stage = "source";
    std::thread::scope(|threads| {
        let watcher = threads.spawn(|| -> Result<()> {
            let _stop_on_exit = StopUnfinishedCapture {
                execution,
                finished: &finished,
            };
            let mut lease = lease;
            let mut lease_cutoff = lease_deadline;
            let mut next = Instant::now();
            let mut stopped = false;
            while !finished.load(Ordering::Acquire) {
                stopped |= execution.active().is_err()
                    || Instant::now() >= lease_cutoff
                    || !now().is_ok_and(|time| time < lease);
                if stopped {
                    // Keep closing a spawn racing the stop request. The source
                    // orchestration cannot publish or start a later stage.
                    execution.stop()?;
                    if Instant::now() >= execution.deadline()? {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(10));
                    continue;
                }
                if Instant::now() >= next {
                    let _observation = observation
                        .lock()
                        .map_err(|_| anyhow::anyhow!("capture observation poisoned"))?;
                    // Each metadata observation gets a fresh local window from
                    // authenticated renewal, capped by the original execution.
                    // Never widen Installed's nonrenewable window in place.
                    let mut observer =
                        Installed::for_capture(scope.clone(), Some(caller.account.clone()))?;
                    observer.observe_until(lease_cutoff);
                    // Transport loss is not a terminal result. The last
                    // authenticated lease remains the nonrenewable limit.
                    if let Ok(response) = observe(&mut observer, &target, intent) {
                        if finished.load(Ordering::Acquire) {
                            break;
                        }
                        let delivery = execution.record()?.delivery_claim;
                        match admitted(
                            &response,
                            &record.input.ownership,
                            record.input.reserved_at,
                            intent,
                            delivery.as_deref(),
                        ) {
                            Ok(updated) if updated > lease => {
                                lease = updated;
                                lease_cutoff = self::lease_deadline(updated, intent, execution)?;
                            }
                            Ok(updated) if updated == lease => {}
                            Ok(_) => {
                                stopped = true;
                                execution.stop()?;
                            }
                            Err(_) => {
                                stopped = true;
                                execution.stop()?;
                            }
                        }
                    }
                    next = Instant::now() + Duration::from_secs(2);
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            ensure!(!stopped, "capture owner expired or cancelled");
            Ok(())
        });
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let captured = super::capture::remote::run(execution, input, pending, &source)?;
            *stage = "delivery";
            execution.active()?;
            captured.validate(intent)?;
            let delivery = native_intent::Delivery::RemoteCaptured {
                remote: Box::new(captured),
            };
            let bytes = serde_json::to_vec(&delivery)?;
            drop(delivery);
            native_intent::Delivery::decode(&bytes, intent)?;
            // Recheck after all offline producers settle and before the only upload.
            transport.observe_until(execution.deadline()?);
            let _observation = observation
                .lock()
                .map_err(|_| anyhow::anyhow!("capture observation poisoned"))?;
            *stage = "delivery-admission";
            let fresh = observe(&mut transport, &target, intent)?;
            admitted(
                &fresh,
                &record.input.ownership,
                record.input.reserved_at,
                intent,
                None,
            )?;
            let digest = abird_host_agent::sha256::digest_bytes(&bytes);
            *stage = "delivery-claim";
            execution.claim_delivery(&digest)?;
            drop(_observation);

            let key = &execution.policy.relay_key;
            capture_role::trusted_ssh_file(key, true)?;
            let mut relay_target = target.clone();
            relay_target.route.endpoint.user = execution.policy.relay_user.clone();
            relay_target.route.endpoint.identity = Some(key.clone());
            let mut relay = Installed::for_relay(scope.clone(), execution.policy.relay_port)?;
            relay.observe_until(execution.deadline()?);
            execution.active()?;
            *stage = "delivery";
            relay.native_inputs(&relay_target, intent, &bytes)
        }))
        .map_err(|_| anyhow::anyhow!("remote source capture panicked"))
        .and_then(|result| result);
        finished.store(true, Ordering::Release);
        let observed = watcher
            .join()
            .map_err(|_| anyhow::anyhow!("capture observer panicked"))?;
        observed?;
        result
    })
}

struct StopUnfinishedCapture<'a> {
    execution: &'a Execution,
    finished: &'a AtomicBool,
}

impl Drop for StopUnfinishedCapture<'_> {
    fn drop(&mut self) {
        if !self.finished.load(Ordering::Acquire) {
            // Error/panic in status observation cannot silently abandon the
            // offline producer. This is a stop request, never settlement proof.
            let _ = self.execution.stop();
        }
    }
}

fn observe(
    transport: &mut Installed,
    target: &HostExecutionTarget,
    intent: &native_intent::Request,
) -> Result<protocol::Response> {
    let request = Request {
        version: protocol::VERSION,
        command: Command::Status {
            attempt_id: intent.attempt_id()?,
        },
    };
    // Use the configured transport bound, capped by the original lease/window.
    // A two-second override spuriously failed under an accounted busy builder.
    let response = transport.request(target, &request)?;
    response.validate_for(&request)?;
    ensure!(
        matches!(response.reply, Reply::Status { .. }),
        "capture admission observation unavailable"
    );
    Ok(response)
}

fn admitted(
    response: &protocol::Response,
    owner: &abird_host_agent::build_executor::Ownership,
    reserved: u64,
    intent: &native_intent::Request,
    delivery: Option<&str>,
) -> Result<u64> {
    let Reply::Status { snapshot } = &response.reply else {
        anyhow::bail!("capture status unavailable")
    };
    let Snapshot::Live {
        acceptance,
        phase: abird_host_agent::build_executor::Phase::Running,
        ownership: Some(observed),
        reserved_at: Some(started),
        renewed_at,
        outcome: None,
        input: Some(input),
        ..
    } = snapshot.as_ref()
    else {
        anyhow::bail!("builder no longer admits this capture")
    };
    use abird_host_agent::build_executor::source_transport::InputState;
    ensure!(
        match input {
            InputState::Ready => true,
            InputState::Received { digest } => delivery == Some(digest.as_str()),
        },
        "capture intake differs from its original delivery"
    );
    ensure!(
        acceptance.attempt_id == intent.attempt_id()?
            && acceptance.spec_digest == intent.digest()?
            && observed == owner
            && *started == reserved,
        "capture admission ownership differs"
    );
    let lease = renewed_at
        .checked_add(intent.deadlines.owner_seconds)
        .context("capture lease overflow")?;
    ensure!(now()? < lease, "capture owner lease expired");
    Ok(lease)
}

fn lease_deadline(
    lease: u64,
    intent: &native_intent::Request,
    execution: &Execution,
) -> Result<Instant> {
    let remaining = lease
        .checked_sub(now()?)
        .filter(|seconds| *seconds > 0)
        .context("capture lease expired")?
        .min(intent.deadlines.owner_seconds);
    Ok(execution
        .deadline()?
        .min(Instant::now() + Duration::from_secs(remaining)))
}

fn now() -> Result<u64> {
    Ok(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs())
}
