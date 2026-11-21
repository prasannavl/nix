{
  pkgs,
  ab,
}: let
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
  ab.package.wire
  (ab.build.go {
    inherit pkgs;
    build = build;
  })
  {
    nixosModule = ab.nixos.service {};
  }
