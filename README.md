# NixOS Config

This repo contains my NixOS and Home Manager configuration, organized as small
modules and composed via `flake.nix`.

## Layout

- `flake.nix`: flake inputs and system definition.
- `config.nix`: root system configuration and module imports.
- `home.nix`: Home Manager configuration for user `pvl`.
- `modules/`: Home Manager helper modules (GNOME extensions, dconf, files).
- `pkgs/`: local package definitions (if any).
- `overlays.nix`: custom overlays used by the system.

## Usage

- Apply the system:
  - `sudo nixos-rebuild switch --flake .#pvl-a1`
- Update inputs:
  - `nix flake update`

## Notes

- GNOME settings and extensions are managed via Home Manager under `home.nix`
  and `modules/`.
