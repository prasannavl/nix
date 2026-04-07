{pkgs ? import <nixpkgs> {}}: let
  pkgHelper = import ../../lib/flake/pkg-helper.nix;
  drv = pkgHelper.mkRustDerivation {
    inherit pkgs;
    src = ./.;
    build = pkgs.rustPlatform.buildRustPackage {
      pname = "hello-rust";
      version = "0.1.0";
      src = ./.;
      cargoLock.lockFile = ./Cargo.lock;
      meta = {
        description = "Hello world Rust example";
        mainProgram = "hello-rust";
      };
    };
  };
in
  drv
