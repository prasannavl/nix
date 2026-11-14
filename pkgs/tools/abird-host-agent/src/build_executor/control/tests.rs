use super::*;
use crate::build_executor::context::{BuildAction, EvaluationIntent, InputLocation, PlanJobs};
use crate::build_executor::protocol::{Snapshot, VERSION};
use crate::build_executor::request::*;
use crate::build_executor::{Phase, PoolHealth};
use crate::sha256::digest_bytes;
use std::path::PathBuf;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use std::thread;

fn config() -> Config {
    let uid = unsafe { libc::geteuid() };
    Config {
        version: 1,
        identity: StorageIdentity {
            authority_id: "authority".into(),
            builder_id: "builder".into(),
            store_id: "store".into(),
        },
        policy: AdmissionPolicy {
            capacity_digest: "c".repeat(64),
            max_jobs: 1,
            max_cores: 1,
            submission_age_seconds: 60,
            future_skew_seconds: 2,
            replay_seconds: 120,
            deadlines: Deadlines {
                heartbeat_seconds: 2,
                stale_seconds: 6,
                owner_seconds: 120,
                queue_seconds: 120,
                runtime_seconds: 120,
                stop_grace_seconds: 3,
                stop_limit_seconds: 10,
                retention_seconds: 60,
            },
        },
        workload_uids: vec![if uid == 1000 { 1001 } else { 1000 }],
        principals: vec![Principal {
            uid,
            issuer: "operator".into(),
        }],
        timeout_millis: 2000,
        allow_submit: false,
    }
}
fn request(config: &Config, now: u64) -> BuildRequest {
    BuildRequest {
        parent: None,
        schema_version: REQUEST_VERSION,
        executor_version: 1,
        id: RequestId {
            issued_at: now,
            nonce: "control".into(),
        },
        run_id: "run".into(),
        issuer: "operator".into(),
        repository_id: "repo".into(),
        source: Source {
            revision: "a".repeat(40),
            base_revision: "a".repeat(40),
            tree_digest: None,
            patch_digest: None,
        },
        controller: Peer {
            host_id: "controller".into(),
            fabric_id: "fleet".into(),
        },
        builder: Peer {
            host_id: "builder".into(),
            fabric_id: "fleet".into(),
        },
        storage: config.identity.clone(),
        mode: BuildMode::System,
        evaluation: EvaluationIntent {
            version: 1,
            action: BuildAction::Build,
            build_flake: InputLocation::source(""),
            inventory: InputLocation::source("hosts/nixbot.nix"),
            overlay: None,
            repository_config: None,
            dependency_flake: InputLocation::source(""),
            plan_jobs: PlanJobs::Auto,
            deploy_jobs_per_domain: None,
        },
        selection: Selection::Exact {
            targets: vec![BuildTarget {
                host: "app".into(),
                configuration: "app".into(),
                outputs: vec!["out".into()],
            }],
        },
        required_hosts: vec!["app".into()],
        nix: NixOptions {
            max_jobs: 1,
            cores: 1,
            substitute: false,
        },
        policy_digest: config.policy.digest().unwrap(),
        deadlines: config.policy.deadlines.clone(),
        owner: Owner::Foreground {
            token_digest: digest_bytes(b"synthetic-owner-secret"),
        },
        predecessor: None,
    }
}
fn fixture() -> (tempfile::TempDir, PathBuf, Config, String) {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("authority");
    let config = config();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let journal =
        Journal::initialize(&path, config.identity.clone(), config.policy.clone(), now).unwrap();
    let key = journal
        .submit("operator", request(&config, now), now)
        .unwrap()
        .attempt_id;
    (root, path, config, key)
}
fn bytes(command: Command) -> Vec<u8> {
    serde_json::to_vec(&Request {
        version: VERSION,
        command,
    })
    .unwrap()
}
fn call(config: Config, path: PathBuf, message: &[u8]) -> Response {
    let (client, server) = UnixStream::pair().unwrap();
    let worker = thread::spawn(move || {
        serve_one(&config, server, || {
            Journal::open(&path, config.identity.clone(), config.policy.clone())
        })
    });
    let response = exchange(
        client,
        unsafe { libc::geteuid() },
        message,
        Duration::from_secs(2),
    );
    worker.join().unwrap().unwrap();
    response
}

