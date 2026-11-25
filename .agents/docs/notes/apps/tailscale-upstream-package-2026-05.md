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
- `sources.nix` records the exact `goVersion`. The package asks
  `ab.toolchains.go` for that version; the resolver, not Tailscale, owns the
  choice of Nixpkgs or the pinned `purpleclay/go-overlay` source. Only the
  Nixpkgs override boundary uses the name `buildGo127Module`.
- `update.sh` prefers a concrete `toolchain` directive in the release's `go.mod`
  and falls back to `go`. It holds the update if the pinned resolver cannot
  return that exact version.
- The vendor-hash probe overrides `pkgs.tailscale-upstream` with the candidate
  source metadata so the probe and final package use the same builder.

## Updater source ref

- `update.sh` references the root flake through the shared helper
  `ab/repo/self-flake.nix`, which uses the Git fetcher.
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
