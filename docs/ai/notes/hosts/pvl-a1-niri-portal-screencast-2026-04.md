# pvl-a1 Niri Portal Screencast 2026-04

## Symptom

- In Niri, Chrome/Google Meet screen sharing opened no visible monitor/window
  selection UI after the Sway portal work that pulled portal packages from git
  and added a custom WLR chooser.

## Findings

- Live Niri session environment was correct:
  `XDG_CURRENT_DESKTOP=niri`, `XDG_SESSION_DESKTOP=niri`,
  `DESKTOP_SESSION=niri`, and `WAYLAND_DISPLAY=wayland-1`.
- Niri itself could enumerate live outputs and windows with `niri msg --json`,
  so the compositor target state was not the failure.
- The live portal core was
  `/nix/store/...-xdg-desktop-portal-git/libexec/xdg-desktop-portal`, while the
  GNOME backend was the packaged `xdg-desktop-portal-gnome-49.0`.
- The Niri portal config correctly selected GNOME for `ScreenCast`,
  `RemoteDesktop`, and `Screenshot`:
  `/etc/xdg/xdg-desktop-portal/niri-portals.conf`.
- During the failed Chrome/Meet attempt, the journal showed GNOME portal
  activation followed by:
  `Failed to open service channel Wayland connection ... Invalid service client
  type`.

## Decision

- Do not globally replace `pkgs.xdg-desktop-portal` with upstream git `main`.
  That makes every desktop, including Niri, use a moving portal core with
  packaged backends.
- Keep the git portal core available only as the explicit
  `pkgs.xdg-desktop-portal-git` package for debugging or targeted experiments.
- Keep Niri on `xdg-desktop-portal-gnome` for screencasting. Niri upstream
  documents GNOME portal as the required portal backend for monitor/window
  screencasting, so switching Niri to the WLR chooser is not the durable fix.
