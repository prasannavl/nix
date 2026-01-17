# NixOS Config

This repo contains my NixOS and Home Manager configuration, organized as small
modules and composed via `flake.nix`.

## Layout

- `flake.nix`: flake inputs and system definition.
- `hosts/pvl-a1/nix.nix`: shared Nix settings (caches, GC, allowUnfree).
- `hosts/<host>/default.nix`: host-specific configuration.
- `hosts/pvl-a1/sys.nix`: hardware module for pvl-a1.
- `users/pvl/home.nix`: Home Manager configuration for user `pvl`.
- `hosts/pvl-a1/boot.nix`, `hardware/`, `hosts/pvl-a1/network.nix`, `hosts/pvl-a1/services.nix`,
  `hosts/pvl-a1/programs.nix`, `hosts/pvl-a1/packages.nix`, `hosts/pvl-a1/security.nix`,
  `hosts/pvl-a1/users.nix`, `hosts/pvl-a1/swap.nix`, `hosts/pvl-a1/locale.nix`,
  `hosts/pvl-a1/misc.nix`, `hosts/pvl-a1/gnome.nix`:
  topic-specific NixOS modules imported by `hosts/pvl-a1/config.nix`.
- `modules/`: Home Manager helper modules (GNOME extensions, dconf, files).
- `overlays/`: custom overlays used by the system.
- `pkgs/`: local package definitions (if any).

## Usage

- Apply the system:
  - `sudo nixos-rebuild switch --flake .#pvl-a1`
  - `sudo nixos-rebuild switch --flake .#pvl-x2`
- Update inputs:
  - `nix flake update`

## Notes

- GNOME settings and extensions are managed via Home Manager under `home.nix`
  and `modules/`.
