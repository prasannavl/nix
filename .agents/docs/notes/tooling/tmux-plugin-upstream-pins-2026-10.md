# tmux Plugin Upstream Pins

## Context

Reviewing the tmux-yank workaround in `users/pvl/tmux/default.nix` raised the
question of whether the pinned tmux plugins are stale. tmux-yank is not: its
nixpkgs pin (`unstable-2023-07-19`, `acfd36e4`) is upstream `master` HEAD. The
rest of the set was stale by years.

## Why nixpkgs cannot fix this

nixpkgs pins each tmux plugin to a specific commit and does not keep them
current. Checked 2026-10-05 against
`https://raw.githubusercontent.com/NixOS/nixpkgs/master/pkgs/misc/tmux-plugins/default.nix`:
every stale rev in the pinned `nixos-26.05` input is byte-identical on nixpkgs
`master`, and `nixos-unstable` carries the same revs too. Bumping any nixpkgs
input therefore cannot update these plugins.

## Mechanism

`overlays/tmux-plugins.nix` owns the upstream revisions, following the
`overlays/sway.nix` source-pin pattern. Notes for future edits:

- Plugin derivations come from `mkTmuxPlugin`, whose `addRtp` wrapper
  **replaces** `overrideAttrs` with one that re-runs `mkTmuxPlugin` over the
  original attrs. So `overrideAttrs (_old: {version; src;})` is enough; nothing
  else needs restating.
- `nix flake prefetch --json github:owner/repo/rev` yields a `hash` value
  interchangeable with `fetchFromGitHub`'s `hash`. Validated by prefetching
  `tmux-prefix-highlight/15acc617` and matching nixpkgs' own recorded
  `sha256-9LWRV0Hw8MmDwn5hWl3DrBuYUqBjLCO02K9bbx11MyM=`.
- `tmux-resurrect` keeps `fetchSubmodules = true` (upstream `lib/tmux-test`
  submodule). Its submodule-inclusive hash comes from
  `nix flake prefetch "git+https://github.com/tmux-plugins/tmux-resurrect?rev=<rev>&submodules=1"`,
  not the plain `github:` form.
- `tmuxPlugins` is `recurseIntoAttrs`, so the merged attrset restates
  `recurseForDerivations = true`.

## Landed pins

After the plugin-set reduction
(`.agents/docs/notes/tooling/tmux-plugins-inlined-2026-10.md`) only resurrect
remains pinned:

| plugin    | was (nixpkgs) | now (upstream HEAD)   | change                                                                                                 |
| --------- | ------------- | --------------------- | ------------------------------------------------------------------------------------------------------ |
| resurrect | 2022-05-01    | 2023-03-06 `cff343cf` | `XDG_DATA_HOME` resurrect dir, busybox `ps`, procfs `cmdline` subshell, program-restore argument fixes |
| continuum | 2022-01-25    | 2024-01-20 `0698e8f4` | systemd unit install/disable fixes, macOS plist idempotence                                            |

Pins that existed in the first pass and were then dropped with their plugins:
`pain-control` (README only), `copycat` (git searches from any subdirectory),
`open` (`@open-editor` fix, phrase search, issue #53), `prefix-highlight`
(`status-format[0]`/`[1]` support, interpolation fixes), `logging` (docs only)
and `continuum` (systemd unit fixes; plugin dropped). `sensible` (`25cb91f4`,
2022-08-14), `better-mouse-mode` (`aa59077c`, 2017-10-16) and `yank`
(`acfd36e4`, 2023-07-19) were already at upstream HEAD, so they were never
pinned; all eight were inlined or replaced by `tmux-fingers`.

`tmux-fingers` also stays unpinned: nixpkgs ships 2.6.2 from the release tag
while upstream is at 2.7.1 (2026-06-09), and bumping it means rebuilding the
Crystal package (`shardsFile`), not a `src` swap.

## Validation

- `nix build .#nixosConfigurations.pvl-a1.pkgs.tmuxPlugins.<plugin>` for the
  pin, plus `tmuxPlugins.fingers`.
- Content spot check: resurrect `scripts/helpers.sh` defaults to `XDG_DATA_HOME`
  and ships the `lib/tmux-test` submodule.
- Generated `pvl-a1` `tmux.conf` `run-shell` lines point at the pinned store
  paths and load without errors (`source-file` clean, `list-keys` shows the
  resurrect `C-s`/`C-r` hooks).

## Maintenance

Drop an overlay entry once nixpkgs carries the same rev. A bump is a manual
`rev` + `nix flake prefetch` hash update: these upstreams have no current
releases (their tags are years behind their default branch), so the
`nix-update-script` passthru that nixpkgs attaches cannot track them.
