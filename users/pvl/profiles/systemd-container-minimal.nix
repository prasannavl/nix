let
  modules = [
    ../bash
    ../inputrc
  ];
in {
  inherit modules;
  default = import ../default.nix {inherit modules;};
}
