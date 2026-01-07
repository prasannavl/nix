{ pkgs, ... }:

let
  extension = pkgs.gnomeExtensions.auto-move-windows;
in {
  homePackages = [ extension ];
}
