//! Fleet accounting shares the roster rows used by the live renderer. Only
//! immutable phase snapshots survive teardown; there is no second live tracker.

use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub(super) enum Interval {
    Task(String),
    Operation(u64),
    Project,
}

/// Union of admitted-operation and task intervals. Idle queue gaps never enter
/// the total; an outer operation covers readiness/retries between its steps.
#[derive(Clone, Debug, Default)]
pub(super) struct HostTiming {
    pub total: Duration,
    pub since: Option<Instant>,
    active: BTreeSet<Interval>,
    finalizing: bool,
    pub observed: bool,
}

impl HostTiming {
    pub fn start(&mut self, interval: Interval, now: Instant) {
        self.observed = true;
        if self.since.is_none() {
            self.since = Some(now);
        }
        if matches!(interval, Interval::Task(_)) {
            self.finalizing = false;
        }
        self.active.insert(interval);
    }

    pub fn finish(&mut self, interval: &Interval, now: Instant, finalizing: bool) {
        if !self.active.remove(interval) {
            return;
        }
        self.finalizing |= finalizing;
        if self.active.is_empty() && !self.finalizing {
            self.pause(now);
        }
    }

    pub fn elapsed(&self, now: Instant) -> Duration {
        self.total
            + self
                .since
                .map_or(Duration::ZERO, |since| now.saturating_duration_since(since))
    }

    pub fn stop(&mut self, now: Instant) {
        self.pause(now);
        self.active.clear();
        self.finalizing = false;
    }

