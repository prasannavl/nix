{pkgs, ...}: let
  extension = pkgs.gnomeExtensions.native-window-placement;
in {
  homePackages = [extension];
}
