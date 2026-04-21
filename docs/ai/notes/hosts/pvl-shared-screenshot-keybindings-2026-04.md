# Shared Screenshot Keybindings

## Context

- `users/pvl/sway/config.nix` and `users/pvl/niri/config.nix` had diverged
  screenshot shortcuts.
- First alignment attempt used `Super+C` everywhere, but Niri needed to keep
  its default centering actions on `Mod+C` / `Mod+Ctrl+C`.

## Decisions

- Standardize Sway and Niri on the same screenshot layout:
  - `Print`: interactive selection, saved to disk.
  - `Shift+Print`: focused monitor, saved to disk.
  - `Alt+Print`: focused window, saved to disk.
  - `Ctrl+<above>`: same target, clipboard only.
- Reuse same layout behind `Super+X` in Sway and Niri so laptops without
  convenient `Print` key still have common tiling-WM shortcut set.
- Keep GNOME on its existing `Super+C` screenshot family.
- Free `Super+X` where needed by moving:
  - Sway launcher alias off `Mod+X`, keeping `Mod+D` and `Mod+Space` as the
    launcher shortcuts.
- Keep `Mod+Shift+C` for Niri clear-dynamic-cast-target because the screenshot
  family now uses `Mod+Shift+X` instead.
- Keep Niri default centering actions on `Mod+C` and `Mod+Ctrl+C`.
