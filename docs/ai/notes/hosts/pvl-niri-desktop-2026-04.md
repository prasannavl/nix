# pvl Niri Desktop

## Context

- `users/pvl/niri/` mirrors the Sway user module shape with separate NixOS
  package wiring and Home Manager config.
- Niri is enabled system-wide through `lib/sway.nix`; the user module supplies
  per-user packages, portals, services, and config under `~/.config/niri/`.

## Decisions

- Niri-specific user services use `Install.WantedBy = ["niri.service"]` so they
  are pulled into the systemd-backed Niri session.
- Ported Sway-adjacent session services are LXQt PolicyKit, Shikane, and
  Noctalia Shell.
- Keybindings intentionally follow Niri defaults for almost everything. Personal
  differences are isolated at the bottom of the `binds` block under a
  `// Custom keybinds` comment.
- Dynamic screencast target actions are bound as a separate default-style group:
  focused window, focused monitor, and clear target.
- `users/pvl/niri/keys.md` is a human-facing grouped key map for the effective
  default-plus-Nix bind set, with HJKL and arrow equivalents grouped together.
- The Home Manager config keeps the full packaged Niri default config in
  `default-config.kdl`, generates `base-config.kdl` from that default with only
  the default `waybar` autostart disabled, and makes `config.kdl` include the
  base plus a small Nix-managed overlay.
- Niri include merging is not universal. Use the overlay include only for
  merge-safe additions and key overrides; use explicit Nix-side base patches for
  non-merging sections such as full pointing-device blocks, struts, multipart
  sections, or removal of default startup commands.
- `config.kdl` itself is unmanaged local state. Home Manager activation creates
  a seed file only when it is absent; that seed includes `base-config.kdl` and
  `nix-config.kdl`. Users can comment either include or add local overrides
  without Nix overwriting them.
- Niri cursor setup lives in `config.kdl` through the `cursor` block to avoid
  broad Home Manager cursor side effects on GNOME/Xwayland scaling.
- Niri enables `services.gnome.gnome-keyring` and
  `services.gnome.gcr-ssh-agent` directly, with competing SSH agents disabled,
  so the module still has the intended keyring and SSH-agent behavior when used
  without the full GNOME module. Niri does not set `SSH_AUTH_SOCK` manually
  because it runs as a systemd-backed session.
- Niri portal preference is `gnome;gtk`, matching the NixOS Niri module's
  upstream portal recommendation while keeping GTK fallback.
