{pkgs, ...}: let
  extension = pkgs.gnomeExtensions.p7-cmds;
in {
  homePackages = [extension];
  gnomeShellExtensions = [extension.extensionUuid];
}
