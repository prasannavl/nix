{
  pkgs,
  lib,
  ...
}: let
  mkExtensionModule = {
    extension,
    enable ? false,
    dconf ? {},
  }: {
    home.packages = [extension];
    dconf.settings = lib.mkIf enable (lib.mkMerge [
      {
        "org/gnome/shell".enabled-extensions = lib.mkAfter [extension.extensionUuid];
      }
      dconf
    ]);
  };

  extensions = [
    {
      extension = pkgs.gnomeExtensions.appindicator;
      enable = true;
    }
    {
      extension = pkgs.gnomeExtensions.auto-move-windows;
    }
    {
      extension = pkgs.gnomeExtensions.bluetooth-quick-connect;
      enable = true;
      dconf = {
        "org/gnome/shell/extensions/bluetooth-quick-connect" = {
          keep-menu-on-toggle = true;
          refresh-button-on = true;
          show-battery-value-on = true;
        };
      };
    }
    {
      extension = pkgs.gnomeExtensions.brightness-control-using-ddcutil;
      enable = true;
      dconf = {
        "org/gnome/shell/extensions/display-brightness-ddcutil" = {
          button-location = 1;
          ddcutil-binary-path = "${pkgs.ddcutil}/bin/ddcutil";
        };
      };
    }
    {
      extension = pkgs.gnomeExtensions.caffeine;
      enable = true;
    }
    {
      extension = pkgs.gnomeExtensions.clipboard-indicator;
      enable = true;
    }
    {
      extension = pkgs.gnomeExtensions.dash-to-panel;
      enable = true;
      dconf = let
        gvariant = lib.gvariant;
        mkDict = entries: let
          names = builtins.attrNames entries;
        in
          gvariant.mkArray (map (name: gvariant.mkDictionaryEntry name entries.${name}) names);
      in {
        "org/gnome/shell/extensions/dash-to-panel" = {
          appicon-margin = 0;
          appicon-padding = 8;
          dot-style-focused = "DASHES";
          dot-style-unfocused = "DASHES";
          extension-version = 72;
          global-border-radius = 0;
          hide-overview-on-startup = true;
          hot-keys = true;
          show-favorites = true;
          animate-appicon-hover = true;
          animate-appicon-hover-animation-travel = mkDict {
            SIMPLE = 0.0;
            RIPPLE = 0.4;
            PLANK = 0.0;
          };

          animate-appicon-hover-animation-duration = mkDict {
            SIMPLE = gvariant.mkUint32 0;
            RIPPLE = gvariant.mkUint32 130;
            PLANK = gvariant.mkUint32 100;
          };
        };
      };
    }
    {
      extension = pkgs.gnomeExtensions.gsconnect;
    }
    {
      extension = pkgs.gnomeExtensions.impatience;
      enable = true;
    }
    {
      extension = pkgs.gnomeExtensions.native-window-placement;
    }
    {
      extension = pkgs.gnomeExtensions.p7-borders;
      enable = true;
      dconf = {
        "org/gnome/shell/extensions/p7-borders" = {
          # default-enabled = true;
          default-maximized-borders = true;
          modal-enabled = true;
        };
      };
    }
    {
      extension = pkgs.gnomeExtensions.p7-cmds;
      enable = true;
    }
    {
      extension = pkgs.gnomeExtensions.windownavigator;
      enable = true;
    }
    {
      extension = pkgs.gnomeExtensions.workspace-indicator;
    }
    {
      extension = pkgs.gnomeExtensions.xwayland-indicator;
      enable = true;
    }
  ];
in {
  imports = map mkExtensionModule extensions;
}
