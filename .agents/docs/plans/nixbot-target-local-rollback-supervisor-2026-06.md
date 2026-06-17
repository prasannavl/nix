# Nixbot Target-Local Rollback Supervisor Plan

## Summary

Design a target-local per-host deploy transaction runner for `nixbot` so a host
that starts activation can also decide and execute its own rollback when the
activation or target-local health checks fail.

This plan is for later implementation. It records the desired design boundary,
current baseline, non-goals, failure semantics, and handoff details.

## Current Baseline

Recent scoped fix:

- `z`: `585ccd13 fix(nixbot): retry bad fd transport`
- `~/src/nix`: `194a3213 fix(nixbot): retry bad fd transport`

That fix only broadened remote-store transport classification so
`Bad file descriptor` is retryable like `Broken pipe`.

Current deploy behavior:

- `BUILD_HOST=local` remains unchanged and uses `nixos-rebuild` from the
  `nixos-rebuild-ng` package.
- Non-local build-cache deploys already have an explicit copy/activate boundary:
  - build on the build host
  - copy or relay the system path to the target
  - run `<out-path>/bin/switch-to-configuration <goal>` from local `nixbot`
  - run operator-owned health checks and rollback handling
- Copy/cache transfer may be retried when it fails before activation starts.
- Once activation has started, any failure must be treated as deploy failure and
  must lead to rollback handling. Do not convert uncertain activation transport
  loss into success based on a stale or matching generation.

## User Corrections and Constraints

- Local builds must stay exactly as they are. They do not need explicit target
  store-copy work added by `nixbot`; local builds should continue to use
  `nixos-rebuild`.
- The target-local rollback supervisor should start with the non-local
  build-cache path, where `nixbot` already owns the direct
  `switch-to-configuration` call.
- Do not fold this into the transport-classifier fix. It is a separate control
  plane change.
- Keep `nixbot` signing-agnostic. The builder owns cache signing and private
  signing keys.
- Do not read `data/secrets/**/*.key`.
- Prefer repo-declarative changes and checked-in helper code over persistent
  live target mutation.

## Design Goal

Move the per-host mutating transaction from "operator observes a remote switch"
to "target runs a durable local transaction".

The operator still owns:

- host selection
- dependency waves
- parent readiness and settlement
- build placement
- target copy/cache transfer before activation
- global cancellation policy
- multi-host summary and failure propagation

The target-local runner owns one host transaction:

- verify requested system path and rollback path
- activate requested system path once
- run target-local health checks
- rollback once on activation or health failure
- persist final state and structured events locally

## Non-Goals

- Do not change `BUILD_HOST=local` deploy behavior in the initial
  implementation.
- Do not make the target a global orchestrator.
- Do not move build, cache signing, dependency wave scheduling, or parent
  readiness into the target runner.
- Do not retry activation itself. Activation remains single-shot per desired
  system path.
- Do not hide failed activation by post-hoc generation matching.
- Do not require a persistent target-side daemon for the first version.

## Proposed Architecture

Introduce a repo-owned target helper, packaged with nixbot, such as:

```text
nixbot-target-transaction
```

The operator invokes it through `systemd-run` on the target after the desired
system path has already been copied or made available.

High-level flow for non-local build-cache deploys:

```text
operator nixbot
  -> build on build host
  -> ensure target can fetch/copy desired out path
  -> snapshot target rollback path
  -> start target-local transaction service
  -> stream target journal/events opportunistically
  -> reconnect/read target state if SSH drops
  -> classify host result
```

Target transaction:

```text
target systemd service
  -> validate desired out path is activatable
  -> validate rollback path is activatable
  -> run pre-switch cleanup/report hooks if needed
  -> run desired switch-to-configuration once
  -> run target-local health checks
  -> on activation or health failure, run rollback switch-to-configuration once
  -> persist terminal state
```

## Target Runtime State

Use a per-run directory:

```text
/run/nixbot/deploy/<run-id>/
```

Suggested files:

- `request.json`: immutable transaction request.
- `state.json`: authoritative machine-readable final or current state.
- `events.jsonl`: structured append-only events.
- `stdout.log`: optional captured stdout from helper subprocesses.
- `stderr.log`: optional captured stderr from helper subprocesses.
- `health.json`: structured health result.
- `rollback.json`: structured rollback result when rollback was attempted.

