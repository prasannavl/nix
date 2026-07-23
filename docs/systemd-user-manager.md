# Systemd User Manager

This module bridges deploy-time switching for user services. It exists for
direct managed user services that live under `systemd --user`.

Podman Compose no longer uses this module for generated compose instances; it
emits native user services and ready targets from
`lib/podman-compose/default.nix`. Keep this module for non-compose user units
that still need generation-driven old/new reconciliation.

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
- `verifyCommand`
- `timeoutReadySeconds`
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
- marks active restart-changed units for deferred restart, so reconcile still
  performs explicit work if the unit remains active after daemon reload
- defers reload for active units when only the reload stamp changed
- restarts `user@<uid>.service` if the managed user identity changed

New generation:

- ensures `user@<uid>.service` is running
- waits for the user bus
- runs `daemon-reload`
- reloads units with deferred reload-only changes
- restarts the reconciler
- waits for successful convergence
- runs provider verification commands for active running units
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

`timeoutReadySeconds` defaults to 120 seconds and bounds waits for a managed
unit to leave `activating`, `deactivating`, or `reloading` states during
reconcile and stop handling.

The generated dispatcher and reconciler use
`max(120, largest managed timeoutReadySeconds) + 60` as their systemd service
timeout, so systemd does not kill an intentionally long bounded reconcile before
the managed unit's own timeout can report success or failure.

`removalPolicy = "keep"` leaves a removed managed entry alone. With
`removalPolicy = "stop"`, the manager either stops the old unit directly or, if
`removalCommand` is set, runs that command as the managed user. Provider
commands are responsible for their own provider-specific stop, cleanup, or
takeover behavior.

`verifyCommand` is an optional provider-specific post-reconcile check. It runs
as the managed user after a desired-running unit is active. If verification
fails, the reconciler restarts that unit once and verifies again. Persistent
verification failure fails the reconcile transaction, so the dispatcher does not
record the generation as applied. Verification is skipped for intentionally
inactive desired-running units, such as `autoStart = false`.

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
- restarts active units with a deferred restart marker from the stop phase
- starts inactive or failed managed units unless `autoStart = false` or
  `state = "stopped"`
- verifies active desired-running units that declare `verifyCommand`, restarting
  once when the provider reports unapplied runtime drift
- uses each managed unit's `timeoutReadySeconds` for stable-state waits

After success it starts `systemd-user-manager-ready.target` for the users it
manages. That target is independent from Podman Compose's generated
`<user>-managed.target` and per-instance ready targets.

## Boot And Dry Activate

- Boot does not depend on mutable activation-time state.
- The real work happens through ordinary systemd units after switch.
- `dry-activate` runs the reconciler in preview mode.
- `dry-activate` skips preview for managed users whose live account does not
  exist yet.

## Podman Compose Boundary

`lib/podman-compose/default.nix` owns its own native user-service graph: one
aggregate `<user>-managed.target`, then per-instance stage, main, optional
reconcile, verify, and ready nodes. Bootstrap preparation runs inside the main
provider transaction rather than through a separate bootstrap service. Compose
`bootTag`, `reloadTag`, `recreateTag`, and `imageTag` are expressed through
generated systemd user-unit triggers and helper state rather than
`services.systemd-user-manager.instances`.

This keeps `systemd-user-manager` generic for the remaining direct user-service
callers. It switches declared units; module-specific behavior stays in the unit
definitions.

## Source Files

- `lib/systemd-user-manager/default.nix`
- `lib/systemd-user-manager/helper.sh`

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
