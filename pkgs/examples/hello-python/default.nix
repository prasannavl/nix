{
  pkgs ? import <nixpkgs> {},
  stack ? import ../../../lib/flake/stack.nix,
}: let
  pkg = stack.pkg;
  srv = stack.srv;
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
  drv =
    pkg.wirePassthru
    (pkg.mkPythonDerivation {
      inherit pkgs;
      build = build;
    })
    {
      nixosModule = srv.mkModule {};
    };
in
  drv
