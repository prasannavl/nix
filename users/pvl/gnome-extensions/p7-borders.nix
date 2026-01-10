{
  pkgs,
  lib,
  ...
}: let
  extension = pkgs.gnomeExtensions.p7-borders;
in {
  home.packages = [extension];
  dconf.settings."org/gnome/shell".enabled-extensions = lib.mkAfter [extension.extensionUuid];
}
