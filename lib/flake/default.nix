{
  flakeTree = import ./flake-tree.nix;
  lint = import ./lint.nix;
  nixosModules = {
    podmanCompose = import ./podman.nix;
    systemdUserManager = import ./systemd-user-manager.nix;
  };
}
