let
  mkModule = modules: {accounts, ...}: let
    userdata = accounts.users.pvl;
    selectedModules = map import modules;
  in {
    imports =
      map (x: x.nixos) selectedModules
      ++ [
        (import ./user.nix {inherit userdata;})
        (import ./home.nix {inherit userdata selectedModules;})
      ];
  };
in rec {
  coreModules = [
    ./bash
    ./inputrc
    ./dotfiles
    ./pi
  ];
  core = mkModule coreModules;

  devModules = [
    ./bash
    ./inputrc
    ./dotfiles
    ./neovim/dev.nix
    ./zoxide
    ./fzf
    ./firefox
    ./fonts
    ./gtk
    ./mime-apps
    ./alacritty
    ./foot
    ./kanshi
    ./wm
    ./noctalia
    ./sway
    ./niri
    ./gnome
    ./tmux
    ./git
    ./ranger
    ./vscode
    ./pi
    ./direnv
    ./xdg-user-dirs
    ./env/cargo.nix
    ./env/go.nix
  ];
  dev = mkModule devModules;

  lxcModules = [
    ./bash
    ./inputrc
    ./dotfiles
    ./neovim
    ./pi
  ];
  lxc = mkModule lxcModules;
}
