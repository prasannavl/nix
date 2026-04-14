{
  pkgs ? import <nixpkgs> {},
  s ? import ../../../lib/flake/stack.nix,
}: let
  pkg = s.pkg;
  srv = s.srv;
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
