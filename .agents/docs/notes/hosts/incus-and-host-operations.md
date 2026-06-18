# Incus And Host Operations

## Scope

Canonical host-side guidance for Incus-managed guests, host documentation
structure, Cloudflare Tunnel host wiring, and durable operational findings from
recent host incidents.

## Incus parent and guest model

- Parent hosts own guest creation and startup.
- Guests boot from the reusable `nixosImages.incus-lxc-base` or
  `nixosImages.incus-vm-base` image and then converge to their real host config
  through `nixbot`. Compatibility image exports are not part of the steady-state
  API.
- Guest-specific configuration stays under `hosts/<name>/`.
- Selecting a guest for deploy should also include its declared parent host.
- Activation-time guest reconcile should stay conservative on containerized
  parents. Do not rely on guest-side activation to reconcile nested Incus state.
- Fix hostname drift inside guests with the dedicated runtime hostname sync
  path, not with ad hoc `/proc/sys/kernel/hostname` writes or reboot-driven
  repair.

## Incus machines module

- The canonical module path is `lib/incus/default.nix`.
- Declarative guests live under `services.incus-manager`.
- Disk devices sync in place. Non-disk device changes are recreate-scoped.
- `bootTag`, `recreateTag`, `imageTag`, and `preseedTag` are the intentional
  operator bump knobs. Image refresh and guest recreate are separate decisions.
- Migration drain for NixOS hosts, including hosts that run as Incus LXCs, is
  guest-side `services.migration-manager`. Do not use parent-side Incus
  lifecycle stops as an application drain: that turns off the whole container
  instead of keeping the host reachable while repo-managed writers are quiesced.
- Image import, reconcile, and GC services are ordinary rerunnable oneshots.
- GC must fail closed on Incus query failure and respect explicit removal
  policy.
- Duplicate guest `ipv4Address` declarations are an evaluation error.
- Preseed fabric changes that rename or move live projects, networks, profiles,
  instances, or volumes must be declared explicitly in
  `services.incus-manager.global.preseedMigrations`; build-time assertions check
  that migration targets are present in `virtualisation.incus.preseed`.
- Incus project renames only work for empty projects. For non-empty project
  transitions, create/prepare the target project and profile, stop instances,
  then move custom volumes and instances across projects.
- Incus network renames only work when nothing uses the network. If a bridge is
  already referenced by live profiles or instances, preserve the bridge name or
  move consumers away before renaming it.
- One-shot migration payloads should be removed after live validation reaches
  the desired shape. Keep the generic migration actions, but do not leave
  host-specific transition allowances, stale bridge names, or temporary access
  grants in the steady-state host config.
- Laptop parents should enable `services.incus-manager.global.hostSuspend` so
  running Incus instances are stopped before host sleep and restarted after
  resume. This is host policy, not guest cooperation: container userspace must
  not be able to block the physical host freezer.

## Guest secret and bootstrap model

- Machine identity secrets remain the canonical guest secret surface:
  `data/secrets/globals/machine/<host>.key.age`.
- Optional guest Tailscale wiring belongs in `lib/incus-vm.nix`, not in the
  shared LXC base profile.
- Persistent server semantics for guest Tailscale should keep explicit tagged,
  non-ephemeral behavior.
- The reusable add-guest flow is:
  1. add `hosts/<name>/default.nix`
  2. register it in `hosts/default.nix`
  3. declare it under the parent's `incus.nix`
  4. add a deploy target in `hosts/nixbot.nix`
  5. add machine recipients and encrypted secrets
  6. deploy the parent
  7. deploy the guest

## Host docs structure

- `docs/hosts.md` should stay focused on host layout, registration,
  provisioning, and host-type guidance.
- SSH-specific operator and CI-host guidance belongs in `docs/ssh-access.md`.
- The human-facing add-host flow should include:
  - parent-host declaration for nested guests
  - machine secret generation and recipient wiring
  - the rule that `parent` already supplies the dependency edge

## Cloudflare Tunnel host wiring

- Hosts should use the native `services.cloudflared.tunnels` NixOS module
  directly.
- Tunnel credentials stay in agenix-managed files under
  `data/secrets/globals/cloudflare/tunnels/`.
- Host config may derive ingress metadata locally, but the final host wiring
  should still use the upstream NixOS module surface.

## Durable operational findings

- Bash prompt command substitution must stay as `'$(...)'` inside `PS1`; the
  escaped `'\$(...)'` form renders literally.
- For Incus LXC containers using `lib/profiles/incus-lxc.nix`, the online
  contract is the underlay interface `eth0:routable`. Overlay interfaces such as
  Tailscale should not decide `network-online.target` during activation. Keep
  `systemd-networkd-wait-online` scoped to `--interface=eth0:routable`.
- Incus LXC images should rely on the upstream NixOS activation path to create
  `/run/current-system` before systemd starts. Do not add repo-owned tmpfiles
  rules or early systemd units that relink `/run/current-system` to
  `/nix/var/nix/profiles/system`: the profile does not exist until
  `register-nix-paths.service` creates it with
  `nix-env --set /run/current-system`.
- `lib/profiles/incus-lxc.nix` is an Incus integration profile layered on top of
  upstream `virtualisation/lxc-container.nix`; it should not reimplement or
  fight upstream LXC boot, activation, or store-registration semantics. Prefer
  removing local meddling and restoring the upstream invariant over adding
  compensating first-boot services.
