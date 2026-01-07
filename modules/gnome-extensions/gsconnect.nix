{ pkgs, ... }:

let
  extension = pkgs.gnomeExtensions.gsconnect;
in {
  homePackages = [ extension ];
}
