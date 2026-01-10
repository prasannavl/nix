{pkgs, lib, ...}: let
  extension = pkgs.gnomeExtensions.brightness-control-using-ddcutil;
in {
  home.packages = [extension];
  dconf.settings = {
    "org/gnome/shell" = {
      enabled-extensions = lib.mkAfter [extension.extensionUuid];
    };
    "org/gnome/shell/extensions/display-brightness-ddcutil" = {
      button-location = 1;
      ddcutil-binary-path = "${pkgs.ddcutil}/bin/ddcutil";
    };
  };
}
