{pkgs, ...}: let
  extension = pkgs.gnomeExtensions.auto-move-windows;
in {
  home.packages = [extension];
}
