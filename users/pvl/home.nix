{
  config,
  pkgs,
  lib,
  ...
}: let
  userdata = (import ../userdata.nix).pvl;
in {
  _module.args = {inherit userdata;};

  imports = [
    ./gnome
    ./git
    ./firefox
    ./inputrc
    ./gtk
    ./ranger
    ./tmux
    ./neovim
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

  programs = {
    bash.enable = true;
  };

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
