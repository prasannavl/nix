{
  inputs ? {},
  nixpkgs,
  flake-utils,
  overlays ? [],
  stackProfiles ? {},
}: let
  appsFn = import ./apps.nix;
  pkgHelper = import ./pkg-helper.nix;
  serviceModuleFactory = import ./service-module.nix;
  lintFn = import ./lint.nix;
  packagesFn = import ./packages.nix;
in rec {
  inherit pkgHelper;
  stacks = stackProfiles;
  inherit serviceModuleFactory;
  serviceModule = serviceModuleFactory.mkServiceLib {
    stackName = "root";
    defaultUser = "root";
    defaultClientSecretsBasePath = ../../data/secrets/pvl/services;
    defaultClientIdentitySuffix = "invalid.invalid";
    defaultServiceIdentitySuffix = "invalid.invalid";
    defaultPostgresUrl = "";
    defaultPostgresCaCertPath = "";
    defaultNatsUrl = "";
    defaultNatsCaCertPath = "";
  };
  withPkgs = pkgs: let
    baseOutputs = packagesFn {
      inherit pkgs;
    };
    isPackageAvailableForSystem = pkg: let
      resolved = builtins.tryEval pkg;
    in
      if !resolved.success
      then false
      else if !pkgs.lib.isDerivation resolved.value
      then false
      else if
        !(
          builtins.hasAttr "meta" resolved.value
          && builtins.hasAttr "platforms" resolved.value.meta
        )
      then true
      else pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform resolved.value;
    packageSetForSystem = pkgs.lib.filterAttrs (_: isPackageAvailableForSystem) baseOutputs.packages;
    stdPackageSetForSystem = pkgs.lib.filterAttrs (_: isPackageAvailableForSystem) baseOutputs.stdPackages;
    rootAppSetForSystem = pkgs.lib.filterAttrs (_: isPackageAvailableForSystem) baseOutputs.rootApps;
    lint = lintFn {
      inherit pkgs;
      packageSet = stdPackageSetForSystem;
      inherit pkgHelper;
    };
    packages = packageSetForSystem // lint.packages;
    apps = appsFn {
      rootApps = rootAppSetForSystem;
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
    ) {} (builtins.attrValues packageSetForSystem);
  in {
    inherit apps lint nixosModules packages;
    inherit (lint) formatter;
  };

  pkgsFor = system:
    import nixpkgs {
      inherit system;
      overlays =
        if overlays != []
        then overlays
        else
          nixpkgs.lib.optional (builtins.hasAttr "crane" inputs)
          (_final: prev: {
            craneLib = inputs.crane.mkLib prev;
          });
    };

  outputsFor = systems:
    nixpkgs.lib.genAttrs systems (system: withPkgs (pkgsFor system));

  standardOutputsFrom = systems: outputsBySystem:
    flake-utils.lib.eachSystem systems (system: let
      outputs = outputsBySystem.${system};
    in {
      inherit (outputs) apps formatter packages;
    });

  standardOutputsFor = systems:
    standardOutputsFrom systems (outputsFor systems);

  # Package-owned modules now resolve their package from the consuming host's
  # `pkgs`, so any system's exported module set is equivalent.
  nixosModules = (withPkgs (pkgsFor (builtins.head flake-utils.lib.defaultSystems))).nixosModules;

  mkNixosSystem = {
    commonModules,
    inputs,
  }: {
    hostName,
    modules,
    stack ? null,
    system,
  }:
    nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit hostName inputs stack system;
        stacks = stackProfiles;
      };
      modules =
        commonModules
        ++ [
          {
            home-manager.extraSpecialArgs = {
              inherit inputs stack;
              stacks = stackProfiles;
            };
          }
        ]
        ++ modules;
    };

  packagesFor = systems:
    nixpkgs.lib.mapAttrs (_: outputs: outputs.packages) (outputsFor systems);
}
