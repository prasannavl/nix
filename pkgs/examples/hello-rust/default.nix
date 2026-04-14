{
  pkgs ? import <nixpkgs> {},
  s ? import ../../../lib/flake/stack.nix,
}: let
  pkg = s.pkg;
  srv = s.srv;
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
