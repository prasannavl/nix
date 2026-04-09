# Systemd User Manager

## Scope

Canonical design for the generation-driven `systemd-user-manager` bridge and its
interaction with deploy-time service reconciliation.

## Core model

- Keep the abstraction narrow:
  - old-world stop for managed user units
  - new-world start and reconcile
  - user-manager identity refresh
  - dry-activate preview
- Desired state comes from generation-local immutable metadata in the store, not
  from mutable root-owned state under `/var/lib`.
- Podman and other higher-level lifecycle semantics should be expressed through
  normal units and dependencies, not through a generic action graph inside the
  bridge.

## Switching rules

- Activation-time old-world stop compares old and new generation metadata.
- New-world reconcile uses only the new desired metadata plus live
  `systemctl --user` state.
- Inactive or failed managed units are started unless they are disabled or
  masked.
- Removed users must be handled before account removal.

## Dispatcher behavior

- Identity-driven `user@<uid>.service` restarts should be detected during old
  versus new comparison but executed later by the dispatcher through ephemeral
  `/run` markers.
- Dispatcher progress should remain visible, but unit-state polling is the
  authoritative wait path.
- Bound journal polling with `timeout`, rate-limit journal reads, and emit
  heartbeats while waiting so quiet or slow journald paths do not look hung.
- Metadata parsing failures must be fatal; malformed JSON must not become a
  silent noop because of process-substitution behavior.

## Operational refinements

- Keep dispatcher logs thin and useful.
- Preserve remote dispatcher diagnostics in deploy logs instead of filtering
  away the lines that explain the failure.
- Parse metadata once per dispatcher where possible instead of re-running small
  `jq` selections per managed unit.

## Source of truth files

- `lib/systemd-user-manager/default.nix`
- `lib/systemd-user-manager/helper.sh`
- `docs/systemd-user-manager.md`

## Provenance

- This note replaces the earlier dated bridge-architecture, dispatcher-fix, and
  related follow-up notes for `systemd-user-manager`.
