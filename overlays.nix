{ inputs }:
final: prev: {
  gnomeExtensions = prev.gnomeExtensions // {
    # p7-commands = prev.callPackage ./pkgs/p7-borders.nix { };
    p7-borders = inputs.p7-borders.packages.${final.stdenv.hostPlatform.system}.p7-borders;
    p7-cmds = prev.callPackage ./pkgs/p7-cmds.nix { };
    # p7-cmds = inputs.p7-cmds.packages.${final.stdenv.hostPlatform.system}.p7-cmds;
  };
}