- NixOS LXC stage-2 activation creates `/run/current-system` before it execs
  systemd, but container systemd can establish the real tmpfs-backed `/run`
  after that point. When this hides activation-created runtime links, restore
  `/run/current-system` and `/run/booted-system` once, before upstream sysinit
  units. Derive the target from `/sbin/init`'s embedded `systemConfig` store
  path, and never point the links at `/nix/var/nix/profiles/system`, because
  that profile is the `register-nix-paths.service` output.
- Incus may still need narrow integration overrides where the runtime, not
  NixOS, owns the boundary. For LXC guests, force `boot.specialFileSystems = {}`
  as a whole-boundary override: upstream generic NixOS declares API/runtime
  mounts such as `/dev`, `/dev/pts`, `/dev/shm`, `/proc`, `/run`, and
  `/run/keys`, while Incus and container systemd provide the actual runtime
  mounts.
- Nested Incus LXC guests need udev coldplug before `systemd-networkd` can
  manage `eth0`. Upstream `virtualisation/lxc-container.nix` re-enables
  `systemd-udev-trigger.service` for this reason, and distrobuilder's LXC
  runtime drop-in calls `udevadm` through `/run/current-system/sw/bin/udevadm`.
  If the runtime system links are missing, the symptom is
  `systemd-udev-trigger.service` showing `status=203/EXEC`, `udevadm info`
  missing `ID_NET_DRIVER` and `ID_NET_LINK_FILE` on `eth0`, and networkd showing
  `Network File: n/a` plus `SETUP=pending`. Restore the NixOS runtime links
  before coldplug and let DHCP/networkd do the address assignment; do not add a
  separate service that reads `ipv4.address` from `/dev/incus/sock` and writes
  IP addresses manually.
- Incus base images must include the bootstrap `nixbot` SSH account, deploy
  public key, and trusted Nix user status. Snapshot and first deploy access
  happen before the guest-specific host configuration has been switched in, so
  relying on `hosts/<guest>` imports alone breaks freshly recreated guests with
  `Permission denied (publickey)` or unsigned-path copy failures.
- Fixing a base image does not repair an already-created guest rootfs. Keep
  `imageTag` as image import or refresh intent, and bump the affected guest's
  `recreateTag` when it must consume the fixed image.
- Incus local image cache checks must verify the actual metadata/rootfs artifact
  content, not only mutable image properties. A stale image can have its
  `user.base-image-*` properties rewritten while still exporting an old rootfs;
  after that happens, bump `recreateTag` again so guests consume the corrected
  alias.
- Do not flip an existing stateful LXC between privileged and unprivileged while
  preserving its `/var/lib` state disk. The rootfs can be recreated, but the
  kept state volume retains ownership/idmap assumptions from the previous
  privilege mode and can leave the instance Running while `incus exec` never
  becomes usable.
- LXC hostnames are declared through `networking.hostName`. Networkd must not
  apply DHCP-provided hostnames on `eth0`; set DHCPv4 and DHCPv6
  `UseHostname=false` to avoid D-Bus activation of `systemd-hostnamed.service`
  racing `systemd-hostnamed.socket` restarts during flake-update switches.
- Desktop suspend triage should start with watchdog behavior before broader GPU
  speculation.
- GNOME auto-lock failures on the affected desktop were caused by active idle
  inhibition, not by wrong lock settings.
- `amdxdna` probe failures on that host were firmware or protocol mismatch noise
  unless the NPU was intentionally in use.
- A recent outer-guest recreation incident was a rootfs-recreation issue, not a
  full data-loss event:
  - declarative Incus state recreated the outer guest from a minimal base image
  - `/var/lib` survived on the persistent volume
  - the lost piece was the outer guest runtime and takeover config
  - recovery should reattach or restore the intended outer guest runtime before
    assuming nested instances are gone

## Nested Incus pattern

- For nested Incus hosts, prefer `dir` storage for the inner layer to avoid
  btrfs-on-btrfs.
- GPU passthrough should match the actual hardware model; avoid inheriting
  unrelated NVIDIA assumptions into AMD-backed guests.
- Podman services, nested Incus, and GPU passthrough can coexist, but the
  source-of-truth files should remain split between the parent host, the nested
  host, and the nested guest.
- When sibling parent fabrics need to reach a subnet behind a nested Incus
  router, declare the route on the parent host that owns both fabrics. In the
  current `pvl-x2` plus `gap3-gondor` shape, traffic from the `abird` project to
  `10.10.30.0/24` needs a parent-host route via `10.10.20.20`; the nested bridge
  NAT handles guest egress, but reverse-initiated traffic does not work until
  the parent knows that `10.10.30.0/24` lives behind the outer nested host.

## Source of truth files

- `lib/incus/default.nix`
- `lib/incus/helper.sh`
- `lib/profiles/incus-lxc.nix`
- `lib/profiles/incus-vm.nix`
- `lib/images/default.nix`
- `lib/images/incus-lxc-base.nix`
- `lib/images/incus-vm-base.nix`
- `hosts/<parent-host>/incus.nix`
- `hosts/<guest>/default.nix`
- `hosts/nixbot.nix`
- `docs/hosts.md`
- `docs/ssh-access.md`
- `docs/incus-vms.md`

## Provenance

- This note replaces the earlier dated host, Incus, SSH-doc-structure, and
  host-incident notes from March and April 2026.
