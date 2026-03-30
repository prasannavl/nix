# Parented Primary-Ready Cache Invalidation

## Context

Parented child deploys still showed bursts of:

- `kex_exchange_identification: read: Connection reset by peer`
- remote file validation retries
- remote temp allocation retries

even after the broader parented deploy preflight retry model was added.

The key issue was phase reuse of the `primary-ready` cache:

- a parented child could succeed once during snapshot
- that success marked the child as `primary ready`
- deploy then reused that cached state and skipped a fresh connectivity probe
  right before deploy preflight

In practice, the parented child path can still be unstable for a short window
after the parent switch and the snapshot phase, so snapshot success is not a
durable deploy-ready lease.

## Decision

Invalidate `primary-ready` state for parented hosts before deploy and before
each parented whole-operation retry attempt.

This forces `prepare_deploy_context` to re-probe the child transport at deploy
time instead of trusting snapshot-era readiness.

## Operational Effect

- parented deploy preflight now proves fresh connectivity at the point deploy
  actually needs it
- short post-parent-switch SSH reset windows are less likely to surface first in
  remote file validation or temp-file allocation
- retry logs are clearer because transport labels now include the deploy node
  and target together for file install steps