#[test]
fn authenticated_description_is_metadata_not_submission_readiness() {
    let (_root, path, config, _) = fixture();
    assert!(!config.allow_submit);
    let response = call(config.clone(), path, &bytes(Command::Describe));
    response
        .validate_for(&Request {
            version: VERSION,
            command: Command::Describe,
        })
        .unwrap();
    let Reply::Description { declaration } = response.reply else {
        panic!();
    };
    assert_eq!(declaration.identity, config.identity);
    assert_eq!(declaration.policy, config.policy);
    assert_eq!(declaration.issuer, "operator");
}

#[test]
fn closed_submission_still_fences_delayed_intent_without_settlement() {
    let (_root, path, config, _) = fixture();
    assert!(!config.allow_submit);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let mut intent = request(&config, now);
    intent.id.nonce = "delayed-while-closed".into();
    let response = call(
        config.clone(),
        path.clone(),
        &bytes(Command::Withdraw {
            request: Box::new(intent.clone()),
        }),
    );
    assert!(matches!(response.reply, Reply::Accepted { .. }));
    let response = call(
        config.clone(),
        path.clone(),
        &bytes(Command::Status {
            attempt_id: intent.attempt_id().unwrap(),
        }),
    );
    assert!(
        matches!(response.reply, Reply::Status { snapshot } if matches!(*snapshot,
        Snapshot::Live { phase: Phase::Stopping, outcome: None, settled_at: None, .. }))
    );
    let mut reopened = config;
    reopened.allow_submit = true;
    assert!(matches!(
        call(
            reopened.clone(),
            path.clone(),
            &bytes(Command::Submit {
                request: Box::new(intent.clone())
            })
        )
        .reply,
        Reply::Accepted { .. }
    ));
    let journal = Journal::open(&path, reopened.identity, reopened.policy).unwrap();
    assert!(journal.queue(&intent.attempt_id().unwrap(), now).is_err());
}

#[test]
fn authenticated_status_and_cancel_remain_nonterminal_without_settlement() {
    let (_root, path, config, key) = fixture();
    let response = call(
        config.clone(),
        path.clone(),
        &bytes(Command::Status {
            attempt_id: key.clone(),
        }),
    );
    let Reply::Status { snapshot } = response.reply else {
        panic!()
    };
    assert!(matches!(
        *snapshot,
        Snapshot::Live {
            phase: Phase::Pending,
            pool: PoolHealth::Quarantined,
            outcome: None,
            ..
        }
    ));
    let response = call(
        config.clone(),
        path.clone(),
        &bytes(Command::Cancel {
            attempt_id: key.clone(),
            expected: None,
        }),
    );
    assert!(matches!(response.reply, Reply::StopRequested { .. }));
    let response = call(config, path, &bytes(Command::Status { attempt_id: key }));
    let Reply::Status { snapshot } = response.reply else {
        panic!()
    };
    assert!(matches!(
        *snapshot,
        Snapshot::Live {
            phase: Phase::Stopping,
            outcome: None,
            ..
        }
    ));
}

#[test]
fn uid_mapping_not_payload_issuer_controls_visibility_and_tokens_are_not_echoed() {
    let (_root, path, mut config, key) = fixture();
    config.principals[0].issuer = "foreign".into();
    let response = call(
        config.clone(),
        path.clone(),
        &bytes(Command::Status {
            attempt_id: key.clone(),
        }),
    );
    assert!(matches!(
        response.reply,
        Reply::Rejected {
            code: Rejection::NotFound
        }
    ));
    config.principals[0].issuer = "operator".into();
    let response = call(
        config,
        path,
        &bytes(Command::Renew {
            attempt_id: key,
            expected: None,
            token: "wrong-private-token".into(),
        }),
    );
    assert!(matches!(
        response.reply,
        Reply::Rejected {
            code: Rejection::Unauthorized
        }
    ));
    assert!(
        !String::from_utf8(response.encode().unwrap())
            .unwrap()
            .contains("wrong-private-token")
    );
}

#[test]
fn declarations_reject_worker_ambiguous_and_unsupported_authority() {
    for mutation in [
        |c: &mut Config| c.workload_uids = vec![c.principals[0].uid],
        |c: &mut Config| c.principals.push(c.principals[0].clone()),
        |c: &mut Config| c.version = 0,
        |c: &mut Config| c.timeout_millis = 0,
        |c: &mut Config| c.timeout_millis = 30_001,
        |c: &mut Config| c.principals.clear(),
    ] {
        let mut c = config();
        mutation(&mut c);
        assert!(c.validate().is_err());
    }
}

