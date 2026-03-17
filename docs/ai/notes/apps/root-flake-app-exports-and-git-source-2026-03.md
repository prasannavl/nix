# Root Flake Custom Pkgs Export And Git Source

- Date: 2026-03-16
- Scope: root flake installables under `pkgs/`

## Context

The root flake originally relied on flat compatibility aliases for runnable
projects while the overlay consumed a separate nested collector tree. That
worked, but the installable surface no longer matched the directory layout as
cleanly as it could.

Separately, `nix run .#...` evaluated the Git-backed flake snapshot, which
excluded the new untracked `pkgs/` tree. `path:.#...` worked because it used the
working tree directly.

Trying to expose the repo-local tree as a pure custom top-level `pkgs` flake
output ran into two Nix constraints:

- pure flake evaluation does not provide `builtins.currentSystem`, so a custom
  top-level `pkgs.<name>` tree cannot be selected per-host that way
- `nix flake show` validates standard `packages`/`apps` outputs strictly, so
  nested app trees and nested package trees are not both representable there

## Decision

Expose the repo-local tree through a custom top-level `pkgs.<system>.*` output
and stop relying on `nix flake show` for deployment host discovery:

- `pkgs.<system>.*` contains derivations for `nix build` and `nix run`.
- runnable aliases such as `deploy` must also be exported under `packages.*` in
  each child flake so the collector can attach them to the custom leaf.
- The overlay publishes host-installable packages directly as `pkgs.<name>`
  rather than `pkgs.apps.<name>`.
- Deploy host discovery now uses
  `nix eval --json path:.#nixosConfigurations --apply builtins.attrNames`.

## Result

- `nix build path:.#pkgs.x86_64-linux.hello-rust` works.
- `nix run path:.#pkgs.x86_64-linux.hello-rust` works.
- `nix run path:.#pkgs.x86_64-linux.cloudflare-workers.<worker>.deploy`
  works.
- Deploy host discovery no longer depends on `nix flake show` succeeding.
