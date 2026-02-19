let
  userdata = (import ../userdata.nix).pvl;
  mkModule = modules: {...}: let
    selectedModules = map (path: import path) modules;
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
  ];
  core = mkModule coreModules;

  desktop-core-modules =
    coreModules
    ++ [
      ./zoxide
      ./fzf
      ./firefox
      ./gtk
      ./sway
    ];
  desktop-core = mkModule desktop-core-modules;

  desktop-gnome-minimal-modules =
    desktop-core-modules
    ++ [
      ./gnome
    ];
  desktop-gnome-minimal = mkModule desktop-gnome-minimal-modules;

  desktop-gnome-modules =
    desktop-gnome-minimal-modules
    ++ [
      ./tmux
      ./git
      ./ranger
      ./neovim
      ./vscode
      ./dotfiles-link-bin
      ./xdg-user-dirs
    ];
  desktop-gnome = mkModule desktop-gnome-modules;

  all-modules = desktop-gnome-modules;
  all = mkModule all-modules;

  systemd-container-modules = [
    ./bash
    ./inputrc
  ];
  systemd-container = mkModule systemd-container-modules;

  default = all;
}
