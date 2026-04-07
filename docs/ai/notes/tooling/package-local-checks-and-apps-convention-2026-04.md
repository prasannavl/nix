# Package-local checks and apps convention

- Date: 2026-04-07
- Scope: root flake tooling, `scripts/lint.sh`, `scripts/fmt.sh`, child flakes
  under `pkgs/`

## Decision

Use one conventional package contract for child flakes under `pkgs/`:

- `checks.lint`
- `checks.fmt`
- `checks.test`
- `apps.lint-fix`
- `apps.fmt`
- `apps.dev` when the package has a dev server or equivalent interactive
  workflow

The root flake owns linting and formatting only for files outside `pkgs/`, and
aggregates package-local checks and apps for everything inside `pkgs/`.

## Why

- Package-owned verification keeps language behavior close to the package and
  lets root tooling stay an orchestrator instead of embedding per-language
  package rules.
- The same package contract works across Rust, Go, Node, Python, Cloudflare, and
  static site child flakes.
- Root-only rules still need one home for files that are not owned by child
  flakes, such as top-level Nix, shell, Markdown, and Terraform files.

## Applied shape

- `nix fmt` at the repo root formats root-managed files outside `pkgs/` through
  `treefmt`, then runs package `fmt` actions through one aggregate package-ops
  manifest.
- `nix run path:.#lint` runs root-only read-only checks outside `pkgs/`, then
  runs package `checks.fmt`, `checks.lint`, and `checks.test` through the same
  aggregate package-ops manifest when present.
- `nix run path:.#lint -- fix` runs the root formatter, then package
  `apps.lint-fix` and `apps.fmt` through the aggregate package-ops manifest,
  then applies root-only fix-capable tools outside `pkgs/`, and finally
  re-runs lint.
- `--project <name>` scopes root `fmt` and `lint` to one or more child flakes by
  directory name under `pkgs/`, including nested child flakes.
- Shared package-helper builders in `lib/flake/pkg-helper.nix` own the common
  package app and check mechanics so child flakes only declare runtime inputs,
  environment, optional overrides, and package-specific commands. Child flakes
  should not open-code repo-root discovery, treefmt wiring, or `runCommand`
  boilerplate per project.
- Root-owned filetype policy outside `pkgs/` is: Markdown/JSON/JSONC with
  `deno fmt`, Nix with `alejandra`, Terraform/OpenTofu with `tofu fmt`, and
  shell with `shfmt`.
- Package-owned language policy under `pkgs/` is defined in shared flake
  helpers: Rust uses `rustfmt` and `clippy`, Python uses `ruff`, Go uses
  `gofmt`, `go vet`, and `go test`, Node/web assets use `biome`, and Deno
  projects use `deno fmt`.
- Shared helper defaults should derive package metadata from `src = ./.` when
  possible, including the project path used by package apps and the default Rust
  package name used in generated app names. Explicit overrides remain available
  for unusual layouts.
- Shared helper defaults should treat a project's own `flake.nix` or
  `default.nix` as the working-directory marker for package apps, rather than
  requiring per-project marker file lists.
- Shared helper defaults should auto-discover owned files by file type and
  respect `.gitignore` in real worktrees; manual include or exclude lists are
  for exceptions, not the default path.
- Shared helper libraries should own language conventions end to end where
  possible. Child flakes should prefer one convention builder per language or
  project type, and one flake-output builder that derives `packages`, `apps`,
  `devShells`, and conventional `checks` from the package's `passthru`, instead
  of repeating that wiring in each `flake.nix`.
- Package definitions should prefer `pkgHelper.mk*Derivation` entrypoints and
  bind the final package derivation as `drv`, rather than building a package
  first and then attaching separate `conventions` attrsets.

## Shared helper surface

The package helper lives in `lib/flake/pkg-helper.nix`. It should be treated as
the canonical place for the child-flake contract under `pkgs/`.

The high-level derivation builders are:

- `mkRustDerivation`
- `mkGoDerivation`
- `mkPythonDerivation`
- `mkWebDerivation`
- `mkStaticWebDerivation`
- `mkShellScriptDerivation`
- `mkAggregateDerivation`

The standard flake wiring helpers are:

- `mkStdFlakeOutputs`: exports `packages.*`, `apps.*`, `checks.*`, and
  `devShells.default` from the derivation and its `passthru`.
- `wirePassthru`: adds shared or package-specific passthru outputs without
  repeating `overrideAttrs` plumbing.
- `mkStdFlakeOutputs` also re-exports helper-provided passthru extras such as
  aggregate `extraPackages` and `extraApps`.

The lower-level package parts remain available for unusual projects:

- `projectFmtGlobal`
- `projectFmtRust`
- `projectFmtGo`
- `projectFmtRuff`
- `projectFmtBiome`
- `projectLintGo`
- `projectLintRuff`
- `projectLintBiome`
- `projectLintShell`
- `projectLintFixRust`
- `projectLintFixRuff`
- `projectLintFixBiome`
- `mkProjectApp`
- `mkProjectCommandsApp`
- `mkProjectCheck`
- `mkProjectCommandsCheck`
- `mkStdApp`
- `mkStdCheck`
- `mkProjectAppOp`
- `mkProjectCheckOp`
- `mkStdAppOp`
- `mkStdCheckOp`
- `mkCheck`
- `mkChecks`
- `mkRustChecks`

Most child packages should not need those lower-level helpers directly. The
default path is:

1. Define the package build in `default.nix`.
2. Wrap it with one `pkgHelper.mk*Derivation`.
3. Re-export it from `flake.nix` through `pkgHelper.mkStdFlakeOutputs`.

## Convention

- Child flakes should use shared helper libraries where possible so the package
  contract stays uniform.
- `checks.*` stay read-only and CI-safe.
- Mutating package actions belong in `apps.*`, not `checks.*`.
- Root tooling should not rename or reinterpret package meanings; it should
  aggregate the conventional outputs as-is.
