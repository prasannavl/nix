{lib}: let
  catalog = import ./catalog.nix;
  core = import ./backends.nix;
  inherit (core) backendConfig configuredBackends missingKeysFrom normalizeBackend validBackendConfig llamaRuntime;

  backendRef = backend: entry: let
    config = backendConfig backend entry;
  in
    assert lib.assertMsg (validBackendConfig config)
    "AI catalog model ${entry.id or "<unknown>"} requires ${backend} to be a non-empty string or an attrset with a non-empty string ref";
      config.ref;

  llamaPresetFor = entry: let
    config = backendConfig "llama" entry;
    configValid = validBackendConfig config;
    preset =
      if configValid
      then config.preset or {}
      else {};
    protectedKeys = [
      "alias"
      "embeddings"
      "hf"
    ];
    conflictingKeys = lib.intersectLists protectedKeys (builtins.attrNames preset);
    invalidValueKeys = builtins.filter (key: !builtins.isString preset.${key}) (builtins.attrNames preset);
  in
    assert lib.assertMsg configValid
    "AI catalog model ${entry.id or "<unknown>"} requires llama to be a non-empty string or an attrset with a non-empty string ref";
    assert lib.assertMsg (builtins.isAttrs preset)
    "AI catalog model ${entry.id or "<unknown>"} requires llama.preset to be an attrset";
    assert lib.assertMsg (conflictingKeys == [])
    "AI catalog model ${entry.id or "<unknown>"} llama.preset cannot override derived keys: ${lib.concatStringsSep ", " conflictingKeys}";
    assert lib.assertMsg (invalidValueKeys == [])
    "AI catalog model ${entry.id or "<unknown>"} requires string llama.preset values: ${lib.concatStringsSep ", " invalidValueKeys}"; preset;
in {
  inherit backendConfig catalog missingKeysFrom normalizeBackend;
  inherit configuredBackends llamaRuntime;

  # Catalog keys in a host selection that do not exist in the catalog.
  missingKeys = missingKeysFrom catalog;

  # Selected entries that lack a reference for the given backend. Entries are
  # catalog attrsets (or {id; missing = true;} sentinels for unknown keys).
  missingRefs = backend: entries:
    builtins.filter (entry: !validBackendConfig (backendConfig backend entry)) entries;

  # Project selected entries onto a backend's reference list, preserving the
  # host's selection order.
  projectModels = backend: entries:
    builtins.map (backendRef backend) entries;

  # Build llama.cpp router presets for selected entries. The entry whose id
  # matches the embedding role id (when set) is additionally flagged with
  # embeddings = "true" so the router routes embedding requests to it.
  # Optional entry.llama.preset settings are merged into the generated preset;
  # alias, embeddings, and hf remain derived and cannot be overridden.
  # Every preset also sets poll = "0": the server default of 50 busy-polls
  # the GPU while waiting for work, so resident models read as constant GPU
  # usage even when idle.
  llamaPresets = embeddingId: entries: let
    refs = builtins.map (backendRef "llama") entries;
    aliases = builtins.map (entry: entry.id) entries;
  in
    assert lib.assertMsg (lib.unique refs == refs)
    "AI catalog llama references must be unique within a runtime";
    assert lib.assertMsg (lib.unique aliases == aliases)
    "AI catalog llama aliases must be unique within a runtime";
      builtins.listToAttrs (builtins.map (entry: {
          name = backendRef "llama" entry;
          value =
            {
              alias = entry.id;
              poll = "0";
            }
            // llamaPresetFor entry
            // (
              if embeddingId != null && entry.id == embeddingId
              then {embeddings = "true";}
              else {}
            );
        })
        entries);
}
