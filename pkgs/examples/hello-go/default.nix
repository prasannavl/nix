{
  pkgs ? import <nixpkgs> {},
  gap3 ? import ../../../lib/flake/gap3.nix,
}: let
  pkg = gap3.pkg;
  srv = gap3.srv;
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
  drv =
    pkg.wirePassthru
    (pkg.mkGoDerivation {
      inherit pkgs;
      build = build;
    })
    {
      nixosModule = srv.mkModule {};
    };
in
  drv
