{
  description = "hello-rust sample app";

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
      build = pkgs.rustPlatform.buildRustPackage {
        pname = "hello-rust";
        version = "0.1.0";
        src = ./.;
        cargoLock.lockFile = ./Cargo.lock;
      };
      run = {
        type = "app";
        program = "${build}/bin/hello-rust";
      };
    in {
      packages = {
        default = build;
        build = build;
        run = build;
      };
      apps = {
        default = run;
        run = run;
      };
    });
}