fn reject_without_open(config: Config, data: &[u8]) -> Response {
    let (client, server) = UnixStream::pair().unwrap();
    let worker =
        thread::spawn(move || serve_one(&config, server, || panic!("must not access journal")));
    let response = exchange(
        client,
        unsafe { libc::geteuid() },
        data,
        Duration::from_secs(2),
    );
    worker.join().unwrap().unwrap();
    response
}

#[test]
fn unregistered_uid_rejects_before_frame_dispatch_or_journal_access() {
    let mut c = config();
    c.principals[0].uid = 123_456;
    assert!(matches!(
        reject_without_open(c, b"not-json").reply,
        Reply::Rejected {
            code: Rejection::Unauthorized
        }
    ));
}

#[test]
fn submission_and_privileged_effects_are_unavailable_over_control_transport() {
    let c = config();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let message = bytes(Command::Submit {
        request: Box::new(request(&c, now)),
    });
    assert!(matches!(
        reject_without_open(c.clone(), &message).reply,
        Reply::Rejected {
            code: Rejection::CapabilityUnavailable
        }
    ));
    for verb in [
        "reserve",
        "prepared",
        "settle",
        "release",
        "recover",
        "queue",
        "stop",
        "advance_stop",
        "begin_worker",
        "launch_next",
        "settle_unlaunched",
        "retain",
        "initialize_roots",
        "verify_roots",
        "retention_clear",
    ] {
        let message = format!("{{\"version\":3,\"command\":{{\"kind\":\"{verb}\"}}}}");
        assert!(matches!(
            reject_without_open(c.clone(), message.as_bytes()).reply,
            Reply::Rejected {
                code: Rejection::InvalidRequest
            }
        ));
    }
}

#[test]
fn malformed_frames_and_trailing_requests_cannot_partially_dispatch() {
    let valid = bytes(Command::Status {
        attempt_id: "a".repeat(64),
    });
    let mut wire = (valid.len() as u32).to_be_bytes().to_vec();
    wire.extend(&valid);
    for bytes in [
        vec![],
        vec![0; 3],
        0u32.to_be_bytes().to_vec(),
        (MAX_FRAME_BYTES as u32 + 1).to_be_bytes().to_vec(),
        [wire.clone(), vec![b'x']].concat(),
        [wire.clone(), wire].concat(),
    ] {
        let c = config();
        let (mut client, server) = UnixStream::pair().unwrap();
        let worker = thread::spawn(move || serve_one(&c, server, || panic!("must not dispatch")));
        client.write_all(&bytes).unwrap();
        client.shutdown(Shutdown::Write).unwrap();
        let response = Response::decode(
            &read_frame(&mut client, Instant::now() + Duration::from_secs(2)).unwrap(),
        )
        .unwrap();
        assert!(matches!(
            response.reply,
            Reply::Rejected {
                code: Rejection::InvalidRequest
            }
        ));
        worker.join().unwrap().unwrap();
    }
}

#[test]
fn slow_peer_has_an_absolute_deadline_not_one_timeout_per_byte() {
    let mut c = config();
    c.timeout_millis = 80;
    let (mut client, server) = UnixStream::pair().unwrap();
    let start = Instant::now();
    let worker =
        thread::spawn(move || serve_one(&c, server, || panic!("partial frame must not dispatch")));
    client.write_all(&[0]).unwrap();
    thread::park_timeout(Duration::from_millis(50));
    let _ = client.write_all(&[0]);
    assert!(worker.join().unwrap().is_err());
    assert!(start.elapsed() < Duration::from_secs(2));
}

#[test]
fn foreign_listener_is_rejected_before_sending_a_secret() {
    let (client, mut server) = UnixStream::pair().unwrap();
    let response = exchange(
        client,
        unsafe { libc::geteuid() } + 1,
        b"synthetic-private-token",
        Duration::from_secs(1),
    );
    assert!(matches!(response.reply, Reply::Unconfirmed { .. }));
    let mut bytes = Vec::new();
    server.read_to_end(&mut bytes).unwrap();
    assert!(bytes.is_empty());
}

#[test]
fn missing_authority_and_broken_reply_are_unconfirmed_not_absence() {
    let c = config();
    let (client, server) = UnixStream::pair().unwrap();
    let worker = thread::spawn(move || {
        serve_one(&c, server, || {
            Err(anyhow::anyhow!("do not echo this detail"))
        })
    });
    let response = exchange(
        client,
        unsafe { libc::geteuid() },
        &bytes(Command::Status {
            attempt_id: "a".repeat(64),
        }),
        Duration::from_secs(2),
    );
    assert!(matches!(
        response.reply,
        Reply::Unconfirmed {
            code: Unconfirmed::Unavailable
        }
    ));
    assert!(
        !String::from_utf8(response.encode().unwrap())
            .unwrap()
            .contains("detail")
    );
    worker.join().unwrap().unwrap();
    let (client, server) = UnixStream::pair().unwrap();
    drop(server);
    assert!(matches!(
        exchange(
            client,
            unsafe { libc::geteuid() },
            b"x",
            Duration::from_secs(1)
        )
        .reply,
        Reply::Unconfirmed { .. }
    ));
}

