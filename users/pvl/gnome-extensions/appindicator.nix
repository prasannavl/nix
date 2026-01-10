{pkgs, lib, ...}: let
  extension = pkgs.gnomeExtensions.appindicator;
in {
  home.packages = [extension];
  dconf.settings."org/gnome/shell".enabled-extensions = lib.mkAfter [extension.extensionUuid];
}
