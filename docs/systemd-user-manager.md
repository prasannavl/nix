# Systemd User Manager Units

This document describes the shared `systemd-user-manager` unit-reconciler module and how
it is used to apply deploy-time behavior to systemd user services.

## Why This Module Exists

NixOS system services get deploy-time restart and reload behavior for free
through the built-in `switch-to-configuration` machinery. Systemd user services
do not. When `nixos-rebuild switch` runs, it knows which system units changed
and restarts them, but it has no equivalent awareness of units running inside
lingering user managers.

That creates a real problem for rootless workloads like Podman compose stacks.
Without intervention, a deploy that changes a compose definition would update
the unit files on disk but leave the old user service running until someone
manually restarts it or the machine reboots.

The module solves this by creating system-side services that:

- Reconcile selected user units from the system side during deploy.
- Persist per-unit stamps so the new generation can decide what changed.
- Replay the appropriate action (restart, reload, or start) against the correct
  user unit after the switch only when the observed unit was previously active.
- Coordinate a single `daemon-reload` per user manager even when multiple
  managed units change in the same deploy.
- Restart the user manager itself when group membership changes, so rootless
  services immediately see new supplementary groups.

This gives user services the same deploy-time lifecycle awareness that system
services get natively, without requiring the workloads themselves to know
anything about NixOS generations.

## Current Model

- Shared unit-reconcile logic lives in `lib/systemd-user-manager.nix`.
- One serialized reconciler service is generated per user manager.
- Managed units are reconciled by that service through
  `systemctl --user --machine=<user>@ ...`.
- The main current consumer is `lib/podman.nix`, but the module is
  generic and can be reused by other user-service modules.

## Boot Activation Invariant

Boot activation is not allowed to depend on this module's mutable work.

- No `systemd-user-manager` activation script may block boot.
- On `NIXOS_ACTION=boot`, module-owned activation scripts must skip mutating
  work entirely.
- Any boot-time reconcile, healing, cleanup, or startup ordering must happen
  later through normal systemd units and targets after userspace is up.

## What Is Reusable

- per-user user-manager reload orchestration
- deploy-time old-stop/new-start behavior for user units
- user-manager restart on account or group changes
- managed-unit configuration for observe-versus-change unit separation

## Shared Unit Model

Modules declare instances under:

```nix
services.systemdUserManager.instances.<name> = {
  user = "app";
  unit = "app.service";
  restartTriggers = ["<generation-specific-value>"];
};
```

More advanced units can also set:

- `observeUnit`
- `changeUnit`
- `onChangeAction`
- `startOnFirstRun`
- `stopOnRemoval`
- `preActions`
- `postActions`

## Core Behavior

Each managed unit is reconciled inside the per-user apply service:

- on deploy, the reconciler compares persisted stamps for the managed unit and
  its pre-actions and post-actions
- if the observed unit was active, it replays the requested action against the
  change unit
- if the unit is unchanged but drifted inactive, it starts it again unless the
  unit file is disabled or masked
- removed managed entries are pruned from persistent state and can stop their
  owned user unit on removal

This gives deploy-time behavior that matches the previous active state while
still healing unexpected drift.

## Unit Options

- `user`:
  - required
  - target user manager owner
- `unit`:
  - default target user unit
- `observeUnit`:
  - optional
  - unit whose `ActiveState` decides whether the bridge should act
  - defaults to `unit`
- `changeUnit`:
  - optional
  - unit the bridge operates on when it does act
  - defaults to `unit`
- `onChangeAction`:
  - default is `restart`
  - supported values: `restart`, `reload`, `start`
- `startOnFirstRun`:
  - default is `true`
  - whether a brand-new bridge starts its target on its first apply pass
- `stopOnRemoval`:
  - default is `true`
  - whether removing the managed unit stops the user unit
- `restartTriggers`:
  - values baked into the managed-unit stamp so generation changes trigger
    reconciliation behavior
- `stampPayload`:
  - optional explicit value hashed for the persisted managed-unit or action
    stamp
  - use this when runtime argv or generated store paths should not count as a
    semantic lifecycle change
- `preActions.<name>.observeUnitInactiveAction` /
  `postActions.<name>.observeUnitInactiveAction`:
  - default is `fail`
  - controls what happens when an action is pending but `observeUnit` is not
    active
  - supported values:
    - `fail`: stop with an error
    - `run-action`: run the action without requiring the observed unit to be
      active
    - `start-change-unit`: start `changeUnit` first, then run the action
- `preActions.<name>.execOnFirstRun` /
  `postActions.<name>.execOnFirstRun`:
  - default is `false`
  - whether a brand-new action runs on its first apply pass

## Reload And Identity Behavior

For each user:

- one reconciler service runs `systemctl --user daemon-reload`
- all managed units for that user depend on it
- user-manager reload therefore happens once per switch, not once per bridged
  unit
- stable-state polling uses a bounded progressive backoff instead of a fixed
  tight loop, which reduces deploy-time churn while still surfacing real
  startup stalls
- all `system.activationScripts` entry points owned by this module are gated by
  `NIXOS_ACTION`
