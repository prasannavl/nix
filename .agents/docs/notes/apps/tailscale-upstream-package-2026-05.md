# Tailscale Upstream Package

## Decision

The repo exposes an upstream Tailscale release package by overriding the nixpkgs
Tailscale package in `lib/ext/tailscale-upstream.nix` and selecting it as
`pkgs.tailscale` in the root overlay.

## Package source

- Current pinned version: `1.98.5`.
- Source: Tailscale GitHub release tag `v1.98.5`.
- `scripts/update-tailscale.sh` treats GitHub Releases `latest` as the stable
  Tailscale source of truth and resolves it through the normal GitHub release
  redirect, avoiding the unauthenticated GitHub API rate limit.
- The package reuses the upstream nixpkgs Tailscale build, wrapper, completions,
  derper output, and systemd unit handling.
- The override pins only the release `src`, `vendorHash`, `version`, and
  version-stamp linker flags.
- The override currently uses `pkgs.unstable.tailscale` as its base because the
  pinned stable nixpkgs Tailscale build uses an older Go toolchain than this
  upstream release requires.

## Overlay contract

- `pkgs.tailscale-upstream` is the explicit upstream-release package.
- `pkgs.tailscale` points at `pkgs.tailscale-upstream`, so existing host package
  lists and the upstream NixOS module default `services.tailscale.package`
  consume the external release without host-local changes.
- `pkgs.unstable.tailscale` remains available through `pkgs.unstable`, but the
  root overlay no longer re-exports it as the top-level `pkgs.tailscale`.
