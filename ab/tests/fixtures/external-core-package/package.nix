{
  ab,
  pkgs,
}: let
  build = pkgs.python3Packages.buildPythonApplication {
    pname = "external-core-python";
    version = "0.1.0";
    pyproject = true;

    src = ./.;

    build-system = [
      pkgs.python3Packages.hatchling
    ];

    meta = {
      description = "External ab-core Python fixture";
      mainProgram = "external-core-python";
    };
  };
in
  ab.package.wire
  (ab.build.python {
    inherit build pkgs;
  })
  {
    nixosModule = ab.nixos.service {
      sourcePath = ./package.nix;
      serviceDescription = "External ab-core Python fixture";
    };
  }
