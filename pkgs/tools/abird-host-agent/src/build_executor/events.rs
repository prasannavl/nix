//! Bounded metadata history and log-window contracts. Installed diagnostics are
//! allowlisted journal events; raw command output never enters the public log.

use std::collections::VecDeque;

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

use super::protocol::Rejection;
use super::{ClientExit, StopReason, digest, identifier};

pub const EVENT_CAPACITY: usize = 64;
pub const MAX_EVENT_PAGE: usize = 32;
pub(super) const MAX_EVENT_BYTES: usize = 256;
pub const MAX_LOG_WINDOW_BYTES: usize = 64 * 1024;
pub const MAX_LOG_PAGE_BYTES: usize = 8 * 1024;
// Fixed-width JSONL records give stable byte cursors across history eviction.
// No additional retained bytes: render only the existing 64 metadata events.
pub(super) const LOG_RECORD_BYTES: usize = 512;
pub(super) const LOG_GENERATION: &str = "journal14";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum EventKind {
    Accepted,
    Queued,
    InputReady,
    InputsReceived {
        digest: String,
    },
    InputsPrepared {
        digest: String,
    },
    Reserved {
        epoch: std::num::NonZeroU64,
    },
    Started,
    ClientExited {
        exit: ClientExit,
    },
    DispatchUnconfirmed,
    Diagnostic {
        diagnostic: super::diagnostics::Diagnostic,
    },
    StopRequested {
        reason: StopReason,
    },
    OwnerRenewed,
    Settled,
    ConsumerAcknowledged {
        digest: String,
    },
    ConsumerAbandoned {
        digest: String,
    },
    ProtectionReleased,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Event {
    pub sequence: u64,
    pub at: u64,
    pub detail: EventKind,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct EventCursor {
    pub attempt_id: String,
    /// Last consumed sequence; zero starts at the retained beginning.
    pub after: u64,
}

#[derive(Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct EventPage {
    pub next: EventCursor,
    pub oldest: Option<u64>,
    pub latest: u64,
    pub gap: bool,
    pub more: bool,
    pub retired: bool,
    pub events: Vec<Event>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct History {
    pub last: u64,
    entries: VecDeque<Event>,
}

impl History {
    pub fn accepted(now: u64) -> Self {
        Self {
            last: 1,
            entries: VecDeque::from([Event {
                sequence: 1,
                at: now,
                detail: EventKind::Accepted,
            }]),
        }
    }

    pub fn push(&mut self, detail: EventKind, now: u64) -> Result<()> {
        self.last = self
            .last
            .checked_add(1)
            .filter(|value| *value <= u64::MAX / LOG_RECORD_BYTES as u64)
            .ok_or(Rejection::Capacity)?;
        if self.entries.len() == EVENT_CAPACITY {
            self.entries.pop_front();
        }
        self.entries.push_back(Event {
            sequence: self.last,
            at: now,
            detail,
        });
        Ok(())
    }

    pub fn validate(&self, now: u64) -> Result<()> {
        ensure!(
            !self.entries.is_empty()
                && self.entries.len() <= EVENT_CAPACITY
                && self.last <= u64::MAX / LOG_RECORD_BYTES as u64,
            "invalid event history size"
        );
        let mut previous = self
            .last
            .checked_sub(self.entries.len() as u64)
            .ok_or_else(|| anyhow::anyhow!("invalid event sequence"))?;
        let mut at = 0;
        for event in &self.entries {
            ensure!(
                serde_json::to_vec(event)?.len() <= MAX_EVENT_BYTES,
                "metadata event exceeds reservation"
            );
            ensure!(
                event.sequence > 0
                    && previous.checked_add(1) == Some(event.sequence)
                    && at <= event.at
                    && event.at <= now,
                "invalid event ordering"
            );
            match event.detail {
                EventKind::ClientExited { exit } => exit.validate()?,
                EventKind::InputsPrepared { ref digest }
                | EventKind::InputsReceived { ref digest }
                | EventKind::ConsumerAcknowledged { ref digest }
                | EventKind::ConsumerAbandoned { ref digest } => super::digest(digest)?,
                EventKind::StopRequested { reason } => reason.validate(true)?,
                _ => {}
            }
            previous = event.sequence;
            at = event.at;
        }
        ensure!(previous == self.last, "invalid event tail");
        Ok(())
    }

    pub fn logs(
        &self,
        key: &str,
        cursor: Option<&LogCursor>,
        limit: usize,
        sealed: bool,
    ) -> Result<LogPage> {
        let oldest = self
            .entries
            .front()
            .expect("validated nonempty history")
            .sequence;
        let base = (oldest - 1)
            .checked_mul(LOG_RECORD_BYTES as u64)
            .ok_or(Rejection::InvalidCursor)?;
        let mut bytes = Vec::with_capacity(self.entries.len() * LOG_RECORD_BYTES);
        for event in &self.entries {
            let next = bytes.len() + LOG_RECORD_BYTES;
            let encoded = serde_json::to_vec(event)?;
            ensure!(
                encoded.len() < LOG_RECORD_BYTES,
                "diagnostic record exceeds reservation"
            );
            bytes.extend(encoded);
            bytes.resize(next - 1, b' ');
            bytes.push(b'\n');
        }
        LogWindow {
            attempt_id: key,
            generation: LOG_GENERATION,
            base,
            bytes: &bytes,
            sealed,
        }
        .page(cursor, limit)
    }

    pub fn page(&self, key: &str, after: u64, limit: usize) -> Result<EventPage> {
        ensure!(
            after <= self.last && (1..=MAX_EVENT_PAGE).contains(&limit),
            Rejection::InvalidCursor
        );
        let oldest = self
            .entries
            .front()
            .expect("validated nonempty history")
            .sequence;
        let gap = after < oldest - 1;
        let events: Vec<_> = self
            .entries
            .iter()
            .filter(|e| e.sequence > after)
            .take(limit)
            .cloned()
            .collect();
        let end = events.last().map_or(after, |e| e.sequence);
        Ok(EventPage {
            next: EventCursor {
                attempt_id: key.to_owned(),
                after: end,
            },
            oldest: Some(oldest),
            latest: self.last,
            gap,
            more: end < self.last,
            retired: false,
            events,
        })
    }
}

impl EventPage {
    pub(super) fn validate(&self) -> Result<()> {
        digest(&self.next.attempt_id)?;
        ensure!(
            self.latest > 0
                && self.next.after <= self.latest
                && self.events.len() <= MAX_EVENT_PAGE
                && self.more == (self.next.after < self.latest),
            "invalid event page bounds"
        );
        if self.retired {
            ensure!(
                self.oldest.is_none() && self.events.is_empty() && !self.more,
                "invalid retired event page"
            );
        } else {
            let oldest = self
                .oldest
                .ok_or_else(|| anyhow::anyhow!("missing history boundary"))?;
            ensure!(
                oldest > 0 && oldest <= self.latest,
                "invalid history boundary"
            );
            let mut previous = None;
            let mut at = 0;
            for event in &self.events {
                ensure!(
                    event.sequence >= oldest
                        && event.sequence <= self.latest
                        && previous.is_none_or(|s: u64| s.checked_add(1) == Some(event.sequence))
                        && event.at >= at,
                    "invalid event ordering"
                );
                match event.detail {
                    EventKind::ClientExited { exit } => exit.validate()?,
                    EventKind::InputsPrepared { ref digest }
                    | EventKind::InputsReceived { ref digest }
                    | EventKind::ConsumerAcknowledged { ref digest }
                    | EventKind::ConsumerAbandoned { ref digest } => super::digest(digest)?,
                    EventKind::StopRequested { reason } => reason.validate(true)?,
                    _ => {}
                }
                previous = Some(event.sequence);
                at = event.at;
            }
            ensure!(
                previous.map_or(self.next.after == self.latest, |s| s == self.next.after),
                "invalid next event cursor"
            );
        }
        Ok(())
    }
}

/// Generation changes on rotation/replacement. Offsets are bytes, not UTF-8 indices.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LogCursor {
    pub attempt_id: String,
    pub generation: String,
    pub offset: u64,
}

#[derive(Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LogPage {
    pub next: LogCursor,
    pub gap: bool,
    pub more: bool,
    /// Closed log, not a terminal job outcome.
    pub sealed: bool,
    pub bytes: Vec<u8>,
}

