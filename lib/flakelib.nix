{
  nixpkgs,
  flake-utils,
  rootDir,
  namespace,
}: let
  lib = nixpkgs.lib;

  collectFlakeDirs = dir: segments: let
    entries = builtins.readDir dir;
    childDirNames = lib.attrNames (lib.filterAttrs (_name: type: type == "directory") entries);
    childEntries = lib.concatMap (name: collectFlakeDirs (dir + "/${name}") (segments ++ [name])) childDirNames;
    currentEntry = lib.optional (builtins.hasAttr "flake.nix" entries) {
      inherit segments;
      path = dir;
    };
  in
    currentEntry ++ childEntries;

  flakeEntries = collectFlakeDirs rootDir [];

  outputsForEntry = system: entry: let
    flakeDef = import (entry.path + "/flake.nix");
    flakeOutputs = flakeDef.outputs {
      inherit nixpkgs flake-utils;
      self = null;
    };
    packages =
      if flakeOutputs ? packages && builtins.hasAttr system flakeOutputs.packages
      then flakeOutputs.packages.${system}
      else {};
    apps =
      if flakeOutputs ? apps && builtins.hasAttr system flakeOutputs.apps
      then flakeOutputs.apps.${system}
      else {};
  in {
    inherit (entry) path segments;
    inherit apps packages;
  };

  requireDefault = kind: entry: attrs:
    if attrs ? default
    then attrs.default
    else throw "Expected `${kind}.default` in ${toString entry.path}/flake.nix for root `${namespace}` export";

  removeDefault = attrs: lib.filterAttrs (name: _value: name != "default") attrs;

  attachAliases = entry: defaultPackage: packageAliases: let
    passthruAliases = packageAliases;
  in
    if passthruAliases == {}
    then defaultPackage
    else if !lib.isDerivation defaultPackage
    then throw "Expected `packages.default` to be a derivation in ${toString entry.path}/flake.nix for root `${namespace}` export"
    else
      defaultPackage.overrideAttrs (old: {
        passthru = (old.passthru or {}) // passthruAliases;
      });

  installableLeaf = entry: let
    defaultPackage = requireDefault "packages" entry entry.packages;
  in
    attachAliases entry defaultPackage (removeDefault entry.packages);

  buildPackageTree = system: let
    entries = map (outputsForEntry system) flakeEntries;
  in
    lib.setAttrByPath [namespace] (
      lib.foldl'
      (acc: entry: lib.recursiveUpdate acc (lib.setAttrByPath entry.segments (installableLeaf entry)))
      {}
      entries
    );
in {
  outputsForSystem = system: {
    packageTree = buildPackageTree system;
  };
}
