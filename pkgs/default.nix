{
  nixpkgs,
  flake-utils,
}:
import (import ../lib/internal).flakeTree {
  inherit nixpkgs flake-utils;
  rootDir = ./.;
  namespace = "pkgs";
}
