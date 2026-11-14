//! One caller controller over immutable child intents. No selection, realization,
//! remote process killing, successor creation, release or deployment authority.

use std::collections::BTreeMap;

use abird_host_agent::build_executor::{
    Outcome, Phase,
    preparation::worker::Planning,
    protocol::{self, Command, Reply, Request, Response, Snapshot},
};
use anyhow::{Context, Result, ensure};

use super::{Manifest, RetainedPlanning, Run};
use crate::fleet::build_backend::agent::control::transport::Transport;

pub(in crate::fleet) fn submit(
    run: &mut Run,
    transport: &mut impl Transport,
) -> Result<BTreeMap<String, Response>> {
    let mut replies = BTreeMap::new();
    let attempts = run.manifest.children.keys().cloned().collect::<Vec<_>>();
    for attempt in attempts {
        let request = run.claim_submit(&attempt)?;
        let response = transport.request(&run.manifest.children[&attempt].target, &request)?;
        run.accept(&attempt, &response)?;
        let accepted = matches!(response.reply, Reply::Accepted { .. });
        replies.insert(attempt, response);
        if !accepted {
            break;
        } // Unknown admission never opens the tail.
    }
    Ok(replies)
}

/// Pure remote observation: can run beside an attached writer and does not need
/// source regeneration, a material file, capability renewal or the writer mutex.
pub(in crate::fleet) fn status(
    manifest: &Manifest,
    transport: &mut impl Transport,
) -> Result<BTreeMap<String, Response>> {
    manifest.validate()?;
    manifest
        .children
        .iter()
        .map(|(attempt, child)| {
            let request = child.status_request()?;
            let response = transport.request(&child.target, &request)?;
            child.validate_status(&response)?;
            Ok((attempt.clone(), response))
        })
        .collect()
}

pub(in crate::fleet) fn captures_settled(
    manifest: &Manifest,
    transport: &mut impl Transport,
    cancel: bool,
) -> Result<bool> {
    super::capture::observed(manifest, transport, cancel)
}

/// Withdrawal is atomic with remote submit deduplication, closing the lost-send
/// race. Accepted is still only a stop ACK; callers must observe settlement.
pub(in crate::fleet) fn cancel(
    manifest: &Manifest,
    transport: &mut impl Transport,
) -> Result<BTreeMap<String, Response>> {
    manifest.validate()?;
    manifest
        .children
        .iter()
        .map(|(attempt, child)| {
            let request = Request {
                version: protocol::VERSION,
                command: child.request.withdraw(),
            };
            let response = transport.request(&child.target, &request)?;
            response.validate_for(&request)?;
            Ok((attempt.clone(), response))
        })
        .collect()
}

