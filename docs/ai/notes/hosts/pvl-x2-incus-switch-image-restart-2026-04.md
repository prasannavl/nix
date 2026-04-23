# pvl-x2 Incus Switch Image Restart 2026-04

## Scope

Records the `pvl-x2` deploy regression where `incus-gap3-gondor.service`
restarted during a normal `nixos-rebuild switch` because the unit definition
changed when the local NixOS image store paths changed.

## Findings

- `lib/incus/default.nix` encoded the full machine image JSON into each
  `incus-<name>.service` environment.
- For local images, that JSON includes store paths for the metadata/rootfs
  tarballs.
- A fresh image build changes those store paths even when the operator did not
  bump `bootTag`, `recreateTag`, or `imageTag`.
- Because the machine unit still used the default `restartIfChanged = true`,
  `switch` restarted the service, which ran the guest lifecycle path again.

## Durable rule

- Declared Incus machine services must not restart merely because their unit
  definition changed from incidental image-derivation churn.
- They should restart only from explicit lifecycle inputs:
  - config hash changes
  - disk sync metadata changes
  - `bootTag`
  - `recreateTag`
  - mutable instance properties such as `ipv4Address` and `removalPolicy`
- Image refresh remains owned by `services.incusMachines.imageTag` and the
  `incus-images.service` path, not by incidental unit restarts.

## Implementation direction

- Keep `incus-<name>.service` as the only restart path.
- Move volatile desired machine state, including local image tarball store
  paths, out of the unit definition and into a stable `/etc/incus-machines`
  JSON file that the helper reads at runtime.
- Keep the machine unit command lines stable by invoking the helper through
  `/run/current-system/sw/bin`, so helper/package store-path churn does not
  itself become another implicit restart trigger.
- Keep Incus ancillary services on narrow trigger inputs:
  - `incus-images.service` should trigger only from declared image state plus
    `imageTag`
  - `incus-machines-gc.service` should trigger only from declared instance
    membership
- Keep a separate lifecycle-trigger JSON file whose contents include only
  explicit lifecycle inputs:
  - config hash changes
  - disk sync metadata changes
  - `bootTag`
  - `recreateTag`
  - mutable instance properties such as `ipv4Address` and `removalPolicy`
- Point `incus-<name>.service.restartTriggers` at that lifecycle-trigger file.
- Result: local image rebuilds update `/etc` state without restarting guests,
  while explicit lifecycle changes still restart the normal machine unit during
  `switch`.
