# Home Manager And Systemd User Manager Ordering 2026-04

## Context

- On `pvl-x2`, a deploy at `2026-04-23 18:20 +08` failed in
  `home-manager-pvl.service` during `dconfSettings` with:
  `Could not activate remote peer 'ca.desrt.dconf': activation request failed: unit is invalid`.
- The failure happened while `systemd-user-manager-dispatcher-pvl.service` was
  restarting `user@1000.service`.
- The old user manager stopped `dconf.service` and the rest of the user bus
  graph just before Home Manager tried to write dconf settings.

## Findings

- `home-manager-pvl.service` and `systemd-user-manager-dispatcher-pvl.service`
  were both plain `multi-user.target` units with no ordering between them.
- The dispatcher restarted `user@1000.service` because
  `services.systemdUserManager` thought the `pvl` identity changed.
- That identity change was a false positive: both generations referenced the
  same `users-groups.json`, so the effective system user/group database did not
  change.
- The false positive came from hashing the full `config.users.users.<name>` and
  `config.users.groups.<group>` attrsets. That is too broad because unrelated
  option changes or group metadata changes can alter the hash without changing
  the credentials used by the lingering user manager.

## Decision

- Narrow the `systemd-user-manager` identity stamp to actual credential inputs:
  user uid, primary group name, supplementary group names, and the gids for the
  referenced groups.
- Add ordering so `home-manager-<user>.service` waits for
  `systemd-user-manager-dispatcher-<user>.service` when that user is managed by
  this bridge.

## Consequences

- Unrelated changes in shared group metadata no longer restart lingering user
  managers.
- A real `user@<uid>.service` restart now settles before Home Manager runs
  `dconfSettings`, reducing deploy-time races with the user D-Bus.
