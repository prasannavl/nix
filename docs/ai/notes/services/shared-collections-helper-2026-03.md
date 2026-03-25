# Shared Collections Helper

## Context

`lib/podman.nix` and `lib/systemd-user-manager.nix` both needed the same small
pure-Nix helper to detect duplicate generated service names.

Keeping identical local copies would make later fixes or behavior changes easy
to miss in one caller.

## Decision

Extract shared collection-oriented helpers into `lib/flake/utils`.

This keeps the helper in the repo's reusable library area rather than as an ad
hoc top-level file, while still remaining available to non-service-specific
modules.

## Implementation

- Added `lib/flake/utils/default.nix`.
- Moved `duplicateValues` there.
- Updated:
  - `lib/podman.nix`
  - `lib/systemd-user-manager.nix`

## Operational Effect

- No behavior change.
- Shared helper logic now has one source of truth.
