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
    ./inputrc
    ./tmux
  ];

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
    firefox = {
      enable = true;
      profiles = {
        default = {
          settings = {
            "general.smoothScroll" = false;
          };
        };
      };
    };
    ranger = {
      enable = true;
      extraConfig = ''
        set preview_images true
        set preview_images_method kitty
        set wrap_scroll true
        set preview_files true
        set preview_directories true
        set use_preview_script true
        set draw_borders both
        default_linemode sizemtime
        set cd_tab_fuzzy true
      '';
    };
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
