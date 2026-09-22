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
    if builtins.isAttrs entry
    then normalizeBackend (entry.${backend} or null)
    else null;

  validBackendConfig = config:
    builtins.isAttrs config
    && (config ? ref)
    && builtins.isString config.ref
    && builtins.match "[^ \t\r\n]+" config.ref != null;

  # Which llama.cpp engine an entry targets. Missing or malformed llama refs do
  # not target an engine; `default` applies only to a valid llama ref.
  llamaRuntime = entry: let
    config = backendConfig "llama" entry;
  in
    if !validBackendConfig config
    then null
    else if !(config ? runtime)
    then "default"
    else if builtins.isString config.runtime && config.runtime != ""
    then config.runtime
    else null;

  validLlamaRuntime = entry: let
    config = backendConfig "llama" entry;
  in
    !validBackendConfig config
    || !(config ? runtime)
    || (builtins.isString config.runtime && config.runtime != "");

  runtimeConfigured = runtimes: runtime:
    runtime
    != null
    && (runtimes ? ${runtime})
    && ((runtimes.${runtime}.deployments or []) != []);

  # Backend membership is a host capability, not raw catalog shape. A model is
  # configured only when it has a valid reference and the matching backend has
  # at least one deployment.
  configuredBackends = {
    entry,
    ollama ? false,
    runtimes ? {},
  }: let
    runtime = llamaRuntime entry;
  in {
    ollama = ollama && validBackendConfig (backendConfig "ollama" entry);
    llamaRuntime =
      if runtimeConfigured runtimes runtime
      then runtime
      else null;
  };
}
