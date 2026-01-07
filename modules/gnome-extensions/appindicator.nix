{ pkgs, ... }:

let
  extension = pkgs.gnomeExtensions.appindicator;
in {
  homePackages = [ extension ];
  gnomeShellExtensions = [ extension.extensionUuid ];
}
