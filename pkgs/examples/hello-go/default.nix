{
  pkgs ? import <nixpkgs> {},
  stack ? import ../../../lib/flake/stack/package.nix,
}: let
  s = stack;
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
in
  pkg.wirePassthru
  (pkg.mkGoDerivation {
    inherit pkgs;
    build = build;
  })
  {
    nixosModule = srv.mkModule {};
  }
