# tmux plugin set -> fingers + inlined tmux 3.6

## Decision

11 plugins -> 2: `tmux-fingers` (replaces copycat, open, thumbs) + `resurrect`
(manual `C-s`/`C-r` snapshots). Rest inlined in `users/pvl/tmux/default.nix`;
`overlays/tmux-plugins.nix` down to 1 pin.

Why: 9/11 untouched upstream 3-9 years; nixpkgs master pins same revs (see
`tmux-plugin-upstream-pins-2026-10.md`); usage evidence: resurrect dir actively
written, no `~/tmux-*.log` ever, prefix-highlight inert (no status line
placeholder).

## Replacement map

| removed                 | inline                                                                                                                                                                                                                                                          |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| sensible                | `display-time 4000`, `status-interval 5`, `setw focus-events on`, `setw aggressive-resize on`, `C-n`/`C-p`, `R` reload. escape-time/history-limit no-ops on 3.6; its `b`->last-window (read default `C-b`, plugins load before our prefix) deliberately dropped |
| pain-control            | all: `h/j/k/l`+`C-h/j/k/l` nav, `H/J/K/L` resize 5, `<`/`>` swap-window, `% " \| \ - _` splits with `-c #{pane_current_path}`, `c` new-window in cwd                                                                                                            |
| better-mouse-mode       | wheel handlers: app (`mouse_any_flag`) > alt-screen arrows > copy-mode `-t=`; `-N3`; no exit at bottom                                                                                                                                                          |
| yank                    | stock drag/copy + `set-clipboard=external` => OSC52 => terminal clipboard; `y` = `copy-selection-and-cancel` (stock has no vi `y`), `Y` put, `!` = `wl-copy --trim-newline`, prefix `y`/`Y` = pane last line/cwd                                                |
| open                    | `o`->`xdg-open`, `C-o`->`$EDITOR` (fingers ctrl-action also opens URLs)                                                                                                                                                                                         |
| logging                 | `P` toggles `pipe-pane` via `#{pane_pipe}`; `M-p`/`M-P` screen/history; `M-c` clear; files under `~/tmp`                                                                                                                                                        |
| prefix-highlight        | `status-left` = `#{?client_prefix,...}`                                                                                                                                                                                                                         |
| copycat + thumbs + open | `tmux-fingers`, prefix `Space`, `@fingers-jump-key J`                                                                                                                                                                                                           |

Kept own bindings: `M-e` prefix, Alt+arrows pane nav.

## 3.6 gotchas

- unquoted `#{..}` starts a comment (`#`) => quote any arg with a format; broke
  `save-buffer ~/tmp/tmux-#{session_name}.txt`, now run-shell + redirect
- `#(cmd)` async => empty on first expansion; use `$(date ..)` in `pipe-pane`
- stock wheel: `copy-mode -e`, `-N5`, `select-pane`; inlines keep old feel
- `client_prefix`, `pane_pipe` exist; user opts readable as `#{@name}`
- OSC52 on copy is default (`external`), so no clipboard helper needed

## persistence

- resurrect only: keys `C-s` save / `C-r` restore; store `~/.tmux/resurrect`
  (267 saves, latest 20261004); pinned 2023 version prefers that legacy dir when
  present (`helpers.sh:1-5`), else `$XDG_DATA_HOME/tmux/resurrect`
- no autosave after dropping continuum: state captured only on `C-s` unless a
  systemd user timer runs `.../resurrect/scripts/save.sh quiet`
- restore replays saved program commands; pane-contents/vim restore are opt-in

## fingers

- attr `pkgs.tmuxPlugins.fingers`; 2.6.2 crystal build, wizard patched out;
  version must match `shard.yml`, so master pin = rebuild pkg (`shardsFile`),
  not `src` swap
- upstream alive (HEAD 2026-06-09; 2.7.1/2.7.0); nixpkgs at 2.6.2 = fine
- `@fingers-key Space`; system clipboard default on; log:
  `~/.local/state/tmux-fingers/`

## Validation

- `tmux -f <generated conf>` + `source-file`: no syntax errors; base-index 1,
  mouse on, history-limit 65536, display-time 4000, status-interval 5,
  aggressive-resize on, focus-events on, new status-left applied
- `list-keys`: inlines present incl. repeatable `-r H/J/K/L`/`<`/`>`, `M-Left..`
  arrows, `prefix Space -> tmux-fingers start #{pane_id}`, resurrect `C-s`/`C-r`
- `pipe-pane` (binding's exact cmd) wrote `~/tmp/tmux-<ts>.log` with pane
  output; `#{pane_pipe}` 0->1->0; `capture-pane -S -` wrote history file;
  `tmux-fingers version` = 2.6.2
