# pvl Noctalia Module

## Context

- `programs.noctalia-shell` was previously enabled inside `users/pvl/wm/`, and
  Sway plus Niri referenced the resulting package path for launcher IPC.
- The live Noctalia configuration had drifted into runtime state under
  `~/.config/noctalia/`, including `settings.json`, `colors.json`,
  `plugins.json`, custom colorschemes, and downloaded plugin payloads.

## Decisions

- `users/pvl/noctalia/` is the dedicated Home Manager module for Noctalia under
  the `pvl` user tree.
- The module expresses runtime config through Home Manager options instead of
  vendoring exported runtime JSON: use `programs.noctalia-shell.settings`,
  `programs.noctalia-shell.plugins`, and
  `programs.noctalia-shell.pluginSettings`.
- Large Noctalia subtrees should stay split into focused sibling files under
  `users/pvl/noctalia/` such as `colorscheme.nix`, `bar.nix`,
  `control-center.nix`, and `plugins.nix`, with `default.nix` acting as the
  orchestrator.
- Active custom colorscheme payloads can be embedded directly in the Nix module
  and written via `xdg.configFile.<path>.text = builtins.toJSON ...;`, so the
  repo does not need separate vendored JSON files when only one scheme is kept.
- `colors.json` is not stored in-repo. For predefined schemes like `Monochrome`,
  Noctalia regenerates derived colors at runtime from the HM `colorSchemes`
  settings.
- Downloaded plugin payloads are not vendored. Declare plugin sources/states in
  Home Manager and let Noctalia fetch upstream plugin code; keep only explicit
  per-plugin settings in `pluginSettings`.
- The Noctalia user service is owned by `users/pvl/noctalia/`, but it should use
  the shared `users/pvl/wm/services.nix` helpers and compositor-ready targets so
  Sway and Niri keep one WM session lifecycle model.
