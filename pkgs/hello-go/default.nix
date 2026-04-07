{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../lib/flake/pkg-helper.nix,
}: let
  drv = pkgHelper.mkGoDerivation {
    inherit pkgs;
    src = ./.;
    build = pkgs.buildGoModule {
      pname = "hello-go";
      version = "0.1.0";

      src = ./.;
      vendorHash = null;

      meta = {
        description = "Hello world Go example";
        mainProgram = "hello-go";
      };
    };
  };
in
  drv
