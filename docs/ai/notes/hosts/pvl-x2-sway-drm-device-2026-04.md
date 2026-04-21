# pvl-x2 Sway DRM Device

## Context

`pvl-x2` is an AMD-only host, but its real DRM node is not stable as
`/dev/dri/card0`.

In practice the compositor-facing AMD device can appear as `card1`, leaving
numeric `cardN` paths brittle for wlroots/Sway startup.

## Decision

- `lib/devices/gmtek-evo-x2.nix` owns stable AMD DRM symlinks for `pvl-x2`:
  `/dev/dri/zcard-amd` and `/dev/dri/zrender-amd`.
- `lib/wm.nix` points the `pvl-x2` Sway wlroots environment at those stable
  symlinks instead of numeric `/dev/dri/cardN` paths.
- Do not treat `card0` as a durable default for single-GPU hosts. Numeric DRM
  minors can shift because early boot DRM devices may claim lower numbers
  before the real GPU driver binds.

## Rationale

- This keeps Sway startup independent of kernel DRM minor numbering.
- The same stable-symlink pattern is already used on hybrid GPU hosts in this
  repo and should be preferred over guessing `card0` or `card1`.
