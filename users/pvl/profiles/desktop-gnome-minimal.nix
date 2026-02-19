let
  modules =
    (import ./desktop-core.nix).modules
    ++ [
      ../gnome
    ];
in {
  inherit modules;
  default = import ../default.nix {inherit modules;};
}
