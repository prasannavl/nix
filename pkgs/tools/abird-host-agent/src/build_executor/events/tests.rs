use super::*;

#[test]
fn metadata_history_is_bounded_contiguous_and_reports_gaps() {
    let mut history = History::accepted(100);
    for now in 101..=200 {
        history.push(EventKind::OwnerRenewed, now).unwrap();
    }
    history.validate(200).unwrap();
    assert_eq!(history.entries.len(), EVENT_CAPACITY);
    let page = history.page(&"a".repeat(64), 0, MAX_EVENT_PAGE).unwrap();
    assert!(page.gap && page.more);
    assert_eq!(page.oldest, Some(38));
    assert_eq!(page.latest, 101);
    assert_eq!(page.events.len(), MAX_EVENT_PAGE);
    assert!(history.page(&"a".repeat(64), 102, 1).is_err());
    assert!(history.page(&"a".repeat(64), 0, 0).is_err());
}

#[test]
fn metadata_history_rejects_corrupt_sequences_times_and_exits() {
    for mutate in [
        |h: &mut History| h.entries[0].sequence = 0,
        |h: &mut History| h.entries[0].at = 101,
        |h: &mut History| h.entries.clear(),
        |h: &mut History| h.last = 2,
        |h: &mut History| {
            h.entries[0].detail = EventKind::ClientExited {
                exit: ClientExit::Failed { exit_code: 0 },
            }
        },
    ] {
        let mut history = History::accepted(100);
        mutate(&mut history);
        assert!(history.validate(100).is_err());
    }
}

#[test]
fn output_cursors_are_byte_exact_bounded_and_do_not_invent_success() {
    let key = "a".repeat(64);
    let bytes = "a💾b\n".as_bytes();
    let window = LogWindow {
        attempt_id: &key,
        generation: "one",
        base: 0,
        bytes,
        sealed: true,
    };
    let first = window.page(None, 2).unwrap();
    assert_eq!(first.bytes, &bytes[..2]);
    assert!(first.more && first.sealed && !first.gap);
    let second = window.page(Some(&first.next), MAX_LOG_PAGE_BYTES).unwrap();
    assert_eq!([first.bytes, second.bytes].concat(), bytes);
    assert!(!second.more);
    assert_eq!(second.next.offset, bytes.len() as u64);
    let empty = window.page(Some(&second.next), 1).unwrap();
    assert!(empty.bytes.is_empty() && !empty.more && empty.sealed);
    // An open, empty window is also legal: silence isn't a completion event.
    let empty_window = LogWindow {
        bytes: &[],
        sealed: false,
        ..window
    };
    assert!(!empty_window.page(None, 1).unwrap().sealed);
}

#[test]
fn rotation_and_retention_report_gaps_but_wrong_job_and_future_offset_reject() {
    let key = "a".repeat(64);
    let window = LogWindow {
        attempt_id: &key,
        generation: "two",
        base: 10,
        bytes: b"retained",
        sealed: false,
    };
    assert!(window.page(None, 1).unwrap().gap);
    for (generation, offset) in [("one", u64::MAX), ("two", 0)] {
        let page = window
            .page(
                Some(&LogCursor {
                    attempt_id: key.clone(),
                    generation: generation.into(),
                    offset,
                }),
                3,
            )
            .unwrap();
        assert!(page.gap);
        assert_eq!(page.bytes, b"ret");
        assert_eq!(page.next.offset, 13);
    }
    for cursor in [
        LogCursor {
            attempt_id: "b".repeat(64),
            generation: "two".into(),
            offset: 10,
        },
        LogCursor {
            attempt_id: key.clone(),
            generation: "two".into(),
            offset: 19,
        },
    ] {
        assert!(window.page(Some(&cursor), 1).is_err());
    }
    assert!(window.page(None, 0).is_err());
    assert!(window.page(None, MAX_LOG_PAGE_BYTES + 1).is_err());
}

#[test]
fn output_windows_reject_overflow_and_oversized_retention_without_allocating_pages() {
    let key = "a".repeat(64);
    let window = LogWindow {
        attempt_id: &key,
        generation: "one",
        base: u64::MAX,
        bytes: b"x",
        sealed: false,
    };
    assert!(window.page(None, 1).is_err());
    let bytes = vec![0; MAX_LOG_WINDOW_BYTES + 1];
    assert!(
        LogWindow {
            base: 0,
            bytes: &bytes,
            ..window
        }
        .page(None, 1)
        .is_err()
    );
    let bytes = vec![255; MAX_LOG_WINDOW_BYTES];
    let page = LogWindow {
        base: 0,
        bytes: &bytes,
        ..window
    }
    .page(None, MAX_LOG_PAGE_BYTES)
    .unwrap();
    assert_eq!(page.bytes.len(), MAX_LOG_PAGE_BYTES);
    let reply = crate::build_executor::protocol::Response {
        version: crate::build_executor::protocol::VERSION,
        reply: crate::build_executor::protocol::Reply::Logs { page },
    };
    assert!(reply.encode().unwrap().len() < crate::build_executor::protocol::MAX_FRAME_BYTES);
}
