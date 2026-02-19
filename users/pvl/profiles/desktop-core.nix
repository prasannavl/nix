let
  modules =
    (import ./core.nix).modules
    ++ [
      ../zoxide
      ../fzf
      ../firefox
      ../gtk
      ../sway
    ];
in {
  inherit modules;
  default = import ../default.nix {inherit modules;};
}
