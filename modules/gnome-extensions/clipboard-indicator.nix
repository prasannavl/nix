{pkgs, ...}: let
  extension = pkgs.gnomeExtensions.clipboard-indicator;
in {
  homePackages = [extension];
  gnomeShellExtensions = [extension.extensionUuid];
}
