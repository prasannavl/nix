# Incus Image And GC Rerunnable Oneshots

**Date**: 2026-03-30

## Summary

Removed `RemainAfterExit = true` from `incus-images.service` and
`incus-machines-gc.service` so parent-host deploys do not reuse stale systemd
"active (exited)" state as a proxy for real Incus state.

## Context

`incus-images.service` imports the local image aliases that guest lifecycle
units depend on, including the default `local:nixos-incus-base` alias. With
`RemainAfterExit = true`, a prior successful run left the unit in
`active (exited)`, so later deploys could satisfy `After=` / `Wants=` ordering
for guest lifecycle units without rerunning the image import helper.

That became incorrect when real Incus state drifted outside systemd. A parent
host could lose the local image alias out of band while `incus-images.service`
still looked active, and a guest recreate on the next deploy would then fail
with `Image "<alias>" not found`.

The same stale-success problem applies to `incus-machines-gc.service`: GC is a
re-runnable reconciliation helper, not a long-lived stateful service.

## Decision

- Treat image import and guest GC as normal rerunnable oneshot helpers.
- Let them exit back to `inactive` after each run.
- Keep the idempotence in the helper logic itself:
  - `images` no-ops when the declared alias source and rebuild tag already match
  - `gc` no-ops when no unmanaged declared drift exists

## Operational Effect

- On boot, both helpers still run via `wantedBy = [ "multi-user.target" ]`.
- On later deploys, they can be started again because they are no longer stuck
  in `active (exited)`.
- Guest lifecycle units that `Wants=` / `After=` `incus-images.service` can now
  trigger a fresh image-import pass instead of reusing stale unit state.
- The deploy model relies on helper idempotence rather than systemd active-state
  memoization.

## Source of Truth

- `lib/incus/default.nix`
