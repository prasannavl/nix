# Gap3 Gondor Base Image Recreation Investigation (2026-04)

## Context

- `pvl-x2` declaratively manages the outer Incus guest `gap3-gondor`.
- The repo no longer builds `hosts.gap3-gondor`; `hosts/default.nix` keeps that
  host commented out as reference only.
- `hosts/pvl-x2/incus.nix` still declares `gap3-gondor`, but it creates that
  guest from `inputs.self.nixosImages.gap3-base`.
- `lib/images/gap3-base.nix` is only a minimal base container image. It does not
  include the nested Incus setup or the separate `gap3x` takeover config.

## What happened

- On `2026-04-06`, `pvl-x2` switched from system generation `520`
  (`25.11.20260329.107cba9`) to generation `521` (`25.11.20260404.36a6011`).
- After the switch, `incus-machines-gc.service` ran as part of the normal
  `sysinit-reactivation.target` path.
- The declared Incus lifecycle then recreated both `gap3-gondor` and `pvl-vlab`.
- Journald on `pvl-x2` shows:
  - `Recreating gap3-gondor (config hash or recreate tag changed)...`
  - `Creating gap3-gondor from image local:nixos-incus-gap3-gondor...`
- The recreated outer guest came back with a fresh root filesystem from the
  repo's `gap3-base` image. Inside the guest:
  - `/etc/nixos/configuration.nix` is the empty generated stub.
  - `incus` is not installed.
  - `incus.service` does not exist.

## Impact

- The nested data under `/var/lib` on `gap3-gondor` survived because
  `hosts/pvl-x2/incus.nix` mounts a persistent custom volume there.
- The nested Incus state is still present under `/var/lib/incus`, including:
  - `containers/gap3-rivendell`
  - `containers/llmug-rivendell`
  - matching storage-pool paths and dnsmasq host entries
- What disappeared was the runtime/configuration from the outer guest rootfs, so
  the inner Incus control plane no longer starts and the preserved nested
  instances look "gone".

## Root cause

- A flake update changed the local image identity used by the declarative Incus
  machine definition on `pvl-x2`.
- `lib/incus/default.nix` includes the local image source paths in the desired
  machine config hash.
- `lib/incus/helper.sh` recreates a managed guest whenever the stored
  `user.config-hash` differs from the desired hash.
- Because `gap3-gondor` is managed here as a base image instead of the actual
  `gap3x` system, any recreation resets its root filesystem to that base image
  and drops the takeover runtime.

## Recovery direction

- Treat this as a rootfs-recreation incident, not a total data-loss incident.
- Recover by restoring the intended `gap3x` takeover on `gap3-gondor`, or by
  reintroducing a declarative image/config on `pvl-x2` that matches the real
  runtime.
- Do not assume the nested `gap3-rivendell` state is gone until `/var/lib/incus`
  inside `gap3-gondor` has been examined and either reattached to a working
  inner Incus daemon or explicitly removed.
