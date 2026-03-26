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
        run = run;
        default = run;
        build = run;
      };
      apps = let
        app = {
          type = "app";
          program = pkgs.lib.getExe run;
        };
      in {
        default = app;
        run = app;
      };
    });
}
