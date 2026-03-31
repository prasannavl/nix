# Nixbot Bootstrap Fallback Refresh And Logging (2026-03)

## Context

Nested-host deploy logs were noisy and misleading after the primary
`nixbot@host` probe failed and `nixbot` fell back to the bootstrap user.

Observed pattern:

- `prepare_deploy_context()` reported `Primary deploy target ... failed`
- fallback then reported `Reusing bootstrap readiness ...`
- later bootstrap transport retries printed fresh primary-probe failures again
- cached bootstrap reuse still printed the stronger
  `forced-command-only for ingress checks` wording

This made it look like the host was bouncing back and forth between primary and
bootstrap routes, even though the active operation was already running on the
bootstrap transport.

## Root Cause

- Transport retry helpers for remote file validation and installation use
  `refresh_prepared_primary_target` as their retry hook.
- That hook always re-prepared the host in `primary-only` mode, even when the
  current prepared context was already using bootstrap fallback.
- The in-flight retry still used its original bootstrap arguments, so the hook
  was only adding log noise; it was not changing the active transport.
- Separately, cached bootstrap readiness and live forced-command validation were
  collapsed into the same `validated_via_forced_command` flag, so cached reuse
  could print a message that implied a fresh forced-command conclusion.

## Decision

- `refresh_prepared_primary_target` must no-op while
  `PREP_USING_BOOTSTRAP_FALLBACK=1`.
- The bootstrap fallback branch in `prepare_deploy_context()` must distinguish:
  - cached bootstrap reuse
  - fresh forced-command validation
  - fresh bootstrap injection

## Operational Effect

- bootstrap transport retries no longer emit repeated primary-probe failures
  after fallback is already active
- cached bootstrap reuse now logs as cached bootstrap reuse, not
  forced-command-only ingress
- operators can still see the original primary failure that caused fallback, but
  not repeated false re-failures from retry hooks