#[test]
fn separate_connections_do_not_share_a_slow_client_or_controller_lock() {
    let (_root, path, c, key) = fixture();
    let gate =
        super::super::launch_gate::Gate::initialize(&path.join("launch"), c.identity.clone())
            .unwrap();
    let _controller = gate.try_controller().unwrap().unwrap();
    let opens = Arc::new(AtomicUsize::new(0));
    let counter = opens.clone();
    let mut slow = c.clone();
    slow.timeout_millis = 200;
    let (_client, server) = UnixStream::pair().unwrap();
    let pending = thread::spawn(move || {
        serve_one(&slow, server, || {
            counter.fetch_add(1, Ordering::SeqCst);
            panic!("partial input")
        })
    });
    let response = call(
        c,
        path,
        &bytes(Command::Cancel {
            attempt_id: key,
            expected: None,
        }),
    );
    assert!(matches!(response.reply, Reply::StopRequested { .. }));
    assert!(pending.join().unwrap().is_err());
    assert_eq!(opens.load(Ordering::SeqCst), 0);
}

#[test]
fn lost_reply_after_cancel_commit_is_reconciled_by_identity_not_reexecution() {
    let (_root, path, c, key) = fixture();
    let (mut client, server) = UnixStream::pair().unwrap();
    let (ready_send, ready_recv) = std::sync::mpsc::channel();
    let (continue_send, continue_recv) = std::sync::mpsc::channel();
    let server_path = path.clone();
    let server_config = c.clone();
    let worker = thread::spawn(move || {
        serve_one(&server_config, server, || {
            ready_send.send(()).unwrap();
            continue_recv.recv().unwrap();
            Journal::open(
                &server_path,
                server_config.identity.clone(),
                server_config.policy.clone(),
            )
        })
    });
    write_frame(
        &mut client,
        &bytes(Command::Cancel {
            attempt_id: key.clone(),
            expected: None,
        }),
        Instant::now() + Duration::from_secs(2),
    )
    .unwrap();
    ready_recv.recv_timeout(Duration::from_secs(2)).unwrap();
    drop(client);
    continue_send.send(()).unwrap();
    assert!(worker.join().unwrap().is_err());
    let response = call(c, path, &bytes(Command::Status { attempt_id: key }));
    let Reply::Status { snapshot } = response.reply else {
        panic!()
    };
    assert!(matches!(
        *snapshot,
        Snapshot::Live {
            phase: Phase::Stopping,
            outcome: None,
            ..
        }
    ));
}

#[test]
fn caller_clock_fields_are_rejected_before_metadata_access() {
    let message = format!(
        "{{\"version\":3,\"now\":0,\"command\":{{\"kind\":\"status\",\"attempt_id\":\"{}\"}}}}",
        "a".repeat(64)
    );
    assert!(matches!(
        reject_without_open(config(), message.as_bytes()).reply,
        Reply::Rejected {
            code: Rejection::InvalidRequest
        }
    ));
}

#[test]
fn opened_authority_must_match_the_authenticated_service_declaration() {
    let (_root, path, c, key) = fixture();
    let mut declaration = c.clone();
    declaration.identity.authority_id = "other-authority".into();
    let (client, server) = UnixStream::pair().unwrap();
    let journal = Journal::open(&path, c.identity.clone(), c.policy.clone()).unwrap();
    let worker = thread::spawn(move || serve_one(&declaration, server, || Ok(journal)));
    let response = exchange(
        client,
        unsafe { libc::geteuid() },
        &bytes(Command::Cancel {
            attempt_id: key.clone(),
            expected: None,
        }),
        Duration::from_secs(2),
    );
    assert!(matches!(response.reply, Reply::Unconfirmed { .. }));
    worker.join().unwrap().unwrap();
    let response = call(c, path, &bytes(Command::Status { attempt_id: key }));
    let Reply::Status { snapshot } = response.reply else {
        panic!()
    };
    assert!(matches!(
        *snapshot,
        Snapshot::Live {
            phase: Phase::Pending,
            ..
        }
    ));
}
