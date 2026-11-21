# Pure, dependency-free helpers over the AI catalog's backend references.
#
# Kept free of nixpkgs `lib` so the projection and repository policy layers can
# consume them without threading `lib` through every call site.
rec {
  # Resolve one deployment field through its local value, backend default, and
  # final fallback. Both the pure policy projection and the NixOS renderer use
  # this helper so their view of a flat llama.cpp deployment cannot drift.
  effectiveDeploymentValue = defaults: deployment: name: fallback: let
    local = deployment.${name} or null;
    shared = defaults.${name} or null;
  in
    if local != null
    then local
    else if shared != null
    then shared
    else fallback;

  # Paths rendered into tmpfiles rules or consumed before activation use a
  # deliberately narrow canonical shape. Rejecting aliases is simpler and safer
  # than normalizing strings that later cross Nix, JSON, shell, and systemd.
  validStoragePath = path: let
    components =
      if builtins.isString path && builtins.stringLength path > 0
      then builtins.tail (builtins.filter builtins.isString (builtins.split "/" path))
      else [];
    validComponent = component:
      component
      != "."
      && component != ".."
      && builtins.match "[A-Za-z0-9._+,:=@-]+" component != null;
  in
    builtins.isString path
    && builtins.stringLength path > 1
    && builtins.substring 0 1 path == "/"
    && components != []
    && builtins.all validComponent components;

  storagePathComponents = path:
    if validStoragePath path
    then builtins.tail (builtins.filter builtins.isString (builtins.split "/" path))
    else [];

  listHasPrefix = prefix: values:
    builtins.length prefix
    <= builtins.length values
    && builtins.genList (index: builtins.elemAt values index) (builtins.length prefix) == prefix;

  # Compare components rather than string prefixes, so `/cache/a` contains
  # `/cache/a/b` but does not overlap `/cache/ab`. Managed backend roots may
  # not be equal or nested because their independent reconcilers and runtimes
  # must never mutate the same storage tree.
  storagePathContains = parent: child:
    validStoragePath parent
    && validStoragePath child
    && listHasPrefix (storagePathComponents parent) (storagePathComponents child);

  storagePathsOverlap = left: right:
    storagePathContains left right || storagePathContains right left;

  indexedPairs = values:
    builtins.concatLists (builtins.genList
      (leftIndex:
        builtins.map
        (rightIndex: {
          left = builtins.elemAt values leftIndex;
          right = builtins.elemAt values rightIndex;
        })
        (builtins.genList
          (offset: leftIndex + offset + 1)
          (builtins.length values - leftIndex - 1)))
      (builtins.length values));

  # Catalog keys in a host selection that do not exist in the catalog.
  missingKeysFrom = sourceCatalog: models:
    builtins.filter (model: !(sourceCatalog ? ${model})) models;

  # A reference string is shorthand for the expanded backend configuration.
  # Normalize at this boundary so every projection consumes one shape.
  normalizeBackend = value:
    if builtins.isString value
    then {ref = value;}
    else value;

  backendConfig = backend: entry:
    if builtins.isAttrs entry
    then normalizeBackend (entry.${backend} or null)
    else null;

  # Auxiliary weights belong to the model whose runtime consumes them. Keep
  # their short, local names in the catalog and resolve backend references only
  # at this boundary.
  artifactsOf = entry:
    if builtins.isAttrs entry && builtins.isAttrs (entry.artifacts or null)
    then entry.artifacts
    else {};

  artifactConfig = backend: entry: artifact:
    backendConfig backend ((artifactsOf entry).${artifact} or null);

  validBackendConfig = config:
    builtins.isAttrs config
    && (config ? ref)
    && builtins.isString config.ref
    && builtins.match "[^ \t\r\n]+" config.ref != null;

  validHfConfig = config:
    validBackendConfig config
    && ((config.revision or null) == null || (builtins.isString config.revision && config.revision != ""))
    && builtins.isList (config.include or [])
    && builtins.all (include: builtins.isString include && include != "") (config.include or []);

  # Runtime names become parts of systemd unit names, cache paths, state-file
  # names, and prefetch identifiers. Keep one deliberately narrow grammar at
  # the backend boundary so every projection uses the same safe identity.
  validRuntimeName = runtime:
    builtins.isString runtime
    && builtins.match "[a-z0-9][a-z0-9-]*" runtime != null;

  # Which llama.cpp engines may load an entry. A plain/string reference and an
  # expanded reference without `runtimes` both target upstream llama.cpp.
  llamaRuntimes = entry: let
    config = backendConfig "llama" entry;
  in
    if !validBackendConfig config
    then []
    else config.runtimes or ["default"];

  validLlamaRuntimes = entry: let
    config = backendConfig "llama" entry;
    runtimes = llamaRuntimes entry;
  in
    !validBackendConfig config
    || (
      builtins.isList runtimes
      && runtimes != []
      && builtins.all validRuntimeName runtimes
      && builtins.length (builtins.attrNames (builtins.listToAttrs (builtins.map (runtime: {
          name = runtime;
          value = true;
        })
        runtimes)))
      == builtins.length runtimes
    );
}
