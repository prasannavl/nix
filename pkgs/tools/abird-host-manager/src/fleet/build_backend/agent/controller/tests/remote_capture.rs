//! Protocol/durability regression in the existing isolated subprocess harness.
//! Synthetic settlement is not evidence of OS/cgroup or installed capture safety.

use super::*;
use abird_host_agent::build_executor::{
    Outcome, Ownership, Phase, PoolHealth, capture_role as role,
    events::{Event, EventCursor, EventKind, EventPage},
    native_intent,
    source_transport::InputState,
};

struct CaptureTransport {
    intent: Option<native_intent::Request>,
    claim: Option<Vec<u8>>,
    begins: usize,
    unknown: bool,
    received: bool,
    stopped: bool,
    phase: role::Phase,
    cancelled: bool,
    released: bool,
    lose_ack: bool,
    pruned: bool,
}

impl CaptureTransport {
    fn new() -> Self {
        Self {
            intent: None,
            claim: None,
            begins: 0,
            unknown: false,
            received: false,
            stopped: false,
            phase: role::Phase::Running,
            cancelled: false,
            released: false,
            lose_ack: false,
            pruned: false,
        }
    }

    fn intent(&self) -> &native_intent::Request {
        self.intent.as_ref().unwrap()
    }
    fn owner(&self) -> Ownership {
        Ownership {
            executor_version: 1,
            builder_id: self.intent().builder.host_id.clone(),
            store_id: self.intent().storage.store_id.clone(),
            attempt_id: self.intent().attempt_id().unwrap(),
            pool_epoch: 1.try_into().unwrap(),
            boot_id: "capture-fixture".into(),
        }
    }
    fn acceptance(&self) -> Acceptance {
        Acceptance {
            attempt_id: self.intent().attempt_id().unwrap(),
            spec_digest: self.intent().digest().unwrap(),
            sequence: 1,
        }
    }
    fn source(&self) -> role::Reply {
        role::Reply::Status {
            status: Box::new(role::Status {
                attempt: self.intent().attempt_id().unwrap(),
                request_digest: self.intent().digest().unwrap(),
                phase: self.phase,
                cancelled: self.cancelled,
                data_released: self.released,
                delivery_claim: self.received.then(|| "c".repeat(64)),
                receipt: (self.received && self.phase == role::Phase::Settled).then(|| Receipt {
                    version: 1,
                    attempt_id: self.intent().attempt_id().unwrap(),
                    request_digest: self.intent().digest().unwrap(),
                    material_digest: "c".repeat(64),
                }),
            }),
        }
    }
}

impl Transport for CaptureTransport {
    fn capture(&mut self, command: &role::Command) -> Result<role::Reply> {
        match command {
            role::Command::Begin { input } => {
                input.validate()?;
                ensure!(self.claim.is_none(), "source capture was replayed");
                self.claim = Some(serde_json::to_vec(input)?);
                self.begins += 1;
                // Root accepted the original claim, but its reply was lost.
                return Ok(role::Reply::Unconfirmed);
            }
            role::Command::Revoke { input } => {
                input.validate()?;
                let bytes = serde_json::to_vec(input)?;
                if let Some(old) = &self.claim {
                    ensure!(
                        old == &bytes,
                        "capture ownership/reservation/pending changed"
                    );
                } else {
                    self.claim = Some(bytes);
                    self.phase = role::Phase::Revoked;
                    self.released = true;
                }
                self.cancelled = true;
            }
            role::Command::Status {
                attempt,
                request_digest,
            } => {
                ensure!(
                    attempt == &self.intent().attempt_id()?
                        && request_digest == &self.intent().digest()?,
                    "capture status identity changed"
                );
                if self.unknown {
                    return Ok(role::Reply::Unconfirmed);
                }
            }
            role::Command::Acknowledge { request } => {
                ensure!(
                    request.as_ref() == self.intent() && self.phase.terminal() && self.released,
                    "root retention ACK precedes original source closure"
                );
                if std::mem::take(&mut self.lose_ack) {
                    return Ok(role::Reply::Unconfirmed);
                }
                if self.pruned {
                    return Ok(role::Reply::RetentionClosed {
                        attempt: request.attempt_id()?,
                        request_digest: request.digest()?,
                    });
                }
            }
            _ => anyhow::bail!("unexpected capture operation"),
        }
        Ok(self.source())
    }

