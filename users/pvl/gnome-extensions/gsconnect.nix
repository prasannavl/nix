{pkgs, ...}: let
  extension = pkgs.gnomeExtensions.gsconnect;
in {
  home.packages = [extension];
}
