# pvl-l5 Noctalia Sway Dock Window Filtering

## Finding

On 2026-07-10, `pvl-l5` was running Sway with Noctalia Shell active:

```console
$ echo "$XDG_CURRENT_DESKTOP $WAYLAND_DISPLAY $SWAYSOCK"
sway wayland-1 /run/user/1000/sway-ipc.1000.6707.sock
```

The live dock settings were enabled and included the expected pinned apps:

```console
$ jq '.dock' ~/.config/noctalia/settings.json
{
  "enabled": true,
  "pinnedApps": ["Alacritty", "org.gnome.Nautilus", "google-chrome", "code", "..."],
  "pinnedStatic": true,
  "position": "top"
}
```

Sway itself saw the missing apps. For example, `swaymsg -t get_tree --raw`
reported four Chrome windows with `app_id = "google-chrome"`.

Noctalia also selected its Sway backend:

```text
SwayService Service started
I3 event socket disconnected.
```

The dock disappearance was not caused by a disabled dock, missing Chrome desktop
entry, or the older generation mismatch from June 2026.

## Root Cause

Noctalia v4's dock builds entries directly from Quickshell's
`ToplevelManager.toplevels`, then filters them by screen when
`Settings.data.dock.onlySameOutput` is true. The upstream default for
`dock.onlySameOutput` is true.

In the live Sway session, Quickshell eventually received all eight toplevels,
but only the focused Code window had a populated `screens` list:

```text
TOPLEVEL_COUNT 2 8
TOPLEVEL 0 obsidian ... false
TOPLEVEL 1 google-chrome Netflix - Google Chrome false
TOPLEVEL 2 google-chrome ... false
TOPLEVEL 3 google-chrome ... false
TOPLEVEL 4 google-chrome ... false
TOPLEVEL 5 Alacritty Alacritty false
TOPLEVEL 6 code opencode - z - Visual Studio Code false
TOPLEVEL 7 code bash - nix - Visual Studio Code true eDP-1
```

`Modules/Dock/Dock.qml` filters running toplevels with:

```qml
if (Settings.data.dock.onlySameOutput && toplevel.screens &&
    !toplevel.screens.includes(modelData)) {
  return;
}
```

Because the non-focused Sway toplevels had an empty `screens` list, they were
treated as not being on `eDP-1`. Pinned apps that were running, such as
`google-chrome`, were not added as inactive pinned entries either, because
Noctalia had already found matching running toplevels before filtering them out.

## Resolution

The repo-side dock settings now set
`programs.noctalia-shell.settings.dock.onlySameOutput = false` in
`users/pvl/noctalia/default.nix`. This avoids treating Sway toplevels with an
empty `screens` list as absent from the current output.

## Operational Notes

Validation commands:

```console
swaymsg -t get_tree --raw | jq -r '.. | objects | select((.type=="con" or .type=="floating_con") and (.app_id or .window_properties.class)) | [(.app_id // .window_properties.class), .name] | @tsv'
jq '.dock' ~/.config/noctalia/settings.json
journalctl --user -u noctalia-shell.service --since today --no-pager | rg -i 'SwayService|I3|dock|toplevel'
```

If this needs a narrower future fix, patch the dock logic so an empty
`toplevel.screens` list means "unknown output" rather than "not on this output".
