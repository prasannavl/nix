//! Shared fleet/CI owned-job frontend. Request construction remains with the
//! native caller adapter; this layer only submits immutable intent and observes
//! its durable children. No selector, realization or deployment fallback.

use std::collections::BTreeMap;
use std::fs::OpenOptions;
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use abird_host_agent::build_executor::{protocol, request::BuildRequest};
use anyhow::{Context, Result, ensure};
use serde::Deserialize;

use crate::fleet::build_backend::agent::control::transport::{Installed, Transport};
use crate::fleet::build_backend::agent::run::{Child, Manifest, Run, controller};
use crate::fleet::host_runtime::HostExecutionTarget;

mod observations;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Submission {
    version: u32,
    run_id: String,
    children: Vec<Intent>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Intent {
    request: BuildRequest,
    target: HostExecutionTarget,
    owner_token: Option<String>,
}

const USAGE: &str = "fleet build-controller submit PRIVATE-INTENT.json\n\
  fleet build-controller status RUN\n\
  fleet build-controller attach RUN [--input ATTEMPT=PRIVATE-MATERIAL.json] [--wait-seconds N]\n\
  fleet build-controller cancel RUN [--wait-seconds N]\n\
  fleet build-controller consume RUN [--wait-seconds N]\n\
  fleet build-controller retire RUN [--wait-seconds N]\n\
  fleet build-controller events RUN [--after ATTEMPT=SEQUENCE]\n\
  fleet build-controller logs RUN [--cursor ATTEMPT=GENERATION:OFFSET]\n\
Logs contain bounded lifecycle diagnostics, not arbitrary subprocess output.\n\
Submit/stop ACKs are not settlement. Reconnect never resubmits or repeats delivered source.\n\
Status settlement_scope is builder; caller lock release is not target activation settlement.\n\
Cancel records durable forward withdrawal and waits for builder settlement and caller exit.\n\
A Deploy with a successful build still exits unconfirmed without target-settlement evidence.\n\
Consume reconciles the original signed acquisition/ACK with the same immutable binding, then\n\
a Deploy run's ordinary deployment phases from retained planning, then retires\n\
the caller record. Retire waits for builder cleanup; unacknowledged acquisitions\n\
require exact authenticated abandonment, not a fabricated ACK. Caller retirement\n\
never certifies target activation/rollback settlement.\n";

/// Both public frontends call this before repository discovery/re-exec. Returns
/// None for their ordinary command surface, preserving legacy dispatch.
pub fn dispatch(arguments: &[String]) -> Option<Result<()>> {
    (arguments
        .first()
        .is_some_and(|arg| matches!(arg.as_str(), "build-controller" | "owned")))
    .then(|| run(&arguments[1..]))
}

fn run(arguments: &[String]) -> Result<()> {
    crate::fleet::signal::install()?;
    let Some(verb) = arguments.first().map(String::as_str) else {
        print!("{USAGE}");
        return Ok(());
    };
    if matches!(verb, "help" | "--help" | "-h") {
        print!("{USAGE}");
        return Ok(());
    }
    let identity = arguments
        .get(1)
        .context("owned operation needs a run ID or private intent file")?;
    let mut transport = Installed::default();
    if matches!(verb, "events" | "logs") {
        return observations::run(identity, &arguments[2..], verb == "logs", &mut transport);
    }
    let (inputs, wait) = options(&arguments[2..])?;
    let deadline = Instant::now() + wait;
    match verb {
        "submit" => {
            ensure!(
                arguments.len() == 2,
                "submit accepts only the immutable intent file"
            );
            let bytes = read_private(Path::new(identity), 8 * 1024 * 1024)?;
            let submission: Submission = serde_json::from_slice(&bytes)
                .map_err(|_| anyhow::anyhow!("invalid owned submission"))?;
            ensure!(
                submission.version == 1
                    && !submission.children.is_empty()
                    && submission.children.len() <= 64,
                "invalid owned submission bounds"
            );
            let mut children = BTreeMap::new();
            for intent in submission.children {
                let attempt = intent.request.attempt_id()?;
                ensure!(
                    children
                        .insert(
                            attempt,
                            Child::new(intent.request, intent.target, intent.owner_token)?
                        )
                        .is_none(),
                    "duplicate owned child"
                );
            }
            super::controller::consumer_nix()?;
            let mut run = Run::create(Manifest {
                version: 3,
                run_id: submission.run_id,
                children,
            })?;
            println!(
                "{}",
                serde_json::json!({"run_id": run.manifest().run_id, "state": "recorded", "path": run.path(),
                "attempts": run.manifest().children.keys().collect::<Vec<_>>() })
            );
            let responses = controller::submit(&mut run, &mut transport)?;
            report(&run.manifest().run_id, &responses)?;
            ensure!(
                responses.len() == run.manifest().children.len()
                    && responses
                        .values()
                        .all(|response| matches!(response.reply, protocol::Reply::Accepted { .. })),
                "submission unconfirmed or rejected; observe this run, never repeat submission"
            );
            Ok(())
        }
        "status" => {
            ensure!(arguments.len() == 2, "status accepts only a run ID");
            let manifest = Run::inspect(identity)?;
            report(identity, &controller::status(&manifest, &mut transport)?)
        }
        "cancel" => {
            ensure!(inputs.is_empty(), "cancel cannot supply source data");
            transport.observe_until(deadline);
            let (manifest, durable) = Run::request_cancel(identity)?;
            println!(
                "{}",
                serde_json::json!({"run_id": identity, "local_cancel_intent_durable": durable})
            );
            report(identity, &controller::cancel(&manifest, &mut transport)?)?;
            ensure!(
                durable,
                "builder withdrawal attempted, but local cancellation could not be persisted; caller/target outcome unconfirmed"
            );
            let completion = std::cell::Cell::new(false);
            let responses = observe_result_until(
                identity,
                deadline,
                || {
                    let responses = controller::status(&Run::inspect(identity)?, &mut transport)?;
                    let inactive = !Run::caller_active(identity)?;
                    // Re-read after exclusion: a final claim may have raced the
                    // initial cancel snapshot, before its writer exited.
                    let latest = Run::inspect(identity)?;
                    let sources = controller::captures_settled(&latest, &mut transport, true)?;
                    completion.set(inactive && sources);
                    Ok(responses)
                },
                || Ok(completion.get()),
            )?;
            // A failed/cancelled build cannot have entered retained deployment.
            // A successful one may have: local exclusion alone cannot certify
            // detached target effects, even after a cooperative caller exits.
            if manifest.children.iter().any(|(attempt, child)| {
                let deployment = child.pending_capture().is_some_and(|pending| {
                    matches!(pending.invocation.action, crate::fleet::cli::Action::Deploy)
                }) || child.native.as_ref().is_some_and(|native| {
                    matches!(native.effective.action, crate::fleet::cli::Action::Deploy)
                });
                deployment
                    && responses
                        .get(attempt)
                        .is_some_and(successful_builder_observation)
            }) {
                anyhow::bail!(
                    "builder attempts settled and caller inactive; target activation/rollback settlement remains unconfirmed"
                );
            }
            Ok(())
        }
        "consume" => {
            ensure!(inputs.is_empty(), "consume cannot supply source data");
            transport.observe_until(deadline);
            let manifest = Run::inspect(identity)?;
            ensure!(
                !manifest.service_owned(),
                "CI-owned consumption belongs to its controller service"
            );
            controller::require_successful_builds(&controller::status(&manifest, &mut transport)?)?;
            let parent =
                crate::fleet::build_backend::agent::controller::Controller::open(identity)?;
            let invocations = manifest
                .children
                .keys()
                .filter_map(|attempt| parent.original_invocation(attempt).ok())
                .collect::<Vec<_>>();
            ensure!(invocations.len() <= 1, "one captured invocation per run");
            let lock = match invocations.first() {
                Some(invocation) => crate::fleet::runtime::action_mutex(invocation)?,
                None => crate::fleet::runtime::ActionLock::NotRequired,
            };
            crate::fleet::build_backend::agent::controller::hand_off(
                parent,
                &mut transport,
                deadline,
                &lock,
            )
        }
        "retire" => {
            ensure!(inputs.is_empty(), "retire cannot supply source data");
            transport.observe_until(deadline);
            crate::fleet::build_backend::agent::controller::Controller::open(identity)?
                .retire_observed(&mut transport, deadline)?;
            println!(
                "{}",
                serde_json::json!({"run_id": identity, "state": "retired", "settlement_scope": "builder",
                    "target_settlement": "not-certified"})
            );
            Ok(())
        }
        "attach" => {
            transport.observe_until(deadline);
            let manifest = Run::inspect(identity)?;
            if manifest.service_owned() {
                ensure!(
                    inputs.is_empty(),
                    "CI observer source cannot be replaced by attachment"
                );
                return observe_until(identity, deadline, || {
                    controller::status(&manifest, &mut transport)
                });
            }
            let mut run = Run::open(identity)?;
            ensure!(
                inputs
                    .keys()
                    .all(|attempt| run.manifest().children.contains_key(attempt)),
                "source names an unknown child"
            );
            ensure!(
                inputs.keys().all(|attempt| !run.has_material(attempt)),
                "retained native source cannot be replaced on attachment"
            );
            let sources = std::cell::Cell::new(false);
            observe_result_until(
                identity,
                deadline,
                || {
                    let replies = controller::poll(&mut run, &mut transport, |attempt| {
                        inputs
                            .get(attempt)
                            .map(|path| {
                                read_private(path,
                    abird_host_agent::build_executor::preparation::source::MAX_MATERIAL_BYTES)
                            })
                            .transpose()
                    })?;
                    sources.set(run.captures_settled());
                    Ok(replies)
                },
                || Ok(sources.get()),
            )
            .map(|_| ())
        }
        _ => anyhow::bail!("unknown owned operation; use fleet build-controller help"),
    }
}

fn successful_builder_observation(response: &protocol::Response) -> bool {
    use abird_host_agent::build_executor::Outcome;
    matches!(&response.reply, protocol::Reply::Status { snapshot } if matches!(
        snapshot.as_ref(),
        protocol::Snapshot::Retired { outcome: Outcome::Succeeded { .. }, .. }
            | protocol::Snapshot::Live {
                outcome: Some(Outcome::Succeeded { .. }), settled_at: Some(_), ..
            }
    ))
}

fn options(arguments: &[String]) -> Result<(BTreeMap<String, PathBuf>, Duration)> {
    let mut inputs = BTreeMap::new();
    let mut wait = 300;
    let mut seen_wait = false;
    let mut arguments = arguments.iter();
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--input" => {
                let (attempt, path) = arguments
                    .next()
                    .context("missing input binding")?
                    .split_once('=')
                    .context("expected ATTEMPT=FILE")?;
                ensure!(
                    !path.is_empty()
                        && inputs
                            .insert(attempt.to_owned(), PathBuf::from(path))
                            .is_none(),
                    "duplicate/empty input binding"
                );
            }
            "--wait-seconds" => {
                ensure!(!seen_wait, "duplicate wait bound");
                wait = arguments
                    .next()
                    .context("missing wait bound")?
                    .parse::<u64>()?;
                ensure!(
                    (1..=3600).contains(&wait),
                    "wait bound outside 1..3600 seconds"
                );
                seen_wait = true;
            }
            _ => anyhow::bail!("unknown owned option"),
        }
    }
    Ok((inputs, Duration::from_secs(wait)))
}

