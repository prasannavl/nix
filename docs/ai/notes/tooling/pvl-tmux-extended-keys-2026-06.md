# pvl tmux Extended Keys 2026-06

`users/pvl/tmux/default.nix` enables tmux extended key passthrough so terminal
TUIs can distinguish modified Enter keys from plain Enter.

The immediate symptom was Codex inside tmux treating `Shift+Enter` like a
regular submit key instead of inserting a newline. The first live tmux state
showed `extended-keys off`; after enabling that, Codex still did not handle
`Shift+Enter` because tmux defaulted `extended-keys-format` to `xterm`.

Codex 0.135.0's TUI only requests tmux modifyOtherKeys mode when
`#{extended-keys-format}` reports `csi-u`; it avoids xterm-style modified-key
sequences because crossterm does not parse them consistently. The declarative
Home Manager tmux config now sets:

- `xterm-keys on`
- `extended-keys always`
- `extended-keys-format csi-u`
- `terminal-features` `extkeys` entries for `xterm*`, `alacritty*`, `kitty*`,
  and `wezterm*`

Restart tmux sessions after activation if existing sessions do not pick up the
new option state.
