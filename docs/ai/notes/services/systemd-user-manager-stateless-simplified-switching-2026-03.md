# systemd-user-manager Stateless Simplified Switching (2026-03)

## Purpose

This note records the final simplified architecture now implemented in
`lib/systemd-user-manager/default.nix`, `lib/systemd-user-manager/helper.sh`,
and `lib/podman-compose.nix`.

It supersedes the earlier direction that used:

- root-owned mutable state under `/var/lib/systemd-user-manager`
- generic per-unit action graphs
- transient Podman lifecycle actions
- a manifest-plus-handoff redesign plan

The current model is narrower and closer to native NixOS switching semantics.

## Final Design

For each managed user:

- one system dispatcher service:
  `systemd-user-manager-dispatcher-<user>.service`
- one user reconciler service: `systemd-user-manager-reconciler-<user>.service`

The systemd-user-manager abstraction now owns only:

- old-world stop for managed user units
- new-world start/reconcile for managed user units
- user-manager identity refresh when user/group membership changes
- dry-activate preview for the same reconciler logic

It no longer owns:

- generic `preActions` / `postActions`
- root-owned per-unit stamp files
- module-specific lifecycle semantics such as Podman image pulls

The canonical code layout is:

- Nix wiring and metadata generation in `lib/systemd-user-manager/default.nix`
- shared shell control flow in `lib/systemd-user-manager/helper.sh`
- generated dispatcher and reconciler services passing explicit environment
  metadata into that helper

## Statelessness Model

The module no longer uses:

- `/var/lib/systemd-user-manager`
- mutable root-owned desired-state files
- per-unit persisted reconcile stamps

Instead, each generated dispatcher and reconciler unit references a
generation-local immutable metadata JSON file in the Nix store.

That metadata contains:

- the managed user
- the managed unit set
- a semantic stamp for each managed unit
- the user identity stamp

## Old/New Split

The split is now:

- old-world stop in activation, diffing old `/run/current-system` unit metadata
  against new `$systemConfig` unit metadata
- new-world start in the dispatcher unit's `ExecStart`

### Old-world stop

The activation hook:

- reads old dispatcher metadata from
  `/run/current-system/etc/systemd/system/systemd-user-manager-dispatcher-*.service`
- reads new dispatcher metadata from
  `$systemConfig/etc/systemd/system/systemd-user-manager-dispatcher-*.service`
- stops removed managed units when `stopOnRemoval = true`
- stops changed managed units when the semantic unit stamp changed
- restarts `user@<uid>.service` when the identity stamp changed, but only after
  old-world stop completes

This follows native NixOS switching semantics more closely than the earlier
attempt to do old/new diffing inside dispatcher `ExecStop`, because activation
still has a stable old-generation view in `/run/current-system` while the new
generation is available through `$systemConfig`.

Removed users must be stopped before the `users` activation phase removes the
account, so the old-world stop path is a real pre-`users` activation step.

### New-world reconcile

The user reconciler uses only:

- new desired metadata
- live `systemctl --user` state

For each managed unit it:

- leaves active units alone
- starts inactive or failed units unless they are disabled or masked

This is the intentionally simplified desired-state model. If a managed unit
should stay off, the user side should disable or mask it.

## Podman Integration

Podman lifecycle behavior is no longer implemented as systemd-user-manager
actions. It is compiled into normal user units and dependencies.

### Main compose unit

The main generated Podman compose service remains the managed unit tracked by
`systemd-user-manager`.

- config changes change its semantic restart stamp
- `bootTag` changes its semantic restart stamp
- `recreateTag` changes its semantic restart stamp

`recreateTag` is now a switch-time trigger only:

- it causes the managed unit to be treated as changed
- active stacks go through the normal stop/start switch path
- it does not remain encoded as sticky steady-state start behavior

### Image pull helper

`imageTag` now generates a separate oneshot helper unit:

- `<compose-service>-image-pull.service`

The main compose service:

- `After=` that helper
- `Requires=` that helper when image refresh is enabled

So the intended semantics are:

