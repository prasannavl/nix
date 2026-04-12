{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
  serviceModule ? import ../../../lib/flake/service-module.nix,
}: let
  drv =
    pkgHelper.wirePassthru
    (pkgHelper.mkWebDerivation {
      inherit pkgs;
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
      lintParts = [
        (pkgHelper.projectLintBiome pkgs {})
        {
          inputs = [pkgs.nodejs];
          commands = ["node --check index.js"];
        }
      ];
    })
    {
      nixosModule = serviceModule.mkModule {};
    };
in
  drv
