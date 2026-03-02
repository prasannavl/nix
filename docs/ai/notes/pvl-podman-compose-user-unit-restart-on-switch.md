# pvl Podman Compose user-unit switch bridge

## Context

- User reported that services generated via `lib/podman.nix` did not restart on
  `nixos-rebuild switch`/`test` when compose definitions changed.
- These services are emitted as `systemd --user` units via
  `systemd.user.services`.
- Requirement evolved to preserve NixOS-like old-stop/new-start behavior as
  closely as possible while keeping Podman units in `systemd --user`.

## Root cause

- `switch-to-configuration-ng` applies full changed-unit start/reload/restart
  logic to system units.
- For user managers, it only reloads user instances and restarts
  `nixos-activation.service`.
- It does not automatically restart changed `systemd.user.services` units.

## Change

- Added new reusable module: `lib/systemd-user-manager.nix`
  - Provides `services.systemdUserManager.bridges` for managing `systemd --user`
    units from system services.
  - Each bridge emits a `systemd.services.<serviceName>` oneshot with
    `RemainAfterExit = true`, `restartIfChanged = true`, `stopIfChanged = true`,
    and configurable `restartTriggers`.
  - Bridge stop path (old generation): checks active state and stops user unit
    via `systemctl --user --machine=<user>@ stop <unit>`, storing a marker if it
    was active.
  - Bridge start path (new generation): starts the user unit only when marker
    exists.
- Updated `lib/podman.nix`:
  - Imports `./systemd-user-manager.nix`.
  - Keeps per-service metadata (`systemdUser`, `restartStamp`).
  - Registers one bridge per generated podman user unit in
    `services.systemdUserManager.bridges`.
  - Removes prior activation-hook restart mechanism.

## Expected outcome

- During `nixos-rebuild switch` or `test`, changed podman services trigger
  system bridge unit restart.
- Bridge `ExecStop` runs under old generation and `ExecStart` under new
  generation, approximating NixOS system-unit old-stop/new-start semantics for
  user units.
- Only user units that were active at stop-time are started again.

## Follow-up

- Generic bridge default naming:
  - `systemd-user-manager-${name}`
- Podman bridge naming override:
  - `systemd-user-manger-podman-<name>`
