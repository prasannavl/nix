{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
  serviceModule ? import ../../../lib/flake/service-module.nix,
}: let
  drv =
    pkgHelper.wirePassthru
    (pkgHelper.mkRustDerivation {
      inherit pkgs;
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
    })
    {
      nixosModule = serviceModule.mkModule {};
    };
in
  drv