/// One bounded observation pass. Reattachment cannot submit, replay delivered
/// source or reset remote drain/deadline clocks. Material is opened only after
/// authenticated InputReady and an original live ownership receipt.
pub(in crate::fleet) fn poll(
    run: &mut Run,
    transport: &mut impl Transport,
    mut material: impl FnMut(&str) -> Result<Option<Vec<u8>>>,
) -> Result<BTreeMap<String, Response>> {
    let cancelling = run.cancelled()?;
    if cancelling {
        cancel(&run.manifest, transport)?;
    }
    let attempts = run.manifest.children.keys().cloned().collect::<Vec<_>>();
    let mut replies = BTreeMap::new();
    for attempt in attempts {
        let child = &run.manifest.children[&attempt];
        let response = transport.request(&child.target, &child.status_request()?)?;
        let confirmed = matches!(response.reply, Reply::Status { .. });
        // The durable merge validates exact acceptance/spec as well as attempt.
        let copy = Response::decode(&response.encode()?)?;
        run.observe(&attempt, copy)?;
        replies.insert(attempt.clone(), response);
        let child = &run.manifest.children[&attempt];
        let source_stop = cancelling
            || run.cancelled()?
            || matches!(
                child.snapshot,
                Some(Snapshot::Live {
                    phase: Phase::Stopping,
                    ..
                })
            )
            || child
                .outcome()
                .is_some_and(|outcome| !matches!(outcome, Outcome::Succeeded { .. }));
        super::capture::poll(run, transport, &attempt, source_stop)?;
        if !confirmed {
            continue;
        }
        let child = &run.manifest.children[&attempt];
        if child.settled() || child.snapshot.is_none() {
            continue;
        }
        let stopping = matches!(
            child.snapshot,
            Some(Snapshot::Live {
                phase: Phase::Stopping,
                ..
            })
        );
        if cancelling || stopping || run.cancelled()? {
            continue;
        }
        if child.token.is_some() {
            let request = child.renew_request()?;
            let response = transport.request(&child.target, &request)?;
            response.validate_for(&request)?;
            if !matches!(response.reply, Reply::Renewed { .. }) {
                continue;
            }
        }
        let child = &run.manifest.children[&attempt];
        let request = child.events_request()?;
        let response = transport.request(&child.target, &request)?;
        if child.remote_capture.is_some()
            && child.input_claimed.is_none()
            && matches!(&response.reply, Reply::Events { page } if page.events.iter().any(|event|
                matches!(&event.detail, abird_host_agent::build_executor::events::EventKind::InputsReceived { .. })))
        {
            // Intake can race the preceding source-status read. Obtain the
            // original root delivery claim; never infer one from event bytes.
            super::capture::poll(run, transport, &attempt, false)?;
            if run.manifest.children[&attempt].input_claimed.is_none() {
                continue; // Preserve the cursor until the bound claim is known.
            }
        }
        run.observe_events(&request, response)?;
        let child = &run.manifest.children[&attempt];
        let active = matches!(
            &child.snapshot,
            Some(Snapshot::Live {
                ownership: Some(_),
                phase: Phase::Starting | Phase::Running,
                outcome: None,
                ..
            })
        );
        if !active || !child.input_ready || child.input_claimed.is_some() {
            continue;
        }
        if child.needs_local_capture() || child.needs_remote_capture() {
            // Fresh status plus InputReady gates the durable one-shot claim.
            // The ordinary caller never reads Git/profile/source bytes here.
            let remote = child.needs_remote_capture();
            let request = child.status_request()?;
            let response = transport.request(&child.target, &request)?;
            let claim = run.claim_capture(&attempt, response)?;
            if remote {
                if let Some(status) =
                    crate::fleet::build_backend::agent::remote_capture::begin(transport, &claim)?
                {
                    run.observe_capture(&attempt, status)?;
                }
                continue;
            }
            let directive = abird_host_agent::build_executor::native_intent::Capture {
                version: 1,
                capture: true,
                request_digest: claim.request.digest()?,
            };
            directive.validate(&claim.request)?;
            run.retain_capture(&attempt, &serde_json::to_vec(&directive)?)?;
        }
        let child = &run.manifest.children[&attempt];
        let bytes = match run.retained_material(&attempt)? {
            Some(bytes) => Some(bytes),
            None if matches!(child.request, super::Intent::Native(_)) => None,
            None => material(&attempt)?,
        };
        let Some(bytes) = bytes else {
            continue;
        };
        run.claim_inputs(&attempt, &bytes)?;
        let child = &run.manifest.children[&attempt];
        let receipt = match &child.request {
            super::Intent::Build(request) => transport.inputs(&child.target, request, &bytes)?,
            super::Intent::Native(request) => {
                transport.native_inputs(&child.target, request, &bytes)?
            }
        };
        if let Some(receipt) = receipt {
            run.input_receipt(&receipt)?;
        }
    }
    Ok(replies)
}

// Only immutable page reads may retry an unavailable reply. Keep the exact
// request, offset and transport lifetime; persistence/rejection stays fail-closed.
fn projection_response(
    request: &Request,
    mut exchange: impl FnMut() -> Result<Response>,
) -> Result<Response> {
    ensure!(
        matches!(
            request.command,
            Command::Artifacts { .. } | Command::Planning { .. }
        ),
        "projection retry requires an immutable page request"
    );
    for attempt in 0..3 {
        let response = exchange()?;
        response.validate_for(request)?;
        if attempt == 2
            || !matches!(
                response.reply,
                Reply::Unconfirmed {
                    code: protocol::Unconfirmed::Unavailable
                }
            )
        {
            return Ok(response);
        }
        std::thread::park_timeout(std::time::Duration::from_millis(100));
    }
    unreachable!()
}

