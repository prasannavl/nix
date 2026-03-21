{inputs}: final: prev: let
  packageDefinitions = import ../pkgs {
    inherit (inputs) nixpkgs;
    inherit (inputs) flake-utils;
  };
  inherit (final.stdenv.hostPlatform) system;
  packageTree = (packageDefinitions.outputsForSystem system).packageTree.pkgs;
  hostInstallablePackages = let
    projectPackage = value:
      if prev.lib.isDerivation value
      then value.build or value
      else if builtins.isAttrs value
      then prev.lib.mapAttrs (_name: projectPackage) value
      else value;
  in
    prev.lib.mapAttrs (_name: projectPackage) packageTree;
in
  hostInstallablePackages
