{
  inputs ? {},
  nixpkgs,
  flake-utils,
  overlays ? [],
  stackProfiles ? {},
}: let
  lib = nixpkgs.lib;

  appsFn = import ./apps.nix;
  flakeTestsFn = import ./tests;
  libTestsFn = import ../tests;
  lintFn = import ./lint.nix;
  packagesFn = import ./packages.nix;
  pkgHelper = import ./pkg-helper.nix;
  serviceModuleFactory = import ./service-module.nix;

  fallbackOverlays =
    lib.optional (inputs ? crane)
    (_final: prev: {
      craneLib = inputs.crane.mkLib prev;
    });

  isAvailablePackage = pkgs: pkg: let
    resolved = builtins.tryEval pkg;
  in
    if !resolved.success
    then false
    else if !pkgs.lib.isDerivation resolved.value
    then false
    else if !((resolved.value.meta or {}) ? platforms)
    then true
    else pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform resolved.value;

  availableAttrs = pkgs:
    pkgs.lib.filterAttrs (_: isAvailablePackage pkgs);

  moduleAttrsFor = packageSet:
    lib.foldl' (
      acc: pkg:
        acc
        // (
          if builtins.isAttrs pkg && pkg ? passthru
          then pkgHelper.mkNixosModuleAttrs {build = pkg;}
          else {}
        )
    ) {} (builtins.attrValues packageSet);

  rootServiceModule = serviceModuleFactory.mkServiceLib {
    stackName = "root";
    defaultUser = "root";
    defaultClientSecretsBasePath = ../../data/secrets/gap3/services;
    defaultClientIdentitySuffix = "invalid.invalid";
    defaultServiceIdentitySuffix = "invalid.invalid";
    defaultPostgresUrl = "";
    defaultPostgresCaCertPath = "";
    defaultNatsUrl = "";
    defaultNatsCaCertPath = "";
  };
in rec {
  inherit pkgHelper serviceModuleFactory;
  stacks = stackProfiles;
  serviceModule = rootServiceModule;

  pkgsFor = system:
    import nixpkgs {
      inherit system;
      overlays =
        if overlays == []
        then fallbackOverlays
        else overlays;
    };

  withPkgs = pkgs: let
    packageOutputs = packagesFn {inherit pkgs;};
    available = availableAttrs pkgs;

    packageSet = available packageOutputs.packages;
    stdPackageSet = available packageOutputs.stdPackages;
    rootAppSet = available packageOutputs.rootApps;
    checks = (libTestsFn {pkgs = pkgs;}) // (flakeTestsFn {pkgs = pkgs;});

    lint = lintFn {
      inherit pkgs;
      packageSet = stdPackageSet;
      inherit pkgHelper;
    };

    apps = appsFn {
      rootApps = rootAppSet;
      lint = lint;
    };

    packages = packageSet // lint.packages;
    nixosModules = moduleAttrsFor packageSet;
  in {
    inherit apps checks lint nixosModules packages;
    inherit (lint) formatter;
  };

  outputsFor = systems:
    lib.genAttrs systems (system: withPkgs (pkgsFor system));

  standardOutputsFrom = systems: outputsBySystem:
    flake-utils.lib.eachSystem systems (system: let
      outputs = outputsBySystem.${system};
    in {
      inherit (outputs) apps checks formatter packages;
    });

  standardOutputsFor = systems:
    standardOutputsFrom systems (outputsFor systems);

  # Package-owned modules resolve their package from the consuming host's
  # `pkgs`, so any system's exported module set is equivalent.
  nixosModules = (withPkgs (pkgsFor (builtins.head flake-utils.lib.defaultSystems))).nixosModules;

  packagesFor = systems:
    lib.mapAttrs (_: outputs: outputs.packages) (outputsFor systems);
}
