{ pkgs, ... }:

let
  extension = pkgs.gnomeExtensions.windownavigator;
in {
  homePackages = [ extension ];
  gnomeShellExtensions = [ extension.extensionUuid ];
}
