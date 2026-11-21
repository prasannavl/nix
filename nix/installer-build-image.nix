{
  repoRoot,
  specFile,
}: let
  ab = import ../ab;
  flake = ab.repo.flake.self {repoRoot = repoRoot;};
  installer = import ./installer.nix {inherit repoRoot;};
in
  ab.system.installer.buildImage {
    inherit flake specFile;
    moduleFor = installer.moduleFor;
  }
