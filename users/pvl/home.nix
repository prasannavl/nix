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
    ./gnome/gnome-extensions.nix
    ./gnome/gnome-dconf.nix
    ./gnome/gnome-keybindings.nix
    ./gnome/gnome-shell-favorites.nix
    ./gnome/gnome-clocks-weather.nix
    (import ./gnome/gnome-wallpaper.nix {
      wallpaperUri = "file://${config.home.homeDirectory}/src/dotfiles/x/files/backgrounds/sw.png";
    })
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
