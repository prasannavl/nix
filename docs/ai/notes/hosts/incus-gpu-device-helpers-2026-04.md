# Incus GPU Device Helpers 2026-04

## Scope

Records the shared helper shape for explicit Incus DRM and KFD passthrough
devices used by host-side guest declarations.

## Decision

- Keep the explicit `unix-char` device model for `/dev/dri/cardN`,
  `/dev/dri/renderDN`, and `/dev/kfd` instead of switching to the coarse Incus
  `gpu` device in guests that need distinct host `video` versus `render` group
  ownership.
- Centralize that device construction in `lib/incus/lib.nix`.

## Applied shape

- `lib/incus/lib.nix` exports:
  - `mkGpuDevices { card ? null; render ? null; kfd ? false; ... }`
- When imported with the host module `config`, the helper defaults those group
  IDs from:
  - `config.users.groups.video.gid`
  - `config.users.groups.render.gid`
- `mkGpuDevices` accepts each device independently:
  - `card = <n>` adds `/dev/dri/card<n>` with `video` group ownership and
    defaults the device key to `dev-dri-card-<n>`
  - `render = <n>` adds `/dev/dri/renderD<n>` with `render` group ownership and
    defaults the device key to `dev-dri-render-<n>`
  - `kfd = true` adds `/dev/kfd` with `render` group ownership
- `mkGpuDevices` owns the correct host and guest paths:
  - `/dev/dri/card<card>`
  - `/dev/dri/renderD<render>`
- `mkGpuDevices` also applies the split group ownership correctly:
  - `videoGid` to the card node
  - `renderGid` to the render node

## Why

- The host modules had repeated literal device attrsets with only the numeric
  card/render node suffixes and group IDs varying.
- A small shared helper keeps the explicit DRM/KFD passthrough model reusable
  without losing the host-specific group split that the generic Incus `gpu`
  device did not express cleanly.
