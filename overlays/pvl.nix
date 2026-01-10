{inputs}: final: prev: let
  system = final.stdenv.hostPlatform.system;
  p7Borders = inputs.p7-borders.packages.${system}.p7-borders;
  # p7Borders = prev.callPackage ../pkgs/p7-borders.nix { };
  p7Cmds = inputs.p7-cmds.packages.${system}.p7-cmds;
  # p7Cmds = prev.callPackage ../pkgs/p7-cmds.nix { };
in rec {
  pvl = {
    gnomeExtensions = {
      p7-borders = p7Borders;
      p7-cmds = p7Cmds;
    };
  };

  gnomeExtensions =
    prev.gnomeExtensions
    // pvl.gnomeExtensions;
}
