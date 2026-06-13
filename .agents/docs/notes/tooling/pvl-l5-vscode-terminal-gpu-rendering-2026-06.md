# pvl-l5 VS Code Terminal GPU Rendering 2026-06

## Finding

On `pvl-l5`, intermittent VS Code integrated-terminal glyph corruption is coming
from the accelerated Electron/WebGL rendering path, not from shell, tmux, or
terminal contents.

Live evidence on 2026-06-12:

- Host is `pvl-l5`, Lenovo Legion 5 15ACH6H, Niri Wayland session.
- VS Code is `1.124.0`, Electron `42.2.0`, launched with only the repo-owned
  `--password-store=gnome-libsecret` override.
- Code's GPU process runs on `/dev/dri/renderD128`, the AMD iGPU render node.
- `code --status` reports AMD/Mesa/ANGLE as active and repeated WebGL
  `GL_INVALID_OPERATION` texture allocation errors from the GPU process.

The terminal artifact is consistent with xterm.js/Electron losing or corrupting
parts of its accelerated glyph/texture atlas. It appears intermittent because it
depends on GPU process state, terminal renderer state, selection/repaint timing,
and whether the affected glyph texture path is hit.

## Related Host Mismatch

Before the hardware fix, the repo's Lenovo Legion module identified the AMD iGPU
as PCI `0000:05:00.0` / `PCI:5:0:0`, but the live machine reports it at
`0000:06:00.0` / `PCI:6:0:0`.

As a result, before the hardware fix, the declared udev aliases for the default
AMD GPU did not exist on the live machine:

- `/dev/dri/zrender-default` is missing.
- `/dev/dri/zcard-default` is missing.
- Niri logs `error opening "/dev/dri/zrender-default" as DRM node`.

This mismatch should be fixed independently because compositor and PRIME config
should match the live PCI topology. It is not sufficient by itself to explain
the VS Code terminal corruption, since Code is still using the AMD render node
directly, but it adds avoidable display-stack ambiguity.

`lib/devices/lenovo-legion-5-15ach6h.nix` now uses `PCI:6:0:0` and
`0000:06:00.0` for the AMD iGPU. NVIDIA remains `PCI:1:0:0` / `0000:01:00.0`.
Live `0000:05:00.0` is the SK hynix NVMe SSD, not a GPU.

After deploying and rebooting with the corrected PCI aliases, Niri successfully
used `/dev/dri/zrender-default` as `/dev/dri/renderD128`, but VS Code still
reported the same ANGLE/WebGL texture allocation errors. The durable workaround
is therefore terminal-scoped: `users/pvl/vscode/default.nix` sets
`terminal.integrated.gpuAcceleration = "off"` so xterm.js avoids the WebGL glyph
atlas path without disabling acceleration for the whole editor.

## Candidate Fixes

- Narrow VS Code terminal workaround: keep
  `terminal.integrated.gpuAcceleration = "off"` in the managed VS Code user
  settings. This avoids the WebGL terminal path without disabling all Electron
  acceleration.
- Broader app workaround: enable VS Code `disable-hardware-acceleration` in
  `~/.vscode/argv.json` or the package wrapper. This is heavier because it
  affects the whole editor.
- Host correctness fix: rebuild/relog with the corrected Legion 5 AMD PCI IDs so
  the `/dev/dri/z*-default` aliases exist before Niri starts.