fn observe_until(
    run: &str,
    deadline: Instant,
    observe: impl FnMut() -> Result<BTreeMap<String, protocol::Response>>,
) -> Result<()> {
    observe_result(run, deadline, observe).map(|_| ())
}

pub(super) fn observe_parent_result(
    run: &str,
    deadline: Instant,
    parent: &mut super::controller::Controller,
    transport: &mut impl Transport,
) -> Result<BTreeMap<String, protocol::Response>> {
    let sources = std::cell::Cell::new(false);
    observe_result_until(
        run,
        deadline,
        || {
            let replies = parent.poll(transport)?;
            sources.set(parent.captures_settled());
            Ok(replies)
        },
        || Ok(sources.get()),
    )
}

pub(super) fn observe_result(
    run: &str,
    deadline: Instant,
    observe: impl FnMut() -> Result<BTreeMap<String, protocol::Response>>,
) -> Result<BTreeMap<String, protocol::Response>> {
    observe_result_until(run, deadline, observe, || Ok(true))
}

fn observe_result_until(
    run: &str,
    deadline: Instant,
    mut observe: impl FnMut() -> Result<BTreeMap<String, protocol::Response>>,
    mut caller_released: impl FnMut() -> Result<bool>,
) -> Result<BTreeMap<String, protocol::Response>> {
    let mut previous = None;
    loop {
        crate::fleet::signal::check_interrupted()?; // Disconnect is not remote cancellation.
        ensure!(
            Instant::now() < deadline,
            "observation ended without settlement; reconnect to the same run"
        );
        let responses = observe()?;
        let caller_released = caller_released()?;
        let serialized = serde_json::to_vec(&(&responses, caller_released))?;
        if previous.as_ref() != Some(&serialized) {
            report(run, &responses)?;
            previous = Some(serialized);
        }
        crate::fleet::signal::check_interrupted()?;
        if caller_released && controller::require_settled(&responses).is_ok() {
            return Ok(responses);
        }
        ensure!(
            Instant::now() < deadline,
            "observation ended without settlement; reconnect to the same run"
        );
        std::thread::park_timeout(
            Duration::from_secs(1).min(deadline.saturating_duration_since(Instant::now())),
        );
    }
}

