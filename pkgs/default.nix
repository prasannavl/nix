{
  nixpkgs,
  flake-utils,
}:
import ../lib/flakelib.nix {
  inherit nixpkgs flake-utils;
  rootDir = ./.;
  namespace = "pkgs";
}
