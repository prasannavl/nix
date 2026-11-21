{
  lib,
  flakeUtils,
  nixpkgs,
  contextFor,
  mkApps,
  checksFor ? _pkgs: _ab: {},
  overlays ? [],
  fallbackOverlays ? [],
}: let
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

  moduleAttrsFor = ab: packageSet:
    lib.foldl'
    (
      acc: pkg:
        acc
        // (
          if builtins.isAttrs pkg && pkg ? passthru
          then ab.flake.modules {build = pkg;}
          else {}
        )
    )
    {}
    (builtins.attrValues packageSet);
in rec {
  pkgsFor = system:
    import nixpkgs {
      inherit system;
      overlays =
        if overlays == []
        then fallbackOverlays
        else overlays;
    };

  withPkgs = pkgs: let
    ab = contextFor pkgs;
    packageOutputs = ab.repo.packages;
    available = availableAttrs pkgs;
    packageSet = available packageOutputs.packages;
    rootAppSet = available packageOutputs.rootApps;
    checks = checksFor pkgs ab;
    tasks = ab.repo.tasks;
    apps = mkApps {
      rootApps = rootAppSet;
      inherit tasks;
    };
    packages = packageSet // tasks.packages;
    nixosModules = moduleAttrsFor ab packageOutputs.packages;
  in {
    inherit apps checks nixosModules packages tasks;
    inherit (tasks) formatter;
  };

  outputsFor = systems:
    lib.genAttrs systems (system: withPkgs (pkgsFor system));

  standardOutputsFrom = systems: outputsBySystem:
    flakeUtils.lib.eachSystem systems (system: let
      outputs = outputsBySystem.${system};
    in {
      inherit (outputs) apps checks formatter packages;
    });

  standardOutputsFor = systems:
    standardOutputsFrom systems (outputsFor systems);

  nixosModules = (withPkgs (pkgsFor (builtins.head flakeUtils.lib.defaultSystems))).nixosModules;

  packagesFor = systems:
    lib.mapAttrs (_: outputs: outputs.packages) (outputsFor systems);
}
