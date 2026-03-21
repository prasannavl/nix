# `lib/flake` Published Podman/Systemd Modules (2026-03)

- Moved `lib/podman.nix` to `lib/flake/podman.nix`.
- Moved `lib/systemd-user-manager.nix` to `lib/flake/systemd-user-manager.nix`.
- Exported both from `lib/flake/default.nix` under `nixosModules` so the root
  flake can publish them directly.
- Exported `nixosModules` from the root `flake.nix` with names: `podmanCompose`
  and `systemdUserManager`.
- Updated in-repo hosts that consumed the old path to import
  `../../lib/flake/podman.nix`.
- `lib/flake/podman.nix` keeps its local import of `./systemd-user-manager.nix`,
  so the module remains standalone when consumed from the published flake
  output.
