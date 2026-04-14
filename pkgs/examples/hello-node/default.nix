{
  pkgs ? import <nixpkgs> {},
  stack ? import ../../../lib/flake/stack.nix,
}: let
  pkg = stack.pkg;
  srv = stack.srv;
  build = pkgs.buildNpmPackage {
    pname = "hello-node";
    version = "0.1.0";

    src = ./.;
    forceEmptyCache = true;
    npmDepsHash = "sha256-eoKSuzf4RFczkr6v1RZo+HyId3HWz5PIRnlJBTgJjHA=";
    dontNpmBuild = true;

    meta = {
      description = "Hello world Node.js example";
      mainProgram = "hello-node";
    };
  };
  drv =
    pkg.wirePassthru
    (pkg.mkWebDerivation {
      inherit pkgs;
      build = build;
      lintParts = [
        (pkg.projectLintBiome pkgs {})
        {
          inputs = [pkgs.nodejs];
          commands = ["node --check index.js"];
        }
      ];
    })
    {
      nixosModule = srv.mkModule {};
    };
in
  drv
