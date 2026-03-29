# Systemd User Manager Units

This document describes the shared `systemd-user-manager` module and the
simplified stateless model it now uses.

## Why This Module Exists

NixOS system services get deploy-time switching through
`switch-to-configuration`. Systemd user services do not. A deploy can update
user unit files on disk while leaving the old lingering user-manager process
tree running until something explicitly reloads and reconciles it.

This module provides that missing bridge for user managers, especially for
rootless workloads such as Podman compose stacks.

## Current Model

For each managed user, the module generates:

- one system dispatcher service:
  `systemd-user-manager-dispatcher-<user>.service`
- one user reconciler service: `systemd-user-manager-reconciler-<user>.service`

The dispatcher is the system-side entrypoint. The reconciler runs inside the
user manager and uses plain `systemctl --user`.

## Shared Unit Model

Modules declare managed user units under:

```nix
services.systemdUserManager.instances.<name> = {
  user = "app";
  unit = "app.service";
  restartTriggers = ["<generation-specific-value>"];
};
```

Supported options:

- `user`: owning account for the user manager
- `unit`: user unit to keep started
- `stopOnRemoval`: whether removing the managed entry stops the old unit
- `restartTriggers`: semantic triggers that mark the managed unit changed
- `stampPayload`: optional explicit payload hashed into the managed-unit stamp

## Stateless Switch Model

The module no longer uses `/var/lib/systemd-user-manager` state files and no
longer keeps a root-owned mutable desired-state cache.

Instead, each dispatcher unit carries a generation-local metadata file in the
store. That metadata includes:

- the managed unit set for the user
- each managed unit’s semantic stamp
- the managed user identity stamp

Switch behavior is split like this:

- old-world stop happens in the old dispatcher’s `ExecStop`
- new-world start happens in the new dispatcher’s `ExecStart`

During old-world stop, the old dispatcher compares its own metadata with the new
dispatcher metadata already loaded into `/etc/systemd/system`:

- removed managed units are stopped when `stopOnRemoval = true`
- changed managed units are stopped
- if the managed user identity stamp changed, `user@<uid>.service` is restarted
  after the old units are stopped

During new-world start, the dispatcher:

- ensures `user@<uid>.service` is active
- waits for the user bus
- runs one user-side `daemon-reload`
- restarts the single user reconciler
- waits for the reconciler to finish successfully

## Reconciler Model

The reconciler is intentionally narrow. It does not run a generic action graph
and it does not persist per-unit stamps.

It only needs:

- the new generation metadata
- live `systemctl --user` state

For each managed unit, it:

- checks the unit’s stable `ActiveState`
- leaves active units alone
- starts inactive or failed units unless the unit is disabled or masked

After successful convergence it starts `systemd-user-manager-ready.target`.

## Boot And Dry Activate

- boot does not depend on activation-time mutable work
- normal boot/startup happens later through the dispatcher system services
- `dry-activate` runs the reconciler script in preview mode as the managed user

## Podman Usage Pattern

`lib/podman-compose.nix` is the primary consumer.

- the main compose unit is managed by `systemd-user-manager`
- `bootTag` changes only the main managed-unit stamp
- `recreateTag` changes the main unit and makes its own `ExecStart` use
  `podman compose up --force-recreate`
- `imageTag` is a separate user oneshot pull unit wired as a dependency of the
  main compose service start path

That keeps `systemd-user-manager` generic: it only switches units. Module-level
behavior is compiled into ordinary unit content and dependencies.

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

- `lib/systemd-user-manager.nix`
- `lib/podman-compose.nix`
