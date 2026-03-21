{
  nixpkgs,
  flake-utils,
}:
(import ../lib/flake).flakeTree {
  inherit nixpkgs flake-utils;
  rootDir = ./.;
  namespace = "pkgs";
}
