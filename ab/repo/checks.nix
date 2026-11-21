{
  checksFor,
  packageSet,
  pkgs,
}: let
  isAvailablePackage = pkg: let
    resolved = builtins.tryEval pkg;
  in
    if !resolved.success
    then false
    else if !pkgs.lib.isDerivation resolved.value
    then false
    else if !((resolved.value.meta or {}) ? platforms)
    then true
    else pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform resolved.value;

  availablePackages = pkgs.lib.filterAttrs (_: isAvailablePackage) packageSet;
  checks = checksFor {
    inherit pkgs;
    lib = pkgs.lib;
    packageSet = availablePackages;
  };
in
  if !builtins.isAttrs checks
  then throw "ab-repo: repository checksFor must return an attribute set"
  else checks
