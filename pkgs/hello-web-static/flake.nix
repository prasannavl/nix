{
  description = "hello-web-static sample app";

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
      build = pkgs.callPackage ./default.nix {};
    in {
      packages = {
        default = build;
        build = build;
      };

      checks = {
        build = build;
      };

      devShells.default = pkgs.mkShell {
        packages = [
          pkgs.python3
        ];
      };
    });
}
