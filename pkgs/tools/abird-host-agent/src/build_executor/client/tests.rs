use super::*;
use std::io::{Read, Write};
use std::num::NonZeroU64;
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::thread::{self, JoinHandle};

use crate::build_executor::journal::Acceptance;
use crate::build_executor::{Outcome, Ownership, Phase, PoolHealth};

fn key() -> String {
    "a".repeat(64)
}
fn owner() -> Ownership {
    Ownership {
        executor_version: 1,
        builder_id: "builder".into(),
        store_id: "store".into(),
        attempt_id: key(),
        pool_epoch: NonZeroU64::new(7).unwrap(),
        boot_id: "original-boot".into(),
    }
}
fn status(phase: Phase) -> Response {
    Response {
        version: protocol::VERSION,
        reply: Reply::Status {
            snapshot: Box::new(Snapshot::Live {
                pool: PoolHealth::Owned,
                acceptance: Acceptance {
                    attempt_id: key(),
                    spec_digest: "b".repeat(64),
                    sequence: 1,
                },
                phase,
                prepared_digest: None,
                input: None,
                outcome: None,
                ownership: Some(owner()),
                accepted_at: 1,
                renewed_at: 2,
                reserved_at: Some(2),
                settled_at: None,
            }),
        },
    }
}
fn request_status() -> Command {
    Command::Status { attempt_id: key() }
}
fn uid() -> u32 {
    unsafe { libc::geteuid() }
}
fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(2)
}

fn endpoint(
    replies: Vec<Option<Response>>,
) -> (tempfile::TempDir, PathBuf, JoinHandle<Vec<Request>>) {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("control.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let worker = thread::spawn(move || {
        let mut seen = Vec::new();
        for reply in replies {
            let mut poll = libc::pollfd {
                fd: listener.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            assert!(unsafe { libc::poll(&mut poll, 1, 3000) } > 0);
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            stream
                .set_write_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut prefix = [0; 4];
            stream.read_exact(&mut prefix).unwrap();
            let length = u32::from_be_bytes(prefix) as usize;
            assert!((1..=protocol::MAX_FRAME_BYTES).contains(&length));
            let mut bytes = vec![0; length];
            stream.read_exact(&mut bytes).unwrap();
            assert_eq!(stream.read(&mut [0; 1]).unwrap(), 0);
            seen.push(Request::decode(&bytes).unwrap());
            if let Some(reply) = reply {
                let bytes = reply.encode().unwrap();
                stream
                    .write_all(&(bytes.len() as u32).to_be_bytes())
                    .unwrap();
                stream.write_all(&bytes).unwrap();
            }
        }
        seen
    });
    (root, path, worker)
}

#[test]
fn reconnect_observes_the_same_attempt_without_resubmission() {
    let (_root, path, worker) = endpoint(vec![
        Some(status(Phase::Running)),
        Some(status(Phase::Running)),
    ]);
    for _ in 0..2 {
        let reply = exchange(&path, uid(), request_status(), deadline()).unwrap();
        let Reply::Status { snapshot } = reply.reply else {
            panic!()
        };
        assert!(
            matches!(*snapshot, Snapshot::Live { phase: Phase::Running, ownership: Some(ref observed), .. } if observed == &owner())
        );
    }
    let seen = worker.join().unwrap();
    assert_eq!(seen.len(), 2);
    assert!(
        seen.iter()
            .all(|r| matches!(&r.command, Command::Status { attempt_id } if attempt_id == &key()))
    );
}

#[test]
fn cancellation_uses_the_observed_original_fence_and_returns_only_an_ack() {
    let ack = Response {
        version: protocol::VERSION,
        reply: Reply::StopRequested { attempt_id: key() },
    };
    let (_root, path, worker) = endpoint(vec![Some(status(Phase::Running)), Some(ack)]);
    let response = cancel_at(&path, uid(), &key(), deadline()).unwrap();
    assert!(matches!(response.reply, Reply::StopRequested { .. }));
    let seen = worker.join().unwrap();
    assert_eq!(seen.len(), 2);
    assert!(
        matches!(&seen[1].command, Command::Cancel { attempt_id, expected: Some(expected) } if attempt_id == &key() && expected == &owner())
    );
}

#[test]
fn lost_status_sends_no_cancellation() {
    let (_root, path, worker) = endpoint(vec![None]);
    let response = cancel_at(&path, uid(), &key(), deadline()).unwrap();
    assert!(matches!(response.reply, Reply::Unconfirmed { .. }));
    let seen = worker.join().unwrap();
    assert_eq!(seen.len(), 1);
    assert!(matches!(seen[0].command, Command::Status { .. }));
}

