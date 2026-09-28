# Abird Host Manager Task And Step Model

## Contract

Fleet execution and progress are separated by a small typed contract in
`pkgs/tools/abird-host-manager/src/fleet/task.rs`:

- a **step** is a named unit of progress, described by a `StepSpec` (`name`,
  `running`, `done`, `finalizing`); nothing else about a step is an execution
  concern;
- `Task` is a step's progress handle: `started`/`finished` are driven exactly
  once by the step runner, while `output`/`note`/`heartbeat` are driven by the
  process layer and fleet callbacks;
- `TaskScope` is a host- or phase-bound factory that owns the display host and
  mints one `Task` per step from the step type, so a `StepSpec` never sees a
  host that could drift from the row it is attributed to;
- `ProcessRecorder` is the display-independent diagnostic sink.

Execution never parses labels and never names a stage in prose. Each high-level
operation owns its own step type in
`pkgs/tools/abird-host-manager/src/fleet/host_tasks.rs` (`BuildStep`,
`SnapshotStep`, `ReadinessStep`, `SshKeyStep`, `TransferStep`, `VerifyStep`,
`AcquireStep`, `DeployStep`, `HealthStep`, `PhaseStep`); the step type maps
itself to a `StepSpec`. `run_step` / `run_step_with` are the single place that
drives a step's lifecycle. `TransferStep` keeps direction and source explicit:
`CachePull`, `RelayPull`, `RelayPush` are cache relays, while `DirectPush` is a
controller-local closure copied straight to the target (`closure copy`).

`ProcessRequest` carries only execution plus `task: Arc<dyn Task>`; the
diagnostic name is the task name. `ProcessExecutor` forwards output through a
`ProcessSink` that fans out to both the progress task and the diagnostics
recorder, and it never drives the task lifecycle. Internal or hidden commands
use `InternalTask`; a hidden probe that runs inside a step uses
`InternalTask::child` so its cancellation still interrupts the owning step.

## Presentation ownership

Only `presentation.rs` knows how a step looks:

- the output policy is derived from `StepSpec::finalizing` (activation allowlist
  for activation/rollback), so execution never selects a policy;
- heartbeat cadence is derived the same way, so `StepSpec` carries no timing
  field;
- `Task::note` takes a semantic line; presentation sanitizes and normalizes it
  before display, so the step output/note path never imports a presentation
  allowlist or sanitizer (execution holds only the progress facade and phase
  labels);
- failed steps publish the `failed; see diagnostics` hint from presentation,
  independent of the process layer.

## Outcomes

- `TaskOutcome` is `Succeeded | Failed | Interrupted`.
- Interruption is resolved once, at the step. When the process runner terminates
  a child under cancellation, `ProcessExecutor` calls `Task::mark_interrupted`,
  so a body that swallowed the failure into a value (for example a snapshot
  probe) still reports `Interrupted`. A typed interruption error is honored
  directly, and a failure observed while cancellation is requested is attributed
  to the interruption.
- `run_step_with` derives a non-interrupted row outcome from the returned value.
  This is required for operations that report failure as an `Ok` status or typed
  outcome (`activate`, `run_remote_build`, the distribution primitives,
  admission, pre-switch preparation, the plan probe), which otherwise render as
  success. A step that merely completes (for example a snapshot probe with no
  previous generation) is `Succeeded`; the host-level policy decides whether a
  missing generation is a failure or an optional skip.
- The host row is a projection of its steps. `host_task_interrupted` renders
  `⊘ interrupted` and keeps the bounded output tail, and it is terminal: a later
  `host_finished` or `host_skipped` for the same host keeps the interruption
  (`HostRow::keep_interrupted`).
- A terminal host outcome must not be rate-limited like a rolling detail line,
  so non-interactive interruption uses `ProgressReporter::message` rather than
  `detail`.
- Step wording is produced only through the `StepSpec` constructors
  (`stage`/`via`/`detail`/`finalizing`), which keep the lowercase `done`
  vocabulary uniform; the activation and rollback steps are the finalizing steps
  that select the activation output allowlist.
