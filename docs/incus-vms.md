# Incus Guests

This document describes the current Incus guest model, the shared lifecycle
module, and the operational rules for creating, rebuilding, and debugging
guests.

## Why This Module Exists

Incus provides the runtime for creating and managing VM and container guests,
but it has no built-in concept of declarative, NixOS-managed guest lifecycle.
Without a shared module, every parent host would need its own imperative scripts
to:

- Import and version declared local images, or mirror remote Incus images into
  stable local aliases.
- Create guests from that image with the right config, devices, and network
  settings.
- Detect when guest configuration has drifted from the declared state and
  recreate the guest.
- Reconcile disk devices in place while forcing recreate for create-only devices
  like GPUs.
- Garbage-collect guests that are no longer declared.
- Provide manual lifecycle knobs (stop/start, delete/recreate, image refresh)
  that integrate with the deploy flow rather than requiring out-of-band
  intervention.

`lib/incus.nix` exists to own that lifecycle declaratively so parent hosts only
describe the desired guest set — IPs, config, devices — and the module handles
image import, create/start, config-hash tracking, device sync, GC, and lifecycle
tags as ordinary systemd services that run during deploy.

## Current Model

- Parent host orchestration lives in `hosts/<parent-host>/incus.nix`.
- Shared Incus lifecycle logic lives in `lib/incus.nix`.
- Reusable guest bootstrap logic lives in `lib/incus-vm.nix`.
- Reusable base image build lives in `lib/images/incus-base.nix`.
- Guest-specific real configuration still lives under `hosts/<guest>/`.
- Deploy targeting still lives in `hosts/nixbot.nix`.

## What Is Reusable

- `lib/incus.nix` owns declarative guest lifecycle:
  - declared image import
  - create/start
  - config-hash driven recreate
  - disk-device sync
  - guest removal GC
  - lifecycle tags
- `lib/incus-vm.nix` owns guest bootstrap conveniences:
  - persistent SSH host keys under `/var/lib/machine`
  - optional Tailscale auth wiring from `data/secrets/tailscale/<host>.key.age`
- `lib/incus-vm.nix` also owns runtime hostname convergence with a dedicated
  oneshot service that uses `hostname(1)` instead of writing
  `/proc/sys/kernel/hostname` directly.
- The default base image is generic and reused across guests.
- Each guest can optionally point at a different image source, including remote
  Incus images such as `debian` or `images:ubuntu/24.04`.
- Guests become normal `nixbot` deploy targets after bootstrap.

## Shared Lifecycle Model

Parent hosts declare guests under:

```nix
services.incusMachines = {
  defaultImage = inputs.self.nixosImages.incus-base;
  defaultImageAlias = "nixos-incus-base";
  imageTag = "0";

  machines.<name> = {
    image = null; # NixOS image attrset or a string like "debian"
    imageAlias = null; # the stable local Incus alias used for `incus create`
    ipv4Address = "10.10.20.10";
    bootTag = "0";
    recreateTag = "0";

    config = {
      "security.nesting" = "true";
    };

    devices = {
      state = {
        source = "<name>";
        path = "/var/lib";
      };
    };
  };
};
```

When `services.incusMachines.machines` is non-empty, the shared module also
enables Incus and provides the default package/UI settings automatically.

Terminology:

- `image`: the image source for the guest
  - a non-string value is treated as a local NixOS image build to import
  - a string is treated as an Incus image reference, such as `debian` or
    `images:debian/12`
- `imageAlias`: the stable Incus-local name for that imported image, for example
  `nixos-incus-base`, which is then used as `local:<alias>` during guest create
- `imageTag`: a manual redeploy knob that forces declared image aliases to be
  refreshed

For string images:

- `debian` is resolved as `images:debian`
- `images:debian/12` is used as-is
- the module copies the remote image into local Incus under the resolved
  `imageAlias`, then creates the guest from `local:<alias>`

## Tags

- `bootTag`:
  - default is `"0"`
  - when the stored value differs from the declared value, the guest is stopped
    and started again
- `recreateTag`:
  - default is `"0"`
  - when the stored value differs from the declared value, the guest is deleted
    and recreated from the current resolved image alias
