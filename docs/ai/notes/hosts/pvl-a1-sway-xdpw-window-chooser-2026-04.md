# `pvl-a1` Sway xdg-desktop-portal-wlr Window Chooser 2026-04

- Symptom: monitor sharing worked through `xdg-desktop-portal-wlr`, but window
  sharing in Chromium/Google Meet silently failed and the portal journal showed
  repeated `wlroots: no output found`.
- Confirmed package state: the host was already running current upstream builds
  of `sway`, `wlroots`, `xdg-desktop-portal`, and `xdg-desktop-portal-wlr`. The
  failure was not caused by stale portal packages.
- Confirmed service wiring: `xdg-desktop-portal-wlr.service` was launched with
  `--config=/nix/store/...-xdg-desktop-portal-wlr.ini`, so Home Manager files
  under `~/.config/xdg-desktop-portal-wlr/` were ignored. The effective chooser
  settings must therefore be configured through the NixOS
  `xdg.portal.wlr.settings` option.
- Durable root cause: the custom chooser script parsed
  `swaymsg -t get_outputs -r` with `grep -o '"name":"[^"]*"'`. Newer Sway JSON
  formatting includes spaces (`"name": "eDP-1"`), so the `grep` returned no
  matches. Because the script runs with `set -euo pipefail`, that failed grep
  aborted the whole chooser before it could enumerate windows, which made xdpw
  report `wlroots: no output found`.
- Regression discovered during the fix: monitor sharing also broke once the
  chooser started handling both outputs and windows in a single strict shell
  pipeline. Any non-zero exit from the window collector could abort the whole
  script even after valid monitor entries had already been produced.
- Additional script fixes:
  - The chooser cleanup trap must not reference a `local` temp-file variable
    from the `EXIT` handler. Use a shell-global temp-file binding or capture the
    expanded path when installing the trap.
  - The chooser wrapper must include every tool it invokes in `runtimeInputs`;
    in this case `gawk` and `jq` are required in addition to the menu frontend
    and `lswt`.
  - The output and window collectors must be isolated so an error in one does
    not discard valid results from the other; the current script uses a
    `collect_choices` wrapper with `collect_outputs || true` and
    `collect_windows || true`.
  - The cleanup handler now uses `${chooser_file:-}` so it is safe with
    `nounset` and still removes the temp file on exit.
- Later follow-up:
  - `xdg-desktop-portal-wlr` persists monitor selections but does not persist
    window selections out of the box. The final local workaround keeps the
    package unpatched and instead makes the chooser cache the most recent
    selection for the exact same offered choice set for a short window. That
    lets Chromium/Google Meet reuse the same window between preview and actual
    sharing without carrying a backend patch.
  - True arbitrary-region screencast is not implemented by the xdpw screencast
    backend. The `slurp` path in xdpw is only a visual monitor/output picker.
    The custom chooser can restore visual monitor picking with `slurp`, but not
    free-form region capture for screencasting.
- Working fix:
  - Configure `xdg.portal.wlr.settings.screencast.chooser_type = "simple"`.
  - Configure `chooser_cmd` to a `writeShellApplication` wrapper.
  - Parse outputs with `jq -r '.[].name // empty'` instead of grepping raw JSON.
  - Keep window enumeration based on `lswt --custom i/a/t`.
- Verification after the fix:
  - `nix build --no-link .#nixosConfigurations.pvl-a1.config.system.build.toplevel`
    succeeds.
  - From the live `xdg-desktop-portal-wlr` environment,
    `swaymsg -t get_outputs -r | jq -r '.[].name // empty'` returns `eDP-1`.
  - From the same environment, `lswt --custom i`, `a`, and `t` enumerate live
    windows.
  - An instrumented copy of the generated chooser returns `Monitor: eDP-1` for a
    forced first-item selection and `Window: <id>` for a forced second-item
    selection in the live portal environment.
