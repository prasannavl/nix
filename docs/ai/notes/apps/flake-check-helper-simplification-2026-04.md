# Flake Check Helper Simplification

- Date: 2026-04-06
- Scope: child wrapper flakes under `pkgs/`, shared helpers under `lib/flake/`

## Decision

The repeated child-flake pattern:

- bind `build = pkgs.callPackage ./default.nix {};`
- define local `checks = { ... };` wrappers in `flake.nix`

is now centralized in two layers:

- `lib/flake/pkg-helper.nix` provides `mkCheck` and `mkChecks`
- each package `default.nix` defines its own `passthru.checks`

Child wrapper flakes now just re-export `checks = build.checks;`.

## Why

- Keeps wrapper flakes focused on package exports rather than repeating check
  names and check-derivation boilerplate.
- Preserves the existing behavior for Rust package checks:
  - suffix `pname` with the check name
  - append optional `nativeBuildInputs`
  - override `buildPhase`
  - replace install with `touch $out`
- Keeps the check list next to the canonical package definition, so package
  behavior and validation stay co-located.

## Current adopters

- `pkgs/examples/hello-rust/flake.nix`
- `pkgs/examples/edi-ast-parser-rs/flake.nix`
- `pkgs/gap3-ai-web/flake.nix`
