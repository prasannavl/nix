//! Neutral task/step contract shared by fleet execution and presentation.
//!
//! Execution names each step and drives its lifecycle through [`TaskScope`] and
//! [`Task`]. Presentation owns the words: it turns a [`StepSpec`] into progress
//! rows. Nothing in the execution path inspects a stage name.

use std::sync::Arc;
use std::time::Duration;

use super::host_runtime::ProcessStream;

/// Terminal state of one step.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TaskOutcome {
    Succeeded,
    Failed,
    Interrupted,
}

/// Everything the renderer needs to draw one step, plus the diagnostic id.
///
/// Step wording is always built through [`StepSpec::stage`], [`StepSpec::via`],
/// [`StepSpec::detail`], or [`StepSpec::finalizing`] so the lowercase/`done`
/// vocabulary stays uniform across every task.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StepSpec {
    pub name: String,
    pub running: String,
    pub done: String,
    pub finalizing: bool,
}

impl StepSpec {
    fn new(name: String, running: String, done: String, finalizing: bool) -> Self {
        Self {
            name,
            running,
            done,
            finalizing,
        }
    }

    /// `sync` -> running `sync`, done `sync done`.
    pub fn stage(name: String, stage: &str) -> Self {
        Self::new(name, stage.to_owned(), format!("{stage} done"), false)
    }

    /// `build` via `gondor-ci` -> running `build via gondor-ci`,
    /// done `build done via gondor-ci`.
    pub fn via(name: String, stage: &str, via: &str) -> Self {
        Self::new(
            name,
            format!("{stage} via {via}"),
            format!("{stage} done via {via}"),
            false,
        )
    }

    /// `parent reconcile` of `gap3-gondor` -> running `parent reconcile gap3-gondor`,
    /// done `parent reconcile done · gap3-gondor`.
    pub fn detail(name: String, stage: &str, detail: &str) -> Self {
        Self::new(
            name,
            format!("{stage} {detail}"),
            format!("{stage} done · {detail}"),
            false,
        )
    }

    /// `activation` -> running `activation observe`, done `activation done, finalizing`.
    ///
    /// The presentation layer renders finalizing steps with the activation
    /// output allowlist; execution only marks the step finalizing.
    pub fn finalizing(name: String, stage: &str) -> Self {
        Self::new(
            name,
            format!("{stage} observe"),
            format!("{stage} done, finalizing"),
            true,
        )
    }
}

/// A task-owned step type. Each high-level task implements this for its own
/// step enum, so step wording lives next to the task that owns it.
pub trait StepSpecSource {
    fn spec(&self, host: &str) -> StepSpec;
}

/// A step's progress handle.
///
/// `started`/`finished` are driven exactly once by the task runner; `output`,
/// `note`, and `heartbeat` are driven by the process layer and fleet callbacks.
pub trait Task: Send + Sync + std::fmt::Debug {
    fn name(&self) -> &str;

    fn started(&self);

    fn output(&self, stream: ProcessStream, chunk: &str);

    /// Publish a semantic line that is not raw process output. Presentation
    /// owns sanitizing and normalizing it before display.
    fn note(&self, _line: &str) {}

    fn heartbeat(&self, _elapsed: Duration) {}

    fn finished(&self, elapsed: Duration, outcome: TaskOutcome);

    /// The process layer marks a step whose process was terminated by fleet
    /// cancellation. The step runner then reports the step as interrupted even
    /// when the body swallowed the failure into a value.
    fn mark_interrupted(&self) {}

    /// Whether a process owned by this step was terminated by cancellation.
    fn was_interrupted(&self) -> bool {
        false
    }

    fn heartbeat_interval(&self) -> Option<Duration> {
        None
    }
}

/// Host- or phase-bound factory that mints one [`Task`] per step. The scope
/// owns the display host, so step specs never see a host that could drift from
/// the row they are attributed to.
pub trait TaskScope: Send + Sync {
    fn step(&self, step: &dyn StepSpecSource) -> Arc<dyn Task>;
}

/// A step with no human presentation (hidden protocols, internal sub-processes).
/// Diagnostics still record it under its name.
///
/// A child links to the step it runs inside, so a cancelled internal process
/// still interrupts the owning step; a standalone internal task is inert.
#[derive(Debug)]
pub struct InternalTask {
    name: String,
    parent: Option<Arc<dyn Task>>,
}

impl InternalTask {
    pub fn new(name: impl Into<String>) -> Arc<Self> {
        Arc::new(Self {
            name: name.into(),
            parent: None,
        })
    }

    pub fn child(name: impl Into<String>, parent: Arc<dyn Task>) -> Arc<Self> {
        Arc::new(Self {
            name: name.into(),
            parent: Some(parent),
        })
    }
}

impl Task for InternalTask {
    fn name(&self) -> &str {
        &self.name
    }

    fn started(&self) {}

    fn output(&self, _stream: ProcessStream, _chunk: &str) {}

    fn finished(&self, _elapsed: Duration, _outcome: TaskOutcome) {}

    fn mark_interrupted(&self) {
        if let Some(parent) = &self.parent {
            parent.mark_interrupted();
        }
    }

    fn was_interrupted(&self) -> bool {
        self.parent
            .as_ref()
            .is_some_and(|parent| parent.was_interrupted())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[derive(Debug)]
    struct MarkingTask {
        interrupted: AtomicBool,
    }

    impl MarkingTask {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                interrupted: AtomicBool::new(false),
            })
        }
    }

    impl Task for MarkingTask {
        fn name(&self) -> &str {
            "marking"
        }

        fn started(&self) {}

        fn output(&self, _stream: ProcessStream, _chunk: &str) {}

        fn finished(&self, _elapsed: Duration, _outcome: TaskOutcome) {}

        fn mark_interrupted(&self) {
            self.interrupted.store(true, Ordering::Release);
        }

        fn was_interrupted(&self) -> bool {
            self.interrupted.load(Ordering::Acquire)
        }
    }

    #[test]
    fn internal_child_propagates_interruption_to_its_step() {
        let parent: Arc<dyn Task> = MarkingTask::new();
        let child = InternalTask::child("hidden-probe", Arc::clone(&parent));
        assert!(!child.was_interrupted());
        child.mark_interrupted();
        assert!(child.was_interrupted());
        assert!(parent.was_interrupted());
    }

    #[test]
    fn standalone_internal_task_ignores_interruption() {
        let task = InternalTask::new("hidden-probe");
        task.mark_interrupted();
        assert!(!task.was_interrupted());
    }
}
