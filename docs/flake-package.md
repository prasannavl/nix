# Flake Package Helper

This repo uses one shared child-flake contract for packages under `pkgs/`.

The helper lives in [`lib/flake/pkg-helper.nix`](../lib/flake/pkg-helper.nix).

## What Packages Should Expose

Standard package outputs:

- `packages.build`
- `packages.default`
- `packages.run`
- `packages.dev`
- `packages.fmt`
- `packages.lint-fix`

Standard checks:

- `checks.build`
- `checks.fmt`
- `checks.lint`
- `checks.test`

Standard apps:

- `apps.run`
- `apps.dev`
- `apps.fmt`
- `apps.lint-fix`

Optional shell:

- `devShells.default`

`checks.*` are read-only. Mutating behavior belongs in apps such as `fmt` and
`lint-fix`.

## Main Commands

Package-local:

- `nix build ./pkgs/<name>`
- `nix run ./pkgs/<name>`
- `nix run ./pkgs/<name>#dev`
- `nix run ./pkgs/<name>#fmt`
- `nix run ./pkgs/<name>#lint-fix`
- `nix build ./pkgs/<name>#checks.fmt`
- `nix build ./pkgs/<name>#checks.lint`
- `nix build ./pkgs/<name>#checks.test`
- `nix flake check ./pkgs/<name>`

Root orchestration:

- `nix fmt`
- `nix run .#fmt -- --project <name>`
- `nix run .#lint`
- `nix run .#lint -- fix`
- `nix run .#lint -- --project <name>`

## Ownership Split

Root tooling owns files outside `pkgs/`:

- `nix fmt`
- `nix run .#lint`
- `nix run .#lint -- fix`

Package tooling owns language-specific behavior inside child flakes:

- `apps.fmt`
- `apps.lint-fix`
- `checks.fmt`
- `checks.lint`
- `checks.test`

## Default Language Policy

- Rust: `rustfmt`, `clippy`, `cargo test`
- Python: `ruff`
- Go: `gofmt`, `go vet`, `go test`
- Web projects: `biome`
- Deno-capable web dev shells: `deno`

## Standard Shape

`default.nix` should define the build and apply one helper:

```nix
let
  pkgHelper = import <repo-relative-path>/lib/flake/pkg-helper.nix;
  drv = pkgHelper.mkGoDerivation {
    inherit pkgs;
    build = ...;
    src = ./.;
  };
in
  drv
```

`flake.nix` should usually just re-export the derivation:

```nix
let
  drv = pkgs.callPackage ./default.nix {};
in
  pkgHelper.mkStdFlakeOutputs {
    inherit pkgs;
    build = drv;
  }
```

## Main Helpers

High-level derivation builders:

- `mkRustDerivation`
- `mkGoDerivation`
- `mkPythonDerivation`
- `mkWebDerivation`
- `mkStaticWebDerivation`
- `mkShellScriptDerivation`
- `mkAggregateDerivation`

Wiring helpers:

- `mkStdFlakeOutputs`
- `wirePassthru`

Lower-level helpers remain available for unusual package layouts, but most
packages should not need them directly.

## Detailed Reference

The sections below cover conventions, rationale, and extended examples.

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
