{inputs}: final: prev: let
  appDefinitions = import ../apps {
    nixpkgs = inputs.nixpkgs;
    flake-utils = inputs.flake-utils;
  };
  system = final.stdenv.hostPlatform.system;
  appPackages = (appDefinitions.outputsForSystem system).packages.apps;
  hostInstallableApps = let
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
    prev.lib.mapAttrs (_name: value: projectPackage value) appPackages;
in {
  apps = (prev.apps or {}) // hostInstallableApps;
}
