{
  pkgs ? import <nixpkgs> {},
  gap3 ? import ../../../lib/flake/gap3.nix,
}: let
  pkg = gap3.pkg;
  srv = gap3.srv;
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
  drv =
    pkg.wirePassthru
    (pkg.mkRustDerivation {
      inherit pkgs;
      build = build;
    })
    {
      nixosModule = srv.mkModule {};
    };
in
  drv
