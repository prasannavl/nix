# Tailscale Upstream Package

## Decision

The repo exposes an upstream Tailscale release package by overriding the nixpkgs
Tailscale package and selecting it as `pkgs.tailscale` in the root overlay.

## Package layout

- `lib/ext/tailscale/sources.nix` owns the pinned release data.
- `lib/ext/tailscale/default.nix` owns the packaging override.
- `lib/ext/tailscale/update.sh` resolves GitHub Releases `latest`, prefetches
  the source hash, and probes the Go module vendor hash.

## Package source

- Current pinned version: `1.104.1`.
- Source: Tailscale GitHub release tag `v1.104.1`.
- The updater treats GitHub Releases `latest` as the stable Tailscale source of
  truth and resolves it through the normal GitHub release redirect, avoiding the
  unauthenticated GitHub API rate limit.
- The package reuses the upstream nixpkgs Tailscale build, wrapper, completions,
  derper output, and systemd unit handling.
- The override pins only the release `src`, `vendorHash`, `version`, and
  version-stamp linker flags.

## Go toolchain pin

- Tailscale 1.104+ requires Go >= 1.27.1, while the pinned nixpkgs default Go is
  1.26.8.
- `default.nix` and `update.sh` both override the base package with
  `buildGoModule = pkgs.unstable.buildGo127Module`.
- Keep the override in both places: the vendor-hash probe must build with the
  same toolchain the final package uses, or the updater fails before any hash
  mismatch is reported.

## Updater source ref

- `update.sh` references the root flake through the shared helper
  `lib/flake/repo-flake.nix`
  (`import ${REPO_ROOT}/lib/flake/repo-flake.nix {repoRoot = ${REPO_ROOT};}`),
  which forces the Git fetcher.
- A bare absolute path passed to `builtins.getFlake` resolves to a `path:` input
  whose fetcher descends into git-ignored linked worktrees; unreadable leftovers
  under `worktrees/**/tmp` then fail the probe for unrelated reasons.
- See `.agents/docs/notes/tooling/ai-nix-evaluation-source-refs-2026-05.md`.

## Overlay contract

- `pkgs.tailscale-upstream` is the explicit upstream-release package.
- `pkgs.tailscale` points at `pkgs.tailscale-upstream`, so existing host package
  lists and the upstream NixOS module default `services.tailscale.package`
  consume the external release without host-local changes.
- `pkgs.unstable.tailscale` remains available through `pkgs.unstable`, but the
  root overlay no longer re-exports it as the top-level `pkgs.tailscale`.