/// Read-only projection of the original settled artifact. This does not query
/// the flake again, copy store objects, acquire consumer roots or send an ACK.
pub(in crate::fleet) fn artifact(
    manifest: &Manifest,
    attempt: &str,
    transport: &mut impl Transport,
) -> Result<abird_host_agent::build_executor::ArtifactDelivery> {
    manifest.validate()?;
    // Consume one child at a time, not up to64 complete closure maps in memory.
    let child = manifest
        .children
        .get(attempt)
        .context("artifact child missing")?;
    let Some(Snapshot::Live {
        ownership: Some(owner),
        outcome: Some(Outcome::Succeeded { artifacts }),
        settled_at: Some(_),
        ..
    }) = &child.snapshot
    else {
        anyhow::bail!("artifact delivery requires the original settled Build receipt");
    };
    let mut bytes = Vec::new();
    let mut binding = None;
    loop {
        let request = Request {
            version: protocol::VERSION,
            command: protocol::Command::Artifacts {
                attempt_id: attempt.to_owned(),
                artifact_digest: artifacts.closure_digest.clone(),
                offset: bytes.len() as u64,
            },
        };
        let response =
            projection_response(&request, || transport.request(&child.target, &request))?;
        let Reply::Artifacts { page } = response.reply else {
            anyhow::bail!("artifact delivery unconfirmed; original protection remains required");
        };
        let current = (page.projection_digest, page.total);
        ensure!(
            binding.as_ref().is_none_or(|expected| expected == &current),
            "artifact projection changed between pages"
        );
        if binding.is_none() {
            binding = Some(current.clone());
        }
        bytes.extend(page.bytes);
        if bytes.len() as u64 == current.1 {
            ensure!(
                abird_host_agent::sha256::digest_bytes(&bytes) == current.0,
                "artifact projection checksum differs"
            );
            break;
        }
    }
    abird_host_agent::build_executor::ArtifactDelivery::decode(&bytes, owner, artifacts)
}

/// Native build/deploy continuation needs successful Build outcomes as well as
/// settlement. Observation-only attach/cancel deliberately use require_settled.
/// Neither check acknowledges consumption or authorizes release/deployment.
pub(in crate::fleet) fn require_successful_builds(
    replies: &BTreeMap<String, Response>,
) -> Result<()> {
    require_settled(replies)?;
    for (attempt, reply) in replies {
        let outcome = settled_outcome(reply).context("descendant settlement is unconfirmed")?;
        let reason = match outcome {
            Outcome::Succeeded { .. } => continue,
            Outcome::Failed { .. } => "failed",
            Outcome::Cancelled { .. } => "cancelled",
            Outcome::Interrupted => "interrupted",
            Outcome::MaintenanceSucceeded { .. } => "not a Build result",
        };
        anyhow::bail!("owned attempt {attempt} settled without build success: {reason}");
    }
    Ok(())
}

fn settled_outcome(reply: &Response) -> Option<&Outcome> {
    let Reply::Status { snapshot } = &reply.reply else {
        return None;
    };
    match snapshot.as_ref() {
        Snapshot::Retired { outcome, .. }
        | Snapshot::Live {
            outcome: Some(outcome),
            settled_at: Some(_),
            ..
        } => Some(outcome),
        _ => None,
    }
}

pub(in crate::fleet) fn require_settled(replies: &BTreeMap<String, Response>) -> Result<()> {
    ensure!(
        !replies.is_empty()
            && replies
                .values()
                .all(|reply| settled_outcome(reply).is_some()),
        "descendant settlement is unconfirmed; observe the original run"
    );
    Ok(())
}

impl Run {
    pub fn retained_planning(&self, attempt: &str) -> Result<Option<Planning>> {
        let delivery = self
            .retained_artifact(attempt)?
            .context("artifact not retained")?;
        let child = self
            .manifest
            .children
            .get(attempt)
            .context("planning child missing")?;
        let consumption = child
            .consumption
            .as_ref()
            .context("consumer intent missing")?;
        let Some(planning) = &consumption.planning else {
            return Ok(None);
        };
        let file = planning
            .file
            .as_ref()
            .context("planning publication unconfirmed; do not recreate it")?;
        let bytes = self.directory.read_planning(attempt, file)?;
        let planning = Planning::decode(&bytes, &delivery.prepared)?;
        child.request.validate_resolved(&planning.request)?;
        Ok(Some(planning))
    }

