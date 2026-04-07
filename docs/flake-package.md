# Flake Package Helper

This repo uses one standard child-flake contract for packages under `pkgs/`. The
shared helper in [`lib/flake/pkg-helper.nix`](../lib/flake/pkg-helper.nix) owns
that contract so package `default.nix` and `flake.nix` files stay short.

## Standard Contract

Packages under `pkgs/` should expose these conventional outputs:

- `packages.build`: the actual package derivation.
- `packages.default`: same as `packages.build`.
- `packages.run`: the runnable package when the build has a `mainProgram`.
- `packages.dev`: optional developer entrypoint package.
- `packages.fmt`: optional package-local formatter app package.
- `packages.lint-fix`: optional package-local mutating lint-fix app package.
- `checks.build`: the package build itself.
- `checks.fmt`: read-only formatting verification.
- `checks.lint`: read-only lint verification.
- `checks.test`: read-only test verification.
- `apps.run`: runnable app wrapper for `packages.run` when present.
- `apps.dev`: optional developer app such as a dev server.
- `apps.fmt`: optional mutating formatter entrypoint for that package.
- `apps.lint-fix`: optional mutating lint-fix entrypoint for that package.
- `devShells.default`: optional package-local development shell.

The intended semantics are:

- `run`: execute the package normally.
- `dev`: start an interactive developer workflow such as a local dev server.
- `fmt`: mutate the package tree to format owned files.
- `lint-fix`: mutate the package tree to apply safe auto-fixes.
- `checks.fmt`: verify that formatting is already correct.
- `checks.lint`: verify that lint rules already pass.
- `checks.test`: verify package tests.

`checks.*` are always read-only and CI-safe. Mutating actions belong in
`apps.*`, not in `checks.*`.

## Root Versus Package Ownership

The repo splits formatting and linting into two layers.

Root-owned tooling handles files outside `pkgs/`:

- `nix fmt` formats root-managed files outside `pkgs/`.
- `nix run path:.#lint` lints root-managed files outside `pkgs/`.
- `nix run path:.#lint -- fix` applies fix-capable root-owned tooling outside
  `pkgs/`.

Package-owned tooling handles files inside each child package:

- `apps.fmt` formats package-owned files.
- `apps.lint-fix` applies package-owned auto-fixes.
- `checks.fmt`, `checks.lint`, and `checks.test` verify the package.

Root tooling is an orchestrator, not the owner of package language rules:

- `nix fmt` runs the root formatter for root-owned files, then runs package
  `fmt` actions through one root aggregate package-ops manifest.
- `nix run path:.#lint` runs root-owned lint checks, then runs package
  `checks.*` through the root aggregate package-ops manifest.
- `nix run path:.#lint -- fix` runs root formatting and root fixers, then runs
  package `fmt` and `lint-fix` actions through the same root aggregate
  package-ops manifest, then re-runs lint.

Root-owned file type policy is:

- Markdown, JSON, JSONC: `deno fmt`
- Nix: `alejandra`
- Terraform and OpenTofu: `tofu fmt`
- Shell: `shfmt` for formatting and `shellcheck` for linting

Package-owned language policy is defined by the shared helper:

- Rust: `rustfmt`, `clippy`, `cargo test`
- Python: `ruff`
- Go: `gofmt`, `go vet`, `go test`
- Web projects: `biome`
- Deno-capable web dev shells: `deno`

## Common Commands

Build and run one package:

- `nix build ./pkgs/<name>`: build that child flake's default package.
- `nix run ./pkgs/<name>`: run its default app.
- `nix run ./pkgs/<name>#run`: run its explicit `run` app.
- `nix run ./pkgs/<name>#dev`: run its explicit `dev` app when present.
- `nix develop ./pkgs/<name>`: enter the package dev shell.

Run package-local format, lint-fix, and checks:

- `nix run ./pkgs/<name>#fmt`: format package-owned files.
- `nix run ./pkgs/<name>#lint-fix`: apply package-owned auto-fixes.
- `nix build ./pkgs/<name>#checks.fmt`: verify formatting.
- `nix build ./pkgs/<name>#checks.lint`: verify lint rules.
- `nix build ./pkgs/<name>#checks.test`: run package tests.
- `nix flake check ./pkgs/<name>`: run all package checks.

Run root orchestration:

- `nix fmt`: format root-owned files and then package-owned files.
- `nix run path:.#fmt -- --project <name>`: run formatting only for selected
  child packages.
- `nix run path:.#lint`: lint root-owned files and package checks.
- `nix run path:.#lint -- fix`: apply root and package auto-fixes, then rerun
  lint.
- `nix run path:.#lint -- --project <name>`: lint only selected child packages
  plus any root-owned scope that still applies.

## Standard Shape

The normal package shape is:

```nix
# default.nix
let
  pkgHelper = import ../../lib/flake/pkg-helper.nix;
  build = ...;
  drv = pkgHelper.mkGoDerivation {
    inherit pkgs build;
    src = ./.;
  };
in
  drv
```