- `imageTag`:
  - default is `"0"`
  - when the stored value on any declared image alias differs from the declared
    value, that image alias is refreshed

Operationally, the intended manual toggles are between `"0"` and `"1"`, though
any new string value works.

## What Changes Trigger

- `bootTag` change:
  - stop + start of the guest
  - no delete
  - no base image re-import
- `recreateTag` change:
  - stop + delete + create + start of the guest
  - recreated from the guest's resolved Incus image alias
  - does not by itself re-import any image alias
- `imageTag` change:
  - refresh of all declared image aliases
  - no guest recreate by itself
- guest `image` source change:
  - triggers guest recreate
  - the guest image source is part of the recreate-tracked config hash
- guest `imageAlias` resolution change:
  - triggers guest recreate
  - changing the image slot a guest is created from is treated as a recreate
    input
- guest `config` attr change:
  - triggers guest recreate
  - implemented through the stored `user.config-hash`
- disk device change:
  - synced in place
  - no guest recreate by itself
- non-disk device change:
  - triggers guest recreate
  - includes devices such as `gpu`, `unix-char`, and similar create-only types

## Device Change Behavior

### Disk Devices

Disk devices are reconciled in place.

Typical examples:

- persistent `/var/lib` state disks
- host-path bind mounts
- Incus storage volume mounts
- `/dev/dri` passthrough when modeled as a host-path disk mount

What happens when they change:

- add a new disk device: added in place
- remove a disk device: removed in place
- change disk properties such as `source`, `path`, `shift`, or `pool`: updated
  in place
- remove a previously set disk property: unset in place

This does not force guest recreate by itself.

### Non-Disk Devices

Non-disk devices are create-only in the shared lifecycle model.

Typical examples:

- `gpu`
- `unix-char`
- `nic`

What happens when they change:

- any add, remove, or property change contributes to the create-only device hash
- hash change triggers guest recreate

This is why GPU-related device changes recreate the guest rather than being
patched live.

### `/dev` Host-Path Disk Mounts

`/dev` host-path disk mounts are a special case of disk devices.

What makes them special:

- they still sync in place like other disk devices
- they are treated as existing device trees, not persistent state directories
- the module does not tmpfiles-create them
- GC does not remove them as guest-owned data

## Deployment And Sequencing

On parent-host deploy, the shared lifecycle model runs in this order:

1. `incus-preseed.service`
2. `incus-images.service`
3. `incus-machines-gc.service`
4. `incus-<guest>.service`

That means:

- `imageTag` is evaluated before any guest recreate runs
- if the same deploy bumps both `imageTag` and a guest `recreateTag`, the guest
  recreate uses the newly refreshed image alias

## What A Parent Host Must Provide

For each guest entry in `hosts/<parent-host>/incus.nix`:

- `ipv4Address`
- `config`
- `devices`
- optional `bootTag`
- optional `recreateTag`
- optional `removalPolicy`

Typical devices:

- persistent `/var/lib` disk
- GPU passthrough
- extra data mounts
- special char devices such as `/dev/kfd`

## How To Create A New Guest

1. Add `hosts/<name>/default.nix`.
   - import `../../lib/profiles/systemd-container.nix`
   - import `(import ../../lib/incus-vm.nix { inherit hostName; })`
   - add host-local modules as needed
2. Register the guest in `hosts/default.nix`.
3. Add a guest entry to `hosts/<parent-host>/incus.nix`.
   - pick a stable IP on the parent-host Incus bridge
   - add the persistent `/var/lib` device
   - add any workload-specific devices
4. Add the deploy target in `hosts/nixbot.nix`.
5. Add machine identity secrets.
6. Optionally add Tailscale auth secrets.
7. Re-encrypt `data/secrets`.
8. Deploy the parent host.
9. Deploy the guest itself.

## Secret Model

- Required:
  - `data/secrets/machine/<host>.key.age`
- Optional:
  - `data/secrets/tailscale/<host>.key.age`
  - when present, `lib/incus-vm.nix` both wires and enables `services.tailscale`
- Not repo-managed:
  - `/var/lib/machine/ssh_host_ed25519_key`
  - `/var/lib/machine/ssh_host_rsa_key`

