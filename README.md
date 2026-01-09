# NixOS Config

This repo contains my NixOS and Home Manager configuration, organized as small
modules and composed via `flake.nix`.

## Layout

- `flake.nix`: flake inputs and system definition.
- `config.nix`: root system configuration and module imports.
- `home.nix`: Home Manager configuration for user `pvl`.
- `boot.nix`, `hardware.nix`, `network.nix`, `services.nix`, `programs.nix`,
  `packages.nix`, `security.nix`, `users.nix`, `swap.nix`, `locale.nix`,
  `misc.nix`, `gnome.nix`: topic-specific NixOS modules imported by `config.nix`.
- `modules/`: Home Manager helper modules (GNOME extensions, dconf, files).
- `overlays/`: custom overlays used by the system.
- `pkgs/`: local package definitions (if any).

## Usage

- Apply the system:
  - `sudo nixos-rebuild switch --flake .#pvl-a1`
- Update inputs:
  - `nix flake update`

## Notes

- GNOME settings and extensions are managed via Home Manager under `home.nix`
  and `modules/`.
