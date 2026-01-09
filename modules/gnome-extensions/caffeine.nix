{pkgs, ...}: let
  extension = pkgs.gnomeExtensions.caffeine;
in {
  homePackages = [extension];
  gnomeShellExtensions = [extension.extensionUuid];
}
