# Rust check convention and clippy fix

- Date: 2026-04-07
- Scope: Rust child flakes under `pkgs/`, `lib/flake/checks.nix`,
  `lib/flake/lint.nix`, `scripts/lint.sh`

## Decision

Use one shared Rust check helper for child flakes and keep mutating Rust lint
fixes in the root lint workflow.

## Why

- `checks.*` should stay read-only and CI-safe; `cargo clippy --fix` mutates the
  worktree and does not belong in child-flake `checks`.
- The repo already treats formatting as a root policy through `treefmt`, so Rust
  packages should opt into verification checks rather than redefining formatter
  behavior package by package.
- A shared helper keeps Rust child flakes consistent while preserving package
  control over cargo flags such as `--locked`.

## Applied shape

- `lib/flake/checks.nix` now exports `rustFmt`, `rustClippy`, `rustTest`, and
  `mkRustChecks`.
- `pkgs/hello-rust`, `pkgs/edi-ast-parser-rs`, and `pkgs/gap3-ai-web` now use
  `mkRustChecks` instead of open-coded `fmt`/`clippy`/`test` check attrsets.
- `gap3-ai-web` passes `--locked` through the shared helper for `clippy` and
  `test` while `fmt` remains plain `cargo fmt --check`.
- The root lint runtime now includes `clippy`, and `nix run path:.#lint -- fix`
  applies
  `cargo clippy --fix --allow-dirty --allow-staged --all-targets
  --locked -- -D warnings`
  to the selected Rust crates before the final formatter pass.

## Convention

- Root `nix fmt` remains the canonical formatter entrypoint.
- Child flakes expose read-only Rust verification as `checks.fmt`,
  `checks.clippy`, and `checks.test`.
- Mutating Rust fixes run only through the root lint fix path, not through
  child-flake `checks`.
