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
- The dispatcher records the last successfully reconciled metadata under
  `/run/systemd-user-manager/applied-metadata/<user>.json`. This is runtime-only
  applied state, not a desired-state database; it lets activation compare the
  last converged user-unit set with the new generation even when
  `/run/current-system` has already advanced.
- Podman and other higher-level lifecycle semantics should be expressed through
  normal units and dependencies, not through a generic action graph inside the
  bridge. `reloadTriggers` are only a generic reload route; service-specific
  staging and validation still belong inside the unit's `ExecReload`.

## Switching rules

- Activation-time old-world stop compares last-applied metadata with new
  generation metadata.
- Applied metadata is versioned. Version mismatch skips old-versus-new diffing
  for that state and lets the dispatcher run a fresh reconcile path.
- New-world reconcile uses only the new desired metadata plus live
  `systemctl --user` state.
- Managed units have separate restart and reload stamps. Restart stamp changes
  keep the old-world stop and new-world start behavior. Reload-only changes are
  deferred, then applied with `systemctl --user reload <unit>` after the
  dispatcher's user-manager `daemon-reload`.
- Inactive or failed managed units are started unless they are disabled or
  masked.
- Managed units may opt out of cold-start through `autoStart = false`; they
  still remain under old-versus-new diff management, and units that were running
  when old-world stop touched them are restarted during new-world reconcile.
- Managed units use `state = "running" | "stopped"` for desired runtime state.
  `state = "stopped"` stops active units, keeps them inactive during
  reconciliation, and is the only generic stopped-state API.
- Managed units carry `timeoutStableSeconds`, defaulting to 120 seconds. The
  helper uses that per-unit timeout for stable-state and stopped-state waits so
  slow services can extend their own convergence budget.
- Removed users must be handled before account removal.

## Dispatcher behavior

- Identity-driven `user@<uid>.service` restarts should be detected during
  metadata comparison but executed later by the dispatcher through ephemeral
  `/run` markers.
- The dispatcher rechecks applied metadata before running the reconciler.
  Missing or version-mismatched applied metadata triggers a fresh reconcile path
  that stops already-active managed units once before starting them from new
  metadata, while normal fresh boots still start inactive units normally.
- Dispatcher system units must not add `After=` on the same target that pulls
  them in via `WantedBy=`. In particular, `WantedBy=multi-user.target` must not
  be paired with `After=multi-user.target`, or explicit deploy-time starts can
  hit a systemd transaction ordering cycle.
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
