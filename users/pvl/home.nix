{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  userdata = (import ../userdata.nix).pvl;
in {
  _module.args = {inherit userdata;};

  imports = [
    inputs.noctalia.homeModules.default
    ./bash
    ./gnome
    ./git
    ./firefox
    ./inputrc
    ./gtk
    ./ranger
    ./tmux
    ./neovim
    ./sway
  ];

  home.preferXdgDirectories = true;
  
  xdg = {
    enable = true;
    userDirs = {
      enable = true;
      createDirectories = true;
    };
  };

  home.packages = with pkgs; [
    atool
  ];

  home.file = {
    # ".config/containers/storage.conf".text = ''
    #   [storage]
    #   driver = "overlay"
    #
    #   [storage.options]
    #   mount_program = "${pkgs.fuse-overlayfs}/bin/fuse-overlayfs"
    # '';
    ".config/chrome-flags.conf".text = ''
      --disable-smooth-scrolling
    '';
  };

  # The state version is required and should stay at the version you
  # originally installed.
  home.stateVersion = "25.11";
}
