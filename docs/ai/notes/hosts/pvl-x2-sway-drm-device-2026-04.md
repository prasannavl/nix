# pvl-x2 Sway DRM Device

## Context

`pvl-x2` is an AMD-only host, but its real DRM node is not stable as
`/dev/dri/card0`.

In practice the compositor-facing AMD device can appear as `card1`, leaving
numeric `cardN` paths brittle for wlroots/Sway startup.

## Decision

- Device modules own repo-stable DRM aliases keyed by host PCI identity rather
  than by vendor alone.
- `lib/devices/gmtek-evo-x2.nix` maps PCI `0000:c6:00.0` to
  `/dev/dri/zcard-amd`, `/dev/dri/zrender-amd`, `/dev/dri/zcard-default`, and
  `/dev/dri/zrender-default`.
- `lib/devices/asus-fa401wv.nix` maps PCI `0000:66:00.0` to the AMD/default
  aliases and PCI `0000:64:00.0` to the NVIDIA aliases.
- Shared compositor configs use the generic default aliases so they do not need
  host PCI paths or brand-specific names for the primary GPU.
- Brand-specific aliases such as `zcard-amd` and `zrender-amd` remain available
  for consumers that need to target a specific vendor explicitly.
- `lib/wm.nix` treats `zcard-default` and `zrender-default` as the wlroots
  defaults for normal hosts, with `pvl-a1` only overriding `drmDevices` to add
  `zcard-nvidia` as its secondary device.
- Do not treat `card0` as a durable default for single-GPU hosts. Numeric DRM
  minors can shift because early boot DRM devices may claim lower numbers before
  the real GPU driver binds.
- Do not use vendor-only matching for these aliases. The stable naming contract
  must be backed by host-specific PCI matches so same-vendor multi-GPU layouts
  do not collide.

## Rationale

- This keeps Sway and Niri startup independent of kernel DRM minor numbering.
- Shared compositor configs can refer to one logical default GPU name without
  repeating host PCI paths.
- PCI-backed alias rules remain unique even when multiple GPUs from the same
  vendor exist.