    fn request(&mut self, _target: &HostExecutionTarget, request: &Request) -> Result<Response> {
        let reply = match &request.command {
            protocol::Command::SubmitNative { request } => {
                ensure!(self.intent.is_none(), "native admission replayed");
                self.intent = Some((**request).clone());
                Reply::Accepted {
                    acceptance: self.acceptance(),
                }
            }
            protocol::Command::WithdrawNative { request } => {
                ensure!(
                    request.as_ref() == self.intent(),
                    "withdrawal changed intent"
                );
                self.stopped = true;
                Reply::Accepted {
                    acceptance: self.acceptance(),
                }
            }
            protocol::Command::Status { .. } => Reply::Status {
                snapshot: Box::new(if self.stopped {
                    protocol::Snapshot::Retired {
                        pool: PoolHealth::Available,
                        acceptance: self.acceptance(),
                        outcome: Outcome::Interrupted,
                    }
                } else {
                    let now = self.intent().id.issued_at + 1;
                    protocol::Snapshot::Live {
                        pool: PoolHealth::Owned,
                        acceptance: self.acceptance(),
                        phase: Phase::Running,
                        prepared_digest: None,
                        outcome: None,
                        ownership: Some(self.owner()),
                        input: Some(if self.received {
                            InputState::Received {
                                digest: "c".repeat(64),
                            }
                        } else {
                            InputState::Ready
                        }),
                        accepted_at: now,
                        renewed_at: now,
                        reserved_at: Some(now),
                        settled_at: None,
                    }
                }),
            },
            protocol::Command::Renew { attempt_id, .. } => Reply::Renewed {
                attempt_id: attempt_id.clone(),
            },
            protocol::Command::Events {
                attempt_id, cursor, ..
            } => {
                let latest = 2 + u64::from(self.received);
                let events = [
                    EventKind::Accepted,
                    EventKind::InputReady,
                    EventKind::InputsReceived {
                        digest: "c".repeat(64),
                    },
                ]
                .into_iter()
                .enumerate()
                .filter(|(index, _)| {
                    (*index as u64) < latest
                        && (*index as u64) >= cursor.as_ref().map_or(0, |cursor| cursor.after)
                })
                .map(|(index, detail)| Event {
                    sequence: index as u64 + 1,
                    at: self.intent().id.issued_at + 1,
                    detail,
                })
                .collect();
                Reply::Events {
                    page: EventPage {
                        next: EventCursor {
                            attempt_id: attempt_id.clone(),
                            after: latest,
                        },
                        oldest: Some(1),
                        latest,
                        gap: false,
                        more: false,
                        retired: false,
                        events,
                    },
                }
            }
            _ => anyhow::bail!("unexpected builder operation"),
        };
        let response = Response {
            version: protocol::VERSION,
            reply,
        };
        response.validate_for(request)?;
        Ok(response)
    }

    fn inputs(
        &mut self,
        _: &HostExecutionTarget,
        _: &BuildRequest,
        _: &[u8],
    ) -> Result<Option<Receipt>> {
        anyhow::bail!("ordinary caller must not transport source bytes")
    }
    // native_inputs deliberately retains the rejecting default implementation.
}

