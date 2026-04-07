# Rust fmt checks and app meta

- Date: 2026-04-07
- Scope: `pkgs/examples/edi-ast-parser-rs/{default.nix,flake.nix}`,
  `pkgs/gap3-ai-web/default.nix`

## Decision

Add explicit `fmt` checks for the Rust child flakes and attach package metadata
to `edi-ast-parser-rs` app outputs.

## Why

- `nix flake check` builds `checks.*` derivations, so Rust formatter checks must
  include `rustfmt` in their sandboxed inputs instead of relying on developer
  shell state.
- `edi-ast-parser-rs` app outputs were defined manually and omitted `meta`,
  which caused `nix flake check` app warnings.
- Keeping `fmt` in `checks` preserves the standard flake contract: individual
  verification stays under `checks`, while runnable entrypoints remain under
  `apps`.

## Applied shape

- `pkgs/examples/edi-ast-parser-rs/default.nix` now defines `checks.fmt` with
  `nativeBuildInputs = [ pkgs.rustfmt ]`.
- `pkgs/gap3-ai-web/default.nix` now defines `checks.fmt` with the same
  sandboxed `rustfmt` input.
- `pkgs/examples/edi-ast-parser-rs/flake.nix` app definitions now inherit
  package `meta`, removing flake-check warnings for missing app metadata.
