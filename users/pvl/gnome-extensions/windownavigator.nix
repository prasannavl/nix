{pkgs, lib, ...}: let
  extension = pkgs.gnomeExtensions.windownavigator;
in {
  home.packages = [extension];
  dconf.settings."org/gnome/shell".enabled-extensions = lib.mkAfter [extension.extensionUuid];
}
