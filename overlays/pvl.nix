{inputs}: final: prev: let
  system = final.stdenv.hostPlatform.system;
  # p7-borders = inputs.p7-borders.packages.${system}.p7-borders;
  p7-borders = final.callPackage ../pkgs/p7-borders.nix {};
  # p7-cmds = inputs.p7-cmds.packages.${system}.p7-cmds;
  p7-cmds = final.callPackage ../pkgs/p7-cmds.nix {};
in rec {
  pvl.gnomeExtensions = {
    inherit p7-borders p7-cmds;
  };

  gnomeExtensions =
    prev.gnomeExtensions
    // pvl.gnomeExtensions;
}
