# Package Architecture

## Scope

Canonical package and child-flake rules for `pkgs/`, root flake exports, shared
helpers under `lib/flake`, package-owned NixOS modules, and repo-local service
stack wiring.

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
- `lib/flake/service-module.nix` exposes the generic `mkServiceLib` factory for
  service modules, transport helpers, and client-identity wiring.
- `lib/flake/stack.nix` is the repo-local instantiation of that factory. It owns
  repo defaults such as secret roots, identity suffixes, transport defaults, and
  default user-service ownership.
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
- Repo-local package and host call sites should import the repo stack and use
  `stack.pkg` or `stack.srv` rather than re-encoding repo defaults directly
  against the generic factory.

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
- Repo-root Rust is workspace-oriented: keep the root `Cargo.toml` member list
  explicit, keep the root `Cargo.lock` canonical, and have workspace packages
  pass `projectDir` into `mkRustDerivation` instead of open-coding package-local
  `src = ./.` builds.

## Package layout

- `pkgs/examples/` is the home for sample projects. Root exports should prefix
  those package names with `example-`.
- Nested package directories under `pkgs/` are acceptable. Keep root flake IDs
  flat and explicit in the manifest.
- Non-package helper derivations consumed directly by overlays or scripts belong
  outside `pkgs/`; see `lib/ext/` for that pattern.

## Package-owned modules

- Package-owned NixOS modules belong on the canonical package derivation as
  `passthru.nixosModule`, not only in child-flake wrappers.
- `pkgHelper.mkNixosModuleAttrs` is the canonical bridge from package passthru
  to flake `nixosModules`, including any `passthru.flakeExtraNixosModules`.
- The root flake imports package-owned modules into the shared NixOS module
  stack for every host, so exported modules must stay safe to evaluate
  everywhere.
- Bound module factories must resolve their package from the consuming host's
  `pkgs` and `system`, not from the flake-evaluation system that exported the
  module.
- `mkNixosSystem` in `lib/flake/default.nix` is the canonical place that passes
  `inputs` and `system` special args needed by those package-owned modules.
- Derivation-backed identity helpers that export `age.secrets` fragments must
  gate those fragments on whether the owning package is present in
  `config.environment.systemPackages`.

## Service module helpers

- Repeated service-module boilerplate belongs in `lib/flake/service-module.nix`.
- `mkServicesModule` owns the standard service split:
  - `services.<name>.enable`
  - `services.<name>.package`
  - `systemd.services.<name>` when the resolved user is `root`
  - `userServices.<user>.<name>` plus `systemd-user-manager` registration when
    the resolved user is non-root
- Generated user-service modules should materialize both:
  - `systemd.user.services.<unit>`
  - `services.systemdUserManager.instances.<user>-<name>`
- Prefer direct systemd wiring fields such as `after`, `before`, `wants`,
  `requires`, and `wantedBy` instead of repo-specific dependency abstractions.
- `mkTcpServiceModule` extends that model with listener address and port options
  when the binary consumes them via environment variables.
- Transport helpers such as `mkPostgresClientService` and `mkNatsClientService`
  should provide environment wiring and default ordering hints only. Callers
  should still tolerate missing or unhealthy upstreams at runtime rather than
  encoding hard infra assumptions into the helper layer.

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
- `lib/flake/stack.nix`
- `pkgs/*/default.nix`
- `pkgs/*/flake.nix`

## Superseded notes

- `docs/ai/notes/lib/service-lib-gap3-instantiation-2026-04.md`
- `docs/ai/notes/lib/package-client-identity-installed-package-gating-2026-04.md`
- `docs/ai/notes/lib/flake-system-specific-host-modules-2026-04.md`
- `docs/ai/notes/services/package-owned-nixos-modules-passthru-2026-04.md`
- `docs/ai/notes/services/package-user-services-gap3-2026-04.md`

## Provenance

- This note replaces the earlier dated package-architecture, package-layout,
  package-owned-module, service-lib-instantiation, client-identity-gating, and
  package-user-service notes from March and April 2026.
