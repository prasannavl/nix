{pkgs, lib, ...}: let
  extension = pkgs.gnomeExtensions.bluetooth-quick-connect;
in {
  home.packages = [extension];
  dconf.settings = {
    "org/gnome/shell" = {
      enabled-extensions = lib.mkAfter [extension.extensionUuid];
    };
    "org/gnome/shell/extensions/bluetooth-quick-connect" = {
      keep-menu-on-toggle = true;
      refresh-button-on = true;
      show-battery-value-on = true;
    };
  };
}
