# systemd-user-manager Bridge Lifecycle (2026-03)

## Scope

Canonical summary of `lib/systemd-user-manager.nix`, including the per-user
reconciler model, reload orchestration, and deploy-time change semantics used
by `lib/podman.nix` and other user-service modules.

## Module model

- `services.systemdUserManager.instances.<name>` declares a managed user unit.
- Each bridge targets a `users.users.<name>` entry with a non-null `uid`.
- One serialized reconciler service is generated per user manager.
- The reconciler runs as root and calls
  `systemctl --user --machine=<user>@ ...` so deploy-time orchestration can
  manage lingering user managers from the system side.

## Bridge options

- `user`: owning account for the user manager.
- `unit`: user unit to manage.
- `observeUnit`: optional user unit whose `ActiveState` decides whether a
  changed bridge should take action. Defaults to `unit`.
- `changeUnit`: optional user unit to operate on when the bridge changes.
  Defaults to `unit`.
- `onChangeAction`: action for previously active changed bridges. Supported
  values: `restart`, `reload`, `start`.
- `startOnFirstRun`: whether the bridge should start its target on its
  first apply pass when there is no old-generation stop record.
- `stopOnRemoval`: whether removing the managed entry should stop the
  managed user unit.
- `restartTriggers`: values baked into the bridge unit so generation changes
  cause old-stop/new-start switch behavior.
- `preActions` / `postActions`: ordered transient actions attached to the
  managed entry.

## Switch behavior

- The per-user apply service is `Type=oneshot` with `RemainAfterExit=true`.
- On each deploy:
  - the reconciler waits for the user manager bus
  - runs one `daemon-reload`
  - loads persisted per-unit state from its `StateDirectory`
  - reconciles unit changes and ordered actions serially
  - writes the new state back atomically
- If the observed unit was previously active, the reconciler runs
  `onChangeAction` against `changeUnit`.
- If a unit is unchanged but drifted inactive, the reconciler starts it again
  unless the unit file is disabled or masked.
- Inactive but startable units are treated as drift and started during
  reconcile unless the unit file is disabled or masked.

## Reload orchestration

- The per-user reconciler runs `systemctl --user daemon-reload` once before it
  reconciles any managed entries for that user.

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
  restart and inactive-but-startable stacks are started during reconcile
- `imageTag` is modeled as a transient pre-action with
  `observeUnitInactiveAction = "run-action"`
- `recreateTag` is modeled as a transient pre-action with
  `observeUnitInactiveAction = "run-action"` that arms the next managed
  start/restart to use `podman compose up --force-recreate`
- `bootTag` remains folded into the main managed-unit restart trigger instead
  of a separate user unit

That keeps Podman lifecycle tags stateless: actions fire only on deploy-time
generation changes, not on normal boot.
