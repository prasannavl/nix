{
  nixpkgs,
  flake-utils,
}:
(import ../lib/internal).flakeTree {
  inherit nixpkgs flake-utils;
  rootDir = ./.;
  namespace = "pkgs";
}
