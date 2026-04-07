# Default Nix `nix-build` Compatibility

- Date: 2026-03-23
- Scope: `pkgs/*/default.nix`

## Decision

Keep package-local `default.nix` files as the canonical package definitions and
make them directly evaluatable by legacy `nix-build`.

## Rule

- Package `default.nix` files should accept `pkgs ? import <nixpkgs> {}` so they
  can build standalone via `nix-build` while still allowing flake wrappers to
  inject a pinned `pkgs` with `callPackage`.
- Repo-local package dependencies in `default.nix` should also provide legacy
  defaults via `pkgs.callPackage ../path/to/default.nix {}` when they need to be
  buildable outside the flake wrapper.

## Applied Here

- `pkgs/examples/hello-rust/default.nix`
- `pkgs/nixbot/default.nix`
- `pkgs/cloudflare-apps/llmug-hello/default.nix`
- `pkgs/cloudflare-apps/default.nix`

This keeps the current architecture where child `flake.nix` files are wrappers
around canonical package definitions instead of making `builtins.getFlake` the
package composition layer.
