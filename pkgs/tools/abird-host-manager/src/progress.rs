use std::time::Duration;

use crate::Action;

#[derive(Clone, Debug)]
pub struct ProgressReporter {
    enabled: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StepProgress {
    pub transaction: String,
    pub item: String,
    pub action: Action,
    pub step: String,
    pub description: String,
    pub location: String,
}

impl ProgressReporter {
    pub fn new(enabled: bool) -> Self {
        Self { enabled }
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    pub fn phase_started(&self, transaction: &str, action: Action, items: usize) {
        if self.enabled {
            eprintln!(
                "[{transaction}][{}] phase started ({items} item{})",
                action.as_str(),
                if items == 1 { "" } else { "s" }
            );
        }
    }

    pub fn phase_completed(&self, transaction: &str, action: Action, elapsed: Duration) {
        if self.enabled {
            eprintln!(
                "[{transaction}][{}] phase completed ({})",
                action.as_str(),
                format_duration(elapsed)
            );
        }
    }

    pub fn step_started(&self, step: &StepProgress) {
        if self.enabled {
            eprintln!("{}: started", step_prefix(step));
        }
    }

    pub fn step_completed(&self, step: &StepProgress, elapsed: Duration) {
        if self.enabled {
            eprintln!(
                "{}: completed ({})",
                step_prefix(step),
                format_duration(elapsed)
            );
        }
    }

    pub fn step_failed(&self, step: &StepProgress, elapsed: Duration, error: &anyhow::Error) {
        if self.enabled {
            eprintln!(
                "{}: failed after {}: {error:#}",
                step_prefix(step),
                format_duration(elapsed)
            );
        }
    }
}

fn step_prefix(step: &StepProgress) -> String {
    format!(
        "[{}][{}][{}] {}: {} @ {}",
        step.transaction,
        step.action.as_str(),
        step.item,
        step.step,
        step.description,
        step.location
    )
}

fn format_duration(duration: Duration) -> String {
    let milliseconds = duration.as_millis();
    if milliseconds < 1_000 {
        format!("{milliseconds}ms")
    } else {
        format!("{:.1}s", duration.as_secs_f64())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_short_and_long_durations_compactly() {
        assert_eq!(format_duration(Duration::from_millis(42)), "42ms");
        assert_eq!(format_duration(Duration::from_millis(1_250)), "1.2s");
    }

    #[test]
    fn step_prefix_contains_durable_and_execution_context() {
        let step = StepProgress {
            transaction: "move-zulip--item-001".to_owned(),
            item: "item-001".to_owned(),
            action: Action::Seed,
            step: "seed".to_owned(),
            description: "copy source data to target".to_owned(),
            location: "controller (source -> target)".to_owned(),
        };
        assert_eq!(
            step_prefix(&step),
            "[move-zulip--item-001][seed][item-001] seed: copy source data to target @ controller (source -> target)"
        );
    }
}
