{ modules
, ...
} @ args:

let
  sharedArgs = builtins.removeAttrs args [ "modules" ];
  moduleResults = map (modulePath: import modulePath sharedArgs) modules;

  mergeAttrs = attr:
    builtins.foldl'
      (acc: module: acc // (module.${attr} or {}))
      {}
      moduleResults;

  mergeLists = attr:
    builtins.concatLists (map (module: module.${attr} or []) moduleResults);

in {
  inherit moduleResults;

  dconfSettings = mergeAttrs "dconfSettings";
  homeFiles = mergeAttrs "homeFiles";
  services = mergeAttrs "services";
  programs = mergeAttrs "programs";
  homePackages = mergeLists "homePackages";
}
