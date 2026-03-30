# Incus GC Switch Trigger And Decoupling

## Context

`incus-machines-gc.service` is host-wide cleanup for managed Incus containers
that are no longer declared in NixOS config. It is not a prerequisite for
starting or recreating one specific guest.

The previous unit graph pulled GC into every guest lifecycle dependency chain,
which meant a single guest restart could also trigger global undeclared-instance
cleanup.

## Decision

- Remove `incus-machines-gc.service` from per-guest lifecycle dependencies.
- Treat GC as switch-scoped Incus maintenance instead of a per-guest
  prerequisite.
- Attach `incus-images.service` and `incus-machines-gc.service` to
  `sysinit-reactivation.target` instead of `multi-user.target`.
- Add a generated `incusSwitchStateFile` trigger that captures parent Incus
  preseed plus declared guest lifecycle state.
- Set `restartTriggers = [ helperScript incusSwitchStateFile ]` on:
  - `incus-images.service`
  - `incus-machines-gc.service`

## Operational Effect

- During `switch`, Incus helper services rerun when Incus-related declaration
  state changes.
- These maintenance helpers are no longer enabled directly under
  `multi-user.target`, so they do not become independent boot prerequisites.
- Guests still pull in `incus-images.service` when they genuinely need image
  reconciliation for create/recreate.
- `incus-machines-gc.service` still runs as part of Incus changes during switch,
  but it no longer runs implicitly just because one guest unit was started or
  restarted.
- Guest lifecycle keeps only its actual prerequisites:
  - `incus-preseed.service`
  - `incus-images.service`
