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

- Current pinned version: `1.104.7`.
- Source: Tailscale GitHub release tag `v1.104.7`.
- The updater treats GitHub Releases `latest` as the stable Tailscale source of
  truth and resolves it through the normal GitHub release redirect, avoiding the
  unauthenticated GitHub API rate limit.
- The package reuses the upstream nixpkgs Tailscale build, wrapper, completions,
  derper output, and systemd unit handling.
- The override pins the release `src`, `vendorHash`, `version`, version-stamp
  linker flags, and the Go toolchain it needs.

## Go toolchain pin

- Tailscale 1.104.7 declares Go 1.27.4 in `go.mod`, while the pinned Nixpkgs Go
  1.27 line can temporarily lag at an earlier patch level.
- The root flake pins `purpleclay/go-overlay` as a non-flake source input and
  applies its overlay directly. Its own flake dependency graph is not used.
- `sources.nix` records only the exact `goVersion` required by Tailscale.
  `default.nix` selects `pkgs.go-bin.versions.<version>` and injects it into
  generic Nixpkgs `buildGoModule`. Upstream Tailscale currently names its
  constructor argument `buildGo127Module`; that name remains only at the
  override boundary.
- `go-overlay` provides pure, reproducible binary Go toolchains across many
  historical/current versions and updates them automatically after go.dev
  releases. This is the Go equivalent of consuming a dedicated Rust toolchain
  provider rather than rebuilding compiler releases locally.
- `update.sh` derives the required Go version from the release's `go.mod` and
  checks that the pinned `go-overlay` contains that exact version. If it does
  not, the Tailscale release is held until the `go-overlay` input is updated.
- The vendor-hash probe imports `lib/ext/tailscale/default.nix` with the same
  `goBin` source and candidate Tailscale metadata, so probe and final package
  share the exact package/toolchain construction.

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
