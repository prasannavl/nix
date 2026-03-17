{inputs}: final: prev: let
  packageDefinitions = import ../pkgs {
    nixpkgs = inputs.nixpkgs;
    flake-utils = inputs.flake-utils;
  };
  system = final.stdenv.hostPlatform.system;
  packageTree = (packageDefinitions.outputsForSystem system).packageTree.pkgs;
  hostInstallablePackages = let
    projectPackage = value:
      if prev.lib.isDerivation value
      then
        if value ? build
        then value.build
        else value
      else if builtins.isAttrs value
      then prev.lib.mapAttrs (_name: child: projectPackage child) value
      else value;
  in
    prev.lib.mapAttrs (_name: value: projectPackage value) packageTree;
in
  hostInstallablePackages
