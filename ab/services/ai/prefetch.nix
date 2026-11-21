let
  backendLib = import ./backends.nix;

  duplicateValues = values: let
    counts =
      builtins.foldl'
      (result: value:
        result
        // {
          ${value} = (result.${value} or 0) + 1;
        })
      {}
      values;
  in
    builtins.filter (value: counts.${value} > 1) (builtins.attrNames counts);

  selectionArtifacts = {
    artifactsByDefault,
    catalog,
    key,
    selection,
  }:
    if !(catalog ? ${key})
    then []
    else let
      requested =
        if builtins.isAttrs selection
        then selection.artifacts or null
        else if builtins.isList selection
        then selection
        else null;
      selectAll =
        if requested == null
        then artifactsByDefault
        else requested == true;
    in
      if builtins.isList requested
      then requested
      else if selectAll
      then builtins.attrNames (backendLib.artifactsOf catalog.${key})
      else [];
in rec {
  # Resolve the user-facing bool/list/expanded map into exact downloadable
  # units and diagnostics. This is pure catalog algebra and needs no NixOS
  # module evaluation, so composition behavior stays cheap to test.
  resolveHf = {
    artifactsByDefault ? true,
    catalog,
    selections,
  }: let
    enabledKeys = builtins.filter (key: selections.${key} != false) (builtins.attrNames selections);
    knownKeys = builtins.filter (key: catalog ? ${key}) enabledKeys;
    artifactsFor = key:
      selectionArtifacts {
        inherit artifactsByDefault catalog key;
        selection = selections.${key};
      };
    baseSelected = key: let
      selection = selections.${key};
    in
      !builtins.isAttrs selection || (selection.base or true);
    unitsFor = key: let
      entry = catalog.${key};
      baseSource = backendLib.backendConfig "hf" entry;
      base =
        if baseSelected key && backendLib.validHfConfig baseSource
        then [
          {
            id = "hf:${key}";
            inherit key;
            artifact = null;
            source = baseSource;
          }
        ]
        else [];
      artifacts =
        builtins.concatMap
        (artifact: let
          source = backendLib.artifactConfig "hf" entry artifact;
        in
          if backendLib.validHfConfig source
          then [
            {
              id = "hf:${key}:${artifact}";
              inherit artifact key source;
            }
          ]
          else [])
        (artifactsFor key);
    in
      base ++ artifacts;
    unitsByKey = builtins.listToAttrs (builtins.map (key: {
        name = key;
        value = unitsFor key;
      })
      knownKeys);
  in {
    inherit enabledKeys knownKeys unitsByKey;
    units = builtins.concatMap (key: unitsByKey.${key}) knownKeys;
    unknownModels = builtins.filter (key: !(catalog ? ${key})) enabledKeys;
    emptyModels = builtins.filter (key: unitsByKey.${key} == []) knownKeys;
    unknownArtifacts =
      builtins.concatMap
      (key:
        builtins.map
        (artifact: "${key}.${artifact}")
        (builtins.filter
          (artifact: !((backendLib.artifactsOf catalog.${key}) ? ${artifact}))
          (artifactsFor key)))
      knownKeys;
    duplicateArtifacts =
      builtins.concatMap
      (key:
        builtins.map
        (artifact: "${key}.${artifact}")
        (duplicateValues (artifactsFor key)))
      knownKeys;
  };

  mkHfPlan = {
    cacheDir,
    owner,
    resolved,
    tokenFile ? null,
  }:
    builtins.map
    (unit: {
      inherit cacheDir owner tokenFile;
      inherit (unit) id;
      type = "hf";
      model = unit.source.ref;
      revision = unit.source.revision or null;
      include = unit.source.include or [];
      policy = "required";
    })
    resolved.units;
}
