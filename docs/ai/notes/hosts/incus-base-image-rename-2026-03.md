# Incus Base Image Rename (2026-03)

## Scope

Rename the reusable Incus image module and image identity from `incus-bootstrap`
to `incus-base`.

## Decision

- Use `base` consistently for the generic reusable Incus image module, exported
  image key, and local Incus image alias.
- Keep guest-specific real configuration terminology unchanged; this rename only
  affects the reusable starting image.

## Source of truth files

- `lib/images/incus-base.nix`
- `lib/images/default.nix`
- `hosts/pvl-x2/incus.nix`
- `docs/incus-vms.md`