    pub fn retain_planning(&mut self, attempt: &str, planning: &Planning) -> Result<()> {
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        let delivery = self
            .retained_artifact(attempt)?
            .context("artifact not retained")?;
        planning.validate(&delivery.prepared)?;
        let bytes = serde_json::to_vec(planning)?;
        let child = self.child_mut(attempt)?;
        child.request.validate_resolved(&planning.request)?;
        let consumption = child
            .consumption
            .as_mut()
            .context("consumer intent missing")?;
        ensure!(
            consumption.planning.is_none() && consumption.acquisition.is_none(),
            "planning retention already claimed or acquisition started"
        );
        consumption.planning = Some(RetainedPlanning {
            bytes: bytes.len() as u64,
            file: None,
        });
        self.save()?;
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        self.poisoned = true;
        let file = self.directory.retain_planning(attempt, &bytes)?;
        self.manifest
            .children
            .get_mut(attempt)
            .context("planning child vanished")?
            .consumption
            .as_mut()
            .context("consumer intent vanished")?
            .planning
            .as_mut()
            .context("planning intent vanished")?
            .file = Some(file);
        self.save()
    }

    /// Metadata-only, bounded by the already retained artifact's planning digest.
    pub fn planning(
        &mut self,
        attempt: &str,
        transport: &mut impl Transport,
    ) -> Result<Option<Planning>> {
        ensure!(!self.cancelled()?, "durable parent is cancelling");
        if let Some(planning) = self.retained_planning(attempt)? {
            return Ok(Some(planning));
        }
        let delivery = self
            .retained_artifact(attempt)?
            .context("artifact not retained")?;
        let Some(digest) = &delivery.prepared.planning_digest else {
            return Ok(None);
        };
        let child = self
            .manifest
            .children
            .get(attempt)
            .context("planning child missing")?;
        let mut bytes = Vec::new();
        let mut total = None;
        loop {
            ensure!(!self.cancelled()?, "durable parent is cancelling");
            let request = Request {
                version: protocol::VERSION,
                command: Command::Planning {
                    attempt_id: attempt.to_owned(),
                    artifact_digest: delivery.artifacts.closure_digest.clone(),
                    planning_digest: digest.clone(),
                    offset: bytes.len() as u64,
                },
            };
            let response =
                projection_response(&request, || transport.request(&child.target, &request))?;
            let Reply::Planning { page } = response.reply else {
                anyhow::bail!("private planning unavailable; original protection remains required");
            };
            ensure!(
                total.is_none_or(|expected| expected == page.total),
                "private planning changed between pages"
            );
            total = Some(page.total);
            bytes.extend(page.bytes);
            if bytes.len() as u64 == page.total {
                break;
            }
        }
        let planning = Planning::decode(&bytes, &delivery.prepared)?;
        self.retain_planning(attempt, &planning)?;
        Ok(Some(planning))
    }

