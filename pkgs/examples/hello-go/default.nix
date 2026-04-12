{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
  serviceModule ? import ../../../lib/flake/service-module.nix,
}: let
  drv =
    pkgHelper.wirePassthru
    (pkgHelper.mkGoDerivation {
      inherit pkgs;
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
    })
    {
      nixosModule = serviceModule.mkModule {};
    };
in
  drv
