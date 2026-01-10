{pkgs, ...}: let
  extension = pkgs.gnomeExtensions.workspace-indicator;
in {
  home.packages = [extension];
}
