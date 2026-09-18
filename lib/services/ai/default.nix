{lib}: let
  catalog = import ./catalog.nix;
in {
  inherit catalog;

  # Catalog keys in a host selection that do not exist in the catalog.
  missingKeys = models:
    builtins.filter (model: !(catalog ? ${model})) models;

  # Selected entries that lack a reference for the given backend. Entries are
  # catalog attrsets (or {id; missing = true;} sentinels for unknown keys).
  missingRefs = backend: entries:
    builtins.filter (entry: !(entry ? ${backend})) entries;

  # Project selected entries onto a backend's reference list, preserving the
  # host's selection order.
  projectModels = backend: entries:
    builtins.map (entry: entry.${backend}) entries;

  # Build llama.cpp router presets for selected entries. The entry whose id
  # matches the embedding role id (when set) is additionally flagged with
  # embeddings = "true" so the router routes embedding requests to it.
  llamaPresets = embeddingId: entries:
    builtins.listToAttrs (builtins.map (entry: {
        name = entry.llama;
        value =
          {alias = entry.id;}
          // (
            if embeddingId != null && entry.id == embeddingId
            then {embeddings = "true";}
            else {}
          );
      })
      entries);
}
