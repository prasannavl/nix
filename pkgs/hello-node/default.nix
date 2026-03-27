{pkgs ? import <nixpkgs> {}}:
pkgs.buildNpmPackage {
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
}
