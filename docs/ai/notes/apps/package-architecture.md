# Package Architecture

## Scope

Canonical package and child-flake rules for `pkgs/`, root flake exports, shared
helpers under `lib/flake`, and package-owned service modules.

## Durable rules

- Keep package-local `default.nix` files as the canonical package definitions.
  They should remain directly buildable via `nix-build`, typically by accepting
  `pkgs ? import <nixpkgs> {}`.
- Treat child `flake.nix` files as thin wrappers for local developer UX:
  `nix run`, `nix develop`, package-local checks, and package-owned NixOS
  exports.
- Keep the root flake explicit. `pkgs/manifest.nix` is the source of truth for:
  - root package registration
  - curated root apps
  - the root `stdPackages` set used by lint and fmt orchestration
- Root app exposure should derive from package metadata and manifest policy, not
  from open-coded per-package flake wiring.
- When Terraform or other repo automation needs to build a package directory, it
  should resolve `--file <dir>/default.nix`. Wrapper flakes are not the build
  contract for that path.

## Shared helper model

- Shared flake helpers live under `lib/flake/`.
- `lib/flake/packages.nix` and `pkgs/manifest.nix` define the canonical root
  package set.
- `lib/flake/pkg-helper.nix` is the canonical helper surface for conventional
  package-local checks, apps, dev shells, and flake output wiring.
- Prefer the high-level helper entrypoints:
  - `mkRustDerivation`
  - `mkGoDerivation`
  - `mkPythonDerivation`
  - `mkWebDerivation`
  - `mkStaticWebDerivation`
  - `mkShellScriptDerivation`
  - `mkStdFlakeOutputs`
- Helper wrappers may infer `src` from `build.src` when the inner build already
  exposes it. Packages should not repeat `src = ./.;` unless a helper requires
  an explicit override.
- Shared check helpers own the repeated child-flake pattern. Package-local
  `default.nix` should define `passthru.checks`, and child flakes should mostly
  re-export them.

## Package contract

- The conventional child-flake interface is:
  - `checks.fmt`
  - `checks.lint`
  - `checks.test`
  - `apps.fmt`
  - `apps.lint-fix`
  - `apps.dev` when the package has a dev server or similar interactive flow
- `checks.*` stay read-only and CI-safe.
- Mutating actions belong in `apps.*`, not `checks.*`.
- Root lint and root fmt aggregate package-local behavior. They should not
  re-encode language-specific package rules under the root flake.
- Rust packages should use the shared Rust helper so `fmt`, `clippy`, and test
  behavior stays consistent and `rustfmt` is present inside sandboxed checks.

## Package layout

- `pkgs/examples/` is the home for sample projects. Root exports should prefix
  those package names with `example-`.
- Nested package directories under `pkgs/` are acceptable. Keep root flake IDs
  flat and explicit in the manifest.
- Non-package helper derivations consumed directly by overlays or scripts belong
  outside `pkgs/`; see `lib/ext/` for that pattern.

## Package-owned service modules

- Services that ship as child flakes under `pkgs/srv/*` should export their
  NixOS modules from the child flake.
- Repeated service-module boilerplate belongs in `lib/flake/service-module.nix`.
- `mkServiceModules` owns the standard service shape:
  - `services.<name>.enable`
  - `services.<name>.package`
  - `systemd.services.<name>` with `ExecStart = lib.getExe cfg.package`
  - standard `Restart`, `wantedBy`, and `after` defaults
- `mkTcpServiceModules` extends that model with listener address and port
  options when the binary consumes them via environment variables.

## Current application notes

- For repo-managed application suites, prefer:
  - one durable ingress boundary first
  - package-owned service exports for repo-managed services
  - operational consolidation before finer deployable splitting
- Existing app and package moves should preserve the rule that manifest IDs and
  root app exposure stay explicit even when on-disk directories move.

## Source of truth files

- `pkgs/manifest.nix`
- `lib/flake/packages.nix`
- `lib/flake/apps.nix`
- `lib/flake/pkg-helper.nix`
- `lib/flake/service-module.nix`
- `pkgs/*/default.nix`
- `pkgs/*/flake.nix`

## Provenance

- This note replaces the earlier dated package-architecture and package-layout
  notes from March and April 2026.
