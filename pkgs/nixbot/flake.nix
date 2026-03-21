{
  description = "nixbot deploy wrapper package";

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
      run = pkgs.callPackage ./default.nix {};
    in {
      packages = {
        inherit run;
        default = run;
        build = run;
      };
      apps = {
        default = {
          type = "app";
          program = "${run}/bin/nixbot";
        };
        run = {
          type = "app";
          program = "${run}/bin/nixbot";
        };
      };
    });
}
