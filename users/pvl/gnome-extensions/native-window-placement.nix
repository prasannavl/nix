{pkgs, ...}: let
  extension = pkgs.gnomeExtensions.native-window-placement;
in {
  home.packages = [extension];
}