    fn pause(&mut self, now: Instant) {
        if let Some(since) = self.since.take() {
            self.total += now.saturating_duration_since(since);
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RowOutcome {
    Succeeded,
    Failed,
    Skipped,
    Interrupted,
    Unconfirmed,
}

/// Unconfirmed remote execution is not a settled completion.
pub(super) fn outcome_counts(
    outcomes: impl IntoIterator<Item = Option<RowOutcome>>,
) -> Vec<String> {
    let (mut total, mut done, mut failed, mut skipped, mut interrupted, mut unconfirmed) =
        (0, 0, 0, 0, 0, 0);
    for outcome in outcomes {
        total += 1;
        match outcome {
            Some(RowOutcome::Succeeded) => done += 1,
            Some(RowOutcome::Failed) => {
                done += 1;
                failed += 1;
            }
            Some(RowOutcome::Skipped) => {
                done += 1;
                skipped += 1;
            }
            Some(RowOutcome::Interrupted) => {
                done += 1;
                interrupted += 1;
            }
            Some(RowOutcome::Unconfirmed) => unconfirmed += 1,
            None => {}
        }
    }
    let mut fields = vec![format!("done {done}/{total}")];
    for (count, label) in [
        (failed, "failed"),
        (skipped, "skipped"),
        (interrupted, "interrupted"),
        (unconfirmed, "unconfirmed"),
    ] {
        if count != 0 {
            fields.push(format!("{count} {label}"));
        }
    }
    fields
}

#[derive(Clone, Debug)]
pub(crate) struct RowSnapshot {
    pub name: String,
    pub elapsed: Option<Duration>,
    pub outcome: Option<RowOutcome>,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) enum RosterKind {
    #[default]
    Hosts,
    Projects,
}

impl RosterKind {
    pub fn noun(self) -> &'static str {
        match self {
            Self::Hosts => "hosts",
            Self::Projects => "projects",
        }
    }

    pub fn counts(self, outcomes: impl IntoIterator<Item = Option<RowOutcome>>) -> Vec<String> {
        let mut fields = outcome_counts(outcomes);
        if self == Self::Projects {
            fields[0].push_str(" projects");
        }
        fields
    }
}

#[derive(Clone, Debug)]
pub(super) struct PhaseSnapshot {
    pub key: String,
    pub label: String,
    pub marker: &'static str,
    pub tone: crate::terminal_style::Tone,
    pub elapsed: Duration,
    pub kind: RosterKind,
    pub rows: Vec<RowSnapshot>,
}

impl PhaseSnapshot {
    pub fn compact(&self) -> String {
        let counts = if self.rows.is_empty() {
            String::new()
        } else {
            format!(
                " · {}",
                self.kind
                    .counts(self.rows.iter().map(|row| row.outcome))
                    .join(" · ")
            )
        };
        format!(
            "{} {}{counts} · {}",
            self.marker,
            self.label,
            super::format_duration(self.elapsed)
        )
    }
}

#[derive(Clone, Debug, Default)]
pub(super) struct WorkflowContext {
    pub started: Option<Instant>,
    pub phases: Vec<PhaseSnapshot>,
}

const HOST_TIMING_PHASES: [(&str, &str); 7] = [
    ("build", "b"),
    ("development build", "b"),
    ("snapshot", "s"),
    ("acquire", "a"),
    ("deploy", "d"),
    ("health", "h"),
    ("bootstrap", "c"),
];

/// Final-summary duration: always carry the unit, but keep the token dense.
fn compact_duration(duration: Duration) -> String {
    let milliseconds = duration.as_millis();
    if milliseconds < 1_000 {
        return format!("{milliseconds}ms");
    }
    let seconds = duration.as_secs_f64();
    if seconds < 10.0 {
        let tenths = (seconds * 10.0).round() as u64;
        if tenths < 100 {
            return format!("{}.{:01}s", tenths / 10, tenths % 10);
        }
    }
    let rounded = seconds.round() as u64;
    if rounded < 60 {
        format!("{rounded}s")
    } else if rounded < 3_600 {
        format!("{}m{:02}s", rounded / 60, rounded % 60)
    } else {
        let minutes = (rounded + 30) / 60;
        format!("{}h{:02}m", minutes / 60, minutes % 60)
    }
}

/// Compact measured host timings for the final summary. Absence and skipped
/// phases are already carried by the typed host status and add no timing signal.
pub(super) fn host_duration_summaries(
    snapshots: &[PhaseSnapshot],
    hosts: &[&str],
) -> BTreeMap<String, String> {
    let mut names = hosts.iter().copied().collect::<BTreeSet<_>>();
    let mut recorded = BTreeMap::new();
    for phase in snapshots {
        if phase.kind != RosterKind::Hosts
            || !HOST_TIMING_PHASES.iter().any(|(key, _)| *key == phase.key)
        {
            continue;
        }
        names.extend(
            phase
                .rows
                .iter()
                .filter(|host| host.elapsed.is_some())
                .map(|host| host.name.as_str()),
        );
        recorded.insert(
            phase.key.as_str(),
            phase
                .rows
                .iter()
                .map(|host| (host.name.as_str(), host))
                .collect::<BTreeMap<_, _>>(),
        );
    }
    names
        .into_iter()
        .filter_map(|host| {
            let fields = HOST_TIMING_PHASES
                .iter()
                .filter_map(|(key, code)| {
                    recorded
                        .get(key)
                        .and_then(|rows| rows.get(host))
                        .and_then(|row| row.elapsed)
                        .map(|elapsed| format!("{code}{}", compact_duration(elapsed)))
                })
                .collect::<Vec<_>>();
            (!fields.is_empty()).then(|| (host.to_owned(), fields.join(" ")))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_distinguish_settled_failures_from_unconfirmed_remote_work() {
        assert_eq!(
            outcome_counts([
                Some(RowOutcome::Succeeded),
                Some(RowOutcome::Failed),
                Some(RowOutcome::Skipped),
                Some(RowOutcome::Interrupted),
                Some(RowOutcome::Unconfirmed),
                None,
            ]),
            [
                "done 4/6",
                "1 failed",
                "1 skipped",
                "1 interrupted",
                "1 unconfirmed"
            ]
        );
    }

    #[test]
    fn sequential_steps_exclude_queued_gaps_and_do_not_reset_the_total() {
        let mut timing = HostTiming::default();
        let start = Instant::now();
        let task = Interval::Task("eval".to_owned());
        timing.start(task.clone(), start);
        timing.finish(&task, start + Duration::from_secs(2), false);
        timing.start(task.clone(), start + Duration::from_secs(20));
        timing.finish(&task, start + Duration::from_secs(23), false);
        assert_eq!(
            timing.elapsed(start + Duration::from_secs(99)),
            Duration::from_secs(5)
        );
    }

    #[test]
    fn operations_include_readiness_retries_and_nested_tasks_once() {
        let mut timing = HostTiming::default();
        let start = Instant::now();
        let operation = Interval::Operation(1);
        let parent = Interval::Task("parent".to_owned());
        let child = Interval::Task("child".to_owned());
        timing.start(operation.clone(), start);
        timing.start(parent.clone(), start + Duration::from_secs(2));
        timing.start(child.clone(), start + Duration::from_secs(3));
        timing.finish(&child, start + Duration::from_secs(5), false);
        timing.finish(&parent, start + Duration::from_secs(6), false);
        timing.start(child.clone(), start + Duration::from_secs(8));
        timing.finish(&child, start + Duration::from_secs(10), false);
        timing.finish(&operation, start + Duration::from_secs(12), false);
        assert_eq!(
            timing.elapsed(start + Duration::from_secs(20)),
            Duration::from_secs(12)
        );
    }

    #[test]
    fn finalizing_runs_until_the_host_settles_and_unknown_completions_do_nothing() {
        let mut timing = HostTiming::default();
        let start = Instant::now();
        let task = Interval::Task("activation".to_owned());
        timing.start(task.clone(), start);
        timing.finish(
            &Interval::Task("other".to_owned()),
            start + Duration::from_secs(1),
            false,
        );
        timing.finish(&task, start + Duration::from_secs(4), true);
        assert_eq!(
            timing.elapsed(start + Duration::from_secs(7)),
            Duration::from_secs(7)
        );
        timing.stop(start + Duration::from_secs(9));
        assert_eq!(
            timing.elapsed(start + Duration::from_secs(30)),
            Duration::from_secs(9)
        );
    }

    #[test]
    fn empty_or_unmeasured_rosters_do_not_add_host_timing_noise() {
        let snapshots = vec![PhaseSnapshot {
            key: "dns".into(),
            label: "dns done".into(),
            marker: "✓",
            tone: crate::terminal_style::Tone::Success,
            elapsed: Duration::from_secs(2),
            kind: RosterKind::Hosts,
            rows: vec![RowSnapshot {
                name: "app".into(),
                elapsed: None,
                outcome: None,
            }],
        }];
        assert!(host_duration_summaries(&snapshots, &["app"]).is_empty());
    }

    #[test]
    fn inline_summaries_keep_only_compact_measured_evidence() {
        let mut snapshots = vec![PhaseSnapshot {
            key: "build".to_owned(),
            label: "build done".to_owned(),
            marker: "✓",
            tone: crate::terminal_style::Tone::Success,
            elapsed: Duration::from_secs(8),
            kind: RosterKind::Hosts,
            rows: vec![RowSnapshot {
                name: "alpha".to_owned(),
                elapsed: Some(Duration::from_secs(5)),
                outcome: Some(RowOutcome::Unconfirmed),
            }],
        }];
        snapshots.push(PhaseSnapshot {
            key: "snapshot".to_owned(),
            label: "snapshot done".into(),
            marker: "✓",
            tone: crate::terminal_style::Tone::Success,
            elapsed: Duration::from_secs(1),
            kind: RosterKind::Hosts,
            rows: vec![RowSnapshot {
                name: "alpha".into(),
                elapsed: Some(Duration::from_millis(327)),
                outcome: Some(RowOutcome::Succeeded),
            }],
        });
        snapshots.push(PhaseSnapshot {
            key: "acquire".to_owned(),
            label: "acquire done".into(),
            marker: "✓",
            tone: crate::terminal_style::Tone::Success,
            elapsed: Duration::from_secs(24),
            kind: RosterKind::Hosts,
            rows: vec![RowSnapshot {
                name: "alpha".into(),
                elapsed: Some(Duration::from_millis(23_200)),
                outcome: Some(RowOutcome::Succeeded),
            }],
        });
        snapshots.push(PhaseSnapshot {
            key: "health".to_owned(),
            label: "health done".to_owned(),
            marker: "◇",
            tone: crate::terminal_style::Tone::Neutral,
            elapsed: Duration::ZERO,
            kind: RosterKind::Hosts,
            rows: vec![RowSnapshot {
                name: "alpha".to_owned(),
                elapsed: None,
                outcome: Some(RowOutcome::Skipped),
            }],
        });
        let hosts = ["alpha", "beta"];
        let summaries = host_duration_summaries(&snapshots, &hosts);
        assert_eq!(summaries["alpha"], "b5.0s s327ms a23s");
        assert!(!summaries.contains_key("beta"));
        assert!(host_duration_summaries(&[], &[]).is_empty());
        // Recorded hosts/phases absent from the final selection still retain evidence.
        assert!(host_duration_summaries(&snapshots, &[])["alpha"].contains("b5.0"));
    }

    #[test]
    fn final_summary_duration_is_deliberately_dense() {
        assert_eq!(compact_duration(Duration::from_millis(327)), "327ms");
        assert_eq!(compact_duration(Duration::from_millis(958)), "958ms");
        assert_eq!(compact_duration(Duration::from_millis(2_800)), "2.8s");
        assert_eq!(compact_duration(Duration::from_millis(9_960)), "10s");
        assert_eq!(compact_duration(Duration::from_millis(11_400)), "11s");
        assert_eq!(compact_duration(Duration::from_millis(59_600)), "1m00s");
        assert_eq!(compact_duration(Duration::from_secs(252)), "4m12s");
        assert_eq!(compact_duration(Duration::from_millis(3_599_600)), "1h00m");
        assert_eq!(compact_duration(Duration::from_secs(3_900)), "1h05m");
    }
}
