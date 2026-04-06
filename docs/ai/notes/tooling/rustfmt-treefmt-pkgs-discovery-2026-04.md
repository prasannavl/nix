# Rustfmt treefmt `pkgs/` discovery

- Date: 2026-04-06
- Scope: `treefmt.toml`, `lib/flake/lint.nix`, `scripts/{lint.sh,rust-fmt.sh}`

## Decision

Make `nix fmt` run Rust formatting generically for tracked Cargo projects under
`pkgs/` by routing `treefmt` through a repo script that discovers
`pkgs/**/Cargo.toml` manifests and runs `cargo fmt --manifest-path ... --all`
for each crate.

## Why

- The repo has multiple Rust crates under `pkgs/`, and keeping one `treefmt`
  stanza per crate does not scale.
- `cargo fmt` needs the correct manifest path, so a single repo-wide raw
  `rustfmt` pass is not enough.
- `lint fix` already uses `treefmt`, so the shared lint runtime also needs
  `cargo` and `rustfmt` available.

## Applied shape

- `treefmt.toml` now has one Rust formatter entry covering `pkgs/**/*.rs`.
- `scripts/rust-fmt.sh` is the generic formatter wrapper and self-bootstraps
  through `nix shell` when run outside the repo formatter environment.
- `lib/flake/lint.nix` adds `cargo` and `rustfmt` to the formatter runtime.
- `scripts/lint.sh` adds the same tools to the shared lint runtime so
  `lint
  fix` can run `treefmt` without nested formatter failures.
