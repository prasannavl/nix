# Incus Guests

Use this model for declarative Incus guest lifecycle on parent hosts.

## What It Owns

- image import and alias management
- guest create and start
- config-hash driven recreate behavior
- in-place disk-device sync
- cleanup of undeclared guests
- manual lifecycle tags

Shared logic lives in `lib/incus.nix`. Guest bootstrap conveniences live in
`lib/incus-vm.nix`.

## Source Of Truth

- parent host declarations: `hosts/<parent>/incus.nix`
- shared lifecycle logic: `lib/incus.nix`
- guest bootstrap logic: `lib/incus-vm.nix`
- base image build: `lib/images/incus-base.nix`
- guest config: `hosts/<guest>/`
- deploy metadata: `hosts/nixbot.nix`

## Declaration Shape

```nix
services.incusMachines = {
  defaultImage = inputs.self.nixosImages.incus-base;
  defaultImageAlias = "nixos-incus-base";
  imageTag = "0";
  preseedTag = "0";

  instances.<name> = {
    ipv4Address = "10.10.20.10";
    bootTag = "0";
    recreateTag = "0";

    config = {
      "security.nesting" = "true";
    };

    devices.state = {
      source = "<name>";
      path = "/var/lib";
    };
  };
};
```

## Images

- non-string `image`: import a local NixOS image build
- string `image`: use an Incus image reference such as `debian` or
  `images:debian/12`
- `imageAlias`: stable local alias used for `incus create`

## Lifecycle Tags

- `bootTag`: stop and start the guest
- `recreateTag`: delete and recreate the guest
- `imageTag`: refresh declared images
- `preseedTag`: force guest recreate after parent Incus fabric changes

Toggle the value when you want the behavior.

## What Triggers Recreate

- `recreateTag` changes
- `preseedTag` changes
- guest `config` changes
- `imageAlias` changes
- non-disk device changes

## What Does Not Recreate By Itself

- `bootTag` changes: only stop and start
- `imageTag` changes: image refresh only
- disk device changes: synced in place

## Devices

Disk devices:

- synced in place
- used for persistent `/var/lib`, bind mounts, and similar state paths

Non-disk devices:

- treated as create-only
- changing them forces recreate

## Deploy Order

Parent-host lifecycle runs in this order:

1. Incus preseed
2. image reconciliation
3. guest GC
4. per-guest lifecycle service

Deploy-time readiness is handled separately by
[`docs/incus-readiness.md`](./incus-readiness.md).

## Related Docs

- [`docs/incus-readiness.md`](./incus-readiness.md)
- [`docs/deployment.md`](./deployment.md)
- [`docs/hosts.md`](./hosts.md)

## Detailed Reference

The sections below cover rationale, lifecycle details, edge cases, and
operator-facing procedures.

## Why This Module Exists

Incus provides runtime guest management, but not this repo's declarative guest
lifecycle model. `lib/incus.nix` exists to make image import, create/start,
recreate triggers, in-place disk sync, guest GC, and manual lifecycle tags part
of ordinary deploy-time reconciliation instead of ad hoc host-local scripts.

## Current Model

- parent hosts declare guests in `hosts/<parent>/incus.nix`
- shared lifecycle logic lives in `lib/incus.nix`
- guest bootstrap conveniences live in `lib/incus-vm.nix`
- guests become normal `nixbot` deploy targets after bootstrap
- images, tags, and devices are declarative inputs to the parent-host lifecycle

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
- `preseedTag` is a manual parent-fabric coordination knob; bump it when a
  parent Incus preseed change should force guest recreate
- if the same deploy bumps both `imageTag` and a guest `recreateTag`, the guest
  recreate uses the newly refreshed image alias
- `incus-images.service` and `incus-machines-gc.service` are rerunnable
  oneshots, so later deploys do not reuse stale `active (exited)` state when
  Incus runtime state drifted out of band
- guest lifecycle units require successful `incus-images.service` completion, so
  image refresh failures surface on the image unit instead of cascading into a
  later guest-create `Image "<alias>" not found` error
- guest create/recreate also performs a just-in-time image preflight for its
  exact declared image, so the create path verifies the alias exists at the
  moment it is needed

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
- `/dev` host-path disk mounts are treated by `lib/incus/default.nix` as
  existing device trees, not persistent state directories

## FAQ

### What happens when I bump `recreateTag`?

The guest is deleted and recreated from the current `local:nixos-incus-base`
alias, or from that guest's configured `imageAlias`, the next time the per-guest
lifecycle service runs.

### What happens when I bump `imageTag`?

Every declared image alias is checked, and any alias whose stored source or
stored rebuild tag differs is refreshed. For local NixOS images that means
re-import; for remote string images that means copying the remote image into the
managed local alias again. Existing guests are not recreated automatically just
because an image alias was refreshed.

### What happens when I bump `preseedTag`?

Every declared guest on that parent host is recreate-tracked against the new tag
value, so the next lifecycle run recreates the guests even if their own
guest-local `config`, `image`, and devices did not change.

### What happens when I point a guest at a different image?

Changing the guest's declared `image` source updates which image content the
declared local alias should point at. That change does not by itself recreate
already-running guests. To roll an existing guest onto the refreshed image, also
bump `recreateTag` or otherwise make a recreate-tracked change.

### What happens when I change `image` but keep the same `imageAlias`?

That no longer triggers guest recreate by itself. The stable `imageAlias`
controls the local Incus handle used for guest create, while alias refresh is
handled separately through `imageTag`. Existing guests keep their current root
filesystem until a later recreate event.

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

Not during activation anymore. Activation no longer reconciles child guests. The
steady-state model is host-side reconcile outside activation via the declared
`incus-<guest>` lifecycle services, the `incus-machines-reconciler.service`
oneshot, or `nixbot`'s parent readiness barriers.

The reconcile policy is controlled by `services.incusMachines.reconcilePolicy`.
The default is **best-effort** on non-container parent hosts and `"off"` on
containerized Incus hosts such as nested guests. Boot-time auto-reconcile is
opt-in through `services.incusMachines.autoReconcile = true;`.

If you need to force a recreate even when the guest still exists and is running,
bump `recreateTag` to a new value.

### Does `recreateTag` rebuild the base image too?

No. `recreateTag` only recreates the guest instance. `imageTag` is the manual
knob for forcing declared image alias refresh.

### Does `imageTag` also recreate running guests?

No. It only refreshes declared image aliases. Existing guests keep their current
root filesystem until recreated by `recreateTag`, by another recreate-tracked
config change, or by deleting the guest and letting the lifecycle service
recreate it.

## Related Docs

- `docs/incus-readiness.md`: Readiness checks and deploy barriers for Incus
  guests.
- `docs/services.md`: Native service pattern for non-container workloads.
- `docs/podman-compose.md`: Podman compose container workloads (uses the same
  lifecycle tag conventions).
- `docs/deployment.md`: Deploy architecture, bootstrap flow, and secret model.

## Source Of Truth Files

- `lib/incus/default.nix`
- `lib/incus-vm.nix`
- `lib/images/incus-base.nix`
- `lib/images/default.nix`
- `hosts/<parent-host>/incus.nix`
- `hosts/<guest>/default.nix`
- `hosts/nixbot.nix`
