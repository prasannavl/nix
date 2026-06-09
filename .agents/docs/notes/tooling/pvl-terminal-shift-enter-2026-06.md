# pvl Terminal Shift Enter 2026-06

Codex inside tmux needs modified Enter keys to arrive as distinct input events.
The tmux side is configured in `users/pvl/tmux/default.nix`:

- `xterm-keys on`
- `extended-keys always`
- `extended-keys-format csi-u`
- `terminal-features` `extkeys` entries for common terminals

`showkey -a` inside the affected tmux pane still showed `Shift+Enter` arriving
as plain carriage return:

```text
^M       13 0015 0x0d
```

That means the key was collapsed before Codex could see it. Alacritty has an
explicit Home Manager binding in `users/pvl/alacritty/default.nix`:

```toml
[[keyboard.bindings]]
key = "Return"
mods = "Shift"
chars = "\u001b[13;2u"
```

Alacritty also starts tmux by default with `tmux new-session -A -s main`. Do not
set Alacritty's outer `TERM` to `tmux-256color`; tmux owns `TERM` only for
processes it starts inside panes.

Foot distinguished `Shift+Enter`, but emitted xterm modifyOtherKeys format:

```text
^[[27;2;13~
```

Codex's tmux path expects CSI-u instead, so `users/pvl/foot/default.nix` maps
`Shift+Return` through foot's `[text-bindings]`:

```ini
[text-bindings]
\x1b[13;2u=Shift+Return
```

Foot's default font is `monospace:size=8`, which appeared smaller than the rest
of the desktop terminals on the `pvl-a1` scaled display. The repo config sets
`font=Adwaita Mono:size=11` to match GNOME's live monospace setting
(`Adwaita Mono 11`).

VS Code integrated terminal also collapsed `Shift+Enter` to plain carriage
return. `users/pvl/vscode/default.nix` binds `shift+enter` with
`workbench.action.terminal.sendSequence` under `terminalFocus`, sending the same
CSI-u sequence.

Ghostty's "Open Configuration" menu calls `xdg-open ~/.config/ghostty/config`.
On `pvl-a1`, `text/plain` was associated with `nvim.desktop`; `xdg-open` from
Ghostty spawned detached Neovim processes that were not visible as a terminal
window. `users/pvl/mime-apps/default.nix` mirrors the live MIME defaults and
sets the `text/plain` MIME default to `org.gnome.TextEditor.desktop` so GUI open
actions have a visible editor.

The expected probe output after activation and a new terminal window is:

```text
^[   27 0033 0x1b
[    91 0133 0x5b
1    49 0061 0x31
3    51 0063 0x33
;    59 0073 0x3b
2    50 0062 0x32
u   117 0165 0x75
```
