# pvl WM Wayland Env Policy 2026-04

## Context

- Shared Sway and Niri config had session-wide environment overrides that pushed
  many toolkit families toward Wayland: `ELECTRON_OZONE_PLATFORM_HINT`,
  `NIXOS_OZONE_WL`, `MOZ_ENABLE_WAYLAND`, `QT_QPA_PLATFORM`, `SDL_VIDEODRIVER`,
  `CLUTTER_BACKEND`, `GDK_BACKEND`, and `WINIT_UNIX_BACKEND`.
- Those exports were originally added to improve backend selection consistency
  and reduce accidental XWayland fallback, especially in Sway.
- A live Noctalia investigation on `pvl-a1` showed at least one concrete
  downside: `QT_QPA_PLATFORM=wayland;xcb` changed quickshell IPC instance
  matching enough that `noctalia-shell ipc ...` failed unless the command
  overrode Qt to `wayland`.

## Decision

- Remove the session-wide Wayland-preference exports from shared Sway and Niri
  config.
- Let modern applications choose their own default backend behavior unless a
  specific app proves otherwise.
- Keep app-specific wrappers/overrides as the durable escape hatch when one app
  still needs coercion, matching the existing repo pattern used for tools like
  VS Code and now Noctalia IPC.

## Consequences

- Some applications may choose XWayland or non-Wayland backends again,
  especially under Sway.
- If a specific app regresses, fix that app locally instead of restoring a
  session-wide blanket policy.