#[test]
fn lost_cancel_reply_reconnects_by_status_without_repeating_the_stop_request() {
    let (_root, path, worker) = endpoint(vec![
        Some(status(Phase::Running)),
        None,
        Some(status(Phase::Stopping)),
    ]);
    let response = cancel_at(&path, uid(), &key(), deadline()).unwrap();
    assert!(matches!(response.reply, Reply::Unconfirmed { .. }));
    let response = exchange(&path, uid(), request_status(), deadline()).unwrap();
    assert!(
        matches!(response.reply, Reply::Status { snapshot } if matches!(*snapshot, Snapshot::Live { phase: Phase::Stopping, outcome: None, .. }))
    );
    let seen = worker.join().unwrap();
    assert_eq!(seen.len(), 3);
    assert_eq!(
        seen.iter()
            .filter(|r| matches!(r.command, Command::Cancel { .. }))
            .count(),
        1
    );
}

#[test]
fn already_settled_failure_is_not_relabelled_as_cancelled() {
    let response = Response {
        version: protocol::VERSION,
        reply: Reply::Status {
            snapshot: Box::new(Snapshot::Retired {
                pool: PoolHealth::Recovering,
                acceptance: Acceptance {
                    attempt_id: key(),
                    spec_digest: "b".repeat(64),
                    sequence: 1,
                },
                outcome: Outcome::Interrupted,
            }),
        },
    };
    let (_root, path, worker) = endpoint(vec![Some(response)]);
    let response = cancel_at(&path, uid(), &key(), deadline()).unwrap();
    assert!(
        matches!(response.reply, Reply::Status { snapshot } if matches!(*snapshot, Snapshot::Retired { outcome: Outcome::Interrupted, .. }))
    );
    assert_eq!(worker.join().unwrap().len(), 1);
}

#[test]
fn wrong_attempt_or_reply_kind_is_unconfirmed_and_never_authorizes_cancel() {
    for wrong in [
        Response {
            version: protocol::VERSION,
            reply: Reply::StopRequested { attempt_id: key() },
        },
        {
            let mut response = status(Phase::Running);
            let Reply::Status { snapshot } = &mut response.reply else {
                panic!()
            };
            let Snapshot::Live {
                acceptance,
                ownership,
                ..
            } = snapshot.as_mut()
            else {
                panic!()
            };
            acceptance.attempt_id = "c".repeat(64);
            ownership.as_mut().unwrap().attempt_id = "c".repeat(64);
            response
        },
    ] {
        let (_root, path, worker) = endpoint(vec![Some(wrong)]);
        assert!(matches!(
            cancel_at(&path, uid(), &key(), deadline()).unwrap().reply,
            Reply::Unconfirmed { .. }
        ));
        assert_eq!(worker.join().unwrap().len(), 1);
    }
}

#[test]
fn wrong_service_uid_receives_no_request_bytes() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("control.sock");
    let listener = UnixListener::bind(&path).unwrap();
    listener.set_nonblocking(true).unwrap();
    let response = exchange(&path, uid() + 1, request_status(), deadline()).unwrap();
    assert!(matches!(response.reply, Reply::Unconfirmed { .. }));
    let (mut stream, _) = listener.accept().unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .unwrap();
    assert_eq!(stream.read(&mut [0; 1]).unwrap(), 0);
}

#[test]
fn invalid_request_and_expired_deadline_do_not_contact_the_service() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("control.sock");
    let listener = UnixListener::bind(&path).unwrap();
    listener.set_nonblocking(true).unwrap();
    assert!(
        exchange(
            &path,
            uid(),
            Command::Status {
                attempt_id: "PRIVATE-INVALID".into()
            },
            deadline()
        )
        .is_err()
    );
    let response = exchange(&path, uid(), request_status(), Instant::now()).unwrap();
    assert!(matches!(response.reply, Reply::Unconfirmed { .. }));
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
}

#[test]
fn full_socket_backlog_and_missing_endpoint_are_unconfirmed_without_blocking() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("control.sock");
    assert!(matches!(
        exchange(&path, uid(), request_status(), deadline())
            .unwrap()
            .reply,
        Reply::Unconfirmed { .. }
    ));
    let listener = UnixListener::bind(&path).unwrap();
    assert_eq!(unsafe { libc::listen(listener.as_raw_fd(), 0) }, 0);
    let _occupied = connect(&path).unwrap();
    let start = Instant::now();
    assert!(matches!(
        exchange(&path, uid(), request_status(), deadline())
            .unwrap()
            .reply,
        Reply::Unconfirmed { .. }
    ));
    assert!(start.elapsed() < Duration::from_secs(1));
}
