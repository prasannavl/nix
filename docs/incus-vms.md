# Incus Guests

This document describes the current Incus guest model, the shared lifecycle
module, and the operational rules for creating, rebuilding, and debugging
guests.

## Why This Module Exists

Incus provides the runtime for creating and managing VM and container guests,
but it has no built-in concept of declarative, NixOS-managed guest lifecycle.
Without a shared module, every parent host would need its own imperative scripts
to:

- Import and version a shared base image.
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
  - base image import
  - create/start
  - config-hash driven recreate
  - disk-device sync
  - guest removal GC
  - lifecycle tags
- `lib/incus-vm.nix` owns guest bootstrap conveniences:
  - persistent SSH host keys under `/var/lib/machine`
  - optional Tailscale auth wiring from `data/secrets/tailscale/<host>.key.age`
- The base image is generic and reused across guests.
- Guests become normal `nixbot` deploy targets after bootstrap.

## Shared Lifecycle Model

Parent hosts declare guests under:

```nix
services.incusMachines = {
  imageTag = "0";

  machines.<name> = {
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

## Tags

- `bootTag`:
  - default is `"0"`
  - when the stored value differs from the declared value, the guest is stopped
    and started again
- `recreateTag`:
  - default is `"0"`
  - when the stored value differs from the declared value, the guest is deleted
    and recreated from the current base image alias
- `imageTag`:
  - default is `"0"`
  - when the stored value on the shared base image alias differs from the
    declared value, the base image alias is deleted and re-imported

Operationally, the intended manual toggles are between `"0"` and `"1"`, though
any new string value works.

## What Changes Trigger

- `bootTag` change:
  - stop + start of the guest
  - no delete
  - no base image re-import
- `recreateTag` change:
  - stop + delete + create + start of the guest
  - recreated from the current `local:nixos-incus-base` alias
  - does not by itself re-import the base image alias
- `imageTag` change:
  - delete + re-import of the shared base image alias
  - no guest recreate by itself
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
2. `incus-image-base.service`
3. `incus-machines-gc.service`
4. `incus-<guest>.service`

That means:

- `imageTag` is evaluated before any guest recreate runs
- if the same deploy bumps both `imageTag` and a guest `recreateTag`, the guest
  recreate uses the newly re-imported base image alias

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
alias the next time the per-guest lifecycle service runs.

### What happens when I bump `imageTag`?

The shared `local:nixos-incus-base` alias is deleted and re-imported. Existing
guests are not recreated automatically just because the image alias changed.

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

Not just because the runtime object is missing. The guest lifecycle is driven by
the `incus-<guest>` systemd oneshot service. If you want to guarantee recreate
on the next deploy, bump `recreateTag` to a new value or restart that service.

### Does `recreateTag` rebuild the base image too?

No. `recreateTag` only recreates the guest instance. `imageTag` is the manual
knob for forcing base image alias re-import.

### Does `imageTag` also recreate running guests?

No. It only refreshes the shared base image alias. Existing guests keep their
current root filesystem until recreated.

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