`/run` is intentionally ephemeral. Failed-run diagnostics can still be copied
back into the operator diag directory. If persistent host-local retention is
needed later, add an explicit bounded retention path such as
`/var/lib/nixbot/deploy-history/` with cleanup policy.

## Request Schema

Start simple and explicit:

```json
{
  "version": 1,
  "runId": "20260616T123456Z-gap3-rivendell-abc123",
  "host": "gap3-rivendell",
  "goal": "switch",
  "desiredSystem": "/nix/store/...-nixos-system-gap3-rivendell...",
  "rollbackSystem": "/run/current-system",
  "health": {
    "enabled": true,
    "timeoutSeconds": 120,
    "checkMode": "systemd-user-manager"
  },
  "operator": {
    "repo": "z",
    "commit": "..."
  }
}
```

The target helper must reject requests when:

- `desiredSystem` or `rollbackSystem` is empty.
- either path is not an absolute `/nix/store/...` path or accepted live profile
  path.
- either path lacks an executable `bin/switch-to-configuration`.
- `goal` is not one of the supported activation goals.
- a transaction with the same `runId` is already active.

## State Machine

Suggested states:

- `created`
- `validating`
- `activating`
- `activated`
- `health-checking`
- `healthy`
- `activation-failed`
- `health-failed`
- `rolling-back`
- `rolled-back`
- `rollback-failed`
- `failed-before-activation`
- `cancelled-before-activation`

Terminal classifications for operator summary:

- `success`: desired path activated and health passed.
- `rolled_back`: desired activation or health failed, rollback succeeded.
- `rollback_failed`: rollback attempted and failed.
- `failed_before_activation`: validation failed before desired activation.
- `unknown`: target state cannot be read after bounded reconnect attempts.

## Failure Semantics

Before target transaction starts:

- Copy/cache transfer failures may be retried by existing transport retry
  policy.
- Snapshot/readiness failures prevent deployment.

After target transaction starts:

- Operator SSH loss is not itself a deploy result.
- Operator reconnects and reads `state.json` or systemd unit status.
- Target-local activation failure triggers rollback locally.
- Target-local health failure triggers rollback locally.
- Target-local rollback failure is terminal `rollback_failed`.
- If target cannot be reached after bounded retries, operator reports `unknown`
  and preserves diagnostics. It must not report success from stale local
  assumptions.

Activation retry rule:

- Never retry desired `switch-to-configuration` after it starts.
- Never run rollback more than once for the same transaction unless a human
  explicitly runs recovery later.

## Health Checks

Initial version should reuse the existing health policy and checks as much as
possible, but run them locally on the target.

Candidate approach:

- Factor current remote health-check shell functions into helper functions that
  can run locally or remotely.
- Target runner invokes the local version.
- Operator still records/streams the resulting structured output.

Health checks should preserve current semantics:

- Failed system units fail health.
- Failed user units fail health.
- Unhealthy Podman containers fail health.
- Containers in `starting` are polled within the service-owned timeout budget.
- Dispatcher/systemd-user-manager report behavior stays bounded.

Do not add a new independent health timeout policy unless the existing metadata
cannot be reused.

## Logging and Operator Output

The target runner should emit both:

- human-readable journal lines for live streaming
- structured JSON events for reconnect and postmortem

Operator behavior:

- Start `journalctl -fu nixbot-deploy-<run-id>.service` opportunistically.
- If stream drops, reconnect and read `state.json` plus the unit journal.
- Prefix streamed output with the host like existing nixbot host logs.
- Preserve target events in the operator diag directory.

This avoids making SSH log streaming the source of truth. It becomes a view of
target-local state.

## Systemd Unit Shape

Use a transient unit so the transaction survives SSH transport loss:

```text
systemd-run \
  --unit nixbot-deploy-<run-id>.service \
  --property Type=exec \
  --property KillMode=control-group \
  --property TimeoutStartSec=<bounded> \
  /run/current-system/sw/bin/nixbot-target-transaction \
    --request /run/nixbot/deploy/<run-id>/request.json
```

