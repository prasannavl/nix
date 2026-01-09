{
  config,
  pkgs,
  lib,
  ...
}: let
  userdata = import ./modules/userdata.nix;
in {
  home-manager.useGlobalPkgs = true;
  home-manager.backupFileExtension = "hm.backup";
  home-manager.users.pvl = {config, ...}: let
    mods = import ./modules {
      lib = lib;
      pkgs = pkgs;
      config = config;
      userdata = userdata;
      modules = [
        ./modules/gnome-extensions/appindicator.nix
        ./modules/gnome-extensions/auto-move-windows.nix
        ./modules/gnome-extensions/bluetooth-quick-connect.nix
        ./modules/gnome-extensions/brightness-control-using-ddcutil.nix
        ./modules/gnome-extensions/caffeine.nix
        ./modules/gnome-extensions/clipboard-indicator.nix
        ./modules/gnome-extensions/dash-to-panel.nix
        ./modules/gnome-extensions/gsconnect.nix
        ./modules/gnome-extensions/impatience.nix
        ./modules/gnome-extensions/native-window-placement.nix
        ./modules/gnome-extensions/p7-borders.nix
        ./modules/gnome-extensions/p7-cmds.nix
        ./modules/gnome-extensions/windownavigator.nix
        ./modules/gnome-extensions/workspace-indicator.nix
        ./modules/gnome-keybindings.nix
        ./modules/gnome-shell-favorites.nix
        ./modules/gnome-clocks-weather.nix
        ./modules/gnome-wallpaper.nix
      ];
    };
    gvariant = lib.gvariant;
  in {
    xdg = {
      enable = true;
      userDirs = {
        enable = true;
        createDirectories = true;
      };
    };

    home.packages = with pkgs;
      [
        atool
      ]
      ++ mods.homePackages;
    programs =
      {
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
        git = {
          enable = true;
          settings = {
            user = {
              name = userdata.pvl.name;
              email = userdata.pvl.email;
              signingKey = userdata.pvl.sshKey;
            };
            commit.gpgSign = true;
            gpg.format = "ssh";
            core.autocrlf = "input";

            grep = {
              extendRegexp = true;
              lineNumber = true;
            };

            merge.conflictstyle = "diff3";
            push.autoSetupRemote = true;

            alias = {
              l = "log --oneline";
              log-full = "log --pretty=format:\"%h%x09%an%x09%ad%x09%s\"";
            };
          };

          lfs.enable = true;
          ignores = [
            ".DS_Store"
            "result"
          ];
        };
        ranger = {
          enable = true;
          extraConfig = ''
            set preview_images true
            set preview_images_method kitty
          '';
        };
      }
      // mods.programs;
    services = mods.services;

    dconf = {
      enable = true;
      settings =
        {
          "org/gnome/shell" = {
            disable-user-extensions = false;
            enabled-extensions = lib.unique mods.gnomeShellExtensions;
            disabled-extensions = [];
            favorite-apps = mods.gnomeFavoriteApps;
          };

          "org/gnome/settings-daemon/plugins/power" = {
            sleep-inactive-ac-type = "nothing";
          };

          "org/gnome/desktop/session" = {
            # Idle timeout (seconds)
            idle-delay = gvariant.mkUint32 480;
          };

          "org/gnome/desktop/wm/preferences" = {
            "button-layout" = ":minimize,maximize,close";
          };
          "org/gnome/desktop/sound" = {
            allow-volume-above-100-percent = true;
          };
          "org/gnome/desktop/a11y" = {
            always-show-universal-access-status = true;
          };
          "org/gnome/desktop/remote-desktop/rdp" = {
            enable = true;
            view-only = false;
          };

          "org/gnome/desktop/interface" = {
            color-scheme = "prefer-dark";
            # accent-color = "blue";
            clock-format = "12h";
            clock-show-seconds = true;
            clock-show-weekday = true;
            # enable-animations = true;
            # enable-hot-corners = true;
            # overlay-scrolling = true;
            show-battery-percentage = true;
          };

          "org/gnome/desktop/calendar" = {
            show-weekdate = true;
          };

          # "org/gnome/Console" = {
          # 	shell = [ "tmux" ];
          # };
        }
        // mods.dconfSettings;
    };

    home.file =
      {
        # ".config/containers/storage.conf".text = ''
        # 	[storage]
        # 	driver = "overlay"

        # 	[storage.options]
        # 	mount_program = "${pkgs.fuse-overlayfs}/bin/fuse-overlayfs"
        # '';

        ".config/chrome-flags.conf".text = ''
          --disable-smooth-scrolling
        '';
      }
      // mods.homeFiles;

    # The state version is required and should stay at the version you
    # originally installed.
    home.stateVersion = "25.11";
  };
}