    pub fn require_retained_planning(&self, attempt: &str) -> Result<()> {
        let delivery = self
            .retained_artifact(attempt)?
            .context("artifact not retained")?;
        if delivery.prepared.planning_digest.is_some() {
            self.retained_planning(attempt)?
                .context("planning not retained")?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use abird_host_agent::build_executor::{
        ArtifactReceipt, PoolHealth, StopReason, journal::Acceptance,
    };

    fn acceptance() -> Acceptance {
        Acceptance {
            attempt_id: "a".repeat(64),
            spec_digest: "b".repeat(64),
            sequence: 1,
        }
    }

    fn response(outcome: Outcome, settled: bool, retired: bool) -> Response {
        let phase = if !settled {
            Phase::Stopping
        } else {
            match &outcome {
                Outcome::Succeeded { .. } | Outcome::MaintenanceSucceeded { .. } => {
                    Phase::Succeeded
                }
                Outcome::Failed { .. } => Phase::Failed,
                Outcome::Cancelled { .. } => Phase::Cancelled,
                Outcome::Interrupted => Phase::Interrupted,
            }
        };
        let snapshot = if retired {
            Snapshot::Retired {
                pool: PoolHealth::Available,
                acceptance: acceptance(),
                outcome,
            }
        } else {
            Snapshot::Live {
                pool: PoolHealth::Draining,
                acceptance: acceptance(),
                phase,
                prepared_digest: None,
                input: None,
                outcome: Some(outcome),
                ownership: None,
                accepted_at: 1,
                renewed_at: 1,
                reserved_at: Some(1),
                settled_at: settled.then_some(2),
            }
        };
        Response {
            version: protocol::VERSION,
            reply: Reply::Status {
                snapshot: Box::new(snapshot),
            },
        }
    }

    #[test]
    fn projection_retries_only_unavailable_reads_of_the_original_page() {
        for planning in [false, true] {
            let command = if planning {
                Command::Planning {
                    attempt_id: "a".repeat(64),
                    artifact_digest: "b".repeat(64),
                    planning_digest: "c".repeat(64),
                    offset: 8192,
                }
            } else {
                Command::Artifacts {
                    attempt_id: "a".repeat(64),
                    artifact_digest: "b".repeat(64),
                    offset: 8192,
                }
            };
            let request = Request {
                version: protocol::VERSION,
                command,
            };
            let encoded = serde_json::to_vec(&request).unwrap();
            let mut calls = 0;
            let response = projection_response(&request, || {
                calls += 1;
                assert_eq!(serde_json::to_vec(&request).unwrap(), encoded);
                let reply = if calls < 3 {
                    Reply::Unconfirmed {
                        code: protocol::Unconfirmed::Unavailable,
                    }
                } else {
                    let page = abird_host_agent::build_executor::ArtifactPage {
                        attempt_id: "a".repeat(64),
                        artifact_digest: "b".repeat(64),
                        projection_digest: "c".repeat(64),
                        offset: 8192,
                        total: 8193,
                        bytes: vec![b'}'],
                    };
                    if planning {
                        Reply::Planning { page }
                    } else {
                        Reply::Artifacts { page }
                    }
                };
                Ok(Response {
                    version: protocol::VERSION,
                    reply,
                })
            })
            .unwrap();
            assert_eq!(calls, 3);
            response.validate_for(&request).unwrap();
        }
    }

    #[test]
    fn projection_retry_is_bounded_and_never_retries_persistence_or_mutation() {
        let request = Request {
            version: protocol::VERSION,
            command: Command::Artifacts {
                attempt_id: "a".repeat(64),
                artifact_digest: "b".repeat(64),
                offset: 0,
            },
        };
        for (code, expected) in [
            (protocol::Unconfirmed::Unavailable, 3),
            (protocol::Unconfirmed::Persistence, 1),
        ] {
            let mut calls = 0;
            let response = projection_response(&request, || {
                calls += 1;
                Ok(Response {
                    version: protocol::VERSION,
                    reply: Reply::Unconfirmed { code },
                })
            })
            .unwrap();
            assert_eq!(calls, expected);
            assert!(matches!(response.reply, Reply::Unconfirmed { .. }));
        }
        let mut calls = 0;
        let response = projection_response(&request, || {
            calls += 1;
            Ok(Response {
                version: protocol::VERSION,
                reply: Reply::Rejected {
                    code: protocol::Rejection::NotFound,
                },
            })
        })
        .unwrap();
        assert_eq!(calls, 1);
        assert!(matches!(response.reply, Reply::Rejected { .. }));
        let mut invalid = request;
        invalid.command = Command::Cancel {
            attempt_id: "a".repeat(64),
            expected: None,
        };
        assert!(projection_response(&invalid, || panic!("mutation must not be sent")).is_err());
    }

    #[test]
    fn native_continuation_needs_settled_build_success_not_stop_or_maintenance_ack() {
        // Caller decision logic only; these synthetic observations prove no OS settlement.
        let success = Outcome::Succeeded {
            artifacts: ArtifactReceipt {
                spec_digest: "b".repeat(64),
                preparation_digest: "c".repeat(64),
                closure_digest: "d".repeat(64),
                roots_digest: "e".repeat(64),
            },
        };
        let outcomes = [
            success,
            Outcome::Cancelled {
                reason: StopReason::Cancelled,
            },
            Outcome::Failed {
                reason: StopReason::VerificationFailed,
            },
            Outcome::Interrupted,
            Outcome::MaintenanceSucceeded {
                verification_digest: "f".repeat(64),
            },
        ];
        for outcome in outcomes {
            let successful = matches!(&outcome, Outcome::Succeeded { .. });
            let pending =
                BTreeMap::from([("a".repeat(64), response(outcome.clone(), false, false))]);
            assert!(require_settled(&pending).is_err());
            assert!(require_successful_builds(&pending).is_err());
            for retired in [false, true] {
                let replies =
                    BTreeMap::from([("a".repeat(64), response(outcome.clone(), true, retired))]);
                require_settled(&replies).unwrap();
                assert_eq!(require_successful_builds(&replies).is_ok(), successful);
            }
        }
        let ack = BTreeMap::from([(
            "a".repeat(64),
            Response {
                version: protocol::VERSION,
                reply: Reply::StopRequested {
                    attempt_id: "a".repeat(64),
                },
            },
        )]);
        assert!(require_settled(&ack).is_err());
        assert!(require_successful_builds(&ack).is_err());
        assert!(require_successful_builds(&BTreeMap::new()).is_err());
    }
}
