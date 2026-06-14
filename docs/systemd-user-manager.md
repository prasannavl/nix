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
services.systemd-user-manager.instances.<name> = {
  user = "app";
  unit = "app.service";
  state = "running";
  restartTriggers = ["<stamp>"];
  reloadTriggers = ["<reload-safe-stamp>"];
};
```

Important options:

- `user`
- `unit`
- `state`
- `autoStart`
- `removalPolicy`
- `removalCommand`
- `timeoutStableSeconds`
- `restartTriggers`
- `reloadTriggers`
- `stampPayload`
- `transitionNeutralStamp`
- `stopOnTransitionFrom`
- `stopOnTransitionTo`

## Switch Behavior

Applied old state:

- handles removed units according to `removalPolicy`
- stops units whose restart stamp changed
- defers reload for active units when only the reload stamp changed
- restarts `user@<uid>.service` if the managed user identity changed

New generation:

- ensures `user@<uid>.service` is running
- waits for the user bus
- runs `daemon-reload`
- reloads units with deferred reload-only changes
- restarts the reconciler
- waits for successful convergence
- records the new metadata as applied only after successful reconciliation

The applied-state copy lives under
`/run/systemd-user-manager/applied-metadata/<user>.json`. It is runtime-only
state and is used to compare the last converged user-unit set with the new
generation when `/run/current-system` may already point at the new system.

`autoStart = false` suppresses cold-start for an inactive managed unit, but it
does not remove that unit from old-versus-new diff management. If a deploy had
to stop a changed unit that was already running, the reconciler starts it again
in the new world.

`state = "stopped"` is desired stopped state. The dispatcher stops an active
unit and the reconciler keeps it inactive until the declaration returns to
`state = "running"`.

`timeoutStableSeconds` defaults to 120 seconds and bounds waits for a managed
unit to leave `activating`, `deactivating`, or `reloading` states during
reconcile and stop handling.

`removalPolicy = "keep"` leaves a removed managed entry alone. With
`removalPolicy = "stop"`, the manager either stops the old unit directly or, if
`removalCommand` is set, runs that command as the managed user. Provider
commands are responsible for their own provider-specific stop, cleanup, or
takeover behavior.

`reloadTriggers` are opt-in. If restart and reload stamps both change, restart
wins. Reload-only changes call `systemctl --user reload <unit>` after the new
generation's user units are daemon-reloaded, so the unit's new `ExecReload`
definition is used.

`transitionNeutralStamp`, `stopOnTransitionFrom`, and `stopOnTransitionTo` are
provider-owned transition controls. When old and new `transitionNeutralStamp`
match, a managed stamp change is treated as policy-only drift and does not stop
the unit by itself. The dispatcher still stops once when the old
`stopOnTransitionFrom` token matches the new `stopOnTransitionTo` token.
`systemd-user-manager` does not interpret provider policy names.

## Reconciler Behavior

The reconciler is intentionally narrow:

- reads generation metadata
- checks live `systemctl --user` state
- leaves active units alone
- starts inactive or failed managed units unless `autoStart = false` or
  `state = "stopped"`
- uses each managed unit's `timeoutStableSeconds` for stable-state waits

After success it starts `systemd-user-manager-ready.target`.

## Boot And Dry Activate

- Boot does not depend on mutable activation-time state.
- The real work happens through ordinary systemd units after switch.
- `dry-activate` runs the reconciler in preview mode.

## Podman Integration

`lib/podman-compose/default.nix` is the main consumer.

- the main compose unit is managed here
- `bootTag` changes the managed-unit stamp
- `reloadTag` changes the managed-unit reload stamp when native reload is
  enabled
- `recreateTag` changes the compose unit and forces recreate behavior
- `imageTag` is handled by a separate pull unit wired into the start path
- reload-safe directory-mounted compose config can flow through
  `reloadTriggers`; other changes keep using restart triggers

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
