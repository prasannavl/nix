# Obsidian blank window on Electron 43

## Symptom

Obsidian (unstable package, 1.14.5 store asar) opened a fully black window.
Window existed in niri with title `Obsidian`, no vault, no error dialog. Started
after a nixpkgs bump moved the default `electron` from 41.x to 43.8.3.

## Diagnosis

Reproduced headless in the live session environment:

```bash
env -i HOME=$HOME XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 \
  ELECTRON_ENABLE_LOGGING=1 obsidian --enable-logging=stderr
```

stderr showed main-process unhandled rejections and nothing else:

```text
UnhandledPromiseRejectionWarning: TypeError: Cannot read properties of
undefined (reading 'defineProperty')
UnhandledPromiseRejectionWarning: TypeError: i.webFrame[t] is not a function
```

`--ozone-platform=wayland` was not the problem: the same failure appears with
the wrapper's wayland flags. Screenshot via `grim` confirmed black client area.

## Result of the version matrix

Same store asar, same user data, only the Electron binary changed:

| Electron                  | Result                                      |
| ------------------------- | ------------------------------------------- |
| 43.8.3 (unstable default) | blank window, `webFrame[...]` rejections    |
| 41.9.1                    | renders (1.14.5 and downloaded 1.15.0 asar) |
| 45.2.1                    | renders, only a deprecation warning         |

Electron 39–42 are marked EOL/insecure in current nixpkgs, so 45 is the pin.

## Fix

`overlays/unstable.nix` pins the runtime instead of inheriting the default:

```nix
obsidian = unstable.obsidian.override { electron = unstable.electron_45; };
```

Verified: `pkgs.obsidian` wrapper now execs `electron-45.2.1`, launches the
auto-updated `~/.config/obsidian/obsidian-1.15.0.asar` and shows the vault.

## Notes

- Obsidian keeps its own updater: `app.asar` (store) is a loader that prefers
  `~/.config/obsidian/obsidian-<version>.asar`. The Electron pin therefore has
  to satisfy both the store asar and auto-downloaded ones.
- Re-test with the default Electron after an Electron bump; drop the pin once
  43+ works again.
- Unrelated: nixpkgs patches `app.asar` (`corsEnabled: true`) for the internal
  PDF viewer. That patch does not apply to auto-downloaded asars.
