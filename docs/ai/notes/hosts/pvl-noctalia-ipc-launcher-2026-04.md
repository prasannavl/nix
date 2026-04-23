# pvl Noctalia IPC Launcher 2026-04

## Context

- `users/pvl/niri/config.nix` and `users/pvl/sway/config.nix` bound launcher
  keys to `noctalia-shell ipc call launcher toggle` with `fuzzel` fallback.
- `noctalia-shell.service` was healthy and running, but manual IPC calls failed
  with `No running instances for ".../share/noctalia-shell/shell.qml"`, causing
  the fallback launcher to run instead.

## Findings

- Quickshell IPC filters candidate instances by display connection.
- The Noctalia instance was present and reachable with
  `noctalia-shell ipc --any-display show`, which proved the service and IPC
  targets were healthy.
- On the live `pvl-a1` Niri session, shell env and Noctalia service env matched
  on `WAYLAND_DISPLAY=wayland-1`, `DISPLAY=:0`, and session metadata, so the
  failure was not stale session variables.
- The deciding factor was Qt platform selection for the IPC client:
  `QT_QPA_PLATFORM=wayland noctalia-shell ipc show` succeeded, while plain
  `noctalia-shell ipc show` and
  `QT_QPA_PLATFORM='wayland;xcb' noctalia-shell ipc show` both failed with
  `No running instances for ".../shell.qml"`.
- That means the IPC client was not binding the active Wayland display unless
  the Wayland Qt platform plugin was forced explicitly.

## Decision

- Do not rely on `--any-display` as the durable fix, because it bypasses
  display scoping instead of fixing why the client failed to identify the active
  Wayland display.
- After the later removal of session-wide Wayland-preference environment
  overrides from the shared WM config, the Noctalia launcher keybindings no
  longer need their temporary `QT_QPA_PLATFORM=wayland` wrapper and can use
  plain `noctalia-shell ipc call launcher toggle` again.
