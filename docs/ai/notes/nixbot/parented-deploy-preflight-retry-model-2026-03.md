# Parented Deploy Preflight Retry Model

## Context

Parented Incus guest deploys started failing even though the parent deploy and
the child snapshot both succeeded.

Observed sequence:

- parent host deploy completed
- parent reconcile and settle completed
- child snapshot eventually succeeded
- deploy then failed during host age identity validation or installation with
  transport resets such as `Connection reset by 100.100.1.1 port 22`

This happened after deploy gained extra pre-activation host age identity work:
validation, optional reinstall, remote temp-file allocation, file copy, and the
activation-context visibility probe.

Snapshot remained stable because it already used a bounded retry loop around the
whole real operation for parented hosts. Deploy did not. It only retried
individual SSH substeps.

## Decision

Use the same parented whole-operation retry model for deploy preflight that
snapshot already uses.

`nixbot` now wraps the parented host age identity preparation flow in a bounded
retry loop derived from:

- `NIXBOT_PARENT_SNAPSHOT_READY_TIMEOUT`
- `NIXBOT_PARENT_SNAPSHOT_READY_INTERVAL_SECS`

The retried operation prepares fresh deploy context and reruns the exact
preflight work needed next:

- initial host age identity preparation
- forced pre-activation host age identity preparation plus activation-context
  visibility check

## Operational Effect

- parented child deploys now retry the actual fragile preflight workload rather
  than only individual remote file transfer steps
- snapshot and deploy now follow the same readiness model for parented hosts:
  retry the whole operation that must succeed next
- non-parented hosts keep the old single-attempt deploy behavior
