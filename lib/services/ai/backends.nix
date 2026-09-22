# Pure, dependency-free helpers over the AI catalog's backend references.
#
# Kept free of nixpkgs `lib` so the projection and repository policy layers can
# consume them without threading `lib` through every call site.
rec {
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
    normalizeBackend (entry.${backend} or null);

  validBackendConfig = config:
    builtins.isAttrs config
    && (config ? ref)
    && builtins.isString config.ref
    && config.ref != "";

  # Which llama.cpp engine serves an entry. `llama.runtime` is engine data, not
  # a preset, so it lives beside `ref`/`preset`; omitting it selects the
  # `default` runtime (the upstream build).
  llamaRuntime = entry: let
    config = backendConfig "llama" entry;
  in
    if builtins.isAttrs config && (config ? runtime)
    then config.runtime
    else "default";
}
