{
  pkgs,
  ab,
}: let
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
  ab.package.wire
  (ab.build.python {
    inherit pkgs;
    build = build;
  })
  {
    nixosModule = ab.nixos.service {};
  }
