{ pkgs, ... }:

let
  extension = pkgs.gnomeExtensions.workspace-indicator;
in {
  homePackages = [ extension ];
}
