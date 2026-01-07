{ pkgs, ... }:

let
  extension = pkgs.gnomeExtensions.impatience;
in {
  homePackages = [ extension ];
  gnomeShellExtensions = [ extension.extensionUuid ];
}
