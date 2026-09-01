# Pvl Btrfs Swap Migration Safety 2026-08

## Incident finding

Adding an `@swap` subvolume to a Disko declaration is not an in-place migration.
Disko creates that subvolume during installation, but a normal NixOS
`switch-to-configuration` only receives the generated `/swap` mount. On an
already installed host without `@swap`, the mount therefore fails before a
swapfile service can run.

The previous `lib/swap-auto.nix` ordering could not repair this state because
its swapfile preparation ran after `swap.mount`. The deploy log also showed the
SSH transport closing while Incus-related system units were restarting. That log
does not prove that swap caused the immediate transport loss or that the host
rebooted. It does prove that the declared swap migration was incomplete, and a
later boot could encounter the missing subvolume.

## Durable contract

For a sized swapfile whose exact parent mount is Btrfs with `subvol=<name>`,
`lib/swap-auto.nix` now:

- rejects evaluation if the containing Btrfs mount is disabled, lacks exactly
  one safe, single-component `subvol=` value, or does not use a device path
  below `/dev`;
- rejects evaluation unless both the Btrfs mount and swap entry include
  `nofail`;
- mounts the Btrfs top level privately, creates the sibling subvolume
  idempotently, and refuses to replace an existing non-subvolume path;
- pulls and orders the preparation service after the backing device unit so a
  stage-2 device appearance (for example a non-initrd LUKS unlock) cannot race
  the private top-level mount;
- runs preparation as a transient prerequisite before the generated mount unit,
  so every new mount attempt rechecks the subvolume without retaining service
  state;
- relies on the upstream NixOS sized-swap service to create the Btrfs swapfile;
- introduces a migration target wanted by `multi-user.target` so a live switch
  retries mount and swap units that already failed under the previous
  generation.

Provisioning errors remain visible as failed swap-related units, but `nofail`
keeps them from blocking multi-user boot and remote SSH recovery. The module
does not delete or replace storage objects.

`pvl-a1`, `pvl-l5`, and `pvl-x2` use this contract for `/swap/swap0`.

## Validation

- The evaluation test covers the generated dependency shape (including the
  device-unit ordering) and confirms that missing `nofail` declarations, a
  device outside `/dev`, a disabled mount, or an unsafe subvolume name fail the
  host build.
- The migration VM boots one node with an absent `@swap` and already-failed
  mount and swap units, then live-switches to the repaired configuration and
  verifies subvolume creation plus active swap. It stops and starts the mount
  chain again to verify that path remains idempotent.
- A cold-boot VM node boots the repaired configuration directly on an unmigrated
  disk (the boot-goal deploy shape) and provisions `@swap` without any live
  switch. The same node then power-cycles and verifies the provisioned subvolume
  and swapfile persist with an unchanged inode and size and no failed units.
- The same VM boots a second node with an already-mounted, active swapfile,
  live-switches to the repaired configuration, and verifies that the subvolume
  and swapfile identity are unchanged.
- The remote-recovery VM separately injects failures during subvolume
  preparation, swapfile creation, and swap activation. It verifies the exact
  bounded state at each boundary: an inactive mount after preparation failure,
  an active mount but no active swap after creation failure, and a failed swap
  unit after activation failure.
- Each controlled failure runs both during a cold boot and during a live
  `switch-to-configuration`. Cold boot reaches `multi-user.target`; a live
  switch reports the provisioning error without taking the running system down.
- A separate Tailscale peer uses a real test Headscale control server to ping
  and key-authenticate over SSH to every target's tailnet IP. Live-switch cases
  are checked before and after the failure. All cases verify
  `multi-user.target`, `sshd.service`, and `tailscaled.service` remain active
  and no broken swap is enabled.

No live host recovery or deployment is part of this repository change.
