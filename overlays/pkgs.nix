_: final: prev: let
  packageTree = import ../lib/flake/packages.nix {pkgs = final;};
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
