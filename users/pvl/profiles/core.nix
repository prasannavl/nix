let
  modules = [
    ../bash
    ../inputrc
    ../dotfiles
  ];
in {
  inherit modules;
  default = import ../default.nix {inherit modules;};
}