Incus guests use the normal machine identity and `nixbot` deploy model. There is
no separate Incus-only secret exchange layer.

## GPU-Backed Guests

For an AMD-backed guest, the durable model is:

- `/dev/dri` available inside the guest
- `/dev/kfd` available inside the guest
- workload access through `video` and `render` groups

For nested Incus specifically:

- the outer guest can use a normal Incus `gpu` device
- the inner nested guest should use `/dev/dri` passthrough plus `/dev/kfd`
- `/dev` host-path disk mounts are treated by `lib/incus.nix` as existing device
  trees, not persistent state directories

## FAQ

### What happens when I bump `recreateTag`?

The guest is deleted and recreated from the current `local:nixos-incus-base`
alias, or from that guest's configured `imageAlias`, the next time the
per-guest lifecycle service runs.

### What happens when I bump `imageTag`?

Every declared image alias is checked, and any alias whose stored source or
stored rebuild tag differs is refreshed. For local NixOS images that means
re-import; for remote string images that means copying the remote image into the
managed local alias again. Existing guests are not recreated automatically just
because an image alias was refreshed.

### What happens when I point a guest at a different image?

Changing the guest's declared `image` source is recreate-tracked, so the guest
is recreated on the next run of its lifecycle service. Re-importing or
refreshing the content behind the same declared image source does not by itself
recreate already-running guests.

### What happens when I change `image` but keep the same `imageAlias`?

That still triggers guest recreate, because the declared image source is part of
the recreate-tracked config hash. The stable `imageAlias` controls the local
Incus handle used for create, not whether a source change is considered a new
guest image input.

### What happens when I change guest `config`?

Guest `config` changes trigger recreate. The module stores a config hash on the
instance and recreates when that hash changes.

### What happens when I change a disk device?

Disk devices sync in place. They are added, removed, updated, or unset without
recreating the guest.

### What happens when I change a GPU or other non-disk device?

Non-disk devices are create-only. Changing them triggers guest recreate.

### If I bump both `imageTag` and `recreateTag` in one deploy, is ordering correct?

Yes. The image import service runs before the guest lifecycle services, so the
guest recreate uses the refreshed base image alias.

### Why didn't setting `recreateTag = "1"` force a recreate earlier?

Because the old default was also `"1"`. A lifecycle tag only does work when its
declared value changes relative to the stored value.

### What are the defaults now?

- `bootTag = "0"`
- `recreateTag = "0"`
- `imageTag = "0"`

### If I manually delete a guest in Incus, will the next deploy recreate it automatically?

Yes, on the next parent-host activation. The shared module now reconciles
declared guests during activation and restarts the `incus-<guest>` lifecycle
service when a guest is missing or stopped.

By default this reconcile is **best-effort** on non-container parent hosts and
`"off"` on containerized Incus hosts such as nested guests. If you want parent
activation to be blocked on guest convergence, set
`services.incusMachines.reconcileOnActivation = "strict"`. You can also disable
activation-time guest reconcile entirely with `"off"`.

If you need to force a recreate even when the guest still exists and is running,
bump `recreateTag` to a new value.

### Does `recreateTag` rebuild the base image too?

No. `recreateTag` only recreates the guest instance. `imageTag` is the manual
knob for forcing declared image alias refresh.

### Does `imageTag` also recreate running guests?

No. It only refreshes declared image aliases. Existing guests keep their
current root filesystem until recreated by `recreateTag`, by a recreate-tracked
config change such as changing `image`, or by deleting the guest and letting
the lifecycle service recreate it.

## Related Docs

- `docs/services.md`: Native service pattern for non-container workloads.
- `docs/podman-compose.md`: Podman compose container workloads (uses the same
  lifecycle tag conventions).
- `docs/deployment.md`: Deploy architecture, bootstrap flow, and secret model.

## Source Of Truth Files

- `lib/incus.nix`
- `lib/incus-vm.nix`
- `lib/images/incus-base.nix`
- `lib/images/default.nix`
- `hosts/<parent-host>/incus.nix`
- `hosts/<guest>/default.nix`
- `hosts/nixbot.nix`
