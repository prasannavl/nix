# Nixbot Systemd User Manager Deploy Summary

## Goal

Make `nixbot` print the `systemd-user-manager` dispatcher/reconciler result
inline immediately after a successful host deploy or host rollback, but only
when the dispatcher actually ran in that window.

## Decisions

- Print the report inline after each successful host deploy or host rollback
  instead of storing it as a separate deploy artifact or surfacing it in the
  global summary.
- Key the report to the local deploy start timestamp so it only shows dispatcher
  activity from this run.
- Collect the report through the normal prepared deploy/root command path so SSH
  target selection, proxying, sudo policy, and bootstrap fallback stay
  consistent with the rest of `nixbot`.
- Report on system dispatcher units
  `systemd-user-manager-dispatcher-*.service`, because the dispatcher already
  waits for the reconciler and streams reconciler logs into its own journal
  output.
- When a dispatcher ran during the deploy window, print the full journal for its
  latest invocation, not an arbitrary line tail.

## Implementation

- `pkgs/nixbot/nixbot.sh` now prints a `systemd-user-manager` block directly at
  the end of a successful host deploy job and successful host rollback.
- Serialized target-side helpers in `nixbot` now follow a `_remote_*` naming
  convention and are defined as normal local Bash functions, then shipped with
  `declare -f` for readability and syntax highlighting.
- The remote report command:
  - lists dispatcher units
  - filters to units with journal activity since the deploy start timestamp
  - prints each unit's active/sub state, result, and exec status
  - prints the full journal for the unit's last invocation
- Failed deploys and failed rollbacks do not print any dispatcher report.
- Successful runs where no dispatcher ran in that window are silent.

## Non-Goals

- This does not change deploy success/failure evaluation.
- This does not attempt to reconstruct reconciler state when the host is
  unreachable after deploy; those cases are reported as unavailable.