- `imageTag`: on the next start or restart, pull first
- `recreateTag`: on the next deploy-triggered run, force a changed-unit
  stop/start cycle
- both together: the next run pulls first, then the main unit starts normally

`imageTag` no longer means "pull immediately on deploy even without a start or
restart". That is an intentional simplification.

## Boot And Preview Rules

- `switch` and `test` keep synchronous old-world stop plus dispatcher-driven new
  reconcile.
- `boot` must not be blocked by repo-owned mutable service logic. Boot skips
  mutating activation-time user-manager work and relies on normal dispatcher
  units later in the target graph.
- `dry-activate` stays non-mutating, but it uses the same generated helper in a
  preview mode so operators can see reconcile actions without performing them.

## Operational Refinements

- First-run and removal behavior use the explicit names `startOnFirstRun` and
  `stopOnRemoval`.
- Inactive-unit action policy uses the clearer
  `observeUnitInactiveAction = fail | run-action | start-change-unit`.
- Stable-state waits use bounded progressive backoff instead of a fixed noisy
  polling loop.
- Dispatcher logs should be thin orchestration logs: start, reconciler output,
  and finish, without redundant reconciler-name chatter.
- Dispatcher journal handling should stream newly appended reconciler lines
  incrementally while the reconciler is still running, then replay the full
  latest invocation once terminal state is reached so downstream deploy
  summaries keep both live progress and final completeness.
- Journal filtering should remove only known systemd boilerplate noise. Do not
  collapse the stream through a broad `grep 'dispatcher '` filter that can hide
  dispatcher-side timeout or retry diagnostics.
- Managed-unit `started in ...` / `failed to start ...` lines should be emitted
  in actual completion order rather than submission order.

## Behavioral Contract

The current intended contract is:

- managed user units represent desired-running state
- inactive-but-startable managed units are started during reconcile
- disabled or masked managed units remain off
- deploy-time change handling comes from old/new generation diff
- module-specific lifecycle behavior should be expressed as ordinary systemd
  units, scripts, and dependencies rather than a generic reconciler action
  engine

## Why This Is Better

- simpler than the old mutable state model
- more composable than a generic action engine
- closer to native NixOS old/new unit switching
- clearer ownership boundary between the generic bridge and higher-level modules
- fewer hidden semantics and less private runtime state

## Source Of Truth

- `lib/systemd-user-manager/default.nix`
- `lib/systemd-user-manager/helper.sh`
- `lib/podman-compose.nix`
- `docs/systemd-user-manager.md`
- `docs/podman-compose.md`

## Superseded notes

- `docs/ai/notes/services/systemd-user-manager-bridge-lifecycle-2026-03.md`
- `docs/ai/notes/services/systemd-user-manager-boot-deferral-2026-03.md`
- `docs/ai/notes/services/systemd-user-manager-dispatcher-journal-drain-and-trap-fix-2026-03.md`
- `docs/ai/notes/services/systemd-user-manager-dispatcher-log-noise-cleanup-2026-03.md`
- `docs/ai/notes/services/systemd-user-manager-dispatcher-reconciler-redesign-2026-03.md`
- `docs/ai/notes/services/systemd-user-manager-dry-activate-preview-2026-03.md`
- `docs/ai/notes/services/systemd-user-manager-first-run-naming-2026-03.md`
- `docs/ai/notes/services/systemd-user-manager-inactive-action-naming-2026-03.md`
- `docs/ai/notes/services/systemd-user-manager-per-user-apply-and-podman-actions-2026-03.md`
- `docs/ai/notes/services/systemd-user-manager-removed-user-stop-ordering-2026-03.md`
- `docs/ai/notes/services/systemd-user-manager-shell-helper-extraction-2026-03.md`
- `docs/ai/notes/services/systemd-user-manager-stable-state-backoff-2026-03.md`
- `docs/ai/notes/services/systemd-user-manager-stateless-manifest-plan-2026-03.md`
- `docs/ai/notes/services/systemd-user-manager-dispatcher-live-log-streaming-2026-04.md`
