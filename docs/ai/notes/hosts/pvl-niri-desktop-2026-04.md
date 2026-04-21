# pvl Niri Desktop

## Context

- `users/pvl/niri/` mirrors the Sway user module shape with separate NixOS
  package wiring and Home Manager config.
- Niri is enabled system-wide through `lib/wm.nix`; the user module supplies
  per-user packages, portals, services, and config under `~/.config/niri/`.

## Decisions

- Niri-specific user services use `Install.WantedBy = ["niri.service"]` so they
  are pulled into the systemd-backed Niri session.
- Ported Sway-adjacent session services are LXQt PolicyKit, Shikane, and
  Noctalia Shell.
- Keybindings intentionally follow Niri defaults for almost everything. Personal
  differences are isolated at the bottom of the `binds` block under a
  `// Custom keybinds` comment.
- Navigation-style keybindings flip the Niri default `Ctrl`/`Shift` convention
  in generated `base-config.kdl`: `Shift` activates movement of the focused
  column/window/workspace, while `Ctrl` is used mostly for monitor-oriented
  focus or alternate navigation.
- Whole-workspace monitor movement is an overlay addition on
  `Mod+Ctrl+Alt+H/J/K/L` and matching arrows, keeping `Mod+Ctrl+Shift` for
  column-to-monitor movement.
- Dynamic screencast target actions are bound as a separate default-style group:
  focused window, focused monitor, and clear target.
- `users/pvl/niri/keys.md` is a human-facing grouped key map for the effective
  default-plus-Nix bind set, with HJKL and arrow equivalents grouped together.
- The Home Manager config keeps the full packaged Niri default config in
  `default-config.kdl`, generates `base-config.kdl` from that default with only
  the default `waybar` autostart disabled, and makes `config.kdl` include the
  base plus a small Nix-managed overlay. The overlay includes generated
  `output-defaults.kdl` for shared startup output mode/scale/transform/VRR
  defaults and `corner-rules.kdl` for per-app geometry radius rules.
- Niri startup output defaults come from the shared `users/pvl/wm/outputs.nix`
  data, matching the Sway pre-kanshi output-default behavior. Kanshi still owns
  dynamic topology and output positioning; Niri only gets the early compositor
  defaults so the session and early clients start with the intended scale and
  mode before profile application.
- Niri include merging is not universal. Use the overlay include only for
  merge-safe additions and key overrides; use explicit Nix-side base patches for
  non-merging sections such as full pointing-device blocks, struts, multipart
  sections, or removal of default startup commands.
- `config.kdl` itself is unmanaged local state. Home Manager activation creates
  a seed file only when it is absent; that seed includes `base-config.kdl` and
  `nix-config.kdl`, and `nix-config.kdl` includes `corner-rules.kdl`. Users can
  comment either seed include or add local overrides without Nix overwriting
  them.
- Niri cursor setup lives in `config.kdl` through the `cursor` block to avoid
  broad Home Manager cursor side effects on GNOME/Xwayland scaling.
- Niri enables `services.gnome.gnome-keyring` and `services.gnome.gcr-ssh-agent`
  directly, with competing SSH agents disabled, so the module still has the
  intended keyring and SSH-agent behavior when used without the full GNOME
  module. Niri does not set `SSH_AUTH_SOCK` manually because it runs as a
  systemd-backed session.
- Niri portal preference is `gnome;gtk`, matching the NixOS Niri module's
  upstream portal recommendation while keeping GTK fallback.
- Niri forces the PipeWire invalid modifier for screencasts because GNOME
  Network Displays failed under Niri with `no more input formats` while
  negotiating the GNOME portal monitor stream with explicit DMA-BUF modifiers.
- Fast logout/relogin failures from GDM are not caused by the Niri user-session
  targets. Upstream GDM launches non-self-registering Wayland sessions through
  `gdm-wayland-session --register-session`, but that helper delays
  `RegisterSession` by 10 seconds. If Niri exits before the timer fires, GDM
  logs `Session never registered, failing` and can leave the next `gdm-password`
  worker wedged. Keep the session-registration fix in GDM, not in Niri quit
  hooks or compositor-ready targets; the local override shortens the fallback
  timeout to 3 seconds instead of removing the delay entirely.
