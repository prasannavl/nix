{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
}: let
  devShell = pkgs.mkShell {
    packages = [
      pkgs.cargo
      pkgs.rust-analyzer
      pkgs.rustc
    ];
  };

  drv =
    pkgHelper.wirePassthru
    (pkgHelper.mkRustDerivation {
      inherit pkgs;
      checkCargoArgs = ["--locked"];
      testCargoArgs = ["--locked"];
      lintFixCargoArgs = ["--locked"];
      build = pkgs.rustPlatform.buildRustPackage {
        pname = "srv-ingest";
        version = "0.1.0";
        src = ./.;
        cargoLock.lockFile = ./Cargo.lock;

        meta = {
          description = "Ingest Service";
          mainProgram = "srv-ingest";
        };
      };
    })
    {
      devShell = devShell;
    };
in
  drv