Open questions for implementation:

- Whether the helper should be invoked from `/run/current-system` or from the
  desired system path.
- Whether the helper should be copied as a small store path before activation,
  or always rely on the currently running system.

Safer first version:

- Run the helper from the current system.
- Treat helper upgrades as normal next-deploy behavior, not as part of the
  transaction being executed.

## Cancellation

Operator cancellation before target transaction starts:

- cancel local work as today.

Operator cancellation after target transaction starts:

- do not kill the target transaction on first cancellation.
- stop scheduling new hosts.
- wait for or reconnect to already-started transactions.
- preserve current multi-press hard-stop behavior only as a last-resort operator
  escape hatch.

Target runner cancellation:

- If cancelled before desired activation starts, mark
  `cancelled-before-activation`.
- If cancelled after desired activation starts, attempt rollback before exit
  when possible.

Do not make incidental SSH hangup cancel the target transaction.

## Security and Trust

- Target runner runs as root through the same prepared root command boundary
  that currently runs activation.
- Request file must be created with root-only permissions.
- Do not include secrets in request, state, or event files.
- Do not accept arbitrary shell snippets from the operator.
- Treat request paths as data, quote all subprocess arguments, and avoid `eval`.
- Host-key verification failures remain trust failures, not retryable transport
  failures.

## Implementation Phases

### Phase 1: Refactor for Shared Local Health Functions

- Isolate current health-check shell logic so it can run target-local.
- Keep current operator-driven health path behavior unchanged.
- Add tests or shell probes for the extracted helpers if practical.

### Phase 2: Add Target Transaction Helper

- Add packaged helper entrypoint.
- Implement request validation, state writes, event writes, activation, health,
  rollback, and terminal classification.
- Keep it usable in local dry tests without SSH.

### Phase 3: Operator Start and Reconnect Logic

- Add a non-local build-cache deploy mode flag or internal path that starts the
  target transaction after copy succeeds.
- Stream journal/events live.
- Reconnect and read target state on transport loss.
- Map target states into existing nixbot summary buckets.

### Phase 4: Rollout Gate

- Default off behind an internal feature flag or CLI option, for example:

```text
NIXBOT_TARGET_LOCAL_TRANSACTION=1
```

- Test on one low-risk non-local build-cache target.
- Keep local-build deploys on `nixos-rebuild`.

### Phase 5: Default for Non-Local Build-Cache Deploys

- Once validated, enable target-local transactions for non-local build-cache
  deploys.
- Update handoff docs and deploy-system notes.
- Decide separately whether any local-build behavior should ever change. Do not
  change it as part of this phase.

## Validation Plan

Static validation:

- `bash -n pkgs/tools/nixbot/nixbot.sh`
- `shellcheck pkgs/tools/nixbot/nixbot.sh`
- formatter for touched Markdown and helper sources

Dry/local validation:

- Run the target helper against fake request paths and confirm validation
  rejects unsafe input.
- Run with a known activatable current system path in a controlled local target
  if available.
- Simulate health failure and confirm rollback path is invoked.

Integration validation:

- Non-local build-cache dry deploy prints target transaction start command
  instead of direct activation.
- Live low-risk deploy:
  - copy succeeds
  - target transaction starts
  - desired activation succeeds
  - health succeeds
  - operator summary reports success
- Failure drills:
  - break desired activation before start: no rollback, failed before activation
  - break health check: rollback succeeds, summary `FAIL (health; rolled back)`
  - drop SSH after transaction start: reconnect reads target state
  - make rollback path invalid in a lab target: summary `rollback_failed`

## Handoff Notes

- The immediate retry fix is already committed in both repos and is
  intentionally narrow.
- This plan should be implemented in a later branch/worktree. Do not combine it
  with unrelated deploy fixes.
- Start with `z`, then mirror the shared nixbot change to `~/src/nix` once the
  shape is validated.
- Keep `.agents/docs/README.md` updated if this plan is renamed, moved, or
  split.
- Preserve the user correction: local builds stay on `nixos-rebuild` unless the
  user explicitly reopens that design.
