# pvl WM Session Services

## Context

- `users/pvl/wm/` owns shared tiling-WM session packages and Home Manager user
  services for the `pvl` desktop profile (Sway and Niri).
- Sway and Niri remain separate WM modules for compositor packages, portals, and
  config, but shared session daemons should not be duplicated there.

## Decisions

- The common service set is `lxqt-policykit`, repo-owned `kanshi.service`,
  `noctalia-shell`, and `swaybg`.
- Shared Wayland desktop packages live in the common module when both Sway and
  Niri use the same tool, including terminal, launcher, lock, clipboard, XDG,
  audio, and backlight basics.
- The shared services are installed for both `niri.service` and
  `sway-session.target`, because the active WM is expected to be either Niri or
  Sway.
- The common wallpaper service uses `swaybg` with `data/backgrounds/sw.png`.
  Niri should not start `swaybg` from `spawn-at-startup`, and Sway should not
  use compositor-native `output bg` for this wallpaper.
- Shared Wayland services are owned only by the shared Wayland session units,
  not by Sway startup commands. Sway reloads should not restart these daemons.
- Kanshi owns output profile switching. Global output defaults keep monitor
  identity settings reusable, while profiles describe laptop-only, LG, and
  LG-plus-extra-output topologies.
- Sway now sets `defaultWorkspace = "workspace number 1"` explicitly so a
  laptop-only start lands on workspace 1 even if some later runtime client or
  session component creates or focuses workspace 10.

## Investigation Notes

- The generated Sway config does not contain a startup command, assignment, or
  workspace mapping that selects workspace 10 at startup.
- The remaining workspace-10 references are only the standard `Mod4+0` and
  `Mod4+Shift+0` keybindings.
- That means the workspace-10 start behavior is not explained by Home Manager
  config ordering; it is more likely caused by a runtime client or session
  component outside the static Sway config.
