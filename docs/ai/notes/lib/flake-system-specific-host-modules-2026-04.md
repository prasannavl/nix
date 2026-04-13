# Flake Host Modules Must Resolve Per Target System

- Date: 2026-04-13
- Scope: `flake.nix`, `hosts/default.nix`, `lib/images/default.nix`

## Decision

Package-owned NixOS modules must resolve their package from the consuming host's
`system` and `inputs.nixpkgs`, not from the flake system that exported the
module.

## Rationale

- The repo's package-owned `nixosModule` exports are currently bound to concrete
  package derivations.
- Importing a module that captures one flake system's derivation causes host
  builds on other systems to inherit the wrong package platform.
- `flake-utils.lib.defaultSystems` ordering is not a safe selector for NixOS
  module binding. In this repo it currently starts with `aarch64-darwin`, which
  caused Linux hosts to try to build Darwin Rust crates.

## Applied shape

- `lib/flake/service-module.nix` now returns system-agnostic module functions
  when `package` is omitted. Those module functions resolve the package from
  `inputs.nixpkgs.legacyPackages.${system}.callPackage sourcePath {}` supplied
  through host/image `specialArgs`.
- `lib/flake/pkg-helper.nix` binds package-owned modules through that factory,
  so the exported module no longer captures the flake-evaluation derivation.
- `lib/flake/default.nix` provides `mkNixosSystem` to inject the required
  `inputs` and `system` special args while keeping host/image declaration files
  minimal.
- The root flake exports a standard flat `nixosModules` attrset again because
  the module bodies now resolve packages against the consuming host platform.
