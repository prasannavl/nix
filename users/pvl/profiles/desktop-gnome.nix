let
  modules =
    (import ./desktop-gnome-minimal.nix).modules
    ++ [
      ../tmux
      ../git
      ../ranger
      ../neovim
      ../vscode
      ../dotfiles-link-bin
      ../xdg-user-dirs
    ];
in {
  inherit modules;
  default = import ../default.nix {inherit modules;};
}
