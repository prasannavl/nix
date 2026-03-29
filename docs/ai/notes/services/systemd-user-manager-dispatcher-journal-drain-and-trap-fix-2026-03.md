# systemd-user-manager Dispatcher Journal Drain And Trap Fix (2026-03)

## Context

Two deploy-time failures showed that the dispatcher's reconciler wait path was
too fragile:

- changed managed units were stopped during activation and then did start again,
  but the deploy summary sometimes showed only a subset of the reconciler's
  `starting ...` log lines
- another host failed after a successful noop reconcile with:
  `line 89: log_pid: unbound variable`

## Root Cause

The dispatcher waited for the user reconciler by:

- starting the reconciler with `systemctl --user restart --no-block`
- opening `journalctl --follow` on that invocation in a background pipeline
- polling the reconciler's final state
- returning immediately when the reconciler reached success or failure

That had two problems:

- the dispatcher only copied reconciler logs that happened to pass through the
  live `journalctl --follow` pipeline before the function returned, so late
  lines could be lost from the dispatcher's own journal even though the
  reconciler really logged them
- cleanup used a `RETURN` trap that referenced a `local` `log_pid` while the
  dispatcher shell was running with `set -u`, which could raise an unbound
  variable error during trap execution

## Fix

- Remove the background `journalctl --follow` pipeline from
  `wait_for_reconciler`.
- Keep polling for the reconciler's final state as before.
- After the reconciler reaches a terminal state, dump the full journal for that
  invocation into the dispatcher log in one shot.
- Return success or failure based on the final observed reconciler state.

## Outcome

- The dispatcher journal now contains the full reconciler invocation log for the
  run it waited on, so `nixbot` summaries stop dropping late per-unit start
  lines.
- The dispatcher no longer depends on a `RETURN` trap or background log PID, so
  the `log_pid: unbound variable` failure is removed.

## Follow-Up

`nixbot` also needed a matching report-side fix. The deploy summary command was
reading dispatcher state immediately after `switch` returned, which could catch
`systemd-user-manager-dispatcher-*.service` in `activating/start` and print only
the first journal lines before reconcile completed.

The remote report helper now waits for any dispatcher unit with journal
activity in the current deploy window to reach a terminal state before it reads
that unit's status.

The report now prefers the matching
`systemd-user-manager-reconciler-<user>.service` invocation journal as the log
payload, because that is the actual source of per-unit `apply start`,
`starting`, `started`, and `apply completed` lines. It falls back to the
dispatcher journal only when no reconciler invocation ID is available.
