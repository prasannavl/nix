# pvl WM Session Services

## Context

- `users/pvl/wm/` owns shared tiling-WM session packages and Home Manager user
  services for the `pvl` desktop profile (Sway and Niri).
- Sway and Niri remain separate WM modules for compositor packages, portals, and
  config, but shared session daemons should not be duplicated there.
- `users/pvl/wm/services.nix` is the shared authority for WM session targets and
  the reusable `mkWmPreService` / `mkWmPostService` helpers used by
  WM-adjacent user modules.
- `users/pvl/kanshi/` owns the kanshi package, config, and user service because
  the topology profiles are host-specific even though output defaults are
  shared.

## Decisions

- The common WM service set is `lxqt-policykit`, `noctalia-shell`, and `swaybg`.
  `kanshi.service` is split into its own user module. A shared oneshot
  `portal-cleanup` service also stops stale XDG desktop portal units before
  every Sway or Niri session start so the new session can activate the correct
  backend on demand.
- Shared Wayland desktop packages live in the common module when both Sway and
  Niri use the same tool, including terminal, launcher, lock, clipboard, XDG,
  audio, and backlight basics.
- The shared services are installed for both `niri.service` and
  `sway-session.target`, because the active WM is expected to be either Niri or
  Sway. That target list plus the shared pre-session and post-session helper
  shapes live in `users/pvl/wm/services.nix`.
- The common wallpaper service uses `swaybg` with `data/backgrounds/sw.png`.
  Niri should not start `swaybg` from `spawn-at-startup`, and Sway should not
  use compositor-native `output bg` for this wallpaper.
- Shared Wayland services are owned only by the shared Wayland session units,
  not by Sway startup commands. Sway reloads should not restart these daemons.
- Kanshi owns output profile switching. Global output defaults stay shared in
  `users/pvl/wm/outputs.nix`, and the kanshi module always installs the shared
  kanshi config and service when included.
- `users/pvl/kanshi/default.nix` is only the orchestrator. Generated defaults
  live in `config-defaults.nix`, host-specific profiles live in `profiles.nix`,
  and any shared profile text should be embedded directly in the orchestrator.
- Host-specific kanshi profiles are selected by `osConfig.networking.hostName`,
  but hosts without a profile still get the shared output-default config and the
  kanshi user service.
- Only `pvl-a1` currently has host-specific kanshi profiles. Other hosts can add
  shared profiles in the orchestrator or add their own host entry in
  `users/pvl/kanshi/profiles.nix` without changing the shared WM module.
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
