# Pure FILE evaluation; arguments are explicit, already cached source paths.
{
  pkgsPath,
  cranePath,
  srcPath,
  system ? "x86_64-linux",
}: let
  inputs.crane.mkLib = pkgs: import cranePath {pkgs = pkgs;};
  toolchain = import ../toolchain.nix {inputs = inputs;};
  pkgs = import pkgsPath {
    inherit system;
    overlays = [toolchain.overlay];
  };
  replay = import ./freshness.nix {
    inherit pkgs;
    src = srcPath;
  };
in
  replay.manifest
