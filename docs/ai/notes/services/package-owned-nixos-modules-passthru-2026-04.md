# Package-Owned NixOS Modules via Passthru

- Date: 2026-04-13
- Scope: `pkgs/srv/*`, `lib/flake/*`, root `flake.nix`

## Decision

Package-owned service modules now live on the canonical package derivation as
`passthru.nixosModule`.

The shared helper names were simplified to singular forms:

- `mkModule`
- `mkServicesModule`
- `mkNatsService`
- `mkTcpServiceModule`
- `nixosModule`

## Rationale

- The child `flake.nix` files are DX wrappers and should not be the canonical
  source of package-owned NixOS modules.
- The package derivation is already the canonical source of truth for build
  metadata and passthru exports.
- `wirePassthru` already carries flake-facing package metadata, so `nixosModule`
  follows the existing pattern cleanly.

## Wiring

- `lib/flake/service-module.nix` now builds a single module from a package-local
  `default.nix` path instead of child-flake `self`.
- `lib/flake/pkg-helper.nix` auto-exports `passthru.nixosModule` as flake
  `nixosModules`.
- `lib/flake/default.nix` aggregates package-owned `nixosModule` passthru values
  into the root flake's `nixosModules` output.
- `flake.nix` imports those package-owned modules into the shared
  `commonModules` stack so every NixOS host can use their options without
  per-host module import boilerplate.
- Each `pkgs/srv/*/default.nix` that owns a service module attaches it directly
  to the package derivation.

## Result

Hosts can now import package-owned service modules from the root flake through
`inputs.self.nixosModules.<service-name>` without depending on child flake
wrapper-local module definitions.
