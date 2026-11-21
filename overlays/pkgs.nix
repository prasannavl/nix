_: final: prev: let
  ab = (import ../ab).withRepository {
    root = ../.;
    manifest = import ../pkgs/manifest.nix;
    treefmtConfig = ../treefmt.toml;
  };
  packageTree = ab.repo.packagesFor final;
  hostInstallablePackages = let
    projectPackage = value:
      if prev.lib.isDerivation value
      then value.build or value
      else if builtins.isAttrs value
      then prev.lib.mapAttrs (_name: projectPackage) value
      else value;
  in
    prev.lib.mapAttrs (_name: projectPackage) packageTree.packages;
in
  hostInstallablePackages
