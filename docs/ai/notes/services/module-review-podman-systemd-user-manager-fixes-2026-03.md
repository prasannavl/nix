# Module Review Fixes: Podman and systemd-user-manager

## Context

A focused review of `lib/incus.nix`, `lib/podman.nix`, and
`lib/systemd-user-manager.nix` identified four issues:

1. silent duplicate-name collisions in generated Podman user units
2. lifecycle tag action units in Podman could race the main compose restart path
3. silent duplicate-name collisions in generated systemd-user-manager services
4. Incus guest reconcile during activation makes parent-host activation depend
   on guest convergence

The user asked to fix the first three issues now and defer the fourth.

## Decision

- Add hard assertions for generated service-name uniqueness in
  `lib/podman.nix`.
- Add hard assertions for generated service-name uniqueness in
  `lib/systemd-user-manager.nix`.
- Serialize Podman lifecycle action units relative to the main compose unit and
  to each other.
- Keep the Incus activation/convergence policy unchanged for now and revisit it
  separately.

## Implementation

### `lib/podman.nix`

- Compute generated `systemd.user` unit names for:
  - the main compose unit
  - `-image-tag`
  - `-recreate-tag`
  - `-boot-tag`
- Assert that those generated names are unique.
- Compute the generated `systemd-user-manager` bridge service names derived from
  those units and assert they are unique.
- Add ordering edges for lifecycle action units:
  - all lifecycle actions run after the main compose unit
  - `recreate-tag` runs after `image-tag`
  - `boot-tag` runs after both `image-tag` and `recreate-tag`

### `lib/systemd-user-manager.nix`

- Compute the generated systemd service names for:
  - per-user reload services
  - per-bridge services
- Assert that the combined set is unique so custom bridge `serviceName`
  overrides cannot silently shadow another bridge or reload service.

## Operational Effect

- Duplicate custom service names now fail evaluation instead of silently
  dropping units through `listToAttrs`.
- Podman lifecycle tag actions no longer run concurrently with each other when
  multiple tag units are part of the same deploy transaction.
- The Incus reconcile-on-activation policy remains as-is and should be reviewed
  separately if parent-host activation should become less strict.