- synchronous reconcile from `system.activationScripts` only runs for
  activation actions like `switch` and `test`
- `dry-activate` runs a non-mutating preview through the same reconciler logic
  and logs the actions it would take without touching user units or stamp state
- boot activation skips all mutating `systemd-user-manager` activation-script
  work, including reconcile, prune, and user-manager identity refresh
- the reconciler instead runs as a normal `multi-user.target` unit after
  `user@<uid>.service` is up, so boot is not held behind user-unit actions like
  image pulls or user-manager restarts
- on successful reconcile, the module starts a user target,
  `systemd-user-manager-ready.target`
- boot-gated consumers can bind their user services to that target instead of
  `default.target` so those units do not start until the reconciler has run
  once in the current user-manager lifetime

The module also includes an activation script that hashes each bridged user’s:

- user definition
- primary group
- extra groups that exist in `users.groups`

If that identity hash changes and `user@<uid>.service` is active, the module
restarts the user manager so lingering user services see new groups in the same
deploy.

## What Changes Trigger

- unit `restartTriggers` change:
  - unit reconciliation runs on deploy
  - if the observed unit was active, the configured change action is replayed
  - if the observed unit is inactive after reconciliation, the bridge treats
    that as drift and starts `changeUnit` unless the unit file is disabled or
    masked
- pre-action or post-action `restartTriggers` change:
  - the reconciler evaluates only the affected action
  - `observeUnitInactiveAction = "run-action"` allows the action to execute
    without an active observed unit
  - `observeUnitInactiveAction = "start-change-unit"` may start `changeUnit`
    first
- modules may override stamp hashing with `stampPayload` so semantic triggers
  stay stable even when generated helper script paths change
- observed unit inactive before switch:
  - changed managed unit does not wake it up unless
    `startOnFirstRun` applies to a brand-new unit or an action explicitly uses
    `observeUnitInactiveAction = "start-change-unit"`
- user identity hash change:
  - activation script restarts `user@<uid>.service`
  - user services then run under the refreshed user manager view of groups

## Podman Usage Pattern

`lib/podman.nix` uses the module in two layers:

- the main compose service unit:
  - defaults to restart semantics
  - is boot-gated behind `systemd-user-manager-ready.target` instead of
    `default.target`
  - changed active stacks restart
  - inactive stacks are started during reconcile unless disabled or masked
- pre-actions such as `imageTag` and `recreateTag`

That keeps Podman lifecycle behavior attached to the main service lifecycle
instead of separate persistent action units. `imageTag` is modeled as a
transient pre-action that pulls images, `recreateTag` is modeled as a transient
pre-action that arms the next managed start/restart to use
`podman compose up --force-recreate`, and `bootTag` remains folded into the
main managed-unit restart trigger.

## FAQ

### Why not manage user units directly from `systemd.user.services` alone?

Because deploy-time switching happens from the system side. The module
lets system services coordinate lingering user managers and preserve
old-generation active state.

### What does “old-stop/new-start” mean here?

It means the reconciler remembers the previous generation’s managed-unit stamp,
then decides what the new generation should do based on the observed user-unit
state.

### Why do inactive units stay inactive on deploy?

They do not. The reconciler treats an inactive but startable managed unit as
drift and starts `changeUnit` unless the unit file is disabled or masked.

### Why is there a separate reload service per user?

So `systemctl --user daemon-reload` runs once per user manager even if multiple
managed units changed in the same deploy.

### Can a failed user-manager action block boot?

Not through this module anymore. On boot, all of its activation-script entry
points skip mutating work, including reconcile, prune, and identity-refresh
restarts. Boot instead lets the reconciler run later as a normal boot unit
after the user manager is up. Deploy-time `switch` and `test` still wait
synchronously and fail the activation if reconciliation fails.

### What happens on `dry-activate`?

The module does not run the real reconciler service. Instead it invokes the
same generated apply logic in preview mode and logs the actions it would take:
pre-actions, managed-unit start/restart/reload decisions, post-actions, and
starting `systemd-user-manager-ready.target`. Preview mode does not mutate
user-unit state, reload the user manager, prune managed state, restart the user
manager for identity changes, or write new persisted stamps.

### How do managed user services avoid racing the reconciler at boot?

Consumers can install their user services under
`systemd-user-manager-ready.target` instead of `default.target`. The reconciler
starts that target only after a successful apply, so those services do not
start before reconcile has run once.

### Does that create a deadlock?

No. The ready target only gates automatic boot pull-in. The reconciler still
starts or restarts managed user units directly with `systemctl --user`, so it
does not need those units to be pulled in by the ready target before it can
finish and start that target.

### Why restart `user@<uid>.service` when groups change?

Because lingering user managers otherwise keep the old supplementary group view,
which can break rootless services that depend on newly assigned groups.

## Related Docs

- `docs/podman-compose.md`: Primary consumer of the module.
- `docs/services.md`: Native service pattern (non-user-managed workloads).
- `docs/deployment.md`: Deploy architecture and sequencing.

## Source Of Truth Files

- `lib/systemd-user-manager.nix`
- `lib/podman.nix`
