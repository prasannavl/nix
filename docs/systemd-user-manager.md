# Systemd User Manager Bridges

This document describes the shared `systemd-user-manager` bridge module and how
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

The bridge module solves this by creating system-side services that:

- Observe whether a user unit was active before the switch.
- Record that state so the new generation can decide what to do.
- Replay the appropriate action (restart, reload, or start) against the correct
  user unit after the switch.
- Coordinate a single `daemon-reload` per user manager even when multiple
  bridged units change in the same deploy.
- Restart the user manager itself when group membership changes, so rootless
  services immediately see new supplementary groups.

This gives user services the same deploy-time lifecycle awareness that system
services get natively, without requiring the workloads themselves to know
anything about NixOS generations.

## Current Model

- Shared bridge logic lives in `lib/systemd-user-manager.nix`.
- Bridge units are system services that control user units through
  `systemctl --user --machine=<user>@ ...`.
- The main current consumer is `lib/podman.nix`, but the bridge module is
  generic and can be reused by other user-service modules.

## What Is Reusable

- per-user user-manager reload orchestration
- deploy-time old-stop/new-start behavior for user units
- user-manager restart on account or group changes
- bridge configuration for observe-versus-change unit separation

## Shared Bridge Model

Modules declare bridges under:

```nix
services.systemdUserManager.bridges.<name> = {
  user = "app";
  unit = "app.service";
  restartTriggers = ["<generation-specific-value>"];
};
```

More advanced bridges can also set:

- `observeUnit`
- `changeUnit`
- `onChangeAction`
- `startOnInitial`
- `stopUnitOnStop`

## Core Behavior

Each bridge is a systemd system service with old-stop/new-start semantics:

- on old-generation stop, it checks whether the observed user unit was active
- if that unit was active, it records a restart-worthy stamp under
  `/run/nixos/systemd-user-manager/`
- on new-generation start, it replays the requested action against the change
  unit

This gives deploy-time behavior that matches the previous active state instead
of blindly starting every user unit on every switch.

## Bridge Options

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
- `startOnInitial`:
  - default is `true`
  - whether a brand-new bridge starts its target on first activation
- `stopUnitOnStop`:
  - default is `true`
  - whether bridge stop stops the user unit
- `restartTriggers`:
  - values baked into the bridge service so generation changes trigger bridge
    stop/start behavior

## Reload And Identity Behavior

For each user:

- one reload service runs `systemctl --user daemon-reload`
- all bridges for that user depend on it
- user-manager reload therefore happens once per switch, not once per bridged
  unit

The module also includes an activation script that hashes each bridged user’s:

- user definition
- primary group
- extra groups that exist in `users.groups`

If that identity hash changes and `user@<uid>.service` is active, the module
restarts the user manager so lingering user services see new groups in the same
deploy.

## What Changes Trigger

- bridge `restartTriggers` change:
  - bridge stop/start runs on deploy
  - if the observed unit was active, the configured change action is replayed
- observed unit inactive before switch:
  - changed bridge does not wake it up unless `startOnInitial` applies to a
    brand-new bridge
- user identity hash change:
  - activation script restarts `user@<uid>.service`
  - user services then run under the refreshed user manager view of groups

## Podman Usage Pattern

`lib/podman.nix` uses the bridge module in two layers:

- the main compose service bridge:
  - defaults to restart semantics
  - changed active stacks restart
  - changed inactive stacks stay inactive
- lifecycle tag action bridges:
  - `observeUnit = "<main>.service"`
  - `changeUnit = "<tag-action>.service"`
  - `onChangeAction = "start"`
  - `startOnInitial = false`
  - `stopUnitOnStop = false`

That keeps Podman lifecycle tags as deploy-time actions only.

## FAQ

### Why not manage user units directly from `systemd.user.services` alone?

Because deploy-time switching happens from the system side. The bridge module
lets system services coordinate lingering user managers and preserve
old-generation active state.

### What does “old-stop/new-start” mean here?

It means the bridge remembers whether the previous generation’s user unit was
active, then decides what the new generation should do based on that state.

### Why do inactive units stay inactive on deploy?

Because the bridge records only restart-worthy prior states. If a unit was
intentionally inactive, the new generation does not start it just because the
definition changed.

### Why is there a separate reload service per user?

So `systemctl --user daemon-reload` runs once per user manager even if multiple
bridged units changed in the same deploy.

### Why restart `user@<uid>.service` when groups change?

Because lingering user managers otherwise keep the old supplementary group view,
which can break rootless services that depend on newly assigned groups.

## Related Docs

- `docs/podman-compose.md`: Primary consumer of the bridge module.
- `docs/services.md`: Native service pattern (non-bridge workloads).
- `docs/deployment.md`: Deploy architecture and sequencing.

## Source Of Truth Files

- `lib/systemd-user-manager.nix`
- `lib/podman.nix`
