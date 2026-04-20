# pvl-a1 Sway GDM Session

## Context

`pvl-a1` runs GDM and offers Sway as a system Wayland session. GDM launches the
system `programs.sway` wrapper from `/run/current-system/sw`, not the Home
Manager wrapper from the user's profile.

Manual `sway` launches from an already logged-in terminal can resolve to the
Home Manager wrapper first via `PATH`, so user-profile-only launch flags may
appear to work manually while failing from GDM.

## Decision

The NixOS `lib/wm.nix` module owns Sway launch requirements used by display
managers before the compositor starts:

- `--unsupported-gpu`
- host-specific wlroots DRM device selection
- desktop identity variables
- GCR `SSH_AUTH_SOCK`

The Home Manager Sway module owns the user-facing Sway config: keybindings,
inputs, startup commands, window rules, bars, and portal preferences. It uses
`osConfig.programs.sway.package` as its `package` so manual user launches, Home
Manager config validation, and GDM all use the same NixOS-built Sway wrapper.

Do not put GDM-launch environment in Home Manager `extraSessionCommands` unless
Home Manager also owns the wrapper launched by GDM. In this setup, the NixOS
wrapper is authoritative.

Home Manager's standard Sway systemd/DBus activation hook imports `--all`,
matching Niri's broad `niri-session` import model. Values that must exist in the
Sway process environment before that import are exported by the NixOS wrapper.

Set `wayland.windowManager.sway.package = osConfig.programs.sway.package` in
Home Manager so the user profile and system profile expose the same wrapper
rather than independently wrapped Sway binaries.

Do not move compositor launch-critical flags or GPU environment back into the
Home Manager Sway wrapper unless GDM is also changed to launch that wrapper
explicitly.

When replacing `pkgs.sway` with a git build, keep the wrapped `sway` package
shape intact. Overriding `pkgs.sway` with `sway-unwrapped` breaks the wrapper
contract expected by both the NixOS and Home Manager Sway modules, so
`programs.sway.extraOptions` such as `--unsupported-gpu` stop applying and the
GPU nag reappears. The correct pattern is to build `sway-unwrapped` from git and
then feed that into nixpkgs' wrapped `sway/package.nix`.
