{
  description = "hello-python sample app";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    nixpkgs,
    flake-utils,
    ...
  }: let
    defaultSystem = builtins.head flake-utils.lib.defaultSystems;
    defaultPkgs = nixpkgs.legacyPackages.${defaultSystem};
    pkgHelper = import ../../../lib/flake/pkg-helper.nix;
    mkOutputs = pkgs: let
      drv = pkgs.callPackage ./default.nix {};
    in {
      flakeOutputs = pkgHelper.mkStdFlakeOutputs {
        pkgs = pkgs;
        build = drv;
        devShell = drv.devShell;
      };
      nixosModules = pkgHelper.mkNixosModuleAttrs {
        build = drv;
      };
    };
    defaultOutputs = mkOutputs defaultPkgs;
  in
    flake-utils.lib.eachDefaultSystem (system:
      (mkOutputs nixpkgs.legacyPackages.${system}).flakeOutputs)
    // {
      nixosModules = defaultOutputs.nixosModules;
    };
}
