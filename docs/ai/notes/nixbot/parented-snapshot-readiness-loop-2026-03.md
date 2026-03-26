# Parented Snapshot Readiness Loop

## Context

The earlier conclusion that a short per-host `wait = 3` solved the Incus guest
snapshot race was not durable.

Repeated repros still failed for parented guests such as:

- `llmug-rivendell`
- `gap3-gondor`

Observed failure pattern:

- parent reconcile and settle succeeded
- the first real snapshot SSH probe still failed with transport resets such as:
  - `Connection reset by 100.100.1.1 port 22`
  - `kex_exchange_identification: read: Connection reset by peer`
- deploy then stopped because rollback snapshot capture is mandatory

This means the parent readiness barrier was proving the wrong thing:
Incus/tcp-level readiness from the parent was not yet equivalent to the actual
snapshot-path SSH readiness that `nixbot` needs next.

## Decision

Do not rely on guest-specific `wait` metadata for this problem.

Instead, for hosts with a declared `parent`, `nixbot` now loops on the actual
snapshot capture itself until it succeeds or a bounded attempt limit derived
from the timeout budget is reached.

Current defaults:

- `NIXBOT_PARENT_SNAPSHOT_READY_TIMEOUT=45`
- `NIXBOT_PARENT_SNAPSHOT_READY_INTERVAL_SECS=5`

## Operational Effect

- parented hosts now wait on the real readiness condition: successful
  snapshot-path SSH access
- retry logs now show `attempt x/y` so operators can see the bounded retry
  budget directly
- non-parented hosts keep the old single-attempt behavior
- host metadata no longer needs hard-coded `wait` values just to compensate for
  transient post-settle SSH resets
