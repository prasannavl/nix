let
  modules = (import ./desktop-gnome.nix).modules;
in {
  inherit modules;
  default = import ../default.nix {inherit modules;};
}
