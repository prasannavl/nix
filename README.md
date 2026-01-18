# NixOS Config

This repo contains my NixOS and Home Manager configuration, organized as small
modules and composed via `flake.nix`.

## Layout

- `flake.nix`: flake inputs and system definition.
- `hosts/<host>/default.nix`: host-specific system definition and module imports.
- `hosts/<host>/sys.nix`: host-local overrides and hardware quirks.
- `users/pvl/home.nix`: Home Manager configuration for user `pvl`.
- `lib/*.nix`: single-topic NixOS modules imported directly by hosts.
- `lib/devices/`: full device modules; compose `lib/hardware/` pieces.
- `lib/hardware/`: hardware fragments, used only from `lib/devices/` (hosts should
  not import these directly).
- `lib/profiles/`: profile bundles that group common module sets for hosts.
- `overlays/`: custom overlays used by the system.
- `pkgs/`: local package definitions (if any).

## Usage

- Apply the system:
  - `sudo nixos-rebuild switch --flake .#pvl-a1`
  - `sudo nixos-rebuild switch --flake .#pvl-x2`
- Update inputs:
  - `nix flake update`

## Notes

- User settings are managed via under `users/` and also use home manager with 
  `home.nix` and self organized modules.
