# Incus Removal Policy Metadata Sync

**Date**: 2026-03-30

## Summary

Teach `lib/incus.nix` to reconcile GC metadata on existing instances so changes
to machine `removalPolicy` and disk-device removal policies apply immediately,
without waiting for a recreate.

## Key Decisions

- Keep `removalPolicy` out of the recreate hash. It remains a GC policy, not a
  runtime recreate trigger.
- Update `user.removal-policy` during normal reconcile, alongside the existing
  `user.config-hash`, `user.boot-tag`, and `user.recreate-tag` sync.
- Reconcile per-disk GC metadata in place:
  - set `user.device.<name>.removal-policy` for currently declared disk devices
  - set `user.device.<name>.source` only for managed host directories
  - unset stale `user.device.<name>.*` keys when a disk device is removed or no
    longer eligible for host-dir cleanup

## Operational Effect

- Changing an instance `removalPolicy` now affects the stored Incus metadata on
  the next reconcile, even if the instance is not recreated.
- Changing a disk-device `removalPolicy` now also updates the stored GC metadata
  immediately.
- `delete-all` GC decisions now reflect the current declaration more reliably,
  including after disk-device removal.
