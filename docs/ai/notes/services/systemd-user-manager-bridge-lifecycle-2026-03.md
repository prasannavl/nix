# systemd-user-manager Bridge Lifecycle (2026-03)

## Scope

Canonical summary of `lib/systemd-user-manager.nix`, including the bridge model,
reload orchestration, and deploy-time change semantics used by `lib/podman.nix`
and other user-service modules.

## Module model

- `services.systemdUserManager.bridges.<name>` declares a system-managed bridge
  for a user unit.
- Each bridge targets a `users.users.<name>` entry with a non-null `uid`.
- Bridge services run as root and call `systemctl --user --machine=<user>@ ...`
  so deploy-time orchestration can manage lingering user managers from the
  system side.
- One reload service is generated per user manager, not per bridged unit.

## Bridge options

- `user`: owning account for the user manager.
- `unit`: user unit to manage.
- `observeUnit`: optional user unit whose `ActiveState` decides whether a
  changed bridge should take action. Defaults to `unit`.
- `changeUnit`: optional user unit to operate on when the bridge changes.
  Defaults to `unit`.
- `onChangeAction`: action for previously active changed bridges. Supported
  values: `restart`, `reload`, `start`.
- `startOnInitial`: whether the bridge should start its target on first
  activation when there is no old-generation stop record.
- `stopUnitOnStop`: whether bridge stop should stop the managed user unit.
- `restartTriggers`: values baked into the bridge unit so generation changes
  cause old-stop/new-start switch behavior.
- `serviceName`: name of the generated system service implementing the bridge.

## Switch behavior

- Bridge services are `Type=oneshot` with `RemainAfterExit=true`.
- On old-generation stop:
  - the bridge queries `observeUnit`
  - active, failed, and transitional states are treated as restart-worthy
  - a stamp file under `/run/nixos/systemd-user-manager/` records whether the
    new generation should perform its change action
- On new-generation start:
  - if the prior bridge recorded an active state, the new bridge runs
    `onChangeAction` against `changeUnit`
  - if there is no prior stop record, the bridge optionally starts `unit`
    depending on `startOnInitial`
  - intentionally inactive units remain inactive across rebuilds

This gives deploy-time old-stop/new-start semantics without forcing every
bridged user unit to restart on every boot.

## Reload orchestration

- A per-user reload service runs `systemctl --user daemon-reload`.
- Bridge units require and start after that reload service.
- All bridges for the same user share the same reload unit, so user-manager
  reload happens once per switch even when many user units changed.

## User identity refresh

- `system.activationScripts.systemdUserManagerIdentity` computes a hash of each
  bridged user's account definition plus referenced primary/extra groups.
- When that hash changes and `user@<uid>.service` is already active, the module
  restarts the user manager.
- This is the mechanism that lets new group memberships become visible to
  lingering rootless services during the same deploy.

## Podman usage pattern

`lib/podman.nix` uses the bridge module in two ways:

- main compose units use the default bridge behavior so changed active stacks
  restart and changed inactive stacks stay inactive
- lifecycle tag actions (`bootTag`, `recreateTag`, `imageTag`) are modeled as
  separate user oneshot services with bridges configured as:
  - `observeUnit = "<main>.service"`
  - `onChangeAction = "start"`
  - `startOnInitial = false`
  - `stopUnitOnStop = false`

That keeps Podman lifecycle tags stateless: actions fire only when tag values
change across generations for already active stacks, not on normal boot.
