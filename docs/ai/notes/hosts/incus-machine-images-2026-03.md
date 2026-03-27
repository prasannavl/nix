# Incus Machine Images

**Date**: 2026-03-26

## Summary

Extended `lib/incus.nix` so each declared Incus machine can choose its own image
source while keeping the existing shared `incus-base` image as the default.

## Key Decisions

- Added top-level defaults:
  - `services.incusMachines.defaultImage`
  - `services.incusMachines.defaultImageAlias`
- Added per-machine overrides:
  - `services.incusMachines.machines.<name>.image`
  - `services.incusMachines.machines.<name>.imageAlias`
- `image` is overloaded by type:
  - strings are treated as remote Incus image references
  - non-string values are treated as local NixOS image builds
- Custom machine images default to alias `nixos-incus-<machine-name>` unless an
  explicit `imageAlias` is provided; custom string images default to a sanitized
  alias derived from the remote reference.
- Terminology:
  - `image` is the declared image source
  - `imageAlias` is the stable Incus-local alias used to create guests from that
    imported image
- `imageTag` now refreshes every declared image alias, not only the default
  `nixos-incus-base` alias.
- Guest recreate behavior remains explicit:
  - re-importing an image alias does **not** recreate existing guests
  - changing the declared `image` source is recreate-tracked even when
    `imageAlias` stays the same
  - guests recreate when `recreateTag` changes, when recreate-tracked config
    changes, or when the resolved image alias changes
- Added an assertion that rejects multiple machine image definitions that reuse
  the same alias for different underlying image sources.

## Source of Truth

- `lib/incus.nix`
- `docs/incus-vms.md`