fn caller(root: &Path) -> (Controller, CaptureTransport, String) {
    let pending = PendingCapture {
        invocation: invocation(),
        cwd: root.join("absent-capture-source"),
        bootstrap: Some(crate::fleet::build_backend::agent::bootstrap::Reference {
            path: "/nix/store/00000000000000000000000000000000-fixture-bootstrap".into(),
            digest: "a".repeat(64),
        }),
        environment: Some(
            serde_json::from_value(serde_json::json!({
                "values": {"HOME": "/absent-capture-home"}, "uid": 2700, "gid": 2700,
                "groups": [], "umask": 18, "defaults": {},
            }))
            .unwrap(),
        ),
    };
    let mut bound = binding();
    bound.target.local = false;
    let trust = root.join("fixture-known-hosts");
    std::fs::write(&trust, "ci.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n").unwrap();
    bound.target.known_hosts_file = Some(trust);
    let mut parent = admit(pending, bound).unwrap();
    let attempt = parent
        .run
        .manifest()
        .children
        .keys()
        .next()
        .unwrap()
        .clone();
    let mut transport = CaptureTransport::new();
    parent.submit(&mut transport).unwrap();
    (parent, transport, attempt)
}

pub(super) fn run(root: &Path) {
    let (mut parent, mut transport, attempt) = caller(root);
    let id = parent.run_id().to_owned();
    parent.poll(&mut transport).unwrap();
    assert_eq!(transport.begins, 1);
    let original = serde_json::to_value(parent.run.manifest()).unwrap()["children"][&attempt]
        ["remote_capture"]["ownership"].clone();
    drop(parent);
    let mut parent = Controller::open(&id).unwrap();
    transport.received = true;
    transport.unknown = true;
    parent.poll(&mut transport).unwrap();
    let state = serde_json::to_value(parent.run.manifest()).unwrap();
    assert!(state["children"][&attempt]["input_claimed"].is_null());
    assert!(state["children"][&attempt]["input_received"].is_null());
    assert_eq!(
        state["children"][&attempt]["snapshot"]["input"]["digest"],
        "c".repeat(64)
    );
    transport.unknown = false;
    parent.poll(&mut transport).unwrap();
    let state = serde_json::to_value(parent.run.manifest()).unwrap();
    assert_eq!(
        state["children"][&attempt]["input_received"],
        "c".repeat(64)
    );
    assert_eq!(
        state["children"][&attempt]["remote_capture"]["ownership"],
        original
    );
    assert_eq!(transport.begins, 1);
    transport.stopped = true;
    let replies = parent.poll(&mut transport).unwrap();
    controller::require_settled(&replies).unwrap();
    assert!(!parent.captures_settled());
    assert!(parent.retire().is_err());
    let mut parent = Controller::open(&id).unwrap();
    transport.phase = role::Phase::Settled;
    transport.released = true;
    transport.lose_ack = true;
    parent.poll(&mut transport).unwrap();
    assert!(parent.captures_settled());
    assert!(parent.retire().is_err());
    // Lost retention reply followed by root metadata pruning is not permanent
    // uncertainty. Only the separate replay-floor proof closes this receipt.
    let mut parent = Controller::open(&id).unwrap();
    transport.pruned = true;
    parent.poll(&mut transport).unwrap();
    parent.retire().unwrap();
    assert!(Run::inspect(&id).is_err());
    assert_eq!(transport.begins, 1);

    let (mut parent, mut transport, attempt) = caller(root);
    let id = parent.run_id().to_owned();
    parent.claim_capture(&attempt, &mut transport).unwrap();
    drop(parent); // Caller died after saving its claim, before sending Begin.
    let (manifest, durable) = Run::request_cancel(&id).unwrap();
    assert!(durable);
    controller::cancel(&manifest, &mut transport).unwrap();
    assert!(controller::captures_settled(&manifest, &mut transport, true).unwrap());
    let mut parent = Controller::open(&id).unwrap();
    parent.poll(&mut transport).unwrap();
    assert_eq!(transport.phase, role::Phase::Revoked);
    assert_eq!(transport.begins, 0);
    parent.retire().unwrap();
    assert!(Run::inspect(&id).is_err());
    assert!(!root.join("absent-capture-source").exists());
}
