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

  desktopCoreModules =
    coreModules
    ++ [
      ./zoxide
      ./fzf
      ./firefox
      ./gtk
      ./sway
    ];
  desktopCore = mkModule desktopCoreModules;

  desktopGnomeMinimalModules =
    desktopCoreModules
    ++ [
      ./gnome
    ];
  desktopGnomeMinimal = mkModule desktopGnomeMinimalModules;

  desktopGnomeModules =
    desktopGnomeMinimalModules
    ++ [
      ./tmux
      ./git
      ./ranger
      ./neovim
      ./vscode
      ./dotfiles-link-bin
      ./xdg-user-dirs
    ];
  desktopGnome = mkModule desktopGnomeModules;

  allModules = desktopGnomeModules;
  all = mkModule allModules;

  systemdContainerMinimalModules = [
    ./bash
    ./inputrc
  ];
  systemdContainerMinimal = mkModule systemdContainerMinimalModules;

  default = all;
}
