# Published Podman/Systemd Modules (2026-03)

- Reverted `lib/flake/podman.nix` back to `lib/podman.nix`.
- Reverted `lib/flake/systemd-user-manager.nix` back to
  `lib/systemd-user-manager.nix`.
- Removed the unused `nixosModules` export from `lib/flake/default.nix` and the
  root `flake.nix`; in-repo consumers import the modules by path directly.
- Updated in-repo hosts that consumed the old path to import
  `../../lib/podman.nix`.
- `lib/podman.nix` keeps its local import of `./systemd-user-manager.nix`, so
  the module remains standalone for direct path imports.
