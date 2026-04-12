{
  nixpkgs,
  flake-utils,
}: let
  appsFn = import ./apps.nix;
  pkgHelper = import ./pkg-helper.nix;
  serviceModule = import ./service-module.nix;
  lintFn = import ./lint.nix;
  packagesFn = import ./packages.nix;
in rec {
  inherit pkgHelper;
  inherit serviceModule;
  withPkgs = pkgs: let
    baseOutputs = packagesFn {
      inherit pkgs;
    };
    lint = lintFn {
      inherit pkgs;
      packageSet = baseOutputs.stdPackages;
      inherit pkgHelper;
    };
    packages = baseOutputs.packages // lint.packages;
    apps = appsFn {
      rootApps = baseOutputs.rootApps;
      lint = lint;
    };
    nixosModules = nixpkgs.lib.foldl' (
      acc: pkg:
        acc
        // (
          if builtins.isAttrs pkg && builtins.hasAttr "passthru" pkg
          then pkgHelper.mkNixosModuleAttrs {build = pkg;}
          else {}
        )
    ) {} (builtins.attrValues baseOutputs.packages);
  in {
    inherit apps lint nixosModules packages;
    inherit (lint) formatter;
  };

  outputsFor = systems:
    nixpkgs.lib.genAttrs systems (system: withPkgs nixpkgs.legacyPackages.${system});

  standardOutputsFrom = systems: outputsBySystem:
    flake-utils.lib.eachSystem systems (system: let
      outputs = outputsBySystem.${system};
    in {
      inherit (outputs) apps formatter packages;
    });

  standardOutputsFor = systems:
    standardOutputsFrom systems (outputsFor systems);

  packagesFor = systems:
    nixpkgs.lib.mapAttrs (_: outputs: outputs.packages) (outputsFor systems);
}