impl LogPage {
    pub(super) fn validate(&self) -> Result<()> {
        digest(&self.next.attempt_id)?;
        identifier(&self.next.generation)?;
        ensure!(
            self.bytes.len() <= MAX_LOG_PAGE_BYTES
                && self.next.offset >= self.bytes.len() as u64
                && (!self.more || !self.bytes.is_empty()),
            "invalid log page"
        );
        Ok(())
    }
}

/// Borrow a bounded, already-redacted retained window. Never clone whole logs.
/// The adapter must persist generation/base/sealed with its private output store.
pub struct LogWindow<'a> {
    pub attempt_id: &'a str,
    pub generation: &'a str,
    pub base: u64,
    pub bytes: &'a [u8],
    pub sealed: bool,
}

impl LogWindow<'_> {
    pub fn page(&self, cursor: Option<&LogCursor>, limit: usize) -> Result<LogPage> {
        digest(self.attempt_id)?;
        ensure!(
            self.bytes.len() <= MAX_LOG_WINDOW_BYTES,
            Rejection::InvalidCursor
        );
        identifier(self.generation)?;
        ensure!(
            (1..=MAX_LOG_PAGE_BYTES).contains(&limit),
            Rejection::InvalidCursor
        );
        let end = self
            .base
            .checked_add(self.bytes.len() as u64)
            .ok_or(Rejection::InvalidCursor)?;
        let (start, gap) = match cursor {
            None => (self.base, self.base != 0),
            Some(cursor) => {
                ensure!(
                    cursor.attempt_id == self.attempt_id,
                    Rejection::InvalidCursor
                );
                identifier(&cursor.generation)?;
                if cursor.generation != self.generation || cursor.offset < self.base {
                    (self.base, true)
                } else {
                    ensure!(cursor.offset <= end, Rejection::InvalidCursor);
                    (cursor.offset, false)
                }
            }
        };
        let offset = usize::try_from(start - self.base)?;
        let length = (self.bytes.len() - offset).min(limit);
        let next = start + length as u64;
        Ok(LogPage {
            next: LogCursor {
                attempt_id: self.attempt_id.to_owned(),
                generation: self.generation.to_owned(),
                offset: next,
            },
            gap,
            more: next < end,
            sealed: self.sealed,
            bytes: self.bytes[offset..offset + length].to_vec(),
        })
    }
}

#[cfg(test)]
mod tests;
