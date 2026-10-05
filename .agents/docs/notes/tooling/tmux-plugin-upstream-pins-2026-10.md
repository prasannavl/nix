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

| plugin           | was (nixpkgs) | now (upstream HEAD)   | change                                                                                                 |
| ---------------- | ------------- | --------------------- | ------------------------------------------------------------------------------------------------------ |
| pain-control     | 2020-02-18    | 2021-08-09 `32b760f6` | README only                                                                                            |
| copycat          | 2020-01-09    | 2020-07-24 `d7f7e6c1` | git searches work from any subdirectory (`git -C`), README note on tmux 3.1 regex search               |
| open             | 2019-12-02    | 2022-08-22 `763d0a85` | `@open-editor` binding fix, phrase search support, issue #53 fix                                       |
| prefix-highlight | 2021-03-30    | 2025-03-01 `06cbb4ec` | `status-format[0]`/`[1]` support, interpolation fixes                                                  |
| resurrect        | 2022-05-01    | 2023-03-06 `cff343cf` | `XDG_DATA_HOME` resurrect dir, busybox `ps`, procfs `cmdline` subshell, program-restore argument fixes |
| continuum        | 2022-01-25    | 2024-01-20 `0698e8f4` | systemd unit install/disable fixes, macOS plist idempotence                                            |
| logging          | 2019-04-19    | 2021-06-10 `b5c5f7b9` | docs only                                                                                              |

Already at upstream HEAD, so not pinned: `sensible` (`25cb91f4`, 2022-08-14),
`better-mouse-mode` (`aa59077c`, 2017-10-16), `yank` (`acfd36e4`, 2023-07-19).

Deliberately left alone: `tmux-thumbs` stays at the `0.8.0` release
(2023-03-11), which is upstream's latest release; `master` adds only a README
line, and the nixpkgs package is a Rust `callPackage` whose `cargoHash` churn is
not worth a README fix.

## Validation

- `nix build .#nixosConfigurations.pvl-a1.pkgs.tmuxPlugins.<plugin>` for all
  seven pins.
- Content spot checks: copycat `scripts/copycat_git_special.sh` uses
  `git -C "$PANE_CURRENT_PATH"`; prefix-highlight handles `status-format[0]` and
  `status-format[1]`; resurrect `scripts/helpers.sh` defaults to `XDG_DATA_HOME`
  and ships the `lib/tmux-test` submodule.
- Generated `pvl-a1` `tmux.conf` `run-shell` lines now point at the new store
  paths for those seven plugins.

## Maintenance

Drop an overlay entry once nixpkgs carries the same rev. A bump is a manual
`rev` + `nix flake prefetch` hash update: these upstreams have no current
releases (their tags are years behind their default branch), so the
`nix-update-script` passthru that nixpkgs attaches cannot track them.