```nix
# flake.nix
let
  pkgHelper = flake.lib.flake.checks;
  drv = pkgs.callPackage ./default.nix {};
in
  pkgHelper.mkStdFlakeOutputs {
    inherit pkgs;
    build = drv;
  }
```

`mkStdFlakeOutputs` reads the derivation and its `passthru` and wires the
standard `packages.*`, `apps.*`, `checks.*`, and `devShells.default` exports.

## High-Level Builders

These are the main package entrypoints:

- `mkRustDerivation`: Rust package conventions. Adds `checks.fmt`,
  `checks.lint`, `checks.test`, `apps.fmt`, and `apps.lint-fix` using `rustfmt`,
  `clippy`, and `cargo test`.
- `mkGoDerivation`: Go package conventions. Adds `checks.fmt`, `checks.lint`,
  and `checks.test` using `gofmt`, `go vet`, and `go test`.
- `mkPythonDerivation`: Python package conventions. Adds `checks.fmt`,
  `checks.lint`, and `apps.lint-fix` using `ruff`.
- `mkWebDerivation`: Web project conventions for JS, TS, CSS, and HTML style
  trees. Adds `checks.fmt`, `checks.lint`, `apps.fmt`, and `apps.lint-fix` using
  `biome`, and includes `biome`, `nodejs`, and `deno` in the default dev shell.
- `mkStaticWebDerivation`: `mkWebDerivation` plus a simple `apps.dev` static
  server and `python3` in the default dev shell.
- `mkShellScriptDerivation`: Shell-script project conventions. Adds root-style
  formatting and `shellcheck`-based linting automatically, with `shellcheck` and
  `shfmt` in the default dev shell.
- `mkAggregateDerivation`: Aggregate namespace package conventions. Builds an
  aggregate package from child derivations, adds aggregate `fmt` / `checks.fmt`,
  and wires aggregate `pkgOps` for root `nix fmt` and `nix run path:.#lint`.

## Wiring Helpers

The main shared wiring helpers are:

- `mkStdFlakeOutputs`: standard child-flake exports from one derivation.
- `wirePassthru`: extend a derivation's `passthru` without repeating
  `overrideAttrs` boilerplate. Use this for extra package-local commands such as
  a custom `dev` app or deployment helper.
- `mkStdFlakeOutputs` also re-exports helper-provided passthru extras such as
  aggregate `extraPackages` and `extraApps` when a derivation carries them.

## Lower-Level Helpers

For cases where the high-level builders are not enough, `pkg-helper.nix` also
exports lower-level project combinators:

- `projectFmtGlobal`: delegate repo-owned file types in a package tree to the
  root formatter policy.
- `projectFmtRust`, `projectFmtGo`, `projectFmtRuff`, `projectFmtBiome`:
  language-specific formatter parts.
- `projectLintGo`, `projectLintRuff`, `projectLintBiome`, `projectLintShell`:
  language-specific read-only lint parts.
- `projectLintFixRust`, `projectLintFixRuff`, `projectLintFixBiome`:
  language-specific mutating lint-fix parts.
- `mkProjectApp`, `mkProjectCommandsApp`, `mkProjectCheck`,
  `mkProjectCommandsCheck`: lower-level building blocks for unusual package
  layouts.
- `mkStdApp`, `mkStdCheck`: standard package-local app and check wrappers.
- `mkProjectAppOp`, `mkProjectCheckOp`: root aggregate operation records for
  package apps and checks.
- `mkStdAppOp`, `mkStdCheckOp`: standard package operation wrappers used by the
  high-level derivation helpers.
- `mkCheck`, `mkChecks`, `mkRustChecks`: shared read-only check wrappers when a
  package needs direct control over its `checks.*` set.

Most child packages should not need those lower-level helpers directly. The
default path is:

1. Define the package build in `default.nix`.
2. Wrap it with one `pkgHelper.mk*Derivation`.
3. Re-export it from `flake.nix` through `pkgHelper.mkStdFlakeOutputs`.

## Defaults

Helper defaults are intentionally automatic:

- `src = ./.` is normally enough. Project name and project path are derived from
  it by default.
- Package app wrappers treat a package-local `flake.nix` or `default.nix` as the
  working-directory marker; per-project marker files are not part of the normal
  API.
- Automatic file discovery is by file type and respects `.gitignore` when the
  package runs inside a Git worktree.
- Root-owned formatting inside package trees is delegated by file type to the
  same repo-wide policy used outside `pkgs/`.

## Intended Outcome

The intent is to keep package files short:

- `default.nix` should define the build and pick one `mk*Derivation`.
- `flake.nix` should usually just call `mkStdFlakeOutputs`.
- Most packages should not open-code formatter commands, lint commands,
  repo-root discovery, `runCommand`, or flake app export boilerplate.
