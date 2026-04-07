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
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      pkgHelper = import ../../../lib/flake/pkg-helper.nix;
      drv = pkgs.callPackage ./default.nix {};
    in
      pkgHelper.mkStdFlakeOutputs {
        pkgs = pkgs;
        build = drv;
        devShell = drv.devShell;
      });
}
