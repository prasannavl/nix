# tmux yank on Wayland: `@override_copy_command 'xsel -i'`

## Symptom

On `pvl-a1` (niri + xwayland-satellite), selecting with the mouse inside tmux
did not reach the system clipboard: pasting in Wayland apps did nothing.

## Root cause

Three layers, all triggered by `users/pvl/tmux/default.nix` pinning tmux-yank to
X11 `xsel`:

1. `@override_copy_command 'xsel -i'` is checked first by tmux-yank's
   `clipboard_copy_command()`, so `@yank_selection`, `@yank_selection_mouse` and
   the `wl-copy` auto-detection were dead config. The resolved binding was
   `bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe "xsel -i"`.
2. `users/pvl/tmux/default.nix` also installed real `pkgs.xsel` into
   `home.packages`, which shadows the `wl-clipboard-x11` **shim** installed by
   `hosts/common/pvl.nix` (`/run/current-system/sw/bin/xsel`), because
   home-manager's path precedes the system path. Real `xsel -i` writes the X11
   **PRIMARY** selection (its default), which Ctrl+V in Wayland apps never sees.
3. `copy-pipe`/`run-shell` jobs run with the **tmux server** environment, not
   the pane's. tmux's default `update-environment` covers `DISPLAY` but not
   `WAYLAND_DISPLAY`, so a server that inherited a stale/absent display makes
   `xsel -i` fail silently (it forks to the background and logs to
   `~/.xsel.log`).

## What the removed comment referred to

The old comment said `# workaround tmux-yank bug on wl-copy` but named no
upstream issue. Verified against the pinned plugin (`tmux-yank` rev
`acfd36e4fcba99f8310a7dfb432111c242fe7392`, `unstable-2023-07-19`,
`share/tmux-plugins/yank/scripts/helpers.sh`):

- Line 151-152 is the only wl-copy handling and returns a bare `wl-copy`,
  ignoring the `mouse` argument and both `@yank_selection` and
  `@yank_selection_mouse`. The plugin's own `yank_selection_mouse_default` is
  `primary` (line 25), so that documented default is unreachable on Wayland and
  mouse drags land in CLIPBOARD. That matches the config wanting `primary` and
  matches the override as a way to reach PRIMARY through X11 `xsel`.
- The other plausible target is the "copy helper wedges tmux" bug class: the
  plugin's CHANGELOG for v2.3.0 records "`yank_line` and `yank_pane_pwd` fork to
  prevent xclip from hanging Tmux", still visible as `run-shell -b`
  (`yank.tmux:81-82`). `xsel` also detaches itself by default. The comment does
  not say which one, and nothing in the commit that added it (`b152dfdc`) does
  either.

Either way the workaround was wrong on Wayland: it pinned an X11 tool, ignored
`@yank_selection*` (the override short-circuits before they are read), and
needed a working `DISPLAY` in the tmux server environment. Plain `wl-copy`
reaches CLIPBOARD, which Ctrl+V reads; PRIMARY-on-drag needs an explicit bind.

## Repo rule

On Wayland hosts, ship `wl-clipboard` plus the `wl-clipboard-x11` shims
(`xsel`/`xclip` names that forward to `wl-copy`/`wl-paste`). Do **not** ship
real `pkgs.xsel`/`pkgs.xclip` on the session path: whichever PATH entry wins
silently changes selection semantics, and the two disagree (`xsel -i` = PRIMARY
for the real tool, CLIPBOARD via the shim). The only intentional real X11
clipboard tools in the tree are inside `pkgs/ext/agent-workspace-linux`, which
prefixes `xclip` into its own Xvfb/openbox sandbox PATH only.

tmux-yank's detection order is `pbcopy` -> `clip.exe` -> `wl-copy` -> `xsel` ->
`xclip`, so dropping the override selects `wl-copy` even if X11 tools exist.

## Change

`users/pvl/tmux/default.nix`: removed the `@override_copy_command` line, the two
inert `@yank_selection*` lines, and the stray `home.packages = [xsel]` block.
`@yank_action 'copy-pipe'` is kept as-is (stay in copy-mode after yanking).

## Evidence

- Before/after binding from the generated config, via
  `tmux list-keys -T copy-mode-vi`: `copy-pipe "xsel -i"` -> `copy-pipe wl-copy`
  for both `y` and `MouseDragEnd1Pane`.
- Clearing the override alone is sufficient: with real `xsel` still installed,
  tmux-yank already resolves to `wl-copy`.
- Shim translation, verified live (no Wayland session here):
  `printf hello | /run/current-system/sw/bin/xsel -i -n` fails inside `wl-copy`
  (`Failed to connect to a Wayland server`), confirming `xsel -i` becomes a
  plain `wl-copy` (CLIPBOARD), and `xsel -i --primary` becomes
  `wl-copy --primary`.
- `copy-pipe` environment: starting a server with `DISPLAY`/`WAYLAND_DISPLAY`
  set and then running `copy-pipe 'env > file'` shows the job sees the server
  environment, not the pane shell's.
- XWayland bridging is bidirectional for `CLIPBOARD` and `PRIMARY` in
  xwayland-satellite 0.8.2 (`src/xstate/selection.rs:734` claims X11 `PRIMARY`
  for a Wayland-owned selection; `src/server/selection.rs:274` publishes an X11
  selection owner as `zwp_primary_selection_source_v1`). Its
  `Primary selection unsupported.` path only triggers when the compositor lacks
  `zwp_primary_selection_device_manager_v1`; niri implements it.
- tmux 3.6a also emits OSC 52 on every copy (`set-clipboard` defaults to
  `external`; `window-copy.c` sets `set_clip` unless `-C` is passed), and
  alacritty 0.17 defaults `terminal.osc52 = OnlyCopy`, so the terminal clipboard
  path works alongside `wl-copy`.

## Optional follow-ups

- Mouse drag to PRIMARY (middle-click paste) instead of CLIPBOARD:
  `bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "wl-copy --primary"`,
  or `wl-copy --primary; wl-copy` to cover both selections.
- Add `WAYLAND_DISPLAY` to `update-environment` for hygiene; wl-clipboard 2.3
  already falls back to `wayland-0` with a note when it is unset.
