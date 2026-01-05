final: prev: {
  gnomeExtensions = prev.gnomeExtensions // {
    p7-borders = prev.callPackage ./pkgs/p7-borders.nix { };
    p7-commands = prev.callPackage ./pkgs/p7-cmds.nix { };
  };
}
