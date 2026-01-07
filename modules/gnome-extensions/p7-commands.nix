{ pkgs, ... }:

let
  extension = pkgs.gnomeExtensions.p7-commands;
in {
  homePackages = [ extension ];
  gnomeShellExtensions = [ extension.extensionUuid ];
}
