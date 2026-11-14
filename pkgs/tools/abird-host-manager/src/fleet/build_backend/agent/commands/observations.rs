//! Read-only pages beside the durable writer, including service-owned parents.
//! Printed cursors resume observation only; they cannot renew or dispatch work.

use std::collections::BTreeMap;

use abird_host_agent::build_executor::{events, protocol};
use anyhow::{Context, Result, ensure};
use serde_json::Value;

use crate::fleet::build_backend::agent::control::transport::Transport;
use crate::fleet::build_backend::agent::run::Run;

fn cursors(arguments: &[String], logs: bool) -> Result<BTreeMap<String, String>> {
    let flag = if logs { "--cursor" } else { "--after" };
    let mut values = BTreeMap::new();
    let mut arguments = arguments.iter();
    while let Some(argument) = arguments.next() {
        ensure!(argument == flag, "unexpected observation option");
        let (attempt, cursor) = arguments
            .next()
            .context("missing observation cursor")?
            .split_once('=')
            .context("expected ATTEMPT=CURSOR")?;
        ensure!(
            !cursor.is_empty()
                && values
                    .insert(attempt.to_owned(), cursor.to_owned())
                    .is_none(),
            "duplicate or empty observation cursor"
        );
    }
    Ok(values)
}

fn request(attempt: &str, cursor: Option<&str>, logs: bool) -> Result<protocol::Request> {
    let command = if logs {
        protocol::Command::Logs {
            attempt_id: attempt.to_owned(),
            cursor: cursor
                .map(|value| -> Result<_> {
                    let (generation, offset) = value
                        .split_once(':')
                        .context("expected GENERATION:OFFSET")?;
                    Ok(events::LogCursor {
                        attempt_id: attempt.to_owned(),
                        generation: generation.to_owned(),
                        offset: offset.parse()?,
                    })
                })
                .transpose()?,
            limit: events::MAX_LOG_PAGE_BYTES,
        }
    } else {
        protocol::Command::Events {
            attempt_id: attempt.to_owned(),
            cursor: cursor
                .map(|value| -> Result<_> {
                    Ok(events::EventCursor {
                        attempt_id: attempt.to_owned(),
                        after: value.parse()?,
                    })
                })
                .transpose()?,
            limit: events::MAX_EVENT_PAGE,
        }
    };
    let request = protocol::Request {
        version: protocol::VERSION,
        command,
    };
    protocol::Request::decode(&serde_json::to_vec(&request)?)?;
    Ok(request)
}

fn display(response: protocol::Response) -> Result<Value> {
    match response.reply {
        protocol::Reply::Logs { page } => {
            // Current installed log is ASCII JSONL. Reject invalid UTF-8 rather
            // than changing byte positions behind the printed continuation.
            let text = String::from_utf8(page.bytes)?;
            Ok(serde_json::json!({ "kind": "logs", "next": page.next,
                "gap": page.gap, "more": page.more, "sealed": page.sealed, "text": text }))
        }
        reply => Ok(serde_json::to_value(reply)?),
    }
}

pub(super) fn run(
    run: &str,
    arguments: &[String],
    logs: bool,
    transport: &mut impl Transport,
) -> Result<()> {
    let manifest = Run::inspect(run)?;
    let cursors = cursors(arguments, logs)?;
    ensure!(
        cursors
            .keys()
            .all(|key| manifest.children.contains_key(key)),
        "cursor names an unknown child"
    );
    // Validate every cursor before the first transport effect. No parent writer,
    // source read, submission, renewal, cancellation or cursor-file reconstruction.
    let requests = manifest
        .children
        .keys()
        .map(|attempt| {
            Ok((
                attempt.clone(),
                request(attempt, cursors.get(attempt).map(String::as_str), logs)?,
            ))
        })
        .collect::<Result<BTreeMap<_, _>>>()?;
    let mut event_pages = BTreeMap::new();
    for (attempt, request) in requests {
        crate::fleet::signal::check_interrupted()?;
        let response = transport.request(&manifest.children[&attempt].target, &request)?;
        response.validate_for(&request)?;
        if logs {
            println!(
                "{}",
                serde_json::to_string(&serde_json::json!({
                    "run_id": run, "attempt_id": attempt, "observation": display(response)?,
                }))?
            );
        } else {
            event_pages.insert(attempt, response);
        }
    }
    if !logs {
        super::report(run, &event_pages)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_options_are_observation_only_and_checked_before_transport() {
        let attempt = "a".repeat(64);
        let values = cursors(
            &["--cursor".into(), format!("{attempt}=journal14:8192")],
            true,
        )
        .unwrap();
        let next = request(&attempt, values.get(&attempt).map(String::as_str), true).unwrap();
        assert!(matches!(
            next.command,
            protocol::Command::Logs {
                cursor: Some(events::LogCursor { offset: 8192, .. }),
                ..
            }
        ));
        assert!(request(&attempt, Some("journal14:-1"), true).is_err());
        assert!(request(&attempt, Some("bad generation:0"), true).is_err());
        assert!(request(&attempt, Some("1:2"), false).is_err());
        assert!(cursors(&["--input".into(), format!("{attempt}=private.json")], true).is_err());
        assert!(
            cursors(
                &[
                    "--after".into(),
                    format!("{attempt}=0"),
                    "--after".into(),
                    format!("{attempt}=1")
                ],
                false
            )
            .is_err()
        );
        assert!(matches!(
            request(&attempt, Some("42"), false).unwrap().command,
            protocol::Command::Events {
                cursor: Some(events::EventCursor { after: 42, .. }),
                ..
            }
        ));
    }

    #[test]
    fn log_display_preserves_cursor_gap_and_unsettled_seal_meaning() {
        let next = events::LogCursor {
            attempt_id: "a".repeat(64),
            generation: "journal14".into(),
            offset: 512,
        };
        let value = display(protocol::Response {
            version: protocol::VERSION,
            reply: protocol::Reply::Logs {
                page: events::LogPage {
                    next: next.clone(),
                    gap: true,
                    more: false,
                    sealed: true,
                    bytes: b"{}\n".to_vec(),
                },
            },
        })
        .unwrap();
        assert_eq!(value["next"], serde_json::to_value(next).unwrap());
        assert_eq!(value["text"], "{}\n");
        assert_eq!(value["gap"], true);
        assert_eq!(value["sealed"], true);
        assert!(value.get("settled").is_none() && value.get("outcome").is_none());
    }
}
