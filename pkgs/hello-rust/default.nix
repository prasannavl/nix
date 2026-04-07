{pkgs ? import <nixpkgs> {}}: let
  flakeChecks = import ../../lib/flake/checks.nix;
  build = pkgs.rustPlatform.buildRustPackage {
    pname = "hello-rust";
    version = "0.1.0";
    src = ./.;
    cargoLock.lockFile = ./Cargo.lock;
    meta = {
      description = "Hello world Rust example";
      mainProgram = "hello-rust";
    };
    passthru.checks = flakeChecks.mkRustChecks {
      inherit build pkgs;
    };
  };
in
  build
