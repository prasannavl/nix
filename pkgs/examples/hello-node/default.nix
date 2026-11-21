{
  pkgs,
  ab,
}: let
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
in
  ab.package.wire
  (ab.build.web {
    inherit pkgs;
    build = build;
    lintParts = [
      (ab.tasks.node.projectLint pkgs {})
      {
        inputs = [pkgs.nodejs];
        commands = ["node --check index.js"];
      }
    ];
  })
  {
    nixosModule = ab.nixos.service {};
  }
