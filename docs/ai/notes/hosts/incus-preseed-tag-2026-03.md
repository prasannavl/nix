# Incus Preseed Tag

**Date**: 2026-03-31

## Summary

Add `services.incusMachines.preseedTag` as an explicit manual coordination knob
for disruptive parent-host Incus preseed changes.

## Context

Parent-host Incus preseed changes can alter bridge names, profile wiring,
storage topology, or other guest creation assumptions. Those changes are not
part of any individual guest's declared `config`, `image`, or device set, so the
shared guest recreate hash previously had no way to represent a parent Incus
fabric epoch.

## Decision

- Add top-level `services.incusMachines.preseedTag`.
- Fold `preseedTag` into each guest's recreate-tracked config hash.
- Document it as a manual operator bump for disruptive parent Incus preseed
  migrations.

## Operational Effect

- Bumping `preseedTag` forces every declared guest on that parent host to
  recreate on its next lifecycle run.
- The tag does not itself reconcile or delete old Incus networks, profiles, or
  other preseeded objects; it is a coordination knob, not a full migration
  engine.
- This keeps preseed-driven guest recreation explicit, similar to `imageTag`,
  `bootTag`, and `recreateTag`.

## Source of Truth

- `lib/incus/default.nix`
- `hosts/<parent-host>/incus.nix`
