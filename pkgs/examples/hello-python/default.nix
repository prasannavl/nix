{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
  serviceModule ? import ../../../lib/flake/service-module.nix,
}: let
  drv =
    pkgHelper.wirePassthru
    (pkgHelper.mkPythonDerivation {
      inherit pkgs;
      build = pkgs.python3Packages.buildPythonApplication {
        pname = "hello-python";
        version = "0.1.0";
        pyproject = true;

        src = ./.;

        build-system = [
          pkgs.python3Packages.hatchling
        ];

        meta = {
          description = "Hello world Python example built from a pyproject package";
          mainProgram = "hello-python";
        };
      };
    })
    {
      nixosModule = serviceModule.mkModule {};
    };
in
  drv
