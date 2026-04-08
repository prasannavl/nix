# Systemd User Manager

This module bridges deploy-time switching for user services. It exists for
workloads such as rootless Podman stacks that live under `systemd --user`.

## What It Does

For each managed user, the module generates:

- `systemd-user-manager-dispatcher-<user>.service`
- `systemd-user-manager-reconciler-<user>.service`

The dispatcher runs from the system side. The reconciler runs inside the user's
manager and uses `systemctl --user`.

## Declaration

```nix
services.systemdUserManager.instances.<name> = {
  user = "app";
  unit = "app.service";
  restartTriggers = ["<stamp>"];
};
```

Important options:

- `user`
- `unit`
- `stopOnRemoval`
- `restartTriggers`
- `stampPayload`

## Switch Behavior

Old generation:

- stops removed units when `stopOnRemoval = true`
- stops changed units
- restarts `user@<uid>.service` if the managed user identity changed

New generation:

- ensures `user@<uid>.service` is running
- waits for the user bus
- runs `daemon-reload`
- restarts the reconciler
- waits for successful convergence

## Reconciler Behavior

The reconciler is intentionally narrow:

- reads generation metadata
- checks live `systemctl --user` state
- leaves active units alone
- starts inactive or failed managed units

After success it starts `systemd-user-manager-ready.target`.

## Boot And Dry Activate

- Boot does not depend on mutable activation-time state.
- The real work happens through ordinary systemd units after switch.
- `dry-activate` runs the reconciler in preview mode.

## Podman Integration

`lib/podman-compose/default.nix` is the main consumer.

- the main compose unit is managed here
- `bootTag` changes the managed-unit stamp
- `recreateTag` changes the compose unit and forces recreate behavior
- `imageTag` is handled by a separate pull unit wired into the start path

This keeps `systemd-user-manager` generic. It switches units. Module-specific
behavior stays in the unit definitions.

## Source Files

- `lib/systemd-user-manager/default.nix`
- `lib/systemd-user-manager/helper.sh`
- `lib/podman-compose/default.nix`
- `lib/podman-compose/helper.sh`

## Detailed Reference

The sections below cover rationale, FAQs, and source files.

## Why This Module Exists

NixOS handles system-service switching during deploys, but `systemd --user`
services need an explicit bridge from the system side. This module exists to
make lingering user managers converge during deploys without pushing Podman- or
service-specific behavior into activation scripts.

## FAQ

### Why not manage user units directly from `systemd.user.services` alone?

Because deploy-time switching is driven from the system side. The dispatcher is
the system-side hook that makes lingering user managers converge during deploys.

### Why is the reconciler per-user?

User units are defined globally in `systemd.user.services`, but the live user
manager boundary is still per-user. One reconciler per user keeps dispatch,
waiting, and failure isolation aligned with that boundary.

### Can this block boot activation?

No. Boot-time mutation is not performed in activation scripts. The real work is
done later by normal systemd units.

### What happens on `dry-activate`?

The module does not start the real dispatcher. It runs the same reconciler logic
as the managed user and logs what it would start.

## Source Of Truth Files

- `lib/systemd-user-manager/default.nix`
- `lib/systemd-user-manager/helper.sh`
- `lib/podman-compose/default.nix`
- `lib/podman-compose/helper.sh`
