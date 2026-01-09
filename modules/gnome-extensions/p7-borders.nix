{pkgs, ...}: let
  extension = pkgs.gnomeExtensions.p7-borders;
in {
  homePackages = [extension];
  gnomeShellExtensions = [extension.extensionUuid];
}
