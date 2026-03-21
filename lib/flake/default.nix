let
  appsFn = import ./apps.nix;
  lintFn = import ./lint.nix;
  packagesFn = import ./packages.nix;
in rec {
  apps = appsFn;
  lint = lintFn;
  packages = packagesFn;

  withPkgs = pkgs: let
    lint = lintFn {inherit pkgs;};
    packages = packagesFn {
      inherit pkgs lint;
    };
    apps = appsFn {
      packageSet = packages;
      inherit lint;
    };
  in {
    inherit apps lint packages;
    inherit (lint) formatter;
  };

  nixosModules = {
    podmanCompose = import ./podman.nix;
    systemdUserManager = import ./systemd-user-manager.nix;
  };
}
