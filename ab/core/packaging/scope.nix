{
  pkgs,
  ab,
}: let
  scope =
    pkgs
    // {
      pkgs = scope;
      ab = ab;
      callPackage = pkgs.lib.callPackageWith scope;
    };
in
  scope
