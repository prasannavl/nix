{
  pkgs ? import <nixpkgs> {},
  stack ? import ../../../lib/flake/stack/package.nix,
}: let
  s = stack;
  pkg = s.pkg;
  srv = s.srv;
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
in
  pkg.wirePassthru
  (pkg.mkPythonDerivation {
    inherit pkgs;
    build = build;
  })
  {
    nixosModule = srv.mkModule {};
  }
