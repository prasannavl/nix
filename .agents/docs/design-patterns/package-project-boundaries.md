# Package Project Boundaries

## Scope

- Apply this when creating or reshaping packages under `pkgs/**`.
- Read this together with
  `.agents/docs/notes/tooling/package-local-checks-and-apps-convention-2026-04.md`.
- For Rust packages, also read `.agents/docs/lang-patterns/rust.md`.

## Current default

- Keep the package build in `default.nix`; wrapper `flake.nix` files are for
  local package UX and standard `packages`, `apps`, `checks`, and `devShells`
  exports.
- Keep using the shared helpers in `lib/flake/pkg-helper.nix`.
- Package `default.nix` files must accept a caller-supplied current `stack` and
  may bind local aliases from it. They may fall back to the generic package
  stack at `lib/flake/stack/package.nix` for standalone package builds.
- Do not import concrete repo stacks such as `config/gap3/default.nix` or
  `config/abird/stacks/abird.nix` from package definitions.
- Root flake builds remain the decisive validation path for repo packages while
  the shared helper imports still reach upward by relative path.

## New project guidance

- Prefer making package `default.nix` parameterized instead of letting it
  discover repo-global paths internally.
- Pass shared helpers, source roots, lockfiles, and service defaults from the
  caller. Host-owned module evaluation should use the current injected `stack`;
  standalone package evaluation can use the generic package stack. This keeps
  the package ready for a future isolated flake boundary.
- Do not introduce new hard-coded upward imports beyond the current established
  helper pattern when a parameter can express the dependency clearly.
- If a package needs service-module defaults, keep the dependency on the service
  stack explicit. The package should not know whether the caller provides the
  real gap3 stack or a stub standalone stack.

## Desired future shape

- `lib/flake` becomes its own standalone flake input that exports generic
  package helpers and service-module factories.
- Repo-specific service defaults live in explicit family configuration under
  `config/<family>/`, such as `config/gap3/default.nix` and
  `config/abird/stacks/abird.nix`, that point at real `data/secrets/**` paths.
- The generic `lib/flake` stack provides stub secret paths so isolated package
  flakes can evaluate and build without the repo's real secret tree.
- Child package flakes depend on the standalone `lib/flake` input for helpers,
  not on the whole monorepo, unless the package intentionally needs monorepo
  source such as the root Cargo workspace.

## Migration guardrails

- Do not break current root-flake builds while preparing for isolated package
  flakes.
- Move one boundary at a time: first make package arguments explicit, then split
  the generic helper flake, then migrate child flakes to consume it.
- Keep secrets absent by default in isolated mode. Missing fake cert or key
  files should mean no managed age secret is emitted, not an evaluation failure.
- Keep repo mode efficient. When the monorepo root supplies a shared source tree
  or lockfile, packages should continue using that shared build input.