fn report(run: &str, responses: &BTreeMap<String, protocol::Response>) -> Result<()> {
    // Exclusion is a local liveness observation, never proof that a target's
    // detached activation or rollback settled after its caller died.
    let caller = match Run::caller_active(run) {
        Ok(true) => "active",
        Ok(false) => "inactive-unconfirmed",
        Err(_) => "unknown",
    };
    println!(
        "{}",
        serde_json::to_string(&serde_json::json!({
            "run_id": run,
            "settled": controller::require_settled(responses).is_ok(),
            "settlement_scope": "builder",
            "caller": caller,
            "attempts": responses,
        }))?
    );
    Ok(())
}

fn read_private(path: &Path, maximum: usize) -> Result<Vec<u8>> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file()
            && metadata.nlink() == 1
            && metadata.uid() == unsafe { libc::geteuid() }
            && metadata.mode() & 0o077 == 0
            && metadata.len() <= maximum as u64,
        "owned input must be a bounded private regular file"
    );
    let mut bytes = Vec::new();
    file.take(maximum as u64 + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= maximum, "owned input exceeds bound");
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builder_settlement_cannot_complete_cancel_while_the_caller_is_active() {
        use abird_host_agent::build_executor::{Outcome, PoolHealth, journal::Acceptance};
        let responses = || {
            BTreeMap::from([(
                "a".repeat(64),
                protocol::Response {
                    version: protocol::VERSION,
                    reply: protocol::Reply::Status {
                        snapshot: Box::new(protocol::Snapshot::Retired {
                            pool: PoolHealth::Available,
                            acceptance: Acceptance {
                                attempt_id: "a".repeat(64),
                                spec_digest: "b".repeat(64),
                                sequence: 1,
                            },
                            outcome: Outcome::Interrupted,
                        }),
                    },
                },
            )])
        };
        controller::require_settled(&responses()).unwrap();
        assert!(
            observe_result_until(
                "fixture-run",
                Instant::now() + Duration::from_millis(20),
                || Ok(responses()),
                || Ok(false),
            )
            .is_err()
        );
        observe_result_until(
            "fixture-run",
            Instant::now() + Duration::from_secs(1),
            || Ok(responses()),
            || Ok(true),
        )
        .unwrap();
    }

    #[test]
    fn another_failed_child_does_not_disprove_a_successful_childs_target_effects() {
        use abird_host_agent::build_executor::{
            ArtifactReceipt, Outcome, PoolHealth, journal::Acceptance,
        };
        let response = |outcome| protocol::Response {
            version: protocol::VERSION,
            reply: protocol::Reply::Status {
                snapshot: Box::new(protocol::Snapshot::Retired {
                    pool: PoolHealth::Available,
                    acceptance: Acceptance {
                        attempt_id: "a".repeat(64),
                        spec_digest: "b".repeat(64),
                        sequence: 1,
                    },
                    outcome,
                }),
            },
        };
        // Synthetic observations exercise classification, not OS settlement.
        let replies = BTreeMap::from([
            (
                "a".repeat(64),
                response(Outcome::Succeeded {
                    artifacts: ArtifactReceipt {
                        spec_digest: "b".repeat(64),
                        preparation_digest: "c".repeat(64),
                        closure_digest: "d".repeat(64),
                        roots_digest: "e".repeat(64),
                    },
                }),
            ),
            ("f".repeat(64), response(Outcome::Interrupted)),
        ]);
        controller::require_settled(&replies).unwrap();
        assert!(controller::require_successful_builds(&replies).is_err());
        assert!(successful_builder_observation(&replies[&"a".repeat(64)]));
        assert!(!successful_builder_observation(&replies[&"f".repeat(64)]));
    }

    #[test]
    fn expired_observation_never_starts_another_controller_pass() {
        let mut calls = 0;
        let result = observe_result("fixture-run", Instant::now(), || {
            calls += 1;
            Ok(BTreeMap::new())
        });
        assert!(result.is_err());
        assert_eq!(calls, 0);
    }
}
