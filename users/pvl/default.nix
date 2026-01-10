{
  config,
  pkgs,
  lib,
  ...
}: let
  userdata = (import ../userdata.nix).pvl;
  username = userdata.username;
in {
  users.groups.pvl = {
    gid = userdata.uid;
  };

  users.users.pvl = {
    isNormalUser = true;
    description = userdata.name;
    uid = userdata.uid;
    group = username;
    hashedPassword = userdata.hashedPassword;
    extraGroups = ["users" "networkmanager" "wheel" "tss" "seat" "i2c" "incus-admin" "podman" "keyd"];
    openssh.authorizedKeys.keys = [userdata.sshKey];
    packages = with pkgs; [];

    # For distrobox, podman, flatpak, etc
    # subUidRanges = [ { startUid = 100000; count = 65536; } ];
    # subGidRanges = [ { startGid = 100000; count = 65536; } ];
  };

  home-manager.users.pvl = { config, ... }: {
    _module.args = {inherit userdata;};

    imports = [
      ./gnome-extensions/appindicator.nix
      ./gnome-extensions/auto-move-windows.nix
      ./gnome-extensions/bluetooth-quick-connect.nix
      ./gnome-extensions/brightness-control-using-ddcutil.nix
      ./gnome-extensions/caffeine.nix
      ./gnome-extensions/clipboard-indicator.nix
      ./gnome-extensions/dash-to-panel.nix
      ./gnome-extensions/gsconnect.nix
      ./gnome-extensions/impatience.nix
      ./gnome-extensions/native-window-placement.nix
      ./gnome-extensions/p7-borders.nix
      ./gnome-extensions/p7-cmds.nix
      ./gnome-extensions/windownavigator.nix
      ./gnome-extensions/workspace-indicator.nix
      ./gnome-dconf.nix
      ./gnome-keybindings.nix
      ./gnome-shell-favorites.nix
      ./gnome-clocks-weather.nix
      (import ./gnome-wallpaper.nix {
        wallpaperUri = "file://${config.home.homeDirectory}/src/dotfiles/x/files/backgrounds/sw.png";
      })
      ./programs-git.nix
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
  };
}
