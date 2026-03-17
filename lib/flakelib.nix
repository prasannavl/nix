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
    leafName = lib.last entry.segments;
  };

  requireDefault = kind: entry: attrs:
    if attrs == {}
    then null
    else if attrs ? default
    then attrs.default
    else throw "Expected `${kind}.default` in ${toString entry.path}/flake.nix for root `${namespace}` export";

  nestedLeafTree = kind: entry: attrs: let
    defaultValue = requireDefault kind entry attrs;
  in
    if defaultValue == null
    then {}
    else lib.setAttrByPath ([namespace] ++ entry.segments) (defaultValue // attrs);

  flatAliases = entry: attrs:
    lib.foldl'
    (acc: aliasName: let
      flatName = "${entry.leafName}-${aliasName}";
    in
      if builtins.hasAttr flatName acc
      then throw "Duplicate flat alias `${flatName}` while collecting ${namespace} flakes"
      else acc // {"${flatName}" = attrs.${aliasName};})
    {}
    (builtins.filter (name: name != "default") (lib.attrNames attrs));

  buildTree = kind: getAttrs: system: let
    entries = map (outputsForEntry system) flakeEntries;
    nested =
      lib.foldl'
      (acc: entry: lib.recursiveUpdate acc (nestedLeafTree kind entry (getAttrs entry)))
      {}
      entries;
    aliases =
      lib.foldl'
      (acc: entry: lib.recursiveUpdate acc (flatAliases entry (getAttrs entry)))
      {}
      entries;
  in
    lib.recursiveUpdate nested aliases;
in {
  outputsForSystem = system: {
    packages = buildTree "packages" (entry: entry.packages) system;
    apps = buildTree "apps" (entry: entry.apps) system;
  };
}
