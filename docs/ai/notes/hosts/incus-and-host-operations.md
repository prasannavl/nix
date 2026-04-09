# Incus And Host Operations

## Scope

Canonical host-side guidance for Incus-managed guests, host documentation
structure, Cloudflare Tunnel host wiring, and durable operational findings from
recent host incidents.

## Incus parent and guest model

- Parent hosts own guest creation and startup.
- Guests boot from the reusable `lib/images/incus-base.nix` image and then
  converge to their real host config through `nixbot`.
- Guest-specific configuration stays under `hosts/<name>/`.
- Selecting a guest for deploy should also include its declared parent host.
- Activation-time guest reconcile should stay conservative on containerized
  parents. Do not rely on guest-side activation to reconcile nested Incus state.
- Fix hostname drift inside guests with the dedicated runtime hostname sync
  path, not with ad hoc `/proc/sys/kernel/hostname` writes or reboot-driven
  repair.

## Incus machines module

- The canonical module path is `lib/incus/default.nix`.
- Declarative guests live under `services.incusMachines`.
- Disk devices sync in place. Non-disk device changes are recreate-scoped.
- `bootTag`, `recreateTag`, `imageTag`, and `preseedTag` are the intentional
  operator bump knobs. Image refresh and guest recreate are separate decisions.
- Image import, reconcile, and GC services are ordinary rerunnable oneshots.
- GC must fail closed on Incus query failure and respect explicit removal
  policy.
- Duplicate guest `ipv4Address` declarations are an evaluation error.

## Guest secret and bootstrap model

- Machine identity secrets remain the canonical guest secret surface:
  `data/secrets/machine/<host>.key.age`.
- Optional guest Tailscale wiring belongs in `lib/incus-vm.nix`, not in the
  shared systemd-container base profile.
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
- SSH-specific operator and bastion guidance belongs in `docs/ssh-access.md`.
- The human-facing add-host flow should include:
  - parent-host declaration for nested guests
  - machine secret generation and recipient wiring
  - the rule that `parent` already supplies the dependency edge

## Cloudflare Tunnel host wiring

- Hosts should use the native `services.cloudflared.tunnels` NixOS module
  directly.
- Tunnel credentials stay in agenix-managed files under
  `data/secrets/cloudflare/tunnels/`.
- Host config may derive ingress metadata locally, but the final host wiring
  should still use the upstream NixOS module surface.

## Durable operational findings

- Bash prompt command substitution must stay as `'$(...)'` inside `PS1`; the
  escaped `'\$(...)'` form renders literally.
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

## Source of truth files

- `lib/incus/default.nix`
- `lib/incus/helper.sh`
- `lib/incus-vm.nix`
- `lib/images/incus-base.nix`
- `hosts/<parent-host>/incus.nix`
- `hosts/<guest>/default.nix`
- `hosts/nixbot.nix`
- `docs/hosts.md`
- `docs/ssh-access.md`
- `docs/incus-vms.md`

## Provenance

- This note replaces the earlier dated host, Incus, SSH-doc-structure, and
  host-incident notes from March and April 2026.
