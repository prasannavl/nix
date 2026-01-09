{modules, ...} @ args: let
  sharedArgs = builtins.removeAttrs args ["modules"];
  normalizeModule = module:
    if builtins.isAttrs module
    then module
    else {path = module; args = {};};
  normalizedModules = map normalizeModule modules;
  moduleResults =
    map
    (module:
      import module.path (sharedArgs // (module.args or {})))
    normalizedModules;

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
  gnomeShellExtensions = mergeLists "gnomeShellExtensions";
  gnomeFavoriteApps = mergeLists "gnomeFavoriteApps";
}
