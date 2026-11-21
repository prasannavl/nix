{
  abCoreSource,
  nixpkgsPath,
  system,
}: let
  pkgs = import nixpkgsPath {inherit system;};
  core = import abCoreSource;
  ab = core.mk {inherit pkgs;};
  package = pkgs.callPackage ./package.nix {inherit ab;};
  nixosModule = (ab.flake.modules {build = package;}).default;
  evaluated = import (nixpkgsPath + "/nixos/lib/eval-config.nix") {
    inherit pkgs system;
    specialArgs.abNixosUser = null;
    modules = [
      nixosModule
      {
        system.stateVersion = "26.05";
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "/dev/null";
          fsType = "ext4";
        };
        services.external-core-python.enable = true;
      }
    ];
  };
in {
  inherit ab core package pkgs;

  outputs = {
    packages.default = package;
    nixosModules.default = nixosModule;
  };

  moduleProbe = {
    package = evaluated.config.services.external-core-python.package;
    execStart = evaluated.config.systemd.services.external-core-python.serviceConfig.ExecStart;
    registeredUnits = evaluated.config._ab.nixos.registeredUnits;
  };
}
