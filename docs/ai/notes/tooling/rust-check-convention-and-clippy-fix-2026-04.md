# Rust package convention under package-local checks and apps

- Date: 2026-04-07
- Scope: Rust child flakes under `pkgs/`, `lib/flake/pkg-helper.nix`,
  `lib/flake/lint.nix`, `scripts/lint.sh`

## Decision

Use one shared Rust helper that makes Rust child flakes conform to the package
contract:

- `checks.fmt`
- `checks.lint`
- `checks.test`
- `apps.fmt`
- `apps.lint-fix`

## Why

- `checks.*` should stay read-only and CI-safe; `cargo clippy --fix` mutates the
  worktree and belongs in a child-flake app, not in `checks`.
- Rust packages should behave the same way as other child flakes in `pkgs/`.
- A shared helper keeps Rust child flakes consistent while preserving package
  control over cargo flags such as `--locked`.

## Applied shape

- `lib/flake/pkg-helper.nix` now exports `rustFmt`, `rustClippy`, `rustTest`,
  `mkRustChecks`, `mkRustDerivation`, `rustFmtApp`, and `rustLintFixApp`.
- `pkgs/hello-rust`, `pkgs/edi-ast-parser-rs`, and `pkgs/gap3-ai-web` now use
  `mkRustChecks` instead of open-coded `fmt`/`lint`/`test` check attrsets.
- `gap3-ai-web` passes `--locked` through the shared helper for `lint` and
  `test` while `fmt` remains plain `cargo fmt --check`.
- Rust child flakes now expose package-local `apps.fmt` and `apps.lint-fix`
  from the shared helper, so root lint and root fmt can delegate to them like
  any other package.

## Convention

- Root `nix fmt` remains the canonical formatter entrypoint.
- Rust child flakes expose read-only verification as `checks.fmt`,
  `checks.lint`, and `checks.test`.
- Mutating Rust fixes run through child-flake apps such as `apps.lint-fix`, not
  through child-flake `checks`.
